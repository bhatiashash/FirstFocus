import Foundation
import SQLite3

/// Production `SignalStore`. SQLite at `~/Library/Application
/// Support/<bundle-id>/store.sqlite`, matching the app's existing
/// direct-SQLite seam (`chat.db`) rather than adding a second persistence
/// stack. Relies on Time Machine for backup; the failure mode of loss is
/// "dismissed and checked-off Messages Signals reappear," not
/// catastrophic.
///
/// `@unchecked Sendable`: no mutable stored state after init — every
/// method opens and closes its own connection, same posture as
/// `ChatDBMessagesSource`.
public final class SQLiteSignalStore: SignalStore, @unchecked Sendable {
    private let path: String

    package var databasePath: String { path }

    /// Fresh per access rather than shared state: `ISO8601DateFormatter`
    /// isn't documented safe for concurrent use, and this class's methods
    /// (each opening its own connection) may run on different threads.
    private var dateFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    public init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    public static func defaultPath(bundleIdentifier: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleIdentifier).appendingPathComponent("store.sqlite").path
    }

    public func isProcessed(sourceRef: String) -> Bool {
        rowExists("SELECT 1 FROM processed_messages WHERE source_ref = ? LIMIT 1") {
            sqlite3_bind_text($0, 1, sourceRef, -1, sqliteTransient)
        }
    }

    /// One connection for all of `sourceRefs`, asked in chunks that stay
    /// under SQLite's limit on bound variables.
    public func processedSourceRefs(among sourceRefs: [String]) -> Set<String> {
        guard !sourceRefs.isEmpty, let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var processed: Set<String> = []
        let chunkSize = 500
        for start in stride(from: 0, to: sourceRefs.count, by: chunkSize) {
            let chunk = sourceRefs[start..<min(start + chunkSize, sourceRefs.count)]
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT source_ref FROM processed_messages WHERE source_ref IN (\(placeholders))"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return processed }
            for (index, ref) in chunk.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), ref, -1, sqliteTransient)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let ref = columnText(statement!, 0) { processed.insert(ref) }
            }
        }
        return processed
    }

    public func recordProcessedBatch(_ batch: MessageBatch, signals: [Signal], superseding: [Supersession]) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }

        try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            for memberId in batch.memberIds {
                try insertProcessed(db, sourceRef: memberId)
            }
            try insertBatch(db, batch)
            for signal in signals {
                try insertSignal(db, signal)
            }
            try supersede(db, superseding, by: batch.id)
        }
    }

    public func members(ofBatch batchId: String) -> [String]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT member_ids FROM batches WHERE batch_id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, batchId, -1, sqliteTransient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return columnText(statement!, 0).map { $0.split(separator: "\n").map(String.init) }
        case SQLITE_DONE:
            // No Batch recorded: a message Processed before batching.
            return [batchId]
        default:
            return nil
        }
    }

    /// The state check lives in the `WHERE`, so it is decided at the moment
    /// of the write: a Signal Approved or Dismissed since the prompt was
    /// built simply matches no row and is left as it is. Each one that
    /// lands is also recorded against `batchId`, so History can name it.
    private func supersede(_ db: OpaquePointer, _ supersessions: [Supersession], by batchId: String) throws {
        for supersession in supersessions {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            UPDATE signals SET state = 'superseded', state_at = ?, superseded_by = ?
            WHERE id = ? AND state = 'open' AND provenance = 'inferred'
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SignalStoreError.writeFailed
            }
            sqlite3_bind_text(statement, 1, dateFormatter.string(from: Date()), -1, sqliteTransient)
            if let replacedBy = supersession.replacedBy {
                sqlite3_bind_text(statement, 2, replacedBy, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, supersession.signalId, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
            if sqlite3_changes(db) > 0 {
                try recordSupersession(db, supersession, by: batchId)
            }
        }
    }

    /// One row per Supersession that landed, never updated or removed, so
    /// a Batch still names what it Superseded after a later Batch
    /// Supersedes the same Suggestion again.
    private func recordSupersession(_ db: OpaquePointer, _ supersession: Supersession, by batchId: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO supersessions (signal_id, batch_id, replaced_by, recorded_at) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, supersession.signalId, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, batchId, -1, sqliteTransient)
        if let replacedBy = supersession.replacedBy {
            sqlite3_bind_text(statement, 3, replacedBy, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, dateFormatter.string(from: Date()), -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
    }

    public func supersessions(byBatches batchIds: [String]) -> [String: [RecordedSupersession]] {
        guard !batchIds.isEmpty, let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ", ")
        let sql = """
        SELECT r.batch_id, r.signal_id, s.label, r.replaced_by, \(supersessionStands), \(supersessionStands) AND \(replacementOpenOrDismissed)
        FROM supersessions r JOIN signals s ON s.id = r.signal_id
        WHERE r.batch_id IN (\(placeholders))
        ORDER BY r.rowid
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
        for (index, batchId) in batchIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), batchId, -1, sqliteTransient)
        }
        var results: [String: [RecordedSupersession]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let batchId = columnText(statement, 0), let signalId = columnText(statement, 1), let label = columnText(statement, 2) else {
                continue
            }
            results[batchId, default: []].append(
                RecordedSupersession(
                    signalId: signalId, label: label, replacedBy: columnText(statement, 3), stands: sqlite3_column_int(statement, 4) != 0,
                    isRestorable: sqlite3_column_int(statement, 5) != 0
                )
            )
        }
        return results
    }

    /// SQL over a supersessions row `r` joined to its Signal `s`: `s` is
    /// still Superseded, and `r`'s Batch was the last to Supersede it.
    private let supersessionStands = """
    (s.state = 'superseded' AND r.batch_id = (SELECT batch_id FROM supersessions WHERE signal_id = s.id ORDER BY rowid DESC LIMIT 1))
    """

    /// SQL over the same row: a CANCEL, or an UPDATE whose replacement is
    /// open, Dismissed, or garbage collected with its Batch.
    private let replacementOpenOrDismissed = """
    (r.replaced_by IS NULL OR COALESCE((SELECT state FROM signals WHERE id = r.replaced_by), 'dismissed') IN ('open', 'dismissed'))
    """

    /// Decided inside one transaction by the same SQL `supersessions`
    /// reads with, so an Approve or a new Supersession that lands after
    /// History was read wins, as with `supersede`.
    public func restore(signalId: String, supersededIn batchId: String) throws -> Bool {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        return try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            try restoreInTransaction(db, signalId: signalId, batchId: batchId)
        }
    }

    private func restoreInTransaction(_ db: OpaquePointer, signalId: String, batchId: String) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT r.replaced_by FROM supersessions r JOIN signals s ON s.id = r.signal_id
        WHERE r.signal_id = ? AND r.batch_id = ? AND \(supersessionStands) AND \(replacementOpenOrDismissed)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, signalId, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, batchId, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let replacedBy = columnText(statement, 0)
        try executeIn(db, "UPDATE signals SET state = 'open', state_at = NULL, superseded_by = NULL WHERE id = ?") {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }
        if let replacedBy {
            try executeIn(db, "UPDATE signals SET state = 'dismissed', state_at = ? WHERE id = ? AND state = 'open'") {
                sqlite3_bind_text($0, 1, self.dateFormatter.string(from: Date()), -1, sqliteTransient)
                sqlite3_bind_text($0, 2, replacedBy, -1, sqliteTransient)
            }
        }
        return true
    }

    /// Member ids are chat.db GUIDs, which never contain a newline, so a
    /// newline-joined column is enough; no second table is needed.
    private func insertBatch(_ db: OpaquePointer, _ batch: MessageBatch) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO batches (batch_id, chat_id, member_ids, recorded_at) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, batch.id, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, Int64(batch.chatId))
        sqlite3_bind_text(statement, 3, batch.memberIds.joined(separator: "\n"), -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, dateFormatter.string(from: Date()), -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
    }

    public func openSignals() -> [Signal] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT id, source_ref, label, original_text, created_at, due_at, priority, provenance, low_confidence, sender, chat_identifier,
            context_text, chat_id
        FROM signals WHERE state = 'open'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }

        var results: [Signal] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let signal = readOpenSignal(statement!) {
                results.append(signal)
            }
        }
        return results
    }

    public func checkOff(signalId: String) throws {
        try setState("checkedOff", forSignalId: signalId)
    }

    public func dismiss(signalId: String) throws {
        try setState("dismissed", forSignalId: signalId)
    }

    public func approve(signalId: String, reminderId: String) throws {
        try setState("approved", forSignalId: signalId, reminderId: reminderId)
    }

    public func dismissByNotForMe(signalId: String) throws {
        try execute("UPDATE signals SET state = 'dismissed', state_at = ?, reminder_id = NULL, dismissed_by_not_for_me = 1 WHERE id = ?") {
            sqlite3_bind_text($0, 1, self.dateFormatter.string(from: Date()), -1, sqliteTransient)
            sqlite3_bind_text($0, 2, signalId, -1, sqliteTransient)
        }
    }

    public func notForMeDismissals(ofBatch batchId: String) -> [String] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id FROM signals WHERE source_ref = ? AND state = 'dismissed' AND dismissed_by_not_for_me = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        sqlite3_bind_text(statement, 1, batchId, -1, sqliteTransient)
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = columnText(statement, 0) { ids.append(id) }
        }
        return ids
    }

    public func reopen(signalId: String) throws {
        let sql = """
        UPDATE signals SET state = 'open', state_at = NULL, reminder_id = NULL, dismissed_by_not_for_me = NULL
        WHERE id = ? AND state IN ('dismissed', 'approved')
        """
        try execute(sql) {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }
    }

    /// One-click promotion (ticket 05): sets a Messages Signal's priority
    /// to `.high` — never its `state`, which `setState` owns — so
    /// `tier(for:)` starts landing it in Focus on the next rank. Only ever
    /// called for a Messages Signal; a Reminders Signal's priority write
    /// goes through `TaskSource.update` instead (ADR 0009).
    public func promote(signalId: String) throws {
        try setPriority(.high, forSignalId: signalId)
    }

    public func demote(signalId: String) throws {
        try setPriority(.none, forSignalId: signalId)
    }

    private func setPriority(_ priority: Priority, forSignalId signalId: String) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE signals SET priority = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, priority.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, signalId, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
        guard sqlite3_changes(db) > 0 else { throw SignalStoreError.signalNotFound(id: signalId) }
    }

    private func setState(_ state: String, forSignalId signalId: String, reminderId: String? = nil) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE signals SET state = ?, state_at = ?, reminder_id = ?, dismissed_by_not_for_me = NULL WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, state, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, dateFormatter.string(from: Date()), -1, sqliteTransient)
        if let reminderId {
            sqlite3_bind_text(statement, 3, reminderId, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, signalId, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
        guard sqlite3_changes(db) > 0 else { throw SignalStoreError.signalNotFound(id: signalId) }
    }

    public func focusOrder(signalId: String) -> Int? {
        queryOne("SELECT position FROM focus_order WHERE signal_id = ? LIMIT 1", bind: {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }, map: { Int(sqlite3_column_int64($0, 0)) })
    }

    /// `focusOrder(signalId:)`, batched into one open/close and one query
    /// with a `WHERE ... IN (...)` clause instead of `signalIds.count`
    /// round trips — `SignalBoard.hydrate` is this store's hottest caller
    /// (every verb, every poll tick), and this is the shape it needs.
    public func focusOrders(signalIds: [String]) -> [String: Int] {
        guard !signalIds.isEmpty else { return [:] }
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: signalIds.count).joined(separator: ", ")
        guard sqlite3_prepare_v2(
            db, "SELECT signal_id, position FROM focus_order WHERE signal_id IN (\(placeholders))", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [:] }
        for (index, signalId) in signalIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), signalId, -1, sqliteTransient)
        }
        var results: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let signalId = columnText(statement, 0) {
                results[signalId] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        return results
    }

    public func setFocusOrders(_ orders: [String: Int]) throws {
        guard !orders.isEmpty else { return }
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }

        try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            for (signalId, position) in orders {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                let sql = "INSERT OR REPLACE INTO focus_order (signal_id, position) VALUES (?, ?)"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw SignalStoreError.writeFailed
                }
                sqlite3_bind_text(statement, 1, signalId, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 2, Int64(position))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
            }
        }
    }

    public func clearFocusOrder(signalId: String) throws {
        try execute("DELETE FROM focus_order WHERE signal_id = ?") {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }
    }

    public func snoozedUntil(signalId: String) -> Date? {
        queryOne("SELECT snoozed_until FROM snoozes WHERE signal_id = ? LIMIT 1", bind: {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }, map: { columnText($0, 0) }).flatMap { dateFormatter.date(from: $0) }
    }

    public func snooze(signalId: String, until: Date, dueAt: Date?) throws {
        try execute("INSERT OR REPLACE INTO snoozes (signal_id, snoozed_until, due_at) VALUES (?, ?, ?)") {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
            sqlite3_bind_text($0, 2, dateFormatter.string(from: until), -1, sqliteTransient)
            if let dueAt {
                sqlite3_bind_text($0, 3, dateFormatter.string(from: dueAt), -1, sqliteTransient)
            } else {
                sqlite3_bind_null($0, 3)
            }
        }
    }

    public func snoozedDueDates(signalIds: [String]) -> [String: Date] {
        guard !signalIds.isEmpty else { return [:] }
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: signalIds.count).joined(separator: ", ")
        guard sqlite3_prepare_v2(
            db, "SELECT signal_id, due_at FROM snoozes WHERE due_at IS NOT NULL AND signal_id IN (\(placeholders))", -1,
            &statement, nil
        ) == SQLITE_OK, let statement else { return [:] }
        for (index, signalId) in signalIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), signalId, -1, sqliteTransient)
        }
        var results: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let signalId = columnText(statement, 0), let dateText = columnText(statement, 1), let date = dateFormatter.date(from: dateText) {
                results[signalId] = date
            }
        }
        return results
    }

    public func unsnooze(signalId: String) throws {
        try execute("DELETE FROM snoozes WHERE signal_id = ?") {
            sqlite3_bind_text($0, 1, signalId, -1, sqliteTransient)
        }
    }

    public func earliestSnoozeEnd(after moment: Date) -> Date? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT snoozed_until FROM snoozes", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        var earliest: Date?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = columnText(statement, 0), let date = dateFormatter.date(from: text), date > moment else { continue }
            earliest = min(earliest ?? date, date)
        }
        return earliest
    }

    /// `snoozedUntil(signalId:)`, batched — see `focusOrders(signalIds:)`.
    public func snoozedUntils(signalIds: [String]) -> [String: Date] {
        guard !signalIds.isEmpty else { return [:] }
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: signalIds.count).joined(separator: ", ")
        guard sqlite3_prepare_v2(
            db, "SELECT signal_id, snoozed_until FROM snoozes WHERE signal_id IN (\(placeholders))", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [:] }
        for (index, signalId) in signalIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), signalId, -1, sqliteTransient)
        }
        var results: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let signalId = columnText(statement, 0), let dateText = columnText(statement, 1), let date = dateFormatter.date(from: dateText) {
                results[signalId] = date
            }
        }
        return results
    }

    public func recordExtractionFailure(_ batch: MessageBatch) throws -> Int {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        return try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            var tries = 0
            for messageId in batch.memberIds {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                let sql = """
                INSERT INTO extraction_failures (message_id, tries) VALUES (?, 1)
                ON CONFLICT(message_id) DO UPDATE SET tries = tries + 1 RETURNING tries
                """
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw SignalStoreError.writeFailed
                }
                sqlite3_bind_text(statement, 1, messageId, -1, sqliteTransient)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw SignalStoreError.writeFailed }
                tries = max(tries, Int(sqlite3_column_int64(statement, 0)))
            }
            return tries
        }
    }

    public func focusListPlacements() -> [FocusListPlacement]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT reminder_id, home_list_id, pending_from_list_id, pending_to_list_id FROM focus_list", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return nil }
        var results: [FocusListPlacement] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let reminderId = columnText(statement, 0) {
                let pending = columnText(statement, 2).flatMap { from in
                    columnText(statement, 3).map { FocusListPendingMove(fromListId: from, toListId: $0) }
                }
                results.append(FocusListPlacement(reminderId: reminderId, homeListId: columnText(statement, 1), pendingMove: pending))
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? results : nil
    }

    public func setFocusListPlacements(_ placements: [FocusListPlacement]) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }

        try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            try executeIn(db, "DELETE FROM focus_list") { _ in }
            for placement in placements {
                try executeIn(db, "INSERT OR REPLACE INTO focus_list (reminder_id, home_list_id, pending_from_list_id, pending_to_list_id) VALUES (?, ?, ?, ?)") {
                    sqlite3_bind_text($0, 1, placement.reminderId, -1, sqliteTransient)
                    if let home = placement.homeListId {
                        sqlite3_bind_text($0, 2, home, -1, sqliteTransient)
                    } else {
                        sqlite3_bind_null($0, 2)
                    }
                    if let pending = placement.pendingMove {
                        sqlite3_bind_text($0, 3, pending.fromListId, -1, sqliteTransient)
                        sqlite3_bind_text($0, 4, pending.toListId, -1, sqliteTransient)
                    } else {
                        sqlite3_bind_null($0, 3)
                        sqlite3_bind_null($0, 4)
                    }
                }
            }
        }
    }

    public func approvedSender(reminderId: String) -> String? {
        queryOne("SELECT sender FROM reminder_senders WHERE reminder_id = ? LIMIT 1", bind: {
            sqlite3_bind_text($0, 1, reminderId, -1, sqliteTransient)
        }, map: { columnText($0, 0) })
    }

    public func recordApprovedSender(reminderId: String, sender: String) throws {
        try execute("INSERT OR REPLACE INTO reminder_senders (reminder_id, sender) VALUES (?, ?)") {
            sqlite3_bind_text($0, 1, reminderId, -1, sqliteTransient)
            sqlite3_bind_text($0, 2, sender, -1, sqliteTransient)
        }
    }

    public func forgetApprovedSender(reminderId: String) throws {
        try execute("DELETE FROM reminder_senders WHERE reminder_id = ?") {
            sqlite3_bind_text($0, 1, reminderId, -1, sqliteTransient)
        }
    }

    /// `approvedSender(reminderId:)`, batched — see `focusOrders(signalIds:)`.
    public func approvedSenders(reminderIds: [String]) -> [String: String] {
        guard !reminderIds.isEmpty else { return [:] }
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: reminderIds.count).joined(separator: ", ")
        guard sqlite3_prepare_v2(
            db, "SELECT reminder_id, sender FROM reminder_senders WHERE reminder_id IN (\(placeholders))", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [:] }
        for (index, reminderId) in reminderIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), reminderId, -1, sqliteTransient)
        }
        var results: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let reminderId = columnText(statement, 0), let sender = columnText(statement, 1) {
                results[reminderId] = sender
            }
        }
        return results
    }

    public func isBackfillComplete() -> Bool {
        metaValue(forKey: "backfill_complete") != nil
    }

    public func markBackfillComplete() throws {
        try setMetaValue("1", forKey: "backfill_complete")
    }

    public func storedSigningIdentity() -> String? {
        metaValue(forKey: "signing_identity")
    }

    public func recordSigningIdentity(_ identity: String) throws {
        try setMetaValue(identity, forKey: "signing_identity")
    }

    public func batchesWithSignals() -> [String] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT source_ref FROM signals", -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let sourceRef = columnText(statement!, 0) {
                results.append(sourceRef)
            }
        }
        return results
    }

    /// Unlike `setState`, a zero-row delete isn't an error worth throwing
    /// `signalNotFound` over: `setState` targets one Signal id the caller
    /// expects to exist, but `sourceRef` here may legitimately have zero
    /// Signals already (Processed with nothing minted) — that's a no-op,
    /// not a mistake.
    public func nonSelfMessagesCutoff() -> Date? {
        metaValue(forKey: "non_self_messages_cutoff").flatMap { dateFormatter.date(from: $0) }
    }

    public func recordNonSelfMessagesCutoff(_ date: Date) throws {
        try setMetaValue(dateFormatter.string(from: date), forKey: "non_self_messages_cutoff")
    }

    public func isAutomated(chatId: Int) -> Bool {
        rowExists("SELECT 1 FROM automated_chats WHERE chat_id = ? LIMIT 1") {
            sqlite3_bind_int64($0, 1, Int64(chatId))
        }
    }

    public func markAutomated(chatId: Int) throws {
        try execute("INSERT OR IGNORE INTO automated_chats (chat_id, marked_at) VALUES (?, ?)") {
            sqlite3_bind_int64($0, 1, Int64(chatId))
            sqlite3_bind_text($0, 2, dateFormatter.string(from: Date()), -1, sqliteTransient)
        }
    }

    public func unmarkAutomated(chatId: Int) throws {
        try execute("DELETE FROM automated_chats WHERE chat_id = ?") {
            sqlite3_bind_int64($0, 1, Int64(chatId))
        }
    }

    public func automatedChatIds() -> Set<Int> {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT chat_id FROM automated_chats", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var results: Set<Int> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.insert(Int(sqlite3_column_int64(statement, 0)))
        }
        return results
    }

    public func isMuted(chatId: Int) -> Bool {
        rowExists("SELECT 1 FROM muted_chats WHERE chat_id = ? LIMIT 1") {
            sqlite3_bind_int64($0, 1, Int64(chatId))
        }
    }

    public func mutedChatIds() -> Set<Int> {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT chat_id FROM muted_chats", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var results: Set<Int> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.insert(Int(sqlite3_column_int64(statement, 0)))
        }
        return results
    }

    public func setMuted(_ isMuted: Bool, chatId: Int) throws {
        if isMuted {
            try execute("INSERT OR IGNORE INTO muted_chats (chat_id, muted_at) VALUES (?, ?)") {
                sqlite3_bind_int64($0, 1, Int64(chatId))
                sqlite3_bind_text($0, 2, dateFormatter.string(from: Date()), -1, sqliteTransient)
            }
        } else {
            try execute("DELETE FROM muted_chats WHERE chat_id = ?") {
                sqlite3_bind_int64($0, 1, Int64(chatId))
            }
        }
    }

    /// Takes the Batch's Signals' Supersessions with them. A Supersession
    /// the Batch itself recorded stays: the Suggestion it Superseded is
    /// still there to Restore.
    public func garbageCollectSignals(ofBatch batchId: String) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            try executeIn(db, "DELETE FROM supersessions WHERE signal_id IN (SELECT id FROM signals WHERE source_ref = ?)") {
                sqlite3_bind_text($0, 1, batchId, -1, sqliteTransient)
            }
            try executeIn(db, "DELETE FROM signals WHERE source_ref = ?") {
                sqlite3_bind_text($0, 1, batchId, -1, sqliteTransient)
            }
        }
    }

    /// Reads every Processed message, every Signal's state and every
    /// recorded Batch, and hands them to
    /// `reExtractionCandidates(processedRefs:signalStates:recordedBatches:)`
    /// rather than encoding ADR 0004's rule as SQL.
    public func reExtractionCandidates() -> [String] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        var processedRefs: Set<String> = []
        var processedStatement: OpaquePointer?
        defer { sqlite3_finalize(processedStatement) }
        guard sqlite3_prepare_v2(db, "SELECT source_ref FROM processed_messages", -1, &processedStatement, nil) == SQLITE_OK else {
            return []
        }
        while sqlite3_step(processedStatement) == SQLITE_ROW {
            if let sourceRef = columnText(processedStatement!, 0) {
                processedRefs.insert(sourceRef)
            }
        }

        var signalStates: [(sourceRef: String, state: SignalState)] = []
        var signalsStatement: OpaquePointer?
        defer { sqlite3_finalize(signalsStatement) }
        guard sqlite3_prepare_v2(db, "SELECT source_ref, state FROM signals", -1, &signalsStatement, nil) == SQLITE_OK else {
            return []
        }
        while sqlite3_step(signalsStatement) == SQLITE_ROW {
            guard let sourceRef = columnText(signalsStatement!, 0), let stateName = columnText(signalsStatement!, 1) else { continue }
            signalStates.append((sourceRef: sourceRef, state: placeholderState(named: stateName)))
        }

        var recordedBatches: [String: [String]] = [:]
        var batchesStatement: OpaquePointer?
        defer { sqlite3_finalize(batchesStatement) }
        guard sqlite3_prepare_v2(db, "SELECT batch_id, member_ids FROM batches", -1, &batchesStatement, nil) == SQLITE_OK else {
            return []
        }
        while sqlite3_step(batchesStatement) == SQLITE_ROW {
            guard let batchId = columnText(batchesStatement!, 0), let members = columnText(batchesStatement!, 1) else { continue }
            recordedBatches[batchId] = members.split(separator: "\n").map(String.init)
        }

        return FirstFocusCore.reExtractionCandidates(
            processedRefs: processedRefs, signalStates: signalStates, recordedBatches: recordedBatches
        )
    }

    /// `reExtractionCandidates()` above only needs to know which case a
    /// row's `state` column names — `isLiveSignalState` never looks at the
    /// associated `at`/`reminderId` values — so this fills them with
    /// throwaway placeholders rather than reading and parsing columns
    /// nothing downstream uses.
    private func placeholderState(named stateName: String) -> SignalState {
        switch stateName {
        case "checkedOff":
            return .checkedOff(at: .distantPast)
        case "dismissed":
            return .dismissed(at: .distantPast)
        case "approved":
            return .approved(reminderId: "", at: .distantPast)
        case "superseded":
            return .superseded(replacedBy: nil, at: .distantPast)
        default:
            return .open
        }
    }

    public func recordReExtractedSignals(sourceRef: String, signals: [Signal]) throws {
        guard !signals.isEmpty else { return }
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }

        try SQLite.inTransaction(db, failure: SignalStoreError.writeFailed) {
            for signal in signals {
                try insertSignal(db, signal)
            }
        }
    }

    private func metaValue(forKey key: String) -> String? {
        queryOne("SELECT value FROM meta WHERE key = ? LIMIT 1", bind: {
            sqlite3_bind_text($0, 1, key, -1, sqliteTransient)
        }, map: { columnText($0, 0) })
    }

    private func setMetaValue(_ value: String, forKey key: String) throws {
        try execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") {
            sqlite3_bind_text($0, 1, key, -1, sqliteTransient)
            sqlite3_bind_text($0, 2, value, -1, sqliteTransient)
        }
    }

    /// Whether `sql` (bound by `bind`) matches any row. Only ever used for
    /// existence checks — a `SELECT 1 ... LIMIT 1` shape, not a value read
    /// (see `queryOne` for that). Swallows a failed open/prepare into
    /// `false`, same posture as every other read in this file: this class
    /// treats a store it can't read as "nothing recorded yet," not an
    /// error worth propagating.
    private func rowExists(_ sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        bind(statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The single-row, single-value read shape repeated across this file's
    /// lookups: prepare `sql`, apply `bind`, and — if a row comes back —
    /// hand the statement to `map` for the caller to pull whichever column
    /// and type it needs. `nil` covers both "no row" and "couldn't open the
    /// store," same swallow-on-failure posture as `rowExists`.
    private func queryOne<T>(_ sql: String, bind: (OpaquePointer) -> Void, map: (OpaquePointer) -> T?) -> T? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return map(statement)
    }

    /// The single-statement write shape repeated across this file's
    /// inserts/updates/deletes that don't need `setState`/`setPriority`'s
    /// affected-rows check: prepare `sql`, apply `bind`, step once. Unlike
    /// the read helpers above, a failure here throws — a write the caller
    /// asked for and silently didn't happen is exactly the kind of failure
    /// this store doesn't swallow.
    private func execute(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db = open() else { throw SignalStoreError.cannotOpen }
        defer { sqlite3_close(db) }
        try executeIn(db, sql, bind: bind)
    }

    /// `execute` on a connection the caller already holds, inside its
    /// transaction.
    private func executeIn(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SignalStoreError.writeFailed
        }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
    }

    func open() -> OpaquePointer? {
        SQLite.open(path: path, schema: createSchemaIfNeeded)
    }

    private func createSchemaIfNeeded(_ db: OpaquePointer) -> Bool {
        let sql = """
        CREATE TABLE IF NOT EXISTS processed_messages (
            source_ref TEXT PRIMARY KEY,
            processed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS signals (
            id TEXT PRIMARY KEY,
            source_ref TEXT NOT NULL,
            label TEXT NOT NULL,
            original_text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            due_at TEXT,
            priority TEXT NOT NULL,
            provenance TEXT NOT NULL,
            state TEXT NOT NULL,
            state_at TEXT,
            low_confidence INTEGER NOT NULL,
            reminder_id TEXT
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS automated_chats (
            chat_id INTEGER PRIMARY KEY,
            marked_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS muted_chats (
            chat_id INTEGER PRIMARY KEY,
            muted_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS focus_order (
            signal_id TEXT PRIMARY KEY,
            position INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS snoozes (
            signal_id TEXT PRIMARY KEY,
            snoozed_until TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS extraction_failures (
            message_id TEXT PRIMARY KEY,
            tries INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS focus_list (
            reminder_id TEXT PRIMARY KEY,
            home_list_id TEXT,
            pending_from_list_id TEXT,
            pending_to_list_id TEXT
        );
        CREATE TABLE IF NOT EXISTS reminder_senders (
            reminder_id TEXT PRIMARY KEY,
            sender TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS batches (
            batch_id TEXT PRIMARY KEY,
            chat_id INTEGER NOT NULL,
            member_ids TEXT NOT NULL,
            recorded_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS supersessions (
            signal_id TEXT NOT NULL,
            batch_id TEXT NOT NULL,
            replaced_by TEXT,
            recorded_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS supersessions_by_batch ON supersessions (batch_id);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return false }
        // Each of these three was added to `signals` after this schema
        // first shipped — `reminder_id` for ticket 06 (the Suggested Tasks
        // Inbox), `sender` for Sender attribution (ADR 0008),
        // `chat_identifier` for Deep Linking (ticket 02) — so a database
        // created before all three landed is missing some or all of them.
        // `addColumnIfMissing` migrates each in place on open,
        // non-destructively, rather than requiring a fresh install — real
        // store files already exist on disk.
        return SQLite.addColumnIfMissing(db, table: "signals", column: "reminder_id", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "sender", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "chat_identifier", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "context_text", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "chat_id", type: "INTEGER")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "superseded_by", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "signals", column: "dismissed_by_not_for_me", type: "INTEGER")
            && SQLite.addColumnIfMissing(db, table: "snoozes", column: "due_at", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "focus_list", column: "pending_from_list_id", type: "TEXT")
            && SQLite.addColumnIfMissing(db, table: "focus_list", column: "pending_to_list_id", type: "TEXT")
    }

    /// A plain `INSERT`, not `INSERT OR REPLACE`: `source_ref`'s primary
    /// key makes a second insert for an already-Processed message fail,
    /// rolling back the whole transaction — including any `insertSignal`
    /// calls already queued in it — rather than silently minting a second
    /// Signal for the same message. Processed is meant to happen exactly
    /// once, ever (CONTEXT.md); this is the backstop if two overlapping
    /// extraction runs both pass the `isProcessed` check before either
    /// commits.
    private func insertProcessed(_ db: OpaquePointer, sourceRef: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO processed_messages (source_ref, processed_at) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, sourceRef, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, dateFormatter.string(from: Date()), -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
    }

    private func insertSignal(_ db: OpaquePointer, _ signal: Signal) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        INSERT INTO signals
            (id, source_ref, label, original_text, created_at, due_at, priority, provenance, state, state_at, low_confidence, reminder_id, sender, chat_identifier, context_text, chat_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SignalStoreError.writeFailed
        }
        sqlite3_bind_text(statement, 1, signal.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, signal.sourceRef, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, signal.label, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, signal.originalText, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, dateFormatter.string(from: signal.createdAt), -1, sqliteTransient)
        if let dueAt = signal.dueAt {
            sqlite3_bind_text(statement, 6, dateFormatter.string(from: dueAt), -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_text(statement, 7, signal.priority.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 8, signal.provenance.rawValue, -1, sqliteTransient)
        let (stateName, stateAt, reminderId) = stateColumns(signal.state)
        sqlite3_bind_text(statement, 9, stateName, -1, sqliteTransient)
        if let stateAt {
            sqlite3_bind_text(statement, 10, dateFormatter.string(from: stateAt), -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_int(statement, 11, signal.lowConfidence ? 1 : 0)
        if let reminderId {
            sqlite3_bind_text(statement, 12, reminderId, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        if let sender = signal.sender {
            sqlite3_bind_text(statement, 13, sender, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 13)
        }
        if let chatIdentifier = signal.chatIdentifier {
            sqlite3_bind_text(statement, 14, chatIdentifier, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 14)
        }
        if let contextText = signal.contextText {
            sqlite3_bind_text(statement, 15, contextText, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        if let chatId = signal.chatId {
            sqlite3_bind_int64(statement, 16, Int64(chatId))
        } else {
            sqlite3_bind_null(statement, 16)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SignalStoreError.writeFailed }
    }

    /// Only ever reads rows with `state = 'open'` (see `openSignals`'s
    /// query), so the state/state_at columns aren't selected and don't
    /// need decoding here.
    private func readOpenSignal(_ statement: OpaquePointer) -> Signal? {
        guard
            let id = columnText(statement, 0),
            let sourceRef = columnText(statement, 1),
            let label = columnText(statement, 2),
            let originalText = columnText(statement, 3),
            let createdAtText = columnText(statement, 4),
            let createdAt = dateFormatter.date(from: createdAtText),
            let priorityText = columnText(statement, 6),
            let priority = Priority(rawValue: priorityText),
            let provenanceText = columnText(statement, 7),
            let provenance = Provenance(rawValue: provenanceText)
        else { return nil }

        let dueAt = columnText(statement, 5).flatMap { dateFormatter.date(from: $0) }
        let lowConfidence = sqlite3_column_int(statement, 8) != 0
        let sender = columnText(statement, 9)
        let chatIdentifier = columnText(statement, 10)
        let contextText = columnText(statement, 11)
        let chatId = sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 12))

        return Signal(
            id: id,
            source: .messages,
            sourceRef: sourceRef,
            label: label,
            originalText: originalText,
            createdAt: createdAt,
            dueAt: dueAt,
            priority: priority,
            provenance: provenance,
            state: .open,
            lowConfidence: lowConfidence,
            sender: sender,
            chatIdentifier: chatIdentifier,
            contextText: contextText,
            chatId: chatId
        )
    }

    private func stateColumns(_ state: SignalState) -> (name: String, at: Date?, reminderId: String?) {
        switch state {
        case .open:
            return ("open", nil, nil)
        case .checkedOff(let at):
            return ("checkedOff", at, nil)
        case .dismissed(let at):
            return ("dismissed", at, nil)
        case .approved(let reminderId, let at):
            return ("approved", at, reminderId)
        case .superseded(_, let at):
            return ("superseded", at, nil)
        }
    }
}
