import DailyOSCore
import Foundation

private func testReminderSignal(id: String = "r1") -> Signal {
    Signal(
        id: id,
        source: .reminders,
        sourceRef: id,
        label: "Test",
        originalText: "Test",
        createdAt: Date(),
        provenance: .stated
    )
}

private func testMessagesSignal(id: String = "s1") -> Signal {
    Signal(
        id: id,
        source: .messages,
        sourceRef: "msg-\(id)",
        label: "Test",
        originalText: "test",
        createdAt: Date(),
        provenance: .inferred
    )
}

@MainActor
private func makeCoordinator(tasks: [ReminderTask] = []) -> (
    coordinator: CheckOffCoordinator, taskSource: FakeTaskSource, changeCount: Box<Int>
) {
    let taskSource = FakeTaskSource(tasks: tasks)
    let coordinator = CheckOffCoordinator(taskSource: taskSource, signalStore: makeTestSignalStore())
    let changeCount = Box(0)
    coordinator.onChange = { changeCount.value += 1 }
    return (coordinator, taskSource, changeCount)
}

/// A reference box so `onChange` closures above can count calls without
/// needing `@Sendable`-safe mutable capture gymnastics — every test drives
/// this synchronously on one thread.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func registerCheckOffCoordinatorTests(_ runner: TestRunner) {
    // The undo window in front of the write is the Undo bar's, tested in
    // UndoBarTests (undo-bar).
    runner.suite("CheckOffCoordinator: the write") { r in
        r.run("a commit hides the Signal while its write is in flight, and shows it again once it lands") {
            let (coordinator, taskSource, changeCount) = await MainActor.run { makeCoordinator(tasks: [
                ReminderTask(id: "r1", title: "Test", dueAt: nil, priority: .none, createdAt: Date()),
            ]) }
            try await MainActor.run {
                coordinator.commit(testReminderSignal(id: "r1"))
                try expect(coordinator.hiddenIDs == ["r1"], "still hidden while the write is in flight")
            }
            await coordinator.settled()
            try await MainActor.run {
                try expect(taskSource.completedIds == ["r1"])
                try expect(coordinator.hiddenIDs.isEmpty, "no longer hidden once the write has landed")
                try expect(changeCount.value == 2, "onChange fires when hiding starts and when it ends, got \(changeCount.value)")
            }
        }

        r.run("the Source is read again before the Signal stops being hidden") {
            let (coordinator, _, _) = await MainActor.run { makeCoordinator(tasks: [
                ReminderTask(id: "r1", title: "Test", dueAt: nil, priority: .none, createdAt: Date()),
            ]) }
            let hiddenDuringReread = await MainActor.run { () -> Box<Set<String>?> in
                let seen = Box<Set<String>?>(nil)
                coordinator.onCommitted = { seen.value = coordinator.hiddenIDs }
                coordinator.commit(testReminderSignal(id: "r1"))
                return seen
            }
            await coordinator.settled()
            try await MainActor.run { try expect(hiddenDuringReread.value == ["r1"], "got \(String(describing: hiddenDuringReread.value))") }
        }
    }

    runner.suite("writeCheckOff") { r in
        r.run("completes the reminder for a Reminders Signal, and never touches the store") {
            let fake = FakeTaskSource(tasks: [ReminderTask(id: "r1", title: "t", dueAt: nil, priority: .none, createdAt: Date())])
            let store = makeTestSignalStore()
            try writeCheckOff(testReminderSignal(id: "r1"), taskSource: fake, signalStore: store)
            try expect(fake.completedIds == ["r1"])
        }

        r.run("records the check-off in the store for a Messages Signal, and never writes to the TaskSource") {
            let fake = FakeTaskSource()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("msg-s1", signals: [testMessagesSignal(id: "s1")])
            try writeCheckOff(testMessagesSignal(id: "s1"), taskSource: fake, signalStore: store)
            try expect(store.openSignals().isEmpty, "the Messages Signal should no longer be open")
            try expect(fake.completedIds.isEmpty, "a Messages check-off must never write to the TaskSource")
        }
    }
}
