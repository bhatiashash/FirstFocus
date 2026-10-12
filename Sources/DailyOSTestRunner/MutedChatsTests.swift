import DailyOSApp
import DailyOSCore
import Foundation

/// The muted-chats-list spec (.scratch/muted-chats-list): Advanced lists
/// every Muted Chat by the name History gives it, with Unmute.

@MainActor
private func mutedChats(_ app: HistoryApp) -> MutedChatsViewModel {
    MutedChatsViewModel(actions: app.actions, historyStore: app.history)
}

/// Each listed Chat as "<chat id> <name>", in list order.
@MainActor
private func listed(_ viewModel: MutedChatsViewModel) -> [String] {
    viewModel.chats.map { "\($0.chatId) \($0.name)" }
}

/// An extraction row for a Batch in `chatId`, named the way intake names
/// it: a group Chat by `chatTitle`, a one-to-one Chat by `sender`.
private func namedEntry(
    ref: String, chatId: Int, sender: String? = nil, chatTitle: String? = nil, at: Date = Date()
) -> HistoryEntry {
    HistoryEntry(
        timestamp: at, sourceRawText: "text \(ref)", rawOutput: "NONE", modelUsed: "Qwen", signalCount: 0,
        chatId: chatId, sourceRef: ref, sender: sender, chatTitle: chatTitle
    )
}

func registerMutedChatsTests(_ runner: TestRunner) {
    runner.suite("Advanced lists every Muted Chat (muted-chats-list 01)") { r in
        r.run("nothing Muted lists nothing") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(extractionEntry(ref: "m1", chatId: 1))
                try expect(mutedChats(app).chats.isEmpty)
            }
        }

        r.run("Chats muted from History are listed by History's names for them, alphabetically") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(namedEntry(ref: "g1", chatId: 7, sender: "Zoe", chatTitle: "book club"))
                try app.history.record(namedEntry(ref: "d1", chatId: 3, sender: "Alice"))
                try app.history.record(namedEntry(ref: "x1", chatId: 5, sender: "Carl"))
                for batch in app.history.batches(since: .distantPast) where batch.chatId != 5 {
                    app.actions.toggleMute(batch)
                }
                try expect(listed(mutedChats(app)) == [
                    "3 Alice",
                    "7 book club",
                ], "got \(listed(mutedChats(app)))")
            }
        }

        r.run("a Muted Chat whose rows are all past History's window is still named") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
                try app.history.record(namedEntry(ref: "o1", chatId: 9, sender: "Old Friend", at: monthAgo))
                try app.signals.setMuted(true, chatId: 9)
                try expect(listed(mutedChats(app)) == ["9 Old Friend"])
            }
        }

        r.run("a Muted Chat with no History rows is listed as Chat not recorded") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 4)
                try expect(listed(mutedChats(app)) == ["4 Chat not recorded"])
            }
        }

        r.run("an Automated Chat that isn't Muted is not listed") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(namedEntry(ref: "a1", chatId: 2, sender: "Bank"))
                try app.signals.markAutomated(chatId: 2)
                try expect(mutedChats(app).chats.isEmpty)
            }
        }

        r.run("a Chat muted from History after the list was read shows up on refresh") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(namedEntry(ref: "d1", chatId: 3, sender: "Alice"))
                let viewModel = mutedChats(app)
                try expect(viewModel.chats.isEmpty)
                app.actions.toggleMute(try require(app.history.batches(since: .distantPast).first))
                viewModel.refresh()
                try expect(listed(viewModel) == ["3 Alice"])
            }
        }
    }

    runner.suite("A Muted Chat's latest message shows on hover") { r in
        r.run("the tooltip is the newest message of the Chat's latest Batch, not a context line") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let sent = Date()
                try app.history.record(HistoryEntry(
                    timestamp: sent, sourceRawText: "Participant A: see you at 6\nParticipant A: bring the charger",
                    rawOutput: "NONE", modelUsed: "Qwen", signalCount: 0, chatId: 3, sourceRef: "d2",
                    sender: "+13134443934",
                    transcript: [
                        HistoryTranscriptLine(speaker: "+13134443934", isFromMe: false, text: "earlier", sentAt: sent, isContext: true),
                        HistoryTranscriptLine(speaker: "+13134443934", isFromMe: false, text: "see you at 6", sentAt: sent),
                        HistoryTranscriptLine(speaker: "+13134443934", isFromMe: false, text: "bring the charger", sentAt: sent),
                    ]
                ))
                try app.signals.setMuted(true, chatId: 3)
                try expect(mutedChats(app).chats.first?.lastMessage == "bring the charger", "got \(String(describing: mutedChats(app).chats.first))")
            }
        }

        r.run("a group Chat's tooltip names who wrote it") {
            try await MainActor.run {
                let app = makeHistoryApp()
                let sent = Date()
                try app.history.record(HistoryEntry(
                    timestamp: sent, sourceRawText: "Participant A: who has the keys", rawOutput: "NONE", modelUsed: "Qwen",
                    signalCount: 0, chatId: 7, sourceRef: "g1", sender: "Zoe",
                    transcript: [HistoryTranscriptLine(speaker: "Zoe", isFromMe: false, text: "who has the keys", sentAt: sent)],
                    chatTitle: "book club"
                ))
                try app.signals.setMuted(true, chatId: 7)
                try expect(mutedChats(app).chats.first?.lastMessage == "Zoe: who has the keys")
            }
        }

        r.run("a Batch recorded without a transcript falls back to its source text's last line") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(namedEntry(ref: "o1", chatId: 9, sender: "Old Friend"))
                try app.signals.setMuted(true, chatId: 9)
                try expect(mutedChats(app).chats.first?.lastMessage == "text o1")
            }
        }

        r.run("a Muted Chat with no History rows says No recent messages") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 4)
                try expect(mutedChats(app).chats.first?.lastMessage == "No recent messages")
            }
        }
    }

    runner.suite("Unmute from Advanced (muted-chats-list 02)") { r in
        r.run("Unmute clears the Chat's Muted state and removes it from the list") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.history.record(namedEntry(ref: "d1", chatId: 3, sender: "Alice"))
                try app.history.record(namedEntry(ref: "b1", chatId: 8, sender: "Bob"))
                try app.signals.setMuted(true, chatId: 3)
                try app.signals.setMuted(true, chatId: 8)
                let viewModel = mutedChats(app)
                viewModel.unmute(chatId: 3)
                try expect(!app.signals.isMuted(chatId: 3))
                try expect(app.signals.isMuted(chatId: 8))
                try expect(listed(viewModel) == ["8 Bob"])
            }
        }

        r.run("History stops pinning and badging a Chat unmuted from Advanced") {
            try await MainActor.run {
                let app = makeHistoryApp()
                try app.signals.setMuted(true, chatId: 9)
                let (history, _) = try makeDashboard([
                    extractionEntry(ref: "old", at: hoursAgo(20 * 24), chatId: 9),
                    extractionEntry(ref: "recent", at: hoursAgo(1), chatId: 1),
                ], app: app)
                try expect(history.sections.map(\.title) == ["Today", "Earlier"])
                let pinned = try require(history.sections.last?.batches.first)
                try expect(history.badges(for: pinned).contains { $0.text == "Muted" })
                mutedChats(app).unmute(chatId: 9)
                try expect(history.sections.map(\.title) == ["Today"], "got \(history.sections.map(\.title))")
                try expect(!history.badges(for: pinned).contains { $0.text == "Muted" })
            }
        }

        r.run("after Unmute the Chat's next Batch reaches the model; Batches Processed while Muted stay skipped") {
            let signals = makeTestSignalStore()
            let history = makeTestHistoryStore()
            let app = await MainActor.run { makeHistoryApp(signals: signals, history: history) }
            try signals.setMuted(true, chatId: 42)
            let extractor = FakeIntentExtractor(defaultResponse: "Call the dentist")
            let fixture = IntakeFixture(historyStore: history)
            let start = Date().addingTimeInterval(-3600)
            let whileMuted = ChatMessage(
                id: "m1", chatId: 42, isFromMe: false, text: "can you call the dentist", createdAt: start,
                senderAddress: "+15551230000"
            )
            _ = await refreshThroughIntake(from: [whileMuted], store: signals, extractor: extractor, fixture: fixture)
            try expect(extractor.calls.isEmpty)
            await MainActor.run { mutedChats(app).unmute(chatId: 42) }
            let afterUnmute = ChatMessage(
                id: "m2", chatId: 42, isFromMe: false, text: "also book the vet", createdAt: start.addingTimeInterval(batchCap * 4),
                senderAddress: "+15551230000"
            )
            _ = await refreshThroughIntake(
                from: [whileMuted, afterUnmute], store: signals, extractor: extractor, fixture: fixture
            )
            try expect(extractor.calls.count == 1, "only the new Batch is judged, got \(extractor.calls)")
            try expect(extractor.calls.first?.contains("also book the vet") == true)
            try expect(history.batches(since: .distantPast).compactMap(\.sourceRef) == ["m2"])
        }
    }
}
