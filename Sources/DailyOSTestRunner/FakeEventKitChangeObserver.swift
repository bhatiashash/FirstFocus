import DailyOSCore
import Foundation

/// Test double for `EventKitChangeObserver`. Captures the handler instead of
/// subscribing to a real `.EKEventStoreChanged` notification, so tests fire
/// the change-notification trigger without a real EventKit connection.
final class FakeEventKitChangeObserver: EventKitChangeObserver {
    private var handler: (@Sendable () -> Void)?

    func onChange(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}
