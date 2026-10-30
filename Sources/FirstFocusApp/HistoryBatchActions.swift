import FirstFocusCore
import Foundation

/// Taking every action on a History Batch, and reading the facts History
/// draws its offers from (history-snapshot). What a Batch offers is
/// `historyBatchOffers`; each action here checks it against facts read at
/// that moment, so a button drawn before something changed does nothing.
///
/// Owned by `AppModel`. Writes to Messages Signals go through the Signal
/// Board, which keeps its share current; the owner is told through
/// `ownerDidChange` so it can show them.
/// `HistoryViewModel` sets `onChange` and re-reads History whenever it
/// fires: after every action, when a Messages pass ends, and when the
/// loaded model changes.
@MainActor
public final class HistoryBatchActions {
    /// Called whenever what History shows may have changed.
    public var onChange: (() -> Void)?

    public var onRetriedInboxFeedback: ((Signal, @escaping @MainActor () -> Void) -> Void)?
    public private(set) var failures: [AppFailure] = []
    private var retries: [String: () -> Void] = [:]
    private var undoReceipts: [String: (HistoryBatch, FeedbackSnapshot)] = [:]

    public func retryFailure(_ id: String) {
        retries[id]?()
    }

    public func dismissFailure(_ id: String) {
        retries[id] = nil
        failures.removeAll { $0.id == id }
        ownerDidChange(.failure)
    }

    private func failed(_ id: String, message: String, retry: (() -> Void)?) {
        retries[id] = retry
        let failure = AppFailure(id: id, message: message, canRetry: retry != nil)
        if let index = failures.firstIndex(where: { $0.id == id }) { failures[index] = failure }
        else { failures.append(failure) }
        ownerDidChange(.failure)
    }

    /// What the owner has to redo after History changed something.
    enum Change {
        /// A Messages Signal on the Board was added, dismissed or reopened,
        /// so the window's list changes.
        case board
        /// Only what History itself holds changed.
        case history
        case failure
    }

    private let ownerDidChange: (Change) -> Void
    private let board: SignalBoard
    /// Runs "This was work" and Try Again's one-Batch pass (intake-runner).
    private let intakeRunner: IntakeRunner
    /// Whether a model is loaded, and the model a Re-run replays through.
    private let extraction: ExtractionHost
    private let historyStore: any HistoryStore
    private let signalStore: any BatchLedger & MessagesIntakeState
    private let corrections: Corrections
    private let feedback: BatchFeedback?
    /// Its toggle decides whether "This was work" is offered, and whether a
    /// Screened Batch offers Add Task instead (screening-optional).
    private let screeningSettings: ScreeningSettings

    init(
        ownerDidChange: @escaping (Change) -> Void, board: SignalBoard, intakeRunner: IntakeRunner, extraction: ExtractionHost, historyStore: any HistoryStore, signalStore: any BatchLedger & MessagesIntakeState,
        corrections: Corrections, feedback: BatchFeedback?, screeningSettings: ScreeningSettings
    ) {
        self.ownerDidChange = ownerDidChange
        self.board = board
        self.intakeRunner = intakeRunner
        self.extraction = extraction
        self.historyStore = historyStore
        self.signalStore = signalStore
        self.corrections = corrections
        self.feedback = feedback
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
            isModelLoaded: base?.isModelLoaded ?? extraction.isLoaded,
            correctionTypes: corrections.types(forBatches: refs), supersessions: signalStore.supersessions(byBatches: refs),
            mutedChats: base?.mutedChats ?? signalStore.mutedChatIds(),
            processedBatches: signalStore.processedSourceRefs(among: refs)
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
        _ = markNotForMe(batch, suggestion: nil)
    }

    private func markNotForMe(_ batch: HistoryBatch, suggestion: Signal?) -> Bool {
        guard isEnabled(.notForMe, for: batch), let target = notForMeTarget(batch) else { return false }
        let id = "feedback-mark-\(target.sourceRef)"
        do {
            guard let persistence = feedback else { throw FeedbackError.unavailable }
            let snapshot = try persistence.feedbackSnapshot(sourceRef: target.sourceRef)
            return applyNotForMe(batch, suggestion: suggestion, expecting: snapshot, failureID: id, retrying: false)
        } catch {
            feedbackReadFailed(id, sourceRef: target.sourceRef)
            return false
        }
    }

    private func feedbackReadFailed(_ id: String, sourceRef: String) {
        failed(id, message: "Couldn’t read feedback state. Nothing changed. Retry to refresh, then choose the action again.", retry: { [weak self] in
            guard let self else { return }
            do {
                guard let persistence = self.feedback else { throw FeedbackError.unavailable }
                _ = try persistence.feedbackSnapshot(sourceRef: sourceRef)
                self.retries[id] = nil
                self.failures.removeAll { $0.id == id }
                self.board.loadStoredMessages()
                self.changed(.board)
            } catch {
                self.feedbackReadFailed(id, sourceRef: sourceRef)
            }
        })
    }

    private func applyNotForMe(
        _ batch: HistoryBatch, suggestion: Signal?, expecting snapshot: FeedbackSnapshot, failureID: String, retrying: Bool
    ) -> Bool {
        do {
            guard let persistence = feedback, let target = notForMeTarget(batch),
                  isEnabled(.notForMe, for: batch) else { throw FeedbackError.stale }
            if retrying {
                guard let fresh = historyStore.batches(forSourceRefs: [target.sourceRef])[target.sourceRef],
                      fresh.rows.map(\.id) == batch.rows.map(\.id) else {
                    throw FeedbackError.stale
                }
                if suggestion != nil, !inboxOffersNotForMe(batch, facts: facts(forBatches: [batch])) {
                    throw FeedbackError.stale
                }
            }
            let receipt = try persistence.markNotForMe(target.row, expecting: snapshot)
            undoReceipts[target.sourceRef] = (batch, receipt)
            failures.removeAll { $0.id == failureID }
            retries[failureID] = nil
            board.loadStoredMessages()
            changed(.board)
            if retrying, let suggestion {
                onRetriedInboxFeedback?(suggestion, { [weak self] in
                    _ = self?.undoNotForMe(batch, owning: receipt)
                })
            }
            return true
        } catch FeedbackError.stale {
            failed(failureID, message: "Feedback wasn’t retried because this Batch changed. Review its current actions.", retry: nil)
        } catch {
            failed(failureID, message: "Couldn’t save Not for me. Nothing changed.", retry: { [weak self] in
                _ = self?.applyNotForMe(batch, suggestion: suggestion, expecting: snapshot, failureID: failureID, retrying: true)
            })
        }
        return false
    }

    /// "Not for me" from the Suggested Tasks Inbox: the same Correction and
    /// dismissal as History's, on the Suggestion's Batch. Does nothing on a
    /// Suggestion the Inbox doesn't offer it on. Returns whether it ran.
    @discardableResult
    public func notForMe(_ suggestion: Signal) -> Bool {
        guard let batch = batch(of: suggestion), inboxOffersNotForMe(batch, facts: facts(forBatches: [batch])) else {
            return false
        }
        guard signalStore.openSignals().contains(where: { $0.id == suggestion.id && isSuggestion($0) }) else { return false }
        return markNotForMe(batch, suggestion: suggestion)
    }

    /// Undoes "Not for me" on the Batch `suggestion` came from: the Undo
    /// bar's way in to `undoNotForMe(_:)`.
    public func undoNotForMe(of suggestion: Signal) {
        guard let batch = batch(of: suggestion) else { return }
        undoNotForMe(batch)
    }

    public func undoAction(for suggestion: Signal) -> @MainActor () -> Void {
        guard let (batch, snapshot) = undoReceipts[suggestion.sourceRef] else { return {} }
        return { [weak self] in _ = self?.undoNotForMe(batch, owning: snapshot) }
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
        do {
            guard let persistence = feedback else { throw FeedbackError.unavailable }
            return undoNotForMe(batch, owning: try persistence.feedbackSnapshot(sourceRef: sourceRef))
        } catch {
            feedbackReadFailed("feedback-undo-\(sourceRef)", sourceRef: sourceRef)
            return []
        }
    }

    private func undoNotForMe(_ batch: HistoryBatch, owning snapshot: FeedbackSnapshot) -> [String] {
        guard let sourceRef = batch.sourceRef else { return [] }
        let id = "feedback-undo-\(sourceRef)"
        do {
            guard let persistence = feedback else { throw FeedbackError.unavailable }
            let reopened = try persistence.undoNotForMe(sourceRef: sourceRef, owning: snapshot)
            retries[id] = nil
            failures.removeAll { $0.id == id }
            board.loadStoredMessages()
            changed(.board)
            return reopened
        } catch FeedbackError.stale {
            failed(id, message: "Undo wasn’t applied because newer feedback replaced this action. Nothing changed.", retry: nil)
        } catch {
            failed(id, message: "Couldn’t undo Not for me. Nothing changed.", retry: { [weak self] in
                _ = self?.undoNotForMe(batch, owning: snapshot)
            })
        }
        return []
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
        await intakeRunner.extractNow(sourceRef: target.sourceRef)
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
        board.add(messagesSuggestion(
            label: label, sourceRef: target.sourceRef, chatId: target.chatId, transcript: transcript,
            isSelfThread: target.row.isSelfThread, chatIdentifier: target.row.chatIdentifier
        ))
        changed(.board)
    }

    /// Sends a Batch intake gave up on back to the model, skipping
    /// Screening, so any Signal it holds lands in Suggestions. Records no
    /// Correction. Waits for a running pass and then runs its own (ADR 0034).
    public func tryAgain(_ batch: HistoryBatch) async {
        let facts = facts(forBatches: [batch])
        guard historyBatchOffers(for: batch, facts: facts)[.tryAgain] == .enabled,
              let target = tryAgainTarget(batch, facts: facts) else { return }
        await intakeRunner.extractNow(sourceRef: target.sourceRef)
        changed()
    }

    /// Replays the Batch against the model now loaded and records the
    /// result as a new row, never editing the old one.
    public func rerun(_ batch: HistoryBatch) async {
        guard isEnabled(.rerun, for: batch), let row = rerunRow(batch), let extractor = extraction.loadedModel else { return }
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

    /// The Chats Muted now, without reading anything else History draws from.
    public func mutedChatIds() -> Set<Int> {
        signalStore.mutedChatIds()
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
            board.restore(signalId: supersession.signalId, supersededIn: sourceRef)
        }
        changed(.board)
    }

    /// Something History shows may have changed: a pass ended, or the
    /// loaded model did.
    func changed(_ change: Change = .history) {
        ownerDidChange(change)
        onChange?()
    }
}
