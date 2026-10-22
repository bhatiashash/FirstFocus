import DailyOSCore
import Foundation

// Every way a snooze ends (CONTEXT.md: Snoozed), driven through the Signal
// Board and its Snoozes module, with check-offs made in FakeTaskSource
// directly, the way one made on a phone reaches DailyOS.

private let today = Calendar.current.startOfDay(for: Date())
private let later = Date().addingTimeInterval(6 * 3600)

private func reminder(_ id: String, dueAt: Date? = nil, recurring: Bool = false) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: dueAt, priority: .none, createdAt: Date(), isRecurring: recurring)
}

@MainActor
private func makeBoard(_ tasks: [ReminderTask], store: SQLiteSignalStore = makeTestSignalStore())
    -> (SignalBoard, FakeTaskSource, SQLiteSignalStore)
{
    let taskSource = FakeTaskSource(tasks: tasks)
    return (SignalBoard(taskSource: taskSource, signalStore: store), taskSource, store)
}

/// Snoozes `id` as the row's Snooze action would, with the Signal the
/// Board holds for it.
@MainActor
private func snooze(_ id: String, on board: SignalBoard) throws {
    let list = board.rankedList(now: Date())
    let signal = try require((list.focus + list.later).first { $0.id == id })
    board.snoozes.snooze(signal, until: later)
}

func registerSnoozeLifecycleTests(_ runner: TestRunner) {
    runner.suite("Snooze: a check-off made anywhere ends it") { r in
        r.run("a reminder checked off on another device loses its snooze at the next fetch") {
            let (board, taskSource, _) = await MainActor.run { makeBoard([reminder("a")]) }
            await board.refreshReminders()
            try await MainActor.run { try snooze("a", on: board) }
            try taskSource.complete(id: "a")
            await board.refreshReminders()
            try await MainActor.run { try expect(board.snoozes.until(signalId: "a") == nil) }
        }

        r.run("a repeating reminder checked off elsewhere loses its snooze, so its next occurrence shows") {
            let (board, taskSource, _) = await MainActor.run { makeBoard([reminder("a", dueAt: today, recurring: true)]) }
            await board.refreshReminders()
            try await MainActor.run { try snooze("a", on: board) }
            try taskSource.complete(id: "a")
            await board.refreshReminders()
            try await MainActor.run {
                try expect(board.snoozes.until(signalId: "a") == nil)
                let list = board.rankedList(now: Date())
                try expect((list.focus + list.later).contains { $0.id == "a" }, "the next occurrence is back on the list")
            }
        }

        r.run("a repeating reminder checked off while DailyOS was closed loses its snooze on the next launch") {
            let store = makeTestSignalStore()
            let (first, taskSource, _) = await MainActor.run { makeBoard([reminder("a", dueAt: today, recurring: true)], store: store) }
            await first.refreshReminders()
            try await MainActor.run { try snooze("a", on: first) }
            try taskSource.complete(id: "a")
            let relaunched = await MainActor.run { SignalBoard(taskSource: taskSource, signalStore: store) }
            await relaunched.refreshReminders()
            try await MainActor.run { try expect(relaunched.snoozes.until(signalId: "a") == nil) }
        }

        r.run("a repeating reminder whose due date hasn't moved stays Snoozed") {
            let (board, taskSource, _) = await MainActor.run { makeBoard([reminder("a", dueAt: today, recurring: true)]) }
            await board.refreshReminders()
            try await MainActor.run { try snooze("a", on: board) }
            try taskSource.update(id: "a", .title("a renamed"))
            await board.refreshReminders()
            try await MainActor.run { try expect(board.snoozes.until(signalId: "a") != nil) }
        }

        r.run("unchecking a reminder in Checked Off brings it back with no snooze") {
            let (board, taskSource, store) = await MainActor.run { makeBoard([reminder("a")]) }
            await board.refreshReminders()
            try taskSource.complete(id: "a")
            await board.refreshReminders()
            // A snooze written after the check-off was seen, which nothing
            // else would end.
            try store.snooze(signalId: "a", until: later)
            let done = try await MainActor.run { try require(board.checkedOff(now: Date()).first) }
            await board.uncheck(done)
            try await MainActor.run {
                try expect(board.snoozes.until(signalId: "a") == nil)
                try expect(board.rankedList(now: Date()).later.map(\.id) == ["a"])
            }
        }
    }
}
