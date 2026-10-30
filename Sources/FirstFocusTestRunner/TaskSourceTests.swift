import FirstFocusCore
import Foundation

/// `@unchecked Sendable`: every call in these tests happens synchronously on
/// the same thread (`RefreshCoordinator`'s `eventKitChanges.fire()` calls
/// `onRefresh` directly), same justification as `RefreshCoordinatorTests`'
/// `TriggerRecorder`. Bundles a `FakeTaskSource` with the ranked Signals a
/// real `.eventKitChange` refresh would recompute, so a test can simulate an
/// edit made directly in the Reminders app (mutating the fake without going
/// through FirstFocus) and check it actually reaches the list a refresh
/// produces, not just that the fake's own state changed.
private final class ExternalChangeHarness: @unchecked Sendable {
    let fake: FakeTaskSource
    private(set) var latestSignals: [Signal] = []

    init(fake: FakeTaskSource) {
        self.fake = fake
    }

    func refresh(on trigger: RefreshTrigger) {
        guard trigger == .eventKitChange else { return }
        latestSignals = fake.listOpenTasks().map(makeSignal(from:))
    }
}

func registerTaskSourceTests(_ runner: TestRunner) {
    runner.suite("Reminder priority collapse") { r in
        r.run("0 is unset, not urgent") {
            try expect(collapseReminderPriority(0) == .none)
        }
        for raw in 1...4 {
            r.run("\(raw) is high") {
                try expect(collapseReminderPriority(raw) == .high)
            }
        }
        for raw in 5...9 {
            r.run("\(raw) is normal") {
                try expect(collapseReminderPriority(raw) == .normal)
            }
        }
    }

    runner.suite("Reminder priority expansion") { r in
        r.run("expanding then collapsing each band round-trips to itself") {
            for priority: Priority in [.none, .high, .normal] {
                try expect(collapseReminderPriority(expandReminderPriority(priority)) == priority)
            }
        }
    }

    runner.suite("Reminder to Signal mapping") { r in
        r.run("label equals original text for a Reminders Signal") {
            let task = ReminderTask(id: "r1", title: "Call the dentist", dueAt: nil, priority: .none, createdAt: Date())
            let signal = makeSignal(from: task)
            try expect(signal.label == signal.originalText)
            try expect(signal.label == "Call the dentist")
        }
        r.run("Reminders Signals are stated, never inferred") {
            let task = ReminderTask(id: "r1", title: "Call the dentist", dueAt: nil, priority: .none, createdAt: Date())
            try expect(makeSignal(from: task).provenance == .stated)
        }
        r.run("source and identity carry through from the task") {
            let task = ReminderTask(id: "r42", title: "Anything", dueAt: nil, priority: .high, createdAt: Date())
            let signal = makeSignal(from: task)
            try expect(signal.source == .reminders)
            try expect(signal.sourceRef == "r42")
            try expect(signal.id == "r42")
            try expect(signal.priority == .high)
        }
    }

    runner.suite("Setting a reminder's priority") { r in
        r.run("a value already in the band is kept") {
            try expect(reminderPriority(setting: .normal, over: 9) == 9, "Low stays Low")
            try expect(reminderPriority(setting: .normal, over: 5) == 5)
            try expect(reminderPriority(setting: .high, over: 3) == 3)
            try expect(reminderPriority(setting: .none, over: 0) == 0)
        }
        r.run("a value in another band becomes that band's canonical value") {
            try expect(reminderPriority(setting: .high, over: 9) == 1)
            try expect(reminderPriority(setting: .high, over: 0) == 1)
            try expect(reminderPriority(setting: .none, over: 3) == 0)
            try expect(reminderPriority(setting: .normal, over: 0) == 5)
        }
    }

    runner.suite("A due date's stored components") { r in
        let calendar = Calendar(identifier: .gregorian)
        r.run("a date at the start of its day is stored as a date alone, all day") {
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
            let components = reminderDueDateComponents(for: date, calendar: calendar)
            try expect(components.hour == nil && components.minute == nil && components.second == nil)
            try expect(calendar.date(from: components) == date)
        }
        r.run("any other time is stored to the second") {
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15, minute: 30, second: 5))!
            let components = reminderDueDateComponents(for: date, calendar: calendar)
            try expect(components.hour == 15 && components.minute == 30 && components.second == 5)
            try expect(calendar.date(from: components) == date)
        }
    }

    runner.suite("FakeTaskSource") { r in
        r.run("undated reminders are returned, not dropped") {
            let undated = ReminderTask(id: "1", title: "No due date", dueAt: nil, priority: .none, createdAt: Date())
            let fake = FakeTaskSource(tasks: [undated])
            try expect(fake.listOpenTasks().count == 1)
            try expect(fake.listOpenTasks().first?.dueAt == nil)
        }
        r.run("completing a task removes it from the open list") {
            let task = ReminderTask(id: "1", title: "Done soon", dueAt: nil, priority: .none, createdAt: Date())
            let fake = FakeTaskSource(tasks: [task])
            try fake.complete(id: "1")
            try expect(fake.listOpenTasks().isEmpty)
            try expect(fake.completedIds == ["1"])
        }
        r.run("completing an unknown id throws rather than silently succeeding") {
            let fake = FakeTaskSource(tasks: [])
            var threw = false
            do {
                try fake.complete(id: "missing")
            } catch {
                threw = true
            }
            try expect(threw, "expected complete(id:) to throw for an unknown id")
        }

        r.run("creating a task assigns a real id and adds it to the open list") {
            let fake = FakeTaskSource(tasks: [])
            let created = try fake.create(ReminderDraft(title: "Buy milk", dueAt: nil, priority: .none))
            try expect(!created.id.isEmpty, "expected a real, non-empty id from create")
            try expect(created.title == "Buy milk")
            try expect(fake.listOpenTasks().map(\.id) == [created.id])
        }

        r.run("created tasks carry the draft's due date and priority through") {
            let fake = FakeTaskSource(tasks: [])
            let dueAt = Date(timeIntervalSince1970: 2_000_000)
            let created = try fake.create(ReminderDraft(title: "Renew passport", dueAt: dueAt, priority: .high))
            try expect(created.dueAt == dueAt)
            try expect(created.priority == .high)
        }

        r.run("an edit sets its one field and leaves the others") {
            let dueAt = Date(timeIntervalSince1970: 2_000_000)
            let task = ReminderTask(id: "1", title: "Old title", dueAt: dueAt, priority: .normal, createdAt: Date())
            let fake = FakeTaskSource(tasks: [task])
            try fake.update(id: "1", .title("New title"))
            var read = try require(fake.listOpenTasks().first)
            try expect(read.title == "New title")
            try expect(read.priority == .normal)
            try expect(read.dueAt == dueAt)
            try fake.update(id: "1", .priority(.high))
            read = try require(fake.listOpenTasks().first)
            try expect(read.title == "New title")
            try expect(read.priority == .high)
            try expect(read.dueAt == dueAt)
        }

        r.run("updating an unknown id throws rather than silently succeeding") {
            let fake = FakeTaskSource(tasks: [])
            var threw = false
            do {
                try fake.update(id: "missing", .title("Ghost"))
            } catch {
                threw = true
            }
            try expect(threw, "expected update(id:_:) to throw for an unknown id")
        }

        r.run("deleting a task removes it from the open list") {
            let task = ReminderTask(id: "1", title: "Cancel this", dueAt: nil, priority: .none, createdAt: Date())
            let fake = FakeTaskSource(tasks: [task])
            try fake.delete(id: "1")
            try expect(fake.listOpenTasks().isEmpty)
        }

        r.run("deleting an unknown id throws rather than silently succeeding") {
            let fake = FakeTaskSource(tasks: [])
            var threw = false
            do {
                try fake.delete(id: "missing")
            } catch {
                threw = true
            }
            try expect(threw, "expected delete(id:) to throw for an unknown id")
        }
    }

    runner.suite("Bidirectional sync reaches the ranked list via refresh") { r in
        r.run("a task created externally is picked up on the next eventKitChange trigger") {
            let harness = ExternalChangeHarness(fake: FakeTaskSource(tasks: []))
            let eventKitChanges = FakeEventKitChangeObserver()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: eventKitChanges,
                onRefresh: harness.refresh
            )
            // Simulates an edit made directly in the Reminders app: the fake
            // is mutated as EventKit would be, with no call through FirstFocus.
            _ = try harness.fake.create(ReminderDraft(title: "Added externally"))
            eventKitChanges.fire()
            try expect(harness.latestSignals.map(\.label) == ["Added externally"])
        }

        r.run("a task deleted externally disappears from the ranked list on the next trigger") {
            let task = ReminderTask(id: "1", title: "Will be deleted externally", dueAt: nil, priority: .none, createdAt: Date())
            let harness = ExternalChangeHarness(fake: FakeTaskSource(tasks: [task]))
            let eventKitChanges = FakeEventKitChangeObserver()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: eventKitChanges,
                onRefresh: harness.refresh
            )
            try harness.fake.delete(id: "1")
            eventKitChanges.fire()
            try expect(harness.latestSignals.isEmpty)
        }

        r.run("a priority change made externally re-ranks the task on the next trigger") {
            let task = ReminderTask(id: "1", title: "Will be reprioritized", dueAt: nil, priority: .none, createdAt: Date())
            let harness = ExternalChangeHarness(fake: FakeTaskSource(tasks: [task]))
            let eventKitChanges = FakeEventKitChangeObserver()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: eventKitChanges,
                onRefresh: harness.refresh
            )
            try harness.fake.update(id: "1", .priority(.high))
            eventKitChanges.fire()
            try expect(harness.latestSignals.first?.priority == .high)
        }
    }
}
