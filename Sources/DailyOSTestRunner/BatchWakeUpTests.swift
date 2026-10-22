import DailyOSApp
import DailyOSCore
import Foundation

/// Ticket 05 (batched-extraction): when a pass leaves a Batch open, Intake
/// asks for one refresh at the moment it will close.

/// Keeps every scheduled action, not just the latest, so a test can fire
/// a superseded wake-up and check it does nothing.
private final class RecordingClock: UndoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [(interval: TimeInterval, action: @Sendable () -> Void)] = []

    var intervals: [TimeInterval] { lock.withLock { scheduled.map(\.interval) } }

    func scheduleOnce(after interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { scheduled.append((interval, action)) }
    }

    func fire(_ index: Int) {
        let action = lock.withLock { scheduled[index].action }
        action()
    }
}

private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private func other(_ id: String, chat: Int = 3, text: String, at date: Date) -> ChatMessage {
    ChatMessage(id: id, chatId: chat, isFromMe: false, text: text, createdAt: date, senderAddress: "+15550003")
}

@MainActor
private func makeIntake(
    messages: [ChatMessage], clock: RecordingClock, counter: WakeCounter
) -> (MessagesIntake, FakeMessagesSource, SQLiteSignalStore, FakeIntentExtractor) {
    let source = FakeMessagesSource(messages: messages)
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
    let intake = MessagesIntake(
        messagesSource: source, signalStore: store, contactsResolver: FakeContactsResolver(),
        bundlePath: "/nonexistent", extractor: extractor, batchWakeClock: clock
    )
    intake.onBatchDue = { counter.increment() }
    return (intake, source, store, extractor)
}

func registerBatchWakeUpTests(_ runner: TestRunner) {
    runner.suite("MessagesIntake: waking up for an open Batch") { r in
        r.run("an open Batch schedules one wake-up for when it goes quiet, and the wake-up asks for a refresh") {
            let now = Date()
            let clock = RecordingClock()
            let counter = WakeCounter()
            let (intake, _, store, extractor) = await makeIntake(
                messages: [other("m1", text: "can you grab milk", at: now.addingTimeInterval(-5))], clock: clock, counter: counter
            )
            _ = await intake.refresh(now: now)
            try expect(extractor.calls.isEmpty, "the Batch is still open")
            try expect(clock.intervals.count == 1)
            try expect(abs(clock.intervals[0] - (batchQuietWindow - 5)) < 0.5, "got \(clock.intervals)")
            clock.fire(0)
            try await waitFor { counter.value == 1 }
            _ = await intake.refresh(now: now.addingTimeInterval(batchQuietWindow))
            try expect(store.openSignals().map(\.label) == ["Grab milk"])
        }

        r.run("a message arriving first moves the wake-up, and only the newest one asks for a refresh") {
            let now = Date()
            let clock = RecordingClock()
            let counter = WakeCounter()
            let (intake, source, _, _) = await makeIntake(
                messages: [other("m1", text: "can you grab milk", at: now.addingTimeInterval(-5))], clock: clock, counter: counter
            )
            _ = await intake.refresh(now: now)
            source.messages.append(other("m2", text: "and bread", at: now.addingTimeInterval(10)))
            _ = await intake.refresh(now: now.addingTimeInterval(10))
            try expect(clock.intervals.count == 2)
            try expect(abs(clock.intervals[1] - batchQuietWindow) < 0.5, "the Chat's newest message restarts the quiet window")
            clock.fire(0)
            clock.fire(1)
            try await waitFor { counter.value >= 1 }
            try expect(counter.value == 1, "the superseded wake-up must do nothing")
        }

        r.run("a Chat that keeps going is woken at the cap, not after its last message") {
            let now = Date()
            let clock = RecordingClock()
            let counter = WakeCounter()
            // One message every 15 seconds, so the Chat never goes quiet.
            let messages = stride(from: -110.0, through: -5, by: 15).map { offset in
                other("m\(Int(-offset))", text: "and another thing", at: now.addingTimeInterval(offset))
            }
            let (intake, _, _, _) = await makeIntake(messages: messages, clock: clock, counter: counter)
            _ = await intake.refresh(now: now)
            try expect(abs((clock.intervals.first ?? -1) - (batchCap - 110)) < 0.5, "got \(clock.intervals)")
        }

        r.run("with no open Batch, no wake-up is scheduled") {
            let now = Date()
            let clock = RecordingClock()
            let (intake, _, store, _) = await makeIntake(
                messages: [other("m1", text: "can you grab milk", at: now.addingTimeInterval(-60))], clock: clock, counter: WakeCounter()
            )
            _ = await intake.refresh(now: now)
            try expect(clock.intervals.isEmpty)
            try expect(store.openSignals().count == 1)
        }
    }

    runner.suite("AppModel: a Batch wake-up refreshes Messages") { r in
        r.run("firing the wake-up runs a Messages pass that judges the Batch") {
            let clock = RecordingClock()
            let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
            let source = FakeMessagesSource(messages: [other("m1", text: "can you grab milk", at: Date().addingTimeInterval(-5))])
            let model = await MainActor.run { () -> AppModel in
                let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
                let store = makeTestSignalStore()
                try? store.markBackfillComplete()
                return AppModel(AppDependencies.test { d in
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
                    d.extractor = extractor
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.batchWakeClock = clock
                    d.bundlePath = "/nonexistent"
                })
            }
            await model.start()
            try expect(extractor.calls.isEmpty)
            try expect(clock.intervals.count == 1)
            // Age the message past the quiet window before the wake-up
            // fires, as real time would have.
            source.messages = [other("m1", text: "can you grab milk", at: Date().addingTimeInterval(-60))]
            clock.fire(0)
            try await waitFor { extractor.calls.count == 1 }
            try await waitFor { await MainActor.run { model.rankedList.suggested.count == 1 } }
        }
    }
}

/// Polls `condition` for up to two seconds.
private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure(message: "condition never became true")
}
