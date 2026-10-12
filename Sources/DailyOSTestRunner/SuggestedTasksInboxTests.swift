import DailyOSCore
import Foundation

private func testSignal(
    id: String,
    createdAt: Date,
    provenance: Provenance = .inferred,
    state: SignalState = .open,
    source: Source = .messages
) -> Signal {
    Signal(
        id: id,
        source: source,
        sourceRef: id,
        label: id,
        originalText: id,
        createdAt: createdAt,
        provenance: provenance,
        state: state
    )
}

func registerSuggestedTasksInboxTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86400

    runner.suite("isSuggestion") { r in
        r.run("an open, inferred signal is a suggestion") {
            let s = testSignal(id: "a", createdAt: now, provenance: .inferred, state: .open)
            try expect(isSuggestion(s))
        }
        r.run("a stated signal is never a suggestion, even if open") {
            let s = testSignal(id: "a", createdAt: now, provenance: .stated, state: .open, source: .reminders)
            try expect(!isSuggestion(s))
        }
        r.run("a checked-off inferred signal is no longer a suggestion") {
            let s = testSignal(id: "a", createdAt: now, provenance: .inferred, state: .checkedOff(at: now))
            try expect(!isSuggestion(s))
        }
        r.run("a dismissed inferred signal is no longer a suggestion") {
            let s = testSignal(id: "a", createdAt: now, provenance: .inferred, state: .dismissed(at: now))
            try expect(!isSuggestion(s))
        }
        r.run("an approved inferred signal is no longer a suggestion") {
            let s = testSignal(id: "a", createdAt: now, provenance: .inferred, state: .approved(reminderId: "r1", at: now))
            try expect(!isSuggestion(s))
        }
    }

    runner.suite("suggestedTasksInbox") { r in
        r.run("only open, inferred signals surface, everything else is excluded") {
            let suggestion = testSignal(id: "suggestion", createdAt: now)
            let stated = testSignal(id: "stated", createdAt: now, provenance: .stated, source: .reminders)
            let checkedOff = testSignal(id: "checked-off", createdAt: now, state: .checkedOff(at: now))
            let dismissed = testSignal(id: "dismissed", createdAt: now, state: .dismissed(at: now))
            let approved = testSignal(id: "approved", createdAt: now, state: .approved(reminderId: "r1", at: now))
            let inbox = suggestedTasksInbox([suggestion, stated, checkedOff, dismissed, approved])
            try expect(inbox.map(\.id) == ["suggestion"])
        }

        r.run("ordered by recency, newest first") {
            let older = testSignal(id: "older", createdAt: now - day)
            let newer = testSignal(id: "newer", createdAt: now)
            let inbox = suggestedTasksInbox([older, newer])
            try expect(inbox.map(\.id) == ["newer", "older"])
        }

        r.run("approving a suggestion removes it from the inbox") {
            let signal = testSignal(id: "a", createdAt: now)
            try expect(suggestedTasksInbox([signal]).map(\.id) == ["a"])
            let approved = testSignal(id: "a", createdAt: now, state: .approved(reminderId: "r1", at: now))
            try expect(suggestedTasksInbox([approved]).isEmpty)
        }

        r.run("dismissing a suggestion removes it from the inbox") {
            let signal = testSignal(id: "a", createdAt: now)
            try expect(suggestedTasksInbox([signal]).map(\.id) == ["a"])
            let dismissed = testSignal(id: "a", createdAt: now, state: .dismissed(at: now))
            try expect(suggestedTasksInbox([dismissed]).isEmpty)
        }

        r.run("empty input produces an empty inbox") {
            try expect(suggestedTasksInbox([]).isEmpty)
        }
    }
}
