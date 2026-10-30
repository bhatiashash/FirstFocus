import FirstFocusApp
import FirstFocusCore
import Foundation

/// The Morning Brief as the app wires it (ADR 0046): AppModel builds the
/// delivery from its dependencies, the same way the executable does.

private let calendar = Calendar.current
private func today(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
}

@MainActor
private func makeModel(
    sender: FakeMessageSender, enabled: Bool, now: TestNow, address: String? = "+15550100"
) -> AppModel {
    let store = makeTestSignalStore()
    try? store.markBackfillComplete()
    let preference = MorningBriefPreference(defaults: morningBriefDefaults())
    preference.isEnabled = enabled
    return AppModel(AppDependencies.test { d in
        d.taskSource = FakeTaskSource(tasks: [
            ReminderTask(id: "r1", title: "Pay rent", dueAt: nil, priority: .high, createdAt: now.date),
        ])
        d.signalStore = store
        d.now = { now.date }
        d.morningBriefPreference = preference
        d.morningBriefSender = sender
        d.selfThreadAddress = { address }
    })
}

func registerMorningBriefWiringTests(_ runner: TestRunner) {
    runner.suite("Morning Brief: wired through AppModel") { r in
        r.run("a Brief missed this morning goes out once the stored list is ready") {
            let sender = FakeMessageSender()
            let now = await MainActor.run { TestNow(today(9)) }
            let model = await MainActor.run { makeModel(sender: sender, enabled: true, now: now) }
            await model.start()
            await model.morningBriefSettled()
            try expect(sender.sent.count == 1, "got \(sender.sent.count)")
            try expect(sender.sent.first?.handle == "+15550100")
            try expect(sender.sent.first?.text.contains("\nPay rent\n") == true, "got \(sender.sent.first?.text ?? "")")
        }

        r.run("with the toggle off nothing goes out at launch") {
            let sender = FakeMessageSender()
            let now = await MainActor.run { TestNow(today(9)) }
            let model = await MainActor.run { makeModel(sender: sender, enabled: false, now: now) }
            await model.start()
            await model.morningBriefSettled()
            try expect(sender.sent.isEmpty)
        }

        r.run("waking from sleep sends a Brief missed while asleep, and only one a day") {
            let sender = FakeMessageSender()
            let now = await MainActor.run { TestNow(today(7)) }
            let model = await MainActor.run { makeModel(sender: sender, enabled: true, now: now) }
            await model.start()
            await model.morningBriefSettled()
            try expect(sender.sent.isEmpty, "not due at 7:00")
            await MainActor.run { now.date = today(8, 30) }
            await model.systemDidWake()
            try expect(sender.sent.count == 1)
            await model.systemDidWake()
            try expect(sender.sent.count == 1, "already sent today")
        }

        r.run("the view model sends a test Brief to the Self-thread address") {
            let sender = FakeMessageSender()
            let now = await MainActor.run { TestNow(today(7)) }
            let model = await MainActor.run { makeModel(sender: sender, enabled: false, now: now, address: "+15550142") }
            await model.morningBriefViewModel.sendTest()
            try expect(sender.sent.first?.handle == "+15550142")
        }
    }
}
