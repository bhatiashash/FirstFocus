import Foundation

/// The Batch a History row is about, as History records it: what the
/// model or Screening was shown, where it came from, and how History's
/// list names it. Every row for one Batch carries the same one.
/// `HistorySubject(batch:context:senderLabel:contactsResolver:)` works it
/// out when a row is recorded.
public struct HistorySubject: Sendable, Equatable {
    /// The Batch's own text — never `formatForExtraction`'s
    /// context-bearing prompt: the message itself for a Batch of one,
    /// otherwise its lines under the labels the model saw. What Re-run
    /// replays; the tradeoff is that Re-run replays the Batch without the
    /// context it originally saw.
    public var sourceRawText: String
    /// chat.db's internal integer Chat id (ticket 02 of the corrections
    /// spec) — the same one `automated_chats`/`muted_chats` key on, never
    /// the app's `chatIdentifier` string field, which is `nil` for every
    /// group chat. `nil` only on a row written before this column existed,
    /// never a sentinel int that could collide with a real chat id.
    public var chatId: Int?
    /// The Batch's newest message id, so every row for the Batch can be
    /// grouped and paired. `nil` only for a row written before this column
    /// existed that the display backfill hasn't matched yet.
    public var sourceRef: String?
    /// Who History names the Batch after (CONTEXT.md: Sender), resolved
    /// from Contacts when the row was recorded: the newest other person in
    /// the Batch, or in its context when every message was yours. `nil`
    /// when there is nobody else, and on a row recorded before History kept
    /// a Sender. Never part of any prompt.
    public var sender: String?
    /// The Batch's messages, oldest first, under resolved names, for
    /// History's detail pane. Stays on the Mac: the model and Screening see
    /// only the rendered prompt, under Participant Labels (ADR 0033). `nil`
    /// on a row written before this column existed.
    public var transcript: [HistoryTranscriptLine]?
    /// A group Chat's name, or its other members' names when it has none.
    /// `nil` for a one-to-one Chat, the Self-thread, and a row written
    /// before this column existed.
    public var chatTitle: String?
    /// The Chat's `chat.chat_identifier`, which a Suggestion needs to open
    /// the Chat in Messages. `nil` for a group Chat, which Messages can't
    /// deep-link into, and for a row written before History recorded it.
    public var chatIdentifier: String?
    public var isSelfThread: Bool
    /// Every message in the Batch was yours, so a Suggestion from it has no
    /// Sender (CONTEXT.md: Sender). A row recorded before History kept this
    /// has it only where nobody else was in the Chat at all: the typed-fields
    /// migration reads it from a Sender of "You", and the display backfill
    /// can't tell which messages its Batch held.
    public var isAllMine: Bool

    public init(
        sourceRawText: String, chatId: Int? = nil, sourceRef: String? = nil, sender: String? = nil,
        transcript: [HistoryTranscriptLine]? = nil, chatTitle: String? = nil, chatIdentifier: String? = nil,
        isSelfThread: Bool = false, isAllMine: Bool = false
    ) {
        self.sourceRawText = sourceRawText
        self.chatId = chatId
        self.sourceRef = sourceRef
        self.sender = sender
        self.transcript = transcript
        self.chatTitle = chatTitle
        self.chatIdentifier = chatIdentifier
        self.isSelfThread = isSelfThread
        self.isAllMine = isAllMine
    }

    /// Whether History recorded how to name the Batch. A row from before it
    /// did is filled in later by `backfillHistoryDisplay`.
    public var hasDisplay: Bool { sender != nil || isAllMine }
}

/// One judgment Messages Intake made about a Batch (CONTEXT.md: History):
/// a real call to `IntentExtractor.extract(from:)`, or a Screening
/// decision. Written whether or not a call produced a Signal — the whole
/// point is auditing what the model did, not mirroring the Signal Board —
/// but only when the model or Screening was actually asked: a message
/// short-circuited by the Automated-chat check, the confidentiality
/// trigger, or the heuristic pre-filter never reaches either, so there is
/// nothing to record for it (see `Extraction.swift`'s `judge`).
public struct HistoryEntry: Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    /// The Batch this row is about.
    public var subject: HistorySubject
    /// The exact string `extract(from:)` returned, before `parseExtractionOutput`
    /// ever sees it. A Screening row holds its summary here instead
    /// (`HistoryEntryKind.summary`), for the Inspector and Export only.
    public let rawOutput: String
    /// `IntentExtractor.modelDisplayName` at the moment of the call, not
    /// whatever model happens to be active now.
    public let modelUsed: String
    public let signalCount: Int
    /// The one field History lets the user edit on an existing row.
    public var isStarred: Bool
    /// The exact composed string `extract(from:)` was actually called
    /// with — `[context]`/`[latest messages]` blocks and all, unlike
    /// `sourceRawText`. A Correction (ADR 0031) builds its example from
    /// it, and the Inspector shows it. Re-run replays `sourceRawText` only.
    public let renderedContext: String
    /// Which judgment this row records (CONTEXT.md: History): a model call,
    /// or a Screening decision (ADR 0036) carrying its probability and
    /// whether it Screened the message. Rows written before this column
    /// existed were all model calls, and the store's typed-fields
    /// migration records them as `.extraction`.
    public let kind: HistoryEntryKind

    public var sourceRawText: String { subject.sourceRawText }
    public var chatId: Int? { subject.chatId }
    public var sourceRef: String? { subject.sourceRef }
    public var sender: String? { subject.sender }
    public var transcript: [HistoryTranscriptLine]? { subject.transcript }
    public var chatTitle: String? { subject.chatTitle }
    public var chatIdentifier: String? { subject.chatIdentifier }
    public var isSelfThread: Bool { subject.isSelfThread }
    public var isAllMine: Bool { subject.isAllMine }

    public var isScreening: Bool { screening != nil }

    /// The Screening decision, or `nil` on an extraction row.
    public var screening: ScreeningDecision? {
        if case .screening(let decision) = kind { return decision }
        return nil
    }

    /// Read-only conveniences over `kind`, so the two can never disagree.
    public var screeningProbability: Double? { screening?.probability }
    public var wasScreened: Bool { screening?.wasScreened ?? false }

    /// A row recording `kind` about `subject`. `rawOutput` is the model's
    /// answer; a Screening row's summary is worked out from its decision,
    /// so no caller writes it by hand. `renderedContext` defaults to the
    /// Batch's own text, for a call made with no context around it.
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        subject: HistorySubject,
        kind: HistoryEntryKind = .extraction,
        rawOutput: String? = nil,
        modelUsed: String,
        signalCount: Int,
        renderedContext: String? = nil,
        isStarred: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subject = subject
        self.kind = kind
        self.rawOutput = rawOutput ?? kind.summary
        self.modelUsed = modelUsed
        self.signalCount = signalCount
        self.renderedContext = renderedContext ?? subject.sourceRawText
        self.isStarred = isStarred
    }

    /// The same, with the subject's fields spelled out.
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceRawText: String,
        rawOutput: String? = nil,
        modelUsed: String,
        signalCount: Int,
        isStarred: Bool = false,
        chatId: Int? = nil,
        renderedContext: String? = nil,
        kind: HistoryEntryKind = .extraction,
        sourceRef: String? = nil,
        sender: String? = nil,
        transcript: [HistoryTranscriptLine]? = nil,
        chatTitle: String? = nil,
        chatIdentifier: String? = nil,
        isSelfThread: Bool = false,
        isAllMine: Bool = false
    ) {
        self.init(
            id: id, timestamp: timestamp,
            subject: HistorySubject(
                sourceRawText: sourceRawText, chatId: chatId, sourceRef: sourceRef, sender: sender, transcript: transcript,
                chatTitle: chatTitle, chatIdentifier: chatIdentifier, isSelfThread: isSelfThread, isAllMine: isAllMine
            ),
            kind: kind, rawOutput: rawOutput, modelUsed: modelUsed, signalCount: signalCount,
            renderedContext: renderedContext, isStarred: isStarred
        )
    }

    /// Derived, never stored: `parseExtractionOutput` is pure, so a History
    /// card can show the clean Label list under the raw output with nothing
    /// duplicated in the database (ADR 0029).
    public var parsedLabels: [String] { parseExtractionOutput(rawOutput) }
}

/// One message of a Batch as History's detail pane shows it.
public struct HistoryTranscriptLine: Codable, Equatable, Sendable {
    /// "You", a resolved Contacts name, or the raw address.
    public let speaker: String
    public let isFromMe: Bool
    public let text: String
    public let sentAt: Date
    /// An earlier message the model saw as context, not part of the Batch
    /// being judged. Shown dimmed above the Batch.
    public let isContext: Bool

    public init(speaker: String, isFromMe: Bool, text: String, sentAt: Date, isContext: Bool = false) {
        self.speaker = speaker
        self.isFromMe = isFromMe
        self.text = text
        self.sentAt = sentAt
        self.isContext = isContext
    }

    private enum CodingKeys: String, CodingKey { case speaker, isFromMe, text, sentAt, isContext }

    // Transcripts written before `isContext` existed held Batch lines only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try container.decode(String.self, forKey: .speaker)
        isFromMe = try container.decode(Bool.self, forKey: .isFromMe)
        text = try container.decode(String.self, forKey: .text)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        isContext = try container.decodeIfPresent(Bool.self, forKey: .isContext) ?? false
    }
}

/// What one Screening call decided about a message (ADR 0036).
public struct ScreeningDecision: Sendable, Equatable {
    /// Whether Screening could stop the Batch: in shadow mode it only
    /// records, in live mode it Screens anything scored below the cutoff.
    public enum Mode: Sendable, Equatable {
        case shadow
        case live(cutoff: Double)

        /// The value stored in History's `screening_mode` column.
        public var storageName: String {
            switch self {
            case .shadow: "shadow"
            case .live: "live"
            }
        }

        /// The mode `storageName` names, with the cutoff stored beside it.
        /// `nil` for an unknown name, or live mode with no cutoff.
        public init?(storageName: String?, cutoff: Double?) {
            switch storageName {
            case "shadow": self = .shadow
            case "live": guard let cutoff else { return nil }; self = .live(cutoff: cutoff)
            default: return nil
            }
        }
    }

    public let probability: Double
    public let mode: Mode
    /// Which wording of `screeningQuestion` produced `probability`. Scores
    /// from different wordings aren't comparable, so the cutoff histogram
    /// uses only the current one.
    public let questionVersion: Int

    public init(probability: Double, mode: Mode, questionVersion: Int = screeningQuestionVersion) {
        self.probability = probability
        self.mode = mode
        self.questionVersion = questionVersion
    }

    /// The cutoff the decision was judged against; `nil` in shadow mode,
    /// which has none.
    public var cutoff: Double? {
        if case .live(let cutoff) = mode { return cutoff }
        return nil
    }

    /// True only in live mode below the cutoff.
    public var wasScreened: Bool { cutoff.map { probability < $0 } ?? false }

    /// The row's summary, for the Inspector and Export. Written alongside
    /// the fields above and never read back for data.
    public var summary: String {
        let score = formatScore(probability)
        switch mode {
        case .live(let cutoff):
            return wasScreened
                ? "Screened: \(score), below cutoff \(formatScore(cutoff))"
                : "Let through: \(score), cutoff \(formatScore(cutoff))"
        case .shadow:
            return "Screening: \(score), shadow (sent on to the model)"
        }
    }
}

public enum HistoryEntryKind: Sendable, Equatable {
    case extraction
    case screening(ScreeningDecision)
    /// A Screening call that failed (timeout, network, rejected request),
    /// after which the message went on to the model as if Screening were
    /// off. Recorded so gaps in the shadow data can be explained. Not a
    /// Screening decision: shadow statistics ignore it.
    case screeningFailed(reason: String)
    /// A Batch that skipped Screening because the breaker was open after
    /// Jev kept failing or rejected the key (CONTEXT.md: Screening
    /// Unavailable). It went straight to the model.
    case screeningUnavailable
    /// A model call that threw instead of answering (a prompt too long, a
    /// decode failure). The Batch stays unprocessed for another try, up to
    /// `maxExtractionTries` (CONTEXT.md: Processed).
    case extractionFailed(reason: String)
    /// The model's verdict on a Screened Batch, taken for the Audit Sample
    /// (CONTEXT.md; ADR 0039) once Screening is live. Never produces a
    /// Signal; exists so the cutoff can be checked against what the model
    /// would have found.
    case audit
    /// A Re-run's result (CONTEXT.md: Re-run): the same input replayed
    /// through whichever model is active. Its own kind so History can tell
    /// it from the extraction row intake wrote for the same Batch. Rows
    /// written before this case existed read back as `.extraction`.
    case rerun

    /// A call to the model that intake or the user asked for directly: an
    /// extraction or a Re-run. Excludes the Audit Sample, which never
    /// produces a Signal.
    public var isModelCall: Bool { self == .extraction || self == .rerun }

    /// What a row of this kind records as its output when it isn't a model
    /// call: a Screening decision's summary, or why Screening failed. Empty
    /// for a model call, whose output is the model's own.
    public var summary: String {
        switch self {
        case .screening(let decision): decision.summary
        case .screeningFailed(let reason): screeningFailurePrefix + reason
        case .screeningUnavailable: "Screening unavailable"
        case .extractionFailed(let reason): extractionFailurePrefix + reason
        case .extraction, .audit, .rerun: ""
        }
    }

    /// Why a failed call failed, stored in its own column.
    public var failureReason: String? {
        switch self {
        case .screeningFailed(let reason), .extractionFailed(let reason): reason
        default: nil
        }
    }

    /// The value stored in History's `kind` column and CSV export.
    public var storageName: String {
        switch self {
        case .extraction: "extraction"
        case .screening: "screening"
        case .screeningFailed: "screening_failed"
        case .screeningUnavailable: "screening_unavailable"
        case .extractionFailed: "extraction_failed"
        case .audit: "audit"
        case .rerun: "rerun"
        }
    }
}

/// How a failed model call's row begins, before its reason.
public let extractionFailurePrefix = "Extraction failed: "

/// How far either side of the cutoff a Screening score still counts as a
/// close call (CONTEXT.md: Borderline).
public let borderlineBandWidth = 0.1

/// The cutoff the Review filter centres on while none is set yet.
public let defaultReviewCutoff = 0.5

/// Absorbs floating-point drift, so 0.4 against a 0.5 cutoff is inside the
/// band even though `0.5 - 0.4` isn't exactly 0.1.
let borderlineTolerance = 1e-9

/// Whether `entry` is a Borderline Screening row (CONTEXT.md): scored
/// within `borderlineBandWidth` of `cutoff`, inclusive, or of
/// `defaultReviewCutoff` when no cutoff is set. Only Screening decisions
/// have a score, so every other row is not.
public func isBorderline(_ entry: HistoryEntry, cutoff: Double?) -> Bool {
    guard let probability = entry.screeningProbability else { return false }
    return abs(probability - (cutoff ?? defaultReviewCutoff)) <= borderlineBandWidth + borderlineTolerance
}

/// Durable History storage (ADR 0029). Deliberately its own protocol, not
/// folded into `SignalStore`: History's callers — `Extraction.swift`'s
/// writer, the History tab's reader — are distinct from any of
/// `SignalStore`'s own four (ADR 0021's split follows the same rule).
///
/// Read-only with respect to extraction: nothing here ever touches
/// `Processed` state or the Signal Board. Deleting a `HistoryEntry` removes
/// only that log row.
public protocol HistoryStore: Sendable {
    func record(_ entry: HistoryEntry) throws
    /// Every Batch with a row recorded at or after `since`, newest first,
    /// each holding all of its rows however old, so a Batch never shows a
    /// partial result. Also the latest Batch of each of `chatIds` that has
    /// nothing in the window: History pins a Muted Chat's latest Batch, so
    /// there is always a row to Unmute from (ADR 0031).
    func batches(since: Date, pinningLatestOf chatIds: Set<Int>) -> HistoryWindow
    /// The latest Batch of each of `chatIds` that has any row, however old.
    /// Advanced names a Muted Chat by it (muted-chats-list).
    func latestBatches(ofChats chatIds: Set<Int>) -> [HistoryBatch]
    /// The Batch each of `sourceRefs` names, with all its rows however
    /// old, keyed by `sourceRef`. A Batch with no rows is left out. The
    /// Suggested Tasks Inbox reads its Suggestions' Batches through this
    /// (inbox-not-for-me).
    func batches(forSourceRefs sourceRefs: Set<String>) -> [String: HistoryBatch]
    /// Each Batch's first Screening decision scored under `questionVersion`,
    /// with the model's verdict on the same Batch, for the cutoff
    /// histogram.
    func screeningOutcomes(questionVersion: Int) -> [ScreeningOutcome]
    /// Up to `limit` starred rows, newest first, or the latest extraction
    /// rows when none is starred, for the model evaluator's spot check.
    func evaluationRows(limit: Int) -> [HistoryEntry]
    func setStarred(_ isStarred: Bool, id: String) throws
    func delete(id: String) throws
    /// Deletes every row recorded for one Batch. Like `delete(id:)`, this
    /// never touches Processed state or the Signal Board.
    func delete(sourceRef: String) throws
    /// Fills in how History names and shows a row recorded before History
    /// kept that (`backfillHistoryDisplay`), and the message id of a row
    /// from before History kept one, once its message is found, from
    /// `subject`. A field that already holds a value is left as it is, and
    /// a row that already has its display keeps its Self-thread and
    /// "every message was yours" facts.
    func fillDisplay(id: String, from subject: HistorySubject) throws
}

extension HistoryStore {
    /// Every Batch with a row recorded at or after `since`, newest first.
    public func batches(since: Date) -> [HistoryBatch] {
        batches(since: since, pinningLatestOf: []).batches
    }
}

/// What History's list reads for its window.
public struct HistoryWindow: Sendable, Equatable {
    /// Newest first.
    public let batches: [HistoryBatch]
    /// The latest Batch of each asked-for Chat with nothing in the window.
    public let pinned: [HistoryBatch]

    public init(batches: [HistoryBatch], pinned: [HistoryBatch]) {
        self.batches = batches
        self.pinned = pinned
    }
}

/// One Screening decision and the model's verdict on the same Batch.
public struct ScreeningOutcome: Sendable, Equatable {
    public let sourceRef: String
    public let probability: Double
    /// Whether the model found a task in the Batch, from intake's own call
    /// or the Audit Sample, never a later Re-run. `nil` when the model
    /// never judged it.
    public let modelFoundTask: Bool?

    public init(sourceRef: String, probability: Double, modelFoundTask: Bool?) {
        self.sourceRef = sourceRef
        self.probability = probability
        self.modelFoundTask = modelFoundTask
    }
}

public enum HistoryStoreError: Error {
    case cannotOpen
    case writeFailed
    case entryNotFound(id: String)
}

/// Re-run (CONTEXT.md): replays a `HistoryEntry`'s stored input through
/// whichever model `extractor` actually is, and records the result as a new
/// entry rather than mutating `entry`. Greedy sampling makes re-running
/// against the same model a no-op, so this exists to compare models against
/// identical input, not to reproduce a past result.
public func rerunHistoryEntry(
    _ entry: HistoryEntry,
    extractor: any IntentExtractor,
    historyStore: any HistoryStore,
    priority: TaskPriority = .userInitiated
) async throws {
    // A Batch row's source text is its lines under their labels; replay it
    // under the block the model first saw it in, not as a bare note.
    let batchInput = "[latest messages]\n" + entry.sourceRawText
    let input = entry.renderedContext.hasSuffix(batchInput) ? batchInput : entry.sourceRawText
    let raw = try await extractor.extract(from: input, priority: priority)
    // Counted the way intake counts: every result that carries a Label.
    let signalCount = parseExtractionResults(raw).compactMap(\.label).count
    // Re-run replays only the Batch's own text (see `sourceRawText`),
    // never reconstructing the context the original call saw, so that is
    // also the new row's rendered context.
    try historyStore.record(HistoryEntry(
        subject: entry.subject, kind: .rerun, rawOutput: raw, modelUsed: extractor.modelDisplayName,
        signalCount: signalCount, renderedContext: entry.sourceRawText
    ))
}
