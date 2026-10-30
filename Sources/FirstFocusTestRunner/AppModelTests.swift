import FirstFocusApp
import FirstFocusCore
import Foundation

/// The first tests that construct `AppModel` at all. Before the FirstFocusApp
/// target existed (ADR 0020) nothing here was reachable: the app model
/// lived in an executable no test target linked, and held the concrete
/// EventKit/chat.db/Contacts adapters rather than the protocols the fakes
/// already satisfied.
///
/// What these cover is deliberately the choreography, not the pure rules.
/// `reminderAvailability`, `messagesAvailability` and `sourcesToRefresh`
/// each already have their own tests; what had none was whether AppModel
/// calls them at the right moment and does the right thing with the answer.
/// `@unchecked Sendable`: every field is a test double driven synchronously
/// by one test at a time, and the model itself is `@MainActor`. This exists
/// only so a harness built on the main actor can be handed back out to the
/// test body, same justification the fakes already carry.
private struct Harness: @unchecked Sendable {
    let model: AppModel
    let taskSource: FakeTaskSource
    let messagesSource: FakeMessagesSource
    let signalStore: SQLiteSignalStore
    let settingsOpener: FakeSettingsOpener
    let clock: FakeRefreshClock
    let eventKitChanges: FakeEventKitChangeObserver
    let foreground: FakeForegroundObserver
    let dayChanges: FakeDayChangeObserver
    let undoAlarm: FakeAlarm
    let reExtractionSettings: ReExtractionSettings
    let extractor: FakeIntentExtractor
    let historyStore: SQLiteHistoryStore
    let correctionStore: FakeCorrectionStore
    let now: SettableNow
}

/// The harness's clock, so a test can move time on without waiting.
final class SettableNow: @unchecked Sendable {
    var date = Date()
}

@MainActor
private func makeHarness(
    tasks: [ReminderTask] = [],
    reminders: SourceAvailability = .available,
    messages: SourceAvailability = .available,
    messagesList: [ChatMessage] = []
) -> Harness {
    let taskSource = FakeTaskSource(tasks: tasks, availability: reminders)
    let messagesSource = FakeMessagesSource(messages: messagesList, availability: messages)
    let signalStore = makeTestSignalStore()
    let settingsOpener = FakeSettingsOpener()
    let clock = FakeRefreshClock()
    let eventKitChanges = FakeEventKitChangeObserver()
    let foreground = FakeForegroundObserver()
    let dayChanges = FakeDayChangeObserver()
    let undoAlarm = FakeAlarm()
    // A throwaway defaults suite, so Zen Focus Mode's persisted flag and
    // re-extraction's cooldown never touch the real ones this machine's
    // app is using.
    let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
    let reExtractionSettings = ReExtractionSettings(defaults: defaults)
    let extractor = FakeIntentExtractor(responses: [:])
    let historyStore = makeTestHistoryStore()
    let correctionStore = FakeCorrectionStore()
    let now = SettableNow()
    let model = AppModel(AppDependencies.test { d in
        d.now = { now.date }
        d.taskSource = taskSource
        d.messagesSource = messagesSource
        d.signalStore = signalStore
        d.contactsResolver = FakeContactsResolver()
        d.settingsOpener = settingsOpener
        d.refreshClock = clock
        d.eventKitChanges = eventKitChanges
        d.foregroundObserver = foreground
        d.dayChanges = dayChanges
        d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
        d.reExtractionSettings = reExtractionSettings
        d.undoAlarm = undoAlarm
        d.loadModel = { _, _ in extractor }
        d.historyStore = historyStore
        d.correctionStore = correctionStore
        d.apiKeyStore = FakeAPIKeyStore()
        // Never fired, so only the triggers a test fires derive the list.
        d.snoozeWakeAlarm = FakeAlarm()
    })
    return Harness(
        model: model, taskSource: taskSource, messagesSource: messagesSource, signalStore: signalStore,
        settingsOpener: settingsOpener, clock: clock, eventKitChanges: eventKitChanges, foreground: foreground,
        dayChanges: dayChanges, undoAlarm: undoAlarm, reExtractionSettings: reExtractionSettings, extractor: extractor, historyStore: historyStore,
        correctionStore: correctionStore, now: now
    )
}

private func task(id: String, title: String, priority: Priority = .high) -> ReminderTask {
    ReminderTask(id: id, title: title, dueAt: nil, priority: priority, createdAt: Date())
}

/// A refresh trigger reaches `handleRefresh` through a `Task`, so firing it
/// is not synchronous with the refetch landing. Yields long enough for that
/// hop plus the detached fetch inside it.
private func settle() async {
    try? await Task.sleep(nanoseconds: 150_000_000)
}

func registerAppModelTests(_ runner: TestRunner) {
    runner.suite("AppModel: Gates degrade rather than block (ADR 0005)") { r in
        r.run("a granted Reminders Gate puts its tasks on the ranked list") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.reload()
            try await MainActor.run {
                try expect(h.model.remindersUnavailable == false)
                let all = h.model.rankedList.focus + h.model.rankedList.later
                try expect(all.map(\.label) == ["Call the dentist"])
            }
        }

        r.run("a denied Reminders Gate degrades to Unavailable and never fetches") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")], reminders: .unavailable) }
            await h.model.reload()
            try await MainActor.run {
                try expect(h.model.remindersUnavailable, "the Source should read as Unavailable")
                try expect(
                    h.model.rankedList.focus.isEmpty && h.model.rankedList.later.isEmpty,
                    "an Unavailable Source contributes no Signals"
                )
                try expect(h.taskSource.listCallCount == 0, "a denied Gate should short-circuit before the fetch")
            }
        }

        r.run("a Gate revoked mid-session empties that Source on the next refresh") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.reload()
            try await MainActor.run {
                try expect(h.model.rankedList.focus.count + h.model.rankedList.later.count == 1)
            }

            h.taskSource.gateAvailability = .unavailable
            await h.model.reload()
            try await MainActor.run {
                try expect(
                    h.model.rankedList.focus.isEmpty && h.model.rankedList.later.isEmpty,
                    "a revoked Gate drops its Signals rather than keeping stale ones"
                )
                try expect(h.model.remindersUnavailable)
            }
        }

        r.run("a denied Full Disk Access surfaces the re-grant state") {
            let h = await MainActor.run { makeHarness(messages: .unavailable) }
            await h.model.reloadMessages()
            try await MainActor.run {
                try expect(h.model.messagesNeedFullDiskAccess)
                try expect(h.messagesSource.listCallCount == 0, "a denied Gate should short-circuit before the read")
            }
        }
    }

    runner.suite("AppModel: refresh routing (ticket 11)") { r in
        r.run("an EventKit change refreshes Reminders and leaves Messages alone") {
            let h = await MainActor.run { makeHarness() }
            await h.model.start()
            let (remindersBefore, messagesBefore) = (h.taskSource.listCallCount, h.messagesSource.listCallCount)

            h.eventKitChanges.fire()
            await settle()

            try expect(h.taskSource.listCallCount == remindersBefore + 1, "Reminders should refetch")
            try expect(h.messagesSource.listCallCount == messagesBefore, "Messages must not be touched")
        }

        r.run("the interval trigger refreshes Messages and leaves Reminders alone") {
            let h = await MainActor.run { makeHarness() }
            await h.model.start()
            let (remindersBefore, messagesBefore) = (h.taskSource.listCallCount, h.messagesSource.listCallCount)

            h.clock.fire()
            await settle()

            try expect(h.messagesSource.listCallCount == messagesBefore + 1, "Messages should refetch")
            try expect(h.taskSource.listCallCount == remindersBefore, "Reminders has its own push trigger")
        }

        r.run("a day change derives the Ranked List again without fetching from either Source (ADR 0042)") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()
            // A Snooze running out is a change time alone makes to the list.
            // The store keeps whole seconds.
            let until = Date(timeIntervalSince1970: h.now.date.timeIntervalSince1970.rounded(.up) + 60)
            await MainActor.run {
                let signal = h.model.rankedList.focus.first { $0.id == "r1" }!
                h.model.snooze(signal, until: until)
            }
            h.now.date = until.addingTimeInterval(60)
            let (remindersBefore, messagesBefore) = (h.taskSource.listCallCount, h.messagesSource.listCallCount)
            let stillHidden = await MainActor.run { !h.model.rankedList.focus.contains { $0.id == "r1" } }
            try expect(stillHidden, "nothing has derived the list since the Snooze ran out")

            h.dayChanges.fire()
            await settle()

            let shown = await MainActor.run { h.model.rankedList.focus.contains { $0.id == "r1" } }
            try expect(shown, "the list is derived again with the current time")
            try expect(h.taskSource.listCallCount == remindersBefore, "Reminders must not be fetched")
            try expect(h.messagesSource.listCallCount == messagesBefore, "Messages must not be fetched")
        }

        r.run("the foreground trigger refreshes both, since either Gate could have changed") {
            let h = await MainActor.run { makeHarness() }
            await h.model.start()
            let (remindersBefore, messagesBefore) = (h.taskSource.listCallCount, h.messagesSource.listCallCount)

            h.foreground.fire()
            await settle()

            try expect(h.taskSource.listCallCount == remindersBefore + 1)
            try expect(h.messagesSource.listCallCount == messagesBefore + 1)
        }
    }

    runner.suite("AppModel: creating a reminder with a typed due date") { r in
        r.run("a due date is saved and the Priority `+` would give is dropped") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()
            let friday = Calendar.current.startOfDay(for: Date().addingTimeInterval(3 * 86400))

            await h.model.addReminder(title: "Call dentist", dueAt: friday)

            let created = try require(h.taskSource.tasks.first { $0.title == "Call dentist" })
            try expect(created.dueAt == friday)
            try expect(created.priority == .none, "a due date alone decides the Tier; Priority stays for what you flag")
        }

        r.run("with no due date, the reminder keeps the Priority `+` gives it in Focus") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()

            await h.model.addReminder(title: "Water the plants")

            let created = try require(h.taskSource.tasks.first { $0.title == "Water the plants" })
            try expect(created.dueAt == nil)
            try expect(created.priority == .high)
        }
    }

    runner.suite("AppModel: the Undo bar (inbox-undo 01)") { r in
        let farOff = Calendar.current.startOfDay(for: Date().addingTimeInterval(21 * 86400))

        r.run("a reminder from `+` due after tomorrow reports that it went to Later, with no Undo") {
            let h = await MainActor.run { makeHarness() }
            await h.model.start()

            await h.model.addReminder(title: "Renew passport", dueAt: farOff)

            let offer = await MainActor.run { h.model.undoOffer }
            try expect(offer?.text == "Added \u{201C}Renew passport\u{201D} to Later", "got \(String(describing: offer))")
            try expect(offer?.canUndo == false)
        }

        r.run("a reminder from `+` that lands in Focus reports nothing") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()

            await h.model.addReminder(title: "Water the plants")
            await h.model.addReminder(title: "Call the bank", dueAt: Calendar.current.startOfDay(for: Date()))

            let offer = await MainActor.run { h.model.undoOffer }
            try expect(offer == nil)
        }

        r.run("a reminder from Quick Capture never reports it") {
            let h = await MainActor.run { makeHarness() }
            await h.model.start()

            await h.model.createTask(title: "Renew passport", dueAt: farOff)

            let offer = await MainActor.run { h.model.undoOffer }
            try expect(offer == nil)
        }

        r.run("checking off shows the bar, and Undo brings the task back") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()

            await MainActor.run { h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!) }
            let offer = await MainActor.run { h.model.undoOffer }
            try expect(offer?.text == "Checked off \u{201C}Call the dentist\u{201D}", "got \(String(describing: offer))")
            try expect(offer?.canUndo == true)

            await h.model.undo()
            let (after, focus) = await MainActor.run { (h.model.undoOffer, h.model.rankedList.focus.map(\.id)) }
            try expect(after == nil)
            try expect(focus == ["r1"])
            try expect(h.taskSource.completedIds.isEmpty)
        }
    }

    runner.suite("AppModel: quitting with a check-off on the Undo bar (undo-bar 03)") { r in
        r.run("the reminder is completed before the app exits") {
            let h = await MainActor.run { makeHarness(tasks: [task(id: "r1", title: "Call the dentist")]) }
            await h.model.start()
            await MainActor.run {
                h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!)
                h.model.prepareToQuit()
            }
            // No settle: the process exits straight after, so the write
            // has to have landed by the time prepareToQuit returns.
            try expect(h.taskSource.completedIds == ["r1"], "got \(h.taskSource.completedIds)")
        }

        r.run("a check-off already being written when the app quits is completed too") {
            let h = await MainActor.run {
                makeHarness(tasks: [task(id: "r1", title: "Call the dentist"), task(id: "r2", title: "Pay rent")])
            }
            await h.model.start()
            await MainActor.run {
                // r2 replacing r1 on the bar starts r1's write in the
                // background, which quitting would otherwise cut short.
                h.taskSource.dropsBackgroundCompletions = true
                h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r1" }!)
                h.model.checkOff(h.model.rankedList.focus.first { $0.id == "r2" }!)
                h.model.prepareToQuit()
            }
            try expect(Set(h.taskSource.completedIds) == ["r1", "r2"], "got \(h.taskSource.completedIds)")
        }
    }

    runner.suite("\u{2318}Z triggers the Undo bar") { r in
        r.run("only with an Undo on offer, the main window key, no sheet, and no text being edited") {
            try expect(commandZUndoesOffer(canUndo: true, isMainWindowKey: true, hasSheet: false, isEditingText: false))
            try expect(!commandZUndoesOffer(canUndo: false, isMainWindowKey: true, hasSheet: false, isEditingText: false))
            try expect(!commandZUndoesOffer(canUndo: true, isMainWindowKey: false, hasSheet: false, isEditingText: false))
            try expect(!commandZUndoesOffer(canUndo: true, isMainWindowKey: true, hasSheet: true, isEditingText: false))
            try expect(!commandZUndoesOffer(canUndo: true, isMainWindowKey: true, hasSheet: false, isEditingText: true))
        }
    }

    runner.suite("AppModel: System Settings crosses the seam") { r in
        r.run("each Gate's re-grant control asks for its own pane") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.openFullDiskAccessSettings()
                h.model.openRemindersSettings()
            }
            try expect(h.settingsOpener.openedPanes == [.fullDiskAccess, .reminders])
        }
    }

    runner.suite("AppModel.canReExtract: the re-extract control's enablement rule (candidate 4)") { r in
        r.run("with nothing loading, pending, or unavailable, re-extraction is enabled") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run { h.model.isLoading = false }
            try await MainActor.run { try expect(h.model.canReExtract) }
        }

        r.run("still loading disables it") {
            let h = await MainActor.run { makeHarness() }
            try await MainActor.run { try expect(h.model.canReExtract == false, "isLoading starts true") }
        }

        r.run("Messages needing Full Disk Access disables it — nothing to re-extract from") {
            let h = await MainActor.run { makeHarness(messages: .unavailable) }
            await h.model.reloadMessages()
            await MainActor.run { h.model.isLoading = false }
            try await MainActor.run { try expect(h.model.canReExtract == false) }
        }

        r.run("the extractor being unavailable disables it") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.isLoading = false
                h.model.extraction.unload()
            }
            try await MainActor.run { try expect(h.model.canReExtract == false) }
        }

        r.run("remindersUnavailable alone does not disable it — re-extraction only concerns Messages") {
            let h = await MainActor.run { makeHarness(reminders: .unavailable) }
            await h.model.reload()
            await MainActor.run { h.model.isLoading = false }
            try await MainActor.run { try expect(h.model.canReExtract) }
        }

        r.run("a run within the configured cooldown disables it") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.isLoading = false
                h.reExtractionSettings.minimumIntervalHours = 6
                h.reExtractionSettings.lastRunAt = Date()
            }
            try await MainActor.run { try expect(h.model.canReExtract == false, "a run just now is well inside a 6-hour cooldown") }
        }

        r.run("a run older than the configured cooldown re-enables it") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.isLoading = false
                h.reExtractionSettings.minimumIntervalHours = 6
                h.reExtractionSettings.lastRunAt = Date().addingTimeInterval(-7 * 3600)
            }
            try await MainActor.run { try expect(h.model.canReExtract) }
        }

        r.run("a zero-hour cooldown never disables it, even for a run just now") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.isLoading = false
                h.reExtractionSettings.minimumIntervalHours = 0
                h.reExtractionSettings.lastRunAt = h.now.date
            }
            try await MainActor.run { try expect(h.model.canReExtract) }
        }

        r.run("reExtract() records the run's start time, disabling a second call inside the cooldown") {
            let h = await MainActor.run { makeHarness() }
            await MainActor.run {
                h.model.isLoading = false
                h.reExtractionSettings.minimumIntervalHours = 6
            }
            try await MainActor.run { try expect(h.reExtractionSettings.lastRunAt == nil, "no run has happened yet") }
            await h.model.reExtract()
            try await MainActor.run {
                try expect(h.reExtractionSettings.lastRunAt != nil, "reExtract() must record when it started")
                try expect(h.model.canReExtract == false, "immediately after a run, the cooldown should already apply")
            }
        }
    }

    runner.suite("AppModel: extraction QoS") { r in
        r.run("reloadMessages() runs the model at .background priority") {
            let msg = ChatMessage(
                id: "m1", chatId: 1, isFromMe: false, text: "call the dentist tomorrow", createdAt: Date()
            )
            let h = await MainActor.run { makeHarness(messagesList: [msg]) }
            await h.model.extraction.load()
            await h.model.reloadMessages()
            try expect(h.extractor.callPriorities == [.background], "an automated refresh must never contend with the UI for the main thread")
        }

        r.run("reExtract() runs the model at .utility priority, distinct from the automated background pass") {
            let msg = ChatMessage(
                id: "m1", chatId: 1, isFromMe: false, text: "call the dentist tomorrow", createdAt: Date()
            )
            let h = await MainActor.run { makeHarness(messagesList: [msg]) }
            await h.model.extraction.load()
            await h.model.reloadMessages()
            try expect(h.extractor.callPriorities == [.background], "the automated pass processes the message first")

            await MainActor.run { h.model.isLoading = false }
            await h.model.reExtract()
            try expect(
                h.extractor.callPriorities == [.background, .utility],
                "the explicit re-extraction click must run at .utility, not silently inherit the automated pass's priority"
            )
        }
    }

    runner.suite("AppModel: History (ADR 0029)") { r in
        r.run("a message the model finds work in is recorded to the History store") {
            let msg = ChatMessage(id: "m1", chatId: 1, isFromMe: false, text: "call the dentist", createdAt: Date())
            let h = await MainActor.run { makeHarness(messagesList: [msg]) }
            await h.model.extraction.load()
            await h.model.reloadMessages()
            let recorded = h.historyStore.allRows()
            try expect(recorded.count == 1)
            try expect(recorded.first?.modelUsed == "Fake Model")
        }

        r.run("activeModelDisplayName reflects whichever extractor is currently loaded") {
            let h = await MainActor.run { makeHarness() }
            try await MainActor.run { try expect(h.model.activeModelDisplayName == nil, "nothing loads before start") }
            await h.model.extraction.load()
            try await MainActor.run {
                try expect(h.model.activeModelDisplayName == "Fake Model")
            }
        }

        r.run("rerun replays a History entry's stored input through the currently loaded model and appends a new entry") {
            let h = await MainActor.run { makeHarness() }
            await h.model.extraction.load()
            let original = HistoryEntry(
                sourceRawText: "call the dentist", rawOutput: "NONE", modelUsed: "Some Other Model", signalCount: 0,
                sourceRef: "m1"
            )
            try h.historyStore.record(original)
            await h.model.historyActions.rerun(historyBatch(original))
            let all = h.historyStore.allRows()
            try expect(all.count == 2, "the original entry must survive, with Re-run's result appended")
            try expect(h.extractor.calls == ["call the dentist"])
            try expect(all.filter { $0.kind == .rerun }.count == 1, "Re-run's row is recorded as a rerun, not an extraction")
        }

        r.run("Mute writes through to the signal store, and reads it back") {
            let h = await MainActor.run { makeHarness() }
            let batch = historyBatch(HistoryEntry(
                sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 1, chatId: 42, sourceRef: "m1"
            ))
            try await MainActor.run {
                let actions = h.model.historyActions
                try expect(actions.isMutedNow(batch) == false)
                actions.toggleMute(batch)
                try expect(h.signalStore.isMuted(chatId: 42), "the store is the source of truth, not a cached flag")
                try expect(actions.isMutedNow(batch))
                actions.toggleMute(batch)
                try expect(actions.isMutedNow(batch) == false, "Muted is reversible, unlike Automated")
            }
        }

        r.run("Not for me records a false-positive Correction against the entry's Batch") {
            let h = await MainActor.run { makeHarness() }
            let entry = HistoryEntry(
                sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Fake Model",
                signalCount: 1, chatId: 42, renderedContext: "[latest messages]\nThem: call the dentist", sourceRef: "m1"
            )
            await MainActor.run { h.model.historyActions.notForMe(historyBatch(entry)) }

            let recorded = try require(h.correctionStore.stored.first)
            try expect(recorded.chatId == 42)
            try expect(recorded.sourceRef == "m1")
            try expect(recorded.inputText == "[latest messages]\nThem: call the dentist")
            try expect(recorded.correctedOutput == "NONE")
            try expect(recorded.correctionType == .falsePositive)
        }

        r.run("Not for me and This was work Corrections are both read back by Batch") {
            let h = await MainActor.run { makeHarness() }
            try h.correctionStore.record(Correction(
                chatId: 1, sourceRef: "m1", inputText: "a", correctedOutput: "NONE", correctionType: .falsePositive
            ))
            try h.correctionStore.record(Correction(
                chatId: 2, sourceRef: "m2", inputText: "b", correctedOutput: "", correctionType: .falseNegative
            ))
            let types = await MainActor.run { h.model.corrections.types(forBatches: ["m1", "m2"]) }
            try expect(types == ["m1": [.falsePositive], "m2": [.falseNegative]])
        }

        r.run("Not for me on a row with no chatId records nothing") {
            let h = await MainActor.run { makeHarness() }
            let entry = HistoryEntry(
                sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Fake Model", signalCount: 1,
                sourceRef: "m1"
            )
            await MainActor.run { h.model.historyActions.notForMe(historyBatch(entry)) }
            try expect(h.correctionStore.stored.isEmpty, "there's no Chat to scope a Correction to")
        }
    }
}
