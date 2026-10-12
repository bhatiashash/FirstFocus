import DailyOSCore
import Foundation

/// Morning Brief tickets 02–03: sending the Brief, and when.

/// Records what it was asked to send, and answers with `failure` (nil is
/// success). `@unchecked Sendable`: tests drive it from one thread.
final class FakeMessageSender: MessageSender, @unchecked Sendable {
    private(set) var sent: [(text: String, handle: String)] = []
    var failure: MorningBriefSendFailure?

    init(failure: MorningBriefSendFailure? = nil) {
        self.failure = failure
    }

    func send(_ text: String, to handle: String) async -> MorningBriefSendFailure? {
        sent.append((text, handle))
        return failure
    }
}

func morningBriefDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: "dailyos-tests-morning-brief-\(suite)")!
}

/// A settable clock for the main actor.
@MainActor
final class TestNow {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private let calendar = Calendar.current
private func today(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
}

@MainActor
private func makeDelivery(
    sender: FakeMessageSender = FakeMessageSender(), myNumber: String? = "+15550100", enabled: Bool = false,
    at time: Date = today(7, 55), suite: String = UUID().uuidString,
    clock: FakeUndoClock = FakeUndoClock()
) -> (delivery: MorningBriefDelivery, preference: MorningBriefPreference, now: TestNow) {
    let preference = MorningBriefPreference(defaults: morningBriefDefaults(suite))
    preference.isEnabled = enabled
    let now = TestNow(time)
    let delivery = MorningBriefDelivery(
        preference: preference, sender: sender, recipient: { myNumber },
        compose: { "\(morningBriefHeader)\n\nPay rent\n\n(0 in Later)" },
        now: { now.date }, clock: clock
    )
    return (delivery, preference, now)
}

func registerMorningBriefDeliveryTests(_ runner: TestRunner) {
    runner.suite("Morning Brief: a test send") { r in
        r.run("sends the composed Brief to your own number, with the toggle off") {
            let sender = FakeMessageSender()
            let (delivery, _, _) = await MainActor.run { makeDelivery(sender: sender, enabled: false) }
            await delivery.sendTest()
            let status = await delivery.status
            try expect(sender.sent.count == 1)
            try expect(sender.sent.first?.handle == "+15550100")
            try expect(sender.sent.first?.text.hasPrefix(morningBriefHeader) == true)
            try expect(status == .sent(today(7, 55)), "got \(status)")
        }

        r.run("a failure is reported with its reason") {
            let sender = FakeMessageSender(failure: .notAllowed)
            let (delivery, _, _) = await MainActor.run { makeDelivery(sender: sender) }
            await delivery.sendTest()
            let status = await delivery.status
            try expect(status == .failed(today(7, 55), .notAllowed), "got \(status)")
        }

        r.run("with no Self-thread nothing is sent") {
            let sender = FakeMessageSender()
            let (delivery, _, _) = await MainActor.run { makeDelivery(sender: sender, myNumber: nil) }
            await delivery.sendTest()
            try expect(sender.sent.isEmpty)
        }

        r.run("the last outcome survives a relaunch") {
            let suite = UUID().uuidString
            let (first, _, _) = await MainActor.run {
                makeDelivery(sender: FakeMessageSender(failure: .messagesUnavailable), suite: suite)
            }
            await first.sendTest()
            let (second, _, _) = await MainActor.run { makeDelivery(suite: suite) }
            let status = await second.status
            try expect(status == .failed(today(7, 55), .messagesUnavailable), "got \(status)")
        }
    }

    runner.suite("Morning Brief: the daily send") { r in
        r.run("goes out at 8:00 when the toggle is on") {
            let sender = FakeMessageSender()
            let clock = FakeUndoClock()
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, clock: clock) }
            await delivery.start()
            try expect(sender.sent.isEmpty, "nothing before 8:00")
            try expect(clock.scheduledInterval == 300, "got \(String(describing: clock.scheduledInterval))")
            await MainActor.run { now.date = today(8) }
            clock.fire()
            await settleDelivery()
            try expect(sender.sent.count == 1)
        }

        r.run("sends nothing at 8:00 with the toggle off") {
            let sender = FakeMessageSender()
            let clock = FakeUndoClock()
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: false, clock: clock) }
            await delivery.start()
            await MainActor.run { now.date = today(8) }
            clock.fire()
            await settleDelivery()
            try expect(sender.sent.isEmpty)
        }

        r.run("a launch at 9:30 with no Brief yet today sends one") {
            let sender = FakeMessageSender()
            let (delivery, _, _) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(9, 30)) }
            await delivery.start()
            try expect(sender.sent.count == 1)
        }

        r.run("a wake at 9:30 sends, a wake at 12:30 doesn't") {
            let sender = FakeMessageSender()
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(12, 30)) }
            await delivery.systemDidWake()
            try expect(sender.sent.isEmpty, "no Brief after noon")
            await MainActor.run { now.date = today(9, 30) }
            await delivery.systemDidWake()
            try expect(sender.sent.count == 1)
        }

        r.run("a second wake after a Brief went out today sends nothing") {
            let sender = FakeMessageSender()
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(8, 30)) }
            await delivery.systemDidWake()
            await MainActor.run { now.date = today(10) }
            await delivery.systemDidWake()
            try expect(sender.sent.count == 1)
        }

        r.run("a failed send is retried at the next wake before noon") {
            let sender = FakeMessageSender(failure: .messagesUnavailable)
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(8, 30)) }
            await delivery.systemDidWake()
            sender.failure = nil
            await MainActor.run { now.date = today(9) }
            await delivery.systemDidWake()
            await MainActor.run { now.date = today(9, 30) }
            await delivery.systemDidWake()
            try expect(sender.sent.count == 2, "got \(sender.sent.count)")
        }

        r.run("a test send at 7:55 doesn't stop the 8:00 send") {
            let sender = FakeMessageSender()
            let clock = FakeUndoClock()
            let (delivery, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, clock: clock) }
            await delivery.start()
            await delivery.sendTest()
            await MainActor.run { now.date = today(8) }
            clock.fire()
            await settleDelivery()
            try expect(sender.sent.count == 2)
        }

        r.run("yesterday's Brief doesn't count today, and a relaunch remembers today's") {
            let suite = UUID().uuidString
            let sender = FakeMessageSender()
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today(8, 30))!
            let (first, _, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: yesterday, suite: suite) }
            await first.start()
            await MainActor.run { now.date = today(8, 30) }
            await first.systemDidWake()
            let (second, _, _) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(9), suite: suite) }
            await second.start()
            try expect(sender.sent.count == 2, "got \(sender.sent.count)")
        }

        r.run("turning the toggle on before noon sends today's Brief; before 8:00 it waits") {
            let sender = FakeMessageSender()
            let (early, _, _) = await MainActor.run { makeDelivery(sender: sender, enabled: false, at: today(7)) }
            await early.setEnabled(true)
            try expect(sender.sent.isEmpty)
            let (late, preference, _) = await MainActor.run { makeDelivery(sender: sender, enabled: false, at: today(9)) }
            await late.setEnabled(true)
            try expect(sender.sent.count == 1)
            try expect(preference.isEnabled)
        }
    }

    runner.suite("Morning Brief: a send time you choose") { r in
        r.run("the timer is set for the chosen time, and the Brief goes out then") {
            let sender = FakeMessageSender()
            let clock = FakeUndoClock()
            let (delivery, preference, now) = await MainActor.run {
                makeDelivery(sender: sender, enabled: true, at: today(6, 0), clock: clock)
            }
            preference.sendTime = MorningBriefTime(hour: 6, minute: 45)
            await delivery.start()
            try expect(clock.scheduledInterval == 45 * 60, "got \(String(describing: clock.scheduledInterval))")
            await MainActor.run { now.date = today(6, 45) }
            clock.fire()
            await settleDelivery()
            try expect(sender.sent.count == 1)
        }

        r.run("a missed Brief still goes out up to four hours after the chosen time") {
            let sender = FakeMessageSender()
            let (delivery, preference, now) = await MainActor.run { makeDelivery(sender: sender, enabled: true, at: today(11, 31)) }
            preference.sendTime = MorningBriefTime(hour: 7, minute: 30)
            await delivery.systemDidWake()
            try expect(sender.sent.isEmpty, "11:31 is past 7:30 plus four hours")
            await MainActor.run { now.date = today(11, 29) }
            await delivery.systemDidWake()
            try expect(sender.sent.count == 1)
        }

        r.run("changing the time sets the timer again") {
            let clock = FakeUndoClock()
            let (delivery, _, _) = await MainActor.run { makeDelivery(enabled: true, at: today(6, 0), clock: clock) }
            await delivery.start()
            await delivery.setSendTime(MorningBriefTime(hour: 9, minute: 0))
            try expect(clock.scheduledInterval == 3 * 3600, "got \(String(describing: clock.scheduledInterval))")
        }

        r.run("8:00 AM is the default") {
            let (_, preference, _) = await MainActor.run { makeDelivery() }
            try expect(preference.sendTime == MorningBriefTime(hour: 8, minute: 0))
        }
    }
}

/// The 8:00 timer hops to the main actor through a `Task`.
private func settleDelivery() async {
    try? await Task.sleep(nanoseconds: 100_000_000)
}
