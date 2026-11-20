import Foundation

/// Incremental parser for the output of `top -l 0 -stats ...`.
///
/// It is strict on purpose: the column set is pinned with `-stats`, the header row of every
/// sample must match it exactly, and a row that does not parse rejects its whole sample.
/// A format change after an OS update therefore surfaces as a failure, never as wrong numbers.
public struct TopParser {
    public enum Failure: Error, Equatable {
        case headerMismatch(String)
        case badRow(String)
    }

    /// `-stats` keys in the order requested, and the header label top prints for each.
    public static let headerLabels: [String: String] = [
        "pid": "PID", "time": "TIME", "mem": "MEM", "cmprs": "CMPRS", "pageins": "PAGEINS", "csw": "CSW",
        "threads": "#TH", "idlew": "IDLEW", "instrs": "INSTRS", "cycles": "CYCLES", "faults": "FAULTS",
        "cpu": "%CPU", "power": "POWER", "uid": "UID", "ppid": "PPID",
    ]

    public let stats: [String]
    private let expectedHeader: [String]
    private var partialLine = ""
    private var rows: [TopRow] = []
    private var inSample = false, sawHeader = false
    private var failure: Failure?
    private var completed: [Result<[TopRow], Failure>] = []

    /// `stats` must not contain `command`: process names contain spaces and break column parsing.
    public init(stats: [String]) {
        precondition(stats.first == "pid" && !stats.contains("command"), "pid must be first and command must not be requested")
        self.stats = stats
        expectedHeader = stats.map { Self.headerLabels[$0] ?? $0.uppercased() }
    }

    /// Feed raw output. Only complete lines are consumed; a trailing partial line is kept.
    public mutating func feed(_ text: String) {
        partialLine += text
        while let nl = partialLine.firstIndex(of: "\n") {
            let line = String(partialLine[..<nl])
            partialLine.removeSubrange(...nl)
            consume(line)
        }
    }

    /// Declare the current sample finished (the stream went quiet). A sample also finishes
    /// when the next one begins. Does nothing while a line is still incomplete.
    public mutating func flush() {
        guard partialLine.isEmpty else { return }
        finishSample()
    }

    /// Completed samples since the last call, oldest first.
    public mutating func take() -> [Result<[TopRow], Failure>] {
        defer { completed.removeAll() }
        return completed
    }

    private mutating func finishSample() {
        guard inSample, sawHeader else { return }
        completed.append(failure.map { .failure($0) } ?? .success(rows))
        rows.removeAll(keepingCapacity: true)
        inSample = false; sawHeader = false; failure = nil
    }

    private mutating func consume(_ line: String) {
        if line.hasPrefix("Processes:") {
            finishSample()
            inSample = true
            return
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        if fields.first == "PID" {
            inSample = true; sawHeader = true
            if fields.map(String.init) != expectedHeader { failure = failure ?? .headerMismatch(line) }
            return
        }
        guard sawHeader, !fields.isEmpty, failure == nil else { return }    // summary lines and blanks
        guard let row = parseRow(fields) else { failure = .badRow(line); return }
        rows.append(row)
    }

    private func parseRow(_ f: [Substring]) -> TopRow? {
        guard f.count == stats.count else { return nil }
        var r = TopRow()
        for (key, value) in zip(stats, f) {
            switch key {
            case "pid": guard let v = Int32(value) else { return nil }; r.pid = v
            case "time": guard let (ns, coarse) = Self.cpuTime(value) else { return nil }; r.cpuNs = ns; r.coarse = coarse
            case "mem": guard let v = Self.size(value) else { return nil }; r.mem = v
            case "cmprs": guard let v = Self.size(value) else { return nil }; r.cmprs = v
            case "pageins": guard let v = Self.count(value) else { return nil }; r.pageins = v
            case "csw": guard let v = Self.count(value) else { return nil }; r.csw = v
            case "idlew": guard let v = Self.count(value) else { return nil }; r.idlew = v
            case "faults": guard let v = Self.count(value) else { return nil }; r.faults = v
            case "instrs": guard let v = Self.count(value) else { return nil }; r.instrs = v
            case "cycles": guard let v = Self.count(value) else { return nil }; r.cycles = v
            case "threads":
                // "12" or "556/8" (total/running)
                guard let v = Int32(value.split(separator: "/").first ?? "") else { return nil }; r.threads = v
            default:
                // Rate and identity columns (%CPU, POWER, UID, PPID) are not used, but must look sane.
                guard value.first?.isNumber == true else { return nil }
            }
        }
        return r
    }

    /// Strip top's trend markers ("+" grew, "-" shrank since the last sample).
    private static func untrended(_ s: Substring) -> Substring {
        (s.last == "+" || s.last == "-") ? s.dropLast() : s
    }

    /// "123", "123+" -> 123
    static func count(_ s: Substring) -> UInt64? { UInt64(untrended(s)) }

    /// "0B", "3953K", "436M+", "1.2G" -> bytes
    static func size(_ s: Substring) -> UInt64? {
        var body = untrended(s)
        var mult = 1.0
        switch body.last {
        case "B": body = body.dropLast()
        case "K": mult = 1024; body = body.dropLast()
        case "M": mult = 1024 * 1024; body = body.dropLast()
        case "G": mult = 1024 * 1024 * 1024; body = body.dropLast()
        case "T": mult = 1024 * 1024 * 1024 * 1024; body = body.dropLast()
        default: break
        }
        guard let v = Double(body), v >= 0 else { return nil }
        return UInt64(v * mult)
    }

    /// "MM:SS.cc" (hundredths) or "HH:MM:SS" (whole seconds, shown once CPU time passes an hour).
    static func cpuTime(_ s: Substring) -> (ns: UInt64, coarse: Bool)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 2:
            guard let m = UInt64(parts[0]), let sec = Double(parts[1]), sec >= 0, sec < 60 else { return nil }
            return (m * 60_000_000_000 + UInt64((sec * 1e9).rounded()), false)
        case 3:
            guard let h = UInt64(parts[0]), let m = UInt64(parts[1]), let sec = UInt64(parts[2]), m < 60, sec < 60 else { return nil }
            return ((h * 3600 + m * 60 + sec) * 1_000_000_000, true)
        default:
            return nil
        }
    }
}
