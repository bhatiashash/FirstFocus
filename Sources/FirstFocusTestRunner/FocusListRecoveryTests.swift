import FirstFocusCore
import Foundation
import SQLite3

private final class RecoveryStore: FocusListStore, @unchecked Sendable {
    let sqlite: SQLiteSignalStore
    let source: FakeTaskSource
    var failAfterMove = true
    var failEveryWrite = false
    var failReads = false
    var removeDestinationAfterPrepare: String?
    var reads = 0
    var writes = 0

    init(sqlite: SQLiteSignalStore, source: FakeTaskSource) {
        self.sqlite = sqlite
        self.source = source
    }

    func focusListPlacements() -> [FocusListPlacement]? {
        reads += 1
        return failReads ? nil : sqlite.focusListPlacements()
    }

    func setFocusListPlacements(_ placements: [FocusListPlacement]) throws {
        writes += 1
        if failEveryWrite || (failAfterMove && source.tasks.first?.listId == "focus") {
            throw SignalStoreError.writeFailed
        }
        try sqlite.setFocusListPlacements(placements)
        if let destination = removeDestinationAfterPrepare,
           placements.contains(where: { $0.pendingMove?.toListId == destination }) {
            source.removeList(id: destination)
            removeDestinationAfterPrepare = nil
        }
    }
}

@MainActor
private final class RecoveryHarness {
    let path = testStorePath()
    let source = FakeTaskSource(tasks: [ReminderTask(
        id: "a", title: "a", dueAt: nil, priority: .high, createdAt: Date(), listId: "work"
    )])
    let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
    let store: RecoveryStore
    var board: SignalBoard
    let snoozes: Snoozes
    var focus: FocusList

    init() {
        source.addList(id: "focus", title: "Focus")
        source.addList(id: "work", title: "Work")
        source.addList(id: "home", title: "Reminders")
        source.defaultList = "home"
        preference.listId = "focus"
        let sqlite = SQLiteSignalStore(path: path)
        store = RecoveryStore(sqlite: sqlite, source: source)
        snoozes = Snoozes(store: sqlite)
        board = SignalBoard(taskSource: source, signalStore: sqlite, snoozes: snoozes)
        focus = FocusList(taskSource: source, store: store, board: board, snoozes: snoozes, preference: preference)
    }

    func sync(fetch: Bool = true) async {
        if fetch { await board.refreshReminders() }
        focus.listDerived(at: Date())
        await focus.settled()
    }

    func restart() {
        let sqlite = SQLiteSignalStore(path: path)
        board = SignalBoard(taskSource: source, signalStore: sqlite, snoozes: snoozes)
        focus = FocusList(taskSource: source, store: sqlite, board: board,
                          snoozes: snoozes, preference: preference)
    }

    func seedPending(from: String = "work", to: String = "focus", home: String = "work") throws {
        try store.sqlite.setFocusListPlacements([FocusListPlacement(
            reminderId: "a", homeListId: home,
            pendingMove: FocusListPendingMove(fromListId: from, toListId: to)
        )])
    }

    func executeFixture(_ sql: String) throws {
        var database: OpaquePointer?
        try expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
}

func registerFocusListRecoveryTests(_ runner: TestRunner) {
    runner.suite("Focus list durable recovery") { suite in
        suite.run("a destination deleted after preparation cannot cause an unjournaled fallback move") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                harness.store.failAfterMove = false
                try harness.source.update(id: "a", .list("focus"))
                try harness.store.sqlite.setFocusListPlacements([
                    FocusListPlacement(reminderId: "a", homeListId: "work")
                ])
                harness.preference.isEnabled = false
                harness.store.removeDestinationAfterPrepare = "work"
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus", "only the durable destination may be used")
                try expect(harness.focus.failure == .reminders)
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "home")
                try expect(harness.focus.failure == nil)
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("a successful move survives failed finalization and restart with its original home") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                harness.restart()
                harness.preference.isEnabled = false
            }
            await harness.sync()
            try await MainActor.run { try expect(harness.source.tasks.first?.listId == "work", "original home must survive") }
        }

        suite.run("a failed home prewrite prevents the reminder move") {
            let harness = await MainActor.run { RecoveryHarness() }
            await MainActor.run { harness.store.failEveryWrite = true }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.focus.failure == .persistenceWrite)
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("a real SQLite prewrite abort rolls back its deletion and prevents moving") {
            let harness = await MainActor.run { RecoveryHarness() }
            let existing = FocusListPlacement(reminderId: "other", homeListId: "home")
            try await MainActor.run {
                try harness.store.sqlite.setFocusListPlacements([existing])
                try harness.executeFixture("CREATE TRIGGER reject_focus_write BEFORE INSERT ON focus_list BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.focus.failure == .persistenceWrite)
                try expect(harness.store.sqlite.focusListPlacements() == [existing])
            }
        }

        suite.run("a real SQLite finalization abort retains the committed movement journal") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                try harness.store.sqlite.setFocusListPlacements([])
                try harness.executeFixture("CREATE TRIGGER reject_focus_finalization BEFORE INSERT ON focus_list WHEN NEW.pending_from_list_id IS NULL BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(harness.focus.failure == .persistenceWrite)
                let pending = try require(harness.store.sqlite.focusListPlacements()?.first)
                try expect(pending.homeListId == "work")
                try expect(pending.pendingMove == FocusListPendingMove(fromListId: "work", toListId: "focus"))
                try harness.executeFixture("DROP TRIGGER reject_focus_finalization;")
                harness.preference.isEnabled = false
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run { try expect(harness.source.tasks.first?.listId == "work") }
        }

        suite.run("a pending app intent before its move is not manual Move to Later after restart") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run { try harness.seedPending(); harness.restart() }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(harness.source.tasks.first?.priority == .high)
                try expect(harness.store.sqlite.focusListPlacements() == [FocusListPlacement(reminderId: "a", homeListId: "work")])
            }
        }

        suite.run("a recovered app move is never reinterpreted as manual promotion") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run {
                try harness.source.update(id: "a", .priority(.none))
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.source.tasks.first?.priority == Priority.none)
            }
        }

        suite.run("a newer manual move to another list wins while recovering") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run {
                try harness.source.update(id: "a", .list("home"))
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "home")
                try expect(harness.source.tasks.first?.priority == Priority.none)
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("a newer manual home survives recovery when a due date keeps the reminder in Focus") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run {
                try harness.source.update(id: "a", .dueDate(Date().addingTimeInterval(-3600)))
                try harness.source.update(id: "a", .list("home"))
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(harness.store.sqlite.focusListPlacements()?.first?.homeListId == "home")
                harness.focus.isEnabled = false
            }
            await harness.focus.settled()
            try await MainActor.run { try expect(harness.source.tasks.first?.listId == "home") }
        }

        suite.run("disabling Focus before a pending entry executes leaves its original list and priority alone") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                try harness.seedPending()
                harness.restart()
                harness.preference.isEnabled = false
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.source.tasks.first?.priority == .high)
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("completion during entry recovery restores the known home") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run { try harness.source.complete(id: "a"); harness.restart() }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.checkedOff.first?.task.listId == "work")
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("deletion during entry recovery removes the durable intent") {
            let harness = await MainActor.run { RecoveryHarness() }
            await harness.sync()
            try await MainActor.run { try harness.source.delete(id: "a"); harness.restart() }
            await harness.sync()
            try await MainActor.run { try expect(harness.store.sqlite.focusListPlacements() == []) }
        }

        suite.run("a pending return that already executed is not a manual Move to Later") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                try harness.seedPending(from: "focus", to: "work")
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.priority == .high)
                try expect(harness.source.tasks.first?.listId == "focus")
            }
        }

        suite.run("a real SQLite return finalization failure survives restart without manual demotion") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                try harness.source.update(id: "a", .list("focus"))
                try harness.store.sqlite.setFocusListPlacements([FocusListPlacement(reminderId: "a", homeListId: "work")])
                try harness.executeFixture("CREATE TRIGGER reject_return_finalization BEFORE DELETE ON focus_list WHEN OLD.pending_from_list_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
                harness.preference.isEnabled = false
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.focus.failure == .persistenceWrite)
                try expect(harness.store.sqlite.focusListPlacements()?.first?.pendingMove == FocusListPendingMove(fromListId: "focus", toListId: "work"))
                try harness.executeFixture("DROP TRIGGER reject_return_finalization;")
                harness.preference.isEnabled = true
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(harness.source.tasks.first?.priority == .high)
                try expect(harness.store.sqlite.focusListPlacements() == [FocusListPlacement(reminderId: "a", homeListId: "work")])
            }
        }

        suite.run("a pending return before its move still restores the known home with Focus disabled") {
            let harness = await MainActor.run { RecoveryHarness() }
            try await MainActor.run {
                try harness.source.update(id: "a", .list("focus"))
                try harness.seedPending(from: "focus", to: "work")
                harness.preference.isEnabled = false
                harness.restart()
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.store.sqlite.focusListPlacements() == [])
            }
        }

        suite.run("a reminder write failure notifies once and waits for an external fetch to retry") {
            let harness = await MainActor.run { RecoveryHarness() }
            let notifications = await MainActor.run {
                let notifications = RecoveryNotifications()
                harness.store.failAfterMove = false
                harness.source.failsUpdates = ["a"]
                harness.focus.onChange = {
                    notifications.count += 1
                    harness.focus.listDerived(at: Date())
                }
                return notifications
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.focus.failure == .reminders)
                try expect(notifications.count == 1)
                try expect(harness.store.writes == 2)
                harness.source.failsUpdates = []
            }
            await harness.sync(fetch: false)
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.store.writes == 2)
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.focus.failure == nil)
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(notifications.count == 2)
            }
        }

        suite.run("persistence failure notifies once and retries only after a new fetch") {
            let harness = await MainActor.run { RecoveryHarness() }
            let notifications = await MainActor.run {
                let notifications = RecoveryNotifications()
                harness.store.failEveryWrite = true
                harness.focus.onChange = {
                    notifications.count += 1
                    harness.focus.listDerived(at: Date())
                }
                return notifications
            }
            await harness.sync()
            await harness.sync(fetch: false)
            try await MainActor.run {
                try expect(harness.store.writes == 1)
                try expect(notifications.count == 1)
                harness.store.failEveryWrite = false
                harness.store.failAfterMove = false
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(harness.focus.failure == nil)
                try expect(notifications.count == 2)
            }
        }

        suite.run("failed finalization does not spin after its own refresh or rederive") {
            let harness = await MainActor.run { RecoveryHarness() }
            let notifications = await MainActor.run {
                let notifications = RecoveryNotifications()
                harness.focus.onChange = {
                    notifications.count += 1
                    harness.focus.listDerived(at: Date())
                }
                return notifications
            }
            await harness.sync()
            await harness.sync(fetch: false)
            try await MainActor.run {
                try expect(harness.store.writes == 2)
                try expect(notifications.count == 1)
                try expect(harness.focus.failure == .persistenceWrite)
                try expect(harness.store.sqlite.focusListPlacements()?.first?.pendingMove != nil)
                harness.store.failAfterMove = false
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.focus.failure == nil)
                try expect(notifications.count == 2)
                try expect(harness.store.sqlite.focusListPlacements()?.first?.pendingMove == nil)
            }
        }

        suite.run("an unreadable placement record reports once without moving or re-reading the same fetch") {
            let harness = await MainActor.run { RecoveryHarness() }
            let notifications = await MainActor.run {
                let notifications = RecoveryNotifications()
                harness.store.failReads = true
                harness.focus.onChange = {
                    notifications.count += 1
                    harness.focus.listDerived(at: Date())
                }
                return notifications
            }
            await harness.sync()
            await harness.sync(fetch: false)
            try await MainActor.run {
                try expect(harness.focus.failure == .persistenceRead)
                try expect(harness.source.tasks.first?.listId == "work")
                try expect(harness.store.reads == 1)
                try expect(notifications.count == 1)
                harness.store.failReads = false
                harness.store.failAfterMove = false
            }
            await harness.sync()
            try await MainActor.run {
                try expect(harness.focus.failure == nil)
                try expect(harness.source.tasks.first?.listId == "focus")
                try expect(notifications.count == 2)
            }
        }

        suite.run("legacy placements migrate without losing known homes") {
            let path = testStorePath()
            var database: OpaquePointer?
            try expect(sqlite3_open(path, &database) == SQLITE_OK)
            try expect(sqlite3_exec(database, "CREATE TABLE focus_list (reminder_id TEXT PRIMARY KEY, home_list_id TEXT); INSERT INTO focus_list VALUES ('a', 'work');", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
            let store = SQLiteSignalStore(path: path)
            try expect(store.focusListPlacements() == [FocusListPlacement(reminderId: "a", homeListId: "work")])
            let pending = FocusListPlacement(reminderId: "a", homeListId: "work", pendingMove: FocusListPendingMove(fromListId: "work", toListId: "focus"))
            try store.setFocusListPlacements([pending])
            try expect(SQLiteSignalStore(path: path).focusListPlacements() == [pending])
        }
    }
}

@MainActor
private final class RecoveryNotifications {
    var count = 0
}
