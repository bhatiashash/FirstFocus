import Foundation

/// Fills in Sender, Chat title and transcript on History rows recorded
/// before History kept them, from the messages an intake pass just read.
/// Without it, a week of older rows would all read "Chat not recorded"
/// until they left the list.
///
/// A row with a message id is matched to its Batch through `ledger`. A row
/// from before History kept message ids is matched by its text: the
/// latest message in its Chat with exactly that text, at or before the row.
/// Such a row also takes the matched message's id, so it can group, take
/// "Add task" and pair with other rows like any newer one. With no match,
/// the Chat's own messages still name the row, and its transcript stays
/// empty. Context is rebuilt the way Extraction builds it.
/// A field that already holds a value is never overwritten.
public func backfillHistoryDisplay(
    history: any HistoryStore,
    messages: [ChatMessage],
    ledger: any BatchLedger,
    contactsResolver: any ContactsResolver,
    since: Date
) {
    let rows = history.batches(since: since).flatMap(\.rows)
        .filter { !$0.subject.hasDisplay || $0.transcript == nil || $0.sourceRef == nil }
    guard !rows.isEmpty else { return }
    let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let byChat = Dictionary(grouping: messages, by: \.chatId).mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
    let eligible = messages.filter { !isConfidentialityTrigger($0.text) }
    var subjects: [String: HistorySubject] = [:]
    // `fillDisplay` never touches a row's source text, so the labels it
    // would be written under don't matter here.
    func subject(for batch: MessageBatch, context: [ChatMessage]) -> HistorySubject {
        HistorySubject(batch: batch, context: context, senderLabel: { _ in unknownSenderName }, contactsResolver: contactsResolver)
    }

    for row in rows {
        let batchMessages: [ChatMessage]
        if let ref = row.sourceRef {
            batchMessages = (ledger.members(ofBatch: ref) ?? []).compactMap { byId[$0] }.sorted { $0.createdAt < $1.createdAt }
        } else if let chatId = row.chatId,
                  let match = byChat[chatId]?.last(where: { $0.text == row.sourceRawText && $0.createdAt <= row.timestamp }) {
            batchMessages = [match]
        } else {
            batchMessages = []
        }

        if !batchMessages.isEmpty {
            let batch = MessageBatch(messages: batchMessages)
            let found = subjects[batch.id] ?? subject(for: batch, context: recentContext(for: batch, in: eligible))
            subjects[batch.id] = found
            try? history.fillDisplay(id: row.id, from: found)
        } else if let chatId = row.chatId, let latest = byChat[chatId]?.last {
            // Nothing to show as a transcript, but the Chat can still be named.
            // Its Batch is unknown, so only a Chat with nobody else in it
            // counts as every message being yours.
            var named = subject(for: MessageBatch(messages: [latest]), context: byChat[chatId] ?? [])
            named.transcript = nil
            named.sourceRef = nil
            named.isAllMine = named.sender == nil
            try? history.fillDisplay(id: row.id, from: named)
        }
    }
}
