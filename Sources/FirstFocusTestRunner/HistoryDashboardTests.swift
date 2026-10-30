import FirstFocusApp
import FirstFocusCore
import Foundation

/// The History dashboard spec (.scratch/history-dashboard): one list row per
/// Batch, a detail pane and an Inspector.

/// A fixed moment, midday on a Wednesday, so day sections don't depend on
/// when the suite runs.
let dashboardNow: Date = {
    var components = DateComponents()
    components.year = 2026; components.month = 9; components.day = 23; components.hour = 12
    return dashboardCalendar.date(from: components)!
}()

let dashboardCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

func hoursAgo(_ hours: Double) -> Date { dashboardNow.addingTimeInterval(-hours * 3600) }

func screeningEntry(
    id: String = UUID().uuidString, ref: String, probability: Double, wasScreened: Bool = false, cutoff: Double = 0.4,
    at: Date = dashboardNow, chatId: Int = 1
) -> HistoryEntry {
    // Screened means live mode below the cutoff; anything else is recorded
    // in shadow mode.
    HistoryEntry(
        id: id, timestamp: at, sourceRawText: "text \(ref)", modelUsed: "JEV", signalCount: 0, chatId: chatId,
        kind: .screening(ScreeningDecision(probability: probability, mode: wasScreened ? .live(cutoff: cutoff) : .shadow)),
        sourceRef: ref
    )
}

func extractionEntry(
    id: String = UUID().uuidString, ref: String?, output: String = "Call the dentist", at: Date = dashboardNow,
    chatId: Int? = 1, kind: HistoryEntryKind = .extraction, model: String = "Qwen", source: String? = nil
) -> HistoryEntry {
    let labels = parseExtractionResults(output).compactMap(\.label)
    return HistoryEntry(
        id: id, timestamp: at, sourceRawText: source ?? "text \(ref ?? id)", rawOutput: output, modelUsed: model,
        signalCount: labels.count, chatId: chatId, kind: kind, sourceRef: ref
    )
}

/// History over `entries`, with the real actions of `app` (a fresh app
/// with a fake model loaded when none is passed).
@MainActor
func makeDashboard(
    _ entries: [HistoryEntry], app: HistoryApp? = nil, cutoff: Double? = nil, unfiltered: Bool = true
) throws -> (HistoryViewModel, SQLiteHistoryStore) {
    let app = app ?? makeHistoryApp()
    let store = app.history
    for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) { try store.record(entry) }
    let settings = app.screeningSettings
    settings.cutoff = cutoff
    let viewModel = app.viewModel(now: { dashboardNow }, calendar: dashboardCalendar)
    // Most tests here are about Batches that produced nothing, which
    // Overview leaves out; the Overview tests themselves pass `false`.
    viewModel.showsUnfilteredLog = unfiltered
    return (viewModel, store)
}

@MainActor
private func seeded(
    app: HistoryApp? = nil, cutoff: Double? = 0.5, unfiltered: Bool = true
) throws -> (HistoryViewModel, SQLiteHistoryStore) {
    try makeDashboard([
        screeningEntry(ref: "edge", probability: 0.4, at: hoursAgo(5)),
        extractionEntry(ref: "edge", at: hoursAgo(5)),
        screeningEntry(ref: "outside", probability: 0.39, wasScreened: true, at: hoursAgo(4)),
        screeningEntry(ref: "far", probability: 0.9, at: hoursAgo(3)),
        extractionEntry(id: "far-model", ref: "far", output: "NONE", at: hoursAgo(3)),
        extractionEntry(ref: "plain", at: hoursAgo(2)),
    ], app: app, cutoff: cutoff, unfiltered: unfiltered)
}

@MainActor
private func badgeTexts(_ viewModel: HistoryViewModel, _ id: String) -> [String] {
    guard let batch = viewModel.batches.first(where: { $0.id == id }) else { return ["<no Batch \(id)>"] }
    return viewModel.badges(for: batch).map(\.text)
}

private let transcriptStart = Date().addingTimeInterval(-600)

private func message(_ id: String, _ text: String, from address: String? = nil, at seconds: TimeInterval, selfThread: Bool = false) -> ChatMessage {
    ChatMessage(
        id: id, chatId: 5, isFromMe: address == nil, text: text, createdAt: transcriptStart.addingTimeInterval(seconds),
        senderAddress: address, isSelfThread: selfThread
    )
}

private func momResolver() -> FakeContactsResolver { FakeContactsResolver(names: ["+15550001": "Mom"]) }

func registerHistoryDashboardTests(_ runner: TestRunner) {
    runner.suite("Re-run row kind (ticket 01)") { r in
        r.run("Re-run records its row as kind rerun, not extraction") {
            let store = makeTestHistoryStore()
            let original = HistoryEntry(
                id: "h1", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A",
                signalCount: 1, chatId: 1, sourceRef: "m1"
            )
            try store.record(original)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"], modelDisplayName: "Model B")
            try await rerunHistoryEntry(original, extractor: extractor, historyStore: store)
            let rerun = try require(store.allRows().first { $0.id != "h1" })
            try expect(rerun.kind == .rerun)
            try expect(rerun.kind.storageName == "rerun")
            try expect(rerun.sourceRef == "m1")
        }

        r.run("a rerun row round-trips through SQLite") {
            let store = makeTestHistoryStore()
            try store.record(HistoryEntry(
                id: "r1", sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 1, kind: .rerun, sourceRef: "m1"
            ))
            let fetched = try require(store.allRows().first)
            try expect(fetched.kind == .rerun)
        }

        r.run("a rerun row counts as a model call for Not for me") {
            let row = HistoryEntry(
                sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 1, chatId: 1, kind: .rerun, sourceRef: "m1"
            )
            try await MainActor.run {
                try expect(makeHistoryApp().actions.offered(.notForMe, for: historyBatch(row)) == .enabled)
            }
        }

        r.run("a rerun row is never a Screening verdict in the cutoff histogram") {
            let store = makeTestHistoryStore()
            try store.record(screeningEntry(ref: "m1", probability: 0.3))
            try store.record(extractionEntry(ref: "m1", kind: .rerun))
            try expect(screeningPoints(from: store.screeningOutcomes(questionVersion: screeningQuestionVersion)).isEmpty)
        }
    }

    runner.suite("History lists Batches (ticket 02)") { r in
        r.run("rows sharing a sourceRef become one Batch; a row with no sourceRef is its own") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "m1", probability: 0.7, at: hoursAgo(3)),
                    extractionEntry(ref: "m1", at: hoursAgo(2.9)),
                    extractionEntry(ref: "m1", output: "Book the dentist", at: hoursAgo(1), kind: .rerun),
                    extractionEntry(id: "legacy", ref: nil, at: hoursAgo(2)),
                ])
                let batches = viewModel.sections.flatMap(\.batches)
                try expect(batches.count == 2, "got \(batches.map(\.id))")
                let m1 = try require(batches.first { $0.sourceRef == "m1" })
                try expect(m1.rows.count == 3)
                try expect(m1.result == .tasks(["Call the dentist"]), "the result comes from intake's row, not the Re-run")
                try expect(m1.reruns.map(\.rawOutput) == ["Book the dentist"])
            }
        }

        r.run("on legacy data, later extraction rows for the same Batch count as Re-runs") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "m1", output: "NONE", at: hoursAgo(3)),
                    extractionEntry(ref: "m1", output: "Call the dentist", at: hoursAgo(1)),
                ])
                let batch = try require(viewModel.sections.first?.batches.first)
                try expect(batch.result == .noTask)
                try expect(batch.reruns.count == 1)
            }
        }

        r.run("a Screened Batch reports its score and the cutoff it was below") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([screeningEntry(ref: "m1", probability: 0.12, wasScreened: true)])
                let batch = try require(viewModel.sections.first?.batches.first)
                try expect(batch.result == .screened(probability: 0.12, cutoff: 0.4))
                try expect(batch.resultSummary == "Screened at 0.12, below the 0.40 cutoff.", "got \(batch.resultSummary)")
            }
        }

        r.run("This was work's extraction row becomes the Screened Batch's result") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "m1", probability: 0.12, wasScreened: true, at: hoursAgo(2)),
                    extractionEntry(ref: "m1", output: "Send the invoice", at: hoursAgo(1)),
                ])
                let batch = try require(viewModel.sections.first?.batches.first)
                try expect(batch.result == .tasks(["Send the invoice"]))
            }
        }

        r.run("a model call that found nothing says so") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: "m1", output: "NONE")])
                let batch = try require(viewModel.sections.first?.batches.first)
                try expect(batch.result == .noTask)
                try expect(batch.resultSummary == "The model found no task.")
            }
        }

        r.run("only the last seven days are listed, and older rows stay in the store") {
            try await MainActor.run {
                let (viewModel, store) = try makeDashboard([
                    extractionEntry(ref: "recent", at: hoursAgo(6 * 24)),
                    extractionEntry(ref: "old", at: hoursAgo(8 * 24)),
                ])
                try expect(viewModel.sections.flatMap(\.batches).map(\.id) == ["recent"])
                try expect(store.allRows().count == 2)
            }
        }

        r.run("Batches group under Today, Yesterday and weekday names, newest first") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "today", at: hoursAgo(1)),
                    extractionEntry(ref: "todayEarly", at: hoursAgo(11)),
                    extractionEntry(ref: "yesterday", at: hoursAgo(24)),
                    extractionEntry(ref: "monday", at: hoursAgo(48)),
                    extractionEntry(ref: "thursday", at: hoursAgo(6 * 24)),
                ])
                try expect(viewModel.sections.map(\.title) == ["Today", "Yesterday", "Monday", "Thursday"], "got \(viewModel.sections.map(\.title))")
                try expect(viewModel.sections[0].batches.map(\.id) == ["today", "todayEarly"])
            }
        }

        r.run("the first Batch is selected, and a deleted selection falls back to the first row") {
            try await MainActor.run {
                let (viewModel, store) = try makeDashboard([
                    screeningEntry(ref: "a", probability: 0.8, at: hoursAgo(2)),
                    extractionEntry(ref: "a", at: hoursAgo(2)),
                    extractionEntry(ref: "b", at: hoursAgo(1)),
                ])
                try expect(viewModel.selectedBatchId == "b")
                viewModel.selectedBatchId = "a"
                let a = try require(viewModel.selectedBatch)
                viewModel.delete(a)
                try expect(store.allRows().allSatisfy { $0.sourceRef != "a" }, "every row of the Batch is deleted")
                try expect(viewModel.selectedBatchId == "b")
            }
        }

        r.run("deleting a legacy Batch deletes its one row") {
            try await MainActor.run {
                let (viewModel, store) = try makeDashboard([extractionEntry(id: "legacy", ref: nil)])
                viewModel.delete(try require(viewModel.selectedBatch))
                try expect(store.allRows().isEmpty)
            }
        }

        r.run("a Re-run lands on the same list row") {
            let extractor = FakeIntentExtractor(defaultResponse: "Book it")
            let app = await MainActor.run { makeHistoryApp(extractor: extractor) }
            await app.model.extraction.load()
            let (viewModel, _) = try await MainActor.run {
                try makeDashboard([
                    extractionEntry(id: "h1", ref: "m1", at: hoursAgo(2)),
                    extractionEntry(ref: "m1", output: "Book the dentist", at: hoursAgo(1), kind: .rerun, source: "an earlier Re-run's input"),
                ], app: app)
            }
            let batch = try await MainActor.run { try require(viewModel.selectedBatch) }
            await app.actions.rerun(batch)
            try expect(extractor.calls == ["text m1"], "Re-run replays intake's row; got \(extractor.calls)")
            try await MainActor.run {
                try expect(viewModel.sections.flatMap(\.batches).count == 1)
                try expect(viewModel.selectedBatch?.reruns.map(\.rawOutput) == ["Book the dentist", "Book it"])
            }
        }

        r.run("This was work is offered only on a Screened Batch with no model result, and records from its Screening row") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, _) = try await MainActor.run {
                try makeDashboard([screeningEntry(id: "s1", ref: "m1", probability: 0.1, wasScreened: true)], app: app)
            }
            let batch = try await MainActor.run { try require(viewModel.selectedBatch) }
            try await MainActor.run {
                try expect(app.actions.offered(.thisWasWork, for: batch) == .enabled)
                try expect(app.actions.offered(.notForMe, for: batch) == nil)
                try expect(app.actions.offered(.rerun, for: batch) == nil)
            }
            await app.actions.thisWasWork(batch)
            try await MainActor.run { try expect(app.model.corrections.types(forBatches: ["m1"]) == ["m1": [.falseNegative]]) }
        }

        r.run("a Batch reads as flagged whichever of its model calls the Correction was recorded from") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let rerun = extractionEntry(id: "r1", ref: "m1", at: hoursAgo(1), kind: .rerun)
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(id: "h1", ref: "m1", at: hoursAgo(2)),
                    rerun,
                ], app: app)
                try app.model.corrections.recordNotForMe(rerun)
                viewModel.refresh()
                let batch = try require(viewModel.selectedBatch)
                try expect(app.actions.offered(.notForMe, for: batch) == .taken, "the flag belongs to the Batch, not to one row's prompt")
                try expect(viewModel.isCorrected(batch))
            }
        }

        r.run("This was work on a Screened Batch counts it as Corrected") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, batch) = try await MainActor.run { () -> (HistoryViewModel, HistoryBatch) in
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(id: "s1", ref: "m2", probability: 0.1, wasScreened: true, at: hoursAgo(1)),
                ], app: app)
                return (viewModel, try require(viewModel.selectedBatch))
            }
            await app.actions.thisWasWork(batch)
            try await MainActor.run {
                let after = try require(viewModel.batches.first { $0.sourceRef == "m2" })
                try expect(viewModel.isCorrected(after))
                try expect(viewModel.weekSummary.corrected == 1)
            }
        }

        r.run("Not for me flags intake's row and reads back as set") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "m1", probability: 0.9, at: hoursAgo(1)),
                    HistoryEntry(
                        id: "h1", timestamp: hoursAgo(1), sourceRawText: "text m1", rawOutput: "Call the dentist",
                        modelUsed: "Qwen", signalCount: 1, chatId: 1, renderedContext: "intake's prompt", sourceRef: "m1"
                    ),
                ], app: app)
                let batch = try require(viewModel.selectedBatch)
                try expect(app.actions.offered(.notForMe, for: batch) == .enabled)
                try expect(app.actions.offered(.thisWasWork, for: batch) == nil)
                app.actions.notForMe(batch)
                try expect(app.model.corrections.falsePositives(since: nil).map(\.inputText) == ["intake's prompt"])
                try expect(app.actions.offered(.notForMe, for: batch) == .taken)
            }
        }

        r.run("starring a Batch stars intake's row, and unstarring clears every star on it") {
            try await MainActor.run {
                let (viewModel, store) = try makeDashboard([
                    screeningEntry(id: "s1", ref: "m1", probability: 0.9, at: hoursAgo(1)),
                    extractionEntry(id: "h1", ref: "m1", at: hoursAgo(1)),
                ])
                viewModel.toggleStar(try require(viewModel.selectedBatch))
                try expect(store.allRows().filter(\.isStarred).map(\.id) == ["h1"])
                try expect(viewModel.selectedBatch?.isStarred == true)
                viewModel.toggleStar(try require(viewModel.selectedBatch))
                try expect(store.allRows().allSatisfy { !$0.isStarred })
            }
        }

        r.run("Mute toggles the Batch's Chat") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: "m1", chatId: 42)], app: app)
                let batch = try require(viewModel.selectedBatch)
                app.actions.toggleMute(batch)
                try expect(app.actions.isMutedNow(batch))
                try expect(badgeTexts(viewModel, "m1") == ["Task", "Muted"])
                app.actions.toggleMute(batch)
                try expect(!app.actions.isMutedNow(batch))
                try expect(badgeTexts(viewModel, "m1") == ["Task"])
            }
        }

        r.run("a Batch with no Chat can't be muted or flagged") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: nil, chatId: nil)], app: app)
                let batch = try require(viewModel.selectedBatch)
                try expect(app.actions.offered(.mute, for: batch) == nil)
                try expect(app.actions.offered(.notForMe, for: batch) == nil)
                app.actions.toggleMute(batch)
                try expect(app.actions.facts(forBatches: []).mutedChats.isEmpty)
            }
        }

        r.run("the SQLite store deletes every row with a sourceRef and nothing else") {
            let store = makeTestHistoryStore()
            try store.record(screeningEntry(id: "s1", ref: "m1", probability: 0.5))
            try store.record(extractionEntry(id: "e1", ref: "m1"))
            try store.record(extractionEntry(id: "e2", ref: "m2"))
            try store.delete(sourceRef: "m1")
            try expect(store.allRows().map(\.id) == ["e2"])
        }
    }

    runner.suite("Toolbar view switcher (ticket 03)") { r in
        r.run("Overview, the default, lists Batches that produced a task plus Borderline and Corrected ones") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, _) = try await MainActor.run { try seeded(app: app, unfiltered: false) }
            try await MainActor.run {
                try expect(viewModel.segment == .overview)
                try expect(Set(viewModel.batches.map(\.id)) == ["edge", "plain"], "got \(viewModel.batches.map(\.id))")
                viewModel.showsUnfilteredLog = true
            }
            let outside = try await MainActor.run { try require(viewModel.batches.first { $0.id == "outside" }) }
            await app.actions.thisWasWork(outside)
            try await MainActor.run {
                viewModel.showsUnfilteredLog = false
                try expect(Set(viewModel.batches.map(\.id)) == ["edge", "plain", "outside"], "a Corrected Batch is listed")
            }
        }

        r.run("the unfiltered log lists every Batch, including those that produced nothing") {
            try await MainActor.run {
                let (viewModel, _) = try seeded(unfiltered: false)
                viewModel.showsUnfilteredLog = true
                try expect(Set(viewModel.batches.map(\.id)) == ["edge", "outside", "far", "plain"])
            }
        }

        r.run("Borderline lists Batches scored within 0.1 of the cutoff, inclusive") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.segment = .borderline
                try expect(viewModel.batches.map(\.id) == ["edge"], "got \(viewModel.batches.map(\.id))")
            }
        }

        r.run("Borderline centres on the default cutoff while none is set") {
            try await MainActor.run {
                let (viewModel, _) = try seeded(cutoff: nil)
                viewModel.segment = .borderline
                try expect(viewModel.batches.map(\.id) == ["edge"])
            }
        }

        r.run("Corrected lists Batches marked Not for me or This was work") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, _) = try await MainActor.run { try seeded(app: app) }
            let (plain, outside) = try await MainActor.run {
                (try require(viewModel.batches.first { $0.id == "plain" }), try require(viewModel.batches.first { $0.id == "outside" }))
            }
            await MainActor.run { app.actions.notForMe(plain) }
            await app.actions.thisWasWork(outside)
            try await MainActor.run {
                viewModel.segment = .corrected
                try expect(Set(viewModel.batches.map(\.id)) == ["plain", "outside"], "got \(viewModel.batches.map(\.id))")
            }
        }

        r.run("Starred lists Batches with a starred row") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.toggleStar(try require(viewModel.batches.first { $0.id == "far" }))
                viewModel.segment = .starred
                try expect(viewModel.batches.map(\.id) == ["far"])
            }
        }

        r.run("the Borderline count covers the week whatever view is showing") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.segment = .starred
                try expect(viewModel.borderlineCountThisWeek == 1)
            }
        }

        r.run("switching views keeps the selection when its Batch is listed, and falls back to the first row when not") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.selectedBatchId = "edge"
                viewModel.segment = .borderline
                try expect(viewModel.selectedBatchId == "edge")
                viewModel.segment = .overview
                viewModel.selectedBatchId = "plain"
                viewModel.segment = .borderline
                try expect(viewModel.selectedBatchId == "edge")
            }
        }

        r.run("an empty view has no selection and its own empty message") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.segment = .starred
                try expect(viewModel.batches.isEmpty)
                try expect(viewModel.selectedBatchId == nil)
                try expect(viewModel.segment.emptyMessage == "No starred Batches in the last 7 days")
            }
        }
    }

    runner.suite("Status badges (ticket 04)") { r in
        r.run("each outcome gets its own primary badge") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "one", at: hoursAgo(1)),
                    extractionEntry(ref: "two", output: "Call the dentist\nBuy milk", at: hoursAgo(1)),
                    extractionEntry(ref: "none", output: "NONE", at: hoursAgo(1)),
                    screeningEntry(ref: "screened", probability: 0.12, wasScreened: true, at: hoursAgo(1)),
                    HistoryEntry(
                        timestamp: hoursAgo(1), sourceRawText: "x", modelUsed: "JEV",
                        signalCount: 0, chatId: 1, kind: .screeningFailed(reason: "timeout"), sourceRef: "failed"
                    ),
                ], cutoff: 0.9)
                try expect(badgeTexts(viewModel, "one") == ["Task"])
                try expect(badgeTexts(viewModel, "two") == ["2 tasks"])
                try expect(badgeTexts(viewModel, "none").isEmpty, "a routine outcome carries no badge")
                try expect(badgeTexts(viewModel, "screened").isEmpty)
                try expect(badgeTexts(viewModel, "failed") == ["Screening failed"])
            }
        }

        r.run("Borderline is added at exactly 0.1 from the cutoff and not beyond") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "in", probability: 0.4, at: hoursAgo(1)),
                    extractionEntry(ref: "in", at: hoursAgo(1)),
                    screeningEntry(ref: "out", probability: 0.39, at: hoursAgo(1)),
                    extractionEntry(ref: "out", at: hoursAgo(1)),
                ], cutoff: 0.5)
                try expect(badgeTexts(viewModel, "in") == ["Task", "Borderline 0.40"])
                try expect(badgeTexts(viewModel, "out") == ["Task"])
            }
        }

        r.run("a Screened Batch overturned with This was work reads Task and Corrected") {
            let app = await MainActor.run { makeHistoryApp() }
            await app.model.extraction.load()
            let (viewModel, store) = try await MainActor.run {
                try makeDashboard([screeningEntry(ref: "m1", probability: 0.12, wasScreened: true, at: hoursAgo(2))], app: app, cutoff: 0.9)
            }
            let batch = try await MainActor.run { try require(viewModel.selectedBatch) }
            await app.actions.thisWasWork(batch)
            try store.record(extractionEntry(ref: "m1", output: "Send the invoice", at: hoursAgo(1)))
            try await MainActor.run {
                viewModel.refresh()
                try expect(badgeTexts(viewModel, "m1") == ["Task", "Corrected"])
            }
        }

        r.run("Not for me adds Corrected") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: "m1")], app: app)
                app.actions.notForMe(try require(viewModel.selectedBatch))
                try expect(badgeTexts(viewModel, "m1") == ["Task", "Corrected"])
            }
        }

        r.run("every badge carries a symbol as well as text, and Muted can be produced") {
            let batch = HistoryBatch(id: "b", rows: [extractionEntry(ref: "b")])
            let badges = historyBadges(for: batch, cutoff: 0.5, isCorrected: true, isMuted: true)
            try expect(badges.map(\.text) == ["Task", "Corrected", "Muted"])
            try expect(badges.allSatisfy { !$0.symbol.isEmpty })
        }
    }

    runner.suite("Sender and transcript (ticket 05)") { r in
        r.run("an extraction row carries the resolved Sender and the transcript; the prompt keeps Participant Labels") {
            let history = makeTestHistoryStore()
            let deps = ExtractionDependencies(
                store: makeTestSignalStore(), extractor: FakeIntentExtractor(defaultResponse: "Grab bread"), contactsResolver: momResolver(),
                historyStore: history
            )
            _ = await refreshThroughIntake(from: [
                message("m1", "can you grab milk", from: "+15550001", at: 0),
                message("m2", "no", at: 5),
                message("m3", "okay, just bread then", from: "+15550009", at: 10),
            ], deps: deps)
            let row = try require(history.allRows().first)
            try expect(row.sender == "+15550009", "the newest other person, raw address when Contacts has no match")
            try expect(row.transcript?.map(\.speaker) == ["Mom", "You", "+15550009"])
            try expect(row.transcript?.map(\.isFromMe) == [false, true, false])
            try expect(row.transcript?.map(\.text) == ["can you grab milk", "no", "okay, just bread then"])
            try expect(!row.renderedContext.contains("Mom"), "the model's prompt never carries a Contacts name")
        }

        r.run("Screening rows carry them too, including a Screened Batch's") {
            let history = makeTestHistoryStore()
            let deps = ExtractionDependencies(
                store: makeTestSignalStore(), extractor: FakeIntentExtractor(defaultResponse: "NONE"), contactsResolver: momResolver(),
                historyStore: history, screener: FakeScreener(probability: 0.05), screeningMode: .live(cutoff: 0.5),
                randomUnit: { 0.99 }
            )
            _ = await refreshThroughIntake(from: [message("m1", "can you call the dentist", from: "+15550001", at: 0)], deps: deps)
            let screening = try require(history.allRows().first { $0.isScreening })
            try expect(screening.wasScreened)
            try expect(screening.sender == "Mom")
            try expect(screening.transcript?.map(\.speaker) == ["Mom"])
            try expect(!screening.renderedContext.contains("Mom"))
        }

        r.run("a Self-thread note's Sender is You") {
            let history = makeTestHistoryStore()
            let deps = ExtractionDependencies(
                store: makeTestSignalStore(), extractor: FakeIntentExtractor(defaultResponse: "Buy milk"), contactsResolver: momResolver(),
                historyStore: history
            )
            _ = await refreshThroughIntake(from: [message("m1", "buy milk", at: 0, selfThread: true)], deps: deps)
            let row = try require(history.allRows().first)
            try expect(row.isSelfThread && row.isAllMine && row.sender == nil, "a fact, not the word You")
            try expect(groupHistoryIntoBatches([row]).first?.sender == "You")
            try expect(row.transcript?.map(\.speaker) == ["You"])
        }

        r.run("a Batch that is all mine names the Chat's other party from context") {
            let history = makeTestHistoryStore()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m0", signals: [])
            let deps = ExtractionDependencies(
                store: store, extractor: FakeIntentExtractor(defaultResponse: "Call the dentist"), contactsResolver: momResolver(),
                historyStore: history
            )
            _ = await refreshThroughIntake(from: [
                message("m0", "did you call the dentist", from: "+15550001", at: -300),
                message("m1", "I will call the dentist tomorrow", at: 0),
            ], deps: deps)
            let row = try require(history.allRows().first)
            try expect(row.sender == "Mom", "got \(row.sender ?? "nil")")
        }

        r.run("sender and transcript round-trip through SQLite, and an old row reads them back as absent") {
            let store = makeTestHistoryStore()
            let lines = [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "hi, \"there\"", sentAt: Date(timeIntervalSince1970: 1_000))]
            try store.record(HistoryEntry(
                id: "new", sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 1, sender: "Mom", transcript: lines
            ))
            try store.record(HistoryEntry(id: "old", sourceRawText: "y", rawOutput: "Y", modelUsed: "M", signalCount: 1))
            let rows = store.allRows()
            let new = try require(rows.first { $0.id == "new" })
            try expect(new.sender == "Mom")
            try expect(new.transcript == lines)
            let old = try require(rows.first { $0.id == "old" })
            try expect(old.sender == nil && old.transcript == nil)
        }

        r.run("a Batch shows its Sender and first message; a legacy row falls back to its raw text") {
            try await MainActor.run {
                var withTranscript = extractionEntry(ref: "m1", at: hoursAgo(1))
                withTranscript = HistoryEntry(
                    id: withTranscript.id, timestamp: withTranscript.timestamp, sourceRawText: "Participant A: hi\nParticipant A: call me",
                    rawOutput: "Call Mom", modelUsed: "Q", signalCount: 1, chatId: 1, sourceRef: "m1", sender: "Mom",
                    transcript: [
                        HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "hi", sentAt: hoursAgo(1)),
                        HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "call me", sentAt: hoursAgo(1)),
                    ]
                )
                let (viewModel, _) = try makeDashboard([
                    withTranscript, extractionEntry(ref: nil, at: hoursAgo(2), source: "line one\nline two"),
                ])
                let batch = try require(viewModel.batches.first { $0.id == "m1" })
                try expect(batch.sender == "Mom")
                try expect(batch.preview == "hi", "the preview is the Batch's first line")
                let legacy = try require(viewModel.batches.first { $0.id != "m1" })
                try expect(legacy.sender == nil)
                try expect(legacy.transcript == nil)
                try expect(legacy.preview == "line one")
            }
        }
    }

    runner.suite("Inspector (ticket 06)") { r in
        r.run("a live Screening decision shows its score, cutoff and mode") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "m1", probability: 0.12, wasScreened: true),
                ])
                let inspection = viewModel.inspection(for: try require(viewModel.selectedBatch))
                let screening = try require(inspection.screening)
                try expect(screening.probability == 0.12)
                try expect(screening.cutoff == 0.4)
                try expect(screening.mode == .live)
                try expect(screening.service == "JEV")
                try expect(inspection.modelCall == nil)
                try expect(inspection.reruns.isEmpty && inspection.audit == nil && inspection.screeningFailure == nil)
                try expect(inspection.messageId == "m1" && inspection.chatId == 1)
            }
        }

        r.run("a shadow Screening decision has no cutoff") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([screeningEntry(ref: "m1", probability: 0.7)])
                let screening = try require(viewModel.inspection(for: try require(viewModel.selectedBatch)).screening)
                try expect(screening.mode == .shadow)
                try expect(screening.cutoff == nil)
            }
        }

        r.run("the model call, its prompt, Re-runs and the Audit Sample are shown verbatim") {
            try await MainActor.run {
                let intake = HistoryEntry(
                    timestamp: hoursAgo(3), sourceRawText: "x", rawOutput: "  Call the dentist \n", modelUsed: "Qwen",
                    signalCount: 1, chatId: 1, renderedContext: "[latest messages]\nParticipant A: call the dentist", sourceRef: "m1"
                )
                let (viewModel, _) = try makeDashboard([
                    intake,
                    extractionEntry(ref: "m1", output: "Book dentist", at: hoursAgo(2), kind: .rerun, model: "Gemma"),
                    extractionEntry(ref: "m1", output: "NONE", at: hoursAgo(1), kind: .audit),
                ])
                let inspection = viewModel.inspection(for: try require(viewModel.selectedBatch))
                try expect(inspection.modelCall?.rawOutput == "  Call the dentist \n", "raw output is never trimmed or parsed")
                try expect(inspection.modelCall?.modelUsed == "Qwen")
                try expect(inspection.prompt == "[latest messages]\nParticipant A: call the dentist")
                try expect(inspection.reruns.map(\.modelUsed) == ["Gemma"])
                try expect(inspection.audit?.rawOutput == "NONE")
            }
        }

        r.run("a Screening failure shows its reason") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    HistoryEntry(
                        sourceRawText: "x", modelUsed: "JEV", signalCount: 0, chatId: 1,
                        kind: .screeningFailed(reason: "timeout"), sourceRef: "m1"
                    ),
                ])
                let failure = try require(viewModel.inspection(for: try require(viewModel.selectedBatch)).screeningFailure)
                try expect(failure.reason == "timeout")
                try expect(failure.service == "JEV")
            }
        }
    }

    runner.suite("Muted Chats stay reachable (ticket 07)") { r in
        r.run("a Muted Chat whose last Batch is past the window is pinned under Earlier, and drops off once unmuted") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 9)
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "older", at: hoursAgo(30 * 24), chatId: 9),
                    extractionEntry(ref: "old", at: hoursAgo(20 * 24), chatId: 9),
                    extractionEntry(ref: "recent", at: hoursAgo(1), chatId: 1),
                ], app: app)
                try expect(viewModel.sections.map(\.title) == ["Today", "Earlier"], "got \(viewModel.sections.map(\.title))")
                let pinned = try require(viewModel.sections.last?.batches.first)
                try expect(pinned.id == "old", "only the Chat's latest Batch is pinned")
                try expect(viewModel.badges(for: pinned).map(\.text) == ["Task", "Muted"])
                app.actions.toggleMute(pinned)
                try expect(viewModel.sections.map(\.title) == ["Today"])
            }
        }

        r.run("a Muted Chat's Batch inside the window shows Muted and is not duplicated under Earlier") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 9)
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "old", at: hoursAgo(20 * 24), chatId: 9),
                    extractionEntry(ref: "recent", at: hoursAgo(1), chatId: 9),
                ], app: app)
                try expect(viewModel.batches.map(\.id) == ["recent"])
                let batch = try require(viewModel.selectedBatch)
                try expect(viewModel.badges(for: batch).contains { $0.text == "Muted" })
            }
        }

        r.run("pinned Batches appear only in All") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 9)
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: "old", at: hoursAgo(20 * 24), chatId: 9)], app: app)
                viewModel.segment = .corrected
                try expect(viewModel.batches.isEmpty)
            }
        }

        r.run("the store pins the latest Batch of each asked-for Chat with nothing in the window") {
            let store = makeTestHistoryStore()
            try store.record(extractionEntry(id: "a1", ref: "a1", at: hoursAgo(50), chatId: 1))
            try store.record(extractionEntry(id: "a2", ref: "a2", at: hoursAgo(40), chatId: 1))
            try store.record(extractionEntry(id: "b1", ref: "b1", at: hoursAgo(45), chatId: 2))
            try store.record(extractionEntry(id: "c1", ref: "c1", at: hoursAgo(1), chatId: 3))
            try store.record(extractionEntry(id: "a2-rerun", ref: "a2", at: hoursAgo(39), chatId: 1, kind: .rerun))
            let window = store.batches(since: hoursAgo(24), pinningLatestOf: [1, 2, 3])
            try expect(window.batches.map(\.id) == ["c1"])
            try expect(Set(window.pinned.map(\.id)) == ["a2", "b1"], "Chat 3 has a Batch in the window; got \(window.pinned.map(\.id))")
            try expect(window.pinned.first { $0.id == "a2" }?.rows.map(\.id) == ["a2", "a2-rerun"])
            try expect(store.batches(since: hoursAgo(24), pinningLatestOf: []).pinned.isEmpty)
        }

        r.run("the signal store lists Muted Chats") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 4)
            try expect(store.mutedChatIds() == [4])
        }
    }

    runner.suite("Markdown export (ticket 08)") { r in
        r.run("both exports cover exactly the Batches in the current view") {
            try await MainActor.run {
                let (viewModel, _) = try seeded()
                viewModel.segment = .borderline
                let csvURL = try require(viewModel.exportCSV())
                let markdownURL = try require(viewModel.exportMarkdown())
                defer {
                    try? FileManager.default.removeItem(at: csvURL)
                    try? FileManager.default.removeItem(at: markdownURL)
                }
                let csv = try String(contentsOf: csvURL, encoding: .utf8)
                try expect(csv.contains("\"edge\""), "the Borderline Batch's rows are exported")
                try expect(!csv.contains("\"plain\"") && !csv.contains("\"far\""), "nothing outside the view is")
                try expect(csv.split(separator: "\n").count == 3, "a header and the Batch's two rows; got \(csv)")
                let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
                try expect(markdown.contains("View: Borderline"))
                try expect(markdown.contains("Cutoff: 0.50"))
                try expect(markdown.components(separatedBy: "\n## ").count == 2, "one section for the one Batch")
            }
        }

        r.run("the Markdown carries the prompt, result, score and raw outputs under Participant Labels, never Contacts names") {
            try await MainActor.run {
                let lines = [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "call the dentist", sentAt: hoursAgo(1))]
                let screening = HistoryEntry(
                    timestamp: hoursAgo(1), sourceRawText: "call the dentist", modelUsed: "JEV", signalCount: 0, chatId: 7, renderedContext: "[latest messages]\nParticipant A: call the dentist",
                    kind: .screening(ScreeningDecision(probability: 0.62, mode: .live(cutoff: 0.4))), sourceRef: "m1",
                    sender: "Mom", transcript: lines
                )
                let model = HistoryEntry(
                    timestamp: hoursAgo(1), sourceRawText: "call the dentist", rawOutput: "Call the dentist\n```odd```",
                    modelUsed: "Qwen", signalCount: 1, chatId: 7, renderedContext: "[latest messages]\nParticipant A: call the dentist",
                    sourceRef: "m1", sender: "Mom", transcript: lines
                )
                let (viewModel, _) = try makeDashboard([screening, model], cutoff: 0.4)
                let url = try require(viewModel.exportMarkdown())
                defer { try? FileManager.default.removeItem(at: url) }
                let markdown = try String(contentsOf: url, encoding: .utf8)
                try expect(markdown.contains("Participant A: call the dentist"))
                try expect(markdown.contains("Tasks: Call the dentist"))
                try expect(markdown.contains("Screening: 0.62 (let through, cutoff 0.40)"), markdown)
                try expect(markdown.contains("Chat 7"))
                try expect(markdown.contains("Qwen"))
                try expect(markdown.contains("````\nCall the dentist\n```odd```\n````"), "a fence longer than any run inside it")
                try expect(!markdown.contains("Mom"), "no Contacts name ever reaches the export")
                try expect(!markdown.contains("[["), "plain Markdown, no wikilinks")
            }
        }
    }

    runner.suite("Review fixes") { r in
        r.run("a pinned Muted Batch brings all of its rows, not only the newest") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 9)
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "old", probability: 0.8, at: hoursAgo(20 * 24), chatId: 9),
                    extractionEntry(ref: "old", at: hoursAgo(20 * 24 - 0.1), chatId: 9),
                    extractionEntry(ref: "old", output: "Other", at: hoursAgo(19 * 24), chatId: 9, kind: .rerun),
                ], app: app)
                let pinned = try require(viewModel.batches.first)
                try expect(pinned.rows.count == 3, "got \(pinned.rows.count)")
                try expect(pinned.result == .tasks(["Call the dentist"]))
            }
        }

        r.run("a failed Screening is the primary badge even after the model judged the Batch") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    HistoryEntry(
                        timestamp: hoursAgo(2), sourceRawText: "x", modelUsed: "JEV",
                        signalCount: 0, chatId: 1, kind: .screeningFailed(reason: "timeout"), sourceRef: "m1"
                    ),
                    extractionEntry(ref: "m1", at: hoursAgo(1.9)),
                ])
                try expect(badgeTexts(viewModel, "m1") == ["Screening failed"])
            }
        }

        r.run("a Batch from this weekday last week but inside the window is not filed under Earlier") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([extractionEntry(ref: "lastWeek", at: hoursAgo(7 * 24 - 1))])
                try expect(viewModel.sections.map(\.title) == ["Last Wednesday"], "got \(viewModel.sections.map(\.title))")
            }
        }

        r.run("the Borderline count counts Batches, not rows") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "m1", probability: 0.5, at: hoursAgo(2)),
                    screeningEntry(ref: "m1", probability: 0.5, at: hoursAgo(1)),
                ], cutoff: 0.5)
                try expect(viewModel.borderlineCountThisWeek == 1)
            }
        }
    }

    runner.suite("History round 2: titles, context, quiet badges, Add task") { r in
        r.run("a group Batch's title is the group's name, and a Self-thread's is Self-thread") {
            let history = makeTestHistoryStore()
            let deps = ExtractionDependencies(
                store: makeTestSignalStore(), extractor: FakeIntentExtractor(defaultResponse: "NONE"), contactsResolver: momResolver(),
                historyStore: history
            )
            let group = ChatMessage(
                id: "g1", chatId: 8, isFromMe: false, text: "can you bring snacks tomorrow", createdAt: transcriptStart,
                senderAddress: "+15550001", chatName: "Book club", isGroupChat: true
            )
            _ = await refreshThroughIntake(from: [group, message("s1", "buy milk", at: 30, selfThread: true)], deps: deps)
            let groupRow = try require(history.allRows().first { $0.chatId == 8 })
            try expect(groupRow.chatTitle == "Book club")
            let selfRow = try require(history.allRows().first { $0.chatId == 5 })
            try expect(selfRow.isSelfThread && selfRow.chatTitle == nil, "a fact, not a stored title")
            try expect(groupHistoryIntoBatches([selfRow]).first?.title == selfThreadTitle)
        }

        r.run("an unnamed group is titled by its other members; a one-to-one Chat has no title") {
            let history = makeTestHistoryStore()
            let deps = ExtractionDependencies(
                store: makeTestSignalStore(), extractor: FakeIntentExtractor(defaultResponse: "NONE"), contactsResolver: momResolver(),
                historyStore: history
            )
            let messages = [
                ChatMessage(id: "g1", chatId: 8, isFromMe: false, text: "can you bring snacks tomorrow", createdAt: transcriptStart, senderAddress: "+15550001", isGroupChat: true),
                ChatMessage(id: "g2", chatId: 8, isFromMe: false, text: "and can you grab napkins", createdAt: transcriptStart.addingTimeInterval(5), senderAddress: "+15550009", isGroupChat: true),
                message("d1", "can you call me", from: "+15550001", at: 100),
            ]
            _ = await refreshThroughIntake(from: messages, deps: deps)
            try expect(history.allRows().first { $0.chatId == 8 }?.chatTitle == "Mom, +15550009")
            let direct = try require(history.allRows().first { $0.chatId == 5 })
            try expect(direct.chatTitle == nil)
        }

        r.run("the transcript carries the context the model saw, marked as context") {
            let history = makeTestHistoryStore()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m0", signals: [])
            let deps = ExtractionDependencies(
                store: store, extractor: FakeIntentExtractor(defaultResponse: "NONE"), contactsResolver: momResolver(), historyStore: history
            )
            _ = await refreshThroughIntake(from: [
                message("m0", "did you leave yet", from: "+15550001", at: -300),
                message("m1", "I'm here as well", at: 0),
            ], deps: deps)
            let row = try require(history.allRows().first)
            try expect(row.transcript?.map(\.isContext) == [true, false])
            try expect(row.transcript?.map(\.text) == ["did you leave yet", "I'm here as well"])
        }

        r.run("the list title prefers the Chat's title, then the Sender; the preview is the Batch's first line") {
            try await MainActor.run {
                let lines = [
                    HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "earlier", sentAt: hoursAgo(2), isContext: true),
                    HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "did you leave yet", sentAt: hoursAgo(1)),
                    HistoryTranscriptLine(speaker: "You", isFromMe: true, text: "on my way", sentAt: hoursAgo(1)),
                ]
                let group = HistoryEntry(
                    timestamp: hoursAgo(1), sourceRawText: "x", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 8,
                    sourceRef: "g", sender: "Mom", transcript: lines, chatTitle: "Book club"
                )
                let direct = HistoryEntry(
                    timestamp: hoursAgo(1), sourceRawText: "x", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 5,
                    sourceRef: "d", sender: "Mom", transcript: lines
                )
                let (viewModel, _) = try makeDashboard([group, direct, extractionEntry(ref: nil, at: hoursAgo(3))])
                let g = try require(viewModel.batches.first { $0.id == "g" })
                try expect(g.title == "Book club")
                try expect(g.preview == "Mom: did you leave yet", "a group's preview names who spoke")
                let d = try require(viewModel.batches.first { $0.id == "d" })
                try expect(d.title == "Mom")
                try expect(d.preview == "did you leave yet")
                let legacy = try require(viewModel.batches.first { $0.sourceRef == nil })
                try expect(legacy.title == "Chat not recorded")
            }
        }

        r.run("routine outcomes carry no badge; exceptions do") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    extractionEntry(ref: "none", output: "NONE", at: hoursAgo(1)),
                    screeningEntry(ref: "screened", probability: 0.05, wasScreened: true, at: hoursAgo(1)),
                    screeningEntry(ref: "through", probability: 0.95, at: hoursAgo(1)),
                    extractionEntry(ref: "task", at: hoursAgo(1)),
                ], cutoff: 0.5)
                try expect(badgeTexts(viewModel, "none").isEmpty)
                try expect(badgeTexts(viewModel, "screened").isEmpty)
                try expect(badgeTexts(viewModel, "through").isEmpty)
                try expect(badgeTexts(viewModel, "task") == ["Task"])
            }
        }

        r.run("Add task is offered on a model call that found nothing, and puts the named task in Suggestions") {
            let app = await MainActor.run { makeHistoryApp() }
            try await MainActor.run {
                let lines = [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "can you book the table", sentAt: hoursAgo(2))]
                let (viewModel, _) = try makeDashboard([
                    HistoryEntry(
                        id: "none-model", timestamp: hoursAgo(2), sourceRawText: "text none", rawOutput: "NONE", modelUsed: "Qwen",
                        signalCount: 0, chatId: 1, sourceRef: "none", sender: "Mom", transcript: lines
                    ),
                    extractionEntry(ref: "task", at: hoursAgo(1)),
                    screeningEntry(ref: "screened", probability: 0.05, wasScreened: true, at: hoursAgo(1)),
                ], app: app)
                let none = try require(viewModel.batches.first { $0.id == "none" })
                try expect(app.actions.offered(.addTask, for: none) == .enabled)
                let task = try require(viewModel.batches.first { $0.id == "task" })
                let screened = try require(viewModel.batches.first { $0.id == "screened" })
                try expect(app.actions.offered(.addTask, for: task) == nil)
                try expect(app.actions.offered(.addTask, for: screened) == nil, "a Screened Batch has This was work")
                app.actions.addTask("  Book the table  ", to: none)
                try expect(app.signals.openSignals().map(\.label) == ["Book the table"])
                let after = try require(viewModel.batches.first { $0.id == "none" })
                try expect(app.actions.offered(.addTask, for: after) == .taken, "once added, the button becomes a label")
                try expect(viewModel.isCorrected(after))
                app.actions.addTask("Another", to: after)
                try expect(app.signals.openSignals().count == 1, "a taken action does nothing")
            }
        }

        r.run("a blank label adds nothing") {
            let app = await MainActor.run { makeHistoryApp() }
            try await MainActor.run {
                let row = HistoryEntry(
                    sourceRawText: "x", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 1, sourceRef: "m1",
                    transcript: [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "x", sentAt: hoursAgo(1))]
                )
                app.actions.addTask("   ", to: historyBatch(row))
                try expect(app.signals.openSignals().isEmpty)
                try expect(app.actions.offered(.addTask, for: historyBatch(row)) == .enabled)
            }
        }

        r.run("Add task records a missed-task Correction and puts an inferred Signal in the Suggested Tasks Inbox") {
            let app = await MainActor.run { makeHistoryApp() }
            let entry = HistoryEntry(
                sourceRawText: "can you book a table", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 3,
                renderedContext: "[latest messages]\nParticipant A: can you book a table", sourceRef: "m9", sender: "Mom",
                transcript: [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "can you book a table", sentAt: Date())]
            )
            await MainActor.run { app.actions.addTask("Book a table", to: historyBatch(entry)) }
            let signal = try require(app.signals.openSignals().first)
            try expect(signal.label == "Book a table")
            try expect(signal.sourceRef == "m9")
            try expect(signal.provenance == .inferred)
            try expect(signal.sender == "Mom")
            try await MainActor.run {
                try expect(app.model.rankedList.suggested.map(\.label) == ["Book a table"])
                try expect(app.model.corrections.types(forBatches: ["m9"]) == ["m9": [.missedTask]])
            }
            let example = try require(selectCorrections(chatId: 3, store: app.corrections).first)
            try expect(example.correctedOutput == "Book a table")
            try expect(example.inputText == "[latest messages]\nParticipant A: can you book a table")
        }

        r.run("a missed-task Correction becomes a worked example; a This was work one does not") {
            let store = FakeCorrectionStore()
            try store.record(Correction(chatId: 1, inputText: "a", correctedOutput: "Book a table", correctionType: .missedTask))
            try store.record(Correction(chatId: 1, inputText: "b", correctedOutput: "", correctionType: .falseNegative))
            let selected = selectCorrections(chatId: 1, store: store)
            try expect(selected.map(\.inputText) == ["a"])
        }

        r.run("the Inspector names Screening's confidence") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([screeningEntry(ref: "m1", probability: 0.12)])
                let screening = try require(viewModel.inspection(for: try require(viewModel.selectedBatch)).screening)
                try expect(screening.confidenceLabel == "JEV confidence")
            }
        }
    }

    runner.suite("History round 3: backfill older rows, weekly summary") { r in
        r.run("a row with a message id gets its Batch's Sender, title and transcript with context filled in") {
            let history = makeTestHistoryStore()
            try history.record(HistoryEntry(
                id: "h1", timestamp: transcriptStart.addingTimeInterval(20), sourceRawText: "Participant A: can you call\nYou: sure",
                rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 5, sourceRef: "m2"
            ))
            let messages = [
                message("m0", "are you around", from: "+15550001", at: -60),
                message("m1", "can you call", from: "+15550001", at: 0),
                message("m2", "sure", at: 5),
            ]
            let ledger = makeTestSignalStore()
            try ledger.recordProcessedBatch(MessageBatch(messages: Array(messages[1...2])), signals: [])
            backfillHistoryDisplay(
                history: history, messages: messages, ledger: ledger,
                contactsResolver: momResolver(), since: transcriptStart.addingTimeInterval(-3600)
            )
            let row = try require(history.allRows().first)
            try expect(row.sender == "Mom")
            try expect(row.transcript?.map(\.text) == ["are you around", "can you call", "sure"])
            try expect(row.transcript?.map(\.isContext) == [true, false, false])
            try expect(row.chatTitle == nil, "a one-to-one Chat is titled by its Sender")
        }

        r.run("a row with no message id is matched by its text within its Chat") {
            let history = makeTestHistoryStore()
            try history.record(HistoryEntry(
                id: "old", timestamp: transcriptStart.addingTimeInterval(30), sourceRawText: "did you take your meds",
                rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 5
            ))
            let messages = [
                message("m0", "hi", from: "+15550001", at: -30),
                message("m1", "did you take your meds", from: "+15550001", at: 0),
                message("m2", "did you take your meds", from: "+15550001", at: 600),
            ]
            backfillHistoryDisplay(
                history: history, messages: messages, ledger: makeTestSignalStore(), contactsResolver: momResolver(),
                since: transcriptStart.addingTimeInterval(-3600)
            )
            let row = try require(history.allRows().first)
            try expect(row.transcript?.map(\.text) == ["hi", "did you take your meds"], "the latest match at or before the row, not a later repeat")
            try expect(row.sender == "Mom")
            try expect(row.sourceRef == "m1", "the matched message's id, so the row can take Add task")
        }

        r.run("with no matching message, the Chat still names the row; rows already filled are left alone") {
            let history = makeTestHistoryStore()
            try history.record(HistoryEntry(
                id: "unmatched", timestamp: transcriptStart.addingTimeInterval(30), sourceRawText: "gone now",
                rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 5
            ))
            try history.record(HistoryEntry(
                id: "filled", timestamp: transcriptStart.addingTimeInterval(40), sourceRawText: "x", rawOutput: "NONE",
                modelUsed: "Q", signalCount: 0, chatId: 5, sender: "Someone", transcript: []
            ))
            backfillHistoryDisplay(
                history: history, messages: [message("m1", "hello", from: "+15550001", at: 0)], ledger: makeTestSignalStore(),
                contactsResolver: momResolver(), since: transcriptStart.addingTimeInterval(-3600)
            )
            let unmatched = try require(history.allRows().first { $0.id == "unmatched" })
            try expect(unmatched.sender == "Mom")
            try expect(unmatched.transcript == nil)
            try expect(history.allRows().first { $0.id == "filled" }?.sender == "Someone")
        }

        r.run("the SQLite store fills display fields only where they are empty") {
            let store = makeTestHistoryStore()
            try store.record(HistoryEntry(id: "a", sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 0))
            try store.record(HistoryEntry(id: "b", sourceRawText: "x", rawOutput: "X", modelUsed: "M", signalCount: 0, sender: "Kept"))
            let lines = [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "x", sentAt: Date(timeIntervalSince1970: 0))]
            try store.fillDisplay(
                id: "a",
                from: HistorySubject(sourceRawText: "x", sourceRef: "m7", sender: "Mom", transcript: lines, chatTitle: "Book club")
            )
            try store.fillDisplay(id: "b", from: HistorySubject(sourceRawText: "x", sender: "Mom"))
            let rows = store.allRows()
            let a = try require(rows.first { $0.id == "a" })
            try expect(a.sender == "Mom" && a.chatTitle == "Book club" && a.transcript == lines && a.sourceRef == "m7")
            try expect(rows.first { $0.id == "b" }?.sender == "Kept")
        }

        r.run("the weekly summary counts the whole window whatever view is showing") {
            try await MainActor.run {
                let (viewModel, _) = try makeDashboard([
                    screeningEntry(ref: "s1", probability: 0.05, wasScreened: true, at: hoursAgo(3)),
                    screeningEntry(ref: "s2", probability: 0.45, wasScreened: true, cutoff: 0.5, at: hoursAgo(3)),
                    extractionEntry(ref: "t1", at: hoursAgo(2)),
                    extractionEntry(ref: "n1", output: "NONE", at: hoursAgo(1)),
                    extractionEntry(ref: "old", at: hoursAgo(10 * 24)),
                ], cutoff: 0.5)
                viewModel.segment = .starred
                let summary = viewModel.weekSummary
                try expect(summary.batches == 4)
                try expect(summary.tasks == 1)
                try expect(summary.screened == 2)
                try expect(summary.borderline == 1)
                try expect(summary.corrected == 0)
            }
        }
    }
}
