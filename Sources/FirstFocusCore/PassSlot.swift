import Foundation

/// The slot Messages passes take turns in (ADR 0034): who runs, who joins a
/// running pass, who waits, and the follow-up a joiner earns. It knows
/// nothing about Messages or the model; the pass's work arrives as closures.
///
/// Intake is not re-entrant: a message is marked Processed only after its
/// model call returns, so two passes overlapping both see it as
/// unprocessed and both run the model on it. ADR 0026 keeps one
/// `llama_context` for the app's lifetime, so passes could only ever queue
/// behind one decode lock anyway. On one machine a model call costs about
/// 10s and chat.db is polled every 60s, so a pass that outlives a poll
/// used to pick up a second concurrent pass, then a third, until nothing
/// finished and the launch pass left the window on "Loading…".
@MainActor
package final class PassSlot<Result: Sendable> {
    /// Which kind of pass holds the slot, or `nil` when none does. A
    /// follow-up pass is automatic whichever kind it follows.
    package private(set) var runningPass: PassKind? {
        didSet { if runningPass != oldValue { onPassChange?(runningPass) } }
    }

    /// Called whenever `runningPass` changes, on the main actor.
    package var onPassChange: (@MainActor (PassKind?) -> Void)?

    /// From a re-extraction's request until its pass ends, including while
    /// it waits behind another pass, so a second request starts nothing.
    package private(set) var isReExtracting = false

    package init() {}

    /// Cleared by the pass itself, as the last thing it does, rather than by
    /// whoever started it. A caller's `defer` looked equivalent and
    /// deadlocked: a waiter awaits this task, and an awaiter of an
    /// already-finished task resumes without suspending, so it could re-read
    /// a slot the starter had not been scheduled to clear yet and spin on it
    /// forever without ever yielding the main actor. Clearing inside the body
    /// happens once, before any awaiter resumes, which is the ordering the
    /// wait depends on.
    private var inFlight: Task<Result, Never>?

    /// Set when an automatic call joins a running pass: that caller was
    /// triggered by something the running pass may already have listed past,
    /// so the pass runs once more before it ends. Holds the latest joiner's
    /// `now`. However many joiners arrive it is one flag, so they earn one
    /// follow-up between them. A re-extraction never sets it.
    private var followUpNow: Date?

    /// Runs `body` as a pass of `kind`.
    ///
    /// An automatic call arriving while any pass runs joins it and earns one
    /// follow-up: it gets that pass's result, or the follow-up's if there is
    /// one, and its own `body` never runs. Any other call waits the running
    /// pass out and then runs its own. The wait loops rather than checking
    /// once because the slot can be taken again by whoever was waiting
    /// alongside it.
    ///
    /// `now` is an automatic call's moment, handed to `followUp` when a
    /// joiner earns one. Returns `nil` for a re-extraction asked for while
    /// another is running or waiting.
    package func run(
        _ kind: PassKind, at now: Date? = nil,
        body: @escaping @MainActor () async -> Result,
        followUp: @escaping @MainActor (Date) async -> Result
    ) async -> Result? {
        if kind == .automatic, let inFlight {
            if let now { followUpNow = now }
            return await inFlight.value
        }
        if kind == .reExtraction {
            guard !isReExtracting else { return nil }
            isReExtracting = true
        }
        while let running = inFlight {
            _ = await running.value
        }
        let pass = Task { @MainActor in
            defer {
                self.runningPass = nil
                self.inFlight = nil
                if kind == .reExtraction { self.isReExtracting = false }
            }
            var latest = await body()
            // Keeps the slot held, so nobody starts a parallel pass in
            // between. A joiner waits for the follow-up too, and gets its
            // result, which is the fresher answer.
            while let moment = self.followUpNow {
                self.followUpNow = nil
                self.runningPass = .automatic
                latest = await followUp(moment)
            }
            return latest
        }
        inFlight = pass
        runningPass = kind
        return await pass.value
    }
}
