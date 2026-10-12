import Foundation

/// What kind of mistake a Correction records. Only `.falsePositive` has a
/// UI trigger today ("Not for me" on a History row) — the other two are
/// part of the schema from the start so adding their UI later needs no
/// migration, per the corrections spec's out-of-scope note.
public enum CorrectionType: String, Sendable {
    case falsePositive = "false_positive"
    case falseNegative = "false_negative"
    case fieldCorrection = "field_correction"
    /// "Add task" on a History Batch the model said held no task: a false
    /// negative against the model, not Screening, carrying the Label the
    /// model should have produced as `correctedOutput`. Unlike "This was
    /// work" (`.falseNegative`, Screening's miss), this one is a worked
    /// example future prompts can show.
    case missedTask = "missed_task"
}

/// A user's explicit signal, from a History row, that one extraction
/// call's output was wrong (CONTEXT.md: Correction). `inputText` is the
/// exact composed prompt line the model saw for the target message —
/// `HistoryEntry.renderedContext`, not `sourceRawText` — so a stored
/// Correction reproduces the real sender-labeled scenario, not a
/// simplified version of it. `correctedOutput` is the full raw output
/// shape (e.g. the literal `"NONE"` for a false positive), matching
/// `IntentExtractor.extract(from:)`'s own return format, so it drops
/// straight into the few-shot template alongside the hardcoded EXAMPLES.
public struct Correction: Sendable, Equatable {
    public let chatId: Int
    /// The Batch this Correction is about (its newest message id, the
    /// `sourceRef` its History rows carry). One Batch holds at most one
    /// Correction of each type. `nil` only for a Correction recorded before
    /// Corrections belonged to a Batch: it still serves as a worked example
    /// but matches no History row.
    public let sourceRef: String?
    public let inputText: String
    public let correctedOutput: String
    public let correctionType: CorrectionType
    public let createdAt: Date

    public init(
        chatId: Int, sourceRef: String? = nil, inputText: String, correctedOutput: String, correctionType: CorrectionType,
        createdAt: Date = Date()
    ) {
        self.chatId = chatId
        self.sourceRef = sourceRef
        self.inputText = inputText
        self.correctedOutput = correctedOutput
        self.correctionType = correctionType
        self.createdAt = createdAt
    }
}

/// Durable Correction storage (ADR 0031). A separate protocol from
/// `HistoryStore`, the same reasoning ADR 0021 already gives for splitting
/// `SignalStore`: this store's one caller (`selectCorrections`, plus the
/// "Not for me" write path) is distinct from History's own callers.
/// Extraction's few-shot reads (ADR 0021: stores split by caller). The
/// only part of Correction storage Extraction ever needs.
public protocol CorrectionExamples: Sendable {
    /// The most recent `limit` Corrections of `type` for `chatId`, newest
    /// first. Few-shot selection only ever asks for false positives: a false
    /// negative is about Screening, and would mislead the model as an
    /// example (ADR 0036).
    func corrections(forChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction]

    /// The most recent Corrections of `type` across every chat except
    /// `chatId`, newest first, unfiltered by per-chat count —
    /// `selectCorrections` applies the per-chat cap itself over this raw
    /// pool, keeping that selection policy in one plain, testable place
    /// rather than in SQL.
    func globalCorrections(excludingChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction]
}

/// Writing a Correction and reading back new ones: History's "Not for me",
/// "This was work" and "Add task", and Rule proposals (ADR 0038). Reached
/// through `Corrections`, which `AppModel` owns.
public protocol CorrectionLog: Sendable {
    /// Stores `correction` as a new row.
    func record(_ correction: Correction) throws

    /// Stores `correction` in place of the Correction with the same
    /// `sourceRef` and type, if there is one, in one transaction: a failed
    /// write leaves the earlier one where it was. A Correction with no
    /// `sourceRef` replaces nothing. When to replace rather than add is
    /// `Corrections`' decision, not the store's.
    func replace(_ correction: Correction) throws

    /// Removes the Correction of `type` that belongs to the Batch
    /// `sourceRef` names: an undone "Not for me" (inbox-undo). A no-op if
    /// there is none.
    func delete(sourceRef: String, type: CorrectionType) throws

    /// Which Correction types each of `sourceRefs` has. A Batch with none
    /// is left out.
    func correctionTypes(forSourceRefs sourceRefs: Set<String>) -> [String: Set<CorrectionType>]

    /// Every Correction of `type` created after `date` (all of them when
    /// `date` is nil), newest first. Rule proposals count and read these
    /// (ADR 0038).
    func corrections(ofType type: CorrectionType, createdAfter date: Date?, limit: Int) -> [Correction]
}

/// Both halves, for the adapters that provide them and the one caller
/// (`AppModel`) that needs them together.
public typealias CorrectionStore = CorrectionExamples & CorrectionLog

/// The per-chat-then-capped-global-fallback selection (ADR 0031, corrections
/// spec ticket 04): a chat's own most recent Corrections first; only when
/// that chat has fewer than `limit` does this backfill from other chats'
/// false positives, newest first, at most one per source chat, until `limit` total or the
/// pool runs out. A free function, not a `CorrectionStore` method, so it's
/// testable against a plain in-memory fake without any SQL involved.
/// The Correction kinds that make a worked example: a task the model
/// wrongly found, and one it wrongly missed. "This was work" is left out:
/// it records Screening's miss, with no Label to show (ADR 0036).
let exampleTypes: [CorrectionType] = [.falsePositive, .missedTask]

/// The kinds that may backfill into another chat. A missed task is left
/// out: its Label is specific to its own chat, and the model copies it word
/// for word into unrelated ones (ADR 0031, amended 2026-09-27).
let crossChatExampleTypes: [CorrectionType] = [.falsePositive]

private func newestFirst(_ lists: [[Correction]], limit: Int) -> [Correction] {
    Array(lists.flatMap { $0 }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
}

public func selectCorrections(
    chatId: Int, store: any CorrectionExamples, limit: Int = 2, fallbackPoolSize: Int = 50
) -> [Correction] {
    let ownChat = newestFirst(exampleTypes.map { store.corrections(forChatId: chatId, limit: limit, type: $0) }, limit: limit)
    guard ownChat.count < limit else { return ownChat }

    let needed = limit - ownChat.count
    let pool = newestFirst(
        crossChatExampleTypes.map { store.globalCorrections(excludingChatId: chatId, limit: fallbackPoolSize, type: $0) },
        limit: fallbackPoolSize
    )
    var seenChatIds: Set<Int> = []
    var backfill: [Correction] = []
    for correction in pool {
        guard !seenChatIds.contains(correction.chatId) else { continue }
        seenChatIds.insert(correction.chatId)
        backfill.append(correction)
        if backfill.count == needed { break }
    }
    return ownChat + backfill
}
