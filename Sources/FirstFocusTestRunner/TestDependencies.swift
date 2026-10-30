import FirstFocusApp
import FirstFocusCore
import Foundation

extension AppDependencies {
    /// What every `AppModel` test starts from: fakes for every Source and
    /// seam, SQLite files of this run's own, and `UserDefaults` suites
    /// nothing else reads. The Focus list is off, and a fake model is
    /// loaded. `configure` replaces whatever the test needs.
    static func test(_ configure: (inout AppDependencies) -> Void = { _ in }) -> AppDependencies {
        let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
        let focusList = FocusListPreference(defaults: defaults)
        focusList.isEnabled = false
        var dependencies = AppDependencies(
            taskSource: FakeTaskSource(),
            messagesSource: FakeMessagesSource(),
            signalStore: makeTestSignalStore(),
            contactsResolver: FakeContactsResolver(),
            settingsOpener: FakeSettingsOpener(),
            refreshClock: FakeRefreshClock(),
            eventKitChanges: FakeEventKitChangeObserver(),
            messagesChanges: NoMessagesChangeObserver(),
            foregroundObserver: FakeForegroundObserver(),
            dayChanges: FakeDayChangeObserver(),
            zenFocusModePreference: ZenFocusModePreference(defaults: defaults),
            captureHotkeyPreference: CaptureHotkeyPreference(defaults: defaults),
            focusListPreference: focusList,
            extractionSettings: ExtractionSettings(defaults: defaults),
            reExtractionSettings: ReExtractionSettings(defaults: defaults),
            undoAlarm: FakeAlarm(),
            undoWindow: 5,
            loadModel: { _, _ in FakeIntentExtractor() },
            historyStore: makeTestHistoryStore(),
            participantLabelStore: SQLiteParticipantLabelStore(path: testStorePath()),
            correctionStore: FakeCorrectionStore(),
            screeningSettings: ScreeningSettings(defaults: defaults),
            filteredSMSSettings: FilteredSMSSettings(defaults: defaults),
            apiKeyStore: FakeAPIKeyStore(),
            makeScreener: { _ in FakeScreener() },
            ruleStore: FakeRuleStore(),
            batchWakeAlarm: FakeAlarm(),
            auditRoll: { Double.random(in: 0..<1) },
            now: { Date() },
            bundlePath: "/nonexistent",
            snoozeWakeAlarm: FakeAlarm(),
            morningBriefAlarm: FakeAlarm(),
            morningBriefPreference: MorningBriefPreference(defaults: defaults),
            morningBriefSender: FakeMessageSender(),
            selfThreadAddress: { nil }
        )
        configure(&dependencies)
        return dependencies
    }
}
