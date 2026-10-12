import Foundation

/// The extraction pipeline's own collaborators, bundled once instead of
/// retyped across every kind of pass. Messages Intake builds one per pass;
/// `messages` and `priority` stay outside it, since those vary by call.
public struct ExtractionDependencies: Sendable {
    public let store: any BatchLedger & MessagesIntakeState
    public let extractor: any IntentExtractor
    public let contactsResolver: any ContactsResolver
    public let participantLabelStore: any ParticipantLabelStore
    public let historyStore: (any HistoryStore)?
    public let correctionStore: (any CorrectionExamples)?
    /// Screening (ADR 0036), read afresh for each Batch. A `nil` Screener,
    /// or mode `.off`, means no message is ever sent off the Mac.
    public let screening: CurrentScreening
    public var screener: (any Screener)? { screening.current.screener }
    public var screeningMode: ScreeningMode { screening.current.mode }
    /// Rolls the Audit Sample: a number in 0..<1, drawn once per Screened
    /// Batch. Injected so a test can decide the roll.
    public let randomUnit: @Sendable () -> Double
    /// Advanced's Ignore Filtered SMS toggle, read afresh for each Batch.
    public let ignoresFilteredSMS: @Sendable () -> Bool

    public init(
        store: any BatchLedger & MessagesIntakeState,
        extractor: any IntentExtractor,
        contactsResolver: any ContactsResolver = NoopContactsResolver(),
        participantLabelStore: any ParticipantLabelStore = InMemoryParticipantLabelStore(),
        historyStore: (any HistoryStore)? = nil,
        correctionStore: (any CorrectionExamples)? = nil,
        screener: (any Screener)? = nil,
        screeningMode: ScreeningMode = .off,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        ignoresFilteredSMS: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            store: store, extractor: extractor, contactsResolver: contactsResolver,
            participantLabelStore: participantLabelStore, historyStore: historyStore, correctionStore: correctionStore,
            screening: CurrentScreening(screener: screener, mode: screeningMode), randomUnit: randomUnit,
            ignoresFilteredSMS: ignoresFilteredSMS
        )
    }

    public init(
        store: any BatchLedger & MessagesIntakeState,
        extractor: any IntentExtractor,
        contactsResolver: any ContactsResolver,
        participantLabelStore: any ParticipantLabelStore,
        historyStore: (any HistoryStore)?,
        correctionStore: (any CorrectionExamples)?,
        screening: CurrentScreening,
        randomUnit: @escaping @Sendable () -> Double,
        ignoresFilteredSMS: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store
        self.extractor = extractor
        self.contactsResolver = contactsResolver
        self.participantLabelStore = participantLabelStore
        self.historyStore = historyStore
        self.correctionStore = correctionStore
        self.screening = screening
        self.randomUnit = randomUnit
        self.ignoresFilteredSMS = ignoresFilteredSMS
    }
}

/// Runs Extraction over whichever of `messages` the store has no Processed
/// record for yet, a closed Batch at a time (ADR 0039), mints and persists
/// whatever Signals Extraction produces for each, then returns every
/// currently open Messages Signal. `now` decides which Batches have closed;
/// `nil` treats every Batch as closed. A Batch still open is left
/// unprocessed for a later pass. A Batch left unrecorded by a failed store
/// write is simply retried on a later run, same as it staying Processed
/// forever once a write does succeed.
func extractSignals(
    from messages: [ChatMessage],
    deps: ExtractionDependencies,
    rules: PassRules,
    priority: TaskPriority = .userInitiated,
    now: Date? = nil
) async -> [Signal] {
    await runIntakePass(
        rules, over: deps.store.unprocessedBatches(in: messages, now: now).closed, allMessages: messages,
        deps: deps, priority: priority
    )
    return deps.store.openSignals()
}

/// The share of Screened Batches that still go to the model once Screening
/// is live (CONTEXT.md: Audit Sample).
public let auditSampleRate = 0.1

/// What judging one Batch produced: new Signals, and the Suggestions its
/// answer Supersedes (ADR 0040).
struct BatchOutcome {
    var signals: [Signal] = []
    var supersessions: [Supersession] = []
}

/// How many of a Chat's undecided Suggestions the model is shown (ADR
/// 0040): the newest, so the list fits the context.
public let maxOpenSuggestionsShown = 5

/// The first-run backfill (ticket 08), self-thread only (ADR 0007: the
/// widened Messages source is never backfilled): walks the full self-thread
/// history, newest first per `messages`' own ordering, committing each
/// message's result to the store as it's produced so quitting mid-run and
/// relaunching resumes at the first unprocessed message rather than
/// starting over. `onProgress` fires once per message in `messages`
/// (including ones already Processed from an earlier run), with the
/// running count against the full total, so a resumed run reports accurate
/// progress from wherever it left off rather than restarting the count at
/// zero. `onProgress` is plain and `@Sendable` — it fires from wherever
/// this function happens to run, off the main actor; a caller updating UI
/// state is responsible for hopping back to its own actor.
func runBackfill(
    messages: [ChatMessage],
    deps: ExtractionDependencies,
    rules: PassRules,
    priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    // Every Batch counts as closed: a first-run backfill reads history,
    // where every conversation has long gone quiet.
    let batches = deps.store.unprocessedBatches(in: messages, now: nil).closed
    let alreadyProcessed = messages.count - batches.reduce(0) { $0 + $1.messages.count }
    await runIntakePass(
        rules, over: batches, allMessages: messages, deps: deps, priority: priority,
        progress: PassProgress(offset: alreadyProcessed, total: messages.count, report: onProgress)
    )
}

/// Ticket 12's manual re-extraction: re-runs ingestion over items a
/// previous pass found nothing in. Purely additive (ADR 0004) — every
/// candidate is already Processed, so this never records a Batch
/// again; it only widens the store with whatever new Signals this pass
/// produces, and only for `store.reExtractionCandidates()` (items with no
/// open or checked-off Signal). A message not currently in `messages` —
/// deleted, in a Chat that's since gone Automated, outside the Messages
/// source's own scope, or (ticket: re-extraction settings) older than the
/// caller's configured lookback window (`MessagesIntake.reExtract` already
/// filters `messages` down to that window before this ever runs) — simply
/// can't be a candidate, since there's no text left to check.
func runReExtraction(
    messages: [ChatMessage],
    deps: ExtractionDependencies,
    rules: PassRules,
    priority: TaskPriority = .userInitiated,
    onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
) async {
    let batches = deps.store.reExtractionCandidates().compactMap { deps.store.batch(named: $0, in: messages) }
    await runIntakePass(
        rules, over: batches, allMessages: messages, deps: deps, priority: priority,
        progress: PassProgress(report: onProgress)
    )
}

/// "This was work" (ADR 0036): puts one Screened message straight through
/// the model, bypassing Screening, and writes whatever it produces through
/// the same additive path re-extraction uses, so a Signal lands in
/// Suggestions. `messages` is the full batch, for same-chat context. A
/// message no longer in `messages` produces nothing.
func runExplicitExtraction(
    sourceRef: String,
    messages: [ChatMessage],
    deps: ExtractionDependencies,
    rules: PassRules,
    priority: TaskPriority = .userInitiated
) async {
    let target = deps.store.batch(named: sourceRef, in: messages).map { [$0] } ?? []
    await runIntakePass(rules, over: target, allMessages: messages, deps: deps, priority: priority)
}

/// How a pass reports progress. Counts messages, not Batches, starting
/// from `offset` (messages already Processed before this pass) out of
/// `total` (every message the pass covers when `nil`), so a resumed
/// backfill reports where it really is.
struct PassProgress {
    var offset = 0
    var total: Int?
    var report: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
}

/// What a pass does with each Batch it judges. Messages Intake decides these
/// for each kind of pass (`PassKind.rules`); Extraction only follows them.
struct PassRules {
    /// Screening may stop a Batch before the model (ADR 0036).
    var screens: Bool
    /// The model is shown the Chat's undecided Suggestions and may
    /// Supersede one (ADR 0040).
    var mayRevise: Bool
    /// Each Batch becomes Processed. Otherwise every Batch is already
    /// Processed and the pass only adds Signals (ADR 0004).
    var recordsProcessed: Bool
}

/// The shared shape behind every kind of pass: mark the Automated Chats
/// in `allMessages` once, then judge each Batch in `batches` and record
/// what it produced. `allMessages` is always the whole read, even when
/// `batches` covers only some of it, since `recentContext` draws a Batch's
/// context from everything before it. `Task.yield()` fires between Batches
/// so other pending work can interleave.
///
/// `rules` decides whether it screens, whether the model may Supersede,
/// and how each Batch's result is recorded.
private func runIntakePass(
    _ rules: PassRules,
    over batches: [MessageBatch],
    allMessages: [ChatMessage],
    deps: ExtractionDependencies,
    priority: TaskPriority,
    progress: PassProgress = PassProgress()
) async {
    markAutomatedChats(in: allMessages, store: deps.store)
    let total = progress.total ?? batches.reduce(0) { $0 + $1.messages.count }
    var completed = progress.offset
    if completed > 0 { progress.report(completed, total) }

    for batch in batches.flatMap(separatingMorningBriefs) {
        let outcome = await judge(
            batch, allMessages: allMessages, deps: deps, priority: priority, screens: rules.screens,
            revisesSuggestions: rules.mayRevise
        )
        do {
            if rules.recordsProcessed {
                try deps.store.recordProcessedBatch(batch, signals: outcome.signals, superseding: outcome.supersessions)
            } else if !outcome.signals.isEmpty {
                try deps.store.recordReExtractedSignals(sourceRef: batch.id, signals: outcome.signals)
            }
        } catch {
            logFailure(sourceRef: batch.id, error: error)
        }
        completed += batch.messages.count
        progress.report(completed, total)
        await Task.yield()
    }
}

/// A Batch holding a Morning Brief beside other messages (ADR 0046), split
/// in two: the other messages, judged as usual and named by their own
/// newest message, and the Briefs, which `judge` turns away. Both are
/// recorded, so every member is Processed. Any other Batch is unchanged.
private func separatingMorningBriefs(_ batch: MessageBatch) -> [MessageBatch] {
    let briefs = batch.messages.filter(isMorningBrief)
    guard !briefs.isEmpty, briefs.count < batch.messages.count else { return [batch] }
    return [MessageBatch(messages: batch.messages.filter { !isMorningBrief($0) }), MessageBatch(messages: briefs)]
}

/// Ticket 02, Rule B, run once ahead of the whole batch: finds every
/// not-yet-Automated Chat with a code-pattern message anywhere in
/// `messages` and marks it, before any Batch reaches `judge`.
/// This has to happen up front rather than inline per-message, because
/// `messages` arrives newest-first (`ChatDBMessagesSource`) — processing
/// in that order, a message newer than the batch's own code-pattern
/// message would otherwise reach the model before the Chat that produced
/// it is ever recognized as Automated. Scanning the whole batch first
/// means intra-batch order can no longer matter: every code-pattern
/// message's Chat is marked before the per-message loop begins.
private func markAutomatedChats(in messages: [ChatMessage], store: any MessagesIntakeState) {
    var newlyMarked = Set<Int>()
    for message in messages {
        // ADR 0007 amendment: the Automated rule is for service lines. The
        // self-thread is the user's own notes, where "code" next to a few
        // digits is ordinary text, so it is never marked.
        guard !message.isSelfThread else { continue }
        // A Morning Brief can quote a Label like "send Sam the door code
        // 4821"; that is DailyOS's own text, not a service line.
        guard !isMorningBrief(message) else { continue }
        guard !newlyMarked.contains(message.chatId), !store.isAutomated(chatId: message.chatId) else { continue }
        if isCodePattern(message.text) {
            try? store.markAutomated(chatId: message.chatId)
            newlyMarked.insert(message.chatId)
        }
    }
}

/// Judges one Batch (ADR 0039). The Chat's Automated and Muted states are
/// checked first, and whether it's Filtered SMS while that's ignored, then
/// every member for a confidentiality trigger (one hit withholds the whole
/// Batch, so a secret never leaves the Mac alongside
/// its neighbours), then the heuristic pre-filter, which lets the Batch
/// through if any member is worth extracting. Only then Screening, then the
/// model, with the Batch's own context: the messages before its first
/// member, never including a withheld line. Every Signal minted here is
/// `inferred` (ADR 0007: sent and received messages alike can be work).
/// More than one new Label still marks each one `lowConfidence`.
private func judge(
    _ batch: MessageBatch,
    allMessages: [ChatMessage],
    deps: ExtractionDependencies,
    priority: TaskPriority = .userInitiated,
    screens: Bool = true,
    revisesSuggestions: Bool = true
) async -> BatchOutcome {
    guard !batch.messages.contains(where: isMorningBrief) else { return BatchOutcome() }
    guard !deps.store.isAutomated(chatId: batch.chatId) else { return BatchOutcome() }
    guard !deps.store.isMuted(chatId: batch.chatId) else { return BatchOutcome() }
    guard !(deps.ignoresFilteredSMS() && isFilteredSMS(batch)) else { return BatchOutcome() }
    guard !batch.messages.contains(where: { isConfidentialityTrigger($0.text) }) else { return BatchOutcome() }
    guard batch.messages.contains(where: { isWorthExtracting($0.text) }) else { return BatchOutcome() }

    // A Morning Brief is never context either (ADR 0046): its list of
    // Labels would read as fresh work to the model.
    let eligibleContext = allMessages.filter { !isConfidentialityTrigger($0.text) && !isMorningBrief($0) }
    let context = recentContext(for: batch, in: eligibleContext)
    // ADR 0033: a non-you message with a known sender address gets a
    // stable, anonymized role label instead of the flattened "Them".
    let senderLabel: (ChatMessage) -> String = { candidate in
        guard let address = candidate.senderAddress else { return "Them" }
        return deps.participantLabelStore.label(chatId: candidate.chatId, senderAddress: address)
    }

    let subject = HistorySubject(
        batch: batch, context: context, senderLabel: senderLabel, contactsResolver: deps.contactsResolver
    )

    // Manual re-extraction and "This was work" only ever add (ADR 0004),
    // so they never show the model anything it could UPDATE or CANCEL.
    let open = revisesSuggestions ? deps.store.openSuggestions(forChat: batch.chatId, in: allMessages) : []

    // Screening (ADR 0036) runs here, after every local check has passed,
    // so a withheld Batch never leaves the Mac. The self-thread skips it:
    // those are the user's own notes. So does a Chat with a Suggestion
    // still waiting (ADR 0040): "nvm, I got it" is exactly what Screening
    // scores low, and only the model can tell it Supersedes that Suggestion.
    // A Screened Batch normally ends here. In live mode, a share of them
    // goes on to the model anyway as the Audit Sample, so the cutoff keeps
    // being checked against what the model would have found; that result
    // is only ever recorded in History.
    var isAudit = false
    if screens, !batch.isSelfThread, open.isEmpty,
       await screen(batch: batch, context: context, senderLabel: senderLabel, subject: subject, deps: deps) {
        // `screen` only answers true in live mode, so no mode check here.
        guard deps.randomUnit() < auditSampleRate else { return BatchOutcome() }
        isAudit = true
    }

    // ADR 0031: this chat's own recent Corrections first, backfilled from
    // other chats if it has few of its own — trimmed, most-recent-dropped-
    // first, until the composed prompt fits `extractor`'s own budget or
    // there are none left to drop. Context and the Batch are never trimmed
    // here; only the Correction count shrinks.
    var corrections = deps.correctionStore.map { selectCorrections(chatId: batch.chatId, store: $0) } ?? []
    func compose() -> String {
        formatForExtraction(
            batch: batch.messages, context: context, corrections: corrections, openSuggestions: open.map(\.label),
            senderLabel: senderLabel
        )
    }
    var prompt = compose()
    while deps.extractor.estimatedTokenCount(for: prompt) > deps.extractor.maxPromptTokens, !corrections.isEmpty {
        corrections.removeLast()
        prompt = compose()
    }

    let raw: String
    do {
        raw = try await deps.extractor.extract(from: prompt, priority: priority)
    } catch {
        logFailure(sourceRef: batch.id, error: error)
        return BatchOutcome()
    }

    // An UPDATE or CANCEL can only name a Suggestion the prompt listed, and
    // a new Label can't repeat one.
    let results = droppingRepeatedSuggestions(
        droppingUnknownSuggestions(parseExtractionResults(raw), openSuggestionCount: open.count),
        openLabels: open.map(\.label)
    )
    let labelled: [(label: String, dueText: String?, replacing: Signal?)] = results.compactMap { result in
        switch result {
        case .new(let label, let dueText): return (label, dueText, nil)
        case .update(let n, let label, let dueText): return (label, dueText, open[n - 1])
        case .cancel: return nil
        }
    }
    let newLabels = labelled.filter { $0.replacing == nil }
    // History (CONTEXT.md; ADR 0029): one row per Batch, recorded here, the
    // one place the model was actually called.
    if let historyStore = deps.historyStore {
        try? historyStore.record(HistoryEntry(
            subject: subject, kind: isAudit ? .audit : .extraction, rawOutput: raw,
            modelUsed: deps.extractor.modelDisplayName, signalCount: labelled.count, renderedContext: prompt
        ))
    }
    if isAudit { return BatchOutcome() }
    let lowConfidence = newLabels.count > 1
    var outcome = BatchOutcome()
    for (label, dueText, replacing) in labelled {
        let signal = messagesSuggestion(
            label: label, sourceRef: batch.id, chatId: batch.chatId, transcript: subject.transcript ?? [],
            isSelfThread: batch.isSelfThread, chatIdentifier: subject.chatIdentifier,
            dueAt: dueText.flatMap(resolveDueDate(fromPhrase:)), lowConfidence: lowConfidence
        )
        outcome.signals.append(signal)
        if let replacing {
            outcome.supersessions.append(Supersession(signalId: replacing.id, replacedBy: signal.id))
        }
    }
    for case .cancel(let n) in results {
        outcome.supersessions.append(Supersession(signalId: open[n - 1].id, replacedBy: nil))
    }
    return outcome
}

/// Asks the Screener about `batch`, records its answer as a History row,
/// and returns whether the message was Screened: true only in live mode
/// below the cutoff, in which case the caller skips the model and the
/// message is recorded Processed with no Signals. Shadow mode only
/// records. An error writes nothing and returns false, the same as
/// Screening being off.
private func screen(
    batch: MessageBatch, context: [ChatMessage], senderLabel: (ChatMessage) -> String,
    subject: HistorySubject, deps: ExtractionDependencies
) async -> Bool {
    // Read once per Batch: a change made mid-pass applies from the next one.
    let (screener, screeningMode) = deps.screening.current
    guard let screener, screeningMode != .off else { return false }
    let input = ScreeningInput(text: formatForExtraction(batch: batch.messages, context: context, senderLabel: senderLabel))
    let probability: Double
    do {
        probability = try await screener.probability(for: input)
    } catch is ScreeningUnavailable {
        try? deps.historyStore?.record(HistoryEntry(
            subject: subject, kind: .screeningUnavailable, modelUsed: screener.serviceName, signalCount: 0,
            renderedContext: input.text
        ))
        return false
    } catch {
        let reason = screeningFailureReason(error)
        log("screening failed sourceRef=\(batch.id), sending to the model: \(error)")
        try? deps.historyStore?.record(HistoryEntry(
            subject: subject, kind: .screeningFailed(reason: reason), modelUsed: screener.serviceName, signalCount: 0,
            renderedContext: input.text
        ))
        return false
    }
    let mode: ScreeningDecision.Mode = switch screeningMode {
    case .live(let cutoff): .live(cutoff: cutoff)
    case .shadow, .off: .shadow
    }
    let decision = ScreeningDecision(probability: probability, mode: mode)
    try? deps.historyStore?.record(HistoryEntry(
        subject: subject, kind: .screening(decision), modelUsed: screener.serviceName, signalCount: 0,
        renderedContext: input.text
    ))
    return decision.wasScreened
}

private func logFailure(sourceRef: String, error: Error) {
    log("store write failed sourceRef=\(sourceRef): \(error)")
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("DailyOS: \(message)\n".utf8))
}
