import Foundation

/// Chronic problems that never trip an episode but are worth knowing about. Evaluated from the
/// rollups once an hour; each rule opens or refreshes a row in `finding`.
///
/// | kind | rule |
/// |---|---|
/// | leak_suspect | footprint rises steadily for 6+ hours (linear fit R² > 0.8) by more than 200 MB |
/// | runaway_cpu | over 80 % of a core for 10+ consecutive minutes while never in focus |
/// | wakeup_storm | over 1000 wakeups per second for 10+ consecutive minutes |
/// | disk_writer | over 5 GB written in 24 h while in focus less than 5 % of the time |
/// | anomaly | an hour at over 3x the app's own 95th percentile (and above an absolute floor) |
/// | crash_loop | three or more crash reports for the same app within an hour |
/// | disk_nearly_full | under 10 % free on the system volume (attached to "This Mac") |
struct Findings {
    let db: Database
    var leakHours = 6, leakR2 = 0.8, leakGrowthBytes = 200.0 * 1_048_576
    var runawayCpuShare = 0.8, sustainedMinutes = 10
    var wakeupsPerSecond = 1000.0
    var diskWriterBytes = 5.0 * 1_073_741_824, diskWriterFocusShare = 0.05
    var anomalyFactor = 3.0, anomalyMinSamples = 24
    var crashLoopCrashes = 3
    var diskFreeWarnPct = 10.0
    /// Open findings not seen again for this long are closed.
    var closeAfterMs: Int64 = 86_400_000

    struct Hit { var kind: String; var appId: Int64; var severity: Int; var evidence: [String: Any]; var firstTs: Int64 }

    func run(now: Int64, machineApp: Int64) throws {
        var hits: [Hit] = []
        hits += try leaks(now: now)
        hits += try sustained(now: now)
        hits += try diskWriters(now: now)
        hits += try anomalies(now: now)
        hits += try crashLoops(now: now)
        hits += try diskSpace(now: now, machineApp: machineApp)
        for h in hits { try record(h, now: now) }
        try db.run("UPDATE finding SET status = 'closed' WHERE status = 'open' AND last_ts < ?", [now - closeAfterMs])
    }

    /// Open a finding, or refresh the open one of the same kind for the same app.
    private func record(_ h: Hit, now: Int64) throws {
        let evidence = String(decoding: (try? JSONSerialization.data(withJSONObject: h.evidence, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        if let id = try db.scalarInt("SELECT finding_id FROM finding WHERE status = 'open' AND kind = ? AND app_id = ?", [h.kind, h.appId]) {
            try db.run("UPDATE finding SET last_ts = ?, severity = MAX(severity, ?), evidence = ? WHERE finding_id = ?", [now, h.severity, evidence, id])
        } else {
            try db.run("INSERT INTO finding (ts, kind, app_id, severity, evidence, first_ts, last_ts, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'open')",
                       [now, h.kind, h.appId, h.severity, evidence, h.firstTs, now])
        }
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    // Footprint growing steadily, hour after hour.
    private func leaks(now: Int64) throws -> [Hit] {
        var series: [Int64: [(t: Double, v: Double)]] = [:]
        try db.query("""
            SELECT r.app_id, r.bucket_ts, r.footprint_avg FROM app_rollup_1h r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ? AND r.footprint_avg IS NOT NULL AND a.key NOT LIKE 'pmon.%' AND a.key NOT LIKE 'system.%'
            ORDER BY r.app_id, r.bucket_ts
            """, [now - 24 * 3_600_000]) { series[$0.int(0), default: []].append((Double($0.int(1)) / 3_600_000, $0.double(2))) }
        var hits: [Hit] = []
        for (app, points) in series where points.count >= leakHours {
            let n = Double(points.count)
            let mx = points.reduce(0) { $0 + $1.t } / n, my = points.reduce(0) { $0 + $1.v } / n
            let sxx = points.reduce(0) { $0 + ($1.t - mx) * ($1.t - mx) }, syy = points.reduce(0) { $0 + ($1.v - my) * ($1.v - my) }
            let sxy = points.reduce(0) { $0 + ($1.t - mx) * ($1.v - my) }
            guard sxx > 0, syy > 0 else { continue }
            let slope = sxy / sxx, r2 = sxy * sxy / (sxx * syy)
            let growth = slope * (points.last!.t - points.first!.t)
            guard slope > 0, r2 >= leakR2, growth >= leakGrowthBytes else { continue }
            hits.append(Hit(kind: "leak_suspect", appId: app, severity: growth >= 4 * leakGrowthBytes ? 2 : 1,
                            evidence: ["hours": Int(n), "growth_mb": round1(growth / 1_048_576), "mb_per_hour": round1(slope / 1_048_576),
                                       "r2": (r2 * 100).rounded() / 100, "now_mb": round1(points.last!.v / 1_048_576)],
                            firstTs: Int64(points.first!.t * 3_600_000)))
        }
        return hits
    }

    // Runs of consecutive minutes over a threshold: runaway CPU and wakeup storms.
    private func sustained(now: Int64) throws -> [Hit] {
        struct Run { var start: Int64 = 0, last: Int64 = 0, minutes = 0, peak = 0.0 }
        var cpu: [Int64: Run] = [:], wake: [Int64: Run] = [:]
        var best: [String: [Int64: Run]] = ["runaway_cpu": [:], "wakeup_storm": [:]]
        func step(_ runs: inout [Int64: Run], _ kind: String, app: Int64, ts: Int64, on: Bool, value: Double) {
            var r = runs[app] ?? Run()
            if on, r.minutes > 0, ts - r.last <= 120_000 { r.minutes += 1; r.last = ts; r.peak = max(r.peak, value) }
            else if on { r = Run(start: ts, last: ts, minutes: 1, peak: value) }
            else { r = Run() }
            runs[app] = r
            if r.minutes >= sustainedMinutes, r.minutes > (best[kind]![app]?.minutes ?? 0) { best[kind]![app] = r }
        }
        try db.query("""
            SELECT r.app_id, r.bucket_ts, r.cpu_ms * 1.0 / NULLIF(r.covered_ms, 0), r.wakeups * 1000.0 / NULLIF(r.covered_ms, 0), r.focus_ms
            FROM app_rollup_1m r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ? AND a.key NOT LIKE 'pmon.%' AND a.key NOT LIKE 'system.%' ORDER BY r.app_id, r.bucket_ts
            """, [now - 2 * 3_600_000]) { r in
            step(&cpu, "runaway_cpu", app: r.int(0), ts: r.int(1), on: r.double(2) >= runawayCpuShare && r.int(4) == 0, value: r.double(2) * 100)
            step(&wake, "wakeup_storm", app: r.int(0), ts: r.int(1), on: r.double(3) >= wakeupsPerSecond, value: r.double(3))
        }
        var hits: [Hit] = []
        for (app, r) in best["runaway_cpu"]! {
            hits.append(Hit(kind: "runaway_cpu", appId: app, severity: r.minutes >= 30 ? 2 : 1,
                            evidence: ["minutes": r.minutes, "peak_cpu_pct": round1(r.peak)], firstTs: r.start))
        }
        for (app, r) in best["wakeup_storm"]! {
            hits.append(Hit(kind: "wakeup_storm", appId: app, severity: 1,
                            evidence: ["minutes": r.minutes, "peak_wakeups_per_s": round1(r.peak)], firstTs: r.start))
        }
        return hits
    }

    private func diskWriters(now: Int64) throws -> [Hit] {
        var hits: [Hit] = []
        try db.query("""
            SELECT r.app_id, SUM(r.disk_write), SUM(r.focus_ms) * 1.0 / NULLIF(SUM(r.covered_ms), 0), MIN(r.bucket_ts)
            FROM app_rollup_1h r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ? AND a.key NOT LIKE 'pmon.%' AND a.key NOT LIKE 'system.%'
            GROUP BY r.app_id HAVING SUM(r.disk_write) >= ?
            """, [now - 24 * 3_600_000, diskWriterBytes]) { r in
            guard r.double(2) < diskWriterFocusShare else { return }
            hits.append(Hit(kind: "disk_writer", appId: r.int(0), severity: r.double(1) >= 4 * diskWriterBytes ? 2 : 1,
                            evidence: ["written_gb": round1(r.double(1) / 1_073_741_824), "focus_pct": round1(r.double(2) * 100)], firstTs: r.int(3)))
        }
        return hits
    }

    // The latest complete hour against the app's own history.
    private func anomalies(now: Int64) throws -> [Hit] {
        guard let latest = try db.scalarInt("SELECT MAX(bucket_ts) FROM app_rollup_1h") else { return [] }
        var hits: [Hit] = []
        try db.query("""
            SELECT r.app_id, r.cpu_ms * 100.0 / NULLIF(r.covered_ms, 0), r.footprint_avg, c.p95, c.n, m.p95, m.n
            FROM app_rollup_1h r
            LEFT JOIN app_baseline c ON c.app_id = r.app_id AND c.metric = 'cpu_pct' AND c.hour_of_week = 168
            LEFT JOIN app_baseline m ON m.app_id = r.app_id AND m.metric = 'footprint' AND m.hour_of_week = 168
            WHERE r.bucket_ts = ?
            """, [latest]) { r in
            if !r.isNull(3), Int(r.int(4)) >= anomalyMinSamples, r.double(1) >= 20, r.double(1) > anomalyFactor * max(r.double(3), 1) {
                hits.append(Hit(kind: "anomaly", appId: r.int(0), severity: 1,
                                evidence: ["metric": "cpu_pct", "value": round1(r.double(1)), "usual_p95": round1(r.double(3))], firstTs: latest))
            } else if !r.isNull(5), Int(r.int(6)) >= anomalyMinSamples, r.double(2) >= 500 * 1_048_576, r.double(2) > anomalyFactor * r.double(5) {
                hits.append(Hit(kind: "anomaly", appId: r.int(0), severity: 1,
                                evidence: ["metric": "footprint_mb", "value": round1(r.double(2) / 1_048_576), "usual_p95": round1(r.double(5) / 1_048_576)], firstTs: latest))
            }
        }
        return hits
    }

    /// The same app crashing again and again. Counted from the system's own crash reports: how
    /// often a process starts says nothing by itself (launchd starts on-demand workers such as
    /// Spotlight's dozens of times an hour, and a build starts hundreds of compilers).
    private func crashLoops(now: Int64) throws -> [Hit] {
        var hits: [Hit] = []
        var rows: [(app: Int64, count: Int, first: Int64, proc: Int64?)] = []
        try db.query("""
            SELECT v.app_id, COUNT(*), MIN(v.ts), MAX(v.proc_id)
            FROM event v WHERE v.kind = 'crash' AND v.app_id IS NOT NULL AND v.ts >= ? GROUP BY v.app_id HAVING COUNT(*) >= ?
            """, [now - 3_600_000, crashLoopCrashes]) { rows.append(($0.int(0), Int($0.int(1)), $0.int(2), $0.optInt(3))) }
        for r in rows {
            var executable = ""
            if let proc = r.proc {
                try db.query("SELECT e.name FROM process p JOIN executable e USING (exe_id) WHERE p.proc_id = ?", [proc]) { executable = $0.text(0) }
            }
            hits.append(Hit(kind: "crash_loop", appId: r.app, severity: 2, evidence: ["crashes_in_hour": r.count, "executable": executable], firstTs: r.first))
        }
        return hits
    }

    private func diskSpace(now: Int64, machineApp: Int64) throws -> [Hit] {
        var hits: [Hit] = []
        try db.query("SELECT total, free FROM volume_sample WHERE mount = '/' ORDER BY sample_id DESC LIMIT 1") { r in
            let pct = Double(r.int(1)) / Double(max(r.int(0), 1)) * 100
            guard pct < diskFreeWarnPct else { return }
            hits.append(Hit(kind: "disk_nearly_full", appId: machineApp, severity: pct < 5 ? 2 : 1,
                            evidence: ["free_gb": round1(Double(r.int(1)) / 1_073_741_824), "free_pct": round1(pct)], firstTs: now))
        }
        return hits
    }

    /// Recompute what is normal for each app: median and 95th percentile of hourly CPU and footprint
    /// over the last four weeks, for all hours together (hour_of_week 168) and per hour of the week
    /// (0 = Monday 00:00 UTC).
    func updateBaselines(now: Int64) throws {
        var values: [String: [Double]] = [:]            // "app|metric|how" -> values
        try db.query("""
            SELECT app_id, bucket_ts, cpu_ms * 100.0 / NULLIF(covered_ms, 0), footprint_avg FROM app_rollup_1h
            WHERE bucket_ts >= ? AND covered_ms >= 600000
            """, [now - 28 * 86_400_000]) { r in
            let how = (r.int(1) / 3_600_000 + 72) % 168
            for (metric, i) in [("cpu_pct", 2), ("footprint", 3)] where !r.isNull(i) {
                values["\(r.int(0))|\(metric)|168", default: []].append(r.double(i))
                values["\(r.int(0))|\(metric)|\(how)", default: []].append(r.double(i))
            }
        }
        try db.run("DELETE FROM app_baseline")
        for (key, v) in values {
            let parts = key.split(separator: "|")
            let sorted = v.sorted()
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
            try db.run("INSERT INTO app_baseline (app_id, metric, hour_of_week, p50, p95, n, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [Int64(parts[0])!, String(parts[1]), Int64(parts[2])!, pct(0.5), pct(0.95), sorted.count, now])
        }
    }
}
