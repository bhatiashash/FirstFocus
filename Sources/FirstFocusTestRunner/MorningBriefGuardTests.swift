import FirstFocusCore
import Foundation

/// Morning Brief ticket 01 (ADR 0046): a message you sent whose first line
/// is the Morning Brief header never reaches Extraction, in any Chat or
/// any kind of pass.
private let base = Date().addingTimeInterval(-3600)

private let brief = "\(morningBriefHeader)\n\nPay rent (overdue)\nCall the dentist\n\n(3 in Later)"

private func note(_ id: String, _ text: String, at seconds: TimeInterval) -> ChatMessage {
    ChatMessage(
        id: id, chatId: 1, isFromMe: true, text: text, createdAt: base.addingTimeInterval(seconds), isSelfThread: true
    )
}

private func line(
    _ id: String, chat: Int = 5, text: String, from address: String? = nil, at seconds: TimeInterval
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chat, isFromMe: address == nil, text: text, createdAt: base.addingTimeInterval(seconds),
        senderAddress: address
    )
}

func registerMorningBriefGuardTests(_ runner: TestRunner) {
    runner.suite("Morning Brief: Intake skips the Brief") { r in
        r.run("a Self-thread Brief yields no Signal and no History row, and is Processed") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            let signals = await refreshThroughIntake(
                from: [note("b1", brief, at: 0)], store: store, extractor: extractor, historyStore: history
            )
            try expect(signals.isEmpty, "got \(signals.map(\.label))")
            try expect(extractor.calls.isEmpty, "got \(extractor.calls)")
            try expect(history.allRows().isEmpty)
            try expect(store.isProcessed(sourceRef: "b1"))
        }

        r.run("a Brief you sent to someone else's Chat is skipped too, and never reaches the Screener") {
            let store = makeTestSignalStore()
            let screener = FakeScreener(probability: 0.9)
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            let deps = ExtractionDependencies(store: store, extractor: extractor, screener: screener, screeningMode: .shadow)
            let signals = await refreshThroughIntake(from: [line("b1", text: brief, at: 0)], deps: deps)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty)
            try expect(screener.inputs.isEmpty)
            try expect(store.isProcessed(sourceRef: "b1"))
        }

        r.run("a Brief sent under an earlier header is still skipped") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            let briefs = ["[DailyOS Morning Brief]", "DailyOS Morning Brief"].enumerated().map {
                note("b\($0.offset)", "\($0.element)\n\nPay rent\n\n(3 in Later)", at: Double($0.offset) * 600)
            }
            let signals = await refreshThroughIntake(from: briefs, store: store, extractor: extractor)
            try expect(signals.isEmpty && extractor.calls.isEmpty, "got \(extractor.calls)")
        }

        r.run("a received message starting with the header is judged as usual") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            let signals = await refreshThroughIntake(
                from: [line("m1", text: brief, from: "+15550001", at: 0)], store: store, extractor: extractor
            )
            try expect(extractor.calls.count == 1)
            try expect(signals.map(\.label) == ["Pay rent"])
        }

        r.run("in a Batch with a reply, only the reply reaches the model, and every member is Processed") {
            let store = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Bring the charger")
            let batch = [
                line("b1", text: brief, at: 0),
                line("m1", text: "can you bring my charger", from: "+15550001", at: 5),
            ]
            let signals = await refreshThroughIntake(from: batch, store: store, extractor: extractor, historyStore: history)
            try expect(extractor.calls == ["[latest messages]\nParticipant A: can you bring my charger"], "got \(extractor.calls)")
            try expect(signals.map(\.label) == ["Bring the charger"])
            try expect(signals.first?.sourceRef == "m1")
            try expect(store.isProcessed(sourceRef: "b1") && store.isProcessed(sourceRef: "m1"))
            try expect(history.allRows().map(\.sourceRef) == ["m1"])
        }

        r.run("a Brief that is the newest in its Batch still leaves the reply's Signal named by the reply") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Bring the charger")
            let batch = [
                line("m1", text: "can you bring my charger", from: "+15550001", at: 0),
                line("b1", text: brief, at: 5),
            ]
            let signals = await refreshThroughIntake(from: batch, store: store, extractor: extractor)
            try expect(signals.map(\.sourceRef) == ["m1"], "got \(signals.map(\.sourceRef))")
            try expect(store.isProcessed(sourceRef: "b1") && store.isProcessed(sourceRef: "m1"))
        }

        r.run("a note after a Brief is extracted with the Brief left out of its context") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "NONE")
            let messages = [note("n0", "buy stamps", at: 0), note("b1", brief, at: 60), note("n1", "call mom", at: 120)]
            _ = await refreshThroughIntake(from: messages, store: store, extractor: extractor)
            let last = try require(extractor.calls.last)
            try expect(!last.contains(morningBriefHeader) && !last.contains("Pay rent"), "got \(last)")
            try expect(last.contains("call mom"))
        }

        r.run("manual re-extraction over a Brief yields nothing") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            let messages = [note("b1", brief, at: 0)]
            _ = await refreshThroughIntake(from: messages, store: store, extractor: extractor)
            await reExtractThroughIntake(messages: messages, store: store, extractor: extractor)
            try expect(extractor.calls.isEmpty, "got \(extractor.calls)")
            try expect(store.openSignals().isEmpty)
        }

        r.run("the first-run backfill skips a Brief") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Pay rent")
            await backfillThroughIntake(messages: [note("b1", brief, at: 0)], store: store, extractor: extractor)
            try expect(extractor.calls.isEmpty, "got \(extractor.calls)")
            try expect(store.isProcessed(sourceRef: "b1"))
        }

        r.run("a Brief mentioning a code never marks the Chat it was sent to Automated") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(defaultResponse: "Reply to Sam")
            let codeBrief = "\(morningBriefHeader)\n\nSend Sam the door code 4821\n\n(0 in Later)"
            let messages = [
                line("b1", text: codeBrief, at: 0),
                line("m1", text: "can you reply to Sam", from: "+15550001", at: 600),
            ]
            let signals = await refreshThroughIntake(from: messages, store: store, extractor: extractor)
            try expect(!store.isAutomated(chatId: 5))
            try expect(signals.map(\.label) == ["Reply to Sam"])
        }
    }
}
