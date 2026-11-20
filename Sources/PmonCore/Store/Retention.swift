import Foundation

/// How long each kind of data is kept.
public struct RetentionPolicy: Codable, Equatable, Sendable {
    /// Raw samples (system, process and app rows).
    public var rawHours = 48.0
    /// Raw samples inside an episode, plus `episodeMarginSeconds` either side, are kept this long instead.
    public var episodeDays = 30.0
    public var episodeMarginSeconds = 300.0
    public var minuteRollupDays = 14.0
    public var hourRollupDays = 400.0
    /// Samples deleted per pass, to keep each transaction short.
    public var batchSamples = 4000

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawHours = try c.decodeIfPresent(Double.self, forKey: .rawHours) ?? rawHours
        episodeDays = try c.decodeIfPresent(Double.self, forKey: .episodeDays) ?? episodeDays
        episodeMarginSeconds = try c.decodeIfPresent(Double.self, forKey: .episodeMarginSeconds) ?? episodeMarginSeconds
        minuteRollupDays = try c.decodeIfPresent(Double.self, forKey: .minuteRollupDays) ?? minuteRollupDays
        hourRollupDays = try c.decodeIfPresent(Double.self, forKey: .hourRollupDays) ?? hourRollupDays
        batchSamples = try c.decodeIfPresent(Int.self, forKey: .batchSamples) ?? batchSamples
    }
}

/// Deletes data past its retention. Raw samples are only removed once they have been rolled up,
/// and never from inside an episode's window, so the evidence for a slowdown outlives the rest.
struct Retention {
    let db: Database
    let policy: RetentionPolicy

    /// One pass. Returns true when more raw samples are waiting (the batch was full).
    func run(now: Int64, rolledUpTo: Int64?) throws -> Bool {
        let hour: Int64 = 3_600_000, day: Int64 = 86_400_000
        // Never delete what has not been rolled up yet.
        let rawCutoff = min(now - Int64(policy.rawHours * Double(hour)), rolledUpTo ?? 0)
        let episodeCutoff = now - Int64(policy.episodeDays * Double(day))
        let margin = Int64(policy.episodeMarginSeconds * 1000)

        try db.exec("CREATE TEMP TABLE IF NOT EXISTS gone (sample_id INTEGER PRIMARY KEY); DELETE FROM gone;")
        try db.run("""
            INSERT INTO gone SELECT s.sample_id FROM sample s
            WHERE s.ts < ?1 AND (s.ts < ?2 OR NOT EXISTS (
                SELECT 1 FROM episode e WHERE s.ts >= e.start_ts - ?3 AND s.ts <= COALESCE(e.end_ts, s.ts) + ?3))
            ORDER BY s.sample_id LIMIT ?4
            """, [rawCutoff, episodeCutoff, margin, policy.batchSamples])
        let n = try db.scalarInt("SELECT COUNT(*) FROM gone") ?? 0
        if n > 0 {
            for table in ["proc_sample", "app_sample", "sys_sample", "volume_sample", "sample"] {
                try db.run("DELETE FROM \(table) WHERE sample_id IN (SELECT sample_id FROM gone)")
            }
        }

        try db.run("DELETE FROM sys_rollup_1m WHERE bucket_ts < ?", [now - Int64(policy.minuteRollupDays * Double(day))])
        try db.run("DELETE FROM app_rollup_1m WHERE bucket_ts < ?", [now - Int64(policy.minuteRollupDays * Double(day))])
        try db.run("DELETE FROM sys_rollup_1h WHERE bucket_ts < ?", [now - Int64(policy.hourRollupDays * Double(day))])
        try db.run("DELETE FROM app_rollup_1h WHERE bucket_ts < ?", [now - Int64(policy.hourRollupDays * Double(day))])

        // Capture files expire with the evidence they belong to; the daemon removes the files.
        try db.run("DELETE FROM capture WHERE ts < ?", [episodeCutoff])

        // Process rows of long-gone processes that nothing refers to any more.
        try db.run("""
            DELETE FROM process WHERE exited_ts IS NOT NULL AND exited_ts < ?
              AND NOT EXISTS (SELECT 1 FROM proc_sample x WHERE x.proc_id = process.proc_id)
              AND NOT EXISTS (SELECT 1 FROM episode_blame b WHERE b.top_proc_id = process.proc_id)
              AND NOT EXISTS (SELECT 1 FROM event v WHERE v.proc_id = process.proc_id)
              AND NOT EXISTS (SELECT 1 FROM capture c WHERE c.proc_id = process.proc_id)
            """, [rawCutoff])
        return n >= Int64(policy.batchSamples)
    }
}
