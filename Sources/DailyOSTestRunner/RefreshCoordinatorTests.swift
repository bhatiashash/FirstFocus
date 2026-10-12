import DailyOSCore
import Foundation

/// `@unchecked Sendable`: every call in these tests happens synchronously
/// on the same thread (`RefreshCoordinator`'s init calls `clock`/
/// `eventKitChanges` synchronously, and `foregroundBecameActive()` is called
/// directly), so there's no real concurrent access for `Sendable` to guard
/// against here — same justification as `ProgressRecorder`.
private final class TriggerRecorder: @unchecked Sendable {
    private(set) var received: [RefreshTrigger] = []

    func record(_ trigger: RefreshTrigger) {
        received.append(trigger)
    }
}

func registerRefreshCoordinatorTests(_ runner: TestRunner) {
    runner.suite("RefreshCoordinator") { r in
        r.run("schedules the interval on the given clock") {
            let clock = FakeRefreshClock()
            let recorder = TriggerRecorder()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: clock,
                eventKitChanges: FakeEventKitChangeObserver(),
                onRefresh: recorder.record
            )
            try expect(clock.scheduledInterval == 30)
        }

        r.run("the interval trigger reaches onRefresh as .interval") {
            let clock = FakeRefreshClock()
            let recorder = TriggerRecorder()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: clock,
                eventKitChanges: FakeEventKitChangeObserver(),
                onRefresh: recorder.record
            )
            clock.fire()
            try expect(recorder.received == [.interval])
        }

        r.run("the change-notification trigger reaches onRefresh as .eventKitChange") {
            let eventKitChanges = FakeEventKitChangeObserver()
            let recorder = TriggerRecorder()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: eventKitChanges,
                onRefresh: recorder.record
            )
            eventKitChanges.fire()
            try expect(recorder.received == [.eventKitChange])
        }

        r.run("every change notification fires immediately with no coalescing") {
            let eventKitChanges = FakeEventKitChangeObserver()
            let recorder = TriggerRecorder()
            _ = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: eventKitChanges,
                onRefresh: recorder.record
            )
            eventKitChanges.fire()
            eventKitChanges.fire()
            eventKitChanges.fire()
            try expect(recorder.received == [.eventKitChange, .eventKitChange, .eventKitChange])
        }

        r.run("the foreground trigger reaches onRefresh as .foreground") {
            let recorder = TriggerRecorder()
            let coordinator = RefreshCoordinator(
                pollInterval: 30,
                clock: FakeRefreshClock(),
                eventKitChanges: FakeEventKitChangeObserver(),
                onRefresh: recorder.record
            )
            coordinator.foregroundBecameActive()
            try expect(recorder.received == [.foreground])
        }

        r.run("all three triggers converge on the same onRefresh callback") {
            let clock = FakeRefreshClock()
            let eventKitChanges = FakeEventKitChangeObserver()
            let recorder = TriggerRecorder()
            let coordinator = RefreshCoordinator(
                pollInterval: 30,
                clock: clock,
                eventKitChanges: eventKitChanges,
                onRefresh: recorder.record
            )
            clock.fire()
            eventKitChanges.fire()
            coordinator.foregroundBecameActive()
            try expect(recorder.received == [.interval, .eventKitChange, .foreground])
        }
    }

    runner.suite("sourcesToRefresh") { r in
        r.run("the interval trigger means Messages only, never Reminders") {
            try expect(sourcesToRefresh(for: .interval) == [.messages], "ticket 11: Reminders already has its own free push")
        }

        r.run("the eventKitChange trigger means Reminders only, never Messages") {
            try expect(sourcesToRefresh(for: .eventKitChange) == [.reminders], "a Reminders refresh must never touch the Messages model")
        }

        r.run("the foreground trigger means both") {
            try expect(sourcesToRefresh(for: .foreground) == [.reminders, .messages], "either Gate could have changed while the window was in the background")
        }
    }
}
