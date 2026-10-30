import FirstFocusCore
import Foundation

@MainActor
private func makeBoard(_ tasks: [ReminderTask]) -> (board: SignalBoard, taskSource: FakeTaskSource) {
    let taskSource = FakeTaskSource(tasks: tasks)
    let store = makeTestSignalStore()
    let board = SignalBoard(taskSource: taskSource, signalStore: store, snoozes: Snoozes(store: store))
    return (board, taskSource)
}

private func reminder(_ id: String, title: String = "Call the dentist", priority: Priority = .none) -> ReminderTask {
    ReminderTask(id: id, title: title, dueAt: nil, priority: priority, createdAt: Date())
}

func registerSignalBoardWriteTests(_ runner: TestRunner) {
    runner.suite("SignalBoard: a write to Reminders says whether it landed") { r in
        r.run("promote reports success and the Board shows the new Priority") {
            let (board, taskSource) = await MainActor.run { makeBoard([reminder("a")]) }
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).later.first) }
            let landed = await board.promote(signal)
            try expect(landed)
            try expect(taskSource.tasks.first?.priority == .high)
            try await MainActor.run { try expect(board.rankedList(now: Date()).focus.map(\.id) == ["a"]) }
        }

        r.run("promote reports failure when Reminders refuses the write, and the Board is unchanged") {
            let (board, taskSource) = await MainActor.run { makeBoard([reminder("a")]) }
            taskSource.failsUpdates = ["a"]
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).later.first) }
            let landed = await board.promote(signal)
            try expect(!landed)
            try await MainActor.run { try expect(board.rankedList(now: Date()).later.map(\.id) == ["a"]) }
        }

        r.run("demote and rename report failure the same way") {
            let (board, taskSource) = await MainActor.run { makeBoard([reminder("a", priority: .high)]) }
            taskSource.failsUpdates = ["a"]
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).focus.first) }
            let demoted = await board.demote(signal)
            let renamed = await board.renameTask(signal, to: "New title")
            try expect(!demoted && !renamed)
            try await MainActor.run { try expect(board.rankedList(now: Date()).focus.first?.label == "Call the dentist") }
        }

        r.run("rename reports success and the Board shows the new title") {
            let (board, _) = await MainActor.run { makeBoard([reminder("a")]) }
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).later.first) }
            let renamed = await board.renameTask(signal, to: "  Call the vet  ")
            try expect(renamed)
            try await MainActor.run { try expect(board.rankedList(now: Date()).later.first?.label == "Call the vet") }
        }

        r.run("deleting a reminder that is already gone reports failure and still refetches") {
            let (board, taskSource) = await MainActor.run { makeBoard([reminder("a"), reminder("b")]) }
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).later.first { $0.id == "a" }) }
            try taskSource.delete(id: "a")
            let deleted = await board.deleteTask(signal)
            try expect(!deleted)
            try await MainActor.run { try expect(board.rankedList(now: Date()).later.map(\.id) == ["b"], "the refetch dropped the gone row") }
        }

        r.run("a blank rename or a Messages Signal writes nothing and reports false") {
            let (board, taskSource) = await MainActor.run { makeBoard([reminder("a")]) }
            await board.refreshReminders()
            let signal = try await MainActor.run { try require(board.rankedList(now: Date()).later.first) }
            let renamed = await board.renameTask(signal, to: "   ")
            try expect(!renamed)
            try expect(taskSource.tasks.first?.title == "Call the dentist")
        }
    }
}
