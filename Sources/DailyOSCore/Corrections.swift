import Foundation

/// Everything about Corrections (CONTEXT.md: Correction) that callers
/// shouldn't each decide for themselves: which Batch a Correction belongs
/// to, what each History action records, and whether a Batch is corrected.
/// The side effects of those actions (dismissing a Signal, sending a Batch
/// to the model, adding a Suggestion) stay with whoever performs them.
///
/// A Correction belongs to the Batch its History row names, one of each
/// type per Batch (ADR 0031, amended 2026-09-26): recording a type the
/// Batch already has replaces it, in one store write, so a Re-run row's
/// flag and its model call's are one Correction. This module is the only
/// place that rule lives; a store just keeps rows. A row with no Chat has nothing to scope
/// a Correction to, so recording from one does nothing. A row from before
/// History recorded Batches is recorded as it is, with no Batch to match.
public struct Corrections: Sendable {
    private let store: any CorrectionStore

    public init(store: any CorrectionStore) {
        self.store = store
    }

    /// "Not for me": the model found a task in `entry`'s Batch that wasn't
    /// one.
    public func recordNotForMe(_ entry: HistoryEntry) throws {
        try record(.falsePositive, from: entry, output: "NONE")
    }

    /// "This was work": Screening stopped `entry`'s Batch, and it held work.
    public func recordThisWasWork(_ entry: HistoryEntry) throws {
        try record(.falseNegative, from: entry, output: "")
    }

    /// "Add task": the model found nothing in `entry`'s Batch, and `label`
    /// is the task it missed.
    public func recordMissedTask(label: String, for entry: HistoryEntry) throws {
        try record(.missedTask, from: entry, output: label)
    }

    /// Undo of "Not for me" (inbox-undo): the Batch named `sourceRef` no
    /// longer has a false positive. A Rule already approved from it stays.
    public func removeNotForMe(fromBatch sourceRef: String) throws {
        try store.delete(sourceRef: sourceRef, type: .falsePositive)
    }

    /// Which Correction types each Batch in `sourceRefs` has, in one read.
    /// A Batch with none is left out.
    public func types(forBatches sourceRefs: some Sequence<String>) -> [String: Set<CorrectionType>] {
        store.correctionTypes(forSourceRefs: Set(sourceRefs))
    }

    /// "Not for me" Corrections recorded after `date` (all of them when
    /// `nil`), newest first: what Rule proposals learn from (ADR 0038).
    public func falsePositives(since date: Date?, limit: Int = 1_000) -> [Correction] {
        store.corrections(ofType: .falsePositive, createdAfter: date, limit: limit)
    }

    private func record(_ type: CorrectionType, from entry: HistoryEntry, output: String) throws {
        guard let chatId = entry.chatId else { return }
        let correction = Correction(
            chatId: chatId, sourceRef: entry.sourceRef, inputText: exampleInput(fromPrompt: entry.renderedContext),
            correctedOutput: output,
            correctionType: type
        )
        try store.replace(correction)
    }
}
