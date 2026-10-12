import DailyOSCore
import Foundation

/// intake-pass-slot ticket 01: Messages Intake's three actions (refresh,
/// re-extract, extract one Batch now) share one pass slot and one opening
/// read. These pin what each action does at the edges, whichever kind of
/// pass is running.
private func message(id: String, chatId: Int = 1, text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId, isFromMe: true, text: text, createdAt: Date().addingTimeInterval(-60))
}

@MainActor
private func makeIntake(
    messages: [ChatMessage], availability: SourceAvailability = .available, confirmedGoneRefs: Set<String> = [],
    extractor: (any IntentExtractor)? = FakeIntentExtractor(), store: SQLiteSignalStore = makeTestSignalStore()
) -> (MessagesIntake, FakeMessagesSource) {
    let source = FakeMessagesSource(messages: messages, confirmedGoneRefs: confirmedGoneRefs, availability: availability)
    try? store.markBackfillComplete()
    return (
        MessagesIntake(
            messagesSource: source, signalStore: store, contactsResolver: FakeContactsResolver(),
            bundlePath: "/nonexistent", extractor: extractor
        ),
        source
    )
}

private func isUnavailable(_ result: MessagesIntake.Result) -> Bool {
    if case .unavailable = result { return true } else { return false }
}

private func isExtractionUnavailable(_ result: MessagesIntake.Result) -> Bool {
    if case .extractionUnavailable = result { return true } else { return false }
}

func registerIntakePassKindTests(_ runner: TestRunner) {
    runner.suite("MessagesIntake: every action reads Messages the same way") { r in
        r.run("a denied Gate returns Unavailable from refresh, re-extract and extract-now alike") {
            let (intake, _) = await MainActor.run { makeIntake(messages: [message(id: "m1", text: "call the dentist")], availability: .unavailable) }
            let refreshed = await intake.refresh(now: Date())
            let reExtracted = await intake.reExtract(now: Date(), lookbackDays: 7)
            let explicit = await intake.extractNow(sourceRef: "m1")
            try expect(isUnavailable(refreshed) && isUnavailable(reExtracted) && isUnavailable(explicit))
        }

        r.run("with no model loaded every action returns extraction-unavailable, and refresh still garbage collects") {
            let store = makeTestSignalStore()
            let gone = Signal(
                id: "s1", source: .messages, sourceRef: "m-gone", label: "Old", originalText: "old", createdAt: Date(),
                provenance: .inferred
            )
            try store.recordOneMessageBatch("m-gone", signals: [gone])
            let (intake, _) = await MainActor.run {
                makeIntake(
                    messages: [message(id: "m1", text: "call the dentist")], confirmedGoneRefs: ["m-gone"], extractor: nil,
                    store: store
                )
            }
            let refreshed = await intake.refresh(now: Date())
            let reExtracted = await intake.reExtract(now: Date(), lookbackDays: 7)
            let explicit = await intake.extractNow(sourceRef: "m1")
            try expect(isExtractionUnavailable(refreshed) && isExtractionUnavailable(reExtracted) && isExtractionUnavailable(explicit))
            try expect(!store.openSignals().contains { $0.id == "s1" }, "a vanished message's Signal is collected with no model")
        }
    }

    runner.suite("MessagesIntake: which calls join a running pass and which wait") { r in
        r.run("extract-now during a refresh waits for it, then sends its own Batch to the model") {
            let extractor = GatedIntentExtractor()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m0", signals: [])
            let (intake, _) = await MainActor.run {
                makeIntake(
                    messages: [message(id: "m0", chatId: 7, text: "screened ask"), message(id: "m1", text: "call the dentist")],
                    extractor: extractor, store: store
                )
            }
            let running = Task { await intake.refresh(now: Date()) }
            let refreshReachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(refreshReachedModel, "the refresh reaches the model")
            let explicit = Task { await intake.extractNow(sourceRef: "m0") }
            _ = await waitUntil(timeout: 0.5) { extractor.calls.count >= 2 }
            try expect(extractor.calls.count == 1, "extract-now waits its turn, got \(extractor.calls)")
            extractor.open()
            _ = await running.value
            _ = await explicit.value
            try expect(extractor.calls.contains { $0.contains("screened ask") }, "then it runs its own, got \(extractor.calls)")
        }

        r.run("a refresh during a re-extraction joins it and earns one follow-up that picks up a new message") {
            let extractor = GatedIntentExtractor()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            let (intake, source) = await MainActor.run {
                makeIntake(messages: [message(id: "m1", text: "call the dentist")], extractor: extractor, store: store)
            }
            let reExtracting = Task { await intake.reExtract(now: Date(), lookbackDays: 7) }
            let reExtractionReachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reExtractionReachedModel, "the re-extraction reaches the model")
            source.messages.append(message(id: "m2", chatId: 2, text: "book the flights"))
            let joining = Task { await intake.refresh(now: Date()) }
            _ = await waitUntil(timeout: 0.5) { extractor.calls.count >= 2 }
            try expect(extractor.calls.count == 1, "the refresh joins rather than starting a second pass")
            extractor.open()
            _ = await reExtracting.value
            _ = await joining.value
            try expect(store.isProcessed(sourceRef: "m2"), "the follow-up pass extracted the message that arrived mid-pass")
            try expect(extractor.calls.filter { $0.contains("book the flights") }.count == 1)
        }
    }

    runner.suite("MessagesIntake: says which kind of pass is running") { r in
        r.run("a refresh, a refresh joining it, then a re-extraction waiting its turn") {
            let extractor = GatedIntentExtractor()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m0", signals: [])
            let (intake, _) = await MainActor.run {
                makeIntake(
                    messages: [message(id: "m0", chatId: 7, text: "old ask"), message(id: "m1", text: "call the dentist")],
                    extractor: extractor, store: store
                )
            }
            let seen = await MainActor.run { () -> PassKindLog in
                let log = PassKindLog()
                intake.onPassChange = { log.kinds.append($0) }
                return log
            }
            let running = Task { await intake.refresh(now: Date()) }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel)
            try await MainActor.run { try expect(intake.runningPass == .automatic) }
            let joining = Task { await intake.refresh(now: Date()) }
            let waiting = Task { await intake.reExtract(now: Date(), lookbackDays: 7) }
            extractor.open()
            _ = await running.value
            _ = await joining.value
            _ = await waiting.value
            try await MainActor.run {
                try expect(seen.kinds == [.automatic, nil, .reExtraction, nil], "got \(seen.kinds)")
                try expect(intake.runningPass == nil)
            }
        }

        r.run("a re-extraction's follow-up pass reports itself as automatic") {
            let extractor = GatedIntentExtractor()
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            let (intake, _) = await MainActor.run {
                makeIntake(messages: [message(id: "m1", text: "call the dentist")], extractor: extractor, store: store)
            }
            let seen = await MainActor.run { () -> PassKindLog in
                let log = PassKindLog()
                intake.onPassChange = { log.kinds.append($0) }
                return log
            }
            let reExtracting = Task { await intake.reExtract(now: Date(), lookbackDays: 7) }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel)
            let joining = Task { await intake.refresh(now: Date()) }
            extractor.open()
            _ = await reExtracting.value
            _ = await joining.value
            try await MainActor.run { try expect(seen.kinds == [.reExtraction, .automatic, nil], "got \(seen.kinds)") }
        }
    }
}

@MainActor
private final class PassKindLog {
    var kinds: [PassKind?] = []
}
