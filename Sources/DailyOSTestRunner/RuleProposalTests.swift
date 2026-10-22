import DailyOSApp
import DailyOSCore
import Foundation

private struct ProposalHarness: @unchecked Sendable {
    let model: AppModel
    let extractor: FakeIntentExtractor
    let corrections: FakeCorrectionStore
    let rules: FakeRuleStore
}

private func makeHarness(falsePositives: Int, falseNegatives: Int = 0, withModel: Bool = true) async -> ProposalHarness {
    await MainActor.run {
        let defaults = UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!
        let extractor = FakeIntentExtractor()
        let corrections = FakeCorrectionStore()
        for i in 0..<falsePositives {
            try? corrections.record(Correction(
                chatId: i, inputText: "Participant A: shipment \(i) is out for delivery", correctedOutput: "NONE",
                correctionType: .falsePositive
            ))
        }
        for i in 0..<falseNegatives {
            try? corrections.record(Correction(
                chatId: 100 + i, inputText: "missed task \(i)", correctedOutput: "", correctionType: .falseNegative
            ))
        }
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
            d.extractor = withModel ? extractor : nil
            d.historyStore = makeTestHistoryStore()
            d.correctionStore = corrections
            d.apiKeyStore = FakeAPIKeyStore()
            d.ruleStore = rules
            d.bundlePath = "/nonexistent"
        })
        return ProposalHarness(model: model, extractor: extractor, corrections: corrections, rules: rules)
    }
}

func registerRuleProposalTests(_ runner: TestRunner) {
    runner.suite("Proposing Rules: when it's allowed (ADR 0038)") { r in
        r.run("four new \"Not for me\" Corrections aren't enough; five are") {
            let four = await makeHarness(falsePositives: 4)
            await four.model.start()
            let fourStatus = await MainActor.run { four.model.ruleProposalStatus() }
            try expect(fourStatus == .needsMoreCorrections(have: 4))

            let five = await makeHarness(falsePositives: 5)
            await five.model.start()
            let fiveStatus = await MainActor.run { five.model.ruleProposalStatus() }
            try expect(fiveStatus == .ready(newCorrections: 5))
        }

        r.run("false-negative Corrections never count") {
            let h = await makeHarness(falsePositives: 4, falseNegatives: 10)
            await h.model.start()
            let status = await MainActor.run { h.model.ruleProposalStatus() }
            try expect(status == .needsMoreCorrections(have: 4))
        }

        r.run("with no model loaded, proposing is unavailable") {
            let h = await makeHarness(falsePositives: 5, withModel: false)
            let status = await MainActor.run { h.model.ruleProposalStatus() }
            try expect(status == .noModel)
        }
    }

    runner.suite("Proposing Rules: what it does") { r in
        r.run("sends only false-positive Corrections to the local model, returns at most three Rules, and moves the watermark") {
            let h = await makeHarness(falsePositives: 5, falseNegatives: 2)
            await h.model.start()
            h.extractor.freeTextResponse = "- Delivery notices are never tasks\n2. Order confirmations are never tasks\nRule three\nRule four"
            let proposed = await h.model.proposeRules()
            try expect(proposed == ["Delivery notices are never tasks", "Order confirmations are never tasks", "Rule three"])

            let request = try require(h.extractor.freeTextRequests.first)
            try expect(request.user.contains("shipment 0 is out for delivery"))
            try expect(!request.user.contains("missed task"), "false negatives are about Screening, not the model")
            try expect(request.system.contains("Never name"), "the prompt forbids naming people, chats or numbers")

            try expect(h.rules.proposalWatermark != nil)
            let after = await MainActor.run { h.model.ruleProposalStatus() }
            try expect(after == .needsMoreCorrections(have: 0), "proposing starts the count again from zero")
        }

        r.run("proposing is refused below five, and the model is never called") {
            let h = await makeHarness(falsePositives: 3)
            await h.model.start()
            let proposed = await h.model.proposeRules()
            try expect(proposed.isEmpty)
            try expect(h.extractor.freeTextRequests.isEmpty)
            try expect(h.rules.proposalWatermark == nil)
        }
    }

    runner.suite("parseProposedRules") { r in
        r.run("strips list markers and blank lines, and drops any line with a phone number") {
            let raw = "\n1) First rule\n* Second rule\n\nCall +1 555 000 1111 back\n"
            try expect(parseProposedRules(raw) == ["First rule", "Second rule"])
        }
    }

    runner.suite("RulesViewModel: pending proposals") { r in
        r.run("proposals arrive as pending; approve adds one, reject drops one, and discarding clears the rest") {
            let store = FakeRuleStore()
            let app = await MainActor.run { FakeRuleProposingApp(proposals: ["A", "B", "C"]) }
            let viewModel = await MainActor.run { RulesViewModel(store: store, app: app, proposer: app) }
            await viewModel.propose()
            try await MainActor.run {
                try expect(viewModel.pending.map(\.text) == ["A", "B", "C"])
                viewModel.approve(viewModel.pending[0].id, text: "A, edited")
                viewModel.reject(viewModel.pending[0].id)
                try expect(viewModel.pending.map(\.text) == ["C"])
                viewModel.discardPending()
                try expect(viewModel.pending.isEmpty)
            }
            try expect(store.stored.map(\.text) == ["A, edited"])
        }

        r.run("approving at the five-Rule cap is refused and the proposal stays pending") {
            let store = FakeRuleStore()
            for i in 1...5 { _ = try store.add("Rule \(i)") }
            let app = await MainActor.run { FakeRuleProposingApp(proposals: ["Sixth"]) }
            let viewModel = await MainActor.run { RulesViewModel(store: store, app: app, proposer: app) }
            await viewModel.propose()
            try await MainActor.run {
                viewModel.approve(viewModel.pending[0].id, text: "Sixth")
                try expect(viewModel.pending.count == 1)
                try expect(viewModel.errorMessage?.contains("Delete one first") == true)
            }
            try expect(store.stored.count == 5)
        }

        r.run("the Propose button's state comes from the app's status") {
            let app = await MainActor.run { FakeRuleProposingApp(proposals: [], status: .needsMoreCorrections(have: 2)) }
            let viewModel = await MainActor.run { RulesViewModel(store: FakeRuleStore(), app: app, proposer: app) }
            try await MainActor.run {
                try expect(!viewModel.canPropose)
                try expect(viewModel.proposeReason == "2 of 5 new \u{201C}Not for me\u{201D} Corrections so far")
            }
        }
    }
}

@MainActor
final class FakeRuleProposingApp: RulesConfiguring, RuleProposing {
    let proposals: [String]
    var status: RuleProposalStatus
    init(proposals: [String], status: RuleProposalStatus = .ready(newCorrections: 5)) {
        self.proposals = proposals
        self.status = status
    }
    func applyRules() {}
    func ruleProposalStatus() -> RuleProposalStatus { status }
    func proposeRules() async -> [String] { proposals }
}
