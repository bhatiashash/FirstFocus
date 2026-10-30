import Foundation

/// The Focus list's name in Reminders (CONTEXT.md: Focus list).
public let focusListTitle = "Focus"

/// A reminder owned by the Focus list, or with a durably prepared move,
/// and the list it goes back to when it leaves. `homeListId` is `nil` when
/// that is unknown, for a reminder you put in the Focus list yourself or
/// made there; it then goes to the default list.
public struct FocusListPlacement: Equatable, Hashable, Sendable {
    public let reminderId: String
    public let homeListId: String?
    public let pendingMove: FocusListPendingMove?

    public init(reminderId: String, homeListId: String?, pendingMove: FocusListPendingMove? = nil) {
        self.reminderId = reminderId
        self.homeListId = homeListId
        self.pendingMove = pendingMove
    }
}

/// An intended move, saved before changing Reminders and cleared only
/// after finalization. Observing its destination recovers a completed app
/// move; observing its source permits retry without treating it as manual.
public struct FocusListPendingMove: Equatable, Hashable, Sendable {
    public let fromListId: String
    public let toListId: String

    public init(fromListId: String, toListId: String) {
        self.fromListId = fromListId
        self.toListId = toListId
    }
}

public enum FocusListFailure: Equatable, Sendable {
    case persistenceRead
    case persistenceWrite
    case reminders
}

/// A Reminders list in Advanced, and whether FirstFocus uses it: an
/// unticked list's reminders are hidden, and the Focus list leaves them
/// alone.
public struct FocusListTick: Equatable, Sendable, Identifiable {
    public let list: ReminderList
    public let isTicked: Bool
    /// Whether it is the default list, where a task approved from a message
    /// is made.
    public let isDefault: Bool

    public var id: String { list.id }

    public init(list: ReminderList, isTicked: Bool, isDefault: Bool = false) {
        self.list = list
        self.isTicked = isTicked
        self.isDefault = isDefault
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
/// A move's home and intended destination are persisted before Reminders
/// is changed. Pending moves survive a restart or failed finalization.
/// Failed writes are tried again only once Reminders has been fetched
/// again. A sync that wrote anything fetches
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

    /// Called after a sync that changed the Board or failure state. The caller derives the
    /// Ranked List again, which asks for another sync; that one finds
    /// nothing to do.
    public var onChange: (() -> Void)?
    /// Nonblocking sync failure, cleared after a successful retry.
    public private(set) var failure: FocusListFailure?

    /// The moment the next sync judges Tier against, `nil` when none is
    /// waiting. A sync asked for while another waits replaces it.
    private var pendingMoment: Date?
    private var lastMoment: Date?
    private var running: Task<Void, Never>?
    /// The fetch each reminder's last failed write was planned from.
    private var failedAt: [String: Int] = [:]
    private var blockedAtFetch: Int?

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

    /// Every Reminders list but the Focus list, by title.
    public func reminderLists() async -> [ReminderList] {
        let taskSource = self.taskSource
        return await Task.detached { taskSource.reminderLists() }.value
            .filter { $0.id != preference.listId }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The default Reminders list's id, where a task approved from a
    /// message is made.
    public func defaultListId() async -> String? {
        let taskSource = self.taskSource
        return await Task.detached { taskSource.defaultListId() }.value
    }

    /// Every Reminders list but the Focus list, and whether it is ticked. A
    /// list made after you last looked reads as ticked.
    public func lists() async -> [FocusListTick] {
        let defaultId = await defaultListId()
        return await reminderLists().map {
            FocusListTick(list: $0, isTicked: isTicked($0.id), isDefault: $0.id == defaultId)
        }
    }

    /// Whether `listId` is ticked.
    public func isTicked(_ listId: String) -> Bool {
        !preference.untickedListIds.contains(listId)
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
                let previousFailure = self.failure
                let changed = await self.sync(at: moment)
                if changed || previousFailure != self.failure { self.onChange?() }
            }
            self?.running = nil
        }
    }

    /// One sync. Returns whether it changed the Board.
    private func sync(at moment: Date) async -> Bool {
        let isEnabled = preference.isEnabled
        guard isEnabled || preference.listId != nil else { return false }
        guard let initialSnapshot = board.reminderSnapshot(), blockedAtFetch != initialSnapshot.fetch else { return false }
        guard var placements = store.focusListPlacements() else {
            failure = .persistenceRead
            blockedAtFetch = initialSnapshot.fetch
            return false
        }
        let stored = placements

        let listId: String
        var unticked: Set<String> = []
        if isEnabled {
            let taskSource = self.taskSource
            let knownId = preference.listId
            guard let ensured = await Task.detached(operation: {
                try? taskSource.ensureList(id: knownId, title: focusListTitle)
            }).value else {
                failure = .reminders
                blockedAtFetch = initialSnapshot.fetch
                return false
            }
            if ensured != knownId {
                // A new list, so nothing is in it yet.
                preference.listId = ensured
                placements = []
            }
            listId = ensured
            // The Focus list itself is one of them, so none means they
            // couldn't be read.
            let lists = await Task.detached { taskSource.reminderLists() }.value
            guard !lists.isEmpty else {
                failure = .reminders
                blockedAtFetch = initialSnapshot.fetch
                return false
            }
            unticked = forgetGoneLists(lists)
        } else if let known = preference.listId {
            listId = known
        } else {
            return false
        }
        // Read after the await, so a fetch that landed meanwhile counts.
        guard let snapshot = board.reminderSnapshot() else { return false }

        placements = placements.compactMap { placement in
            guard let pending = placement.pendingMove, let current = snapshot.listIds[placement.reminderId] else {
                return placement
            }
            if current == pending.toListId {
                return current == listId
                    ? FocusListPlacement(reminderId: placement.reminderId, homeListId: placement.homeListId) : nil
            }
            if current == pending.fromListId, pending.toListId == listId { return nil }
            return FocusListPlacement(reminderId: placement.reminderId, homeListId: placement.homeListId)
        }

        let steps = isEnabled
            ? planFilling(snapshot, focusListId: listId, placements: placements, unticked: unticked, now: moment)
            : planEmptying(snapshot, focusListId: listId, placements: placements)
        let before = Dictionary(stored.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
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
            if Set(kept) != Set(stored) {
                guard persist(kept, fetch: snapshot.fetch) else { return false }
            }
            if !failedAt.values.contains(snapshot.fetch) { failure = nil }
            return false
        }

        let taskSource = self.taskSource
        var journal = Dictionary(kept.map { ($0.reminderId, $0) }, uniquingKeysWith: { first, _ in first })
        var prepared: [FocusListStep] = []
        for var step in toRun {
            if let move = step.move, let from = snapshot.listIds[step.reminderId] {
                let destination = await Task.detached {
                    switch move {
                    case .intoFocusList: return Optional(listId)
                    case .home(let home):
                        if let home, home != listId, taskSource.reminderLists().contains(where: { $0.id == home }) {
                            return home
                        }
                        return taskSource.defaultListId().flatMap { $0 == listId ? nil : $0 }
                    }
                }.value
                guard let destination else {
                    failedAt[step.reminderId] = snapshot.fetch
                    if let previous = before[step.reminderId] {
                        journal[step.reminderId] = previous
                        kept.append(previous)
                    }
                    continue
                }
                if case .home = move { step.move = .home(destination) }
                journal[step.reminderId] = FocusListPlacement(
                    reminderId: step.reminderId,
                    homeListId: step.placement?.homeListId ?? before[step.reminderId]?.homeListId,
                    pendingMove: FocusListPendingMove(fromListId: from, toListId: destination)
                )
            } else if let previous = before[step.reminderId] {
                journal[step.reminderId] = previous
            }
            prepared.append(step)
        }
        guard persist(Array(journal.values), fetch: snapshot.fetch) else { return false }
        toRun = prepared
        for step in toRun where step.unsnooze { snoozes.end(signalId: step.reminderId) }
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
        let finalized = persist(kept, fetch: snapshot.fetch)

        let wrote = toRun.contains { !failed.contains($0.reminderId) && $0.writesReminders }
        if wrote { await board.refreshReminders() }
        if let fetch = board.reminderSnapshot()?.fetch {
            for (id, plannedFetch) in failedAt where plannedFetch == snapshot.fetch { failedAt[id] = fetch }
            if !finalized { blockedAtFetch = fetch }
        }
        if finalized {
            failure = failedAt.values.contains(board.reminderSnapshot()?.fetch ?? snapshot.fetch) ? .reminders : nil
        }
        return wrote || toRun.contains { $0.unsnooze }
    }

    private func persist(_ placements: [FocusListPlacement], fetch: Int) -> Bool {
        do {
            try store.setFocusListPlacements(placements)
            blockedAtFetch = nil
            return true
        } catch {
            failure = .persistenceWrite
            blockedAtFetch = fetch
            return false
        }
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
        guard let listId else { return false }
        return (try? taskSource.update(id: step.reminderId, .list(listId))) != nil
    case nil:
        return true
    }
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
