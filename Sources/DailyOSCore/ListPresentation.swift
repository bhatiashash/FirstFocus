import Foundation

/// Everything the window asks about the list it shows, answered from one
/// Ranked List and the moment it was ranked against (list-presentation).
/// A row's Tier comes only from which part of the Ranked List holds it, so
/// no caller can pass a Tier of its own, and every answer is judged at
/// `rankedAt`, the moment the list on screen agrees with (ADR 0020).
///
/// Immutable: `AppModel` builds a new one whenever the list or a flag
/// changes, and views read it.
public struct ListPresentation: Sendable {
    /// What, beyond the Ranked List, decides the screen and its Sections.
    public struct Flags: Sendable {
        public var isLoading: Bool
        public var backfillProgress: (completed: Int, total: Int)?
        public var isZen: Bool
        public var messagesNeedFullDiskAccess: Bool
        public var remindersUnavailable: Bool
        public var extractionUnavailable: Bool

        public init(
            isLoading: Bool = false, backfillProgress: (completed: Int, total: Int)? = nil, isZen: Bool = false,
            messagesNeedFullDiskAccess: Bool = false, remindersUnavailable: Bool = false, extractionUnavailable: Bool = false
        ) {
            self.isLoading = isLoading
            self.backfillProgress = backfillProgress
            self.isZen = isZen
            self.messagesNeedFullDiskAccess = messagesNeedFullDiskAccess
            self.remindersUnavailable = remindersUnavailable
            self.extractionUnavailable = extractionUnavailable
        }
    }

    /// Where a dragged row can land: on another row, or on a Tier's header
    /// or the empty Focus drop zone, which both mean the Tier itself.
    public enum DropTarget: Equatable, Sendable {
        case row(id: String)
        case tier(Tier)
    }

    /// What a drop does.
    public enum Drop: Equatable, Sendable {
        /// Within Focus: takes `ontoId`'s place (ADR 0011).
        case reorder(draggedId: String, ontoId: String)
        /// From Later into Focus: gets a Priority (ADR 0009), then takes
        /// `ontoId`'s place if dropped on a row.
        case promote(Signal, ontoId: String?)
        /// From Focus into Later: its Priority is cleared.
        case demote(Signal)
    }

    public let rankedList: RankedList
    public let rankedAt: Date
    public let flags: Flags
    public let screenMode: ScreenMode
    public let sections: [Section]

    public init(rankedList: RankedList, rankedAt: Date, flags: Flags) {
        self.rankedList = rankedList
        self.rankedAt = rankedAt
        self.flags = flags
        self.screenMode = decideScreenMode(rankedList, flags)
        self.sections = decideSections(rankedList, flags)
    }

    /// Before the first list: loading, with nothing to draw.
    public static func loading(at moment: Date) -> ListPresentation {
        ListPresentation(rankedList: RankedList(focus: [], later: [], suggested: []), rankedAt: moment, flags: Flags(isLoading: true))
    }

    /// The Focus or Later row with `id`, and its Tier.
    public func row(_ id: String) -> (signal: Signal, tier: Tier)? {
        if let signal = rankedList.focus.first(where: { $0.id == id }) { return (signal, .focus) }
        if let signal = rankedList.later.first(where: { $0.id == id }) { return (signal, .later) }
        return nil
    }

    /// Which actions `signal`'s row offers (ADR 0023): from the part of
    /// the list that holds it.
    public func affordances(for signal: Signal) -> SignalAffordances {
        if rankedList.snoozed.contains(where: { $0.id == signal.id }) {
            return snoozedAffordances(for: signal)
        }
        return tierAffordances(for: signal, isLater: row(signal.id)?.tier == .later, now: rankedAt)
    }

    /// What dropping `draggedId` onto `target` does, or `nil` where the
    /// drop means nothing: within Later, which has no manual order, onto
    /// itself, or from Focus into Later for a row its due date holds in
    /// Focus (ADR 0042).
    public func drop(_ draggedId: String, onto target: DropTarget) -> Drop? {
        guard let (dragged, source) = row(draggedId) else { return nil }
        let ontoId: String?
        let targetTier: Tier
        switch target {
        case .row(let id):
            guard id != draggedId, let (_, tier) = row(id) else { return nil }
            (ontoId, targetTier) = (id, tier)
        case .tier(let tier):
            (ontoId, targetTier) = (nil, tier)
        }
        switch (source, targetTier) {
        case (.focus, .focus):
            return ontoId.map { .reorder(draggedId: draggedId, ontoId: $0) }
        case (.later, .focus):
            return .promote(dragged, ontoId: ontoId)
        case (.focus, .later):
            return canMoveToLater(dragged, now: rankedAt) ? .demote(dragged) : nil
        case (.later, .later):
            return nil
        }
    }

    /// Whether `signal`'s due date draws as overdue.
    public func isOverdue(_ signal: Signal) -> Bool {
        signal.dueAt.map { DailyOSCore.isOverdue($0, at: rankedAt) } ?? false
    }

    /// Whether Focus is drawn, so the `+` field sits inside it and what it
    /// adds keeps a Priority.
    public var showsFocus: Bool {
        switch screenMode {
        case .list, .zen: sections.contains { if case .tier(.focus, _) = $0 { true } else { false } }
        default: false
        }
    }

    /// Whether the Suggestion `id` is still in the Inbox, so keyboard
    /// focus or a preview on it can stay.
    public func isSuggested(_ id: String) -> Bool {
        rankedList.suggested.contains { $0.id == id }
    }
}

/// The precedence among the five screens: backfill, then loading, then
/// empty, then Zen, then the list.
///
/// "Nothing open" (`.empty`) requires every Source to be reachable too,
/// not just every list empty: an unreachable Source still has its own
/// Notice to show, so `.list`, not `.empty`, is what renders it.
private func decideScreenMode(_ rankedList: RankedList, _ flags: ListPresentation.Flags) -> ScreenMode {
    if let progress = flags.backfillProgress {
        return .backfill(completed: progress.completed, total: progress.total)
    }
    if flags.isLoading {
        return .loading
    }
    let isEverythingEmpty = rankedList.focus.isEmpty && rankedList.later.isEmpty && rankedList.suggested.isEmpty
        && rankedList.snoozed.isEmpty
        && !flags.messagesNeedFullDiskAccess && !flags.remindersUnavailable && !flags.extractionUnavailable
    if isEverythingEmpty {
        return .empty
    }
    if flags.isZen {
        return .zen
    }
    return .list
}

/// Which Sections exist right now, in order, holding what. A Suggested
/// Tasks Inbox with nothing in it, or a Tier with nothing in it, produces
/// no Section.
///
/// Zen hides Later, the Snoozed Section and the Suggested Tasks Inbox
/// outright (CONTEXT.md: Zen Focus Mode) and never changes which Signals
/// are Open or how they rank.
///
/// A Notice ignores Zen and always sorts after every Signal-bearing
/// Section: Zen hides what competes for attention, and a Source the app
/// can't read at all isn't competing, it's broken. Hiding it there would
/// leave Zen showing an incomplete picture, or, with Focus empty, an
/// entirely blank window.
private func decideSections(_ rankedList: RankedList, _ flags: ListPresentation.Flags) -> [Section] {
    var result: [Section] = []
    if !flags.isZen && !rankedList.suggested.isEmpty {
        result.append(.suggested(rankedList.suggested))
    }
    // An empty Focus still shows beside a non-empty Later, as the place to
    // drag a Later row into. Zen shows nothing else, so there it needs rows.
    let showsEmptyFocus = !flags.isZen && !rankedList.later.isEmpty
    if !rankedList.focus.isEmpty || showsEmptyFocus {
        result.append(.tier(.focus, groupForRendering(rankedList.focus)))
    }
    if !flags.isZen && !rankedList.later.isEmpty {
        result.append(.tier(.later, groupForRendering(rankedList.later)))
    }
    if !flags.isZen && !rankedList.snoozed.isEmpty {
        result.append(.snoozed(rankedList.snoozed))
    }
    if flags.messagesNeedFullDiskAccess {
        result.append(.notice(.messagesUnavailable))
    }
    if flags.remindersUnavailable {
        result.append(.notice(.remindersUnavailable))
    }
    if flags.extractionUnavailable {
        result.append(.notice(.extractionUnavailable))
    }
    return result
}
