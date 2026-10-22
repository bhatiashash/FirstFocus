import Foundation

/// Signal durable state, in six protocols. Five are split along who
/// calls them (ADR 0021). The Batch Ledger is grouped around the Batch
/// instead, because every one of its callers asks about Batches (ADR 0021,
/// amended 2026-09-26). `SignalStore` composes all six back into the one
/// type `SQLiteSignalStore` implements in full; tests run against it too,
/// on a file of their own.
public protocol SignalStore: BatchLedger, MessagesIntakeState, SignalBoardStore, CheckOffStore, FocusListStore, SnoozeStore {}

/// The durable record of what Extraction produced from each Batch.
/// Load-bearing rather than convenient: Extraction never re-runs on a
/// Batch it has already judged, so this is the only durable copy of a
/// Messages Signal's content. Every question about a Batch is answered
/// here, including the one rule about messages Processed before Batches
/// existed: each counts as a Batch of one, named by its own id.
public protocol BatchLedger: Sendable {
    /// Whether `sourceRef` (a Messages message id) has already gone
    /// through Extraction, whether or not that run produced any Signals.
    func isProcessed(sourceRef: String) -> Bool

    /// Marks every message in `batch` Processed, records which messages
    /// the Batch held (ADR 0039), and stores `signals` (possibly empty),
    /// all in one transaction. It fails if any member is already
    /// Processed, so no message ever belongs to two Batches. `signals`
    /// carry the ids they will keep for the life of the app, minted once
    /// by the caller, never recomputed here. Each Suggestion in
    /// `superseding` is marked Superseded (ADR 0040), but only one still
    /// Open and inferred when the write lands, so an Approve or Dismiss
    /// that got there first always wins.
    func recordProcessedBatch(_ batch: MessageBatch, signals: [Signal], superseding: [Supersession]) throws

    /// Notes that the model failed on `batch` once more, and returns how
    /// many times it has failed on it, counted per message so a Batch that
    /// picks up a later message on its next try keeps its count. Never
    /// marks anything Processed; the caller decides when to stop trying
    /// (CONTEXT.md: Processed).
    func recordExtractionFailure(_ batch: MessageBatch) throws -> Int

    /// The member message ids of the Batch named `batchId`, oldest first.
    /// A message Processed before batching is a Batch of one, so a
    /// `batchId` with no Batch recorded gives just `[batchId]`. Only a
    /// Batch's id names it; asking with another member's id gives that
    /// member alone. `nil` when the store can't be read, which callers
    /// must never mistake for a Batch of one.
    func members(ofBatch batchId: String) -> [String]?

    /// What each Batch in `batchIds` Superseded, keyed by Batch id, in the
    /// order it was recorded. A Batch that Superseded nothing, or did so
    /// before the store recorded it, is absent. A Suggestion since removed
    /// by garbage collection is left out.
    func supersessions(byBatches batchIds: [String]) -> [String: [RecordedSupersession]]

    /// Undoes a Supersession (superseded-restore): puts `signalId` back in
    /// the Suggested Tasks Inbox under the same id, its content untouched,
    /// and dismisses an UPDATE's replacement if it is still open. Only
    /// when the Supersession `batchId` recorded is still restorable as the
    /// write lands (`RecordedSupersession.isRestorable`); returns whether
    /// it was.
    func restore(signalId: String, supersededIn batchId: String) throws -> Bool

    /// The Signals against the Batch `batchId` that "Not for me" dismissed
    /// and that are still Dismissed (inbox-undo). A dismissal from before
    /// the store noted this is not among them.
    func notForMeDismissals(ofBatch batchId: String) -> [String]

    /// Every stored Signal still in the `open` state. The one place
    /// Messages Intake reads back what Extraction (and everything since)
    /// has produced — `SignalBoard` never calls this directly, it only
    /// ever sees Intake's return value.
    func openSignals() -> [Signal]

    /// Processed Messages items with no open, checked-off, or approved
    /// Signal — either Extraction found nothing, or every Signal it did
    /// find has since been dismissed. Ticket 12's manual re-extraction only
    /// ever revisits this set; an item currently holding live work (open,
    /// checked off, or approved into a real reminder) is never a candidate
    /// (ADR 0004).
    func reExtractionCandidates() -> [String]

    /// Inserts an additional Signal against an item re-extraction
    /// revisited. Unlike `recordProcessedBatch`, this never touches
    /// `processed_messages` — the item is already Processed — and never
    /// touches any existing Signal row. Purely additive, so a message can
    /// end up carrying an old dismissed Signal and a newer open one side by
    /// side (ADR 0004).
    func recordReExtractedSignals(sourceRef: String, signals: [Signal]) throws

    /// Every Batch that currently holds at least one Signal, in any state,
    /// by id. The candidates `vanishedBatches` checks against a fresh
    /// fetch.
    func batchesWithSignals() -> [String]

    /// Removes every Signal against the Batch `batchId` names, in any
    /// state. Called only for a Batch `vanishedBatches` returned. Leaves
    /// Processed and the recorded Batch untouched: Processed is permanent
    /// (see `isProcessed`), so a message that somehow reappeared still
    /// never re-enters Extraction.
    func garbageCollectSignals(ofBatch batchId: String) throws
}

public extension BatchLedger {
    /// A Batch whose answer Supersedes no Suggestion.
    func recordProcessedBatch(_ batch: MessageBatch, signals: [Signal]) throws {
        try recordProcessedBatch(batch, signals: signals, superseding: [])
    }

    /// The Batches holding Signals whose every message is gone from
    /// Messages, given a fresh fetch in `messages`. Unsending one message
    /// leaves its Batch standing.
    ///
    /// Missing from the fetch is never enough on its own: a transient read
    /// failure or the Gate going Unavailable look the same as a real
    /// vanish from a bulk fetch. Every member must also be confirmed gone
    /// by `source.isGone(sourceRef:)`, and its `nil` ("can't tell") counts
    /// as still there. A Batch Processed with no Signal has nothing to
    /// collect and is never returned.
    func vanishedBatches(among messages: [ChatMessage], source: any MessagesSource) -> [String] {
        let fetchedIds = Set(messages.map(\.id))
        return batchesWithSignals().filter { batchId in
            guard let members = members(ofBatch: batchId) else { return false }
            return members.allSatisfy { !fetchedIds.contains($0) }
                && members.allSatisfy { source.isGone(sourceRef: $0) == true }
        }
    }

    /// The Batches `messages` holds once everything already Processed is
    /// set aside.
    func unprocessedBatches(in messages: [ChatMessage], now: Date?) -> BatchClosing {
        closeBatches(messages.filter { !isProcessed(sourceRef: $0.id) }, now: now)
    }
}

extension BatchLedger {
    /// The Batch `batchId` names, rebuilt from whichever of its members
    /// `messages` still holds. `nil` when none of it is left to read.
    func batch(named batchId: String, in messages: [ChatMessage]) -> MessageBatch? {
        guard let members = members(ofBatch: batchId).map(Set.init) else { return nil }
        let present = messages.filter { members.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        return present.isEmpty ? nil : MessageBatch(messages: present)
    }

    /// A Chat's undecided Suggestions, newest first, as the model sees them
    /// numbered. One saved before Signals carried their Chat is matched
    /// through its source message instead, while that message is still in
    /// `messages`.
    func openSuggestions(forChat chatId: Int, in messages: [ChatMessage]) -> [Signal] {
        let chatMessageIds = Set(messages.lazy.filter { $0.chatId == chatId }.map(\.id))
        return openSignals()
            .filter { signal in
                isSuggestion(signal) && signal.source == .messages
                    && (signal.chatId == chatId || (signal.chatId == nil && chatMessageIds.contains(signal.sourceRef)))
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maxOpenSuggestionsShown)
            .map { $0 }
    }
}

/// Housekeeping `Messages Intake` owns beyond the Batch Ledger:
/// first-run backfill, the signing-identity Gate check, the non-self
/// Messages cutoff, and Automated Chat tracking. None of it is about any
/// one Signal, which is what separates it from `SignalBoardStore` — a
/// `SignalBoard` fake never needs to implement any of this.
public protocol MessagesIntakeState: Sendable {
    /// Whether the first-run backfill (ticket 08) has ever finished. A
    /// one-way flag: once set, later launches skip straight to the ranked
    /// list rather than re-walking the whole self-thread history (backfill
    /// is still self-thread-only, per ADR 0007) to
    /// rediscover that everything's already Processed.
    func isBackfillComplete() -> Bool

    /// Records that the backfill has finished. Never unset.
    func markBackfillComplete() throws

    /// The signing identity recorded after the last successful self-thread
    /// read, or `nil` if none has been recorded yet (first run, or every
    /// attempt so far has failed). See `identityMismatch`.
    func storedSigningIdentity() -> String?

    /// Records `identity` as the one to compare future launches against.
    func recordSigningIdentity(_ identity: String) throws

    /// ADR 0007: the moment a non-self Chat's history first started being
    /// read, recorded once and never moved. `MessagesSource.listMessages`
    /// uses this as the floor below which a non-self message is never
    /// included, so widening the Messages source past the self-thread
    /// never backfills what already existed in `chat.db` before this
    /// shipped. `nil` before the first successful read.
    func nonSelfMessagesCutoff() -> Date?

    /// Records `date` as the cutoff. Never called again once a value is
    /// already stored — see `nonSelfMessagesCutoff`.
    func recordNonSelfMessagesCutoff(_ date: Date) throws

    /// Ticket 02, Rule B: whether `chatId` has ever produced a one-time
    /// code or similar machine-generated content. An Automated Chat is
    /// excluded from every future `MessagesSource.listMessages` call,
    /// checked before the confidentiality check, the heuristic, or the
    /// model ever sees a message from it.
    func isAutomated(chatId: Int) -> Bool

    /// Marks `chatId` Automated, permanently — see CONTEXT.md: Automated.
    func markAutomated(chatId: Int) throws

    /// The one exception to "permanently" (ADR 0007 amendment): a self-chat
    /// marked before the self-thread was exempt from the rule. Messages
    /// Intake calls this only for self-chat ids; nothing else un-marks.
    func unmarkAutomated(chatId: Int) throws

    /// Every currently Automated chat id. `MessagesSource.listMessages`'s
    /// `excludingChatIds` is meant to be this — fetched once per reload and
    /// handed to the source, so an Automated Chat's messages are excluded
    /// at the read itself rather than fetched and decoded only to be
    /// dropped by `isAutomated(chatId:)` moments later during Extraction.
    func automatedChatIds() -> Set<Int>

    /// Mute Thread (ADR 0032): whether the user has explicitly opted
    /// `chatId` out of Extraction. Checked in `Extraction.swift`'s guard
    /// chain alongside `isAutomated(chatId:)` — unlike that one, this is
    /// reversible (see `setMuted(_:chatId:)`) and never set by anything
    /// but an explicit History row action.
    func isMuted(chatId: Int) -> Bool

    /// Sets or clears `chatId`'s Muted state. Unlike `markAutomated`, this
    /// can be called with `false` to reverse a prior mute.
    func setMuted(_ isMuted: Bool, chatId: Int) throws

    /// Every currently Muted chat id, for History to keep a way back to
    /// Unmute (ADR 0031).
    func mutedChatIds() -> Set<Int>
}

/// Per-Signal state the Signal Board reads and writes: manual Focus order,
/// Snooze, Sender-on-approval, and every verb but Check off itself
/// (see `CheckOffStore`). `SignalBoard`'s own hydration
/// (`focusOrder`/`snoozedUntil`/`approvedSender`, read fresh on every
/// `rankedList(now:hiding:)` call) and its nine remaining verbs are the
/// entire caller list for this protocol.
public protocol SignalBoardStore: Sendable {
    /// Marks a stored Signal dismissed: a fact recorded and nothing more.
    /// Distinct from checked off (see CONTEXT.md: Dismiss), writes nothing
    /// to any Source, and never feeds back into Extraction.
    func dismiss(signalId: String) throws

    /// `dismiss(signalId:)`, noting that "Not for me" did it, so undoing
    /// "Not for me" reopens this Signal and no other (inbox-undo).
    func dismissByNotForMe(signalId: String) throws

    /// Marks a stored Signal approved, carrying the id of the reminder
    /// `TaskSource.create` already minted for it (Suggested Tasks Inbox,
    /// Focus Mode v2). Writes nothing to any Source itself — creating the
    /// reminder is the caller's job before calling this — and never
    /// mutates or removes the Signal row otherwise, so it stays around as
    /// a record of what it became.
    func approve(signalId: String, reminderId: String) throws

    /// Undo (inbox-undo, ADR 0043): puts a Dismissed or Approved Signal
    /// back to open under the same id, its content untouched, forgetting
    /// the reminder an Approve recorded. A Signal in any other state is
    /// left alone. Deleting that reminder is the caller's job.
    func reopen(signalId: String) throws

    /// One-click promotion (ticket 05): sets a stored Messages Signal's
    /// priority to `.high`, the same local durability check-off already
    /// has for that source. Never touches `state`. Only ever called for a
    /// Messages Signal — a Reminders Signal's priority write goes through
    /// `TaskSource.update` instead (ADR 0009: no persisted manual order).
    func promote(signalId: String) throws

    /// One-click demotion: the reverse of `promote`, clearing a stored
    /// Messages Signal's priority back to `.none`. Same scope as
    /// `promote` — Messages only, never touches `state`.
    func demote(signalId: String) throws

    /// Manual Focus ordering (ADR 0011, supersedes ADR 0009): the position
    /// a user last dragged this Signal to within Focus, or `nil` if it's
    /// never been manually placed. Keyed by Signal id independent of
    /// source — the one place a Reminders-sourced Signal (never itself a
    /// persisted row anywhere; `TaskSource` is the source of truth for
    /// everything else about it) has any durable local state at all.
    func focusOrder(signalId: String) -> Int?

    /// Persists every id → position pair in `orders` as the new manual
    /// Focus order, upserting each in place — an id not present in
    /// `orders` keeps whatever it already had. A drag reorders the whole
    /// currently-visible Focus list at once (`SignalBoard.reorderFocus`),
    /// never a single position in isolation, so there's no separate
    /// "set one" method.
    func setFocusOrders(_ orders: [String: Int]) throws

    /// Forgets where a Signal was dragged to, so it takes its computed
    /// place again. Unchecking a reminder does this: the drag order it had
    /// described a list that has since changed.
    func clearFocusOrder(signalId: String) throws

    /// Sender-on-approval: the Sender an approved Messages Signal came
    /// from, keyed by the real reminder's id it became — the only place
    /// that survives, since `ReminderTask`/`EKReminder` has no Sender
    /// concept at all (see CONTEXT.md: Sender). `nil` for any reminder not
    /// approved from a Messages Signal with a resolved sender name — a
    /// reminder created directly, promoted, or approved from an unresolved
    /// raw address never has an entry here.
    func approvedSender(reminderId: String) -> String?

    /// Records `sender` against `reminderId`, called once at the same time
    /// as `approve(signalId:reminderId:)` — never for any other reminder.
    func recordApprovedSender(reminderId: String, sender: String) throws

    /// Undo of an Approve (inbox-undo): the reminder is gone, so is the
    /// Sender recorded against it. A no-op if none was.
    func forgetApprovedSender(reminderId: String) throws

    /// `focusOrder(signalId:)`, batched: every entry in `signalIds` that
    /// has a manual Focus order, keyed by its own id. An id with no entry
    /// is simply absent from the result rather than mapped to `nil` — the
    /// same "never manually placed" meaning `focusOrder` gives it.
    /// `SignalBoard.hydrate` calls this once per `rankedList` read instead
    /// of once per Signal, the shape every other lookup here already has.
    func focusOrders(signalIds: [String]) -> [String: Int]

    /// `approvedSender(reminderId:)`, batched — see `focusOrders(signalIds:)`.
    func approvedSenders(reminderIds: [String]) -> [String: String]

}

/// Snooze's record (ticket 04, ADR 0045), whose one caller is the Snooze
/// module (`Snoozes`). Keyed by Signal id independent of source: a
/// Reminders Signal is never itself a row in `signals`, so this can't live
/// there. Never writes to the underlying Source (CONTEXT.md: Snoozed).
public protocol SnoozeStore: Sendable {
    /// The moment before which `signalId` stays off the Ranked List, or
    /// `nil` if it isn't snoozed.
    func snoozedUntil(signalId: String) -> Date?

    /// `snoozedUntil(signalId:)`, batched: an id with no snooze is absent.
    func snoozedUntils(signalIds: [String]) -> [String: Date]

    /// The due date each Snoozed reminder had when it was snoozed, for those
    /// in `signalIds` that had one.
    func snoozedDueDates(signalIds: [String]) -> [String: Date]

    /// Snoozes `signalId` until `until`, replacing any snooze it had, and
    /// keeps the due date it has now.
    func snooze(signalId: String, until: Date, dueAt: Date?) throws

    /// Ends `signalId`'s snooze, if it has one.
    func unsnooze(signalId: String) throws
}

public extension SnoozeStore {
    func snooze(signalId: String, until: Date) throws {
        try snooze(signalId: signalId, until: until, dueAt: nil)
    }
}

/// The Focus list's record (ADR 0048): the reminders that were in it at
/// the last sync, with the list each goes back to. Its own protocol, since
/// its one caller is the Focus list module (ADR 0021).
public protocol FocusListStore: Sendable {
    /// `nil` when the store can't be read, which a caller must never
    /// mistake for an empty list: that would read every reminder in the
    /// list as one you just put there.
    func focusListPlacements() -> [FocusListPlacement]?

    /// Replaces every placement with `placements`.
    func setFocusListPlacements(_ placements: [FocusListPlacement]) throws
}

/// The write-through half of Check off, isolated to its own one-method
/// protocol rather than folded into `SignalBoardStore`: `checkOff` is a
/// `SignalBoardStore`-shaped verb by nature, but it is called from
/// `CheckOffCoordinator`, a module `SignalBoard` doesn't own and that owns
/// no other per-Signal state — see ADR 0020's note on why check off's
/// write stayed a narrow seam of its own rather than moving wholesale.
public protocol CheckOffStore: Sendable {
    /// Marks a stored Signal checked off. Writes nothing to any Source —
    /// a Messages check-off is local to this store.
    func checkOff(signalId: String) throws
}

public enum SignalStoreError: Error {
    case cannotOpen
    case writeFailed
    case signalNotFound(id: String)
}
