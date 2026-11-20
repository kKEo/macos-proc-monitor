import Foundation

/// Schema migrations keyed on `PRAGMA user_version`. Append only: never edit a released step.
public enum Migrations {
    static let steps: [(version: Int, sql: String)] = [
        (1, Schema.v1),
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
