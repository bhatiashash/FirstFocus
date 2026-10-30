import FirstFocusApp
import FirstFocusCore
import Foundation

/// typed-title-entry: typing a reminder title into `+`, Rename or Quick
/// Capture, with a pinned clock.
private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 15, minute: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute))!
}

private func startOf(_ date: Date) -> Date {
    Calendar.current.startOfDay(for: date)
}

/// 2026-09-23 is a Wednesday. Tests type weekday names and other phrases
/// from the fixed list, which count from the clock the entry is given;
/// `NSDataDetector`'s own phrases ("tomorrow") read the wall clock.
private let wednesday = day(2026, 9, 23)

/// Types `text` one character at a time, the way a text field reports it.
private func type(_ text: String, into entry: inout TypedTitleEntry) {
    for character in text {
        entry.edit(to: entry.text + String(character))
    }
}

func registerTypedTitleEntryTests(_ runner: TestRunner) {
    runner.suite("typed-title-entry: a date phrase in the title") { r in
        r.run("a phrase shows a badge, and ⏎ saves the title without it") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday", into: &entry)
            try expect(entry.badge?.text == "Tomorrow", "got \(String(describing: entry.badge))")
            let saved = try require(entry.submit())
            try expect(saved.title == "Call the dentist", "got \(saved.title)")
            try expect(saved.dueAt == startOf(day(2026, 9, 24)))
        }

        r.run("a phrase that is the whole text shows no badge and is saved as the title") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("thursday", into: &entry)
            try expect(entry.badge == nil)
            let saved = try require(entry.submit())
            try expect(saved.title == "thursday" && saved.dueAt == nil, "got \(saved)")
        }

        r.run("empty or whitespace-only text saves nothing") {
            var entry = TypedTitleEntry(now: { wednesday })
            try expect(entry.submit() == nil && entry.isBlank)
            type("   ", into: &entry)
            try expect(entry.submit() == nil && entry.isBlank)
            type("x", into: &entry)
            try expect(!entry.isBlank)
        }
    }

    runner.suite("typed-title-entry: cancelling the badge") { r in
        r.run("cancelling keeps the phrase as words for the rest of the entry") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday", into: &entry)
            entry.cancelBadge()
            try expect(entry.badge == nil)
            type(" please", into: &entry)
            try expect(entry.badge == nil, "got \(String(describing: entry.badge))")
            let saved = try require(entry.submit())
            try expect(saved.title == "Call the dentist thursday please" && saved.dueAt == nil, "got \(saved)")
        }

        r.run("with the later phrase cancelled, an earlier one can show instead") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Pay rent friday or thursday", into: &entry)
            entry.cancelBadge()
            try expect(entry.badge?.dueAt == startOf(day(2026, 9, 25)), "got \(String(describing: entry.badge))")
        }

        r.run("⌫ straight after the badge appears cancels it and keeps the text") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday", into: &entry)
            entry.edit(to: "Call the dentist thursda")
            try expect(entry.text == "Call the dentist thursday", "got \(entry.text)")
            try expect(entry.badge == nil)
        }

        r.run("⌫ once the phrase is no longer at the end just deletes") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday!", into: &entry)
            entry.edit(to: "Call the dentist thursday")
            try expect(entry.text == "Call the dentist thursday", "got \(entry.text)")
            try expect(entry.badge?.text == "Tomorrow", "the badge stays, got \(String(describing: entry.badge))")
        }

        r.run("selecting and deleting more than one character just deletes") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday", into: &entry)
            entry.edit(to: "Call the dentist thurs")
            try expect(entry.text == "Call the dentist thurs", "got \(entry.text)")
        }
    }

    runner.suite("typed-title-entry: starting from a title, and starting again") { r in
        r.run("a title that already has date phrases shows no badge and saves no date") {
            let entry = TypedTitleEntry(text: "Pay rent friday or thursday", now: { wednesday })
            try expect(entry.badge == nil, "got \(String(describing: entry.badge))")
            let saved = try require(entry.submit())
            try expect(saved.title == "Pay rent friday or thursday" && saved.dueAt == nil, "got \(saved)")
        }

        r.run("a phrase typed into it still shows a badge") {
            var entry = TypedTitleEntry(text: "Pay rent friday", now: { wednesday })
            type(" in 3 days", into: &entry)
            try expect(entry.badge?.dueAt == startOf(day(2026, 9, 26)), "got \(String(describing: entry.badge))")
        }

        r.run("reset clears the text and what was cancelled") {
            var entry = TypedTitleEntry(now: { wednesday })
            type("Call the dentist thursday", into: &entry)
            entry.cancelBadge()
            entry.reset()
            try expect(entry.text.isEmpty)
            type("Call the dentist thursday", into: &entry)
            try expect(entry.badge?.text == "Tomorrow", "got \(String(describing: entry.badge))")
        }
    }

    runner.suite("typed-title-entry: the clock") { r in
        r.run("⏎ just after midnight dates the phrase from the clock at ⏎") {
            let clock = MutableClock(day(2026, 9, 23, hour: 23, minute: 59))
            var entry = TypedTitleEntry(now: { clock.now })
            type("Water the plants in 1 day", into: &entry)
            try expect(entry.badge?.dueAt == startOf(day(2026, 9, 24)))
            clock.now = day(2026, 9, 24, hour: 0, minute: 1)
            let saved = try require(entry.submit())
            try expect(saved.dueAt == startOf(day(2026, 9, 25)), "got \(String(describing: saved.dueAt))")
        }
    }
}

private final class MutableClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
