import DailyOSApp
import DailyOSCore
import Foundation

// Checked Off (checked-off-section, checked-off-sheet): today's
// checked-off reminders, driven through `AppModel` and read back off the
// rows, count and sheet flag it publishes.

private final class FakeNow: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private struct Harness: @unchecked Sendable {
    let model: AppModel
    let taskSource: FakeTaskSource
    let store: SQLiteSignalStore
    let undoClock: FakeUndoClock
    let dayChanges: FakeDayChangeObserver
    let clock: FakeNow
}

private func makeHarness(
    tasks: [ReminderTask] = [], checkedOff: [CheckedOffReminder] = [], zen: Bool = false,
    reminders: SourceAvailability = .available, messages: SourceAvailability = .available, now: Date = Date()
) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
        let preference = ZenFocusModePreference(defaults: defaults)
        preference.isEnabled = zen
        let store = makeTestSignalStore()
        try? store.markBackfillComplete()
        let taskSource = FakeTaskSource(tasks: tasks, checkedOff: checkedOff, availability: reminders)
        let undoClock = FakeUndoClock()
        let dayChanges = FakeDayChangeObserver()
        let clock = FakeNow(now)
        let model = AppModel(AppDependencies.test { d in
            d.taskSource = taskSource
            d.messagesSource = FakeMessagesSource(messages: [], availability: messages)
            d.signalStore = store
            d.contactsResolver = FakeContactsResolver()
            d.settingsOpener = FakeSettingsOpener()
            d.refreshClock = FakeRefreshClock()
            d.eventKitChanges = FakeEventKitChangeObserver()
            d.foregroundObserver = FakeForegroundObserver()
            d.dayChanges = dayChanges
            d.zenFocusModePreference = preference
            d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
            d.undoClock = undoClock
            d.loadModel = { _, _ in FakeIntentExtractor() }
            d.historyStore = makeTestHistoryStore()
            d.correctionStore = FakeCorrectionStore()
            d.apiKeyStore = FakeAPIKeyStore()
            d.now = { clock.date }
            d.bundlePath = "/nonexistent"
        })
        return Harness(model: model, taskSource: taskSource, store: store, undoClock: undoClock, dayChanges: dayChanges, clock: clock)
    }
}

private func task(id: String, priority: Priority = .high, dueAt: Date? = nil, createdAt: Date = Date()) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: dueAt, priority: priority, createdAt: createdAt)
}

private func checkedOffReminder(
    id: String, at checkedOffAt: Date, priority: Priority = .high, createdAt: Date = Date(), isRecurring: Bool = false
) -> CheckedOffReminder {
    CheckedOffReminder(
        task: task(id: id, priority: priority, createdAt: createdAt), checkedOffAt: checkedOffAt, isRecurring: isRecurring
    )
}

@MainActor
private func checkedOffRow(_ model: AppModel, _ id: String) -> CheckedOffReminder? {
    model.checkedOff.first { $0.id == id }
}

/// The ids Checked Off lists, or `nil` when it lists nothing. Also
/// checks the count agrees with the rows, so every test covers it.
@MainActor
private func checkedOffIds(_ model: AppModel) throws -> [String]? {
    try expect(model.checkedOffCount == model.checkedOff.count, "count \(model.checkedOffCount), rows \(model.checkedOff.count)")
    return model.checkedOff.isEmpty ? nil : model.checkedOff.map(\.task.id)
}

private func settle() async {
    try? await Task.sleep(nanoseconds: 150_000_000)
}

func registerCheckedOffTests(_ runner: TestRunner) {
    runner.suite("AppModel: Checked Off lists today's checked-off reminders") { r in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        r.run("a reminder checked off elsewhere today is listed") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == ["r1"], "got \(String(describing: ids))")
        }

        r.run("with nothing open, the window shows the empty screen with the count") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let (isEmpty, ids, count) = await MainActor.run {
                (h.model.presentation.screenMode == .empty, h.model.presentation.sections.map(\.id), h.model.checkedOffCount)
            }
            try expect(isEmpty, "nothing open is the empty screen, whatever was checked off")
            try expect(ids.isEmpty, "got \(ids)")
            try expect(count == 1, "got \(count)")
            let shows = await MainActor.run { h.model.showsCheckedOffCount }
            try expect(shows, "the count shows under the empty screen")
        }

        r.run("with open work, the count shows at the end of the list") {
            let h = await makeHarness(
                tasks: [task(id: "focus")], checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now
            )
            await h.model.start()
            let (isList, shows) = await MainActor.run { (h.model.presentation.screenMode == .list, h.model.showsCheckedOffCount) }
            try expect(isList && shows)
        }

        r.run("Zen hides the count, and leaving Zen brings it back") {
            let h = await makeHarness(
                tasks: [task(id: "focus")], checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], zen: true, now: now
            )
            await h.model.start()
            let inZen = await MainActor.run { h.model.showsCheckedOffCount }
            try expect(!inZen, "Zen shows only active work")
            let afterZen = await MainActor.run {
                h.model.isZenFocusModeEnabled = false
                return h.model.showsCheckedOffCount
            }
            try expect(afterZen)
        }

        r.run("with nothing open in Zen, the window is empty") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], zen: true, now: now)
            await h.model.start()
            let (isEmpty, shows) = await MainActor.run { (h.model.presentation.screenMode == .empty, h.model.showsCheckedOffCount) }
            try expect(isEmpty, "Zen draws nothing but Focus, so the window is empty")
            try expect(!shows, "Zen's empty screen has no count under it")
        }

        r.run("nothing checked off today lists nothing and shows no count") {
            let h = await makeHarness(tasks: [task(id: "open")], now: now)
            await h.model.start()
            let (ids, shows) = try await MainActor.run { (try checkedOffIds(h.model), h.model.showsCheckedOffCount) }
            try expect(ids == nil, "got \(String(describing: ids))")
            try expect(!shows)
        }

        r.run("a reminder checked off yesterday is not listed") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "old", at: now.addingTimeInterval(-86_400 * 2))], now: now)
            await h.model.start()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == nil, "got \(String(describing: ids))")
        }

        r.run("the newest check-off comes first") {
            let h = await makeHarness(
                checkedOff: [checkedOffReminder(id: "earlier", at: now.addingTimeInterval(-120)), checkedOffReminder(id: "latest", at: now.addingTimeInterval(-10))],
                now: now
            )
            await h.model.start()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == ["latest", "earlier"], "got \(String(describing: ids))")
        }

        r.run("it is never a Section") {
            let h = await makeHarness(
                tasks: [task(id: "later", priority: .none)], checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))],
                messages: .unavailable, now: now
            )
            await h.model.start()
            let ids = await MainActor.run { h.model.presentation.sections.map(\.id) }
            try expect(ids == ["tier-focus", "tier-later", "notice-messagesUnavailable"], "got \(ids)")
        }

        r.run("the day change empties it") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            h.clock.date = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
            h.dayChanges.fire()
            await settle()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == nil, "got \(String(describing: ids))")
        }

        r.run("a revoked Reminders Gate removes it") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            h.taskSource.gateAvailability = .unavailable
            await h.model.reload()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == nil, "got \(String(describing: ids))")
        }
    }

    runner.suite("AppModel: a check-off made in DailyOS lands in Checked Off after its Undo expires") { r in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        r.run("it stays out while the Undo bar shows") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            let ids = try await MainActor.run {
                h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!)
                return try checkedOffIds(h.model)
            }
            try expect(ids == nil, "got \(String(describing: ids))")
        }

        r.run("it appears once the Undo expires, and leaves Focus") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            await MainActor.run { h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!) }
            h.undoClock.fire()
            await settle()
            let (ids, focus) = try await MainActor.run { (try checkedOffIds(h.model), h.model.rankedList.focus.map(\.id)) }
            try expect(ids == ["r1"], "got \(String(describing: ids))")
            try expect(focus.isEmpty, "got \(focus)")
        }

        r.run("Undo leaves it out") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            await MainActor.run { h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!) }
            await h.model.undo()
            h.undoClock.fire()
            await settle()
            let (ids, focus) = try await MainActor.run { (try checkedOffIds(h.model), h.model.rankedList.focus.map(\.id)) }
            try expect(ids == nil, "got \(String(describing: ids))")
            try expect(focus == ["r1"], "got \(focus)")
        }
    }

    runner.suite("AppModel: unchecking a Checked Off row reopens the reminder") { r in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        r.run("it leaves Checked Off and is open in Reminders again") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let row = try await MainActor.run { try require(checkedOffRow(h.model, "r1")) }
            await h.model.uncheck(row)
            let (ids, focus) = try await MainActor.run { (try checkedOffIds(h.model), h.model.rankedList.focus.map(\.id)) }
            try expect(ids == nil, "got \(String(describing: ids))")
            try expect(focus == ["r1"], "a reminder with a Priority goes back to Focus, got \(focus)")
            try expect(h.taskSource.tasks.map(\.id) == ["r1"])
        }

        r.run("with no Priority or date it goes to Later") {
            let h = await makeHarness(
                checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60), priority: .none)], now: now
            )
            await h.model.start()
            let row = try await MainActor.run { try require(checkedOffRow(h.model, "r1")) }
            await h.model.uncheck(row)
            let later = await MainActor.run { h.model.rankedList.later.map(\.id) }
            try expect(later == ["r1"], "got \(later)")
        }

        r.run("it takes its computed place, not the spot it was dragged to") {
            let h = await makeHarness(
                tasks: [task(id: "a")],
                checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60), createdAt: now.addingTimeInterval(-86_400 * 30))],
                now: now
            )
            try h.store.setFocusOrders(["r1": 0, "a": 1])
            await h.model.start()
            let row = try await MainActor.run { try require(checkedOffRow(h.model, "r1")) }
            await h.model.uncheck(row)
            let focus = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(focus == ["a", "r1"], "got \(focus)")
        }

        r.run("it offers no Undo") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let row = try await MainActor.run { try require(checkedOffRow(h.model, "r1")) }
            await h.model.uncheck(row)
            let offer = await MainActor.run { h.model.undoOffer }
            try expect(offer == nil, "got \(String(describing: offer))")
        }
    }

    runner.suite("AppModel: recurring reminders are listed but locked") { r in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        r.run("a recurring reminder is listed") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60), isRecurring: true)], now: now)
            await h.model.start()
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == ["r1"], "got \(String(describing: ids))")
        }

        r.run("unchecking it writes nothing and leaves it in Checked Off") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60), isRecurring: true)], now: now)
            await h.model.start()
            let row = try await MainActor.run { try require(checkedOffRow(h.model, "r1")) }
            await h.model.uncheck(row)
            let ids = try await MainActor.run { try checkedOffIds(h.model) }
            try expect(ids == ["r1"], "got \(String(describing: ids))")
            try expect(h.taskSource.tasks.isEmpty, "the reminder must stay completed")
        }
    }

    runner.suite("AppModel: the Checked Off sheet") { r in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        r.run("the count reads in the singular and the plural") {
            try expect(checkedOffCountText(1) == "1 reminder completed today")
            try expect(checkedOffCountText(3) == "3 reminders completed today")
        }

        r.run("toggling opens it when something was checked off today") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let presented = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return h.model.isCheckedOffSheetPresented
            }
            try expect(presented)
        }

        r.run("toggling does nothing when nothing was checked off today") {
            let h = await makeHarness(tasks: [task(id: "open")], now: now)
            await h.model.start()
            let presented = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return h.model.isCheckedOffSheetPresented
            }
            try expect(!presented)
        }

        r.run("unchecking the last row leaves it open and empty, and toggling closes it") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let row = try await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return try require(checkedOffRow(h.model, "r1"))
            }
            await h.model.uncheck(row)
            let (presented, count) = await MainActor.run { (h.model.isCheckedOffSheetPresented, h.model.checkedOffCount) }
            try expect(presented, "an emptied sheet stays open")
            try expect(count == 0, "got \(count)")
            let afterToggle = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return h.model.isCheckedOffSheetPresented
            }
            try expect(!afterToggle, "toggling closes an empty sheet")
        }

        r.run("the day change empties it but leaves it open") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            await MainActor.run { h.model.toggleCheckedOffSheet() }
            h.clock.date = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
            h.dayChanges.fire()
            await settle()
            let (presented, count) = await MainActor.run { (h.model.isCheckedOffSheetPresented, h.model.checkedOffCount) }
            try expect(presented)
            try expect(count == 0, "got \(count)")
        }

        r.run("a revoked Reminders Gate empties it but leaves it open") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            await MainActor.run { h.model.toggleCheckedOffSheet() }
            h.taskSource.gateAvailability = .unavailable
            await h.model.reload()
            let (presented, count) = await MainActor.run { (h.model.isCheckedOffSheetPresented, h.model.checkedOffCount) }
            try expect(presented)
            try expect(count == 0, "got \(count)")
        }

        r.run("entering Zen closes it, and leaving Zen doesn't reopen it") {
            let h = await makeHarness(
                tasks: [task(id: "focus")], checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now
            )
            await h.model.start()
            let inZen = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                h.model.isZenFocusModeEnabled = true
                return h.model.isCheckedOffSheetPresented
            }
            try expect(!inZen, "Zen shows only active work")
            let afterZen = await MainActor.run {
                h.model.isZenFocusModeEnabled = false
                return h.model.isCheckedOffSheetPresented
            }
            try expect(!afterZen)
        }

        r.run("toggling in Zen does nothing") {
            let h = await makeHarness(
                tasks: [task(id: "focus")], checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], zen: true, now: now
            )
            await h.model.start()
            let (presented, canToggle) = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return (h.model.isCheckedOffSheetPresented, h.model.canToggleCheckedOffSheet)
            }
            try expect(!presented)
            try expect(!canToggle, "the menu item is disabled in Zen")
        }

        r.run("the menu item is enabled with a count, or while the sheet is open") {
            let h = await makeHarness(checkedOff: [checkedOffReminder(id: "r1", at: now.addingTimeInterval(-60))], now: now)
            await h.model.start()
            let withCount = await MainActor.run { h.model.canToggleCheckedOffSheet }
            try expect(withCount)
            let row = try await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return try require(checkedOffRow(h.model, "r1"))
            }
            await h.model.uncheck(row)
            let emptyButOpen = await MainActor.run { h.model.canToggleCheckedOffSheet }
            try expect(emptyButOpen, "an open sheet can always be closed")
            let closed = await MainActor.run {
                h.model.toggleCheckedOffSheet()
                return h.model.canToggleCheckedOffSheet
            }
            try expect(!closed, "nothing to open")
        }
    }
}
