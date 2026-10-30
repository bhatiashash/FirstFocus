import FirstFocusCore
import Foundation

/// Ticket 04 (batched-extraction): Extraction judges a closed Batch as
/// one piece of source text (ADR 0039).
private let base = Date().addingTimeInterval(-3600)

private func line(
    _ id: String, chat: Int = 5, text: String, from address: String? = nil, at seconds: TimeInterval
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chat, isFromMe: address == nil, text: text, createdAt: base.addingTimeInterval(seconds),
        senderAddress: address
    )
}

func registerBatchExtractionTests(_ runner: TestRunner) {
    runner.suite("Messages Intake refresh over Batches") { r in
        r.run("one model call and one History row per Batch, and every member is Processed") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let batch = [
                line("m1", text: "can you grab milk", from: "+15550001", at: 0),
                line("m2", text: "no", at: 5),
                line("m3", text: "okay, just bread then", from: "+15550001", at: 10),
            ]
            let extractor = FakeIntentExtractor(defaultResponse: "Grab bread")
            let signals = await refreshThroughIntake(from: batch, store: store, extractor: extractor, historyStore: history)
            try expect(extractor.calls == ["[latest messages]\nParticipant A: can you grab milk\nYou: no\nParticipant A: okay, just bread then"],
                       "got \(extractor.calls)")
            try expect(signals.map(\.label) == ["Grab bread"])
            try expect(signals.first?.sourceRef == "m3", "a Signal from a Batch carries the Batch id, its newest message")
            try expect(["m1", "m2", "m3"].allSatisfy { store.isProcessed(sourceRef: $0) })
            try expect(store.members(ofBatch: "m3") == ["m1", "m2", "m3"])
            let rows = history.allRows()
            try expect(rows.count == 1)
            try expect(rows.first?.sourceRef == "m3")
        }

        r.run("a message arriving after its Batch closed starts a new Batch, with the old one as context") {
            let store = makeTestSignalStore()
            let first = [line("m1", text: "can you grab milk", from: "+15550001", at: 0)]
            let extractor = FakeIntentExtractor(defaultResponse: "NONE")
            _ = await refreshThroughIntake(from: first, store: store, extractor: extractor)
            let later = first + [line("m2", text: "also bread", from: "+15550001", at: 600)]
            _ = await refreshThroughIntake(from: later, store: store, extractor: extractor)
            try expect(extractor.calls.last == "[context]\nParticipant A: can you grab milk\n\n[latest messages]\nParticipant A: also bread",
                       "got \(extractor.calls)")
        }

        r.run("a confidentiality trigger in any member withholds the whole Batch, and nothing reaches the Screener") {
            let store = makeTestSignalStore()
            let screener = FakeScreener()
            let extractor = FakeIntentExtractor(defaultResponse: "Call the dentist")
            let batch = [
                line("m1", text: "keep this between us", from: "+15550001", at: 0),
                line("m2", text: "can you call the dentist", from: "+15550001", at: 5),
            ]
            let deps = ExtractionDependencies(store: store, extractor: extractor, screener: screener, screeningMode: .shadow)
            let signals = await refreshThroughIntake(from: batch, deps: deps)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty)
            try expect(screener.inputs.isEmpty)
            try expect(store.isProcessed(sourceRef: "m1") && store.isProcessed(sourceRef: "m2"))
        }

        r.run("original wording is the whole Batch with display names, context is kept, and Sender is the newest other person") {
            let store = makeTestSignalStore()
            let resolver = FakeContactsResolver(names: ["+15550001": "Mom", "+15550002": "Dad"])
            try store.recordOneMessageBatch("m0", signals: [])
            let messages = [
                line("m0", text: "are you around this weekend", from: "+15550002", at: -60),
                line("m1", text: "can you grab milk", from: "+15550001", at: 0),
                line("m2", text: "no", at: 5),
                line("m3", text: "okay, just bread then", from: "+15550002", at: 10),
                line("m4", text: "will do", at: 15),
            ]
            let extractor = FakeIntentExtractor(defaultResponse: "Grab bread")
            let signals = await refreshThroughIntake(from: messages, store: store, extractor: extractor, contactsResolver: resolver)
            let signal = try require(signals.first)
            try expect(signal.originalText == "Mom: can you grab milk\nYou: no\nDad: okay, just bread then\nYou: will do",
                       "got \(signal.originalText)")
            try expect(signal.contextText == "Dad: are you around this weekend")
            try expect(signal.sender == "Dad", "the newest message that isn't yours decides the Sender")
        }

        r.run("a Batch of only your own messages has no Sender") {
            let store = makeTestSignalStore()
            let batch = [line("m1", text: "need to book flights", at: 0), line("m2", text: "and a hotel", at: 5)]
            let extractor = FakeIntentExtractor(defaultResponse: "Book flights and a hotel")
            let signals = await refreshThroughIntake(from: batch, store: store, extractor: extractor)
            try expect(signals.count == 1)
            try expect(signals.first?.sender == nil)
        }

        r.run("a lone message from someone else is still named; a Self-thread note keeps its plain text") {
            let store = makeTestSignalStore()
            let resolver = FakeContactsResolver(names: ["+15550001": "Mom"])
            let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
            let signals = await refreshThroughIntake(
                from: [line("m1", text: "can you grab milk", from: "+15550001", at: 0)], store: store, extractor: extractor,
                contactsResolver: resolver
            )
            try expect(signals.first?.originalText == "Mom: can you grab milk")
            let note = ChatMessage(
                id: "n1", chatId: 9, isFromMe: true, text: "call the dentist", createdAt: base, isSelfThread: true
            )
            let noteSignals = await refreshThroughIntake(from: [note], store: store, extractor: extractor)
            try expect(noteSignals.first { $0.sourceRef == "n1" }?.originalText == "call the dentist")
        }

        r.run("the Screener sees the whole Batch under Participant Labels, and both rows name the Batch") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let screener = FakeScreener(probability: 0.8)
            let extractor = FakeIntentExtractor(defaultResponse: "Grab bread")
            let batch = [
                line("m1", text: "can you grab milk", from: "+15550001", at: 0),
                line("m2", text: "and bread", from: "+15550001", at: 5),
            ]
            let deps = ExtractionDependencies(
                store: store, extractor: extractor, historyStore: history, screener: screener, screeningMode: .shadow
            )
            _ = await refreshThroughIntake(from: batch, deps: deps)
            let input = try require(screener.inputs.first).text
            try expect(input == "[latest messages]\nParticipant A: can you grab milk\nParticipant A: and bread", "got \(input)")
            try expect(!input.contains("+1555"))
            let rows = history.allRows()
            try expect(rows.count == 2)
            try expect(rows.allSatisfy { $0.sourceRef == "m2" }, "Screening and extraction rows pair by Batch id")
            try expect(screeningQuestion.contains("[latest messages]") && screeningQuestion.contains("'You' is the user"), "the question must say what the Batch and the labels are")
        }

        r.run("with a clock, an open Batch is left for later, then judged once it has gone quiet") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
            let messages = [line("m1", text: "can you grab milk", from: "+15550001", at: 0)]
            let early = await refreshThroughIntake(
                from: messages, deps: ExtractionDependencies(store: store, extractor: extractor), now: base.addingTimeInterval(5)
            )
            try expect(early.isEmpty)
            try expect(extractor.calls.isEmpty)
            try expect(!store.isProcessed(sourceRef: "m1"))
            let later = await refreshThroughIntake(
                from: messages, deps: ExtractionDependencies(store: store, extractor: extractor),
                now: base.addingTimeInterval(batchQuietWindow)
            )
            try expect(later.map(\.label) == ["Grab milk"])
        }
    }

    runner.suite("SQLiteSignalStore: Batches") { r in
        r.run("a Batch's members, its Signals and their context round-trip through the real store") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("firstfocus-batch-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)
            let batch = MessageBatch(messages: [
                line("m1", text: "can you grab milk", from: "+15550001", at: 0),
                line("m2", text: "and bread", from: "+15550001", at: 5),
            ])
            let signal = Signal(
                id: "s1", source: .messages, sourceRef: batch.id, label: "Grab milk and bread",
                originalText: "Mom: can you grab milk\nMom: and bread", createdAt: Date(), provenance: .inferred,
                contextText: "You: heading to the store"
            )
            try store.recordProcessedBatch(batch, signals: [signal])
            try expect(store.isProcessed(sourceRef: "m1") && store.isProcessed(sourceRef: "m2"))
            try expect(store.members(ofBatch: "m2") == ["m1", "m2"])
            try expect(store.openSignals().first?.contextText == "You: heading to the store")
            var threw = false
            do { try store.recordProcessedBatch(MessageBatch(messages: [batch.messages[1]]), signals: []) } catch { threw = true }
            try expect(threw, "a message never belongs to two Batches")
        }
    }
}
