import DailyOSApp
import DailyOSCore
import Foundation

/// inbox-undo: every action in the Suggested Tasks Inbox shows the Undo
/// bar, and Undo reverses what the action already wrote (ADR 0043).
private let chatId = 7
private let base = Date().addingTimeInterval(-3600)

private func suggestion(_ id: String, _ label: String, sourceRef: String, dueAt: Date? = nil, sender: String? = nil) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label.lowercased(), createdAt: base,
        dueAt: dueAt, provenance: .inferred, sender: sender, chatId: chatId
    )
}

private func modelRow(sourceRef: String, rawOutput: String) -> HistoryEntry {
    HistoryEntry(
        timestamp: base, sourceRawText: "Participant A: \(rawOutput.lowercased())", rawOutput: rawOutput, modelUsed: "Model",
        signalCount: parseExtractionResults(rawOutput).compactMap(\.label).count, chatId: chatId,
        renderedContext: "Participant A: \(rawOutput.lowercased())", sourceRef: sourceRef
    )
}

/// "one" produced one Suggestion, "two" produced two. Both have their
/// model-call row in History.
@MainActor
private func makeApp(extra: [(batch: String, signal: Signal)] = []) throws -> HistoryApp {
    let signals = makeTestSignalStore()
    try signals.markBackfillComplete()
    try signals.recordOneMessageBatch("one", chatId: chatId, signals: [suggestion("s1", "Call the dentist", sourceRef: "one")])
    try signals.recordOneMessageBatch("two", chatId: chatId, signals: [
        suggestion("s2", "Grab milk", sourceRef: "two"), suggestion("s3", "Grab bread", sourceRef: "two"),
    ])
    for (batch, signal) in extra {
        try signals.recordOneMessageBatch(batch, chatId: chatId, signals: [signal])
    }
    let app = makeHistoryApp(signals: signals)
    try app.history.record(modelRow(sourceRef: "one", rawOutput: "Call the dentist"))
    try app.history.record(modelRow(sourceRef: "two", rawOutput: "Grab milk\nGrab bread"))
    return app
}

@MainActor
private func suggested(_ app: HistoryApp) -> [String] {
    app.model.rankedList.suggested.map(\.id).sorted()
}

@MainActor
private func signal(_ id: String, in app: HistoryApp) throws -> Signal {
    try require(app.model.rankedList.suggested.first { $0.id == id }, "\(id) isn't in the Inbox")
}

@MainActor
private func batch(_ ref: String, in app: HistoryApp) throws -> HistoryBatch {
    try require(app.history.batches(forSourceRefs: [ref])[ref], "no History for \(ref)")
}

@MainActor
private func freshSuggested(_ app: HistoryApp) async -> [String] {
    let fresh = makeHistoryApp(signals: app.signals, history: app.history)
    await fresh.model.start()
    return suggested(fresh)
}

func registerInboxUndoTests(_ runner: TestRunner) {
    runner.suite("Undo Dismiss from the Inbox (inbox-undo 02)") { r in
        r.run("Dismiss shows the bar and is written at once") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.dismiss(try signal("s1", in: app))
                let offer = app.model.undoOffer
                try expect(offer?.text == "Dismissed \u{201C}Call the dentist\u{201D}", "got \(String(describing: offer))")
                try expect(offer?.canUndo == true)
                try expect(suggested(app) == ["s2", "s3"])
            }
            let fresh = await freshSuggested(app)
            try expect(fresh == ["s2", "s3"], "a fresh app sees the Dismiss already, got \(fresh)")
        }

        r.run("Undo puts the Suggestion back under the same id, focused, and it stays back") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run { app.model.dismiss(try signal("s1", in: app)) }
            await app.model.undo()
            try await MainActor.run {
                try expect(suggested(app) == ["s1", "s2", "s3"], "got \(suggested(app))")
                try expect(app.model.focusedSuggestionId == "s1")
                try expect(app.model.undoOffer == nil)
            }
            let fresh = await freshSuggested(app)
            try expect(fresh == ["s1", "s2", "s3"], "got \(fresh)")
        }

        r.run("Delete from the keyboard shows the bar too, and Undo moves focus back") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            await MainActor.run { app.model.focusedSuggestionId = "s1" }
            await app.model.handleInboxKey(.dismiss)
            let offer = await MainActor.run { app.model.undoOffer }
            try expect(offer?.action == .dismissed)
            await app.model.undo()
            let focused = await MainActor.run { app.model.focusedSuggestionId }
            try expect(focused == "s1", "got \(String(describing: focused))")
        }

        r.run("Undo still reopens it when another open Suggestion has the same Label") {
            let app = try await MainActor.run {
                try makeApp(extra: [("three", suggestion("s4", "Call the dentist", sourceRef: "three"))])
            }
            await app.model.start()
            try await MainActor.run { app.model.dismiss(try signal("s1", in: app)) }
            await app.model.undo()
            try await MainActor.run { try expect(suggested(app) == ["s1", "s2", "s3", "s4"], "got \(suggested(app))") }
        }

        r.run("Undo records no Correction") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run { app.model.dismiss(try signal("s1", in: app)) }
            await app.model.undo()
            try await MainActor.run {
                try expect(app.model.corrections.types(forBatches: ["one", "two"]).isEmpty)
            }
        }
    }

    runner.suite("Undo Approve (inbox-undo 03)") { r in
        r.run("Approve shows the bar with the Tier it landed in, and the task is there at once") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s1", in: app) })
            try await MainActor.run {
                let offer = app.model.undoOffer
                try expect(offer?.text == "Added \u{201C}Call the dentist\u{201D} to Later", "got \(String(describing: offer))")
                try expect(app.model.rankedList.later.map(\.label) == ["Call the dentist"])
                try expect(suggested(app) == ["s2", "s3"])
            }
        }

        r.run("a Suggestion due today says it went to Focus") {
            let today = Calendar.current.startOfDay(for: Date())
            let app = try await MainActor.run {
                try makeApp(extra: [("three", suggestion("s4", "Pay rent", sourceRef: "three", dueAt: today))])
            }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s4", in: app) })
            try await MainActor.run {
                try expect(app.model.undoOffer?.text == "Added \u{201C}Pay rent\u{201D} to Focus", "got \(String(describing: app.model.undoOffer))")
                try expect(app.model.rankedList.focus.map(\.label) == ["Pay rent"])
            }
        }

        r.run("Undo deletes the reminder and puts the Suggestion back, focused, and it stays that way") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s1", in: app) })
            await app.model.undo()
            try await MainActor.run {
                try expect(app.taskSource.tasks.isEmpty, "got \(app.taskSource.tasks.map(\.title))")
                try expect(app.model.rankedList.later.isEmpty && app.model.rankedList.focus.isEmpty)
                try expect(suggested(app) == ["s1", "s2", "s3"], "got \(suggested(app))")
                try expect(app.model.focusedSuggestionId == "s1")
                try expect(app.model.undoOffer == nil)
            }
            let fresh = await freshSuggested(app)
            try expect(fresh == ["s1", "s2", "s3"], "got \(fresh)")
        }

        r.run("Undo after the reminder was already deleted still puts the Suggestion back") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s1", in: app) })
            let reminderId = try require(app.taskSource.tasks.first?.id)
            try app.taskSource.delete(id: reminderId)
            await app.model.undo()
            try await MainActor.run { try expect(suggested(app) == ["s1", "s2", "s3"], "got \(suggested(app))") }
        }

        r.run("Undo clears the approved Sender") {
            let app = try await MainActor.run {
                try makeApp(extra: [("three", suggestion("s4", "Book the table", sourceRef: "three", sender: "Mom"))])
            }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s4", in: app) })
            let reminderId = try require(app.taskSource.tasks.first?.id)
            try expect(app.signals.approvedSender(reminderId: reminderId) == "Mom")
            await app.model.undo()
            try expect(app.signals.approvedSender(reminderId: reminderId) == nil)
        }
    }

    runner.suite("Undo \"Not for me\" from History (inbox-undo 04)") { r in
        r.run("Undo deletes the false positive, the row offers it again, and the Suggestion is back") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                let one = try batch("one", in: app)
                app.actions.notForMe(one)
                try expect(app.actions.offered(.notForMe, for: one) == .taken)
                app.actions.undoNotForMe(one)
                try expect(app.model.corrections.types(forBatches: ["one"]).isEmpty)
                try expect(app.model.corrections.falsePositives(since: nil).isEmpty)
                try expect(app.actions.offered(.notForMe, for: one) == .enabled)
                try expect(suggested(app) == ["s1", "s2", "s3"], "got \(suggested(app))")
                try expect(app.model.notForMeOffers == ["s1"], "got \(app.model.notForMeOffers)")
            }
            let fresh = await freshSuggested(app)
            try expect(fresh == ["s1", "s2", "s3"], "got \(fresh)")
        }

        r.run("it comes back even when a re-run of the same Batch made a new open Suggestion") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.actions.notForMe(try batch("one", in: app))
                try app.signals.recordReExtractedSignals(
                    sourceRef: "one", signals: [suggestion("s5", "Call the dentist", sourceRef: "one")]
                )
                app.actions.undoNotForMe(try batch("one", in: app))
                try expect(suggested(app) == ["s1", "s2", "s3", "s5"], "got \(suggested(app))")
            }
        }

        r.run("only what \"Not for me\" dismissed comes back: a Suggestion dismissed with × before stays dismissed") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.dismiss(try signal("s2", in: app))
                app.actions.notForMe(try batch("two", in: app))
                try expect(suggested(app) == ["s1"])
                app.actions.undoNotForMe(try batch("two", in: app))
                try expect(suggested(app) == ["s1", "s3"], "got \(suggested(app))")
            }
        }

        r.run("an Approved Suggestion from the Batch stays Approved") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            await app.model.approve(try await MainActor.run { try signal("s2", in: app) })
            try await MainActor.run {
                app.actions.notForMe(try batch("two", in: app))
                app.actions.undoNotForMe(try batch("two", in: app))
                try expect(suggested(app) == ["s1", "s3"], "got \(suggested(app))")
                try expect(app.model.rankedList.later.map(\.label) == ["Grab milk"])
            }
        }

        r.run("a \"Not for me\" with no record of what it dismissed still deletes the Correction") {
            let app = try await MainActor.run { try makeApp() }
            try app.corrections.record(Correction(
                chatId: chatId, sourceRef: "one", inputText: "Participant A: call the dentist", correctedOutput: "NONE",
                correctionType: .falsePositive
            ))
            await app.model.start()
            try await MainActor.run {
                app.actions.undoNotForMe(try batch("one", in: app))
                try expect(app.model.corrections.types(forBatches: ["one"]).isEmpty)
                try expect(suggested(app) == ["s1", "s2", "s3"])
            }
        }

        r.run("Undo on a Batch not marked does nothing") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.dismiss(try signal("s1", in: app))
                app.actions.undoNotForMe(try batch("one", in: app))
                try expect(suggested(app) == ["s2", "s3"], "got \(suggested(app))")
            }
        }
    }

    runner.suite("Undo \"Not for me\" from the Inbox (inbox-undo 05)") { r in
        r.run("the thumbs-down shows the bar, and the Correction and Dismiss are written at once") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.notForMe(try signal("s1", in: app))
                try expect(app.model.undoOffer?.text == "Marked \u{201C}Call the dentist\u{201D} Not for me", "got \(String(describing: app.model.undoOffer))")
                try expect(app.model.corrections.types(forBatches: ["one"]) == ["one": [.falsePositive]])
                try expect(suggested(app) == ["s2", "s3"])
            }
        }

        r.run("Undo reverses it the way History's does, and focuses the Suggestion") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run { app.model.notForMe(try signal("s1", in: app)) }
            await app.model.undo()
            try await MainActor.run {
                try expect(app.model.corrections.types(forBatches: ["one"]).isEmpty)
                try expect(suggested(app) == ["s1", "s2", "s3"], "got \(suggested(app))")
                try expect(app.model.focusedSuggestionId == "s1")
                try expect(app.model.notForMeOffers == ["s1"], "the thumbs-down shows on it again")
                let one = try batch("one", in: app)
                try expect(app.actions.offered(.notForMe, for: one) == .enabled)
            }
            let fresh = await freshSuggested(app)
            try expect(fresh == ["s1", "s2", "s3"], "got \(fresh)")
        }

        r.run("where the Inbox doesn't offer it, nothing happens and no bar shows") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.notForMe(try signal("s2", in: app))
                try expect(app.model.undoOffer == nil)
                try expect(suggested(app) == ["s1", "s2", "s3"])
            }
        }
    }
}
