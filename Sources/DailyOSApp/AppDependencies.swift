import DailyOSCore
import Foundation

/// Everything `AppModel` is built from, in one value. There are no
/// defaults: production builds `live(...)`, which opens the real stores
/// and reads the real Sources, and nothing else does. A test starts from
/// a test value of its own, so it can reach live data only by asking for
/// `live` by name.
public struct AppDependencies {
    public var taskSource: any TaskSource
    public var messagesSource: any MessagesSource
    public var signalStore: any SignalStore
    public var contactsResolver: any ContactsResolver
    public var settingsOpener: any SettingsOpener
    public var refreshClock: any RefreshClock
    public var eventKitChanges: any EventKitChangeObserver
    public var messagesChanges: any MessagesChangeObserver
    public var foregroundObserver: any ForegroundObserver
    public var dayChanges: any DayChangeObserver
    public var zenFocusModePreference: ZenFocusModePreference
    public var captureHotkeyPreference: CaptureHotkeyPreference
    public var focusListPreference: FocusListPreference
    public var extractionSettings: ExtractionSettings
    public var reExtractionSettings: ReExtractionSettings
    public var undoClock: any UndoClock
    public var undoWindow: TimeInterval
    /// One supplied here is taken as final and nothing is loaded; `nil`
    /// makes `start()` load the model from disk.
    public var extractor: (any IntentExtractor)?
    public var historyStore: any HistoryStore
    public var participantLabelStore: any ParticipantLabelStore
    public var correctionStore: any CorrectionStore
    public var screeningSettings: ScreeningSettings
    public var filteredSMSSettings: FilteredSMSSettings
    public var apiKeyStore: any APIKeyStore
    public var makeScreener: @Sendable (String) -> any Screener
    public var ruleStore: any RuleStore
    public var batchWakeClock: any UndoClock
    public var auditRoll: @Sendable () -> Double
    /// "Now", injected so a test can stand just before midnight.
    public var now: @MainActor () -> Date
    /// Feeds `MessagesIntake`'s signing-identity check (ticket 10).
    public var bundlePath: String
    public var snoozeWakeClock: any UndoClock

    public init(
        taskSource: any TaskSource, messagesSource: any MessagesSource, signalStore: any SignalStore,
        contactsResolver: any ContactsResolver, settingsOpener: any SettingsOpener, refreshClock: any RefreshClock,
        eventKitChanges: any EventKitChangeObserver, messagesChanges: any MessagesChangeObserver,
        foregroundObserver: any ForegroundObserver, dayChanges: any DayChangeObserver,
        zenFocusModePreference: ZenFocusModePreference, captureHotkeyPreference: CaptureHotkeyPreference,
        focusListPreference: FocusListPreference, extractionSettings: ExtractionSettings,
        reExtractionSettings: ReExtractionSettings, undoClock: any UndoClock, undoWindow: TimeInterval,
        extractor: (any IntentExtractor)?, historyStore: any HistoryStore, participantLabelStore: any ParticipantLabelStore,
        correctionStore: any CorrectionStore, screeningSettings: ScreeningSettings, filteredSMSSettings: FilteredSMSSettings,
        apiKeyStore: any APIKeyStore, makeScreener: @escaping @Sendable (String) -> any Screener, ruleStore: any RuleStore,
        batchWakeClock: any UndoClock, auditRoll: @escaping @Sendable () -> Double, now: @escaping @MainActor () -> Date,
        bundlePath: String, snoozeWakeClock: any UndoClock
    ) {
        self.taskSource = taskSource
        self.messagesSource = messagesSource
        self.signalStore = signalStore
        self.contactsResolver = contactsResolver
        self.settingsOpener = settingsOpener
        self.refreshClock = refreshClock
        self.eventKitChanges = eventKitChanges
        self.messagesChanges = messagesChanges
        self.foregroundObserver = foregroundObserver
        self.dayChanges = dayChanges
        self.zenFocusModePreference = zenFocusModePreference
        self.captureHotkeyPreference = captureHotkeyPreference
        self.focusListPreference = focusListPreference
        self.extractionSettings = extractionSettings
        self.reExtractionSettings = reExtractionSettings
        self.undoClock = undoClock
        self.undoWindow = undoWindow
        self.extractor = extractor
        self.historyStore = historyStore
        self.participantLabelStore = participantLabelStore
        self.correctionStore = correctionStore
        self.screeningSettings = screeningSettings
        self.filteredSMSSettings = filteredSMSSettings
        self.apiKeyStore = apiKeyStore
        self.makeScreener = makeScreener
        self.ruleStore = ruleStore
        self.batchWakeClock = batchWakeClock
        self.auditRoll = auditRoll
        self.now = now
        self.bundlePath = bundlePath
        self.snoozeWakeClock = snoozeWakeClock
    }

    /// The shipped app: the real Sources, and every store at the bundle's
    /// own Application Support path. `settingsOpener`, `foregroundObserver`
    /// and `messagesChanges` are AppKit or FSEvents, which this target does
    /// not import, so the executable passes them in.
    public static func live(
        settingsOpener: any SettingsOpener, foregroundObserver: any ForegroundObserver,
        messagesChanges: any MessagesChangeObserver
    ) -> AppDependencies {
        AppDependencies(
            taskSource: EventKitTaskSource(),
            messagesSource: ChatDBMessagesSource(path: liveChatDBPath),
            signalStore: SQLiteSignalStore(path: SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier)),
            contactsResolver: CNContactsResolver(),
            settingsOpener: settingsOpener,
            refreshClock: TimerRefreshClock(),
            eventKitChanges: NotificationCenterEventKitChangeObserver(),
            messagesChanges: messagesChanges,
            foregroundObserver: foregroundObserver,
            dayChanges: NotificationCenterDayChangeObserver(),
            zenFocusModePreference: ZenFocusModePreference(),
            captureHotkeyPreference: CaptureHotkeyPreference(),
            focusListPreference: FocusListPreference(),
            extractionSettings: ExtractionSettings(),
            reExtractionSettings: ReExtractionSettings(),
            undoClock: TaskSleepUndoClock(),
            undoWindow: 5,
            extractor: nil,
            historyStore: SQLiteHistoryStore(path: SQLiteHistoryStore.defaultPath(bundleIdentifier: bundleIdentifier)),
            participantLabelStore: SQLiteParticipantLabelStore(
                path: SQLiteParticipantLabelStore.defaultPath(bundleIdentifier: bundleIdentifier)
            ),
            correctionStore: SQLiteCorrectionStore(path: SQLiteCorrectionStore.defaultPath(bundleIdentifier: bundleIdentifier)),
            screeningSettings: ScreeningSettings(),
            filteredSMSSettings: FilteredSMSSettings(),
            apiKeyStore: KeychainAPIKeyStore(service: bundleIdentifier),
            makeScreener: { JEVScreener(apiKey: $0) },
            ruleStore: SQLiteRuleStore(path: SQLiteRuleStore.defaultPath(bundleIdentifier: bundleIdentifier)),
            batchWakeClock: TaskSleepUndoClock(),
            auditRoll: { Double.random(in: 0..<1) },
            now: { Date() },
            bundlePath: Bundle.main.bundlePath,
            snoozeWakeClock: TaskSleepUndoClock()
        )
    }
}
