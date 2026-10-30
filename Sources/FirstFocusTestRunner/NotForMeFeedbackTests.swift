import FirstFocusApp
import FirstFocusCore
import Foundation
import SQLite3

private func row(chatId: Int?, sourceRef: String? = "m1") -> HistoryEntry {
    HistoryEntry(
        sourceRawText: "shareholder notice", rawOutput: "Read shareholder notice", modelUsed: "Model", signalCount: 1,
        chatId: chatId, renderedContext: "Participant A: shareholder notice", sourceRef: sourceRef
    )
}

/// Makes every later insert into `path`'s Corrections fail, the way a full
/// disk would, while deletes still go through.
private func failCorrectionInserts(at path: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestFailure(message: "couldn't open \(path)") }
    defer { sqlite3_close(db) }
    let sql = "CREATE TRIGGER fail_inserts BEFORE INSERT ON corrections BEGIN SELECT RAISE(ABORT, 'disk full'); END"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure(message: "couldn't add the trigger") }
}

func registerNotForMeFeedbackTests(_ runner: TestRunner) {
    runner.suite("\"Not for me\" shows that it worked") { r in
        r.run("a row reads as flagged right after the click") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(row(chatId: 1291))
            try await MainActor.run {
                let viewModel = app.viewModel()
                let batch = try require(viewModel.selectedBatch)
                try expect(app.actions.offered(.notForMe, for: batch) == .enabled)
                app.actions.notForMe(batch)
                try expect(app.actions.offered(.notForMe, for: batch) == .taken)
                let after = try require(viewModel.selectedBatch)
                try expect(viewModel.isCorrected(after))
            }
        }

        r.run("a row with no Chat can't be flagged, so the action isn't offered") {
            try await MainActor.run {
                let actions = makeHistoryApp().actions
                try expect(actions.offered(.notForMe, for: historyBatch(row(chatId: nil))) == nil)
                try expect(actions.offered(.notForMe, for: historyBatch(row(chatId: 1291))) == .enabled)
            }
        }

        r.run("Not for me is read back by the Batch it was recorded against") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try expect(app.model.corrections.types(forBatches: ["m1"]).isEmpty)
                app.actions.notForMe(historyBatch(row(chatId: 1291)))
                try expect(app.model.corrections.types(forBatches: ["m1", "m2"]) == ["m1": [.falsePositive]])
            }
        }

        r.run("recording Not for me twice on one Batch keeps exactly one Correction") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.model.corrections.recordNotForMe(row(chatId: 1291))
                try app.model.corrections.recordNotForMe(row(chatId: 1291))
                try expect(app.model.corrections.falsePositives(since: nil).count == 1)
            }
        }

        r.run("a Correction replace whose second write fails keeps the earlier Correction") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let batch = historyBatch(row(chatId: 1291))
                app.actions.notForMe(batch)
                try failCorrectionInserts(at: app.correctionsPath)
                let failed = (try? app.model.corrections.recordNotForMe(row(chatId: 1291))) == nil
                try expect(failed, "the insert half of the replace was meant to fail")
                try expect(app.actions.offered(.notForMe, for: batch) == .taken, "the earlier flag survives")
                try expect(app.model.corrections.falsePositives(since: nil).count == 1)
            }
        }
    }
}
