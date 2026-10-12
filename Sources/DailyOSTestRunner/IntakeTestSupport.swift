import DailyOSCore
import Foundation

/// Drives Messages Intake's own actions (refresh, re-extract, extract one
/// Batch now) over a `FakeMessagesSource` holding `messages`, the way the
/// app does. Tests of Extraction's judgments go through these rather than
/// Extraction's pass functions, so the Gate, the read and the pass slot
/// are always part of what they exercise (intake-pass-slot tickets 04–05).
///
/// Unless a test says otherwise, the store is set up as a steady-state
/// install: the one-time backfill already done, and the non-self cutoff
/// (ADR 0007) far enough back that every fixture message is read.
struct IntakeFixture: Sendable {
    var contactsResolver: any ContactsResolver = FakeContactsResolver()
    var participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore()
    var historyStore: (any HistoryStore)?
    var correctionStore: (any CorrectionExamples)?
    var screener: (any Screener)?
    var screeningMode: ScreeningMode = .off
    var auditRoll: @Sendable () -> Double = { Double.random(in: 0..<1) }
    var ignoresFilteredSMS: @Sendable () -> Bool = { false }

    init(
        contactsResolver: any ContactsResolver = FakeContactsResolver(),
        participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
        historyStore: (any HistoryStore)? = nil, correctionStore: (any CorrectionExamples)? = nil,
        screener: (any Screener)? = nil, screeningMode: ScreeningMode = .off,
        auditRoll: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        ignoresFilteredSMS: @escaping @Sendable () -> Bool = { false }
    ) {
        self.ignoresFilteredSMS = ignoresFilteredSMS
        self.contactsResolver = contactsResolver
        self.participantLabelStore = participantLabelStore
        self.historyStore = historyStore
        self.correctionStore = correctionStore
        self.screener = screener
        self.screeningMode = screeningMode
        self.auditRoll = auditRoll
    }

    /// The same collaborators a test built for Extraction directly.
    init(_ deps: ExtractionDependencies) {
        self.init(
            contactsResolver: deps.contactsResolver, participantLabelStore: deps.participantLabelStore,
            historyStore: deps.historyStore, correctionStore: deps.correctionStore, screener: deps.screener,
            screeningMode: deps.screeningMode, auditRoll: deps.randomUnit, ignoresFilteredSMS: deps.ignoresFilteredSMS
        )
    }
}

@MainActor
func makeIntake(
    over messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    fixture: IntakeFixture = IntakeFixture(), backfillDone: Bool = true
) -> MessagesIntake {
    if backfillDone, !store.isBackfillComplete() { try? store.markBackfillComplete() }
    if store.nonSelfMessagesCutoff() == nil { try? store.recordNonSelfMessagesCutoff(.distantPast) }
    let intake = MessagesIntake(
        messagesSource: FakeMessagesSource(messages: messages), signalStore: store,
        contactsResolver: fixture.contactsResolver, bundlePath: "/nonexistent",
        participantLabelStore: fixture.participantLabelStore, historyStore: fixture.historyStore,
        correctionStore: fixture.correctionStore, extractor: extractor, auditRoll: fixture.auditRoll,
        ignoresFilteredSMS: fixture.ignoresFilteredSMS
    )
    intake.screener = fixture.screener
    intake.screeningMode = fixture.screeningMode
    return intake
}

/// A moment by which every Batch in `messages` has closed, and from which
/// all of them still fall inside the lookback window: what a pass sees
/// once a conversation has gone quiet.
func quietAfter(_ messages: [ChatMessage]) -> Date {
    (messages.map(\.createdAt).max() ?? Date()).addingTimeInterval(batchCap + 1)
}

/// What a refresh returned. Anything but `.refreshed` reads as no
/// Signals: these helpers always open the Gate and pass an extractor, so a
/// test that gets there has a broken fixture, and its own expectations
/// will say so.
private func refreshedSignals(_ result: MessagesIntake.Result) -> [Signal] {
    if case .refreshed(let signals) = result { return signals }
    return []
}

/// A refresh over `messages`: every closed Batch not yet Processed goes to
/// the model. `now` defaults to once they have all gone quiet.
func refreshThroughIntake(
    from messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    fixture: IntakeFixture, priority: TaskPriority = .userInitiated, now: Date? = nil
) async -> [Signal] {
    let intake = await makeIntake(over: messages, store: store, extractor: extractor, fixture: fixture)
    return refreshedSignals(await intake.refresh(now: now ?? quietAfter(messages), priority: priority))
}

/// The same, for a test holding the collaborators as `ExtractionDependencies`.
func refreshThroughIntake(
    from messages: [ChatMessage], deps: ExtractionDependencies, priority: TaskPriority = .userInitiated, now: Date? = nil
) async -> [Signal] {
    await refreshThroughIntake(
        from: messages, store: deps.store, extractor: deps.extractor, fixture: IntakeFixture(deps), priority: priority,
        now: now
    )
}

/// The first refresh on a fresh install, which runs the one-time backfill.
func backfillThroughIntake(
    messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    fixture: IntakeFixture, priority: TaskPriority = .userInitiated, now: Date? = nil,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    let intake = await makeIntake(over: messages, store: store, extractor: extractor, fixture: fixture, backfillDone: false)
    _ = await intake.refresh(now: now ?? quietAfter(messages), priority: priority, onProgress: onProgress)
}

/// Wide enough that a re-extraction's lookback never leaves out a fixture.
private let fixtureLookbackDays = 3650.0

/// Manual re-extraction over `messages`, with a lookback wide enough for
/// any fixture.
func reExtractThroughIntake(
    messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    fixture: IntakeFixture, priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    let intake = await makeIntake(over: messages, store: store, extractor: extractor, fixture: fixture)
    _ = await intake.reExtract(now: quietAfter(messages), lookbackDays: fixtureLookbackDays, priority: priority, onProgress: onProgress)
}

func reExtractThroughIntake(
    messages: [ChatMessage], deps: ExtractionDependencies, priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    await reExtractThroughIntake(
        messages: messages, store: deps.store, extractor: deps.extractor, fixture: IntakeFixture(deps),
        priority: priority, onProgress: onProgress
    )
}

/// "This was work": the Batch `sourceRef` names, straight to the model.
func extractNowThroughIntake(
    sourceRef: String, messages: [ChatMessage], deps: ExtractionDependencies, priority: TaskPriority = .userInitiated
) async {
    let intake = await makeIntake(over: messages, store: deps.store, extractor: deps.extractor, fixture: IntakeFixture(deps))
    _ = await intake.extractNow(sourceRef: sourceRef, priority: priority)
}

/// The same, taking the collaborators a test most often varies one by one
/// instead of as an `IntakeFixture`.
func refreshThroughIntake(
    from messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    contactsResolver: any ContactsResolver = FakeContactsResolver(),
    participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
    historyStore: (any HistoryStore)? = nil, correctionStore: (any CorrectionExamples)? = nil,
    priority: TaskPriority = .userInitiated
) async -> [Signal] {
    await refreshThroughIntake(
        from: messages, store: store, extractor: extractor,
        fixture: IntakeFixture(
            contactsResolver: contactsResolver, participantLabelStore: participantLabelStore, historyStore: historyStore,
            correctionStore: correctionStore
        ),
        priority: priority
    )
}

func backfillThroughIntake(
    messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    contactsResolver: any ContactsResolver = FakeContactsResolver(),
    participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
    historyStore: (any HistoryStore)? = nil, correctionStore: (any CorrectionExamples)? = nil,
    priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    await backfillThroughIntake(
        messages: messages, store: store, extractor: extractor,
        fixture: IntakeFixture(
            contactsResolver: contactsResolver, participantLabelStore: participantLabelStore, historyStore: historyStore,
            correctionStore: correctionStore
        ),
        priority: priority, onProgress: onProgress
    )
}

func reExtractThroughIntake(
    messages: [ChatMessage], store: any BatchLedger & MessagesIntakeState, extractor: any IntentExtractor,
    contactsResolver: any ContactsResolver = FakeContactsResolver(),
    participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
    historyStore: (any HistoryStore)? = nil, correctionStore: (any CorrectionExamples)? = nil,
    priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    await reExtractThroughIntake(
        messages: messages, store: store, extractor: extractor,
        fixture: IntakeFixture(
            contactsResolver: contactsResolver, participantLabelStore: participantLabelStore, historyStore: historyStore,
            correctionStore: correctionStore
        ),
        priority: priority, onProgress: onProgress
    )
}
