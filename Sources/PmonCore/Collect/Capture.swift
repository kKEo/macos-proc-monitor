import Foundation
import Darwin

/// How an optional collector runs.
public enum CollectorMode: String, Codable, Sendable, CaseIterable {
    /// Never.
    case off
    /// Only around a slowdown, within the shared budget.
    case triggered
    /// Whenever it applies, outside the budget.
    case always
}

/// Switches and limits of the optional collectors. Everything heavier than a counter read is off
/// by default; only the GPU device reading (one registry property per sample) is on.
public struct CollectorConfig: Codable, Equatable, Sendable {
    /// Call stacks of the process using most CPU when a slowdown starts (`sample`).
    public var stack = CollectorMode.off
    /// Threads, open files and (if `args` is on) arguments of the five busiest processes.
    public var threads = CollectorMode.off
    /// Memory composition of the largest process in a memory slowdown (`footprint`).
    public var footprint = CollectorMode.off
    /// Fast scan for short-lived processes when CPU cannot be attributed.
    public var shortLived = CollectorMode.off
    /// GPU device utilisation on every sample. `triggered` reads it only around a slowdown.
    public var gpu = CollectorMode.always
    /// GPU time per process. `triggered` reads it only around a slowdown.
    public var gpuProcess = CollectorMode.off
    /// Network bytes per process during a slowdown (`nettop`; costs over a second of CPU per run).
    public var network = CollectorMode.off
    /// Time one uncached read from the system volume, once a minute.
    public var diskProbe = CollectorMode.off
    /// Include command-line arguments in the `threads` capture. They can contain secrets.
    public var args = CollectorMode.off

    /// Budget shared by all triggered captures.
    public var maxCaptureSetsPerHour = 6
    public var minBatteryPct = 20
    /// Capture files are deleted when the directory grows past this.
    public var captureCapMB = 500
    /// Share of one core that must go unattributed before a short-lived process scan starts.
    public var shortLivedCpuShare = 0.25

    public static let names = ["stack", "threads", "footprint", "shortLived", "gpu", "gpuProcess", "network", "diskProbe", "args"]

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func mode(_ k: CodingKeys, _ d: CollectorMode) throws -> CollectorMode { try c.decodeIfPresent(CollectorMode.self, forKey: k) ?? d }
        stack = try mode(.stack, stack); threads = try mode(.threads, threads); footprint = try mode(.footprint, footprint)
        shortLived = try mode(.shortLived, shortLived); gpu = try mode(.gpu, gpu); gpuProcess = try mode(.gpuProcess, gpuProcess)
        network = try mode(.network, network); diskProbe = try mode(.diskProbe, diskProbe); args = try mode(.args, args)
        maxCaptureSetsPerHour = try c.decodeIfPresent(Int.self, forKey: .maxCaptureSetsPerHour) ?? maxCaptureSetsPerHour
        minBatteryPct = try c.decodeIfPresent(Int.self, forKey: .minBatteryPct) ?? minBatteryPct
        captureCapMB = try c.decodeIfPresent(Int.self, forKey: .captureCapMB) ?? captureCapMB
        shortLivedCpuShare = try c.decodeIfPresent(Double.self, forKey: .shortLivedCpuShare) ?? shortLivedCpuShare
    }

    public subscript(name: String) -> CollectorMode? {
        get {
            switch name {
            case "stack": return stack
            case "threads": return threads
            case "footprint": return footprint
            case "shortLived": return shortLived
            case "gpu": return gpu
            case "gpuProcess": return gpuProcess
            case "network": return network
            case "diskProbe": return diskProbe
            case "args": return args
            default: return nil
            }
        }
        set {
            guard let v = newValue else { return }
            switch name {
            case "stack": stack = v
            case "threads": threads = v
            case "footprint": footprint = v
            case "shortLived": shortLived = v
            case "gpu": gpu = v
            case "gpuProcess": gpuProcess = v
            case "network": network = v
            case "diskProbe": diskProbe = v
            case "args": args = v
            default: break
            }
        }
    }
}

/// The shared limit on triggered captures: one set per episode, a cap per hour, and none on a
/// nearly empty battery.
public struct CaptureBudget: Sendable {
    public var maxPerHour: Int
    public var minBatteryPct: Int
    private var granted: [Int64] = []          // times (ms) of the sets granted in the last hour
    private var episodes: Set<Int64> = []

    public init(maxPerHour: Int = 6, minBatteryPct: Int = 20) {
        self.maxPerHour = maxPerHour; self.minBatteryPct = minBatteryPct
    }

    /// Whether this episode has already been considered (granted or not): each gets one chance.
    public func seen(_ episodeId: Int64) -> Bool { episodes.contains(episodeId) }

    public mutating func allow(episodeId: Int64, nowMs: Int64, onBattery: Bool, batteryPct: Int?) -> Bool {
        guard !episodes.contains(episodeId) else { return false }
        episodes.insert(episodeId)
        if episodes.count > 1000 { episodes = [episodeId] }
        granted.removeAll { nowMs - $0 >= 3_600_000 }
        if onBattery, let pct = batteryPct, pct < minBatteryPct { return false }
        guard granted.count < maxPerHour else { return false }
        granted.append(nowMs)
        return true
    }
}

/// A process to look at more closely.
public struct CaptureTarget: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    /// CPU used over the last process interval, as a share of one core.
    public var cpuShare: Double
    public var footprint: Int64
    public init(pid: Int32, name: String, cpuShare: Double, footprint: Int64) {
        self.pid = pid; self.name = name; self.cpuShare = cpuShare; self.footprint = footprint
    }
}

/// What the pipeline asks for when an episode opens.
public struct CaptureRequest: Equatable, Sendable {
    public var episodeId: Int64
    public var ts: Int64
    /// The sub-score that was highest when the episode opened.
    public var dominant: String
    /// Readable processes by CPU, busiest first, and by memory, largest first.
    public var cpuTop: [CaptureTarget]
    public var memTop: [CaptureTarget]
    public init(episodeId: Int64, ts: Int64, dominant: String, cpuTop: [CaptureTarget], memTop: [CaptureTarget]) {
        self.episodeId = episodeId; self.ts = ts; self.dominant = dominant; self.cpuTop = cpuTop; self.memTop = memTop
    }
}

/// Runs the heavy, optional captures on its own queue and leaves compressed files in a directory
/// next to the database. Results are handed back to the collectors, which put them on a tick record.
public final class CaptureManager {
    public let dir: String
    private let config: CollectorConfig
    private var budget: CaptureBudget
    private let queue = DispatchQueue(label: "pmon.capture", qos: .utility)
    private let lock = NSLock()
    private var results: [CaptureResult] = []

    public init(dir: String, config: CollectorConfig) {
        self.dir = dir; self.config = config
        budget = CaptureBudget(maxPerHour: config.maxCaptureSetsPerHour, minBatteryPct: config.minBatteryPct)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// True when at least one capture kind is switched on.
    public var enabled: Bool {
        [config.stack, config.threads, config.footprint, config.network].contains { $0 != .off }
    }

    public func take() -> [CaptureResult] {
        lock.lock(); defer { lock.unlock() }
        defer { results.removeAll() }
        return results
    }

    private func add(_ r: CaptureResult?) {
        guard let r else { return }
        lock.lock(); results.append(r); lock.unlock()
    }

    /// Decide what to capture for a newly opened episode and start it in the background.
    public func submit(_ req: CaptureRequest, onBattery: Bool, batteryPct: Int?) {
        guard enabled, !budget.seen(req.episodeId) else { return }
        let within = budget.allow(episodeId: req.episodeId, nowMs: req.ts, onBattery: onBattery, batteryPct: batteryPct)
        func on(_ m: CollectorMode) -> Bool { m == .always || (m == .triggered && within) }
        let stamp = "\(req.ts)-e\(req.episodeId)"
        queue.async { [self] in
            // A stack is only worth taking from a process that is actually busy.
            if on(config.stack), let t = req.cpuTop.first, t.cpuShare >= 0.2 {
                add(captureStack(t, episode: req.episodeId, stamp: stamp))
            }
            if on(config.threads), !req.cpuTop.isEmpty {
                add(captureProcs(Array(req.cpuTop.prefix(5)), episode: req.episodeId, stamp: stamp))
            }
            if on(config.footprint), req.dominant == "memory", let t = req.memTop.first {
                add(captureFootprint(t, episode: req.episodeId, stamp: stamp))
            }
            if on(config.network) { add(captureNetwork(episode: req.episodeId, stamp: stamp)) }
        }
    }

    /// Delete capture files that are too old, then the oldest ones until the directory fits its cap.
    public func expire(maxAgeDays: Double) {
        queue.async { [self] in
            let fm = FileManager.default
            var files: [(path: String, date: Date, size: Int)] = []
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".gz") {
                let path = dir + "/" + name
                guard let a = try? fm.attributesOfItem(atPath: path), let d = a[.modificationDate] as? Date, let s = a[.size] as? Int else { continue }
                files.append((path, d, s))
            }
            files.sort { $0.date < $1.date }
            var total = files.reduce(0) { $0 + $1.size }
            let cutoff = Date().addingTimeInterval(-maxAgeDays * 86_400)
            for f in files where f.date < cutoff || total > config.captureCapMB << 20 {
                try? fm.removeItem(atPath: f.path)
                total -= f.size
            }
        }
    }

    // MARK: - Capture kinds

    private func finish(kind: String, pid: Int32?, episode: Int64, textPath: String, summary: String, started: UInt64) -> CaptureResult? {
        _ = Self.run("/usr/bin/gzip", ["-f", textPath])
        let path = textPath + ".gz"
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return nil }
        chmod(path, 0o600)
        return CaptureResult(episodeId: episode, kind: kind, pid: pid, path: path, bytes: size, summary: summary,
                             costMs: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
    }

    func captureStack(_ t: CaptureTarget, episode: Int64, stamp: String) -> CaptureResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let path = "\(dir)/\(stamp)-stack-\(t.pid).txt"
        guard Self.run("/usr/bin/sample", ["\(t.pid)", "3", "-mayDie", "-file", path]).status == 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let frames = CaptureSummary.hotFrames(sampleOutput: text)
        let summary = "\(t.name): " + (frames.isEmpty ? "no frames on a core" : frames.joined(separator: "; "))
        return finish(kind: "stack", pid: t.pid, episode: episode, textPath: path, summary: summary, started: t0)
    }

    func captureFootprint(_ t: CaptureTarget, episode: Int64, stamp: String) -> CaptureResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let path = "\(dir)/\(stamp)-footprint-\(t.pid).txt"
        let r = Self.run("/usr/bin/footprint", ["\(t.pid)"])
        guard r.status == 0, (try? r.output.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        let summary = "\(t.name): " + CaptureSummary.footprintCategories(r.output).joined(separator: ", ")
        return finish(kind: "footprint", pid: t.pid, episode: episode, textPath: path, summary: summary, started: t0)
    }

    func captureProcs(_ targets: [CaptureTarget], episode: Int64, stamp: String) -> CaptureResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let before = targets.map { ProcessProbe.threads(pid: $0.pid) }
        usleep(1_000_000)
        var procs: [[String: Any]] = []
        var headline = ""
        for (i, t) in targets.enumerated() {
            let after = ProcessProbe.threads(pid: t.pid)
            let prev = Dictionary(before[i].map { ($0.id, $0.cpuNs) }, uniquingKeysWith: { a, _ in a })
            let busy = after.map { (name: $0.name, ms: Double($0.cpuNs &- (prev[$0.id] ?? $0.cpuNs)) / 1e6) }
                .filter { $0.ms >= 1 }.sorted { $0.ms > $1.ms }
            var p: [String: Any] = ["pid": Int(t.pid), "name": t.name, "cpu_share": (t.cpuShare * 1000).rounded() / 1000,
                                    "footprint": t.footprint, "threads": after.count,
                                    "busy_threads": busy.prefix(12).map { ["name": $0.name, "cpu_ms": ($0.ms * 10).rounded() / 10] }]
            if let fds = ProcessProbe.openFiles(pid: t.pid) { p["open_files"] = fds }
            if config.args != .off, let args = ProcessProbe.arguments(pid: t.pid) { p["args"] = args }
            procs.append(p)
            if i == 0 {
                let top = busy.prefix(3).map { "\($0.name.isEmpty ? "unnamed" : $0.name) \(Int(($0.ms / 10).rounded())) %" }
                headline = "\(t.name): \(after.count) threads" + (top.isEmpty ? "" : ", busiest " + top.joined(separator: ", "))
                    + ((p["open_files"] as? Int).map { ", \($0) open files" } ?? "")
            }
        }
        let path = "\(dir)/\(stamp)-procs.json"
        let doc: [String: Any] = ["episode": episode, "interval_ms": 1000, "processes": procs]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
              FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return finish(kind: "procs", pid: targets.first?.pid, episode: episode, textPath: path, summary: headline, started: t0)
    }

    func captureNetwork(episode: Int64, stamp: String) -> CaptureResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = Self.run("/usr/bin/nettop", ["-P", "-d", "-L", "2", "-s", "2", "-x", "-J", "bytes_in,bytes_out"])
        guard r.status == 0 else { return nil }
        let path = "\(dir)/\(stamp)-network.csv"
        guard (try? r.output.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        let top = CaptureSummary.networkTalkers(r.output, seconds: 2)
        return finish(kind: "network", pid: nil, episode: episode, textPath: path,
                      summary: top.isEmpty ? "no network traffic" : top.joined(separator: ", "), started: t0)
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Turns the tools' text output into one-line summaries.
public enum CaptureSummary {
    /// Frames that mean "waiting", not "working".
    private static let idle: Set<String> = [
        "__ulock_wait", "__ulock_wait2", "mach_msg2_trap", "mach_msg_trap", "kevent", "kevent64", "kevent_id", "kevent_qos",
        "__psynch_cvwait", "__psynch_mutexwait", "__workq_kernreturn", "__semwait_signal", "semaphore_wait_trap",
        "semaphore_timedwait_trap", "__select", "poll", "__sigsuspend", "__sigwait", "read", "__read_nocancel", "__accept",
        "__recvfrom", "start_wqthread", "__wait4", "__psynch_rw_rdlock", "__psynch_rw_wrlock", "__bsdthread_ctl", "__pselect",
    ]

    /// The functions most often on top of the stack in `sample` output, with their share of the
    /// samples that were on a core.
    public static func hotFrames(sampleOutput text: String, limit: Int = 4) -> [String] {
        var frames: [(name: String, count: Int)] = []
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Sort by top of stack") { inSection = true; continue }
            guard inSection else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            guard let gap = trimmed.lastIndex(of: " "), let count = Int(trimmed[trimmed.index(after: gap)...]) else { continue }
            var name = trimmed[..<gap].trimmingCharacters(in: .whitespaces)
            var library = ""
            if let r = name.range(of: "  (in ", options: .backwards) {
                library = String(name[r.upperBound...].dropLast())
                name = String(name[..<r.lowerBound])
            }
            if idle.contains(name) { continue }
            frames.append((library.isEmpty ? name : "\(name) (\(library))", count))
        }
        let total = frames.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        return frames.prefix(limit).map { "\($0.name) \($0.count * 100 / total) %" }
    }

    /// The largest dirty-memory categories in `footprint` output.
    public static func footprintCategories(_ text: String, limit: Int = 4) -> [String] {
        var out: [String] = []
        var inTable = false
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.first == "Dirty" { inTable = true; continue }
            guard inTable, f.count >= 8, f[0] != "---" else { continue }
            // Columns: dirty value+unit, clean value+unit, reclaimable value+unit, regions, category...
            let category = f[7...].joined(separator: " ")
            if category == "TOTAL" { break }
            if f[0] == "0" { continue }
            out.append("\(category) \(f[0]) \(f[1])")
            if out.count == limit { break }
        }
        return out
    }

    /// Processes by bytes moved, from the last block of `nettop -P -d -x -J bytes_in,bytes_out` output.
    public static func networkTalkers(_ text: String, seconds: Double, limit: Int = 4) -> [String] {
        var block: [(name: String, bytes: Int)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            if f.count >= 3, f[1] == "bytes_in" { block.removeAll(); continue }      // header: a new block starts
            guard f.count >= 3, let i = Int(f[1]), let o = Int(f[2]), i + o > 0 else { continue }
            var name = String(f[0])
            if let dot = name.lastIndex(of: "."), Int(name[name.index(after: dot)...]) != nil { name = String(name[..<dot]) }
            block.append((name, i + o))
        }
        return block.sorted { $0.bytes > $1.bytes }.prefix(limit).map {
            "\($0.name) \(String(format: "%.0f", Double($0.bytes) / seconds / 1024)) KB/s"
        }
    }
}

/// Details of one process that are cheap to read for the user's own processes but not worth
/// collecting on every sweep.
public enum ProcessProbe {
    public struct ThreadTime: Equatable, Sendable {
        public var id: UInt64
        public var name: String
        public var cpuNs: UInt64
    }

    public static func threads(pid: Int32) -> [ThreadTime] {
        var ids = [UInt64](repeating: 0, count: 2048)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * 8))
        guard bytes > 0 else { return [] }
        var out: [ThreadTime] = []
        for id in ids.prefix(Int(bytes) / 8) {
            var info = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: &info.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            out.append(ThreadTime(id: id, name: name, cpuNs: info.pth_user_time &+ info.pth_system_time))
        }
        return out
    }

    /// Number of open file descriptors (files, sockets, pipes).
    public static func openFiles(pid: Int32) -> Int? {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return nil }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(need), alignment: 8)
        defer { buf.deallocate() }
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, need)
        return got > 0 ? Int(got) / MemoryLayout<proc_fdinfo>.size : nil
    }

    /// Command-line arguments, joined and truncated.
    public static func arguments(pid: Int32, limit: Int = 400) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }         // executable path
        while i < size, buf[i] == 0 { i += 1 }         // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        let joined = args.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }
}
