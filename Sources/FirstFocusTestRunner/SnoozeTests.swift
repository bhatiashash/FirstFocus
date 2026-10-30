import FirstFocusCore
import Foundation

// Snooze return times (snooze-section spec, ADR 0045): Tomorrow and Next
// Week each end at 8:00 AM.

func registerSnoozeTests(_ runner: TestRunner) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    runner.suite("Snooze return time") { r in
        r.run("Tomorrow on a Friday afternoon is Saturday 8 AM") {
            try expect(snoozeEnd(.tomorrow, now: at(2026, 10, 2, 16), calendar: calendar) == at(2026, 10, 3, 8))
        }
        r.run("Tomorrow between midnight and 8 AM is 8 AM the same day") {
            try expect(snoozeEnd(.tomorrow, now: at(2026, 10, 6, 1), calendar: calendar) == at(2026, 10, 6, 8))
        }
        r.run("Tomorrow at exactly 8 AM is 8 AM the next day") {
            try expect(snoozeEnd(.tomorrow, now: at(2026, 10, 6, 8), calendar: calendar) == at(2026, 10, 7, 8))
        }
        r.run("Next Week on a Friday is the coming Monday 8 AM") {
            try expect(snoozeEnd(.nextWeek, now: at(2026, 10, 2, 16), calendar: calendar) == at(2026, 10, 5, 8))
        }
        r.run("Next Week on a Sunday is the next day, the same as Tomorrow") {
            let sunday = at(2026, 10, 4, 21)
            try expect(snoozeEnd(.nextWeek, now: sunday, calendar: calendar) == at(2026, 10, 5, 8))
            try expect(snoozeEnd(.tomorrow, now: sunday, calendar: calendar) == at(2026, 10, 5, 8))
        }
        r.run("Next Week on a Monday is the following Monday, even before 8 AM") {
            try expect(snoozeEnd(.nextWeek, now: at(2026, 10, 5, 6), calendar: calendar) == at(2026, 10, 12, 8))
            try expect(snoozeEnd(.nextWeek, now: at(2026, 10, 5, 14), calendar: calendar) == at(2026, 10, 12, 8))
        }
        r.run("Next Week across the end of daylight saving is still 8 AM local") {
            // US clocks go back on Sunday 1 November 2026.
            let end = snoozeEnd(.nextWeek, now: at(2026, 10, 30, 16), calendar: calendar)
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
            try expect(parts == DateComponents(year: 2026, month: 11, day: 2, hour: 8, minute: 0), "got \(parts)")
        }
    }
}
