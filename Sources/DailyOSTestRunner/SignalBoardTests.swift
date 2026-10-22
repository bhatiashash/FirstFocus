import DailyOSCore
import Foundation

private func reminderTask(
    id: String = "r1", title: String = "Call the dentist", priority: Priority = .none, dueAt: Date? = nil,
    createdAt: Date = Date()
) -> ReminderTask {
    ReminderTask(id: id, title: title, dueAt: dueAt, priority: priority, createdAt: createdAt)
}

private func messageSignal(
    id: String = "s1", sourceRef: String = "m1", label: String = "Buy milk", provenance: Provenance = .stated,
    state: SignalState = .open, createdAt: Date = Date()
) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label, createdAt: createdAt,
        provenance: provenance, state: state
    )
}

@MainActor
private func makeBoard(
    tasks: [ReminderTask] = [], reminderAvailability: SourceAvailability = .available,
    messages: [ChatMessage] = [], messagesAvailability: SourceAvailability = .available
) -> (board: SignalBoard, taskSource: FakeTaskSource, intake: MessagesIntake, store: SQLiteSignalStore) {
    let taskSource = FakeTaskSource(tasks: tasks, availability: reminderAvailability)
    let messagesSource = FakeMessagesSource(messages: messages, availability: messagesAvailability)
    let store = makeTestSignalStore()
    let intake = MessagesIntake(
        messagesSource: messagesSource, signalStore: store, contactsResolver: FakeContactsResolver(),
        bundlePath: "/nonexistent", extractor: FakeIntentExtractor()
    )
    let board = SignalBoard(taskSource: taskSource, signalStore: store)
    return (board, taskSource, intake, store)
}

func registerSignalBoardTests(_ runner: TestRunner) {
    runner.suite("SignalBoard: refresh replaces exactly one Source's share") { r in
        r.run("refreshing Reminders never touches Messages, and vice versa") {
            let now = Date()
            let (board, _, _, store) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal()])
            }
            await board.refreshReminders()
            try await MainActor.run {
                let list = board.rankedList(now: now)
                try expect(list.later.map(\.label) == ["Call the dentist"], "Reminders should be present after its own refresh")
                try expect(!list.later.contains { $0.label == "Buy milk" }, "Messages should be untouched until its own refresh runs")
            }
        }

        r.run("a denied Reminders Gate empties only the Reminders share") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask()], reminderAvailability: .unavailable) }
            await board.refreshReminders()
            let availability = await MainActor.run { board.availability(of: .reminders) }
            try await MainActor.run {
                try expect(availability == .unavailable)
                try expect(taskSource.listCallCount == 0, "a denied Gate should short-circuit before the fetch")
                try expect(board.rankedList(now: now).later.isEmpty)
            }
        }
    }

    runner.suite("SignalBoard: the Snoozed Section (ADR 0045)") { r in
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        r.run("a Snoozed Signal is listed under snoozed and in neither Tier") {
            let (board, _, _, _) = await MainActor.run {
                makeBoard(tasks: [reminderTask(id: "r1", title: "Pay rent", priority: .high), reminderTask(id: "r2", title: "Book flights")])
            }
            await board.refreshReminders()
            try await MainActor.run {
                let row = try require(board.rankedList(now: now).focus.first { $0.id == "r1" })
                board.snooze(row, until: now.addingTimeInterval(3600))
                let list = board.rankedList(now: now)
                try expect(list.snoozed.map(\.id) == ["r1"])
                try expect(!list.focus.contains { $0.id == "r1" } && !list.later.contains { $0.id == "r1" })
                try expect(list.snoozed[0].snoozedUntil == now.addingTimeInterval(3600), "the row carries its return time")
            }
        }

        r.run("snoozed is ordered soonest to return first") {
            let (board, _, _, _) = await MainActor.run {
                makeBoard(tasks: [reminderTask(id: "r1", title: "A"), reminderTask(id: "r2", title: "B"), reminderTask(id: "r3", title: "C")])
            }
            await board.refreshReminders()
            try await MainActor.run {
                let later = board.rankedList(now: now).later
                let byId = Dictionary(uniqueKeysWithValues: later.map { ($0.id, $0) })
                board.snooze(byId["r1"]!, until: now.addingTimeInterval(3 * 3600))
                board.snooze(byId["r2"]!, until: now.addingTimeInterval(1 * 3600))
                board.snooze(byId["r3"]!, until: now.addingTimeInterval(2 * 3600))
                try expect(board.rankedList(now: now).snoozed.map(\.id) == ["r2", "r3", "r1"])
            }
        }

        r.run("once the snooze ends the Signal leaves snoozed and is back in its Tier") {
            let (board, _, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask(id: "r1")]) }
            await board.refreshReminders()
            try await MainActor.run {
                board.snooze(board.rankedList(now: now).later[0], until: now.addingTimeInterval(3600))
                let later = board.rankedList(now: now.addingTimeInterval(3601))
                try expect(later.snoozed.isEmpty)
                try expect(later.later.map(\.id) == ["r1"])
            }
        }

        r.run("Snoozed Signals don't use up the Later cap") {
            let tasks = (0..<(maxRankedSignals + 3)).map { reminderTask(id: "r\($0)", title: "Task \($0)") }
            let (board, _, _, _) = await MainActor.run { makeBoard(tasks: tasks) }
            await board.refreshReminders()
            try await MainActor.run {
                for row in board.rankedList(now: now).later.prefix(3) {
                    board.snooze(row, until: now.addingTimeInterval(3600))
                }
                let list = board.rankedList(now: now)
                try expect(list.later.count == maxRankedSignals, "got \(list.later.count)")
                try expect(list.snoozed.count == 3)
            }
        }

        r.run("unsnooze puts the Signal straight back in its Tier") {
            let (board, _, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask(id: "r1")]) }
            await board.refreshReminders()
            try await MainActor.run {
                board.snooze(board.rankedList(now: now).later[0], until: now.addingTimeInterval(3600))
                board.unsnooze(signalId: "r1")
                let list = board.rankedList(now: now)
                try expect(list.snoozed.isEmpty)
                try expect(list.later.map(\.id) == ["r1"])
            }
        }

        r.run("a Suggestion is never listed under snoozed") {
            let (board, _, intake, store) = await MainActor.run { makeBoard() }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk", provenance: .inferred)])
                try store.snooze(signalId: "s1", until: now.addingTimeInterval(3600))
            }
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                let list = board.rankedList(now: now)
                try expect(list.snoozed.isEmpty)
                try expect(list.suggested.map(\.id) == ["s1"])
            }
        }
    }

    runner.suite("SignalBoard: hydration is read fresh, never patched") { r in
        r.run("snooze excludes a Signal from the very next read with no array patch") {
            let now = Date()
            let (board, _, intake, store) = await MainActor.run { makeBoard() }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk")])
            }
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                try expect(board.rankedList(now: now).later.map(\.label) == ["Buy milk"])
                board.snooze(board.rankedList(now: now).later[0], until: now.addingTimeInterval(3600))
                try expect(board.rankedList(now: now).later.isEmpty, "a snoozed Signal should disappear on the next read alone")
            }
        }

        r.run("manual Focus order is read fresh after reorderFocus, with no array patch") {
            let now = Date()
            let (board, _, _, _) = await MainActor.run {
                makeBoard(tasks: [
                    // Explicit times: two `Date()` calls a few nanoseconds
                    // apart can compare equal, leaving recency a tie.
                    reminderTask(id: "r1", title: "Older", priority: .high, createdAt: now.addingTimeInterval(-120)),
                    reminderTask(id: "r2", title: "Newer", priority: .high, createdAt: now.addingTimeInterval(-60)),
                ])
            }
            await board.refreshReminders()
            try await MainActor.run {
                let before = board.rankedList(now: now).focus.map(\.label)
                try expect(before == ["Newer", "Older"], "neither has been manually placed, so recency alone should decide")

                board.reorderFocus(draggedId: "r1", droppedOnId: "r2", currentFocusIds: ["r2", "r1"])
                let after = board.rankedList(now: now).focus.map(\.label)
                try expect(after == ["Older", "Newer"], "the dragged Signal should sort first on the very next read")
            }
        }
    }

    runner.suite("SignalBoard: hiding excludes before dedup, tiering or the cap") { r in
        r.run("a hidden id never appears in any tier or the Suggested Tasks Inbox") {
            let now = Date()
            let (board, _, intake, store) = await MainActor.run { makeBoard(tasks: [reminderTask(priority: .high)]) }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(provenance: .inferred)])
            }
            await board.refreshReminders()
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                let full = board.rankedList(now: now)
                try expect(full.focus.count == 1 && full.suggested.count == 1)

                let hidden = board.rankedList(now: now, hiding: [full.focus[0].id, full.suggested[0].id])
                try expect(hidden.focus.isEmpty)
                try expect(hidden.suggested.isEmpty)
            }
        }
    }

    runner.suite("SignalBoard: Sender-on-approval stays Reminders-only") { r in
        r.run("a Messages Signal's resolved Sender survives hydration untouched") {
            let now = Date()
            let (board, _, intake, store) = await MainActor.run { makeBoard() }
            let withSender = Signal(
                id: "s1", source: .messages, sourceRef: "m1", label: "Call back", originalText: "call back",
                createdAt: Date(), provenance: .stated, sender: "Alex Rivera"
            )
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [withSender])
            }
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                let list = board.rankedList(now: now)
                try expect(
                    list.later.first?.sender == "Alex Rivera",
                    "hydration must never overwrite a resolved Messages Sender with a reminderId lookup miss"
                )
            }
        }
    }

    runner.suite("SignalBoard: promote and demote branch on Source") { r in
        r.run("promoting a Messages Signal writes locally and needs no Reminders round trip") {
            let now = Date()
            let (board, taskSource, intake, store) = await MainActor.run { makeBoard() }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal()])
            }
            await board.apply(messages: await intake.refresh(now: now))
            let signal = await MainActor.run { board.rankedList(now: now).later[0] }

            await board.promote(signal)

            try await MainActor.run {
                try expect(taskSource.listCallCount == 0, "a Messages promotion should never touch Reminders")
                try expect(board.rankedList(now: now).focus.map(\.label) == ["Buy milk"])
            }
        }

        r.run("promoting a Reminders Signal writes through and re-fetches") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: now).later[0] }

            await board.promote(signal)

            try await MainActor.run {
                try expect(taskSource.tasks.first?.priority == .high)
                try expect(board.rankedList(now: now).focus.map(\.label) == ["Call the dentist"])
            }
        }
    }

    runner.suite("SignalBoard: dismiss, demote, and the Reminders write-through verbs") { r in
        r.run("dismiss removes a Messages Signal locally and is a no-op for a Reminders Signal") {
            let now = Date()
            let (board, _, intake, store) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk")])
            }
            await board.refreshReminders()
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                let messagesSignal = board.rankedList(now: now).later.first { $0.label == "Buy milk" }!
                let remindersSignal = board.rankedList(now: now).later.first { $0.label == "Call the dentist" }!

                board.dismiss(remindersSignal)
                try expect(
                    board.rankedList(now: now).later.contains { $0.label == "Call the dentist" },
                    "Dismiss only ever means \"Extraction produced a false positive\" — a Reminders Signal never went through Extraction"
                )

                board.dismiss(messagesSignal)
                try expect(!board.rankedList(now: now).later.contains { $0.label == "Buy milk" })
                try expect(!store.openSignals().contains { $0.id == messagesSignal.id }, "the store's own record is no longer open")
                try expect(
                    store.reExtractionCandidates().contains(messagesSignal.sourceRef),
                    "a dismissed Signal leaves its Batch open to re-extraction, unlike a checked-off one"
                )
            }
        }

        r.run("demoting a Messages Signal writes locally; demoting a Reminders Signal writes through and re-fetches") {
            let now = Date()
            let (board, taskSource, intake, store) = await MainActor.run {
                makeBoard(tasks: [reminderTask(priority: .high)])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk")])
            }
            await board.refreshReminders()
            await board.apply(messages: await intake.refresh(now: now))
            try await MainActor.run {
                try store.promote(signalId: store.openSignals().first!.id)
            }
            await board.apply(messages: await intake.refresh(now: now))

            let (remindersSignal, messagesSignal, fetchesBeforeDemote) = await MainActor.run {
                (
                    board.rankedList(now: now).focus.first { $0.label == "Call the dentist" }!,
                    board.rankedList(now: now).focus.first { $0.label == "Buy milk" }!,
                    taskSource.listCallCount
                )
            }

            await board.demote(messagesSignal)
            try await MainActor.run {
                try expect(
                    taskSource.listCallCount == fetchesBeforeDemote,
                    "demoting a Messages Signal should never touch Reminders"
                )
                try expect(!board.rankedList(now: now).focus.contains { $0.label == "Buy milk" })
            }

            await board.demote(remindersSignal)
            try await MainActor.run {
                // `taskSource.tasks.first?.priority == .none` would silently
                // compare against Optional.none (nil) rather than the
                // Priority.none case, since Priority has its own `.none`
                // case — unwrap first so `.none` unambiguously means the
                // enum case.
                let priority = try require(taskSource.tasks.first?.priority)
                try expect(priority == .none)
                try expect(!board.rankedList(now: now).focus.contains { $0.label == "Call the dentist" })
            }
        }

        r.run("createTask writes through and the new reminder appears on the next read") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard() }
            await board.createTask(title: "  Water the plants  ")
            try await MainActor.run {
                try expect(taskSource.tasks.map(\.title) == ["Water the plants"], "the title should be trimmed")
                let all = board.rankedList(now: now).focus + board.rankedList(now: now).later
                try expect(all.map(\.label) == ["Water the plants"])
            }
        }

        r.run("a task created in Focus carries a Priority, so it lands in Focus rather than Later") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard() }
            await board.createTask(title: "Call the bank", priority: .high)
            try await MainActor.run {
                try expect(taskSource.tasks.map(\.priority) == [.high])
                try expect(board.rankedList(now: now).focus.map(\.label) == ["Call the bank"])
            }
        }

        r.run("createTask with only whitespace never reaches the Source") {
            let (board, taskSource, _, _) = await MainActor.run { makeBoard() }
            await board.createTask(title: "   ")
            try await MainActor.run { try expect(taskSource.tasks.isEmpty) }
        }

        r.run("renameTask writes through for a Reminders Signal and is a no-op for a Messages Signal") {
            let now = Date()
            let (board, taskSource, intake, store) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk")])
            }
            await board.refreshReminders()
            await board.apply(messages: await intake.refresh(now: now))
            let (remindersSignal, messagesSignal) = await MainActor.run {
                (
                    board.rankedList(now: now).later.first { $0.label == "Call the dentist" }!,
                    board.rankedList(now: now).later.first { $0.label == "Buy milk" }!
                )
            }

            await board.renameTask(messagesSignal, to: "Buy eggs")
            try await MainActor.run {
                try expect(taskSource.tasks.first?.title == "Call the dentist", "a Messages Signal has no reminder to rename")
            }

            await board.renameTask(remindersSignal, to: "Call the vet")
            try await MainActor.run {
                try expect(taskSource.tasks.first?.title == "Call the vet")
            }
        }

        r.run("renaming with a date phrase saves the new title and the due date") {
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask(priority: .high)]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: Date()).focus[0] }
            let today = Calendar.current.startOfDay(for: Date())

            await board.renameTask(signal, to: "Get this done", dueAt: today)

            let read = try require(taskSource.tasks.first)
            try expect(read.title == "Get this done")
            try expect(read.dueAt == today)
            try expect(read.priority == .high)
        }

        r.run("renaming without a date phrase leaves the due date alone") {
            let dueAt = Date(timeIntervalSince1970: 2_000_000)
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask(dueAt: dueAt)]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: Date()).focus[0] }

            await board.renameTask(signal, to: "Call the vet")

            try expect(taskSource.tasks.first?.dueAt == dueAt)
        }

        r.run("renaming never writes back fields changed elsewhere since the last read") {
            let dueAt = Date(timeIntervalSince1970: 2_000_000)
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask(dueAt: dueAt)]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: Date()).focus[0] }
            // Changed on a phone; DailyOS hasn't re-read it yet.
            try taskSource.update(id: "r1", .priority(.high))

            await board.renameTask(signal, to: "Call the vet")

            let read = try require(taskSource.tasks.first)
            try expect(read.title == "Call the vet")
            try expect(read.priority == .high, "the rename wrote back the priority DailyOS read before the change")
            try expect(read.dueAt == dueAt)
        }

        r.run("promoting never writes back a title changed elsewhere since the last read") {
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: Date()).later[0] }
            try taskSource.update(id: "r1", .title("Call the dentist at 9"))

            await board.promote(signal)

            let read = try require(taskSource.tasks.first)
            try expect(read.priority == .high)
            try expect(read.title == "Call the dentist at 9", "the promote wrote back the title DailyOS read before the change")
        }

        r.run("a Reminders fetch that finishes after a later one leaves the later one's read") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            taskSource.afterReading = {
                entered.signal()
                release.wait()
            }
            let slow = Task { await board.refreshReminders() }
            waitOutsideAsync(entered)
            // The slow fetch has read "Call the dentist" and not returned.
            // The reminder is renamed and a second fetch runs to the end.
            taskSource.afterReading = nil
            try taskSource.update(id: "r1", .title("Call the vet"))
            await board.refreshReminders()
            release.signal()
            _ = await slow.value
            try await MainActor.run {
                try expect(
                    board.rankedList(now: now).later.map(\.label) == ["Call the vet"],
                    "the older fetch replaced the newer one's read"
                )
            }
        }

        r.run("deleteTask deletes the reminder and it is gone on the next read") {
            let now = Date()
            let (board, taskSource, _, _) = await MainActor.run { makeBoard(tasks: [reminderTask()]) }
            await board.refreshReminders()
            let signal = await MainActor.run { board.rankedList(now: now).later[0] }

            await board.deleteTask(signal)

            try await MainActor.run {
                try expect(taskSource.tasks.isEmpty)
                try expect(board.rankedList(now: now).later.isEmpty)
            }
        }
    }

    runner.suite("SignalBoard: approve turns a suggestion into a real reminder") { r in
        r.run("approving removes the Signal from Suggested and it reappears as a Reminders Signal") {
            let now = Date()
            let (board, _, intake, store) = await MainActor.run { makeBoard() }
            try await MainActor.run {
                try store.recordOneMessageBatch("m1", signals: [messageSignal(label: "Buy milk", provenance: .inferred)])
            }
            await board.apply(messages: await intake.refresh(now: now))
            let signal = await MainActor.run { board.rankedList(now: now).suggested[0] }

            await board.approve(signal)

            try await MainActor.run {
                let list = board.rankedList(now: now)
                try expect(list.suggested.isEmpty, "the approved Signal should leave the inbox immediately")
                try expect(
                    list.focus.contains { $0.label == "Buy milk" } || list.later.contains { $0.label == "Buy milk" },
                    "it should reappear as the new Reminders Signal the re-fetch picked up"
                )
            }
        }
    }
}

/// `DispatchSemaphore.wait()` can't be called from an async context.
private func waitOutsideAsync(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
