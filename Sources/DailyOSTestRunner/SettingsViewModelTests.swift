import DailyOSApp
import DailyOSCore
import Foundation

/// Advanced's Extraction Prompt and Re-extraction settings, driven through
/// `SettingsViewModel` with a fake reloader so no test loads a real model.

/// A suite name rather than the `UserDefaults` itself, since a name can
/// cross into `MainActor.run` and the defaults object can't.
private func isolatedSuite() -> String {
    "dailyos-tests-settings-viewmodel-\(UUID().uuidString)"
}

private func defaults(_ suite: String) -> UserDefaults {
    UserDefaults(suiteName: suite)!
}

/// Stores a prompt the way an app version before prompt format versioning
/// did, so `ExtractionSettings` sets it aside.
private func storeOldFormatPrompt(_ prompt: String, in defaults: UserDefaults) {
    defaults.set(prompt, forKey: "extractionPromptOverride")
}

@MainActor
private func makeViewModel(
    suite: String, reloader: TestExtraction = TestExtraction()
) -> SettingsViewModel {
    SettingsViewModel(
        extractionSettings: ExtractionSettings(defaults: defaults(suite)),
        reExtractionSettings: ReExtractionSettings(defaults: defaults(suite)),
        extraction: reloader.host
    )
}

func registerSettingsViewModelTests(_ runner: TestRunner) {
    runner.suite("SettingsViewModel") { r in
        r.run("starts from the built-in prompt when nothing is saved") {
            try await MainActor.run {
                let viewModel = makeViewModel(suite: isolatedSuite())
                try expect(viewModel.prompt == LlamaCppIntentExtractor.defaultExtractionPrompt)
            }
        }

        r.run("starts from the saved prompt when one is saved") {
            try await MainActor.run {
                let suite = isolatedSuite()
                ExtractionSettings(defaults: defaults(suite)).promptOverride = "Only ever output NONE."
                let viewModel = makeViewModel(suite: suite)
                try expect(viewModel.prompt == "Only ever output NONE.")
            }
        }

        r.run("saving an edited prompt stores it and reloads extraction once") {
            let suite = isolatedSuite()
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { makeViewModel(suite: suite, reloader: reloader) }
            await MainActor.run { viewModel.prompt = "Custom prompt." }
            await viewModel.saveAndReload()
            try await MainActor.run {
                try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == "Custom prompt.")
                try expect(reloader.log.loads == 1)
                try expect(viewModel.statusMessage == "Saved. Extraction is using the new prompt.")
            }
        }

        r.run("saving an empty prompt stores no override") {
            let suite = isolatedSuite()
            ExtractionSettings(defaults: defaults(suite)).promptOverride = "Custom prompt."
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            await MainActor.run { viewModel.prompt = "   \n" }
            await viewModel.saveAndReload()
            try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == nil)
        }

        r.run("saving the built-in prompt unchanged stores no override") {
            let suite = isolatedSuite()
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            await viewModel.saveAndReload()
            try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == nil)
        }

        r.run("saving the default while an old prompt is set aside keeps the old prompt") {
            let suite = isolatedSuite()
            storeOldFormatPrompt("my old prompt", in: defaults(suite))
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            await viewModel.saveAndReload()
            try await MainActor.run {
                try expect(viewModel.setAsidePrompt == "my old prompt")
                try expect(ExtractionSettings(defaults: defaults(suite)).setAsidePromptOverride == "my old prompt")
            }
        }

        r.run("a reload that leaves extraction unavailable says so") {
            let reloader = await MainActor.run { TestExtraction() }
            await MainActor.run { reloader.log.fails = true }
            let viewModel = await MainActor.run { makeViewModel(suite: isolatedSuite(), reloader: reloader) }
            await MainActor.run { viewModel.prompt = "Custom prompt." }
            await viewModel.saveAndReload()
            try await MainActor.run {
                try expect(viewModel.statusMessage == "Couldn't load the model — check Models and try again.")
            }
        }

        r.run("lookback is edited in hours and stored in days") {
            let suite = isolatedSuite()
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            await MainActor.run { viewModel.reExtractionLookbackHours = 72 }
            try expect(ReExtractionSettings(defaults: defaults(suite)).lookbackDays == 3)
        }
        r.run("prompt status reads Default with nothing saved, Custom with a saved prompt, and set aside for an old one") {
            try await MainActor.run {
                try expect(makeViewModel(suite: isolatedSuite()).promptStatus == .builtIn)

                let custom = isolatedSuite()
                ExtractionSettings(defaults: defaults(custom)).promptOverride = "Custom prompt."
                try expect(makeViewModel(suite: custom).promptStatus == .custom)

                let old = isolatedSuite()
                storeOldFormatPrompt("my old prompt", in: defaults(old))
                try expect(makeViewModel(suite: old).promptStatus == .setAside)
            }
        }

        r.run("cancelling an edit leaves the saved prompt alone and the next edit starts from it") {
            let suite = isolatedSuite()
            ExtractionSettings(defaults: defaults(suite)).promptOverride = "Saved prompt."
            let reloader = await MainActor.run { TestExtraction() }
            try await MainActor.run {
                let viewModel = makeViewModel(suite: suite, reloader: reloader)
                viewModel.beginEditing()
                viewModel.prompt = "Half-finished edit"
                viewModel.cancelEditing()
                try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == "Saved prompt.")
                try expect(reloader.log.loads == 0)
                viewModel.beginEditing()
                try expect(viewModel.prompt == "Saved prompt.")
            }
        }

        r.run("saving reports whether extraction came back") {
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { makeViewModel(suite: isolatedSuite(), reloader: reloader) }
            await MainActor.run { viewModel.prompt = "Custom prompt." }
            let succeeded = await viewModel.saveAndReload()
            try expect(succeeded)

            await MainActor.run { reloader.log.fails = true }
            let failed = await viewModel.saveAndReload()
            try expect(!failed)
        }

        r.run("a failed reload keeps the saved prompt") {
            let suite = isolatedSuite()
            let reloader = await MainActor.run { TestExtraction() }
            await MainActor.run { reloader.log.fails = true }
            let viewModel = await MainActor.run { makeViewModel(suite: suite, reloader: reloader) }
            await MainActor.run { viewModel.prompt = "Custom prompt." }
            await viewModel.saveAndReload()
            try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == "Custom prompt.")
        }

        r.run("reset to default clears the saved prompt and reloads once") {
            let suite = isolatedSuite()
            ExtractionSettings(defaults: defaults(suite)).promptOverride = "Custom prompt."
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { makeViewModel(suite: suite, reloader: reloader) }
            await viewModel.resetToDefault()
            try await MainActor.run {
                try expect(ExtractionSettings(defaults: defaults(suite)).promptOverride == nil)
                try expect(reloader.log.loads == 1)
                try expect(viewModel.promptStatus == .builtIn)
                try expect(viewModel.prompt == LlamaCppIntentExtractor.defaultExtractionPrompt)
            }
        }

        r.run("reset to default keeps an old prompt that was set aside") {
            let suite = isolatedSuite()
            storeOldFormatPrompt("my old prompt", in: defaults(suite))
            let viewModel = await MainActor.run { makeViewModel(suite: suite) }
            await viewModel.resetToDefault()
            try await MainActor.run {
                try expect(viewModel.setAsidePrompt == "my old prompt")
                try expect(viewModel.promptStatus == .setAside)
            }
        }
    }
}
