import Foundation
import SQLite3

/// Production `CorrectionStore`. Lives in the same SQLite file
/// `SQLiteSignalStore`/`SQLiteHistoryStore`/`SQLiteParticipantLabelStore`
/// already write to — another table there, not another database (ADR 0029's
/// reasoning, applied again).
///
/// `@unchecked Sendable`: no mutable stored state after init — every method
/// opens and closes its own connection, the same posture the other SQLite
/// stores in this file already take.
public final class SQLiteCorrectionStore: CorrectionStore, @unchecked Sendable {
    private let path: String

    /// Written with fractional seconds, so a Correction made in the same
    /// second as a Rule proposal's watermark still compares correctly
    /// (ADR 0038). Rows written before this read back through
    /// `wholeSecondFormatter`.
    private var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private var wholeSecondFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    public init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    public static func defaultPath(bundleIdentifier: String) -> String {
        SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier)
    }

    public func record(_ correction: Correction) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        try insert(correction, into: db)
    }

    public func replace(_ correction: Correction) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        try SQLite.inTransaction(db, failure: HistoryStoreError.writeFailed) {
            if let sourceRef = correction.sourceRef {
                try execute(db, "DELETE FROM corrections WHERE source_ref = ? AND correction_type = ?") { statement in
                    sqlite3_bind_text(statement, 1, sourceRef, -1, sqliteTransient)
                    sqlite3_bind_text(statement, 2, correction.correctionType.rawValue, -1, sqliteTransient)
                }
            }
            try insert(correction, into: db)
        }
    }

    public func delete(sourceRef: String, type: CorrectionType) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        try execute(db, "DELETE FROM corrections WHERE source_ref = ? AND correction_type = ?") { statement in
            sqlite3_bind_text(statement, 1, sourceRef, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, type.rawValue, -1, sqliteTransient)
        }
    }

    private func insert(_ correction: Correction, into db: OpaquePointer) throws {
        let sql = """
        INSERT INTO corrections (chat_id, source_ref, input_text, corrected_output, correction_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        try execute(db, sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(correction.chatId))
            if let sourceRef = correction.sourceRef {
                sqlite3_bind_text(statement, 2, sourceRef, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, correction.inputText, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, correction.correctedOutput, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, correction.correctionType.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 6, self.dateFormatter.string(from: correction.createdAt), -1, sqliteTransient)
        }
    }

    public func correctionTypes(forSourceRefs sourceRefs: Set<String>) -> [String: Set<CorrectionType>] {
        guard !sourceRefs.isEmpty, let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Corrections number in the dozens, so reading every Batch-bound
        // one beats binding a week of source references.
        let sql = "SELECT source_ref, correction_type FROM corrections WHERE source_ref IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        var types: [String: Set<CorrectionType>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sourceRef = columnText(statement!, 0), sourceRefs.contains(sourceRef),
                let type = columnText(statement!, 1).flatMap(CorrectionType.init(rawValue:))
            else { continue }
            types[sourceRef, default: []].insert(type)
        }
        return types
    }

    private func execute(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.writeFailed
        }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
    }

    public func corrections(forChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction] {
        query(chatClause: "chat_id = ?", chatId: chatId, limit: limit, type: type)
    }

    public func globalCorrections(excludingChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction] {
        query(chatClause: "chat_id != ?", chatId: chatId, limit: limit, type: type)
    }

    public func corrections(ofType type: CorrectionType, createdAfter date: Date?, limit: Int) -> [Correction] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT chat_id, input_text, corrected_output, correction_type, created_at, source_ref
        FROM corrections
        WHERE correction_type = ? AND (? IS NULL OR created_at > ?)
        ORDER BY created_at DESC
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(statement, 1, type.rawValue, -1, sqliteTransient)
        if let date {
            let stamp = dateFormatter.string(from: date)
            sqlite3_bind_text(statement, 2, stamp, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, stamp, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 2)
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int(statement, 4, Int32(limit))
        return readCorrections(statement!)
    }

    /// Newest first, narrowed to one Correction type.
    private func query(chatClause: String, chatId: Int, limit: Int, type: CorrectionType) -> [Correction] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT chat_id, input_text, corrected_output, correction_type, created_at, source_ref
        FROM corrections
        WHERE \(chatClause) AND correction_type = ?
        ORDER BY created_at DESC
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, Int64(chatId))
        sqlite3_bind_text(statement, 2, type.rawValue, -1, sqliteTransient)
        sqlite3_bind_int(statement, 3, Int32(limit))
        return readCorrections(statement!)
    }

    private func readCorrections(_ statement: OpaquePointer) -> [Correction] {
        var results: [Correction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let inputText = columnText(statement, 1),
                let correctedOutput = columnText(statement, 2),
                let typeRaw = columnText(statement, 3),
                let type = CorrectionType(rawValue: typeRaw),
                let createdAtText = columnText(statement, 4),
                let createdAt = dateFormatter.date(from: createdAtText) ?? wholeSecondFormatter.date(from: createdAtText)
            else { continue }
            let chatId = Int(sqlite3_column_int64(statement, 0))
            results.append(Correction(
                chatId: chatId, sourceRef: columnText(statement, 5), inputText: inputText, correctedOutput: correctedOutput,
                correctionType: type, createdAt: createdAt
            ))
        }
        return results
    }

    private func open() -> OpaquePointer? {
        SQLite.open(path: path, schema: createSchemaIfNeeded)
    }

    private func createSchemaIfNeeded(_ db: OpaquePointer) -> Bool {
        guard migrateToBatchIdentityIfNeeded(db) else { return false }
        let sql = """
        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY,
            chat_id INTEGER NOT NULL,
            source_ref TEXT,
            input_text TEXT NOT NULL,
            corrected_output TEXT NOT NULL,
            correction_type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS corrections_batch ON corrections (source_ref, correction_type)
            WHERE source_ref IS NOT NULL;
        CREATE INDEX IF NOT EXISTS corrections_created_at ON corrections (created_at DESC);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return false }
        cutStoredExamplesDown(db)
        return true
    }

    /// Corrections used to keep the whole prompt, including the examples and
    /// open Suggestions it carried, so each generation nested the ones before
    /// it. Rewrites any stored example still carrying either, or still in
    /// the pre-batch `[message to judge]` format, down to what
    /// `exampleInput(fromPrompt:)` keeps. Only rows still in the old shape
    /// match, so after the first open this reads nothing.
    private func cutStoredExamplesDown(_ db: OpaquePointer) {
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        let sql = """
        SELECT id, input_text FROM corrections
        WHERE input_text LIKE '%[corrections]%' OR input_text LIKE '%[open suggestions]%'
            OR input_text LIKE '%[message to judge]%'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &select, nil) == SQLITE_OK else { return }
        var rewrites: [(id: Int64, text: String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            guard let stored = columnText(select!, 1) else { continue }
            let example = exampleInput(fromPrompt: stored)
            if example != stored { rewrites.append((sqlite3_column_int64(select, 0), example)) }
        }
        for rewrite in rewrites {
            try? execute(db, "UPDATE corrections SET input_text = ? WHERE id = ?") { statement in
                sqlite3_bind_text(statement, 1, rewrite.text, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 2, rewrite.id)
            }
        }
    }

    /// A Correction used to be keyed by its Chat and the whole prompt the
    /// model saw. The table now belongs to Batches (ADR 0031, amended
    /// 2026-09-26). Each old row takes the `sourceRef` of the History row
    /// whose rendered input it was recorded from, when one still exists in
    /// this file; the rest keep none, stay usable as worked examples, and
    /// match no History row. Runs once: a table with `source_ref` is left
    /// alone.
    private func migrateToBatchIdentityIfNeeded(_ db: OpaquePointer) -> Bool {
        let columns = SQLite.columnNames(db, table: "corrections")
        guard !columns.isEmpty, !columns.contains("source_ref") else { return true }
        let batchOfRow = SQLite.columnNames(db, table: "history_entries").isSuperset(of: ["chat_id", "rendered_context", "source_ref"])
            ? """
            (SELECT h.source_ref FROM history_entries h
             WHERE h.chat_id = old.chat_id AND h.rendered_context = old.input_text AND h.source_ref IS NOT NULL
             ORDER BY h.timestamp LIMIT 1)
            """
            : "NULL"
        let sql = """
        BEGIN;
        ALTER TABLE corrections RENAME TO corrections_before_batches;
        DROP INDEX IF EXISTS corrections_created_at;
        CREATE TABLE corrections (
            id INTEGER PRIMARY KEY,
            chat_id INTEGER NOT NULL,
            source_ref TEXT,
            input_text TEXT NOT NULL,
            corrected_output TEXT NOT NULL,
            correction_type TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX corrections_batch ON corrections (source_ref, correction_type) WHERE source_ref IS NOT NULL;
        INSERT OR IGNORE INTO corrections (chat_id, source_ref, input_text, corrected_output, correction_type, created_at)
            SELECT old.chat_id, \(batchOfRow), old.input_text, old.corrected_output, old.correction_type, old.created_at
            FROM corrections_before_batches old
            ORDER BY old.created_at DESC;
        DROP TABLE corrections_before_batches;
        COMMIT;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        return true
    }
}
