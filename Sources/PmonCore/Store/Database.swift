import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement. Obtained from `Database.prepare`, which caches them by SQL text.
public final class Statement {
    fileprivate let stmt: OpaquePointer
    private unowned let db: Database

    fileprivate init(stmt: OpaquePointer, db: Database) { self.stmt = stmt; self.db = db }
    deinit { sqlite3_finalize(stmt) }

    /// Bind positional parameters. Supported: integers, Double, String, Bool, nil.
    public func bind(_ args: [Any?]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch arg {
            case nil: rc = sqlite3_bind_null(stmt, idx)
            case let v as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as UInt64: rc = sqlite3_bind_int64(stmt, idx, Int64(clamping: v))
            case let v as UInt32: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool: rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: rc = sqlite3_bind_double(stmt, idx, v)
            case let v as String: rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: throw SQLiteError(code: SQLITE_MISUSE, message: "unsupported bind type \(type(of: arg!)) at index \(idx)")
            }
            if rc != SQLITE_OK { throw db.lastError() }
        }
    }

    /// Advance to the next row. Returns false when there are no more rows.
    public func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.lastError()
        }
    }

    /// Bind, execute to completion and reset. For statements that return no rows.
    public func run(_ args: [Any?] = []) throws {
        try bind(args)
        defer { sqlite3_reset(stmt) }
        while try step() {}
    }

    public func reset() { sqlite3_reset(stmt) }

    public var columnCount: Int { Int(sqlite3_column_count(stmt)) }
    public func name(_ i: Int) -> String { String(cString: sqlite3_column_name(stmt, Int32(i))) }
    public func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
    public func int(_ i: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(i)) }
    public func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
    public func text(_ i: Int) -> String { sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } ?? "" }
    public func optInt(_ i: Int) -> Int64? { isNull(i) ? nil : int(i) }
    public func optDouble(_ i: Int) -> Double? { isNull(i) ? nil : double(i) }
    public func optText(_ i: Int) -> String? { isNull(i) ? nil : text(i) }
}

/// Thin SQLite wrapper: one connection, cached prepared statements, transactions.
/// The daemon holds the single writer; the CLI opens read-only connections.
public final class Database {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]
    public let path: String
    public let readOnly: Bool

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.readOnly = readOnly
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: "\(msg) (\(path))")
        }
        sqlite3_busy_timeout(handle, 3000)
        if !readOnly {
            // Owner-only: the data describes everything the user runs. WAL and SHM files inherit this mode.
            chmod(path, 0o600)
            // auto_vacuum must be chosen before the first table exists; a no-op on an existing file.
            try exec("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        }
    }

    deinit {
        cache.removeAll()
        sqlite3_close(handle)
    }

    fileprivate func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Execute one or more statements that take no parameters and return no rows.
    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] { return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        let s = Statement(stmt: stmt, db: self)
        cache[sql] = s
        return s
    }

    public func run(_ sql: String, _ args: [Any?] = []) throws { try prepare(sql).run(args) }

    /// Run a query and call `row` for each result row.
    public func query(_ sql: String, _ args: [Any?] = [], row: (Statement) throws -> Void) throws {
        let s = try prepare(sql)
        try s.bind(args)
        defer { s.reset() }
        while try s.step() { try row(s) }
    }

    public func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int64? {
        var out: Int64?
        try query(sql, args) { if out == nil { out = $0.optInt(0) } }
        return out
    }

    public var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Run `body` in a transaction; roll back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int { Int((try? scalarInt("PRAGMA user_version")) ?? 0) }
}
