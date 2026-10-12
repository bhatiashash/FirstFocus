import DailyOSCore
import Foundation

private func messagesSignal(id: String = "s1", sourceRef: String = "m1") -> Signal {
    Signal(
        id: id,
        source: .messages,
        sourceRef: sourceRef,
        label: "Test",
        originalText: "test",
        createdAt: Date(),
        provenance: .inferred
    )
}

func registerSignalStoreTests(_ runner: TestRunner) {
    runner.suite("SignalStore dismiss") { r in
        r.run("dismissing a Signal removes it from openSignals") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.dismiss(signalId: "s1")
            try expect(store.openSignals().isEmpty)
        }

        r.run("dismissal is a distinct state from checked off, not a variant of it") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1")])
            try store.recordOneMessageBatch("m2", signals: [messagesSignal(id: "s2", sourceRef: "m2")])
            try store.dismiss(signalId: "s1")
            try store.checkOff(signalId: "s2")
            try expect(store.openSignals().isEmpty)
            try expect(store.reExtractionCandidates() == ["m1"], "a dismissed Signal leaves its Batch open to re-extraction; a checked-off one doesn't")
        }

        r.run("dismissing an unknown id throws rather than silently succeeding") {
            let store = makeTestSignalStore()
            var threw = false
            do {
                try store.dismiss(signalId: "missing")
            } catch {
                threw = true
            }
            try expect(threw)
        }
    }

    runner.suite("SignalStore approve") { r in
        r.run("approving a Signal removes it from openSignals and keeps its Batch out of re-extraction") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.approve(signalId: "s1", reminderId: "reminder-1")
            try expect(store.openSignals().isEmpty)
            try expect(store.reExtractionCandidates().isEmpty, "an approved Signal is live work")
        }

        r.run("approving an unknown id throws rather than silently succeeding") {
            let store = makeTestSignalStore()
            var threw = false
            do {
                try store.approve(signalId: "missing", reminderId: "reminder-1")
            } catch {
                threw = true
            }
            try expect(threw)
        }

        r.run("an approved item no longer counts as a re-extraction candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try store.approve(signalId: "s1", reminderId: "reminder-1")
            try expect(store.reExtractionCandidates().isEmpty, "m1 has live work now (an approved reminder), so it must not be revisited")
        }
    }

    runner.suite("SignalStore approve (SQLiteSignalStore, real persistence)") { r in
        r.run("an approved Signal stays out of openSignals across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try firstOpen.approve(signalId: "s1", reminderId: "reminder-1")
            try expect(firstOpen.openSignals().isEmpty)
            try expect(firstOpen.reExtractionCandidates().isEmpty, "an approved item has live work and must not be revisited")

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.openSignals().isEmpty, "approval should persist across a fresh connection to the same file")
        }
    }

    runner.suite("SignalStore dismiss (SQLiteSignalStore, real persistence)") { r in
        r.run("a dismissed Signal stays dismissed across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try firstOpen.dismiss(signalId: "s1")
            try expect(firstOpen.openSignals().isEmpty, "dismissed Signal should not be open in the same store instance")

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.openSignals().isEmpty, "dismissal should persist across a fresh connection to the same file")
        }
    }

    runner.suite("SignalStore rejects a second Batch holding a Processed message") { r in
        r.run("recording an already-Processed message again throws") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1")])
            var threw = false
            do {
                try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s2")])
            } catch {
                threw = true
            }
            try expect(threw, "recording the same message twice should throw rather than mint a duplicate Signal")
            try expect(store.openSignals().map(\.id) == ["s1"], "only the first call's Signal should exist")
        }

        r.run("SQLiteSignalStore: recording an already-Processed message again throws and mints nothing") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)

            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1")])
            var threw = false
            do {
                try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s2")])
            } catch {
                threw = true
            }
            try expect(threw)
            try expect(store.openSignals().map(\.id) == ["s1"], "the second call's Signal should never have been committed")
        }
    }

    runner.suite("SignalStore reExtractionCandidates") { r in
        r.run("a Processed item with no Signal at all is a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [])
            try expect(store.reExtractionCandidates() == ["m1"])
        }

        r.run("a Processed item whose only Signal is dismissed is a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try store.dismiss(signalId: "s1")
            try expect(store.reExtractionCandidates() == ["m1"])
        }

        r.run("a Processed item with an open Signal is not a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try expect(store.reExtractionCandidates().isEmpty)
        }

        r.run("a Processed item with a checked-off Signal is not a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try store.checkOff(signalId: "s1")
            try expect(store.reExtractionCandidates().isEmpty)
        }

        r.run("an item with one dismissed Signal and one open Signal is not a candidate") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [
                messagesSignal(id: "s1", sourceRef: "m1"),
                messagesSignal(id: "s2", sourceRef: "m1"),
            ])
            try store.dismiss(signalId: "s1")
            try expect(store.reExtractionCandidates().isEmpty, "s2 is still open, so m1 has live work and must not be revisited")
        }

        r.run("an unprocessed item is never a candidate") {
            let store = makeTestSignalStore()
            try expect(store.reExtractionCandidates().isEmpty)
        }

        r.run("SQLiteSignalStore: candidates come back sorted") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = SQLiteSignalStore(path: path)
            try store.recordOneMessageBatch("m2", signals: [])
            try store.recordOneMessageBatch("m1", signals: [])
            try store.recordOneMessageBatch("m3", signals: [messagesSignal(id: "s1", sourceRef: "m3")])
            try expect(
                store.reExtractionCandidates() == ["m1", "m2"],
                "m3 has an open Signal and must not be revisited; the other two come back sorted"
            )
        }
    }

    runner.suite("SignalStore recordReExtractedSignals") { r in
        r.run("adds a new Signal without touching an existing dismissed one") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try store.dismiss(signalId: "s1")
            try store.recordReExtractedSignals(sourceRef: "m1", signals: [messagesSignal(id: "s2", sourceRef: "m1")])

            try expect(store.openSignals().map(\.id) == ["s2"])
        }

        r.run("SQLiteSignalStore: an added Signal and an untouched dismissed one both persist across a reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try firstOpen.dismiss(signalId: "s1")
            try expect(firstOpen.reExtractionCandidates() == ["m1"])
            try firstOpen.recordReExtractedSignals(sourceRef: "m1", signals: [messagesSignal(id: "s2", sourceRef: "m1")])

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.openSignals().map(\.id) == ["s2"])
            try expect(secondOpen.reExtractionCandidates().isEmpty, "m1 now has an open Signal, so it's no longer a candidate")
        }
    }

    runner.suite("SignalStore sender persistence (tickets 02/03)") { r in
        r.run("SQLiteSignalStore: a resolved sender persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let signal = Signal(
                id: "s1", source: .messages, sourceRef: "m1", label: "Grab milk", originalText: "can you grab milk",
                createdAt: Date(), provenance: .inferred, sender: "Alex"
            )
            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [signal])
            try expect(firstOpen.openSignals().first?.sender == "Alex")

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.openSignals().first?.sender == "Alex", "sender should persist across a fresh connection to the same file")
        }

        r.run("SQLiteSignalStore: a Signal with no sender reads back nil, not an empty string") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = SQLiteSignalStore(path: path)
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try expect(store.openSignals().first?.sender == nil)
        }
    }

    runner.suite("SignalStore chatIdentifier persistence (ticket 02)") { r in
        r.run("SQLiteSignalStore: a resolved chatIdentifier persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let signal = Signal(
                id: "s1", source: .messages, sourceRef: "m1", label: "Grab milk", originalText: "can you grab milk",
                createdAt: Date(), provenance: .inferred, chatIdentifier: "+15551234567"
            )
            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [signal])
            try expect(firstOpen.openSignals().first?.chatIdentifier == "+15551234567")

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(
                secondOpen.openSignals().first?.chatIdentifier == "+15551234567",
                "chatIdentifier should persist across a fresh connection to the same file"
            )
        }

        r.run("SQLiteSignalStore: a group-chat Signal with no chatIdentifier reads back nil, not an empty string") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = SQLiteSignalStore(path: path)
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try expect(store.openSignals().first?.chatIdentifier == nil)
        }
    }

    runner.suite("SignalStore focusOrder (ADR 0011)") { r in
        r.run("a fresh signal has no manual order") {
            let store = makeTestSignalStore()
            try expect(store.focusOrder(signalId: "s1") == nil)
        }

        r.run("setFocusOrders is reflected back per id") {
            let store = makeTestSignalStore()
            try store.setFocusOrders(["s1": 0, "s2": 1])
            try expect(store.focusOrder(signalId: "s1") == 0)
            try expect(store.focusOrder(signalId: "s2") == 1)
        }

        r.run("setFocusOrders only touches the ids it's given, leaving others untouched") {
            let store = makeTestSignalStore()
            try store.setFocusOrders(["s1": 0])
            try store.setFocusOrders(["s2": 1])
            try expect(store.focusOrder(signalId: "s1") == 0, "a later call for a different id must not clear an earlier one")
        }

        r.run("setFocusOrders overwrites a previous position for the same id") {
            let store = makeTestSignalStore()
            try store.setFocusOrders(["s1": 0])
            try store.setFocusOrders(["s1": 3])
            try expect(store.focusOrder(signalId: "s1") == 3)
        }

        r.run("SQLiteSignalStore: manual order persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.setFocusOrders(["s1": 2, "s2": 0])
            try expect(firstOpen.focusOrder(signalId: "s1") == 2)

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.focusOrder(signalId: "s1") == 2, "manual order should persist across a fresh connection to the same file")
            try expect(secondOpen.focusOrder(signalId: "s2") == 0)
        }

        r.run("SQLiteSignalStore: works for an id that's never a row in the signals table — the Reminders case") {
            // A Reminders Signal is never persisted in `signals` at all
            // (ReminderSignalMapping rebuilds it fresh every reload); this
            // is the one place it gets any durable local state.
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)
            try store.setFocusOrders(["reminder-42": 0])
            try expect(store.focusOrder(signalId: "reminder-42") == 0)
        }

        r.run("SQLiteSignalStore: setFocusOrders with an empty dictionary is a harmless no-op") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)
            try store.setFocusOrders([:])
            try expect(store.focusOrder(signalId: "anything") == nil)
        }
    }

    runner.suite("SignalStore promote (ticket 05)") { r in
        r.run("promoting a Signal sets its priority to high") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            let promoted = try require(store.openSignals().first { $0.id == "s1" })
            try expect(promoted.priority == .high)
        }

        r.run("promoting moves the Signal into Focus on the next rank") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            let promoted = try require(store.openSignals().first)
            try expect(tier(for: promoted, now: Date()) == .focus)
        }

        r.run("promoting an unknown id throws rather than silently succeeding") {
            let store = makeTestSignalStore()
            var threw = false
            do {
                try store.promote(signalId: "missing")
            } catch {
                threw = true
            }
            try expect(threw)
        }

        r.run("promoting never touches state — the Signal stays open") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            try expect(store.openSignals().map(\.id) == ["s1"])
        }

        r.run("SQLiteSignalStore: a promoted Signal's high priority persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try firstOpen.promote(signalId: "s1")
            try expect(firstOpen.openSignals().first?.priority == .high)

            let secondOpen = SQLiteSignalStore(path: path)
            let reopened = try require(secondOpen.openSignals().first)
            try expect(reopened.priority == .high, "promotion should persist across a fresh connection to the same file")
        }

        r.run("SQLiteSignalStore: promoting an unknown id throws") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)

            var threw = false
            do {
                try store.promote(signalId: "missing")
            } catch {
                threw = true
            }
            try expect(threw)
        }
    }

    runner.suite("SignalStore demote") { r in
        r.run("demoting a promoted Signal clears its priority back to none") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            try store.demote(signalId: "s1")
            let demoted = try require(store.openSignals().first { $0.id == "s1" })
            try expect(demoted.priority == .none)
        }

        r.run("demoting moves the Signal out of Focus on the next rank") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            try store.demote(signalId: "s1")
            let demoted = try require(store.openSignals().first)
            try expect(tier(for: demoted, now: Date()) == .later)
        }

        r.run("demoting an unknown id throws rather than silently succeeding") {
            let store = makeTestSignalStore()
            var threw = false
            do {
                try store.demote(signalId: "missing")
            } catch {
                threw = true
            }
            try expect(threw)
        }

        r.run("demoting never touches state — the Signal stays open") {
            let store = makeTestSignalStore()
            try store.recordOneMessageBatch("m1", signals: [messagesSignal()])
            try store.promote(signalId: "s1")
            try store.demote(signalId: "s1")
            try expect(store.openSignals().map(\.id) == ["s1"])
        }

        r.run("SQLiteSignalStore: a demoted Signal's cleared priority persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.recordOneMessageBatch("m1", signals: [messagesSignal(id: "s1", sourceRef: "m1")])
            try firstOpen.promote(signalId: "s1")
            try firstOpen.demote(signalId: "s1")
            let demoted = try require(firstOpen.openSignals().first)
            try expect(demoted.priority == .none)

            let secondOpen = SQLiteSignalStore(path: path)
            let reopened = try require(secondOpen.openSignals().first)
            try expect(reopened.priority == .none, "demotion should persist across a fresh connection to the same file")
        }

        r.run("SQLiteSignalStore: demoting an unknown id throws") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)

            var threw = false
            do {
                try store.demote(signalId: "missing")
            } catch {
                threw = true
            }
            try expect(threw)
        }
    }

    runner.suite("SignalStore snooze (ticket 04)") { r in
        r.run("a fresh signal has never been snoozed") {
            let store = makeTestSignalStore()
            try expect(store.snoozedUntil(signalId: "s1") == nil)
        }

        r.run("snoozing records the given timestamp") {
            let store = makeTestSignalStore()
            let until = Date(timeIntervalSince1970: 2_000_000)
            try store.snooze(signalId: "s1", until: until)
            try expect(store.snoozedUntil(signalId: "s1") == until)
        }

        r.run("snoozing again overwrites the previous timestamp") {
            let store = makeTestSignalStore()
            try store.snooze(signalId: "s1", until: Date(timeIntervalSince1970: 1_000_000))
            try store.snooze(signalId: "s1", until: Date(timeIntervalSince1970: 2_000_000))
            try expect(store.snoozedUntil(signalId: "s1") == Date(timeIntervalSince1970: 2_000_000))
        }

        r.run("SQLiteSignalStore: a snooze persists across a store reopen") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let until = Date(timeIntervalSince1970: 2_000_000)
            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.snooze(signalId: "s1", until: until)
            try expect(firstOpen.snoozedUntil(signalId: "s1") == until)

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.snoozedUntil(signalId: "s1") == until, "a snooze should persist across a fresh connection to the same file")
        }

        r.run("SQLiteSignalStore: works for an id that's never a row in the signals table — the Reminders case") {
            // A Reminders Signal is never persisted in `signals` at all, the
            // same reason focusOrder needs its own table — snooze applies
            // uniformly across sources, so it can't live in `signals` either.
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteSignalStore(path: path)
            let until = Date(timeIntervalSince1970: 2_000_000)
            try store.snooze(signalId: "reminder-42", until: until)
            try expect(store.snoozedUntil(signalId: "reminder-42") == until)
        }
    }

    runner.suite("SignalStore signing identity") { r in
        r.run("a fresh store has no stored signing identity") {
            let store = makeTestSignalStore()
            try expect(store.storedSigningIdentity() == nil)
        }
        r.run("a recorded identity is read back") {
            let store = makeTestSignalStore()
            try store.recordSigningIdentity("DailyOS Local Dev")
            try expect(store.storedSigningIdentity() == "DailyOS Local Dev")
        }
        r.run("recording again replaces the previous identity") {
            let store = makeTestSignalStore()
            try store.recordSigningIdentity("Old Identity")
            try store.recordSigningIdentity("New Identity")
            try expect(store.storedSigningIdentity() == "New Identity")
        }
    }

    runner.suite("SignalStore Muted (ADR 0032)") { r in
        r.run("a fresh chat is not muted") {
            let store = makeTestSignalStore()
            try expect(store.isMuted(chatId: 42) == false)
        }

        r.run("setting muted true is reflected back") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 42)
            try expect(store.isMuted(chatId: 42))
        }

        r.run("setting muted false reverses a prior mute — unlike Automated, this is a two-way toggle") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 42)
            try store.setMuted(false, chatId: 42)
            try expect(store.isMuted(chatId: 42) == false)
        }

        r.run("muting one chat never affects another") {
            let store = makeTestSignalStore()
            try store.setMuted(true, chatId: 42)
            try expect(store.isMuted(chatId: 7) == false)
        }

        r.run("Muted state survives a SQLiteSignalStore reopen against the same file") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteSignalStore(path: path)
            try firstOpen.setMuted(true, chatId: 42)

            let secondOpen = SQLiteSignalStore(path: path)
            try expect(secondOpen.isMuted(chatId: 42))
        }

        r.run("unmuting through SQLiteSignalStore persists across a reopen too") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-signalstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = SQLiteSignalStore(path: path)
            try store.setMuted(true, chatId: 42)
            try store.setMuted(false, chatId: 42)

            let reopened = SQLiteSignalStore(path: path)
            try expect(reopened.isMuted(chatId: 42) == false)
        }
    }
}
