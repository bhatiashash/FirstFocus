import DailyOSApp
import DailyOSCore
import Foundation

/// Morning Brief tickets 02–03: Advanced's Morning Brief section, driven
/// through its view model with a fake sender and a fake Self-thread.

@MainActor
private func makeViewModel(
    suite: String = UUID().uuidString, sender: FakeMessageSender = FakeMessageSender(), selfThread: SelfThread = SelfThread(),
    at time: Date = Date()
) -> MorningBriefViewModel {
    let preference = MorningBriefPreference(defaults: morningBriefDefaults(suite))
    let delivery = MorningBriefDelivery(
        preference: preference, sender: sender, recipient: { selfThread.number }, compose: { morningBriefHeader },
        now: { time }, alarm: FakeAlarm()
    )
    let list = RankedList(
        focus: ["A", "B", "C", "D"].map {
            Signal(id: $0, source: .reminders, sourceRef: $0, label: $0, originalText: $0, createdAt: time, provenance: .stated)
        },
        later: [], suggested: []
    )
    return MorningBriefViewModel(
        delivery: delivery, preference: preference, myNumber: { selfThread.number },
        preview: { composeMorningBrief(list, now: time, format: $0) }
    )
}

/// Your Self-thread address, which a test can change.
@MainActor
final class SelfThread {
    var number: String?
    init(_ number: String? = "+15550100") { self.number = number }
}

func registerMorningBriefViewModelTests(_ runner: TestRunner) {
    runner.suite("Morning Brief: Advanced's section") { r in
        r.run("the Brief goes to your Self-thread, and it can't be changed here") {
            let selfThread = await MainActor.run { SelfThread("+15550100") }
            try await MainActor.run {
                let viewModel = makeViewModel(selfThread: selfThread)
                try expect(viewModel.myNumber == "+15550100")
                try expect(viewModel.canSend && viewModel.canEnable)
            }
        }

        r.run("with no Self-thread nothing can be sent, until one appears") {
            let selfThread = await MainActor.run { SelfThread(nil) }
            try await MainActor.run {
                let viewModel = makeViewModel(selfThread: selfThread)
                try expect(viewModel.myNumber == nil)
                try expect(!viewModel.canSend && !viewModel.canEnable)
                selfThread.number = "+15550100"
                viewModel.refresh()
                try expect(viewModel.myNumber == "+15550100" && viewModel.canSend)
            }
        }

        r.run("the status line reports a send and each kind of failure") {
            let sender = FakeMessageSender()
            let viewModel = await MainActor.run { makeViewModel(sender: sender, selfThread: SelfThread("+15550100")) }
            try await MainActor.run { try expect(viewModel.statusText == nil) }
            await viewModel.sendTest()
            try await MainActor.run {
                try expect(viewModel.statusText?.hasPrefix("Last sent today at ") == true, "got \(String(describing: viewModel.statusText))")
            }
            sender.failure = .notAllowed
            await viewModel.sendTest()
            try await MainActor.run {
                try expect(viewModel.statusText?.contains("isn't allowed to control Messages") == true,
                           "got \(String(describing: viewModel.statusText))")
            }
            sender.failure = .messagesUnavailable
            await viewModel.sendTest()
            try await MainActor.run {
                try expect(viewModel.statusText?.contains("signed in") == true, "got \(String(describing: viewModel.statusText))")
            }
        }

        r.run("the toggle turns the daily send on") {
            let sender = FakeMessageSender()
            let suite = UUID().uuidString
            let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let viewModel = await MainActor.run {
                makeViewModel(suite: suite, sender: sender, selfThread: SelfThread("+15550100"), at: morning)
            }
            try await MainActor.run { try expect(!viewModel.isEnabled) }
            await viewModel.setEnabled(true)
            try await MainActor.run {
                try expect(viewModel.isEnabled)
                try expect(MorningBriefPreference(defaults: morningBriefDefaults(suite)).isEnabled)
            }
            try expect(sender.sent.count == 1, "turning it on at 9:00 sends today's Brief")
        }

        r.run("the format starts as the standard one, and an edit is kept and shown in the preview") {
            let suite = UUID().uuidString
            try await MainActor.run {
                let viewModel = makeViewModel(suite: suite)
                try expect(viewModel.format == .standard)
                viewModel.format.limit = 2
                viewModel.format.itemLine = "- {label}"
                try expect(viewModel.preview.contains("\n- A\n- B\n+2 more in Focus\n"), "got\n\(viewModel.preview)")
                let reopened = makeViewModel(suite: suite)
                try expect(reopened.format.limit == 2 && reopened.format.itemLine == "- {label}")
            }
        }

        r.run("Reset to Default puts the standard format back") {
            try await MainActor.run {
                let viewModel = makeViewModel()
                viewModel.format.body = "{top}"
                viewModel.resetFormat()
                try expect(viewModel.format == .standard)
            }
        }

        r.run("the send time starts at 8:00 AM and a new one is kept") {
            let suite = UUID().uuidString
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            try await MainActor.run { try expect(viewModel.sendTime == .standard) }
            await viewModel.setSendTime(MorningBriefTime(hour: 6, minute: 30))
            try await MainActor.run {
                try expect(viewModel.sendTime == MorningBriefTime(hour: 6, minute: 30))
                try expect(makeViewModel(suite: suite).sendTime == MorningBriefTime(hour: 6, minute: 30))
            }
        }
    }
}
