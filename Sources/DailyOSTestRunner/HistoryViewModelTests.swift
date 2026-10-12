import DailyOSApp
import DailyOSCore
import Foundation

private func entry(
    id: String, sourceRawText: String = "call the dentist", rawOutput: String = "Call the dentist", signalCount: Int = 1,
    chatId: Int = 0
) -> HistoryEntry {
    HistoryEntry(
        id: id, sourceRawText: sourceRawText, rawOutput: rawOutput, modelUsed: "Test Model", signalCount: signalCount,
        chatId: chatId, sourceRef: "ref-\(id)"
    )
}

/// Row-level behaviour carried over from before History grouped by Batch.
/// Batch grouping, sections and selection are in `HistoryDashboardTests`.
func registerHistoryViewModelTests(_ runner: TestRunner) {
    runner.suite("HistoryViewModel") { r in
        r.run("the unfiltered log lists Batches that produced nothing alongside those that did") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(entry(id: "produced", signalCount: 1))
            try app.history.record(entry(id: "empty", rawOutput: "NONE", signalCount: 0))
            try await MainActor.run {
                let viewModel = app.viewModel()
                try expect(viewModel.batches.map(\.id) == ["ref-produced"], "Overview leaves out a Batch that produced nothing")
                viewModel.showsUnfilteredLog = true
                try expect(Set(viewModel.batches.map(\.id)) == Set(["ref-produced", "ref-empty"]))
            }
        }

        r.run("Not for me records the stored row whole, Chat and prompt intact") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(HistoryEntry(
                id: "h1", sourceRawText: "call the dentist", rawOutput: "Call the dentist", modelUsed: "Test Model",
                signalCount: 1, chatId: 42, renderedContext: "[context]\nThem: hi\n\n[latest messages]\nThem: call the dentist",
                sourceRef: "m1"
            ))
            try await MainActor.run {
                let viewModel = app.viewModel()
                app.actions.notForMe(try require(viewModel.selectedBatch))
                let flagged = try require(app.model.corrections.falsePositives(since: nil).first)
                try expect(flagged.chatId == 42)
                try expect(flagged.sourceRef == "m1")
                try expect(flagged.inputText == "[context]\nThem: hi\n\n[latest messages]\nThem: call the dentist")
            }
        }

        r.run("Not for me never touches History itself") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(entry(id: "h1", chatId: 42))
            try await MainActor.run {
                let viewModel = app.viewModel()
                app.actions.notForMe(try require(viewModel.selectedBatch))
            }
            try expect(app.history.allRows().map(\.id) == ["h1"])
        }

        r.run("muting one Batch's Chat never affects a different Chat's Batch") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(entry(id: "h1", chatId: 42))
            try app.history.record(entry(id: "h2", chatId: 7))
            try await MainActor.run {
                let viewModel = app.viewModel()
                let muted = try require(viewModel.batches.first { $0.chatId == 42 })
                let other = try require(viewModel.batches.first { $0.chatId == 7 })
                app.actions.toggleMute(muted)
                try expect(app.actions.isMutedNow(muted))
                try expect(app.actions.isMutedNow(other) == false)
            }
        }

        r.run("exportCSV escapes embedded quotes and commas") {
            let app = await MainActor.run { makeHistoryApp() }
            try app.history.record(entry(id: "h1", rawOutput: "Say \"hi\", then call"))
            let url = try await MainActor.run { try require(app.viewModel().exportCSV()) }
            defer { try? FileManager.default.removeItem(at: url) }
            let csv = try String(contentsOf: url, encoding: .utf8)
            try expect(csv.contains("\"Say \"\"hi\"\", then call\""), "an embedded quote must be doubled per RFC 4180, not left to break the column boundary")
        }
    }
}
