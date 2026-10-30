import FirstFocusApp
import FirstFocusCore
import Foundation

/// Morning Brief ticket 02: the message built from the Ranked List.
private let calendar = Calendar.current
private let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
private let today = calendar.startOfDay(for: now)

private func signal(_ label: String, dueAt: Date? = nil) -> Signal {
    Signal(
        id: label, source: .reminders, sourceRef: label, label: label, originalText: label, createdAt: now,
        dueAt: dueAt, provenance: .stated
    )
}

func registerMorningBriefTests(_ runner: TestRunner) {
    runner.suite("Morning Brief: the message") { r in
        r.run("the top Focus Signal stands alone under the header, the rest follow a line each, then the Later count") {
            let list = RankedList(
                focus: [signal("Pay rent"), signal("Call the dentist"), signal("Send Q3 numbers")], later: [],
                suggested: [], laterCount: 12
            )
            let expected = """
                FirstFocus Morning Brief

                Pay rent
                Call the dentist
                Send Q3 numbers

                (12 in Later)
                """
            let text = composeMorningBrief(list, now: now)
            try expect(text == expected, "got\n\(text)")
        }

        r.run("only Signals due before today are marked overdue") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let list = RankedList(
                focus: [signal("Pay rent", dueAt: yesterday), signal("Call the dentist", dueAt: today)], later: [],
                suggested: [], laterCount: 0
            )
            let text = composeMorningBrief(list, now: now)
            try expect(text.contains("\nPay rent (overdue)\n"), "got\n\(text)")
            try expect(text.contains("\nCall the dentist\n"), "got\n\(text)")
        }

        r.run("with Focus empty it still goes out and says so") {
            let list = RankedList(focus: [], later: [], suggested: [], laterCount: 3)
            let expected = """
                FirstFocus Morning Brief

                Nothing in Focus.

                (3 in Later)
                """
            let text = composeMorningBrief(list, now: now)
            try expect(text == expected, "got\n\(text)")
        }

        r.run("Suggestions and Snoozed Signals are left out") {
            let list = RankedList(
                focus: [signal("Pay rent")], later: [], suggested: [signal("Maybe call Sam")],
                snoozed: [signal("Book flights")], laterCount: 0
            )
            let text = composeMorningBrief(list, now: now)
            try expect(!text.contains("Maybe call Sam") && !text.contains("Book flights"), "got\n\(text)")
        }

        r.run("a limit lists only the first Signals and says how many more are in Focus") {
            let list = RankedList(
                focus: ["A", "B", "C", "D", "E"].map { signal($0) }, later: [], suggested: [], laterCount: 2
            )
            var format = MorningBriefFormat.standard
            format.limit = 3
            let expected = """
                FirstFocus Morning Brief

                A
                B
                C
                +2 more in Focus

                (2 in Later)
                """
            let text = composeMorningBrief(list, now: now, format: format)
            try expect(text == expected, "got\n\(text)")
        }

        r.run("a limit above the Focus count adds no more line") {
            var format = MorningBriefFormat.standard
            format.limit = 5
            let list = RankedList(focus: [signal("A")], later: [], suggested: [], laterCount: 0)
            let text = composeMorningBrief(list, now: now, format: format)
            try expect(!text.contains("more in Focus"), "got\n\(text)")
        }

        r.run("a custom format numbers lines and rearranges the body, under the fixed header") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let list = RankedList(
                focus: [signal("Pay rent", dueAt: yesterday), signal("Call the dentist")], later: [], suggested: [],
                laterCount: 4
            )
            let format = MorningBriefFormat(
                body: "Later: {later}\n{top} <- start here\n{rest}", itemLine: "{n}. {label}{overdue}", limit: nil
            )
            let expected = """
                FirstFocus Morning Brief

                Later: 4
                1. Pay rent (overdue) <- start here
                2. Call the dentist
                """
            let text = composeMorningBrief(list, now: now, format: format)
            try expect(text == expected, "got\n\(text)")
        }

        r.run("text around {rest} repeats on every line it lists, and a line with nothing to list is dropped") {
            let format = MorningBriefFormat(body: "- {top}\n- {rest}", itemLine: "{label}", limit: nil)
            let list = RankedList(focus: [signal("A"), signal("B"), signal("C")], later: [], suggested: [])
            let text = composeMorningBrief(list, now: now, format: format)
            try expect(text == "\(morningBriefHeader)\n\n- A\n- B\n- C", "got\n\(text)")
            let single = composeMorningBrief(RankedList(focus: [signal("A")], later: [], suggested: []), now: now, format: format)
            try expect(single == "\(morningBriefHeader)\n\n- A", "got\n\(single)")
        }

        r.run("a Label containing a placeholder is printed as written") {
            let list = RankedList(focus: [signal("Fill in {later} field")], later: [], suggested: [], laterCount: 7)
            let text = composeMorningBrief(list, now: now)
            try expect(text.contains("\nFill in {later} field\n"), "got\n\(text)")
        }

        r.run("the header stays even when the body is cleared") {
            let format = MorningBriefFormat(body: "", itemLine: "", limit: nil)
            let text = composeMorningBrief(RankedList(focus: [signal("A")], later: [], suggested: []), now: now, format: format)
            try expect(text.hasPrefix(morningBriefHeader), "got\n\(text)")
        }

        r.run("the header carries the app's name, without brackets") {
            try expect(morningBriefHeader == "FirstFocus Morning Brief")
        }

        r.run("the Brief it composes is one Intake recognizes") {
            let text = composeMorningBrief(RankedList(focus: [], later: [], suggested: [], laterCount: 0), now: now)
            let sent = ChatMessage(id: "b1", chatId: 1, isFromMe: true, text: text, createdAt: now, isSelfThread: true)
            try expect(isMorningBrief(sent))
        }
    }

    runner.suite("Morning Brief: the Later count") { r in
        r.run("counts every open Later Signal past the Later cap, but no Snoozed one") {
            let tasks = (0..<30).map {
                ReminderTask(id: "r\($0)", title: "Later \($0)", dueAt: nil, priority: .none, createdAt: now)
            } + [ReminderTask(id: "f1", title: "Pay rent", dueAt: nil, priority: .high, createdAt: now)]
            let store = makeTestSignalStore()
            let board = await MainActor.run {
                SignalBoard(taskSource: FakeTaskSource(tasks: tasks), signalStore: store, snoozes: Snoozes(store: store))
            }
            await board.refreshReminders()
            try store.snooze(signalId: "r0", until: now.addingTimeInterval(86400))
            try await MainActor.run {
                let list = board.rankedList(now: now)
                try expect(list.later.count == maxRankedSignals - 1, "the window still caps Later")
                try expect(list.laterCount == 29, "got \(list.laterCount)")
                try expect(composeMorningBrief(list, now: now).hasSuffix("(29 in Later)"))
            }
        }
    }

    runner.suite("Morning Brief: built from the app's Ranked List") { r in
        r.run("Focus Signals follow an order you dragged") {
            let store = makeTestSignalStore()
            let tasks = ["Pay rent", "Call the dentist", "Send Q3 numbers"].enumerated().map {
                ReminderTask(id: "r\($0.offset)", title: $0.element, dueAt: nil, priority: .high, createdAt: now)
            }
            let board = await MainActor.run { SignalBoard(taskSource: FakeTaskSource(tasks: tasks), signalStore: store, snoozes: Snoozes(store: store)) }
            await board.refreshReminders()
            try store.setFocusOrders(["r2": 0, "r0": 1, "r1": 2])
            let text = await MainActor.run { composeMorningBrief(board.rankedList(now: now), now: now) }
            try expect(text.contains("\n\nSend Q3 numbers\nPay rent\nCall the dentist\n"), "got\n\(text)")
        }

        r.run("a Signal snoozed until 8:00 is in the Brief sent at 8:00, even before the list is derived again") {
            let clock = await MainActor.run { TestNow(now.addingTimeInterval(-60)) }
            let store = makeTestSignalStore()
            let model = await MainActor.run {
                AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [
                        ReminderTask(id: "r1", title: "Pay rent", dueAt: nil, priority: .high, createdAt: now),
                    ])
                    d.messagesSource = FakeMessagesSource(messages: [])
                    d.signalStore = store
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.dayChanges = FakeDayChangeObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: morningBriefDefaults())
                    d.reExtractionSettings = ReExtractionSettings(defaults: morningBriefDefaults())
                    d.loadModel = { _, _ in FakeIntentExtractor() }
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.now = { clock.date }
                    d.bundlePath = "/nonexistent"
                    d.snoozeWakeAlarm = FakeAlarm()
                })
            }
            try store.snooze(signalId: "r1", until: now)
            await model.reload()
            let text = await MainActor.run { () -> String in
                clock.date = now
                return model.morningBriefText()
            }
            try expect(text.contains("\nPay rent\n"), "got\n\(text)")
        }

        r.run("at launch the Brief waits for the stored list, so it never texts an empty one") {
            let store = makeTestSignalStore()
            try store.markBackfillComplete()
            let model = await MainActor.run {
                AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [
                        ReminderTask(id: "r1", title: "Pay rent", dueAt: nil, priority: .high, createdAt: now),
                    ])
                    d.messagesSource = FakeMessagesSource(messages: [])
                    d.signalStore = store
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.dayChanges = FakeDayChangeObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: morningBriefDefaults())
                    d.reExtractionSettings = ReExtractionSettings(defaults: morningBriefDefaults())
                    d.loadModel = { _, _ in FakeIntentExtractor() }
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.bundlePath = "/nonexistent"
                    d.snoozeWakeAlarm = FakeAlarm()
                })
            }
            let seen = await MainActor.run { () -> Box in
                let seen = Box()
                model.onStoredListReady = { seen.texts.append(model.morningBriefText()) }
                return seen
            }
            await model.start()
            let texts = await MainActor.run { seen.texts }
            try expect(texts.count == 1, "fires once")
            try expect(texts.first?.contains("\nPay rent\n") == true, "got \(texts)")
        }
    }

    runner.suite("Morning Brief: where it is sent") { r in
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        r.run("the Self-thread is the conversation named for one of your own addresses") {
            let address = selfThreadAddress(
                ownAddresses: ["+15550142"],
                chats: [("+15550001", later), ("+15550142", earlier)]
            )
            try expect(address == "+15550142", "got \(String(describing: address))")
        }

        r.run("with two Self-threads, the one you wrote in most recently wins") {
            let address = selfThreadAddress(
                ownAddresses: ["+15550142", "me@example.com"],
                chats: [("+15550142", earlier), ("me@example.com", later)]
            )
            try expect(address == "me@example.com", "got \(String(describing: address))")
        }

        r.run("no conversation with yourself means nowhere to send") {
            let address = selfThreadAddress(ownAddresses: ["+15550142"], chats: [("+15550001", later)])
            try expect(address == nil)
        }
    }
}

@MainActor
private final class Box {
    var texts: [String] = []
}
