import FirstFocusCore
import Foundation

// intake-runner: every Messages Intake pass, run by `IntakeRunner` on a
// fake Messages source and a test store, with its result on the Signal
// Board. No AppModel.

private final class Moment: @unchecked Sendable {
    var date = Date()
}

private func selfNote(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: 1, isFromMe: true, text: text, createdAt: Date().addingTimeInterval(-60))
}

private struct Harness: @unchecked Sendable {
    let runner: IntakeRunner
    let board: SignalBoard
    let store: SQLiteSignalStore
    let host: ExtractionHost
    let source: FakeMessagesSource
    let settings: ReExtractionSettings
    let moment: Moment
}

private func isolated() -> UserDefaults {
    UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
}

@MainActor
private func makeHarness(
    messages: [ChatMessage] = [selfNote("m1", "call the dentist")], availability: SourceAvailability = .available,
    extractor: any IntentExtractor = FakeIntentExtractor(defaultResponse: "Call the dentist"), backfillDone: Bool = true
) -> Harness {
    let store = makeTestSignalStore()
    if backfillDone { try? store.markBackfillComplete() }
    try? store.recordNonSelfMessagesCutoff(.distantPast)
    let source = FakeMessagesSource(messages: messages, availability: availability)
    let intake = MessagesIntake(
        messagesSource: source, signalStore: store, contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent"
    )
    let host = ExtractionHost(
        intake: intake, loader: { _, _ in extractor }, extractionSettings: ExtractionSettings(defaults: isolated()),
        bundleIdentifier: "FirstFocusTests", ruleStore: FakeRuleStore(), corrections: Corrections(store: FakeCorrectionStore()),
        screeningSettings: ScreeningSettings(defaults: isolated()), apiKeyStore: FakeAPIKeyStore(),
        makeScreener: { _ in FakeScreener() }
    )
    let board = SignalBoard(taskSource: FakeTaskSource(), signalStore: store, snoozes: Snoozes(store: store))
    let settings = ReExtractionSettings(defaults: isolated())
    let moment = Moment()
    let runner = IntakeRunner(
        intake: intake, board: board, extraction: host, reExtractionSettings: settings, now: { moment.date }
    )
    return Harness(runner: runner, board: board, store: store, host: host, source: source, settings: settings, moment: moment)
}

@MainActor
private func labels(_ board: SignalBoard) -> [String] {
    let list = board.rankedList(now: Date())
    return (list.focus + list.later + list.suggested).map(\.label)
}

func registerIntakeRunnerTests(_ runner: TestRunner) {
    runner.suite("IntakeRunner: the live pass") { r in
        r.run("a pass's Signals reach the Board") {
            let h = await makeHarness()
            await h.host.load()
            await h.runner.refresh()
            let found = await labels(h.board)
            try expect(found == ["Call the dentist"], "got \(found)")
        }

        r.run("a running pass is reported, holds Rule proposals back, and clears after") {
            let extractor = GatedIntentExtractor()
            let h = await makeHarness(extractor: extractor)
            await h.host.load()
            let pass = Task { await h.runner.refresh() }
            let reached = await waitUntil { extractor.calls.count == 1 }
            try expect(reached)
            try await MainActor.run {
                try expect(h.runner.runningPass == .automatic)
                try expect(h.host.ruleProposalStatus() == .passRunning)
            }
            extractor.open()
            await pass.value
            try await MainActor.run { try expect(h.runner.runningPass == nil) }
        }

        r.run("a first-run backfill reports progress, and clears it when done") {
            let extractor = GatedIntentExtractor()
            let h = await makeHarness(extractor: extractor, backfillDone: false)
            await h.host.load()
            let pass = Task { await h.runner.refresh() }
            let reached = await waitUntil { extractor.calls.count == 1 }
            try expect(reached)
            let reported = await waitUntilOnMainActor { h.runner.backfillProgress != nil }
            try expect(reported, "progress shows while the backfill runs")
            extractor.open()
            await pass.value
            try await MainActor.run { try expect(h.runner.backfillProgress == nil) }
        }

        r.run("Messages that can't be read show as Unavailable") {
            let h = await makeHarness(availability: .unavailable)
            await h.runner.refresh()
            try await MainActor.run { try expect(h.runner.messagesUnavailable) }
        }

        r.run("extract-now waits for a running pass, then runs its own (ADR 0034)") {
            let extractor = GatedIntentExtractor()
            let h = await makeHarness(extractor: extractor)
            await h.host.load()
            let pass = Task { await h.runner.refresh() }
            let reached = await waitUntil { extractor.calls.count == 1 }
            try expect(reached)
            let explicit = Task { await h.runner.extractNow(sourceRef: "m1") }
            try await MainActor.run { try expect(h.runner.runningPass == .automatic, "it waits") }
            extractor.open()
            await pass.value
            await explicit.value
            try await MainActor.run { try expect(h.runner.runningPass == nil) }
        }
    }

    runner.suite("IntakeRunner: re-extraction and whether it's allowed") { r in
        r.run("with nothing running and no recent run, Re-extract is allowed") {
            let h = await makeHarness()
            await h.host.load()
            try await MainActor.run { try expect(h.runner.canReExtract) }
        }

        r.run("a re-extraction records its start at the injected moment and clears its progress") {
            let h = await makeHarness()
            await h.host.load()
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            h.moment.date = start
            await h.runner.reExtract()
            try await MainActor.run {
                try expect(h.settings.lastRunAt == start)
                try expect(h.runner.reExtractionProgress == nil)
            }
        }

        r.run("re-extraction progress shows while it runs, refuses another, and clears") {
            // Two Batches judged before with nothing found, so both are
            // candidates; the model answers the first and holds the second.
            let gate = SecondCallGate()
            let extractor = FakeIntentExtractor()
            extractor.onExtract = { await gate.pass() }
            let h = await makeHarness(
                messages: [selfNote("m1", "call the dentist"), ChatMessage(
                    id: "m2", chatId: 2, isFromMe: true, text: "book flights", createdAt: Date().addingTimeInterval(-60)
                )],
                extractor: extractor
            )
            try await MainActor.run {
                try h.store.recordOneMessageBatch("m1", chatId: 1, signals: [])
                try h.store.recordOneMessageBatch("m2", chatId: 2, signals: [])
            }
            await h.host.load()
            let run = Task { await h.runner.reExtract() }
            let reported = await waitUntilOnMainActor { h.runner.reExtractionProgress != nil }
            try expect(reported, "progress shows while it runs")
            try await MainActor.run { try expect(!h.runner.canReExtract) }
            gate.open()
            await run.value
            try await MainActor.run {
                try expect(h.runner.reExtractionProgress == nil)
                try expect(h.runner.runningPass == nil)
            }
        }

        r.run("a second click while a re-extraction waits behind a pass starts nothing") {
            let extractor = GatedIntentExtractor()
            let h = await makeHarness(extractor: extractor)
            await h.host.load()
            let pass = Task { await h.runner.refresh() }
            let reached = await waitUntil { extractor.calls.count == 1 }
            try expect(reached)
            let first = Date(timeIntervalSince1970: 1_790_000_000)
            h.moment.date = first
            let queued = Task { await h.runner.reExtract() }
            await MainActor.run {}
            h.moment.date = first.addingTimeInterval(60)
            await h.runner.reExtract()
            try await MainActor.run { try expect(h.settings.lastRunAt == first, "the second click didn't start a run") }
            extractor.open()
            await pass.value
            await queued.value
        }

        r.run("a running pass refuses it") {
            let extractor = GatedIntentExtractor()
            let h = await makeHarness(extractor: extractor)
            await h.host.load()
            let pass = Task { await h.runner.refresh() }
            let reached = await waitUntil { extractor.calls.count == 1 }
            try expect(reached)
            try await MainActor.run { try expect(!h.runner.canReExtract) }
            extractor.open()
            await pass.value
        }

        r.run("Messages that can't be read refuse it") {
            let h = await makeHarness(availability: .unavailable)
            await h.host.load()
            await h.runner.refresh()
            try await MainActor.run { try expect(!h.runner.canReExtract) }
        }

        r.run("no model refuses it") {
            let h = await makeHarness()
            try await MainActor.run {
                h.host.unload()
                try expect(!h.runner.canReExtract)
            }
        }

        r.run("inside the cooldown it's refused; after it, allowed, judged at the injected moment") {
            let h = await makeHarness()
            await h.host.load()
            let lastRun = Date(timeIntervalSince1970: 1_790_000_000)
            h.settings.minimumIntervalHours = 6
            h.settings.lastRunAt = lastRun
            h.moment.date = lastRun.addingTimeInterval(5 * 3600)
            try await MainActor.run { try expect(!h.runner.canReExtract) }
            h.moment.date = lastRun.addingTimeInterval(7 * 3600)
            try await MainActor.run { try expect(h.runner.canReExtract) }
        }
    }
}

/// `waitUntil`, for a condition read on the main actor.
private func waitUntilOnMainActor(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

/// Lets a model's first call through and holds every later one until
/// `open()`.
private final class SecondCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var isOpen = false

    func open() { lock.withLock { isOpen = true } }

    func pass() async {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard call > 1 else { return }
        while !lock.withLock({ isOpen }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
