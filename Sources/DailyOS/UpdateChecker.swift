import Combine
import Foundation
import Sparkle

/// Updates (ADR 0044): owns Sparkle's updater and reports whether a check
/// is waiting on the feed, for the sidebar footer's version button. Sparkle
/// draws every window itself: the new version with its release notes, or
/// "You're up to date".
///
/// `isChecking` covers only the fetch. It turns on when any check starts,
/// the footer's, the menu's or Sparkle's daily one, and off as soon as
/// Sparkle knows the answer, before you have acted on its window.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    @Published private(set) var isChecking = false
    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// The footer's click and the DailyOS menu's Check for Updates… both
    /// land here: the same check, with Sparkle's window either way.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// Sparkle calls these on the main thread.
extension UpdateChecker: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        MainActor.assumeIsolated { isChecking = true }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { isChecking = false }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { isChecking = false }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { isChecking = false }
    }

    /// The backstop: every check ends here, whatever happened on the way.
    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        MainActor.assumeIsolated { isChecking = false }
    }
}
