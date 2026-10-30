import Foundation
import SQLite3

/// Tells SQLite to copy a bound string, so the Swift string need not outlive
/// the statement.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The text in `column` of the current row, or nil for NULL.
func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

/// What every SQLite-backed store shares: opening a connection with its
/// schema in place, running a transaction, and adding a column to a table
/// that may predate it. Each store keeps its own SQL; none of this knows a
/// table.
package enum SQLite {
    /// A read-write connection to `path`, made if the file isn't there,
    /// with `schema` run on it first. `schema` returns false when it could
    /// not bring the tables up to date. Nil when the file can't be opened
    /// or `schema` fails; the caller closes the connection it gets back.
    package static func open(path: String, schema: (OpaquePointer) -> Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        guard schema(db) else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// Runs `body` inside `BEGIN IMMEDIATE` ... `COMMIT`. A throw from
    /// `body`, or a commit that fails, rolls back and throws; `failure` is
    /// what a failed `BEGIN` or `COMMIT` throws, in the store's own error
    /// type.
    package static func inTransaction<T>(_ db: OpaquePointer, failure: Error, _ body: () throws -> T) throws -> T {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure }
        do {
            let result = try body()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// `inTransaction` for a step that reports success as a Bool: false from
    /// `body`, or a failed `BEGIN` or `COMMIT`, is false, with a rollback
    /// once the transaction has begun.
    package static func inTransaction(_ db: OpaquePointer, _ body: () -> Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        guard body(), sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        return true
    }

    /// The names of `table`'s columns. `table` is always a fixed,
    /// code-controlled name, never user input; `PRAGMA table_info` takes no
    /// bound parameters for it.
    package static func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement!, 1) { names.insert(name) }
        }
        return names
    }

    /// This SQLite build's `ALTER TABLE ... ADD COLUMN` has no
    /// `IF NOT EXISTS` clause (it is a syntax error here although
    /// `sqlite3_libversion()` reports 3.51.0), so the check is done by hand
    /// against `PRAGMA table_info`.
    package static func addColumnIfMissing(_ db: OpaquePointer, table: String, column: String, type: String) -> Bool {
        guard !columnNames(db, table: table).contains(column) else { return true }
        return sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(type)", nil, nil, nil) == SQLITE_OK
    }
}
