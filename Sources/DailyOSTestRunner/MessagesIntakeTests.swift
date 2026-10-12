import DailyOSCore
import Foundation

private func message(
    id: String, chatId: Int? = nil, isFromMe: Bool = true, text: String = "call the dentist", createdAt: Date = Date()
) -> ChatMessage {
    ChatMessage(id: id, chatId: chatId ?? abs(id.hashValue % 1000), isFromMe: isFromMe, text: text, createdAt: createdAt)
}

@MainActor
private func makeIntake(
    messages: [ChatMessage] = [], confirmedGoneRefs: Set<String> = [], availability: SourceAvailability = .available,
    extractorResponses: [String: String] = [:]
) -> (intake: MessagesIntake, store: SQLiteSignalStore, source: FakeMessagesSource, extractor: FakeIntentExtractor) {
    let source = FakeMessagesSource(messages: messages, confirmedGoneRefs: confirmedGoneRefs, availability: availability)
    let store = makeTestSignalStore()
    let extractor = FakeIntentExtractor(responses: extractorResponses)
    let intake = MessagesIntake(
        messagesSource: source, signalStore: store, contactsResolver: FakeContactsResolver(),
        bundlePath: "/nonexistent", extractor: extractor
    )
    return (intake, store, source, extractor)
}

func registerMessagesIntakeTests(_ runner: TestRunner) {
    runner.suite("MessagesIntake: backfill runs once (ticket 08)") { r in
        r.run("the first refresh backfills and marks the flag; a second refresh does not re-run it") {
            let (intake, store, _, _) = await MainActor.run {
                makeIntake(messages: [message(id: "m1", text: "call the dentist")], extractorResponses: ["call the dentist": "Call the dentist"])
            }
            try await MainActor.run { try expect(!store.isBackfillComplete()) }

            let recorder = ProgressRecorder()
            let firstResult = await intake.refresh(now: Date()) { completed, total in recorder.record(completed, total) }
            try await MainActor.run {
                try expect(store.isBackfillComplete(), "the flag should be set once the pass finishes")
                guard case .refreshed(let signals) = firstResult else { throw TestFailure(message: "expected .refreshed") }
                try expect(signals.map(\.label) == ["Call the dentist"])
                try expect(!recorder.reported.isEmpty, "the one-time backfill should report progress")
            }

            let recorderAfter = ProgressRecorder()
            _ = await intake.refresh(now: Date()) { completed, total in recorderAfter.record(completed, total) }
            try await MainActor.run {
                try expect(recorderAfter.reported.isEmpty, "an already-backfilled refresh should never report backfill progress")
            }
        }

        r.run("a refresh with no extractor still reads and reports .extractionUnavailable, never touching the flag") {
            let (intake, store, _, _) = await MainActor.run {
                (
                    MessagesIntake(
                        messagesSource: FakeMessagesSource(messages: [message(id: "m1")]),
                        signalStore: makeTestSignalStore(), contactsResolver: FakeContactsResolver(),
                        bundlePath: "/nonexistent"
                    ),
                    makeTestSignalStore(), FakeMessagesSource(), FakeIntentExtractor()
                )
            }
            let result = await intake.refresh(now: Date())
            try await MainActor.run {
                guard case .extractionUnavailable = result else { throw TestFailure(message: "expected .extractionUnavailable") }
                try expect(!store.isBackfillComplete(), "no model ran, so the flag must stay unset")
            }
        }
    }

    runner.suite("MessagesIntake: the Messages Gate degrades rather than blocks (ADR 0005)") { r in
        r.run("a denied Full Disk Access returns .unavailable without reading or writing anything") {
            let (intake, store, source, extractor) = await MainActor.run {
                makeIntake(messages: [message(id: "m1")], availability: .unavailable)
            }
            let result = await intake.refresh(now: Date())
            try await MainActor.run {
                guard case .unavailable = result else { throw TestFailure(message: "expected .unavailable") }
                try expect(extractor.calls.isEmpty, "a denied Gate should short-circuit before extraction ever runs")
                try expect(!store.isBackfillComplete(), "a denied Gate on the first run should never mark backfill complete")
                try expect(store.batchesWithSignals().isEmpty, "nothing should have been recorded")
            }
            _ = source
        }

        r.run("manual re-extraction also degrades to .unavailable on a denied Gate") {
            let (intake, _, _, _) = await MainActor.run {
                makeIntake(messages: [message(id: "m1")], availability: .unavailable)
            }
            let result = await intake.reExtract(now: Date(), lookbackDays: ReExtractionSettings.defaultLookbackDays)
            try await MainActor.run {
                guard case .unavailable = result else { throw TestFailure(message: "expected .unavailable") }
            }
        }
    }

    runner.suite("MessagesIntake: garbage collection only on confirmed gone (ticket 13)") { r in
        r.run("a confirmed-gone source ref is removed; an unknown one is left alone") {
            let (intake, store, _, _) = await MainActor.run {
                makeIntake(messages: [], confirmedGoneRefs: ["gone-1"])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("gone-1", signals: [
                    Signal(
                        id: "s1", source: .messages, sourceRef: "gone-1", label: "Old task", originalText: "old task",
                        createdAt: Date(), provenance: .inferred
                    ),
                ])
                try store.recordOneMessageBatch("unknown-1", signals: [
                    Signal(
                        id: "s2", source: .messages, sourceRef: "unknown-1", label: "Unclear task", originalText: "unclear",
                        createdAt: Date(), provenance: .inferred
                    ),
                ])
            }

            _ = await intake.refresh(now: Date())

            try await MainActor.run {
                let refs = Set(store.batchesWithSignals())
                try expect(!refs.contains("gone-1"), "a confirmed-gone ref should be garbage collected")
                try expect(refs.contains("unknown-1"), "an unresolved isGone should never be treated as gone")
            }
        }

        r.run("a source ref still present in the fetch is never a garbage collection candidate") {
            let stillHere = message(id: "still-here", text: "call the dentist")
            let (intake, store, _, _) = await MainActor.run {
                makeIntake(messages: [stillHere], confirmedGoneRefs: ["still-here"], extractorResponses: ["call the dentist": "Call the dentist"])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("still-here", signals: [
                    Signal(
                        id: "s1", source: .messages, sourceRef: "still-here", label: "Call the dentist",
                        originalText: "call the dentist", createdAt: Date(), provenance: .inferred
                    ),
                ])
            }

            _ = await intake.refresh(now: Date())

            try await MainActor.run {
                try expect(
                    store.batchesWithSignals().contains("still-here"),
                    "a ref present in the fetch must never be garbage collected regardless of isGone"
                )
            }
        }
    }

    runner.suite("MessagesIntake: the extraction window bounds both automatic passes and manual re-extraction") { r in
        r.run("a message older than the lookback window is never reached by the extractor") {
            let old = message(id: "old", text: "call the dentist", createdAt: Date().addingTimeInterval(-30 * 86400))
            let recent = message(id: "recent", text: "buy milk", createdAt: Date())
            let (intake, store, _, extractor) = await MainActor.run {
                makeIntake(
                    messages: [old, recent],
                    extractorResponses: ["call the dentist": "Call the dentist", "buy milk": "Buy milk"]
                )
            }

            let result = await intake.refresh(now: Date())

            try await MainActor.run {
                guard case .refreshed(let signals) = result else { throw TestFailure(message: "expected .refreshed") }
                try expect(signals.map(\.label) == ["Buy milk"], "only the message inside the window should produce a Signal")
                try expect(!extractor.calls.contains("call the dentist"), "the old message should never reach the extractor")
                try expect(!store.isProcessed(sourceRef: "old"), "a message outside the window is never marked Processed either")
            }
        }

        r.run("manual re-extraction only reaches a candidate within its own configured lookback") {
            // Re-extraction now has its own window (ReExtractionSettings),
            // separate from automatic intake's extractionLookbackDays —
            // no longer genuinely unbounded the way ticket 12 originally
            // shipped it.
            let old = message(id: "old", text: "call the dentist", createdAt: Date().addingTimeInterval(-30 * 86400))
            let (intake, store, _, extractor) = await MainActor.run {
                makeIntake(messages: [old], extractorResponses: ["call the dentist": "Call the dentist"])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("old", signals: [])
            }

            _ = await intake.reExtract(now: Date(), lookbackDays: ReExtractionSettings.defaultLookbackDays)

            try await MainActor.run {
                try expect(!extractor.calls.contains("call the dentist"), "a candidate outside the configured window should never reach the extractor")
                try expect(store.openSignals().isEmpty)
            }
        }

        r.run("manual re-extraction reaches a candidate within its configured lookback") {
            // -60s, not -3600s: the default lookback itself is now one
            // hour (ReExtractionSettings.defaultLookbackDays), so a
            // fixture placed exactly at the old boundary would sit right
            // on the new one instead — flaky by a few microseconds of
            // test execution time between the two `Date()` calls, not a
            // real behavior question. Comfortably inside either default.
            let recent = message(id: "recent", text: "call the dentist", createdAt: Date().addingTimeInterval(-60))
            let (intake, store, _, extractor) = await MainActor.run {
                makeIntake(messages: [recent], extractorResponses: ["call the dentist": "Call the dentist"])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("recent", signals: [])
            }

            _ = await intake.reExtract(now: Date(), lookbackDays: ReExtractionSettings.defaultLookbackDays)

            try await MainActor.run {
                try expect(extractor.calls.contains { $0.hasSuffix("call the dentist") }, "a candidate within the configured window should reach the extractor")
                try expect(store.openSignals().map(\.label) == ["Call the dentist"])
            }
        }

        r.run("a wider configured lookback reaches a candidate an old default would have excluded") {
            let old = message(id: "old", text: "call the dentist", createdAt: Date().addingTimeInterval(-10 * 86400))
            let (intake, store, _, extractor) = await MainActor.run {
                makeIntake(messages: [old], extractorResponses: ["call the dentist": "Call the dentist"])
            }
            try await MainActor.run {
                try store.recordOneMessageBatch("old", signals: [])
            }

            _ = await intake.reExtract(now: Date(), lookbackDays: 30)

            try await MainActor.run {
                try expect(extractor.calls.contains { $0.hasSuffix("call the dentist") }, "a wider configured window should reach an older candidate")
                try expect(store.openSignals().map(\.label) == ["Call the dentist"])
            }
        }
    }
}
