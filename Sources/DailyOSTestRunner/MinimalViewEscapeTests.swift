import DailyOSApp
import Foundation

/// Esc leaves Minimal View or Zen Focus Mode, which hide the toolbar that
/// holds their buttons, but only when nothing else in the window wants Esc.
func registerMinimalViewEscapeTests(_ runner: TestRunner) {
    runner.suite("Esc leaves Minimal View") { r in
        r.run("Esc exits Minimal View when nothing else wants it") {
            try expect(escapeLeavesPresentationMode(
                isActive: true, isMainWindowKey: true, hasSheet: false, isPreviewOpen: false
            ))
        }
        r.run("Esc does nothing to Minimal View while an alert, a preview or another window has it, or outside Minimal View") {
            try expect(!escapeLeavesPresentationMode(isActive: false, isMainWindowKey: true, hasSheet: false, isPreviewOpen: false))
            try expect(!escapeLeavesPresentationMode(isActive: true, isMainWindowKey: false, hasSheet: false, isPreviewOpen: false))
            try expect(!escapeLeavesPresentationMode(isActive: true, isMainWindowKey: true, hasSheet: true, isPreviewOpen: false))
            try expect(!escapeLeavesPresentationMode(isActive: true, isMainWindowKey: true, hasSheet: false, isPreviewOpen: true))
        }
    }
}
