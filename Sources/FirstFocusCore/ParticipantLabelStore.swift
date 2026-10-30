import Foundation

/// Assigns a stable, anonymized label to each non-you sender within a Chat,
/// for use in the composed prompt an extractor sees — never a resolved
/// Contacts name (ADR 0033). Sender attribution (ADR 0008) resolves a real
/// name for display only, from an entirely separate table; this store never
/// reads or writes anything ADR 0008 owns; the two exist in parallel.
///
/// The first `senderAddress` seen within a given `chatId` becomes
/// "Participant A", the next "Participant B", and so on. The same pair
/// always returns the same label afterward, which is what lets a stored
/// Correction (ADR 0031) that references "Participant B" stay valid for
/// later messages from that same real sender.
public protocol ParticipantLabelStore: Sendable {
    func label(chatId: Int, senderAddress: String) -> String
}

/// "Participant A", "Participant B", ... "Participant Z", then "Participant
/// AA" — the same letter-then-double-letter progression spreadsheet columns
/// use, since a group Chat exceeding 26 participants is the only case that
/// ever reaches the fallback.
func participantLabel(forIndex index: Int) -> String {
    var n = index
    var letters = ""
    repeat {
        letters = String(UnicodeScalar(65 + n % 26)!) + letters
        n = n / 26 - 1
    } while n >= 0
    return "Participant \(letters)"
}

/// The `participantLabelStore` default for every call site that doesn't
/// care about labels surviving a relaunch — tests, and any caller that
/// hasn't wired up durable storage. Assigns labels in memory only, for the
/// lifetime of this instance; the production default is
/// `SQLiteParticipantLabelStore`, held once by `AppModel` the same way
/// `historyStore` already is.
///
/// `@unchecked Sendable`: mutated only from `Extraction.swift`'s per-message
/// loop, which awaits each call in turn rather than running concurrently.
public final class InMemoryParticipantLabelStore: ParticipantLabelStore, @unchecked Sendable {
    private var labels: [ChatSenderKey: String] = [:]
    private var nextIndexByChat: [Int: Int] = [:]

    public init() {}

    public func label(chatId: Int, senderAddress: String) -> String {
        let key = ChatSenderKey(chatId: chatId, senderAddress: senderAddress)
        if let existing = labels[key] { return existing }
        let index = nextIndexByChat[chatId, default: 0]
        nextIndexByChat[chatId] = index + 1
        let assigned = participantLabel(forIndex: index)
        labels[key] = assigned
        return assigned
    }
}

struct ChatSenderKey: Hashable {
    let chatId: Int
    let senderAddress: String
}
