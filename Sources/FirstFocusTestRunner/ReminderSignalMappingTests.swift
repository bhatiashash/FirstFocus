import FirstFocusCore
import Foundation

private func testSignal(label: String = "Test", sender: String? = nil) -> Signal {
    Signal(
        id: "s1",
        source: .messages,
        sourceRef: "msg-1",
        label: label,
        originalText: label,
        createdAt: Date(),
        provenance: .inferred,
        sender: sender
    )
}

func registerReminderSignalMappingTests(_ runner: TestRunner) {
    runner.suite("isResolvedSenderName") { r in
        r.run("a plain name is resolved") {
            try expect(isResolvedSenderName("Sanjana"))
        }

        r.run("a full name is resolved") {
            try expect(isResolvedSenderName("Aman Todi"))
        }

        r.run("a +1 phone number is not resolved") {
            try expect(!isResolvedSenderName("+13177959806"))
        }

        r.run("an email address is not resolved") {
            try expect(!isResolvedSenderName("someone@example.com"))
        }
    }

    runner.suite("approvedReminderDraft") { r in
        r.run("a resolved sender is folded into the title") {
            let draft = approvedReminderDraft(from: testSignal(label: "Get Uno and Taboo", sender: "Sanjana"))
            try expect(draft.title == "Get Uno and Taboo (from Sanjana)")
        }

        r.run("an unresolved sender (raw phone number) is dropped, not appended") {
            let draft = approvedReminderDraft(from: testSignal(label: "Go to the brewery", sender: "+15173038190"))
            try expect(draft.title == "Go to the brewery")
        }

        r.run("no sender at all leaves the title untouched") {
            let draft = approvedReminderDraft(from: testSignal(label: "Note to self", sender: nil))
            try expect(draft.title == "Note to self")
        }

        r.run("dueAt and priority pass through unchanged") {
            let dueAt = Date()
            let signal = Signal(
                id: "s1", source: .messages, sourceRef: "msg-1", label: "Test", originalText: "Test",
                createdAt: Date(), dueAt: dueAt, priority: .high, provenance: .inferred, sender: "Sanjana"
            )
            let draft = approvedReminderDraft(from: signal)
            try expect(draft.dueAt == dueAt)
            try expect(draft.priority == .high)
        }
    }
}
