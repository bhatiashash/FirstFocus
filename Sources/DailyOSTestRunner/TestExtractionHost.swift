import DailyOSApp
import DailyOSCore
import Foundation

/// What a test's model loader did, and what it does next. A class, so the
/// `@Sendable` loader and the test share it.
final class LoaderLog: @unchecked Sendable {
    /// Every load attempted.
    var loads = 0
    /// While set, a load returns no model, as a missing or broken file does.
    var fails = false
}

/// A real `ExtractionHost` on fakes (extraction-host): Intake on a test
/// store, a loader that hands back `extractor` unless told to fail, and a
/// Screener factory that counts what it builds. Settings view models take
/// `host` as they would in the app.
@MainActor
final class TestExtraction {
    let host: ExtractionHost
    let intake: MessagesIntake
    let extractor: FakeIntentExtractor
    let log = LoaderLog()
    private let screeners = LoaderLog()

    init(
        extractor: FakeIntentExtractor = FakeIntentExtractor(), ruleStore: any RuleStore = FakeRuleStore(),
        corrections: any CorrectionStore = FakeCorrectionStore(), keyStore: any APIKeyStore = FakeAPIKeyStore(),
        screeningSettings: ScreeningSettings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
    ) {
        let intake = MessagesIntake(
            messagesSource: FakeMessagesSource(messages: []), signalStore: makeTestSignalStore(),
            contactsResolver: FakeContactsResolver(), bundlePath: "/nonexistent"
        )
        let log = self.log
        let screeners = self.screeners
        self.intake = intake
        self.extractor = extractor
        self.host = ExtractionHost(
            intake: intake,
            loader: { _, _ in
                log.loads += 1
                return log.fails ? nil : extractor
            },
            extractionSettings: ExtractionSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!),
            bundleIdentifier: "DailyOSTests", ruleStore: ruleStore, corrections: Corrections(store: corrections),
            screeningSettings: screeningSettings, apiKeyStore: keyStore,
            makeScreener: { _ in
                screeners.loads += 1
                return FakeScreener()
            }
        )
    }

    /// How many Screeners the Host has built: one per breaker.
    var screenersBuilt: Int { screeners.loads }
}
