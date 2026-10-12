import DailyOSCore
import Foundation

func registerSelfThreadAutomatedTests(_ runner: TestRunner) {
    runner.suite("The self-thread is never Automated (ADR 0007 amendment)") { r in
        r.run("a code-like note in the self-thread doesn't mark it Automated, and still reaches the model") {
            let store = makeTestSignalStore()
            let extractor = FakeIntentExtractor()
            let note = ChatMessage(
                id: "m1", chatId: 78, isFromMe: true, text: "Your verification code is 482913", createdAt: Date(),
                isSelfThread: true
            )
            _ = await refreshThroughIntake(from: [note], store: store, extractor: extractor)
            try expect(!store.isAutomated(chatId: 78))
            try expect(extractor.calls.count == 1)
        }

        r.run("the same message in another Chat still marks that Chat Automated") {
            let store = makeTestSignalStore()
            let code = ChatMessage(id: "m1", chatId: 5, isFromMe: false, text: "Your verification code is 482913", createdAt: Date())
            _ = await refreshThroughIntake(from: [code], store: store, extractor: FakeIntentExtractor())
            try expect(store.isAutomated(chatId: 5))
        }

        r.run("a self-chat already marked Automated is cleared on the next pass and its notes are read again") {
            let store = makeTestSignalStore()
            try store.markAutomated(chatId: 78)
            try store.markAutomated(chatId: 5)
            let source = FakeMessagesSource(messages: [
                ChatMessage(id: "m1", chatId: 78, isFromMe: true, text: "book the flights", createdAt: Date(), isSelfThread: true),
            ])
            source.selfChatIdSet = [78]
            let extractor = FakeIntentExtractor(responses: ["book the flights": "Book the flights"])
            let intake = await MainActor.run {
                MessagesIntake(
                    messagesSource: source, signalStore: store, contactsResolver: FakeContactsResolver(),
                    bundlePath: "/nonexistent", extractor: extractor
                )
            }
            _ = await intake.refresh(now: Date())
            try expect(!store.isAutomated(chatId: 78), "a self-chat must not stay Automated")
            try expect(store.isAutomated(chatId: 5), "any other Automated Chat stays Automated")
            try expect(source.lastExcludedChatIds == [5], "the self-chat must no longer be excluded from the read")
            try expect(extractor.calls == ["book the flights"])
        }
    }
}
