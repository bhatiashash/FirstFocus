import Foundation

/// Runs every Messages Intake pass and hands each result to the Signal
/// Board (intake-runner). Holds Messages Intake and the Board side by
/// side, not Intake behind the Board (ADR 0020, amended 2026-09-26), along
/// with the ExtractionHost, whose model a pass needs.
///
/// Owns what the passes leave behind: backfill and re-extraction
/// progress, the re-extraction cooldown's last run, the launch-time
/// identity mismatch, and which pass is running. Its caller decides when
/// to run a pass and mirrors this state; `onChange` fires after any of it
/// changes. Every moment it judges against comes from `now`.
@MainActor
public final class IntakeRunner {
    /// Something below changed.
    public var onChange: (() -> Void)?
    /// A pass handed the Board its result: the Ranked List may have
    /// changed.
    public var onResultApplied: (() -> Void)?
    /// A pass ended: History shows the rows it wrote.
    public var onPassEnded: (() -> Void)?

    /// Which kind of pass is running (ADR 0034), `nil` when none is.
    public private(set) var runningPass: PassKind?
    /// The first-run backfill's progress, `nil` when none is running.
    public private(set) var backfillProgress: (completed: Int, total: Int)?
    /// A re-extraction's progress, `nil` when none is running.
    public private(set) var reExtractionProgress: (completed: Int, total: Int)?

    private let intake: MessagesIntake
    private let board: SignalBoard
    private let extraction: ExtractionHost
    private let reExtractionSettings: ReExtractionSettings
    private let now: @MainActor () -> Date
    /// A signing identity that changed since the last launch (ticket 10):
    /// Messages reads as Unavailable until a pass reads it for itself.
    private var hasIdentityMismatch = false
    /// From a re-extraction's click until it ends, including while it waits
    /// behind another pass, so a second click starts nothing.
    private var isReExtracting = false

    public init(
        intake: MessagesIntake, board: SignalBoard, extraction: ExtractionHost, reExtractionSettings: ReExtractionSettings,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.intake = intake
        self.board = board
        self.extraction = extraction
        self.reExtractionSettings = reExtractionSettings
        self.now = now
        intake.onPassChange = { [weak self] kind in
            guard let self else { return }
            self.runningPass = kind
            self.onChange?()
            if kind == nil { self.onPassEnded?() }
        }
    }

    /// Once, at launch, before the first read: whether the app's signing
    /// identity changed (ticket 10). It can't change mid-session.
    public func checkIdentityAtLaunch() {
        hasIdentityMismatch = intake.identityMismatch()
        onChange?()
    }

    /// Whether Messages reads as Unavailable: a launch identity mismatch no
    /// pass has cleared yet, or the last read found the Gate missing.
    public var messagesUnavailable: Bool {
        hasIdentityMismatch || board.availability(of: .messages) == .unavailable
    }

    /// The automatic pass: launch, the poll, a `chat.db` change, a Batch
    /// closing. `.background`, since nobody is waiting on it.
    public func refresh() async {
        let result = await intake.refresh(now: now(), priority: .background) { [weak self] completed, total in
            Task { @MainActor in self?.report(backfill: (completed, total)) }
        }
        backfillProgress = nil
        apply(result)
    }

    /// Manual re-extraction (ADR 0004), at `.utility`: someone clicked and
    /// watches its progress. The cooldown counts from when it starts.
    public func reExtract() async {
        guard !isReExtracting else { return }
        isReExtracting = true
        defer { isReExtracting = false }
        reExtractionSettings.lastRunAt = now()
        let result = await intake.reExtract(
            now: now(), lookbackDays: reExtractionSettings.lookbackDays, priority: .utility
        ) { [weak self] completed, total in
            Task { @MainActor in self?.report(reExtraction: (completed, total)) }
        }
        reExtractionProgress = nil
        apply(result)
    }

    /// "This was work" and Try Again: the one Batch, straight to the
    /// model, after any running pass (ADR 0034).
    public func extractNow(sourceRef: String) async {
        apply(await intake.extractNow(sourceRef: sourceRef))
    }

    /// Whether Re-extract can start, from everything but the launch's
    /// loading state, which its caller adds. A running pass would only make
    /// the click wait (ADR 0034), so it reads as unavailable instead.
    public var canReExtract: Bool {
        !isReExtracting && reExtractionProgress == nil && backfillProgress == nil && runningPass == nil
            && !messagesUnavailable && !extraction.isUnavailable
            && reExtractionAllowed(
                now: now(), lastRunAt: reExtractionSettings.lastRunAt,
                minimumIntervalHours: reExtractionSettings.minimumIntervalHours
            )
    }

    /// A pass's result onto the Board. A pass that read Messages found out
    /// for itself, so the launch identity mismatch no longer decides.
    private func apply(_ result: MessagesIntake.Result) {
        board.apply(messages: result)
        if case .notRead = result {} else { hasIdentityMismatch = false }
        onChange?()
        onResultApplied?()
    }

    /// A progress report, which arrives through a hop to the main actor. One
    /// landing after its pass ended is dropped, so progress never sticks.
    private func report(backfill: (completed: Int, total: Int)) {
        guard runningPass == .automatic else { return }
        backfillProgress = backfill
        onChange?()
    }

    private func report(reExtraction: (completed: Int, total: Int)) {
        guard runningPass == .reExtraction else { return }
        reExtractionProgress = reExtraction
        onChange?()
    }
}
