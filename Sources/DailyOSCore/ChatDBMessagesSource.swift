import Foundation
import SQLite3

/// Production `MessagesSource`, backed by direct SQLite against `chat.db`.
/// Opens read-only, makes no copy of the file, and never sets
/// `immutable=1` (wrong here: `chat.db` is written to constantly, and an
/// immutable assertion that turns out false can produce corrupt results).
///
/// `@unchecked Sendable`: this type has no mutable stored state after
/// init — every method opens and closes its own connection.
public final class ChatDBMessagesSource: MessagesSource, @unchecked Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// Whether the database can actually be opened and queried right now.
    /// There is no programmatic Full Disk Access request the way EventKit
    /// has one for Reminders — the only way to know is to try, since a
    /// missing grant surfaces as an open or read failure, not a distinct
    /// error the OS announces in advance.
    public func canOpen() -> Bool {
        guard let db = openReadOnly(path: path) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM message LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        let stepResult = sqlite3_step(statement)
        return stepResult == SQLITE_ROW || stepResult == SQLITE_DONE
    }

    /// `MessagesSource.availability()`: one line over the pure, tested
    /// mapping. Stays as cheap as `canOpen()` because ticket 10 calls it
    /// twice around every read, before and after, to catch a grant pulled
    /// by hand mid-read.
    public func availability() -> SourceAvailability {
        messagesAvailability(canOpen: canOpen())
    }

    /// ADR 0007: every Chat, not only the self-thread. Fetches broadly (the
    /// same "no SQL date filter, window in Swift" posture the self-thread
    /// read already took) and applies `shouldIncludeMessage` per row —
    /// self-chats dedupe to sent-only, everything else keeps both
    /// directions bounded by `nonSelfCutoff`, and an excluded Chat (Automated,
    /// ticket 02) drops out regardless of direction or date.
    public func listMessages(excludingChatIds: Set<Int>, nonSelfCutoff: Date) -> [ChatMessage] {
        guard let db = openReadOnly(path: path) else { return [] }
        defer { sqlite3_close(db) }

        let hasAttributedBody = tableColumns(db, table: "message").contains("attributedBody")
        let ownAddresses = fetchOwnAddresses(db)
        let chats = fetchChatIdentifiers(db)
        let selfIds = Set(DailyOSCore.selfChatIds(ownAddresses: ownAddresses, chats: chats))
        let chatIdentifiersById = Dictionary(uniqueKeysWithValues: chats.map { ($0.chatId, $0.identifier) })
        let participantCounts = fetchParticipantCounts(db)

        let raw = fetchMessages(
            db, hasAttributedBody: hasAttributedBody,
            chatIdentifiers: chatIdentifiersById, participantCounts: participantCounts, chatNames: fetchChatNames(db)
        )
        let included = raw.filter {
            shouldIncludeMessage(
                chatId: $0.chatId,
                isFromMe: $0.isFromMe,
                createdAt: $0.createdAt,
                selfChatIds: selfIds,
                excludedChatIds: excludingChatIds,
                nonSelfCutoff: nonSelfCutoff
            )
        }
        return flagSelfThread(included, selfChatIds: selfIds)
    }

    public func selfChatIds() -> Set<Int> {
        guard let db = openReadOnly(path: path) else { return [] }
        defer { sqlite3_close(db) }
        return Set(DailyOSCore.selfChatIds(ownAddresses: fetchOwnAddresses(db), chats: fetchChatIdentifiers(db)))
    }

    /// Your Self-thread's address, where the Morning Brief goes (ADR 0046).
    /// `nil` without Full Disk Access or without a conversation with yourself.
    public func selfThreadAddress() -> String? {
        guard let db = openReadOnly(path: path) else { return nil }
        defer { sqlite3_close(db) }
        var chats: [(identifier: String, lastMessageAt: Date?)] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT c.chat_identifier, MAX(m.date) FROM chat c
        LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        LEFT JOIN message m ON m.ROWID = cmj.message_id
        WHERE c.chat_identifier IS NOT NULL
        GROUP BY c.ROWID
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = sqlite3_column_text(statement, 0) else { continue }
            let lastMessageAt = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil : epochDate(fromCoreDataValue: sqlite3_column_int64(statement, 1))
            chats.append((String(cString: identifier), lastMessageAt))
        }
        return DailyOSCore.selfThreadAddress(ownAddresses: fetchOwnAddresses(db), chats: chats)
    }

    private func openReadOnly(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    /// The capability probe: schemas vary independently of OS release, so
    /// compose the query from what actually exists rather than assuming a
    /// fixed shape.
    private func tableColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var columns = Set<String>()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return columns
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private func fetchOwnAddresses(_ db: OpaquePointer) -> [String] {
        var results: [String] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT DISTINCT destination_caller_id FROM message
        WHERE is_from_me = 1 AND destination_caller_id IS NOT NULL
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }

    /// Deep Linking (ticket 02): how many distinct handles `chat_handle_join`
    /// lists per Chat — `resolveChatIdentifier`'s input for telling a group
    /// Chat apart from a one-to-one one. A Chat with no rows here (a
    /// self-chat, which has no second party) is absent from the result
    /// entirely rather than present with a zero count; callers already treat
    /// a missing key as zero.
    private func fetchParticipantCounts(_ db: OpaquePointer) -> [Int: Int] {
        var results: [Int: Int] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT chat_id, COUNT(*) FROM chat_handle_join GROUP BY chat_id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }
        while sqlite3_step(statement) == SQLITE_ROW {
            let chatId = Int(sqlite3_column_int64(statement, 0))
            let count = Int(sqlite3_column_int64(statement, 1))
            results[chatId] = count
        }
        return results
    }

    /// Every named Chat's name (`chat.display_name`). Only group Chats get
    /// one; an unnamed Chat stores an empty string, left out here.
    private func fetchChatNames(_ db: OpaquePointer) -> [Int: String] {
        var results: [Int: String] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT ROWID, display_name FROM chat WHERE display_name IS NOT NULL AND display_name != ''"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                results[Int(sqlite3_column_int64(statement, 0))] = String(cString: name)
            }
        }
        return results
    }

    private func fetchChatIdentifiers(_ db: OpaquePointer) -> [(chatId: Int, identifier: String)] {
        var results: [(Int, String)] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT ROWID, chat_identifier FROM chat WHERE chat_identifier IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }
        while sqlite3_step(statement) == SQLITE_ROW {
            let chatId = Int(sqlite3_column_int64(statement, 0))
            if let identifier = sqlite3_column_text(statement, 1) {
                results.append((chatId, String(cString: identifier)))
            }
        }
        return results
    }

    /// Every Chat, every direction — `shouldIncludeMessage` does the
    /// narrowing afterward, in Swift, the same division of labor
    /// `listMessages` already used for the self-thread-only read this
    /// replaces. Excludes: announcements (`item_type` non-zero), tapbacks
    /// (`associated_message_type` outside 0/2/3), empty rows,
    /// unsent/retracted messages, recently-deleted rows (via
    /// `chat_recoverable_message_join`), and bare pasted links that became
    /// a rich URL balloon rather than typed text (`balloon_bundle_id`).
    ///
    /// Sender attribution (tickets 02/03): `handle.id` via `m.handle_id`
    /// is `chat.db`'s own per-message sender — the same join resolves a
    /// 1:1 Chat and a group Chat identically, since a received message's
    /// `handle_id` always names its actual sender regardless of how many
    /// other participants the Chat has. A message the user sent leaves
    /// `handle_id` null (Messages never attributes an outgoing message to a
    /// handle), so the `LEFT JOIN` naturally yields no sender address for
    /// it.
    private func fetchMessages(
        _ db: OpaquePointer,
        hasAttributedBody: Bool,
        chatIdentifiers: [Int: String],
        participantCounts: [Int: Int],
        chatNames: [Int: String]
    ) -> [ChatMessage] {
        let attributedBodySelect = hasAttributedBody ? "m.attributedBody" : "NULL"

        let sql = """
        SELECT m.ROWID, cmj.chat_id, m.is_from_me, m.text, \(attributedBodySelect), m.date, h.id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID NOT IN (SELECT message_id FROM chat_recoverable_message_join)
          AND m.item_type = 0
          AND m.associated_message_type IN (0, 2, 3)
          AND m.is_empty = 0
          AND m.date_retracted = 0
          AND m.balloon_bundle_id IS NULL
        ORDER BY m.date DESC
        """

        var results: [ChatMessage] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return results }

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(statement, 0)
            let chatId = Int(sqlite3_column_int64(statement, 1))
            let isFromMe = sqlite3_column_int(statement, 2) != 0
            let plainText = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let blobPointer = sqlite3_column_blob(statement, 4)
            let blobLength = sqlite3_column_bytes(statement, 4)
            let rawDate = sqlite3_column_int64(statement, 5)
            let senderAddress = sqlite3_column_text(statement, 6).map { String(cString: $0) }

            // attributedBody first, text second: current macOS leaves
            // `text` null and writes the body into attributedBody instead.
            let decodedFromBlob: String? = {
                guard let blobPointer, blobLength > 0 else { return nil }
                let data = Data(bytes: blobPointer, count: Int(blobLength))
                return decodeAttributedBody(data)
            }()

            guard let text = decodedFromBlob ?? plainText, !text.isEmpty else {
                logUndecodable(rowid: rowid, byteLength: Int(blobLength))
                continue
            }

            results.append(ChatMessage(
                id: String(rowid),
                chatId: chatId,
                isFromMe: isFromMe,
                text: text,
                createdAt: epochDate(fromCoreDataValue: rawDate),
                senderAddress: isFromMe ? nil : senderAddress,
                chatIdentifier: resolveChatIdentifier(
                    forChatId: chatId, chatIdentifiers: chatIdentifiers, participantCounts: participantCounts
                ),
                chatName: chatNames[chatId],
                isGroupChat: (participantCounts[chatId] ?? 0) > 1
            ))
        }
        return results
    }

    /// `true` covers both ways a message vanishes that a WHERE clause on a
    /// bulk fetch can't tell apart from "genuinely deleted": unsent
    /// (`date_retracted` set) and recoverably deleted (present in
    /// `chat_recoverable_message_join`) — the same two conditions
    /// `fetchMessages`'s own predicate already excludes on, aimed here at
    /// one row instead of all of them. A row missing from `message`
    /// entirely is the third, genuine-delete case. `nil` means the lookup
    /// itself failed (can't open the database, or the sourceRef isn't a
    /// valid ROWID) — never treated as confirmation by a caller.
    public func isGone(sourceRef: String) -> Bool? {
        guard let rowid = Int64(sourceRef) else { return nil }
        guard let db = openReadOnly(path: path) else { return nil }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT m.date_retracted,
               EXISTS (SELECT 1 FROM chat_recoverable_message_join WHERE message_id = m.ROWID)
        FROM message m WHERE m.ROWID = ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, rowid)

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            // SQLITE_DONE with no row: the ROWID doesn't exist at all —
            // genuinely deleted. Anything else is a query failure, not a
            // confirmation.
            return stepResult == SQLITE_DONE ? true : nil
        }

        let retracted = sqlite3_column_int64(statement, 0) != 0
        let recoverablyDeleted = sqlite3_column_int(statement, 1) != 0
        return retracted || recoverablyDeleted
    }

    private func logUndecodable(rowid: Int64, byteLength: Int) {
        let message = "DailyOS: dropped undecodable message rowid=\(rowid) attributedBody bytes=\(byteLength)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
