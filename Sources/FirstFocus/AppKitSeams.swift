import AppKit
import Combine
import FirstFocusApp
import FirstFocusCore
import ServiceManagement

/// The two `FirstFocusCore` seams whose only real implementation is AppKit,
/// kept here rather than in `FirstFocusApp` so that target imports no AppKit
/// and stays constructible in a test process (ADR 0020).

/// Production `ForegroundObserver`. The window coming to the foreground is
/// the moment a user who just granted a Gate in System Settings is most
/// likely to switch back, which is why it is a refresh trigger at all.
///
/// The observer token is intentionally discarded: `AppModel` is created
/// once in `main.swift` and lives for the whole process, so there is no
/// `deinit` that would need to balance this with a `removeObserver`.
final class NSApplicationForegroundObserver: ForegroundObserver {
    func onForeground(_ handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            handler()
        }
    }
}

/// Production `SettingsOpener`. Owns the `x-apple.systempreferences:`
/// spelling for each pane so callers ask for the Gate they mean.
struct NSWorkspaceSettingsOpener: SettingsOpener {
    func open(_ pane: SettingsPane) {
        guard let url = URL(string: Self.urlString(for: pane)) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func urlString(for pane: SettingsPane) -> String {
        switch pane {
        case .fullDiskAccess:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .reminders:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        }
    }
}

/// Production `LoginItem`, backed by `SMAppService.mainApp`. A login item
/// waiting for approval in System Settings counts as on, since macOS will
/// open the app once it's approved.
final class MainAppLoginItem: LoginItem {
    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
