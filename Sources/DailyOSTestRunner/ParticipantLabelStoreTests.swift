import DailyOSCore
import Foundation

func registerParticipantLabelStoreTests(_ runner: TestRunner) {
    runner.suite("ParticipantLabelStore (InMemoryParticipantLabelStore)") { r in
        r.run("the same (chatId, senderAddress) returns the same label across repeated calls") {
            let store = InMemoryParticipantLabelStore()
            let first = store.label(chatId: 1, senderAddress: "+15551111111")
            let second = store.label(chatId: 1, senderAddress: "+15551111111")
            try expect(first == second)
        }

        r.run("a new senderAddress within an already-labeled chat gets the next label in sequence") {
            let store = InMemoryParticipantLabelStore()
            let first = store.label(chatId: 1, senderAddress: "+15551111111")
            let second = store.label(chatId: 1, senderAddress: "+15552222222")
            try expect(first == "Participant A")
            try expect(second == "Participant B")
        }

        r.run("the same senderAddress in a different chatId gets its own independent label") {
            let store = InMemoryParticipantLabelStore()
            _ = store.label(chatId: 1, senderAddress: "+15551111111")
            _ = store.label(chatId: 1, senderAddress: "+15552222222")
            let inOtherChat = store.label(chatId: 2, senderAddress: "+15552222222")
            try expect(inOtherChat == "Participant A", "a fresh chat starts its own sequence, unaffected by another chat's assignments")
        }
    }

    runner.suite("ParticipantLabelStore (SQLiteParticipantLabelStore, real persistence)") { r in
        r.run("a label survives a store reopen against the same file") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-participantlabelstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let firstOpen = SQLiteParticipantLabelStore(path: path)
            let assigned = firstOpen.label(chatId: 1, senderAddress: "+15551111111")

            let secondOpen = SQLiteParticipantLabelStore(path: path)
            let reread = secondOpen.label(chatId: 1, senderAddress: "+15551111111")
            try expect(assigned == reread)
        }

        r.run("sequential assignment and per-chat independence hold through real SQL, not just the in-memory store") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("dailyos-participantlabelstore-test-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = SQLiteParticipantLabelStore(path: path)
            try expect(store.label(chatId: 1, senderAddress: "+15551111111") == "Participant A")
            try expect(store.label(chatId: 1, senderAddress: "+15552222222") == "Participant B")
            try expect(store.label(chatId: 2, senderAddress: "+15552222222") == "Participant A")
        }
    }
}
