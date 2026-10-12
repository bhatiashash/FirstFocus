import DailyOSApp
import DailyOSCore
import Foundation

/// superseded-restore: History names the Suggestion an UPDATE or CANCEL
/// replaced, and Restore puts it back in the Suggested Tasks Inbox.
private let chatId = 5
private let base = Date().addingTimeInterval(-7200)

private func line(_ id: String, text: String, at seconds: TimeInterval) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chatId, isFromMe: false, text: text, createdAt: base.addingTimeInterval(seconds),
        senderAddress: "+15550001"
    )
}

private func suggestion(_ id: String, _ label: String, sourceRef: String, at seconds: TimeInterval = 0) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: label, originalText: label.lowercased(),
        createdAt: base.addingTimeInterval(seconds), provenance: .inferred, chatId: chatId
    )
}

private let earlier = line("m1", text: "book a table for friday", at: 0)
private let later = line("m2", text: "actually saturday", at: 600)

/// An app whose store holds an earlier Batch (m1) that produced
/// `suggestions`, with a later message m2 the model answers with
/// `response` once the app starts. History shows every Batch.
@MainActor
private func makeApp(
    suggestions: [Signal] = [suggestion("s1", "Book a table for Friday", sourceRef: "m1")], response: String
) throws -> (HistoryApp, HistoryViewModel) {
    let signals = makeTestSignalStore()
    try signals.markBackfillComplete()
    try signals.recordNonSelfMessagesCutoff(.distantPast)
    try signals.recordProcessedBatch(MessageBatch(messages: [earlier]), signals: suggestions)
    let app = makeHistoryApp(
        messages: [earlier, later], extractor: FakeIntentExtractor(defaultResponse: response), signals: signals
    )
    let viewModel = app.viewModel()
    viewModel.showsUnfilteredLog = true
    return (app, viewModel)
}

@MainActor
private func batch(_ ref: String, in viewModel: HistoryViewModel) throws -> HistoryBatch {
    viewModel.refresh()
    return try require(viewModel.batches.first { $0.id == ref }, "History doesn't list \(ref)")
}

func registerSupersededRestoreTests(_ runner: TestRunner) {
    runner.suite("History names the Suggestion an UPDATE or CANCEL replaced") { r in
        r.run("an UPDATE Batch shows the Label it replaced") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            try await MainActor.run {
                let lines = viewModel.supersededLines(for: try batch("m2", in: viewModel))
                try expect(lines == ["Replaced: Book a table for Friday"], "got \(lines)")
            }
        }

        r.run("a CANCEL Batch shows the Label it withdrew, and Overview lists it though it found no task") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "CANCEL 1") }
            await app.model.start()
            try await MainActor.run {
                viewModel.showsUnfilteredLog = false
                let cancel = try batch("m2", in: viewModel)
                try expect(cancel.result == .noTask)
                let lines = viewModel.supersededLines(for: cancel)
                try expect(lines == ["Withdrew: Book a table for Friday"], "got \(lines)")
            }
        }

        r.run("a Batch that Supersedes two Suggestions names both") {
            let (app, viewModel) = try await MainActor.run {
                try makeApp(
                    suggestions: [
                        suggestion("s1", "Book a table for Friday", sourceRef: "m1"),
                        suggestion("s2", "Order flowers", sourceRef: "m1", at: 1),
                    ],
                    response: "CANCEL 1\nUPDATE 2: Book a table for Saturday"
                )
            }
            await app.model.start()
            try await MainActor.run {
                let lines = viewModel.supersededLines(for: try batch("m2", in: viewModel))
                try expect(lines == ["Replaced: Book a table for Friday", "Withdrew: Order flowers"], "got \(lines)")
            }
        }

        r.run("a Supersession that didn't land, because the Suggestion was Approved first, isn't recorded") {
            let store = makeTestSignalStore()
            try store.recordProcessedBatch(
                MessageBatch(messages: [earlier]), signals: [suggestion("s1", "Book a table for Friday", sourceRef: "m1")]
            )
            try store.approve(signalId: "s1", reminderId: "r1")
            try store.recordProcessedBatch(
                MessageBatch(messages: [later]), signals: [], superseding: [Supersession(signalId: "s1", replacedBy: nil)]
            )
            try expect(store.supersessions(byBatches: ["m2"]).isEmpty, "got \(store.supersessions(byBatches: ["m2"]))")
        }
    }

    runner.suite("Restore a Suggestion a wrong CANCEL withdrew") { r in
        r.run("Restore puts the same Suggestion back in the Inbox, records no Correction, and then shows as taken") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "CANCEL 1") }
            await app.model.start()
            try await MainActor.run {
                try expect(app.model.rankedList.suggested.isEmpty)
                let cancel = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: cancel) == .enabled)
                app.actions.restore(cancel)
                let restored = app.model.rankedList.suggested
                try expect(restored.map(\.id) == ["s1"], "got \(restored.map(\.label))")
                try expect(restored.first?.label == "Book a table for Friday")
                try expect(app.model.corrections.types(forBatches: ["m2"]).isEmpty)
                let after = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: after) == .taken)
                try expect(viewModel.supersededLines(for: after) == ["Withdrew: Book a table for Friday"])
            }
        }

        r.run("a Batch that Superseded nothing doesn't offer Restore") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "Order flowers") }
            await app.model.start()
            try await MainActor.run {
                let plain = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: plain) == nil)
            }
        }

        r.run("once a later Batch Supersedes the restored Suggestion again, the earlier row shows Restored and the later one offers it") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "CANCEL 1") }
            await app.model.start()
            let third = line("m3", text: "no really, cancel it", at: 1200)
            try await MainActor.run {
                app.actions.restore(try batch("m2", in: viewModel))
                try app.signals.recordProcessedBatch(
                    MessageBatch(messages: [third]), signals: [], superseding: [Supersession(signalId: "s1", replacedBy: nil)]
                )
                try app.history.record(HistoryEntry(
                    timestamp: third.createdAt, sourceRawText: third.text, rawOutput: "CANCEL 1", modelUsed: "Q", signalCount: 0,
                    chatId: chatId, sourceRef: "m3"
                ))
                let second = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: second) == .taken)
                let latest = try batch("m3", in: viewModel)
                try expect(app.actions.offered(.restore, for: latest) == .enabled)
                let undid = try app.signals.restore(signalId: "s1", supersededIn: "m2")
                try expect(!undid, "the earlier Batch can't undo the later one")
                try expect(app.signals.openSignals().isEmpty)
            }
        }
    }

    runner.suite("Restore a Suggestion a wrong UPDATE replaced") { r in
        r.run("Restore brings the replaced Suggestion back and dismisses the open replacement") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            try await MainActor.run {
                try expect(app.model.rankedList.suggested.map(\.label) == ["Book a table for Saturday"])
                let update = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: update) == .enabled)
                app.actions.restore(update)
                try expect(app.model.rankedList.suggested.map(\.id) == ["s1"], "got \(app.model.rankedList.suggested.map(\.label))")
                try expect(app.signals.openSignals().map(\.id) == ["s1"], "the replacement is dismissed in the store too")
                try expect(app.model.corrections.types(forBatches: ["m2"]).isEmpty)
            }
        }

        r.run("with the replacement already marked Not for me, Restore is offered and only reopens") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            try await MainActor.run {
                let update = try batch("m2", in: viewModel)
                app.actions.notForMe(update)
                try expect(app.model.rankedList.suggested.isEmpty)
                let afterNotForMe = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: afterNotForMe) == .enabled)
                app.actions.restore(afterNotForMe)
                try expect(app.model.rankedList.suggested.map(\.id) == ["s1"])
                try expect(app.model.corrections.types(forBatches: ["m2"]) == ["m2": [.falsePositive]])
            }
        }

        r.run("Restore isn't offered once the replacement is Approved") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            try await MainActor.run {
                let replacement = try require(app.model.rankedList.suggested.first)
                try app.signals.approve(signalId: replacement.id, reminderId: "r1")
                let update = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: update) == nil)
                app.actions.restore(update)
                try expect(!app.signals.openSignals().contains { $0.id == "s1" })
            }
        }

        r.run("Restore isn't offered once the replacement is itself Superseded") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            let third = line("m3", text: "make it sunday", at: 1200)
            try await MainActor.run {
                let replacement = try require(app.model.rankedList.suggested.first)
                try app.signals.recordProcessedBatch(
                    MessageBatch(messages: [third]), signals: [],
                    superseding: [Supersession(signalId: replacement.id, replacedBy: nil)]
                )
                let update = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: update) == nil)
                let undid = try app.signals.restore(signalId: "s1", supersededIn: "m2")
                try expect(!undid, "the store refuses it too")
            }
        }

        r.run("in a Batch where one Suggestion can come back and one can't, Restore brings back the one and then shows Restored") {
            let (app, viewModel) = try await MainActor.run {
                try makeApp(
                    suggestions: [
                        suggestion("s1", "Book a table for Friday", sourceRef: "m1"),
                        suggestion("s2", "Order flowers", sourceRef: "m1", at: 1),
                    ],
                    response: "CANCEL 1\nUPDATE 2: Book a table for Saturday"
                )
            }
            await app.model.start()
            try await MainActor.run {
                let replacement = try require(app.model.rankedList.suggested.first)
                try app.signals.approve(signalId: replacement.id, reminderId: "r1")
                let mixed = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: mixed) == .enabled)
                app.actions.restore(mixed)
                try expect(app.signals.openSignals().map(\.id) == ["s2"], "got \(app.signals.openSignals().map(\.label))")
                let after = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: after) == .taken)
            }
        }

        r.run("once the replacement's Batch is garbage collected, Restore still brings back the Suggestion it replaced") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "UPDATE 1: Book a table for Saturday") }
            await app.model.start()
            try await MainActor.run {
                try app.signals.garbageCollectSignals(ofBatch: "m2")
                let update = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: update) == .enabled)
                app.actions.restore(update)
                try expect(app.signals.openSignals().map(\.id) == ["s1"])
            }
        }

        r.run("garbage collecting a Superseded Suggestion's Batch takes its Supersession with it") {
            let (app, viewModel) = try await MainActor.run { try makeApp(response: "CANCEL 1") }
            await app.model.start()
            try await MainActor.run {
                try app.signals.garbageCollectSignals(ofBatch: "m1")
                try expect(app.signals.supersessions(byBatches: ["m2"]).isEmpty)
                let cancel = try batch("m2", in: viewModel)
                try expect(app.actions.offered(.restore, for: cancel) == nil)
            }
        }
    }
}
