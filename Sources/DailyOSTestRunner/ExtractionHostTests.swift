import DailyOSCore
import Foundation

// extraction-host: the model's life, its Rules, Rule proposals and
// Screening, driven through a real `ExtractionHost` on fakes
// (`TestExtraction`). No AppModel.

private final class Changes: @unchecked Sendable {
    var loadedAtEach: [Bool] = []
}

@MainActor
private func watching(_ extraction: TestExtraction) -> Changes {
    let changes = Changes()
    extraction.host.onChange = { changes.loadedAtEach.append(extraction.host.isLoaded) }
    return changes
}

private func falsePositives(_ count: Int, words: Int = 3) -> FakeCorrectionStore {
    let store = FakeCorrectionStore()
    for i in 0..<count {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        try? store.record(Correction(
            chatId: i, inputText: "\(text) \(i)", correctedOutput: "", correctionType: .falsePositive,
            createdAt: Date().addingTimeInterval(Double(i) - 100)
        ))
    }
    return store
}

func registerExtractionHostTests(_ runner: TestRunner) {
    runner.suite("ExtractionHost: loading the model") { r in
        r.run("a load hands Intake the model and fires onChange") {
            let extraction = await MainActor.run { TestExtraction() }
            let changes = await MainActor.run { watching(extraction) }
            await extraction.host.load()
            try await MainActor.run {
                try expect(extraction.host.isLoaded)
                try expect(!extraction.host.isUnavailable)
                try expect(extraction.host.displayName == "Fake Model")
                try expect(changes.loadedAtEach == [true])
            }
        }

        r.run("a load that fails leaves extraction Unavailable") {
            let extraction = await MainActor.run { TestExtraction() }
            extraction.log.fails = true
            let changes = await MainActor.run { watching(extraction) }
            await extraction.host.load()
            try await MainActor.run {
                try expect(!extraction.host.isLoaded)
                try expect(extraction.host.isUnavailable)
                try expect(changes.loadedAtEach == [false])
            }
        }

        r.run("a second load with a model loaded reads nothing again (ADR 0026)") {
            let extraction = await MainActor.run { TestExtraction() }
            await extraction.host.load()
            await extraction.host.load()
            try expect(extraction.log.loads == 1)
        }

        r.run("Retry after a failure loads the model") {
            let extraction = await MainActor.run { TestExtraction() }
            extraction.log.fails = true
            await extraction.host.load()
            extraction.log.fails = false
            await extraction.host.retry()
            try await MainActor.run {
                try expect(extraction.host.isLoaded)
                try expect(!extraction.host.isUnavailable)
            }
        }

        r.run("a settings change drops the model, says so, then loads it again") {
            let extraction = await MainActor.run { TestExtraction() }
            await extraction.host.load()
            let changes = await MainActor.run { watching(extraction) }
            await extraction.host.applySettingsChange()
            try expect(changes.loadedAtEach == [false, true], "History shows model-bound actions disabled while it loads")
            try expect(extraction.log.loads == 2)
        }

        r.run("unloading leaves extraction Unavailable and fires onChange") {
            let extraction = await MainActor.run { TestExtraction() }
            await extraction.host.load()
            let changes = await MainActor.run { watching(extraction) }
            try await MainActor.run {
                extraction.host.unload()
                try expect(!extraction.host.isLoaded)
                try expect(extraction.host.isUnavailable)
                try expect(changes.loadedAtEach == [false])
            }
        }
    }

    runner.suite("ExtractionHost: Rules (ADR 0038)") { r in
        r.run("a load hands the model the approved Rules") {
            let rules = FakeRuleStore()
            _ = try rules.add("Shipping updates are never tasks")
            let extraction = await MainActor.run { TestExtraction(ruleStore: rules) }
            await extraction.host.load()
            try expect(extraction.extractor.rules == ["Shipping updates are never tasks"])
        }

        r.run("a reload hands the new model the Rules too") {
            let rules = FakeRuleStore()
            let extraction = await MainActor.run { TestExtraction(ruleStore: rules) }
            await extraction.host.load()
            _ = try rules.add("Receipts are never tasks")
            await extraction.host.applySettingsChange()
            try expect(extraction.extractor.rules == ["Receipts are never tasks"])
        }
    }

    runner.suite("ExtractionHost: proposing Rules") { r in
        r.run("with no model loaded there is nothing to propose with") {
            let extraction = await MainActor.run { TestExtraction(corrections: falsePositives(5)) }
            let status = await MainActor.run { extraction.host.ruleProposalStatus() }
            try expect(status == .noModel)
        }

        r.run("a running pass or re-extraction holds a proposal back (ADR 0034)") {
            let extraction = await MainActor.run { TestExtraction(corrections: falsePositives(5)) }
            await extraction.host.load()
            try await MainActor.run {
                try expect(extraction.host.ruleProposalStatus() == .ready(newCorrections: 5))
                extraction.host.isPassRunning = { true }
                try expect(extraction.host.ruleProposalStatus() == .passRunning)
            }
            let proposed = await extraction.host.proposeRules()
            try expect(proposed.isEmpty)
        }

        r.run("a proposal that produced Rules uses the Corrections up; an empty one doesn't") {
            let rules = FakeRuleStore()
            let extractor = FakeIntentExtractor()
            let extraction = await MainActor.run {
                TestExtraction(extractor: extractor, ruleStore: rules, corrections: falsePositives(5))
            }
            await extraction.host.load()
            let empty = await extraction.host.proposeRules()
            try expect(empty.isEmpty)
            try expect(rules.proposalWatermark == nil, "the user can simply try again")

            extractor.freeTextResponse = "Receipts are never tasks"
            let proposed = await extraction.host.proposeRules()
            try expect(proposed == ["Receipts are never tasks"])
            try expect(rules.proposalWatermark != nil)
            let status = await MainActor.run { extraction.host.ruleProposalStatus() }
            try expect(status == .needsMoreCorrections(have: 0))
        }

        r.run("only as many Corrections as fit the model's prompt are sent") {
            let extractor = FakeIntentExtractor(maxPromptTokens: ruleProposalMaxTokens + 400)
            extractor.freeTextResponse = "A rule"
            let extraction = await MainActor.run {
                TestExtraction(extractor: extractor, corrections: falsePositives(8, words: 60))
            }
            await extraction.host.load()
            _ = await extraction.host.proposeRules()
            let sent = try require(extractor.freeTextRequests.first?.user)
            let included = (0..<8).filter { sent.contains("word \($0)") }.count
            try expect(included > 0 && included < 8, "got \(included) of 8")
        }
    }

    runner.suite("ExtractionHost: Screening (ADR 0036)") { r in
        r.run("with the toggle on and a key, Intake screens; the breaker is kept while the key stays") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let keys = FakeAPIKeyStore(key: "k1")
            let extraction = await MainActor.run { TestExtraction(keyStore: keys, screeningSettings: settings) }
            try await MainActor.run {
                extraction.host.applyScreeningSettings()
                try expect(extraction.intake.screeningMode != .off)
                try expect(extraction.intake.screener != nil)
                extraction.host.applyScreeningSettings()
                try expect(extraction.screenersBuilt == 1)
            }
        }

        r.run("a new key gets its own breaker") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let keys = FakeAPIKeyStore(key: "k1")
            let extraction = await MainActor.run { TestExtraction(keyStore: keys, screeningSettings: settings) }
            try await MainActor.run {
                extraction.host.applyScreeningSettings()
                keys.key = "k2"
                extraction.host.applyScreeningSettings()
                try expect(extraction.screenersBuilt == 2)
            }
        }

        r.run("an access change rebuilds the breaker and fires onChange") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let extraction = await MainActor.run {
                TestExtraction(keyStore: FakeAPIKeyStore(key: "k1"), screeningSettings: settings)
            }
            let changes = await MainActor.run { watching(extraction) }
            try await MainActor.run {
                extraction.host.applyScreeningSettings()
                extraction.host.applyScreeningAccessChange()
                try expect(extraction.screenersBuilt == 2)
                try expect(changes.loadedAtEach.count == 1)
            }
        }

        r.run("with no key, nothing leaves the Mac") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            settings.isEnabled = true
            let extraction = await MainActor.run { TestExtraction(screeningSettings: settings) }
            try await MainActor.run {
                extraction.host.applyScreeningSettings()
                try expect(extraction.intake.screeningMode == .off)
                try expect(extraction.intake.screener == nil)
                try expect(extraction.screenersBuilt == 0)
            }
        }
    }
}
