import DailyOSCore
import Foundation

// alarm: the one-shot timer every user schedules through. The fake is what
// the other tests drive; the production alarm is checked against real
// time, briefly.

private final class Ran: @unchecked Sendable {
    var names: [String] = []
}

/// Waits for `ran` to hold `count` names, up to a second.
private func waitFor(_ count: Int, in ran: Ran) async {
    for _ in 0..<100 where await MainActor.run(body: { ran.names.count }) < count {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func registerAlarmTests(_ runner: TestRunner) {
    runner.suite("FakeAlarm") { r in
        r.run("fire runs the pending action and clears it") {
            let alarm = FakeAlarm()
            let ran = Ran()
            let at = Date(timeIntervalSince1970: 1_000)
            try await MainActor.run {
                alarm.schedule(at: at) { ran.names.append("a") }
                try expect(alarm.pending == at)
                try expect(alarm.isPending)
            }
            await alarm.fire()
            try await MainActor.run {
                try expect(ran.names == ["a"])
                try expect(!alarm.isPending)
            }
        }

        r.run("scheduling replaces what was pending") {
            let alarm = FakeAlarm()
            let ran = Ran()
            await MainActor.run {
                alarm.schedule(at: Date()) { ran.names.append("old") }
                alarm.schedule(at: Date()) { ran.names.append("new") }
            }
            await alarm.fire()
            await alarm.fire()
            try expect(ran.names == ["new"])
        }

        r.run("cancel drops the pending action, and fire then does nothing") {
            let alarm = FakeAlarm()
            let ran = Ran()
            await MainActor.run {
                alarm.schedule(at: Date()) { ran.names.append("a") }
                alarm.cancel()
            }
            await alarm.fire()
            try expect(ran.names.isEmpty)
        }
    }

    runner.suite("WallClockAlarm") { r in
        r.run("a deadline already past fires at once") {
            let ran = Ran()
            let alarm = await MainActor.run { WallClockAlarm() }
            await MainActor.run { alarm.schedule(at: Date().addingTimeInterval(-60)) { ran.names.append("past") } }
            await waitFor(1, in: ran)
            try expect(ran.names == ["past"])
            try await MainActor.run { try expect(!alarm.isPending) }
        }

        r.run("a replaced action never runs") {
            let ran = Ran()
            let alarm = await MainActor.run { WallClockAlarm() }
            await MainActor.run {
                alarm.schedule(at: Date().addingTimeInterval(0.05)) { ran.names.append("old") }
                alarm.schedule(at: Date().addingTimeInterval(0.1)) { ran.names.append("new") }
            }
            await waitFor(1, in: ran)
            try? await Task.sleep(nanoseconds: 100_000_000)
            try expect(ran.names == ["new"])
        }

        r.run("a cancelled action never runs") {
            let ran = Ran()
            let alarm = await MainActor.run { WallClockAlarm() }
            await MainActor.run {
                alarm.schedule(at: Date().addingTimeInterval(0.05)) { ran.names.append("a") }
                alarm.cancel()
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            try expect(ran.names.isEmpty)
        }

        r.run("it checks the wall clock in steps, so a deadline passed meanwhile fires at the next step") {
            let ran = Ran()
            final class Clock: @unchecked Sendable { var now = Date() }
            let clock = Clock()
            let alarm = await MainActor.run { WallClockAlarm(step: 0.02, now: { clock.now }) }
            await MainActor.run {
                alarm.schedule(at: clock.now.addingTimeInterval(3600)) { ran.names.append("woke") }
            }
            clock.now = clock.now.addingTimeInterval(7200)
            await waitFor(1, in: ran)
            try expect(ran.names == ["woke"], "an hour slept through fires at the next check, not an hour later")
        }
    }
}
