import Foundation
import SQLite3

final class SQLiteStatement {
    private let db: OpaquePointer?
    private var statement: OpaquePointer?

    init(db: OpaquePointer?, sql: String) throws {
        self.db = db

        let result = sql.withCString { sqlPointer in
            sqlite3_prepare_v2(db, sqlPointer, -1, &statement, nil)
        }

        guard result == SQLite.ok else {
            throw BrowserDatabaseError.sqliteFailure(db.map(SQLite.message(for:)) ?? "Could not prepare SQLite statement.")
        }
    }

    deinit {
        _ = sqlite3_finalize(statement)
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            let result = value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, SQLite.transient)
            }
            try check(result)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value))
    }

    func bind(_ value: Double?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Data?, at index: Int32) throws {
        if let value {
            let result = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    index,
                    buffer.baseAddress,
                    Int32(value.count),
                    SQLite.transient
                )
            }
            try check(result)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func step() throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLite.row || result == SQLite.done else {
            throw BrowserDatabaseError.sqliteFailure(SQLite.message(for: db))
        }

        return result
    }

    func stepDone() throws {
        let result = try step()
        guard result == SQLite.done else {
            throw BrowserDatabaseError.sqliteFailure("SQLite statement returned rows where none were expected.")
        }
    }

    func text(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLite.null,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    func data(at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLite.null,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }

        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else {
            return nil
        }

        return Data(bytes: bytes, count: byteCount)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func optionalInt64(at index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLite.null else {
            return nil
        }

        return sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func optionalDouble(at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLite.null else {
            return nil
        }

        return sqlite3_column_double(statement, index)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLite.ok else {
            throw BrowserDatabaseError.sqliteFailure(SQLite.message(for: db))
        }
    }
}

enum SQLite {
    static let ok = SQLITE_OK
    static let row = SQLITE_ROW
    static let done = SQLITE_DONE
    static let null = SQLITE_NULL

    static let openReadWrite = SQLITE_OPEN_READWRITE
    static let openCreate = SQLITE_OPEN_CREATE
    static let openFullMutex = SQLITE_OPEN_FULLMUTEX

    static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static func message(for db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error."
        }

        return String(cString: message)
    }
}
