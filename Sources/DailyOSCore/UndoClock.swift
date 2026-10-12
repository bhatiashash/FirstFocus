import Foundation

/// The one-shot timer `UndoBar` schedules the undo window
/// through. A protocol, not a direct `Task.sleep` call, so a test can
/// fire the expiry on demand instead of waiting on real time — the same
/// reason `RefreshClock` exists for `RefreshCoordinator`'s repeating
/// timer, just one-shot instead of repeating.
public protocol UndoClock: Sendable {
    /// Calls `action` once, after `interval` seconds have passed.
    func scheduleOnce(after interval: TimeInterval, _ action: @escaping @Sendable () -> Void)
}

/// Production `UndoClock`, backed by `Task.sleep`.
public final class TaskSleepUndoClock: UndoClock {
    public init() {}

    public func scheduleOnce(after interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            action()
        }
    }
}
