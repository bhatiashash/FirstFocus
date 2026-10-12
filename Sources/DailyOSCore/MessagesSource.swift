import Foundation

/// A message read from `chat.db`, already decoded to plain text, tagged
/// with which Chat it belongs to and which direction it went. Not a
/// Signal — Extraction decides that. `chatId` and `isFromMe` are what let
/// Extraction apply Chat-level rules (Automated gating) and build
/// conversation context across messages from several Chats at once.
public struct ChatMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let chatId: Int
    public let isFromMe: Bool
    public let text: String
    public let createdAt: Date
    /// The raw phone number/email of whoever actually sent this message —
    /// `chat.db`'s per-message handle, which disambiguates correctly even
    /// inside a group Chat (ticket 03). `nil` for a message the user sent
    /// (`isFromMe`): DailyOS itself is never worth attributing back to the
    /// user via Contacts. Sender attribution (ADR 0008) resolves this into
    /// a Contacts name once, at Extraction.
    public let senderAddress: String?
    /// Deep Linking (ticket 02): the `chat.chat_identifier` needed to
    /// reopen this message's originating Chat, resolved once here — the
    /// same one-time treatment `senderAddress` already gets. `nil` for a
    /// group Chat, where no specific-chat targeting is possible (see
    /// `resolveChatIdentifier`).
    public let chatIdentifier: String?
    /// Whether this message's Chat is the self-thread. Screening (ADR 0036)
    /// skips the self-thread, and until now only `ChatDBMessagesSource`
    /// knew which Chats those were.
    public let isSelfThread: Bool
    /// The Chat's own name (`chat.display_name`), if it has one. Only a
    /// group Chat can be named. Shown in History, never sent in a prompt.
    public let chatName: String?
    /// Whether the Chat has more than one other participant.
    public let isGroupChat: Bool

    public init(
        id: String, chatId: Int, isFromMe: Bool, text: String, createdAt: Date, senderAddress: String? = nil,
        chatIdentifier: String? = nil, isSelfThread: Bool = false, chatName: String? = nil, isGroupChat: Bool = false
    ) {
        self.id = id
        self.chatId = chatId
        self.isFromMe = isFromMe
        self.text = text
        self.createdAt = createdAt
        self.senderAddress = senderAddress
        self.chatIdentifier = chatIdentifier
        self.isSelfThread = isSelfThread
        self.chatName = chatName
        self.isGroupChat = isGroupChat
    }
}

/// Stamps `isSelfThread` on every message whose Chat is in `selfChatIds`
/// (the set `selfChatIds(ownAddresses:chats:)` computes), leaving the rest
/// unflagged.
public func flagSelfThread(_ messages: [ChatMessage], selfChatIds: Set<Int>) -> [ChatMessage] {
    messages.map { message in
        ChatMessage(
            id: message.id, chatId: message.chatId, isFromMe: message.isFromMe, text: message.text,
            createdAt: message.createdAt, senderAddress: message.senderAddress,
            chatIdentifier: message.chatIdentifier, isSelfThread: selfChatIds.contains(message.chatId),
            chatName: message.chatName, isGroupChat: message.isGroupChat
        )
    }
}

/// Production adapter is SQLite against `chat.db`; test adapter is a
/// fixture-backed fake. Two adapters because the Chat categorization logic
/// (self-chat union, self-chat dedup, non-self cutoff, epoch-sniffing) is
/// real logic worth fixture-testing off a live connection, not a thin
/// pass-through.
///
/// Reads every Chat, not only the self-thread (ADR 0007): a self-chat
/// still reads sent-only, since sending to yourself writes two rows, but
/// every other Chat reads both directions, bounded by `nonSelfCutoff`
/// rather than backfilled — see `shouldIncludeMessage`.
public protocol MessagesSource: Sendable {
    /// Whether `chat.db` can currently be read. Full Disk Access has no
    /// status query, so the adapter answers by attempting a read; kept on
    /// the interface so a Gate outage is reachable from a test.
    /// Deliberately cheap: ticket 10 probes it twice around every read.
    func availability() -> SourceAvailability

    func listMessages(excludingChatIds: Set<Int>, nonSelfCutoff: Date) -> [ChatMessage]

    /// The ids of every self-chat (the self-thread may span several: one
    /// per address you own). Read so Messages Intake can keep a self-chat
    /// from ever being excluded as Automated (ADR 0007 amendment).
    func selfChatIds() -> Set<Int>

    /// A targeted, single-item confirmation for ticket 13's garbage
    /// collection: is `sourceRef` actually gone — deleted or unsent — as
    /// opposed to merely missing from the last bulk fetch? `nil` means
    /// "can't tell" (the read itself failed), and a caller must treat that
    /// exactly like "still there," never like "gone."
    func isGone(sourceRef: String) -> Bool?
}

/// Core Data / Cocoa reference date: 2001-01-01 00:00:00 UTC.
private let coreDataEpoch = Date(timeIntervalSince1970: 978_307_200)

/// `chat.db` stores dates as an integer offset from the Core Data epoch,
/// in nanoseconds on current macOS but seconds on databases migrated
/// forward from pre-High-Sierra machines. Sniff magnitude rather than
/// assume: no plausible seconds value reaches 1e12 (that threshold is
/// itself about 2001-01-01 00:16, decades before any real message), so
/// the two encodings never collide.
public func epochDate(fromCoreDataValue rawValue: Int64) -> Date {
    let magnitudeThreshold: Int64 = 1_000_000_000_000
    let seconds = rawValue >= magnitudeThreshold
        ? Double(rawValue) / 1_000_000_000
        : Double(rawValue)
    return coreDataEpoch.addingTimeInterval(seconds)
}

/// A self-chat is an ordinary 1:1 chat whose `chat_identifier` is one of
/// the user's own addresses, derived from `destination_caller_id` on
/// messages they sent. Expect several: self-notes sent from more than one
/// of the user's own addresses (a phone number and an iCloud email, say)
/// produce separate `chat` rows for what the user thinks of as one
/// thread, and every one of them is wanted, unioned rather than picking
/// the largest. `destination_caller_id` can also carry malformed variants
/// of the same number (with or without a leading "+", or a "tel:" prefix)
/// that simply match no `chat_identifier` and are harmlessly ignored.
public func selfChatIds(
    ownAddresses: [String],
    chats: [(chatId: Int, identifier: String)]
) -> [Int] {
    let addressSet = Set(ownAddresses)
    return chats.filter { addressSet.contains($0.identifier) }.map(\.chatId)
}

/// Where the Morning Brief goes (ADR 0046): the identifier of your
/// Self-thread, the conversation named for one of your own addresses. With
/// more than one (your number and your Apple ID email), the one with the
/// newest message, since that is the one you use. `nil` with none.
public func selfThreadAddress(ownAddresses: [String], chats: [(identifier: String, lastMessageAt: Date?)]) -> String? {
    let own = Set(ownAddresses)
    return chats
        .filter { own.contains($0.identifier) }
        .max { ($0.lastMessageAt ?? .distantPast) < ($1.lastMessageAt ?? .distantPast) }?
        .identifier
}

/// The rule (ADR 0007) deciding which raw `chat.db` rows the widened
/// Messages source keeps, independent of SQL: an Automated Chat (ticket
/// 02) is excluded outright regardless of direction or date; a self-chat
/// keeps only what the user sent, since sending to yourself writes two
/// rows; every other Chat keeps both directions, but only messages after
/// `nonSelfCutoff` — the moment that Chat's history first started being
/// read, never backfilled from before it.
/// Deep Linking (ticket 02): which `chat.chat_identifier` (if any) is safe
/// to hand to a click-time handler as a specific-Chat target. Participant
/// count, not chat shape, is the source of truth: a self-chat has zero rows
/// in `chat_handle_join` and an ordinary one-to-one Chat has exactly one, so
/// both are targetable; two or more participants makes it a group Chat,
/// which has no public, documented way to deep-link to a specific
/// conversation on macOS — `nil` here is ticket 03's signal to fall back to
/// opening Messages.app untargeted rather than a real platform bug to chase.
public func resolveChatIdentifier(
    forChatId chatId: Int,
    chatIdentifiers: [Int: String],
    participantCounts: [Int: Int]
) -> String? {
    let isGroupChat = (participantCounts[chatId] ?? 0) > 1
    guard !isGroupChat else { return nil }
    return chatIdentifiers[chatId]
}

public func shouldIncludeMessage(
    chatId: Int,
    isFromMe: Bool,
    createdAt: Date,
    selfChatIds: Set<Int>,
    excludedChatIds: Set<Int>,
    nonSelfCutoff: Date
) -> Bool {
    guard !excludedChatIds.contains(chatId) else { return false }
    if selfChatIds.contains(chatId) {
        return isFromMe
    }
    return createdAt > nonSelfCutoff
}
