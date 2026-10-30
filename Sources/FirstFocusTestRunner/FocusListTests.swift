import FirstFocusApp
import FirstFocusCore
import Foundation

// The Focus list (ADR 0048): a list in Reminders FirstFocus keeps matching
// the Focus Tier, where a move you make counts as Move to Focus or Move
// to Later. Driven through `FocusList` against `FakeTaskSource` and a
// test SQLite store, and through `AppModel` for the setting.

private let focus = "focus"
private let home = "home"
private let work = "work"
private let muse = "muse"

private func task(_ id: String, priority: Priority = .none, dueAt: Date? = nil, list: String?) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: dueAt, priority: priority, createdAt: Date(), listId: list)
}

private final class Count: @unchecked Sendable {
    var value = 0
}

/// A record that can't be read.
private struct UnreadableStore: FocusListStore {
    func focusListPlacements() -> [FocusListPlacement]? { nil }
    func setFocusListPlacements(_ placements: [FocusListPlacement]) throws { throw SignalStoreError.cannotOpen }
}

private struct Harness: @unchecked Sendable {
    let focusList: FocusList
    let board: SignalBoard
    let snoozes: Snoozes
    let taskSource: FakeTaskSource
    let store: SQLiteSignalStore
    let preference: FocusListPreference
    let changes: Count
}

/// The lists Reminders, Work and, unless `withFocusList` is false, a
/// Focus list FirstFocus already uses. `placed` is the record from the last
/// sync. `withMuse` adds Muse List, which you unticked.
@MainActor
private func makeHarness(
    _ tasks: [ReminderTask], checkedOff: [CheckedOffReminder] = [], placed: [FocusListPlacement] = [],
    withFocusList: Bool = true, withMuse: Bool = false, record: (any FocusListStore)? = nil
) -> Harness {
    let taskSource = FakeTaskSource(tasks: tasks, checkedOff: checkedOff)
    taskSource.addList(id: home, title: "Reminders")
    taskSource.addList(id: work, title: "Work")
    taskSource.defaultList = home
    let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
    if withFocusList {
        taskSource.addList(id: focus, title: "Focus")
        preference.listId = focus
    }
    if withMuse {
        taskSource.addList(id: muse, title: "Muse List")
        preference.untickedListIds = [muse]
    }
    let store = makeTestSignalStore()
    try? store.setFocusListPlacements(placed)
    let snoozes = Snoozes(store: store)
    let board = SignalBoard(taskSource: taskSource, signalStore: store, snoozes: snoozes)
    let focusList = FocusList(
        taskSource: taskSource, store: record ?? store, board: board, snoozes: snoozes, preference: preference
    )
    let changes = Count()
    focusList.onChange = { changes.value += 1 }
    return Harness(
        focusList: focusList, board: board, snoozes: snoozes, taskSource: taskSource, store: store, preference: preference, changes: changes
    )
}

/// Fetches Reminders, unless `fetch` is false, then tells the Focus list
/// the Ranked List was derived and waits for its one sync.
private func sync(_ h: Harness, at now: Date = Date(), fetch: Bool = true) async {
    if fetch { await h.board.refreshReminders() }
    await MainActor.run { h.focusList.listDerived(at: now) }
    await h.focusList.settled()
}

private func list(of id: String, in taskSource: FakeTaskSource) -> String? {
    (taskSource.tasks.first { $0.id == id } ?? taskSource.checkedOff.first { $0.id == id }?.task)?.listId
}

private func priority(of id: String, in taskSource: FakeTaskSource) -> Priority? {
    taskSource.tasks.first { $0.id == id }?.priority
}

private func placed(_ id: String, _ home: String?) -> FocusListPlacement {
    FocusListPlacement(reminderId: id, homeListId: home)
}

@MainActor
private func makeModel(_ taskSource: FakeTaskSource, _ preference: FocusListPreference) -> AppModel {
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    return AppModel(AppDependencies.test { d in
        d.taskSource = taskSource
        d.messagesSource = FakeMessagesSource(messages: [], availability: .available)
        d.signalStore = store
        d.contactsResolver = FakeContactsResolver()
        d.settingsOpener = FakeSettingsOpener()
        d.refreshClock = FakeRefreshClock()
        d.eventKitChanges = FakeEventKitChangeObserver()
        d.foregroundObserver = FakeForegroundObserver()
        d.dayChanges = FakeDayChangeObserver()
        d.zenFocusModePreference = ZenFocusModePreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
        d.focusListPreference = preference
        d.loadModel = { _, _ in FakeIntentExtractor() }
        d.historyStore = makeTestHistoryStore()
        d.correctionStore = FakeCorrectionStore()
        d.apiKeyStore = FakeAPIKeyStore()
        d.bundlePath = "/nonexistent"
    })
}

func registerFocusListTests(_ runner: TestRunner) {
    registerFocusListRecoveryTests(runner)
    runner.suite("Focus list: keeping it in line with the Focus Tier") { r in
        r.run("the first sync makes a Focus list and moves the Focus Tier into it") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, list: work), task("b", list: home)], withFocusList: false)
            }
            await sync(h)
            let listId = try require(h.preference.listId)
            try expect(h.taskSource.lists[listId] == "Focus")
            try expect(list(of: "a", in: h.taskSource) == listId)
            try expect(list(of: "b", in: h.taskSource) == home, "a Later reminder stays where it is")
            try expect(h.store.focusListPlacements() == [placed("a", work)], "it remembers its own list")
            try expect(h.changes.value == 1)
            await sync(h)
            try expect(h.changes.value == 1, "a second sync finds nothing to move")
        }

        r.run("a reminder leaving the Focus Tier goes back to its own list") {
            let h = await MainActor.run { makeHarness([task("a", list: focus)], placed: [placed("a", work)]) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work)
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("a Snoozed reminder leaves the list and stays Snoozed") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: focus)], placed: [placed("a", home)]) }
            let until = Date().addingTimeInterval(3600)
            await MainActor.run { h.snoozes.snooze(signalId: "a", until: until, dueAt: nil) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == home)
            try await MainActor.run { try expect(h.snoozes.until(signalId: "a") != nil, "only a move you make ends a snooze") }
        }

        r.run("a reminder checked off in the list goes back to its own list") {
            let done = CheckedOffReminder(task: task("a", list: focus), checkedOffAt: Date())
            let h = await MainActor.run { makeHarness([], checkedOff: [done], placed: [placed("a", work)]) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work)
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("a reminder whose list is unknown is left alone") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: nil)]) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == nil)
            try expect(h.changes.value == 0)
        }

        r.run("with its own list deleted, a reminder goes to the default list") {
            let h = await MainActor.run { makeHarness([task("a", list: focus)], placed: [placed("a", work)]) }
            h.taskSource.removeList(id: work)
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == home)
        }

        r.run("a list made again after you deleted it starts with nothing placed") {
            let h = await MainActor.run { makeHarness([], placed: [placed("gone-reminder", home)], withFocusList: false) }
            h.preference.listId = "deleted"
            await sync(h)
            try expect(h.preference.listId != "deleted")
            try expect(h.store.focusListPlacements() == [])
        }
    }

    runner.suite("Focus list: moves you make in Reminders") { r in
        r.run("putting a Later reminder in the list gives it a Priority, as Move to Focus does") {
            let h = await MainActor.run { makeHarness([task("a", list: focus)]) }
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == .high)
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(h.store.focusListPlacements() == [placed("a", nil)], "its own list is unknown")
        }

        r.run("putting a Snoozed reminder in the list ends its snooze") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: focus)]) }
            await MainActor.run { h.snoozes.snooze(signalId: "a", until: Date().addingTimeInterval(3600), dueAt: nil) }
            await sync(h)
            try await MainActor.run { try expect(h.snoozes.until(signalId: "a") == nil) }
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(h.changes.value == 1, "ending a snooze changes the Board")
        }

        r.run("taking a reminder out clears its Priority, as Move to Later does") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: work)], placed: [placed("a", home)]) }
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == Priority.none)
            try expect(list(of: "a", in: h.taskSource) == work, "it stays in the list you moved it to")
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("taking out one its due date holds in Focus puts it back, to return later to the list you chose") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, dueAt: Date(), list: work)], placed: [placed("a", home)])
            }
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == .high, "Move to Later does nothing to a row its due date holds")
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(h.store.focusListPlacements() == [placed("a", work)])
        }
    }

    runner.suite("Focus list: the lists it draws from") { r in
        r.run("every list starts ticked") {
            let h = await MainActor.run { makeHarness([]) }
            await sync(h)
            try expect(h.preference.untickedListIds.isEmpty)
            let ticks = await h.focusList.lists()
            try expect(ticks.map(\.list.title) == ["Reminders", "Work"] && ticks.allSatisfy(\.isTicked))
        }

        r.run("a list made later starts ticked, so its Focus Tier reminders move in") {
            let h = await MainActor.run { makeHarness([]) }
            await sync(h)
            h.taskSource.addList(id: "later", title: "Later List")
            h.taskSource.add(task("b", priority: .high, list: "later"))
            await sync(h)
            try expect(h.preference.untickedListIds.isEmpty)
            try expect(list(of: "b", in: h.taskSource) == focus)
        }

        r.run("an install with the old record keeps the lists that were unticked in it") {
            let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
            defaults.set([home, work, muse], forKey: "focusListSeenListIds")
            defaults.set([home, work], forKey: "focusListTickedListIds")
            let preference = FocusListPreference(defaults: defaults)
            try expect(preference.untickedListIds == [muse])
            preference.untickedListIds = []
            try expect(preference.untickedListIds.isEmpty, "once written, the old record is no longer read")
        }

        r.run("a reminder with a Priority in an unticked list stays put and keeps its Priority") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: muse)], withMuse: true) }
            await sync(h)
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == muse)
            try expect(priority(of: "a", in: h.taskSource) == .high)
            try expect(h.changes.value == 0)
        }

        r.run("a reminder its due date holds in Focus stays in an unticked list") {
            let h = await MainActor.run { makeHarness([task("a", dueAt: Date(), list: muse)], withMuse: true) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == muse)
            try expect(priority(of: "a", in: h.taskSource) == Priority.none)
        }

        r.run("taking a reminder out into an unticked list is final, whatever its due date") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, dueAt: Date(), list: muse)], placed: [placed("a", work)], withMuse: true)
            }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == muse)
            try expect(priority(of: "a", in: h.taskSource) == .high, "it isn't a Move to Later")
            try expect(h.store.focusListPlacements() == [])
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == muse)
            try expect(h.changes.value == 0)
        }

        r.run("unticking a list sends its reminders back with their Priority") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, dueAt: Date(), list: focus)], placed: [placed("a", work)])
            }
            await sync(h)
            await MainActor.run { h.focusList.setTicked(false, listId: work) }
            await h.focusList.settled()
            try expect(list(of: "a", in: h.taskSource) == work)
            try expect(priority(of: "a", in: h.taskSource) == .high)
            try expect(h.store.focusListPlacements() == [])
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work, "it stays out")
        }

        r.run("ticking a list moves its Focus Tier reminders in") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: muse)], withMuse: true) }
            await sync(h)
            await MainActor.run { h.focusList.setTicked(true, listId: muse) }
            await h.focusList.settled()
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(h.store.focusListPlacements() == [placed("a", muse)])
        }

        r.run("a reminder you put in the list from an unticked list is Move to Focus") {
            let h = await MainActor.run { makeHarness([task("a", list: muse)], withMuse: true) }
            await sync(h)
            try h.taskSource.update(id: "a", .list(focus))
            await sync(h)
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(priority(of: "a", in: h.taskSource) == .high)
        }

        r.run("a deleted list is forgotten, and one made again with its title starts ticked") {
            let h = await MainActor.run { makeHarness([]) }
            await MainActor.run { h.focusList.setTicked(false, listId: work) }
            await sync(h)
            h.taskSource.removeList(id: work)
            h.taskSource.addList(id: "work-again", title: "Work")
            await sync(h)
            try expect(h.preference.untickedListIds.isEmpty)
        }

        r.run("the ticks survive turning the setting off and on") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: muse)], withMuse: true) }
            await MainActor.run { h.focusList.isEnabled = false }
            await sync(h)
            await MainActor.run { h.focusList.isEnabled = true }
            await sync(h)
            try expect(h.preference.untickedListIds == [muse])
            try expect(list(of: "a", in: h.taskSource) == muse)
        }

        r.run("nothing is forgotten while Reminders is Unavailable") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: work)], withMuse: true) }
            h.taskSource.gateAvailability = .unavailable
            await sync(h)
            try expect(h.preference.untickedListIds == [muse])
            try expect(list(of: "a", in: h.taskSource) == work)
        }
    }

    runner.suite("Focus list: writes that fail") { r in
        r.run("a failed Priority write leaves your move to be tried again after the next fetch") {
            let h = await MainActor.run { makeHarness([task("a", list: focus)]) }
            h.taskSource.failsUpdates = ["a"]
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == focus, "it isn't sent home")
            try expect(h.store.focusListPlacements() == [], "your move isn't recorded as handled")
            h.taskSource.failsUpdates = []
            await sync(h, fetch: false)
            try expect(priority(of: "a", in: h.taskSource) == Priority.none, "not tried again from the same fetch")
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == .high)
        }

        r.run("a failed demote leaves your move to be tried again") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: work)], placed: [placed("a", home)]) }
            h.taskSource.failsUpdates = ["a"]
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work, "it isn't moved back")
            try expect(h.store.focusListPlacements() == [placed("a", home)])
            h.taskSource.failsUpdates = []
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == Priority.none)
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("a move that keeps failing doesn't stop the next sync") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, list: home), task("b", priority: .high, list: focus)], placed: [placed("b", home)])
            }
            h.taskSource.unmovableIds = ["a"]
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == home)
            await MainActor.run { h.snoozes.snooze(signalId: "b", until: Date().addingTimeInterval(3600), dueAt: nil) }
            await sync(h, fetch: false)
            try expect(list(of: "b", in: h.taskSource) == home, "a snooze still takes it out")
        }

        r.run("a move that failed isn't read later as one you made") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: work)]) }
            h.taskSource.unmovableIds = ["a"]
            await sync(h)
            await sync(h)
            try expect(priority(of: "a", in: h.taskSource) == .high, "its Priority is untouched")
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("nothing moves while the record can't be read") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: work)], record: UnreadableStore()) }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work)
        }
    }

    runner.suite("Focus list: turning it off") { r in
        r.run("sends every reminder back and keeps the list") {
            let h = await MainActor.run {
                makeHarness([task("a", priority: .high, list: focus), task("b", priority: .high, list: focus)], placed: [placed("a", work)])
            }
            await MainActor.run { h.focusList.isEnabled = false }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work)
            try expect(list(of: "b", in: h.taskSource) == home, "an unknown list means the default list")
            try expect(priority(of: "b", in: h.taskSource) == .high, "nothing else about it changes")
            try expect(h.taskSource.lists[focus] == "Focus")
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("while Reminders is Unavailable, empties the list once Reminders is back") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: focus)], placed: [placed("a", work)]) }
            h.taskSource.gateAvailability = .unavailable
            await MainActor.run { h.focusList.isEnabled = false }
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == focus)
            try expect(h.store.focusListPlacements() == [placed("a", work)], "the record is kept")
            h.taskSource.gateAvailability = .available
            await sync(h)
            try expect(list(of: "a", in: h.taskSource) == work)
            try expect(h.store.focusListPlacements() == [])
        }

        r.run("turning it back on uses the same list") {
            let h = await MainActor.run { makeHarness([task("a", priority: .high, list: focus)], placed: [placed("a", work)]) }
            await MainActor.run { h.focusList.isEnabled = false }
            await sync(h)
            await MainActor.run { h.focusList.isEnabled = true }
            await sync(h)
            try expect(h.preference.listId == focus)
            try expect(list(of: "a", in: h.taskSource) == focus)
        }
    }

    runner.suite("Focus list: the setting") { r in
        r.run("is on by default, and turning it off moves every reminder back") {
            let taskSource = FakeTaskSource(tasks: [task("a", priority: .high, list: work)])
            taskSource.addList(id: work, title: "Work")
            taskSource.defaultList = work
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.start()
            await model.focusListSettled()
            let listId = try require(preference.listId)
            try expect(list(of: "a", in: taskSource) == listId)

            await MainActor.run { model.isFocusListEnabled = false }
            await model.focusListSettled()
            try expect(!preference.isEnabled)
            try expect(list(of: "a", in: taskSource) == work)

            await MainActor.run { model.isFocusListEnabled = true }
            await model.focusListSettled()
            try expect(list(of: "a", in: taskSource) == listId, "turning it back on uses the same list")
        }

        r.run("Advanced lists every list but the Focus list, and a tick moves reminders") {
            let taskSource = FakeTaskSource(tasks: [task("a", priority: .high, list: work)])
            taskSource.addList(id: work, title: "Work")
            taskSource.addList(id: home, title: "Reminders")
            taskSource.defaultList = home
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.start()
            await model.focusListSettled()
            let listId = try require(preference.listId)
            await model.refreshFocusListTicks()
            try await MainActor.run {
                try expect(model.focusListTicks.map(\.list.title) == ["Reminders", "Work"])
                try expect(model.focusListTicks.allSatisfy(\.isTicked))
            }
            try expect(list(of: "a", in: taskSource) == listId)

            await MainActor.run { model.setFocusListTick(false, listId: work) }
            await model.focusListSettled()
            try expect(list(of: "a", in: taskSource) == work)
            try expect(priority(of: "a", in: taskSource) == .high)
            try await MainActor.run { try expect(model.focusListTicks.first { $0.id == work }?.isTicked == false) }

            await MainActor.run { model.setFocusListTick(true, listId: work) }
            await model.focusListSettled()
            try expect(list(of: "a", in: taskSource) == listId)
        }

        r.run("an unticked list's reminders leave the window, even with the Focus list off, and return when ticked") {
            let done = CheckedOffReminder(task: task("d", list: work), checkedOffAt: Date())
            let taskSource = FakeTaskSource(
                tasks: [task("a", priority: .high, list: work), task("b", priority: .high, list: home)], checkedOff: [done]
            )
            taskSource.addList(id: work, title: "Work")
            taskSource.addList(id: home, title: "Reminders")
            taskSource.defaultList = home
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            preference.isEnabled = false
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.start()
            try await MainActor.run {
                try expect(Set(model.rankedList.focus.map(\.id)) == ["a", "b"])
                try expect(model.checkedOff.map(\.id) == ["d"])
            }

            await MainActor.run { model.setFocusListTick(false, listId: work) }
            try await MainActor.run {
                try expect(model.rankedList.focus.map(\.id) == ["b"], "Work's reminder is gone from Focus")
                try expect(model.checkedOff.isEmpty, "and from the Checked Off sheet")
            }

            await MainActor.run { model.setFocusListTick(true, listId: work) }
            try await MainActor.run { try expect(Set(model.rankedList.focus.map(\.id)) == ["a", "b"]) }
        }

        r.run("a list unticked in an earlier launch is still hidden at start") {
            let taskSource = FakeTaskSource(tasks: [task("a", priority: .high, list: work)])
            taskSource.addList(id: work, title: "Work")
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            preference.untickedListIds = [work]
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.start()
            await model.focusListSettled()
            try await MainActor.run { try expect(model.rankedList.focus.isEmpty && model.rankedList.later.isEmpty) }
            try expect(list(of: "a", in: taskSource) == work, "and the Focus list leaves it alone")
        }

        r.run("the ticks Advanced shows are the stored record, not a copy AppModel keeps") {
            let taskSource = FakeTaskSource(tasks: [])
            taskSource.addList(id: work, title: "Work")
            taskSource.addList(id: home, title: "Reminders")
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.refreshFocusListTicks()
            preference.untickedListIds = [work]
            let ticks = await MainActor.run { model.focusListTicks.map { "\($0.list.title):\($0.isTicked)" } }
            try expect(ticks == ["Reminders:true", "Work:false"], "got \(ticks)")
        }

        r.run("a Move to Later from the window takes the reminder out") {
            let taskSource = FakeTaskSource(tasks: [task("a", priority: .high, list: work)])
            taskSource.addList(id: work, title: "Work")
            let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let model = await MainActor.run { makeModel(taskSource, preference) }
            await model.start()
            await model.focusListSettled()
            let signal = try await MainActor.run { try require(model.rankedList.focus.first) }
            await model.demote(signal)
            await model.focusListSettled()
            try expect(list(of: "a", in: taskSource) == work)
            try await MainActor.run { try expect(model.rankedList.later.map(\.id) == ["a"]) }
        }
    }
}
