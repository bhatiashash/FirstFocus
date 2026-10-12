import DailyOSCore
import Foundation

/// Each test gets its own isolated `UserDefaults` suite, the same pattern
/// `ZenFocusModePreferenceTests` and `ExtractionSettingsTests` already use.
private func freshDefaults() -> UserDefaults {
    let suiteName = "dailyos-tests-reextraction-settings-\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

func registerReExtractionSettingsTests(_ runner: TestRunner) {
    runner.suite("ReExtractionSettings") { r in
        r.run("a fresh settings instance falls back to the documented defaults") {
            let settings = ReExtractionSettings(defaults: freshDefaults())
            try expect(settings.lookbackDays == ReExtractionSettings.defaultLookbackDays)
            try expect(settings.minimumIntervalHours == ReExtractionSettings.defaultMinimumIntervalHours)
            try expect(settings.lastRunAt == nil)
        }

        r.run("a stored lookback and interval are reflected back on the same instance") {
            let settings = ReExtractionSettings(defaults: freshDefaults())
            settings.lookbackDays = 5
            settings.minimumIntervalHours = 12
            try expect(settings.lookbackDays == 5)
            try expect(settings.minimumIntervalHours == 12)
        }

        r.run("a zero-hour interval is a legitimate stored value, not confused with never having been set") {
            let settings = ReExtractionSettings(defaults: freshDefaults())
            settings.minimumIntervalHours = 0
            try expect(settings.minimumIntervalHours == 0, "0 must round-trip as 0, not fall back to the default")
        }

        r.run("stored values persist across a fresh instance over the same UserDefaults") {
            let defaults = freshDefaults()
            let first = ReExtractionSettings(defaults: defaults)
            first.lookbackDays = 5
            first.minimumIntervalHours = 12
            first.lastRunAt = Date(timeIntervalSince1970: 1_000_000)

            let second = ReExtractionSettings(defaults: defaults)
            try expect(second.lookbackDays == 5)
            try expect(second.minimumIntervalHours == 12)
            try expect(second.lastRunAt == Date(timeIntervalSince1970: 1_000_000))
        }

        r.run("lastRunAt can be cleared back to nil") {
            let settings = ReExtractionSettings(defaults: freshDefaults())
            settings.lastRunAt = Date()
            settings.lastRunAt = nil
            try expect(settings.lastRunAt == nil)
        }
    }

    runner.suite("reExtractionAllowed") { r in
        let now = Date(timeIntervalSince1970: 1_000_000)

        r.run("allowed when there's no prior run at all") {
            try expect(reExtractionAllowed(now: now, lastRunAt: nil, minimumIntervalHours: 6))
        }

        r.run("not allowed when the last run is inside the minimum interval") {
            let lastRunAt = now.addingTimeInterval(-3600)
            try expect(reExtractionAllowed(now: now, lastRunAt: lastRunAt, minimumIntervalHours: 6) == false)
        }

        r.run("allowed once the last run is exactly at the minimum interval") {
            let lastRunAt = now.addingTimeInterval(-6 * 3600)
            try expect(reExtractionAllowed(now: now, lastRunAt: lastRunAt, minimumIntervalHours: 6))
        }

        r.run("allowed once the last run is well past the minimum interval") {
            let lastRunAt = now.addingTimeInterval(-24 * 3600)
            try expect(reExtractionAllowed(now: now, lastRunAt: lastRunAt, minimumIntervalHours: 6))
        }

        r.run("a zero-hour minimum interval always allows another run") {
            try expect(reExtractionAllowed(now: now, lastRunAt: now, minimumIntervalHours: 0))
        }
    }
}
