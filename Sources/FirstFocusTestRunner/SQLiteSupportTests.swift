import FirstFocusCore
import Foundation
import SQLite3

private struct Boom: Error {}

private func tempDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("firstfocus-sqlite-support-\(UUID().uuidString).sqlite").path
}

private func rowCount(_ db: OpaquePointer) -> Int {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &statement, nil)
    sqlite3_step(statement)
    return Int(sqlite3_column_int64(statement, 0))
}

private func openWithTable() -> OpaquePointer? {
    SQLite.open(path: tempDatabasePath()) {
        sqlite3_exec($0, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY)", nil, nil, nil) == SQLITE_OK
    }
}

func registerSQLiteSupportTests(_ runner: TestRunner) {
    runner.suite("SQLite (the module under every store)") { r in
        r.run("open runs the schema and hands back a usable connection") {
            guard let db = openWithTable() else { throw TestFailure(message: "open returned nil") }
            defer { sqlite3_close(db) }
            try expect(rowCount(db) == 0)
        }

        r.run("open is nil when the file can't be opened") {
            let db = SQLite.open(path: "/nonexistent-directory/store.sqlite") { _ in true }
            try expect(db == nil)
        }

        r.run("open is nil when the schema step fails") {
            let db = SQLite.open(path: tempDatabasePath()) { _ in false }
            try expect(db == nil)
        }

        r.run("inTransaction commits when the body returns") {
            guard let db = openWithTable() else { throw TestFailure(message: "open returned nil") }
            defer { sqlite3_close(db) }
            let value = try SQLite.inTransaction(db, failure: Boom()) { () -> Int in
                sqlite3_exec(db, "INSERT INTO t DEFAULT VALUES", nil, nil, nil)
                return 7
            }
            try expect(value == 7 && rowCount(db) == 1)
        }

        r.run("inTransaction rolls back and rethrows when the body throws") {
            guard let db = openWithTable() else { throw TestFailure(message: "open returned nil") }
            defer { sqlite3_close(db) }
            var threw = false
            do {
                try SQLite.inTransaction(db, failure: Boom()) {
                    sqlite3_exec(db, "INSERT INTO t DEFAULT VALUES", nil, nil, nil)
                    throw Boom()
                }
            } catch { threw = true }
            try expect(threw && rowCount(db) == 0, "the insert before the throw is undone")
        }

        r.run("the Bool inTransaction rolls back when the body says false") {
            guard let db = openWithTable() else { throw TestFailure(message: "open returned nil") }
            defer { sqlite3_close(db) }
            let ok = SQLite.inTransaction(db) {
                sqlite3_exec(db, "INSERT INTO t DEFAULT VALUES", nil, nil, nil)
                return false
            }
            try expect(!ok && rowCount(db) == 0)
        }

        r.run("addColumnIfMissing adds a column once and leaves it alone the second time") {
            guard let db = openWithTable() else { throw TestFailure(message: "open returned nil") }
            defer { sqlite3_close(db) }
            try expect(SQLite.addColumnIfMissing(db, table: "t", column: "note", type: "TEXT"))
            try expect(SQLite.addColumnIfMissing(db, table: "t", column: "note", type: "TEXT"))
            try expect(SQLite.columnNames(db, table: "t") == ["id", "note"])
        }
    }
}
