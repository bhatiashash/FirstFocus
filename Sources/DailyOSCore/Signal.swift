import Foundation

/// A candidate obligation ranked in the focus list. See CONTEXT.md: Signal.
public struct Signal: Identifiable, Equatable, Sendable {
    public var id: String
    public var source: Source
    public var sourceRef: String
    public var label: String
    public var originalText: String
    public var createdAt: Date
    public var dueAt: Date?
    public var priority: Priority
    public var provenance: Provenance
    public var state: SignalState
    public var lowConfidence: Bool
    /// Who a Messages Signal's source message actually came from: a
    /// resolved Contacts name, or the raw phone number/email when nothing
    /// matches. Resolved once, at Extraction, and kept forever after — like
    /// Label, never re-resolved (ADR 0008; CONTEXT.md: Sender). `nil` for a
    /// Reminders Signal (no Sender concept there) and for a self-thread
    /// Signal (no second party to resolve).
    public var sender: String?
    /// Deep Linking (ticket 02): the `chat.db` chat identifier needed to
    /// reopen this Messages Signal's originating one-to-one Chat, resolved
    /// once at Extraction — the same one-time treatment Sender already
    /// gets. `nil` for a group Chat (no specific-chat targeting is
    /// possible; ticket 03's click-through falls back to opening
    /// Messages.app untargeted) and always `nil` for a Reminders Signal.
    public var chatIdentifier: String?
    /// chat.db's own id for the Chat a Messages Signal came from (ADR
    /// 0040), which is how a later Batch from that Chat finds it as an open
    /// suggestion. Unlike `chatIdentifier`, set for group Chats too. `nil`
    /// for a Reminders Signal and for one saved before this field existed.
    public var chatId: Int?
    /// For a Signal from a Batch (ADR 0039): the messages Extraction saw
    /// before the Batch, one per line with display names, kept so the
    /// Suggested Tasks Inbox can show what the model saw after those
    /// messages leave the Messages lookback. `nil` for every other Signal.
    public var contextText: String?
    /// Manual Focus ordering (ADR 0011, supersedes ADR 0009): the position
    /// a user last dragged this Signal to within Focus, read fresh from
    /// `SignalStore.focusOrder(signalId:)` on every rank — not part of
    /// `Signal`'s own durable identity the way Label or Sender are. `nil`
    /// means "never manually placed," and falls back to the existing
    /// priority/due-date/recency order.
    public var focusOrder: Int?
    /// Snooze (ticket 04, ADR 0045): the moment before which this Signal is
    /// excluded from the ranked list entirely, or `nil` if it's never been
    /// snoozed. Read fresh from `SignalStore.snoozedUntil(signalId:)` on
    /// every rank — not part of `Signal`'s own durable identity the way
    /// Label or Sender are, the same posture `focusOrder` already takes.
    /// Never written to the underlying Source; see CONTEXT.md: Snoozed.
    public var snoozedUntil: Date?
    /// A Reminders Signal's Notes (CONTEXT.md: Notes; ADR 0041): for a
    /// reminder made by Approve, the Batch it came from. `nil` for a
    /// Messages Signal and for a reminder without notes.
    public var notes: String?
    /// A Reminders Signal's URL: for one Approved from a one-to-one Chat,
    /// that Chat's link. `nil` for a Messages Signal.
    public var url: URL?

    public init(
        id: String,
        source: Source,
        sourceRef: String,
        label: String,
        originalText: String,
        createdAt: Date,
        dueAt: Date? = nil,
        priority: Priority = .none,
        provenance: Provenance,
        state: SignalState = .open,
        lowConfidence: Bool = false,
        sender: String? = nil,
        focusOrder: Int? = nil,
        snoozedUntil: Date? = nil,
        chatIdentifier: String? = nil,
        contextText: String? = nil,
        chatId: Int? = nil,
        notes: String? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceRef = sourceRef
        self.label = label
        self.originalText = originalText
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.priority = priority
        self.provenance = provenance
        self.state = state
        self.lowConfidence = lowConfidence
        self.sender = sender
        self.focusOrder = focusOrder
        self.snoozedUntil = snoozedUntil
        self.chatIdentifier = chatIdentifier
        self.contextText = contextText
        self.chatId = chatId
        self.notes = notes
        self.url = url
    }
}

public enum Source: String, Equatable, Sendable {
    case reminders
    case messages
}

/// Normalized urgency. Reminders' 0-9 inverted scale collapses into this on
/// read; Messages and Gmail carry no priority signal of their own.
public enum Priority: String, Equatable, Sendable {
    case none
    case normal
    case high
}

public enum Provenance: String, Equatable, Sendable {
    case stated
    case inferred
}

public enum SignalState: Equatable, Sendable {
    case open
    case checkedOff(at: Date)
    case dismissed(at: Date)
    /// Suggested Tasks Inbox (Focus Mode v2): the originating inferred
    /// Signal was Approved and now lives on as a real reminder created via
    /// `TaskSource.create`. `reminderId` is that reminder's id; the
    /// Signal's own id is never recomputed or mutated in place (CONTEXT.md:
    /// Processed).
    case approved(reminderId: String, at: Date)
    /// An inferred Signal still undecided in the Suggested Tasks Inbox that
    /// a later Batch from its Chat replaced (UPDATE, `replacedBy` naming the
    /// new Signal) or withdrew (CANCEL, `replacedBy` nil). Set by
    /// Extraction, never by the user (CONTEXT.md: Superseded; ADR 0040).
    case superseded(replacedBy: String?, at: Date)
}

/// One Suggestion a Batch's answer Supersedes (ADR 0040): `replacedBy` is the
/// new Signal an UPDATE minted, or `nil` for a CANCEL.
public struct Supersession: Equatable, Sendable {
    public let signalId: String
    public let replacedBy: String?

    public init(signalId: String, replacedBy: String?) {
        self.signalId = signalId
        self.replacedBy = replacedBy
    }
}

/// A Supersession as the store recorded it, read back for History
/// (superseded-restore): which Suggestion a Batch Superseded, and with
/// what. Recorded only once a Supersession has landed, so a Suggestion
/// Approved first has none.
public struct RecordedSupersession: Equatable, Sendable {
    public let signalId: String
    /// The Superseded Suggestion's Label.
    public let label: String
    /// The Signal an UPDATE minted, or `nil` for a CANCEL.
    public let replacedBy: String?
    /// Whether the Suggestion is still Superseded, and by this Batch. False
    /// once it is Restored, or once a later Batch Supersedes it again.
    public let stands: Bool
    /// Whether it can be put back in the Inbox: it stands, and an UPDATE's
    /// replacement is still open or Dismissed. One you Approved, or one a
    /// later Batch Superseded, would leave two versions of the task.
    public let isRestorable: Bool

    public init(signalId: String, label: String, replacedBy: String?, stands: Bool, isRestorable: Bool) {
        self.signalId = signalId
        self.label = label
        self.replacedBy = replacedBy
        self.stands = stands
        self.isRestorable = isRestorable
    }
}
