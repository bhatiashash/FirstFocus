import Foundation

/// The two ways to snooze a row (CONTEXT.md: Snoozed, ADR 0045). Each
/// ends at 8:00 AM; there is no custom duration.
public enum SnoozeChoice: CaseIterable, Sendable {
    case tomorrow
    case nextWeek
}

/// The hour of the morning a snooze ends.
let snoozeEndHour = 8

/// When a snooze made at `now` ends. Tomorrow is 8:00 AM on the next
/// day, or today when it's still before 8:00 AM, since "tomorrow" at 1 AM
/// means the morning you're about to wake up for. Next Week is 8:00 AM on
/// the next Monday after today: on a Sunday that's the next day, on a
/// Monday a week on.
public func snoozeEnd(_ choice: SnoozeChoice, now: Date, calendar: Calendar = .current) -> Date {
    let today = calendar.startOfDay(for: now)
    let day: Date
    switch choice {
    case .tomorrow:
        let todayAtEight = calendar.date(bySettingHour: snoozeEndHour, minute: 0, second: 0, of: today)!
        if now < todayAtEight { return todayAtEight }
        day = calendar.date(byAdding: .day, value: 1, to: today)!
    case .nextWeek:
        day = calendar.nextDate(
            after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime
        )!
    }
    return calendar.date(bySettingHour: snoozeEndHour, minute: 0, second: 0, of: day)!
}
