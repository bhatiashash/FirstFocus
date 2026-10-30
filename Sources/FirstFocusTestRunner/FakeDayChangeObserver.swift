import FirstFocusCore
import Foundation

/// Test double for `DayChangeObserver`. Captures the handler instead of
/// subscribing to `NSCalendarDayChanged`, so tests fire midnight on demand.
final class FakeDayChangeObserver: DayChangeObserver, @unchecked Sendable {
    private var handler: (@Sendable () -> Void)?

    func onDayChange(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}
