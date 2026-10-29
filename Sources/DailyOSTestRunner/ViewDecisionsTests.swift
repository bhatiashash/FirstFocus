import DailyOSApp
import DailyOSCore
import Foundation

// What the window used to decide on its own and now asks AppModel: when a
// due date is overdue, and which Sections are collapsed.

private final class FakeNow: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
private func makeModel(
    tasks: [ReminderTask] = [], suggestions: [String] = [], clock: FakeNow = FakeNow(Date())
) -> (AppModel, FakeTaskSource) {
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    for (index, label) in suggestions.enumerated() {
        let signal = Signal(
            id: "s\(index + 1)", source: .messages, sourceRef: "m\(index + 1)", label: label, originalText: label,
            createdAt: Date().addingTimeInterval(-Double(index) * 60), provenance: .inferred
        )
        try? store.recordOneMessageBatch("m\(index + 1)", signals: [signal])
    }
    let taskSource = FakeTaskSource(tasks: tasks)
    let model = AppModel(AppDependencies.test { d in
        d.taskSource = taskSource
        d.signalStore = store
        d.now = { clock.date }
    })
    return (model, taskSource)
}

func registerViewDecisionsTests(_ runner: TestRunner) {
    runner.suite("Overdue: one rule for the window and the Morning Brief") { r in
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let today = calendar.startOfDay(for: noon)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        r.run("a date with no time is overdue only once its day has ended") {
            try expect(!isOverdue(today, at: noon), "due today, with no time, isn't overdue at noon")
            try expect(isOverdue(yesterday, at: noon))
        }

        r.run("a date with a time is overdue once the time has passed") {
            try expect(isOverdue(noon.addingTimeInterval(-3 * 3600), at: noon))
            try expect(!isOverdue(noon.addingTimeInterval(3600), at: noon))
        }

        r.run("the Brief marks a reminder due earlier today at a time, and not one due today with no time") {
            let morning = noon.addingTimeInterval(-3 * 3600)
            let list = RankedList(
                focus: [
                    makeSignal(from: ReminderTask(id: "a", title: "Call at 9", dueAt: morning, priority: .none, createdAt: Date())),
                    makeSignal(from: ReminderTask(id: "b", title: "Pay rent", dueAt: today, priority: .none, createdAt: Date())),
                ],
                later: [], suggested: []
            )
            let brief = composeMorningBrief(list, now: noon)
            try expect(brief.contains("Call at 9 (overdue)"), brief)
            try expect(brief.contains("Pay rent") && !brief.contains("Pay rent (overdue)"), brief)
        }

        r.run("AppModel judges a row against the moment the list was ranked") {
            let clock = FakeNow(noon)
            let (model, _) = await MainActor.run {
                makeModel(tasks: [ReminderTask(id: "a", title: "Call", dueAt: noon.addingTimeInterval(3600), priority: .none, createdAt: Date())],
                          clock: clock)
            }
            await model.start()
            try await MainActor.run {
                let row = try require(model.rankedList.focus.first)
                try expect(!model.presentation.isOverdue(row))
                clock.date = noon.addingTimeInterval(2 * 3600)
                try expect(!model.presentation.isOverdue(row), "nothing re-ranked yet, so the row still agrees with the list")
            }
        }
    }

    runner.suite("Sections: collapsing") { r in
        r.run("the Snoozed Section starts collapsed, the Inbox and Later expanded") {
            let (model, _) = await MainActor.run { makeModel() }
            try await MainActor.run {
                try expect(model.isCollapsed(.snoozed))
                try expect(!model.isCollapsed(.inbox) && !model.isCollapsed(.later))
            }
        }

        r.run("a collapsed Inbox takes no keys and drops its focus and preview") {
            let (model, _) = await MainActor.run { makeModel(suggestions: ["Call the dentist", "Book flights"]) }
            await model.start()
            try await MainActor.run {
                try expect(model.pressInboxKey(.down))
            }
            await model.handleInboxKey(.down)
            try await MainActor.run {
                try expect(model.focusedSuggestionId != nil)
                model.toggleCollapse(.inbox)
                try expect(model.focusedSuggestionId == nil && model.previewedSuggestionId == nil)
                for key: AppModel.InboxKey in [.up, .down, .approve, .dismiss, .togglePreview] {
                    try expect(!model.pressInboxKey(key), "\(key) passes through while collapsed")
                }
            }
            await model.handleInboxKey(.down)
            try await MainActor.run {
                try expect(model.focusedSuggestionId == nil)
                try expect(model.rankedList.suggested.count == 2, "nothing was approved or dismissed")
                model.toggleCollapse(.inbox)
                try expect(model.pressInboxKey(.down), "expanded again, it takes keys")
            }
        }

        r.run("a reminder added to a collapsed Later opens it") {
            let (model, _) = await MainActor.run { makeModel() }
            await model.start()
            await MainActor.run { model.toggleCollapse(.later) }
            let tier = await model.addReminder(title: "Renew passport", dueAt: Date().addingTimeInterval(30 * 86400))
            try expect(tier == .later)
            try await MainActor.run { try expect(!model.isCollapsed(.later)) }
        }
    }
}
