import DailyOSCore
import Foundation

/// Same shape as `RefreshCoordinatorTests`' own recorder: every call here
/// happens synchronously on one thread.
private final class Triggers: @unchecked Sendable {
    private(set) var received: [RefreshTrigger] = []
    func record(_ trigger: RefreshTrigger) { received.append(trigger) }
}

/// A minute old, so its Batch has already gone quiet (ADR 0039) and the
/// pass that reads it judges it straight away.
private func chatMessage(id: String, chatId: Int, text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: true, text: text, createdAt: Date().addingTimeInterval(-60))
}

/// A change reaches the debounce alarm on the main actor. Queued behind
/// it, this returns once every change fired so far has.
private func afterChanges() async {
    await MainActor.run {}
}

func registerRealTimeIntakeTests(_ runner: TestRunner) {
    runner.suite("RefreshCoordinator: a Messages write triggers intake (ADR 0034 amendment)") { r in
        r.run("a change, once the grouping window passes, reaches onRefresh as .messagesChanged") {
            let changes = FakeMessagesChangeObserver()
            let debounce = FakeAlarm()
            let triggers = Triggers()
            _ = RefreshCoordinator(
                pollInterval: 60, clock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
                messagesChanges: changes, debounceAlarm: debounce, onRefresh: triggers.record
            )
            changes.fire()
            await afterChanges()
            try expect(triggers.received.isEmpty, "nothing should fire before the grouping window closes")
            let pending = try require(await debounce.pending)
            try expect(abs(pending.timeIntervalSinceNow - 1) < 0.5, "the grouping window is about a second")
            await debounce.fire()
            try expect(triggers.received == [.messagesChanged])
        }

        r.run("a burst of changes inside the window fires one refresh") {
            let changes = FakeMessagesChangeObserver()
            let debounce = FakeAlarm()
            let triggers = Triggers()
            _ = RefreshCoordinator(
                pollInterval: 60, clock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
                messagesChanges: changes, debounceAlarm: debounce, onRefresh: triggers.record
            )
            changes.fire()
            changes.fire()
            changes.fire()
            await afterChanges()
            await debounce.fire()
            await debounce.fire()
            try expect(triggers.received == [.messagesChanged])
        }

        r.run("a change after the window closed starts a new window") {
            let changes = FakeMessagesChangeObserver()
            let debounce = FakeAlarm()
            let triggers = Triggers()
            _ = RefreshCoordinator(
                pollInterval: 60, clock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
                messagesChanges: changes, debounceAlarm: debounce, onRefresh: triggers.record
            )
            changes.fire()
            await afterChanges()
            await debounce.fire()
            changes.fire()
            await afterChanges()
            await debounce.fire()
            try expect(triggers.received == [.messagesChanged, .messagesChanged])
        }

        r.run("the 60-second poll still fires alongside the change trigger") {
            let clock = FakeRefreshClock()
            let triggers = Triggers()
            _ = RefreshCoordinator(
                pollInterval: 60, clock: clock, eventKitChanges: FakeEventKitChangeObserver(),
                messagesChanges: FakeMessagesChangeObserver(), debounceAlarm: FakeAlarm(), onRefresh: triggers.record
            )
            clock.fire()
            try expect(triggers.received == [.interval])
        }

        r.run("the change trigger means Messages only") {
            try expect(sourcesToRefresh(for: .messagesChanged) == [.messages])
        }
    }

    runner.suite("MessagesIntake: a refresh that arrives mid-pass earns one follow-up pass") { r in
        r.run("a message that lands mid-pass is extracted by the follow-up pass, not the next poll") {
            let extractor = GatedIntentExtractor()
            let source = FakeMessagesSource(messages: [chatMessage(id: "m1", chatId: 1, text: "call the dentist")])
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: source, signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }
            let first = Task { await intake.refresh(now: Date()) }
            let reached = await waitUntil { extractor.calls.count >= 1 }
            try expect(reached, "the first pass should reach the model")

            source.messages.append(chatMessage(id: "m2", chatId: 2, text: "book the flights"))
            let joiner = Task { await intake.refresh(now: Date()) }
            extractor.open()
            _ = await first.value
            _ = await joiner.value

            try expect(source.listCallCount == 2, "expected the pass plus one follow-up, got \(source.listCallCount) reads")
            try expect(extractor.calls.count == 2, "m2 should have reached the model in the follow-up, got \(extractor.calls)")
        }

        r.run("three refreshes mid-pass still cause exactly one follow-up") {
            let extractor = GatedIntentExtractor()
            let source = FakeMessagesSource(messages: [chatMessage(id: "m1", chatId: 1, text: "call the dentist")])
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: source, signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }
            let first = Task { await intake.refresh(now: Date()) }
            let reached = await waitUntil { extractor.calls.count >= 1 }
            try expect(reached)
            let joiners = (0..<3).map { _ in Task { await intake.refresh(now: Date()) } }
            try? await Task.sleep(nanoseconds: 20_000_000)
            extractor.open()
            _ = await first.value
            for joiner in joiners { _ = await joiner.value }
            try expect(source.listCallCount == 2, "expected exactly one follow-up, got \(source.listCallCount) reads")
        }

        r.run("a pass nobody joined runs no follow-up") {
            let extractor = GatedIntentExtractor()
            extractor.open()
            let source = FakeMessagesSource(messages: [chatMessage(id: "m1", chatId: 1, text: "call the dentist")])
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: source, signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }
            _ = await intake.refresh(now: Date())
            try expect(source.listCallCount == 1)
        }

        r.run("a re-extraction waiting on a pass does not cause a follow-up by itself") {
            let extractor = GatedIntentExtractor()
            let source = FakeMessagesSource(messages: [chatMessage(id: "m1", chatId: 1, text: "call the dentist")])
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: source, signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }
            let pass = Task { await intake.refresh(now: Date()) }
            let reached = await waitUntil { extractor.calls.count >= 1 }
            try expect(reached)
            let manual = Task { await intake.reExtract(now: Date(), lookbackDays: 7) }
            try? await Task.sleep(nanoseconds: 20_000_000)
            extractor.open()
            _ = await pass.value
            _ = await manual.value
            try expect(source.listCallCount == 2, "one read for the pass, one for the re-extraction, got \(source.listCallCount)")
        }
    }
}
