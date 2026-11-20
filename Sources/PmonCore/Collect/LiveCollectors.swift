import Foundation
import Darwin

/// Reads the live machine: runs the collectors that are due on a tick.
public final class LiveCollectors {
    private let system = SystemCollector()
    private let slow = SlowCollector()
    private let processes = NativeProcessCollector()
    private let ps = PsCollector()
    private let session: SessionCollector?
    private let topStream: TopStream?
    private let diagReports: DiagReportWatcher?
    private let selfPid = getpid()
    private var announcedPsOnly = false
    private var pendingNotes: [CollectorNote] = []
    private let gpu = GpuCollector()
    private let collectors: CollectorConfig
    private let captures: CaptureManager?
    private let scanner: ShortLivedScanner?
    private let diskProbe: DiskProbe?

    /// Ask for `ps` on every process sweep, for finer CPU resolution of foreign processes
    /// than the top stream gives. Used while a slowdown is being investigated.
    public var psBurst = false

    /// - Parameters:
    ///   - topStream: nil means foreign processes are covered by `ps` alone.
    ///   - session: nil disables session signals (frontmost app, user presence).
    ///   - diagReports: nil disables ingestion of system diagnostic reports.
    ///   - collectors: modes of the optional collectors.
    ///   - captures, scanner: sources of finished captures and short-lived process scans to put on the record.
    ///   - diskProbe: where the latency probe keeps its scratch file.
    public init(topStream: TopStream? = nil, session: SessionCollector? = nil, diagReports: DiagReportWatcher? = nil,
                collectors: CollectorConfig = CollectorConfig(), captures: CaptureManager? = nil, scanner: ShortLivedScanner? = nil,
                diskProbe: DiskProbe? = nil) {
        self.topStream = topStream
        self.session = session
        self.diagReports = diagReports
        self.collectors = collectors
        self.captures = captures
        self.scanner = scanner
        self.diskProbe = diskProbe
    }

    private func on(_ mode: CollectorMode) -> Bool { mode == .always || (mode == .triggered && psBurst) }

    /// Queue an event to be recorded with the next tick (for example a cadence change).
    public func addNote(_ note: CollectorNote) { pendingNotes.append(note) }

    public func collect(for tick: Tick) -> TickRecord {
        var rec = TickRecord(tick: tick)
        var notes = pendingNotes
        pendingNotes.removeAll()
        if tick.tiers.contains(.system) {
            rec.system = system.collect()
            rec.session = session?.collect()
            if on(collectors.gpu) { rec.system?.gpuUtilPct = gpu.utilisation() }
        }
        if tick.tiers.contains(.process) {
            let sweep = processes.collect()
            rec.procs = sweep; rec.selfPid = selfPid
            let foreignPids = Set(sweep.foreign.map(\.pid))
            if let sample = topStream?.take() {
                rec.top = TopSample(monoNs: sample.monoNs, rows: sample.rows.filter { foreignPids.contains($0.pid) })
            }
            if psBurst || topStream == nil || topStream!.needsFallback {
                rec.ps = ps.collect(pids: sweep.foreign.map(\.pid))
            }
            notes += topStream?.takeNotes() ?? []
            if topStream == nil, !announcedPsOnly {
                announcedPsOnly = true
                notes.append(CollectorNote(kind: "foreign_source", value: 2, detail: #"{"mode":"ps","reason":"top stream disabled in configuration"}"#))
            }
            notes += diagReports?.takeNotes() ?? []
            if on(collectors.gpuProcess) { rec.gpu = gpu.clients() }
        }
        if tick.tiers.contains(.slow) {
            rec.slow = slow.collect()
            if collectors.diskProbe != .off { rec.slow?.diskProbeUs = diskProbe?.measure() }
        }
        if let done = captures?.take(), !done.isEmpty { rec.captures = done }
        rec.shortLived = scanner?.take()
        if !notes.isEmpty { rec.notes = notes }
        return rec
    }
}
