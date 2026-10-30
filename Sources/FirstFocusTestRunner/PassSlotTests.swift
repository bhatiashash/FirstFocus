import FirstFocusCore
import Foundation

/// The pass slot on its own: joining, follow-ups, waiting and the
/// re-extraction guard, with bodies the test controls. No Messages, no model.

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Log {
    var lines: [String] = []
}

/// Lets tasks that are ready to run reach their next suspension. A sleep,
/// since yielding from here gives the main actor no guaranteed turn.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(30))
}

private let t1 = Date(timeIntervalSince1970: 1_000)
private let t2 = Date(timeIntervalSince1970: 2_000)
private let t3 = Date(timeIntervalSince1970: 3_000)

func registerPassSlotTests(_ runner: TestRunner) {
    runner.suite("PassSlot: one pass at a time") { r in
        r.run("an automatic call that arrives mid-pass joins it, earns one follow-up, and both get the follow-up's result") {
            let slot = await MainActor.run { PassSlot<String>() }
            let gate = await MainActor.run { Gate() }
            let log = await MainActor.run { Log() }
            let first = Task { @MainActor in
                await slot.run(
                    .automatic, at: t1,
                    body: { log.lines.append("pass"); await gate.wait(); return "first" },
                    followUp: { now in log.lines.append("follow-up \(Int(now.timeIntervalSince1970))"); return "second" }
                )
            }
            await settle()
            let joiner = Task { @MainActor in
                await slot.run(
                    .automatic, at: t2, body: { log.lines.append("joiner ran its own body"); return "never" },
                    followUp: { _ in "never" }
                )
            }
            await settle()
            await MainActor.run { gate.open() }
            let results = await (first.value, joiner.value)
            try expect(results.0 == "second" && results.1 == "second", "got \(results)")
            let lines = await MainActor.run { log.lines }
            try expect(lines == ["pass", "follow-up 2000"], "got \(lines)")
        }

        r.run("however many callers join, they earn one follow-up, at the latest one's moment") {
            let slot = await MainActor.run { PassSlot<String>() }
            let gate = await MainActor.run { Gate() }
            let log = await MainActor.run { Log() }
            let first = Task { @MainActor in
                await slot.run(
                    .automatic, at: t1, body: { await gate.wait(); return "first" },
                    followUp: { now in log.lines.append("follow-up \(Int(now.timeIntervalSince1970))"); return "second" }
                )
            }
            await settle()
            let joiners = (0..<3).map { index in
                Task { @MainActor in
                    await slot.run(.automatic, at: [t2, t3, t2][index], body: { "never" }, followUp: { _ in "never" })
                }
            }
            await settle()
            await MainActor.run { gate.open() }
            _ = await first.value
            for joiner in joiners { _ = await joiner.value }
            let lines = await MainActor.run { log.lines }
            try expect(lines == ["follow-up 2000"] || lines == ["follow-up 3000"], "one follow-up, got \(lines)")
            try expect(lines.count == 1)
        }

        r.run("a pass of another kind waits the running pass out, then runs its own") {
            let slot = await MainActor.run { PassSlot<String>() }
            let gate = await MainActor.run { Gate() }
            let log = await MainActor.run { Log() }
            let kinds = await MainActor.run { Log() }
            await MainActor.run { slot.onPassChange = { kinds.lines.append($0.map { "\($0)" } ?? "idle") } }
            let first = Task { @MainActor in
                await slot.run(
                    .automatic, at: t1, body: { log.lines.append("automatic"); await gate.wait(); return "a" },
                    followUp: { _ in "a" }
                )
            }
            await settle()
            let explicit = Task { @MainActor in
                await slot.run(.explicit, body: { log.lines.append("explicit"); return "e" }, followUp: { _ in "e" })
            }
            await settle()
            let before = await MainActor.run { log.lines }
            try expect(before == ["automatic"], "the explicit pass has not started: \(before)")
            await MainActor.run { gate.open() }
            _ = await first.value
            let result = await explicit.value
            try expect(result == "e")
            let order = await MainActor.run { (log.lines, kinds.lines) }
            try expect(order.0 == ["automatic", "explicit"])
            try expect(order.1 == ["automatic", "idle", "explicit", "idle"], "got \(order.1)")
        }

        r.run("the follow-up runs as an automatic pass") {
            let slot = await MainActor.run { PassSlot<String>() }
            let gate = await MainActor.run { Gate() }
            let seen = await MainActor.run { Log() }
            let first = Task { @MainActor in
                await slot.run(
                    .reExtraction, body: { await gate.wait(); return "r" },
                    followUp: { _ in seen.lines.append("\(slot.runningPass.map { "\($0)" } ?? "idle")"); return "f" }
                )
            }
            await settle()
            // A re-extraction never earns a follow-up by itself; an automatic joiner does.
            let joiner = Task { @MainActor in
                await slot.run(.automatic, at: t2, body: { "never" }, followUp: { _ in "never" })
            }
            await settle()
            await MainActor.run { gate.open() }
            _ = await first.value
            _ = await joiner.value
            let kinds = await MainActor.run { seen.lines }
            try expect(kinds == ["automatic"], "got \(kinds)")
        }

        r.run("a second re-extraction while one is running or waiting does nothing") {
            let slot = await MainActor.run { PassSlot<String>() }
            let gate = await MainActor.run { Gate() }
            let first = Task { @MainActor in
                await slot.run(.automatic, at: t1, body: { await gate.wait(); return "a" }, followUp: { _ in "a" })
            }
            await settle()
            let waiting = Task { @MainActor in
                await slot.run(.reExtraction, body: { "re" }, followUp: { _ in "re" })
            }
            await settle()
            try await MainActor.run { try expect(slot.isReExtracting, "from the click, while it waits behind another pass") }
            let duplicate = await slot.run(.reExtraction, body: { "again" }, followUp: { _ in "again" })
            try expect(duplicate == nil)
            await MainActor.run { gate.open() }
            _ = await first.value
            let waited = await waiting.value
            try expect(waited == "re")
            try await MainActor.run { try expect(!slot.isReExtracting && slot.runningPass == nil) }
        }
    }
}

func registerIntakeClockTests(_ runner: TestRunner) {
    runner.suite("Messages Intake: the clock is injected") { r in
        r.run("the floor for non-self messages is the injected moment of the first pass") {
            let store = makeTestSignalStore()
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: []), signalStore: store,
                    contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent",
                    extractor: FakeIntentExtractor(), clock: { t2 }
                )
            }
            _ = await intake.refresh(now: t2)
            try expect(store.nonSelfMessagesCutoff() == t2)
        }
    }
}
