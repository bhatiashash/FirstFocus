import FirstFocusCore
import Foundation
import SQLite3

/// The History table as it stood before the typed-fields migration: `kind`
/// could be NULL, and a Screening row's mode, cutoff and failure reason
/// lived only in its `raw_output` text.
private let pretypedSchema = """
CREATE TABLE history_entries (
    id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, source_raw_text TEXT NOT NULL, raw_output TEXT NOT NULL,
    model_used TEXT NOT NULL, signal_count INTEGER NOT NULL, is_starred INTEGER NOT NULL,
    chat_id INTEGER, rendered_context TEXT, kind TEXT, source_ref TEXT, screening_probability REAL, was_screened INTEGER,
    sender TEXT, transcript TEXT, chat_title TEXT, screening_question_version INTEGER, chat_identifier TEXT
);
"""

/// One row in each format History has written.
private let pretypedRows = """
INSERT INTO history_entries (id, timestamp, source_raw_text, raw_output, model_used, signal_count, is_starred, chat_id, kind, source_ref,
    screening_probability, was_screened, screening_question_version) VALUES
('nokind', '2026-09-15T10:00:00Z', 'call mom', 'Call mom', 'Qwen', 1, 0, 3, NULL, NULL, NULL, NULL, NULL),
('shadowOld', '2026-09-16T10:00:00Z', 'x', 'Screening: 0.31, shadow (not dropped)', 'JEV', 0, 0, 3, 'screening', 'm1', 0.31, 0, NULL),
('shadowNew', '2026-09-17T10:00:00Z', 'x', 'Screening: 0.20, shadow (sent on to the model)', 'JEV', 0, 0, 3, 'screening', 'm2', 0.2, 0, 2),
('liveBelow', '2026-09-18T10:00:00Z', 'x', 'Screened: 0.12, below cutoff 0.40', 'JEV', 0, 0, 3, 'screening', 'm3', 0.12, 1, 2),
('liveAbove', '2026-09-19T10:00:00Z', 'x', 'Let through: 0.62, cutoff 0.45', 'JEV', 0, 0, 3, 'screening', 'm4', 0.62, 0, 2),
('failed', '2026-09-20T10:00:00Z', 'x', 'Screening failed: timed out', 'JEV', 0, 0, 3, 'screening_failed', 'm5', NULL, 0, NULL),
('rerun', '2026-09-21T10:00:00Z', 'x', 'Book it', 'Gemma', 1, 0, 3, 'rerun', 'm4', NULL, 0, NULL),
('audit', '2026-09-22T10:00:00Z', 'x', 'NONE', 'Qwen', 0, 0, 3, 'audit', 'm3', NULL, 0, NULL);
INSERT INTO history_entries (id, timestamp, source_raw_text, raw_output, model_used, signal_count, is_starred, chat_id, kind, source_ref,
    sender, chat_title) VALUES
('selfNote', '2026-09-23T10:00:00Z', 'buy milk', 'Buy milk', 'Qwen', 1, 0, 5, 'extraction', 's1', 'You', 'Self-thread'),
('allMine', '2026-09-23T11:00:00Z', 'on my way', 'NONE', 'Qwen', 0, 0, 6, 'extraction', 'y1', 'You', NULL),
('group', '2026-09-23T12:00:00Z', 'snacks?', 'NONE', 'Qwen', 0, 0, 8, 'extraction', 'g1', 'Mom', 'Book club'),
('oneToOne', '2026-09-23T13:00:00Z', 'call me', 'NONE', 'Qwen', 0, 0, 9, 'extraction', 'o1', 'Mom', NULL);
"""

/// A store file holding `pretypedRows` under the old schema, not yet
/// opened by `SQLiteHistoryStore`.
private func pretypedStore() throws -> String {
    let path = testStorePath()
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    try expect(sqlite3_open(path, &db) == SQLITE_OK)
    try expect(sqlite3_exec(db, pretypedSchema + pretypedRows, nil, nil, nil) == SQLITE_OK)
    return path
}

private func execute(_ sql: String, at path: String) throws {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    try expect(sqlite3_open(path, &db) == SQLITE_OK)
    try expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sql)
}

/// Whether the `history_entries` column `name` is declared NOT NULL.
private func isRequired(_ name: String, at path: String) throws -> Bool {
    var db: OpaquePointer?
    var statement: OpaquePointer?
    defer {
        sqlite3_finalize(statement)
        sqlite3_close(db)
    }
    try expect(sqlite3_open(path, &db) == SQLITE_OK)
    try expect(sqlite3_prepare_v2(db, "PRAGMA table_info(history_entries)", -1, &statement, nil) == SQLITE_OK)
    while sqlite3_step(statement) == SQLITE_ROW {
        if String(cString: sqlite3_column_text(statement, 1)) == name { return sqlite3_column_int(statement, 3) != 0 }
    }
    throw TestFailure(message: "no column \(name)")
}

func registerHistoryMigrationTests(_ runner: TestRunner) {
    runner.suite("History's typed-fields migration") { r in
        r.run("every format History has written reads back typed") {
            let rows = Dictionary(uniqueKeysWithValues: SQLiteHistoryStore(path: try pretypedStore()).allRows().map { ($0.id, $0) })
            try expect(rows.count == 12, "every row survives, got \(rows.keys.sorted())")
            try expect(rows["nokind"]?.kind == .extraction, "a row from before Screening is a model call")
            try expect(rows["shadowOld"]?.kind == .screening(ScreeningDecision(probability: 0.31, mode: .shadow, questionVersion: 1)))
            try expect(rows["shadowNew"]?.kind == .screening(ScreeningDecision(probability: 0.2, mode: .shadow, questionVersion: 2)))
            try expect(rows["liveBelow"]?.kind == .screening(ScreeningDecision(probability: 0.12, mode: .live(cutoff: 0.4))))
            try expect(rows["liveBelow"]?.wasScreened == true)
            try expect(rows["liveAbove"]?.kind == .screening(ScreeningDecision(probability: 0.62, mode: .live(cutoff: 0.45))))
            try expect(rows["liveAbove"]?.wasScreened == false)
            try expect(rows["failed"]?.kind == .screeningFailed(reason: "timed out"))
            try expect(rows["rerun"]?.kind == .rerun)
            try expect(rows["audit"]?.kind == .audit)
        }

        r.run("a Self-thread row and a row with a Sender of You become facts, and the list names them as before") {
            let batches = Dictionary(
                uniqueKeysWithValues: groupHistoryIntoBatches(SQLiteHistoryStore(path: try pretypedStore()).allRows()).map { ($0.id, $0) }
            )
            let selfBatch = try require(batches["s1"])
            let selfNote = selfBatch.rows[0]
            try expect(selfNote.isSelfThread && selfNote.isAllMine)
            try expect(selfNote.chatTitle == nil && selfNote.sender == nil, "no display text is stored")
            try expect(selfBatch.title == selfThreadTitle)
            try expect(selfBatch.sender == "You")
            let allMine = try require(batches["y1"])
            try expect(allMine.rows[0].isAllMine && !allMine.rows[0].isSelfThread && allMine.rows[0].sender == nil)
            try expect(allMine.title == "You", "nobody else to name")
            let group = try require(batches["g1"])
            try expect(group.title == "Book club")
            try expect(group.preview == "snacks?")
            let oneToOne = try require(batches["o1"])
            try expect(oneToOne.title == "Mom")
            try expect((group.rows + oneToOne.rows).allSatisfy { !$0.isSelfThread && !$0.isAllMine })
        }

        r.run("the summary text is kept for the Inspector and Export") {
            let rows = SQLiteHistoryStore(path: try pretypedStore()).allRows()
            try expect(rows.first { $0.id == "shadowOld" }?.rawOutput == "Screening: 0.31, shadow (not dropped)")
            try expect(rows.first { $0.id == "failed" }?.rawOutput == "Screening failed: timed out")
        }

        r.run("kind is required after the migration") {
            let path = try pretypedStore()
            let before = try isRequired("kind", at: path)
            _ = SQLiteHistoryStore(path: path).allRows()
            let after = try isRequired("kind", at: path)
            try expect(!before && after)
        }

        r.run("running it twice changes nothing") {
            let path = try pretypedStore()
            let once = SQLiteHistoryStore(path: path).allRows()
            try execute("DELETE FROM meta WHERE key = '\(SQLiteHistoryStore.typedFieldsMigrationKey)'", at: path)
            let twice = SQLiteHistoryStore(path: path).allRows()
            try expect(once == twice)
            try expect(SQLiteHistoryStore(path: path).allRows() == once)
        }

        r.run("a new store starts typed and records every kind") {
            let path = testStorePath()
            let store = SQLiteHistoryStore(path: path)
            let kinds: [HistoryEntryKind] = [
                .extraction, .audit, .rerun, .screeningFailed(reason: "timed out"),
                .screening(ScreeningDecision(probability: 0.3, mode: .shadow)),
                .screening(ScreeningDecision(probability: 0.3, mode: .live(cutoff: 0.5))),
            ]
            for kind in kinds {
                try store.record(HistoryEntry(sourceRawText: "x", modelUsed: "M", signalCount: 0, kind: kind))
            }
            let recorded = store.allRows().map(\.kind)
            try expect(recorded.count == kinds.count && kinds.allSatisfy(recorded.contains), "got \(recorded)")
            let required = try isRequired("kind", at: path)
            try expect(required)
        }
    }
}
