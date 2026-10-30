import DailyOSApp
import DailyOSCore
import Foundation

/// A fresh, empty History store on disk: the real adapter, not a fake.
func makeTestHistoryStore() -> SQLiteHistoryStore {
    SQLiteHistoryStore(path: testStorePath())
}

extension HistoryStore {
    /// Every row the store holds, newest Batch first and newest row first
    /// within it, read through History's Batch read.
    func allRows() -> [HistoryEntry] {
        batches(since: .distantPast).flatMap { $0.rows.reversed() }
    }
}

/// History as the app builds it: `AppModel` over SQLite stores at temp
/// paths, owning the real History Batch actions. `@unchecked Sendable` for
/// the same reason every other test harness here is: one test drives it at
/// a time, and the model itself is `@MainActor`.
struct HistoryApp: @unchecked Sendable {
    let model: AppModel
    let signals: SQLiteSignalStore
    let history: SQLiteHistoryStore
    let corrections: SQLiteCorrectionStore
    let correctionsPath: String
    let taskSource: FakeTaskSource
    /// Closes the Undo bar's window when a test fires it.
    let undoAlarm: FakeAlarm
    /// The app's Screening settings, which History's view model shares
    /// unless a test passes its own.
    let screeningSettings: ScreeningSettings

    @MainActor var actions: HistoryBatchActions { model.historyActions }

    /// History's view model over this app, as `main.swift` builds it.
    @MainActor
    func viewModel(
        screeningSettings: ScreeningSettings? = nil, now: @escaping () -> Date = Date.init, calendar: Calendar = .current
    ) -> HistoryViewModel {
        HistoryViewModel(
            historyStore: history, actions: actions,
            screeningSettings: screeningSettings ?? self.screeningSettings, now: now,
            calendar: calendar
        )
    }
}

func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
}

/// `extractor: nil` is an app with no model loaded, as long as the test
/// never calls `start()`, which would load the real one off disk. The
/// Signal store is a steady-state install unless one is passed in: backfill
/// done, and every fixture message recent enough to read.
@MainActor
func makeHistoryApp(
    messages: [ChatMessage] = [], extractor: (any IntentExtractor)? = FakeIntentExtractor(),
    signals: SQLiteSignalStore? = nil, history: SQLiteHistoryStore? = nil,
    contactsResolver: any ContactsResolver = FakeContactsResolver(),
    screeningSettings: ScreeningSettings? = nil, screener: (any Screener)? = nil
) -> HistoryApp {
    let defaults = throwawayDefaults()
    let signals = signals ?? {
        let store = makeTestSignalStore()
        try? store.markBackfillComplete()
        try? store.recordNonSelfMessagesCutoff(.distantPast)
        return store
    }()
    let history = history ?? makeTestHistoryStore()
    let correctionsPath = testStorePath()
    let corrections = SQLiteCorrectionStore(path: correctionsPath)
    let taskSource = FakeTaskSource(tasks: [], availability: .available)
    let undoAlarm = FakeAlarm()
    // Screening's toggle on unless a test says otherwise, so History shows
    // Screening; with no screener there's no key, so intake stays local.
    let screeningSettings = screeningSettings ?? {
        let settings = ScreeningSettings(defaults: defaults)
        settings.isEnabled = true
        return settings
    }()
    let model = AppModel(AppDependencies.test { d in
        d.taskSource = taskSource
        d.messagesSource = FakeMessagesSource(messages: messages)
        d.signalStore = signals
        d.contactsResolver = contactsResolver
        d.settingsOpener = FakeSettingsOpener()
        d.refreshClock = FakeRefreshClock()
        d.eventKitChanges = FakeEventKitChangeObserver()
        d.foregroundObserver = FakeForegroundObserver()
        d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
        d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
        d.undoAlarm = undoAlarm
        d.loadModel = { _, _ in extractor }
        d.historyStore = history
        d.correctionStore = corrections
        d.screeningSettings = screeningSettings
        d.apiKeyStore = FakeAPIKeyStore(key: screener == nil ? nil : "k")
        d.makeScreener = { [screener] key in screener ?? JEVScreener(apiKey: key) }
        d.auditRoll = { 1 }
        d.bundlePath = "/nonexistent"
    })
    return HistoryApp(
        model: model, signals: signals, history: history, corrections: corrections, correctionsPath: correctionsPath,
        taskSource: taskSource, undoAlarm: undoAlarm, screeningSettings: screeningSettings
    )
}

/// A lone row as the Batch History would list it.
func historyBatch(_ row: HistoryEntry) -> HistoryBatch {
    HistoryBatch(id: row.sourceRef ?? "row:\(row.id)", rows: [row])
}

extension HistoryBatchActions {
    /// What History would offer on `batch` if it refreshed now: the offer
    /// rule over facts read fresh, the same check taking an action makes.
    func offered(_ action: HistoryBatchAction, for batch: HistoryBatch) -> HistoryActionState? {
        historyBatchOffers(for: batch, facts: facts(forBatches: [batch]))[action]
    }

    /// Whether History would label `batch`'s Chat Muted if it refreshed now.
    func isMutedNow(_ batch: HistoryBatch) -> Bool {
        facts(forBatches: [batch]).isMuted(batch)
    }
}
