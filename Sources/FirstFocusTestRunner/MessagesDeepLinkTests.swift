import FirstFocusCore
import Foundation

private func testSignal(source: Source, chatIdentifier: String? = nil) -> Signal {
    Signal(
        id: "s1", source: source, sourceRef: "m1", label: "Test", originalText: "test",
        createdAt: Date(), provenance: source == .messages ? .inferred : .stated, chatIdentifier: chatIdentifier
    )
}

func registerMessagesDeepLinkTests(_ runner: TestRunner) {
    runner.suite("messagesDeepLinkTarget: Deep Linking (ticket 03)") { r in
        r.run("a Reminders Signal resolves to .none — a row click stays a no-op") {
            let signal = testSignal(source: .reminders)
            try expect(messagesDeepLinkTarget(for: signal) == .none)
        }

        r.run("a one-to-one Messages Signal resolves to .chat with its resolved identifier") {
            let signal = testSignal(source: .messages, chatIdentifier: "+15551234567")
            try expect(messagesDeepLinkTarget(for: signal) == .chat(identifier: "+15551234567"))
        }

        r.run("a group-chat Messages Signal (no chatIdentifier) resolves to .appOnly") {
            let signal = testSignal(source: .messages, chatIdentifier: nil)
            try expect(messagesDeepLinkTarget(for: signal) == .appOnly)
        }
    }
}
