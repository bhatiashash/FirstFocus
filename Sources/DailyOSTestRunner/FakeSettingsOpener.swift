import DailyOSCore
import Foundation

/// Test double for `SettingsOpener`. Records which panes were asked for
/// instead of launching System Settings, which is the whole reason this
/// seam exists: a test constructing `AppModel` must never open a window
/// belonging to another application.
///
/// `@unchecked Sendable`: every test drives this synchronously on one
/// thread, same justification as `FakeContactsResolver`.
final class FakeSettingsOpener: SettingsOpener, @unchecked Sendable {
    private(set) var openedPanes: [SettingsPane] = []

    func open(_ pane: SettingsPane) {
        openedPanes.append(pane)
    }
}
