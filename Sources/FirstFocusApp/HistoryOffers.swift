import FirstFocusCore
import Foundation

/// The actions History offers on a Batch (ADR 0031, 0032, 0036).
public enum HistoryBatchAction: CaseIterable, Sendable {
    /// Records a false positive and dismisses the Signal the Batch produced.
    case notForMe
    /// Records Screening's false negative and sends the Batch to the model.
    case thisWasWork
    /// Records a missed task and puts it in the Suggested Tasks Inbox.
    case addTask
    /// Replays the Batch against the model now loaded and appends a row.
    case rerun
    /// Mute or Unmute the Batch's Chat, whichever it isn't.
    case mute
    /// Puts back in the Inbox a Suggestion the Batch's UPDATE or CANCEL
    /// Superseded (superseded-restore).
    case restore
    /// Sends a Batch the model kept failing on back to it once more, and
    /// keeps any Signals it finds. Records no Correction: the model failed,
    /// it didn't judge wrong.
    case tryAgain
}

/// How an offered action shows.
public enum HistoryActionState: Equatable, Sendable {
    case enabled
    /// Already taken on this Batch, and shown as done: "Marked Not for me",
    /// "Task Added".
    case taken
    /// The Batch allows it but the app can't do it right now. `reason` is
    /// the help text on the disabled button.
    case unavailable(reason: String)
}

/// Why "This was work" and Re-run are disabled while no model is loaded.
public let noModelLoadedReason = "No model loaded"

/// Everything besides a Batch's own rows that decides what it offers,
/// read at one moment (history-snapshot). History reads it once per
/// refresh and draws every row from it; taking an action reads it again,
/// so a button drawn before something changed can't do what the current
/// facts forbid.
public struct HistoryFacts: Equatable, Sendable {
    /// The Screening toggle (screening-optional).
    public var showsScreening: Bool
    public var isModelLoaded: Bool
    /// Each Batch's Correction types, by `sourceRef`.
    public var correctionTypes: [String: Set<CorrectionType>]
    /// What each Batch Superseded, by `sourceRef`.
    public var supersessions: [String: [RecordedSupersession]]
    public var mutedChats: Set<Int>
    /// Which of the Batches are Processed, by `sourceRef`. A Batch the model
    /// failed on is retried until it is (CONTEXT.md: Processed).
    public var processedBatches: Set<String>

    public init(
        showsScreening: Bool, isModelLoaded: Bool, correctionTypes: [String: Set<CorrectionType>],
        supersessions: [String: [RecordedSupersession]], mutedChats: Set<Int>, processedBatches: Set<String> = []
    ) {
        self.showsScreening = showsScreening
        self.isModelLoaded = isModelLoaded
        self.correctionTypes = correctionTypes
        self.supersessions = supersessions
        self.mutedChats = mutedChats
        self.processedBatches = processedBatches
    }

    /// A Batch whose model calls all failed and that intake has stopped
    /// trying.
    public func gaveUp(on batch: HistoryBatch) -> Bool {
        guard case .extractionFailed = batch.result, let sourceRef = batch.sourceRef else { return false }
        return processedBatches.contains(sourceRef)
    }

    public func correctionTypes(of batch: HistoryBatch) -> Set<CorrectionType> {
        batch.sourceRef.flatMap { correctionTypes[$0] } ?? []
    }

    /// Whether the Batch carries a Correction of any type: "Not for me",
    /// "This was work" or "Add task".
    public func isCorrected(_ batch: HistoryBatch) -> Bool {
        !correctionTypes(of: batch).isEmpty
    }

    public func supersessions(of batch: HistoryBatch) -> [RecordedSupersession] {
        batch.sourceRef.flatMap { supersessions[$0] } ?? []
    }

    public func isMuted(_ batch: HistoryBatch) -> Bool {
        batch.chatId.map(mutedChats.contains) ?? false
    }
}

/// What one Batch offers: each action's state, `nil` where it isn't
/// offered, and whether its Chat is Muted, for the Mute button's label.
public struct HistoryBatchOffers: Equatable, Sendable {
    public let states: [HistoryBatchAction: HistoryActionState]
    public let isMuted: Bool

    public subscript(action: HistoryBatchAction) -> HistoryActionState? {
        states[action]
    }
}

/// The one rule for what a History Batch offers. An action is offered only
/// when the Batch has everything its effect needs (a Chat, a Batch
/// reference, a transcript where the effect uses one), and enabled only
/// when the app can do it now, so an enabled button always does something.
public func historyBatchOffers(for batch: HistoryBatch, facts: HistoryFacts) -> HistoryBatchOffers {
    var states: [HistoryBatchAction: HistoryActionState] = [:]
    for action in HistoryBatchAction.allCases {
        states[action] = offerState(action, for: batch, facts: facts)
    }
    return HistoryBatchOffers(states: states, isMuted: facts.isMuted(batch))
}

private func offerState(_ action: HistoryBatchAction, for batch: HistoryBatch, facts: HistoryFacts) -> HistoryActionState? {
    let modelState: HistoryActionState = facts.isModelLoaded ? .enabled : .unavailable(reason: noModelLoadedReason)
    switch action {
    case .notForMe:
        return notForMeState(batch, corrected: facts.correctionTypes(of: batch))
    case .thisWasWork:
        guard thisWasWorkTarget(batch, facts: facts) != nil else { return nil }
        return modelState
    case .addTask:
        guard addTaskTarget(batch, facts: facts) != nil else { return nil }
        return facts.correctionTypes(of: batch).contains(.missedTask) ? .taken : .enabled
    case .rerun:
        guard rerunRow(batch) != nil else { return nil }
        return modelState
    case .mute:
        return batch.chatId == nil ? nil : .enabled
    case .restore:
        return restoreState(facts.supersessions(of: batch))
    case .tryAgain:
        guard tryAgainTarget(batch, facts: facts) != nil else { return nil }
        return modelState
    }
}

/// A missed-task Correction says the Batch held a task, so "Not for
/// me" would contradict it (inbox-not-for-me).
private func notForMeState(_ batch: HistoryBatch, corrected: Set<CorrectionType>) -> HistoryActionState? {
    guard notForMeTarget(batch) != nil, !corrected.contains(.missedTask) else { return nil }
    return corrected.contains(.falsePositive) ? .taken : .enabled
}

/// The Inbox offers "Not for me" on a Suggestion only where "no task" is
/// right for its whole Batch: History would offer it, and the model found
/// this one task and no other (inbox-not-for-me).
func inboxOffersNotForMe(_ batch: HistoryBatch, facts: HistoryFacts) -> Bool {
    guard case .tasks(let labels) = batch.result, labels.count == 1 else { return false }
    return notForMeState(batch, corrected: facts.correctionTypes(of: batch)) == .enabled
}

/// Restore is taken once nothing the Batch Superseded can come back and at
/// least one no longer stands. Not offered when everything that stands
/// can't come back (its replacement Approved or Superseded).
private func restoreState(_ recorded: [RecordedSupersession]) -> HistoryActionState? {
    guard !recorded.isEmpty else { return nil }
    if recorded.contains(where: \.isRestorable) { return .enabled }
    return recorded.allSatisfy(\.stands) ? nil : .taken
}

// MARK: - The row each action works from

/// A row an action records from, with the Chat and Batch the action is
/// scoped to.
struct HistoryActionTarget {
    let row: HistoryEntry
    let chatId: Int
    let sourceRef: String
}

/// The one place the rule lives that a Chat-scoped action needs its row's
/// Chat and Batch.
private func target(_ row: HistoryEntry?) -> HistoryActionTarget? {
    guard let row, let chatId = row.chatId, let sourceRef = row.sourceRef else { return nil }
    return HistoryActionTarget(row: row, chatId: chatId, sourceRef: sourceRef)
}

/// "Not for me" retracts a task the model found.
func notForMeTarget(_ batch: HistoryBatch) -> HistoryActionTarget? {
    guard case .tasks = batch.result else { return nil }
    return target(batch.resultRow)
}

/// A Screened Batch the model hasn't since judged.
private func unjudgedScreenedRow(_ batch: HistoryBatch) -> HistoryEntry? {
    guard batch.wasScreened, batch.resultRow == nil else { return nil }
    return batch.screeningRow
}

/// "This was work": a Screened Batch the model hasn't since judged, while
/// the Screening toggle is on.
func thisWasWorkTarget(_ batch: HistoryBatch, facts: HistoryFacts) -> HistoryActionTarget? {
    guard facts.showsScreening else { return nil }
    return target(unjudgedScreenedRow(batch))
}

/// Try again: a Batch intake gave up on after the model kept failing.
/// While it still has tries left, intake retries it on its own.
func tryAgainTarget(_ batch: HistoryBatch, facts: HistoryFacts) -> HistoryActionTarget? {
    guard facts.gaveUp(on: batch) else { return nil }
    return target(batch.extractionFailureRow)
}

/// "Add task": the model judged the Batch and found nothing, or intake
/// gave up on it after the model kept failing, or, with the Screening
/// toggle off, Screening stopped it before the model saw it
/// (screening-optional). Its Suggestion is made from the transcript, so a
/// row without one can't.
func addTaskTarget(_ batch: HistoryBatch, facts: HistoryFacts) -> HistoryActionTarget? {
    let row: HistoryEntry?
    if batch.result == .noTask {
        row = batch.resultRow
    } else if facts.gaveUp(on: batch) {
        row = batch.extractionFailureRow
    } else if !facts.showsScreening {
        row = unjudgedScreenedRow(batch)
    } else {
        row = nil
    }
    guard let target = target(row), target.row.transcript != nil else { return nil }
    return target
}

/// Re-run replays intake's own input, never an earlier Re-run's. Its row
/// files under the Batch, so a row with no Batch reference has nowhere to
/// go.
func rerunRow(_ batch: HistoryBatch) -> HistoryEntry? {
    guard let row = batch.intakeRow ?? batch.resultRow, row.sourceRef != nil else { return nil }
    return row
}
