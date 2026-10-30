import FirstFocusApp
import FirstFocusCore
import Foundation

private func received(_ id: String, chatId: Int, text: String, sender: String = "+15550001111") -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: false, text: text, createdAt: Date(), senderAddress: sender)
}

private func deps(
    store: SQLiteSignalStore = makeTestSignalStore(), extractor: FakeIntentExtractor, history: SQLiteHistoryStore = makeTestHistoryStore(),
    screener: FakeScreener?, mode: ScreeningMode
) -> ExtractionDependencies {
    ExtractionDependencies(
        store: store, extractor: extractor, historyStore: history, screener: screener, screeningMode: mode
    )
}

func registerScreeningTests(_ runner: TestRunner) {
    runner.suite("Screening in the Extraction pipeline (ADR 0036), shadow mode") { r in
        r.run("off: the Screener is never called and extraction runs exactly as before") {
            let screener = FakeScreener()
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            let signals = await refreshThroughIntake(
                from: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: deps(extractor: extractor, history: history, screener: screener, mode: .off)
            )
            try expect(screener.inputs.isEmpty)
            try expect(signals.map(\.label) == ["Book the flights"])
            try expect(history.allRows().allSatisfy { $0.kind == .extraction })
        }

        r.run("no Screener configured behaves as off, whatever the mode") {
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            _ = await refreshThroughIntake(
                from: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: deps(extractor: extractor, history: history, screener: nil, mode: .shadow)
            )
            try expect(extractor.calls.count == 1)
            try expect(history.allRows().allSatisfy { $0.kind == .extraction })
        }

        r.run("shadow: the Screener is called, a Screening row is written, and the model still sees the message") {
            let screener = FakeScreener(probability: 0.12)
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            let signals = await refreshThroughIntake(
                from: [received("m1", chatId: 4, text: "can you book the flights")],
                deps: deps(extractor: extractor, history: history, screener: screener, mode: .shadow)
            )
            try expect(screener.inputs.count == 1)
            try expect(extractor.calls.count == 1, "shadow mode must never keep a message from the model")
            try expect(signals.map(\.label) == ["Book the flights"])

            let screening = try require(history.allRows().first { $0.isScreening })
            try expect(screening.screeningProbability == 0.12)
            try expect(!screening.wasScreened, "nothing is Screened in shadow mode, however low the score")
            try expect(screening.sourceRef == "m1")
            try expect(screening.chatId == 4)
            try expect(screening.modelUsed == "Fake Screener")
            try expect(screening.signalCount == 0)
            try expect(history.allRows().contains { $0.kind == .extraction && $0.sourceRef == "m1" })
        }

        r.run("a Screener error sends the message to the model and records the failure, with no Screening decision") {
            let screener = FakeScreener(failure: URLError(.timedOut))
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            let history = makeTestHistoryStore()
            _ = await refreshThroughIntake(
                from: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: deps(extractor: extractor, history: history, screener: screener, mode: .shadow)
            )
            try expect(extractor.calls.count == 1)
            try expect(!history.allRows().contains { $0.isScreening }, "a failure is not a Screening decision")
            let failure = try require(history.allRows().first { $0.kind != .extraction })
            try expect(failure.kind == .screeningFailed(reason: "timed out"), "got \(failure.kind)")
            try expect(failure.sourceRef == "m1")
            try expect(failure.signalCount == 0)
        }

        r.run("Automated, Muted, confidentiality-triggered and heuristic-rejected messages never reach the Screener") {
            let store = makeTestSignalStore()
            try store.markAutomated(chatId: 1)
            try store.setMuted(true, chatId: 2)
            let screener = FakeScreener()
            let messages = [
                received("m1", chatId: 1, text: "can you book the flights"),
                received("m2", chatId: 2, text: "can you book the flights"),
                received("m3", chatId: 3, text: "don't tell anyone, but book the flights"),
                received("m4", chatId: 4, text: "lol"),
            ]
            _ = await refreshThroughIntake(
                from: messages,
                deps: deps(store: store, extractor: FakeIntentExtractor(responses: [:]), screener: screener, mode: .shadow)
            )
            try expect(screener.inputs.isEmpty, "got \(screener.inputs.map(\.text))")
        }

        r.run("self-thread messages never reach the Screener") {
            let screener = FakeScreener()
            let extractor = FakeIntentExtractor(responses: ["buy milk": "Buy milk"])
            let note = ChatMessage(id: "m1", chatId: 78, isFromMe: true, text: "buy milk", createdAt: Date(), isSelfThread: true)
            _ = await refreshThroughIntake(from: [note], deps: deps(extractor: extractor, screener: screener, mode: .shadow))
            try expect(screener.inputs.isEmpty)
            try expect(extractor.calls.count == 1)
        }

        r.run("manual re-extraction never calls the Screener") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            let screener = FakeScreener()
            let extractor = FakeIntentExtractor(responses: ["can you book the flights": "Book the flights"])
            await reExtractThroughIntake(
                messages: [received("m1", chatId: 1, text: "can you book the flights")],
                deps: deps(store: store, extractor: extractor, screener: screener, mode: .shadow)
            )
            try expect(screener.inputs.isEmpty)
            try expect(extractor.calls.count == 1)
        }

        r.run("the Screening input uses Participant Labels, never a sender address, and carries no Corrections") {
            let screener = FakeScreener()
            let corrections = FakeCorrectionStore()
            try corrections.record(Correction(chatId: 9, inputText: "grab snacks", correctedOutput: "NONE", correctionType: .falsePositive))
            let earlier = ChatMessage(
                id: "m0", chatId: 9, isFromMe: false, text: "can you grab milk",
                createdAt: Date().addingTimeInterval(-60), senderAddress: "+15550001111"
            )
            let target = received("m1", chatId: 9, text: "also grab bread", sender: "+15550001111")
            _ = await refreshThroughIntake(
                from: [earlier, target],
                deps: ExtractionDependencies(
                    store: makeTestSignalStore(), extractor: FakeIntentExtractor(responses: [:]), correctionStore: corrections,
                    screener: screener, screeningMode: .shadow
                )
            )
            let input = try require(screener.inputs.last)
            try expect(input.text.contains("Participant A: also grab bread"), "got \(input.text)")
            try expect(!input.text.contains("+1555"), "a phone number must never leave the Mac")
            try expect(!input.text.contains("[corrections]"))
        }
    }

    runner.suite("JEV request and response") { r in
        r.run("the request asks one Yes/No question about the rendered message") {
            let body = try jevRequestBody(for: ScreeningInput(text: "Participant A: can you book the flights"))
            let json = try require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            try expect(json["state"] as? String == "Participant A: can you book the flights")
            try expect(json["model"] as? String == jevModelID)
            let questions = try require(json["questions"] as? [String: Any])
            let question = try require(questions[jevQuestionKey] as? [String: Any])
            try expect(question["type"] as? String == "noul")
            try expect(question["instructions"] as? String == screeningQuestion)
        }

        r.run("a noul answer parses to its probability") {
            let data = Data(#"{"model":"jev-1.13.0","answers":{"asks_for_action":{"type":"noul","noul":0.95}}}"#.utf8)
            let probability = try parseJevProbability(data)
            try expect(probability == 0.95)
        }

        r.run("a response without the answer, or out of range, is an error") {
            let missing = Data(#"{"model":"jev-1.13.0","answers":{}}"#.utf8)
            let outOfRange = Data(#"{"answers":{"asks_for_action":{"type":"noul","noul":1.4}}}"#.utf8)
            for data in [missing, outOfRange, Data("not json".utf8)] {
                var threw = false
                do { _ = try parseJevProbability(data) } catch { threw = true }
                try expect(threw)
            }
        }
    }

    runner.suite("screeningFailureReason") { r in
        r.run("names the kind of failure in plain words") {
            try expect(screeningFailureReason(URLError(.timedOut)) == "timed out")
            try expect(screeningFailureReason(URLError(.notConnectedToInternet)) == "no network connection")
            try expect(screeningFailureReason(URLError(.cannotFindHost)).hasPrefix("network error"))
            try expect(screeningFailureReason(JEVResponseError.httpStatus(401)) == "HTTP 401: API key rejected")
            try expect(screeningFailureReason(JEVResponseError.httpStatus(429)) == "HTTP 429: rate limited")
            try expect(screeningFailureReason(JEVResponseError.httpStatus(529)) == "HTTP 529: TypeSafe overloaded")
            try expect(screeningFailureReason(JEVResponseError.httpStatus(422)) == "HTTP 422: request rejected")
            try expect(screeningFailureReason(JEVResponseError.malformed) == "unreadable response")
        }
    }

    runner.suite("Screening settings") { r in
        r.run("Screening is off by default, in shadow mode") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            try expect(!settings.isEnabled)
            try expect(settings.mode == .shadow)
        }

        r.run("the pipeline mode is off until Screening is enabled and a key exists") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let keys = FakeAPIKeyStore()
            try expect(effectiveScreeningMode(settings: settings, apiKey: keys.read()) == .off)
            settings.isEnabled = true
            try expect(effectiveScreeningMode(settings: settings, apiKey: keys.read()) == .off, "no key, no Screening")
            try keys.write("tsk-123")
            try expect(effectiveScreeningMode(settings: settings, apiKey: keys.read()) == .shadow)
            try keys.write("   ")
            try expect(effectiveScreeningMode(settings: settings, apiKey: keys.read()) == .off, "a blank key counts as none")
        }
    }

    runner.suite("ScreeningSettingsViewModel") { r in
        r.run("enabling Screening and saving a key reaches Intake, and the key goes to the key store, not preferences") {
            let suite = "FirstFocusTests-\(UUID().uuidString)"
            let keys = FakeAPIKeyStore()
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: suite)!)
            let extraction = await MainActor.run { TestExtraction(keyStore: keys, screeningSettings: settings) }
            let viewModel = await MainActor.run {
                ScreeningSettingsViewModel(settings: settings, keyStore: keys, extraction: extraction.host)
            }
            await MainActor.run {
                viewModel.apiKeyDraft = "tsk-123"
                viewModel.saveAPIKey()
                viewModel.isEnabled = true
            }
            try expect(keys.key == "tsk-123")
            try expect(!UserDefaults(suiteName: suite)!.dictionaryRepresentation().values.contains { ($0 as? String) == "tsk-123" })
            try await MainActor.run {
                try expect(extraction.intake.screeningMode == .shadow, "got \(extraction.intake.screeningMode)")
                try expect(extraction.intake.screener != nil)
                try expect(viewModel.hasAPIKey)
                try expect(viewModel.apiKeyDraft.isEmpty, "the field clears once the key is stored")
            }
        }

        r.run("removing the key turns Screening back to local-only") {
            let keys = FakeAPIKeyStore(key: "tsk-123")
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let extraction = await MainActor.run { TestExtraction(keyStore: keys, screeningSettings: settings) }
            let viewModel = await MainActor.run {
                ScreeningSettingsViewModel(settings: settings, keyStore: keys, extraction: extraction.host)
            }
            try await MainActor.run {
                extraction.host.applyScreeningSettings()
                try expect(extraction.intake.screeningMode != .off)
                viewModel.removeAPIKey()
            }
            try expect(keys.key == nil)
            try await MainActor.run {
                try expect(extraction.intake.screeningMode == .off)
                try expect(extraction.intake.screener == nil)
            }
        }

        r.run("cancelling key entry throws away what was typed and leaves the stored key alone") {
            let keys = FakeAPIKeyStore(key: "tsk-123")
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
            let extraction = await MainActor.run { TestExtraction(keyStore: keys, screeningSettings: settings) }
            let viewModel = await MainActor.run {
                ScreeningSettingsViewModel(settings: settings, keyStore: keys, extraction: extraction.host)
            }
            await MainActor.run {
                viewModel.apiKeyDraft = "tsk-typo"
                viewModel.cancelKeyEntry()
            }
            try expect(keys.key == "tsk-123")
            try await MainActor.run {
                try expect(viewModel.apiKeyDraft.isEmpty)
                try expect(viewModel.hasAPIKey)
                try expect(extraction.screenersBuilt == 0, "nothing reached Screening")
            }
        }
    }
}

func registerScreeningAppModelTests(_ runner: TestRunner) {
    runner.suite("AppModel: Screening settings reach intake") { r in
        r.run("with Screening enabled and a key stored, the launch pass asks the Screener; with neither, it doesn't") {
            for enabled in [true, false] {
                let screener = FakeScreener(probability: 0.4)
                let extractor = GatedIntentExtractor()
                extractor.open()
                let suite = "FirstFocusTests-\(UUID().uuidString)"
                let model = await MainActor.run { () -> AppModel in
                    let defaults = UserDefaults(suiteName: suite)!
                    let settings = ScreeningSettings(defaults: defaults)
                    settings.isEnabled = enabled
                    return AppModel(AppDependencies.test { d in
                        d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                        d.messagesSource = FakeMessagesSource(messages: [
                            ChatMessage(id: "m1", chatId: 1, isFromMe: false, text: "can you book the flights", createdAt: Date()),
                        ])
                        d.signalStore = makeTestSignalStore()
                        d.contactsResolver = FakeContactsResolver()
                        d.settingsOpener = FakeSettingsOpener()
                        d.refreshClock = FakeRefreshClock()
                        d.eventKitChanges = FakeEventKitChangeObserver()
                        d.foregroundObserver = FakeForegroundObserver()
                        d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                        d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                        d.loadModel = { _, _ in extractor }
                        d.historyStore = makeTestHistoryStore()
                        d.correctionStore = FakeCorrectionStore()
                        d.screeningSettings = settings
                        d.apiKeyStore = FakeAPIKeyStore(key: enabled ? "tsk-123" : nil)
                        d.makeScreener = { _ in screener }
                        d.bundlePath = "/nonexistent"
                    })
                }
                await model.start()
                try expect(screener.inputs.count == (enabled ? 1 : 0), "enabled=\(enabled): got \(screener.inputs.count) Screening calls")
                try expect(extractor.calls.count == 1, "shadow or off, the model still sees the message")
            }
        }
    }
}
