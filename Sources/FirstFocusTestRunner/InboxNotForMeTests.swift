import FirstFocusApp
import FirstFocusCore
import Foundation

/// inbox-not-for-me ticket 01: a Suggestion in the Inbox offers "Not for
/// me" when "no task" is right for its whole Batch, and taking it records
/// the Correction History records.
private let chatId = 7
private let base = Date().addingTimeInterval(-3600)

private func suggestion(_ id: String, _ label: String, sourceRef: String) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label.lowercased(), createdAt: base,
        provenance: .inferred, chatId: chatId
    )
}

private func modelRow(sourceRef: String, rawOutput: String, transcript: [HistoryTranscriptLine]? = nil) -> HistoryEntry {
    HistoryEntry(
        timestamp: base, sourceRawText: "Participant A: \(rawOutput.lowercased())", rawOutput: rawOutput, modelUsed: "Model",
        signalCount: parseExtractionResults(rawOutput).compactMap(\.label).count, chatId: chatId,
        renderedContext: "Participant A: \(rawOutput.lowercased())", sourceRef: sourceRef, transcript: transcript
    )
}

/// "one" produced one Suggestion, "two" produced two. Both have their
/// model-call row in History.
@MainActor
private func makeApp() throws -> HistoryApp {
    let signals = makeTestSignalStore()
    try signals.markBackfillComplete()
    try signals.recordOneMessageBatch("one", chatId: chatId, signals: [suggestion("s1", "Call the dentist", sourceRef: "one")])
    try signals.recordOneMessageBatch("two", chatId: chatId, signals: [
        suggestion("s2", "Grab milk", sourceRef: "two"), suggestion("s3", "Grab bread", sourceRef: "two"),
    ])
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

func registerInboxNotForMeTests(_ runner: TestRunner) {
    runner.suite("\"Not for me\" on a Suggestion in the Inbox") { r in
        r.run("a one-Label Suggestion offers it; taking it records the Batch's false positive and dismisses the Suggestion") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                try expect(app.model.notForMeOffers == ["s1"], "got \(app.model.notForMeOffers)")
                app.actions.notForMe(try signal("s1", in: app))
                try expect(app.model.corrections.types(forBatches: ["one"]) == ["one": [.falsePositive]])
                try expect(app.model.corrections.falsePositives(since: nil).count == 1)
                try expect(suggested(app) == ["s2", "s3"], "got \(suggested(app))")
                let oneBatch = try batch("one", in: app)
                try expect(app.actions.offered(.notForMe, for: oneBatch) == .taken)
                try expect(app.model.notForMeOffers.isEmpty)
            }
        }

        r.run("the Suggestion stays gone in a fresh app on the same stores") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run { app.actions.notForMe(try signal("s1", in: app)) }
            let fresh = await MainActor.run { makeHistoryApp(signals: app.signals, history: app.history) }
            await fresh.model.start()
            try await MainActor.run { try expect(suggested(fresh) == ["s2", "s3"], "got \(suggested(fresh))") }
        }

        r.run("a two-Label Batch offers it in History but on neither Suggestion, even after one is decided") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                try expect(!app.model.notForMeOffers.contains("s2") && !app.model.notForMeOffers.contains("s3"))
                app.model.dismiss(try signal("s2", in: app))
                try expect(!app.model.notForMeOffers.contains("s3"))
                app.actions.notForMe(try signal("s3", in: app))
                try expect(app.model.corrections.types(forBatches: ["two"]).isEmpty, "taking it where it isn't offered records nothing")
                try expect(suggested(app) == ["s1", "s3"])
                let twoBatch = try batch("two", in: app)
                try expect(app.actions.offered(.notForMe, for: twoBatch) == .enabled)
            }
        }

        r.run("a Suggestion made by Add task doesn't offer it") {
            let signals = makeTestSignalStore()
            try signals.markBackfillComplete()
            try signals.recordOneMessageBatch("none", chatId: chatId, signals: [])
            let app = await MainActor.run { makeHistoryApp(signals: signals) }
            try app.history.record(modelRow(
                sourceRef: "none", rawOutput: "NONE",
                transcript: [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: "book the table", sentAt: base)]
            ))
            await app.model.start()
            try await MainActor.run {
                app.actions.addTask("Book the table", to: try batch("none", in: app))
                try expect(app.model.rankedList.suggested.map(\.label) == ["Book the table"])
                try expect(app.model.notForMeOffers.isEmpty, "got \(app.model.notForMeOffers)")
            }
        }

        r.run("a Batch with a missed-task Correction offers it in neither place") {
            let app = try await MainActor.run { try makeApp() }
            try app.corrections.record(Correction(
                chatId: chatId, sourceRef: "one", inputText: "Participant A: call the dentist", correctedOutput: "Call the dentist",
                correctionType: .missedTask
            ))
            await app.model.start()
            try await MainActor.run {
                try expect(!app.model.notForMeOffers.contains("s1"))
                let oneBatch = try batch("one", in: app)
                try expect(app.actions.offered(.notForMe, for: oneBatch) == nil)
            }
        }

        r.run("a Suggestion whose History rows were deleted doesn't offer it") {
            let app = try await MainActor.run { try makeApp() }
            try app.history.delete(sourceRef: "one")
            await app.model.start()
            try await MainActor.run {
                try expect(app.model.notForMeOffers.isEmpty, "got \(app.model.notForMeOffers)")
                app.actions.notForMe(try signal("s1", in: app))
                try expect(app.model.corrections.falsePositives(since: nil).isEmpty)
                try expect(suggested(app).contains("s1"))
            }
        }

        r.run("Dismiss on a Suggestion that offers it records no Correction") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.model.dismiss(try signal("s1", in: app))
                try expect(suggested(app) == ["s2", "s3"])
                try expect(app.model.corrections.types(forBatches: ["one"]).isEmpty)
            }
        }

        r.run("taking it in History drops the Suggestion from the offers; taking it in the Inbox tells History") {
            let app = try await MainActor.run { try makeApp() }
            await app.model.start()
            try await MainActor.run {
                app.actions.notForMe(try batch("one", in: app))
                try expect(app.model.notForMeOffers.isEmpty)
            }

            let other = try await MainActor.run { try makeApp() }
            await other.model.start()
            try await MainActor.run {
                var changes = 0
                other.actions.onChange = { changes += 1 }
                other.actions.notForMe(try signal("s1", in: other))
                try expect(changes == 1, "got \(changes)")
            }
        }
    }

    runner.suite("\"Not for me\" on a Suggestion made by UPDATE") { r in
        r.run("offers it, and taking it leaves the Suggestion it replaced Superseded") {
            let earlier = ChatMessage(
                id: "m1", chatId: chatId, isFromMe: false, text: "book a table for friday", createdAt: base, senderAddress: "+15550001"
            )
            let later = ChatMessage(
                id: "m2", chatId: chatId, isFromMe: false, text: "actually saturday", createdAt: base.addingTimeInterval(600),
                senderAddress: "+15550001"
            )
            let signals = makeTestSignalStore()
            try signals.markBackfillComplete()
            try signals.recordNonSelfMessagesCutoff(.distantPast)
            try signals.recordProcessedBatch(MessageBatch(messages: [earlier]), signals: [
                suggestion("s1", "Book a table for Friday", sourceRef: "m1"),
            ])
            let app = await MainActor.run {
                makeHistoryApp(
                    messages: [earlier, later], extractor: FakeIntentExtractor(defaultResponse: "UPDATE 1: Book a table for Saturday"),
                    signals: signals
                )
            }
            await app.model.start()
            try await MainActor.run {
                let replacement = try require(app.model.rankedList.suggested.first, "no replacement Suggestion")
                try expect(replacement.label == "Book a table for Saturday" && replacement.sourceRef == "m2")
                try expect(app.model.notForMeOffers == [replacement.id], "got \(app.model.notForMeOffers)")
                app.actions.notForMe(replacement)
                try expect(app.model.corrections.types(forBatches: ["m2"]) == ["m2": [.falsePositive]])
                try expect(app.model.rankedList.suggested.isEmpty)
            }
            try expect(signals.openSignals().isEmpty, "the Superseded Suggestion stays out of the Inbox")
        }
    }
}
