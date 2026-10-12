import DailyOSCore
import Foundation

/// Each test gets its own isolated `UserDefaults` suite, the same pattern
/// `ZenFocusModePreferenceTests` already uses, so these never read or
/// leave behind real state on the machine running them.
private func freshDefaults() -> UserDefaults {
    let suiteName = "dailyos-tests-extraction-settings-\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

func registerExtractionSettingsTests(_ runner: TestRunner) {
    runner.suite("ExtractionSettings (ticket 04)") { r in
        r.run("a fresh settings instance has no override for either field") {
            let settings = ExtractionSettings(defaults: freshDefaults())
            try expect(settings.promptOverride == nil)
            try expect(settings.modelPathOverride == nil)
        }

        r.run("a stored override is reflected back on the same instance") {
            let settings = ExtractionSettings(defaults: freshDefaults())
            settings.promptOverride = "Only ever output NONE."
            settings.modelPathOverride = "/tmp/custom-model.gguf"
            try expect(settings.promptOverride == "Only ever output NONE.")
            try expect(settings.modelPathOverride == "/tmp/custom-model.gguf")
        }

        r.run("an override persists across a fresh instance over the same UserDefaults") {
            let defaults = freshDefaults()
            let first = ExtractionSettings(defaults: defaults)
            first.promptOverride = "Custom prompt."
            first.modelPathOverride = "/tmp/model.gguf"

            let second = ExtractionSettings(defaults: defaults)
            try expect(second.promptOverride == "Custom prompt.")
            try expect(second.modelPathOverride == "/tmp/model.gguf")
        }

        r.run("effectiveModelPath falls back to the built-in default when there's no override") {
            let settings = ExtractionSettings(defaults: freshDefaults())
            let expected = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: "com.example.Test")
            try expect(settings.effectiveModelPath(bundleIdentifier: "com.example.Test") == expected)
        }

        r.run("effectiveModelPath uses a non-blank override") {
            let settings = ExtractionSettings(defaults: freshDefaults())
            settings.modelPathOverride = "/tmp/custom-model.gguf"
            try expect(settings.effectiveModelPath(bundleIdentifier: "com.example.Test") == "/tmp/custom-model.gguf")
        }

        r.run("effectiveModelPath falls back to the default when the override is blank, not an empty path") {
            let settings = ExtractionSettings(defaults: freshDefaults())
            settings.modelPathOverride = "   "
            let expected = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: "com.example.Test")
            try expect(settings.effectiveModelPath(bundleIdentifier: "com.example.Test") == expected)
        }

        r.run("modelsDirectoryURL is a models/ folder under the bundle identifier in Application Support") {
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: "com.example.Test")
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let expected = applicationSupport.appendingPathComponent("com.example.Test").appendingPathComponent("models")
            try expect(directory == expected)
        }
    }
}
