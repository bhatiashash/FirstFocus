import FirstFocusCore
import Foundation

private func entry(
    id: String = UUID().uuidString, timestamp: Date = Date(), sourceRawText: String = "call the dentist",
    rawOutput: String = "Call the dentist", modelUsed: String = "Test Model", signalCount: Int = 1, chatId: Int = 0,
    renderedContext: String? = nil, kind: HistoryEntryKind = .extraction, sourceRef: String? = nil
) -> HistoryEntry {
    // Only a model call carries the model's output; a Screening row's
    // summary comes from its decision.
    HistoryEntry(
        id: id, timestamp: timestamp, sourceRawText: sourceRawText, rawOutput: kind.isModelCall || kind == .audit ? rawOutput : nil,
        modelUsed: modelUsed, signalCount: signalCount, chatId: chatId, renderedContext: renderedContext, kind: kind,
        sourceRef: sourceRef
    )
}

private func shadowScreening(_ probability: Double, questionVersion: Int = screeningQuestionVersion) -> HistoryEntryKind {
    .screening(ScreeningDecision(probability: probability, mode: .shadow, questionVersion: questionVersion))
}

private let now = Date()

private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 60 * 60) }

func registerHistoryStoreTests(_ runner: TestRunner) {
    runner.suite("HistoryStore (SQLiteHistoryStore)") { r in
        r.run("a recorded entry survives a store reopen against the same file") {
            let path = testStorePath()
            try SQLiteHistoryStore(path: path).record(entry(id: "h1", sourceRawText: "call the dentist", rawOutput: "Call the dentist"))
            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.id == "h1")
            try expect(fetched.sourceRawText == "call the dentist")
            try expect(fetched.rawOutput == "Call the dentist")
            try expect(fetched.signalCount == 1)
        }

        r.run("a zero-Signal entry is recorded and read back") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "h1", rawOutput: "NONE", signalCount: 0))
            try expect(store.allRows().map(\.id) == ["h1"])
        }

        r.run("chatId and renderedContext survive a store reopen against the same file") {
            let path = testStorePath()
            let composed = "[context]\nParticipant A: can someone grab snacks\n\n[latest messages]\nParticipant B: also grab napkins"
            try SQLiteHistoryStore(path: path).record(entry(id: "h1", chatId: 99, renderedContext: composed))
            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.chatId == 99)
            try expect(fetched.renderedContext == composed)
        }

        r.run("a Chat's deep-link identifier survives a store reopen, and a row without one reads back nil") {
            let path = testStorePath()
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                id: "h1", sourceRawText: "can you book the table", rawOutput: "NONE", modelUsed: "Q", signalCount: 0,
                chatId: 5, sourceRef: "m1", chatIdentifier: "+15551234567"
            ))
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                id: "h2", sourceRawText: "snacks?", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 9, sourceRef: "g1"
            ))
            let fetched = SQLiteHistoryStore(path: path).allRows()
            try expect(fetched.first { $0.id == "h1" }?.chatIdentifier == "+15551234567")
            try expect(fetched.first { $0.id == "h2" }.map { $0.chatIdentifier == nil } == true)
        }

        r.run("renderedContext defaults to the Batch's own text, never a blank string") {
            let store = makeTestHistoryStore()
            try store.record(HistoryEntry(
                id: "old", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A", signalCount: 1
            ))
            try expect(store.allRows().first?.renderedContext == "call the dentist")
        }

        r.run("chatId reads back nil, not a sentinel 0, when never supplied") {
            let store = makeTestHistoryStore()
            try store.record(HistoryEntry(
                id: "old", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A", signalCount: 1
            ))
            let fetched = try require(store.allRows().first)
            try expect(fetched.chatId == nil, "NULL on disk must read back as nil, never 0 — a real chat could someday have id 0")
        }

        r.run("starring and deleting persist across a reopen") {
            let path = testStorePath()
            let firstOpen = SQLiteHistoryStore(path: path)
            try firstOpen.record(entry(id: "h1"))
            try firstOpen.record(entry(id: "h2"))
            try firstOpen.setStarred(true, id: "h1")
            try firstOpen.delete(id: "h2")
            let remaining = SQLiteHistoryStore(path: path).allRows()
            try expect(remaining.map(\.id) == ["h1"])
            try expect(remaining.first?.isStarred == true)
        }

        r.run("deleting or starring an unknown id throws rather than silently succeeding") {
            let store = makeTestHistoryStore()
            var deleteThrew = false
            do { try store.delete(id: "missing") } catch { deleteThrew = true }
            var starThrew = false
            do { try store.setStarred(true, id: "missing") } catch { starThrew = true }
            try expect(deleteThrew && starThrew)
        }

        r.run("deleting a Batch removes every row recorded for it and nothing else") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "s", signalCount: 0, kind: shadowScreening(0.6), sourceRef: "m1"))
            try store.record(entry(id: "e", sourceRef: "m1"))
            try store.record(entry(id: "other", sourceRef: "m2"))
            try store.delete(sourceRef: "m1")
            try expect(store.allRows().map(\.id) == ["other"])
        }
    }

    runner.suite("HistoryStore: reading whole Batches") { r in
        r.run("a Batch with a row in the window comes back with every row, however old") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "intake", timestamp: daysAgo(9), rawOutput: "Call the dentist", sourceRef: "m1"))
            try store.record(entry(id: "rerun", timestamp: daysAgo(1), rawOutput: "NONE", signalCount: 0, kind: .rerun, sourceRef: "m1"))
            let batch = try require(store.batches(since: daysAgo(7)).first)
            try expect(batch.rows.map(\.id) == ["intake", "rerun"], "oldest first")
            try expect(batch.resultRow?.id == "intake", "the result is intake's call, not the Re-run")
            try expect(batch.result == .tasks(["Call the dentist"]))
            try expect(batch.listedAt > daysAgo(7), "listed on the Re-run's day, not under Earlier")
        }

        r.run("a Batch's result is its extraction call however many other rows it has") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "screening", timestamp: daysAgo(2), signalCount: 0, kind: shadowScreening(0.7), sourceRef: "m1"))
            try store.record(entry(id: "intake", timestamp: daysAgo(2), rawOutput: "Book the table", sourceRef: "m1"))
            for index in 0..<30 {
                try store.record(entry(
                    id: "rerun\(index)", timestamp: daysAgo(1), rawOutput: "NONE", signalCount: 0, kind: .rerun, sourceRef: "m1"
                ))
            }
            let batches = store.batches(since: daysAgo(7))
            try expect(batches.count == 1)
            try expect(batches.first?.rows.count == 32)
            try expect(batches.first?.result == .tasks(["Book the table"]))
        }

        r.run("Batches outside the window stay out, and the rest come back newest first") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "old", timestamp: daysAgo(8), sourceRef: "m0"))
            try store.record(entry(id: "older-in", timestamp: daysAgo(3), sourceRef: "m1"))
            try store.record(entry(id: "newer-in", timestamp: daysAgo(1), sourceRef: "m2"))
            try expect(store.batches(since: daysAgo(7)).map(\.id) == ["m2", "m1"])
        }

        r.run("a row with no message id is a Batch of its own") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "legacy1", timestamp: daysAgo(2)))
            try store.record(entry(id: "legacy2", timestamp: daysAgo(1)))
            try store.record(entry(id: "legacy-old", timestamp: daysAgo(9)))
            try expect(store.batches(since: daysAgo(7)).map(\.id) == ["row:legacy2", "row:legacy1"])
        }
    }

    runner.suite("HistoryStore: the evaluator's read") { r in
        r.run("starred rows come first; with none starred, the latest extraction rows") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "e1", timestamp: daysAgo(3), sourceRef: "m1"))
            try store.record(entry(id: "s2", timestamp: daysAgo(2), signalCount: 0, kind: shadowScreening(0.7), sourceRef: "m2"))
            try store.record(entry(id: "e2", timestamp: daysAgo(2), sourceRef: "m2"))
            try store.record(entry(id: "r2", timestamp: daysAgo(1), kind: .rerun, sourceRef: "m2"))
            try store.record(entry(id: "e3", timestamp: daysAgo(1), sourceRef: "m3"))
            try expect(store.evaluationRows(limit: 2).map(\.id) == ["e3", "e2"], "no Screening or Re-run rows, newest first")
            try store.setStarred(true, id: "e1")
            try expect(store.evaluationRows(limit: 2).map(\.id) == ["e1"])
        }
    }

    runner.suite("HistoryStore: Screening outcomes") { r in
        r.run("each Screening decision under the question comes with the model's first verdict on its Batch") {
            let store = makeTestHistoryStore()
            try store.record(entry(id: "sa", timestamp: daysAgo(5), signalCount: 0, kind: shadowScreening(0.05), sourceRef: "a"))
            try store.record(entry(id: "ea", timestamp: daysAgo(5), signalCount: 0, sourceRef: "a"))
            try store.record(entry(id: "ra", timestamp: daysAgo(4), signalCount: 3, kind: .rerun, sourceRef: "a"))
            try store.record(entry(id: "sb", timestamp: daysAgo(3), signalCount: 0, kind: shadowScreening(0.25), sourceRef: "b"))
            try store.record(entry(id: "ab", timestamp: daysAgo(3), signalCount: 1, kind: .audit, sourceRef: "b"))
            try store.record(entry(id: "sc", timestamp: daysAgo(2), signalCount: 0, kind: shadowScreening(0.5), sourceRef: "c"))
            try store.record(entry(
                id: "sd", timestamp: daysAgo(1), signalCount: 0,
                kind: shadowScreening(0.9, questionVersion: screeningQuestionVersion - 1), sourceRef: "d"
            ))
            try store.record(entry(id: "ed", timestamp: daysAgo(1), signalCount: 1, sourceRef: "d"))
            let outcomes = store.screeningOutcomes(questionVersion: screeningQuestionVersion)
            try expect(outcomes == [
                ScreeningOutcome(sourceRef: "a", probability: 0.05, modelFoundTask: false),
                ScreeningOutcome(sourceRef: "b", probability: 0.25, modelFoundTask: true),
                ScreeningOutcome(sourceRef: "c", probability: 0.5, modelFoundTask: nil),
            ], "a later Re-run never replaces the verdict, and an older wording is left out; got \(outcomes)")
        }
    }

    runner.suite("rerunHistoryEntry") { r in
        r.run("replays the entry's stored raw input through the given extractor and records a new entry under its model") {
            let store = makeTestHistoryStore()
            let original = entry(id: "h1", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A")
            try store.record(original)

            let extractor = FakeIntentExtractor(
                responses: ["call the dentist": "Call the dentist\nBuy milk"], modelDisplayName: "Model B"
            )
            try await rerunHistoryEntry(original, extractor: extractor, historyStore: store)

            let all = store.allRows()
            try expect(all.count == 2, "the original entry must survive untouched, with a new one appended")
            try expect(extractor.calls == ["call the dentist"], "Re-run must replay the exact stored input, unmodified")

            let originalStillThere = try require(all.first { $0.id == "h1" })
            try expect(originalStillThere.modelUsed == "Model A", "the original entry is never mutated by Re-run")

            let rerunEntry = try require(all.first { $0.id != "h1" })
            try expect(rerunEntry.modelUsed == "Model B")
            try expect(rerunEntry.signalCount == 2)
            try expect(rerunEntry.kind == .rerun)
            try expect(rerunEntry.subject == original.subject, "the same Batch, shown the same way")
        }
    }
}
