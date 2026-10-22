import Foundation

/// Every Signal currently known, across both Sources, before any ordering,
/// deduplication or filtering (CONTEXT.md: Signal Board). Owns
/// `TaskSource`, `SignalStore` and both per-Source arrays. Messages Intake
/// is not behind it: the caller runs intake and hands each result to
/// `apply(messages:)` (ADR 0020, amended 2026-09-26). The fact that used
/// to be kept three ways (`reminderSignals`, `messageSignals`, and the
/// published `signals` a caller had to remember to re-derive after every
/// write) collapses to one: the two arrays here, with everything else
/// computed fresh by `rankedList(now:hiding:)`.
///
/// `focusOrder`, `snoozedUntil` and Sender-on-approval are never patched
/// into the arrays after a write the way they used to be — `rankedList`
/// reads all three straight from `SignalStore` on every call, so a write
/// through `snooze(_:until:)` or `reorderFocus` needs nothing more than
/// the store write itself to show up on the very next read.
///
/// `@MainActor`: matches `MessagesIntake`, and every call site (AppModel)
/// already lives there.
@MainActor
public final class SignalBoard {
    private let taskSource: any TaskSource
    private let signalStore: any SignalBoardStore
    /// Every way a snooze starts and ends. The Board reads snoozes through
    /// it and tells it about each Reminders fetch.
    public let snoozes: Snoozes

    private var reminderSignals: [Signal] = []
    private var messageSignals: [Signal] = []
    /// Today's checked-off reminders (CONTEXT.md: Checked Off). Never
    /// ranked and never part of the Ranked List.
    private var checkedOffReminders: [CheckedOffReminder] = []
    /// Counts Reminders fetches, so a fetch that finishes after a later
    /// one started throws its older read away instead of replacing the
    /// newer one's.
    private var reminderFetchCount = 0
    /// Which fetch `reminderSignals` came from, 0 before any.
    private var remindersReadAt = 0
    /// Each reminder's list, open and checked off, from the last fetch.
    private var reminderListIds: [String: String] = [:]
    /// Read only to bound the checked-off fetch to today.
    private let now: @MainActor () -> Date
    /// What the last read of each Source found about its Gate. Recorded
    /// by every read, including one a verb's refetch makes, so a Gate
    /// revoked mid-session shows as soon as anything reads that Source.
    private var availabilities: [Source: SourceAvailability] = [:]

    public init(
        taskSource: any TaskSource, signalStore: any SignalBoardStore & SnoozeStore,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.taskSource = taskSource
        self.signalStore = signalStore
        self.snoozes = Snoozes(store: signalStore)
        self.now = now
    }

    // MARK: - Refresh

    /// Whether `source` could be read last time it was: `.unavailable`
    /// once a read found its Gate missing, `.available` before any read.
    public func availability(of source: Source) -> SourceAvailability {
        availabilities[source] ?? .available
    }

    /// Re-fetches Reminders and replaces its share of the Board: the open
    /// reminders and those checked off since the start of today.
    public func refreshReminders() async {
        reminderFetchCount += 1
        let fetch = reminderFetchCount
        guard taskSource.availability() == .available else {
            reminderSignals = []
            checkedOffReminders = []
            reminderListIds = [:]
            remindersReadAt = 0
            availabilities[.reminders] = .unavailable
            return
        }
        let source = taskSource
        let since = Calendar.current.startOfDay(for: now())
        let (tasks, checkedOff) = await Task.detached {
            (source.listOpenTasks(), source.listCheckedOffTasks(since: since))
        }.value
        guard fetch == reminderFetchCount else { return }
        reminderSignals = tasks.map(makeSignal(from:))
        checkedOffReminders = checkedOff
        reminderListIds = Dictionary(
            (checkedOff.map(\.task) + tasks).compactMap { task in task.listId.map { (task.id, $0) } },
            uniquingKeysWith: { _, open in open }
        )
        remindersReadAt = fetch
        availabilities[.reminders] = .available
        snoozes.remindersFetched(open: tasks, checkedOff: checkedOff)
    }

    /// Replaces the Messages share with what a Messages Intake pass
    /// produced. `.extractionUnavailable` deliberately leaves the share
    /// exactly as it was, never clearing it, since there's a Gate open and
    /// real Signals behind it, just no model to re-derive them with.
    /// `.notRead` changes nothing: no read means nothing was learned.
    public func apply(messages result: MessagesIntake.Result) {
        switch result {
        case .unavailable:
            messageSignals = []
            availabilities[.messages] = .unavailable
        case .extractionUnavailable:
            availabilities[.messages] = .available
        case .notRead:
            break
        case .refreshed(let signals):
            messageSignals = signals
            availabilities[.messages] = .available
        }
    }

    /// Replaces the Messages share with Signals read back from the store
    /// (ADR 0035) rather than from a pass. Reads nothing from Messages, so
    /// it leaves the Source's availability as the last pass found it.
    public func seed(messages signals: [Signal]) {
        messageSignals = signals
    }

    // MARK: - Reading

    /// Every Signal the window should show, ordered, tiered, deduplicated,
    /// and split into the Suggested Tasks Inbox versus everything else —
    /// derived fresh from the Board on every call, never stored (ADR
    /// 0020). `hiding` excludes ids before dedup, tiering or the Later
    /// cap ever sees them: the Signal mid-undo-window, the ones mid-write,
    /// or one being optimistically deleted. The Board never learns why any
    /// of them are hidden.
    public func rankedList(now: Date, hiding: Set<String> = []) -> RankedList {
        var combined = reminderSignals + messageSignals
        combined.removeAll { hiding.contains($0.id) }
        combined = hydrate(combined)

        let suggested = suggestedTasksInbox(combined)
        let notSuggested = combined.filter { !isSuggestion($0) }
        let ranked = rank(notSuggested, now: now)
        let focus = ranked.filter { tier(for: $0, now: now) == .focus }
        let later = ranked.filter { tier(for: $0, now: now) == .later }
        let snoozed = notSuggested
            .filter { isSnoozed($0, now: now) }
            .sorted { ($0.snoozedUntil!, $0.label) < ($1.snoozedUntil!, $1.label) }
        let laterCount = deduplicateByLabel(notSuggested.filter { !isSnoozed($0, now: now) })
            .filter { tier(for: $0, now: now) == .later }
            .count
        return RankedList(focus: focus, later: later, suggested: suggested, snoozed: snoozed, laterCount: laterCount)
    }

    /// The Checked Off sheet's rows: reminders checked off on `now`'s
    /// day, newest first. Judged against `now` rather than the fetch, so
    /// after midnight yesterday's rows drop out before the next fetch.
    /// `hiding` is the same set `rankedList` takes.
    public func checkedOff(now: Date, hiding: Set<String> = []) -> [CheckedOffReminder] {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return checkedOffReminders
            .filter { $0.checkedOffAt >= startOfDay && !hiding.contains($0.id) }
            .sorted { $0.checkedOffAt > $1.checkedOffAt }
    }

    /// Manual Focus order (`focusOrder`), Snooze (`snoozedUntil`)
    /// and Sender-on-approval are read fresh here rather than kept on the
    /// arrays — the three chains that used to be hydrated in three
    /// different nestings at three different call sites collapse to one.
    /// Sender-on-approval stays Reminders-only, exactly as it always was:
    /// `approvedSender(reminderId:)` is keyed by a real reminder id, and a
    /// Messages Signal's `sourceRef` is a chat.db message id that will
    /// never match one — applying this unconditionally would overwrite an
    /// already-resolved Messages Sender with `nil` on every lookup miss.
    ///
    /// Batched (`focusOrders(signalIds:)` etc.) rather than one lookup per
    /// Signal: this runs on every verb and every poll tick, against every
    /// open Signal, not just the 25 `Ranking.swift` eventually keeps —
    /// three round trips beats up to three per Signal.
    private func hydrate(_ signals: [Signal]) -> [Signal] {
        let signalIds = signals.map(\.id)
        let reminderIds = signals.filter { $0.source == .reminders }.map(\.sourceRef)
        let focusOrders = signalStore.focusOrders(signalIds: signalIds)
        let snoozedUntils = snoozes.untils(signalIds: signalIds)
        let approvedSenders = signalStore.approvedSenders(reminderIds: reminderIds)
        return signals.map { signal in
            var updated = signal
            updated.focusOrder = focusOrders[signal.id]
            updated.snoozedUntil = snoozedUntils[signal.id]
            if signal.source == .reminders {
                updated.sender = approvedSenders[signal.sourceRef]
            }
            return updated
        }
    }

    // MARK: - Verbs

    /// Messages Signals only: Dismiss means "Extraction produced a false
    /// positive," and a Reminders Signal never went through Extraction
    /// (CONTEXT.md: Dismiss).
    public func dismiss(_ signal: Signal) {
        guard signal.source == .messages else { return }
        messageSignals.removeAll { $0.id == signal.id }
        try? signalStore.dismiss(signalId: signal.id)
    }

    /// Undo of a Dismiss (inbox-undo): the Signal is open again in the
    /// store. The caller re-reads stored Signals onto the Board.
    public func reopen(signalId: String) {
        try? signalStore.reopen(signalId: signalId)
    }

    /// One-click promotion (ticket 05). A Reminders Signal writes through
    /// to Reminders and the Board re-fetches to pick it back up; a
    /// Messages Signal is recorded locally, the same durability
    /// `checkOff` already gives that Source.
    /// "Not for me" (ADR 0031 amendment): dismisses every open Messages
    /// Signal minted from the message `sourceRef` names.
    /// Each is noted as dismissed by "Not for me", so undoing it reopens
    /// these and no other (inbox-undo).
    public func dismiss(sourceRef: String) {
        for signal in messageSignals where signal.sourceRef == sourceRef {
            messageSignals.removeAll { $0.id == signal.id }
            try? signalStore.dismissByNotForMe(signalId: signal.id)
        }
    }

    public func promote(_ signal: Signal) async {
        await setPriority(on: signal, priority: .high) { [signalStore] in
            try? signalStore.promote(signalId: $0)
        }
    }

    /// One-click demotion: the reverse of `promote`.
    public func demote(_ signal: Signal) async {
        await setPriority(on: signal, priority: .none) { [signalStore] in
            try? signalStore.demote(signalId: $0)
        }
    }

    /// `promote`/`demote`'s shared shape: a Reminders Signal writes its
    /// priority through and the Board re-fetches; a Messages Signal
    /// is updated locally and durably recorded via `writeLocally`. Neither
    /// caller passes a throwing `writeLocally` — both already discard the
    /// store write's error the same way `checkOff` does for this Source.
    private func setPriority(
        on signal: Signal, priority: Priority, writeLocally: (String) -> Void
    ) async {
        switch signal.source {
        case .reminders:
            let taskSource = self.taskSource
            let id = signal.sourceRef
            await Task.detached { try? taskSource.update(id: id, .priority(priority)) }.value
            await refreshReminders()
        case .messages:
            guard let index = messageSignals.firstIndex(where: { $0.id == signal.id }) else { return }
            messageSignals[index].priority = priority
            writeLocally(signal.id)
        }
    }

    /// Manual Focus ordering (ADR 0011). `currentFocusIds` is the caller's
    /// own currently-visible Focus order (what `rankedList(...).focus`
    /// last returned) rather than something the Board re-derives, so a
    /// drag reorders exactly what the user is looking at, `hiding` and
    /// all, not a fresh recompute that might disagree with it.
    public func reorderFocus(draggedId: String, droppedOnId: String, currentFocusIds: [String]) {
        guard let orders = reorderedFocusPositions(
            draggedId: draggedId, droppedOnId: droppedOnId, currentFocusIds: currentFocusIds
        ) else { return }
        try? signalStore.setFocusOrders(orders)
    }

    /// Suggested Tasks Inbox: mints a real reminder, marks the originating
    /// Messages Signal `approved` with its id, and folds in a resolved
    /// Sender when there is one (CONTEXT.md: Approve, Sender).
    /// Returns the new reminder's id, or `nil` if nothing was created.
    @discardableResult
    /// `snoozedUntil`, when given, is written for the new reminder before
    /// the Board re-fetches, so no read in between finds it unsnoozed
    /// (ADR 0045: Approve & Snooze).
    public func approve(_ signal: Signal, snoozedUntil: Date? = nil) async -> String? {
        guard signal.source == .messages, signal.provenance == .inferred else { return nil }
        let taskSource = self.taskSource
        let draft = approvedReminderDraft(from: signal)
        let created: ReminderTask? = await Task.detached { try? taskSource.create(draft) }.value
        guard let created else { return nil }
        try? signalStore.approve(signalId: signal.id, reminderId: created.id)
        if let snoozedUntil { snoozes.snooze(signalId: created.id, until: snoozedUntil, dueAt: created.dueAt) }
        if let sender = signal.sender, isResolvedSenderName(sender) {
            try? signalStore.recordApprovedSender(reminderId: created.id, sender: sender)
        }
        messageSignals.removeAll { $0.id == signal.id }
        await refreshReminders()
        return created.id
    }

    /// Undo of an Approve (inbox-undo, ADR 0043): deletes the reminder by
    /// the id Approve returned, whatever became of it since (already gone
    /// is fine), forgets its Sender, and puts the Signal back to open. The
    /// caller re-reads stored Signals onto the Board.
    public func unapprove(signalId: String, reminderId: String) async {
        let taskSource = self.taskSource
        await Task.detached { try? taskSource.delete(id: reminderId) }.value
        try? signalStore.forgetApprovedSender(reminderId: reminderId)
        snoozes.end(signalId: reminderId)
        try? signalStore.reopen(signalId: signalId)
        await refreshReminders()
    }

    /// Bidirectional Reminders sync: writes through, then re-fetches
    /// rather than patching `reminderSignals` by hand, so the Board always
    /// reflects exactly what Reminders itself now reports.
    /// `priority` lets a task typed into Focus stay in Focus: with none,
    /// a new reminder lands in Later.
    /// Returns the new reminder's Signal id, or `nil` if nothing was created.
    @discardableResult
    public func createTask(title: String, priority: Priority = .none, dueAt: Date? = nil) async -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let taskSource = self.taskSource
        let created = await Task.detached { try? taskSource.create(ReminderDraft(title: trimmed, dueAt: dueAt, priority: priority)) }.value
        await refreshReminders()
        return created?.id
    }

    /// Reminders Signals only. Writes the title, and the due date only when
    /// the new title carried a date phrase (`dueAt`); nothing else.
    public func renameTask(_ signal: Signal, to newTitle: String, dueAt: Date? = nil) async {
        guard signal.source == .reminders else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let taskSource = self.taskSource
        let id = signal.sourceRef
        await Task.detached {
            try? taskSource.update(id: id, .title(trimmed))
            if let dueAt { try? taskSource.update(id: id, .dueDate(dueAt)) }
        }.value
        await refreshReminders()
    }

    /// Reopens a reminder from the Checked Off sheet and re-fetches, so
    /// it lands in Focus or Later by the ordinary Tier rules, at its
    /// computed place rather than wherever it was once dragged. Refuses a
    /// recurring reminder: reopening it would fork the recurrence into
    /// duplicate reminders.
    public func uncheck(_ reminder: CheckedOffReminder) async {
        guard !reminder.isRecurring else { return }
        let taskSource = self.taskSource
        await Task.detached { try? taskSource.reopen(id: reminder.id) }.value
        try? signalStore.clearFocusOrder(signalId: reminder.id)
        snoozes.end(signalId: reminder.id)
        await refreshReminders()
    }

    public func deleteTask(_ signal: Signal) async {
        guard signal.source == .reminders else { return }
        let taskSource = self.taskSource
        await Task.detached { try? taskSource.delete(id: signal.sourceRef) }.value
        await refreshReminders()
    }
}

// MARK: - Focus list

/// The Reminders share as the Focus list reads it (ADR 0048): every open
/// reminder, hydrated with its snooze, today's checked-off ones, each
/// one's list, and which fetch all of it came from.
public struct ReminderSnapshot: Sendable {
    public let open: [Signal]
    public let checkedOffIds: [String]
    public let listIds: [String: String]
    /// Rises with every fetch, so two snapshots from one fetch match.
    public let fetch: Int
}

extension SignalBoard {
    /// The Reminders share, or `nil` while Reminders is Unavailable or
    /// before its first read.
    public func reminderSnapshot() -> ReminderSnapshot? {
        guard availability(of: .reminders) == .available, remindersReadAt > 0 else { return nil }
        return ReminderSnapshot(
            open: hydrate(reminderSignals), checkedOffIds: checkedOffReminders.map(\.id), listIds: reminderListIds,
            fetch: remindersReadAt
        )
    }
}

/// The ordered, tiered, deduplicated Signals the window shows (CONTEXT.md:
/// Ranked List). `focus` and `later` are `rank(_:now:)`'s own output
/// split back out by `tier(for:now:)` — the one place that split happens,
/// rather than a view body re-deriving it with its own `Date()`. `suggested`
/// is the Suggested Tasks Inbox: distinct from both Tiers, never a Tier
/// itself (CONTEXT.md: Section). `snoozed` is the Snoozed Section, soonest
/// to return first: never ranked, deduplicated or capped (ADR 0045).
public struct RankedList: Equatable, Sendable {
    public let focus: [Signal]
    public let later: [Signal]
    public let suggested: [Signal]
    public let snoozed: [Signal]
    /// Every open, un-Snoozed Later Signal, counted before the Later cap
    /// trims `later`. The Morning Brief reports this, not `later.count`.
    public let laterCount: Int

    public init(focus: [Signal], later: [Signal], suggested: [Signal], snoozed: [Signal] = [], laterCount: Int? = nil) {
        self.focus = focus
        self.later = later
        self.suggested = suggested
        self.snoozed = snoozed
        self.laterCount = laterCount ?? later.count
    }
}
