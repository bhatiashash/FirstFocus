import Foundation

extension HistorySubject {
    /// How History records a Batch Extraction is judging, with the context
    /// shown alongside it: its text under the labels the model saw, and
    /// how to name and show it under real names. Resolved once here, like a
    /// Signal's Sender, and never part of a prompt (ADR 0033).
    ///
    /// The Sender is the newest message in the Batch that isn't yours;
    /// when every message is yours, the newest other person in its
    /// context; nobody when there is nobody else, as in the Self-thread.
    /// The Chat title is a group Chat's name, or its other members' names
    /// when it has none. The transcript is the context, marked as such,
    /// then the Batch itself.
    public init(
        batch: MessageBatch, context: [ChatMessage], senderLabel: (ChatMessage) -> String,
        contactsResolver: any ContactsResolver
    ) {
        var resolved: [String: String] = [:]
        func name(_ message: ChatMessage) -> String {
            if message.isFromMe { return "You" }
            guard let address = message.senderAddress else { return unknownSenderName }
            if let known = resolved[address] { return known }
            let found = contactsResolver.resolveName(forAddress: address) ?? address
            resolved[address] = found
            return found
        }
        let other = batch.isSelfThread ? nil : (batch.messages.last { !$0.isFromMe } ?? context.last { !$0.isFromMe })
        var chatTitle: String?
        if !batch.isSelfThread, batch.newest.isGroupChat {
            var members: [String] = []
            for message in context + batch.messages where !message.isFromMe {
                let member = name(message)
                if !members.contains(member) { members.append(member) }
            }
            chatTitle = batch.newest.chatName ?? (members.isEmpty ? nil : members.joined(separator: ", "))
        }
        let transcript = context.map {
            HistoryTranscriptLine(speaker: name($0), isFromMe: $0.isFromMe, text: $0.text, sentAt: $0.createdAt, isContext: true)
        } + batch.messages.map {
            HistoryTranscriptLine(speaker: name($0), isFromMe: $0.isFromMe, text: $0.text, sentAt: $0.createdAt)
        }
        self.init(
            sourceRawText: historySourceText(for: batch, senderLabel: senderLabel), chatId: batch.chatId, sourceRef: batch.id,
            sender: other.map(name), transcript: transcript, chatTitle: chatTitle, chatIdentifier: batch.newest.chatIdentifier,
            isSelfThread: batch.isSelfThread, isAllMine: batch.isSelfThread || batch.messages.allSatisfy(\.isFromMe)
        )
    }
}

/// What a Batch's History row shows as its source text: the message itself
/// for a Batch of one, as before batching; otherwise the Batch's lines
/// under the same labels the model saw, so the row never shows a real name
/// the prompt didn't.
private func historySourceText(for batch: MessageBatch, senderLabel: (ChatMessage) -> String) -> String {
    guard batch.messages.count > 1 else { return batch.newest.text }
    return batch.messages.map { "\($0.isFromMe ? "You" : senderLabel($0)): \($0.text)" }.joined(separator: "\n")
}
