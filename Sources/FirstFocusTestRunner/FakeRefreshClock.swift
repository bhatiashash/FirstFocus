import FirstFocusCore
import Foundation

/// Test double for `RefreshClock`. Captures the scheduled action instead of
/// starting a real timer, so tests fire the interval trigger on demand
/// rather than waiting on real time.
final class FakeRefreshClock: RefreshClock {
    private(set) var scheduledInterval: TimeInterval?
    private var action: (@Sendable () -> Void)?

    func scheduleRepeating(interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        scheduledInterval = interval
        self.action = action
    }

    func fire() {
        action?()
    }
}
