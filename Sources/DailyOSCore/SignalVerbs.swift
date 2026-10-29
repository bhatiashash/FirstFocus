import Foundation

/// Every verb that writes Signal state, each with its Undo (signal-verbs).
/// Holds the Undo bar and the check-off writer, so which ids are hidden
/// from the Ranked List, and why, is decided here and nowhere else. Writes
/// go through the Signal Board, which keeps its Messages share current, so
/// no Undo re-reads anything.
///
/// `onChange` fires after anything a caller shows may have changed: the
/// Board, `hiddenIDs` or `currentOffer`. Core stays free of Combine (ADR
/// 0020), so it is a callback.
@MainActor
public final class SignalVerbs {
    /// "Not for me" lives with History, outside Core: marking a Suggestion's
    /// Batch, and undoing it. `mark` returns whether the Batch offered it.
    public struct NotForMe {
        public let mark: @MainActor (Signal) -> Bool
        public let undo: @MainActor (Signal) -> Void

        public init(mark: @escaping @MainActor (Signal) -> Bool, undo: @escaping @MainActor (Signal) -> Void) {
            self.mark = mark
            self.undo = undo
        }
    }

    public var onChange: () -> Void = {}
    /// Settable rather than an init parameter, like `onChange`: its
    /// closures reach History, which its owner can only build once it
    /// exists itself.
    public var notForMe: NotForMe?

    private let board: SignalBoard
    private let undoBar: UndoBar
    private let checkOffs: CheckOffCoordinator
    private let now: @MainActor () -> Date
    /// Reminders being deleted: hidden until the write lands, so a refresh
    /// mid-delete never shows the row again.
    private var deletingIDs: Set<String> = []
    /// The Signal the offer showing brings back if undone, for keyboard
    /// focus.
    private var bringsBack: String?

    public init(
        board: SignalBoard, taskSource: any TaskSource, signalStore: any CheckOffStore,
        undoClock: any UndoClock, undoWindow: TimeInterval, now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.board = board
        self.undoBar = UndoBar(clock: undoClock, window: undoWindow)
        self.checkOffs = CheckOffCoordinator(taskSource: taskSource, signalStore: signalStore)
        self.now = now
        undoBar.onChange = { [weak self] in self?.onChange() }
        checkOffs.onChange = { [weak self] in self?.onChange() }
        // Re-read Reminders before the id stops being hidden, so the row
        // doesn't show again from the stale read.
        checkOffs.onCommitted = { [weak self] in await self?.board.refreshReminders() }
    }

    /// What the Undo bar shows, if anything.
    public var currentOffer: UndoOffer? { undoBar.current }

    /// Every id kept off the Ranked List: a check-off held back on the
    /// Undo bar or still being written, and a reminder being deleted.
    public var hiddenIDs: Set<String> {
        undoBar.hiddenIDs.union(checkOffs.hiddenIDs).union(deletingIDs)
    }

    // MARK: - The Undo bar

    /// The Undo bar's button, and ⌘Z. Returns the Signal it brought back,
    /// if it brought one back. Does nothing when the bar is hidden or only
    /// reports.
    @discardableResult
    public func undo() async -> String? {
        guard currentOffer?.canUndo == true else { return nil }
        let target = bringsBack
        await undoBar.undo()
        return target
    }

    /// Returns once every check-off being written has landed. For tests.
    public func settled() async {
        await checkOffs.settled()
    }

    /// The app is about to quit. A check-off still held back is written
    /// before this returns, so it isn't lost with the process (ADR 0043).
    public func prepareToQuit() {
        // The writer first, so the held-back offer's commit writes inline.
        checkOffs.prepareToQuit()
        undoBar.flush()
    }

    private func offer(_ action: UndoOffer.Action, label: String, bringingBack id: String? = nil, _ kind: UndoBar.Kind) {
        undoBar.offer(action, label: label, kind)
        bringsBack = id
    }

    // MARK: - Check off

    /// Held back on the Undo bar and written once the offer ends (ADR
    /// 0022). Writing it also ends any snooze, so a recurring reminder's
    /// next occurrence, which keeps the same id, doesn't start out hidden
    /// (ADR 0045).
    public func checkOff(_ signal: Signal) {
        offer(.checkedOff, label: signal.label, .heldBack(hiding: signal.id) { [weak self] in
            self?.board.snoozes.end(signalId: signal.id)
            self?.checkOffs.commit(signal)
        })
    }

    /// Unchecking a Checked Off row: the reminder goes back to Focus or
    /// Later. No Undo bar.
    public func uncheck(_ reminder: CheckedOffReminder) async {
        await board.uncheck(reminder)
        onChange()
    }

    // MARK: - Suggestions

    /// Messages Signals only (CONTEXT.md: Dismiss). Written at once and
    /// reversed by Undo (ADR 0043).
    public func dismiss(_ signal: Signal) {
        guard signal.source == .messages else { return }
        board.dismiss(signal)
        onChange()
        offer(.dismissed, label: signal.label, bringingBack: signal.id, .reversible { [weak self] in
            self?.board.reopen(signalIds: [signal.id])
            self?.onChange()
        })
    }

    /// The Inbox's thumbs-down: History's "Not for me" on the Suggestion's
    /// Batch. Undo reverses it the way History's Undo does (ADR 0043).
    public func notForMe(_ suggestion: Signal) {
        guard let notForMe, notForMe.mark(suggestion) else { return }
        onChange()
        offer(.notForMe, label: suggestion.label, bringingBack: suggestion.id, .reversible { [weak self] in
            notForMe.undo(suggestion)
            self?.onChange()
        })
    }

    /// Mints a real reminder from a Suggestion (CONTEXT.md: Approve).
    /// Written at once, and reversed by Undo (ADR 0043). Returns the new
    /// reminder's id.
    @discardableResult
    public func approve(_ signal: Signal) async -> String? {
        guard let reminderId = await board.approve(signal) else {
            onChange()
            return nil
        }
        onChange()
        offer(.approved(tierOf(reminderId)), label: signal.label, bringingBack: signal.id, unapproving(signal, reminderId))
        return reminderId
    }

    /// Tomorrow or Next Week on a Suggestion (ADR 0045): Approves it and
    /// Snoozes the new reminder in one step, so it never shows in Focus or
    /// Later. One Undo reverses both.
    @discardableResult
    public func approve(_ signal: Signal, snoozing choice: SnoozeChoice) async -> String? {
        let until = snoozeEnd(choice, now: now())
        guard let reminderId = await board.approve(signal, snoozedUntil: until) else {
            onChange()
            return nil
        }
        onChange()
        offer(.approvedAndSnoozed(until: until), label: signal.label, bringingBack: signal.id, unapproving(signal, reminderId))
        return reminderId
    }

    /// Both Approves' Undo: the reminder is deleted and the Suggestion is
    /// back.
    private func unapproving(_ signal: Signal, _ reminderId: String) -> UndoBar.Kind {
        .reversible { [weak self] in
            await self?.board.unapprove(signalId: signal.id, reminderId: reminderId)
            self?.onChange()
        }
    }

    // MARK: - Snooze

    /// Snoozes `signal` until `until` (CONTEXT.md: Snoozed). No Undo bar.
    public func snooze(_ signal: Signal, until: Date) {
        board.snoozes.snooze(signal, until: until)
        onChange()
    }

    /// Tomorrow or Next Week from a row (ADR 0045): ends at 8:00 AM.
    /// Undo puts back whatever snooze the row had before, or none.
    public func snooze(_ signal: Signal, _ choice: SnoozeChoice) {
        let previous = board.snoozes.until(signalId: signal.id)
        let until = snoozeEnd(choice, now: now())
        snooze(signal, until: until)
        offer(.snoozed(until: until), label: signal.label, .reversible { [weak self] in
            guard let self else { return }
            if let previous {
                self.board.snoozes.snooze(signal, until: previous)
            } else {
                self.board.snoozes.end(signalId: signal.id)
            }
            self.onChange()
        })
    }

    /// Unsnooze on a Snoozed row (ADR 0045). No Undo bar; the row
    /// reappearing is the confirmation.
    public func unsnooze(_ signal: Signal) {
        board.snoozes.end(signalId: signal.id)
        onChange()
    }

    // MARK: - Tiers and order

    /// Move to Focus: gives `signal` a Priority (ADR 0009).
    public func promote(_ signal: Signal) async {
        await board.promote(signal)
        onChange()
    }

    /// Move to Later: clears its Priority.
    public func demote(_ signal: Signal) async {
        await board.demote(signal)
        onChange()
    }

    /// Manual Focus order (ADR 0011), among `currentFocusIds`, the Focus
    /// the user is looking at.
    public func reorderFocus(draggedId: String, droppedOnId: String, currentFocusIds: [String]) {
        board.reorderFocus(draggedId: draggedId, droppedOnId: droppedOnId, currentFocusIds: currentFocusIds)
        onChange()
    }

    // MARK: - Reminders

    /// Quick Capture's path: no Priority, and no report of where it landed.
    public func createTask(title: String, dueAt: Date? = nil) async {
        _ = await board.createTask(title: title, priority: .none, dueAt: dueAt)
        onChange()
    }

    /// The `+` field's write. Returns the Tier the reminder landed in, `nil`
    /// if the write failed. Landing in Later, which may be collapsed, is
    /// reported on the Undo bar so it doesn't seem to vanish.
    public func addReminder(title: String, priority: Priority, dueAt: Date? = nil) async -> Tier? {
        guard let id = await board.createTask(title: title, priority: priority, dueAt: dueAt) else {
            onChange()
            return nil
        }
        onChange()
        let list = board.rankedList(now: now(), hiding: hiddenIDs)
        if let added = list.later.first(where: { $0.id == id }) {
            offer(.addedToLater, label: added.label, .report)
            return .later
        }
        return list.focus.contains { $0.id == id } ? .focus : nil
    }

    /// Reminders Signals only: the title, and a due date typed into it.
    public func renameTask(_ signal: Signal, to newTitle: String, dueAt: Date? = nil) async {
        await board.renameTask(signal, to: newTitle, dueAt: dueAt)
        onChange()
    }

    /// Deletes the reminder outright, distinct from check off. Hidden until
    /// the write lands, since a refresh mid-delete would still report it.
    public func deleteTask(_ signal: Signal) async {
        deletingIDs.insert(signal.id)
        onChange()
        await board.deleteTask(signal)
        deletingIDs.remove(signal.id)
        onChange()
    }

    /// The Tier a just-approved reminder landed in, for the Undo bar's text.
    private func tierOf(_ reminderId: String) -> Tier {
        board.rankedList(now: now(), hiding: hiddenIDs).focus.contains { $0.id == reminderId } ? .focus : .later
    }
}
