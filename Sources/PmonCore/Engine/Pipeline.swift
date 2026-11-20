import Foundation
import Darwin

/// Turns raw tick records into stored rows: deltas, then one transaction per tick.
///
/// The pipeline has no access to collectors or clocks. Everything it knows arrives in a
/// `TickRecord`, so a live run and a replay of its recording produce identical rows.
public final class Pipeline {
    private let db: Database
    private let host: HostInfo
    private let writer: Writer
    private let procStore: ProcStore
    private var systemDeltas = SystemDeltaEngine()
    private var procDeltas = ProcDeltaEngine()
    private var limiter = SelfLimiter()
    private var topDeltas = TopDeltaEngine()
    private var psDeltas = PsDeltaEngine()
    /// Cumulative system busy CPU and readable-process CPU over time, to line them up with top samples.
    private var busySeries = CumulativeSeries()
    private var ownSeries = CumulativeSeries()
    private var lastTopMonoNs: UInt64?
    private var diskBytesSinceSweep: Int64 = 0
    private var lastSlow: SlowReading?

    /// Monotonic time of the previous process sweep, and system busy CPU accumulated since then.
    private var lastSweepMonoNs: UInt64?
    private var busyMsSinceSweep: Int64 = 0
    private var busyCoversSweep = false
    private var sweeps = 0

    /// Counts for health reporting.
    public private(set) var ticksIngested = 0
    public private(set) var samplesWritten = 0
    /// Current self-limiter level (0 = normal). The driver stretches the process interval by `backoffMultiplier`.
    public var backoffLevel: Int { limiter.level }
    public var backoffMultiplier: Double { limiter.intervalMultiplier }

    public init(db: Database, host: HostInfo) throws {
        self.db = db
        self.host = host
        try Migrations.migrate(db)
        let bootId: Int64 = try db.transaction {
            try Dimensions.upsertHost(db, host)
            return try Dimensions.bootId(db, host)
        }
        writer = Writer(db: db, bootId: bootId, pageSize: Int64(host.pageSize))
        procStore = try ProcStore(db: db, bootId: bootId)
    }

    public func ingest(_ rec: TickRecord) throws {
        ticksIngested += 1
        if let slow = rec.slow { lastSlow = slow }
        try db.transaction { try ingestInTransaction(rec) }
    }

    private func ingestInTransaction(_ rec: TickRecord) throws {
        let tick = rec.tick

        for note in rec.notes ?? [] {
            try writer.insertEvent(ts: tick.wallMs, kind: note.kind, value: note.value, detail: note.detail)
        }

        // Dimension rows first: they are valid whether or not this tick yields a sample.
        if let sweep = rec.procs {
            try procStore.apply(identities: sweep.identities, ts: tick.wallMs)
            let present = Set(sweep.procs.map(\.uid)).union(sweep.foreign.map(\.uid))
            try procStore.markExited(present: present, ts: tick.wallMs)
            sweeps += 1
            if sweeps % 30 == 0 { try procStore.touchLive(ts: tick.wallMs) }
        }

        // An interval that spans sleep is not a real interval: drop every baseline so the next
        // tick starts fresh, and leave a flagged marker row so the gap is explained.
        if tick.afterWake {
            systemDeltas.reset()
            procDeltas.reset()
            topDeltas.reset(); psDeltas.reset()
            busySeries.reset(); ownSeries.reset(); lastTopMonoNs = nil
            diskBytesSinceSweep = 0
            if let sweep = rec.procs {            // re-baseline the foreign sources too
                let uidByPid = Dictionary(sweep.foreign.map { ($0.pid, $0.uid) }, uniquingKeysWith: { a, _ in a })
                if let top = rec.top { _ = topDeltas.deltas(top, uidByPid: uidByPid); lastTopMonoNs = top.monoNs }
                if let ps = rec.ps { _ = psDeltas.deltas(ps, uidByPid: uidByPid) }
            }
            if let sys = rec.system { _ = systemDeltas.delta(sys, coreIsPerformance: host.coreIsPerformance) }
            if let sweep = rec.procs { _ = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs) }
            lastSweepMonoNs = rec.procs == nil ? nil : tick.monoNs
            busyMsSinceSweep = 0; busyCoversSweep = rec.procs != nil
            _ = try writer.insertSample(tick: tick, tier: 1, flags: .afterWake)
            samplesWritten += 1
            return
        }

        let sysDelta = rec.system.flatMap { systemDeltas.delta($0, coreIsPerformance: host.coreIsPerformance) }
        if let d = sysDelta {
            busyMsSinceSweep += d.cpuUserMs + d.cpuSysMs
            diskBytesSinceSweep += d.diskRead + d.diskWrite
            busySeries.add(Double(d.cpuUserMs + d.cpuSysMs), at: tick.monoNs)
        } else {
            busyCoversSweep = false
            if rec.system != nil { busySeries.reset(); busySeries.anchor(at: tick.monoNs) }
        }

        // Process deltas, and the totals that go onto the system sample.
        var deltas: [ProcDelta] = []
        var totals: ProcTotals?
        var procDtMs: Int64?
        if let sweep = rec.procs {
            deltas = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs).deltas
            if let last = lastSweepMonoNs {
                procDtMs = Int64((tick.monoNs - last) / 1_000_000)
                let cpuMs = Int64(deltas.reduce(UInt64(0)) { $0 + $1.cpuNs } / 1_000_000)
                let ownDisk = deltas.reduce(Int64(0)) { $0 + $1.dDiskRead + $1.dDiskWrite }
                ownSeries.add(Double(cpuMs), at: tick.monoNs)
                totals = ProcTotals(procCount: sweep.procs.count + sweep.foreign.count,
                                    threadCount: sweep.procs.reduce(0) { $0 + Int($1.threads) },
                                    waitMs: deltas.reduce(0) { $0 + $1.waitMs },
                                    unattributedCpuMs: busyCoversSweep ? max(0, busyMsSinceSweep - cpuMs) : nil,
                                    unattributedDiskBytes: busyCoversSweep ? max(0, diskBytesSinceSweep - ownDisk) : nil)
                try observeSelfCost(sweep: sweep, deltas: deltas, selfPid: rec.selfPid, procDtMs: procDtMs!, ts: tick.wallMs)
            } else {
                ownSeries.anchor(at: tick.monoNs)
            }
            lastSweepMonoNs = tick.monoNs
        }

        // Processes of other users: top stream and/or ps, merged into one set of rows.
        var foreign: [ForeignDelta] = []
        var foreignDtMs: Int64?
        var flags: SampleFlags = backoffLevel > 0 ? .degraded : []
        if let sweep = rec.procs {
            let uidByPid = Dictionary(sweep.foreign.map { ($0.pid, $0.uid) }, uniquingKeysWith: { a, _ in a })
            var rows: [UInt64: ForeignDelta] = [:]

            if let top = rec.top {
                if let r = topDeltas.deltas(top, uidByPid: uidByPid) {
                    rows = r.rows; foreignDtMs = r.dtMs; flags.insert(.foreignFresh)
                }
            }
            // ps supplies CPU at the process cadence. While it is active it is the only CPU source,
            // so CPU already reported by ps is not counted again when a top sample arrives.
            let ps = rec.ps.flatMap { psDeltas.deltas($0, uidByPid: uidByPid) }
            if rec.ps == nil { psDeltas.reset() }
            if let ps {
                flags.insert(.foreignCpuFromPs)
                for uid in rows.keys { rows[uid]!.cpuUserMs = nil; rows[uid]!.cpuSysMs = nil; rows[uid]!.cpuNs = 0 }
                for (uid, cpu) in ps {
                    var d = rows[uid] ?? ForeignDelta()
                    if rows[uid] == nil { d.uid = uid; d.fidelity = 2 }
                    d.cpuUserMs = cpu.userMs; d.cpuSysMs = cpu.sysMs; d.cpuNs = cpu.ns; d.cpuFromPs = true
                    rows[uid] = d
                }
            }
            foreign = Array(rows.values)

            // Residual: system busy CPU minus readable processes minus measured foreign processes.
            let foreignCpuMs = Double(foreign.reduce(UInt64(0)) { $0 + $1.cpuNs }) / 1e6
            if ps != nil, let own = totals, let notOwn = own.unattributedCpuMs {
                totals?.foreignCpuMs = Int64(foreignCpuMs.rounded())
                totals?.unknownCpuMs = notOwn - Int64(foreignCpuMs.rounded())
            } else if let top = rec.top, foreignDtMs != nil, totals != nil {
                totals?.foreignCpuMs = Int64(foreignCpuMs.rounded())
                // The top sample covers [previous top sample, this top sample], which does not line
                // up with ticks: read the cumulative system and own-process CPU at those two moments.
                if let last = lastTopMonoNs,
                   let b0 = busySeries.value(at: last), let b1 = busySeries.value(at: top.monoNs),
                   let o0 = ownSeries.value(at: last), let o1 = ownSeries.value(at: top.monoNs) {
                    totals?.unknownCpuMs = Int64(((b1 - b0) - (o1 - o0) - foreignCpuMs).rounded())
                }
            }
            if let top = rec.top { lastTopMonoNs = top.monoNs }
            busyMsSinceSweep = 0; diskBytesSinceSweep = 0; busyCoversSweep = true
        }

        guard let sys = rec.system, let d = sysDelta else {
            return   // first reading, or a counter reset: baselines only
        }
        let id = try writer.insertSample(tick: tick, tier: rec.procs != nil ? 2 : 1, flags: flags,
                                         procDtMs: procDtMs, foreignDtMs: foreignDtMs)
        try writer.insertSystem(sampleId: id, tick: tick, reading: sys, delta: d, slow: lastSlow, procs: totals)
        if procDtMs != nil {
            for (delta, reason) in ProvisionalSelection.select(deltas, selfPid: rec.selfPid) {
                try procStore.insertSample(sampleId: id, delta, reason: reason)
            }
        }
        if !foreign.isEmpty {
            // CPU from ps covers the process interval; everything from top covers the top interval.
            let cpuDt = flags.contains(.foreignCpuFromPs) ? (procDtMs ?? 10_000) : (foreignDtMs ?? 30_000)
            for (delta, reason) in ProvisionalSelection.selectForeign(foreign, dtMs: cpuDt) {
                try procStore.insertForeign(sampleId: id, delta, reason: reason)
            }
        }
        if let slow = rec.slow { try writer.insertVolumes(sampleId: id, slow.volumes) }
        samplesWritten += 1
    }

    /// Feed the self-limiter and record a change of level as an event.
    private func observeSelfCost(sweep: ProcSweep, deltas: [ProcDelta], selfPid: Int32?, procDtMs: Int64, ts: Int64) throws {
        let selfCpu = selfPid.flatMap { pid in deltas.first { $0.pid == pid }?.cpuMs }
        let sweepMs = Double(sweep.durationNs) / 1e6
        guard limiter.observe(sweepMs: sweepMs, selfCpuMs: selfCpu, dtMs: procDtMs) else { return }
        let share = limiter.cpuShare.map { String(format: "%.4f", $0) } ?? "null"
        try writer.insertEvent(ts: ts, kind: "collector_backoff", value: Int64(limiter.level),
                               detail: #"{"level":\#(limiter.level),"sweep_ms":\#(String(format: "%.1f", sweepMs)),"cpu_share":\#(share)}"#)
    }
}

/// Reads the live machine: runs the collectors that are due on a tick.
public final class LiveCollectors {
    private let system = SystemCollector()
    private let slow = SlowCollector()
    private let processes = NativeProcessCollector()
    private let ps = PsCollector()
    private let topStream: TopStream?
    private let selfPid = getpid()
    private var announcedPsOnly = false

    /// Ask for `ps` on every process sweep, for finer CPU resolution of foreign processes
    /// than the top stream gives. Used while a slowdown is being investigated.
    public var psBurst = false

    /// `topStream` nil means foreign processes are covered by `ps` alone.
    public init(topStream: TopStream? = nil) {
        self.topStream = topStream
    }

    public func collect(for tick: Tick) -> TickRecord {
        var rec = TickRecord(tick: tick)
        if tick.tiers.contains(.system) { rec.system = system.collect() }
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
            var notes = topStream?.takeNotes() ?? []
            if topStream == nil, !announcedPsOnly {
                announcedPsOnly = true
                notes.append(CollectorNote(kind: "foreign_source", value: 2, detail: #"{"mode":"ps","reason":"top stream disabled in configuration"}"#))
            }
            if !notes.isEmpty { rec.notes = notes }
        }
        if tick.tiers.contains(.slow) { rec.slow = slow.collect() }
        return rec
    }
}
