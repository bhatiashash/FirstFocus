import DailyOSCore
import Foundation

private func remindersSignal(dueAt: Date? = nil, priority: Priority = .none) -> Signal {
    Signal(
        id: "r1", source: .reminders, sourceRef: "r1", label: "Test", originalText: "Test", createdAt: Date(),
        dueAt: dueAt, priority: priority, provenance: .stated
    )
}

private func messagesSignal() -> Signal {
    Signal(
        id: "s1", source: .messages, sourceRef: "m1", label: "Test", originalText: "test", createdAt: Date(),
        provenance: .inferred
    )
}

func registerSignalAffordancesTests(_ runner: TestRunner) {
    let now = Date()
    let day: TimeInterval = 86400
    runner.suite("affordances(for:isLater:now:)") { r in
        r.run("a Focus row with a Priority and a due date after tomorrow offers Move to Later (ADR 0042)") {
            let result = affordances(for: remindersSignal(dueAt: now + 30 * day, priority: .high), isLater: false, now: now)
            try expect(result.contains(.demote), "clearing Priority moves it to Later, since its date is too far off to hold it in Focus")
        }

        r.run("a Focus row with a Priority due tomorrow still offers no Move to Later") {
            let result = affordances(for: remindersSignal(dueAt: now + day, priority: .high), isLater: false, now: now)
            try expect(!result.contains(.demote))
        }

        r.run("a Later Reminders Signal offers rename, delete and promote — never dismiss, demote or reorder") {
            let result = affordances(for: remindersSignal(), isLater: true, now: now)
            try expect(result == [.rename, .delete, .promote])
        }

        r.run("a Focus Reminders Signal with a due date offers rename, delete and reorder — never demote") {
            let result = affordances(for: remindersSignal(dueAt: Date()), isLater: false, now: now)
            try expect(
                result == [.rename, .delete, .reorder],
                "a due date alone keeps tier(for:) at .focus regardless of priority, so demote would silently do nothing"
            )
        }

        r.run("a Focus Reminders Signal with priority but no due date offers demote too") {
            let result = affordances(for: remindersSignal(priority: .high), isLater: false, now: now)
            try expect(result == [.rename, .delete, .reorder, .demote])
        }

        r.run("a Focus Reminders Signal with both a due date and priority still offers no demote") {
            let result = affordances(for: remindersSignal(dueAt: Date(), priority: .high), isLater: false, now: now)
            try expect(!result.contains(.demote), "the due date alone is enough to disqualify demote, priority or not")
        }

        r.run("a Later Messages Signal offers dismiss and promote — never rename, delete, demote or reorder") {
            let result = affordances(for: messagesSignal(), isLater: true, now: now)
            try expect(result == [.dismiss, .promote])
        }

        r.run("a Focus Messages Signal with priority offers dismiss, reorder and demote") {
            var signal = messagesSignal()
            signal.priority = .high
            let result = affordances(for: signal, isLater: false, now: now)
            try expect(result == [.dismiss, .reorder, .demote])
        }

        r.run("rename and delete are mutually exclusive with dismiss, by source, always") {
            try expect(affordances(for: remindersSignal(), isLater: true, now: now).isDisjoint(with: [.dismiss]))
            try expect(affordances(for: messagesSignal(), isLater: true, now: now).isDisjoint(with: [.rename, .delete]))
        }
    }
}
