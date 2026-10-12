import DailyOSCore
import Foundation

/// `chatId` defaults to a value derived from `id` rather than a shared
/// constant, so two messages built with different ids in the same test
/// land in different Chats by default and never accidentally become each
/// other's `recentContext` — a test that wants that has to ask for it
/// explicitly by passing the same `chatId` to both.
private func message(
    id: String = "m1", chatId: Int? = nil, isFromMe: Bool = true, text: String = "just chatting", createdAt: Date = Date(),
    senderAddress: String? = nil, chatIdentifier: String? = nil
) -> ChatMessage {
    ChatMessage(
        id: id, chatId: chatId ?? abs(id.hashValue % 1000), isFromMe: isFromMe, text: text, createdAt: createdAt,
        senderAddress: senderAddress, chatIdentifier: chatIdentifier
    )
}

func registerExtractionTests(_ runner: TestRunner) {
    runner.suite("Messages Intake refresh") { r in
        r.run("a message the model finds nothing in produces no Signal but is marked Processed") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["just chatting": "NONE"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "just chatting")], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(store.isProcessed(sourceRef: "m1"))
        }

        r.run("a message the model finds work in produces one inferred Signal") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "call the dentist")], store: store, extractor: extractor)
            try expect(signals.count == 1)
            let signal = try require(signals.first)
            try expect(signal.label == "Call the dentist")
            try expect(signal.originalText == "You: call the dentist", "a message outside the Self-thread keeps its speaker")
            try expect(signal.source == .messages)
            try expect(signal.sourceRef == "m1")
            try expect(signal.provenance == .inferred)
            try expect(signal.lowConfidence == false)
        }

        r.run("a message yielding several candidates sets lowConfidence on the whole batch") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["long pasted block": "Buy milk\nCall the dentist"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "long pasted block")], store: store, extractor: extractor)
            try expect(signals.count == 2)
            try expect(signals.allSatisfy(\.lowConfidence))
        }

        r.run("a message the heuristic rejects never reaches the extractor") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["ok": "Something the model would have said"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "ok")], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty, "the heuristic must short-circuit before any model call")
            try expect(store.isProcessed(sourceRef: "m1"))
        }

        r.run("a Processed message is never re-checked on a later run") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", text: "call the dentist")
            let firstRun = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let secondRun = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(firstRun.count == 1)
            try expect(secondRun.count == 1, "openSignals still returns it — the point is the message isn't recorded twice")
            try expect(extractor.calls.count == 1, "the model must only be called once per message, ever")
        }

        r.run("a Signal's identity is minted once and stable across runs") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", text: "call the dentist")
            let firstRun = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let secondRun = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let firstId = try require(firstRun.first?.id)
            let secondId = try require(secondRun.first?.id)
            try expect(firstId == secondId)
        }

        r.run("open Signals from several already-processed messages all come back together") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: [
                "call the dentist": "Call the dentist",
                "buy milk": "Buy milk",
            ])
            let messages = [
                message(id: "m1", text: "call the dentist"),
                message(id: "m2", text: "buy milk"),
            ]
            let signals = await refreshThroughIntake(from: messages, store: store, extractor: extractor)
            try expect(Set(signals.map(\.label)) == Set(["Call the dentist", "Buy milk"]))
        }

        r.run("a batch mixing an already-processed message with a new one only extracts from the new one") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["buy milk": "Buy milk"])
            try store.recordOneMessageBatch("m1", signals: [])
            let messages = [message(id: "m1", text: "call the dentist"), message(id: "m2", text: "buy milk")]
            let signals = await refreshThroughIntake(from: messages, store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Buy milk"])
            try expect(extractor.calls == ["[latest messages]\nYou: buy milk"], "the already-processed message must never reach the model again")
        }
    }

    runner.suite("Messages Intake backfill") { r in
        r.run("every message commits to the store, including ones that produced nothing") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist", "just chatting": "NONE"])
            let messages = [message(id: "m1", text: "call the dentist"), message(id: "m2", text: "just chatting")]
            await backfillThroughIntake(messages: messages, store: store, extractor: extractor)
            try expect(store.isProcessed(sourceRef: "m1"))
            try expect(store.isProcessed(sourceRef: "m2"))
            try expect(store.openSignals().count == 1)
        }

        r.run("resuming a backfill skips already-processed messages") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist", "buy milk": "Buy milk"])
            let messages = [message(id: "m1", text: "call the dentist"), message(id: "m2", text: "buy milk")]
            // The app quit after the backfill had done m1 but before it
            // finished: m1 is Processed with its Signal, the flag is unset.
            let done = Signal(
                id: "s1", source: .messages, sourceRef: "m1", label: "Call the dentist", originalText: "call the dentist",
                createdAt: Date(), provenance: .inferred
            )
            try store.recordOneMessageBatch("m1", signals: [done])
            try expect(!store.isBackfillComplete())
            await backfillThroughIntake(messages: messages, store: store, extractor: extractor)
            try expect(!extractor.calls.contains { $0.contains("call the dentist") }, "m1 never reaches the model again")
            try expect(extractor.calls.contains { $0.contains("buy milk") }, "the backfill picks up where it stopped")
            try expect(store.openSignals().count == 2, "a resumed run must not mint duplicate Signals for already-processed messages")
            try expect(store.isBackfillComplete())
        }

        r.run("onProgress reports the running count against the total, once per message, in order") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor()
            let messages = [message(id: "m1"), message(id: "m2"), message(id: "m3")]
            let recorder = ProgressRecorder()
            await backfillThroughIntake(messages: messages, store: store, extractor: extractor, onProgress: recorder.record)
            // Intake reports 0 of 3 first, so the progress screen shows
            // before the first model call returns.
            try expect(recorder.reported.map(\.completed) == [0, 1, 2, 3])
            try expect(recorder.reported.map(\.total) == [3, 3, 3, 3])
        }

        r.run("a resumed run reports progress for already-processed messages too, not just new ones") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor()
            let messages = [message(id: "m1", text: "already done"), message(id: "m2", text: "still pending")]
            try store.recordOneMessageBatch("m1", signals: [])
            let recorder = ProgressRecorder()
            await backfillThroughIntake(messages: messages, store: store, extractor: extractor, onProgress: recorder.record)
            try expect(recorder.reported.map(\.completed) == [0, 1, 2])
        }
    }

    runner.suite("Messages Intake re-extraction") { r in
        r.run("a message with no open or checked-off Signal is re-checked and gains a new Signal if the model now finds work in it") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            try store.recordOneMessageBatch("m1", signals: [])
            await reExtractThroughIntake(messages: [message(id: "m1", text: "call the dentist")], store: store, extractor: extractor)
            try expect(store.openSignals().map(\.label) == ["Call the dentist"])
        }

        r.run("an item with an open Signal is left untouched") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["something else": "Something else"])
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Existing", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            await reExtractThroughIntake(messages: [message(id: "m1", text: "something else")], store: store, extractor: extractor)
            try expect(store.openSignals().map(\.label) == ["Existing"])
        }

        r.run("an item with a checked-off Signal is left untouched") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["something else": "Something else"])
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Existing", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.checkOff(signalId: "s1")
            await reExtractThroughIntake(messages: [message(id: "m1", text: "something else")], store: store, extractor: extractor)
            try expect(store.openSignals().isEmpty)
        }

        r.run("a dismissed Signal survives a re-extraction pass completely unchanged") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["new text": "New label"])
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Old label", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.dismiss(signalId: "s1")
            await reExtractThroughIntake(messages: [message(id: "m1", text: "new text")], store: store, extractor: extractor)

            try expect(!store.openSignals().contains { $0.id == "s1" }, "s1 must stay dismissed")
            try expect(store.openSignals().map(\.label) == ["New label"], "the new Signal should be minted alongside, not in place of, the dismissed one")
        }

        r.run("a message that still finds no work stays a candidate, with no new Signal minted") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["just chatting": "NONE"])
            try store.recordOneMessageBatch("m1", signals: [])
            await reExtractThroughIntake(messages: [message(id: "m1", text: "just chatting")], store: store, extractor: extractor)
            try expect(store.openSignals().isEmpty)
            try expect(store.reExtractionCandidates() == ["m1"], "still nothing open or checked off, so it remains eligible for a later pass")
        }

        r.run("an unprocessed message is never a candidate") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["brand new": "Brand new"])
            await reExtractThroughIntake(messages: [message(id: "m1", text: "brand new")], store: store, extractor: extractor)
            try expect(store.openSignals().isEmpty)
        }

        r.run("a candidate whose message isn't in the supplied messages is skipped, not crashed on") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor()
            try store.recordOneMessageBatch("m1", signals: [])
            await reExtractThroughIntake(messages: [], store: store, extractor: extractor)
            try expect(store.openSignals().isEmpty)
        }

        r.run("onProgress reports the running count against the candidate total only") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor()
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m2", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m2", label: "Live", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.recordOneMessageBatch("m3", signals: [])
            let messages = [message(id: "m1"), message(id: "m2"), message(id: "m3")]
            let recorder = ProgressRecorder()
            await reExtractThroughIntake(messages: messages, store: store, extractor: extractor, onProgress: recorder.record)
            try expect(recorder.reported.map(\.total) == [2, 2], "m2 has an open Signal and isn't a candidate, so the total should exclude it")
        }

        r.run("a message that gained an open Signal from one pass is not revisited by a later pass") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            try store.recordOneMessageBatch("m1", signals: [])
            let messages = [message(id: "m1", text: "call the dentist")]
            await reExtractThroughIntake(messages: messages, store: store, extractor: extractor)
            try expect(store.openSignals().count == 1)
            await reExtractThroughIntake(messages: messages, store: store, extractor: extractor)
            try expect(store.openSignals().count == 1, "m1 now has an open Signal from the first pass, so a later pass must not revisit it")
        }

        r.run("dismissing a re-extracted Signal makes the item eligible again, and the next pass adds alongside both prior Signals") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["second guess text": "second guess", "third guess text": "third guess"])
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "First guess", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.dismiss(signalId: "s1")
            await reExtractThroughIntake(messages: [message(id: "m1", text: "second guess text")], store: store, extractor: extractor)

            let secondSignal = try require(store.openSignals().first { $0.label == "second guess" })
            try store.dismiss(signalId: secondSignal.id)

            await reExtractThroughIntake(messages: [message(id: "m1", text: "third guess text")], store: store, extractor: extractor)

            try expect(store.openSignals().map(\.label) == ["third guess"])
        }
    }

    runner.suite("SignalStore backfill flag") { r in
        r.run("a fresh store has not completed the backfill") {
            let store = makeTestSignalStore()
            try expect(store.isBackfillComplete() == false)
        }
        r.run("marking the backfill complete is reflected back") {
            let store = makeTestSignalStore()
            try store.markBackfillComplete()
            try expect(store.isBackfillComplete())
        }
    }

    runner.suite("Messages Intake refresh: ticket 02 Chat-level gating") { r in
        r.run("a code-pattern message never reaches the model, marks its Chat Automated, and is Processed with no Signal") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["482910 is your verification code": "Something the model would have said"])
            let msg = message(id: "m1", chatId: 42, text: "482910 is your verification code")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty, "a code pattern must never reach the model")
            try expect(store.isProcessed(sourceRef: "m1"))
            try expect(store.isAutomated(chatId: 42))
        }

        r.run("once a Chat is Automated, a later ordinary message from it is skipped without reaching the model") {
            let store = makeTestSignalStore()
            try store.markAutomated(chatId: 42)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty)
            try expect(store.isProcessed(sourceRef: "m1"))
        }

        r.run("marking one Chat Automated never affects another Chat") {
            let store = makeTestSignalStore()
            try store.markAutomated(chatId: 42)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 7, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Call the dentist"])
        }

        r.run("within one batch, an ordinary message never reaches the model even if it's newer than the batch's own code-pattern message") {
            let store = makeTestSignalStore()
            let now = Date()
            // ChatDBMessagesSource fetches newest-first, so the array
            // itself is ordered exactly this way: the ordinary message
            // (newer) comes before the code-pattern one (older) here.
            // Without the whole-batch pre-pass, a per-message-only check
            // would reach and extract the ordinary message before ever
            // discovering, later in the loop, that its Chat is Automated.
            let ordinary = message(id: "m2", chatId: 42, text: "call the dentist", createdAt: now)
            let code = message(id: "m1", chatId: 42, text: "482910 is your verification code", createdAt: now - 60)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Something the model would have said"])
            let signals = await refreshThroughIntake(from: [ordinary, code], store: store, extractor: extractor)
            try expect(signals.isEmpty, "the whole Chat must be recognized as Automated before either message is evaluated")
            try expect(extractor.calls.isEmpty, "neither message should ever reach the model")
            try expect(store.isAutomated(chatId: 42))
        }

        r.run("a confidentiality-trigger message never reaches the model and is withheld, but its Chat is not marked Automated") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["don't tell anyone, but call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, text: "don't tell anyone, but call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty)
            try expect(store.isProcessed(sourceRef: "m1"))
            try expect(store.isAutomated(chatId: 42) == false, "confidentiality withholds the message, not the whole Chat")
        }

        r.run("a later ordinary message in the same Chat as an earlier confidentiality trigger is still read normally, and the trigger never leaks in as its context") {
            let store = makeTestSignalStore()
            let now = Date()
            let secret = message(id: "m1", chatId: 42, text: "don't tell anyone", createdAt: now - 60)
            let ordinary = message(id: "m2", chatId: 42, text: "call the dentist", createdAt: now)
            // A withheld message is also ineligible as someone else's
            // context (ExtractionContext.swift), so the confidential line
            // never reaches the model at all here — the extractor is
            // keyed on the bare target text, not a context-bearing prompt.
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            try store.recordOneMessageBatch("m1", signals: [])
            let signals = await refreshThroughIntake(from: [secret, ordinary], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Call the dentist"])
        }

        r.run("a received message can become a Signal, same as a sent one") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can you grab milk": "Grab milk"])
            let msg = message(id: "m1", isFromMe: false, text: "can you grab milk")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Grab milk"])
            try expect(signals.first?.provenance == .inferred)
        }

        r.run("the model sees prior same-chat context, not just the target message in isolation") {
            let store = makeTestSignalStore()
            let now = Date()
            let earlier = message(id: "m1", chatId: 42, isFromMe: false, text: "can you grab milk", createdAt: now - 60)
            let later = message(id: "m2", chatId: 42, isFromMe: true, text: "also grab bread", createdAt: now)
            let expectedPrompt = "[context]\nThem: can you grab milk\n\n[latest messages]\nYou: also grab bread"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab bread"])
            try store.recordOneMessageBatch("m1", signals: [])
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Grab bread"], "the extractor must have been called with the context-bearing prompt, not the bare target text")
        }

        r.run("a message in a group Chat is read the same as any other Chat, with several participants' prior lines as context") {
            let store = makeTestSignalStore()
            let now = Date()
            let fromAlex = message(id: "m1", chatId: 99, isFromMe: false, text: "can someone grab snacks", createdAt: now - 120)
            let fromMe = message(id: "m2", chatId: 99, isFromMe: true, text: "sure what kind", createdAt: now - 60)
            let fromJo = message(id: "m3", chatId: 99, isFromMe: false, text: "also grab napkins", createdAt: now)
            let expectedPrompt = """
            [context]
            Them: can someone grab snacks
            You: sure what kind

            [latest messages]
            Them: also grab napkins
            """
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab napkins"])
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m2", signals: [])
            let signals = await refreshThroughIntake(from: [fromAlex, fromMe, fromJo], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Grab napkins"], "a group Chat message needs no special handling beyond ordinary same-chat context")
        }

        r.run("a Signal produced before either Chat-level trigger arrives is left untouched by both") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let existing = message(id: "m1", chatId: 42, text: "call the dentist")
            _ = await refreshThroughIntake(from: [existing], store: store, extractor: extractor)
            try expect(store.openSignals().map(\.label) == ["Call the dentist"])

            // Now the same Chat produces a code-pattern message, in a
            // later, separate batch — matching how a real poll only ever
            // sees new messages, not the whole history again.
            let code = message(id: "m2", chatId: 42, text: "482910 is your verification code")
            _ = await refreshThroughIntake(from: [existing, code], store: store, extractor: extractor)
            try expect(store.openSignals().map(\.label) == ["Call the dentist"], "the earlier Signal must survive the Chat going Automated afterward")

            // And separately, a confidentiality trigger in a different
            // Chat that already holds an existing Signal.
            let otherStore = makeTestSignalStore()
            let otherExisting = message(id: "e1", chatId: 7, text: "call the dentist")
            _ = await refreshThroughIntake(from: [otherExisting], store: otherStore, extractor: extractor)
            let secretLater = message(id: "s1", chatId: 7, text: "don't tell anyone")
            _ = await refreshThroughIntake(from: [otherExisting, secretLater], store: otherStore, extractor: extractor)
            try expect(otherStore.openSignals().map(\.label) == ["Call the dentist"], "the earlier Signal must survive a later confidentiality trigger in the same Chat too")
        }
    }

    runner.suite("Messages Intake refresh: Mute Thread (ADR 0032)") { r in
        r.run("a message in a muted chat produces no Signal and writes no History row") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            try store.setMuted(true, chatId: 42)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, historyStore: historyStore)
            try expect(signals.isEmpty)
            try expect(extractor.calls.isEmpty, "a muted chat's messages must never reach the model")
            try expect(store.isProcessed(sourceRef: "m1"))
            try expect(historyStore.allRows().isEmpty, "no model call means nothing to audit")
        }

        r.run("muting one chat never affects extraction in another") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 42)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 7, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Call the dentist"])
        }

        r.run("unmuting a chat lets its later messages reach the model again") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 42)
            try store.setMuted(false, chatId: 42)
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Call the dentist"])
        }
    }

    runner.suite("Messages Intake refresh: ADR 0031 Correction loop") { r in
        r.run("a chat's own Correction is folded into the composed prompt sent to the model") {
            let store = makeTestSignalStore()
            let correctionStore = FakeCorrectionStore()
            try correctionStore.record(Correction(chatId: 42, inputText: "past mistake", correctedOutput: "NONE", correctionType: .falsePositive))
            let expectedPrompt = "[corrections]\nMessage: \"past mistake\"\nOutput: NONE\n\n[latest messages]\nYou: call the dentist"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, isFromMe: true, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, correctionStore: correctionStore)
            try expect(signals.map(\.label) == ["Call the dentist"], "the extractor must have seen the Correction, not just the bare message")
        }

        r.run("a chat with none of its own Corrections backfills from another chat's, via the capped global fallback") {
            let store = makeTestSignalStore()
            let correctionStore = FakeCorrectionStore()
            try correctionStore.record(Correction(chatId: 42, inputText: "past mistake", correctedOutput: "NONE", correctionType: .falsePositive))
            let expectedPrompt = "[corrections]\nMessage: \"past mistake\"\nOutput: NONE\n\n[latest messages]\nYou: call the dentist"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Call the dentist"])
            let msg = message(id: "m1", chatId: 7, isFromMe: true, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, correctionStore: correctionStore)
            try expect(signals.map(\.label) == ["Call the dentist"], "chat 7 has none of its own, so chat 42's Correction should backfill in via the capped global fallback (selectCorrections' own tests cover the cap itself)")
        }

        r.run("with no correctionStore supplied, extraction proceeds exactly as before") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", isFromMe: true, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Call the dentist"])
        }

        r.run("under token pressure, the correction count shrinks before any context message is dropped") {
            let store = makeTestSignalStore()
            let correctionStore = FakeCorrectionStore()
            let now = Date()
            // Three corrections plus one context message would together
            // exceed a tiny budget — the shrink loop must drop corrections
            // (least-recent-first) before ever touching `context`.
            try correctionStore.record(Correction(chatId: 42, inputText: "correction one two three four", correctedOutput: "NONE", correctionType: .falsePositive, createdAt: now - 30))
            try correctionStore.record(Correction(chatId: 42, inputText: "correction five six seven eight", correctedOutput: "NONE", correctionType: .falsePositive, createdAt: now - 20))
            try correctionStore.record(Correction(chatId: 42, inputText: "correction nine ten eleven twelve", correctedOutput: "NONE", correctionType: .falsePositive, createdAt: now - 10))
            let earlier = message(id: "m1", chatId: 42, isFromMe: false, text: "can you grab milk please today", createdAt: now - 60)
            let later = message(id: "m2", chatId: 42, isFromMe: true, text: "also grab bread", createdAt: now)
            // A budget generous enough for the context-bearing target alone,
            // but not for any of the three corrections on top of it.
            let bareContextPrompt = "[context]\nThem: can you grab milk please today\n\n[latest messages]\nYou: also grab bread"
            let tightBudget = FakeIntentExtractor(responses: [:]).estimatedTokenCount(for: bareContextPrompt) + 2
            let extractor = FakeIntentExtractor(responses: [bareContextPrompt: "Grab bread"], maxPromptTokens: tightBudget)
            try store.recordOneMessageBatch("m1", signals: [])
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor, correctionStore: correctionStore)
            try expect(signals.map(\.label) == ["Grab bread"], "context must survive even though every correction had to be dropped to fit")
            // `earlier` is itself processed in this same batch first (with
            // no context of its own) and makes its own call — this asserts
            // only on `later`'s call, the one actually under test.
            try expect(extractor.calls.last == bareContextPrompt, "the final call must carry zero corrections once none fit, never a truncated/malformed prompt")
        }
    }

    runner.suite("Messages Intake refresh: ticket 01 due-date extraction") { r in
        r.run("a clear temporal cue produces a Signal carrying the right due date") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist by friday": "Call the dentist\nDUE_TEXT: \"tomorrow\""])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "call the dentist by friday")], store: store, extractor: extractor)
            let signal = try require(signals.first)
            let dueAt = try require(signal.dueAt)
            try expect(Calendar(identifier: .gregorian).isDate(dueAt, inSameDayAs: expectedDate(daysFromToday: 1)))
        }

        r.run("an ambiguous or unresolvable cue produces no date, never a guess") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist soon": "Call the dentist\nDUE_TEXT: \"sometime soon\""])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "call the dentist soon")], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.dueAt == nil)
        }

        r.run("a message with no temporal cue at all produces dueAt == nil, unchanged") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "call the dentist")], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.dueAt == nil)
        }

        r.run("approving the resulting suggestion writes the extracted due date through, unedited") {
            // Exercises the same field `ReminderSignalMapping`/`AppModel.approve`
            // already carry from a Signal to a `ReminderDraft` — no new review
            // step, per the spec.
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["renew passport by next friday": "Renew passport\nDUE_TEXT: \"Friday\""])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "renew passport by next friday")], store: store, extractor: extractor)
            let signal = try require(signals.first)
            let draft = ReminderDraft(title: signal.label, dueAt: signal.dueAt, priority: signal.priority)
            try expect(draft.dueAt == signal.dueAt)
        }
    }

    runner.suite("Messages Intake refresh: ticket 02 Deep Linking chat identifier") { r in
        r.run("a one-to-one message's chatIdentifier flows through onto the minted Signal") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", text: "call the dentist", chatIdentifier: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.chatIdentifier == "+15551234567")
        }

        r.run("a group-chat message (chatIdentifier already nil) mints a Signal correctly flagged as non-targetable") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can someone grab snacks": "Grab snacks"])
            let msg = message(id: "m1", text: "can someone grab snacks", chatIdentifier: nil)
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.chatIdentifier == nil)
        }

        r.run("a message the user sent still carries its Chat's chatIdentifier — this is per-Chat, not per-sender") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let msg = message(id: "m1", isFromMe: true, text: "call the dentist", chatIdentifier: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.chatIdentifier == "+15551234567")
        }
    }

    runner.suite("Messages Intake refresh: tickets 02/03 sender attribution") { r in
        r.run("a received message's sender resolves to the matching contact's name") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can you grab milk": "Grab milk"])
            let resolver = FakeContactsResolver(names: ["+15551234567": "Alex"])
            let msg = message(id: "m1", isFromMe: false, text: "can you grab milk", senderAddress: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, contactsResolver: resolver)
            let signal = try require(signals.first)
            try expect(signal.sender == "Alex")
        }

        r.run("an address with no Contacts match falls back to the raw address, never blank") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can you grab milk": "Grab milk"])
            let resolver = FakeContactsResolver(names: [:])
            let msg = message(id: "m1", isFromMe: false, text: "can you grab milk", senderAddress: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, contactsResolver: resolver)
            let signal = try require(signals.first)
            try expect(signal.sender == "+15551234567")
        }

        r.run("a denied or revoked Contacts Gate degrades to the raw address rather than blocking") {
            // A resolver backing a denied Gate resolves nothing at all, the
            // same shape a no-match address takes — both fall back to the
            // raw address via the identical code path in `makeSignals`.
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can you grab milk": "Grab milk"])
            let deniedGateResolver = FakeContactsResolver(names: [:])
            let msg = message(id: "m1", isFromMe: false, text: "can you grab milk", senderAddress: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, contactsResolver: deniedGateResolver)
            let signal = try require(signals.first)
            try expect(signal.sender == "+15551234567")
            try expect(!signals.isEmpty, "a denied Gate degrades the Signal, it never blocks extraction")
        }

        r.run("a message the user sent has no sender to resolve, and the resolver is never even called") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let resolver = FakeContactsResolver(names: ["+15551234567": "Alex"])
            let msg = message(id: "m1", isFromMe: true, text: "call the dentist")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, contactsResolver: resolver)
            let signal = try require(signals.first)
            try expect(signal.sender == nil)
            try expect(resolver.calls.isEmpty)
        }

        r.run("the default contactsResolver leaves sender nil, matching a denied Gate") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["can you grab milk": "Grab milk"])
            let msg = message(id: "m1", isFromMe: false, text: "can you grab milk", senderAddress: "+15551234567")
            let signals = await refreshThroughIntake(from: [msg], store: store, extractor: extractor)
            let signal = try require(signals.first)
            try expect(signal.sender == "+15551234567", "with no resolver supplied, the raw address is still shown, never blank")
        }

        r.run("two different senders within the same group Chat resolve to two different names, independently") {
            let store = makeTestSignalStore()
            let now = Date()
            let fromAlex = message(id: "m1", chatId: 99, isFromMe: false, text: "can someone grab snacks", createdAt: now - 60, senderAddress: "+15551111111")
            let fromJo = message(id: "m2", chatId: 99, isFromMe: false, text: "also grab napkins", createdAt: now, senderAddress: "+15552222222")
            let resolver = FakeContactsResolver(names: ["+15551111111": "Alex", "+15552222222": "Jo"])
            let expectedPromptForNapkins = """
            [open suggestions]
            1. Grab snacks

            [context]
            Participant A: can someone grab snacks

            [latest messages]
            Participant B: also grab napkins
            """
            let extractor = FakeIntentExtractor(responses: [
                "[latest messages]\nParticipant A: can someone grab snacks": "Grab snacks",
                expectedPromptForNapkins: "Grab napkins",
            ])
            _ = await refreshThroughIntake(from: [fromAlex], store: store, extractor: extractor, contactsResolver: resolver)
            let signals = await refreshThroughIntake(from: [fromAlex, fromJo], store: store, extractor: extractor, contactsResolver: resolver)
            let snacksSignal = try require(signals.first { $0.label == "Grab snacks" })
            let napkinsSignal = try require(signals.first { $0.label == "Grab napkins" })
            try expect(snacksSignal.sender == "Alex")
            try expect(napkinsSignal.sender == "Jo")
        }
    }

    runner.suite("Messages Intake refresh: ADR 0033 Participant Labels") { r in
        r.run("a message addressed to a different participant in a group Chat is not mistaken for a task addressed to the model's own user") {
            let store = makeTestSignalStore()
            let now = Date()
            let fromAlex = message(
                id: "m1", chatId: 99, isFromMe: false, text: "can someone grab snacks", createdAt: now - 60,
                senderAddress: "+15551111111"
            )
            let fromJo = message(
                id: "m2", chatId: 99, isFromMe: false, text: "Alex, can you send the slides tonight", createdAt: now,
                senderAddress: "+15552222222"
            )
            let expectedPrompt = """
            [context]
            Participant A: can someone grab snacks

            [latest messages]
            Participant B: Alex, can you send the slides tonight
            """
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "NONE"])
            try store.recordOneMessageBatch("m1", signals: [])
            let signals = await refreshThroughIntake(from: [fromAlex, fromJo], store: store, extractor: extractor)
            try expect(signals.isEmpty, "a request addressed to a different participant must not become a Signal")
        }

        r.run("the same real sender keeps the same label across two separate extraction calls sharing a labelStore") {
            let store = makeTestSignalStore()
            let labelStore = InMemoryParticipantLabelStore()
            let now = Date()
            let fromAlex1 = message(id: "m1", chatId: 99, isFromMe: false, text: "can someone grab snacks", createdAt: now - 120, senderAddress: "+15551111111")
            let fromJo = message(id: "m2", chatId: 99, isFromMe: false, text: "sure", createdAt: now - 60, senderAddress: "+15552222222")
            let fromAlex2 = message(id: "m3", chatId: 99, isFromMe: false, text: "also grab bread", createdAt: now, senderAddress: "+15551111111")
            let expectedPrompt = """
            [context]
            Participant A: can someone grab snacks
            Participant B: sure

            [latest messages]
            Participant A: also grab bread
            """
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab bread"])
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m2", signals: [])
            let signals = await refreshThroughIntake(
                from: [fromAlex1, fromJo, fromAlex2], store: store, extractor: extractor, participantLabelStore: labelStore
            )
            try expect(signals.map(\.label) == ["Grab bread"], "Alex must be labeled Participant A again, not reassigned, once already seen in this Chat")
        }

        r.run("a message with no senderAddress falls back to the literal Them, never crashing on a missing identity") {
            let store = makeTestSignalStore()
            let now = Date()
            let earlier = message(id: "m1", chatId: 42, isFromMe: false, text: "can you grab milk", createdAt: now - 60, senderAddress: nil)
            let later = message(id: "m2", chatId: 42, isFromMe: true, text: "also grab bread", createdAt: now)
            let expectedPrompt = "[context]\nThem: can you grab milk\n\n[latest messages]\nYou: also grab bread"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab bread"])
            try store.recordOneMessageBatch("m1", signals: [])
            let signals = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor)
            try expect(signals.map(\.label) == ["Grab bread"])
        }
    }

    runner.suite("Messages Intake refresh: History (ADR 0029)") { r in
        r.run("a message the model finds work in is recorded, with the raw output and model identity") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"], modelDisplayName: "Model A")
            _ = await refreshThroughIntake(
                from: [message(id: "m1", text: "call the dentist")], store: store, extractor: extractor, historyStore: historyStore
            )
            let entries = historyStore.allRows()
            try expect(entries.count == 1)
            let entry = try require(entries.first)
            try expect(entry.sourceRawText == "call the dentist")
            try expect(entry.rawOutput == "Call the dentist")
            try expect(entry.modelUsed == "Model A")
            try expect(entry.signalCount == 1)
        }

        r.run("a message the model finds nothing in is still recorded, with signalCount zero") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["just chatting": "NONE"])
            _ = await refreshThroughIntake(
                from: [message(id: "m1", text: "just chatting")], store: store, extractor: extractor, historyStore: historyStore
            )
            let entries = historyStore.allRows()
            try expect(entries.count == 1)
            try expect(entries.first?.signalCount == 0)
        }

        r.run("a message the heuristic rejects never reaches the model, and gets no History entry at all") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["ok": "Something the model would have said"])
            _ = await refreshThroughIntake(from: [message(id: "m1", text: "ok")], store: store, extractor: extractor, historyStore: historyStore)
            try expect(extractor.calls.isEmpty)
            try expect(historyStore.allRows().isEmpty, "no model call means nothing to audit")
        }

        r.run("a code-pattern message never reaches the model, and gets no History entry") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["482910 is your verification code": "Something the model would have said"])
            let msg = message(id: "m1", chatId: 42, text: "482910 is your verification code")
            _ = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, historyStore: historyStore)
            try expect(extractor.calls.isEmpty)
            try expect(historyStore.allRows().isEmpty)
        }

        r.run("a confidentiality-trigger message never reaches the model, and gets no History entry") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let extractor = FakeIntentExtractor(responses: ["don't tell anyone, but call the dentist": "Call the dentist"])
            let msg = message(id: "m1", chatId: 42, text: "don't tell anyone, but call the dentist")
            _ = await refreshThroughIntake(from: [msg], store: store, extractor: extractor, historyStore: historyStore)
            try expect(extractor.calls.isEmpty)
            try expect(historyStore.allRows().isEmpty)
        }

        r.run("sourceRawText is the message's own text, not the context-bearing prompt the model was actually shown") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let now = Date()
            let earlier = message(id: "m1", chatId: 42, isFromMe: false, text: "can you grab milk", createdAt: now - 60)
            let later = message(id: "m2", chatId: 42, isFromMe: true, text: "also grab bread", createdAt: now)
            let expectedPrompt = "[context]\nThem: can you grab milk\n\n[latest messages]\nYou: also grab bread"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab bread"])
            try store.recordOneMessageBatch("m1", signals: [])
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor, historyStore: historyStore)
            // `earlier` is itself processed in this same batch (with no
            // context of its own) and gets its own zero-Signal History
            // entry; only the one that produced a Signal matters here.
            let entries = historyStore.allRows().filter { $0.signalCount > 0 }
            try expect(entries.map(\.sourceRawText) == ["also grab bread"], "History shows the raw iMessage text, matching what a Re-run replays — not the internal context-bearing prompt")
        }

        r.run("a recorded entry carries the message's chatId and the exact composed prompt, not just its own text") {
            let store = makeTestSignalStore()
            let historyStore = makeTestHistoryStore()
            let now = Date()
            let earlier = message(id: "m1", chatId: 42, isFromMe: false, text: "can you grab milk", createdAt: now - 60)
            let later = message(id: "m2", chatId: 42, isFromMe: true, text: "also grab bread", createdAt: now)
            let expectedPrompt = "[context]\nThem: can you grab milk\n\n[latest messages]\nYou: also grab bread"
            let extractor = FakeIntentExtractor(responses: [expectedPrompt: "Grab bread"])
            try store.recordOneMessageBatch("m1", signals: [])
            _ = await refreshThroughIntake(from: [earlier, later], store: store, extractor: extractor, historyStore: historyStore)
            let entry = try require(historyStore.allRows().first { $0.sourceRawText == "also grab bread" })
            try expect(entry.chatId == 42)
            try expect(entry.renderedContext == expectedPrompt, "renderedContext must be the full context-bearing prompt the model actually saw")
        }

        r.run("with no historyStore supplied, extraction proceeds exactly as before — History is opt-in") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor(responses: ["call the dentist": "Call the dentist"])
            let signals = await refreshThroughIntake(from: [message(id: "m1", text: "call the dentist")], store: store, extractor: extractor)
            try expect(signals.count == 1)
        }
    }
}
