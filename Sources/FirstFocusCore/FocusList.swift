import Foundation

/// The Focus list's name in Reminders (CONTEXT.md: Focus list).
public let focusListTitle = "Focus"

/// A reminder that was in the Focus list when FirstFocus last looked, and
/// the list it goes back to when it leaves. `homeListId` is `nil` when
/// that is unknown, for a reminder you put in the Focus list yourself or
/// made there; it then goes to the default list.
public struct FocusListPlacement: Equatable, Hashable, Sendable {
    public let reminderId: String
    public let homeListId: String?

    public init(reminderId: String, homeListId: String?) {
        self.reminderId = reminderId
        self.homeListId = homeListId
    }
}

/// A Reminders list in Advanced, and whether FirstFocus uses it: an
/// unticked list's reminders are hidden, and the Focus list leaves them
/// alone.
public struct FocusListTick: Equatable, Sendable, Identifiable {
    public let list: ReminderList
    public let isTicked: Bool

    public var id: String { list.id }

    public init(list: ReminderList, isTicked: Bool) {
        self.list = list
        self.isTicked = isTicked
    }
}

/// Keeps the Focus list in Reminders in line with the Focus Tier
/// (ADR 0048). Told each time the Ranked List is derived, it syncs one
/// sync at a time, and calls `onChange` once a sync has changed the
/// Signal Board.
///
/// Every sync works toward a target. With the setting on, the Focus list
/// holds every open reminder in the Focus Tier that isn't Snoozed and whose
/// own list is ticked, judged at the moment the list was ranked against.
/// With it off, the Focus list holds nothing. A move you made in Reminders since the last sync counts
/// first: putting a reminder in is Move to Focus, taking it out is Move to
/// Later.
///
/// A reminder whose write fails keeps the record it had before the sync,
/// so the next sync sees your move again, and is tried again only once
/// Reminders has been fetched again. A sync that wrote anything fetches
/// Reminders before it ends, and the next sync waits for it, so no sync
/// reads a fetch older than the last write; one that started earlier is
/// thrown away by the Board. Nothing happens while Reminders is
/// Unavailable or the record can't be read.
@MainActor
public final class FocusList {
    private let taskSource: any TaskSource
    private let store: any FocusListStore
    private let board: SignalBoard
    /// Putting a reminder in the Focus list yourself ends its snooze.
    private let snoozes: Snoozes
    private let preference: FocusListPreference

    /// Called after a sync that changed the Board. The caller derives the
    /// Ranked List again, which asks for another sync; that one finds
    /// nothing to do.
    public var onChange: (() -> Void)?

    /// The moment the next sync judges Tier against, `nil` when none is
    /// waiting. A sync asked for while another waits replaces it.
    private var pendingMoment: Date?
    private var lastMoment: Date?
    private var running: Task<Void, Never>?
    /// The fetch each reminder's last failed write was planned from.
    private var failedAt: [String: Int] = [:]

    public init(
        taskSource: any TaskSource, store: any FocusListStore, board: SignalBoard, snoozes: Snoozes,
        preference: FocusListPreference
    ) {
        self.snoozes = snoozes
        self.taskSource = taskSource
        self.store = store
        self.board = board
        self.preference = preference
    }

    /// The setting in Advanced. Changing it asks for a sync, which fills
    /// the list or empties it.
    public var isEnabled: Bool {
        get { preference.isEnabled }
        set {
            guard newValue != preference.isEnabled else { return }
            preference.isEnabled = newValue
            if let lastMoment { requestSync(at: lastMoment) }
        }
    }

    /// Every Reminders list but the Focus list, by title, and whether it is
    /// ticked. A list made after you last looked reads as ticked.
    public func lists() async -> [FocusListTick] {
        let taskSource = self.taskSource
        let lists = await Task.detached { taskSource.reminderLists() }.value
            .filter { $0.id != preference.listId }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let unticked = preference.untickedListIds
        return lists.map { FocusListTick(list: $0, isTicked: !unticked.contains($0.id)) }
    }

    /// The lists you unticked. The window hides their reminders.
    public var untickedListIds: Set<String> { preference.untickedListIds }

    /// Ticks or unticks a list, then asks for a sync, which moves its
    /// reminders in or sends them back. The caller derives the Ranked List
    /// again, which shows or hides them.
    public func setTicked(_ isTicked: Bool, listId: String) {
        var unticked = preference.untickedListIds
        if isTicked {
            unticked.remove(listId)
        } else {
            unticked.insert(listId)
        }
        preference.untickedListIds = unticked
        if let lastMoment { requestSync(at: lastMoment) }
    }

    /// The Ranked List was derived at `moment`.
    public func listDerived(at moment: Date) {
        lastMoment = moment
        requestSync(at: moment)
    }

    /// Returns once no sync is running or waiting, including any a sync
    /// led to.
    public func settled() async {
        while let running { await running.value }
    }

    private func requestSync(at moment: Date) {
        pendingMoment = moment
        guard running == nil else { return }
        running = Task { [weak self] in
            while let self, let moment = self.pendingMoment {
                self.pendingMoment = nil
                if await self.sync(at: moment) { self.onChange?() }
            }
            self?.running = nil
        }
    }

    /// One sync. Returns whether it changed the Board.
    private func sync(at moment: Date) async -> Bool {
        let isEnabled = preference.isEnabled
        guard isEnabled || preference.listId != nil else { return false }
        guard board.reminderSnapshot() != nil, var placements = store.focusListPlacements() else { return false }
        let stored = placements

        let listId: String
        var unticked: Set<String> = []
        if isEnabled {
            let taskSource = self.taskSource
            let knownId = preference.listId
            guard let ensured = await Task.detached(operation: {
                try? taskSource.ensureList(id: knownId, title: focusListTitle)
            }).value else { return false }
            if ensured != knownId {
                // A new list, so nothing is in it yet.
                preference.listId = ensured
                placements = []
            }
            listId = ensured
            // The Focus list itself is one of them, so none means they
            // couldn't be read.
            let lists = await Task.detached { taskSource.reminderLists() }.value
            guard !lists.isEmpty else { return false }
            unticked = forgetGoneLists(lists)
        } else if let known = preference.listId {
            listId = known
        } else {
            return false
        }
        // Read after the await, so a fetch that landed meanwhile counts.
        guard let snapshot = board.reminderSnapshot() else { return false }

        let steps = isEnabled
            ? planFilling(snapshot, focusListId: listId, placements: placements, unticked: unticked, now: moment)
            : planEmptying(snapshot, focusListId: listId, placements: placements)
        let before = Dictionary(placements.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [FocusListPlacement] = []
        var toRun: [FocusListStep] = []
        for step in steps {
            if !step.hasWrites {
                if let placement = step.placement { kept.append(placement) }
            } else if failedAt[step.reminderId] == snapshot.fetch {
                if let placement = before[step.reminderId] { kept.append(placement) }
            } else {
                toRun.append(step)
            }
        }
        guard !toRun.isEmpty else {
            if Set(kept) != Set(stored) { try? store.setFocusListPlacements(kept) }
            return false
        }

        for step in toRun where step.unsnooze { snoozes.end(signalId: step.reminderId) }
        let taskSource = self.taskSource
        let writes = toRun
        let failed = await Task.detached {
            Set(writes.filter { !run($0, focusListId: listId, taskSource: taskSource) }.map(\.reminderId))
        }.value

        for step in toRun {
            if failed.contains(step.reminderId) {
                failedAt[step.reminderId] = snapshot.fetch
                if let placement = before[step.reminderId] { kept.append(placement) }
            } else {
                failedAt[step.reminderId] = nil
                if let placement = step.placement { kept.append(placement) }
            }
        }
        try? store.setFocusListPlacements(kept)

        let wrote = toRun.contains { !failed.contains($0.reminderId) && $0.writesReminders }
        if wrote { await board.refreshReminders() }
        return wrote || toRun.contains { $0.unsnooze }
    }

    /// Forgets unticked lists that no longer exist and returns the rest.
    private func forgetGoneLists(_ lists: [ReminderList]) -> Set<String> {
        let all = preference.untickedListIds
        let unticked = all.intersection(lists.map(\.id))
        if unticked != all { preference.untickedListIds = unticked }
        return unticked
    }
}

/// What one sync does to one reminder, and what the record says about it
/// once every write lands.
private struct FocusListStep: Sendable {
    let reminderId: String
    var unsnooze = false
    /// `.high` for Move to Focus, `.none` for Move to Later.
    var priority: Priority?
    var move: FocusListMove?
    var placement: FocusListPlacement?

    init(_ reminderId: String) {
        self.reminderId = reminderId
    }

    var writesReminders: Bool { priority != nil || move != nil }
    var hasWrites: Bool { unsnooze || writesReminders }
}

private enum FocusListMove: Sendable {
    case intoFocusList
    /// Back to this list, or to the default list when it is `nil` or gone.
    case home(String?)
}

/// The setting on. A reminder belongs in the Focus list while it is in
/// the Focus Tier and not Snoozed. `placements` is what was in the list
/// last time, which tells a move you made from one FirstFocus made:
///
/// - In the list now but not last time: you put it there, which counts
///   as Move to Focus. A Snoozed one is unsnoozed, and one in Later gets
///   a Priority.
/// - In the list last time but not now: you took it out, which counts as
///   Move to Later. Its Priority is cleared, unless its due date holds it
///   in Focus, in which case it goes back. Either way the list you moved
///   it to becomes the one it returns to.
///
/// A reminder checked off today that is still in the list goes back to
/// its own. One whose list is unknown is left alone.
///
/// Only ticked lists are drawn from. A reminder whose own list is
/// unticked is never moved in and never has its Priority written: one in
/// the Focus list goes back to it, and one you took out into it is
/// forgotten, whatever its due date.
private func planFilling(
    _ snapshot: ReminderSnapshot, focusListId: String, placements: [FocusListPlacement], unticked: Set<String>,
    now: Date
) -> [FocusListStep] {
    let placed = Dictionary(placements.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
    var steps: [FocusListStep] = []
    var openIds: Set<String> = []

    for original in snapshot.open where original.source == .reminders {
        let id = original.id
        openIds.insert(id)
        var step = FocusListStep(id)
        guard let listId = snapshot.listIds[id] else {
            step.placement = placed[id]
            steps.append(step)
            continue
        }
        let isInList = listId == focusListId
        var signal = original
        var home = placed[id]?.homeListId

        if let ownList = isInList ? home : listId, unticked.contains(ownList) {
            // An unticked list's reminders are left alone. One you moved
            // into it is forgotten, and one still in the list goes back.
            if isInList { step.move = .home(ownList) }
            steps.append(step)
            continue
        }

        if isInList, placed[id] == nil {
            if isSnoozed(signal, now: now) {
                step.unsnooze = true
                signal.snoozedUntil = nil
            }
            if tier(for: signal, now: now) == .later {
                step.priority = .high
                signal.priority = .high
            }
        } else if !isInList, placed[id] != nil {
            home = listId
            if signal.priority != .none, !dueDateHoldsInFocus(signal, now: now) {
                step.priority = Priority.none
                signal.priority = .none
            }
        }

        let belongs = tier(for: signal, now: now) == .focus && !isSnoozed(signal, now: now)
        switch (belongs, isInList) {
        case (true, false):
            step.move = .intoFocusList
            step.placement = FocusListPlacement(reminderId: id, homeListId: listId)
        case (true, true):
            step.placement = FocusListPlacement(reminderId: id, homeListId: home)
        case (false, true):
            step.move = .home(home)
        case (false, false):
            break
        }
        steps.append(step)
    }

    for id in snapshot.checkedOffIds where !openIds.contains(id) && snapshot.listIds[id] == focusListId {
        var step = FocusListStep(id)
        step.move = .home(placed[id]?.homeListId)
        steps.append(step)
    }
    return steps
}

/// The setting off: every reminder still in the Focus list, open or
/// checked off, goes back to its own list.
private func planEmptying(
    _ snapshot: ReminderSnapshot, focusListId: String, placements: [FocusListPlacement]
) -> [FocusListStep] {
    let placed = Dictionary(placements.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
    return snapshot.listIds.filter { $0.value == focusListId }.keys.sorted().map { id in
        var step = FocusListStep(id)
        step.move = .home(placed[id]?.homeListId)
        return step
    }
}

/// Makes one step's writes to Reminders, stopping at the first that
/// fails. Returns whether every one landed.
private func run(_ step: FocusListStep, focusListId: String, taskSource: any TaskSource) -> Bool {
    if let priority = step.priority {
        guard (try? taskSource.update(id: step.reminderId, .priority(priority))) != nil else { return false }
    }
    switch step.move {
    case .intoFocusList:
        return (try? taskSource.update(id: step.reminderId, .list(focusListId))) != nil
    case .home(let listId):
        return moveReminderHome(step.reminderId, to: listId, focusListId: focusListId, taskSource: taskSource)
    case nil:
        return true
    }
}

/// Moves a reminder out of the Focus list: to `listId`, or to the default
/// list when that is `nil` or gone. Never into the Focus list itself, so
/// with the Focus list as the default it stays where it is. Returns
/// whether it moved.
private func moveReminderHome(
    _ reminderId: String, to listId: String?, focusListId: String, taskSource: any TaskSource
) -> Bool {
    if let listId, listId != focusListId {
        do {
            try taskSource.update(id: reminderId, .list(listId))
            return true
        } catch TaskSourceError.listNotFound {
            // Its own list was deleted: the default list instead.
        } catch {
            return false
        }
    }
    guard let fallback = taskSource.defaultListId(), fallback != focusListId else { return false }
    return (try? taskSource.update(id: reminderId, .list(fallback))) != nil
}

/// The Focus list's setting and which Reminders list it is, in
/// `UserDefaults`. On until you turn it off. `@unchecked Sendable` for
/// the same reason as `ZenFocusModePreference`.
public struct FocusListPreference: @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let enabled = "focusListEnabled"
        static let listId = "focusListId"
        static let seenListIds = "focusListSeenListIds"
        static let tickedListIds = "focusListTickedListIds"
        static let untickedListIds = "focusListUntickedListIds"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// The list last used, kept when the setting is turned off so the list
    /// can be emptied, and so turning it back on uses the same list.
    public var listId: String? {
        get { defaults.string(forKey: Key.listId) }
        nonmutating set { defaults.set(newValue, forKey: Key.listId) }
    }

    /// The lists you unticked in Advanced. Their reminders are hidden from
    /// FirstFocus and the Focus list leaves them alone. Every other list
    /// is ticked, including one made later.
    ///
    /// Before this was stored directly, the record was the lists a sync had
    /// seen and which of them were ticked, with a list made later starting
    /// unticked. An install with only that record reads its unticked lists
    /// from it, once, the first time they are read.
    public var untickedListIds: Set<String> {
        get {
            if let stored = defaults.stringArray(forKey: Key.untickedListIds) { return Set(stored) }
            guard let seen = defaults.stringArray(forKey: Key.seenListIds) else { return [] }
            return Set(seen).subtracting(defaults.stringArray(forKey: Key.tickedListIds) ?? [])
        }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.untickedListIds) }
    }
}
