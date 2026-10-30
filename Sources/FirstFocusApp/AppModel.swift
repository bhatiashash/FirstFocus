import Combine
import CoreGraphics
import FirstFocusCore
import EventKit
import Foundation

/// The real, live path a shipped build reads. Development and testing
/// against a live-equivalent database use the snapshot at
/// ~/FirstFocus-data/ instead — never this path — since this machine's own
/// agent shell cannot hold a stable Full Disk Access grant.
public let liveChatDBPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Messages/chat.db").path

/// The folder `liveChatDBPath` sits in, watched for writes (ADR 0034
/// amendment) so intake starts within a second of a message arriving.
public let liveMessagesDirectory = (liveChatDBPath as NSString).deletingLastPathComponent

/// `Bundle.main.bundleIdentifier` reads `Info.plist`'s `CFBundleIdentifier`
/// once the app is bundled and signed (the normal `build.sh` path); the
/// fallback only matters for `swift run FirstFocus` straight from source,
/// where there's no real bundle to read it from.
public let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.shashbhatia.FirstFocus"

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
    /// place. `presentation` is what the window draws from it.
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
        hasCheckedOffToShow && (presentation.screenMode == .list || presentation.screenMode == .empty)
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
    /// The ids of the Suggestions the Inbox offers "Not for me" on
    /// (inbox-not-for-me). Worked out when the list republishes and when
    /// History's actions change something, never per render.
    @Published public private(set) var notForMeOffers: Set<String> = []
    /// Everything the window asks about the list (list-presentation): the
    /// screen, its Sections, each row's actions and what a drop does.
    /// Rebuilt by `updatePresentation()` whenever the list or a flag it
    /// reads changes, so views only read it.
    @Published public private(set) var presentation: ListPresentation
    /// The moment `rankedList` was ranked against. Every gesture on the
    /// list is judged against this rather than a fresh clock read, so just
    /// after midnight a drop or a row's actions follow the Tiers on
    /// screen until the day change derives the list again (ADR 0042).
    private var rankedAt: Date
    /// "Now", injected so a test can stand just before midnight. Read for
    /// ranking and for snoozing only.
    private let now: @MainActor () -> Date
    /// Every snooze, and the wake-up that brings a Snoozed row back when
    /// its snooze ends (ADR 0045, snooze-wake). Handed to the Board, the
    /// verbs and the Focus list.
    private let snoozes: Snoozes
    @Published public var isLoading = true {
        didSet { updatePresentation() }
    }
    /// The Undo bar's offer (CONTEXT.md: Undo bar), or `nil` when the bar
    /// is hidden. A mirror of `verbs.currentOffer` for SwiftUI's sake.
    @Published public private(set) var undoOffer: UndoOffer?
    @Published public private(set) var failures: [AppFailure] = []
    @Published public private(set) var focusListFailure: FocusListFailure?
    private var dismissedFocusFailure: FocusListFailure?
    /// Every verb that writes Signal state, with its Undo (signal-verbs).
    private let verbs: SignalVerbs
    private let feedback: BatchFeedback?
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
    /// Read from `extraction` whenever it changes.
    @Published public private(set) var extractionUnavailable = false {
        didSet { updatePresentation() }
    }
    /// Mirrored from `intakeRunner` whenever it changes, because SwiftUI
    /// has to redraw what they drive and FirstFocusCore uses no Combine or
    /// Observation
    /// (ADR 0020).
    @Published public private(set) var backfillProgress: (completed: Int, total: Int)? {
        didSet { updatePresentation() }
    }
    /// Which kind of Messages pass is running (ADR 0034), `nil` when none
    /// is: the input behind Re-extract being disabled rather than queueing
    /// invisibly.
    @Published public private(set) var runningMessagesPass: PassKind?
    public var isMessagesPassRunning: Bool { runningMessagesPass != nil }
    @Published public private(set) var reExtractionProgress: (completed: Int, total: Int)?
    /// Keyboard focus, the open popover and the collapsed Sections
    /// (`InboxTriage`). One value, so a change publishes once.
    @Published private(set) var triage = InboxTriage()
    /// The Suggestion keyboard triage acts on, or `nil`.
    public var focusedSuggestionId: String? {
        get { triage.focusedId }
        set { triage.focusedId = newValue }
    }
    /// The Suggestion whose context popover is open, or `nil`.
    public var previewedSuggestionId: String? {
        get { triage.previewedId }
        set { triage.previewedId = newValue }
    }
    public var collapsedSections: Set<CollapsibleSection> { triage.collapsed }
    /// The Morning Brief's send (ADR 0046), shared by Advanced's section and
    /// the daily send. It composes the Brief from the Ranked List as it is
    /// at the moment of sending.
    public private(set) lazy var morningBriefDelivery = MorningBriefDelivery(
        preference: morningBriefPreference, sender: morningBriefSender, recipient: selfThreadAddress,
        compose: { [weak self] in self?.morningBriefText(format: self?.morningBriefPreference.format ?? .standard) ?? "" },
        now: now, alarm: morningBriefAlarm
    )
    /// Advanced's Morning Brief section.
    public private(set) lazy var morningBriefViewModel = MorningBriefViewModel(
        delivery: morningBriefDelivery, preference: morningBriefPreference, myNumber: selfThreadAddress,
        preview: { [weak self] in self?.morningBriefText(format: $0) ?? "" }
    )
    private let morningBriefPreference: MorningBriefPreference
    private let morningBriefSender: any MessageSender
    private let selfThreadAddress: @MainActor () -> String?
    private let morningBriefAlarm: any Alarm
    /// The launch send, which runs beside the rest of launch.
    private var morningBriefStart: Task<Void, Never>?

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
            updatePresentation()
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
    /// The Reminders lists Advanced shows, as of the last
    /// `refreshFocusListTicks()`. Which are ticked is the Focus list's.
    @Published private var reminderLists: [ReminderList] = []
    private var defaultReminderListId: String?
    /// Each list and whether it is ticked, read from the Focus list every
    /// time, so no copy of the ticks can go stale.
    public var focusListTicks: [FocusListTick] {
        reminderLists.map {
            FocusListTick(list: $0, isTicked: focusList.isTicked($0.id), isDefault: $0.id == defaultReminderListId)
        }
    }
    /// Held directly, alongside handing the same instance to `board` at
    /// init, purely for `start()`'s one-time Gate request — requesting
    /// access is a launch-time action, not part of reading or ranking, so
    /// it stays outside what the Signal Board owns.
    private let taskSource: any TaskSource
    private let contactsResolver: any ContactsResolver
    private let board: SignalBoard
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
    /// Runs every Messages Intake pass and hands its result to the Board,
    /// holding Intake beside the Board rather than behind it (ADR 0020,
    /// intake-runner).
    public let intakeRunner: IntakeRunner
    /// History (ADR 0029): handed straight to `MessagesIntake`, which
    /// threads it through to `Extraction.swift`'s writer, and to
    /// `historyActions` for Re-run. The Models tab's `ModelDownloading`
    /// seam has no relationship to the extraction pipeline at all, so unlike
    /// this it is never held here — `main.swift` hands it straight to
    /// `ModelsViewModel`, the only thing that ever touches it.
    private let historyStore: any HistoryStore
    /// Mute Thread (ADR 0032) and Restore (superseded-restore): handed to
    /// `historyActions` without widening what `board` or `verbs` are
    /// handed, since neither needs this state.
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
        ownerDidChange: { [weak self] in
            switch $0 {
            case .board: self?.boardChanged()
            case .history: self?.updateNotForMeOffers()
            case .failure: break
            }
            self?.publishFailures()
        },
        board: board, intakeRunner: intakeRunner, extraction: extraction, historyStore: historyStore, signalStore: signalStore, corrections: corrections,
        feedback: feedback,
        screeningSettings: screeningSettings
    )
    /// Screening (ADR 0036): the preferences, the Keychain-backed key, and
    /// how to build a Screener from a key. The last is a seam so a test
    /// never makes a network call.
    private let screeningSettings: ScreeningSettings
    /// The extraction model, its Rules, Rule proposals and Screening
    /// (extraction-host). Settings view models take it directly.
    public let extraction: ExtractionHost

    private var refreshCoordinator: RefreshCoordinator?
    /// Excluded from every `republish()` before dedup, tiering or the
    /// Later cap ever sees them. Neither the Signal Board nor AppModel
    /// learns why any of them are hidden.
    private var hidingIDs: Set<String> { verbs.hiddenIDs }

    /// Built only from `dependencies`, which carries no defaults: the
    /// executable passes `AppDependencies.live(...)` and a test passes a
    /// test value, so a test never opens a live store by accident.
    public init(_ dependencies: AppDependencies) {
        self.feedback = dependencies.batchFeedback
        self.taskSource = dependencies.taskSource
        self.contactsResolver = dependencies.contactsResolver
        let filteredSMSSettings = dependencies.filteredSMSSettings
        let intake = MessagesIntake(
            messagesSource: dependencies.messagesSource, signalStore: dependencies.signalStore,
            contactsResolver: dependencies.contactsResolver, bundlePath: dependencies.bundlePath,
            participantLabelStore: dependencies.participantLabelStore, historyStore: dependencies.historyStore,
            correctionStore: dependencies.correctionStore,
            batchWakeAlarm: dependencies.batchWakeAlarm, auditRoll: dependencies.auditRoll,
            ignoresFilteredSMS: { filteredSMSSettings.ignoresFilteredSMS },
            clock: dependencies.now
        )
        let snoozes = Snoozes(store: dependencies.signalStore, alarm: dependencies.snoozeWakeAlarm, now: dependencies.now)
        self.snoozes = snoozes
        self.board = SignalBoard(
            taskSource: dependencies.taskSource, signalStore: dependencies.signalStore, now: dependencies.now, snoozes: snoozes
        )
        self.focusList = FocusList(
            taskSource: dependencies.taskSource, store: dependencies.signalStore, board: board, snoozes: snoozes,
            preference: dependencies.focusListPreference
        )
        self.isFocusListEnabled = dependencies.focusListPreference.isEnabled
        self.verbs = SignalVerbs(
            board: board, snoozes: snoozes, taskSource: dependencies.taskSource, signalStore: dependencies.signalStore,
            undoAlarm: dependencies.undoAlarm, undoWindow: dependencies.undoWindow, now: dependencies.now
        )
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
        self.historyStore = dependencies.historyStore
        self.signalStore = dependencies.signalStore
        let corrections = Corrections(store: dependencies.correctionStore)
        self.corrections = corrections
        self.screeningSettings = dependencies.screeningSettings
        self.extraction = ExtractionHost(
            intake: intake, loader: dependencies.loadModel, extractionSettings: dependencies.extractionSettings,
            bundleIdentifier: bundleIdentifier, ruleStore: dependencies.ruleStore, corrections: corrections,
            screeningSettings: dependencies.screeningSettings, apiKeyStore: dependencies.apiKeyStore,
            makeScreener: dependencies.makeScreener
        )
        self.intakeRunner = IntakeRunner(
            intake: intake, board: board, extraction: extraction, reExtractionSettings: dependencies.reExtractionSettings,
            now: dependencies.now
        )
        self.now = dependencies.now
        self.morningBriefPreference = dependencies.morningBriefPreference
        self.morningBriefSender = dependencies.morningBriefSender
        self.selfThreadAddress = dependencies.selfThreadAddress
        self.morningBriefAlarm = dependencies.morningBriefAlarm
        self.rankedAt = dependencies.now()
        self.presentation = .loading(at: dependencies.now())

        // Wired last, once every stored property above has a value:
        // `self` only becomes a valid `[weak self]` capture at that point.
        // A Batch left open by a pass wakes a Messages refresh through the
        // same path every other trigger takes (batched-extraction ticket 05).
        intakeRunner.onChange = { [weak self] in
            self?.mirrorIntakeRunner()
        }
        intakeRunner.onResultApplied = { [weak self] in
            self?.republish()
        }
        // A pass writes History rows as it goes; History shows them once it
        // ends.
        intakeRunner.onPassEnded = { [weak self] in
            self?.historyActions.changed()
        }
        intake.onBatchDue = { [weak self] in
            Task { await self?.handleRefresh(.batchDue) }
        }
        self.verbs.onChange = { [weak self] in
            guard let self else { return }
            self.undoOffer = self.verbs.currentOffer
            self.republish()
        }
        self.verbs.notForMe = SignalVerbs.NotForMe(
            mark: { [weak self] suggestion in
                guard let self, self.historyActions.notForMe(suggestion) else { return nil }
                return self.historyActions.undoAction(for: suggestion)
            }
        )
        self.historyActions.onRetriedInboxFeedback = { [weak self] suggestion, undo in
            self?.verbs.offerNotForMe(suggestion, undo: undo)
        }
        self.focusList.onChange = { [weak self] in
            self?.publishFailures()
            self?.republish()
        }
        self.snoozes.onWake = { [weak self] in
            self?.republish()
        }
        self.extraction.onChange = { [weak self] in
            guard let self else { return }
            if self.extraction.isUnavailable != self.extractionUnavailable {
                self.extractionUnavailable = self.extraction.isUnavailable
            }
            self.historyActions.changed()
        }
    }

    /// The extraction Notice's Retry.
    public func retryLoadingExtractor() async {
        await extraction.retry()
    }

    /// Whether the chosen model's file is on disk, loaded or not.
    public var hasModelFile: Bool { extraction.hasModelFile }

    /// The loaded model's name, `nil` with none loaded.
    public var activeModelDisplayName: String? { extraction.displayName }

    /// History wrote to the Signal Board (board-messages-share): the
    /// window shows it.
    func boardChanged() {
        republish()
    }

    /// Re-reads which Suggestions offer "Not for me". Called by
    /// `republish()` and whenever `historyActions` changes something.
    func updateNotForMeOffers() {
        let offers = historyActions.suggestionsOfferingNotForMe(rankedList.suggested)
        if offers != notForMeOffers { notForMeOffers = offers }
    }

    /// Copies the runner's state into what SwiftUI watches. A progress
    /// tick redraws the screen it drives, not the whole list.
    private func mirrorIntakeRunner() {
        if runningMessagesPass != intakeRunner.runningPass { runningMessagesPass = intakeRunner.runningPass }
        if backfillProgress?.completed != intakeRunner.backfillProgress?.completed
            || backfillProgress?.total != intakeRunner.backfillProgress?.total {
            backfillProgress = intakeRunner.backfillProgress
        }
        reExtractionProgress = intakeRunner.reExtractionProgress
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
        intakeRunner.checkIdentityAtLaunch()
        setUpRefreshCoordinator()
        extraction.applyScreeningSettings()
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
        // moments later (see `presentation.screenMode`), and clearing early there would
        // flash "Nothing open. Nice." at someone whose backfill is about to
        // start.
        board.loadStoredMessages()
        republish()
        onStoredListReady?()
        // A Brief missed while the app was closed goes out now, then the
        // timer is set. Beside the rest of launch, which can take minutes.
        morningBriefStart = Task { await morningBriefDelivery.start() }
        if signalStore.isBackfillComplete() {
            isLoading = false
        }

        await extraction.load()
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
        await intakeRunner.refresh()
    }

    public func openFullDiskAccessSettings() {
        settingsOpener.open(.fullDiskAccess)
    }

    public func openRemindersSettings() {
        settingsOpener.open(.reminders)
    }

    /// Ticket 12's manual re-extraction, only ever from a click (ADR 0004).
    public func reExtract() async {
        await intakeRunner.reExtract()
    }

    /// The File menu's Re-run Extraction item enabled: the runner's rule,
    /// plus the launch's loading state, which also covers the Reminders
    /// read.
    public var canReExtract: Bool {
        !isLoading && intakeRunner.canReExtract
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
        let messagesOut = intakeRunner.messagesUnavailable
        if messagesOut != messagesNeedFullDiskAccess { messagesNeedFullDiskAccess = messagesOut }
        board.hiddenListIds = focusList.untickedListIds
        rankedList = board.rankedList(now: rankedAt, hiding: hidingIDs)
        checkedOff = board.checkedOff(now: rankedAt, hiding: hidingIDs)
        checkedOffCount = checkedOff.count
        updatePresentation()
        updateNotForMeOffers()
        triage.drop { [presentation] in !presentation.isSuggested($0) }
        focusList.listDerived(at: rankedAt)
    }

    private func publishFailures() {
        let focusFailure = focusList.failure
        if focusListFailure != focusFailure {
            focusListFailure = focusFailure
            dismissedFocusFailure = nil
        }
        var current = historyActions.failures
        if let focusFailure, dismissedFocusFailure != focusFailure {
            let message: String
            switch focusFailure {
            case .persistenceRead: message = "Couldn’t read Focus list sync state. Sync will retry after the next refresh."
            case .persistenceWrite: message = "Couldn’t save Focus list sync state. Sync will retry after the next refresh."
            case .reminders: message = "Couldn’t update Reminders for the Focus list. Sync will retry after the next refresh."
            }
            current.append(AppFailure(id: "focus-list-sync", message: message, canRetry: false))
        }
        if failures != current { failures = current }
    }

    public func retryFailure(_ id: String) {
        historyActions.retryFailure(id)
    }

    public func dismissFailure(_ id: String) {
        if id == "focus-list-sync" {
            dismissedFocusFailure = focusListFailure
            publishFailures()
        } else {
            historyActions.dismissFailure(id)
        }
    }

    /// Wake from sleep is the other moment a missed Brief can go out. The
    /// executable calls this when macOS posts its wake notification.
    public func systemDidWake() async {
        await morningBriefDelivery.systemDidWake()
    }

    /// Waits for the launch send of the Morning Brief. For tests.
    public func morningBriefSettled() async {
        await morningBriefStart?.value
    }

    /// Waits for every Focus list sync asked for so far, and any each one
    /// leads to. For tests.
    public func focusListSettled() async {
        await focusList.settled()
    }

    /// Reads Reminders' lists again, for Advanced as it opens.
    public func refreshFocusListTicks() async {
        defaultReminderListId = await focusList.defaultListId()
        reminderLists = await focusList.reminderLists()
    }

    /// Ticks or unticks a list in Advanced: an unticked list's reminders
    /// leave the window at once, and come back when it is ticked.
    public func setFocusListTick(_ isTicked: Bool, listId: String) {
        focusList.setTicked(isTicked, listId: listId)
        objectWillChange.send()
        republish()
    }

    /// The Morning Brief's text (ADR 0046), from the Ranked List derived
    /// afresh for this moment rather than the last published one, so a
    /// snooze ending at 8:00 AM is back in it whichever timer fires first.
    public func morningBriefText(format: MorningBriefFormat = .standard) -> String {
        let moment = now()
        return composeMorningBrief(board.rankedList(now: moment, hiding: hidingIDs), now: moment, format: format)
    }

    /// Builds `presentation` from the list and the flags it reads. Called
    /// by `republish()` and by each flag's `didSet`.
    private func updatePresentation() {
        presentation = ListPresentation(
            rankedList: rankedList, rankedAt: rankedAt,
            flags: ListPresentation.Flags(
                isLoading: isLoading, backfillProgress: backfillProgress, isZen: isZenFocusModeEnabled,
                messagesNeedFullDiskAccess: messagesNeedFullDiskAccess, remindersUnavailable: remindersUnavailable,
                extractionUnavailable: extractionUnavailable
            )
        )
    }

    /// Held back on the Undo bar, and written once the offer ends (ADR
    /// 0022). Writing it also ends any snooze, so
    /// a recurring reminder's next occurrence, which keeps the same id,
    /// doesn't start out hidden (ADR 0045).
    public func checkOff(_ signal: Signal) {
        verbs.checkOff(signal)
    }

    /// Unchecking a Checked Off row: reopens the reminder, which goes back
    /// to Focus or Later. No Undo bar, and ⌘Z doesn't reach it.
    public func uncheck(_ reminder: CheckedOffReminder) async {
        await verbs.uncheck(reminder)
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
        verbs.prepareToQuit()
    }

    /// Esc: leaves Zen Focus Mode or Minimal View, Zen first. `true` when the
    /// key was taken; `false` leaves it for whatever else is listening.
    @discardableResult
    public func pressEscape(window: WindowFocus) -> Bool {
        let mode = PresentationMode(isZen: isZenFocusModeEnabled, isMinimalView: isMinimalViewEnabled)
        switch mode.escapeExit(window: window, isPreviewOpen: previewedSuggestionId != nil) {
        case .zen: isZenFocusModeEnabled = false
        case .minimalView: isMinimalViewEnabled = false
        case nil: return false
        }
        return true
    }

    /// ⌘Z triggers the Undo bar before the Edit menu sees it: only while the
    /// bar offers an Undo, the main window is key with no sheet over it, and
    /// no text is being edited, where ⌘Z undoes typing. `true` when taken.
    @discardableResult
    public func pressCommandZ(window: WindowFocus) -> Bool {
        guard undoOffer?.canUndo == true, window.isMainWindowKey, !window.hasSheet, !window.isEditingText else {
            return false
        }
        Task { await undo() }
        return true
    }

    /// The count at the end of the window that opens the Checked Off sheet
    /// (CONTEXT.md: Checked Off).
    public var checkedOffCountText: String {
        checkedOffCount == 1 ? "1 reminder completed today" : "\(checkedOffCount) reminders completed today"
    }

    /// The Undo bar's button, and ⌘Z: reverses whatever the bar offers.
    /// Does nothing when the bar is hidden or only reports.
    public func undo() async {
        if let broughtBack = await verbs.undo() { focusSuggestion(broughtBack) }
    }

    /// Messages Signals only: Dismiss means "Extraction produced a false
    /// positive," and Reminders Signals never go through Extraction, so
    /// there's nothing for it to mean there (see CONTEXT.md: Dismiss).
    /// Written at once, unlike check-off, and reversed if the Undo bar's
    /// Undo is pressed (ADR 0043).
    public func dismiss(_ signal: Signal) {
        verbs.dismiss(signal)
    }

    /// The Inbox's thumbs-down: History's "Not for me" on the Suggestion's
    /// Batch, then the Undo bar, whose Undo reverses it the way History's
    /// Undo does (ADR 0043).
    public func notForMe(_ suggestion: Signal) {
        verbs.notForMe(suggestion)
    }

    private var inboxIds: [String] { rankedList.suggested.map(\.id) }

    private func focusSuggestion(_ id: String) {
        triage.focus(id, inboxIds: inboxIds)
    }

    /// One-click promotion (ticket 05): sets `signal`'s priority to
    /// `.high`, which is the entire mechanism — `tier(for:)` already puts
    /// anything carrying a priority into Focus (ADR 0009), so nothing else
    /// about ranking needs to change. No demote counterpart for a row its
    /// due date holds in Focus (ADR 0009's noted asymmetry, ADR 0042).
    public func promote(_ signal: Signal) async {
        await verbs.promote(signal)
    }

    /// One-click demotion: the reverse of `promote`.
    public func demote(_ signal: Signal) async {
        await verbs.demote(signal)
    }

    /// Snoozes `signal` off the ranked list until `until`, applying
    /// uniformly regardless of source (see CONTEXT.md: Snoozed). Just a
    /// store write plus a republish — `rankedList` reads `snoozedUntil`
    /// fresh on every call, so there's nothing to patch. No Undo bar.
    public func snooze(_ signal: Signal, until: Date) {
        verbs.snooze(signal, until: until)
    }

    /// Unsnooze on a Snoozed row (ADR 0045): back to Focus or Later at
    /// once. No Undo bar; the row reappearing is the confirmation.
    public func unsnooze(_ signal: Signal) {
        verbs.unsnooze(signal)
    }

    /// Tomorrow or Next Week from a row's tray or menu (ADR 0045): ends
    /// at 8:00 AM, judged by the injected clock. Written at once; Undo
    /// puts back whatever snooze the row had before, or none.
    public func snooze(_ signal: Signal, _ choice: SnoozeChoice) {
        verbs.snooze(signal, choice)
    }

    /// Manual Focus ordering (ADR 0011, supersedes ADR 0009): dragging
    /// `draggedId` onto `droppedOnId` moves it to sit immediately before
    /// that row, among whatever's *currently* visible in Focus —
    /// `rankedList.focus`, `hidingIDs` and all, the same list the user is
    /// actually looking at, not a fresh recompute that might disagree
    /// with it.
    private func reorderFocus(draggedId: String, droppedOnId: String) {
        verbs.reorderFocus(draggedId: draggedId, droppedOnId: droppedOnId, currentFocusIds: rankedList.focus.map(\.id))
    }

    /// Where a dragged row can land: on another row, or on a Tier's header
    /// or the empty Focus drop zone, which both mean the Tier itself.
    public typealias DropTarget = ListPresentation.DropTarget

    /// A row dragged onto `target`. Dropped in Focus on a row it takes that
    /// row's place (ADR 0011), after moving into Focus if it came from
    /// Later; dropped in Later it moves there. A drop the Tier rules
    /// refuse, such as a row its due date keeps in Focus into Later, does
    /// nothing. Judged against `rankedAt`, the moment the list on screen
    /// was ranked against.
    public func drop(_ draggedId: String, onto target: DropTarget) async {
        switch presentation.drop(draggedId, onto: target) {
        case .reorder(let draggedId, let ontoId):
            reorderFocus(draggedId: draggedId, droppedOnId: ontoId)
        case .promote(let dragged, let ontoId):
            await promote(dragged)
            if let ontoId { reorderFocus(draggedId: dragged.id, droppedOnId: ontoId) }
        case .demote(let dragged):
            await demote(dragged)
        case nil:
            break
        }
    }

    /// Whether `section` is collapsed.
    public func isCollapsed(_ section: CollapsibleSection) -> Bool {
        triage.isCollapsed(section)
    }

    /// A Section header's chevron.
    public func toggleCollapse(_ section: CollapsibleSection) {
        triage.toggleCollapse(section)
    }

    /// Suggested Tasks Inbox (Focus Mode v2): approving mints a real
    /// reminder and marks the originating Messages Signal `approved`
    /// (CONTEXT.md: Approve).
    /// Written at once, so the task shows where it landed, and reversed
    /// if the Undo bar's Undo is pressed (ADR 0043).
    public func approve(_ signal: Signal) async {
        await verbs.approve(signal)
    }

    /// Tomorrow or Next Week on a Suggestion (ADR 0045): Approves it and
    /// Snoozes the new reminder before the Board re-fetches, so it never
    /// shows in Focus or Later. One Undo reverses both. Records
    /// nothing for extraction, like a plain Approve.
    public func approve(_ signal: Signal, snoozing choice: SnoozeChoice) async {
        await verbs.approve(signal, snoozing: choice)
    }

    public typealias InboxKey = InboxTriage.Key

    /// A key pressed in the window, answered at once: `true` when the
    /// Inbox takes it, `false` to leave it for anything else listening. A
    /// key taken is acted on in its own task.
    @discardableResult
    public func pressInboxKey(_ key: InboxKey) -> Bool {
        guard triage.takes(key, inboxIds: inboxIds, isZen: isZenFocusModeEnabled) else { return false }
        Task { await handleInboxKey(key) }
        return true
    }

    /// Keyboard triage of the Suggested Tasks Inbox. Approve and Dismiss
    /// act only on the focused Suggestion, then move focus to its neighbour
    /// so the next keystroke acts on the next row. The tier an Approved
    /// Signal lands in is left to the usual rules (ADR 0002).
    public func handleInboxKey(_ key: InboxKey) async {
        guard let act = triage.handle(key, inboxIds: inboxIds, isZen: isZenFocusModeEnabled),
              let signal = rankedList.suggested.first(where: { $0.id == act.id }) else { return }
        if act.key == .approve {
            await approve(signal)
        } else {
            dismiss(signal)
        }
        triage.finish(act, inboxIds: inboxIds)
    }

    /// Hover: the view calls this once the pointer has rested on a
    /// Suggestion for half a second.
    public func showPreview(forSuggestionId id: String) {
        triage.showPreview(of: id, inboxIds: inboxIds)
    }

    /// The pointer left `id`'s row; closes its popover if it's the open one.
    public func hidePreview(forSuggestionId id: String) {
        triage.hidePreview(of: id)
    }

    /// Bidirectional Reminders sync (Focus Mode v2, supersedes ADR 0001):
    /// writes straight through to Reminders and re-fetches, so the ranked
    /// list always reflects exactly what Reminders itself now reports —
    /// the same source of truth an external edit would produce. Quick
    /// Capture's path: no Priority, and no report of where it landed.
    public func createTask(title: String, dueAt: Date? = nil) async {
        await verbs.createTask(title: title, dueAt: dueAt)
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
        let priority: Priority = dueAt == nil && presentation.showsFocus ? .high : .none
        let tier = await verbs.addReminder(title: title, priority: priority, dueAt: dueAt)
        // Later opens, so the new row shows where it went.
        if tier == .later { triage.expand(.later) }
        return tier
    }

    /// Reminders Signals only: title is currently the only field FirstFocus
    /// lets the user edit from inside the app.
    public func renameTask(_ signal: Signal, to newTitle: String, dueAt: Date? = nil) async {
        await verbs.renameTask(signal, to: newTitle, dueAt: dueAt)
    }

    /// Deletes the reminder outright, distinct from check off, which
    /// leaves it in place, completed. Hidden until the write lands.
    public func deleteTask(_ signal: Signal) async {
        await verbs.deleteTask(signal)
    }
}
