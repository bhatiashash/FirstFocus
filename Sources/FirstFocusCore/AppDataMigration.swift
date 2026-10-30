import Foundation
import SQLite3

public enum AppDataMigration {
    public static func recoverLegacyStore(applicationSupportDirectory: URL) throws {
        let files = FileManager.default
        let legacy = applicationSupportDirectory.appendingPathComponent("com.shashbhatia.DailyOS/store.sqlite")
        guard files.fileExists(atPath: legacy.path) else { return }
        let current = applicationSupportDirectory.appendingPathComponent("com.shashbhatia.FirstFocus/store.sqlite")
        try files.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try open(current.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(database) }
        let marker = "dailyos_store_recovered"
        if try rows(database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta'").count == 1,
           try rows(database, "SELECT value FROM meta WHERE key = '\(marker)'").count == 1 { return }

        let backupDirectory = applicationSupportDirectory
            .appendingPathComponent("FirstFocus Migration Backups/\(UUID().uuidString)")
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let legacyBackup = backupDirectory.appendingPathComponent("DailyOS-store.sqlite")
        try backup(path: legacy.path, to: legacyBackup.path)
        try backup(path: current.path, to: backupDirectory.appendingPathComponent("FirstFocus-store.sqlite").path)

        var attachment: OpaquePointer?
        guard sqlite3_prepare_v2(database, "ATTACH DATABASE ? AS legacy", -1, &attachment, nil) == SQLITE_OK else {
            throw failure(database)
        }
        defer { sqlite3_finalize(attachment) }
        sqlite3_bind_text(attachment, 1, legacyBackup.path, -1, sqliteTransient)
        guard sqlite3_step(attachment) == SQLITE_DONE else { throw failure(database) }
        defer { sqlite3_exec(database, "DETACH DATABASE legacy", nil, nil, nil) }

        try SQLite.inTransaction(database, failure: failure(database)) {
            let tables = try rows(database, """
                SELECT name, sql FROM legacy.sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
                """)
            for table in tables {
                try merge(table: table[0], schema: table[1], database: database)
            }
            try execute(database, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(database, "INSERT INTO meta (key, value) VALUES ('\(marker)', '1')")
        }
    }

    private static func merge(table: String, schema: String, database: OpaquePointer) throws {
        let name = quoted(table)
        if try rows(database, "SELECT name FROM main.sqlite_master WHERE type = 'table'").contains([table]) == false {
            try execute(database, schema)
        }
        let sourceColumns = try rows(database, "PRAGMA legacy.table_info(\(name))")
        let targetColumns = try rows(database, "PRAGMA main.table_info(\(name))")
        let targetNames = Set(targetColumns.map { $0[1] })
        for column in sourceColumns where !targetNames.contains(column[1]) {
            let defaultValue = column[4].isEmpty ? "" : " DEFAULT \(column[4])"
            try execute(database, "ALTER TABLE \(name) ADD COLUMN \(quoted(column[1])) \(column[2])\(defaultValue)")
        }
        let columns = sourceColumns.map { $0[1] }.filter { table != "corrections" || $0 != "id" }
        let columnList = columns.map(quoted).joined(separator: ", ")
        let selectList = columns.map { "old.\(quoted($0))" }.joined(separator: ", ")
        let sameRow = columns.map { "present.\(quoted($0)) IS old.\(quoted($0))" }.joined(separator: " AND ")
        var duplicate = sameRow
        if table == "corrections", columns.contains("source_ref"), columns.contains("correction_type") {
            duplicate = """
                (old.source_ref IS NOT NULL AND present.source_ref = old.source_ref
                    AND present.correction_type = old.correction_type) OR (\(sameRow))
                """
        }
        try execute(database, """
            INSERT INTO main.\(name) (\(columnList))
            SELECT \(selectList) FROM legacy.\(name) AS old
            WHERE NOT EXISTS (SELECT 1 FROM main.\(name) AS present WHERE \(duplicate))
            ON CONFLICT DO NOTHING
            """)
    }

    private static func backup(path: String, to destination: String) throws {
        let source = try open(path, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(source) }
        let target = try open(destination, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw failure(target) }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw failure(target) }
    }

    private static func open(_ path: String, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let error = failure(database)
            if let database { sqlite3_close(database) }
            throw error
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure(database) }
    }

    private static func rows(_ database: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(database) }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append((0..<sqlite3_column_count(statement)).map { columnText(statement!, $0) ?? "" })
            case SQLITE_DONE:
                return result
            default:
                throw failure(database)
            }
        }
    }

    private static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func failure(_ database: OpaquePointer?) -> NSError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the database."
        return NSError(domain: "FirstFocus.AppDataMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
