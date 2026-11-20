import Foundation

/// One app's activity over an interval, summed over its processes. Nil means "no source could
/// supply this", which is stored as NULL.
struct AppAgg {
    var procCount = 0
    var cpuMs: Int64?
    var cpuPMs: Int64?, cpuFgMs: Int64?, cpuUtilMs: Int64?, cpuBgMs: Int64?, waitMs: Int64?
    var footprint: Int64?, dFootprint: Int64?, pageins: Int64?
    var diskRead: Int64?, diskWrite: Int64?, wakeups: Int64?, energyUj: Int64?
    /// 0 native, 1 top stream, 2 ps, 3 residual. The worst contributor wins.
    var fidelity = 0

    private static func add(_ a: inout Int64?, _ b: Int64?) { if let b { a = (a ?? 0) + b } }

    mutating func add(_ o: AppAgg) {
        procCount += o.procCount
        Self.add(&cpuMs, o.cpuMs); Self.add(&cpuPMs, o.cpuPMs); Self.add(&cpuFgMs, o.cpuFgMs)
        Self.add(&cpuUtilMs, o.cpuUtilMs); Self.add(&cpuBgMs, o.cpuBgMs); Self.add(&waitMs, o.waitMs)
        Self.add(&footprint, o.footprint); Self.add(&dFootprint, o.dFootprint); Self.add(&pageins, o.pageins)
        Self.add(&diskRead, o.diskRead); Self.add(&diskWrite, o.diskWrite)
        Self.add(&wakeups, o.wakeups); Self.add(&energyUj, o.energyUj)
        fidelity = max(fidelity, o.fidelity)
    }

    mutating func add(own d: ProcDelta) {
        procCount += 1
        Self.add(&cpuMs, d.cpuMs); Self.add(&cpuPMs, d.cpuPMs); Self.add(&cpuFgMs, d.cpuFgMs)
        Self.add(&cpuUtilMs, d.cpuUtilMs); Self.add(&cpuBgMs, d.cpuBgMs); Self.add(&waitMs, d.waitMs)
        Self.add(&footprint, d.footprint); Self.add(&dFootprint, d.dFootprint); Self.add(&pageins, d.dPageins)
        Self.add(&diskRead, d.dDiskRead); Self.add(&diskWrite, d.dDiskWrite)
        Self.add(&wakeups, d.dWakeups); Self.add(&energyUj, d.dEnergyUj)
    }

    /// Worth its own row? Everything else is summed into the "idle apps" row, so totals still add up.
    func significant(dtMs: Int64) -> Bool {
        (cpuMs ?? 0) * 2000 >= max(dtMs, 1)            // 0.05 % of a core
            || (diskRead ?? 0) + (diskWrite ?? 0) > 0
            || abs(dFootprint ?? 0) >= 1 << 20
            || (footprint ?? 0) >= 100 << 20
    }

    /// The part of this aggregate that falls into one of several ticks covering its interval.
    /// Counters are split by `from`...`to` (cumulative fractions, so the parts add up exactly);
    /// gauges (footprint, process count) are point-in-time values and are kept only where asked.
    func slice(from: Double, to: Double, gauges: Bool = true) -> AppAgg {
        func part(_ v: Int64?) -> Int64? {
            v.map { Int64((Double($0) * to).rounded()) - Int64((Double($0) * from).rounded()) }
        }
        var s = self
        s.cpuMs = part(cpuMs); s.dFootprint = part(dFootprint); s.pageins = part(pageins); s.wakeups = part(wakeups)
        s.diskRead = part(diskRead); s.diskWrite = part(diskWrite); s.energyUj = part(energyUj)
        if !gauges { s.footprint = nil; s.procCount = 0 }
        return s
    }
}

/// Writes `app_sample`: the complete, summable fact table. Rows are merged additively, because
/// one app's row can receive contributions from several sources and, for processes read through
/// the top stream, after the tick it belongs to.
struct AppStore {
    let db: Database

    private static let additive = ["proc_count", "cpu_ms", "cpu_p_ms", "cpu_fg_ms", "cpu_util_ms", "cpu_bg_ms", "runnable_ms",
                                   "footprint", "d_footprint", "d_pageins", "d_disk_read", "d_disk_write", "d_wakeups", "d_energy_uj"]
    private static let sql: String = {
        let merge = additive.map {
            "\($0) = CASE WHEN \($0) IS NULL AND excluded.\($0) IS NULL THEN NULL ELSE COALESCE(\($0), 0) + COALESCE(excluded.\($0), 0) END"
        }.joined(separator: ", ")
        return """
            INSERT INTO app_sample (sample_id, app_id, \(additive.joined(separator: ", ")), is_focus, fidelity)
            VALUES (?, ?, \(additive.map { _ in "?" }.joined(separator: ", ")), ?, ?)
            ON CONFLICT(sample_id, app_id) DO UPDATE SET \(merge),
              is_focus = MAX(is_focus, excluded.is_focus), fidelity = MAX(fidelity, excluded.fidelity)
            """
    }()

    func add(sampleId: Int64, appId: Int64, _ a: AppAgg, isFocus: Bool) throws {
        try db.run(Self.sql, [sampleId, appId, a.procCount == 0 ? nil : a.procCount, a.cpuMs, a.cpuPMs, a.cpuFgMs, a.cpuUtilMs, a.cpuBgMs, a.waitMs,
                              a.footprint, a.dFootprint, a.pageins, a.diskRead, a.diskWrite, a.wakeups, a.energyUj, isFocus, a.fidelity])
    }
}
