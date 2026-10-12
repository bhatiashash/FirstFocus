import DailyOSApp
import DailyOSCore
import Foundation
import SQLite3

private func tempStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dailyos-screening-groundwork-\(UUID().uuidString).sqlite").path
}

private func screeningRow(id: String, sourceRef: String, probability: Double, wasScreened: Bool) -> HistoryEntry {
    HistoryEntry(
        id: id, sourceRawText: "lol sounds good", modelUsed: "JEV", signalCount: 0, chatId: 7,
        kind: .screening(ScreeningDecision(probability: probability, mode: wasScreened ? .live(cutoff: 0.4) : .shadow)),
        sourceRef: sourceRef
    )
}

func registerScreeningGroundworkTests(_ runner: TestRunner) {
    runner.suite("History records the message and the kind of row") { r in
        r.run("a Screening row round-trips its kind, message id, probability and Screened flag through real SQL") {
            let path = tempStorePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try SQLiteHistoryStore(path: path).record(screeningRow(id: "s1", sourceRef: "m1", probability: 0.12, wasScreened: true))

            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.isScreening)
            try expect(fetched.sourceRef == "m1")
            try expect(fetched.screeningProbability == 0.12)
            try expect(fetched.wasScreened)
        }

        r.run("a Screening row round-trips which wording of the question scored it") {
            let path = tempStorePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                id: "s1", sourceRawText: "hi", modelUsed: "JEV", signalCount: 0, chatId: 7,
                kind: .screening(ScreeningDecision(probability: 0.4, mode: .shadow, questionVersion: 7)), sourceRef: "m1"
            ))
            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.screening?.questionVersion == 7)
        }

        r.run("an extraction row reads back as extraction with no Screening fields") {
            let path = tempStorePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                id: "e1", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A",
                signalCount: 1, sourceRef: "m1"
            ))
            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.kind == .extraction)
            try expect(fetched.sourceRef == "m1")
            try expect(fetched.screeningProbability == nil)
            try expect(!fetched.wasScreened)
        }

        r.run("a database from before this change migrates in place; old rows read as extraction with no message id") {
            let path = tempStorePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            var db: OpaquePointer?
            try expect(sqlite3_open(path, &db) == SQLITE_OK)
            let legacy = """
            CREATE TABLE history_entries (
                id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, source_raw_text TEXT NOT NULL, raw_output TEXT NOT NULL,
                model_used TEXT NOT NULL, signal_count INTEGER NOT NULL, is_starred INTEGER NOT NULL,
                chat_id INTEGER, rendered_context TEXT
            );
            INSERT INTO history_entries VALUES ('old', '2026-09-01T10:00:00Z', 'call mom', 'Call mom', 'Model A', 1, 0, 3, 'call mom');
            """
            try expect(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)

            let store = SQLiteHistoryStore(path: path)
            let fetched = try require(store.allRows().first)
            try expect(fetched.id == "old")
            try expect(fetched.kind == .extraction)
            try expect(fetched.sourceRef == nil)
            try expect(fetched.screeningProbability == nil)
            try expect(!fetched.wasScreened)
            try store.record(screeningRow(id: "new", sourceRef: "m2", probability: 0.9, wasScreened: false))
            try expect(store.allRows().count == 2, "the migrated table must accept new rows")
        }

        r.run("a Screening failure row round-trips its reason through real SQL, and is not a Screening decision") {
            let path = tempStorePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                id: "f1", sourceRawText: "hi", modelUsed: "JEV", signalCount: 0,
                chatId: 7, kind: .screeningFailed(reason: "timed out"), sourceRef: "m1"
            ))
            let fetched = try require(SQLiteHistoryStore(path: path).allRows().first)
            try expect(fetched.kind == .screeningFailed(reason: "timed out"), "got \(fetched.kind)")
            try expect(!fetched.isScreening)
            try expect(fetched.screeningProbability == nil)
        }

        r.run("Extraction writes the message id and the extraction kind on every row it records") {
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist", "book the flights": "NONE"])
            let messages = [
                ChatMessage(id: "m1", chatId: 1, isFromMe: true, text: "call the dentist", createdAt: Date()),
                ChatMessage(id: "m2", chatId: 2, isFromMe: true, text: "book the flights", createdAt: Date()),
            ]
            _ = await refreshThroughIntake(from: messages, store: makeTestSignalStore(), extractor: extractor, historyStore: history)
            let rows = history.allRows()
            try expect(Set(rows.compactMap(\.sourceRef)) == Set(["m1", "m2"]), "got \(rows.map(\.sourceRef))")
            try expect(rows.allSatisfy { $0.kind == .extraction })
        }

        r.run("Re-run keeps the original row's message id") {
            let history = makeTestHistoryStore()
            let original = HistoryEntry(
                id: "h1", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Model A",
                signalCount: 1, sourceRef: "m1"
            )
            try await rerunHistoryEntry(
                original, extractor: FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"]), historyStore: history
            )
            try expect(history.allRows().first?.sourceRef == "m1")
        }

        r.run("CSV export carries the row kind and message id") {
            let store = makeTestHistoryStore()
            try store.record(screeningRow(id: "s1", sourceRef: "m1", probability: 0.12, wasScreened: true))
            let url = try await MainActor.run { () -> URL in
                let viewModel = makeHistoryApp(history: store).viewModel()
                viewModel.showsUnfilteredLog = true
                return try require(viewModel.exportCSV())
            }
            let csv = try String(contentsOf: url, encoding: .utf8)
            try expect(csv.hasPrefix("timestamp,kind,message id,"), "got header: \(csv.split(separator: "\n").first ?? "")")
            try expect(csv.contains("\"screening\",\"m1\""))
        }
    }

    runner.suite("Messages carry whether their Chat is the self-thread") { r in
        r.run("a message in a self-chat is flagged; one in any other Chat is not") {
            let messages = [
                ChatMessage(id: "m1", chatId: 78, isFromMe: true, text: "buy milk", createdAt: Date()),
                ChatMessage(id: "m2", chatId: 5, isFromMe: false, text: "call me", createdAt: Date()),
            ]
            let flagged = flagSelfThread(messages, selfChatIds: [78])
            try expect(flagged.map(\.isSelfThread) == [true, false])
        }

        r.run("a message built without the flag defaults to not the self-thread") {
            try expect(!ChatMessage(id: "m1", chatId: 1, isFromMe: true, text: "x", createdAt: Date()).isSelfThread)
        }
    }
}
