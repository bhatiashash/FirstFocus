import Foundation
import SQLite3

public struct FeedbackSnapshot: Equatable, Sendable {
    let revision: Int64
    let correctionExists: Bool
    let owner: String?
}

public enum FeedbackError: Error {
    case unavailable
    case stale
}

public struct BatchFeedback: Sendable {
    private let corrections: SQLiteCorrectionStore

    public init(path: String) {
        self.corrections = SQLiteCorrectionStore(path: path)
    }

    private func openFeedback() throws -> OpaquePointer {
        guard let signals = SQLiteSignalStore(path: corrections.path).open() else { throw FeedbackError.unavailable }
        sqlite3_close(signals)
        guard let database = corrections.open() else { throw FeedbackError.unavailable }
        guard SQLite.addColumnIfMissing(database, table: "corrections", column: "feedback_owner", type: "TEXT") else {
            sqlite3_close(database)
            throw FeedbackError.unavailable
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS feedback_revisions (source_ref TEXT PRIMARY KEY, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS feedback_dismissals (signal_id TEXT PRIMARY KEY, owner TEXT NOT NULL);
        CREATE TRIGGER IF NOT EXISTS feedback_signal_updated AFTER UPDATE ON signals BEGIN
            DELETE FROM feedback_dismissals WHERE signal_id = OLD.id;
            INSERT INTO feedback_revisions VALUES (OLD.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS feedback_signal_deleted AFTER DELETE ON signals BEGIN
            DELETE FROM feedback_dismissals WHERE signal_id = OLD.id;
            INSERT INTO feedback_revisions VALUES (OLD.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS feedback_signal_inserted AFTER INSERT ON signals BEGIN
            DELETE FROM feedback_dismissals WHERE signal_id = NEW.id;
            INSERT INTO feedback_revisions VALUES (NEW.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS feedback_correction_inserted AFTER INSERT ON corrections WHEN NEW.source_ref IS NOT NULL BEGIN
            INSERT INTO feedback_revisions VALUES (NEW.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS feedback_correction_deleted AFTER DELETE ON corrections WHEN OLD.source_ref IS NOT NULL BEGIN
            INSERT INTO feedback_revisions VALUES (OLD.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS feedback_correction_updated AFTER UPDATE ON corrections WHEN NEW.source_ref IS NOT NULL BEGIN
            INSERT INTO feedback_revisions VALUES (NEW.source_ref, 1)
                ON CONFLICT(source_ref) DO UPDATE SET revision = revision + 1;
        END;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw FeedbackError.unavailable
        }
        return database
    }

    private func snapshot(_ database: OpaquePointer, sourceRef: String) throws -> FeedbackSnapshot {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT COALESCE((SELECT revision FROM feedback_revisions WHERE source_ref = ?), 0),
            EXISTS(SELECT 1 FROM corrections WHERE source_ref = ? AND correction_type = 'false_positive'),
            (SELECT feedback_owner FROM corrections WHERE source_ref = ? AND correction_type = 'false_positive')
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FeedbackError.unavailable
        }
        for index in 1...3 { sqlite3_bind_text(statement, Int32(index), sourceRef, -1, sqliteTransient) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FeedbackError.unavailable }
        return FeedbackSnapshot(
            revision: sqlite3_column_int64(statement, 0), correctionExists: sqlite3_column_int(statement, 1) != 0,
            owner: columnText(statement, 2)
        )
    }

    public func feedbackSnapshot(sourceRef: String) throws -> FeedbackSnapshot {
        let database = try openFeedback()
        defer { sqlite3_close(database) }
        return try snapshot(database, sourceRef: sourceRef)
    }

    public func markNotForMe(_ entry: HistoryEntry, expecting expected: FeedbackSnapshot) throws -> FeedbackSnapshot {
        guard let sourceRef = entry.sourceRef, let chatId = entry.chatId else { throw FeedbackError.stale }
        let database = try openFeedback()
        defer { sqlite3_close(database) }
        return try SQLite.inTransaction(database, failure: SignalStoreError.writeFailed) {
            guard try snapshot(database, sourceRef: sourceRef) == expected, !expected.correctionExists else {
                throw FeedbackError.stale
            }
            let owner = UUID().uuidString
            try corrections.insert(Correction(
                chatId: chatId, sourceRef: sourceRef, inputText: exampleInput(fromPrompt: entry.renderedContext),
                correctedOutput: "NONE", correctionType: .falsePositive
            ), into: database)
            try corrections.execute(database, "UPDATE corrections SET feedback_owner = ? WHERE source_ref = ? AND correction_type = 'false_positive'") {
                sqlite3_bind_text($0, 1, owner, -1, sqliteTransient)
                sqlite3_bind_text($0, 2, sourceRef, -1, sqliteTransient)
            }
            let ids = try feedbackSignalIDs(database, sql: "SELECT id FROM signals WHERE source_ref = ? AND state = 'open' AND provenance = 'inferred'", value: sourceRef)
            for id in ids {
                try corrections.execute(database, "UPDATE signals SET state = 'dismissed', state_at = ?, dismissed_by_not_for_me = 1 WHERE id = ? AND state = 'open'") {
                    sqlite3_bind_text($0, 1, ISO8601DateFormatter().string(from: Date()), -1, sqliteTransient)
                    sqlite3_bind_text($0, 2, id, -1, sqliteTransient)
                }
                try corrections.execute(database, "INSERT INTO feedback_dismissals (signal_id, owner) VALUES (?, ?)") {
                    sqlite3_bind_text($0, 1, id, -1, sqliteTransient)
                    sqlite3_bind_text($0, 2, owner, -1, sqliteTransient)
                }
            }
            return try snapshot(database, sourceRef: sourceRef)
        }
    }

    public func undoNotForMe(sourceRef: String, owning expected: FeedbackSnapshot) throws -> [String] {
        let database = try openFeedback()
        defer { sqlite3_close(database) }
        return try SQLite.inTransaction(database, failure: SignalStoreError.writeFailed) {
            let current = try snapshot(database, sourceRef: sourceRef)
            guard current.correctionExists, expected.correctionExists, current.owner == expected.owner,
                  current.owner != nil || current.revision == expected.revision else { throw FeedbackError.stale }
            let sql: String
            let value: String
            if let owner = expected.owner {
                sql = "SELECT s.id FROM signals s JOIN feedback_dismissals d ON d.signal_id = s.id WHERE s.state = 'dismissed' AND d.owner = ?"
                value = owner
            } else {
                sql = "SELECT id FROM signals WHERE source_ref = ? AND state = 'dismissed' AND dismissed_by_not_for_me = 1 AND id NOT IN (SELECT signal_id FROM feedback_dismissals)"
                value = sourceRef
            }
            let ids = try feedbackSignalIDs(database, sql: sql, value: value)
            try corrections.execute(database, "DELETE FROM corrections WHERE source_ref = ? AND correction_type = 'false_positive'") {
                sqlite3_bind_text($0, 1, sourceRef, -1, sqliteTransient)
            }
            for id in ids {
                try corrections.execute(database, "UPDATE signals SET state = 'open', state_at = NULL, reminder_id = NULL, dismissed_by_not_for_me = NULL WHERE id = ? AND state = 'dismissed'") {
                    sqlite3_bind_text($0, 1, id, -1, sqliteTransient)
                }
            }
            return ids
        }
    }

    private func feedbackSignalIDs(_ database: OpaquePointer, sql: String, value: String) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FeedbackError.unavailable
        }
        sqlite3_bind_text(statement, 1, value, -1, sqliteTransient)
        var ids: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let id = columnText(statement, 0) { ids.append(id) }
            case SQLITE_DONE: return ids
            default: throw FeedbackError.unavailable
            }
        }
    }
}
