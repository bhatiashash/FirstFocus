import FirstFocusApp
import FirstFocusCore
import Foundation

/// Ticket 06 (batched-extraction): re-extraction, "This was work",
/// "Not for me", Re-run and Corrections act on whole Batches.
private let base = Date().addingTimeInterval(-3600)

private func line(_ id: String, text: String, from address: String? = "+15550001", at seconds: TimeInterval) -> ChatMessage {
    ChatMessage(
        id: id, chatId: 5, isFromMe: address == nil, text: text, createdAt: base.addingTimeInterval(seconds),
        senderAddress: address
    )
}

private let milkBatch = [
    line("m1", text: "can you grab milk", at: 0),
    line("m2", text: "and bread", at: 5),
]
private let milkPrompt = "[latest messages]\nParticipant A: can you grab milk\nParticipant A: and bread"

func registerBatchHistoryActionsTests(_ runner: TestRunner) {
    runner.suite("Re-extraction candidates over Batches") { r in
        r.run("a Batch is one candidate, named by its id; its other members never are") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [])
            try store.recordOneMessageBatch("solo", signals: [])
            let candidates = store.reExtractionCandidates()
            try expect(candidates == ["m2", "solo"], "got \(candidates)")
        }
        r.run("a Batch with a live Signal is not a candidate") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [Signal(
                id: "s1", source: .messages, sourceRef: "m2", label: "Grab milk and bread", originalText: "…",
                createdAt: Date(), provenance: .inferred, chatId: 5
            )])
            try expect(store.reExtractionCandidates().isEmpty)
        }
        r.run("a message Processed before batching is a candidate as a Batch of one") {
            let path = testStorePath()
            try seedPreBatchMessage("m0", signals: [], inStoreAt: path)
            let store = SQLiteSignalStore(path: path)
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [])
            try expect(store.reExtractionCandidates() == ["m0", "m2"], "got \(store.reExtractionCandidates())")
            try expect(store.members(ofBatch: "m0") == ["m0"])
        }
    }

    runner.suite("re-extraction and This was work over Batches") { r in
        r.run("manual re-extraction puts the whole Batch back through the model, additively") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [])
            try expect(store.reExtractionCandidates() == ["m2"])
            let extractor = FakeIntentExtractor(responses: [milkPrompt: "Grab milk and bread"])
            await reExtractThroughIntake(messages: milkBatch, store: store, extractor: extractor)
            try expect(extractor.calls == [milkPrompt], "got \(extractor.calls)")
            try expect(store.openSignals().map(\.sourceRef) == ["m2"])
        }

        r.run("This was work sends the whole Screened Batch to the model and never to the Screener") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [])
            let screener = FakeScreener(probability: 0.01)
            let extractor = FakeIntentExtractor(responses: [milkPrompt: "Grab milk and bread"])
            let deps = ExtractionDependencies(store: store, extractor: extractor, screener: screener, screeningMode: .live(cutoff: 0.5))
            await extractNowThroughIntake(sourceRef: "m2", messages: milkBatch, deps: deps)
            try expect(extractor.calls == [milkPrompt])
            try expect(screener.inputs.isEmpty)
            try expect(store.openSignals().map(\.label) == ["Grab milk and bread"])
        }

        r.run("manual re-extraction never shows open suggestions, so it can only add (ADR 0004)") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [])
            try store.recordOneMessageBatch("other", signals: [Signal(
                id: "s9", source: .messages, sourceRef: "other", label: "Book the flights", originalText: "…",
                createdAt: base, provenance: .inferred, chatId: 5
            )])
            let extractor = FakeIntentExtractor(defaultResponse: "CANCEL 1")
            await reExtractThroughIntake(messages: milkBatch, store: store, extractor: extractor)
            try expect(extractor.calls == [milkPrompt], "got \(extractor.calls)")
            try expect(store.openSignals().map(\.id) == ["s9"], "nothing is Superseded by a re-extraction")
        }

        r.run("a message Processed before batching is still acted on as a Batch of one") {
            let path = testStorePath()
            try seedPreBatchMessage("m1", signals: [], inStoreAt: path)
            let store = SQLiteSignalStore(path: path)
            let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
            await extractNowThroughIntake(
                sourceRef: "m1", messages: milkBatch, deps: ExtractionDependencies(store: store, extractor: extractor)
            )
            try expect(extractor.calls == ["[latest messages]\nParticipant A: can you grab milk"], "got \(extractor.calls)")
        }
    }

    runner.suite("Re-run of a Batch row") { r in
        r.run("a Batch row is replayed under [latest messages], a single-message row as before") {
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor()
            let batchRow = HistoryEntry(
                sourceRawText: "Participant A: can you grab milk\nParticipant A: and bread", rawOutput: "NONE",
                modelUsed: "Model", signalCount: 0, chatId: 5, renderedContext: milkPrompt, sourceRef: "m2"
            )
            try await rerunHistoryEntry(batchRow, extractor: extractor, historyStore: history)
            let singleRow = HistoryEntry(
                sourceRawText: "call the dentist", rawOutput: "NONE", modelUsed: "Model", signalCount: 0, chatId: 9,
                renderedContext: "call the dentist", sourceRef: "n1"
            )
            try await rerunHistoryEntry(singleRow, extractor: extractor, historyStore: history)
            try expect(extractor.calls == [milkPrompt, "call the dentist"], "got \(extractor.calls)")
        }
    }

    runner.suite("Corrections from Batches") { r in
        r.run("a Correction from a long Batch shows the model only the Batch's last six lines") {
            let longInput = "[context]\nThem: earlier\n\n[latest messages]\n" + (1...9).map { "Them: line \($0)" }.joined(separator: "\n")
            let correction = Correction(chatId: 5, inputText: longInput, correctedOutput: "NONE", correctionType: .falsePositive)
            let target = ChatMessage(id: "t", chatId: 5, isFromMe: false, text: "ok", createdAt: base)
            let formatted = formatForExtraction(target: target, context: [], corrections: [correction])
            try expect(!formatted.contains("line 3"), "got:\n\(formatted)")
            try expect(formatted.contains("Them: line 4\nThem: line 5\nThem: line 6\nThem: line 7\nThem: line 8\nThem: line 9\nOutput: NONE"))
            try expect(formatted.contains("[context]\nThem: earlier"), "the example keeps its own context block")
        }

        r.run("no call carries more than two Corrections") {
            let store = FakeCorrectionStore()
            for index in 0..<4 {
                try store.record(Correction(
                    chatId: 5, inputText: "mistake \(index)", correctedOutput: "NONE", correctionType: .falsePositive,
                    createdAt: base.addingTimeInterval(Double(index))
                ))
            }
            try expect(selectCorrections(chatId: 5, store: store).count == 2)
        }
    }

    runner.suite("\"Not for me\" on a Batch row") { r in
        r.run("records the Correction and dismisses every open Signal the Batch produced") {
            let store = makeTestSignalStore()
            try store.markBackfillComplete()
            let milk = Signal(
                id: "s1", source: .messages, sourceRef: "m2", label: "Grab milk", originalText: "…", createdAt: base,
                provenance: .inferred
            )
            let bread = Signal(
                id: "s2", source: .messages, sourceRef: "m2", label: "Grab bread", originalText: "…", createdAt: base,
                provenance: .inferred
            )
            try store.recordProcessedBatch(MessageBatch(messages: milkBatch), signals: [milk, bread])
            let app = await MainActor.run { makeHistoryApp(signals: store) }
            await app.model.start()
            let row = HistoryEntry(
                sourceRawText: "Participant A: can you grab milk\nParticipant A: and bread", rawOutput: "Grab milk\nGrab bread",
                modelUsed: "Model", signalCount: 2, chatId: 5, renderedContext: milkPrompt, sourceRef: "m2"
            )
            await MainActor.run { app.actions.notForMe(historyBatch(row)) }
            let types = await MainActor.run { app.model.corrections.types(forBatches: ["m2"]) }
            try expect(types == ["m2": [.falsePositive]])
            try expect(store.openSignals().isEmpty)
        }
    }
}
