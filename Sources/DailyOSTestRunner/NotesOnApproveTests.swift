import DailyOSApp
import DailyOSCore
import Foundation

/// ADR 0041: Approve writes the Batch into the reminder's Notes and a
/// one-to-one Chat's link into its URL, and every reminder's Notes and URL
/// come back on the Ranked List.
private struct Harness: @unchecked Sendable {
    let model: AppModel
    let taskSource: FakeTaskSource
}

private func makeHarness(suggestions: [Signal] = [], tasks: [ReminderTask] = []) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
        let store = makeTestSignalStore()
        try? store.markBackfillComplete()
        for signal in suggestions {
            try? store.recordOneMessageBatch(signal.sourceRef, signals: [signal])
        }
        let taskSource = FakeTaskSource(tasks: tasks, availability: .available)
        let model = AppModel(
            taskSource: taskSource,
            messagesSource: FakeMessagesSource(messages: []), signalStore: store,
            contactsResolver: FakeContactsResolver(), settingsOpener: FakeSettingsOpener(),
            refreshClock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
            foregroundObserver: FakeForegroundObserver(), dayChanges: FakeDayChangeObserver(),
            zenFocusModePreference: ZenFocusModePreference(defaults: defaults),
            focusListPreference: isolatedFocusListOff(), reExtractionSettings: ReExtractionSettings(defaults: defaults),
            extractor: FakeIntentExtractor(), historyStore: makeTestHistoryStore(), correctionStore: FakeCorrectionStore(),
            apiKeyStore: FakeAPIKeyStore(), bundlePath: "/nonexistent"
        )
        return Harness(model: model, taskSource: taskSource)
    }
}

private func suggestion(originalText: String, sender: String?, chatIdentifier: String?) -> Signal {
    Signal(
        id: "s1", source: .messages, sourceRef: "m1", label: "Send the deck", originalText: originalText,
        createdAt: Date(), provenance: .inferred, sender: sender, chatIdentifier: chatIdentifier, chatId: 7
    )
}

func registerNotesOnApproveTests(_ runner: TestRunner) {
    runner.suite("AppModel: Approve saves the Batch and Chat link (ADR 0041)") { r in
        r.run("from a one-to-one Chat, Notes are the Batch with names and the URL opens that Chat") {
            let batch = "Priya: can you send the deck before the call\nYou: sure, by friday"
            let h = await makeHarness(suggestions: [suggestion(originalText: batch, sender: "Priya", chatIdentifier: "+15551234567")])
            await h.model.start()
            let signal = await MainActor.run { h.model.rankedList.suggested.first! }

            await h.model.approve(signal)

            let created = try require(h.taskSource.tasks.first)
            try expect(created.notes == batch)
            try expect(created.url == URL(string: "sms:+15551234567"))
            try expect(created.title == "Send the deck (from Priya)", "the title rule from ADR 0016 is unchanged")
        }

        r.run("from a group Chat, Notes are saved and there is no URL") {
            let batch = "Participant A: who's bringing the deck\nYou: I'll send it"
            let h = await makeHarness(suggestions: [suggestion(originalText: batch, sender: "Priya", chatIdentifier: nil)])
            await h.model.start()
            let signal = await MainActor.run { h.model.rankedList.suggested.first! }

            await h.model.approve(signal)

            let created = try require(h.taskSource.tasks.first)
            try expect(created.notes == batch)
            try expect(created.url == nil)
        }

        r.run("from the Self-thread, Notes are the note itself") {
            let h = await makeHarness(suggestions: [suggestion(originalText: "send the deck to priya", sender: nil, chatIdentifier: nil)])
            await h.model.start()
            let signal = await MainActor.run { h.model.rankedList.suggested.first! }

            await h.model.approve(signal)

            try expect(h.taskSource.tasks.first?.notes == "send the deck to priya")
            try expect(h.taskSource.tasks.first?.title == "Send the deck")
        }

        r.run("a reminder's Notes and URL reach the Ranked List") {
            let task = ReminderTask(
                id: "r1", title: "Send the deck", dueAt: nil, priority: .high, createdAt: Date(),
                notes: "Priya: can you send the deck", url: URL(string: "sms:+15551234567")
            )
            let h = await makeHarness(tasks: [task])
            await h.model.start()

            let signal = try await MainActor.run { try require(h.model.rankedList.focus.first { $0.id == "r1" }) }
            try expect(signal.notes == "Priya: can you send the deck")
            try expect(signal.url == URL(string: "sms:+15551234567"))
        }

        r.run("Rename, Move to Later and Move to Focus keep Notes and URL") {
            let task = ReminderTask(
                id: "r1", title: "Send the deck", dueAt: nil, priority: .high, createdAt: Date(),
                notes: "Priya: can you send the deck", url: URL(string: "sms:+15551234567")
            )
            let h = await makeHarness(tasks: [task])
            await h.model.start()

            var signal = try await MainActor.run { try require(h.model.rankedList.focus.first { $0.id == "r1" }) }
            await h.model.renameTask(signal, to: "Send Priya the deck")
            signal = try await MainActor.run { try require(h.model.rankedList.focus.first { $0.id == "r1" }) }
            await h.model.demote(signal)
            signal = try await MainActor.run { try require(h.model.rankedList.later.first { $0.id == "r1" }) }
            await h.model.promote(signal)

            let stored = try require(h.taskSource.tasks.first)
            try expect(stored.title == "Send Priya the deck")
            try expect(stored.notes == "Priya: can you send the deck")
            try expect(stored.url == URL(string: "sms:+15551234567"))
        }
    }
}
