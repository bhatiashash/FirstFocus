import FirstFocusApp
import FirstFocusCore
import Foundation

private func tempPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("firstfocus-rules-\(UUID().uuidString).sqlite").path
}

private struct RulesHarness: @unchecked Sendable {
    let model: AppModel
    let extractor: FakeIntentExtractor
    let rules: FakeRuleStore
}

func registerRulesTests(_ runner: TestRunner) {
    runner.suite("SQLiteRuleStore") { r in
        r.run("Rules persist across a reopen, in the order they were added") {
            let path = tempPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            _ = try SQLiteRuleStore(path: path).add("Shipping updates are never tasks")
            _ = try SQLiteRuleStore(path: path).add("A question about plans is not a task unless it asks me to do something")
            try expect(SQLiteRuleStore(path: path).rules().map(\.text) == [
                "Shipping updates are never tasks",
                "A question about plans is not a task unless it asks me to do something",
            ])
        }

        r.run("a sixth Rule is refused") {
            let path = tempPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteRuleStore(path: path)
            for i in 1...5 { _ = try store.add("Rule \(i)") }
            var refused = false
            do { _ = try store.add("Rule 6") } catch RuleStoreError.capReached { refused = true }
            try expect(refused)
            try expect(store.rules().count == 5)
        }

        r.run("editing and deleting change the stored set") {
            let path = tempPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteRuleStore(path: path)
            let first = try store.add("Old wording")
            let second = try store.add("Delete me")
            try store.update(id: first.id, text: "New wording")
            try store.delete(id: second.id)
            try expect(SQLiteRuleStore(path: path).rules().map(\.text) == ["New wording"])
        }

        r.run("the proposal watermark round-trips, and is nil until set") {
            let path = tempPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = SQLiteRuleStore(path: path)
            try expect(store.proposalWatermark == nil)
            let when = Date(timeIntervalSince1970: 1_800_000_000)
            store.proposalWatermark = when
            try expect(SQLiteRuleStore(path: path).proposalWatermark == when)
        }
    }

    runner.suite("Rules in the system turn (ADR 0038)") { r in
        r.run("with no Rules, the system turn is exactly what it was without them") {
            try expect(LlamaCppIntentExtractor.systemTurn(rules: []) == LlamaCppIntentExtractor.systemTurn())
        }

        r.run("Rules appear in order, under their own heading, after the instructions and before the examples") {
            let turn = LlamaCppIntentExtractor.systemTurn(rules: ["First rule", "Second rule"])
            let heading = try require(turn.range(of: "RULES"))
            let first = try require(turn.range(of: "- First rule"))
            let second = try require(turn.range(of: "- Second rule"))
            let examples = try require(turn.range(of: "EXAMPLES:"))
            let instructions = try require(turn.range(of: "INPUT FORMAT:"))
            try expect(instructions.lowerBound < heading.lowerBound)
            try expect(heading.lowerBound < first.lowerBound && first.lowerBound < second.lowerBound)
            try expect(second.lowerBound < examples.lowerBound)
        }

        r.run("a custom prompt with no EXAMPLES section gets its Rules at the end") {
            let turn = LlamaCppIntentExtractor.systemTurn(promptOverride: "Only output NONE.", rules: ["Be brief"])
            try expect(turn.contains("Only output NONE.\n\nRULES"))
            try expect(turn.hasSuffix("- Be brief<|im_end|>\n"))
        }

        r.run("changing the Rules changes the system turn") {
            try expect(LlamaCppIntentExtractor.systemTurn(rules: ["A"]) != LlamaCppIntentExtractor.systemTurn(rules: ["B"]))
        }
    }

    runner.suite("RulesViewModel") { r in
        r.run("adding, editing and deleting a Rule each hand the new set to the loaded model") {
            let store = FakeRuleStore()
            let extraction = await MainActor.run { TestExtraction(ruleStore: store) }
            await extraction.host.load()
            let viewModel = await MainActor.run { RulesViewModel(store: store, extraction: extraction.host) }
            try await MainActor.run {
                viewModel.draft = "Shipping updates are never tasks"
                viewModel.addDraft()
                try expect(extraction.extractor.rules == ["Shipping updates are never tasks"])
            }
            let id = try require(store.stored.first?.id)
            try await MainActor.run {
                viewModel.update(id: id, text: "Delivery notices are never tasks")
                try expect(extraction.extractor.rules == ["Delivery notices are never tasks"])
                viewModel.delete(id: id)
                try expect(extraction.extractor.rules.isEmpty)
                try expect(viewModel.rules.isEmpty)
                try expect(viewModel.draft.isEmpty)
            }
        }

        r.run("a sixth Rule is refused with a reason, and the model keeps the five") {
            let store = FakeRuleStore()
            for i in 1...5 { _ = try store.add("Rule \(i)") }
            let extraction = await MainActor.run { TestExtraction(ruleStore: store) }
            await extraction.host.load()
            let viewModel = await MainActor.run { RulesViewModel(store: store, extraction: extraction.host) }
            try await MainActor.run {
                viewModel.draft = "Rule 6"
                viewModel.addDraft()
                try expect(viewModel.errorMessage?.contains("Delete one first") == true, "got \(viewModel.errorMessage ?? "nil")")
                try expect(extraction.extractor.rules.count == 5)
                try expect(viewModel.rules.count == 5)
            }
        }
    }

    runner.suite("AppModel: Rules reach the extractor") { r in
        r.run("the stored Rules are handed to the extractor at launch, and again whenever they change") {
            let h = await MainActor.run { () -> RulesHarness in
                let defaults = UserDefaults(suiteName: "FirstFocusTests-\(UUID().uuidString)")!
                let extractor = FakeIntentExtractor()
                let rules = FakeRuleStore()
                _ = try? rules.add("Shipping updates are never tasks")
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
                    d.correctionStore = FakeCorrectionStore()
                    d.apiKeyStore = FakeAPIKeyStore()
                    d.ruleStore = rules
                    d.bundlePath = "/nonexistent"
                })
                return RulesHarness(model: model, extractor: extractor, rules: rules)
            }
            await h.model.start()
            try expect(h.extractor.rules == ["Shipping updates are never tasks"])
            _ = try h.rules.add("Delivery notices are never tasks")
            await MainActor.run { h.model.extraction.applyRules() }
            try expect(h.extractor.rules == ["Shipping updates are never tasks", "Delivery notices are never tasks"])
        }
    }
}
