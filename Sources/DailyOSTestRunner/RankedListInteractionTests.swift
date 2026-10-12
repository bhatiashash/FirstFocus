import DailyOSApp
import DailyOSCore
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
    let store: SQLiteSignalStore
    let clock: FakeNow
    let snoozeWakeClock: FakeUndoClock
}

/// `messageSignals` go into the store as one Batch each, keyed by their
/// `sourceRef`, so Signals sharing one land in the same Batch.
private func makeHarness(
    tasks: [ReminderTask] = [], messageSignals: [Signal] = [], zen: Bool = false, now: Date = Date()
) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
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
        let clock = FakeNow(now)
        let snoozeWakeClock = FakeUndoClock()
        let model = AppModel(
            taskSource: taskSource,
            messagesSource: FakeMessagesSource(messages: []), signalStore: store,
            contactsResolver: FakeContactsResolver(), settingsOpener: FakeSettingsOpener(),
            refreshClock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
            foregroundObserver: FakeForegroundObserver(), dayChanges: FakeDayChangeObserver(),
            zenFocusModePreference: preference,
            reExtractionSettings: ReExtractionSettings(defaults: defaults),
            undoClock: FakeUndoClock(),
            extractor: FakeIntentExtractor(), historyStore: makeTestHistoryStore(), correctionStore: FakeCorrectionStore(),
            apiKeyStore: FakeAPIKeyStore(), now: { clock.date }, bundlePath: "/nonexistent",
            snoozeWakeClock: snoozeWakeClock
        )
        return Harness(model: model, taskSource: taskSource, store: store, clock: clock, snoozeWakeClock: snoozeWakeClock)
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
                try expect(h.model.affordances(for: row).contains(.demote), "the list was ranked before midnight")
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
                try expect(!h.model.affordances(for: row).contains(.demote), "its date now holds it in Focus")
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
                try expect(h.model.sections.map(\.id) == ["tier-focus", "tier-later"], "the empty Focus is drawn as a target")
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
            try await MainActor.run { try expect(!h.model.showsFocus) }
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
        r.run("Return, Delete and Space with nothing focused are ignored") {
            let h = await makeHarness(messageSignals: [suggestion(id: "s1")])
            await h.model.start()
            try await MainActor.run {
                try expect(h.model.pressInboxKey(.approve) == false)
                try expect(h.model.pressInboxKey(.dismiss) == false)
                try expect(h.model.pressInboxKey(.togglePreview) == false)
            }
            await settle()
            try expect(h.taskSource.tasks.isEmpty)
            try expect(h.store.openSignals().count == 1)
        }

        r.run("Escape with no popover open is ignored") {
            let h = await makeHarness(messageSignals: [suggestion(id: "s1")])
            await h.model.start()
            try await MainActor.run { try expect(h.model.pressInboxKey(.closePreview) == false) }
        }

        r.run("every key is ignored with an empty Inbox") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)])
            await h.model.start()
            try await MainActor.run {
                try expect(h.model.pressInboxKey(.down) == false)
                try expect(h.model.pressInboxKey(.up) == false)
            }
        }

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
                try expect(h.model.affordances(for: row) == [.unsnooze, .rename, .delete], "got \(h.model.affordances(for: row).rawValue)")
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
                try expect(h.model.affordances(for: snoozed) == [.unsnooze, .dismiss])
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

    runner.suite("AppModel: Snoozed rows come back on time (ADR 0045)") { r in
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        r.run("nothing Snoozed schedules no wake-up") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            try expect(h.snoozeWakeClock.scheduledInterval == nil)
        }

        r.run("a snooze schedules a wake-up for when it ends, and the wake-up brings the row back") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: now)
            await h.model.start()
            await MainActor.run { h.model.snooze(h.model.rankedList.later[0], until: now.addingTimeInterval(3600)) }
            try expect(h.snoozeWakeClock.scheduledInterval == 3600, "got \(String(describing: h.snoozeWakeClock.scheduledInterval))")
            h.clock.date = now.addingTimeInterval(3600)
            h.snoozeWakeClock.fire()
            await settle()
            let later = await MainActor.run { h.model.rankedList.later.map(\.id) }
            try expect(later == ["r1"], "got \(later)")
        }

        r.run("an earlier snooze replaces the scheduled wake-up, and the later one is scheduled after it") {
            let h = await makeHarness(tasks: [task(id: "a"), task(id: "b")], now: now)
            await h.model.start()
            try await MainActor.run {
                h.model.snooze(try require(h.model.rankedList.later.first { $0.id == "a" }), until: now.addingTimeInterval(7200))
                h.model.snooze(try require(h.model.rankedList.later.first { $0.id == "b" }), until: now.addingTimeInterval(3600))
            }
            try expect(h.snoozeWakeClock.scheduledInterval == 3600)
            h.clock.date = now.addingTimeInterval(3600)
            h.snoozeWakeClock.fire()
            await settle()
            let (later, snoozed) = await MainActor.run { (h.model.rankedList.later.map(\.id), h.model.rankedList.snoozed.map(\.id)) }
            try expect(later == ["b"], "got \(later)")
            try expect(snoozed == ["a"], "got \(snoozed)")
            try expect(h.snoozeWakeClock.scheduledInterval == 3600, "a's wake-up, an hour after b's")
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

        r.run("Undo deletes the reminder and puts the Suggestion back") {
            let h = await makeHarness(messageSignals: [suggestion(id: "Call the dentist")], now: friday)
            await h.model.start()
            let row = try await MainActor.run { try require(h.model.rankedList.suggested.first) }
            await h.model.approve(row, snoozing: .tomorrow)
            let reminderId = try require(h.taskSource.tasks.first { $0.title == "Call the dentist" }).id
            await h.model.undo()
            try expect(!h.taskSource.tasks.contains { $0.id == reminderId })
            try expect(h.store.snoozedUntils(signalIds: [reminderId])[reminderId] == nil)
            let (suggested, snoozed) = await MainActor.run { (h.model.rankedList.suggested.map(\.id), h.model.rankedList.snoozed) }
            try expect(suggested == ["Call the dentist"], "got \(suggested)")
            try expect(snoozed.isEmpty)
        }
    }

    runner.suite("AppModel: Tomorrow and Next Week (ADR 0045)") { r in
        // A Friday at 4 PM, in whole seconds since the store keeps no finer.
        let friday = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 16))!
        let saturdayMorning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8))!
        let mondayMorning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 8))!

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

        r.run("Undo of a snooze puts the row back with no snooze") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: friday)
            await h.model.start()
            await MainActor.run { h.model.snooze(h.model.rankedList.later[0], .tomorrow) }
            await h.model.undo()
            try expect(h.store.snoozedUntils(signalIds: ["r1"])["r1"] == nil)
            let back = await MainActor.run { h.model.rankedList.later.contains { $0.id == "r1" } }
            try expect(back)
        }

        r.run("Undo of a re-snooze puts back the earlier return time") {
            let h = await makeHarness(tasks: [task(id: "r1")], now: friday)
            await h.model.start()
            await MainActor.run { h.model.snooze(h.model.rankedList.later[0], .tomorrow) }
            await MainActor.run {
                let snoozed = Signal(
                    id: "r1", source: .reminders, sourceRef: "r1", label: "r1", originalText: "r1",
                    createdAt: friday, provenance: .stated, snoozedUntil: saturdayMorning
                )
                h.model.snooze(snoozed, .nextWeek)
            }
            try expect(h.store.snoozedUntils(signalIds: ["r1"])["r1"] == mondayMorning)
            await h.model.undo()
            try expect(h.store.snoozedUntils(signalIds: ["r1"])["r1"] == saturdayMorning)
        }
    }

    runner.suite("AppModel.screenMode: which of the five screens wins") { r in
        r.run("everything false, nil or empty shows empty") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run { try expect(h.model.screenMode == .empty) }
        }

        r.run("a non-empty list shows the list") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)])
            await h.model.start()
            try await MainActor.run { try expect(h.model.screenMode == .list) }
        }

        r.run("backfill beats everything else, including loading") {
            let h = await makeHarness()
            await MainActor.run {
                h.model.isLoading = true
                h.model.backfillProgress = (completed: 1, total: 10)
            }
            try await MainActor.run { try expect(h.model.screenMode == .backfill(completed: 1, total: 10)) }
        }

        r.run("loading beats empty and Zen") {
            let h = await makeHarness(zen: true)
            try await MainActor.run { try expect(h.model.screenMode == .loading, "isLoading starts true") }
        }

        r.run("an empty list still shows the list, not empty, when a Source is unavailable") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run {
                h.model.messagesNeedFullDiskAccess = true
                try expect(h.model.screenMode == .list, "there's a Notice to show for the unreachable Source")
                h.model.messagesNeedFullDiskAccess = false
                h.model.remindersUnavailable = true
                try expect(h.model.screenMode == .list)
                h.model.remindersUnavailable = false
                h.model.extractionUnavailable = true
                try expect(h.model.screenMode == .list)
            }
        }

        r.run("empty beats Zen") {
            let h = await makeHarness(zen: true)
            await h.model.start()
            try await MainActor.run { try expect(h.model.screenMode == .empty) }
        }

        r.run("Zen wins once the list is non-empty and nothing else takes precedence") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)], zen: true)
            await h.model.start()
            try await MainActor.run { try expect(h.model.screenMode == .zen) }
        }

        r.run("turning Zen off shows the list") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)], zen: true)
            await h.model.start()
            try await MainActor.run {
                h.model.isZenFocusModeEnabled = false
                try expect(h.model.screenMode == .list)
            }
        }
    }

    runner.suite("AppModel.sections: which Sections exist, in order") { r in
        let everything = (
            tasks: [task(id: "f1", priority: .high), task(id: "l1")],
            messages: [suggestion(id: "s1")]
        )

        r.run("with everything present: Suggested, Focus, then Later") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages)
            await h.model.start()
            try await MainActor.run { try expect(h.model.sections.map(\.id) == ["suggested", "tier-focus", "tier-later"]) }
        }

        r.run("an empty Tier or an empty Suggested Tasks Inbox produces no Section") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high)])
            await h.model.start()
            try await MainActor.run { try expect(h.model.sections.map(\.id) == ["tier-focus"]) }
        }

        r.run("Zen Focus Mode hides Suggested and Later, keeping Focus") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages, zen: true)
            await h.model.start()
            try await MainActor.run { try expect(h.model.sections.map(\.id) == ["tier-focus"]) }
        }

        r.run("Zen Focus Mode with an empty Focus produces no Section") {
            let h = await makeHarness(tasks: [task(id: "l1")], messageSignals: [suggestion(id: "s1")], zen: true)
            await h.model.start()
            try await MainActor.run { try expect(h.model.sections.isEmpty) }
        }

        r.run("toggling Zen updates the Sections") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages)
            await h.model.start()
            try await MainActor.run {
                h.model.isZenFocusModeEnabled = true
                try expect(h.model.sections.map(\.id) == ["tier-focus"])
                h.model.isZenFocusModeEnabled = false
                try expect(h.model.sections.map(\.id) == ["suggested", "tier-focus", "tier-later"])
            }
        }

        r.run("every Notice appears in Messages, Reminders, Extraction order, after every Signal-bearing Section") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages)
            await h.model.start()
            try await MainActor.run {
                h.model.extractionUnavailable = true
                h.model.remindersUnavailable = true
                h.model.messagesNeedFullDiskAccess = true
                try expect(h.model.sections.map(\.id) == [
                    "suggested", "tier-focus", "tier-later",
                    "notice-messagesUnavailable", "notice-remindersUnavailable", "notice-extractionUnavailable",
                ])
            }
        }

        r.run("the Snoozed Section comes after Later and before any Notice (ADR 0045)") {
            let h = await makeHarness(tasks: everything.tasks + [task(id: "z1")], messageSignals: everything.messages)
            await h.model.start()
            try await MainActor.run {
                let row = try require(h.model.rankedList.later.first { $0.id == "z1" })
                h.model.snooze(row, until: Date().addingTimeInterval(3600))
                h.model.remindersUnavailable = true
                try expect(h.model.sections.map(\.id) == [
                    "suggested", "tier-focus", "tier-later", "snoozed", "notice-remindersUnavailable",
                ])
            }
        }

        r.run("Zen Focus Mode hides the Snoozed Section") {
            let h = await makeHarness(tasks: [task(id: "f1", priority: .high), task(id: "z1")], zen: true)
            await h.model.start()
            try await MainActor.run {
                let row = try require(h.model.rankedList.later.first { $0.id == "z1" })
                h.model.snooze(row, until: Date().addingTimeInterval(3600))
                try expect(h.model.sections.map(\.id) == ["tier-focus"])
            }
        }

        r.run("with only Snoozed rows the window shows them, not the empty screen") {
            let h = await makeHarness(tasks: [task(id: "z1")])
            await h.model.start()
            try await MainActor.run {
                h.model.snooze(h.model.rankedList.later[0], until: Date().addingTimeInterval(3600))
                try expect(h.model.screenMode == .list, "got \(h.model.screenMode)")
                try expect(h.model.sections.map(\.id) == ["snoozed"])
            }
        }

        r.run("no flag set produces no Notice") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run { try expect(h.model.sections.isEmpty) }
        }

        r.run("extraction coming back removes its Notice") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run {
                h.model.extractionUnavailable = true
                try expect(h.model.sections.map(\.id) == ["notice-extractionUnavailable"])
                h.model.extractionUnavailable = false
                try expect(h.model.sections.isEmpty)
            }
        }

        r.run("a Gate coming back removes its Notice") {
            let h = await makeHarness()
            await h.model.start()
            try await MainActor.run {
                h.model.remindersUnavailable = true
                try expect(h.model.sections.map(\.id) == ["notice-remindersUnavailable"])
                h.model.remindersUnavailable = false
                try expect(h.model.sections.isEmpty)
            }
        }

        r.run("a Notice survives Zen Focus Mode, even with an empty Focus") {
            let h = await makeHarness(tasks: everything.tasks, messageSignals: everything.messages, zen: true)
            await h.model.start()
            try await MainActor.run {
                h.model.messagesNeedFullDiskAccess = true
                try expect(h.model.sections.map(\.id) == ["tier-focus", "notice-messagesUnavailable"])
            }
            let empty = await makeHarness(zen: true)
            await empty.model.start()
            try await MainActor.run {
                empty.model.messagesNeedFullDiskAccess = true
                try expect(empty.model.sections.map(\.id) == ["notice-messagesUnavailable"])
            }
        }

        r.run("Suggested carries raw Signals, never grouped") {
            let h = await makeHarness(messageSignals: [
                suggestion(id: "s1", sourceRef: "m1", lowConfidence: true),
                suggestion(id: "s2", sourceRef: "m1", lowConfidence: true),
            ])
            await h.model.start()
            try await MainActor.run {
                guard case .suggested(let signals) = h.model.sections.first else {
                    throw TestFailure(message: "expected .suggested first")
                }
                try expect(signals.count == 2)
            }
        }

        r.run("a Tier groups a same-source, low-confidence run") {
            let stated = ["b1", "b2"].map {
                Signal(
                    id: $0, source: .messages, sourceRef: "m1", label: $0, originalText: "milk and eggs",
                    createdAt: Date(), provenance: .stated, lowConfidence: true
                )
            }
            let h = await makeHarness(messageSignals: stated)
            await h.model.start()
            try await MainActor.run {
                guard case .tier(.later, let groups) = h.model.sections.last else {
                    throw TestFailure(message: "expected .tier(.later, _) last, got \(h.model.sections.map(\.id))")
                }
                try expect(groups.count == 1)
            }
        }
    }
}
