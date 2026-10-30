import Foundation

/// One pass over Messages that turns source text into Signals: reading the
/// Chats, honouring the Gate, garbage collecting what has vanished,
/// bounding how far back to look, and running Extraction over whatever
/// survives (CONTEXT.md: Messages Intake). The first-run backfill and
/// manual re-extraction are both variants of this, not of Extraction
/// itself, which only ever judges one piece of text.
///
/// `@MainActor`: every call here lifts its Sendable dependencies into a
/// `Task.detached` for the blocking chat.db/SQLite work, the same pattern
/// `AppModel.reloadMessages` used before this existed — the class itself
/// stays on the main actor so a caller never has to hop to reach it.
@MainActor
public final class MessagesIntake {
    /// Intake's own long-lived state, not a per-call parameter: the model
    /// takes seconds to load, so a caller sets this once loading finishes
    /// and leaves it `nil` until then. `refresh(now:onProgress:)` degrades
    /// to reading and garbage collecting but skipping extraction when it's
    /// `nil` — the same "surface it, never block" treatment ticket 10
    /// gives a missing Gate.
    /// Written only by `ExtractionHost` (extraction-host), or once at init.
    public internal(set) var extractor: (any IntentExtractor)?

    /// Screening (ADR 0036), set by the app from Screening settings and the
    /// stored API key. `.off` or `nil` means nothing leaves the Mac. A
    /// change made while a pass runs applies from its next Batch.
    public var screener: (any Screener)? {
        get { screening.current.screener }
        set { screening.set(screener: newValue) }
    }
    public var screeningMode: ScreeningMode {
        get { screening.current.mode }
        set { screening.set(mode: newValue) }
    }
    private let screening = CurrentScreening()

    /// Sets the Screener and mode together, so no Batch sees one changed
    /// and not the other.
    /// `ExtractionHost`'s way in (extraction-host).
    func setScreening(_ screener: (any Screener)?, mode: ScreeningMode) {
        screening.set(screener: screener, mode: mode)
    }

    private let messagesSource: any MessagesSource
    private let signalStore: any BatchLedger & MessagesIntakeState
    private let contactsResolver: any ContactsResolver
    /// ADR 0033: held once, the same way `historyStore` is, so a real
    /// sender's label stays stable across every intake pass for the life of
    /// the app rather than resetting on every call the way the in-memory
    /// default would.
    private let participantLabelStore: any ParticipantLabelStore
    /// History (ADR 0029): `nil` is a legitimate value, not a placeholder for
    /// "not wired up yet" — passing it straight through to `Extraction.swift`
    /// simply means no `HistoryEntry` gets written, which every existing
    /// caller (including every test that constructs this without History in
    /// mind) already tolerates.
    private let historyStore: (any HistoryStore)?
    /// Older History rows are backfilled once per launch (see
    /// `backfillHistoryDisplay`); rows recorded since carry their own.
    private var hasBackfilledHistoryDisplay = false
    /// ADR 0031: `nil` is legitimate the same way `historyStore` being `nil`
    /// is — every existing caller (including every test predating this
    /// feature) simply gets no Correction lookup or capture at all.
    private let correctionStore: (any CorrectionExamples)?
    /// Injected rather than read from `Bundle.main` inside, so a test can
    /// drive `identityMismatch()` at all.
    private let bundlePath: String
    /// Wakes Intake when the Batch a pass left open closes. At most one
    /// wake-up is pending: the next pass replaces it.
    private let batchWakeAlarm: (any Alarm)?
    /// Rolls the Audit Sample (ADR 0039); injected so tests can fix it.
    private let auditRoll: @Sendable () -> Double
    /// Advanced's Ignore Filtered SMS toggle, read for each Batch.
    private let ignoresFilteredSMS: @Sendable () -> Bool

    /// Called when a Batch a pass left open is due to close (batched-
    /// extraction ticket 05). The caller answers with a Messages refresh
    /// through its usual path, so the wake-up joins or follows a running
    /// pass exactly as a chat.db write would (ADR 0034).
    public var onBatchDue: (@MainActor @Sendable () -> Void)?

    public init(
        messagesSource: any MessagesSource,
        signalStore: any BatchLedger & MessagesIntakeState,
        contactsResolver: any ContactsResolver,
        bundlePath: String,
        participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
        historyStore: (any HistoryStore)? = nil,
        correctionStore: (any CorrectionExamples)? = nil,
        extractor: (any IntentExtractor)? = nil,
        batchWakeAlarm: (any Alarm)? = nil,
        auditRoll: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        ignoresFilteredSMS: @escaping @Sendable () -> Bool = { false }
    ) {
        self.messagesSource = messagesSource
        self.signalStore = signalStore
        self.contactsResolver = contactsResolver
        self.bundlePath = bundlePath
        self.participantLabelStore = participantLabelStore
        self.historyStore = historyStore
        self.correctionStore = correctionStore
        self.extractor = extractor
        self.batchWakeAlarm = batchWakeAlarm
        self.auditRoll = auditRoll
        self.ignoresFilteredSMS = ignoresFilteredSMS
    }

    /// `nil` until the model finishes loading, same as `extractor` itself
    /// — built fresh from `extractor`'s current value rather than stored,
    /// since `extractor` is a `var` a caller sets after `init`.
    private var deps: ExtractionDependencies? {
        extractor.map { extractor in
            ExtractionDependencies(
                store: signalStore, extractor: extractor, contactsResolver: contactsResolver,
                participantLabelStore: participantLabelStore, historyStore: historyStore, correctionStore: correctionStore,
                screening: screening, randomUnit: auditRoll, ignoresFilteredSMS: ignoresFilteredSMS
            )
        }
    }

    /// What a refresh or re-extraction pass produced. `.extractionUnavailable`
    /// is distinct from `.unavailable`: the Gate is open and the read
    /// succeeded, there is simply no model to run text through, and a
    /// caller holding a Messages array from an earlier pass should leave
    /// it exactly as it was rather than clear it.
    ///
    /// `.notRead` is a pass that stopped before reading Messages, since
    /// with no model it had nothing to do: it says nothing about the Gate.
    public enum Result: Sendable {
        case unavailable
        case extractionUnavailable
        case notRead
        case refreshed([Signal])
    }

    /// ticket 10: compares the running binary's signing identity against
    /// the one recorded after the last successful read. Meant to be
    /// checked once, at launch — the identity can't change mid-session —
    /// with `refresh(now:onProgress:)`'s own `availability()` probe right
    /// after as the authoritative source of truth once it runs.
    /// `nil` from `currentSigningIdentity` (unsigned, ad-hoc, or some
    /// other introspection failure) is never a mismatch — nothing to have
    /// drifted from.
    public func identityMismatch() -> Bool {
        guard let current = currentSigningIdentity(bundlePath: bundlePath) else { return false }
        let stored = signalStore.storedSigningIdentity()
        // Gates.identityMismatch(current:stored:): a different function
        // than this method despite the shared name — Swift resolves the
        // call by argument list, the same way a method can freely call a
        // free function it happens to share a name with.
        guard DailyOSCore.identityMismatch(current: current, stored: stored) else { return false }
        // ADR 0019: this comparison is known to be silent for the one
        // case that actually breaks Full Disk Access under a local rebuild
        // cycle (the CDHash changes; the common name compared here does
        // not) — logged anyway, since it is still the only detector this
        // app has and the message is what let that ADR's cause be found
        // at all.
        let message = "DailyOS: signing identity changed since the last successful Messages read " +
            "(was \(stored ?? "unknown"), now \(current)); Full Disk Access will need to be re-granted.\n"
        FileHandle.standardError.write(Data(message.utf8))
        return true
    }

    /// The one pass currently running, if any, whichever kind it is (ADR
    /// 0034). Intake is not re-entrant: `runIntakePass` only marks a message Processed
    /// *after* its model call returns, so two passes overlapping both see
    /// the same message as unprocessed and both run the model on it. On
    /// this machine a call costs ~10s and the chat.db poll fires every 60s,
    /// so a pass that outlives one poll interval picks up a second
    /// concurrent pass, then a third, each multiplying the duplicated work
    /// until nothing finishes at all — the launch pass included, which is
    /// what left the window on "Loading…" indefinitely.
    ///
    /// `refresh` and `reExtract` share this one slot rather than guarding
    /// themselves separately, because the resource they contend for is the
    /// same either way: ADR 0026 keeps a single `llama_context` alive for
    /// the app's lifetime, so there is exactly one `decodeLock` and two
    /// passes can only ever queue behind it, never run in parallel.
    ///
    /// Cleared by the pass itself, as the last thing it does, rather than
    /// by whoever started it. A caller's `defer` looked equivalent and
    /// deadlocked: `reExtract` waits by awaiting this task, and an awaiter
    /// of an already-finished task resumes without suspending, so it could
    /// re-read a slot the starter had not been scheduled to clear yet and
    /// spin on it forever without ever yielding the main actor. Clearing
    /// inside the body happens once, before any awaiter resumes, which is
    /// the ordering the wait actually depends on.
    private var inFlightPass: Task<Result, Never>?

    /// Which kind of pass holds the slot, or `nil` when none does. A
    /// follow-up pass is automatic whichever kind it follows. Set and
    /// cleared only by the pass itself.
    public private(set) var runningPass: PassKind? {
        didSet { if runningPass != oldValue { onPassChange?(runningPass) } }
    }

    /// Called whenever `runningPass` changes, on the main actor. The same
    /// shape as `onBatchDue`: DailyOSCore has no Observation, so a caller
    /// that shows the running pass mirrors it from here.
    public var onPassChange: (@MainActor (PassKind?) -> Void)?

    /// Set when a `refresh` joins a running pass (ADR 0034 amendment): that
    /// caller was triggered by something the running pass may already have
    /// listed past, so the pass runs once more before it ends. Holds the
    /// latest joiner's `now`. However many joiners arrive, it's one flag,
    /// so they earn one follow-up between them. `reExtract` never sets it.
    private var followUpNow: Date?

    /// The intake pass: read, garbage collect, and (if a model is loaded)
    /// extract. `now` bounds `withinExtractionWindow` — the first-run
    /// backfill and every later pass alike only ever consider
    /// `extractionLookbackDays` of history — and is threaded through
    /// rather than read from `Date()` here, the same discipline
    /// `Ranking.rank(_:now:)` already holds callers to.
    ///
    /// `onProgress` only ever fires during the one-time backfill; an
    /// already-backfilled refresh reports nothing.
    ///
    /// Calls that arrive while a pass is running join that pass and get its
    /// result, rather than starting a second one. Coalescing rather than
    /// dropping, so every caller still gets a real `Result` to act on and
    /// no caller has to learn a "busy" case. A joiner's own `onProgress` is
    /// never called — the running pass reports to whoever started it —
    /// which is what the callers want anyway: the launch pass owns the
    /// progress readout, and the poll that joins it has no UI of its own.
    /// A joiner also earns the running pass one follow-up (see
    /// `runFollowUps`), so a message that arrived after the running pass
    /// listed chat.db is picked up as soon as that pass ends, not on the
    /// next poll.
    public func refresh(
        now: Date, priority: TaskPriority = .userInitiated,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> Result {
        await runInSlot(.automatic(now: now), priority: priority, onProgress: onProgress)
    }

    /// ticket 12's manual re-extraction, never called automatically (ADR
    /// 0004 is unchanged — this is still only ever triggered by a click).
    /// `lookbackDays` bounds which candidates are even considered, the
    /// same way `now` bounds `refresh`'s own `withinExtractionWindow` call
    /// — `ReExtractionSettings.lookbackDays` is the caller's usual source
    /// for this, not `extractionLookbackDays`, which is a different,
    /// separately-tuned number for automatic intake.
    /// `.notRead` when there's no model to run: there's nothing to
    /// re-extract with, so Messages isn't read at all.
    ///
    /// Waits the running pass out rather than joining it, the one place
    /// this differs from `refresh`. A refresh that joins still gets an
    /// honest answer, since every pass returns the current Messages
    /// share. Re-extraction does not: its whole job is to put candidates
    /// back through the model, which the pass it would be joining is not
    /// doing, so joining would make an explicit click silently do nothing.
    public func reExtract(
        now: Date, lookbackDays: Double, priority: TaskPriority = .userInitiated,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> Result {
        await runInSlot(.reExtraction(now: now, lookbackDays: lookbackDays), priority: priority, onProgress: onProgress)
    }

    /// "This was work" (ADR 0036): reads Messages and puts the one Batch
    /// `sourceRef` names straight through the model, never through
    /// Screening. Waits its turn behind a running pass, like `reExtract`,
    /// since it too exists to make the model look again.
    public func extractNow(sourceRef: String, priority: TaskPriority = .userInitiated) async -> Result {
        await runInSlot(.explicit(sourceRef: sourceRef), priority: priority, onProgress: { _, _ in })
    }

    /// One call to intake, with what its kind of pass needs.
    private enum PassRequest {
        case automatic(now: Date)
        case reExtraction(now: Date, lookbackDays: Double)
        case explicit(sourceRef: String)

        var kind: PassKind {
            switch self {
            case .automatic: .automatic
            case .reExtraction: .reExtraction
            case .explicit: .explicit
            }
        }
    }

    /// The pass slot (ADR 0034), the only place `inFlightPass` and
    /// `runningPass` are taken or cleared. An automatic call arriving while
    /// any pass runs joins it and earns one follow-up; any other call waits
    /// the running pass out and then runs its own. The wait loops rather than checking once because
    /// the slot can be taken again by whoever was waiting alongside it.
    private func runInSlot(
        _ request: PassRequest, priority: TaskPriority,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async -> Result {
        if case .automatic(let now) = request, let inFlightPass {
            followUpNow = now
            return await inFlightPass.value
        }
        while let running = inFlightPass {
            _ = await running.value
        }
        let pass = Task { @MainActor in
            defer {
                self.runningPass = nil
                self.inFlightPass = nil
            }
            let result = await self.run(request, priority: priority, onProgress: onProgress)
            return await self.runFollowUps(after: result, priority: priority)
        }
        inFlightPass = pass
        runningPass = request.kind
        return await pass.value
    }

    /// Runs a refresh pass for as long as `followUpNow` keeps getting set,
    /// inside the pass's own task, so the slot stays held and nobody starts
    /// a parallel pass in between. A joiner waits for the follow-up too and
    /// gets its result, which is the fresher answer. The follow-up reports
    /// no progress: only the starter's `onProgress` ever fires.
    private func runFollowUps(after result: Result, priority: TaskPriority) async -> Result {
        var latest = result
        while let now = followUpNow {
            followUpNow = nil
            runningPass = .automatic
            latest = await run(.automatic(now: now), priority: priority, onProgress: { _, _ in })
        }
        return latest
    }

    /// One pass of any kind. Every kind reads Messages the same way and
    /// reports a denied Gate as `.unavailable`. Only the automatic pass
    /// reads before checking for a model, since its garbage collection and
    /// History display backfill need no model; the others have nothing to
    /// do without one.
    private func run(
        _ request: PassRequest, priority: TaskPriority,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async -> Result {
        let passStartedAt = Date()
        let rules = request.kind.rules
        if request.kind != .automatic, deps == nil { return .notRead }
        let source = messagesSource
        let store = signalStore

        // Re-probed after the real read, not just before it: chat.db has
        // no revocation notification, so a grant pulled by hand mid-read
        // is only ever caught by noticing the next read fail (ticket 10).
        let (availability, messages) = await Task.detached { readMessages(source: source, store: store) }.value
        guard availability == .available else { return .unavailable }

        switch request {
        case .automatic(let now):
            await afterSuccessfulRead(messages: messages, now: now)
            // No local model, nothing to extract with (ticket 05): degrade
            // the same way a missing Gate does. Garbage collection above
            // still ran, so a vanished message's Signals are cleaned up
            // either way.
            guard let deps else { return .extractionUnavailable }
            let extractionMessages = withinExtractionWindow(messages, now: now)
            if !store.isBackfillComplete() {
                // The first-run backfill (ticket 08): every Batch counts as
                // closed, since history has long gone quiet. Each Batch's
                // result is committed as it's produced, so quitting mid-run
                // resumes at the first unprocessed one, and progress counts
                // what an earlier run already did.
                onProgress(0, extractionMessages.count)
                let batches = store.unprocessedBatches(in: extractionMessages, now: nil).closed
                let alreadyProcessed = extractionMessages.count - batches.reduce(0) { $0 + $1.messages.count }
                await runIntakePass(
                    rules, over: batches, allMessages: extractionMessages, deps: deps, priority: priority,
                    progress: PassProgress(offset: alreadyProcessed, total: extractionMessages.count, report: onProgress)
                )
                try? store.markBackfillComplete()
            }
            // Every closed Batch nothing has Processed yet (ADR 0039). One
            // still open waits for a later pass.
            await runIntakePass(
                rules, over: store.unprocessedBatches(in: extractionMessages, now: now).closed,
                allMessages: extractionMessages, deps: deps, priority: priority
            )
            let signals = store.openSignals()
            scheduleWakeUp(
                at: store.unprocessedBatches(in: extractionMessages, now: now).nextClosingAt, now: now,
                passStartedAt: passStartedAt
            )
            return .refreshed(signals)
        case .reExtraction(let now, let lookbackDays):
            guard let deps else { return .extractionUnavailable }
            // Ticket 12: only Batches a pass found nothing in, and only
            // those still in the lookback window, since a message no longer
            // read has no text left to check (ADR 0004).
            let window = withinExtractionWindow(messages, now: now, lookbackDays: lookbackDays)
            let batches = store.reExtractionCandidates().compactMap { store.batch(named: $0, in: window) }
            await runIntakePass(
                rules, over: batches, allMessages: window, deps: deps, priority: priority,
                progress: PassProgress(report: onProgress)
            )
            return .refreshed(store.openSignals())
        case .explicit(let sourceRef):
            guard let deps else { return .extractionUnavailable }
            // "This was work" or Try again: the one Batch, with the whole
            // read as its context. One no longer read produces nothing.
            let target = store.batch(named: sourceRef, in: messages).map { [$0] } ?? []
            await runIntakePass(rules, over: target, allMessages: messages, deps: deps, priority: priority)
            return .refreshed(store.openSignals())
        }
    }

    /// The automatic pass's work that needs a successful read but no model:
    /// recording which signing identity last read chat.db, garbage
    /// collecting vanished messages, and once per launch giving older
    /// History rows their names and transcripts.
    private func afterSuccessfulRead(messages: [ChatMessage], now: Date) async {
        let source = messagesSource
        let store = signalStore

        // "The last successful read" (ticket 10) — recorded here, not at
        // launch, so a launch that never actually reaches a working read
        // doesn't overwrite the one identity that's known to have worked.
        if let currentIdentity = currentSigningIdentity(bundlePath: bundlePath) {
            try? store.recordSigningIdentity(currentIdentity)
        }

        // Garbage collection, judged against *this* successful fetch. A
        // Batch goes only once Messages confirms every one of its messages
        // gone, so a transient read failure removes nothing.
        let vanished = await Task.detached {
            store.vanishedBatches(among: messages, source: source)
        }.value
        for batchId in vanished {
            try? store.garbageCollectSignals(ofBatch: batchId)
        }

        if !hasBackfilledHistoryDisplay, let historyStore {
            hasBackfilledHistoryDisplay = true
            let resolver = contactsResolver
            let since = now.addingTimeInterval(-7 * 24 * 60 * 60)
            await Task.detached {
                backfillHistoryDisplay(
                    history: historyStore, messages: messages, ledger: store,
                    contactsResolver: resolver, since: since
                )
            }.value
        }
    }

    /// Replaces any pending wake-up with one for `closingAt`, the earliest
    /// moment a Batch this pass left open will close; with nothing open,
    /// the pending one is simply dropped. The 60-second poll stays as the
    /// backstop if a wake-up is ever lost.
    private func scheduleWakeUp(at closingAt: Date?, now: Date, passStartedAt: Date) {
        guard let batchWakeAlarm else { return }
        guard let closingAt else {
            batchWakeAlarm.cancel()
            return
        }
        // `now` is the moment the pass judged against; the Batch closes
        // that long after the pass started, however long it then spent in
        // the model.
        batchWakeAlarm.schedule(at: passStartedAt.addingTimeInterval(closingAt.timeIntervalSince(now))) { [weak self] in
            self?.onBatchDue?()
        }
    }
}

/// The read every pass starts with, off the main actor: honour the Gate,
/// clear any Automated mark on a self-chat (ADR 0007 amendment: marks set
/// before the self-thread was exempt), then list everything outside the
/// remaining Automated Chats. Availability is re-probed after the read,
/// since a Full Disk Access grant pulled mid-read has no notification of
/// its own (ticket 10).
private func readMessages(
    source: any MessagesSource, store: any MessagesIntakeState
) -> (availability: SourceAvailability, messages: [ChatMessage]) {
    guard source.availability() == .available else { return (.unavailable, []) }
    for chatId in store.automatedChatIds().intersection(source.selfChatIds()) {
        try? store.unmarkAutomated(chatId: chatId)
    }
    let nonSelfCutoff = ensureNonSelfMessagesCutoff(store: store)
    let messages = source.listMessages(excludingChatIds: store.automatedChatIds(), nonSelfCutoff: nonSelfCutoff)
    return (source.availability(), messages)
}

/// ADR 0007: the floor below which a non-self Chat's messages are never
/// read, set once — the first time this ever runs successfully — and
/// never moved again. A free function so `readMessages` can reach it from
/// inside a `Task.detached` closure, off the main actor, alongside
/// the other blocking store I/O there.
private func ensureNonSelfMessagesCutoff(store: any MessagesIntakeState) -> Date {
    if let existing = store.nonSelfMessagesCutoff() {
        return existing
    }
    let now = Date()
    try? store.recordNonSelfMessagesCutoff(now)
    return now
}

/// The kinds of pass Messages Intake runs. One runs at a time, whichever
/// kind (ADR 0034).
public enum PassKind: Sendable, Equatable {
    /// A refresh: the launch pass, a chat.db write, the poll or a Batch
    /// wake-up. The only kind that screens, may Supersede, backfills and
    /// records Batches as Processed.
    case automatic
    /// Manual re-extraction: already Processed Batches back through the
    /// model, adding only (ADR 0004).
    case reExtraction
    /// "This was work": one Batch straight to the model (ADR 0036).
    case explicit
}

extension PassKind {
    /// What each kind of pass does with the Batches it judges. Only an
    /// automatic pass screens (an explicit request for the model's opinion
    /// never gives Screening a say, ADR 0036), shows the model open
    /// Suggestions it may Supersede, and records Batches as Processed.
    /// Re-extraction and "This was work" judge Batches that are already
    /// Processed and only ever add Signals (ADR 0004).
    var rules: PassRules {
        switch self {
        case .automatic: PassRules(screens: true, mayRevise: true, recordsProcessed: true)
        case .reExtraction, .explicit: PassRules(screens: false, mayRevise: false, recordsProcessed: false)
        }
    }
}
