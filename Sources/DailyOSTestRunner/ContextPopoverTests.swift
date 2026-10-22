import DailyOSApp
import DailyOSCore
import Foundation

/// Ticket 09 (batched-extraction): a popover on a Suggestion shows the
/// Batch and the messages the model saw before it.
@MainActor
private func makeModel(suggestions: [Signal], zen: Bool = false) -> AppModel {
    let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
    let preference = ZenFocusModePreference(defaults: defaults)
    preference.isEnabled = zen
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    for signal in suggestions {
        try? store.recordOneMessageBatch(signal.sourceRef, signals: [signal])
    }
    return AppModel(AppDependencies.test { d in
        d.taskSource = FakeTaskSource(tasks: [], availability: .available)
        d.messagesSource = FakeMessagesSource(messages: [])
        d.signalStore = store
        d.contactsResolver = FakeContactsResolver()
        d.settingsOpener = FakeSettingsOpener()
        d.refreshClock = FakeRefreshClock()
        d.eventKitChanges = FakeEventKitChangeObserver()
        d.foregroundObserver = FakeForegroundObserver()
        d.zenFocusModePreference = preference
        d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
        d.extractor = FakeIntentExtractor()
        d.historyStore = makeTestHistoryStore()
        d.correctionStore = FakeCorrectionStore()
        d.apiKeyStore = FakeAPIKeyStore()
        d.bundlePath = "/nonexistent"
    })
}

private func suggestion(_ id: String, label: String, originalText: String, contextText: String? = nil, age: Double) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: "m-\(id)", label: label, originalText: originalText,
        createdAt: Date().addingTimeInterval(-age), provenance: .inferred, contextText: contextText
    )
}

func registerContextPopoverTests(_ runner: TestRunner) {
    runner.suite("suggestionPreview (pure)") { r in
        r.run("shows the context lines, then the Batch") {
            let signal = suggestion(
                "s1", label: "Grab bread", originalText: "Mom: can you grab milk\nYou: no\nMom: just bread then",
                contextText: "Mom: are you at the store", age: 0
            )
            let preview = suggestionPreview(for: signal)
            try expect(preview.contextLines == ["Mom: are you at the store"])
            try expect(preview.batchLines == ["Mom: can you grab milk", "You: no", "Mom: just bread then"])
        }
        r.run("a Signal from before batching shows only its original wording") {
            let preview = suggestionPreview(for: suggestion("s1", label: "Call the dentist", originalText: "call the dentist", age: 0))
            try expect(preview.contextLines.isEmpty)
            try expect(preview.batchLines == ["call the dentist"])
        }
    }

    runner.suite("AppModel: the Suggestion popover") { r in
        r.run("Space toggles the popover for the focused Suggestion, and Escape closes it") {
            let model = await makeModel(suggestions: [
                suggestion("s1", label: "Grab bread", originalText: "grab bread", age: 10),
                suggestion("s2", label: "Book flights", originalText: "book flights", age: 20),
            ])
            await model.start()
            await model.handleInboxKey(.togglePreview)
            try await MainActor.run { try expect(model.previewedSuggestionId == nil, "nothing is focused yet") }
            await model.handleInboxKey(.down)
            await model.handleInboxKey(.togglePreview)
            try await MainActor.run { try expect(model.previewedSuggestionId == "s1") }
            await model.handleInboxKey(.togglePreview)
            try await MainActor.run { try expect(model.previewedSuggestionId == nil) }
            await model.handleInboxKey(.togglePreview)
            await model.handleInboxKey(.closePreview)
            try await MainActor.run { try expect(model.previewedSuggestionId == nil) }
        }

        r.run("an open popover follows focus to the next Suggestion") {
            let model = await makeModel(suggestions: [
                suggestion("s1", label: "Grab bread", originalText: "grab bread", age: 10),
                suggestion("s2", label: "Book flights", originalText: "book flights", age: 20),
            ])
            await model.start()
            await model.handleInboxKey(.down)
            await model.handleInboxKey(.togglePreview)
            await model.handleInboxKey(.down)
            try await MainActor.run { try expect(model.previewedSuggestionId == "s2") }
            await model.handleInboxKey(.dismiss)
            try await MainActor.run { try expect(model.previewedSuggestionId == "s1", "after acting, it follows focus again") }
        }

        r.run("hovering can open and close the popover for any Suggestion") {
            let model = await makeModel(suggestions: [suggestion("s1", label: "Grab bread", originalText: "grab bread", age: 10)])
            await model.start()
            await MainActor.run { model.showPreview(forSuggestionId: "s1") }
            try await MainActor.run { try expect(model.previewedSuggestionId == "s1") }
            await MainActor.run { model.hidePreview(forSuggestionId: "s1") }
            try await MainActor.run { try expect(model.previewedSuggestionId == nil) }
        }
    }
}
