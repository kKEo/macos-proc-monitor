import XCTest
@testable import PmonCore

final class StoreTests: XCTestCase {
    func testMigrationCreatesSchemaAndIsIdempotent() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        XCTAssertEqual(db.userVersion, 0)
        XCTAssertEqual(try Migrations.migrate(db), Migrations.steps.count)
        XCTAssertEqual(db.userVersion, Migrations.latestVersion)
        XCTAssertEqual(try Migrations.migrate(db), 0, "second run applies nothing")
        let tables = try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")
        XCTAssertEqual(tables, 23)
        for t in ["sample", "sys_sample", "proc_sample", "app_sample", "episode", "episode_blame", "app_rollup_1m", "app_rollup_1h", "app_rollup_1d", "sys_rollup_1d"] {
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [t]), 1, t)
        }
    }

    func testNewerSchemaIsRefused() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try db.exec("PRAGMA user_version = 999")
        XCTAssertThrowsError(try Migrations.migrate(db))
    }

    func testWalModeAndPragmas() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        var mode = ""
        try db.query("PRAGMA journal_mode") { mode = $0.text(0) }
        XCTAssertEqual(mode, "wal")
        XCTAssertEqual(try db.scalarInt("PRAGMA auto_vacuum"), 2)          // incremental
    }

    func testBindTypesRoundTrip() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try db.exec("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b INTEGER, n INTEGER)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [Int64(1) << 40, 2.5, "héllo", true, nil])
        try db.query("SELECT i, r, s, b, n FROM t") { r in
            XCTAssertEqual(r.int(0), 1 << 40); XCTAssertEqual(r.double(1), 2.5); XCTAssertEqual(r.text(2), "héllo")
            XCTAssertEqual(r.int(3), 1); XCTAssertTrue(r.isNull(4)); XCTAssertNil(r.optInt(4))
        }
    }

    func testTransactionRollsBackOnError() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try db.exec("CREATE TABLE t (i INTEGER PRIMARY KEY)")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            try db.run("INSERT INTO t VALUES (1)")           // primary key violation
        })
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM t"), 0)
    }

    func testReaderSeesCommittedRowsWhileWriterIsOpen() throws {
        let path = tempDir(self) + "/a.db"
        let writer = try Database(path: path)
        try writer.exec("CREATE TABLE t (i INTEGER)")
        let reader = try Database(path: path, readOnly: true)
        try writer.run("INSERT INTO t VALUES (1)")
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM t"), 1)
        try writer.exec("BEGIN IMMEDIATE")
        try writer.run("INSERT INTO t VALUES (2)")
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM t"), 1, "uncommitted row is invisible, and the reader is not blocked")
        try writer.exec("COMMIT")
        XCTAssertEqual(try reader.scalarInt("SELECT COUNT(*) FROM t"), 2)
        XCTAssertThrowsError(try reader.run("INSERT INTO t VALUES (3)"), "read-only connection cannot write")
    }
}
