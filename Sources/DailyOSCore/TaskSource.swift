import Foundation

/// A reminder read from Reminders. Named `ReminderTask`, not `Task`, to
/// avoid colliding with Swift's own concurrency `Task` type; CONTEXT.md's
/// glossary term "Task" still applies to what this models.
public struct ReminderTask: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dueAt: Date?
    public let priority: Priority
    public let createdAt: Date
    /// The reminder's notes (CONTEXT.md: Notes). Read on every fetch;
    /// `update` never writes them, so an edit made in Reminders.app is
    /// never overwritten (ADR 0041).
    public let notes: String?
    /// The reminder's URL: for one Approved from a one-to-one Chat, that
    /// Chat's link. Read on every fetch; `update` never writes it.
    public let url: URL?
    /// The id of the list the reminder is in, which the Focus list
    /// (ADR 0048) reads to tell what is in it. `nil` only from a source
    /// that doesn't say; the Focus list then leaves the reminder alone.
    public let listId: String?
    /// Whether it repeats. Checking off a repeating reminder keeps its id
    /// open and moves its due date to the next occurrence, which is how a
    /// check-off made elsewhere ends its snooze (CONTEXT.md: Snoozed).
    public let isRecurring: Bool

    public init(
        id: String, title: String, dueAt: Date?, priority: Priority, createdAt: Date,
        notes: String? = nil, url: URL? = nil, listId: String? = nil, isRecurring: Bool = false
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.priority = priority
        self.createdAt = createdAt
        self.notes = notes
        self.url = url
        self.listId = listId
        self.isRecurring = isRecurring
    }
}

/// A reminder checked off today, for the Checked Off sheet (CONTEXT.md:
/// Checked Off). `checkedOffAt` is when it was checked off, wherever
/// that happened. `isRecurring` is whether it repeats, since
/// reopening a repeating reminder would fork its recurrence.
public struct CheckedOffReminder: Equatable, Sendable, Identifiable {
    public let task: ReminderTask
    public let checkedOffAt: Date
    public let isRecurring: Bool

    public var id: String { task.id }

    public init(task: ReminderTask, checkedOffAt: Date, isRecurring: Bool = false) {
        self.task = task
        self.checkedOffAt = checkedOffAt
        self.isRecurring = isRecurring
    }
}

/// The fields needed to create a reminder. No `id` or `createdAt`: both are
/// assigned by Reminders itself at creation time, not chosen by the caller.
public struct ReminderDraft: Equatable, Sendable {
    public let title: String
    public let dueAt: Date?
    public let priority: Priority
    /// Written only on Approve: the Batch the Signal came from (ADR 0041).
    public let notes: String?
    /// Written only on Approve, for a one-to-one Chat: its link.
    public let url: URL?

    public init(title: String, dueAt: Date? = nil, priority: Priority = .none, notes: String? = nil, url: URL? = nil) {
        self.title = title
        self.dueAt = dueAt
        self.priority = priority
        self.notes = notes
        self.url = url
    }
}

/// Shaped only for what Reminders needs, deliberately not hedged for a
/// second provider. See ADR 0018.
///
/// Focus Mode v2 makes this fully bidirectional (supersedes ADR 0001, which
/// limited the app to reading plus `complete(id:)`): DailyOS now creates,
/// edits, and deletes reminders too. A change made outside the app —
/// directly in the Reminders app — needs no separate reconciliation path,
/// since `listOpenTasks()` is already a full unbounded fetch re-run on every
/// refresh trigger.
public protocol TaskSource: Sendable {
    /// Requests the Reminders Gate. Called once, before the window
    /// appears. On the interface rather than only on the EventKit adapter
    /// so `start()`'s Gate sequence crosses the seam like everything else.
    func requestAccess() async throws -> Bool

    /// Whether this Source can currently be read, decided from its Gate.
    /// On the interface rather than a raw `EKAuthorizationStatus` the
    /// caller has to remember to map: the caller's question is "is this
    /// Source available", so that is what it asks. Adapters implement it
    /// by calling `reminderAvailability(authorizationStatus:)`, which
    /// stays pure and tested.
    func availability() -> SourceAvailability

    /// Every incomplete reminder, unbounded. A date-bounded query would drop
    /// undated reminders, so ranking always happens in process.
    func listOpenTasks() -> [ReminderTask]

    /// Every reminder checked off at or after `since`, in DailyOS or
    /// anywhere else. Bounded by date so the fetch stays small however many
    /// completed reminders there are.
    func listCheckedOffTasks(since: Date) -> [CheckedOffReminder]

    /// Completes the reminder.
    func complete(id: String) throws

    /// Reopens a completed reminder: the reverse of `complete(id:)`.
    func reopen(id: String) throws

    /// Creates a new reminder from `draft` and returns it with the real id
    /// and creation date Reminders assigned.
    func create(_ draft: ReminderDraft) throws -> ReminderTask

    /// Sets one field of the reminder with `id`, leaving every other field
    /// as Reminders has it now.
    func update(id: String, _ edit: ReminderEdit) throws

    /// Deletes the reminder outright — distinct from `complete(id:)`, which
    /// leaves it in place, completed.
    func delete(id: String) throws

    /// The Focus list (ADR 0048): the list with `id` if it still exists,
    /// otherwise a list titled `title` in the same account as the default
    /// list, created if there is none. Returns that list's id.
    func ensureList(id: String?, title: String) throws -> String

    /// The list new reminders go in, where a reminder leaving the Focus
    /// list goes when its own list is unknown or gone.
    func defaultListId() -> String?
}

/// Collapses Reminders' inverted 0-9 priority scale (0 = unset) to the
/// three-value scale the ranking function understands. 1-4 is Reminders'
/// own "High", 5 is "Medium", 6-9 is "Low"; only "unset" and "High" are
/// distinct for ranking, so Medium and Low both land on `.normal`.
public func collapseReminderPriority(_ raw: Int) -> Priority {
    switch raw {
    case 0:
        return .none
    case 1...4:
        return .high
    default:
        return .normal
    }
}

/// The inverse of `collapseReminderPriority`, for writing a Signal's
/// three-value priority back out to Reminders' own 0-9 scale. Picks one
/// canonical raw value per band rather than trying to preserve whatever
/// specific number a reminder happened to carry before.
public func expandReminderPriority(_ priority: Priority) -> Int {
    switch priority {
    case .none: return 0
    case .high: return 1
    case .normal: return 5
    }
}

/// The one field of an existing reminder an edit from DailyOS changes.
/// An edit never carries the rest of the reminder: writing back a copy
/// read earlier would overwrite whatever changed since on a phone or in
/// Reminders.app, and would round an all-day due date to midnight or a
/// Low priority to Medium on the way through.
public enum ReminderEdit: Equatable, Sendable {
    case title(String)
    case priority(Priority)
    /// Stored as `reminderDueDateComponents(for:)` gives it: a date at the
    /// start of its day, as a typed phrase always is, is all day.
    case dueDate(Date)
    /// Moves the reminder to the list with this id, keeping its id
    /// (ADR 0048). Throws `listNotFound` when there is no such list.
    case list(String)
}

/// The raw 0-9 value to store when setting `priority` on a reminder that
/// holds `raw`. A value already in `priority`'s band is kept, so a Low (9)
/// or a High of 3 set by another app survives an edit to the same band.
public func reminderPriority(setting priority: Priority, over raw: Int) -> Int {
    collapseReminderPriority(raw) == priority ? raw : expandReminderPriority(priority)
}

/// The due date components to store for `date`. A date at the start of its
/// day is stored as a date alone, an all-day reminder, since that is what
/// a typed "tomorrow" or a date-only Suggestion means; any other time is
/// stored to the second. Reading back gives the same `Date` either way.
public func reminderDueDateComponents(for date: Date, calendar: Calendar = .current) -> DateComponents {
    if calendar.startOfDay(for: date) == date {
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
    return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
}

public enum TaskSourceError: Error {
    case taskNotFound(id: String)
    case listNotFound(id: String)
}
