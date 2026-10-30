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

/// Every way a snooze starts and ends (CONTEXT.md: Snoozed, ADR 0045), in
/// one place. The Signal Board reads snoozes through it and tells it about
/// each Reminders fetch; everything else that ends a snooze calls `end`.
///
/// A snooze ends when its moment passes (the Ranked List judges that on
/// every read), on Unsnooze, and when the reminder is checked off,
/// wherever that happened: one that appears among today's checked-off
/// reminders, or a repeating one whose due date has moved past the date
/// it had when it was snoozed, since checking off a repeating reminder
/// keeps its id and moves the date to the next occurrence. The due date is
/// stored with the snooze, so a check-off made while DailyOS was closed
/// still counts.
///
/// It also brings a Snoozed row back on time (snooze-wake): its alarm is
/// kept set for the earliest snooze end still to come, read from the store
/// at init and after every change, and `onWake` fires when one ends. The
/// alarm fires on wake when the Mac slept through the end.
@MainActor
public final class Snoozes {
    /// A snooze has ended: the Ranked List changes with no write.
    public var onWake: (() -> Void)?

    private let store: any SnoozeStore
    /// `nil` where nothing needs waking, as in a test of the Board alone.
    private let alarm: (any Alarm)?
    private let now: @MainActor () -> Date
    /// When the alarm is set for, so an unchanged end isn't scheduled again.
    private var wakeAt: Date?

    public init(store: any SnoozeStore, alarm: (any Alarm)? = nil, now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.alarm = alarm
        self.now = now
        reschedule()
    }

    /// Snoozes `signal` until `until`, replacing any snooze it had.
    /// Returns the end it replaced, for Undo.
    @discardableResult
    public func snooze(_ signal: Signal, until: Date) -> Date? {
        let replaced = store.snoozedUntil(signalId: signal.id)
        snooze(signalId: signal.id, until: until, dueAt: signal.dueAt)
        return replaced
    }

    /// The same by id, for a reminder Approve just made, which the caller
    /// holds no Signal for yet.
    public func snooze(signalId: String, until: Date, dueAt: Date?) {
        try? store.snooze(signalId: signalId, until: until, dueAt: dueAt)
        reschedule()
    }

    /// Puts `signal`'s snooze back to `until`, or ends it with `nil`: a
    /// snooze's Undo.
    public func set(_ signal: Signal, until: Date?) {
        if let until {
            snooze(signal, until: until)
        } else {
            end(signalId: signal.id)
        }
    }

    /// Ends `signalId`'s snooze, if it has one.
    public func end(signalId: String) {
        try? store.unsnooze(signalId: signalId)
        reschedule()
    }

    /// When `signalId`'s snooze ends, read from the store rather than a
    /// Signal hydrated before the last snooze.
    public func until(signalId: String) -> Date? {
        store.snoozedUntil(signalId: signalId)
    }

    /// The Board's hydration: each Snoozed id among `signalIds`, with when
    /// its snooze ends.
    func untils(signalIds: [String]) -> [String: Date] {
        store.snoozedUntils(signalIds: signalIds)
    }

    /// A Reminders fetch landed: ends the snooze of every reminder it shows
    /// checked off.
    public func remindersFetched(open: [ReminderTask], checkedOff: [CheckedOffReminder]) {
        let candidates = checkedOff.map(\.id) + open.filter(\.isRecurring).map(\.id)
        let snoozed = store.snoozedUntils(signalIds: candidates)
        guard !snoozed.isEmpty else { return }
        for reminder in checkedOff where snoozed[reminder.id] != nil {
            end(signalId: reminder.id)
        }
        let recurring = open.filter { $0.isRecurring && snoozed[$0.id] != nil }
        let dueWhenSnoozed = store.snoozedDueDates(signalIds: recurring.map(\.id))
        for reminder in recurring {
            if let then = dueWhenSnoozed[reminder.id], let now = reminder.dueAt, now > then {
                end(signalId: reminder.id)
            }
        }
    }

    /// Sets the alarm for the earliest snooze end still to come, or cancels
    /// it with none.
    private func reschedule() {
        guard let alarm else { return }
        let earliest = store.earliestSnoozeEnd(after: now())
        guard earliest != wakeAt || !alarm.isPending else { return }
        wakeAt = earliest
        guard let earliest else {
            alarm.cancel()
            return
        }
        alarm.schedule(at: earliest) { [weak self] in
            guard let self else { return }
            self.wakeAt = nil
            self.reschedule()
            self.onWake?()
        }
    }
}
