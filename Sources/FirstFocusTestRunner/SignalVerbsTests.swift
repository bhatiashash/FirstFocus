import FirstFocusCore
import Foundation

// signal-verbs: every verb and its Undo, driven through `SignalVerbs`
// against `FakeTaskSource`, a test SQLite store and a fake Undo alarm.
// No AppModel and no sleeps.

private func reminder(_ id: String, title: String? = nil, priority: Priority = .none) -> ReminderTask {
    ReminderTask(id: id, title: title ?? id, dueAt: nil, priority: priority, createdAt: Date())
}

private func suggestion(_ id: String, sourceRef: String = "m1", label: String = "Buy milk") -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label, createdAt: Date(),
        provenance: .inferred
    )
}

@MainActor
private final class Recorder {
    var marked: [String] = []
    var undone: [String] = []
    var offersNotForMe = true
}

private struct Harness: @unchecked Sendable {
    let verbs: SignalVerbs
    let board: SignalBoard
    let snoozes: Snoozes
    let taskSource: FakeTaskSource
    let store: SQLiteSignalStore
    let clock: FakeAlarm
    let recorder: Recorder
}

/// `now` is fixed so a snooze's end is known.
private let now = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
private func makeHarness(_ tasks: [ReminderTask] = [], suggestions: [Signal] = []) throws -> Harness {
    let taskSource = FakeTaskSource(tasks: tasks)
    let store = makeTestSignalStore()
    if !suggestions.isEmpty { try store.recordOneMessageBatch("m1", signals: suggestions) }
    let snoozes = Snoozes(store: store, now: { now })
    let board = SignalBoard(taskSource: taskSource, signalStore: store, now: { now }, snoozes: snoozes)
    let clock = FakeAlarm()
    let verbs = SignalVerbs(
        board: board, snoozes: snoozes, taskSource: taskSource, signalStore: store, undoAlarm: clock, undoWindow: 5, now: { now }
    )
    let recorder = Recorder()
    verbs.notForMe = SignalVerbs.NotForMe(
        mark: { signal in
            guard recorder.offersNotForMe else { return nil }
            recorder.marked.append(signal.id)
            return { recorder.undone.append(signal.id) }
        }
    )
    board.loadStoredMessages()
    return Harness(verbs: verbs, board: board, snoozes: snoozes, taskSource: taskSource, store: store, clock: clock, recorder: recorder)
}

/// The Undo bar's window running out.
private func afterTimers(_ h: Harness) async {
    await h.clock.fire()
}

@MainActor
private func list(_ h: Harness) -> RankedList {
    h.board.rankedList(now: now, hiding: h.verbs.hiddenIDs)
}

func registerSignalVerbsTests(_ runner: TestRunner) {
    runner.suite("SignalVerbs: check off and its Undo") { r in
        r.run("check off hides the row; Undo brings it back and writes nothing") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            try await MainActor.run {
                h.verbs.checkOff(list(h).later[0])
                try expect(h.verbs.hiddenIDs == ["r1"])
                try expect(h.verbs.currentOffer?.action == .checkedOff)
            }
            let broughtBack = await h.verbs.undo()
            await afterTimers(h)
            await h.verbs.settled()
            try await MainActor.run {
                try expect(broughtBack == nil, "a check-off isn't a Suggestion to focus")
                try expect(h.verbs.hiddenIDs.isEmpty)
                try expect(list(h).later.map(\.id) == ["r1"])
                try expect(h.taskSource.completedIds.isEmpty)
            }
        }

        r.run("its window running out writes it and ends its snooze") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            await MainActor.run {
                let row = list(h).later[0]
                h.verbs.snooze(row, until: now.addingTimeInterval(3600))
                h.verbs.checkOff(row)
            }
            await afterTimers(h)
            await h.verbs.settled()
            try await MainActor.run {
                try expect(h.taskSource.completedIds == ["r1"])
                try expect(h.snoozes.until(signalId: "r1") == nil, "ADR 0045")
                try expect(h.verbs.hiddenIDs.isEmpty)
                try expect(h.verbs.currentOffer == nil)
            }
        }

        r.run("an undone check-off keeps its snooze") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            let until = now.addingTimeInterval(3600)
            await MainActor.run {
                let row = list(h).later[0]
                h.verbs.snooze(row, until: until)
                h.verbs.checkOff(row)
            }
            _ = await h.verbs.undo()
            await afterTimers(h)
            try await MainActor.run { try expect(h.snoozes.until(signalId: "r1") == until) }
        }

        r.run("a new offer writes a held-back check-off first") {
            let h = try await MainActor.run { try makeHarness([reminder("r1"), reminder("r2")]) }
            await h.board.refreshReminders()
            await MainActor.run {
                let rows = list(h).later
                h.verbs.checkOff(rows.first { $0.id == "r1" }!)
                h.verbs.snooze(rows.first { $0.id == "r2" }!, .tomorrow)
            }
            await h.verbs.settled()
            try expect(h.taskSource.completedIds == ["r1"])
        }

        r.run("quitting writes a held-back check-off before it returns") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            try await MainActor.run {
                h.verbs.checkOff(list(h).later[0])
                h.verbs.prepareToQuit()
                try expect(h.taskSource.completedIds == ["r1"])
            }
        }
    }

    runner.suite("SignalVerbs: Suggestions and their Undo") { r in
        r.run("Dismiss then Undo brings the Suggestion back and names it") {
            let h = try await MainActor.run { try makeHarness(suggestions: [suggestion("s1")]) }
            try await MainActor.run {
                h.verbs.dismiss(list(h).suggested[0])
                try expect(list(h).suggested.isEmpty)
                try expect(h.verbs.currentOffer?.action == .dismissed)
            }
            let broughtBack = await h.verbs.undo()
            try await MainActor.run {
                try expect(broughtBack == "s1")
                try expect(list(h).suggested.map(\.id) == ["s1"])
            }
        }

        r.run("Approve then Undo deletes the reminder and brings the Suggestion back") {
            let h = try await MainActor.run { try makeHarness(suggestions: [suggestion("s1")]) }
            let signal = await MainActor.run { list(h).suggested[0] }
            let reminderId = await h.verbs.approve(signal)
            try await MainActor.run {
                try expect(reminderId != nil)
                try expect(h.verbs.currentOffer?.action == .approved(.later))
                try expect(h.taskSource.tasks.count == 1)
            }
            let broughtBack = await h.verbs.undo()
            try await MainActor.run {
                try expect(broughtBack == "s1")
                try expect(h.taskSource.tasks.isEmpty)
                try expect(list(h).suggested.map(\.id) == ["s1"])
            }
        }

        r.run("Approve and Snooze then Undo deletes the reminder and ends its snooze") {
            let h = try await MainActor.run { try makeHarness(suggestions: [suggestion("s1")]) }
            let signal = await MainActor.run { list(h).suggested[0] }
            let reminderId = try require(await h.verbs.approve(signal, snoozing: .tomorrow))
            try await MainActor.run {
                try expect(h.snoozes.until(signalId: reminderId) != nil)
                try expect(list(h).focus.isEmpty && list(h).later.isEmpty, "it never shows in Focus or Later")
            }
            _ = await h.verbs.undo()
            try await MainActor.run {
                try expect(h.snoozes.until(signalId: reminderId) == nil)
                try expect(h.taskSource.tasks.isEmpty)
                try expect(list(h).suggested.map(\.id) == ["s1"])
            }
        }

        r.run("Not for me goes through History's closures, and Undo through its undo") {
            let h = try await MainActor.run { try makeHarness(suggestions: [suggestion("s1")]) }
            try await MainActor.run {
                h.verbs.notForMe(list(h).suggested[0])
                try expect(h.recorder.marked == ["s1"])
                try expect(h.verbs.currentOffer?.action == .notForMe)
            }
            let broughtBack = await h.verbs.undo()
            try await MainActor.run {
                try expect(broughtBack == "s1")
                try expect(h.recorder.undone == ["s1"])
            }
        }

        r.run("Not for me where History doesn't offer it shows no bar") {
            let h = try await MainActor.run { try makeHarness(suggestions: [suggestion("s1")]) }
            try await MainActor.run {
                h.recorder.offersNotForMe = false
                h.verbs.notForMe(list(h).suggested[0])
                try expect(h.verbs.currentOffer == nil)
            }
        }
    }

    runner.suite("SignalVerbs: snoozes and their Undo") { r in
        r.run("Undo of a snooze leaves no snooze") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            await MainActor.run { h.verbs.snooze(list(h).later[0], .tomorrow) }
            let broughtBack = await h.verbs.undo()
            try await MainActor.run {
                try expect(broughtBack == nil)
                try expect(h.snoozes.until(signalId: "r1") == nil)
            }
        }

        r.run("Undo of a re-snooze puts back the earlier return") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            let earlier = now.addingTimeInterval(7200)
            await MainActor.run {
                let row = list(h).later[0]
                h.verbs.snooze(row, until: earlier)
                h.verbs.snooze(row, .nextWeek)
            }
            _ = await h.verbs.undo()
            try await MainActor.run { try expect(h.snoozes.until(signalId: "r1") == earlier) }
        }

        r.run("Undo with nothing showing does nothing") {
            let h = try await MainActor.run { try makeHarness() }
            let broughtBack = await h.verbs.undo()
            try expect(broughtBack == nil)
        }
    }

    runner.suite("SignalVerbs: reminders") { r in
        r.run("a reminder being deleted is hidden until the write lands") {
            let h = try await MainActor.run { try makeHarness([reminder("r1")]) }
            await h.board.refreshReminders()
            final class Seen: @unchecked Sendable { var hidden: [Set<String>] = [] }
            let seen = Seen()
            let row = await MainActor.run {
                h.verbs.onChange = { seen.hidden.append(h.verbs.hiddenIDs) }
                return list(h).later[0]
            }
            await h.verbs.deleteTask(row)
            try await MainActor.run {
                try expect(seen.hidden.first == ["r1"], "got \(seen.hidden)")
                try expect(h.verbs.hiddenIDs.isEmpty)
                try expect(h.taskSource.tasks.isEmpty)
            }
        }

        r.run("a reminder added to Later is reported there") {
            let h = try await MainActor.run { try makeHarness() }
            let tier = await h.verbs.addReminder(title: "Call the bank", priority: .none)
            try await MainActor.run {
                try expect(tier == .later)
                try expect(h.verbs.currentOffer?.action == .addedToLater)
                try expect(h.verbs.currentOffer?.canUndo == false)
            }
        }

        r.run("a reminder added with a Priority lands in Focus with no report") {
            let h = try await MainActor.run { try makeHarness() }
            let tier = await h.verbs.addReminder(title: "Call the bank", priority: .high)
            try await MainActor.run {
                try expect(tier == .focus)
                try expect(h.verbs.currentOffer == nil)
            }
        }

        r.run("Quick Capture adds with no Priority and no report") {
            let h = try await MainActor.run { try makeHarness() }
            await h.verbs.createTask(title: "Call the bank")
            try await MainActor.run {
                try expect(list(h).later.map(\.label) == ["Call the bank"])
                try expect(h.verbs.currentOffer == nil)
            }
        }
    }
}
