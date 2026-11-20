import Foundation

/// Rolls raw samples up into one-minute, one-hour and one-day buckets.
///
/// Incremental and restart-safe: each grain has a watermark (the end of the last bucket rolled),
/// kept in the `state` table. A bucket is rolled once it is complete *and* old enough that late
/// top-stream data for it has arrived. Rolling a range deletes and rewrites it, so running the
/// rollup twice changes nothing.
///
/// Buckets are aligned to UTC. `covered_ms` is the time actually observed in the bucket, the
/// denominator for every rate: it stays correct when the Mac slept for part of the bucket.
struct Rollup {
    let db: Database
    /// How long after a minute ends before it is rolled up.
    var lagMs: Int64 = 120_000

    static let minute: Int64 = 60_000, hour: Int64 = 3_600_000, day: Int64 = 86_400_000

    func watermark(_ grain: String) throws -> Int64? { try db.scalarInt("SELECT value FROM state WHERE key = ?", ["rollup_" + grain]) }

    private func setWatermark(_ grain: String, _ value: Int64) throws {
        try db.run("INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", ["rollup_" + grain, value])
    }

    /// Roll everything that is ready at time `now`. Returns the grains that advanced.
    @discardableResult
    func run(now: Int64) throws -> Set<String> {
        var advanced = Set<String>()
        let first = try db.scalarInt("SELECT MIN(ts) FROM sample") ?? now

        // Minutes, from raw samples.
        let upto1m = ((now - lagMs) / Self.minute) * Self.minute
        let from1m = try watermark("1m") ?? (first / Self.minute) * Self.minute
        if upto1m > from1m {
            try rollMinutes(from: from1m, to: upto1m)
            try setWatermark("1m", upto1m)
            advanced.insert("1m")
        }
        // Hours from minutes, days from hours: only buckets that are complete in the finer grain.
        for (grain, size, source) in [("1h", Self.hour, "1m"), ("1d", Self.day, "1h")] {
            guard let sourceMark = try watermark(source) else { continue }
            let upto = (sourceMark / size) * size
            let from = try watermark(grain) ?? (first / size) * size
            if upto > from {
                try rollUp(grain: grain, from: source, size: size, start: from, end: upto)
                try setWatermark(grain, upto)
                advanced.insert(grain)
            }
        }
        return advanced
    }

    private func rollMinutes(from: Int64, to: Int64) throws {
        try db.run("DELETE FROM sys_rollup_1m WHERE bucket_ts >= ? AND bucket_ts < ?", [from, to])
        try db.run("DELETE FROM app_rollup_1m WHERE bucket_ts >= ? AND bucket_ts < ?", [from, to])
        try db.run("""
            INSERT INTO sys_rollup_1m (bucket_ts, covered_ms, cpu_busy_pct_avg, cpu_busy_pct_max, runnable_wait_ms, mem_compressed_max,
              swap_used_max, pressure_warn_ms, pressure_crit_ms, swapouts, pageins, disk_read, disk_write, disk_io_time_ms,
              thermal_throttled_ms, gpu_util_avg, slug_index_avg, slug_index_max, sluggish_ms, episodes, awake_ms, user_present_ms, on_battery_ms)
            SELECT (s.ts / 60000) * 60000 AS b, SUM(s.dt_ms),
              SUM(y.cpu_user_ms + y.cpu_sys_ms) * 100.0 / NULLIF(SUM(y.cpu_user_ms + y.cpu_sys_ms + y.cpu_idle_ms), 0),
              MAX((y.cpu_user_ms + y.cpu_sys_ms) * 100.0 / NULLIF(y.cpu_user_ms + y.cpu_sys_ms + y.cpu_idle_ms, 0)),
              SUM(y.runnable_wait_ms), MAX(y.mem_compressed), MAX(y.swap_used),
              SUM(CASE WHEN y.pressure_level = 2 THEN s.dt_ms ELSE 0 END), SUM(CASE WHEN y.pressure_level >= 4 THEN s.dt_ms ELSE 0 END),
              SUM(y.d_swapouts), SUM(y.d_pageins), SUM(y.d_disk_read), SUM(y.d_disk_write), SUM(y.disk_io_time_ms),
              SUM(CASE WHEN y.thermal_level >= 2 THEN s.dt_ms ELSE 0 END), AVG(y.gpu_util_pct),
              SUM(y.slug_index * s.dt_ms) * 1.0 / NULLIF(SUM(CASE WHEN y.slug_index IS NOT NULL THEN s.dt_ms END), 0), MAX(y.slug_index),
              SUM(CASE WHEN s.flags & 16 THEN s.dt_ms ELSE 0 END), 0, SUM(s.dt_ms),
              SUM(CASE WHEN y.user_idle_s < 120 AND y.display_on = 1 AND COALESCE(y.screen_locked, 0) = 0 THEN s.dt_ms ELSE 0 END),
              SUM(CASE WHEN y.on_battery = 1 THEN s.dt_ms ELSE 0 END)
            FROM sample s JOIN sys_sample y USING (sample_id) WHERE s.ts >= ? AND s.ts < ? GROUP BY b
            """, [from, to])
        try db.run("""
            UPDATE sys_rollup_1m SET episodes = (SELECT COUNT(*) FROM episode e WHERE e.start_ts >= bucket_ts AND e.start_ts < bucket_ts + 60000)
            WHERE bucket_ts >= ? AND bucket_ts < ?
            """, [from, to])

        // Apps that did next to nothing in a minute are folded into the "idle apps" row, so the table
        // stays small (tens of rows per minute, not hundreds) while its sums still match the raw data.
        let other = try db.scalarInt("SELECT app_id FROM app WHERE key = 'pmon.other'") ?? -1
        try db.run("""
            WITH per_app AS (
              SELECT (s.ts / 60000) * 60000 AS b, x.app_id AS app, SUM(x.cpu_ms) AS cpu, SUM(x.cpu_fg_ms) AS fg, SUM(x.cpu_util_ms) AS util,
                SUM(x.cpu_bg_ms) AS bg, MAX(x.cpu_ms * 100.0 / NULLIF(s.proc_dt_ms, 0)) AS pct_max, AVG(x.footprint) AS fp_avg, MAX(x.footprint) AS fp_max,
                SUM(x.d_disk_read) AS rd, SUM(x.d_disk_write) AS wr, SUM(x.d_wakeups) AS wk, SUM(x.d_energy_uj) AS en, SUM(x.d_pageins) AS pg,
                SUM(CASE WHEN x.is_focus = 1 THEN s.proc_dt_ms ELSE 0 END) AS focus, SUM(CASE WHEN s.flags & 16 THEN s.proc_dt_ms ELSE 0 END) AS slug,
                MAX(x.proc_count) AS procs
              FROM app_sample x JOIN sample s USING (sample_id) WHERE s.ts >= ?1 AND s.ts < ?2 GROUP BY b, x.app_id
            )
            INSERT INTO app_rollup_1m (bucket_ts, app_id, cpu_ms, cpu_fg_ms, cpu_util_ms, cpu_bg_ms, cpu_pct_max, footprint_avg, footprint_max,
              disk_read, disk_write, wakeups, energy_uj, pageins, focus_ms, sluggish_ms, proc_max)
            SELECT b, CASE WHEN COALESCE(cpu, 0) >= 60 OR COALESCE(rd, 0) + COALESCE(wr, 0) >= 1048576 OR COALESCE(fp_max, 0) >= 104857600
                             OR focus > 0 OR app IN (SELECT app_id FROM app WHERE key LIKE 'system.%') THEN app ELSE ?3 END AS target,
              SUM(cpu), SUM(fg), SUM(util), SUM(bg), MAX(pct_max), CAST(SUM(fp_avg) AS INTEGER), SUM(fp_max),
              SUM(rd), SUM(wr), SUM(wk), SUM(en), SUM(pg), SUM(focus), MAX(slug), SUM(procs)
            FROM per_app GROUP BY b, target
            """, [from, to, other])
        // Per-bucket values that are not plain aggregates of the app's own rows.
        try db.run("""
            UPDATE app_rollup_1m SET
              covered_ms = (SELECT SUM(s.proc_dt_ms) FROM sample s WHERE s.proc_dt_ms IS NOT NULL AND s.ts >= bucket_ts AND s.ts < bucket_ts + 60000),
              footprint_last = (SELECT x.footprint FROM app_sample x JOIN sample s USING (sample_id)
                                WHERE x.app_id = app_rollup_1m.app_id AND x.footprint IS NOT NULL AND s.ts >= bucket_ts AND s.ts < bucket_ts + 60000
                                ORDER BY s.sample_id DESC LIMIT 1),
              blame = (SELECT SUM(b.score * (e.end_ts - e.start_ts)) / 60000.0 FROM episode e JOIN episode_blame b USING (episode_id)
                       WHERE b.app_id = app_rollup_1m.app_id AND b.role = 'culprit' AND e.end_ts >= bucket_ts AND e.end_ts < bucket_ts + 60000),
              launches = (SELECT COUNT(*) FROM event v WHERE v.kind = 'proc_start' AND v.app_id = app_rollup_1m.app_id
                          AND v.ts >= bucket_ts AND v.ts < bucket_ts + 60000)
            WHERE bucket_ts >= ? AND bucket_ts < ?
            """, [from, to])
    }

    private func rollUp(grain: String, from source: String, size: Int64, start: Int64, end: Int64) throws {
        try db.run("DELETE FROM sys_rollup_\(grain) WHERE bucket_ts >= ? AND bucket_ts < ?", [start, end])
        try db.run("DELETE FROM app_rollup_\(grain) WHERE bucket_ts >= ? AND bucket_ts < ?", [start, end])
        try db.run("""
            INSERT INTO sys_rollup_\(grain) (bucket_ts, covered_ms, cpu_busy_pct_avg, cpu_busy_pct_max, runnable_wait_ms, mem_compressed_max,
              swap_used_max, pressure_warn_ms, pressure_crit_ms, swapouts, pageins, disk_read, disk_write, disk_io_time_ms,
              thermal_throttled_ms, gpu_util_avg, slug_index_avg, slug_index_max, sluggish_ms, episodes, awake_ms, user_present_ms, on_battery_ms)
            SELECT (bucket_ts / \(size)) * \(size) AS b, SUM(covered_ms),
              SUM(cpu_busy_pct_avg * covered_ms) / NULLIF(SUM(CASE WHEN cpu_busy_pct_avg IS NOT NULL THEN covered_ms END), 0), MAX(cpu_busy_pct_max),
              SUM(runnable_wait_ms), MAX(mem_compressed_max), MAX(swap_used_max), SUM(pressure_warn_ms), SUM(pressure_crit_ms),
              SUM(swapouts), SUM(pageins), SUM(disk_read), SUM(disk_write), SUM(disk_io_time_ms), SUM(thermal_throttled_ms), AVG(gpu_util_avg),
              SUM(slug_index_avg * covered_ms) / NULLIF(SUM(CASE WHEN slug_index_avg IS NOT NULL THEN covered_ms END), 0), MAX(slug_index_max),
              SUM(sluggish_ms), SUM(episodes), SUM(awake_ms), SUM(user_present_ms), SUM(on_battery_ms)
            FROM sys_rollup_\(source) WHERE bucket_ts >= ? AND bucket_ts < ? GROUP BY b
            """, [start, end])
        try db.run("""
            INSERT INTO app_rollup_\(grain) (bucket_ts, app_id, covered_ms, cpu_ms, cpu_fg_ms, cpu_util_ms, cpu_bg_ms, cpu_pct_max, footprint_avg,
              footprint_max, disk_read, disk_write, wakeups, energy_uj, pageins, focus_ms, sluggish_ms, blame, proc_max, launches)
            SELECT (bucket_ts / \(size)) * \(size) AS b, app_id, SUM(covered_ms), SUM(cpu_ms), SUM(cpu_fg_ms), SUM(cpu_util_ms), SUM(cpu_bg_ms),
              MAX(cpu_pct_max), CAST(SUM(footprint_avg * covered_ms) / NULLIF(SUM(CASE WHEN footprint_avg IS NOT NULL THEN covered_ms END), 0) AS INTEGER),
              MAX(footprint_max), SUM(disk_read), SUM(disk_write), SUM(wakeups), SUM(energy_uj), SUM(pageins), SUM(focus_ms), SUM(sluggish_ms),
              SUM(blame), MAX(proc_max), SUM(launches)
            FROM app_rollup_\(source) WHERE bucket_ts >= ? AND bucket_ts < ? GROUP BY b, app_id
            """, [start, end])
        try db.run("""
            UPDATE app_rollup_\(grain) SET footprint_last = (
              SELECT r.footprint_last FROM app_rollup_\(source) r WHERE r.app_id = app_rollup_\(grain).app_id AND r.footprint_last IS NOT NULL
                AND r.bucket_ts >= app_rollup_\(grain).bucket_ts AND r.bucket_ts < app_rollup_\(grain).bucket_ts + \(size)
              ORDER BY r.bucket_ts DESC LIMIT 1)
            WHERE bucket_ts >= ? AND bucket_ts < ?
            """, [start, end])
    }
}
