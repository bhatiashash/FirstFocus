import EventKit
import Foundation

/// Production `TaskSource`, backed by EventKit. There is no read-only
/// reminders scope on macOS: `requestFullAccessToReminders` is the only
/// door, so this asks for write access it uses only for `complete(id:)`.
/// `@unchecked Sendable`: `EKEventStore` predates Swift concurrency
/// annotations but documents its methods as safe to call from any thread.
public final class EventKitTaskSource: TaskSource, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Requests the Reminders Gate. Call once, before the window appears,
    /// per the permissions and first-run flow.
    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    /// The Reminders Gate's current state, without prompting — a class-level
    /// EventKit query, unlike Full Disk Access which has no such API. Used
    /// to detect revocation on re-check (foreground, manual retry) and to
    /// feed `reminderAvailability(authorizationStatus:)`.
    public static func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// `TaskSource.availability()`: one line over the pure, tested
    /// mapping, so the rule stays in `Gates.swift` and only the reading
    /// of it lives here.
    public func availability() -> SourceAvailability {
        reminderAvailability(authorizationStatus: Self.authorizationStatus())
    }

    public func listOpenTasks() -> [ReminderTask] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        return fetch(matching: predicate).map(makeTask(from:))
    }

    public func listCheckedOffTasks(since: Date) -> [CheckedOffReminder] {
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: since,
            ending: nil,
            calendars: nil
        )
        return fetch(matching: predicate).map { reminder in
            CheckedOffReminder(
                task: makeTask(from: reminder),
                checkedOffAt: reminder.completionDate ?? since,
                isRecurring: reminder.hasRecurrenceRules
            )
        }
    }

    private func fetch(matching predicate: NSPredicate) -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func makeTask(from reminder: EKReminder) -> ReminderTask {
        ReminderTask(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            dueAt: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
            priority: collapseReminderPriority(reminder.priority),
            createdAt: reminder.creationDate ?? .distantPast,
            notes: reminder.hasNotes ? reminder.notes : nil,
            url: reminder.url
        )
    }

    public func complete(id: String) throws {
        let reminder = try fetchReminder(id: id)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    public func reopen(id: String) throws {
        let reminder = try fetchReminder(id: id)
        reminder.isCompleted = false
        try store.save(reminder, commit: true)
    }

    public func create(_ draft: ReminderDraft) throws -> ReminderTask {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.title = draft.title
        reminder.dueDateComponents = draft.dueAt.map { reminderDueDateComponents(for: $0) }
        reminder.priority = expandReminderPriority(draft.priority)
        // Notes and URL are written here and nowhere else (ADR 0041).
        reminder.notes = draft.notes
        reminder.url = draft.url
        try store.save(reminder, commit: true)

        return ReminderTask(
            id: reminder.calendarItemIdentifier,
            title: draft.title,
            dueAt: draft.dueAt,
            priority: draft.priority,
            createdAt: reminder.creationDate ?? .distantPast,
            notes: draft.notes,
            url: draft.url
        )
    }

    /// Sets the one field on the reminder as the store has it now, so
    /// nothing else on it is rewritten (`ReminderEdit`).
    public func update(id: String, _ edit: ReminderEdit) throws {
        let reminder = try fetchReminder(id: id)
        switch edit {
        case .title(let title):
            reminder.title = title
        case .priority(let priority):
            reminder.priority = reminderPriority(setting: priority, over: reminder.priority)
        case .dueDate(let dueAt):
            reminder.dueDateComponents = reminderDueDateComponents(for: dueAt)
        }
        try store.save(reminder, commit: true)
    }

    public func delete(id: String) throws {
        let reminder = try fetchReminder(id: id)
        try store.remove(reminder, commit: true)
    }

    private func fetchReminder(id: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        return reminder
    }
}
