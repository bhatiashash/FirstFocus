import FirstFocusApp
import FirstFocusCore
import Foundation

// Gestures on the Ranked List, driven through `AppModel`'s verbs: a drop,
// `+`, an Inbox key and a snooze, plus the screen and Sections it publishes.

/// "Now" as a box a test can move without anything re-deriving the list,
/// since gestures are judged against the moment the list was ranked.
private final class FakeNow: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private struct Harness: @unchecked Sendable {
    let model: AppModel
    let taskSource: FakeTaskSource
    let messagesSource: FakeMessagesSource
    let store: SQLiteSignalStore
    let clock: FakeNow
    let snoozeWakeAlarm: FakeAlarm
}

/// Takes a Source's Gate away or gives it back, then reads that Source the
/// way a refresh trigger would.
private func setGate(_ source: Source, _ availability: SourceAvailability, in h: Harness) async {
    switch source {
    case .reminders:
        h.taskSource.gateAvailability = availability
        await h.model.reload()
    case .messages:
        h.messagesSource.gateAvailability = availability
        await h.model.reloadMessages()
    }
}

/// `messageSignals` go into the store as one Batch each, keyed by their
/// `sourceRef`, so Signals sharing one land in the same Batch.
private func makeHarness(
    tasks: [ReminderTask] = [], messageSignals: [Signal] = [], zen: Bool = false, now: Date = Date()
) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
        let preference = ZenFocusModePreference(defaults: defaults)
        preference.isEnabled = zen
        let store = makeTestSignalStore()
        try? store.markBackfillComplete()
        var batches: [String: [Signal]] = [:]
        var order: [String] = []
        for signal in messageSignals {
            if batches[signal.sourceRef] == nil { order.append(signal.sourceRef) }
            batches[signal.sourceRef, default: []].append(signal)
        }
        for sourceRef in order {
            try? store.recordOneMessageBatch(sourceRef, signals: batches[sourceRef]!)
        }
        let taskSource = FakeTaskSource(tasks: tasks, availability: .available)
        let messagesSource = FakeMessagesSource(messages: [])
        let clock = FakeNow(now)
        let snoozeWakeAlarm = FakeAlarm()
        let model = AppModel(AppDependencies.test { d in
            d.taskSource = taskSource
            d.messagesSource = messagesSource
            d.signalStore = store
            d.contactsResolver = FakeContactsResolver()
            d.settingsOpener = FakeSettingsOpener()
            d.refreshClock = FakeRefreshClock()
            d.eventKitChanges = FakeEventKitChangeObserver()
            d.foregroundObserver = FakeForegroundObserver()
            d.dayChanges = FakeDayChangeObserver()
            d.zenFocusModePreference = preference
            d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
            d.undoAlarm = FakeAlarm()
            d.loadModel = { _, _ in FakeIntentExtractor() }
            d.historyStore = makeTestHistoryStore()
            d.correctionStore = FakeCorrectionStore()
            d.apiKeyStore = FakeAPIKeyStore()
            d.now = { clock.date }
            d.bundlePath = "/nonexistent"
            d.snoozeWakeAlarm = snoozeWakeAlarm
        })
        return Harness(
            model: model, taskSource: taskSource, messagesSource: messagesSource, store: store, clock: clock,
            snoozeWakeAlarm: snoozeWakeAlarm
        )
    }
}

private func task(id: String, priority: Priority = .none, dueAt: Date? = nil) -> ReminderTask {
    ReminderTask(id: id, title: id, dueAt: dueAt, priority: priority, createdAt: Date())
}

private func suggestion(id: String, sourceRef: String? = nil, lowConfidence: Bool = false) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef ?? "m-\(id)", label: id, originalText: id,
        createdAt: Date(), provenance: .inferred, lowConfidence: lowConfidence
    )
}

private func startOfDay(daysFromToday days: Int) -> Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date()))!
}

/// A pressed key's work runs in its own task.
private func settle() async {
    try? await Task.sleep(nanoseconds: 150_000_000)
}

func registerRankedListInteractionTests(_ runner: TestRunner) {
    runner.suite("AppModel: gestures are judged against the list's moment (ADR 0020, ADR 0042)") { r in
        // Just before midnight, a row with a Priority due the day after
        // tomorrow sits in Focus by its Priority alone, so it offers Move to
        // Later. One minute later the same date is tomorrow and would hold
        // it in Focus.
        let beforeMidnight = startOfDay(daysFromToday: 1).addingTimeInterval(-60)
        let afterMidnight = startOfDay(daysFromToday: 1).addingTimeInterval(60)
        let dueAt = startOfDay(daysFromToday: 2)

        r.run("row actions still match the list once the clock passes midnight") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high, dueAt: dueAt)], now: beforeMidnight)
            await h.model.start()
            h.clock.date = afterMidnight
            try await MainActor.run {
                let row = try require(h.model.rankedList.focus.first { $0.id == "r1" })
                try expect(h.model.presentation.affordances(for: row).contains(.demote), "the list was ranked before midnight")
            }
        }

        r.run("a drop into Later is judged against the list's moment, not the clock") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high, dueAt: dueAt)], now: beforeMidnight)
            await h.model.start()
            h.clock.date = afterMidnight
            await h.model.drop("r1", onto: .tier(.later))
            try expect(h.taskSource.tasks.first { $0.id == "r1" }?.priority == Priority.none, "the move the list showed as allowed happens")
        }

        r.run("the next list is ranked against the clock again") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high, dueAt: dueAt)], now: beforeMidnight)
            await h.model.start()
            h.clock.date = afterMidnight
            await h.model.reload()
            try await MainActor.run {
                let row = try require(h.model.rankedList.focus.first { $0.id == "r1" })
                try expect(!h.model.presentation.affordances(for: row).contains(.demote), "its date now holds it in Focus")
            }
        }
    }

    runner.suite("AppModel: dropping a row (ADR 0011)") { r in
        r.run("a Later row dropped onto the second Focus row gets a Priority and sits second") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high), task(id: "f2", priority: .high), task(id: "l1")])
            await h.model.start()
            let before = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(before.count == 2)
            await h.model.drop("l1", onto: .row(id: before[1]))
            let after = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(after == [before[0], "l1", before[1]], "got \(after)")
            try expect(h.taskSource.tasks.first { $0.id == "l1" }?.priority == .high)
        }

        r.run("a Later row dropped on the Focus header gets a Priority") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high), task(id: "l1")])
            await h.model.start()
            await h.model.drop("l1", onto: .tier(.focus))
            let focus = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(focus.contains("l1"))
            try expect(h.taskSource.tasks.first { $0.id == "l1" }?.priority == .high)
        }

        r.run("a Later row dropped on an empty Focus gets a Priority") {
            let h = await makeHarness(tasks: [task(id: "l1")])
            await h.model.start()
            try await MainActor.run {
                try expect(h.model.presentation.sections.map(\.id) == ["tier-focus", "tier-later"], "the empty Focus is drawn as a target")
            }
            await h.model.drop("l1", onto: .tier(.focus))
            let focus = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(focus == ["l1"])
        }

        r.run("a row due tomorrow dropped into Later stays in Focus") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high, dueAt: startOfDay(daysFromToday: 1)), task(id: "l1")])
            await h.model.start()
            await h.model.drop("r1", onto: .tier(.later))
            await h.model.drop("r1", onto: .row(id: "l1"))
            let focus = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(focus == ["r1"])
            try expect(h.taskSource.tasks.first { $0.id == "r1" }?.priority == .high, "clearing Priority wouldn't move it")
        }

        r.run("a Focus row held there only by its Priority moves to Later when dropped there") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high)])
            await h.model.start()
            await h.model.drop("r1", onto: .tier(.later))
            let later = await MainActor.run { h.model.rankedList.later.map(\.id) }
            try expect(later == ["r1"])
        }

        r.run("a Focus row with a Priority and a far-off due date moves to Later when dropped there (ADR 0042)") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high, dueAt: startOfDay(daysFromToday: 30))])
            await h.model.start()
            await h.model.drop("r1", onto: .tier(.later))
            let later = await MainActor.run { h.model.rankedList.later.map(\.id) }
            try expect(later == ["r1"])
        }

        r.run("a Focus row dropped onto another Focus row takes its place") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high), task(id: "f2", priority: .high)])
            await h.model.start()
            let before = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            await h.model.drop(before[1], onto: .row(id: before[0]))
            let after = await MainActor.run { h.model.rankedList.focus.map(\.id) }
            try expect(after == [before[1], before[0]])
        }

        r.run("Later has no manual order, so a Later row dropped in Later does nothing") {
            let h = await makeHarness(tasks: [task(id: "l1"), task(id: "l2")])
            await h.model.start()
            await h.model.drop("l1", onto: .row(id: "l2"))
            await h.model.drop("l1", onto: .tier(.later))
            try expect(h.taskSource.tasks.allSatisfy { $0.priority == .none })
        }
    }

    runner.suite("AppModel: `+` adds a reminder") { r in
        r.run("with Focus showing it adds with a Priority and lands in Focus") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)])
            await h.model.start()
            let tier = await h.model.addReminder(title: "Water the plants")
            try expect(tier == .focus)
            try expect(h.taskSource.tasks.first { $0.title == "Water the plants" }?.priority == .high)
            let reported = await MainActor.run { h.model.undoOffer }
            try expect(reported == nil)
        }

        r.run("with Focus hidden it adds to Later and reports Later") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run { try expect(!h.model.presentation.showsFocus) }
            let tier = await h.model.addReminder(title: "Water the plants")
            try expect(tier == .later)
            try expect(h.taskSource.tasks.first { $0.title == "Water the plants" }?.priority == Priority.none)
            let reported = await MainActor.run { h.model.undoOffer }
            try expect(reported?.action == .addedToLater && reported?.label == "Water the plants")
        }

        r.run("in Zen Focus Mode Focus is showing, so it adds with a Priority") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)], zen: true)
            await h.model.start()
            let tier = await h.model.addReminder(title: "Water the plants")
            try expect(tier == .focus)
        }

        r.run("a typed due date decides the Tier, whether or not Focus is showing") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)])
            await h.model.start()
            let later = await h.model.addReminder(title: "Renew passport", dueAt: startOfDay(daysFromToday: 21))
            try expect(later == .later)

            let empty = await makeHarness()
            await empty.model.start()
            let focus = await empty.model.addReminder(title: "Call dentist", dueAt: startOfDay(daysFromToday: 1))
            try expect(focus == .focus)
        }
    }

    runner.suite("AppModel: Inbox keys answer at once") { r in
        r.run("every key is ignored in Zen Focus Mode, which hides the Inbox") {
            let h = await makeHarness(messageSignals: [suggestion(id: "s1")], zen: true)
            await h.model.start()
            try await MainActor.run { try expect(h.model.pressInboxKey(.down) == false) }
        }

        r.run("a key taken is acted on") {
            let h = await makeHarness(messageSignals: [suggestion(id: "s1")])
            await h.model.start()
            try await MainActor.run { try expect(h.model.pressInboxKey(.down)) }
            await settle()
            try await MainActor.run { try expect(h.model.focusedSuggestionId == "s1") }
            try await MainActor.run { try expect(h.model.pressInboxKey(.dismiss)) }
            await settle()
            try expect(!h.store.openSignals().contains { $0.id == "s1" })
        }
    }

    runner.suite("AppModel: a Snoozed row (ADR 0045)") { r in
        r.run("offers Unsnooze, Rename and Delete, and no Move to Focus or drag") {
            let h = await makeHarness(tasks: [task(id: "r1")])
            await h.model.start()
            try await MainActor.run {
                h.model.snooze(h.model.rankedList.later[0], until: Date().addingTimeInterval(3600))
                let row = try require(h.model.rankedList.snoozed.first)
                try expect(h.model.presentation.affordances(for: row) == [.unsnooze, .rename, .delete], "got \(h.model.presentation.affordances(for: row).rawValue)")
            }
        }

        r.run("a Snoozed Messages row offers Unsnooze and Dismiss") {
            let stated = Signal(
                id: "m1", source: .messages, sourceRef: "msg-1", label: "Buy milk", originalText: "Buy milk",
                createdAt: Date(), provenance: .stated
            )
            let h = await makeHarness(messageSignals: [stated])
            await h.model.start()
            try await MainActor.run {
                let row = try require(h.model.rankedList.later.first { $0.id == "m1" })
                h.model.snooze(row, until: Date().addingTimeInterval(3600))
                let snoozed = try require(h.model.rankedList.snoozed.first)
                try expect(h.model.presentation.affordances(for: snoozed) == [.unsnooze, .dismiss])
            }
        }

        r.run("Unsnooze puts the row back in its Tier and offers no Undo") {
            let h = await makeHarness(tasks: [task(id: "r1")])
            await h.model.start()
            try await MainActor.run {
                h.model.snooze(h.model.rankedList.later[0], until: Date().addingTimeInterval(3600))
                h.model.unsnooze(try require(h.model.rankedList.snoozed.first))
                try expect(h.model.rankedList.snoozed.isEmpty)
                try expect(h.model.rankedList.later.map(\.id) == ["r1"])
                try expect(h.model.undoOffer == nil)
            }
            try expect(h.store.snoozedUntils(signalIds: ["r1"])["r1"] == nil)
        }
    }

    runner.suite("AppModel: a snooze ending derives the list again (ADR 0045)") { r in
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        r.run("a snooze schedules a wake-up for when it ends, and the wake-up brings the row back") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            await MainActor.run { h.model.snooze(h.model.rankedList.later[0], until: now.addingTimeInterval(3600)) }
            let pending = await h.snoozeWakeAlarm.pending
            try expect(pending == now.addingTimeInterval(3600), "got \(String(describing: pending))")
            h.clock.date = now.addingTimeInterval(3600)
            await h.snoozeWakeAlarm.fire()
            let later = await MainActor.run { h.model.rankedList.later.map(\.id) }
            try expect(later == ["r1"], "got \(later)")
        }
    }

    runner.suite("AppModel: Approve and Snooze from a Suggestion (ADR 0045)") { r in
        let friday = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 16))!
        let mondayMorning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 8))!

        r.run("makes the reminder, Snoozed, and never in Focus or Later") {
            let h = await makeHarness(messageSignals: [suggestion(id: "Call the dentist")], now: friday)
            await h.model.start()
            let row = try await MainActor.run { try require(h.model.rankedList.suggested.first) }
            await h.model.approve(row, snoozing: .nextWeek)
            let reminder = try require(h.taskSource.tasks.first { $0.title == "Call the dentist" })
            try await MainActor.run {
                let list = h.model.rankedList
                try expect(list.suggested.isEmpty)
                try expect(list.snoozed.map(\.id) == [reminder.id], "got \(list.snoozed.map(\.id))")
                try expect(!list.focus.contains { $0.id == reminder.id } && !list.later.contains { $0.id == reminder.id })
                try expect(
                    h.model.undoOffer?.text == "Added \u{201C}Call the dentist\u{201D}, snoozed until Mon 5 Oct",
                    "got \(String(describing: h.model.undoOffer))"
                )
            }
            try expect(h.store.snoozedUntils(signalIds: [reminder.id])[reminder.id] == mondayMorning)
        }
    }

    runner.suite("AppModel: Tomorrow and Next Week (ADR 0045)") { r in
        // A Friday at 4 PM, in whole seconds since the store keeps no finer.
        let friday = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 16))!
        let saturdayMorning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8))!

        r.run("Tomorrow snoozes until 8 AM the next day, judged by the injected clock") {
            let h = await makeHarness(tasks: [task(id: "r1", priority: .high)], now: friday)
            await h.model.start()
            try await MainActor.run {
                let row = try require(h.model.rankedList.focus.first { $0.id == "r1" })
                h.model.snooze(row, .tomorrow)
                try expect(!h.model.rankedList.focus.contains { $0.id == "r1" })
            }
            try expect(h.store.snoozedUntils(signalIds: ["r1"])["r1"] == saturdayMorning)
        }

        r.run("a snooze offers Undo naming the row and the day it returns") {
            let h = await makeHarness(tasks: [task(id: "Pay rent")], now: friday)
            await h.model.start()
            try await MainActor.run {
                let row = try require(h.model.rankedList.later.first { $0.id == "Pay rent" })
                h.model.snooze(row, .nextWeek)
                let offer = h.model.undoOffer
                try expect(offer?.text == "Snoozed \u{201C}Pay rent\u{201D} until Mon 5 Oct", "got \(String(describing: offer))")
                try expect(offer?.canUndo == true)
            }
        }
    }

    runner.suite("AppModel: the screen follows its flags") { r in
        r.run("an empty list still shows the list, not empty, when a Source is unavailable") {
            let h = await makeHarness()
            await h.model.start()
            await setGate(.messages, .unavailable, in: h)
            try await MainActor.run { try expect(h.model.presentation.screenMode == .list, "there's a Notice to show for the unreachable Source") }
            await setGate(.messages, .available, in: h)
            await setGate(.reminders, .unavailable, in: h)
            try await MainActor.run { try expect(h.model.presentation.screenMode == .list) }
            await setGate(.reminders, .available, in: h)
            try await MainActor.run {
                h.model.extraction.unload()
                try expect(h.model.presentation.screenMode == .list)
            }
        }

        r.run("turning Zen off shows the list") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)], zen: true)
            await h.model.start()
            try await MainActor.run {
                h.model.isZenFocusModeEnabled = false
                try expect(h.model.presentation.screenMode == .list)
            }
        }
    }

    runner.suite("AppModel: the Sections follow the list and its flags") { r in
        let everything = (
            tasks: [task(id: "f1", priority: .high), task(id: "l1")],
            messages: [suggestion(id: "s1")]
        )

        r.run("toggling Zen updates the Sections") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages)
            await h.model.start()
            try await MainActor.run {
                h.model.isZenFocusModeEnabled = true
                try expect(h.model.presentation.sections.map(\.id) == ["tier-focus"])
                h.model.isZenFocusModeEnabled = false
                try expect(h.model.presentation.sections.map(\.id) == ["suggested", "tier-focus", "tier-later"])
            }
        }

        r.run("a Gate a verb's refetch finds missing shows its Notice at once") {
            let h = await makeHarness(tasks: [task(id: "l1")])
            await h.model.start()
            h.taskSource.gateAvailability = .unavailable
            let row = try await MainActor.run { try require(h.model.rankedList.later.first) }
            await h.model.promote(row)
            try await MainActor.run {
                try expect(h.model.remindersUnavailable)
                try expect(h.model.presentation.sections.map(\.id) == ["notice-remindersUnavailable"], "got \(h.model.presentation.sections.map(\.id))")
            }
        }

        r.run("with only Snoozed rows the window shows them, not the empty screen") {
            let h = await makeHarness(tasks: [task(id: "z1")])
            await h.model.start()
            try await MainActor.run {
                h.model.snooze(h.model.rankedList.later[0], until: Date().addingTimeInterval(3600))
                try expect(h.model.presentation.screenMode == .list, "got \(h.model.presentation.screenMode)")
                try expect(h.model.presentation.sections.map(\.id) == ["snoozed"])
            }
        }

        r.run("extraction coming back removes its Notice") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run {
                h.model.extraction.unload()
                try expect(h.model.presentation.sections.map(\.id) == ["notice-extractionUnavailable"])
            }
            await h.model.retryLoadingExtractor()
            try await MainActor.run { try expect(h.model.presentation.sections.isEmpty) }
        }

        r.run("a Gate coming back removes its Notice") {
            let h = await makeHarness()
            await h.model.start()
            await setGate(.reminders, .unavailable, in: h)
            try await MainActor.run { try expect(h.model.presentation.sections.map(\.id) == ["notice-remindersUnavailable"]) }
            await setGate(.reminders, .available, in: h)
            try await MainActor.run { try expect(h.model.presentation.sections.isEmpty) }
        }
    }
}
