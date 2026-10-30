import FirstFocusCore
import Foundation
import SQLite3

private func migrationHistory(id: String, starred: Bool = false) -> HistoryEntry {
    HistoryEntry(
        id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000), sourceRawText: "test message",
        rawOutput: "NONE", modelUsed: "test model", signalCount: 0, isStarred: starred
    )
}

private func migrationSQL(_ path: String, _ sql: String) throws {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    try expect(sqlite3_open(path, &database) == SQLITE_OK)
    try expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "fixture SQL failed")
}

private func withMigrationStores(_ body: (URL, String, String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firstfocus-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appendingPathComponent("com.shashbhatia.DailyOS/store.sqlite").path
    let current = directory.appendingPathComponent("com.shashbhatia.FirstFocus/store.sqlite").path
    try body(directory, legacy, current)
}

func registerAppDataMigrationTests(_ runner: TestRunner) {
    runner.suite("App data survives the bundle identifier rename") { suite in
        suite.run("History, stars and corrections return without losing new History") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "old", starred: true))
                try SQLiteCorrectionStore(path: legacy).record(Correction(
                    chatId: 1, sourceRef: "old-batch", inputText: "old correction", correctedOutput: "NONE",
                    correctionType: .falsePositive
                ))
                try SQLiteHistoryStore(path: current).record(migrationHistory(id: "new"))
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                let history = SQLiteHistoryStore(path: current).allRows()
                try expect(Set(history.map(\.id)) == ["old", "new"], "History must include both databases")
                try expect(history.first { $0.id == "old" }?.isStarred == true)
                let corrections = SQLiteCorrectionStore(path: current).corrections(forChatId: 1, limit: 10, type: .falsePositive)
                try expect(corrections.map(\.inputText) == ["old correction"])
                try expect(SQLiteHistoryStore(path: legacy).allRows().count == 1, "old database stays untouched")
            }
        }

        suite.run("a first launch without a new database recovers ordering and processing state too") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "old", starred: true))
                let oldSignals = SQLiteSignalStore(path: legacy)
                try oldSignals.setFocusOrders(["reminder": 42])
                try oldSignals.markBackfillComplete()
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                try expect(SQLiteHistoryStore(path: current).allRows().map(\.id) == ["old"])
                try expect(SQLiteSignalStore(path: current).focusOrder(signalId: "reminder") == 42)
                try expect(SQLiteSignalStore(path: current).isBackfillComplete())
            }
        }

        suite.run("local correction IDs cannot discard old corrections, and newer logical corrections win") {
            try withMigrationStores { directory, legacy, current in
                for (path, sourceRef, text) in [(legacy, "old", "old example"), (current, "new", "new example")] {
                    try SQLiteCorrectionStore(path: path).record(Correction(
                        chatId: 1, sourceRef: sourceRef, inputText: text, correctedOutput: "NONE",
                        correctionType: .falsePositive
                    ))
                    try SQLiteCorrectionStore(path: path).record(Correction(
                        chatId: 1, sourceRef: "shared", inputText: text, correctedOutput: "NONE",
                        correctionType: .falsePositive
                    ))
                }
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                let corrections = SQLiteCorrectionStore(path: current).corrections(forChatId: 1, limit: 10, type: .falsePositive)
                try expect(corrections.count == 3)
                try expect(corrections.first { $0.sourceRef == "shared" }?.inputText == "new example")
            }
        }

        suite.run("recovery is one-time, so later deletes and unstars stay deleted and unstarred") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "shared", starred: true))
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "deleted"))
                try SQLiteHistoryStore(path: current).record(migrationHistory(id: "shared"))
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                let store = SQLiteHistoryStore(path: current)
                try expect(store.allRows().first { $0.id == "shared" }?.isStarred == false, "current edit wins")
                try store.delete(id: "deleted")
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                try expect(store.allRows().map(\.id) == ["shared"])
            }
        }

        suite.run("both databases have readable pre-recovery backups") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "old"))
                try SQLiteHistoryStore(path: current).record(migrationHistory(id: "new"))
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                let backups = try FileManager.default.contentsOfDirectory(
                    at: directory.appendingPathComponent("FirstFocus Migration Backups"), includingPropertiesForKeys: nil
                )
                let backup = try require(backups.first)
                try expect(SQLiteHistoryStore(path: backup.appendingPathComponent("DailyOS-store.sqlite").path).allRows().map(\.id) == ["old"])
                try expect(SQLiteHistoryStore(path: backup.appendingPathComponent("FirstFocus-store.sqlite").path).allRows().map(\.id) == ["new"])
            }
        }

        suite.run("a failed merge rolls back every table and can be retried") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "old"))
                try SQLiteSignalStore(path: legacy).setFocusOrders(["old-order": 2])
                try SQLiteHistoryStore(path: current).record(migrationHistory(id: "new"))
                try migrationSQL(current, """
                    CREATE TRIGGER block_recovery BEFORE INSERT ON history_entries
                    BEGIN SELECT RAISE(ABORT, 'test failure'); END;
                    """)
                var failed = false
                do { try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory) }
                catch { failed = true }
                try expect(failed)
                try expect(SQLiteHistoryStore(path: current).allRows().map(\.id) == ["new"])
                try expect(SQLiteSignalStore(path: current).focusOrder(signalId: "old-order") == nil)
                try migrationSQL(current, "DROP TRIGGER block_recovery")
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                try expect(SQLiteHistoryStore(path: current).allRows().count == 2)
                try expect(SQLiteSignalStore(path: current).focusOrder(signalId: "old-order") == 2)
            }
        }

        suite.run("a corrupt legacy database cannot erase the current History") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: current).record(migrationHistory(id: "new"))
                try FileManager.default.createDirectory(atPath: (legacy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data("not a database".utf8).write(to: URL(fileURLWithPath: legacy))
                var failed = false
                do { try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory) }
                catch { failed = true }
                try expect(failed)
                try expect(SQLiteHistoryStore(path: current).allRows().map(\.id) == ["new"])
            }
        }

        suite.run("an install without DailyOS data creates no database") {
            try withMigrationStores { directory, _, current in
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                try expect(!FileManager.default.fileExists(atPath: current))
            }
        }

        suite.run("WAL-backed legacy writes are included even before checkpointing") {
            try withMigrationStores { directory, legacy, current in
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "old"))
                var connection: OpaquePointer?
                try expect(sqlite3_open(legacy, &connection) == SQLITE_OK)
                defer { sqlite3_close(connection) }
                try expect(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil) == SQLITE_OK)
                try SQLiteHistoryStore(path: legacy).record(migrationHistory(id: "in-wal", starred: true))
                try expect(FileManager.default.fileExists(atPath: legacy + "-wal"))
                try AppDataMigration.recoverLegacyStore(applicationSupportDirectory: directory)
                let history = SQLiteHistoryStore(path: current).allRows()
                try expect(Set(history.map(\.id)) == ["old", "in-wal"])
                try expect(history.first { $0.id == "in-wal" }?.isStarred == true)
            }
        }
    }
}
