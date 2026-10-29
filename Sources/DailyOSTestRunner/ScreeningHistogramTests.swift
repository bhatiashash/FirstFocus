import DailyOSApp
import DailyOSCore
import Foundation

/// Ticket 12 (batched-extraction): the cutoff histogram and its readout,
/// from Screening decisions paired with the model's verdict by Batch id.
private func screening(_ ref: String, _ probability: Double, at offset: TimeInterval = 0, chatId: Int = 1) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_000 + offset), sourceRawText: ref, modelUsed: "JEV",
        signalCount: 0, chatId: chatId, renderedContext: "input \(ref)",
        kind: .screening(ScreeningDecision(probability: probability, mode: .shadow)), sourceRef: ref
    )
}

private func extraction(_ ref: String?, signals: Int, at offset: TimeInterval = 1, kind: HistoryEntryKind = .extraction) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_000 + offset), sourceRawText: ref ?? "", rawOutput: signals > 0 ? "Task" : "NONE",
        modelUsed: "Model", signalCount: signals, kind: kind, sourceRef: ref
    )
}

/// A "This was work" Correction as `Corrections` records it: on the Batch,
/// with only the Batch's last lines as its example, never the whole prompt.
private func thisWasWork(_ ref: String, chatId: Int = 1) -> Correction {
    Correction(chatId: chatId, sourceRef: ref, inputText: "last lines of \(ref)", correctedOutput: "", correctionType: .falseNegative)
}

/// The histogram's points for `entries` recorded in a real store, with
/// `markedAsWork` Batches carrying a "This was work" Correction. A row that
/// fails to record is simply missing, which the caller's check catches.
private func points(_ entries: [HistoryEntry], markedAsWork: Set<String> = []) -> [ScreeningPoint] {
    let store = makeTestHistoryStore()
    for entry in entries { try? store.record(entry) }
    return screeningPoints(from: store.screeningOutcomes(questionVersion: screeningQuestionVersion), markedAsWork: markedAsWork)
        .sorted { $0.probability < $1.probability }
}

func registerScreeningHistogramTests(_ runner: TestRunner) {
    runner.suite("screeningPoints") { r in
        r.run("pairs each Screening row with the model's verdict on the same Batch") {
            let entries = [
                screening("a", 0.05), extraction("a", signals: 0),
                screening("b", 0.25), extraction("b", signals: 1),
                screening("c", 0.97), extraction("c", signals: 0, kind: .audit),
            ]
            try expect(points(entries) == [
                ScreeningPoint(probability: 0.05, hadWork: false),
                ScreeningPoint(probability: 0.25, hadWork: true),
                ScreeningPoint(probability: 0.97, hadWork: false),
            ])
        }
        r.run("a Screening row with no verdict, or a verdict with no Screening row, is ignored") {
            let entries = [screening("lonely", 0.05), extraction("unscreened", signals: 1), extraction(nil, signals: 1)]
            try expect(points(entries).isEmpty)
        }
        r.run("a Batch's own intake call is what's paired, not a later Re-run of it") {
            let entries = [screening("a", 0.05, at: 0), extraction("a", signals: 0, at: 1), extraction("a", signals: 3, at: 50, kind: .rerun)]
            try expect(points(entries) == [ScreeningPoint(probability: 0.05, hadWork: false)])
        }
        r.run("a This was work Correction counts its Batch as work, with or without a model verdict") {
            let entries = [screening("a", 0.05), screening("b", 0.1), extraction("b", signals: 0)]
            try expect(points(entries, markedAsWork: ["a", "b"]) == [
                ScreeningPoint(probability: 0.05, hadWork: true), ScreeningPoint(probability: 0.1, hadWork: true),
            ])
        }
        r.run("a This was work Correction on another Batch in the same Chat doesn't mark the point") {
            let entries = [screening("a", 0.05), extraction("a", signals: 0)]
            try expect(points(entries, markedAsWork: ["b"]) == [ScreeningPoint(probability: 0.05, hadWork: false)])
        }
        r.run("a score from an earlier wording of the Screening question is left out") {
            let old = HistoryEntry(
                sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 7,
                kind: .screening(ScreeningDecision(probability: 0.2, mode: .shadow, questionVersion: screeningQuestionVersion - 1)),
                sourceRef: "old"
            )
            let entries = [old, extraction("old", signals: 1), screening("new", 0.3), extraction("new", signals: 0)]
            try expect(points(entries) == [ScreeningPoint(probability: 0.3, hadWork: false)])
        }
    }

    runner.suite("screeningHistogram and cutoffReadout (pure)") { r in
        let points = [
            ScreeningPoint(probability: 0.02, hadWork: false),
            ScreeningPoint(probability: 0.04, hadWork: true),
            ScreeningPoint(probability: 0.51, hadWork: false),
            ScreeningPoint(probability: 1.0, hadWork: true),
        ]
        r.run("twenty 0.05-wide bins, each split into work and nothing") {
            let bins = screeningHistogram(points)
            try expect(bins.count == 20)
            try expect(bins[0].lower == 0 && bins[0].work == 1 && bins[0].nothing == 1)
            try expect(bins[10].work == 0 && bins[10].nothing == 1, "0.51 lands in [0.50, 0.55)")
            try expect(bins[19].work == 1, "a score of exactly 1 goes in the last bin")
            try expect(screeningHistogram([ScreeningPoint(probability: 0.15, hadWork: true)])[3].work == 1,
                       "a score on an edge goes in the bin it starts")
            try expect(bins.reduce(0) { $0 + $1.work + $1.nothing } == points.count)
        }
        r.run("the readout at a cutoff is what live mode would drop: everything scored below it") {
            try expect(cutoffReadout(points, cutoff: 0.5) == CutoffReadout(wouldScreen: 2, hadWork: 1))
            try expect(cutoffReadout(points, cutoff: 0.51) == CutoffReadout(wouldScreen: 2, hadWork: 1), "live drops only strictly below")
            try expect(cutoffReadout(points, cutoff: 0.52) == CutoffReadout(wouldScreen: 3, hadWork: 1))
        }
    }

    runner.suite("ScreeningSettingsViewModel: the histogram") { r in
        r.run("reads History and This was work Corrections, and dragging never changes the stored cutoff") {
            let history = makeTestHistoryStore()
            try history.record(screening("a", 0.05))
            try history.record(extraction("a", signals: 0))
            try history.record(screening("b", 0.3))
            try history.record(screening("c", 0.35))
            let corrections = FakeCorrectionStore()
            try corrections.record(thisWasWork("b"))
            try corrections.record(thisWasWork("d"))
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            let viewModel = await MainActor.run {
                ScreeningSettingsViewModel(
                    settings: settings, keyStore: FakeAPIKeyStore(), extraction: TestExtraction().host, historyStore: history,
                    correctionLog: corrections
                )
            }
            try await MainActor.run {
                try expect(viewModel.points.count == 2, "c has no verdict, and the Correction on d is another Batch in the same Chat")
                viewModel.candidateCutoff = 0.4
                try expect(viewModel.readout == CutoffReadout(wouldScreen: 2, hadWork: 1))
                try expect(settings.cutoff == nil, "dragging alone stores nothing")
                viewModel.setCutoff(viewModel.candidateCutoff)
                try expect(settings.cutoff == 0.4)
            }
        }
    }
}
