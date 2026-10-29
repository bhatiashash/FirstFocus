import DailyOSApp
import DailyOSCore
import Foundation

/// Test double for `IntentExtractor` that suspends inside `extract` until a
/// test opens the gate. Exists because the real bug only appears while a
/// model call is *in flight*: `FakeIntentExtractor` returns instantly, so a
/// second intake pass never overlaps the first one there, and the
/// duplicated work this file is about can't be reproduced with it. Holding
/// the call open is what makes the overlap deterministic rather than a race
/// the test would have to sleep and hope for.
final class GatedIntentExtractor: IntentExtractor, @unchecked Sendable {
    let modelDisplayName = "Gated Fake Model"
    let maxPromptTokens = 10_000

    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var isOpen = false

    var calls: [String] { lock.withLock { recordedCalls } }

    /// Lets every suspended call — and every later one — return.
    func open() { lock.withLock { isOpen = true } }

    func extract(from text: String, priority: TaskPriority = .userInitiated) async throws -> String {
        lock.withLock { recordedCalls.append(text) }
        while !lock.withLock({ isOpen }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return "NONE"
    }

    func estimatedTokenCount(for text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Polls `condition` until it holds or `timeout` elapses, returning whether
/// it held. A bounded poll rather than a fixed sleep so the test is fast
/// when the condition is met and still terminates when it never will be —
/// both outcomes are meaningful here, which is why this returns a `Bool`
/// instead of throwing.
func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

/// `waitUntil` for a condition that has to be read on the main actor —
/// `AppModel`'s published state, which a nonisolated poll cannot touch.
private func waitUntilOnMain(
    timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await MainActor.run(body: condition)
}

/// A minute old by default, so its Batch has already gone quiet (ADR 0039)
/// and a pass judges it straight away.
private func message(
    id: String, chatId: Int? = nil, isFromMe: Bool = true, text: String, createdAt: Date = Date().addingTimeInterval(-60)
) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId ?? abs(id.hashValue % 1000), isFromMe: isFromMe, text: text, createdAt: createdAt)
}

/// `@unchecked Sendable` for the same reason `AppModelTests`' own harness
/// is: both fields are built and driven on the main actor, and this exists
/// only so one `MainActor.run` can hand them back out to the test body.
private struct PollHarness: @unchecked Sendable {
    let model: AppModel
    let clock: FakeRefreshClock
}

func registerIntakeConcurrencyTests(_ runner: TestRunner) {
    runner.suite("MessagesIntake: overlapping passes never duplicate extraction") { r in
        r.run("a second refresh started mid-pass re-extracts nothing the first pass already has in flight") {
            let extractor = GatedIntentExtractor()
            let messages = [
                message(id: "m1", chatId: 1, text: "call the dentist"),
                message(id: "m2", chatId: 2, text: "book the flights"),
            ]
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: messages),
                    signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }

            // The launch pass, suspended on the first message's model call.
            let first = Task { await intake.refresh(now: Date()) }
            let reachedModel = await waitUntil { extractor.calls.count >= 1 }
            try expect(reachedModel, "the first pass should reach the model")

            // The 60s chat.db poll, firing while that pass is still running.
            let second = Task { await intake.refresh(now: Date()) }
            // Expected to time out once the fix is in: nothing should be
            // extracted twice, so the call count should stay at 1.
            _ = await waitUntil(timeout: 1) { extractor.calls.count >= 2 }

            extractor.open()
            _ = await first.value
            _ = await second.value

            let calls = extractor.calls
            try expect(
                calls.count == Set(calls).count,
                "each message should reach the model once across both passes, got \(calls)"
            )
        }
    }

    runner.suite("MessagesIntake: re-extraction waits its turn rather than joining") { r in
        r.run("a re-extraction started mid-pass runs nothing until that pass finishes, then runs") {
            let extractor = GatedIntentExtractor()
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: [message(id: "m1", chatId: 1, text: "call the dentist")]),
                    signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }

            let pass = Task { await intake.refresh(now: Date()) }
            let reachedModel = await waitUntil { extractor.calls.count >= 1 }
            try expect(reachedModel, "the refresh pass should reach the model")

            let manual = Task { await intake.reExtract(now: Date(), lookbackDays: 7) }
            // Unlike a joining refresh, this must not start: it would be a
            // second pass through the model while the first still holds it.
            _ = await waitUntil(timeout: 1) { extractor.calls.count >= 2 }
            // Removing the wait fails the *second* assertion below, not this
            // one: an unguarded re-extraction reads `reExtractionCandidates`
            // while the running pass still has the message unprocessed,
            // finds nothing to revisit, and silently does no work at all.
            // Both halves are the rule, so both are asserted.
            try expect(
                extractor.calls.count == 1,
                "re-extraction should not have reached the model yet, got \(extractor.calls)"
            )

            extractor.open()
            _ = await pass.value
            _ = await manual.value

            // It waited, but it did run: re-extraction is additive (ADR
            // 0004), so the same message going through the model a second
            // time here is the point, not the bug the suite above pins.
            try expect(
                extractor.calls.count == 2,
                "re-extraction should have run once the pass finished, got \(extractor.calls)"
            )
        }
    }

    runner.suite("AppModel: the chat.db poll never piles work onto the launch intake") { r in
        r.run("an interval trigger during start() does not re-extract what start() is already extracting") {
            let extractor = GatedIntentExtractor()
            let messages = [
                message(id: "m1", chatId: 1, text: "call the dentist"),
                message(id: "m2", chatId: 2, text: "book the flights"),
            ]
            let h = await MainActor.run { () -> PollHarness in
                let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
                let clock = FakeRefreshClock()
                let model = AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource(messages: messages)
                    d.signalStore = makeTestSignalStore()
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = clock
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                    d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                    d.loadModel = { _, _ in extractor }
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.bundlePath = "/nonexistent"
                })
                return PollHarness(model: model, clock: clock)
            }

            let launch = Task { await h.model.start() }
            let reachedModel = await waitUntil { extractor.calls.count >= 1 }
            try expect(reachedModel, "start() should reach the model")

            await MainActor.run { h.clock.fire() }
            _ = await waitUntil(timeout: 1) { extractor.calls.count >= 2 }

            extractor.open()
            await launch.value

            let calls = extractor.calls
            try expect(
                calls.count == Set(calls).count,
                "the poll should not re-extract what start() already has in flight, got \(calls)"
            )
            try await MainActor.run {
                try expect(h.model.isLoading == false, "start() should have finished and cleared Loading")
            }
        }
    }

    runner.suite("AppModel: Re-extract is disabled while a pass is running") { r in
        r.run("canReExtract is false for the duration of a Messages pass and true once it finishes") {
            let extractor = GatedIntentExtractor()
            let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
            let model = try await MainActor.run { () -> AppModel in
                let store = makeTestSignalStore()
                // Backfill already done, so `backfillProgress` stays nil and
                // the running pass is the only thing this can be measuring.
                try store.markBackfillComplete()
                return AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource(messages: [message(id: "m1", chatId: 1, text: "call the dentist")])
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
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.bundlePath = "/nonexistent"
                })
            }

            let launch = Task { await model.start() }
            let reachedModel = await waitUntil { extractor.calls.count >= 1 }
            try expect(reachedModel, "the launch pass should reach the model")

            try await MainActor.run {
                try expect(model.isLoading == false, "ADR 0035 clears Loading before the pass finishes")
                try expect(
                    model.canReExtract == false,
                    "Re-extract should be disabled while a pass holds the model, not enabled and silently queued"
                )
            }

            extractor.open()
            await launch.value

            try await MainActor.run {
                try expect(model.canReExtract, "Re-extract should be enabled again once the pass finishes")
            }
        }
    }

    runner.suite("AppModel: launch shows what the store already has") { r in
        r.run("start() clears Loading and publishes stored Signals without waiting for the intake pass") {
            let extractor = GatedIntentExtractor()
            let stored = Signal(
                id: "s1", source: .messages, sourceRef: "old-1", label: "Call the dentist",
                originalText: "call the dentist", createdAt: Date(), provenance: .inferred
            )
            let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
            let model = try await MainActor.run { () -> AppModel in
                let store = makeTestSignalStore()
                try store.recordOneMessageBatch("old-1", signals: [stored])
                try store.markBackfillComplete()
                return AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource(messages: [message(id: "m1", chatId: 1, text: "book the flights")])
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
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.bundlePath = "/nonexistent"
                })
            }

            // Never opened: the pass stays stuck in the model for the whole
            // test, standing in for the multi-minute real one.
            let launch = Task { await model.start() }
            let cleared = await waitUntilOnMain { !model.isLoading }

            try await MainActor.run {
                try expect(cleared, "Loading should clear without waiting for the Messages pass")
                let all = model.rankedList.focus + model.rankedList.later + model.rankedList.suggested
                try expect(all.map(\.label) == ["Call the dentist"], "the stored Signal should already be on the list, got \(all.map(\.label))")
            }

            extractor.open()
            await launch.value
        }
    }
}
