import Foundation

/// One app's part in an episode, for one pressure dimension.
struct BlameRow {
    var appId: Int64
    var dim: String
    /// 0...1 of the dimension's activity during the episode.
    var share: Double
    /// share x (dimension's mean sub-score / 100). Summable across dimensions and episodes.
    var score: Double
    var role: String              // culprit | victim
    var confidence: Int           // 0 low (residual), 1 medium (top stream / ps), 2 high (native)
    var peakValue: Int64?
    /// The numbers behind the share, kept so reports do not depend on raw samples that expire.
    var detail: [String: Double]
}

/// Works out who caused an episode, from the complete app-level rows.
///
/// Shares per dimension:
/// - cpu: CPU time weighted by QoS group (foreground 1.0, utility 0.5, background 0.2), because
///   background work on efficiency cores competes far less with what the user is doing.
/// - memory: 0.6 x share of memory held during the episode + 0.4 x share of growth over the
///   ten minutes leading up to it. Holding memory and having just grabbed it both count.
/// - disk: share of bytes read and written.
/// - thermal: share of energy over the five minutes before and during the episode (heat lags).
/// - ui: the app named in a hang report.
///
/// Victims: in a memory episode the app with the most page-ins is often the one being hurt,
/// not the one causing harm; in a CPU episode the same holds for an app that mostly waits.
/// Such apps are stored with role `victim` and a score of 0.
struct BlameCalculator {
    let db: Database
    let thresholds: Thresholds

    private struct AppWindow {
        var cpuMs = 0.0, weightedCpu = 0.0, waitMs = 0.0
        var footprintSum = 0.0, footprintSamples = 0.0, footprintMax = 0.0
        var pageins = 0.0, disk = 0.0, energy = 0.0
        var fidelity = 0
        var peakCpuShare = 0.0, peakDisk = 0.0
    }

    func compute(episodeId: Int64, start: Int64, end: Int64, meanScores: [String: Double], hangApps: [Int64]) throws -> [BlameRow] {
        let t = thresholds
        // Process ticks cover the interval *before* their timestamp, so include the first tick after the end.
        let endTick = try db.scalarInt("SELECT MIN(ts) FROM sample WHERE proc_dt_ms IS NOT NULL AND ts >= ?", [end]) ?? end
        let lastTs = min(endTick, end + 60_000)

        var apps: [Int64: AppWindow] = [:]
        var ticks = 0.0
        try db.query("SELECT COUNT(*) FROM sample WHERE proc_dt_ms IS NOT NULL AND ts > ? AND ts <= ?", [start, lastTs]) { ticks = $0.double(0) }
        guard ticks > 0 else { return [] }

        try db.query("""
            SELECT x.app_id, x.cpu_ms, x.cpu_fg_ms, x.cpu_util_ms, x.cpu_bg_ms, x.runnable_ms, x.footprint, x.d_pageins,
                   COALESCE(x.d_disk_read, 0) + COALESCE(x.d_disk_write, 0), x.fidelity, s.proc_dt_ms
            FROM app_sample x JOIN sample s USING (sample_id) WHERE s.ts > ? AND s.ts <= ?
            """, [start, lastTs]) { r in
            var a = apps[r.int(0)] ?? AppWindow()
            let cpu = r.double(1)
            a.cpuMs += cpu
            if r.isNull(2) {
                a.weightedCpu += cpu                               // no QoS split (top or ps): count in full
            } else {
                let split = r.double(2) + r.double(3) + r.double(4)
                a.weightedCpu += r.double(2) + t.qosWeightUtility * r.double(3) + t.qosWeightBackground * r.double(4) + max(0, cpu - split)
            }
            a.waitMs += r.double(5)
            if !r.isNull(6) { a.footprintSum += r.double(6); a.footprintSamples += 1; a.footprintMax = max(a.footprintMax, r.double(6)) }
            a.pageins += r.double(7); a.disk += r.double(8)
            a.fidelity = max(a.fidelity, Int(r.int(9)))
            if r.int(10) > 0 { a.peakCpuShare = max(a.peakCpuShare, cpu / r.double(10)) }
            a.peakDisk = max(a.peakDisk, r.double(8))
            apps[r.int(0)] = a
        }

        // Lead-up windows: memory growth and energy.
        var growth: [Int64: Double] = [:], energy: [Int64: Double] = [:]
        try db.query("""
            SELECT x.app_id, SUM(x.d_footprint) FROM app_sample x JOIN sample s USING (sample_id)
            WHERE s.ts > ? AND s.ts <= ? GROUP BY x.app_id HAVING SUM(x.d_footprint) > 0
            """, [start - Int64(t.memoryLeadSeconds * 1000), lastTs]) { growth[$0.int(0)] = $0.double(1) }
        try db.query("""
            SELECT x.app_id, SUM(x.d_energy_uj) FROM app_sample x JOIN sample s USING (sample_id)
            WHERE s.ts > ? AND s.ts <= ? AND x.d_energy_uj IS NOT NULL GROUP BY x.app_id
            """, [start - Int64(t.thermalLeadSeconds * 1000), lastTs]) { energy[$0.int(0)] = $0.double(1) }

        func total(_ f: (AppWindow) -> Double) -> Double { apps.values.reduce(0) { $0 + f($1) } }
        let totalWeighted = total { $0.weightedCpu }, totalCpu = total { $0.cpuMs }, totalWait = total { $0.waitMs }
        // Memory held: each app's average footprint over the ticks of the episode.
        let held = apps.mapValues { $0.footprintSamples > 0 ? $0.footprintSum / ticks : 0 }
        let totalHeld = held.values.reduce(0, +)
        let totalGrowth = growth.values.reduce(0, +), totalPageins = total { $0.pageins }
        let totalDisk = total { $0.disk }, totalEnergy = energy.values.reduce(0, +)
        let windowMs = max(Double(lastTs - start), 1)

        var rows: [BlameRow] = []
        func confidence(_ a: AppWindow) -> Int { a.fidelity == 0 ? 2 : (a.fidelity >= 3 ? 0 : 1) }
        func add(_ app: Int64, _ dim: String, _ share: Double, role: String = "culprit", confidence c: Int, peak: Double?, _ detail: [String: Double]) {
            guard share >= t.minShare else { return }
            let weight = role == "culprit" ? (meanScores[dim] ?? 0) / 100 : 0
            rows.append(BlameRow(appId: app, dim: dim, share: share, score: share * weight, role: role, confidence: c,
                                 peakValue: peak.map { Int64($0.rounded()) }, detail: detail))
        }

        for (app, a) in apps {
            let mb = 1.0 / 1_048_576
            if (meanScores["cpu"] ?? 0) >= t.minDimensionScore, totalWeighted > 0 {
                let share = a.weightedCpu / totalWeighted
                let detail = ["cpu_pct": a.cpuMs / windowMs * 100, "peak_cpu_pct": a.peakCpuShare * 100, "wait_s": a.waitMs / 1000]
                if share >= t.minShare {
                    add(app, "cpu", share, confidence: confidence(a), peak: a.peakCpuShare * 100, detail)
                } else if totalWait > 0, a.waitMs / totalWait >= 0.3, totalCpu > 0, a.cpuMs / totalCpu < 0.1 {
                    add(app, "cpu", a.waitMs / totalWait, role: "victim", confidence: confidence(a), peak: nil, detail)
                }
            }
            if (meanScores["memory"] ?? 0) >= t.minDimensionScore, totalHeld > 0 {
                let holdShare = (held[app] ?? 0) / totalHeld
                let growShare = totalGrowth > 0 ? (growth[app] ?? 0) / totalGrowth : 0
                let share = totalGrowth > 0 ? t.memoryHoldWeight * holdShare + t.memoryGrowthWeight * growShare : holdShare
                let pageShare = totalPageins > 0 ? a.pageins / totalPageins : 0
                let detail = ["held_mb": (held[app] ?? 0) * mb, "peak_mb": a.footprintMax * mb, "growth_mb": (growth[app] ?? 0) * mb,
                              "pageins": a.pageins, "hold_share": holdShare, "growth_share": growShare]
                if pageShare >= 0.3, holdShare < 0.1, growShare < 0.1 {
                    add(app, "memory", pageShare, role: "victim", confidence: confidence(a), peak: a.pageins, detail)
                } else {
                    add(app, "memory", share, confidence: confidence(a), peak: a.footprintMax, detail)
                }
            }
            if (meanScores["disk"] ?? 0) >= t.minDimensionScore, totalDisk > 0 {
                add(app, "disk", a.disk / totalDisk, confidence: confidence(a), peak: a.peakDisk,
                    ["disk_mb": a.disk * mb, "mb_per_s": a.disk * mb / (windowMs / 1000)])
            }
            if (meanScores["thermal"] ?? 0) >= t.minDimensionScore, totalEnergy > 0, let e = energy[app] {
                // Energy is only known for natively read processes, so shares are among those.
                add(app, "thermal", e / totalEnergy, confidence: min(confidence(a), 1), peak: nil, ["energy_mwh": e / 3.6e6])
            }
        }
        if (meanScores["ui"] ?? 0) >= t.minDimensionScore {
            for app in Set(hangApps) { add(app, "ui", 1.0 / Double(Set(hangApps).count), confidence: 2, peak: nil, [:]) }
        }
        return rows.sorted { ($0.score, $0.share, Double($1.appId)) > ($1.score, $1.share, Double($0.appId)) }
    }

    /// The process of an app that stood out most in a dimension during the window.
    func topProcess(appId: Int64, dim: String, start: Int64, end: Int64) throws -> Int64? {
        let metric: String
        switch dim {
        case "memory": metric = "MAX(x.footprint)"
        case "disk": metric = "SUM(COALESCE(x.d_disk_read, 0) + COALESCE(x.d_disk_write, 0))"
        default: metric = "SUM(COALESCE(x.cpu_user_ms, 0) + COALESCE(x.cpu_sys_ms, 0))"
        }
        return try db.scalarInt("""
            SELECT x.proc_id FROM proc_sample x JOIN sample s USING (sample_id) JOIN process p USING (proc_id)
            WHERE p.app_id = ? AND s.ts > ? AND s.ts <= ? GROUP BY x.proc_id ORDER BY \(metric) DESC, x.proc_id LIMIT 1
            """, [appId, start, end + 60_000])
    }
}

/// Reads and writes `episode` and `episode_blame`.
struct EpisodeStore {
    let db: Database

    func open(startTs: Int64) throws -> Int64 {
        try db.run("INSERT INTO episode (start_ts) VALUES (?)", [startTs])
        return db.lastInsertRowId
    }

    func close(_ s: EpisodeSummary, endTs: Int64, afterWake: Bool) throws {
        try db.run("""
            UPDATE episode SET end_ts = ?, peak_index = ?, mean_index = ?, dominant = ?,
              m_cpu = ?, m_mem = ?, m_disk = ?, m_thermal = ?, m_gpu = ?, m_ui = ?,
              user_present = ?, focus_app_id = ?, on_battery = ?, low_power = ?, after_wake = ?
            WHERE episode_id = ?
            """, [endTs, s.peak, s.meanIndex, s.dominant,
                  Int(s.mean("cpu").rounded()), Int(s.mean("memory").rounded()), Int(s.mean("disk").rounded()),
                  Int(s.mean("thermal").rounded()), Int(s.mean("gpu").rounded()), Int(s.mean("ui").rounded()),
                  s.userPresent, s.focusApp, s.onBattery, s.lowPower, afterWake, s.id])
    }

    /// Episodes left open by a daemon that stopped: end them at the last sample recorded.
    func closeDangling() throws {
        let last = try db.scalarInt("SELECT MAX(ts) FROM sample") ?? 0
        try db.run("UPDATE episode SET end_ts = MAX(start_ts, ?) WHERE end_ts IS NULL", [last])
    }

    func replaceBlame(episodeId: Int64, _ rows: [BlameRow], calculator: BlameCalculator, start: Int64, end: Int64) throws {
        try db.run("DELETE FROM episode_blame WHERE episode_id = ?", [episodeId])
        for r in rows {
            // Confidence follows the process that dominates the app's share: an app made of natively
            // read processes stays "high" even if a minor system-owned helper belongs to it too.
            let top = try calculator.topProcess(appId: r.appId, dim: r.dim, start: start, end: end)
            var confidence = r.confidence
            if confidence == 1, let top, try db.scalarInt("SELECT source FROM process WHERE proc_id = ?", [top]) == 0 { confidence = 2 }
            let detail = (try? JSONSerialization.data(withJSONObject: r.detail.mapValues { ($0 * 100).rounded() / 100 }, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) }
            try db.run("""
                INSERT OR REPLACE INTO episode_blame (episode_id, app_id, dim, share, score, role, confidence, top_proc_id, peak_value, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [episodeId, r.appId, r.dim, (r.share * 10000).rounded() / 10000, (r.score * 10000).rounded() / 10000, r.role, confidence,
                      top, r.peakValue, detail])
        }
    }
}
