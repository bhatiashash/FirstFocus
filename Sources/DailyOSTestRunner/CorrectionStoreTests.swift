import DailyOSCore
import Foundation
import SQLite3

private func correction(
    chatId: Int, sourceRef: String? = nil, inputText: String = "call the dentist", correctedOutput: String = "NONE",
    correctionType: CorrectionType = .falsePositive, createdAt: Date = Date()
) -> Correction {
    Correction(
        chatId: chatId, sourceRef: sourceRef, inputText: inputText, correctedOutput: correctedOutput,
        correctionType: correctionType, createdAt: createdAt
    )
}

func registerCorrectionStoreTests(_ runner: TestRunner) {
    for (label, makeStore) in storeVariants() {
        runner.suite("CorrectionStore (\(label))") { r in
            r.run("a recorded correction is retrievable for its chat") {
                let store = makeStore()
                try store.record(correction(chatId: 1))
                try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).count == 1)
            }

            r.run("replacing a Batch's Correction of one type leaves its other types and other Batches alone") {
                let store = makeStore()
                try store.record(correction(chatId: 1, sourceRef: "m1", correctionType: .falsePositive))
                try store.record(correction(chatId: 1, sourceRef: "m1", correctedOutput: "Book a table", correctionType: .missedTask))
                try store.record(correction(chatId: 2, sourceRef: "m2", correctionType: .falsePositive))
                try store.replace(correction(chatId: 1, sourceRef: "m1", inputText: "again", correctionType: .falsePositive))
                try expect(store.correctionTypes(forSourceRefs: ["m1", "m2"]) == ["m1": [.falsePositive, .missedTask], "m2": [.falsePositive]])
                let falsePositives = store.corrections(ofType: .falsePositive, createdAfter: nil, limit: 10)
                try expect(falsePositives.filter { $0.sourceRef == "m1" }.map(\.inputText) == ["again"])
            }

            r.run("replacing a Correction with no Batch replaces nothing") {
                let store = makeStore()
                try store.record(correction(chatId: 1, inputText: "old"))
                try store.replace(correction(chatId: 1, inputText: "new"))
                try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).count == 2)
            }

            r.run("correctionTypes answers for the Batches asked about and leaves out the rest") {
                let store = makeStore()
                try store.record(correction(chatId: 1, sourceRef: "m1"))
                try store.record(correction(chatId: 2, sourceRef: "m2", correctedOutput: "", correctionType: .falseNegative))
                try store.record(correction(chatId: 3, inputText: "no Batch"))
                try expect(store.correctionTypes(forSourceRefs: ["m2", "m9"]) == ["m2": [.falseNegative]])
            }

            r.run("a different inputText for the same chat is a separate row") {
                let store = makeStore()
                try store.record(correction(chatId: 1, inputText: "call the dentist"))
                try store.record(correction(chatId: 1, inputText: "buy milk"))
                try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).count == 2)
            }

            r.run("corrections(forChatId:) returns only that chat's rows") {
                let store = makeStore()
                try store.record(correction(chatId: 1))
                try store.record(correction(chatId: 2))
                try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).allSatisfy { $0.chatId == 1 })
            }

            r.run("corrections(forChatId:) returns newest first, capped at limit") {
                let store = makeStore()
                let now = Date()
                try store.record(correction(chatId: 1, inputText: "a", createdAt: now - 120))
                try store.record(correction(chatId: 1, inputText: "b", createdAt: now - 60))
                try store.record(correction(chatId: 1, inputText: "c", createdAt: now))
                let top2 = store.corrections(forChatId: 1, limit: 2, type: .falsePositive)
                try expect(top2.map(\.inputText) == ["c", "b"])
            }

            r.run("globalCorrections excludes the given chatId") {
                let store = makeStore()
                try store.record(correction(chatId: 1))
                try store.record(correction(chatId: 2))
                let global = store.globalCorrections(excludingChatId: 1, limit: 10, type: .falsePositive)
                try expect(global.allSatisfy { $0.chatId != 1 })
                try expect(global.count == 1)
            }

            r.run("globalCorrections returns newest first across chats") {
                let store = makeStore()
                let now = Date()
                try store.record(correction(chatId: 2, inputText: "older", createdAt: now - 60))
                try store.record(correction(chatId: 3, inputText: "newer", createdAt: now))
                let global = store.globalCorrections(excludingChatId: 1, limit: 10, type: .falsePositive)
                try expect(global.map(\.inputText) == ["newer", "older"])
            }
        }
    }

    for (label, makeStore) in storeVariants() {
        runner.suite("Corrections: one of each type per Batch (\(label))") { r in
            func modelCall(_ id: String, prompt: String) -> HistoryEntry {
                HistoryEntry(
                    id: id, sourceRawText: "can you book a table", rawOutput: "Book a table", modelUsed: "Q", signalCount: 1,
                    chatId: 1, renderedContext: prompt, sourceRef: "m1"
                )
            }

            r.run("Not for me twice on one Batch, from its model call and then a Re-run, keeps one Correction") {
                let store = makeStore()
                let corrections = Corrections(store: store)
                try corrections.recordNotForMe(modelCall("h1", prompt: "[latest messages]\nParticipant A: can you book a table"))
                try corrections.recordNotForMe(modelCall("r1", prompt: "can you book a table"))
                let all = store.corrections(forChatId: 1, limit: 10, type: .falsePositive)
                try expect(all.count == 1, "one Batch holds at most one Correction of each type, got \(all.count)")
                try expect(all.first?.inputText == "can you book a table", "the newer one replaces the older")
            }

            r.run("each type is its own Correction on the same Batch") {
                let store = makeStore()
                let corrections = Corrections(store: store)
                try corrections.recordNotForMe(modelCall("h1", prompt: "x"))
                try corrections.recordMissedTask(label: "Book a table", for: modelCall("h1", prompt: "x"))
                try expect(corrections.types(forBatches: ["m1"]) == ["m1": [.falsePositive, .missedTask]])
            }
        }
    }

    runner.suite("Corrections recorded before they belonged to a Batch") { r in
        r.run("one whose input matches a History row takes that row's Batch; one with no match keeps none") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-correction-migration-\(UUID().uuidString).sqlite").path
            let matchedPrompt = "[latest messages]\nParticipant A: can you book a table"
            try SQLiteHistoryStore(path: path).record(HistoryEntry(
                sourceRawText: "can you book a table", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 3,
                renderedContext: matchedPrompt, sourceRef: "m9"
            ))
            try writeCorrectionsTableBeforeBatches(at: path, rows: [
                (chatId: 3, inputText: matchedPrompt, output: "Book a table", type: "missed_task"),
                (chatId: 1291, inputText: "Participant A: shareholder notice", output: "NONE", type: "false_positive"),
            ])

            let store = SQLiteCorrectionStore(path: path)
            try expect(store.correctionTypes(forSourceRefs: ["m9"]) == ["m9": [.missedTask]])
            let matched = try require(store.corrections(forChatId: 3, limit: 10, type: .missedTask).first)
            try expect(matched.sourceRef == "m9")
            try expect(matched.correctedOutput == "Book a table")
            let unmatched = try require(store.corrections(forChatId: 1291, limit: 10, type: .falsePositive).first)
            try expect(unmatched.sourceRef == nil, "no History row carries its input, so it has no Batch")
            try expect(unmatched.inputText == "Participant A: shareholder notice", "it stays a worked example")
        }

        r.run("a stored example carrying earlier examples and open Suggestions is cut down to its own context and Batch") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-correction-migration-\(UUID().uuidString).sqlite").path
            let nested = """
            [corrections]
            Message:
            [context]
            Participant A: old context

            [latest messages]
            Participant A: old ask
            Output: NONE

            [open suggestions]
            1. Pack the bags

            [latest messages]
            Participant A: shareholder notice
            """
            try writeCorrectionsTableBeforeBatches(at: path, rows: [
                (chatId: 1291, inputText: nested, output: "NONE", type: "false_positive"),
                (chatId: 7, inputText: "[context]\nThem: hey\n\n[message to judge]\nThem: lol", output: "NONE", type: "false_positive"),
            ])
            let store = SQLiteCorrectionStore(path: path)
            let cleaned = try require(store.corrections(forChatId: 1291, limit: 10, type: .falsePositive).first)
            try expect(cleaned.inputText == "[latest messages]\nParticipant A: shareholder notice", "got:\n\(cleaned.inputText)")
            let preBatch = try require(store.corrections(forChatId: 7, limit: 10, type: .falsePositive).first)
            try expect(preBatch.inputText == "[context]\nThem: hey\n\n[latest messages]\nThem: lol")
        }

        r.run("a store with no History table still migrates, every Correction without a Batch") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-correction-migration-\(UUID().uuidString).sqlite").path
            try writeCorrectionsTableBeforeBatches(at: path, rows: [
                (chatId: 1, inputText: "a", output: "NONE", type: "false_positive"),
            ])
            let store = SQLiteCorrectionStore(path: path)
            try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).map(\.sourceRef) == [nil])
            let row = HistoryEntry(sourceRawText: "x", rawOutput: "X", modelUsed: "Q", signalCount: 1, chatId: 1, sourceRef: "m1")
            try Corrections(store: store).recordNotForMe(row)
            try Corrections(store: store).recordNotForMe(row)
            try expect(store.corrections(forChatId: 1, limit: 10, type: .falsePositive).count == 2, "one migrated, one for Batch m1")
        }
    }

    runner.suite("selectCorrections (ADR 0031 per-chat + capped global fallback)") { r in
        r.run("a chat with enough of its own corrections never touches the global pool") {
            let store = FakeCorrectionStore()
            let now = Date()
            try store.record(correction(chatId: 1, inputText: "a", createdAt: now - 120))
            try store.record(correction(chatId: 1, inputText: "b", createdAt: now - 60))
            try store.record(correction(chatId: 1, inputText: "c", createdAt: now))
            try store.record(correction(chatId: 2, inputText: "should never appear", createdAt: now))
            let selected = selectCorrections(chatId: 1, store: store)
            try expect(selected.map(\.inputText) == ["c", "b"], "the two most recent, at most two per call (ADR 0039)")
        }

        r.run("a chat with none of its own backfills entirely from the global pool") {
            let store = FakeCorrectionStore()
            let now = Date()
            try store.record(correction(chatId: 2, inputText: "x", createdAt: now - 60))
            try store.record(correction(chatId: 3, inputText: "y", createdAt: now))
            let selected = selectCorrections(chatId: 1, store: store)
            try expect(selected.map(\.inputText) == ["y", "x"])
        }

        r.run("the global fallback is capped at one correction per source chat") {
            let store = FakeCorrectionStore()
            let now = Date()
            // Chat 2 alone has enough corrections to fill the whole
            // fallback on its own — the cap must still leave room for
            // chat 3's contribution instead of chat 2 dominating.
            try store.record(correction(chatId: 2, inputText: "newest", createdAt: now))
            try store.record(correction(chatId: 2, inputText: "second newest", createdAt: now - 30))
            try store.record(correction(chatId: 3, inputText: "third chat", createdAt: now - 60))
            let selected = selectCorrections(chatId: 1, store: store, limit: 3)
            try expect(selected.map(\.inputText) == ["newest", "third chat"], "only one row from chat 2 should ever appear, even though it has more available")
        }

        r.run("a chat with 1 of its own backfills exactly 2 more from the capped global pool") {
            let store = FakeCorrectionStore()
            let now = Date()
            try store.record(correction(chatId: 1, inputText: "own", createdAt: now))
            try store.record(correction(chatId: 2, inputText: "fallback A", createdAt: now - 30))
            try store.record(correction(chatId: 3, inputText: "fallback B", createdAt: now - 60))
            let selected = selectCorrections(chatId: 1, store: store, limit: 3)
            try expect(selected.map(\.inputText) == ["own", "fallback A", "fallback B"])
        }

        r.run("a missed task never backfills into another chat; false positives still do") {
            // A missed task carries a Label the model copies word for word
            // into unrelated chats ("Lets work", 2026-09-27). A false
            // positive only teaches NONE, which is safe anywhere.
            let store = FakeCorrectionStore()
            let now = Date()
            try store.record(correction(
                chatId: 2, inputText: "if you wanna work", correctedOutput: "Lets work", correctionType: .missedTask, createdAt: now
            ))
            try store.record(correction(chatId: 3, inputText: "just chatting", createdAt: now - 60))
            let selected = selectCorrections(chatId: 1, store: store)
            try expect(selected.map(\.inputText) == ["just chatting"], "got \(selected.map(\.inputText))")
        }

        r.run("a chat's own missed task is still its worked example") {
            let store = FakeCorrectionStore()
            try store.record(correction(chatId: 1, inputText: "if you wanna work", correctedOutput: "Lets work", correctionType: .missedTask))
            try expect(selectCorrections(chatId: 1, store: store).map(\.correctedOutput) == ["Lets work"])
        }

        r.run("an empty store returns no corrections at all") {
            let store = FakeCorrectionStore()
            try expect(selectCorrections(chatId: 1, store: store).isEmpty)
        }
    }
}

private func storeVariants() -> [(String, () -> any CorrectionStore)] {
    [
        ("FakeCorrectionStore", { FakeCorrectionStore() }),
        ("SQLiteCorrectionStore, real persistence", {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-correctionstore-test-\(UUID().uuidString).sqlite").path
            return SQLiteCorrectionStore(path: path)
        }),
    ]
}

/// The `corrections` table as it stood before Corrections belonged to a
/// Batch: keyed by Chat and the whole prompt, with no `source_ref`.
private func writeCorrectionsTableBeforeBatches(
    at path: String, rows: [(chatId: Int, inputText: String, output: String, type: String)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw TestFailure(message: "cannot open \(path)") }
    defer { sqlite3_close(db) }
    let schema = """
    CREATE TABLE corrections (
        chat_id INTEGER NOT NULL,
        input_text TEXT NOT NULL,
        corrected_output TEXT NOT NULL,
        correction_type TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (chat_id, input_text)
    );
    CREATE INDEX corrections_created_at ON corrections (created_at DESC);
    """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw TestFailure(message: "old schema") }
    for row in rows {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO corrections VALUES (?, ?, ?, ?, '2026-09-20T10:00:00Z')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestFailure(message: "insert") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, Int64(row.chatId))
        sqlite3_bind_text(statement, 2, row.inputText, -1, transient)
        sqlite3_bind_text(statement, 3, row.output, -1, transient)
        sqlite3_bind_text(statement, 4, row.type, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestFailure(message: "insert step") }
    }
}
