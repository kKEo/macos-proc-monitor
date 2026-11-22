import Foundation

/// One query function per report, shared by the text, JSON and HTML outputs.
public enum Queries {
    /// The rollup grain that covers `spanMs` with a sensible number of rows.
    public static func grain(for spanMs: Int64) -> (suffix: String, bucketMs: Int64) {
        if spanMs <= 3 * 3_600_000 { return ("1m", 60_000) }
        if spanMs <= 14 * 86_400_000 { return ("1h", 3_600_000) }
        return ("1d", 86_400_000)
    }

    /// As above, but falls back to a finer grain when the coarse one has nothing yet (a bucket is
    /// only written once it is complete, so a young database has minutes before it has hours).
    public static func grain(_ db: Database, since: Int64, now: Int64) throws -> (suffix: String, bucketMs: Int64) {
        let all: [(suffix: String, bucketMs: Int64)] = [("1d", 86_400_000), ("1h", 3_600_000), ("1m", 60_000)]
        let preferred = grain(for: now - since)
        for g in all where g.bucketMs <= preferred.bucketMs {
            if (try db.scalarInt("SELECT COUNT(*) FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ?", [since - g.bucketMs]) ?? 0) > 0 { return g }
        }
        return preferred
    }

    public struct Offender: Sendable, Hashable { public var app: String, kind: String, minutes: Double, episodes: Int, via: String }

    /// Apps ranked by sluggish-minutes caused: blame share x episode length, summed.
    public static func offenders(_ db: Database, since: Int64, includeAway: Bool, limit: Int = 10) throws -> [Offender] {
        var out: [Offender] = []
        try db.query("""
            SELECT a.name, a.kind, SUM(b.score * (e.end_ts - e.start_ts)) / 60000.0 AS minutes, COUNT(DISTINCT e.episode_id),
                   (SELECT b2.dim FROM episode_blame b2 JOIN episode e2 USING (episode_id)
                    WHERE b2.app_id = a.app_id AND b2.role = 'culprit' AND e2.start_ts >= ?1 GROUP BY b2.dim ORDER BY SUM(b2.score) DESC LIMIT 1)
            FROM episode e JOIN episode_blame b USING (episode_id) JOIN app a USING (app_id)
            WHERE e.start_ts >= ?1 AND e.end_ts IS NOT NULL AND b.role = 'culprit' AND (?2 = 1 OR e.user_present = 1)
            GROUP BY a.app_id HAVING minutes >= 0.005 ORDER BY minutes DESC LIMIT ?3
            """, [since, includeAway ? 1 : 0, limit]) { r in
            out.append(Offender(app: r.text(0), kind: r.text(1), minutes: r.double(2), episodes: Int(r.int(3)), via: r.optText(4) ?? ""))
        }
        return out
    }

    public struct Totals: Sendable, Hashable { public var episodes: Int, sluggishMs: Int64, away: Int, observedMs: Int64, presentMs: Int64 }

    /// `includeAway` counts slowdowns nobody was present for as well (they are otherwise only tallied in `away`).
    public static func totals(_ db: Database, since: Int64, now: Int64, includeAway: Bool = false) throws -> Totals {
        var t = Totals(episodes: 0, sluggishMs: 0, away: 0, observedMs: 0, presentMs: 0)
        try db.query("SELECT COUNT(*), COALESCE(SUM(end_ts - start_ts), 0) FROM episode WHERE start_ts >= ? AND end_ts IS NOT NULL AND (user_present = 1 OR ? = 1)", [since, includeAway ? 1 : 0]) {
            t.episodes = Int($0.int(0)); t.sluggishMs = $0.int(1)
        }
        t.away = Int(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE start_ts >= ? AND end_ts IS NOT NULL AND user_present = 0", [since]) ?? 0)
        let g = try grain(db, since: since, now: now)
        try db.query("SELECT COALESCE(SUM(awake_ms), 0), COALESCE(SUM(user_present_ms), 0) FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ?", [since - g.bucketMs]) {
            t.observedMs = $0.int(0); t.presentMs = $0.int(1)
        }
        return t
    }

    public struct Background: Sendable, Hashable { public var app: String, kind: String, cpuCoreMinutes: Double, peakMb: Double, energyMwh: Double?, focusPct: Double, writtenMb: Double }

    /// What apps cost while (almost) never in front.
    public static func background(_ db: Database, since: Int64, now: Int64, limit: Int = 8) throws -> [Background] {
        let g = try grain(db, since: since, now: now)
        var out: [Background] = []
        try db.query("""
            SELECT a.name, a.kind, SUM(r.cpu_ms) / 60000.0 AS cpu, MAX(r.footprint_max) / 1048576.0, SUM(r.energy_uj) / 3.6e6,
                   COALESCE(SUM(r.focus_ms), 0) * 100.0 / NULLIF(SUM(r.covered_ms), 0) AS focus, COALESCE(SUM(r.disk_write), 0) / 1048576.0
            FROM app_rollup_\(g.suffix) r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ? AND a.key NOT LIKE 'pmon.%' AND a.key NOT LIKE 'system.%'
            GROUP BY a.app_id HAVING focus < 5 AND cpu >= 0.05 ORDER BY cpu DESC LIMIT ?
            """, [since - g.bucketMs, limit]) { r in
            out.append(Background(app: r.text(0), kind: r.text(1), cpuCoreMinutes: r.double(2), peakMb: r.double(3), energyMwh: r.optDouble(4),
                                  focusPct: r.double(5), writtenMb: r.double(6)))
        }
        return out
    }

    public struct Finding: @unchecked Sendable, Identifiable { public var id: Int64, kind: String, app: String, severity: Int, first: Int64, last: Int64, status: String, evidence: [String: Any] }

    public static func findings(_ db: Database, includeClosed: Bool, since: Int64 = 0) throws -> [Finding] {
        var out: [Finding] = []
        try db.query("""
            SELECT f.finding_id, f.kind, a.name, f.severity, COALESCE(f.first_ts, f.ts), COALESCE(f.last_ts, f.ts), f.status, f.evidence
            FROM finding f JOIN app a USING (app_id) WHERE (f.status = 'open' OR ?1 = 1) AND COALESCE(f.last_ts, f.ts) >= ?2
            ORDER BY (f.status = 'open') DESC, f.severity DESC, f.last_ts DESC
            """, [includeClosed ? 1 : 0, since]) { r in
            let ev = (try? JSONSerialization.jsonObject(with: Data(r.text(7).utf8))) as? [String: Any] ?? [:]
            out.append(Finding(id: r.int(0), kind: r.text(1), app: r.text(2), severity: Int(r.int(3)), first: r.int(4), last: r.int(5), status: r.text(6), evidence: ev))
        }
        return out
    }

    /// A finding in one sentence.
    public static func sentence(_ f: Finding) -> String {
        func n(_ key: String, _ digits: Int = 0) -> String { Fmt.num((f.evidence[key] as? NSNumber)?.doubleValue ?? 0, digits) }
        switch f.kind {
        case "leak_suspect": return "\(f.app) may be leaking memory: up \(Fmt.size(mb: (f.evidence["growth_mb"] as? NSNumber)?.doubleValue ?? 0)) over \(n("hours")) hours (\(n("mb_per_hour")) MB per hour), now \(Fmt.size(mb: (f.evidence["now_mb"] as? NSNumber)?.doubleValue ?? 0))."
        case "runaway_cpu": return "\(f.app) used over 80 % of a core for \(n("minutes")) minutes in the background (peak \(n("peak_cpu_pct")) %)."
        case "wakeup_storm": return "\(f.app) woke the CPU about \(n("peak_wakeups_per_s")) times a second for \(n("minutes")) minutes; that costs battery."
        case "disk_writer": return "\(f.app) wrote \(n("written_gb", 1)) GB in 24 hours while in focus \(n("focus_pct")) % of the time."
        case "anomaly":
            let metric = f.evidence["metric"] as? String == "cpu_pct" ? "CPU" : "memory"
            let unit = metric == "CPU" ? " % of a core" : " MB"
            return "\(f.app) is far above its usual \(metric): \(n("value"))\(unit) in the last hour, normally under \(n("usual_p95"))."
        case "crash_loop": return "\(f.app) crashed \(n("crashes_in_hour")) times within an hour."
        case "disk_nearly_full": return "The system volume has \(n("free_gb", 1)) GB free (\(n("free_pct", 1)) %). A nearly full disk slows writes and leaves little room for swap."
        default: return "\(f.app): \(f.kind)"
        }
    }

    public struct TimelinePoint: Sendable, Hashable { public var ts: Int64, avg: Double?, max: Int?, sluggishMs: Int64, coveredMs: Int64 }

    public static func timeline(_ db: Database, since: Int64, now: Int64) throws -> (points: [TimelinePoint], bucketMs: Int64) {
        let g = try grain(db, since: since, now: now)
        var out: [TimelinePoint] = []
        try db.query("SELECT bucket_ts, slug_index_avg, slug_index_max, sluggish_ms, covered_ms FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ? ORDER BY bucket_ts", [since - g.bucketMs]) { r in
            out.append(TimelinePoint(ts: r.int(0), avg: r.optDouble(1), max: r.optInt(2).map { Int($0) }, sluggishMs: r.int(3), coveredMs: r.int(4)))
        }
        return (out, g.bucketMs)
    }

    public static func episodes(_ db: Database, since: Int64, now: Int64) throws -> [Episode] {
        var list: [Episode] = []
        try db.query("SELECT \(Episode.columns) FROM episode e WHERE COALESCE(e.end_ts, ?) >= ? ORDER BY e.start_ts", [now, since]) { list.append(Episode($0)) }
        return list
    }
}
