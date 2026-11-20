import Foundation
import Darwin
import CPmonSys

/// A supervised, long-lived `top` child: the unprivileged source of metrics for processes
/// owned by other users (`top` is setuid, so it can read what we cannot).
///
/// The child is always in a known state: it is restarted with back-off if it dies, declared
/// failed if its output stops matching the expected format (the caller then falls back to
/// `ps`), retried later, and never left behind when the daemon goes away.
public final class TopStream {
    public enum State: Equatable, Sendable {
        case stopped, running, paused
        /// Output is unusable or the child keeps dying; a retry is scheduled.
        case failed(String)
    }

    public static let defaultStats = ["pid", "time", "mem", "cmprs", "pageins", "csw", "threads", "idlew", "instrs", "cycles", "faults"]

    private let command: [String]
    private let stats: [String]
    private let pidFile: String?
    private let queue = DispatchQueue(label: "pmon.topstream", qos: .utility)
    /// Quiet time after which a burst of output is taken to be one complete sample.
    public var settleSeconds = 0.3
    public var restartBaseSeconds = 2.0
    public var maxRestarts = 5
    public var retryAfterFailureSeconds = 3600.0
    public var badSamplesToFail = 3

    private var process: Process?
    private var parser: TopParser
    private var settle: DispatchWorkItem?
    private var burstStartNs: UInt64?
    private var latest: TopSample?
    private var notes: [CollectorNote] = []
    private var _state = State.stopped
    private var wantRunning = false
    private var restarts = 0, badSamples = 0
    private var announcedHealthy = false
    private var generation = 0

    public init(intervalSeconds: Int, stats: [String] = TopStream.defaultStats, pidFile: String? = nil, command: [String]? = nil) {
        self.stats = stats
        self.pidFile = pidFile
        self.command = command ?? ["/usr/bin/top", "-l", "0", "-s", String(max(intervalSeconds, 1)), "-stats", stats.joined(separator: ",")]
        parser = TopParser(stats: stats)
    }

    public var state: State { queue.sync { _state } }

    /// Pid of the running child, if any.
    public var childPid: Int32? { queue.sync { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } } }

    /// Whether the caller should use `ps` for foreign processes instead.
    public var needsFallback: Bool { if case .failed = state { return true } else { return false } }

    public func start() {
        queue.sync {
            guard !wantRunning else { return }
            wantRunning = true
            reapOrphan()
            spawn()
        }
    }

    public func stop() {
        queue.sync {
            wantRunning = false
            generation += 1
            killChild()
            _state = .stopped
        }
    }

    /// Suspend the child (no CPU at all) while nobody needs its data.
    public func pause() {
        queue.sync {
            guard _state == .running, let p = process, p.isRunning else { return }
            kill(p.processIdentifier, SIGSTOP)
            _state = .paused
        }
    }

    public func resume() {
        queue.sync {
            guard _state == .paused, let p = process else { return }
            kill(p.processIdentifier, SIGCONT)
            _state = .running
        }
    }

    /// The newest complete sample not yet taken, if any.
    public func take() -> TopSample? {
        queue.sync { defer { latest = nil }; return latest }
    }

    /// Events to record (source switched to `ps`, or back to `top`).
    public func takeNotes() -> [CollectorNote] {
        queue.sync { defer { notes.removeAll() }; return notes }
    }

    // MARK: - Child management (all on `queue`)

    private func spawn() {
        guard wantRunning else { return }
        generation += 1
        let gen = generation
        parser = TopParser(stats: stats)
        burstStartNs = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let now = MachTime.ns(mach_absolute_time())
            self?.queue.async { self?.received(data, at: now, generation: gen) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.childExited(generation: gen) }
        }
        do {
            try p.run()
            process = p
            _state = .running
            if let pidFile { try? "\(p.processIdentifier)\n".write(toFile: pidFile, atomically: true, encoding: .utf8) }
        } catch {
            fail("cannot start \(command[0]): \(error.localizedDescription)")
        }
    }

    private func killChild() {
        settle?.cancel(); settle = nil
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning {
            kill(p.processIdentifier, SIGCONT)      // a stopped child would ignore SIGTERM until continued
            p.terminate()
        }
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
    }

    /// A previous daemon that was killed while its child was suspended leaves a stopped `top`
    /// behind (a running one dies by itself on its next write). Clean that up.
    private func reapOrphan() {
        guard let pidFile, let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        var basic = pmon_basic_t()
        if pmon_proc_basic(pid, &basic) == 0, basic.ppid == 1,
           withUnsafeBytes(of: &basic.comm, { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }) == "top" {
            kill(pid, SIGCONT); kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    private func received(_ data: Data, at now: UInt64, generation gen: Int) {
        guard gen == generation, let text = String(data: data, encoding: .utf8) else { return }
        if burstStartNs == nil { burstStartNs = now }
        parser.feed(text)
        drain()                                  // a new sample header completes the previous sample
        settle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.parser.flush()
            self.drain()
            self.burstStartNs = nil
        }
        settle = item
        queue.asyncAfter(deadline: .now() + settleSeconds, execute: item)
    }

    private func drain() {
        for result in parser.take() {
            switch result {
            case .success(let rows):
                badSamples = 0; restarts = 0
                latest = TopSample(monoNs: burstStartNs ?? MachTime.ns(mach_absolute_time()), rows: rows)
                if !announcedHealthy {
                    announcedHealthy = true
                    notes.append(CollectorNote(kind: "foreign_source", value: 1, detail: #"{"mode":"top"}"#))
                }
            case .failure(.headerMismatch(let line)):
                fail("top header changed: \(line.prefix(120))")
                return
            case .failure(.badRow(let line)):
                badSamples += 1
                if badSamples >= badSamplesToFail { fail("top rows unparseable: \(line.prefix(120))"); return }
            }
        }
    }

    private func childExited(generation gen: Int) {
        guard gen == generation, wantRunning else { return }
        process = nil
        restarts += 1
        if restarts > maxRestarts { fail("top exited \(restarts) times in a row"); return }
        let delay = restartBaseSeconds * Double(1 << min(restarts - 1, 5))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.spawn()
        }
    }

    private func fail(_ reason: String) {
        generation += 1
        let gen = generation
        killChild()
        _state = .failed(reason)
        announcedHealthy = false
        restarts = 0; badSamples = 0
        let escaped = reason.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        notes.append(CollectorNote(kind: "foreign_source", value: 2, detail: #"{"mode":"ps","reason":"\#(escaped)"}"#))
        queue.asyncAfter(deadline: .now() + retryAfterFailureSeconds) { [weak self] in
            guard let self, gen == self.generation, self.wantRunning else { return }
            self.spawn()
        }
    }
}
