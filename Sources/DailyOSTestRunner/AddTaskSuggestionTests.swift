import DailyOSApp
import DailyOSCore
import Foundation

/// correction-identity ticket 03: a Suggestion added with "Add task" is made
/// the way the model's Suggestions are, and History rows record the Chat's
/// deep-link identifier.
private let priya = "+15551234567"
private let now = Date()

private func message(
    _ id: String, _ text: String, minutesAgo: Double, fromMe: Bool = false, chatId: Int = 5,
    chatIdentifier: String? = priya, isGroupChat: Bool = false
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chatId, isFromMe: fromMe, text: text, createdAt: now.addingTimeInterval(-minutesAgo * 60),
        senderAddress: fromMe ? nil : priya, chatIdentifier: chatIdentifier, isGroupChat: isGroupChat
    )
}

private struct Harness: @unchecked Sendable {
    let model: AppModel
    let signals: SQLiteSignalStore
    let history: SQLiteHistoryStore
}

private func makeHarness(messages: [ChatMessage], responses: [String: String]) async -> Harness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
        let signals = makeTestSignalStore()
        try? signals.markBackfillComplete()
        try? signals.recordNonSelfMessagesCutoff(now.addingTimeInterval(-24 * 60 * 60))
        let history = makeTestHistoryStore()
        let screening = ScreeningSettings(defaults: defaults)
        screening.isEnabled = true
        let screener = FakeScreener(probability: 0.9)
        let model = AppModel(
            taskSource: FakeTaskSource(tasks: [], availability: .available),
            messagesSource: FakeMessagesSource(messages: messages), signalStore: signals,
            contactsResolver: FakeContactsResolver(names: [priya: "Priya"]), settingsOpener: FakeSettingsOpener(),
            refreshClock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
            foregroundObserver: FakeForegroundObserver(),
            zenFocusModePreference: ZenFocusModePreference(defaults: defaults),
            reExtractionSettings: ReExtractionSettings(defaults: defaults),
            extractor: FakeIntentExtractor(responses: responses), historyStore: history,
            correctionStore: FakeCorrectionStore(), screeningSettings: screening, apiKeyStore: FakeAPIKeyStore(key: "k"),
            makeScreener: { _ in screener }, bundlePath: "/nonexistent"
        )
        return Harness(model: model, signals: signals, history: history)
    }
}

private func transcriptLine(_ speaker: String, _ text: String, fromMe: Bool = false, context: Bool = false) -> HistoryTranscriptLine {
    HistoryTranscriptLine(speaker: speaker, isFromMe: fromMe, text: text, sentAt: now, isContext: context)
}

func registerAddTaskSuggestionTests(_ runner: TestRunner) {
    runner.suite("\"Add task\" makes its Suggestion the way the model does") { r in
        r.run("a Suggestion from Add task matches the model's for the same Batch: wording, Sender, Chat link and context") {
            let h = await makeHarness(
                messages: [
                    message("m1", "we're going out friday", minutesAgo: 60),
                    message("m2", "can you book the table", minutesAgo: 5),
                    message("m3", "sure", minutesAgo: 4.9, fromMe: true),
                ],
                responses: ["we're going out friday": "NONE", "can you book the table\nsure": "Book the table"]
            )
            await h.model.start()
            let fromModel = try require(h.signals.openSignals().first { $0.sourceRef == "m3" }, "the model's Suggestion")
            let row = try require(h.history.allRows().first { $0.sourceRef == "m3" && $0.kind == .extraction })
            try expect(row.chatIdentifier == priya, "a one-to-one Chat's History row records its deep link")

            // The same Batch as a model call that found nothing, the only
            // kind that offers Add task.
            let missed = HistoryEntry(
                subject: row.subject, rawOutput: "NONE", modelUsed: row.modelUsed, signalCount: 0,
                renderedContext: row.renderedContext
            )
            await MainActor.run { h.model.historyActions.addTask("Book the table", to: historyBatch(missed)) }
            let added = try require(h.signals.openSignals().first { $0.sourceRef == "m3" && $0.id != fromModel.id })
            try expect(added.originalText == fromModel.originalText, "got \(added.originalText) vs \(fromModel.originalText)")
            try expect(added.sender == fromModel.sender && added.sender == "Priya")
            try expect(added.chatIdentifier == priya)
            try expect(added.contextText == fromModel.contextText && added.contextText == "Priya: we're going out friday")
            try expect(added.createdAt == fromModel.createdAt)
        }

        r.run("every History row for a Batch records the Chat link: Screening and extraction; a group Chat's record none") {
            let h = await makeHarness(
                messages: [
                    message("m1", "can you book the table", minutesAgo: 5),
                    message("g1", "who's bringing snacks", minutesAgo: 5, chatId: 9, chatIdentifier: nil, isGroupChat: true),
                ],
                responses: [:]
            )
            await h.model.start()
            let oneToOne = h.history.allRows().filter { $0.sourceRef == "m1" }
            try expect(oneToOne.contains { $0.isScreening } && oneToOne.contains { $0.kind == .extraction }, "got \(oneToOne.map(\.kind))")
            try expect(oneToOne.allSatisfy { $0.chatIdentifier == priya })
            let group = h.history.allRows().filter { $0.sourceRef == "g1" }
            try expect(!group.isEmpty && group.allSatisfy { $0.chatIdentifier == nil })
        }

        r.run("Add task on a row written before rows recorded the Chat link still adds the Suggestion, with no link") {
            let h = await makeHarness(messages: [], responses: [:])
            await h.model.start()
            let row = HistoryEntry(
                sourceRawText: "can you book a table", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 3,
                renderedContext: "[latest messages]\nParticipant A: can you book a table", sourceRef: "m9", sender: "Mom",
                transcript: [transcriptLine("Mom", "can you book a table")]
            )
            await MainActor.run { h.model.historyActions.addTask("Book a table", to: historyBatch(row)) }
            let added = try require(h.signals.openSignals().first { $0.sourceRef == "m9" })
            try expect(added.chatIdentifier == nil)
            try expect(added.originalText == "Mom: can you book a table")
            try expect(added.sender == "Mom")
        }
    }

    runner.suite("messagesSuggestion (the one way a Messages Suggestion is made)") { r in
        func make(_ transcript: [HistoryTranscriptLine], selfThread: Bool = false, chatIdentifier: String? = nil) -> Signal {
            messagesSuggestion(
                label: "Book the table", sourceRef: "m3", chatId: 5, transcript: transcript, isSelfThread: selfThread,
                chatIdentifier: chatIdentifier
            )
        }

        r.run("a Self-thread note keeps its plain text and has no Sender") {
            let signal = make([transcriptLine("You", "book the table", fromMe: true)], selfThread: true)
            try expect(signal.originalText == "book the table")
            try expect(signal.sender == nil)
            try expect(signal.contextText == nil)
            try expect(signal.provenance == .inferred)
        }

        r.run("a one-to-one Batch names every line, keeps its context and link, and its Sender is the newest line not yours") {
            let signal = make([
                transcriptLine("Priya", "we're going out friday", context: true),
                transcriptLine("Priya", "can you book the table"),
                transcriptLine("You", "sure", fromMe: true),
            ], chatIdentifier: priya)
            try expect(signal.originalText == "Priya: can you book the table\nYou: sure")
            try expect(signal.contextText == "Priya: we're going out friday")
            try expect(signal.sender == "Priya")
            try expect(signal.chatIdentifier == priya)
        }

        r.run("a group Batch's Sender is whoever wrote its newest line that isn't yours") {
            let signal = make([
                transcriptLine("Priya", "who's booking"),
                transcriptLine("Sam", "can you book the table"),
            ])
            try expect(signal.sender == "Sam")
            try expect(signal.chatIdentifier == nil)
        }

        r.run("a Batch of only your own lines has no Sender") {
            let signal = make([transcriptLine("You", "I'll book the table", fromMe: true)])
            try expect(signal.sender == nil)
        }
    }
}
