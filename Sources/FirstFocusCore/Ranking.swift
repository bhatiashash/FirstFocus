import Foundation

/// The tier a Signal falls into for ranking. Tier membership is most of
/// the answer to "why is this Signal ranked where it is" — there is no
/// single numeric score. See ADR 0002 and CONTEXT.md: Tier.
///
/// Two Tiers (Focus Mode v2), not the original four: Focus holds anything
/// with a real claim on today (overdue, prioritized, or due by tomorrow); Later is
/// everything else, always fully visible alongside it. `header` is
/// presentation copy only.
public enum Tier: CaseIterable, Hashable, Sendable {
    case focus
    case later

    public var header: String {
        switch self {
        case .focus: return "Focus"
        case .later: return "Later"
        }
    }
}

/// Recency's half-life. Fixed in code for v1, not stored, not user-tunable.
public let recencyHalfLifeInDays: Double = 4

/// Later's ceiling, not the whole list's: Focus is never truncated,
/// however many active deadlines it holds — dropping one would mean
/// silently hiding something overdue or prioritized, which defeats the
/// point of a "what should I work on next" list. Only Later, from the
/// bottom of its order (undated, least recent first), absorbs the cut once Focus and Later together
/// pass this count. Fixed in code, not user-tunable.
public let maxRankedSignals = 25

/// Higher is more recent. Decays exponentially so recency is the only thing
/// capping how long a stale, undated Signal keeps competing.
public func recencyScore(for signal: Signal, now: Date) -> Double {
    let ageInDays = now.timeIntervalSince(signal.createdAt) / 86400
    return pow(0.5, ageInDays / recencyHalfLifeInDays)
}

/// Tier assignment. Anything overdue, prioritized, or due by the end of
/// tomorrow has a real claim on today and lands in Focus; everything else,
/// including a Signal due further out, is Later (ADR 0042).
public func tier(for signal: Signal, now: Date) -> Tier {
    if signal.priority != .none || dueDateHoldsInFocus(signal, now: now) {
        return .focus
    }
    return .later
}

/// Whether `signal`'s due date alone puts it in Focus: it falls before the
/// start of the day after tomorrow, counted in local days since due dates
/// carry no time of day (ADR 0030). Overdue dates are included. This is
/// also what stops Move to Later: clearing Priority can't move a Signal
/// its due date holds here.
public func dueDateHoldsInFocus(_ signal: Signal, now: Date) -> Bool {
    guard let dueAt = signal.dueAt else { return false }
    let calendar = Calendar.current
    guard let horizon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return false }
    return dueAt < horizon
}

/// Later's order (ADR 0042): dated Signals first, soonest first, then
/// undated ones by recency. The cap cuts from the bottom of this order, so
/// an undated Signal is always dropped before a dated one.
private func laterOrdersBefore(_ lhs: Signal, _ rhs: Signal, now: Date) -> Bool {
    switch (lhs.dueAt, rhs.dueAt) {
    case let (l?, r?):
        if l != r { return l < r }
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    case (.none, .none):
        break
    }
    return recencyScore(for: lhs, now: now) > recencyScore(for: rhs, now: now)
}

/// Priority's place within Focus: after the due date, before recency.
/// Lower sorts first — high priority, then normal, then none.
private func priorityBand(_ priority: Priority) -> Int {
    switch priority {
    case .high: return 0
    case .normal: return 1
    case .none: return 2
    }
}

/// Focus's Date-First comparator (ADR 0047, replacing Impact-First), with
/// manual Focus ordering (ADR 0011) layered on top: a Signal the user has
/// dragged to a position (`focusOrder` non-nil) always sorts ahead of one
/// that hasn't, and two manually-placed Signals sort by that position
/// directly. Everything else sorts dated before undated, by due date
/// ascending (most overdue first, then soonest), then by priority band,
/// then by recency.
private func focusOrdersBefore(_ lhs: Signal, _ rhs: Signal, now: Date) -> Bool {
    switch (lhs.focusOrder, rhs.focusOrder) {
    case let (l?, r?):
        if l != r { return l < r }
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    case (.none, .none):
        break
    }

    switch (lhs.dueAt, rhs.dueAt) {
    case let (l?, r?):
        if l != r { return l < r }
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    case (.none, .none):
        break
    }
    let lhsBand = priorityBand(lhs.priority)
    let rhsBand = priorityBand(rhs.priority)
    if lhsBand != rhsBand {
        return lhsBand < rhsBand
    }
    return recencyScore(for: lhs, now: now) > recencyScore(for: rhs, now: now)
}

/// Manual Focus ordering (ADR 0011): the new position for every id in
/// `currentFocusIds` once `draggedId` is moved to sit immediately before
/// `droppedOnId`, among whatever is currently visible in Focus — not a
/// single position in isolation, the whole visible arrangement is
/// recaptured at once. `nil` for a no-op drag (the same id dropped on
/// itself) or either id missing from `currentFocusIds`, matching what
/// `SignalBoard.reorderFocus` used to do inline before this was pulled
/// out and made independently testable.
public func reorderedFocusPositions(
    draggedId: String, droppedOnId: String, currentFocusIds: [String]
) -> [String: Int]? {
    guard draggedId != droppedOnId else { return nil }
    var focusIds = currentFocusIds
    guard let draggedIndex = focusIds.firstIndex(of: draggedId), focusIds.contains(droppedOnId) else { return nil }
    focusIds.remove(at: draggedIndex)
    guard let insertionIndex = focusIds.firstIndex(of: droppedOnId) else { return nil }
    focusIds.insert(draggedId, at: insertionIndex)

    var orders: [String: Int] = [:]
    for (index, id) in focusIds.enumerated() {
        orders[id] = index
    }
    return orders
}

/// Snooze (ticket 04, ADR 0045): whether `signal` is currently Snoozed and so
/// must be excluded from the ranked list entirely, not merely pushed to
/// Later. Once `now` passes `snoozedUntil`, the snooze has expired and
/// the Signal rejoins tiering exactly as if it had never been snoozed —
/// there's no separate "just reappeared" state to track.
public func isSnoozed(_ signal: Signal, now: Date) -> Bool {
    guard let snoozedUntil = signal.snoozedUntil else { return false }
    return snoozedUntil > now
}

/// The Signals that compete for the list, split by Tier and sorted within
/// each, before Later is capped. The one place that decides what is
/// snoozed out, what is a duplicate and which Tier a Signal falls in, so
/// the list and the Later count the Morning Brief reports agree.
public struct TieredSignals: Sendable {
    public let focus: [Signal]
    /// Every Later Signal, sorted, whatever the cap leaves.
    public let allLater: [Signal]

    /// Later as the list shows it: Focus is never cut, so Later keeps
    /// whatever room `maxRankedSignals` leaves.
    public var later: [Signal] {
        Array(allLater.prefix(max(0, maxRankedSignals - focus.count)))
    }
}

/// Excludes anything currently snoozed before deduplication or tiering
/// ever sees it, deduplicates by label, then splits by Tier. Pure: no
/// clock of its own, no Source. Tiers are sorted within each, not combined
/// into a weighted sum (ADR 0002). Provenance never enters ordering.
public func tierSignals(_ signals: [Signal], now: Date) -> TieredSignals {
    let visible = signals.filter { !isSnoozed($0, now: now) }
    let deduplicated = deduplicateByLabel(visible)
    let byTier = Dictionary(grouping: deduplicated) { tier(for: $0, now: now) }
    return TieredSignals(
        focus: (byTier[.focus] ?? []).sorted { focusOrdersBefore($0, $1, now: now) },
        allLater: (byTier[.later] ?? []).sorted { laterOrdersBefore($0, $1, now: now) }
    )
}

/// The list: all of Focus, then Later capped at `maxRankedSignals` in
/// total. The cap trims only Later; every Focus signal always survives.
public func rank(_ signals: [Signal], now: Date) -> [Signal] {
    let tiers = tierSignals(signals, now: now)
    return tiers.focus + tiers.later
}

/// Collapses Signals that share a label, once case, punctuation, and
/// whitespace differences are ignored, down to one — so the same
/// real-world task showing up more than once ("Call the dentist" and
/// "Call the dentist.", or the same obligation logged in both Reminders
/// and the self-thread) only takes one slot on the list. A Reminders
/// Signal wins a tie over a self-thread one, since checking it off there
/// completes the real reminder rather than only recording local state;
/// otherwise the more recently created one wins.
public func deduplicateByLabel(_ signals: [Signal]) -> [Signal] {
    var kept: [String: Signal] = [:]
    for signal in signals {
        let key = normalizedLabel(signal.label)
        if let existing = kept[key] {
            if isPreferred(signal, over: existing) {
                kept[key] = signal
            }
        } else {
            kept[key] = signal
        }
    }
    return Array(kept.values)
}

/// Lowercases, strips punctuation, and collapses whitespace runs to a
/// single space — "Call the dentist.", "call the dentist!", and "Call,
/// the  dentist" all normalize to the same key. Substantively different
/// labels ("Call the dentist re: insurance") stay distinct; only
/// punctuation/case/whitespace noise is ignored.
private func normalizedLabel(_ label: String) -> String {
    let lowercasedNoPunctuation = label.lowercased().unicodeScalars.filter {
        !CharacterSet.punctuationCharacters.contains($0)
    }
    return String(String.UnicodeScalarView(lowercasedNoPunctuation))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func isPreferred(_ candidate: Signal, over existing: Signal) -> Bool {
    if candidate.source != existing.source {
        return candidate.source == .reminders
    }
    return candidate.createdAt > existing.createdAt
}
