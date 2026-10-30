import Foundation

/// What History and a Suggestion call someone whose message carries no
/// address to resolve. Such a message has no Sender.
let unknownSenderName = "Them"

/// The one way an inferred Messages Signal is made, whether the model found
/// it (`judge`) or you named it from History ("Add task"), so the two can't
/// drift apart. `transcript` is the Batch as History records it: its context
/// lines first, marked `isContext`, then its own lines, each under the name
/// Contacts gives the speaker.
///
/// - The original wording is every Batch line under those names (ADR 0018's
///   recovery path), or a Self-thread note's plain text.
/// - The Sender is whoever wrote the Batch's newest line that isn't yours;
///   nobody when every line is yours, or when that line had no address.
/// - `createdAt` is the Batch's newest line.
public func messagesSuggestion(
    label: String, sourceRef: String, chatId: Int, transcript: [HistoryTranscriptLine], isSelfThread: Bool,
    chatIdentifier: String?, dueAt: Date? = nil, lowConfidence: Bool = false
) -> Signal {
    let context = transcript.filter(\.isContext)
    let batch = transcript.filter { !$0.isContext }
    func named(_ lines: [HistoryTranscriptLine]) -> String {
        lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
    let sender = batch.last { !$0.isFromMe }.map(\.speaker).flatMap { $0 == unknownSenderName ? nil : $0 }
    return Signal(
        id: UUID().uuidString,
        source: .messages,
        sourceRef: sourceRef,
        label: label,
        originalText: isSelfThread ? (batch.last?.text ?? "") : named(batch),
        createdAt: batch.last?.sentAt ?? Date(),
        dueAt: dueAt,
        provenance: .inferred,
        lowConfidence: lowConfidence,
        sender: isSelfThread ? nil : sender,
        chatIdentifier: chatIdentifier,
        contextText: context.isEmpty ? nil : named(context),
        chatId: chatId
    )
}
