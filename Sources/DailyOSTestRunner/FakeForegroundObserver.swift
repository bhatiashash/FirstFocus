import DailyOSCore
import Foundation

/// Test double for `ForegroundObserver`. Captures the handler instead of
/// subscribing to `NSApplication.didBecomeActiveNotification`, so tests
/// fire the foreground trigger without a running application.
final class FakeForegroundObserver: ForegroundObserver {
    private var handler: (@Sendable () -> Void)?

    func onForeground(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}
