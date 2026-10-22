import DailyOSApp
import DailyOSCore
import Foundation

/// Ticket 08 (batched-extraction): the Suggested Tasks Inbox can be
/// triaged from the keyboard.
private struct Harness: @unchecked Sendable {
    let model: AppModel
    let store: SQLiteSignalStore
    let taskSource: FakeTaskSource
}

private func makeHarness(suggestionLabels: [String], zen: Bool = false) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
        let preference = ZenFocusModePreference(defaults: defaults)
        preference.isEnabled = zen
        let store = makeTestSignalStore()
        try? store.markBackfillComplete()
        let base = Date()
        for (index, label) in suggestionLabels.enumerated() {
            // Newest first in the Inbox, so the first label is the newest.
            let signal = Signal(
                id: "s\(index + 1)", source: .messages, sourceRef: "m\(index + 1)", label: label,
                originalText: label.lowercased(), createdAt: base.addingTimeInterval(-Double(index) * 60), provenance: .inferred
            )
            try? store.recordOneMessageBatch("m\(index + 1)", signals: [signal])
        }
        let taskSource = FakeTaskSource(tasks: [], availability: .available)
        let model = AppModel(
            taskSource: taskSource,
            messagesSource: FakeMessagesSource(messages: []), signalStore: store,
            contactsResolver: FakeContactsResolver(), settingsOpener: FakeSettingsOpener(),
            refreshClock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
            foregroundObserver: FakeForegroundObserver(),
            zenFocusModePreference: preference,
            focusListPreference: isolatedFocusListOff(), reExtractionSettings: ReExtractionSettings(defaults: defaults),
            extractor: FakeIntentExtractor(), historyStore: makeTestHistoryStore(), correctionStore: FakeCorrectionStore(),
            apiKeyStore: FakeAPIKeyStore(), bundlePath: "/nonexistent"
        )
        return Harness(model: model, store: store, taskSource: taskSource)
    }
}

func registerInboxTriageTests(_ runner: TestRunner) {
    runner.suite("inboxFocus (pure)") { r in
        r.run("down with nothing focused focuses the first Suggestion") {
            try expect(inboxFocus(moving: .down, from: nil, in: ["a", "b"]) == "a")
        }
        r.run("up with nothing focused focuses the last Suggestion") {
            try expect(inboxFocus(moving: .up, from: nil, in: ["a", "b"]) == "b")
        }
        r.run("down and up move one row and stop at the ends") {
            try expect(inboxFocus(moving: .down, from: "a", in: ["a", "b"]) == "b")
            try expect(inboxFocus(moving: .down, from: "b", in: ["a", "b"]) == "b")
            try expect(inboxFocus(moving: .up, from: "b", in: ["a", "b"]) == "a")
            try expect(inboxFocus(moving: .up, from: "a", in: ["a", "b"]) == "a")
        }
        r.run("a focused id that has left the Inbox counts as nothing focused") {
            try expect(inboxFocus(moving: .down, from: "gone", in: ["a", "b"]) == "a")
        }
        r.run("an empty Inbox has nothing to focus") {
            try expect(inboxFocus(moving: .down, from: nil, in: []) == nil)
        }
        r.run("after acting on a row, focus moves to the next one") {
            try expect(inboxFocus(afterActingOn: "a", in: ["a", "b", "c"]) == "b")
        }
        r.run("after acting on the last row, focus moves to the previous one") {
            try expect(inboxFocus(afterActingOn: "c", in: ["a", "b", "c"]) == "b")
        }
        r.run("after acting on the only row, nothing is focused") {
            try expect(inboxFocus(afterActingOn: "a", in: ["a"]) == nil)
        }
    }

    runner.suite("AppModel: Inbox keyboard triage") { r in
        r.run("Return approves the focused Suggestion and focus moves to the next") {
            let h = await makeHarness(suggestionLabels: ["Book the flights", "Read the notice", "Call the plumber"])
            await h.model.start()
            await h.model.handleInboxKey(.down)
            try await MainActor.run { try expect(h.model.focusedSuggestionId == "s1") }
            await h.model.handleInboxKey(.approve)
            try expect(h.taskSource.tasks.map(\.title) == ["Book the flights"], "got \(h.taskSource.tasks.map(\.title))")
            try await MainActor.run {
                try expect(h.model.rankedList.suggested.map(\.id) == ["s2", "s3"])
                try expect(h.model.focusedSuggestionId == "s2")
            }
        }

        r.run("Delete dismisses the focused Suggestion") {
            let h = await makeHarness(suggestionLabels: ["Book the flights", "Read the notice"])
            await h.model.start()
            await h.model.handleInboxKey(.down)
            await h.model.handleInboxKey(.down)
            await h.model.handleInboxKey(.dismiss)
            try expect(!h.store.openSignals().contains { $0.id == "s2" }, "the dismissal must be stored")
            try expect(h.taskSource.tasks.isEmpty)
            try await MainActor.run {
                try expect(h.model.rankedList.suggested.map(\.id) == ["s1"])
                try expect(h.model.focusedSuggestionId == "s1", "acting on the last row moves focus back one")
            }
        }

        r.run("Return and Delete do nothing with no Suggestion focused") {
            let h = await makeHarness(suggestionLabels: ["Book the flights"])
            await h.model.start()
            await h.model.handleInboxKey(.approve)
            await h.model.handleInboxKey(.dismiss)
            try expect(h.taskSource.tasks.isEmpty)
            try expect(h.store.openSignals().count == 1)
        }

        r.run("in Zen Focus Mode the keys do nothing, since the Inbox is hidden") {
            let h = await makeHarness(suggestionLabels: ["Book the flights"], zen: true)
            await h.model.start()
            await h.model.handleInboxKey(.down)
            await h.model.handleInboxKey(.approve)
            try await MainActor.run { try expect(h.model.focusedSuggestionId == nil) }
            try expect(h.taskSource.tasks.isEmpty)
        }

        r.run("an empty Inbox leaves nothing focused") {
            let h = await makeHarness(suggestionLabels: [])
            await h.model.start()
            await h.model.handleInboxKey(.down)
            try await MainActor.run { try expect(h.model.focusedSuggestionId == nil) }
        }

        r.run("focus clears when the focused Suggestion leaves the Inbox another way") {
            let h = await makeHarness(suggestionLabels: ["Book the flights", "Read the notice"])
            await h.model.start()
            await h.model.handleInboxKey(.down)
            await MainActor.run {
                let focused = h.model.rankedList.suggested[0]
                h.model.dismiss(focused)
            }
            try await MainActor.run { try expect(h.model.focusedSuggestionId == nil) }
        }
    }
}
