import FirstFocusCore
import Foundation

/// Ticket 11 (batched-extraction): once Screening is live, some Screened
/// Batches still go to the model in the background, and only History
/// hears about it.
private let batch = [
    ChatMessage(
        id: "m1", chatId: 5, isFromMe: false, text: "can you grab milk", createdAt: Date().addingTimeInterval(-600),
        senderAddress: "+15550001"
    ),
]

private func run(mode: ScreeningMode, roll: Double) async -> (SQLiteSignalStore, SQLiteHistoryStore, FakeIntentExtractor) {
    let store = makeTestSignalStore()
    let history = makeTestHistoryStore()
    let extractor = FakeIntentExtractor(defaultResponse: "Grab milk")
    let deps = ExtractionDependencies(
        store: store, extractor: extractor, historyStore: history, screener: FakeScreener(probability: 0.1),
        screeningMode: mode, randomUnit: { roll }
    )
    _ = await refreshThroughIntake(from: batch, deps: deps)
    return (store, history, extractor)
}

func registerAuditSampleTests(_ runner: TestRunner) {
    runner.suite("Audit Sample") { r in
        r.run("a Screened Batch picked for the sample goes to the model, is recorded as audit, and mints nothing") {
            let (store, history, extractor) = await run(mode: .live(cutoff: 0.5), roll: 0.05)
            try expect(extractor.calls.count == 1)
            try expect(store.openSignals().isEmpty)
            try expect(store.isProcessed(sourceRef: "m1"))
            let audit = try require(history.allRows().first { $0.kind == .audit })
            try expect(audit.sourceRef == "m1", "paired with the Screening row by Batch id")
            try expect(audit.signalCount == 1, "records what the model would have found")
        }

        r.run("a Screened Batch not picked never reaches the model") {
            let (_, history, extractor) = await run(mode: .live(cutoff: 0.5), roll: auditSampleRate)
            try expect(extractor.calls.isEmpty)
            try expect(!history.allRows().contains { $0.kind == .audit })
        }

        r.run("shadow mode never takes an Audit Sample") {
            let (store, history, extractor) = await run(mode: .shadow, roll: 0)
            try expect(extractor.calls.count == 1, "shadow mode sends everything to the model anyway")
            try expect(store.openSignals().count == 1)
            try expect(!history.allRows().contains { $0.kind == .audit })
        }

        r.run("an audit row stands in for the model's verdict in the cutoff histogram") {
            let (_, history, _) = await run(mode: .live(cutoff: 0.5), roll: 0)
            let points = screeningPoints(from: history.screeningOutcomes(questionVersion: screeningQuestionVersion))
            try expect(points == [ScreeningPoint(probability: 0.1, hadWork: true)])
        }
    }
}
