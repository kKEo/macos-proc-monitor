import Foundation
import PmonCore

// The dashboard's view of the database. Everything here is read-only and plain values, so it can
// cross from the reading actor to the main thread.

func msNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// The six dimensions of the sluggishness index, in display order.
let dimensions = ["cpu", "memory", "disk", "thermal", "gpu", "ui"]

/// One raw sample, for the live charts and the minutes around a slowdown.
struct LivePoint: Identifiable, Sendable {
    var id: Int64                     // sample_id
    var ts: Date
    var index: Int?
    var scores: [String: Int]
    var cpuPct: Double?, pPct: Double?, ePct: Double?
    var memLevelPct: Double?, compressedGB: Double?, compressorGB: Double?, swapGB: Double?
    var diskReadMBs: Double?, diskWriteMBs: Double?
    var netInMBs: Double?, netOutMBs: Double?
    var gpuPct: Double?
    var episodeOpen: Bool
}

/// An application busy in the latest process sweep.
struct TopApp: Identifiable, Sendable, Hashable {
    var id: Int64                     // app_id
    var name: String, kind: String
    var cpuPct: Double, footprintMB: Double, procs: Int
    var focus: Bool
}

/// One system rollup bucket.
struct SysPoint: Identifiable, Sendable {
    var id: Int64 { bucket }
    var bucket: Int64
    var ts: Date
    var cpuAvg: Double?, cpuMax: Double?
    var slugAvg: Double?, slugMax: Double?
    var compressedGB: Double?, swapGB: Double?
    var diskMB: Double, gpuAvg: Double?
}

/// One application rollup bucket.
struct AppPoint: Identifiable, Sendable {
    var id: Int64 { bucket }
    var bucket: Int64
    var ts: Date
    var cpuPct: Double, cpuMaxPct: Double?
    var footprintMB: Double?, footprintMaxMB: Double?
    var diskMB: Double, energyMwh: Double?
}

/// An application for the Apps list: what it cost over the chosen range.
struct AppSummary: Identifiable, Sendable, Hashable {
    var id: Int64
    var name: String, kind: String
    var cpuCoreMinutes: Double, peakMB: Double, focusPct: Double, blameMinutes: Double
}

/// An episode with its main cause, for the Slowdowns list.
struct EpisodeRow: Identifiable, Sendable, Hashable {
    var episode: Episode
    var cause: String?
    var id: Int64 { episode.id }
}

/// Everything the detail pane of a slowdown needs.
struct EpisodeDetail: Sendable {
    var episode: Episode
    var text: String
    var blame: [Blame]
    var window: [LivePoint]
    var evidence: [Explain.Evidence]
}

/// Everything the detail pane of an application needs.
struct AppDetail: Sendable {
    var app: AppRef
    var series: [AppPoint]
    var bucketMs: Int64
    var episodes: [(episode: Episode, dim: String, share: Double, role: String)]
    var findings: [Queries.Finding]
}

struct AppRef: Sendable, Hashable { var id: Int64, name: String, kind: String }

/// The overview tab's numbers, read together.
struct Overview: Sendable {
    var totals: Queries.Totals
    var series: [SysPoint]
    var bucketMs: Int64
    var offenders: [Queries.Offender]
    var background: [Queries.Background]
    var episodes: [Episode]
    var activeFindings: Int
}

/// The time ranges the history tabs offer.
enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1 hour", day = "24 hours", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var ms: Int64 {
        switch self {
        case .hour: return 3_600_000
        case .day: return 86_400_000
        case .week: return 7 * 86_400_000
        case .month: return 30 * 86_400_000
        }
    }
}

struct NoDatabase: Error {}

/// Owns the one read-only connection. The statement cache is not thread-safe, so every query
/// goes through this actor.
actor DashboardData {
    let path: String
    private var db: Database?
    private var cores = (p: 4.0, e: 4.0)

    init(path: String) { self.path = path }

    /// The connection, opened on first use (the daemon may create the file later).
    private func open() throws -> Database {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path) else { throw NoDatabase() }
        let d = try Database(path: path, readOnly: true)
        try d.query("SELECT p_cores, e_cores FROM host WHERE host_id = 1") { cores = (max(1, $0.double(0)), max(1, $0.double(1))) }
        db = d
        return d
    }

    /// Age of the newest sample in seconds, nil when there is none.
    func sampleAge() throws -> Double? {
        let ts = try open().scalarInt("SELECT MAX(ts) FROM sample")
        return ts.map { Double(msNow() - $0) / 1000 }
    }

    // MARK: Live

    private static let liveColumns = """
        s.sample_id, s.ts, s.dt_ms, y.slug_index, y.s_cpu, y.s_mem, y.s_disk, y.s_thermal, y.s_gpu, y.s_ui,
        y.cpu_user_ms, y.cpu_sys_ms, y.cpu_idle_ms, y.p_busy_ms, y.e_busy_ms,
        y.mem_level_pct, y.mem_compressed, y.swap_used, y.d_disk_read, y.d_disk_write, y.d_net_in, y.d_net_out, y.gpu_util_pct, s.flags, y.compressor_size
        """

    private func livePoint(_ r: Statement) -> LivePoint {
        let dt = max(Double(r.int(2)) / 1000, 0.001)
        func opt(_ i: Int) -> Double? { r.optDouble(i) }
        let busy = (opt(10) ?? 0) + (opt(11) ?? 0), total = busy + (opt(12) ?? 0)
        var scores: [String: Int] = [:]
        for (i, d) in dimensions.enumerated() { scores[d] = r.optInt(4 + i).map { Int($0) } ?? 0 }
        let gb = 1_073_741_824.0, mb = 1_048_576.0
        return LivePoint(
            id: r.int(0), ts: date(r.int(1)), index: r.optInt(3).map { Int($0) }, scores: scores,
            cpuPct: r.isNull(10) || total <= 0 ? nil : busy / total * 100,
            pPct: opt(13).map { min(100, $0 / (dt * 1000 * cores.p) * 100) },
            ePct: opt(14).map { min(100, $0 / (dt * 1000 * cores.e) * 100) },
            memLevelPct: opt(15), compressedGB: opt(16).map { $0 / gb }, compressorGB: opt(24).map { $0 / gb }, swapGB: opt(17).map { $0 / gb },
            diskReadMBs: opt(18).map { $0 / mb / dt }, diskWriteMBs: opt(19).map { $0 / mb / dt },
            netInMBs: opt(20).map { $0 / mb / dt }, netOutMBs: opt(21).map { $0 / mb / dt },
            gpuPct: opt(22), episodeOpen: r.int(23) & 16 != 0)
    }

    /// Raw samples between two moments.
    func samples(from: Int64, to: Int64) throws -> [LivePoint] {
        var out: [LivePoint] = []
        try open().query("""
            SELECT \(Self.liveColumns) FROM sample s JOIN sys_sample y USING (sample_id)
            WHERE s.ts >= ? AND s.ts <= ? ORDER BY s.sample_id
            """, [from, to]) { out.append(livePoint($0)) }
        return out
    }

    func live(minutes: Int) throws -> [LivePoint] {
        let now = msNow()
        return try samples(from: now - Int64(minutes) * 60_000, to: now)
    }

    /// Applications in the latest process sweep, busiest first.
    func topApps(limit: Int = 12) throws -> [TopApp] {
        var out: [TopApp] = []
        try open().query("""
            SELECT a.app_id, a.name, a.kind, x.cpu_ms * 100.0 / s.proc_dt_ms, COALESCE(x.footprint, 0) / 1048576.0, COALESCE(x.proc_count, 0), x.is_focus
            FROM app_sample x JOIN sample s USING (sample_id) JOIN app a USING (app_id)
            WHERE s.sample_id = (SELECT MAX(sample_id) FROM sample WHERE proc_dt_ms > 0)
              AND a.key NOT IN ('pmon.other', 'system.machine')
            ORDER BY x.cpu_ms DESC, x.footprint DESC LIMIT ?
            """, [limit]) { r in
            out.append(TopApp(id: r.int(0), name: r.text(1), kind: r.text(2), cpuPct: r.double(3), footprintMB: r.double(4),
                              procs: Int(r.int(5)), focus: r.int(6) == 1))
        }
        return out
    }

    // MARK: History

    func systemSeries(since: Int64, now: Int64) throws -> (points: [SysPoint], bucketMs: Int64) {
        let db = try open()
        let g = try Queries.grain(db, since: since, now: now)
        var out: [SysPoint] = []
        let gb = 1_073_741_824.0
        try db.query("""
            SELECT bucket_ts, cpu_busy_pct_avg, cpu_busy_pct_max, slug_index_avg, slug_index_max, mem_compressed_max, swap_used_max,
                   COALESCE(disk_read, 0) + COALESCE(disk_write, 0), gpu_util_avg
            FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ? AND bucket_ts <= ? ORDER BY bucket_ts
            """, [since - g.bucketMs, now]) { r in
            out.append(SysPoint(bucket: r.int(0), ts: date(r.int(0)), cpuAvg: r.optDouble(1), cpuMax: r.optDouble(2),
                                slugAvg: r.optDouble(3), slugMax: r.optDouble(4),
                                compressedGB: r.optDouble(5).map { $0 / gb }, swapGB: r.optDouble(6).map { $0 / gb },
                                diskMB: r.double(7) / 1_048_576, gpuAvg: r.optDouble(8)))
        }
        return (out, g.bucketMs)
    }

    func overview(range: TimeRange) throws -> Overview {
        let db = try open()
        let now = msNow(), since = now - range.ms
        let series = try systemSeries(since: since, now: now)
        return Overview(
            totals: try Queries.totals(db, since: since, now: now),
            series: series.points, bucketMs: series.bucketMs,
            offenders: try Queries.offenders(db, since: since, includeAway: false, limit: 10),
            background: try Queries.background(db, since: since, now: now),
            episodes: try Queries.episodes(db, since: since, now: now),
            activeFindings: Int(try db.scalarInt("SELECT COUNT(*) FROM finding WHERE status = 'open'") ?? 0))
    }

    // MARK: Slowdowns

    func episodes(range: TimeRange) throws -> [EpisodeRow] {
        let db = try open()
        let now = msNow()
        return try Queries.episodes(db, since: now - range.ms, now: now).reversed().map { e in
            let cause = e.end == nil ? nil : try loadBlame(db, episode: e.id).first { $0.role == "culprit" && $0.dim == e.dominant }
            return EpisodeRow(episode: e, cause: cause.map { "\($0.app) (\(Fmt.num($0.share * 100)) %)" })
        }
    }

    func episode(id: Int64) throws -> EpisodeDetail? {
        let db = try open()
        let now = msNow()
        var found: Episode?
        try db.query("SELECT \(Episode.columns) FROM episode e WHERE e.episode_id = ?", [id]) { found = Episode($0) }
        guard let e = found else { return nil }
        let blame = try loadBlame(db, episode: e.id)
        let margin: Int64 = 5 * 60_000
        return EpisodeDetail(episode: e, text: Explain.text(e, blame, now: now), blame: blame,
                             window: try samples(from: e.start - margin, to: (e.end ?? now) + margin),
                             evidence: try Explain.evidenceItems(db, e, now: now))
    }

    /// The newest episode, open or closed.
    func latestEpisodeId() throws -> Int64? {
        try open().scalarInt("SELECT MAX(episode_id) FROM episode")
    }

    // MARK: Findings

    func activeFindingCount() throws -> Int {
        Int(try open().scalarInt("SELECT COUNT(*) FROM finding WHERE status = 'open'") ?? 0)
    }

    func findings(includeClosed: Bool) throws -> [Queries.Finding] {
        try Queries.findings(try open(), includeClosed: includeClosed)
    }

    // MARK: Apps

    func apps(range: TimeRange) throws -> [AppSummary] {
        let db = try open()
        let now = msNow(), since = now - range.ms
        let g = try Queries.grain(db, since: since, now: now)
        var out: [AppSummary] = []
        try db.query("""
            SELECT a.app_id, a.name, a.kind, SUM(r.cpu_ms) / 60000.0 AS cpu, COALESCE(MAX(r.footprint_max), 0) / 1048576.0,
                   COALESCE(SUM(r.focus_ms), 0) * 100.0 / NULLIF(SUM(r.covered_ms), 0),
                   (SELECT COALESCE(SUM(b.score * (e.end_ts - e.start_ts)), 0) / 60000.0 FROM episode_blame b JOIN episode e USING (episode_id)
                    WHERE b.app_id = a.app_id AND b.role = 'culprit' AND e.start_ts >= ?1 AND e.end_ts IS NOT NULL)
            FROM app_rollup_\(g.suffix) r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ?2 AND a.key NOT IN ('pmon.other', 'system.machine', 'pmon.unresolved')
            GROUP BY a.app_id ORDER BY cpu DESC LIMIT 60
            """, [since, since - g.bucketMs]) { r in
            out.append(AppSummary(id: r.int(0), name: r.text(1), kind: r.text(2), cpuCoreMinutes: r.double(3), peakMB: r.double(4),
                                  focusPct: r.optDouble(5) ?? 0, blameMinutes: r.double(6)))
        }
        return out
    }

    /// Find an application by name; names come from lists that only carry the name.
    func appRef(name: String) throws -> AppRef? {
        var out: AppRef?
        try open().query("SELECT app_id, name, kind FROM app WHERE name = ? ORDER BY last_seen DESC LIMIT 1", [name]) {
            out = AppRef(id: $0.int(0), name: $0.text(1), kind: $0.text(2))
        }
        return out
    }

    func appRef(id: Int64) throws -> AppRef? {
        var out: AppRef?
        try open().query("SELECT app_id, name, kind FROM app WHERE app_id = ?", [id]) { out = AppRef(id: $0.int(0), name: $0.text(1), kind: $0.text(2)) }
        return out
    }

    /// An application's cost over time. `from`/`to` default to the range ending now.
    func appSeries(_ app: Int64, from: Int64, to: Int64) throws -> (points: [AppPoint], bucketMs: Int64) {
        let db = try open()
        let g = try Queries.grain(db, since: from, now: to)
        var out: [AppPoint] = []
        let mb = 1_048_576.0
        try db.query("""
            SELECT bucket_ts, COALESCE(cpu_ms, 0) * 100.0 / NULLIF(covered_ms, 0), cpu_pct_max, footprint_avg, footprint_max,
                   COALESCE(disk_read, 0) + COALESCE(disk_write, 0), energy_uj
            FROM app_rollup_\(g.suffix) WHERE app_id = ? AND bucket_ts >= ? AND bucket_ts <= ? ORDER BY bucket_ts
            """, [app, from - g.bucketMs, to]) { r in
            out.append(AppPoint(bucket: r.int(0), ts: date(r.int(0)), cpuPct: r.optDouble(1) ?? 0, cpuMaxPct: r.optDouble(2),
                                footprintMB: r.optDouble(3).map { $0 / mb }, footprintMaxMB: r.optDouble(4).map { $0 / mb },
                                diskMB: r.double(5) / mb, energyMwh: r.optDouble(6).map { $0 / 3.6e6 }))
        }
        return (out, g.bucketMs)
    }

    func appDetail(_ ref: AppRef, range: TimeRange) throws -> AppDetail {
        let db = try open()
        let now = msNow(), since = now - range.ms
        let series = try appSeries(ref.id, from: since, to: now)
        var episodes: [(Episode, String, Double, String)] = []
        try db.query("""
            SELECT \(Episode.columns), b.dim, b.share, b.role FROM episode e JOIN episode_blame b USING (episode_id)
            WHERE b.app_id = ? AND e.start_ts >= ? ORDER BY e.start_ts DESC, b.score DESC
            """, [ref.id, since]) { r in
            episodes.append((Episode(r), r.text(17), r.double(18), r.text(19)))
        }
        // One line per episode: the dimension where this app weighed most.
        var seen = Set<Int64>()
        episodes = episodes.filter { seen.insert($0.0.id).inserted }
        let findings = try Queries.findings(db, includeClosed: true).filter { $0.app == ref.name }
        return AppDetail(app: ref, series: series.points, bucketMs: series.bucketMs,
                         episodes: episodes.map { (episode: $0.0, dim: $0.1, share: $0.2, role: $0.3) }, findings: findings)
    }
}
