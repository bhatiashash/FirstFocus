import Combine
import CoreGraphics
import DailyOSCore
import EventKit
import Foundation

/// The real, live path a shipped build reads. Development and testing
/// against a live-equivalent database use the snapshot at
/// ~/DailyOS-data/ instead — never this path — since this machine's own
/// agent shell cannot hold a stable Full Disk Access grant.
public let liveChatDBPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Messages/chat.db").path

/// The folder `liveChatDBPath` sits in, watched for writes (ADR 0034
/// amendment) so intake starts within a second of a message arriving.
public let liveMessagesDirectory = (liveChatDBPath as NSString).deletingLastPathComponent

/// `Bundle.main.bundleIdentifier` reads `Info.plist`'s `CFBundleIdentifier`
/// once the app is bundled and signed (the normal `build.sh` path); the
/// fallback only matters for `swift run DailyOS` straight from source,
/// where there's no real bundle to read it from.
public let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.shashbhatia.DailyOS"

/// The `chat.db` poll interval (ticket 11). Never settled during charting;
/// picked as a constant here and treated as tuning, not design. Also
/// Focus Mode v2's intake "wake delay" (ticket 02): the poll already
/// fetches everything unprocessed since the last tick and runs it as one
/// batch, so retuning this constant is the whole implementation of that
/// requirement — no separate scheduling infrastructure is needed.
private let chatDBPollIntervalSeconds: TimeInterval = 60


@MainActor
public final class AppModel: ObservableObject {
    /// The window's whole reason to exist (ADR 0020): derived fresh from
    /// `board.rankedList(now:hiding:)` by `republish()`, never patched in
    /// place. `sections` is what the window draws from it.
    @Published public private(set) var rankedList = RankedList(focus: [], later: [], suggested: [])
    /// The Checked Off sheet's rows, derived alongside `rankedList`.
    @Published public private(set) var checkedOff: [CheckedOffReminder] = []
    /// How many reminders were checked off today: the count at the end of
    /// the window that opens the Checked Off sheet. Always `checkedOff.count`.
    @Published public private(set) var checkedOffCount = 0
    /// Whether the window draws the count: only with something to count,
    /// only under the list or the empty screen, and never in Zen, whose
    /// own empty screen is `.empty` too (CONTEXT.md: Checked Off).
    public var showsCheckedOffCount: Bool {
        hasCheckedOffToShow && (screenMode == .list || screenMode == .empty)
    }
    /// Something checked off today, and not in Zen, which shows only
    /// active work.
    private var hasCheckedOffToShow: Bool {
        checkedOffCount > 0 && !isZenFocusModeEnabled
    }
    /// Whether the Checked Off sheet is open. Settable so the sheet's
    /// Done button and Esc can close it; opening goes through
    /// `toggleCheckedOffSheet()`. Nothing closes it on its own when it
    /// empties, so it never vanishes from under the user.
    @Published public var isCheckedOffSheetPresented = false
    /// Which of the five screens the window shows, and the Sections a
    /// `.list` or `.zen` screen draws. Worked out here, in `republish()`
    /// and whenever one of their inputs changes, so the view only reads
    /// them.
    /// The ids of the Suggestions the Inbox offers "Not for me" on
    /// (inbox-not-for-me). Worked out when the list republishes and when
    /// History's actions change something, never per render.
    @Published public private(set) var notForMeOffers: Set<String> = []
    @Published public private(set) var screenMode: ScreenMode = .loading
    @Published public private(set) var sections: [DailyOSCore.Section] = []
    /// The moment `rankedList` was ranked against. Every gesture on the
    /// list is judged against this rather than a fresh clock read, so just
    /// after midnight a drop or a row's actions follow the Tiers on
    /// screen until the day change derives the list again (ADR 0042).
    private var rankedAt: Date
    /// "Now", injected so a test can stand just before midnight. Read for
    /// ranking and for snoozing only.
    private let now: @MainActor () -> Date
    /// Brings Snoozed rows back when their snooze ends (ADR 0045). The
    /// day-change refresh comes at midnight, but a snooze ends at 8 AM.
    private let snoozeWakeClock: any UndoClock
    /// When the one wake-up `snoozeWakeClock` holds is for, and a token
    /// telling it apart from any it replaced, whose late firing does
    /// nothing.
    private var snoozeWake: (at: Date, token: Int)?
    private var snoozeWakeToken = 0
    @Published public var isLoading = true {
        didSet { updateScreen() }
    }
    /// The Undo bar's offer (CONTEXT.md: Undo bar), or `nil` when the bar
    /// is hidden. A mirror of `undoBar.current` for SwiftUI's sake.
    @Published public private(set) var undoOffer: UndoOffer?
    private let undoBar: UndoBar
    /// Owned here rather than as `ContentView` local `@State` because the
    /// trailing-edge toolbar buttons are hosted in a separate view
    /// hierarchy (their own `NSToolbarItem`, not a `ContentView`
    /// descendant) and need a shared place to signal "open the add sheet."
    @Published public var isAddingTask = false

    /// Whether each Source shows as Unavailable, read from the Signal
    /// Board by `republish()` so that a Gate any read finds missing shows
    /// at once, whichever verb made the read.
    @Published public private(set) var messagesNeedFullDiskAccess = false
    @Published public private(set) var remindersUnavailable = false
    /// A signing identity that changed since the last launch (ticket 10).
    /// Shows Messages as Unavailable from launch until the first pass
    /// reads Messages and finds out for itself.
    private var messagesIdentityMismatch = false
    @Published public var extractionUnavailable = false {
        didSet { updateScreen() }
    }
    @Published public var backfillProgress: (completed: Int, total: Int)? {
        didSet { updateScreen() }
    }
    /// Which kind of Messages pass is running (ADR 0034), `nil` when none
    /// is: the input behind Re-extract being disabled rather than queueing
    /// invisibly. Mirrored from intake's `runningPass` through
    /// `onPassChange`, because SwiftUI has to redraw the control when it
    /// changes and DailyOSCore cannot notify anyone (ADR 0020). Intake
    /// reports the pass itself, so callers joining one pass never need
    /// counting.
    @Published public private(set) var runningMessagesPass: PassKind?
    public var isMessagesPassRunning: Bool { runningMessagesPass != nil }
    @Published public var reExtractionProgress: (completed: Int, total: Int)?
    /// The Suggestion keyboard triage acts on (batched-extraction ticket
    /// 08), or `nil` when nothing is focused. Cleared whenever that
    /// Suggestion leaves the Inbox by any route.
    @Published public var focusedSuggestionId: String?
    /// The Suggestion whose context popover is open (batched-extraction
    /// ticket 09), or `nil`. Cleared, like focus, once it leaves the Inbox.
    @Published public var previewedSuggestionId: String?
    /// Zen Focus Mode (ticket 06): backed by `ZenFocusModePreference`, a
    /// thin typed wrapper over a single `UserDefaults` flag — see its own
    /// doc comment for why it isn't just a bare `UserDefaults` call here.
    @Published public var isZenFocusModeEnabled = false {
        didSet {
            zenFocusModePreference.isEnabled = isZenFocusModeEnabled
            // Zen shows only active work, so the Checked Off sheet closes
            // on the way in (CONTEXT.md: Zen Focus Mode).
            if isZenFocusModeEnabled {
                isCheckedOffSheetPresented = false
            }
            updateScreen()
        }
    }
    /// Zen Focus Mode's content-hugging window sizing: the natural height
    /// `ContentView.zenContent`'s `GeometryReader` measured for whatever's
    /// actually showing (Suggested + Focus, Later already excluded).
    /// `ZenWindowSizer` (main.swift) is the only reader; kept on `AppModel`
    /// rather than passed as a closure so `ContentView` doesn't need a
    /// second initializer parameter just for this.
    @Published public var idealZenContentHeight: CGFloat = 0
    /// Minimal View (ticket 03, unified-window-and-minimal-view): collapses
    /// the unified window's sidebar/toolbar/footer down to a single-pane
    /// Main display. Deliberately distinct from and independent of Zen
    /// Focus Mode above — Minimal View operates on window chrome, Zen
    /// Focus Mode on which Sections are drawn, and neither reads the
    /// other's state. Not persisted across launches (unlike Zen Focus
    /// Mode's `UserDefaults`-backed preference): this is read by both
    /// AppKit (`MinimalViewToolbarController`, hiding the `NSToolbar`) and
    /// SwiftUI (`AppShellView`, collapsing `NavigationSplitView`'s
    /// sidebar column) off the one shared flag, the same split Zen Focus
    /// Mode's own toggle already has between `ActionsToolbarDelegate` and
    /// `ContentView`.
    @Published public var isMinimalViewEnabled = false
    /// Global Hotkey Input (ticket 01), moved here from a bare `main.swift`
    /// local so the SwiftUI "More" menu (`AppShellView`'s `.toolbar`) can
    /// read and set it reactively — the actual system-wide registration
    /// stays in `main.swift` (`GlobalHotKeyManager`, AppKit-only), watching
    /// this published value the same way `MinimalViewToolbarController`
    /// watches `isMinimalViewEnabled`.
    @Published public var captureHotkeyPreset: CaptureHotkeyPreset {
        didSet { captureHotkeyPreference.selected = captureHotkeyPreset }
    }
    /// The Focus list in Reminders (ADR 0048), from Advanced. Turning it
    /// off sends every reminder in it back to its own list.
    @Published public var isFocusListEnabled: Bool {
        didSet { focusList.isEnabled = isFocusListEnabled }
    }
    /// Held directly, alongside handing the same instance to `board` at
    /// init, purely for `start()`'s one-time Gate request — requesting
    /// access is a launch-time action, not part of reading or ranking, so
    /// it stays outside what the Signal Board owns.
    private let taskSource: any TaskSource
    private let contactsResolver: any ContactsResolver
    private let board: SignalBoard
    /// Writes a check-off once the Undo bar lets it go.
    private let checkOffCoordinator: CheckOffCoordinator
    private let settingsOpener: any SettingsOpener
    private let refreshClock: any RefreshClock
    private let eventKitChanges: any EventKitChangeObserver
    private let messagesChanges: any MessagesChangeObserver
    private let foregroundObserver: any ForegroundObserver
    private let dayChanges: any DayChangeObserver
    private let zenFocusModePreference: ZenFocusModePreference
    private let captureHotkeyPreference: CaptureHotkeyPreference
    /// Keeps the Focus list in Reminders in line with the Focus Tier
    /// (ADR 0048), told each time the list is derived.
    private let focusList: FocusList
    /// Extraction settings (ticket 04): the prompt and model path
    /// `loadExtractor()` reads instead of always using the built-in
    /// defaults. Injectable the same way every other preference wrapper
    /// here is, so a test can point at an isolated `UserDefaults` suite.
    private let extractionSettings: ExtractionSettings
    /// Re-extraction's own scope and cooldown: `reExtract()` and
    /// `canReExtract` both read this instead of the old fixed "unbounded,
    /// no cooldown" behavior.
    private let reExtractionSettings: ReExtractionSettings
    /// Messages Intake (CONTEXT.md), held here rather than behind the
    /// Signal Board: every pass result is handed to `board.apply(messages:)`
    /// (ADR 0020, amended 2026-09-26).
    private let intake: MessagesIntake
    /// History (ADR 0029): handed straight to `MessagesIntake`, which
    /// threads it through to `Extraction.swift`'s writer, and to
    /// `historyActions` for Re-run. The Models tab's `ModelDownloading`
    /// seam has no relationship to the extraction pipeline at all, so unlike
    /// this it is never held here — `main.swift` hands it straight to
    /// `ModelsViewModel`, the only thing that ever touches it.
    private let historyStore: any HistoryStore
    /// Mute Thread (ADR 0032) and Restore (superseded-restore): handed to
    /// `historyActions` without widening what `board` or
    /// `checkOffCoordinator` are handed, since neither needs this state.
    private let signalStore: any BatchLedger & MessagesIntakeState
    /// Corrections (ADR 0031): what each History action records, which
    /// Batches are corrected, and what Rule proposals learn from. Held here
    /// rather than by the Signal Board, since History's actions are not
    /// the Board's concern. Handed to `historyActions`, which records
    /// through it; public so tests read Corrections back the same way.
    public let corrections: Corrections
    /// Every action on a History Batch (ADR 0031, 0032, 0036), handed to
    /// History's view model.
    public private(set) lazy var historyActions = HistoryBatchActions(
        app: self, intake: intake, historyStore: historyStore, signalStore: signalStore, corrections: corrections,
        screeningSettings: screeningSettings
    )
    /// Screening (ADR 0036): the preferences, the Keychain-backed key, and
    /// how to build a Screener from a key. The last is a seam so a test
    /// never makes a network call.
    private let screeningSettings: ScreeningSettings
    private let apiKeyStore: any APIKeyStore
    private let makeScreener: @Sendable (String) -> any Screener
    /// Wraps the Screener intake is given, and outlives passes so an outage
    /// found by one pass spares the next (screening-optional). Rebuilt,
    /// which closes it, when the toggle or key changes; kept with the key
    /// its Screener was built from, so a new key always gets its own.
    private var screeningBreaker: (key: String, breaker: ScreeningBreaker)?
    /// Approved Rules (ADR 0038), handed to the extractor whenever one is
    /// loaded and whenever the set changes.
    private let ruleStore: any RuleStore

    private var isReExtracting = false
    private var refreshCoordinator: RefreshCoordinator?
    /// `deleteTask`'s own optimistic hiding. A check-off is hidden by the
    /// Undo bar while offered and by `checkOffCoordinator` while written.
    private var deletingSignalIDs: Set<String> = []

    /// Excluded from every `republish()` before dedup, tiering or the
    /// Later cap ever sees them. The Signal Board never learns why any
    /// of them are hidden.
    private var hidingIDs: Set<String> {
        undoBar.hiddenIDs.union(checkOffCoordinator.hiddenIDs).union(deletingSignalIDs)
    }

    /// Built only from `dependencies`, which carries no defaults: the
    /// executable passes `AppDependencies.live(...)` and a test passes a
    /// test value, so a test never opens a live store by accident.
    public init(_ dependencies: AppDependencies) {
        self.taskSource = dependencies.taskSource
        self.contactsResolver = dependencies.contactsResolver
        let filteredSMSSettings = dependencies.filteredSMSSettings
        let intake = MessagesIntake(
            messagesSource: dependencies.messagesSource, signalStore: dependencies.signalStore,
            contactsResolver: dependencies.contactsResolver, bundlePath: dependencies.bundlePath,
            participantLabelStore: dependencies.participantLabelStore, historyStore: dependencies.historyStore,
            correctionStore: dependencies.correctionStore, extractor: dependencies.extractor,
            batchWakeClock: dependencies.batchWakeClock, auditRoll: dependencies.auditRoll,
            ignoresFilteredSMS: { filteredSMSSettings.ignoresFilteredSMS }
        )
        self.intake = intake
        self.board = SignalBoard(taskSource: dependencies.taskSource, signalStore: dependencies.signalStore, now: dependencies.now)
        self.focusList = FocusList(
            taskSource: dependencies.taskSource, store: dependencies.signalStore, board: board,
            preference: dependencies.focusListPreference
        )
        self.isFocusListEnabled = dependencies.focusListPreference.isEnabled
        self.checkOffCoordinator = CheckOffCoordinator(taskSource: dependencies.taskSource, signalStore: dependencies.signalStore)
        self.undoBar = UndoBar(clock: dependencies.undoClock, window: dependencies.undoWindow)
        self.settingsOpener = dependencies.settingsOpener
        self.refreshClock = dependencies.refreshClock
        self.eventKitChanges = dependencies.eventKitChanges
        self.messagesChanges = dependencies.messagesChanges
        self.foregroundObserver = dependencies.foregroundObserver
        self.dayChanges = dependencies.dayChanges
        self.zenFocusModePreference = dependencies.zenFocusModePreference
        self.isZenFocusModeEnabled = dependencies.zenFocusModePreference.isEnabled
        self.captureHotkeyPreference = dependencies.captureHotkeyPreference
        self.captureHotkeyPreset = dependencies.captureHotkeyPreference.selected
        self.extractionSettings = dependencies.extractionSettings
        self.reExtractionSettings = dependencies.reExtractionSettings
        self.historyStore = dependencies.historyStore
        self.signalStore = dependencies.signalStore
        self.corrections = Corrections(store: dependencies.correctionStore)
        self.screeningSettings = dependencies.screeningSettings
        self.apiKeyStore = dependencies.apiKeyStore
        self.makeScreener = dependencies.makeScreener
        self.ruleStore = dependencies.ruleStore
        self.now = dependencies.now
        self.rankedAt = dependencies.now()
        self.snoozeWakeClock = dependencies.snoozeWakeClock

        // Wired last, once every stored property above has a value:
        // `self` only becomes a valid `[weak self]` capture at that point.
        // A Batch left open by a pass wakes a Messages refresh through the
        // same path every other trigger takes (batched-extraction ticket 05).
        intake.onPassChange = { [weak self] kind in
            guard let self else { return }
            self.runningMessagesPass = kind
            // A pass writes History rows as it goes; History shows them once
            // it ends.
            if kind == nil { self.historyActions.changed() }
        }
        intake.onBatchDue = { [weak self] in
            Task { await self?.handleRefresh(.batchDue) }
        }
        self.checkOffCoordinator.onChange = { [weak self] in
            self?.republish()
        }
        self.undoBar.onChange = { [weak self] in
            guard let self else { return }
            self.undoOffer = self.undoBar.current
            self.republish()
        }
        self.focusList.onChange = { [weak self] in
            self?.republish()
        }
        self.checkOffCoordinator.onCommitted = { [weak self] in
            await self?.reload()
        }
    }

    /// Loading the model (reading a ~2.5GB file, allocating KV cache
    /// buffers) is too slow for the main actor. A missing or unloadable
    /// model degrades to `extractionUnavailable`, the same "surface it,
    /// never block" treatment ticket 10 gives a missing Gate — Messages
    /// reading and Reminders both keep working either way.
    ///
    /// An extractor supplied at init is taken as final and nothing is
    /// loaded: otherwise `start()` reads the real 2.5GB model off this
    /// machine's disk, which a test must never do.
    private func loadExtractor() async {
        // Whichever extractor ends up loaded, it starts with the current
        // Rules (ADR 0038), and History's model-bound actions follow it.
        defer {
            applyRules()
            historyActions.changed()
        }
        guard intake.extractor == nil else { return }
        let modelPath = extractionSettings.effectiveModelPath(bundleIdentifier: bundleIdentifier)
        let promptOverride = extractionSettings.effectivePromptOverride
        let loaded: LlamaCppIntentExtractor? = await Task.detached {
            do {
                return try LlamaCppIntentExtractor(modelPath: modelPath, promptOverride: promptOverride)
            } catch {
                FileHandle.standardError.write(Data("DailyOS: failed to load the local extraction model: \(error)\n".utf8))
                return nil
            }
        }.value

        if let loaded {
            intake.extractor = loaded
            extractionUnavailable = false
        } else {
            extractionUnavailable = true
        }
    }

    /// Hands the stored Rules to the loaded extractor. A no-op until a
    /// model is loaded; `loadExtractor` calls this once one is.
    public func applyRules() {
        intake.extractor?.setRules(ruleStore.rules().map(\.text))
    }

    /// Whether "Propose rules" can run: a model that can generate free
    /// text, no intake pass holding it, and at least five "Not for me"
    /// Corrections since the last proposal. False-negative Corrections
    /// never count: they are about Screening, not the model (ADR 0038).
    public func ruleProposalStatus() -> RuleProposalStatus {
        guard intake.extractor is FreeTextGenerating else { return .noModel }
        guard runningMessagesPass == nil, !isReExtracting else { return .passRunning }
        let count = newFalsePositives().count
        return count >= minimumCorrectionsForProposal ? .ready(newCorrections: count) : .needsMoreCorrections(have: count)
    }

    /// Asks the local model for up to three general Rules from the new
    /// "Not for me" Corrections, newest first and as many as fit, then
    /// moves the watermark so the count starts again. Nothing is approved
    /// here; the caller shows the result for review.
    public func proposeRules() async -> [String] {
        guard case .ready = ruleProposalStatus(), let generator = intake.extractor as? FreeTextGenerating else { return [] }
        let tokenBudget = (intake.extractor?.maxPromptTokens ?? 0) - ruleProposalMaxTokens
        var chosen: [Correction] = []
        for correction in newFalsePositives() {
            let candidate = chosen + [correction]
            guard (intake.extractor?.estimatedTokenCount(for: ruleProposalUserPrompt(corrections: candidate)) ?? .max) <= tokenBudget
            else { break }
            chosen = candidate
        }
        guard !chosen.isEmpty else { return [] }
        let startedAt = Date()
        let raw = (try? await generator.generateText(
            system: ruleProposalSystemPrompt, user: ruleProposalUserPrompt(corrections: chosen),
            maxTokens: ruleProposalMaxTokens, priority: .userInitiated
        )) ?? ""
        let proposed = parseProposedRules(raw)
        // Only a proposal that produced something uses the Corrections up.
        // A failed or empty generation leaves the count where it was, so the
        // user can simply try again.
        if !proposed.isEmpty {
            ruleStore.proposalWatermark = startedAt
        }
        return proposed
    }

    private func newFalsePositives() -> [Correction] {
        corrections.falsePositives(since: ruleStore.proposalWatermark)
    }

    /// Reads Screening settings and the stored key and hands intake the
    /// result. No key, or Screening off, leaves intake local-only.
    public func applyScreeningSettings() {
        let key = apiKeyStore.read()
        let mode = effectiveScreeningMode(settings: screeningSettings, apiKey: key)
        guard mode != .off, let key else {
            intake.setScreening(nil, mode: .off)
            return
        }
        if screeningBreaker?.key != key {
            screeningBreaker = (key, ScreeningBreaker(screener: makeScreener(key)))
        }
        intake.setScreening(screeningBreaker?.breaker, mode: mode)
    }

    public func applyScreeningAccessChange() {
        screeningBreaker = nil
        applyScreeningSettings()
        // The toggle decides what History shows about Screening, and which
        // of "This was work" and "Add task" a Screened Batch offers.
        historyActions.changed()
    }

    public func retryLoadingExtractor() async {
        extractionUnavailable = false
        await loadExtractor()
    }

    /// Extraction settings (ticket 04): the "explicit re-load action" a
    /// changed prompt or model path takes effect on, without waiting for
    /// a full app relaunch. Unlike `retryLoadingExtractor` — which only
    /// loads when there currently is none — this unconditionally drops
    /// whatever's loaded first, since the common case here is a working
    /// extractor whose settings just changed, not a missing one.
    public func applyExtractionSettingsChange() async {
        intake.extractor = nil
        // History's model-bound actions show disabled while the new one loads.
        historyActions.changed()
        extractionUnavailable = false
        await loadExtractor()
    }

    /// The active model's file was deleted. Releasing the extractor frees
    /// the model's memory once no pass holds it, and with no extractor
    /// intake skips extraction and leaves Batches unprocessed for the next
    /// model. Nothing is reloaded: the path now points at nothing.
    public func unloadExtractor() {
        intake.extractor = nil
        historyActions.changed()
        extractionUnavailable = true
    }

    /// Whether the model path points at a file. False once the active
    /// model is deleted, which the footer shows as "No model selected".
    public var hasModelFile: Bool {
        FileManager.default.fileExists(atPath: extractionSettings.effectiveModelPath(bundleIdentifier: bundleIdentifier))
    }

    /// Settings' footer (ADR 0027): `nil` while no model is loaded, the same
    /// moment `extractionUnavailable` is `true` — there is nothing to name.
    public var activeModelDisplayName: String? {
        intake.extractor?.modelDisplayName
    }

    /// "Not for me"'s effect on the Signal Board: the open Signals the
    /// Batch produced are dismissed.
    func dismissMessages(sourceRef: String) {
        board.dismiss(sourceRef: sourceRef)
        republish()
    }

    /// Re-reads which Suggestions offer "Not for me". Called by
    /// `republish()` and whenever `historyActions` changes something.
    func updateNotForMeOffers() {
        let offers = historyActions.suggestionsOfferingNotForMe(rankedList.suggested)
        if offers != notForMeOffers { notForMeOffers = offers }
    }

    /// "This was work"'s pass: the one Batch, straight to the model.
    func extractNow(sourceRef: String) async {
        applyMessages(await intake.extractNow(sourceRef: sourceRef))
    }

    /// Stores a Signal against its already-Processed Batch, as
    /// re-extraction does, and puts it on the Board.
    func addMessageSignal(_ signal: Signal) {
        if intake.addSignal(signal) {
            board.seed(messages: intake.storedSignals())
        }
        republish()
    }

    /// Undo of "Not for me" (inbox-undo): puts `signalIds` back to open.
    func reopenMessageSignals(_ signalIds: [String]) {
        for id in signalIds { board.reopen(signalId: id) }
        reloadMessageSignals()
    }

    /// Re-reads the stored Messages Signals onto the Board, after History
    /// changed them in the store directly.
    func reloadMessageSignals() {
        board.seed(messages: intake.storedSignals())
        republish()
    }

    private func applyMessages(_ result: MessagesIntake.Result) {
        applyPass(result)
        republish()
    }

    /// A pass's result onto the Board. A pass has read Messages, so a
    /// launch-time identity mismatch no longer decides anything.
    private func applyPass(_ result: MessagesIntake.Result) {
        board.apply(messages: result)
        messagesIdentityMismatch = false
    }

    /// Fires once during `start()`, as soon as Reminders and every stored
    /// Signal are on the Ranked List and before the slow model load and
    /// Messages pass. The Morning Brief's launch catch-up waits for it, so
    /// it never texts a list that hasn't loaded yet.
    public var onStoredListReady: (() -> Void)?

    /// Requests the Reminders Gate, then does the first fetch. A denied
    /// Gate degrades its Source to Unavailable (ticket 10) rather than
    /// blocking the app. Full Disk Access has no equivalent request API —
    /// EventKit's is unusual in offering one — so the Messages read is
    /// just attempted, and failure surfaces the System Settings prompt.
    /// The Contacts Gate (ADR 0008) is requested here too, the same
    /// fire-and-forget shape as Reminders': a denied or ignored prompt
    /// just means `contactsResolver` resolves nothing later, degrading
    /// Sender to the raw address rather than blocking anything.

    public func start() async {
        // The identity comparison only matters on launch — it can't
        // change mid-session (ticket 10) — so this runs once, before the
        // first read attempt. `reloadMessages()` still runs its own
        // availability() probe right after and is the authoritative
        // source of truth once it does; see `MessagesIntake.identityMismatch`.
        messagesIdentityMismatch = intake.identityMismatch()
        setUpRefreshCoordinator()
        applyScreeningSettings()
        _ = try? await taskSource.requestAccess()
        _ = try? await contactsResolver.requestAccess()
        await reload()

        // ADR 0035. Everything extraction has ever produced is in the store,
        // so the list the window should draw is knowable before any of the
        // slow launch work below runs — loading a 2.5GB model, reading
        // chat.db, and running a week of messages through the model, which
        // together take minutes on a real database. Waiting on all of that
        // to clear `isLoading` meant a full store rendered as "Loading…"
        // for the entire pass. A first run genuinely has nothing to show,
        // so it keeps waiting: `backfillProgress` takes over the screen
        // moments later (see `screenMode`), and clearing early there would
        // flash "Nothing open. Nice." at someone whose backfill is about to
        // start.
        board.seed(messages: intake.storedSignals())
        republish()
        onStoredListReady?()
        if signalStore.isBackfillComplete() {
            isLoading = false
        }

        await loadExtractor()
        await reloadMessages()
        isLoading = false
    }

    /// Wires up the refresh triggers: `chat.db` writes (ADR 0034
    /// amendment), `chat.db` polled on `chatDBPollIntervalSeconds` as the
    /// backstop, an immediate refetch on every EventKit
    /// change notification (this is also how Reminders revocation and
    /// Gate re-checks arrive — ticket 10), and the window coming to the
    /// foreground, which is the moment a user who just granted a Gate in
    /// System Settings is most likely to switch back. Full Disk Access
    /// gets no push of its own; its recovery relies on the foreground
    /// re-check plus the manual retry control. The day changing derives
    /// the Ranked List again, since Tier depends on the day (ADR 0042).
    private func setUpRefreshCoordinator() {
        refreshCoordinator = RefreshCoordinator(
            pollInterval: chatDBPollIntervalSeconds,
            clock: refreshClock,
            eventKitChanges: eventKitChanges,
            foreground: foregroundObserver,
            messagesChanges: messagesChanges,
            dayChanges: dayChanges
        ) { [weak self] trigger in
            Task { @MainActor in
                await self?.handleRefresh(trigger)
            }
        }
    }

    /// Which Source(s) each trigger means is `sourcesToRefresh(for:)`'s
    /// call, not this one — this just executes whichever it names, in the
    /// same order a `.foreground` trigger always has (Reminders, then
    /// Messages).
    private func handleRefresh(_ trigger: RefreshTrigger) async {
        let sources = sourcesToRefresh(for: trigger)
        if sources.contains(.reminders) {
            await reload()
        }
        if sources.contains(.messages) {
            await reloadMessages()
        }
        if sources.isEmpty {
            republish()
        }
    }

    /// Retriable directly from the UI (`UnavailableSourceRow`'s retry
    /// control), not just reachable through a refresh trigger.
    public func reload() async {
        await board.refreshReminders()
        republish()
    }

    /// Retriable directly from the UI (`UnavailableSourceRow`'s retry
    /// control), not just reachable through a refresh trigger. `.background`
    /// (extraction QoS): every caller of this — the chat.db poll, a
    /// foreground trigger, an EventKit change, and this retry control — is
    /// silent/automatic from the user's point of view, so the actual model
    /// work should never contend with the UI for the main thread's
    /// attention. Contrast `reExtract()`, the one path a user explicitly
    /// waits on a progress readout for.
    public func reloadMessages() async {
        let result = await intake.refresh(now: Date(), priority: .background) { [weak self] completed, total in
            Task { @MainActor in
                self?.backfillProgress = (completed, total)
            }
        }
        applyPass(result)
        backfillProgress = nil
        republish()
    }

    public func openFullDiskAccessSettings() {
        settingsOpener.open(.fullDiskAccess)
    }

    public func openRemindersSettings() {
        settingsOpener.open(.reminders)
    }

    /// ticket 12's manual re-extraction: never called automatically, only
    /// from a user-initiated action (ADR 0004, unchanged). `canReExtract`
    /// is the UI-facing enablement rule the toolbar checks before ever
    /// calling this; `isReExtracting` is this function's own narrower
    /// re-entrancy guard, checked independently in case something calls it
    /// anyway. `reExtractionSettings.lastRunAt` is recorded the moment this
    /// starts, not when it finishes — a slow run shouldn't leave the
    /// cooldown reading as if no run had started at all. `.utility`
    /// (extraction QoS): unlike `reloadMessages()`'s automated triggers,
    /// this only ever runs from an explicit click the toolbar shows a
    /// progress readout for — lower than the default so it still yields to
    /// the UI, but not deprioritized behind background work the way an
    /// automated pass is.
    public func reExtract() async {
        guard !isReExtracting else { return }
        isReExtracting = true
        defer { isReExtracting = false }
        reExtractionSettings.lastRunAt = Date()

        let result = await intake.reExtract(
            now: Date(), lookbackDays: reExtractionSettings.lookbackDays, priority: .utility
        ) { [weak self] completed, total in
            Task { @MainActor in
                self?.reExtractionProgress = (completed, total)
            }
        }
        applyPass(result)
        reExtractionProgress = nil
        republish()
    }

    /// The UI-facing enablement rule for the manual re-extraction control,
    /// read only by the File menu's `validateMenuItem` (main.swift) —
    /// pulled out into one property here so the rule reads in one place
    /// instead of only inside AppKit plumbing. `reExtractionAllowed` is the
    /// one condition here that depends on the wall clock rather than
    /// `AppModel`'s own `@Published` state, kept as a separately-testable
    /// pure function for the same reason `Ranking.rank(_:now:)` takes `now`
    /// as a parameter instead of minting it internally.
    ///
    /// `isMessagesPassRunning` is here because ADR 0034 made a click during
    /// a running pass wait for that pass rather than no-op, and ADR 0035
    /// stopped `isLoading` from covering the launch pass. Without it the
    /// control reads as enabled and then appears to do nothing for however
    /// long the pass takes, which is the failure the disable is for.
    public var canReExtract: Bool {
        reExtractionProgress == nil && !isLoading && backfillProgress == nil
            && !isMessagesPassRunning
            && !messagesNeedFullDiskAccess && !extractionUnavailable
            && reExtractionAllowed(
                now: Date(), lastRunAt: reExtractionSettings.lastRunAt,
                minimumIntervalHours: reExtractionSettings.minimumIntervalHours
            )
    }

    /// The File menu's Re-run Extraction item: its own name when it can
    /// run, otherwise the kind of pass that is holding the model.
    public var reExtractionMenuTitle: String {
        switch runningMessagesPass {
        case nil: "Re-run Extraction"
        case .automatic: "Checking Messages…"
        case .reExtraction: "Re-extracting…"
        case .explicit: "Checking a Batch…"
        }
    }

    /// The one place a moment is minted for ranking — every verb below
    /// ends by calling this instead of computing anything about Tier,
    /// order, or visibility itself. The moment is kept with the list, so
    /// gestures are judged against the same day the list shows.
    private func republish() {
        rankedAt = now()
        let remindersOut = board.availability(of: .reminders) == .unavailable
        if remindersOut != remindersUnavailable { remindersUnavailable = remindersOut }
        let messagesOut = messagesIdentityMismatch || board.availability(of: .messages) == .unavailable
        if messagesOut != messagesNeedFullDiskAccess { messagesNeedFullDiskAccess = messagesOut }
        rankedList = board.rankedList(now: rankedAt, hiding: hidingIDs)
        checkedOff = board.checkedOff(now: rankedAt, hiding: hidingIDs)
        checkedOffCount = checkedOff.count
        updateScreen()
        updateNotForMeOffers()
        if let focused = focusedSuggestionId, !rankedList.suggested.contains(where: { $0.id == focused }) {
            focusedSuggestionId = nil
        }
        if let previewed = previewedSuggestionId, !rankedList.suggested.contains(where: { $0.id == previewed }) {
            previewedSuggestionId = nil
        }
        scheduleSnoozeWake()
        focusList.listDerived(at: rankedAt)
    }

    /// Waits for every Focus list sync asked for so far, and any each one
    /// leads to. For tests.
    public func focusListSettled() async {
        await focusList.settled()
    }

    /// The Morning Brief's text (ADR 0046), from the Ranked List derived
    /// afresh for this moment rather than the last published one, so a
    /// snooze ending at 8:00 AM is back in it whichever timer fires first.
    public func morningBriefText(format: MorningBriefFormat = .standard) -> String {
        let moment = now()
        return composeMorningBrief(board.rankedList(now: moment, hiding: hidingIDs), now: moment, format: format)
    }

    /// One wake-up, for the earliest snooze still running, replacing any
    /// scheduled for a different moment. Firing derives the list again.
    private func scheduleSnoozeWake() {
        let earliest = rankedList.snoozed.first?.snoozedUntil
        guard earliest != snoozeWake?.at else { return }
        snoozeWakeToken += 1
        guard let earliest else {
            snoozeWake = nil
            return
        }
        let token = snoozeWakeToken
        snoozeWake = (earliest, token)
        snoozeWakeClock.scheduleOnce(after: max(earliest.timeIntervalSince(rankedAt), 0)) { [weak self] in
            Task { @MainActor in
                guard let self, self.snoozeWake?.token == token else { return }
                self.snoozeWake = nil
                self.republish()
            }
        }
    }

    /// Works out `screenMode` and `sections` from the list and the flags
    /// they depend on. Called by `republish()` and by each flag's `didSet`.
    private func updateScreen() {
        screenMode = decideScreenMode(
            rankedList: rankedList, isLoading: isLoading, backfillProgress: backfillProgress,
            isZen: isZenFocusModeEnabled, messagesNeedFullDiskAccess: messagesNeedFullDiskAccess,
            remindersUnavailable: remindersUnavailable, extractionUnavailable: extractionUnavailable
        )
        sections = decideSections(
            from: rankedList, isZen: isZenFocusModeEnabled, messagesNeedFullDiskAccess: messagesNeedFullDiskAccess,
            remindersUnavailable: remindersUnavailable, extractionUnavailable: extractionUnavailable
        )
    }

    /// Held back on the Undo bar, and written by `checkOffCoordinator`
    /// once the offer ends (ADR 0022). Writing it also ends any snooze, so
    /// a recurring reminder's next occurrence, which keeps the same id,
    /// doesn't start out hidden (ADR 0045).
    public func checkOff(_ signal: Signal) {
        undoBar.offer(.checkedOff, label: signal.label, .heldBack(hiding: signal.id) { [weak self] in
            self?.board.unsnooze(signalId: signal.id)
            self?.checkOffCoordinator.commit(signal)
        })
    }

    /// Unchecking a Checked Off row: reopens the reminder, which goes back
    /// to Focus or Later. No Undo bar, and ⌘Z doesn't reach it.
    public func uncheck(_ reminder: CheckedOffReminder) async {
        await board.uncheck(reminder)
        republish()
    }

    /// The count's click: opens the Checked Off sheet when there is
    /// something in it, or closes it if it's open, empty or not.
    public func toggleCheckedOffSheet() {
        guard canToggleCheckedOffSheet else { return }
        isCheckedOffSheetPresented.toggle()
    }

    /// Whether the count's click and the View menu's ⇧⌘C do anything: an
    /// open sheet can always be closed, and a closed one opens only with
    /// something in it and outside Zen.
    public var canToggleCheckedOffSheet: Bool {
        isCheckedOffSheetPresented || hasCheckedOffToShow
    }

    /// The app is about to quit. A check-off still held back on the Undo
    /// bar is written before this returns, so it isn't lost with the
    /// process (ADR 0043).
    public func prepareToQuit() {
        // The coordinator first, so the held-back offer's commit writes inline.
        checkOffCoordinator.prepareToQuit()
        undoBar.flush()
    }

    /// The Undo bar's button, and ⌘Z: reverses whatever the bar offers.
    /// Does nothing when the bar is hidden or only reports.
    public func undo() async {
        await undoBar.undo()
    }

    /// Messages Signals only: Dismiss means "Extraction produced a false
    /// positive," and Reminders Signals never go through Extraction, so
    /// there's nothing for it to mean there (see CONTEXT.md: Dismiss).
    /// Written at once, unlike check-off, and reversed if the Undo bar's
    /// Undo is pressed (ADR 0043).
    public func dismiss(_ signal: Signal) {
        guard signal.source == .messages else { return }
        board.dismiss(signal)
        republish()
        undoBar.offer(.dismissed, label: signal.label, .reversible { [weak self] in
            guard let self else { return }
            self.board.reopen(signalId: signal.id)
            self.reloadMessageSignals()
            self.focusSuggestion(signal.id)
        })
    }

    /// The Inbox's thumbs-down: History's "Not for me" on the Suggestion's
    /// Batch, then the Undo bar, whose Undo reverses it the way History's
    /// Undo does (ADR 0043).
    public func notForMe(_ suggestion: Signal) {
        guard historyActions.notForMe(suggestion) else { return }
        undoBar.offer(.notForMe, label: suggestion.label, .reversible { [weak self] in
            guard let self else { return }
            self.historyActions.undoNotForMe(of: suggestion)
            self.focusSuggestion(suggestion.id)
        })
    }

    /// Keyboard focus on `id`, if it's in the Inbox: after Undo brings a
    /// Suggestion back, the next key acts on it.
    private func focusSuggestion(_ id: String) {
        if rankedList.suggested.contains(where: { $0.id == id }) { focusedSuggestionId = id }
    }

    /// One-click promotion (ticket 05): sets `signal`'s priority to
    /// `.high`, which is the entire mechanism — `tier(for:)` already puts
    /// anything carrying a priority into Focus (ADR 0009), so nothing else
    /// about ranking needs to change. No demote counterpart for a row its
    /// due date holds in Focus (ADR 0009's noted asymmetry, ADR 0042).
    public func promote(_ signal: Signal) async {
        await board.promote(signal)
        republish()
    }

    /// One-click demotion: the reverse of `promote`.
    public func demote(_ signal: Signal) async {
        await board.demote(signal)
        republish()
    }

    /// Snoozes `signal` off the ranked list until `until`, applying
    /// uniformly regardless of source (see CONTEXT.md: Snoozed). Just a
    /// store write plus a republish — `rankedList` reads `snoozedUntil`
    /// fresh on every call, so there's nothing to patch. No Undo bar.
    public func snooze(_ signal: Signal, until: Date) {
        board.snooze(signal, until: until)
        republish()
    }

    /// Unsnooze on a Snoozed row (ADR 0045): back to Focus or Later at
    /// once. No Undo bar; the row reappearing is the confirmation.
    public func unsnooze(_ signal: Signal) {
        board.unsnooze(signalId: signal.id)
        republish()
    }

    /// Tomorrow or Next Week from a row's tray or menu (ADR 0045): ends
    /// at 8:00 AM, judged by the injected clock. Written at once; Undo
    /// puts back whatever snooze the row had before, or none.
    public func snooze(_ signal: Signal, _ choice: SnoozeChoice) {
        let previous = board.snoozedUntil(signalId: signal.id)
        let until = snoozeEnd(choice, now: now())
        snooze(signal, until: until)
        undoBar.offer(.snoozed(until: until), label: signal.label, .reversible { [weak self] in
            guard let self else { return }
            if let previous {
                self.board.snooze(signal, until: previous)
            } else {
                self.board.unsnooze(signalId: signal.id)
            }
            self.republish()
        })
    }

    /// Manual Focus ordering (ADR 0011, supersedes ADR 0009): dragging
    /// `draggedId` onto `droppedOnId` moves it to sit immediately before
    /// that row, among whatever's *currently* visible in Focus —
    /// `rankedList.focus`, `hidingIDs` and all, the same list the user is
    /// actually looking at, not a fresh recompute that might disagree
    /// with it.
    private func reorderFocus(draggedId: String, droppedOnId: String) {
        board.reorderFocus(draggedId: draggedId, droppedOnId: droppedOnId, currentFocusIds: rankedList.focus.map(\.id))
        republish()
    }

    /// Where a dragged row can land: on another row, or on a Tier's header
    /// or the empty Focus drop zone, which both mean the Tier itself.
    public enum DropTarget: Equatable, Sendable {
        case row(id: String)
        case tier(Tier)
    }

    /// A row dragged onto `target`. Dropped in Focus on a row it takes that
    /// row's place (ADR 0011), after moving into Focus if it came from
    /// Later; dropped in Later it moves there. A drop the Tier rules
    /// refuse, such as a row its due date keeps in Focus into Later, does
    /// nothing. Judged against `rankedAt`, the moment the list on screen
    /// was ranked against.
    public func drop(_ draggedId: String, onto target: DropTarget) async {
        guard let (dragged, source) = row(draggedId) else { return }
        let targetId: String?
        let targetTier: Tier
        switch target {
        case .row(let id):
            guard id != draggedId, let (_, tier) = row(id) else { return }
            (targetId, targetTier) = (id, tier)
        case .tier(let tier):
            (targetId, targetTier) = (nil, tier)
        }
        switch tierDrop(of: dragged, from: source, onto: targetTier, now: rankedAt) {
        case .reorder:
            if let targetId { reorderFocus(draggedId: draggedId, droppedOnId: targetId) }
        case .promote:
            await promote(dragged)
            if let targetId { reorderFocus(draggedId: draggedId, droppedOnId: targetId) }
        case .demote:
            await demote(dragged)
        case nil:
            break
        }
    }

    /// Which actions `signal`'s row offers (ADR 0023), judged against
    /// `rankedAt` rather than a fresh clock read, so the row agrees with
    /// the Tier it's drawn in.
    public func affordances(for signal: Signal) -> SignalAffordances {
        if rankedList.snoozed.contains(where: { $0.id == signal.id }) {
            return snoozedAffordances(for: signal)
        }
        return DailyOSCore.affordances(for: signal, isLater: row(signal.id)?.tier == .later, now: rankedAt)
    }

    /// The Focus or Later row with `id` in the list on screen, and its Tier.
    private func row(_ id: String) -> (signal: Signal, tier: Tier)? {
        if let signal = rankedList.focus.first(where: { $0.id == id }) { return (signal, .focus) }
        if let signal = rankedList.later.first(where: { $0.id == id }) { return (signal, .later) }
        return nil
    }

    /// Suggested Tasks Inbox (Focus Mode v2): approving mints a real
    /// reminder and marks the originating Messages Signal `approved`
    /// (CONTEXT.md: Approve).
    /// Written at once, so the task shows where it landed, and reversed
    /// if the Undo bar's Undo is pressed (ADR 0043).
    public func approve(_ signal: Signal) async {
        let reminderId = await board.approve(signal)
        republish()
        guard let reminderId else { return }
        let tier: Tier = rankedList.focus.contains { $0.id == reminderId } ? .focus : .later
        undoBar.offer(.approved(tier), label: signal.label, .reversible { [weak self] in
            guard let self else { return }
            await self.board.unapprove(signalId: signal.id, reminderId: reminderId)
            self.reloadMessageSignals()
            self.focusSuggestion(signal.id)
        })
    }

    /// Tomorrow or Next Week on a Suggestion (ADR 0045): Approves it and
    /// Snoozes the new reminder before the Board re-fetches, so it never
    /// shows in Focus or Later. One Undo reverses both. Records
    /// nothing for extraction, like a plain Approve.
    public func approve(_ signal: Signal, snoozing choice: SnoozeChoice) async {
        let until = snoozeEnd(choice, now: now())
        let reminderId = await board.approve(signal, snoozedUntil: until)
        republish()
        guard let reminderId else { return }
        undoBar.offer(.approvedAndSnoozed(until: until), label: signal.label, .reversible { [weak self] in
            guard let self else { return }
            await self.board.unapprove(signalId: signal.id, reminderId: reminderId)
            self.reloadMessageSignals()
            self.focusSuggestion(signal.id)
        })
    }

    /// A key the Suggested Tasks Inbox answers to (batched-extraction
    /// ticket 08): arrows move focus, Return Approves, Delete Dismisses.
    public enum InboxKey: Sendable {
        case up, down, approve, dismiss
        /// Space (ticket 09): opens or closes the focused Suggestion's
        /// popover. `closePreview` is Escape.
        case togglePreview, closePreview
    }

    /// A key pressed in the window, answered at once: `true` when the
    /// Inbox takes it, `false` to leave it for anything else listening.
    /// Return, Delete and Space mean something only with a Suggestion
    /// focused, Escape only with a popover open, and nothing does while the
    /// Inbox is empty or hidden by Zen Focus Mode. A key taken is acted on
    /// in its own task.
    @discardableResult
    public func pressInboxKey(_ key: InboxKey) -> Bool {
        guard !isZenFocusModeEnabled, !rankedList.suggested.isEmpty else { return false }
        switch key {
        case .approve, .dismiss, .togglePreview:
            guard focusedSuggestionId != nil else { return false }
        case .closePreview:
            guard previewedSuggestionId != nil else { return false }
        case .up, .down:
            break
        }
        Task { await handleInboxKey(key) }
        return true
    }

    /// Keyboard triage of the Suggested Tasks Inbox. Does nothing while
    /// Zen Focus Mode hides the Inbox. Approve and Dismiss act only on the
    /// focused Suggestion, then move focus to its neighbour so the next
    /// keystroke acts on the next row. The tier an Approved Signal lands
    /// in is left to the usual rules (ADR 0002).
    public func handleInboxKey(_ key: InboxKey) async {
        guard !isZenFocusModeEnabled else { return }
        let ids = rankedList.suggested.map(\.id)
        // Read before acting: dismissing the previewed row clears it.
        let wasPreviewing = previewedSuggestionId != nil
        switch key {
        case .up:
            focusedSuggestionId = inboxFocus(moving: .up, from: focusedSuggestionId, in: ids)
        case .down:
            focusedSuggestionId = inboxFocus(moving: .down, from: focusedSuggestionId, in: ids)
        case .approve, .dismiss:
            guard let focused = focusedSuggestionId,
                  let signal = rankedList.suggested.first(where: { $0.id == focused }) else { return }
            let next = inboxFocus(afterActingOn: focused, in: ids)
            if key == .approve {
                await approve(signal)
            } else {
                dismiss(signal)
            }
            focusedSuggestionId = next.flatMap { id in rankedList.suggested.contains { $0.id == id } ? id : nil }
        case .togglePreview:
            previewedSuggestionId = previewedSuggestionId == nil ? focusedSuggestionId : nil
            return
        case .closePreview:
            previewedSuggestionId = nil
            return
        }
        // An open popover follows focus, the way Quick Look follows the
        // selection in Finder.
        if wasPreviewing {
            previewedSuggestionId = focusedSuggestionId
        }
    }

    /// Hover (ticket 09): the view calls this once the pointer has rested
    /// on a Suggestion for half a second.
    public func showPreview(forSuggestionId id: String) {
        guard rankedList.suggested.contains(where: { $0.id == id }) else { return }
        previewedSuggestionId = id
    }

    /// The pointer left `id`'s row; closes its popover if it's the open one.
    public func hidePreview(forSuggestionId id: String) {
        if previewedSuggestionId == id { previewedSuggestionId = nil }
    }

    /// Bidirectional Reminders sync (Focus Mode v2, supersedes ADR 0001):
    /// writes straight through to Reminders and re-fetches, so the ranked
    /// list always reflects exactly what Reminders itself now reports —
    /// the same source of truth an external edit would produce. Quick
    /// Capture's path: no Priority, and no report of where it landed.
    public func createTask(title: String, dueAt: Date? = nil) async {
        _ = await board.createTask(title: title, priority: .none, dueAt: dueAt)
        republish()
    }

    /// Whether Focus is drawn, so the `+` field sits inside it and what it
    /// adds keeps a Priority.
    public var showsFocus: Bool {
        switch screenMode {
        case .list, .zen: sections.contains { if case .tier(.focus, _) = $0 { true } else { false } }
        default: false
        }
    }

    /// The `+` field. Inside a drawn Focus the reminder gets a Priority so
    /// it stays where it was added; with no Focus drawn it gets none and
    /// lands in Later. A typed due date (`parseTypedDueDate`) replaces the
    /// Priority either way: the date alone decides the Tier, so Priority
    /// keeps meaning only that you flagged something. Returns the Tier it
    /// landed in, `nil` if the write failed. Landing in Later, which may be
    /// collapsed, is reported so it doesn't seem to vanish.
    @discardableResult
    public func addReminder(title: String, dueAt: Date? = nil) async -> Tier? {
        let priority: Priority = dueAt == nil && showsFocus ? .high : .none
        guard let id = await board.createTask(title: title, priority: priority, dueAt: dueAt) else {
            republish()
            return nil
        }
        republish()
        if let added = rankedList.later.first(where: { $0.id == id }) {
            reportAddedToLater(added.label)
            return .later
        }
        return rankedList.focus.contains { $0.id == id } ? .focus : nil
    }

    private func reportAddedToLater(_ label: String) {
        undoBar.offer(.addedToLater, label: label, .report)
    }

    /// Reminders Signals only: title is currently the only field DailyOS
    /// lets the user edit from inside the app.
    public func renameTask(_ signal: Signal, to newTitle: String, dueAt: Date? = nil) async {
        await board.renameTask(signal, to: newTitle, dueAt: dueAt)
        republish()
    }

    /// Deletes the reminder outright — distinct from check off, which
    /// leaves it in place, completed. `deletingSignalIDs` hides it
    /// optimistically for the same reason check off's own mid-write
    /// tracking does: the write hasn't landed yet, so a refresh
    /// mid-delete would otherwise still report it open.
    public func deleteTask(_ signal: Signal) async {
        deletingSignalIDs.insert(signal.id)
        republish()
        await board.deleteTask(signal)
        deletingSignalIDs.remove(signal.id)
        republish()
    }
}

/// What dropping a dragged row does, given the Tier it came from and the
/// Tier it lands in.
private enum TierDrop {
    /// Moves it within Focus (ADR 0011).
    case reorder
    /// Moves it from Later into Focus by giving it a Priority (ADR 0009).
    case promote
    /// Moves it from Focus into Later by clearing its Priority.
    case demote
}

/// `nil` where the drop means nothing: within Later, which has no manual
/// order, or from Focus into Later for a row its due date keeps in Focus,
/// the same rows that offer no Move to Later.
private func tierDrop(of signal: Signal, from source: Tier, onto target: Tier, now: Date) -> TierDrop? {
    switch (source, target) {
    case (.focus, .focus): .reorder
    case (.later, .focus): .promote
    case (.focus, .later): affordances(for: signal, isLater: false, now: now).contains(.demote) ? .demote : nil
    case (.later, .later): nil
    }
}

/// The precedence among the five screens: backfill, then loading, then
/// empty, then Zen, then the list.
///
/// "Nothing open" (`.empty`) requires every Source to be reachable too,
/// not just every list empty: an unreachable Source still has its own
/// Notice to show, so `.list` — not `.empty` — is what renders it.
private func decideScreenMode(
    rankedList: RankedList,
    isLoading: Bool,
    backfillProgress: (completed: Int, total: Int)?,
    isZen: Bool,
    messagesNeedFullDiskAccess: Bool,
    remindersUnavailable: Bool,
    extractionUnavailable: Bool
) -> ScreenMode {
    if let progress = backfillProgress {
        return .backfill(completed: progress.completed, total: progress.total)
    }
    if isLoading {
        return .loading
    }
    let isEverythingEmpty = rankedList.focus.isEmpty && rankedList.later.isEmpty && rankedList.suggested.isEmpty
        && rankedList.snoozed.isEmpty
        && !messagesNeedFullDiskAccess && !remindersUnavailable && !extractionUnavailable
    if isEverythingEmpty {
        return .empty
    }
    if isZen {
        return .zen
    }
    return .list
}

/// Which Sections exist right now, in order, holding what. A Suggested
/// Tasks Inbox with nothing in it, or a Tier with nothing in it, produces
/// no Section.
///
/// `isZen` hides Later, the Snoozed Section and the Suggested Tasks Inbox outright — Zen Focus
/// Mode narrows the window down to Focus alone (CONTEXT.md: Zen Focus
/// Mode) — and never changes which Signals are Open or how they rank.
///
/// A Notice deliberately ignores `isZen` and always sorts after every
/// Signal-bearing Section: Zen hides what competes for attention, and a
/// Source the app can't read at all isn't competing, it's broken. Hiding
/// it there would leave Zen silently showing an incomplete picture, or —
/// with Focus empty — an entirely blank window (CONTEXT.md: Zen Focus
/// Mode).
private func decideSections(
    from rankedList: RankedList,
    isZen: Bool,
    messagesNeedFullDiskAccess: Bool,
    remindersUnavailable: Bool,
    extractionUnavailable: Bool
) -> [DailyOSCore.Section] {
    var result: [DailyOSCore.Section] = []
    if !isZen && !rankedList.suggested.isEmpty {
        result.append(.suggested(rankedList.suggested))
    }
    // An empty Focus still shows beside a non-empty Later, as the place to
    // drag a Later row into. Zen shows nothing else, so there it needs rows.
    let showsEmptyFocus = !isZen && !rankedList.later.isEmpty
    if !rankedList.focus.isEmpty || showsEmptyFocus {
        result.append(.tier(.focus, groupForRendering(rankedList.focus)))
    }
    if !isZen && !rankedList.later.isEmpty {
        result.append(.tier(.later, groupForRendering(rankedList.later)))
    }
    if !isZen && !rankedList.snoozed.isEmpty {
        result.append(.snoozed(rankedList.snoozed))
    }
    if messagesNeedFullDiskAccess {
        result.append(.notice(.messagesUnavailable))
    }
    if remindersUnavailable {
        result.append(.notice(.remindersUnavailable))
    }
    if extractionUnavailable {
        result.append(.notice(.extractionUnavailable))
    }
    return result
}
