import FirstFocusCore
import Foundation

/// Each test gets its own isolated `UserDefaults` suite rather than
/// `.standard`, so these never read or leave behind real state on the
/// machine running them, and tests can't interfere with each other.
private func freshDefaults() -> UserDefaults {
    let suiteName = "firstfocus-tests-zen-focus-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return defaults
}

func registerZenFocusModePreferenceTests(_ runner: TestRunner) {
    runner.suite("ZenFocusModePreference (ticket 06)") { r in
        r.run("a fresh preference defaults to disabled") {
            let preference = ZenFocusModePreference(defaults: freshDefaults())
            try expect(preference.isEnabled == false)
        }

        r.run("enabling is reflected back on the same instance") {
            let preference = ZenFocusModePreference(defaults: freshDefaults())
            preference.isEnabled = true
            try expect(preference.isEnabled)
        }

        r.run("the toggle's persisted state survives a fresh instance, the way isBackfillComplete and similar flags already do") {
            let defaults = freshDefaults()
            let first = ZenFocusModePreference(defaults: defaults)
            first.isEnabled = true

            let second = ZenFocusModePreference(defaults: defaults)
            try expect(second.isEnabled, "a fresh instance over the same UserDefaults must read back what an earlier instance wrote")
        }

        r.run("disabling again is reflected back too, not stuck once true") {
            let defaults = freshDefaults()
            let preference = ZenFocusModePreference(defaults: defaults)
            preference.isEnabled = true
            preference.isEnabled = false
            try expect(ZenFocusModePreference(defaults: defaults).isEnabled == false)
        }
    }
}
