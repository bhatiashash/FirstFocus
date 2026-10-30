import FirstFocusApp
import FirstFocusCore
import Foundation

private struct Harness: @unchecked Sendable {
    let model: AppModel
    let extractor: ThrowingFreeTextExtractor
    let corrections: FakeCorrectionStore
    let rules: FakeRuleStore
}

/// Generates free text by throwing, to stand in for a failed proposal.
final class ThrowingFreeTextExtractor: IntentExtractor, FreeTextGenerating, @unchecked Sendable {
    let modelDisplayName = "Throwing Fake"
    let maxPromptTokens = 10_000
    func extract(from text: String, priority: TaskPriority) async throws -> String { "NONE" }
    func estimatedTokenCount(for text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
    func generateText(system: String, user: String, maxTokens: Int, priority: TaskPriority) async throws -> String {
        throw FakeScreeningFailure()
    }
}

func registerReviewFixTests(_ runner: TestRunner) {
    runner.suite("Review fixes") { r in
        r.run("parseProposedRules drops a phone-number-like run but keeps a line with scattered digits") {
            try expect(parseProposedRules("Reply by 5 pm on day 1 of 2 weeks, 3 to 4 times in 20 minutes") ==
                ["Reply by 5 pm on day 1 of 2 weeks, 3 to 4 times in 20 minutes"])
            try expect(parseProposedRules("Call 555-000-1111 back").isEmpty)
        }

        r.run("a failed proposal leaves the watermark, so the Corrections still count") {
            let h = await MainActor.run { () -> Harness in
                let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
                let corrections = FakeCorrectionStore()
                for i in 0..<5 {
                    try? corrections.record(Correction(chatId: i, inputText: "notice \(i)", correctedOutput: "NONE", correctionType: .falsePositive))
                }
                let extractor = ThrowingFreeTextExtractor()
                let rules = FakeRuleStore()
                let model = AppModel(AppDependencies.test { d in
                    d.taskSource = FakeTaskSource(tasks: [], availability: .available)
                    d.messagesSource = FakeMessagesSource(messages: [])
                    d.signalStore = makeTestSignalStore()
                    d.contactsResolver = FakeContactsResolver()
                    d.settingsOpener = FakeSettingsOpener()
                    d.refreshClock = FakeRefreshClock()
                    d.eventKitChanges = FakeEventKitChangeObserver()
                    d.foregroundObserver = FakeForegroundObserver()
                    d.zenFocusModePreference = ZenFocusModePreference(defaults: defaults)
                    d.reExtractionSettings = ReExtractionSettings(defaults: defaults)
                    d.loadModel = { _, _ in extractor }
                    d.historyStore = makeTestHistoryStore()
                    d.correctionStore = corrections
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.ruleStore = rules
                    d.bundlePath = "/nonexistent"
                })
                return Harness(model: model, extractor: extractor, corrections: corrections, rules: rules)
            }
            await h.model.start()
            let proposed = await h.model.extraction.proposeRules()
            try expect(proposed.isEmpty)
            try expect(h.rules.proposalWatermark == nil, "nothing was proposed, so nothing was used up")
            let status = await MainActor.run { h.model.extraction.ruleProposalStatus() }
            try expect(status == .ready(newCorrections: 5))
        }

        r.run("a Correction recorded in the same second as the watermark, but after it, still counts") {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("firstfocus-rf-\(UUID().uuidString).sqlite").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteCorrectionStore(path: path)
            let second = Date(timeIntervalSince1970: 1_800_000_000)
            let watermark = second.addingTimeInterval(0.2)
            try store.record(Correction(chatId: 1, inputText: "before", correctedOutput: "NONE", correctionType: .falsePositive,
                                        createdAt: second.addingTimeInterval(0.1)))
            try store.record(Correction(chatId: 1, inputText: "after", correctedOutput: "NONE", correctionType: .falsePositive,
                                        createdAt: second.addingTimeInterval(0.6)))
            let counted = store.corrections(ofType: .falsePositive, createdAfter: watermark, limit: 10)
            try expect(counted.map(\.inputText) == ["after"], "got \(counted.map(\.inputText))")
        }
    }
}
