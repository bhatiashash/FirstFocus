import DailyOSApp
import DailyOSCore
import Foundation

/// intake-pass-slot ticket 02: AppModel shows which kind of Messages pass
/// is running, and the controls a pass disables say which one it is.
extension GatedIntentExtractor: FreeTextGenerating {
    func generateText(system: String, user: String, maxTokens: Int, priority: TaskPriority) async throws -> String { "" }
}

private func message(id: String, text: String) -> ChatMessage {
    ChatMessage(id: id, chatId: 1, isFromMe: true, text: text, createdAt: Date().addingTimeInterval(-60))
}

/// A model whose store already has `m1` Processed with nothing found, so
/// the launch pass has no model call to make unless `m1` is left new.
@MainActor
private func makeModel(extractor: GatedIntentExtractor, m1AlreadyProcessed: Bool) throws -> AppModel {
    let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
    let store = makeTestSignalStore()
    try store.markBackfillComplete()
    if m1AlreadyProcessed { try store.recordOneMessageBatch("m1", signals: []) }
    let corrections = FakeCorrectionStore()
    // Enough "Not for me" Corrections that only a running pass can keep
    // Propose Rules from being ready.
    for index in 0..<minimumCorrectionsForProposal {
        try corrections.record(Correction(
            chatId: 1, sourceRef: "b\(index)", inputText: "x", correctedOutput: "NONE", correctionType: .falsePositive
        ))
    }
    return AppModel(
        taskSource: FakeTaskSource(tasks: [], availability: .available),
        messagesSource: FakeMessagesSource(messages: [message(id: "m1", text: "call the dentist")]), signalStore: store,
        contactsResolver: FakeContactsResolver(), settingsOpener: FakeSettingsOpener(),
        refreshClock: FakeRefreshClock(), eventKitChanges: FakeEventKitChangeObserver(),
        foregroundObserver: FakeForegroundObserver(),
        zenFocusModePreference: ZenFocusModePreference(defaults: defaults),
        focusListPreference: isolatedFocusListOff(), reExtractionSettings: ReExtractionSettings(defaults: defaults),
        extractor: extractor, historyStore: makeTestHistoryStore(), correctionStore: corrections,
        screeningSettings: screeningOn(defaults), apiKeyStore: FakeAPIKeyStore(), bundlePath: "/nonexistent"
    )
}

/// The Screening toggle on, so History offers "This was work".
private func screeningOn(_ defaults: UserDefaults) -> ScreeningSettings {
    let settings = ScreeningSettings(defaults: defaults)
    settings.isEnabled = true
    return settings
}

private let screenedRow = HistoryEntry(
    sourceRawText: "call the dentist", modelUsed: "JEV", signalCount: 0, chatId: 1,
    kind: .screening(ScreeningDecision(probability: 0.1, mode: .live(cutoff: 0.4))), sourceRef: "m1"
)

func registerPassMenuTests(_ runner: TestRunner) {
    runner.suite("AppModel: the running Messages pass, by kind") { r in
        r.run("the launch pass reads as checking Messages, and nothing else can start") {
            let extractor = GatedIntentExtractor()
            let model = try await MainActor.run { try makeModel(extractor: extractor, m1AlreadyProcessed: false) }
            let launch = Task { await model.start() }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel)
            try await MainActor.run {
                try expect(model.runningMessagesPass == .automatic)
                try expect(model.reExtractionMenuTitle == "Checking Messages…")
                try expect(!model.canReExtract)
                try expect(model.ruleProposalStatus() == .passRunning)
            }
            extractor.open()
            await launch.value
            try await MainActor.run {
                try expect(model.runningMessagesPass == nil)
                try expect(model.reExtractionMenuTitle == "Re-run Extraction")
                try expect(model.ruleProposalStatus() == .ready(newCorrections: minimumCorrectionsForProposal))
            }
        }

        r.run("a re-extraction reads as re-extracting") {
            let extractor = GatedIntentExtractor()
            let model = try await MainActor.run { try makeModel(extractor: extractor, m1AlreadyProcessed: true) }
            await model.start()
            let reExtracting = Task { await model.reExtract() }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel)
            try await MainActor.run {
                try expect(model.runningMessagesPass == .reExtraction)
                try expect(model.reExtractionMenuTitle == "Re-extracting…")
                try expect(model.ruleProposalStatus() == .passRunning)
            }
            extractor.open()
            await reExtracting.value
            try await MainActor.run { try expect(model.runningMessagesPass == nil) }
        }

        r.run("This was work reads as checking one Batch") {
            let extractor = GatedIntentExtractor()
            let model = try await MainActor.run { try makeModel(extractor: extractor, m1AlreadyProcessed: true) }
            await model.start()
            let checking = Task { await model.historyActions.thisWasWork(historyBatch(screenedRow)) }
            let reachedModel = await waitUntil { extractor.calls.count == 1 }
            try expect(reachedModel)
            try await MainActor.run {
                try expect(model.runningMessagesPass == .explicit)
                try expect(model.reExtractionMenuTitle == "Checking a Batch…")
                try expect(!model.canReExtract)
                try expect(model.ruleProposalStatus() == .passRunning)
            }
            extractor.open()
            await checking.value
            try await MainActor.run { try expect(model.runningMessagesPass == nil) }
        }
    }
}
