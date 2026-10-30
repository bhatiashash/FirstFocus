import FirstFocusCore
import Foundation

/// Test double for `Alarm`. Keeps the one pending action instead of
/// waiting on real time; `fire()` runs it inline, so a test awaits the
/// action itself and never sleeps for it.
@MainActor
final class FakeAlarm: Alarm {
    /// When the pending action is set for, `nil` with none pending.
    private(set) var pending: Date?
    private var action: (@MainActor () async -> Void)?

    nonisolated init() {}

    var isPending: Bool { pending != nil }

    func schedule(at deadline: Date, _ action: @escaping @MainActor () async -> Void) {
        pending = deadline
        self.action = action
    }

    func cancel() {
        pending = nil
        action = nil
    }

    /// Runs the pending action, as its deadline arriving would. Does
    /// nothing with none pending.
    func fire() async {
        guard let action else { return }
        cancel()
        await action()
    }
}
