import DailyOSApp
import DailyOSCore
import Foundation

/// history-batch-actions tickets 02 and 03: an action is offered only when
/// taking it will do something, and History re-reads whenever something it
/// shows changes, a pass ending included.

private let chatId = 1

private func transcript(_ text: String, at: Date = Date()) -> [HistoryTranscriptLine] {
    [HistoryTranscriptLine(speaker: "Mom", isFromMe: false, text: text, sentAt: at)]
}

/// One Batch for each action to be enabled on: a task the model found, one
/// it found nothing in, one Screening stopped, and one whose CANCEL
/// withdrew an earlier Suggestion.
private let fixture: [HistoryEntry] = [
    HistoryEntry(
        timestamp: Date().addingTimeInterval(-400), sourceRawText: "never mind the flowers", rawOutput: "CANCEL 1",
        modelUsed: "Q", signalCount: 0, chatId: chatId, sourceRef: "cancel", sender: "Mom"
    ),
    HistoryEntry(
        timestamp: Date().addingTimeInterval(-300), sourceRawText: "can you call the dentist", rawOutput: "Call the dentist",
        modelUsed: "Q", signalCount: 1, chatId: chatId, sourceRef: "task", sender: "Mom",
        transcript: transcript("can you call the dentist")
    ),
    HistoryEntry(
        timestamp: Date().addingTimeInterval(-200), sourceRawText: "can you book the table", rawOutput: "NONE",
        modelUsed: "Q", signalCount: 0, chatId: chatId, sourceRef: "none", sender: "Mom",
        transcript: transcript("can you book the table")
    ),
    HistoryEntry(
        timestamp: Date().addingTimeInterval(-100), sourceRawText: "send the invoice", modelUsed: "JEV", signalCount: 0,
        chatId: chatId, kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))),
        sourceRef: "screened", sender: "Mom", transcript: transcript("send the invoice")
    ),
]

/// Everything History and the Suggested Tasks Inbox show that an action on
/// a Batch could change.
private struct Seen: Equatable {
    let rows: [String: Int]
    let badges: [String: [String]]
    let states: [String]
    let suggestions: [String]
}

@MainActor
private func seen(_ app: HistoryApp, _ viewModel: HistoryViewModel) -> Seen {
    let batches = viewModel.batches
    return Seen(
        rows: Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0.rows.count) }),
        badges: Dictionary(uniqueKeysWithValues: batches.map { ($0.id, viewModel.badges(for: $0).map(\.text)) }),
        states: batches.flatMap { batch in
            HistoryBatchAction.allCases.map { "\(batch.id) \($0): \(String(describing: viewModel.offers(for: batch)[$0]))" }
        },
        suggestions: app.model.rankedList.suggested.map(\.label)
    )
}

@MainActor
private func take(_ action: HistoryBatchAction, on batch: HistoryBatch, in app: HistoryApp) async {
    switch action {
    case .notForMe: app.actions.notForMe(batch)
    case .thisWasWork: await app.actions.thisWasWork(batch)
    case .addTask: app.actions.addTask("Book the table", to: batch)
    case .rerun: await app.actions.rerun(batch)
    case .mute: app.actions.toggleMute(batch)
    case .restore: app.actions.restore(batch)
    }
}

/// An app over `fixture`, the "task" Batch's Signal open in Suggestions,
/// and History showing every Batch.
@MainActor
private func makeFixtureApp(extractor: (any IntentExtractor)?) throws -> (HistoryApp, HistoryViewModel) {
    let signals = makeTestSignalStore()
    try signals.markBackfillComplete()
    try signals.recordOneMessageBatch("task", signals: [Signal(
        id: "s1", source: .messages, sourceRef: "task", label: "Call the dentist", originalText: "Mom: can you call the dentist",
        createdAt: Date(), provenance: .inferred, chatId: chatId
    )])
    try signals.recordOneMessageBatch("none", signals: [])
    try signals.recordOneMessageBatch("screened", signals: [])
    try signals.recordOneMessageBatch("flowers", signals: [Signal(
        id: "s0", source: .messages, sourceRef: "flowers", label: "Order flowers", originalText: "Mom: order flowers",
        createdAt: Date(), provenance: .inferred, chatId: chatId
    )])
    try signals.recordProcessedBatch(
        MessageBatch(messages: [ChatMessage(id: "cancel", chatId: chatId, isFromMe: false, text: "", createdAt: Date())]),
        signals: [], superseding: [Supersession(signalId: "s0", replacedBy: nil)]
    )
    try signals.recordNonSelfMessagesCutoff(.distantPast)
    // The Batches' messages are still in chat.db, so a pass keeps their
    // Signals and "This was work" finds its Batch.
    let flowers = ChatMessage(
        id: "flowers", chatId: chatId, isFromMe: false, text: "order flowers", createdAt: Date().addingTimeInterval(-500),
        senderAddress: "+15550001"
    )
    let messages = [flowers] + fixture.map { entry in
        ChatMessage(
            id: entry.sourceRef!, chatId: chatId, isFromMe: false, text: entry.sourceRawText, createdAt: entry.timestamp,
            senderAddress: "+15550001"
        )
    }
    let app = makeHistoryApp(messages: messages, extractor: extractor, signals: signals)
    for entry in fixture { try app.history.record(entry) }
    let viewModel = app.viewModel()
    viewModel.showsUnfilteredLog = true
    return (app, viewModel)
}

func registerHistoryActionOfferTests(_ runner: TestRunner) {
    runner.suite("History actions: offered means it does something") { r in
        for action in HistoryBatchAction.allCases {
            r.run("\(action), offered and enabled, changes what History or Suggestions show") {
                let (app, viewModel) = try await MainActor.run { try makeFixtureApp(extractor: FakeIntentExtractor()) }
                await app.model.start()
                let (batch, before) = try await MainActor.run { () -> (HistoryBatch, Seen) in
                    let batch = try require(
                        viewModel.batches.first { viewModel.offers(for: $0)[action] == .enabled },
                        "no Batch in the fixture offers \(action)"
                    )
                    return (batch, seen(app, viewModel))
                }
                await take(action, on: batch, in: app)
                let after = await MainActor.run { seen(app, viewModel) }
                try expect(after != before, "\(action) on \(batch.id) changed nothing")
            }
        }

        r.run("Not for me dismisses the task, and This was work, Add task and Re-run each leave their mark") {
            let (app, viewModel) = try await MainActor.run { try makeFixtureApp(extractor: FakeIntentExtractor()) }
            await app.model.start()
            let batches = try await MainActor.run { () -> [String: HistoryBatch] in
                try expect(app.model.rankedList.suggested.map(\.label) == ["Call the dentist"])
                return Dictionary(uniqueKeysWithValues: viewModel.batches.map { ($0.id, $0) })
            }
            await MainActor.run { app.actions.notForMe(batches["task"]!) }
            await app.actions.thisWasWork(batches["screened"]!)
            await MainActor.run { app.actions.addTask("Book the table", to: batches["none"]!) }
            await app.actions.rerun(batches["none"]!)
            try await MainActor.run {
                try expect(app.model.rankedList.suggested.map(\.label) == ["Book the table"])
                try expect(viewModel.weekSummary.corrected == 3)
                let none = try require(viewModel.batches.first { $0.id == "none" })
                try expect(none.reruns.count == 1)
            }
        }
    }

    runner.suite("History actions: disabled or not offered") { r in
        r.run("with no model loaded, This was work and Re-run show disabled with the reason, and clicking changes nothing") {
            let (app, viewModel) = try await MainActor.run { try makeFixtureApp(extractor: nil) }
            let (screened, none, before) = try await MainActor.run { () -> (HistoryBatch, HistoryBatch, Seen) in
                let screened = try require(viewModel.batches.first { $0.id == "screened" })
                let none = try require(viewModel.batches.first { $0.id == "none" })
                let noModel = HistoryActionState.unavailable(reason: "No model loaded")
                try expect(app.actions.offered(.thisWasWork, for: screened) == noModel)
                try expect(app.actions.offered(.rerun, for: none) == noModel)
                try expect(app.actions.offered(.addTask, for: none) == .enabled, "Add task needs no model")
                return (screened, none, seen(app, viewModel))
            }
            await app.actions.thisWasWork(screened)
            await app.actions.rerun(none)
            let after = await MainActor.run { seen(app, viewModel) }
            try expect(after == before)
            try await MainActor.run { try expect(app.model.corrections.types(forBatches: ["screened"]).isEmpty) }
        }

        r.run("a row with no Chat offers no Chat-scoped action") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let rows = [
                    HistoryEntry(sourceRawText: "x", rawOutput: "Call Mom", modelUsed: "Q", signalCount: 1, sourceRef: "a"),
                    HistoryEntry(sourceRawText: "x", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, sourceRef: "b", transcript: transcript("x")),
                    HistoryEntry(
                        sourceRawText: "x", modelUsed: "JEV", signalCount: 0,
                        kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "c"
                    ),
                ]
                for row in rows {
                    let batch = historyBatch(row)
                    for action in [HistoryBatchAction.notForMe, .thisWasWork, .addTask, .mute] {
                        try expect(app.actions.offered(action, for: batch) == nil, "\(action) offered on \(row.sourceRef ?? "")")
                    }
                }
            }
        }

        r.run("a row with no Batch reference offers no action at all") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let batch = historyBatch(HistoryEntry(sourceRawText: "x", rawOutput: "Call Mom", modelUsed: "Q", signalCount: 1, chatId: 4))
                for action in [HistoryBatchAction.notForMe, .addTask, .thisWasWork, .rerun] {
                    try expect(app.actions.offered(action, for: batch) == nil, "\(action) offered")
                }
                try expect(app.actions.offered(.mute, for: batch) == .enabled, "Mute needs only the Chat")
            }
        }

        r.run("an old row with no transcript doesn't offer Add task") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let old = HistoryEntry(sourceRawText: "x", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 4, sourceRef: "m1")
                try expect(app.actions.offered(.addTask, for: historyBatch(old)) == nil)
                app.actions.addTask("Book the table", to: historyBatch(old))
                try expect(app.model.corrections.types(forBatches: ["m1"]).isEmpty)
            }
        }

        r.run("Add task in the Self-thread keeps the note's own wording, whatever the row is titled") {
            let app = await MainActor.run { makeHistoryApp() }
            let note = HistoryEntry(
                sourceRawText: "buy milk", rawOutput: "NONE", modelUsed: "Q", signalCount: 0, chatId: 4, sourceRef: "m1",
                transcript: [HistoryTranscriptLine(speaker: "You", isFromMe: true, text: "buy milk", sentAt: Date())],
                chatTitle: "Not the Self-thread's title", isSelfThread: true, isAllMine: true
            )
            await MainActor.run { app.actions.addTask("Buy milk", to: historyBatch(note)) }
            let added = try require(app.signals.openSignals().first)
            try expect(added.originalText == "buy milk")
            try expect(added.sender == nil)
        }
    }

    runner.suite("History re-reads when a pass ends") { r in
        r.run("a Batch a pass writes shows while History is open") {
            let messages = [ChatMessage(
                id: "m1", chatId: chatId, isFromMe: false, text: "can you call the dentist",
                createdAt: Date().addingTimeInterval(-600), senderAddress: "+15550001"
            )]
            let app = await MainActor.run { makeHistoryApp(messages: messages, extractor: FakeIntentExtractor(defaultResponse: "Call the dentist")) }
            let viewModel = await MainActor.run { app.viewModel() }
            try await MainActor.run { try expect(viewModel.batches.isEmpty) }
            await app.model.start()
            try await MainActor.run {
                try expect(viewModel.batches.map(\.id) == ["m1"], "got \(viewModel.batches.map(\.id))")
            }
        }

        r.run("This was work during a pass sends the Batch once the pass ends, and History shows the result") {
            let extractor = GatedIntentExtractor()
            let messages = [
                ChatMessage(
                    id: "old", chatId: chatId, isFromMe: false, text: "can you send the invoice",
                    createdAt: Date().addingTimeInterval(-7200), senderAddress: "+15550001"
                ),
                ChatMessage(
                    id: "new", chatId: chatId, isFromMe: false, text: "are you around",
                    createdAt: Date().addingTimeInterval(-60), senderAddress: "+15550001"
                ),
            ]
            let signals = makeTestSignalStore()
            try signals.markBackfillComplete()
            try signals.recordNonSelfMessagesCutoff(.distantPast)
            try signals.recordOneMessageBatch("old", signals: [])
            let app = await MainActor.run { makeHistoryApp(messages: messages, extractor: extractor, signals: signals) }
            try app.history.record(HistoryEntry(
                timestamp: Date().addingTimeInterval(-7200), sourceRawText: "can you send the invoice", modelUsed: "JEV",
                signalCount: 0, chatId: chatId, kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))),
                sourceRef: "old"
            ))
            let viewModel = await MainActor.run {
                let viewModel = app.viewModel()
                viewModel.showsUnfilteredLog = true
                return viewModel
            }
            let launch = Task { await app.model.start() }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel, "the launch pass reached the model")
            let screened = try await MainActor.run { try require(viewModel.batches.first { $0.id == "old" }) }
            let work = Task { await app.actions.thisWasWork(screened) }
            let ranEarly = await waitUntil(timeout: 0.2) { extractor.calls.count > 1 }
            try expect(!ranEarly, "This was work waits for the running pass")
            extractor.open()
            await work.value
            await launch.value
            try expect(extractor.calls.count == 2 && extractor.calls[1].contains("can you send the invoice"), "got \(extractor.calls)")
            try await MainActor.run {
                let after = try require(viewModel.batches.first { $0.id == "old" })
                try expect(after.resultSummary == "The model found no task.", "got \(after.result)")
                try expect(viewModel.isCorrected(after))
            }
        }
    }
}
