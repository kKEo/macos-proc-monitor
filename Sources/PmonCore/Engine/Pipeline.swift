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
            if let sys = rec.system { _ = systemDeltas.delta(sys, coreIsPerformance: host.coreIsPerformance) }
            if let sweep = rec.procs { _ = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs) }
            lastSweepMonoNs = rec.procs == nil ? nil : tick.monoNs
            busyMsSinceSweep = 0; busyCoversSweep = rec.procs != nil
            _ = try writer.insertSample(tick: tick, tier: 1, flags: .afterWake)
            samplesWritten += 1
            return
        }

        let sysDelta = rec.system.flatMap { systemDeltas.delta($0, coreIsPerformance: host.coreIsPerformance) }
        if let d = sysDelta { busyMsSinceSweep += d.cpuUserMs + d.cpuSysMs } else { busyCoversSweep = false }

        // Process deltas, and the totals that go onto the system sample.
        var deltas: [ProcDelta] = []
        var totals: ProcTotals?
        var procDtMs: Int64?
        if let sweep = rec.procs {
            deltas = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs).deltas
            if let last = lastSweepMonoNs {
                procDtMs = Int64((tick.monoNs - last) / 1_000_000)
                let cpuMs = Int64(deltas.reduce(UInt64(0)) { $0 + $1.cpuNs } / 1_000_000)
                totals = ProcTotals(procCount: sweep.procs.count + sweep.foreign.count,
                                    threadCount: sweep.procs.reduce(0) { $0 + Int($1.threads) },
                                    waitMs: deltas.reduce(0) { $0 + $1.waitMs },
                                    unattributedCpuMs: busyCoversSweep ? max(0, busyMsSinceSweep - cpuMs) : nil)
                try observeSelfCost(sweep: sweep, deltas: deltas, selfPid: rec.selfPid, procDtMs: procDtMs!, ts: tick.wallMs)
            }
            lastSweepMonoNs = tick.monoNs
            busyMsSinceSweep = 0; busyCoversSweep = true
        }

        guard let sys = rec.system, let d = sysDelta else {
            return   // first reading, or a counter reset: baselines only
        }
        let id = try writer.insertSample(tick: tick, tier: rec.procs != nil ? 2 : 1, flags: backoffLevel > 0 ? .degraded : [],
                                         procDtMs: procDtMs)
        try writer.insertSystem(sampleId: id, tick: tick, reading: sys, delta: d, slow: lastSlow, procs: totals)
        if procDtMs != nil {
            for (delta, reason) in ProvisionalSelection.select(deltas, selfPid: rec.selfPid) {
                try procStore.insertSample(sampleId: id, delta, reason: reason)
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
    private let selfPid = getpid()
    public init() {}

    public func collect(for tick: Tick) -> TickRecord {
        var rec = TickRecord(tick: tick)
        if tick.tiers.contains(.system) { rec.system = system.collect() }
        if tick.tiers.contains(.process) { rec.procs = processes.collect(); rec.selfPid = selfPid }
        if tick.tiers.contains(.slow) { rec.slow = slow.collect() }
        return rec
    }
}
