import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

/// A deliberately small SQLite wrapper. Not thread-safe; owned by an actor.
final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close_v2(db) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(db), message: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            let n = sqlite3_column_count(stmt)
            rows.append((0..<n).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) { .blob(Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))) } else { .blob(Data()) }
                default: .null
                }
            })
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        let row = try? query("PRAGMA user_version").first
        return row?.first?.int ?? 0
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .double(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let .blob(v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
        return stmt
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}

extension SQLValue {
    init(_ d: Double?) { self = d.map { .double($0) } ?? .null }
    init(_ i: Int?) { self = i.map { .int(Int64($0)) } ?? .null }
    init(_ i: Int64?) { self = i.map { .int($0) } ?? .null }
    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ d: Date?) { self = d.map { .double($0.timeIntervalSince1970) } ?? .null }

    var double: Double? {
        switch self { case let .double(v): v; case let .int(v): Double(v); default: nil }
    }
    var int64: Int64? {
        switch self { case let .int(v): v; case let .double(v): Int64(v); default: nil }
    }
    var int: Int? { int64.map(Int.init) }
    var string: String? { if case let .text(v) = self { v } else { nil } }
    var date: Date? { double.map(Date.init(timeIntervalSince1970:)) }
    var data: Data? {
        switch self { case let .blob(v): v; case let .text(v): Data(v.utf8); default: nil }
    }
}
