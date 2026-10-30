import Foundation

/// Zen Focus Mode's persisted toggle (ticket 06): "a toolbar toggle that
/// hides the Later section entirely... state persists across launches (one
/// `UserDefaults` flag)." A thin typed wrapper rather than `AppModel`
/// calling `UserDefaults` directly, so the persistence itself is testable
/// with an injected, isolated `UserDefaults` suite — the same reason
/// `isBackfillComplete` lives behind `SignalStore` rather than as a bare
/// flag scattered through call sites.
/// `@unchecked Sendable`: `UserDefaults` predates Swift concurrency
/// annotations but documents itself as safe to use from any thread, same
/// posture as `EventKitTaskSource`'s `EKEventStore`.
public struct ZenFocusModePreference: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "zenFocusModeEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
