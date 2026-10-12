import DailyOSCore
import Foundation

/// Test double for `UndoClock`. Captures every scheduled action instead of
/// waiting on real time, so tests fire the undo window's expiry on demand
/// — the same shape `FakeRefreshClock` already has for its repeating
/// timer. Keeps every action, not just the last: production fires each
/// timer it was given, including one for an offer that has since been
/// replaced, and the guards against those late timers only run if the
/// fake fires them too.
///
/// `@unchecked Sendable`: every test drives this synchronously on one
/// thread, same justification as the other fakes.
final class FakeUndoClock: UndoClock, @unchecked Sendable {
    private(set) var scheduledInterval: TimeInterval?
    private var actions: [@Sendable () -> Void] = []

    func scheduleOnce(after interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        scheduledInterval = interval
        actions.append(action)
    }

    /// Every window still running ends, oldest first, as they would in
    /// production if the test waited them all out.
    func fire() {
        let due = actions
        actions = []
        due.forEach { $0() }
    }

    /// Only the oldest window still running ends.
    func fireOldest() {
        guard !actions.isEmpty else { return }
        actions.removeFirst()()
    }
}
