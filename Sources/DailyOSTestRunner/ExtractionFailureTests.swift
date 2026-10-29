import DailyOSApp
import DailyOSCore
import Foundation

// A model call that throws (CONTEXT.md: Processed): the Batch is tried
// again on the next pass, up to `maxExtractionTries`, each failure leaves
// a History row, and once intake gives up History offers Try Again.

private let chatId = 7

private func message(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chatId, isFromMe: false, text: text, createdAt: Date().addingTimeInterval(-3600),
        senderAddress: "+15550001"
    )
}

private func failedRows(_ history: SQLiteHistoryStore) -> [HistoryEntry] {
    history.allRows().filter { if case .extractionFailed = $0.kind { return true } else { return false } }
}

func registerExtractionFailureTests(_ runner: TestRunner) {
    runner.suite("Extraction: a model call that fails") { r in
        let messages = [message("m1", "can you pick up the cake")]

        r.run("leaves the Batch unprocessed for the next pass, with a History row saying why") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor()
            extractor.failure = LlamaCppIntentExtractorError.decodeFailed
            _ = await refreshThroughIntake(
                from: messages, store: store, extractor: extractor, fixture: IntakeFixture(historyStore: history)
            )
            try expect(!store.isProcessed(sourceRef: "m1"))
            let rows = failedRows(history)
            try expect(rows.count == 1)
            try expect(rows.first?.kind == .extractionFailed(reason: "the model stopped while reading"))
        }

        r.run("is tried \(maxExtractionTries) times, then the Batch is Processed with no Signals and no more tries") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor()
            extractor.failure = LlamaCppIntentExtractorError.promptTooLong(tokenCount: 9000, contextSize: 8192)
            let fixture = IntakeFixture(historyStore: history)
            for pass in 1...maxExtractionTries {
                try expect(!store.isProcessed(sourceRef: "m1"), "still being tried before pass \(pass)")
                _ = await refreshThroughIntake(from: messages, store: store, extractor: extractor, fixture: fixture)
            }
            try expect(store.isProcessed(sourceRef: "m1"))
            try expect(store.openSignals().isEmpty)
            _ = await refreshThroughIntake(from: messages, store: store, extractor: extractor, fixture: fixture)
            try expect(extractor.calls.count == maxExtractionTries, "got \(extractor.calls.count) calls")
            try expect(failedRows(history).count == maxExtractionTries)
        }

        r.run("then answering on a later try keeps what the model found") {
            let store = makeTestSignalStore()
            let failing = FakeIntentExtractor()
            failing.failure = LlamaCppIntentExtractorError.decodeFailed
            _ = await refreshThroughIntake(from: messages, store: store, extractor: failing, fixture: IntakeFixture())
            let answering = FakeIntentExtractor(responses: ["can you pick up the cake": "Pick up the cake"])
            let signals = await refreshThroughIntake(from: messages, store: store, extractor: answering, fixture: IntakeFixture())
            try expect(signals.map(\.label) == ["Pick up the cake"])
            try expect(store.isProcessed(sourceRef: "m1"))
        }

        r.run("in a re-extraction writes a row and changes nothing else") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            try store.recordOneMessageBatch("m1", signals: [])
            let extractor = FakeIntentExtractor()
            extractor.failure = LlamaCppIntentExtractorError.decodeFailed
            await reExtractThroughIntake(
                messages: messages, store: store, extractor: extractor, fixture: IntakeFixture(historyStore: history)
            )
            try expect(failedRows(history).count == 1)
            try expect(store.openSignals().isEmpty)
        }
    }

    runner.suite("History: a Batch the model failed on") { r in
        let failed = HistoryEntry(
            timestamp: Date().addingTimeInterval(-60), sourceRawText: "can you pick up the cake", modelUsed: "Fake Model",
            signalCount: 0, chatId: chatId, kind: .extractionFailed(reason: "the model stopped while reading"),
            sourceRef: "m1", sender: "Mom",
            transcript: [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "can you pick up the cake", sentAt: Date())]
        )

        r.run("reads as a failed model call, with a badge") {
            let batch = historyBatch(failed)
            try expect(batch.result == .extractionFailed(reason: "the model stopped while reading"))
            try expect(batch.resultSummary == "The model call failed (the model stopped while reading).")
            let badges = historyBadges(for: batch, cutoff: 0.4, isCorrected: false, isMuted: false).map(\.text)
            try expect(badges == ["Model failed"])
        }

        r.run("offers nothing new while intake still has tries left") {
            let app = await MainActor.run { makeHistoryApp(messages: [message("m1", "can you pick up the cake")]) }
            try app.history.record(failed)
            try await MainActor.run {
                let viewModel = app.viewModel()
                let batch = try require(viewModel.batches.first { $0.id == "m1" })
                try expect(app.actions.offered(.tryAgain, for: batch) == nil)
                try expect(app.actions.offered(.addTask, for: batch) == nil)
            }
        }

        r.run("once intake gives up, offers Try Again, which keeps the task the model then finds") {
            let extractor = FakeIntentExtractor(responses: ["can you pick up the cake": "Pick up the cake"])
            let app = await MainActor.run {
                makeHistoryApp(messages: [message("m1", "can you pick up the cake")], extractor: extractor)
            }
            await app.model.extraction.load()
            try app.history.record(failed)
            try app.signals.recordOneMessageBatch("m1", signals: [])
            let batch = try await MainActor.run { () -> HistoryBatch in
                let viewModel = app.viewModel()
                let batch = try require(viewModel.batches.first { $0.id == "m1" })
                try expect(app.actions.offered(.tryAgain, for: batch) == .enabled)
                try expect(app.actions.offered(.addTask, for: batch) == .enabled)
                return batch
            }
            await app.actions.tryAgain(batch)
            try await MainActor.run {
                try expect(app.model.rankedList.suggested.map(\.label) == ["Pick up the cake"])
                try expect(app.model.corrections.types(forBatches: ["m1"]).isEmpty, "Try Again records no Correction")
            }
        }
    }
}
