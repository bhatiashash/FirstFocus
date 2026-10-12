import DailyOSCore
import Foundation

/// Ticket 07 (batched-extraction): a Batch can UPDATE or CANCEL a
/// Suggestion still waiting in the Inbox, and nothing else (ADR 0040).
private let base = Date().addingTimeInterval(-7200)

private func line(
    _ id: String, chat: Int = 5, text: String, from address: String? = "+15550001", at seconds: TimeInterval,
    isSelfThread: Bool = false
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chat, isFromMe: address == nil, text: text, createdAt: base.addingTimeInterval(seconds),
        senderAddress: address, isSelfThread: isSelfThread
    )
}

private func suggestion(
    _ id: String, label: String, sourceRef: String, chat: Int? = 5, at seconds: TimeInterval
) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label.lowercased(),
        createdAt: base.addingTimeInterval(seconds), provenance: .inferred, chatId: chat
    )
}

/// Answers with `response`, after running `beforeAnswering` — which lets
/// a test change the store between the prompt being built and the answer
/// being written.
private final class HookedExtractor: IntentExtractor, @unchecked Sendable {
    let response: String
    let beforeAnswering: () -> Void
    private(set) var calls: [String] = []
    let modelDisplayName = "Hooked"
    let maxPromptTokens = 10_000

    init(response: String, beforeAnswering: @escaping () -> Void = {}) {
        self.response = response
        self.beforeAnswering = beforeAnswering
    }

    func extract(from text: String, priority: TaskPriority) async throws -> String {
        calls.append(text)
        beforeAnswering()
        return response
    }

    func estimatedTokenCount(for text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// A store holding one earlier Batch (m1) that produced `signals`, with a
/// later message m2 in the same Chat still to judge.
private func storeWithEarlierBatch(_ signals: [Signal]) throws -> SQLiteSignalStore {
    let store = makeTestSignalStore()
    try store.recordProcessedBatch(MessageBatch(messages: [line("m1", text: "book a table for friday", at: 0)]), signals: signals)
    return store
}

private let earlier = line("m1", text: "book a table for friday", at: 0)
private let later = line("m2", text: "actually saturday", at: 600)

func registerSupersededTests(_ runner: TestRunner) {
    runner.suite("Superseded: UPDATE and CANCEL") { r in
        r.run("the model sees the Chat's undecided Suggestions, numbered") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = FakeIntentExtractor()
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            let prompt = try require(extractor.calls.first)
            try expect(prompt.hasPrefix("[open suggestions]\n1. Book a table for Friday\n\n"), "got:\n\(prompt)")
        }

        r.run("a new Label repeating an open Suggestion mints nothing and leaves the Suggestion open") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = FakeIntentExtractor(defaultResponse: "Book a table for Friday")
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(signals.map(\.id) == ["s1"], "only the earlier Suggestion, got \(signals.map(\.label))")
        }

        r.run("UPDATE mints a new Signal and marks the old one Superseded, linked to it") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = FakeIntentExtractor(defaultResponse: "UPDATE 1: Book a table for Saturday")
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Book a table for Saturday"])
            let replacement = try require(signals.first)
            try expect(suggestedTasksInbox(store.openSignals()).map(\.id) == [replacement.id], "the old Suggestion leaves the Inbox")
            try expect(replacement.sourceRef == "m2")
        }

        r.run("CANCEL marks the Suggestion Superseded with no replacement") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = FakeIntentExtractor(defaultResponse: "CANCEL 1")
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(store.openSignals().isEmpty, "the Suggestion leaves the Inbox")
        }

        r.run("a Suggestion Approved before the answer is written is left alone, and the update still lands as a new Suggestion") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = HookedExtractor(response: "UPDATE 1: Book a table for Saturday") {
                try? store.approve(signalId: "s1", reminderId: "r1")
            }
            let signals = await refreshThroughIntake(
                from: [earlier, later], deps: ExtractionDependencies(store: store, extractor: extractor)
            )
            try expect(signals.map(\.label) == ["Book a table for Saturday"])
            try expect(!store.openSignals().contains { $0.id == "s1" }, "the Approved Suggestion stays out of the Inbox")
        }

        r.run("an UPDATE or CANCEL naming a number that wasn't listed changes nothing") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let extractor = FakeIntentExtractor(defaultResponse: "CANCEL 2\nUPDATE 3: Something")
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(store.openSignals().map(\.id) == ["s1"])
        }

        r.run("Superseded Signals leave the Suggested Tasks Inbox and are not Open") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: FakeIntentExtractor(defaultResponse: "CANCEL 1"))
            try expect(store.openSignals().isEmpty)
            try expect(suggestedTasksInbox(store.openSignals()).isEmpty)
        }

        r.run("only this Chat's undecided Suggestions are listed, at most five, newest first") {
            let store = makeTestSignalStore()
            var signals = (0..<6).map { suggestion("s\($0)", label: "Task \($0)", sourceRef: "m1", at: Double($0)) }
            signals.append(suggestion("other", label: "Other chat", sourceRef: "m1", chat: 99, at: 100))
            var dismissed = suggestion("gone", label: "Dismissed one", sourceRef: "m1", at: 200)
            dismissed.state = .dismissed(at: base)
            signals.append(dismissed)
            try store.recordProcessedBatch(MessageBatch(messages: [earlier]), signals: signals)
            let extractor = FakeIntentExtractor()
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            let prompt = try require(extractor.calls.first)
            try expect(prompt.hasPrefix("[open suggestions]\n1. Task 5\n2. Task 4\n3. Task 3\n4. Task 2\n5. Task 1\n\n"), "got:\n\(prompt)")
        }

        r.run("a Suggestion saved before Signals carried their Chat is found through its source message") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", chat: nil, at: 0)])
            let extractor = FakeIntentExtractor()
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(extractor.calls.first?.hasPrefix("[open suggestions]\n1. Book a table for Friday") == true)
        }

        r.run("a Self-thread note can cancel a Suggestion an earlier note produced") {
            let first = line("n1", chat: 9, text: "call the dentist", from: nil, at: 0, isSelfThread: true)
            let second = line("n2", chat: 9, text: "skip the dentist, moved it", from: nil, at: 60, isSelfThread: true)
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(
                MessageBatch(messages: [first]), signals: [suggestion("s1", label: "Call the dentist", sourceRef: "n1", chat: 9, at: 0)]
            )
            let extractor = FakeIntentExtractor(defaultResponse: "CANCEL 1")
            _ = await refreshThroughIntake(from: [first, second], store: store, extractor: extractor)
            try expect(extractor.calls.first == "[open suggestions]\n1. Call the dentist\n\n[context]\nYou: call the dentist\n\n[latest messages]\nYou: skip the dentist, moved it",
                       "got \(extractor.calls)")
            try expect(store.openSignals().isEmpty)
        }

        r.run("a Batch from a Chat with an undecided Suggestion skips the Screener, even live") {
            let store = try storeWithEarlierBatch([suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0)])
            let screener = FakeScreener(probability: 0.01)
            let extractor = FakeIntentExtractor(defaultResponse: "CANCEL 1")
            let deps = ExtractionDependencies(store: store, extractor: extractor, screener: screener, screeningMode: .live(cutoff: 0.5))
            _ = await refreshThroughIntake(from: [earlier, later], deps: deps)
            try expect(screener.inputs.isEmpty)
            try expect(extractor.calls.count == 1)
        }
    }

    runner.suite("SQLiteSignalStore: Superseded and the Signal's Chat") { r in
        r.run("Superseded round-trips, blocks re-extraction, and loses to an earlier Approve") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-superseded-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)
            try store.recordProcessedBatch(
                MessageBatch(messages: [earlier]),
                signals: [
                    suggestion("s1", label: "Book a table for Friday", sourceRef: "m1", at: 0),
                    suggestion("s2", label: "Order flowers", sourceRef: "m1", at: 1),
                ]
            )
            try expect(store.openSignals().first { $0.id == "s1" }?.chatId == 5)
            try store.approve(signalId: "s2", reminderId: "r2")
            let replacement = suggestion("s3", label: "Book a table for Saturday", sourceRef: "m2", at: 600)
            try store.recordProcessedBatch(
                MessageBatch(messages: [later]), signals: [replacement],
                superseding: [Supersession(signalId: "s1", replacedBy: "s3"), Supersession(signalId: "s2", replacedBy: nil)]
            )
            try expect(store.openSignals().map(\.id) == ["s3"])
            try expect(!store.reExtractionCandidates().contains("m1"), "a Superseded Signal still counts as decided")
        }
    }
}
