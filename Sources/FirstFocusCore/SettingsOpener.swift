import Foundation

/// Which System Settings pane a Gate is re-granted in. Named panes rather
/// than raw URLs so the caller asks for the Gate it means and the adapter
/// owns the `x-apple.systempreferences:` spelling.
public enum SettingsPane: Equatable, Sendable {
    case fullDiskAccess
    case reminders
}

/// Opening System Settings so a user can grant a Gate. A protocol, not a
/// direct `NSWorkspace` call, for two reasons: this module is AppKit-free,
/// and a test that constructs the app model must never actually launch
/// System Settings. The `NSWorkspace` adapter lives in the executable.
public protocol SettingsOpener: Sendable {
    func open(_ pane: SettingsPane)
}
