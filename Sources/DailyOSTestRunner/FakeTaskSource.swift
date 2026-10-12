import DailyOSCore
import Foundation

/// Test double for `TaskSource`. Holds tasks in memory; `complete(id:)`
/// moves the task out of `tasks` into `checkedOff`, matching EventKit's
/// real behaviour of returning a completed reminder only from the
/// completed-reminders fetch.
final class FakeTaskSource: TaskSource, @unchecked Sendable {
    private(set) var tasks: [ReminderTask]
    /// Seedable, to stand in for reminders completed on a phone or in
    /// Reminders.app.
    private(set) var checkedOff: [CheckedOffReminder]
    private(set) var completedIds: [String] = []
    private(set) var requestedAccess = false
    /// Settable so a test can drive ADR 0005's degrade path: a Gate that
    /// is denied at launch, or revoked part-way through a session.
    var gateAvailability: SourceAvailability
    private var nextId = 1

    init(tasks: [ReminderTask] = [], checkedOff: [CheckedOffReminder] = [], availability: SourceAvailability = .available) {
        self.tasks = tasks
        self.checkedOff = checkedOff
        self.gateAvailability = availability
    }

    func requestAccess() async throws -> Bool {
        requestedAccess = true
        return gateAvailability == .available
    }

    func availability() -> SourceAvailability {
        gateAvailability
    }

    /// Counts fetches so a test can tell which Source a refresh trigger
    /// actually reached (ticket 11: a `.eventKitChange` must never touch
    /// the Messages model).
    private(set) var listCallCount = 0

    /// Runs inside `listOpenTasks()` after it reads and before it returns,
    /// off the main actor, so a test can hold one fetch's read back while
    /// another fetch runs.
    var afterReading: (@Sendable () -> Void)?

    func listOpenTasks() -> [ReminderTask] {
        listCallCount += 1
        let read = tasks
        afterReading?()
        return read
    }

    /// Stands in for the process exiting before a background write lands:
    /// while set, a `complete` off the main thread never happens.
    var dropsBackgroundCompletions = false

    func complete(id: String) throws {
        if dropsBackgroundCompletions, !Thread.isMainThread { return }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        let task = tasks.remove(at: index)
        checkedOff.append(CheckedOffReminder(task: task, checkedOffAt: Date()))
        completedIds.append(id)
    }

    func reopen(id: String) throws {
        guard let index = checkedOff.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        tasks.append(checkedOff.remove(at: index).task)
    }

    func listCheckedOffTasks(since: Date) -> [CheckedOffReminder] {
        checkedOff.filter { $0.checkedOffAt >= since }
    }

    func create(_ draft: ReminderDraft) throws -> ReminderTask {
        let task = ReminderTask(
            id: "fake-\(nextId)",
            title: draft.title,
            dueAt: draft.dueAt,
            priority: draft.priority,
            createdAt: Date(),
            notes: draft.notes,
            url: draft.url
        )
        nextId += 1
        tasks.append(task)
        return task
    }

    func update(id: String, _ edit: ReminderEdit) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        let task = tasks[index]
        var title = task.title
        var priority = task.priority
        var dueAt = task.dueAt
        switch edit {
        case .title(let newTitle): title = newTitle
        case .priority(let newPriority): priority = newPriority
        case .dueDate(let newDueAt): dueAt = newDueAt
        }
        tasks[index] = ReminderTask(
            id: task.id, title: title, dueAt: dueAt, priority: priority, createdAt: task.createdAt,
            notes: task.notes, url: task.url
        )
    }

    func delete(id: String) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        tasks.remove(at: index)
    }
}
