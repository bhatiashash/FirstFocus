import Foundation

/// Which actions a Signal's row offers, decided once, in one place —
/// candidate 4's deepening (ADR 0023). Before this, whether a row showed
/// rename, delete, promote, demote, reorder or dismiss was
/// separate `nil`-or-a-closure decisions made inline at the view's
/// call site; the rules are domain facts about the Signal and its Tier,
/// not anything about drawing, so they live here instead, where a test
/// can reach them without constructing a view.
public struct SignalAffordances: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Editing the title from inside the app.
    public static let rename = SignalAffordances(rawValue: 1 << 1)
    /// Deleting the reminder outright.
    public static let delete = SignalAffordances(rawValue: 1 << 2)
    /// Marking a Signal as never having been real work (CONTEXT.md:
    /// Dismiss).
    public static let dismiss = SignalAffordances(rawValue: 1 << 3)
    /// One-click promotion (ticket 05): into Focus.
    public static let promote = SignalAffordances(rawValue: 1 << 4)
    /// One-click demotion: out of Focus.
    public static let demote = SignalAffordances(rawValue: 1 << 5)
    /// Manual Focus ordering (ADR 0011): draggable, and a drop target.
    public static let reorder = SignalAffordances(rawValue: 1 << 6)
    /// Ending a snooze early, offered only on a row in the Snoozed
    /// Section (ADR 0045). Such a row is never dragged or dropped on.
    public static let unsnooze = SignalAffordances(rawValue: 1 << 7)
}

/// The single source of truth for what a Signal's row can do. Check off
/// and snoozing aren't affordances here — every row offers both
/// unconditionally, regardless of source or Tier, so there's nothing to
/// decide about them.
///
/// Asked only by `ListPresentation`, which knows the row's Tier from the
/// part of the Ranked List that holds it (list-presentation). `now` is
/// needed only for demote: whether a due date holds the row in Focus
/// depends on the day (ADR 0042).
func tierAffordances(for signal: Signal, isLater: Bool, now: Date) -> SignalAffordances {
    var result: SignalAffordances = []

    switch signal.source {
    case .messages:
        // Dismiss means something only for a Messages Signal: a Reminders
        // Signal never went through Extraction for Dismiss to mean "false
        // positive" about (CONTEXT.md: Dismiss). Opening the Chat is the
        // Notes drawer's call now (`rowDrawer(for:)`), not an affordance.
        result.insert(.dismiss)
    case .reminders:
        // Rename and Delete both write through to the real reminder —
        // neither has meaning for a Messages Signal, which has no
        // reminder behind it to edit or delete.
        result.insert(.rename)
        result.insert(.delete)
    }

    if isLater {
        // Promote is the only way out of Later by hand; nothing in
        // Focus needs a way further into itself.
        result.insert(.promote)
    } else {
        // Reorder only ever applies within Focus (ADR 0011) — dragging
        // within Later or Suggested has no defined meaning, since
        // neither has a manual order concept.
        result.insert(.reorder)
        // Demote only when Focus membership came from Priority alone,
        // not a due date within tomorrow: clearing priority on such a row
        // wouldn't move it to Later at all, since that date alone keeps
        // `tier(for:now:)` returning `.focus` (ADR 0009's noted asymmetry,
        // narrowed by ADR 0042) — offering the button there would
        // silently do nothing rather than what it promises.
        if canMoveToLater(signal, now: now) {
            result.insert(.demote)
        }
    }

    return result
}

/// What a row in the Snoozed Section can do (ADR 0045): Unsnooze, plus
/// the same source-specific actions as anywhere else. No Tier moves and
/// no drag, since nothing in the Section is ranked.
func snoozedAffordances(for signal: Signal) -> SignalAffordances {
    switch signal.source {
    case .messages: return [.unsnooze, .dismiss]
    case .reminders: return [.unsnooze, .rename, .delete]
    }
}

/// Whether clearing a Focus row's Priority moves it to Later: only when
/// the Priority alone holds it in Focus, not a due date within tomorrow
/// (ADR 0009's asymmetry, narrowed by ADR 0042). Move to Later and a drop
/// into Later both ask this.
func canMoveToLater(_ signal: Signal, now: Date) -> Bool {
    signal.priority != .none && !dueDateHoldsInFocus(signal, now: now)
}
