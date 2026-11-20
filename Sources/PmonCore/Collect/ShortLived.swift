import Foundation
import Darwin
import CPmonSys

/// Finds processes that live and die between regular sweeps, by comparing the pid list many
/// times a second for a few seconds. Identity (path, parent) is readable for every process.
///
/// A process that lives for less than the scan interval is seen only by chance, but the chance
/// is proportional to how long it lives: the number of *sightings* per executable is therefore
/// a fair sample of where the time went, even when most individual processes are missed.
public final class ShortLivedScanner {
    private let lock = NSLock()
    private var result: ShortLivedScan?
    private var running = false

    public init() {}

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Run one scan on a background thread. Does nothing if one is already running.
    public func start(seconds: Double = 10, intervalMs: Int = 50) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in
            let scan = Self.scan(seconds: seconds, intervalMs: intervalMs)
            guard let self else { return }
            self.lock.lock(); self.result = scan; self.running = false; self.lock.unlock()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// The result of the last finished scan, once.
    public func take() -> ShortLivedScan? {
        lock.lock(); defer { lock.unlock() }
        defer { result = nil }
        return result
    }

    private struct Track {
        var path = "", name = ""
        var ppid: Int32 = 0
        var firstMs = 0.0, sightings = 0, aliveMs = 0.0
        var cpuNs: UInt64 = 0
        var gone = false
    }

    /// Scan synchronously.
    public static func scan(seconds: Double, intervalMs: Int) -> ShortLivedScan {
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let t0 = DispatchTime.now().uptimeNanoseconds
        var buf = [pid_t](repeating: 0, count: 8192)
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        func list() -> Set<pid_t> {
            let n = Int(proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
            return Set(buf[0..<max(0, min(n, buf.count))])
        }
        func path(_ pid: pid_t) -> String? {
            proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : nil
        }

        let baseline = list()
        var tracked: [pid_t: Track] = [:]
        var finished: [Track] = []
        var ppidOf: [pid_t: Int32] = [:]
        // Bounded by time, not by a number of looks: on a starved machine each look takes longer.
        var lastNs = t0
        var elapsedMs = 0.0
        while elapsedMs < seconds * 1000 {
            usleep(useconds_t(intervalMs * 1000))
            let now = list()
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let gapMs = Double(nowNs - lastNs) / 1e6
            lastNs = nowNs; elapsedMs = Double(nowNs - t0) / 1e6
            for pid in now where !baseline.contains(pid) {
                var t = tracked[pid] ?? Track()
                if t.sightings == 0 {
                    t.firstMs = elapsedMs
                    var basic = pmon_basic_t()
                    if pmon_proc_basic(pid, &basic) == 0 {
                        t.ppid = basic.ppid
                        ppidOf[pid] = basic.ppid
                        t.name = withUnsafeBytes(of: &basic.comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                    }
                }
                // A new process is first seen as a copy of its parent; the image it executes shows a moment later.
                if t.sightings < 4, let p = path(pid) { t.path = p; t.name = (p as NSString).lastPathComponent }
                var ri = rusage_info_v2()
                let ok = withUnsafeMutablePointer(to: &ri) { p in
                    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
                }
                if ok == 0 { t.cpuNs = MachTime.ns(ri.ri_user_time &+ ri.ri_system_time) }
                t.sightings += 1; t.aliveMs += gapMs
                tracked[pid] = t
            }
            for (pid, t) in tracked where !now.contains(pid) {
                var t = t; t.gone = true
                finished.append(t)
                tracked[pid] = nil
            }
        }
        let births = finished.count + tracked.count
        // Still running at the end: part of the churn only if it appeared in the last second.
        let shortLived = finished + tracked.values.filter { $0.firstMs > elapsedMs - 1000 }

        // Attribute each process to its nearest ancestor that predates the scan.
        func anchor(_ ppid: Int32) -> Int32 {
            var p = ppid, hops = 0
            while !baseline.contains(p), let up = ppidOf[p], hops < 16 { p = up; hops += 1 }
            return p
        }
        struct Key: Hashable { var path: String; var parent: Int32 }
        var groups: [Key: ShortLivedGroup] = [:]
        var parentNames: [Int32: String] = [:]
        for t in shortLived where !(t.path.isEmpty && t.name.isEmpty) {      // gone before it could be identified
            let parent = anchor(t.ppid)
            let key = Key(path: t.path.isEmpty ? t.name : t.path, parent: parent)
            if parentNames[parent] == nil { parentNames[parent] = path(parent).map { ($0 as NSString).lastPathComponent } ?? "" }
            var g = groups[key] ?? ShortLivedGroup(path: t.path, name: t.name, parentPid: parent, parentName: parentNames[parent]!,
                                                   count: 0, sightings: 0, aliveMs: 0, cpuMs: 0)
            g.count += 1; g.sightings += t.sightings; g.aliveMs += Int64(t.aliveMs.rounded()); g.cpuMs += Int64(t.cpuNs / 1_000_000)
            groups[key] = g
        }
        let top = groups.values.sorted { ($0.sightings, $0.count, $1.path) > ($1.sightings, $1.count, $0.path) }.prefix(20)
        return ShortLivedScan(durationMs: Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000), intervalMs: intervalMs,
                              births: births, costCpuMs: Int((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1_000_000),
                              groups: Array(top))
    }
}
