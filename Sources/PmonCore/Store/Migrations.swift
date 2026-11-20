import Foundation

/// Schema migrations keyed on `PRAGMA user_version`. Append only: never edit a released step.
public enum Migrations {
    static let steps: [(version: Int, sql: String)] = [
        (1, Schema.v1),
        // 2: utility-QoS CPU as its own column (blame weights it differently from background),
        //    and the interval covered by process rows, which differs from the system interval.
        (2, """
            ALTER TABLE sample ADD COLUMN proc_dt_ms INTEGER;
            ALTER TABLE proc_sample ADD COLUMN cpu_util_ms INTEGER;
            ALTER TABLE app_sample ADD COLUMN cpu_util_ms INTEGER;
            ALTER TABLE app_rollup_1m ADD COLUMN cpu_util_ms INTEGER;
            ALTER TABLE app_rollup_1h ADD COLUMN cpu_util_ms INTEGER;
            ALTER TABLE app_rollup_1d ADD COLUMN cpu_util_ms INTEGER;
            """),
        // 3: processes of other users arrive from the top stream on their own, longer interval,
        //    and the residuals that make totals reconcile.
        (3, """
            ALTER TABLE sample ADD COLUMN foreign_dt_ms INTEGER;
            ALTER TABLE sys_sample ADD COLUMN foreign_cpu_ms INTEGER;
            ALTER TABLE sys_sample ADD COLUMN unknown_cpu_ms INTEGER;
            ALTER TABLE sys_sample ADD COLUMN unattributed_disk_bytes INTEGER;
            """),
    ]

    public static var latestVersion: Int { steps.last!.version }

    /// Apply every step newer than the database's current version. Returns the number applied.
    @discardableResult
    public static func migrate(_ db: Database) throws -> Int {
        let current = db.userVersion
        guard current <= latestVersion else {
            throw SQLiteError(code: 1, message: "database schema version \(current) is newer than this build supports (\(latestVersion))")
        }
        var applied = 0
        for step in steps where step.version > current {
            try db.transaction {
                try db.exec(step.sql)
                try db.exec("PRAGMA user_version = \(step.version)")
            }
            applied += 1
        }
        return applied
    }
}
