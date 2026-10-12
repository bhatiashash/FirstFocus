import DailyOSApp
import DailyOSCore
import Foundation

@MainActor
private func makeApp() -> HistoryApp {
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    let suggestion = Signal(
        id: "s1", source: .messages, sourceRef: "m1", label: "Read shareholder notice",
        originalText: "shareholder notice", createdAt: Date(), provenance: .inferred
    )
    let other = Signal(
        id: "s2", source: .messages, sourceRef: "m2", label: "Book the flights",
        originalText: "book the flights", createdAt: Date(), provenance: .inferred
    )
    try? store.recordOneMessageBatch("m1", signals: [suggestion])
    try? store.recordOneMessageBatch("m2", signals: [other])
    return makeHistoryApp(signals: store)
}

private func row(sourceRef: String?) -> HistoryEntry {
    HistoryEntry(
        sourceRawText: "shareholder notice", rawOutput: "Read shareholder notice", modelUsed: "Model",
        signalCount: 1, chatId: 1291, renderedContext: "Participant A: shareholder notice", sourceRef: sourceRef
    )
}

func registerNotForMeDismissesTests(_ runner: TestRunner) {
    runner.suite("\"Not for me\" also dismisses the Signal it produced (ADR 0031 amendment)") { r in
        r.run("records the Correction and dismisses that message's open Signal, leaving others") {
            let app = await MainActor.run { makeApp() }
            await app.model.start()
            let batch = historyBatch(row(sourceRef: "m1"))
            try await MainActor.run {
                app.actions.notForMe(batch)
                try expect(app.actions.offered(.notForMe, for: batch) == .taken)
                let all = app.model.rankedList.suggested + app.model.rankedList.focus + app.model.rankedList.later
                try expect(all.map(\.label) == ["Book the flights"], "got \(all.map(\.label))")
            }
            try expect(!app.signals.openSignals().contains { $0.id == "s1" }, "the dismissal must be stored, not just hidden")
        }

        r.run("a row with no message id isn't offered Not for me, and clicking it changes nothing") {
            let app = await MainActor.run { makeApp() }
            await app.model.start()
            let batch = historyBatch(row(sourceRef: nil))
            try await MainActor.run {
                try expect(app.actions.offered(.notForMe, for: batch) == nil)
                app.actions.notForMe(batch)
                try expect(app.model.corrections.falsePositives(since: nil).isEmpty)
            }
            try expect(app.signals.openSignals().count == 2)
        }
    }
}
