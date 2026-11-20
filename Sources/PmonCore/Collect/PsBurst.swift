import Foundation
import Darwin

/// CPU time of processes we cannot read natively, from the setuid `ps` tool.
/// Costs about 28 ms of CPU per call, so it runs only as the fallback when the `top` stream
/// is unavailable, or in bursts when finer resolution is wanted.
public struct PsCollector {
    public var executable = "/bin/ps"
    public init() {}

    public func collect(pids: [Int32]) -> PsSample? {
        guard !pids.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-p", pids.map(String.init).joined(separator: ","), "-o", "pid=,utime=,stime="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let mono = MachTime.ns(mach_absolute_time())
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // ps exits 1 when some of the pids no longer exist; the rows it did print are still valid.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let rows = Self.parse(text)
        return rows.isEmpty ? nil : PsSample(monoNs: mono, rows: rows)
    }

    /// Lines of "pid utime stime". Malformed lines are skipped.
    static func parse(_ text: String) -> [PsRow] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let u = time(f[1]), let s = time(f[2]) else { return nil }
            return PsRow(pid: pid, userNs: u, sysNs: s)
        }
    }

    /// "M:SS.cc" where minutes are unbounded ("461:20.81"); also accepts "H:MM:SS.cc".
    static func time(_ s: Substring) -> UInt64? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let sec = Double(parts.last!), sec >= 0, sec < 60 else { return nil }
        var minutes: UInt64 = 0
        for part in parts.dropLast() {
            guard let v = UInt64(part) else { return nil }
            minutes = minutes * 60 + v
        }
        return minutes * 60_000_000_000 + UInt64((sec * 1e9).rounded())
    }
}
