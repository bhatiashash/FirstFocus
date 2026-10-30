import FirstFocusApp
import FirstFocusCore
import Foundation

/// A task approved from a message is made in the default Reminders list, so
/// unticking that list hides it. Advanced says so beside the list.

private let home = "list-home"
private let work = "list-work"

@MainActor
private func makeModel(preference: FocusListPreference, store: SQLiteSignalStore, taskSource: FakeTaskSource) -> AppModel {
    AppModel(AppDependencies.test { d in
        d.taskSource = taskSource
        d.signalStore = store
        d.focusListPreference = preference
    })
}

private func suggestion() -> Signal {
    Signal(
        id: "s1", source: .messages, sourceRef: "m1", label: "Book the table", originalText: "book the table",
        createdAt: Date(), provenance: .inferred
    )
}

private func fixtures() throws -> (FakeTaskSource, FocusListPreference, SQLiteSignalStore) {
    let taskSource = FakeTaskSource(tasks: [])
    taskSource.addList(id: home, title: "Reminders")
    taskSource.addList(id: work, title: "Work")
    taskSource.defaultList = home
    let preference = FocusListPreference(defaults: UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!)
    let store = makeTestSignalStore()
    try store.markBackfillComplete()
    try store.recordOneMessageBatch("m1", signals: [suggestion()])
    return (taskSource, preference, store)
}

func registerDefaultListTests(_ runner: TestRunner) {
    runner.suite("Default list: where an approved task lands") { r in
        r.run("Advanced marks the default list, and only it") {
            let (taskSource, preference, store) = try fixtures()
            let model = await MainActor.run { makeModel(preference: preference, store: store, taskSource: taskSource) }
            await model.refreshFocusListTicks()
            let marked = await MainActor.run { model.focusListTicks.filter(\.isDefault).map(\.list.title) }
            try expect(marked == ["Reminders"], "got \(marked)")
        }

        r.run("approving with the default list ticked shows the new reminder") {
            let (taskSource, preference, store) = try fixtures()
            let model = await MainActor.run { makeModel(preference: preference, store: store, taskSource: taskSource) }
            await model.start()
            let signal = try await MainActor.run { try require(model.rankedList.suggested.first) }
            await model.approve(signal)
            let labels = await MainActor.run { (model.rankedList.focus + model.rankedList.later).map(\.label) }
            try expect(labels == ["Book the table"], "got \(labels)")
        }

        r.run("approving with the default list unticked still makes the reminder and clears the Suggestion, but hides it") {
            let (taskSource, preference, store) = try fixtures()
            preference.untickedListIds = [home]
            let model = await MainActor.run { makeModel(preference: preference, store: store, taskSource: taskSource) }
            await model.start()
            let signal = try await MainActor.run { try require(model.rankedList.suggested.first) }
            await model.approve(signal)
            try expect(taskSource.tasks.map(\.title) == ["Book the table"], "the reminder exists in Reminders")
            try await MainActor.run {
                try expect(model.rankedList.suggested.isEmpty, "the Suggestion is gone from the Inbox")
                try expect((model.rankedList.focus + model.rankedList.later).isEmpty, "and the new reminder is hidden with its list")
            }
        }
    }
}
