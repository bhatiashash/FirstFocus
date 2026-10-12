import Foundation

/// What the Undo bar at the bottom of the window shows: the last action
/// taken, and whether Undo can reverse it (inbox-undo). One at a time: a
/// new action replaces it, and the action it offered stays done.
public struct UndoOffer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case checkedOff
        /// A reminder from `+` that landed in Later. Reported, not undoable.
        case addedToLater
        case dismissed
        /// An Approved Suggestion, and the Tier its reminder landed in.
        case approved(Tier)
        case notForMe
        /// A row Snoozed until the given moment (ADR 0045).
        case snoozed(until: Date)
        /// A Suggestion Approved and its reminder Snoozed in one step.
        case approvedAndSnoozed(until: Date)
    }

    public let action: Action
    public let label: String
    /// Tells two offers for the same action and label apart, so a bar
    /// replaced by an identical one still redraws.
    let token: Int

    public var canUndo: Bool { action != .addedToLater }

    public var text: String {
        let quoted = "\u{201C}\(label)\u{201D}"
        switch action {
        case .checkedOff: return "Checked off \(quoted)"
        case .addedToLater: return "Added \(quoted) to Later"
        case .dismissed: return "Dismissed \(quoted)"
        case .approved(.focus): return "Added \(quoted) to Focus"
        case .approved: return "Added \(quoted) to Later"
        case .notForMe: return "Marked \(quoted) Not for me"
        case .snoozed(let until): return "Snoozed \(quoted) until \(snoozeDayText(until))"
        case .approvedAndSnoozed(let until): return "Added \(quoted), snoozed until \(snoozeDayText(until))"
        }
    }
}

/// "Mon 12 Oct": the day a snooze ends, as the Undo bar names it. The
/// hour is always 8 AM, so it's left out.
func snoozeDayText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM"
    return formatter.string(from: date)
}

/// The Undo bar (CONTEXT.md): holds the one offer showing, ends it when
/// its window runs out, replaces it when another action comes, and runs
/// Undo. Knows nothing of what an offer's steps do; the caller hands them
/// over with the offer (undo-bar, amending ADR 0022).
///
/// `@MainActor` for the same reason as `CheckOffCoordinator`: the clock's
/// expiry and the caller both touch `current`.
@MainActor
public final class UndoBar {
    /// How an offer ends.
    public enum Kind {
        /// Written only when the offer ends, by its window running out,
        /// another offer replacing it, or the app quitting; Undo drops it
        /// unwritten. `hiding` stays off the Ranked List meanwhile.
        case heldBack(hiding: String, commit: @MainActor () -> Void)
        /// Already written; Undo runs `reverse`.
        case reversible(reverse: @MainActor () async -> Void)
        /// Reported only; Undo does nothing.
        case report
    }

    /// Called after every change to `current` or `hiddenIDs`.
    public var onChange: () -> Void = {}

    public private(set) var current: UndoOffer?
    private var kind: Kind?
    private var token = 0
    private let clock: any UndoClock
    private let window: TimeInterval

    public init(clock: any UndoClock = TaskSleepUndoClock(), window: TimeInterval = 5) {
        self.clock = clock
        self.window = window
    }

    /// The id a held-back offer keeps off the Ranked List.
    public var hiddenIDs: Set<String> {
        if case .heldBack(let id, _) = kind { return [id] }
        return []
    }

    /// Shows `action` in place of whatever was there. A held-back offer
    /// it replaces is written first: its bar is going, so nothing is left
    /// to undo it from.
    public func offer(_ action: UndoOffer.Action, label: String, _ kind: Kind) {
        commitHeldBack()
        token += 1
        current = UndoOffer(action: action, label: label, token: token)
        self.kind = kind
        onChange()
        let token = self.token
        clock.scheduleOnce(after: window) { [weak self] in
            Task { @MainActor in self?.expire(token) }
        }
    }

    /// The window of the offer `token` named has run out. A no-op once
    /// that offer is gone, so a late timer never ends a newer one.
    private func expire(_ token: Int) {
        guard token == self.token, current != nil else { return }
        commitHeldBack()
        clear()
    }

    /// The bar's Undo button, and ⌘Z. Drops a held-back offer unwritten,
    /// or runs a reversible one's reverse step. Does nothing when the bar
    /// is hidden or only reports.
    public func undo() async {
        switch kind {
        case .heldBack:
            clear()
        case .reversible(let reverse):
            clear()
            await reverse()
        case .report, nil:
            return
        }
    }

    /// The app is about to quit: a held-back offer is written now, since
    /// nothing will be left to write it once its window would have ended.
    /// The bar stays as it is; the process is going away.
    public func flush() {
        commitHeldBack()
    }

    /// Runs a held-back offer's commit step, once. The bar stops hiding
    /// the id here, so the commit step has to start hiding it itself
    /// before it returns, as `CheckOffCoordinator.commit` does.
    private func commitHeldBack() {
        guard case .heldBack(_, let commit) = kind else { return }
        kind = nil
        commit()
    }

    private func clear() {
        current = nil
        kind = nil
        onChange()
    }
}
