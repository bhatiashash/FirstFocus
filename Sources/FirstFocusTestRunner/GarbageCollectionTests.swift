import FirstFocusCore
import Foundation

private func message(id: String = "m1", text: String = "call the dentist", createdAt: Date = Date()) -> ChatMessage {
    ChatMessage(id: id, chatId: 1, isFromMe: true, text: text, createdAt: createdAt)
}

private func signal(_ id: String, in batchId: String) -> Signal {
    Signal(id: id, source: .messages, sourceRef: batchId, label: "x", originalText: "x", createdAt: Date(), provenance: .inferred)
}

/// A store holding one Batch of `memberIds`, oldest first, that produced
/// one Signal.
private func storeWithSignal(inBatch memberIds: [String]) throws -> SQLiteSignalStore {
    let store = makeTestSignalStore()
    let messages = memberIds.enumerated().map { index, id in
        message(id: id, createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
    }
    try store.recordProcessedBatch(MessageBatch(messages: messages), signals: [signal("s1", in: memberIds.last!)])
    return store
}

func registerGarbageCollectionTests(_ runner: TestRunner) {
    runner.suite("Batch Ledger: vanished Batches") { r in
        r.run("a Batch confirmed gone is returned to remove") {
            let store = try storeWithSignal(inBatch: ["m1"])
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m1"])
            try expect(store.vanishedBatches(among: [], source: source) == ["m1"])
        }

        r.run("a Batch still in the fetch is never removed, even if isGone is never asked") {
            let store = try storeWithSignal(inBatch: ["m1"])
            let source = FakeMessagesSource(messages: [message(id: "m1")], confirmedGoneRefs: ["m1"])
            try expect(store.vanishedBatches(among: [message(id: "m1")], source: source).isEmpty)
        }

        r.run("an empty fetch alone removes nothing: isGone must still confirm it") {
            let store = try storeWithSignal(inBatch: ["m1"])
            let source = FakeMessagesSource(messages: [])
            try expect(store.vanishedBatches(among: [], source: source).isEmpty)
        }

        r.run("a transient read failure (isGone returns nil) removes nothing") {
            let store = try storeWithSignal(inBatch: ["m1"])
            let source = FakeMessagesSource(messages: [], unknownRefs: ["m1"])
            try expect(store.vanishedBatches(among: [], source: source).isEmpty)
        }

        r.run("a Processed Batch with no Signal is never a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m1"])
            try expect(store.vanishedBatches(among: [], source: source).isEmpty)
        }

        r.run("unsending a Batch's newest message leaves its Signals") {
            let store = try storeWithSignal(inBatch: ["m1", "m2"])
            let source = FakeMessagesSource(messages: [message(id: "m1")], confirmedGoneRefs: ["m2"])
            try expect(store.vanishedBatches(among: [message(id: "m1")], source: source).isEmpty)
        }

        r.run("unsending an older message in a Batch leaves its Signals") {
            let store = try storeWithSignal(inBatch: ["m1", "m2"])
            let source = FakeMessagesSource(messages: [message(id: "m2")], confirmedGoneRefs: ["m1"])
            try expect(store.vanishedBatches(among: [message(id: "m2")], source: source).isEmpty)
        }

        r.run("a Batch whose every message is gone is returned to remove") {
            let store = try storeWithSignal(inBatch: ["m1", "m2"])
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m1", "m2"])
            try expect(store.vanishedBatches(among: [], source: source) == ["m2"])
        }

        r.run("one message Messages can't confirm gone keeps the whole Batch") {
            let store = try storeWithSignal(inBatch: ["m1", "m2"])
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m2"], unknownRefs: ["m1"])
            try expect(store.vanishedBatches(among: [], source: source).isEmpty)
        }

        r.run("a message Processed before batching that is gone is returned, as a Batch of one") {
            let path = testStorePath()
            try seedPreBatchMessage("m1", signals: [signal("s1", in: "m1")], inStoreAt: path)
            let store = SQLiteSignalStore(path: path)
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m1"])
            try expect(store.vanishedBatches(among: [], source: source) == ["m1"])
        }

        r.run("a refresh removes a Batch once every message is gone, and never judges it again") {
            let store = try storeWithSignal(inBatch: ["m1", "m2"])
            try store.markBackfillComplete()
            try store.recordNonSelfMessagesCutoff(.distantPast)
            let other = message(id: "m9", text: "unrelated", createdAt: Date(timeIntervalSince1970: 100))
            let extractor = FakeIntentExtractor()
            let unsentOne = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: [message(id: "m1"), other], confirmedGoneRefs: ["m2"]),
                    signalStore: store, contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent", extractor: extractor
                )
            }
            _ = await unsentOne.refresh(now: Date(), priority: .userInitiated)
            try expect(store.openSignals().map(\.id) == ["s1"], "one unsent message leaves the Batch")

            let allGone = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: [other], confirmedGoneRefs: ["m1", "m2"]),
                    signalStore: store, contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent", extractor: extractor
                )
            }
            _ = await allGone.refresh(now: Date(), priority: .userInitiated)
            try expect(store.openSignals().isEmpty, "every message gone removes the Batch's Signals")

            let callsBefore = extractor.calls.count
            let back = await MainActor.run {
                MessagesIntake(
                    messagesSource: FakeMessagesSource(messages: [message(id: "m1"), message(id: "m2"), other]),
                    signalStore: store, contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent", extractor: extractor
                )
            }
            _ = await back.refresh(now: Date(), priority: .userInitiated)
            try expect(extractor.calls.count == callsBefore, "a vanished Batch stays Processed, so it is never judged again")
        }

        r.run("several Batches are each judged on their own") {
            let store = try storeWithSignal(inBatch: ["m1"])
            try store.recordOneMessageBatch("m2", signals: [signal("s2", in: "m2")])
            try store.recordOneMessageBatch("m3", signals: [signal("s3", in: "m3")])
            let source = FakeMessagesSource(messages: [], confirmedGoneRefs: ["m1", "m3"], unknownRefs: ["m2"])
            try expect(Set(store.vanishedBatches(among: [], source: source)) == ["m1", "m3"], "m2's inconclusive lookup keeps it")
        }
    }

    runner.suite("SignalStore garbage collection") { r in
        r.run("garbageCollectSignals removes every Signal from that Batch, in any state") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Open one", originalText: "x", createdAt: Date(), provenance: .inferred),
                Signal(id: "s2", source: .messages, sourceRef: "m1", label: "Dismissed one", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.dismiss(signalId: "s2")
            try store.garbageCollectSignals(ofBatch: "m1")
            try expect(store.batchesWithSignals().isEmpty, "both the open and the dismissed Signal against m1 should be gone")
        }

        r.run("garbageCollectSignals leaves other Batches untouched") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Gone", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.recordOneMessageBatch("m2", signals: [
                Signal(id: "s2", source: .messages, sourceRef: "m2", label: "Still here", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.garbageCollectSignals(ofBatch: "m1")
            try expect(store.batchesWithSignals() == ["m2"])
        }

        r.run("garbageCollectSignals leaves processed_messages alone — Processed stays permanent") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Gone", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.garbageCollectSignals(ofBatch: "m1")
            try expect(store.isProcessed(sourceRef: "m1"), "garbage collection removes Signals, never the Processed record")
        }

        r.run("batchesWithSignals excludes Batches Processed with no Signal") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m2", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m2", label: "x", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try expect(store.batchesWithSignals() == ["m2"])
        }

        r.run("an end-to-end pass removes a vanished item's Signals, keeps another's, and keeps Processed") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Vanished", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.recordOneMessageBatch("m2", signals: [
                Signal(id: "s2", source: .messages, sourceRef: "m2", label: "Still there", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])

            let source = FakeMessagesSource(messages: [message(id: "m2")], confirmedGoneRefs: ["m1"])
            for ref in store.vanishedBatches(among: [message(id: "m2")], source: source) {
                try store.garbageCollectSignals(ofBatch: ref)
            }

            try expect(store.openSignals().map(\.id) == ["s2"])
            try expect(store.isProcessed(sourceRef: "m1"), "m1's Processed record should survive its own garbage collection")
        }

        r.run("an inconclusive lookup on a missing item leaves its Signal in place") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Maybe gone", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])

            // m1 is missing from this fetch (an empty fetch, e.g. a
            // transient read problem), but the source can't confirm it's
            // actually gone — nothing should be removed.
            let source = FakeMessagesSource(messages: [], unknownRefs: ["m1"])
            for ref in store.vanishedBatches(among: [], source: source) {
                try store.garbageCollectSignals(ofBatch: ref)
            }

            try expect(store.openSignals().map(\.id) == ["s1"], "an inconclusive lookup must never remove real history")
        }

        r.run("SQLiteSignalStore: an end-to-end pass removes a vanished item's Signals, keeps another's, and keeps Processed") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("firstfocus-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)

            try store.recordOneMessageBatch("m1", signals: [
                Signal(id: "s1", source: .messages, sourceRef: "m1", label: "Vanished", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])
            try store.recordOneMessageBatch("m2", signals: [
                Signal(id: "s2", source: .messages, sourceRef: "m2", label: "Still there", originalText: "x", createdAt: Date(), provenance: .inferred),
            ])

            let source = FakeMessagesSource(messages: [message(id: "m2")], confirmedGoneRefs: ["m1"])
            for ref in store.vanishedBatches(among: [message(id: "m2")], source: source) {
                try store.garbageCollectSignals(ofBatch: ref)
            }

            try expect(store.openSignals().map(\.id) == ["s2"])
            try expect(store.isProcessed(sourceRef: "m1"), "m1's Processed record should survive its own garbage collection")
        }
    }
}
