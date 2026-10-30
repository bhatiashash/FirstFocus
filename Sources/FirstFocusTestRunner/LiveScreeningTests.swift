import FirstFocusApp
import FirstFocusCore
import Foundation

private func received(_ id: String, chatId: Int, text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: false, text: text, createdAt: Date(), senderAddress: "+15550001111")
}

private func liveDeps(
    store: SQLiteSignalStore, extractor: FakeIntentExtractor, history: SQLiteHistoryStore, screener: FakeScreener, cutoff: Double
) -> ExtractionDependencies {
    ExtractionDependencies(
        store: store, extractor: extractor, historyStore: history, screener: screener, screeningMode: .live(cutoff: cutoff),
        // Never picked for the Audit Sample, so a Screened message stays unseen.
        randomUnit: { 1 }
    )
}

private struct LiveHarness: @unchecked Sendable {
    let model: AppModel
    let store: SQLiteSignalStore
    let corrections: FakeCorrectionStore
    let extractor: FakeIntentExtractor
    let screener: FakeScreener
}

func registerLiveScreeningTests(_ runner: TestRunner) {
    runner.suite("Live Screening (ADR 0036)") { r in
        r.run("at or above the cutoff, the message goes on to the model") {
            let screener = FakeScreener(probability: 0.5)
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            let signals = await refreshThroughIntake(
                from: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: liveDeps(store: makeTestSignalStore(), extractor: extractor, history: history, screener: screener, cutoff: 0.5)
            )
            try expect(extractor.calls.count == 1)
            try expect(signals.map(\.label) == ["Book the flights"])
            let row = try require(history.allRows().first { $0.isScreening })
            try expect(!row.wasScreened)
        }

        r.run("below the cutoff, the message is Screened: Processed with no Signals, a Screened row, and no model call") {
            let screener = FakeScreener(probability: 0.2)
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            let store = makeTestSignalStore()
            let signals = await refreshThroughIntake(
                from: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: liveDeps(store: store, extractor: extractor, history: history, screener: screener, cutoff: 0.5)
            )
            try expect(extractor.calls.isEmpty, "a Screened message never reaches the model")
            try expect(signals.isEmpty)
            try expect(store.isProcessed(sourceRef: "m1"))
            let row = try require(history.allRows().first { $0.isScreening })
            try expect(row.wasScreened)
            try expect(row.screeningProbability == 0.2)
            try expect(history.allRows().contains { $0.wasScreened })
        }

        r.run("automatic intake never sends a Screened message to Screening again") {
            let screener = FakeScreener(probability: 0.2)
            let extractor = FakeIntentExtractor(responses: [:])
            let history = makeTestHistoryStore()
            let store = makeTestSignalStore()
            let messages = [received("m1", chatId: 1, text: "can you book the flights")]
            let deps = liveDeps(store: store, extractor: extractor, history: history, screener: screener, cutoff: 0.5)
            _ = await refreshThroughIntake(from: messages, deps: deps)
            _ = await refreshThroughIntake(from: messages, deps: deps)
            try expect(screener.inputs.count == 1)
        }
    }

    runner.suite("Screening settings: live mode needs a cutoff") { r in
        r.run("live can't be chosen until a cutoff is set; once set, the mode carries it") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            settings.isLive = true
            try expect(settings.mode == .shadow, "no cutoff yet, so live must not take effect")
            settings.cutoff = 0.35
            try expect(settings.mode == .live(cutoff: 0.35))
            try expect(effectiveScreeningMode(settings: settings, apiKey: "tsk-1") == .live(cutoff: 0.35))
            settings.isLive = false
            try expect(settings.mode == .shadow)
        }

        r.run("the view model offers live only once a cutoff has been chosen") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let app = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { ScreeningSettingsViewModel(settings: settings, keyStore: FakeAPIKeyStore(), extraction: app.host) }
            try await MainActor.run {
                try expect(!viewModel.canGoLive)
                try expect(viewModel.cutoff == 0.5, "the stepper starts at 0.5, but nothing is stored until it's set")
                viewModel.setCutoff(0.4)
                try expect(viewModel.canGoLive)
                viewModel.isLive = true
            }
            try expect(settings.mode == .live(cutoff: 0.4))
        }
    }

    runner.suite("Correction selection uses false positives only") { r in
        r.run("a false-negative Correction never becomes an extraction example") {
            let store = FakeCorrectionStore()
            try store.record(Correction(chatId: 1, inputText: "missed", correctedOutput: "", correctionType: .falseNegative))
            try store.record(Correction(chatId: 1, inputText: "wrong", correctedOutput: "NONE", correctionType: .falsePositive))
            try store.record(Correction(chatId: 2, inputText: "missed elsewhere", correctedOutput: "", correctionType: .falseNegative))
            let selected = selectCorrections(chatId: 1, store: store)
            try expect(selected.map(\.inputText) == ["wrong"], "got \(selected.map(\.inputText))")
        }

        r.run("the SQLite store filters by type too") {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("firstfocus-corr-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteCorrectionStore(path: path)
            try store.record(Correction(chatId: 1, inputText: "missed", correctedOutput: "", correctionType: .falseNegative))
            try store.record(Correction(chatId: 1, inputText: "wrong", correctedOutput: "NONE", correctionType: .falsePositive))
            try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).map(\.inputText) == ["wrong"])
            try expect(store.globalCorrections(excludingChatId: 9, limit: 10, type: .falseNegative).map(\.inputText) == ["missed"])
        }
    }

    runner.suite("\"This was work\"") { r in
        r.run("records a false-negative Correction, sends the message to the model without Screening, and lands a Suggestion") {
            let h = await MainActor.run { () -> LiveHarness in
                let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
                let settings = ScreeningSettings(defaults: defaults)
                settings.isEnabled = true
                settings.cutoff = 0.5
                settings.isLive = true
                let store = makeTestSignalStore()
                try? store.markBackfillComplete()
                let corrections = FakeCorrectionStore()
                let extractor = FakeIntentExtractor(responses: [
                    "[context]\nParticipant A: are you around saturday\n\n[latest messages]\nParticipant A: can you book the flights": "Book the flights",
                ])
                let screener = FakeScreener(probability: 0.1)
                let model = AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource(messages: [
                        ChatMessage(id: "m0", chatId: 3, isFromMe: false, text: "are you around saturday",
                                    createdAt: Date().addingTimeInterval(-60), senderAddress: "+15550001111"),
                        received("m1", chatId: 3, text: "can you book the flights"),
                    ])
                    d.signalStore = store
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                    d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                    d.loadModel = { _, _ in extractor }
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = corrections
                    d.screeningSettings = settings
                    d.apiKeyStore = FakeAPIKeyStore(key: "tsk-1")
                    d.makeScreener = { _ in screener }
                    d.auditRoll = { 1 }
                    d.bundlePath = "/nonexistent"
                })
                return LiveHarness(model: model, store: store, corrections: corrections, extractor: extractor, screener: screener)
            }
            await h.model.start()
            try expect(h.extractor.calls.isEmpty, "both messages were Screened at launch")
            let screenedCalls = h.screener.inputs.count

            let screenedRow = HistoryEntry(
                sourceRawText: "can you book the flights", modelUsed: "JEV", signalCount: 0, chatId: 3,
                renderedContext: "Participant A: can you book the flights", kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "m1"
            )
            await h.model.historyActions.thisWasWork(historyBatch(screenedRow))

            try expect(h.corrections.stored.count == 1)
            let correction = try require(h.corrections.stored.first)
            try expect(correction.correctionType == .falseNegative)
            try expect(correction.chatId == 3)
            try expect(h.screener.inputs.count == screenedCalls, "This was work must bypass Screening")
            try expect(h.extractor.calls.count == 1)
            try await MainActor.run {
                try expect(h.model.rankedList.suggested.map(\.label) == ["Book the flights"])
            }
        }

        r.run("with no model loaded it shows disabled with the reason, and clicking records nothing") {
            let app = await MainActor.run { makeHistoryApp(extractor: nil) }
            let row = HistoryEntry(
                sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 3,
                kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "m1"
            )
            let batch = historyBatch(row)
            try await MainActor.run {
                try expect(app.actions.offered(.thisWasWork, for: batch) == .unavailable(reason: noModelLoadedReason))
                try expect(noModelLoadedReason == "No model loaded")
            }
            await app.actions.thisWasWork(batch)
            try await MainActor.run { try expect(app.model.corrections.types(forBatches: ["m1"]).isEmpty) }
        }

        r.run("History re-reads after This was work, so the Batch shows as Corrected") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            try app.history.record(HistoryEntry(
                sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 3,
                kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "m1"
            ))
            let viewModel = await MainActor.run {
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                return viewModel
            }
            let batch = try await MainActor.run { try require(viewModel.selectedBatch) }
            await app.actions.thisWasWork(batch)
            try await MainActor.run {
                try expect(viewModel.weekSummary.corrected == 1)
                let batch = try require(viewModel.selectedBatch)
                try expect(viewModel.badges(for: batch).map(\.text) == ["Corrected"])
            }
        }
    }
}
