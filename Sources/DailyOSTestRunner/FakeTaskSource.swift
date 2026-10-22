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
    /// Every list, by id, with its title. Empty unless a test adds lists:
    /// a task with no `listId` is one the Focus list leaves alone.
    private(set) var lists: [String: String] = [:]
    /// Where `create` puts a new task, and where the Focus list sends one
    /// whose own list is unknown.
    var defaultList: String?
    /// Tasks whose moves fail, standing in for a reminder in another
    /// account than the list.
    var unmovableIds: Set<String> = []
    /// Tasks every edit fails on, standing in for a write Reminders refused.
    var failsUpdates: Set<String> = []

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

    func addList(id: String, title: String) {
        lists[id] = title
    }

    func removeList(id: String) {
        lists[id] = nil
    }

    func ensureList(id: String?, title: String) throws -> String {
        if let id, lists[id] != nil { return id }
        if let existing = lists.first(where: { $0.value == title })?.key { return existing }
        let created = "list-\(nextId)"
        nextId += 1
        lists[created] = title
        return created
    }

    func defaultListId() -> String? {
        defaultList
    }

    func create(_ draft: ReminderDraft) throws -> ReminderTask {
        let task = ReminderTask(
            id: "fake-\(nextId)",
            title: draft.title,
            dueAt: draft.dueAt,
            priority: draft.priority,
            createdAt: Date(),
            notes: draft.notes,
            url: draft.url,
            listId: defaultList
        )
        nextId += 1
        tasks.append(task)
        return task
    }

    func update(id: String, _ edit: ReminderEdit) throws {
        guard !failsUpdates.contains(id) else { throw TaskSourceError.taskNotFound(id: id) }
        // EventKit moves a completed reminder as readily as an open one.
        if case .list(let newListId) = edit, let index = checkedOff.firstIndex(where: { $0.id == id }) {
            guard lists[newListId] != nil else { throw TaskSourceError.listNotFound(id: newListId) }
            let done = checkedOff[index]
            let task = done.task
            checkedOff[index] = CheckedOffReminder(
                task: ReminderTask(
                    id: task.id, title: task.title, dueAt: task.dueAt, priority: task.priority, createdAt: task.createdAt,
                    notes: task.notes, url: task.url, listId: newListId
                ),
                checkedOffAt: done.checkedOffAt, isRecurring: done.isRecurring
            )
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        let task = tasks[index]
        var title = task.title
        var priority = task.priority
        var dueAt = task.dueAt
        var listId = task.listId
        switch edit {
        case .title(let newTitle): title = newTitle
        case .priority(let newPriority): priority = newPriority
        case .dueDate(let newDueAt): dueAt = newDueAt
        case .list(let newListId):
            guard lists[newListId] != nil else { throw TaskSourceError.listNotFound(id: newListId) }
            guard !unmovableIds.contains(id) else { throw TaskSourceError.taskNotFound(id: id) }
            listId = newListId
        }
        tasks[index] = ReminderTask(
            id: task.id, title: title, dueAt: dueAt, priority: priority, createdAt: task.createdAt,
            notes: task.notes, url: task.url, listId: listId
        )
    }

    func delete(id: String) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskSourceError.taskNotFound(id: id)
        }
        tasks.remove(at: index)
    }
}
