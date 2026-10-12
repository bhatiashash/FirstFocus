import Foundation

/// One Batch (CONTEXT.md; ADR 0039): the stretch of one Chat that
/// Extraction judges as a single piece of source text. `messages` are
/// oldest first. A Self-thread note is always a Batch of one.
public struct MessageBatch: Equatable, Sendable {
    public let messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        precondition(!messages.isEmpty, "a Batch always has at least one message")
        self.messages = messages
    }

    /// The Batch's newest message id. What a Signal from this Batch carries
    /// as its source reference, and what History and Screening rows record.
    public var id: String { messages[messages.count - 1].id }
    public var chatId: Int { messages[0].chatId }
    public var isSelfThread: Bool { messages[0].isSelfThread }
    public var newest: ChatMessage { messages[messages.count - 1] }
    public var memberIds: [String] { messages.map(\.id) }
}

/// How long a Chat has to stay quiet before its Batch closes. A constant,
/// not a setting (ADR 0039: 15–30 seconds, starting at 20).
public let batchQuietWindow: TimeInterval = 20

/// The longest a Batch waits after its first message, however busy the
/// Chat stays.
public let batchCap: TimeInterval = 120

/// The most messages one Batch holds. Not in the spec: a Chat left unread
/// while the app wasn't running can pile up far more than the context
/// has room for, so a longer run is split, oldest first, into Batches of
/// at most this many. Reaching it also closes a Batch early, the same way
/// the cap does. Set high enough that a live conversation rarely hits it.
public let maxBatchMessages = 20

/// What `closeBatches` found: the Batches ready to judge, and when the
/// earliest one still open will be ready (`nil` when none is open).
public struct BatchClosing: Equatable, Sendable {
    public let closed: [MessageBatch]
    public let nextClosingAt: Date?
}

/// Groups unprocessed messages into Batches, one Chat at a time, and
/// returns those that have closed. Within a Chat, a pause of at least
/// `quietWindow` between two messages starts a new Batch. A Batch closes
/// once its newest message is `quietWindow` old, once its oldest is `cap`
/// old, or once it holds `maxBatchMessages`. Self-thread notes are each their own Batch
/// and always closed. With `now` nil, everything counts as closed: the
/// caller has asked for every message to be judged now, as a first-run
/// backfill or a test does.
public func closeBatches(
    _ unprocessed: [ChatMessage], now: Date?, quietWindow: TimeInterval = batchQuietWindow, cap: TimeInterval = batchCap
) -> BatchClosing {
    var closed: [MessageBatch] = []
    var nextClosingAt: Date?
    let byChat = Dictionary(grouping: unprocessed, by: \.chatId)
    for chatId in byChat.keys.sorted() {
        let messages = byChat[chatId]!.sorted { $0.createdAt < $1.createdAt }
        if messages[0].isSelfThread {
            closed += messages.map { MessageBatch(messages: [$0]) }
            continue
        }
        // A pause of a quiet window or longer already closed the stretch
        // before it, so each stretch is its own Batch; then an overlong
        // stretch is cut into pieces of at most maxBatchMessages.
        var stretches: [[ChatMessage]] = []
        for message in messages {
            if let last = stretches.last?.last, message.createdAt.timeIntervalSince(last.createdAt) < quietWindow {
                stretches[stretches.count - 1].append(message)
            } else {
                stretches.append([message])
            }
        }
        let chunks = stretches.flatMap { stretch in
            stride(from: 0, to: stretch.count, by: maxBatchMessages).map {
                Array(stretch[$0..<min($0 + maxBatchMessages, stretch.count)])
            }
        }
        for chunk in chunks {
            let quietAt = chunk[chunk.count - 1].createdAt.addingTimeInterval(quietWindow)
            let capAt = chunk[0].createdAt.addingTimeInterval(cap)
            let closesAt = min(quietAt, capAt)
            if let now, chunk.count < maxBatchMessages, now < closesAt {
                nextClosingAt = min(nextClosingAt ?? closesAt, closesAt)
            } else {
                closed.append(MessageBatch(messages: chunk))
            }
        }
    }
    return BatchClosing(closed: closed.sorted { $0.newest.createdAt < $1.newest.createdAt }, nextClosingAt: nextClosingAt)
}
