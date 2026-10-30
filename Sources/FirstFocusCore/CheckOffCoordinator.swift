import Foundation

/// Writes a check-off through to its Source and keeps the Signal hidden
/// until the write has landed and the Source has been read again. The
/// undo window in front of it is the Undo bar's (undo-bar, amending ADR
/// 0022): the bar holds a check-off back and calls `commit(_:)` once its
/// offer ends.
///
/// `@MainActor`: owns mutable state (`committing`) that `onChange` and the
/// write's completion both touch, the same isolation `SignalBoard` and
/// `MessagesIntake` already use for the same reason.
@MainActor
public final class CheckOffCoordinator {
    private let taskSource: any TaskSource
    private let signalStore: any CheckOffStore

    /// Called whenever `hiddenIDs` changes, so a caller knows to re-derive
    /// the Ranked List. Settable rather than an init parameter: `AppModel`
    /// constructs this alongside its own other stored properties and only
    /// becomes a valid `[weak self]` capture once all of them are
    /// assigned, which is after this object already exists.
    public var onChange: () -> Void = {}

    /// Awaited once a write has landed and before its id stops being
    /// hidden, so the caller can re-read the Source first. Without it the
    /// row would show again from the stale read until the next refresh,
    /// and the Checked Off sheet wouldn't have it yet.
    public var onCommitted: @MainActor () async -> Void = {}

    /// Every Signal whose write hasn't landed yet, by id.
    private var committing: [String: Signal] = [:]
    /// Set once the app is about to quit: a write can't be left to a task
    /// the process won't live to run.
    private var writesInline = false
    /// Every write still running, so `settled()` can wait for them.
    private var writes: [Int: Task<Void, Never>] = [:]
    private var nextWrite = 0

    public init(taskSource: any TaskSource, signalStore: any CheckOffStore) {
        self.taskSource = taskSource
        self.signalStore = signalStore
    }

    /// Every id whose check-off is still being written. The caller never
    /// learns why, the same posture ADR 0020 gives the Signal Board toward
    /// `hiding`.
    public var hiddenIDs: Set<String> { Set(committing.keys) }

    /// The app is about to quit. Writes every check-off still in flight
    /// now, since the process won't live to finish them, and from then on
    /// `commit(_:)` writes before it returns. A write that had landed after
    /// all fails harmlessly: the reminder is already completed.
    public func prepareToQuit() {
        writesInline = true
        for signal in committing.values {
            try? writeCheckOff(signal, taskSource: taskSource, signalStore: signalStore)
        }
    }

    /// Writes `signal` through, off the main actor: `taskSource`/
    /// `signalStore` are Sendable, unlike this class itself, which stays
    /// main-actor-only.
    public func commit(_ signal: Signal) {
        if writesInline {
            try? writeCheckOff(signal, taskSource: taskSource, signalStore: signalStore)
            return
        }
        committing[signal.id] = signal
        onChange()

        let taskSource = self.taskSource
        let signalStore = self.signalStore
        let key = nextWrite
        nextWrite += 1
        writes[key] = Task {
            try? await Task.detached {
                try writeCheckOff(signal, taskSource: taskSource, signalStore: signalStore)
            }.value
            await self.onCommitted()
            self.committing[signal.id] = nil
            self.writes[key] = nil
            self.onChange()
        }
    }

    /// Returns once every write started so far has landed and its id is
    /// no longer hidden. For tests.
    public func settled() async {
        while let write = writes.values.first { await write.value }
    }
}

/// Writes a checked-off Signal through to its Source: Reminders via
/// `taskSource`, or the local store for a Messages Signal — Messages has
/// no completion state anyone could write to (ADR 0001). Free-standing
/// rather than a `CheckOffCoordinator` method so it can run off the main
/// actor: `taskSource`/`signalStore` are Sendable, unlike
/// `CheckOffCoordinator` itself, which stays main-actor-only.
public func writeCheckOff(_ signal: Signal, taskSource: any TaskSource, signalStore: any CheckOffStore) throws {
    switch signal.source {
    case .reminders:
        try taskSource.complete(id: signal.sourceRef)
    case .messages:
        try signalStore.checkOff(signalId: signal.id)
    }
}
