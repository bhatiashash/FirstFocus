import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Production `HistoryStore`. Lives in the same SQLite file
/// `SQLiteSignalStore` already writes to (same Application Support
/// directory, same "durable local state" role) but reached only through
/// `HistoryStore`, so a consumer depends on nothing it doesn't call (ADR
/// 0029). A separate table, not a shared one — History rows have no
/// relationship to `signals` rows beyond both originating from Extraction.
///
/// `@unchecked Sendable`: no mutable stored state after init — every method
/// opens and closes its own connection, the same posture `SQLiteSignalStore`
/// already takes.
public final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    private let path: String

    /// Every column `readEntry` reads, in its order.
    private static let columns = """
    id, timestamp, source_raw_text, raw_output, model_used, signal_count, is_starred, chat_id, rendered_context,
        kind, source_ref, screening_probability, was_screened, sender, transcript, chat_title, screening_question_version,
        chat_identifier, screening_mode, screening_cutoff, failure_reason, is_self_thread, is_all_mine
    """

    /// The meta key recording that the typed-fields migration has run.
    public static let typedFieldsMigrationKey = "history_typed_fields_migrated"

    private var dateFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    public init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// Same file `SQLiteSignalStore` already uses — History is a second
    /// table there, not a second database.
    public static func defaultPath(bundleIdentifier: String) -> String {
        SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier)
    }

    public func record(_ entry: HistoryEntry) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        INSERT INTO history_entries (
            id, timestamp, source_raw_text, raw_output, model_used, signal_count, is_starred, chat_id, rendered_context,
            kind, source_ref, screening_probability, was_screened, sender, transcript, chat_title, screening_question_version,
            chat_identifier, screening_mode, screening_cutoff, failure_reason, is_self_thread, is_all_mine
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, entry.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, dateFormatter.string(from: entry.timestamp), -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, entry.sourceRawText, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, entry.rawOutput, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, entry.modelUsed, -1, sqliteTransient)
        sqlite3_bind_int(statement, 6, Int32(entry.signalCount))
        sqlite3_bind_int(statement, 7, entry.isStarred ? 1 : 0)
        if let chatId = entry.chatId {
            sqlite3_bind_int64(statement, 8, Int64(chatId))
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_text(statement, 9, entry.renderedContext, -1, sqliteTransient)
        sqlite3_bind_text(statement, 10, entry.kind.storageName, -1, sqliteTransient)
        if let sourceRef = entry.sourceRef {
            sqlite3_bind_text(statement, 11, sourceRef, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        if let probability = entry.screeningProbability {
            sqlite3_bind_double(statement, 12, probability)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        sqlite3_bind_int(statement, 13, entry.wasScreened ? 1 : 0)
        bindOptionalText(statement, 14, entry.sender)
        bindOptionalText(statement, 15, entry.transcript.flatMap(encodeTranscript))
        bindOptionalText(statement, 16, entry.chatTitle)
        if let questionVersion = entry.screening?.questionVersion {
            sqlite3_bind_int(statement, 17, Int32(questionVersion))
        } else {
            sqlite3_bind_null(statement, 17)
        }
        bindOptionalText(statement, 18, entry.chatIdentifier)
        bindOptionalText(statement, 19, entry.screening?.mode.storageName)
        if let cutoff = entry.screening?.cutoff {
            sqlite3_bind_double(statement, 20, cutoff)
        } else {
            sqlite3_bind_null(statement, 20)
        }
        if case .screeningFailed(let reason) = entry.kind {
            sqlite3_bind_text(statement, 21, reason, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 21)
        }
        sqlite3_bind_int(statement, 22, entry.isSelfThread ? 1 : 0)
        sqlite3_bind_int(statement, 23, entry.isAllMine ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
    }

    public func batches(since: Date, pinningLatestOf chatIds: Set<Int>) -> HistoryWindow {
        guard let db = open() else { return HistoryWindow(batches: [], pinned: []) }
        defer { sqlite3_close(db) }
        // Timestamps are stored as UTC ISO 8601 text, which sorts the same
        // way the moments do, so a text comparison is a time comparison.
        let sinceText = dateFormatter.string(from: since)
        var rows: [HistoryEntry] = []
        let clause = """
        source_ref IN (SELECT source_ref FROM history_entries WHERE timestamp >= ?1 AND source_ref IS NOT NULL)
            OR (source_ref IS NULL AND timestamp >= ?1)
        ORDER BY timestamp, rowid
        """
        select(db, where: clause, bind: { sqlite3_bind_text($0, 1, sinceText, -1, sqliteTransient) }) { rows.append($0) }
        let recent = groupHistoryIntoBatches(rows, since: since)
        let listedChats = Set(recent.compactMap(\.chatId))
        return HistoryWindow(batches: recent, pinned: latestBatches(db, forChatIds: chatIds.subtracting(listedChats)))
    }

    public func latestBatches(ofChats chatIds: Set<Int>) -> [HistoryBatch] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        return latestBatches(db, forChatIds: chatIds)
    }

    public func batches(forSourceRefs sourceRefs: Set<String>) -> [String: HistoryBatch] {
        guard !sourceRefs.isEmpty, let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var rows: [HistoryEntry] = []
        select(db, where: "source_ref IN (\(placeholders(sourceRefs.count))) ORDER BY timestamp, rowid", bind: { statement in
            for (index, ref) in sourceRefs.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), ref, -1, sqliteTransient)
            }
        }) { rows.append($0) }
        return Dictionary(uniqueKeysWithValues: groupHistoryIntoBatches(rows).map { ($0.id, $0) })
    }

    public func screeningOutcomes(questionVersion: Int) -> [ScreeningOutcome] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // The verdict is the Batch's earliest extraction or Audit Sample
        // row, so a later Re-run never replaces the judgment the cutoff is
        // measured against.
        let sql = """
        SELECT s.source_ref, s.screening_probability, (
            SELECT v.signal_count FROM history_entries v
            WHERE v.source_ref = s.source_ref AND v.kind IN ('extraction', 'audit')
            ORDER BY v.timestamp, v.rowid LIMIT 1
        )
        FROM history_entries s
        WHERE s.kind = 'screening' AND s.source_ref IS NOT NULL AND s.screening_question_version = ?
        ORDER BY s.timestamp, s.rowid
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(questionVersion))
        var seen: Set<String> = []
        var outcomes: [ScreeningOutcome] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let ref = text(statement!, 0), seen.insert(ref).inserted else { continue }
            let verdict = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 2) > 0
            outcomes.append(ScreeningOutcome(
                sourceRef: ref, probability: sqlite3_column_double(statement, 1), modelFoundTask: verdict
            ))
        }
        return outcomes
    }

    public func evaluationRows(limit: Int) -> [HistoryEntry] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let bindLimit: (OpaquePointer?) -> Void = { sqlite3_bind_int($0, 1, Int32(clamping: limit)) }
        var rows: [HistoryEntry] = []
        select(db, where: "is_starred = 1 ORDER BY timestamp DESC, rowid DESC LIMIT ?", bind: bindLimit) { rows.append($0) }
        guard rows.isEmpty else { return rows }
        select(db, where: "kind = 'extraction' ORDER BY timestamp DESC, rowid DESC LIMIT ?", bind: bindLimit) { rows.append($0) }
        return rows
    }

    public func setStarred(_ isStarred: Bool, id: String) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE history_entries SET is_starred = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        sqlite3_bind_int(statement, 1, isStarred ? 1 : 0)
        sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
        guard sqlite3_changes(db) > 0 else { throw HistoryStoreError.entryNotFound(id: id) }
    }

    public func delete(id: String) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM history_entries WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
        guard sqlite3_changes(db) > 0 else { throw HistoryStoreError.entryNotFound(id: id) }
    }

    public func fillDisplay(id: String, from subject: HistorySubject) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Every expression reads the row as it was before this update, so
        // the two facts are only set on a row that had no display yet.
        let sql = """
        UPDATE history_entries
        SET sender = COALESCE(sender, ?), chat_title = COALESCE(chat_title, ?), transcript = COALESCE(transcript, ?),
            source_ref = COALESCE(source_ref, ?),
            is_self_thread = CASE WHEN sender IS NULL AND is_all_mine = 0 THEN ? ELSE is_self_thread END,
            is_all_mine = CASE WHEN sender IS NULL AND is_all_mine = 0 THEN ? ELSE is_all_mine END
        WHERE id = ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw HistoryStoreError.writeFailed }
        bindOptionalText(statement, 1, subject.sender)
        bindOptionalText(statement, 2, subject.chatTitle)
        bindOptionalText(statement, 3, subject.transcript.flatMap(encodeTranscript))
        bindOptionalText(statement, 4, subject.sourceRef)
        sqlite3_bind_int(statement, 5, subject.isSelfThread ? 1 : 0)
        sqlite3_bind_int(statement, 6, subject.isAllMine ? 1 : 0)
        sqlite3_bind_text(statement, 7, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
    }

    public func delete(sourceRef: String) throws {
        guard let db = open() else { throw HistoryStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM history_entries WHERE source_ref = ?", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, sourceRef, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.writeFailed }
    }

    /// The newest Batch of each of `chatIds`, however old, with all its rows.
    private func latestBatches(_ db: OpaquePointer, forChatIds chatIds: Set<Int>) -> [HistoryBatch] {
        guard !chatIds.isEmpty else { return [] }
        // Newest first, so the first row seen for a Chat is its latest.
        var latest: [Int: HistoryEntry] = [:]
        select(db, where: "chat_id IN (\(placeholders(chatIds.count))) ORDER BY timestamp DESC, rowid DESC", bind: { statement in
            for (index, chatId) in chatIds.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), Int64(chatId))
            }
        }) { entry in
            guard let chatId = entry.chatId, latest[chatId] == nil else { return }
            latest[chatId] = entry
        }
        // A legacy row has no Batch to widen to; it stands alone.
        var rows = latest.values.filter { $0.sourceRef == nil }
        let refs = latest.values.compactMap(\.sourceRef)
        if !refs.isEmpty {
            select(db, where: "source_ref IN (\(placeholders(refs.count))) ORDER BY timestamp, rowid", bind: { statement in
                for (index, ref) in refs.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), ref, -1, sqliteTransient)
                }
            }) { rows.append($0) }
        }
        return groupHistoryIntoBatches(rows)
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func select(
        _ db: OpaquePointer, where clause: String, bind: (OpaquePointer?) -> Void, each: (HistoryEntry) -> Void
    ) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT \(Self.columns) FROM history_entries WHERE \(clause)", -1, &statement, nil) == SQLITE_OK
        else { return }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = readEntry(statement!) { each(entry) }
        }
    }

    private func readEntry(_ statement: OpaquePointer) -> HistoryEntry? {
        guard
            let id = text(statement, 0),
            let timestampText = text(statement, 1),
            let timestamp = dateFormatter.date(from: timestampText),
            let sourceRawText = text(statement, 2),
            let rawOutput = text(statement, 3),
            let modelUsed = text(statement, 4)
        else { return nil }
        let signalCount = Int(sqlite3_column_int(statement, 5))
        let isStarred = sqlite3_column_int(statement, 6) != 0
        // `NULL` only for a row written before this column existed — the
        // migration adds it with no backfill (see `chatId`'s own doc
        // comment) — never a sentinel value standing in for "no chat".
        let chatId: Int? = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7))
        // A row written before `rendered_context` existed has `NULL` there
        // (the migration below adds the column with no backfill) — falling
        // back to `sourceRawText`, the same default the initializer itself
        // uses, rather than surfacing an empty string for old rows.
        let renderedContext = text(statement, 8) ?? sourceRawText
        let sourceRef = text(statement, 10)
        // Typed since the typed-fields migration: a row whose fields don't
        // make a kind is unreadable, never guessed at.
        let kind: HistoryEntryKind
        switch text(statement, 9) {
        case "extraction": kind = .extraction
        case "audit": kind = .audit
        case "rerun": kind = .rerun
        case "screening_unavailable": kind = .screeningUnavailable
        case "screening_failed":
            guard let reason = text(statement, 20) else { return nil }
            kind = .screeningFailed(reason: reason)
        case "screening":
            guard sqlite3_column_type(statement, 11) != SQLITE_NULL, sqlite3_column_type(statement, 16) != SQLITE_NULL
            else { return nil }
            let cutoff = sqlite3_column_type(statement, 19) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 19)
            guard let mode = ScreeningDecision.Mode(storageName: text(statement, 18), cutoff: cutoff) else { return nil }
            kind = .screening(ScreeningDecision(
                probability: sqlite3_column_double(statement, 11), mode: mode,
                questionVersion: Int(sqlite3_column_int(statement, 16))
            ))
        default:
            return nil
        }
        return HistoryEntry(
            id: id, timestamp: timestamp, sourceRawText: sourceRawText, rawOutput: rawOutput,
            modelUsed: modelUsed, signalCount: signalCount, isStarred: isStarred, chatId: chatId,
            renderedContext: renderedContext, kind: kind, sourceRef: sourceRef,
            sender: text(statement, 13), transcript: text(statement, 14).flatMap(decodeTranscript),
            chatTitle: text(statement, 15), chatIdentifier: text(statement, 17),
            isSelfThread: sqlite3_column_int(statement, 21) != 0, isAllMine: sqlite3_column_int(statement, 22) != 0
        )
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func encodeTranscript(_ lines: [HistoryTranscriptLine]) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(lines)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decodeTranscript(_ json: String) -> [HistoryTranscriptLine]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([HistoryTranscriptLine].self, from: Data(json.utf8))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
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

    /// The table as it stands now. A database from before a column existed
    /// gains it through `addColumnIfMissing`, and the typed-fields migration
    /// rebuilds it into this shape so `kind` is required.
    private static func tableDefinition(named name: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(name) (
            id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            source_raw_text TEXT NOT NULL,
            raw_output TEXT NOT NULL,
            model_used TEXT NOT NULL,
            signal_count INTEGER NOT NULL,
            is_starred INTEGER NOT NULL,
            chat_id INTEGER,
            rendered_context TEXT,
            kind TEXT NOT NULL,
            source_ref TEXT,
            screening_probability REAL,
            was_screened INTEGER,
            sender TEXT,
            transcript TEXT,
            chat_title TEXT,
            screening_question_version INTEGER,
            chat_identifier TEXT,
            screening_mode TEXT,
            screening_cutoff REAL,
            failure_reason TEXT,
            is_self_thread INTEGER NOT NULL DEFAULT 0,
            is_all_mine INTEGER NOT NULL DEFAULT 0
        )
        """
    }

    private func createSchemaIfNeeded(_ db: OpaquePointer) -> Bool {
        let sql = """
        \(Self.tableDefinition(named: "history_entries"));
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return false }
        // Every column after the first seven was added after the table first
        // shipped — see `SQLiteSignalStore`'s own `addColumnIfMissing` for
        // why this migrates an older database non-destructively rather than
        // requiring a fresh install.
        let added = [
            ("chat_id", "INTEGER"), ("rendered_context", "TEXT"), ("kind", "TEXT"), ("source_ref", "TEXT"),
            ("screening_probability", "REAL"), ("was_screened", "INTEGER"), ("sender", "TEXT"), ("transcript", "TEXT"),
            ("chat_title", "TEXT"), ("screening_question_version", "INTEGER"), ("chat_identifier", "TEXT"),
            ("screening_mode", "TEXT"), ("screening_cutoff", "REAL"), ("failure_reason", "TEXT"),
            ("is_self_thread", "INTEGER NOT NULL DEFAULT 0"), ("is_all_mine", "INTEGER NOT NULL DEFAULT 0"),
        ]
        guard added.allSatisfy({ addColumnIfMissing(db, table: "history_entries", column: $0.0, type: $0.1) }) else {
            return false
        }
        guard migrateToTypedFieldsIfNeeded(db) else { return false }
        // After the migration, whose rebuild drops the table's indexes.
        let indexes = """
        CREATE INDEX IF NOT EXISTS history_entries_timestamp ON history_entries (timestamp DESC);
        CREATE INDEX IF NOT EXISTS history_entries_source_ref ON history_entries (source_ref);
        """
        return sqlite3_exec(db, indexes, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - The typed-fields migration

    /// Runs once per database, recorded in `meta`. Before it, a Screening
    /// decision's mode and cutoff lived only in its summary text, a
    /// Screening failure's reason behind a text prefix, and rows written
    /// before Screening existed had no `kind`. A Self-thread row was known
    /// only by its stored title, "Self-thread", and a row whose messages
    /// were all yours with nobody else in the Chat by its Sender, "You".
    /// This reads each of those once into its own column, then rebuilds the
    /// table so `kind` is required. Nothing reads the text back afterwards. Every step leaves
    /// an already-migrated row as it is, so running it again changes
    /// nothing.
    private func migrateToTypedFieldsIfNeeded(_ db: OpaquePointer) -> Bool {
        guard metaValue(db, key: Self.typedFieldsMigrationKey) == nil else { return true }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        guard migrateToTypedFields(db) else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        return sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
    }

    private func migrateToTypedFields(_ db: OpaquePointer) -> Bool {
        // Live summaries name their cutoff ("Screened: 0.12, below cutoff
        // 0.40", "Let through: 0.62, cutoff 0.40"); shadow ones never did
        // ("Screening: 0.31, shadow (not dropped)", later "(sent on to the
        // model)").
        let screenings = rows(db, "SELECT id, raw_output FROM history_entries WHERE kind = 'screening' AND screening_mode IS NULL")
        for (id, summary) in screenings {
            let cutoff = summary.firstMatch(of: /cutoff (\d+(?:\.\d+)?)/).flatMap { Double($0.1) }
            guard execute(
                db, "UPDATE history_entries SET screening_mode = ?, screening_cutoff = ? WHERE id = ?",
                [(cutoff.map { ScreeningDecision.Mode.live(cutoff: $0) } ?? .shadow).storageName, cutoff, id]
            ) else { return false }
        }
        let failures = rows(db, "SELECT id, raw_output FROM history_entries WHERE kind = 'screening_failed' AND failure_reason IS NULL")
        for (id, output) in failures {
            let reason = output.hasPrefix(screeningFailurePrefix) ? String(output.dropFirst(screeningFailurePrefix.count)) : output
            guard execute(db, "UPDATE history_entries SET failure_reason = ? WHERE id = ?", [reason, id]) else { return false }
        }
        let statements = [
            // Scored before question versions were recorded, all under the
            // first wording.
            "UPDATE history_entries SET screening_question_version = 1 WHERE kind = 'screening' AND screening_question_version IS NULL",
            // Written before Screening existed, when every row was a model call.
            "UPDATE history_entries SET kind = 'extraction' WHERE kind IS NULL",
            // The title and the Sender are worked out when a row is read now.
            "UPDATE history_entries SET is_self_thread = 1, chat_title = NULL WHERE chat_title = 'Self-thread'",
            "UPDATE history_entries SET is_all_mine = 1, sender = NULL WHERE sender = 'You'",
        ]
        guard statements.allSatisfy({ sqlite3_exec(db, $0, nil, nil, nil) == SQLITE_OK }) else { return false }
        guard kindIsRequired(db) || rebuildTable(db) else { return false }
        return execute(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [Self.typedFieldsMigrationKey, "1"])
    }

    /// SQLite can't add `NOT NULL` to an existing column, so the table is
    /// copied into a new one of the current shape.
    private func rebuildTable(_ db: OpaquePointer) -> Bool {
        let columns = Self.columns
        let sql = """
        \(Self.tableDefinition(named: "history_entries_rebuilt"));
        INSERT INTO history_entries_rebuilt (\(columns)) SELECT \(columns) FROM history_entries;
        DROP TABLE history_entries;
        ALTER TABLE history_entries_rebuilt RENAME TO history_entries;
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func kindIsRequired(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(history_entries)", -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement!, 1) == "kind" { return sqlite3_column_int(statement, 3) != 0 }
        }
        return false
    }

    private func metaValue(_ db: OpaquePointer, key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement!, 0) : nil
    }

    /// Two text columns from every row `sql` selects.
    private func rows(_ db: OpaquePointer, _ sql: String) -> [(String, String)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var results: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let first = text(statement!, 0), let second = text(statement!, 1) { results.append((first, second)) }
        }
        return results
    }

    /// Runs `sql` with `values` bound in order: text, a number, or NULL.
    private func execute(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let number as Double: sqlite3_bind_double(statement, index, number)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            default: sqlite3_bind_null(statement, index)
            }
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// This SQLite build's `ALTER TABLE ... ADD COLUMN` has no
    /// `IF NOT EXISTS` clause — see `SQLiteSignalStore.addColumnIfMissing`'s
    /// own doc comment — so the check is done by hand against
    /// `PRAGMA table_info` instead, the same way that one is.
    private func addColumnIfMissing(_ db: OpaquePointer, table: String, column: String, type: String) -> Bool {
        guard !columnExists(db, table: table, column: column) else { return true }
        return sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(type)", nil, nil, nil) == SQLITE_OK
    }

    private func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement!, 1), name == column {
                return true
            }
        }
        return false
    }
}
