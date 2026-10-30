import Foundation

/// A one-shot timer with at most one action pending (alarm). Scheduling
/// replaces whatever was pending, so a user never keeps a token to ignore
/// a stale timer, and the action runs on the main actor, so no user hops
/// there itself. The Undo bar, the Morning Brief, Intake's batch wake-up,
/// the snooze wake-up and the Messages refresh debounce each hold one.
@MainActor
public protocol Alarm: AnyObject, Sendable {
    /// Runs `action` at `deadline`, in place of anything pending.
    func schedule(at deadline: Date, _ action: @escaping @MainActor () async -> Void)
    /// Drops the pending action, if any.
    func cancel()
    /// Whether an action is waiting to run. False once it has started.
    var isPending: Bool { get }
}

/// The production `Alarm`. Waits in steps of at most `step` seconds and
/// checks the wall clock after each, so a deadline the Mac slept through
/// fires within one step of waking rather than after however long the
/// sleep was: `Task.sleep` counts no time asleep.
@MainActor
public final class WallClockAlarm: Alarm {
    private let step: TimeInterval
    private let now: @MainActor () -> Date
    private var waiting: Task<Void, Never>?
    /// Rises with every schedule and cancel, so a wait that was replaced
    /// never runs its action, even if it wakes before seeing the cancel.
    private var generation = 0

    public nonisolated init(step: TimeInterval = 60, now: @escaping @MainActor () -> Date = { Date() }) {
        self.step = step
        self.now = now
    }

    public var isPending: Bool { waiting != nil }

    public func schedule(at deadline: Date, _ action: @escaping @MainActor () async -> Void) {
        cancel()
        let generation = self.generation
        let step = self.step
        waiting = Task { [weak self] in
            // Holds the alarm only while checking, never across a sleep.
            while let remaining = self.flatMap({ $0.generation == generation ? deadline.timeIntervalSince($0.now()) : nil }),
                  remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, step) * 1_000_000_000))
            }
            guard let self, self.generation == generation else { return }
            self.waiting = nil
            await action()
        }
    }

    public func cancel() {
        generation += 1
        waiting?.cancel()
        waiting = nil
    }
}
