import DailyOSApp
import DailyOSCore
import Foundation

func registerOutputPrefixAndCutoffTests(_ runner: TestRunner) {
    runner.suite("parseExtractionOutput: a leaked \"Output:\" prefix") { r in
        r.run("is removed from a Label") {
            try expect(parseExtractionOutput("Output: Rewrite onboarding flow") == ["Rewrite onboarding flow"])
        }

        r.run("in front of NONE still means no Signal") {
            try expect(parseExtractionOutput("Output: NONE").isEmpty)
        }

        r.run("doesn't touch a Label that merely starts with the word Output") {
            try expect(parseExtractionOutput("Output report to finance") == ["Output report to finance"])
        }

        r.run("leaves the DUE_TEXT line out, as before") {
            try expect(parseExtractionOutput("Output: Call the dentist\nDUE_TEXT: \"tomorrow\"") == ["Call the dentist"])
        }
    }

    runner.suite("Screening cutoff is stored to two decimal places") { r in
        r.run("floating-point drift from the stepper is rounded away") {
            let settings = ScreeningSettings(defaults: UserDefaults(suiteName: "DailyOSTests-\(UUID().uuidString)")!)
            let app = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { ScreeningSettingsViewModel(settings: settings, keyStore: FakeAPIKeyStore(), extraction: app.host) }
            await MainActor.run { viewModel.setCutoff(0.4999999999999996) }
            try expect(settings.cutoff == 0.5, "got \(String(describing: settings.cutoff))")
            let shown = await MainActor.run { viewModel.cutoff }
            try expect(shown == 0.5)
        }
    }
}
