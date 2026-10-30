import Foundation

/// Manual re-extraction's own scope and cadence (ticket 12, ADR 0004),
/// user-tunable via Settings — previously fixed as "unbounded, whenever
/// you click it." Still a manual command in every other respect: ADR 0004's
/// "never automatic" decision is unchanged, this only bounds what a click
/// actually does and how soon another click is allowed to do it again.
/// Same thin `UserDefaults`-backed shape `ZenFocusModePreference` and
/// `ExtractionSettings` already use.
///
/// `@unchecked Sendable`: `UserDefaults` documents itself as safe to use
/// from any thread, the same posture every other preference wrapper here
/// already takes.
public struct ReExtractionSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let lookbackDaysKey = "reExtractionLookbackDays"
    private static let minimumIntervalHoursKey = "reExtractionMinimumIntervalHours"
    private static let lastRunAtKey = "reExtractionLastRunAt"

    /// "The past hour" — deliberately much narrower than automatic
    /// intake's 7-day `extractionLookbackDays`. Re-extraction revisits
    /// dismissed and never-extracted messages on the chance a better model
    /// judges them differently; scoping the default to what's still fresh
    /// enough to plausibly act on keeps a routine re-run cheap. Expressed
    /// as a fraction of a day rather than in a separate unit — nothing
    /// downstream (`withinExtractionWindow`) does day-boundary math, it's
    /// `lookbackDays * 86400` seconds either way, so a sub-day value works
    /// without any other change. Advanced's Stepper (`AdvancedTabView`)
    /// edits this in hours for exactly that reason.
    public static let defaultLookbackDays: Double = 1.0 / 24.0
    /// A modest floor against accidental rapid re-triggering — re-running
    /// extraction is not free, and clicking the menu item twice in a row
    /// by mistake shouldn't cost a second full pass. `0` is a legitimate
    /// choice too (no minimum at all), distinguished from "never set" by
    /// checking for the key's presence, not just reading a default `0.0`.
    public static let defaultMinimumIntervalHours: Double = 6

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lookbackDays: Double {
        get {
            guard let stored = defaults.object(forKey: Self.lookbackDaysKey) as? Double else {
                return Self.defaultLookbackDays
            }
            return stored
        }
        nonmutating set { defaults.set(newValue, forKey: Self.lookbackDaysKey) }
    }

    public var minimumIntervalHours: Double {
        get {
            guard let stored = defaults.object(forKey: Self.minimumIntervalHoursKey) as? Double else {
                return Self.defaultMinimumIntervalHours
            }
            return stored
        }
        nonmutating set { defaults.set(newValue, forKey: Self.minimumIntervalHoursKey) }
    }

    /// The moment the last re-extraction run started, or `nil` if one has
    /// never run. `AppModel.reExtract()` is the only writer, recording
    /// this the moment a run begins rather than when it finishes — a slow
    /// run shouldn't let a second one start the instant the first
    /// completes just because "the last run" hadn't been recorded yet.
    public var lastRunAt: Date? {
        get { defaults.object(forKey: Self.lastRunAtKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastRunAtKey) }
    }
}

/// Whether a re-extraction run is allowed to start right now: `lastRunAt`
/// is either `nil` (never run) or far enough in the past to clear
/// `minimumIntervalHours`. Pure; `IntakeRunner.canReExtract` calls it
/// with its injected `now`.
public func reExtractionAllowed(now: Date, lastRunAt: Date?, minimumIntervalHours: Double) -> Bool {
    guard let lastRunAt else { return true }
    return now.timeIntervalSince(lastRunAt) >= minimumIntervalHours * 3600
}
