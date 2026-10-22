import DailyOSCore
import Foundation

/// Taking every action on a History Batch, and reading the facts History
/// draws its offers from (history-snapshot). What a Batch offers is
/// `historyBatchOffers`; each action here checks it against facts read at
/// that moment, so a button drawn before something changed does nothing.
///
/// Owned by `AppModel`, which it reaches back to for the Signal Board.
/// `HistoryViewModel` sets `onChange` and re-reads History whenever it
/// fires: after every action, when a Messages pass ends, and when the
/// loaded model changes.
@MainActor
public final class HistoryBatchActions {
    /// Called whenever what History shows may have changed.
    public var onChange: (() -> Void)?

    private weak var app: AppModel?
    private let intake: MessagesIntake
    private let historyStore: any HistoryStore
    private let signalStore: any BatchLedger & MessagesIntakeState
    private let corrections: Corrections
    /// Its toggle decides whether "This was work" is offered, and whether a
    /// Screened Batch offers Add Task instead (screening-optional).
    private let screeningSettings: ScreeningSettings

    init(
        app: AppModel, intake: MessagesIntake, historyStore: any HistoryStore, signalStore: any BatchLedger & MessagesIntakeState,
        corrections: Corrections, screeningSettings: ScreeningSettings
    ) {
        self.app = app
        self.intake = intake
        self.historyStore = historyStore
        self.signalStore = signalStore
        self.corrections = corrections
        self.screeningSettings = screeningSettings
    }

    // MARK: - What's offered

    /// What History needs to know about `batches` to draw them, read now:
    /// the Screening toggle, whether a model is loaded, Muted Chats, and
    /// the Batches' Corrections and Supersessions, one read each. Given
    /// `over`, keeps its toggle, model state and Muted Chats and reads only
    /// the Batches' own facts, for a refresh that needed those first to
    /// know which Batches to read.
    public func facts(forBatches batches: [HistoryBatch], over base: HistoryFacts? = nil) -> HistoryFacts {
        let refs = batches.compactMap(\.sourceRef)
        return HistoryFacts(
            showsScreening: base?.showsScreening ?? screeningSettings.isEnabled,
            isModelLoaded: base?.isModelLoaded ?? (intake.extractor != nil),
            correctionTypes: corrections.types(forBatches: refs), supersessions: signalStore.supersessions(byBatches: refs),
            mutedChats: base?.mutedChats ?? signalStore.mutedChatIds(),
            processedBatches: Set(refs.filter { signalStore.isProcessed(sourceRef: $0) })
        )
    }

    /// What `batch` offers as of now: the guard every action takes.
    private func offersNow(_ batch: HistoryBatch) -> HistoryBatchOffers {
        historyBatchOffers(for: batch, facts: facts(forBatches: [batch]))
    }

    private func isEnabled(_ action: HistoryBatchAction, for batch: HistoryBatch) -> Bool {
        offersNow(batch)[action] == .enabled
    }

    /// Of `suggestions`, the ids of those the Inbox offers "Not for me"
    /// on, in one History read and one read of the facts.
    public func suggestionsOfferingNotForMe(_ suggestions: [Signal]) -> Set<String> {
        let refs = Set(suggestions.lazy.filter { $0.source == .messages }.map(\.sourceRef))
        guard !refs.isEmpty else { return [] }
        let batches = historyStore.batches(forSourceRefs: refs)
        let facts = facts(forBatches: Array(batches.values))
        return Set(suggestions.compactMap { signal in
            guard signal.source == .messages, let batch = batches[signal.sourceRef],
                  inboxOffersNotForMe(batch, facts: facts) else { return nil }
            return signal.id
        })
    }

    // MARK: - Taking them

    /// Records the Correction and dismisses the open Signals the Batch
    /// produced, so one click both teaches the model and clears the task.
    public func notForMe(_ batch: HistoryBatch) {
        guard isEnabled(.notForMe, for: batch), let target = notForMeTarget(batch) else { return }
        try? corrections.recordNotForMe(target.row)
        app?.dismissMessages(sourceRef: target.sourceRef)
        changed()
    }

    /// "Not for me" from the Suggested Tasks Inbox: the same Correction and
    /// dismissal as History's, on the Suggestion's Batch. Does nothing on a
    /// Suggestion the Inbox doesn't offer it on. Returns whether it ran.
    @discardableResult
    public func notForMe(_ suggestion: Signal) -> Bool {
        guard let batch = batch(of: suggestion), inboxOffersNotForMe(batch, facts: facts(forBatches: [batch])) else {
            return false
        }
        notForMe(batch)
        return true
    }

    /// Undoes "Not for me" on the Batch `suggestion` came from: the Undo
    /// bar's way in to `undoNotForMe(_:)`.
    public func undoNotForMe(of suggestion: Signal) {
        guard let batch = batch(of: suggestion) else { return }
        undoNotForMe(batch)
    }

    private func batch(of suggestion: Signal) -> HistoryBatch? {
        guard suggestion.source == .messages else { return nil }
        return historyStore.batches(forSourceRefs: [suggestion.sourceRef])[suggestion.sourceRef]
    }

    /// Undoes "Not for me" on a Batch marked with it (inbox-undo): deletes
    /// the false positive and reopens the Signals it dismissed, whatever
    /// else the Batch or Chat has produced since. A Rule already approved
    /// stays. A mark from before dismissals were noted only loses its
    /// Correction. Returns the ids reopened.
    @discardableResult
    public func undoNotForMe(_ batch: HistoryBatch) -> [String] {
        guard offersNow(batch)[.notForMe] == .taken, let sourceRef = batch.sourceRef else { return [] }
        // A Correction that can't be deleted keeps its Suggestions dismissed,
        // so History and the Inbox never disagree about the mark.
        do { try corrections.removeNotForMe(fromBatch: sourceRef) } catch { return [] }
        let reopened = signalStore.notForMeDismissals(ofBatch: sourceRef)
        app?.reopenMessageSignals(reopened)
        changed()
        return reopened
    }

    /// Records the Correction, then sends the Batch straight to the model,
    /// skipping Screening, so any Signal it holds lands in Suggestions.
    /// Waits for a running pass and then runs its own (ADR 0034).
    public func thisWasWork(_ batch: HistoryBatch) async {
        let facts = facts(forBatches: [batch])
        guard historyBatchOffers(for: batch, facts: facts)[.thisWasWork] == .enabled,
              let target = thisWasWorkTarget(batch, facts: facts) else { return }
        try? corrections.recordThisWasWork(target.row)
        changed()
        await app?.extractNow(sourceRef: target.sourceRef)
        changed()
    }

    /// Records a missed-task Correction with `label` as the right answer
    /// and puts the task in the Suggested Tasks Inbox, made the way the
    /// model's Suggestions are. Adds without taking the pass slot (ADR 0034
    /// note): a running pass read the Chat's open Suggestions before this
    /// lands, so it can't Supersede it.
    public func addTask(_ label: String, to batch: HistoryBatch) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = facts(forBatches: [batch])
        guard !label.isEmpty, historyBatchOffers(for: batch, facts: facts)[.addTask] == .enabled,
              let target = addTaskTarget(batch, facts: facts), let transcript = target.row.transcript else { return }
        try? corrections.recordMissedTask(label: label, for: target.row)
        app?.addMessageSignal(messagesSuggestion(
            label: label, sourceRef: target.sourceRef, chatId: target.chatId, transcript: transcript,
            isSelfThread: target.row.isSelfThread, chatIdentifier: target.row.chatIdentifier
        ))
        changed()
    }

    /// Sends a Batch intake gave up on back to the model, skipping
    /// Screening, so any Signal it holds lands in Suggestions. Records no
    /// Correction. Waits for a running pass and then runs its own (ADR 0034).
    public func tryAgain(_ batch: HistoryBatch) async {
        let facts = facts(forBatches: [batch])
        guard historyBatchOffers(for: batch, facts: facts)[.tryAgain] == .enabled,
              let target = tryAgainTarget(batch, facts: facts) else { return }
        await app?.extractNow(sourceRef: target.sourceRef)
        changed()
    }

    /// Replays the Batch against the model now loaded and records the
    /// result as a new row, never editing the old one.
    public func rerun(_ batch: HistoryBatch) async {
        guard isEnabled(.rerun, for: batch), let row = rerunRow(batch), let extractor = intake.extractor else { return }
        try? await rerunHistoryEntry(row, extractor: extractor, historyStore: historyStore)
        changed()
    }

    /// Mutes the Batch's Chat, or unmutes it. Old rows from the Chat stay,
    /// which is what lets one of them be the way back to Unmute.
    public func toggleMute(_ batch: HistoryBatch) {
        guard let chatId = batch.chatId else { return }
        if offersNow(batch).isMuted {
            unmute(chatId: chatId)
        } else {
            try? signalStore.setMuted(true, chatId: chatId)
            changed()
        }
    }

    /// The one way to Unmute a Chat, from History or from Advanced
    /// (muted-chats-list). Extraction checks Muted on every Batch, so the
    /// Chat's next Batch is judged with nothing else to do.
    public func unmute(chatId: Int) {
        try? signalStore.setMuted(false, chatId: chatId)
        changed()
    }

    /// Puts back in the Suggested Tasks Inbox each Suggestion the Batch
    /// Superseded that can come back, dismissing an UPDATE's replacement
    /// if it is still open. Records no
    /// Correction: the model's answer was wrong about which task is open,
    /// not about whether the Batch held one.
    public func restore(_ batch: HistoryBatch) {
        guard isEnabled(.restore, for: batch), let sourceRef = batch.sourceRef else { return }
        for supersession in signalStore.supersessions(byBatches: [sourceRef])[sourceRef] ?? [] where supersession.isRestorable {
            _ = try? signalStore.restore(signalId: supersession.signalId, supersededIn: sourceRef)
        }
        app?.reloadMessageSignals()
        changed()
    }

    /// Something History shows may have changed: a pass ended, or the
    /// loaded model did.
    func changed() {
        app?.updateNotForMeOffers()
        onChange?()
    }
}
