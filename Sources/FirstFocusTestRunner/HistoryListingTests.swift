import FirstFocusApp
import FirstFocusCore
import Foundation

/// The listing rules and the exports, tested against `HistoryBatch` values
/// with no stores and no AppModel.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func modelRow(
    _ ref: String, output: String, sourceText: String = "text", isStarred: Bool = false
) -> HistoryEntry {
    HistoryEntry(
        timestamp: now, sourceRawText: sourceText, rawOutput: output, modelUsed: "Q",
        signalCount: output == "NONE" ? 0 : 1, isStarred: isStarred, chatId: 1, sourceRef: ref
    )
}

private func screenedRow(_ ref: String, probability: Double) -> HistoryEntry {
    HistoryEntry(
        timestamp: now, sourceRawText: "text", modelUsed: "JEV", signalCount: 0, chatId: 1,
        kind: .screening(ScreeningDecision(probability: probability, mode: .live(cutoff: 0.5))), sourceRef: ref
    )
}

private func facts(
    showsScreening: Bool = true, corrections: [String: Set<CorrectionType>] = [:],
    supersessions: [String: [RecordedSupersession]] = [:]
) -> HistoryFacts {
    HistoryFacts(
        showsScreening: showsScreening, isModelLoaded: true, correctionTypes: corrections,
        supersessions: supersessions, mutedChats: []
    )
}

private func snapshot(
    _ week: [HistoryBatch], pinned: [HistoryBatch] = [], facts: HistoryFacts = facts(), segment: HistorySegment = .overview,
    showsUnfilteredLog: Bool = false
) -> HistorySnapshot {
    historySnapshot(
        week: week, pinned: pinned, facts: facts, cutoff: 0.5, segment: segment, showsUnfilteredLog: showsUnfilteredLog,
        now: now, calendar: Calendar(identifier: .gregorian)
    )
}

private func listedIds(_ snapshot: HistorySnapshot) -> Set<String> {
    Set(snapshot.sections.flatMap(\.batches).map(\.id))
}

func registerHistoryListingTests(_ runner: TestRunner) {
    runner.suite("History listing: the rules, over HistoryBatch values") { r in
        let task = historyBatch(modelRow("task", output: "Call the dentist"))
        let filler = historyBatch(modelRow("filler", output: "NONE"))
        let failed = historyBatch(HistoryEntry(
            timestamp: now, sourceRawText: "text", rawOutput: "", modelUsed: "Q", signalCount: 0, chatId: 1,
            kind: .extractionFailed(reason: "timed out"), sourceRef: "failed"
        ))

        r.run("Overview lists a Batch with a task and leaves the filler out") {
            try expect(listedIds(snapshot([task, filler])) == ["task"])
        }

        r.run("the unfiltered log lists the filler too") {
            try expect(listedIds(snapshot([task, filler], showsUnfilteredLog: true)) == ["task", "filler"])
        }

        r.run("Overview lists a Batch the model failed on, so it isn't silently unjudged") {
            try expect(listedIds(snapshot([failed])) == ["failed"])
        }

        r.run("Overview lists a Batch that was corrected, or that Superseded a Suggestion") {
            let corrected = facts(corrections: ["filler": [.missedTask]])
            try expect(listedIds(snapshot([filler], facts: corrected)) == ["filler"])
            let superseding = facts(supersessions: [
                "filler": [RecordedSupersession(signalId: "s", label: "Old", replacedBy: nil, stands: true, isRestorable: true)]
            ])
            try expect(listedIds(snapshot([filler], facts: superseding)) == ["filler"])
        }

        r.run("a pinned Batch is listed whatever it produced") {
            try expect(listedIds(snapshot([task], pinned: [filler])) == ["task", "filler"])
        }

        r.run("the Starred view lists only starred Batches") {
            let starred = historyBatch(modelRow("starred", output: "NONE", isStarred: true))
            try expect(listedIds(snapshot([task, starred], segment: .starred)) == ["starred"])
        }

        r.run("Borderline exists only while Screening shows") {
            let close = historyBatch(screenedRow("close", probability: 0.5))
            try expect(listedIds(snapshot([close], segment: .borderline)) == ["close"])
            try expect(listedIds(snapshot([close], facts: facts(showsScreening: false), segment: .borderline)).isEmpty)
            try expect(snapshot([close], facts: facts(showsScreening: false)).weekSummary.borderline == 0)
        }

        r.run("the week summary counts every Batch whatever the view lists") {
            let summary = snapshot([task, filler, failed], segment: .starred).weekSummary
            try expect(summary.batches == 3 && summary.tasks == 1)
        }

        r.run("each listed Batch carries its offers") {
            let result = snapshot([task])
            try expect(result.offers["task"]?[.notForMe] == .enabled)
            try expect(result.offers["filler"] == nil)
        }
    }

    runner.suite("History export: pure text from Batches") { r in
        r.run("CSV quotes every field and doubles embedded quotes") {
            let row = modelRow("m1", output: "say \"hi\"", sourceText: "a,b")
            let lines = historyCSV(rows: [row]).split(separator: "\n")
            try expect(lines.count == 2)
            try expect(lines[1].contains("\"a,b\"") && lines[1].contains("\"say \"\"hi\"\"\""))
        }

        r.run("Markdown names the view and cutoff, and fences a model output longer than any backtick run in it") {
            let batch = historyBatch(modelRow("m1", output: "has ``` inside"))
            let text = historyMarkdown(batches: [batch], view: "Overview", cutoff: 0.4, exportedAt: now)
            try expect(text.contains("View: Overview"))
            try expect(text.contains("````\nhas ``` inside\n````"), "four backticks fence a block that holds three")
        }
    }
}
