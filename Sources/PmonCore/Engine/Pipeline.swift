import Foundation

/// Turns raw tick records into stored rows: deltas, then one transaction per tick.
///
/// The pipeline has no access to collectors or clocks. Everything it knows arrives in a
/// `TickRecord`, so a live run and a replay of its recording produce identical rows.
public final class Pipeline {
    private let db: Database
    private let host: HostInfo
    private let writer: Writer
    private var systemDeltas = SystemDeltaEngine()
    private var lastSlow: SlowReading?

    /// Counts for health reporting.
    public private(set) var ticksIngested = 0
    public private(set) var samplesWritten = 0

    public init(db: Database, host: HostInfo) throws {
        self.db = db
        self.host = host
        try Migrations.migrate(db)
        let bootId: Int64 = try db.transaction {
            try Dimensions.upsertHost(db, host)
            return try Dimensions.bootId(db, host)
        }
        writer = Writer(db: db, bootId: bootId, pageSize: Int64(host.pageSize))
    }

    public func ingest(_ rec: TickRecord) throws {
        ticksIngested += 1
        if let slow = rec.slow { lastSlow = slow }

        // An interval that spans sleep is not a real interval: drop the baseline so the next
        // tick starts a fresh one, and leave a flagged marker row so the gap is explained.
        if rec.tick.afterWake {
            systemDeltas.reset()
            if let sys = rec.system { _ = systemDeltas.delta(sys, coreIsPerformance: host.coreIsPerformance) }
            try db.transaction {
                _ = try writer.insertSample(tick: rec.tick, tier: 1, flags: .afterWake)
            }
            samplesWritten += 1
            return
        }

        guard let sys = rec.system,
              let delta = systemDeltas.delta(sys, coreIsPerformance: host.coreIsPerformance) else {
            return   // first reading, or a counter reset: baseline only
        }
        try db.transaction {
            let id = try writer.insertSample(tick: rec.tick, tier: rec.tick.tiers.contains(.process) ? 2 : 1, flags: [])
            try writer.insertSystem(sampleId: id, tick: rec.tick, reading: sys, delta: delta, slow: lastSlow)
            if let slow = rec.slow { try writer.insertVolumes(sampleId: id, slow.volumes) }
        }
        samplesWritten += 1
    }
}

/// Reads the live machine: runs the collectors that are due on a tick.
public struct LiveCollectors {
    private let system = SystemCollector()
    private let slow = SlowCollector()
    public init() {}

    public func collect(for tick: Tick) -> TickRecord {
        var rec = TickRecord(tick: tick)
        if tick.tiers.contains(.system) { rec.system = system.collect() }
        if tick.tiers.contains(.slow) { rec.slow = slow.collect() }
        return rec
    }
}
