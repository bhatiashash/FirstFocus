import DailyOSApp
import DailyOSCore
import Foundation

/// Ticket 10 (batched-extraction): History's Review filter shows only
/// Borderline rows, Screening rows scored within 0.1 of the cutoff.
private func screeningRow(
    id: String, probability: Double, liveCutoff: Double? = nil, timestamp: Date = Date()
) -> HistoryEntry {
    HistoryEntry(
        id: id, timestamp: timestamp, sourceRawText: "text \(id)", modelUsed: "JEV",
        signalCount: 0, chatId: 1, kind: .screening(ScreeningDecision(probability: probability, mode: liveCutoff.map { .live(cutoff: $0) } ?? .shadow)),
        sourceRef: "m-\(id)"
    )
}

private func extractionRow(id: String) -> HistoryEntry {
    HistoryEntry(id: id, sourceRawText: "text", rawOutput: "Call the dentist", modelUsed: "Model", signalCount: 1, chatId: 1)
}

private func seed(_ store: any HistoryStore) throws {
    try store.record(screeningRow(id: "low", probability: 0.29))
    try store.record(screeningRow(id: "edgeLow", probability: 0.4))
    try store.record(screeningRow(id: "mid", probability: 0.55, liveCutoff: 0.6))
    try store.record(screeningRow(id: "edgeHigh", probability: 0.6))
    try store.record(screeningRow(id: "high", probability: 0.61))
    try store.record(extractionRow(id: "model"))
}

func registerReviewFilterTests(_ runner: TestRunner) {
    runner.suite("isBorderline (pure)") { r in
        r.run("the band is inclusive at exactly 0.1 either side of the cutoff") {
            try expect(isBorderline(screeningRow(id: "a", probability: 0.4), cutoff: 0.5))
            try expect(isBorderline(screeningRow(id: "a", probability: 0.6), cutoff: 0.5))
            try expect(!isBorderline(screeningRow(id: "a", probability: 0.39), cutoff: 0.5))
            try expect(!isBorderline(screeningRow(id: "a", probability: 0.61), cutoff: 0.5))
        }
        r.run("the band moves with the cutoff") {
            try expect(isBorderline(screeningRow(id: "a", probability: 0.25), cutoff: 0.3))
            try expect(!isBorderline(screeningRow(id: "a", probability: 0.45), cutoff: 0.3))
        }
        r.run("with no cutoff set, the band centres on 0.5") {
            try expect(isBorderline(screeningRow(id: "a", probability: 0.45), cutoff: nil))
            try expect(!isBorderline(screeningRow(id: "a", probability: 0.25), cutoff: nil))
        }
        r.run("an extraction row is never Borderline") {
            try expect(!isBorderline(extractionRow(id: "a"), cutoff: 0.5))
        }
    }

    runner.suite("HistoryViewModel: the Borderline view") { r in
        r.run("lists only Borderline Batches, zero-Signal or not") {
            let store = makeTestHistoryStore()
            try seed(store)
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            settings.cutoff = 0.5
            try await MainActor.run {
                let viewModel = makeHistoryApp(history: store).viewModel(screeningSettings: settings)
                viewModel.segment = .borderline
                try expect(Set(viewModel.batches.compactMap(\.sourceRef)) == ["m-edgeLow", "m-mid", "m-edgeHigh"])
            }
        }
    }

    runner.suite("HistoryViewModel: Review") { r in
        r.run("the Review count covers the last seven days only") {
            let store = makeTestHistoryStore()
            let now = Date()
            try store.record(screeningRow(id: "recent", probability: 0.5, timestamp: now.addingTimeInterval(-86_400)))
            try store.record(screeningRow(id: "old", probability: 0.5, timestamp: now.addingTimeInterval(-8 * 86_400)))
            try store.record(screeningRow(id: "far", probability: 0.9, timestamp: now))
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let viewModel = await MainActor.run { makeHistoryApp(history: store).viewModel(screeningSettings: settings) }
            try await MainActor.run { try expect(viewModel.borderlineCountThisWeek == 1) }
        }
        r.run("a Screened Batch still offers This was work") {
            let store = makeTestHistoryStore()
            try seed(store)
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            let app = await MainActor.run { makeHistoryApp(history: store) }
            let viewModel = await MainActor.run {
                let viewModel = app.viewModel(screeningSettings: settings)
                viewModel.showsUnfilteredLog = true
                return viewModel
            }
            let screened = try await MainActor.run { () -> HistoryBatch in
                let batch = try require(viewModel.batches.first { $0.sourceRef == "m-mid" })
                try expect(app.actions.offered(.thisWasWork, for: batch) == .enabled, "the view offers This was work on a Screened Batch")
                return batch
            }
            await app.actions.thisWasWork(screened)
            try await MainActor.run {
                let after = try require(viewModel.batches.first { $0.sourceRef == "m-mid" })
                try expect(viewModel.isCorrected(after))
            }
        }
    }
}
