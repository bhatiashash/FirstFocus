import DailyOSApp
import DailyOSCore
import Foundation

// screening-optional: DailyOS works with and without Jev.

private func received(_ id: String, chatId: Int, text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: false, text: text, createdAt: Date(), senderAddress: "+15550001111")
}

/// Three Batches, one per Chat, each worth a model call.
private let threeBatches = [
    received("m1", chatId: 1, text: "can you book the flights"),
    received("m2", chatId: 2, text: "can you call the plumber"),
    received("m3", chatId: 3, text: "can you send the invoice"),
]

private func threeBatchExtractor() -> FakeIntentExtractor {
    FakeIntentExtractor(responses: [
        "can you book the flights": "Book the flights",
        "can you call the plumber": "Call the plumber",
        "can you send the invoice": "Send the invoice",
    ])
}

/// Runs one refresh over `threeBatches` and returns what reached the model
/// and what History holds.
private func runMatrixCase(
    screener: FakeScreener?, mode: ScreeningMode
) async -> (extractor: FakeIntentExtractor, history: SQLiteHistoryStore, store: SQLiteSignalStore) {
    let store = makeTestSignalStore()
    let history = makeTestHistoryStore()
    let extractor = threeBatchExtractor()
    _ = await refreshThroughIntake(
        from: threeBatches, store: store, extractor: extractor,
        fixture: IntakeFixture(historyStore: history, screener: screener, screeningMode: mode, auditRoll: { 0.99 })
    )
    return (extractor, history, store)
}

func registerScreeningOptionalIntakeTests(_ runner: TestRunner) {
    runner.suite("screening-optional: intake with no Jev, a failing Jev and a working Jev") { r in
        r.run("no Screener: every Batch reaches the model and History holds only model calls") {
            let result = await runMatrixCase(screener: nil, mode: .off)
            try expect(result.extractor.calls.count == 3)
            try expect(result.history.allRows().allSatisfy { $0.kind == .extraction })
            try expect(result.store.openSignals().count == 3)
        }

        r.run("a Screener that always fails: every Batch reaches the model, each with a Screening failed row") {
            let screener = FakeScreener(failure: URLError(.timedOut))
            let result = await runMatrixCase(screener: screener, mode: .live(cutoff: 0.5))
            try expect(result.extractor.calls.count == 3)
            let failures = result.history.allRows().filter { $0.kind == .screeningFailed(reason: "timed out") }
            try expect(failures.count == 3, "got \(result.history.allRows().map(\.kind))")
            try expect(result.store.openSignals().count == 3)
        }

        r.run("a Screener that fails once then recovers: every Batch reaches the model; one failed row, then Screening rows") {
            let screener = FakeScreener(probability: 0.9)
            screener.script([.fail(URLError(.timedOut))])
            let result = await runMatrixCase(screener: screener, mode: .live(cutoff: 0.5))
            try expect(result.extractor.calls.count == 3)
            try expect(result.history.allRows().filter { $0.kind == .screeningFailed(reason: "timed out") }.count == 1)
            try expect(result.history.allRows().filter(\.isScreening).count == 2)
        }

        r.run("a Screener that scores every Batch above the cutoff: all reach the model, each with a Screening row") {
            let screener = FakeScreener(probability: 0.9)
            let result = await runMatrixCase(screener: screener, mode: .live(cutoff: 0.5))
            try expect(result.extractor.calls.count == 3)
            try expect(result.history.allRows().filter(\.isScreening).count == 3)
            try expect(result.store.openSignals().count == 3)
        }

        r.run("a Screener that scores every Batch below the cutoff: none reach the model, all are Screened") {
            let screener = FakeScreener(probability: 0.1)
            let result = await runMatrixCase(screener: screener, mode: .live(cutoff: 0.5))
            try expect(result.extractor.calls.isEmpty)
            try expect(result.history.allRows().filter(\.wasScreened).count == 3)
            try expect(result.store.openSignals().isEmpty)
        }
    }

    runner.suite("screening-optional: a Screening change applies from the next Batch") { r in
        r.run("turning Screening off during a pass sends none of the remaining Batches to the Screener") {
            let store = makeTestSignalStore()
            let extractor = threeBatchExtractor()
            let screener = FakeScreener(probability: 0.9)
            let intake = await makeIntake(
                over: threeBatches, store: store, extractor: extractor,
                fixture: IntakeFixture(screener: screener, screeningMode: .shadow)
            )
            screener.onCall = {
                await MainActor.run {
                    intake.screener = nil
                    intake.screeningMode = .off
                }
            }
            _ = await intake.refresh(now: quietAfter(threeBatches))
            try expect(screener.inputs.count == 1, "got \(screener.inputs.count) Screening calls")
            try expect(extractor.calls.count == 3)
        }

        r.run("turning Screening on during a pass screens the next Batch") {
            let store = makeTestSignalStore()
            let extractor = threeBatchExtractor()
            let screener = FakeScreener(probability: 0.9)
            let intake = await makeIntake(over: threeBatches, store: store, extractor: extractor)
            extractor.onExtract = {
                await MainActor.run {
                    intake.screener = screener
                    intake.screeningMode = .shadow
                }
            }
            _ = await intake.refresh(now: quietAfter(threeBatches))
            try expect(screener.inputs.count == 2, "got \(screener.inputs.count) Screening calls")
            try expect(extractor.calls.count == 3)
        }
    }
}

/// The keys `makeScreener` was called with, in order.
private final class BuiltKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var keys: [String] { lock.withLock { recorded } }
    func append(_ key: String) { lock.withLock { recorded.append(key) } }
}

/// A clock a test moves by hand, readable from any thread.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) { lock.withLock { current += interval } }
}

/// `count` Batches, one per Chat, all long since quiet.
private func quietBatches(_ count: Int, startingAt first: Int = 1) -> [ChatMessage] {
    (first..<(first + count)).map { n in
        ChatMessage(
            id: "m\(n)", chatId: n, isFromMe: false, text: "can you book the flights \(n)",
            createdAt: Date().addingTimeInterval(-600), senderAddress: "+15550001111"
        )
    }
}

private func kinds(_ history: SQLiteHistoryStore, _ storageName: String) -> Int {
    history.allRows().filter { $0.kind.storageName == storageName }.count
}

func registerScreeningBreakerTests(_ runner: TestRunner) {
    runner.suite("screening-optional: the circuit breaker stops calling a failing Jev") { r in
        @Sendable func runPass(
            _ screener: FakeScreener, batches: Int, clock: ManualClock = ManualClock()
        ) async -> (history: SQLiteHistoryStore, extractor: FakeIntentExtractor) {
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor()
            let messages = quietBatches(batches)
            _ = await refreshThroughIntake(
                from: messages, store: makeTestSignalStore(), extractor: extractor,
                fixture: IntakeFixture(
                    historyStore: history, screener: ScreeningBreaker(screener: screener, now: { clock.date }),
                    screeningMode: .shadow
                ),
                now: Date()
            )
            return (history, extractor)
        }

        r.run("trips on the third timeout in a row, not the second") {
            let screener = FakeScreener(failure: URLError(.timedOut))
            let result = await runPass(screener, batches: 5)
            try expect(screener.inputs.count == 3, "got \(screener.inputs.count) calls")
            try expect(kinds(result.history, "screening_failed") == 3)
            try expect(kinds(result.history, "screening_unavailable") == 2)
            try expect(result.extractor.calls.count == 5, "every Batch still reaches the model")
        }

        for status in [401, 403] {
            r.run("trips on the first HTTP \(status)") {
                let screener = FakeScreener(failure: JEVResponseError.httpStatus(status))
                let result = await runPass(screener, batches: 3)
                try expect(screener.inputs.count == 1, "got \(screener.inputs.count) calls")
                try expect(kinds(result.history, "screening_failed") == 1, "the tripping failure keeps its row")
                try expect(kinds(result.history, "screening_unavailable") == 2)
                try expect(result.extractor.calls.count == 3)
            }
        }

        r.run("a 5xx and a malformed reply count toward the three") {
            let screener = FakeScreener()
            screener.script([.fail(JEVResponseError.httpStatus(503)), .fail(JEVResponseError.malformed), .fail(JEVResponseError.httpStatus(429))])
            let result = await runPass(screener, batches: 4)
            try expect(screener.inputs.count == 3)
            try expect(kinds(result.history, "screening_unavailable") == 1)
        }

        r.run("an answer between failures resets the count") {
            let screener = FakeScreener()
            let timeout = FakeScreener.Outcome.fail(URLError(.timedOut))
            screener.script([timeout, timeout, .answer, timeout, timeout])
            let result = await runPass(screener, batches: 5)
            try expect(screener.inputs.count == 5)
            try expect(kinds(result.history, "screening_unavailable") == 0)
        }

        r.run("stays open for 15 minutes, then calls Jev again") {
            let clock = ManualClock()
            let screener = FakeScreener(failure: JEVResponseError.httpStatus(401))
            let breaker = ScreeningBreaker(screener: screener, now: { clock.date })
            let store = makeTestSignalStore()
            try store.markBackfillComplete()
            try store.recordNonSelfMessagesCutoff(.distantPast)
            let messagesSource = FakeMessagesSource(messages: quietBatches(1))
            let intake = await MainActor.run {
                let intake = MessagesIntake(
                    messagesSource: messagesSource, signalStore: store, contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: FakeIntentExtractor()
                )
                intake.screener = breaker
                intake.screeningMode = .shadow
                return intake
            }
            _ = await intake.refresh(now: Date())
            try expect(screener.inputs.count == 1)

            clock.advance(by: 14 * 60)
            messagesSource.messages += quietBatches(1, startingAt: 2)
            _ = await intake.refresh(now: Date())
            try expect(screener.inputs.count == 1, "still open at 14 minutes")

            clock.advance(by: 60)
            messagesSource.messages += quietBatches(1, startingAt: 3)
            _ = await intake.refresh(now: Date())
            try expect(screener.inputs.count == 2, "calls Jev again at 15 minutes")
        }
    }

    runner.suite("screening-optional: saving the key or flipping the toggle closes the breaker") { r in
        struct Harness: @unchecked Sendable {
            let model: AppModel
            let viewModel: ScreeningSettingsViewModel
            let source: FakeMessagesSource
            let screener: FakeScreener
        }

        @Sendable func makeHarness() async -> Harness {
            await MainActor.run {
                let defaults = throwawayDefaults()
                let settings = ScreeningSettings(defaults: defaults)
                settings.isEnabled = true
                let store = makeTestSignalStore()
                try? store.markBackfillComplete()
                try? store.recordNonSelfMessagesCutoff(.distantPast)
                let source = FakeMessagesSource(messages: quietBatches(2))
                let screener = FakeScreener(failure: JEVResponseError.httpStatus(401))
                let keys = FakeAPIKeyStore(key: "tsk-1")
                let model = AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = source
                    d.signalStore = store
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                    d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                    d.extractor = FakeIntentExtractor()
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.screeningSettings = settings
                    d.apiKeyStore = keys
                    d.makeScreener = { _ in screener }
                    d.bundlePath = "/nonexistent"
                })
                let viewModel = ScreeningSettingsViewModel(settings: settings, keyStore: keys, app: model)
                return Harness(model: model, viewModel: viewModel, source: source, screener: screener)
            }
        }

        r.run("a rejected key trips the breaker for later passes") {
            let h = await makeHarness()
            await h.model.start()
            try expect(h.screener.inputs.count == 1)
            h.source.messages += quietBatches(1, startingAt: 10)
            await h.model.reloadMessages()
            try expect(h.screener.inputs.count == 1, "the next pass skips Jev too")
        }

        r.run("saving the key, even the same one, calls Jev on the next Batch") {
            let h = await makeHarness()
            await h.model.start()
            await MainActor.run {
                h.viewModel.apiKeyDraft = "tsk-1"
                h.viewModel.saveAPIKey()
            }
            h.source.messages += quietBatches(1, startingAt: 10)
            await h.model.reloadMessages()
            try expect(h.screener.inputs.count == 2, "got \(h.screener.inputs.count)")
        }

        r.run("flipping the toggle off and on calls Jev on the next Batch") {
            let h = await makeHarness()
            await h.model.start()
            await MainActor.run {
                h.viewModel.isEnabled = false
                h.viewModel.isEnabled = true
            }
            h.source.messages += quietBatches(1, startingAt: 10)
            await h.model.reloadMessages()
            try expect(h.screener.inputs.count == 2, "got \(h.screener.inputs.count)")
        }

        r.run("removing the key and saving it again calls Jev on the next Batch") {
            let h = await makeHarness()
            await h.model.start()
            await MainActor.run {
                h.viewModel.removeAPIKey()
                h.viewModel.apiKeyDraft = "tsk-1"
                h.viewModel.saveAPIKey()
            }
            h.source.messages += quietBatches(1, startingAt: 10)
            await h.model.reloadMessages()
            try expect(h.screener.inputs.count == 2, "got \(h.screener.inputs.count)")
        }

        r.run("a different key reaching intake gets a Screener of its own, whatever path it took") {
            let keys = FakeAPIKeyStore(key: "tsk-1")
            let built = BuiltKeys()
            let model = await MainActor.run { () -> AppModel in
                let defaults = throwawayDefaults()
                let settings = ScreeningSettings(defaults: defaults)
                settings.isEnabled = true
                return AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource()
                    d.signalStore = makeTestSignalStore()
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                    d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                    d.extractor = FakeIntentExtractor()
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.screeningSettings = settings
                    d.apiKeyStore = keys
                    d.makeScreener = { key in
                        built.append(key)
                        return FakeScreener()
                    }
                    d.bundlePath = "/nonexistent"
                })
            }
            await MainActor.run {
                model.applyScreeningSettings()
                keys.key = "tsk-2"
                model.applyScreeningSettings()
            }
            try expect(built.keys == ["tsk-1", "tsk-2"], "got \(built.keys)")
        }

        r.run("setting a cutoff leaves the breaker open") {
            let h = await makeHarness()
            await h.model.start()
            await MainActor.run { h.viewModel.setCutoff(0.4) }
            h.source.messages += quietBatches(1, startingAt: 10)
            await h.model.reloadMessages()
            try expect(h.screener.inputs.count == 1, "got \(h.screener.inputs.count)")
        }
    }
}

func registerScreeningUnavailableHistoryTests(_ runner: TestRunner) {
    runner.suite("screening-optional: History shows Screening Unavailable") { r in
        r.run("the Inspector says Screening unavailable, and the row gets no badge for it") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    HistoryEntry(
                        timestamp: hoursAgo(2), sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 1,
                        kind: .screeningUnavailable, sourceRef: "m1"
                    ),
                    extractionEntry(ref: "m1", output: "NONE", at: hoursAgo(1)),
                ])
                let batch = try require(viewModel.selectedBatch)
                let inspection = viewModel.inspection(for: batch)
                try expect(inspection.screeningUnavailable)
                try expect(inspection.screening == nil && inspection.screeningFailure == nil)
                try expect(viewModel.badges(for: batch).isEmpty, "got \(viewModel.badges(for: batch).map(\.text))")
                try expect(batch.resultSummary == "The model found no task.")
            }
        }
    }
}

/// History holding Jev-era rows: a Screened Batch the model never saw
/// (with a transcript, so Add Task can use it), a Borderline Batch where
/// the model found nothing, and a Batch whose Screening failed before the
/// model found a task. Cutoff 0.4, so 0.45 is Borderline.
@MainActor
private func jevEraHistory(screeningOn: Bool, unfiltered: Bool = true) throws -> (HistoryViewModel, HistoryApp) {
    let app = makeHistoryApp()
    let settings = app.screeningSettings
    settings.isEnabled = screeningOn
    settings.cutoff = 0.4
    let screened = HistoryEntry(
        timestamp: hoursAgo(3), sourceRawText: "can you book the flights", modelUsed: "JEV", signalCount: 0, chatId: 1,
        renderedContext: "[latest messages]\nParticipant A: can you book the flights",
        kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "screened",
        sender: "Mom", transcript: [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "can you book the flights", sentAt: hoursAgo(3))]
    )
    for entry in [
        screened,
        screeningEntry(ref: "borderline", probability: 0.45, at: hoursAgo(2.5), chatId: 2),
        extractionEntry(ref: "borderline", output: "NONE", at: hoursAgo(2.4), chatId: 2),
        HistoryEntry(
            timestamp: hoursAgo(2), sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 3,
            kind: .screeningFailed(reason: "timed out"), sourceRef: "failed"
        ),
        extractionEntry(ref: "failed", output: "Call the dentist", at: hoursAgo(1.9), chatId: 3),
    ] {
        try app.history.record(entry)
    }
    let viewModel = app.viewModel(now: { dashboardNow }, calendar: dashboardCalendar)
    viewModel.showsUnfilteredLog = unfiltered
    return (viewModel, app)
}

@MainActor
private func batch(_ id: String, in viewModel: HistoryViewModel) throws -> HistoryBatch {
    try require(viewModel.batches.first { $0.sourceRef == id }, "no Batch \(id) listed")
}

func registerScreeningToggleHistoryTests(_ runner: TestRunner) {
    runner.suite("screening-optional: the Screening toggle hides Screening in History") { r in
        r.run("toggle off: no Borderline view, no Screening counts, badges or This was work") {
            try await MainActor.run {
                let (viewModel, app) = try jevEraHistory(screeningOn: false)
                try expect(!viewModel.segments.contains(.borderline))
                try expect(viewModel.weekCounts == "3 Batches · 1 with a task", "got \(viewModel.weekCounts)")
                try expect(viewModel.borderlineCountThisWeek == 0)

                let screened = try batch("screened", in: viewModel)
                let borderline = try batch("borderline", in: viewModel)
                let failed = try batch("failed", in: viewModel)
                try expect(viewModel.badges(for: borderline).isEmpty)
                try expect(viewModel.badges(for: failed).map(\.text) == ["Task"])

                try expect(viewModel.resultSummary(for: screened) == "Not read by the model.")
                try expect(viewModel.rawOutputToCopy(for: screened) == "", "Jev's output is Screening data")
                try expect(viewModel.offers(for: screened)[.thisWasWork] == nil)
            }
        }

        r.run("toggle off: the Inspector still shows the Screening each Batch stored") {
            try await MainActor.run {
                let (viewModel, _) = try jevEraHistory(screeningOn: false, unfiltered: true)
                let screened = try batch("screened", in: viewModel)
                let failed = try batch("failed", in: viewModel)
                try expect(viewModel.inspection(for: screened).screening?.probability == 0.1)
                try expect(viewModel.inspection(for: screened).prompt == "[latest messages]\nParticipant A: can you book the flights")
                try expect(viewModel.inspection(for: failed).screeningFailure?.reason == "timed out")
            }
        }

        r.run("toggle on, even with no key: everything Screening shows, as stored") {
            try await MainActor.run {
                let (viewModel, app) = try jevEraHistory(screeningOn: true)
                try expect(viewModel.segments.contains(.borderline))
                try expect(
                    viewModel.weekCounts == "3 Batches · 1 with a task · 1 Screened · 1 Borderline", "got \(viewModel.weekCounts)"
                )
                try expect(viewModel.borderlineCountThisWeek == 1)

                let screened = try batch("screened", in: viewModel)
                let borderline = try batch("borderline", in: viewModel)
                let failed = try batch("failed", in: viewModel)
                try expect(viewModel.badges(for: borderline).map(\.text) == ["Borderline 0.45"])
                try expect(viewModel.badges(for: failed).map(\.text) == ["Screening failed"])
                try expect(viewModel.inspection(for: screened).screening?.probability == 0.1)
                try expect(viewModel.inspection(for: failed).screeningFailure?.reason == "timed out")
                try expect(viewModel.resultSummary(for: screened) == "Screened at 0.10, below the 0.40 cutoff.")
                try expect(viewModel.rawOutputToCopy(for: screened) == screened.rawOutputToCopy)
                try expect(viewModel.offers(for: screened)[.thisWasWork] == .enabled)
                try expect(viewModel.offers(for: screened)[.addTask] == nil)
            }
        }

        r.run("turning the toggle off and on again brings Screening back unchanged") {
            try await MainActor.run {
                let (viewModel, app) = try jevEraHistory(screeningOn: true)
                let failed = try batch("failed", in: viewModel)
                let screened = try batch("screened", in: viewModel)
                let settings = ScreeningSettingsViewModel(settings: app.screeningSettings, keyStore: FakeAPIKeyStore(), app: app.model)
                settings.isEnabled = false
                try expect(viewModel.badges(for: failed).map(\.text) == ["Task"])
                settings.isEnabled = true
                try expect(viewModel.badges(for: failed).map(\.text) == ["Screening failed"])
                try expect(viewModel.inspection(for: screened).screening?.probability == 0.1)
            }
        }

        r.run("with the toggle off, Borderline is no reason for Overview to list a Batch") {
            try await MainActor.run {
                let (off, _) = try jevEraHistory(screeningOn: false, unfiltered: false)
                try expect(off.batches.map(\.sourceRef) == ["failed"], "got \(off.batches.map(\.sourceRef))")
                let (on, _) = try jevEraHistory(screeningOn: true, unfiltered: false)
                try expect(Set(on.batches.compactMap(\.sourceRef)) == ["failed", "borderline"], "got \(on.batches.map(\.sourceRef))")
            }
        }

        r.run("a Borderline view left selected falls back to Overview when the toggle goes off") {
            try await MainActor.run {
                let (viewModel, app) = try jevEraHistory(screeningOn: true)
                viewModel.segment = .borderline
                let settings = ScreeningSettingsViewModel(settings: app.screeningSettings, keyStore: FakeAPIKeyStore(), app: app.model)
                settings.isEnabled = false
                try expect(viewModel.segment == .overview)
            }
        }

        r.run("with the toggle off, Add Task on a Screened Batch records a missed task and adds a Suggestion") {
            let (app, viewModel, screened) = try await MainActor.run { () -> (HistoryApp, HistoryViewModel, HistoryBatch) in
                let (viewModel, app) = try jevEraHistory(screeningOn: false)
                return (app, viewModel, try batch("screened", in: viewModel))
            }
            try await MainActor.run {
                try expect(viewModel.offers(for: screened)[.addTask] == .enabled)
                app.actions.addTask("Book the flights", to: screened)
                try expect(app.model.rankedList.suggested.map(\.label) == ["Book the flights"])
                try expect(app.model.corrections.types(forBatches: ["screened"])["screened"] == [.missedTask])
                try expect(viewModel.offers(for: screened)[.addTask] == .taken)
            }
        }
    }
}

func registerScreeningKeylessSettingsTests(_ runner: TestRunner) {
    runner.suite("screening-optional: Advanced with the toggle on and no key") { r in
        r.run("Tune Cutoff is disabled with a prompt for the key until one is saved") {
            try await MainActor.run {
                let settings = ScreeningSettings(defaults: throwawayDefaults())
                settings.isEnabled = true
                let viewModel = ScreeningSettingsViewModel(
                    settings: settings, keyStore: FakeAPIKeyStore(), app: FakeScreeningConfiguring()
                )
                try expect(!viewModel.canTuneCutoff)
                try expect(viewModel.tuneCutoffHint == "Add a key to tune the cutoff.")
                viewModel.apiKeyDraft = "tsk-1"
                viewModel.saveAPIKey()
                try expect(viewModel.canTuneCutoff)
                try expect(viewModel.tuneCutoffHint == nil)
                viewModel.removeAPIKey()
                try expect(!viewModel.canTuneCutoff)
            }
        }
    }
}
