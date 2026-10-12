import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Production `ParticipantLabelStore`. Lives in the same SQLite file
/// `SQLiteSignalStore` and `SQLiteHistoryStore` already write to — a third
/// table there, not a third database, matching History's own reasoning
/// (ADR 0029) for why this doesn't need a file of its own.
///
/// `@unchecked Sendable`: no mutable stored state after init — every method
/// opens and closes its own connection, the same posture `SQLiteHistoryStore`
/// already takes.
public final class SQLiteParticipantLabelStore: ParticipantLabelStore, @unchecked Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// Same file `SQLiteSignalStore`/`SQLiteHistoryStore` already use.
    public static func defaultPath(bundleIdentifier: String) -> String {
        SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier)
    }

    public func label(chatId: Int, senderAddress: String) -> String {
        guard let db = open() else { return participantLabel(forIndex: 0) }
        defer { sqlite3_close(db) }

        if let existingIndex = existingIndex(db, chatId: chatId, senderAddress: senderAddress) {
            return participantLabel(forIndex: existingIndex)
        }

        let nextIndex = count(db, chatId: chatId)
        insert(db, chatId: chatId, senderAddress: senderAddress, index: nextIndex)
        return participantLabel(forIndex: nextIndex)
    }

    private func existingIndex(_ db: OpaquePointer, chatId: Int, senderAddress: String) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT label_index FROM participant_labels WHERE chat_id = ? AND sender_address = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(chatId))
        sqlite3_bind_text(statement, 2, senderAddress, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func count(_ db: OpaquePointer, chatId: Int) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM participant_labels WHERE chat_id = ?", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_int64(statement, 1, Int64(chatId))
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func insert(_ db: OpaquePointer, chatId: Int, senderAddress: String, index: Int) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR IGNORE INTO participant_labels (chat_id, sender_address, label_index) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, Int64(chatId))
        sqlite3_bind_text(statement, 2, senderAddress, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 3, Int64(index))
        sqlite3_step(statement)
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        guard createSchemaIfNeeded(db) else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func createSchemaIfNeeded(_ db: OpaquePointer) -> Bool {
        let sql = """
        CREATE TABLE IF NOT EXISTS participant_labels (
            chat_id INTEGER NOT NULL,
            sender_address TEXT NOT NULL,
            label_index INTEGER NOT NULL,
            PRIMARY KEY (chat_id, sender_address)
        );
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
