import FirstFocusCore
import Foundation

// snooze-wake: the snooze module keeps its alarm set for the earliest
// snooze end still to come, read from its store, and says when one ends.
// Driven through `Snoozes` on a test SQLite store and a fake alarm.

private final class Moment: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class Wakes: @unchecked Sendable {
    var count = 0
}

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func reminder(_ id: String, dueAt: Date? = nil, isRecurring: Bool = false) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: dueAt, priority: .none, createdAt: start, isRecurring: isRecurring)
}

private func signal(_ id: String) -> Signal {
    makeSignal(from: reminder(id))
}

private struct Harness: @unchecked Sendable {
    let snoozes: Snoozes
    let alarm: FakeAlarm
    let store: SQLiteSignalStore
    let moment: Moment
    let wakes: Wakes
}

@MainActor
private func makeHarness(store: SQLiteSignalStore = makeTestSignalStore(), at date: Date = start) -> Harness {
    let alarm = FakeAlarm()
    let moment = Moment(date)
    let wakes = Wakes()
    let snoozes = Snoozes(store: store, alarm: alarm, now: { moment.date })
    snoozes.onWake = { wakes.count += 1 }
    return Harness(snoozes: snoozes, alarm: alarm, store: store, moment: moment, wakes: wakes)
}

func registerSnoozeWakeTests(_ runner: TestRunner) {
    runner.suite("Snoozes: the wake-up (snooze-wake)") { r in
        r.run("nothing Snoozed schedules nothing") {
            let h = await makeHarness()
            let pending = await h.alarm.pending
            try expect(pending == nil)
        }

        r.run("a snooze schedules its end, and an earlier one replaces it") {
            let h = await makeHarness()
            try await MainActor.run {
                h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(7200))
                try expect(h.alarm.pending == start.addingTimeInterval(7200))
                h.snoozes.snooze(signal("b"), until: start.addingTimeInterval(3600))
                try expect(h.alarm.pending == start.addingTimeInterval(3600))
            }
        }

        r.run("the earliest ending says so and moves the alarm to the next") {
            let h = await makeHarness()
            await MainActor.run {
                h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(7200))
                h.snoozes.snooze(signal("b"), until: start.addingTimeInterval(3600))
            }
            h.moment.date = start.addingTimeInterval(3600)
            await h.alarm.fire()
            try expect(h.wakes.count == 1)
            let next = await h.alarm.pending
            try expect(next == start.addingTimeInterval(7200), "got \(String(describing: next))")
        }

        r.run("the last one ending cancels the alarm") {
            let h = await makeHarness()
            await MainActor.run { h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(3600)) }
            h.moment.date = start.addingTimeInterval(3600)
            await h.alarm.fire()
            try expect(h.wakes.count == 1)
            let pending = await h.alarm.pending
            try expect(pending == nil)
        }

        r.run("Unsnooze reschedules to the next, or cancels") {
            let h = await makeHarness()
            try await MainActor.run {
                h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(7200))
                h.snoozes.snooze(signal("b"), until: start.addingTimeInterval(3600))
                h.snoozes.end(signalId: "b")
                try expect(h.alarm.pending == start.addingTimeInterval(7200))
                h.snoozes.end(signalId: "a")
                try expect(h.alarm.pending == nil)
            }
        }

        r.run("a check-off found by a Reminders fetch reschedules") {
            let h = await makeHarness()
            try await MainActor.run {
                h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(7200))
                h.snoozes.snooze(signal("b"), until: start.addingTimeInterval(3600))
                h.snoozes.remindersFetched(
                    open: [reminder("a")], checkedOff: [CheckedOffReminder(task: reminder("b"), checkedOffAt: start)]
                )
                try expect(h.alarm.pending == start.addingTimeInterval(7200))
            }
        }

        r.run("at launch, the next snooze end still to come is scheduled, not one already past") {
            let store = makeTestSignalStore()
            try store.snooze(signalId: "past", until: start.addingTimeInterval(-60), dueAt: nil)
            try store.snooze(signalId: "next", until: start.addingTimeInterval(600), dueAt: nil)
            let h = await makeHarness(store: store)
            let pending = await h.alarm.pending
            try expect(pending == start.addingTimeInterval(600), "got \(String(describing: pending))")
        }
    }

    runner.suite("Snoozes: putting a snooze back") { r in
        r.run("a snooze returns the end it replaced, and set puts it back in one call") {
            let h = await makeHarness()
            try await MainActor.run {
                let earlier = start.addingTimeInterval(3600)
                try expect(h.snoozes.snooze(signal("a"), until: earlier) == nil)
                let replaced = h.snoozes.snooze(signal("a"), until: start.addingTimeInterval(86_400))
                try expect(replaced == earlier)
                h.snoozes.set(signal("a"), until: replaced)
                try expect(h.snoozes.until(signalId: "a") == earlier)
                try expect(h.alarm.pending == earlier)
                h.snoozes.set(signal("a"), until: nil)
                try expect(h.snoozes.until(signalId: "a") == nil)
                try expect(h.alarm.pending == nil)
            }
        }
    }
}
