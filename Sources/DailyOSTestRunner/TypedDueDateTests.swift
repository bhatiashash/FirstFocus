import DailyOSCore
import Foundation

/// A local calendar day at mid-afternoon, so a pinned "today" never sits
/// near a midnight the time zone could push it across.
private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 15))!
}

private func startOf(_ date: Date) -> Date {
    Calendar.current.startOfDay(for: date)
}

func registerTypedDueDateTests(_ runner: TestRunner) {
    // 2026-09-23 is a Wednesday.
    let wednesday = day(2026, 9, 23)

    runner.suite("parseTypedDueDate: the fixed phrases (ADR 0030 amendment)") { r in
        r.run("\"next week\" is next Monday") {
            try expect(parseTypedDueDate(in: "next week", today: wednesday)?.dueAt == startOf(day(2026, 9, 28)))
        }
        r.run("\"next week\" on a Sunday is the next day, and on a Monday a week out") {
            try expect(parseTypedDueDate(in: "next week", today: day(2026, 9, 27))?.dueAt == startOf(day(2026, 9, 28)))
            try expect(parseTypedDueDate(in: "next week", today: day(2026, 9, 28))?.dueAt == startOf(day(2026, 10, 5)))
        }
        r.run("\"this weekend\" is the coming Saturday") {
            try expect(parseTypedDueDate(in: "this weekend", today: wednesday)?.dueAt == startOf(day(2026, 9, 26)))
        }
        r.run("\"this weekend\" on a Saturday or a Sunday is today") {
            try expect(parseTypedDueDate(in: "this weekend", today: day(2026, 9, 26))?.dueAt == startOf(day(2026, 9, 26)))
            try expect(parseTypedDueDate(in: "this weekend", today: day(2026, 9, 27))?.dueAt == startOf(day(2026, 9, 27)))
        }
        r.run("\"end of month\" and \"end of the month\" are the last day of this month") {
            try expect(parseTypedDueDate(in: "end of month", today: wednesday)?.dueAt == startOf(day(2026, 9, 30)))
            try expect(parseTypedDueDate(in: "end of the month", today: day(2026, 12, 15))?.dueAt == startOf(day(2026, 12, 31)))
            try expect(parseTypedDueDate(in: "end of month", today: day(2028, 2, 10))?.dueAt == startOf(day(2028, 2, 29)), "a leap year")
        }
        r.run("\"in N days\" and \"in N weeks\" count from today, across a month and a year end") {
            try expect(parseTypedDueDate(in: "in 3 days", today: day(2026, 9, 29))?.dueAt == startOf(day(2026, 10, 2)))
            try expect(parseTypedDueDate(in: "in 1 day", today: wednesday)?.dueAt == startOf(day(2026, 9, 24)))
            try expect(parseTypedDueDate(in: "in 2 weeks", today: day(2026, 12, 25))?.dueAt == startOf(day(2027, 1, 8)))
        }
        r.run("a weekday is the next one, and today when it names today") {
            try expect(parseTypedDueDate(in: "friday", today: wednesday)?.dueAt == startOf(day(2026, 9, 25)))
            try expect(parseTypedDueDate(in: "Wednesday", today: wednesday)?.dueAt == startOf(wednesday))
            try expect(parseTypedDueDate(in: "tuesday", today: wednesday)?.dueAt == startOf(day(2026, 9, 29)))
        }
    }

    runner.suite("parseTypedDueDate: phrases NSDataDetector resolves") { r in
        // NSDataDetector always resolves against the live clock (ADR 0030),
        // so these pass the real today and check the shape of the answer.
        r.run("\"tomorrow\" is tomorrow, at the start of the day") {
            let parsed = try require(parseTypedDueDate(in: "Call the bank tomorrow", today: Date()))
            try expect(parsed.dueAt == startOf(expectedDate(daysFromToday: 1)))
            try expect(parsed.title == "Call the bank")
        }
        r.run("\"by Today\" is today, and leaves the title without it") {
            let parsed = try require(parseTypedDueDate(in: "get this done by Today", today: Date()))
            try expect(parsed.dueAt == startOf(Date()))
            try expect(parsed.title == "get this done")
        }
        r.run("\"tonight\" is today, since due dates carry no time of day") {
            try expect(parseTypedDueDate(in: "buy milk tonight", today: Date())?.dueAt == startOf(Date()))
        }
        r.run("\"next monday\" is read as one phrase, not as a stray \"next\" plus a weekday") {
            let parsed = try require(parseTypedDueDate(in: "call bob next monday", today: Date()))
            try expect(parsed.title == "call bob")
            try expect(Calendar.current.component(.weekday, from: parsed.dueAt) == 2)
        }
        r.run("\"due tomorrow\" is tomorrow, not today (NSDataDetector misreads \"due\")") {
            let parsed = try require(parseTypedDueDate(in: "send deck due tomorrow", today: Date()))
            try expect(parsed.dueAt == startOf(expectedDate(daysFromToday: 1)))
            try expect(parsed.title == "send deck")
        }
    }

    runner.suite("parseTypedDueDate: the title and the match") { r in
        r.run("the phrase is removed from the title, with a connecting \"on\", \"by\" or \"due\"") {
            try expect(parseTypedDueDate(in: "Call dentist friday", today: wednesday)?.title == "Call dentist")
            try expect(parseTypedDueDate(in: "Call dentist on friday", today: wednesday)?.title == "Call dentist")
            try expect(parseTypedDueDate(in: "Send the deck by friday", today: wednesday)?.title == "Send the deck")
            try expect(parseTypedDueDate(in: "due monday send deck", today: wednesday)?.title == "send deck")
        }
        r.run("whitespace left behind is collapsed") {
            try expect(parseTypedDueDate(in: "Call  friday   dentist", today: wednesday)?.title == "Call dentist")
        }
        r.run("the phrase is reported as typed, for the badge") {
            try expect(parseTypedDueDate(in: "Call dentist Friday", today: wednesday)?.phrase == "Friday")
        }
        r.run("with two date phrases, the last one sets the date") {
            let parsed = try require(parseTypedDueDate(in: "Pay the May 3 invoice by friday", today: wednesday))
            try expect(parsed.dueAt == startOf(day(2026, 9, 25)))
            try expect(parsed.title == "Pay the May 3 invoice")
        }
        r.run("a cancelled phrase is never matched again") {
            try expect(parseTypedDueDate(in: "Call dentist friday", today: wednesday, cancelled: ["friday"]) == nil)
            try expect(parseTypedDueDate(in: "Call dentist Friday", today: wednesday, cancelled: ["friday"]) == nil, "case doesn't matter")
        }
        r.run("cancelling the last phrase falls back to an earlier one") {
            let parsed = try require(parseTypedDueDate(in: "next week or friday", today: wednesday, cancelled: ["friday"]))
            try expect(parsed.phrase == "next week")
        }
        r.run("text with no date gives no match") {
            try expect(parseTypedDueDate(in: "Buy milk", today: wednesday) == nil)
            try expect(parseTypedDueDate(in: "", today: wednesday) == nil)
        }
        r.run("\"Watch Friday Night Lights\" matches, which is what cancelling is for") {
            try expect(parseTypedDueDate(in: "Watch Friday Night Lights", today: Date()) != nil)
        }
        r.run("a word merely containing a weekday is not a match") {
            try expect(parseTypedDueDate(in: "Plan sundays", today: wednesday) == nil)
        }
    }

    runner.suite("typedDueDateBadgeText: the pill's words") { r in
        r.run("today and tomorrow are named; any other day is its date") {
            try expect(typedDueDateBadgeText(dueAt: startOf(wednesday), today: wednesday) == "Today")
            try expect(typedDueDateBadgeText(dueAt: startOf(day(2026, 9, 24)), today: wednesday) == "Tomorrow")
            let friday = startOf(day(2026, 9, 25))
            try expect(
                typedDueDateBadgeText(dueAt: friday, today: wednesday)
                    == friday.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            )
        }
    }
}
