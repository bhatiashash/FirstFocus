import Foundation

/// Whether Esc should leave Minimal View or Zen Focus Mode. Both hide the
/// toolbar that holds their own buttons, so Esc is the visible way out. It yields to
/// anything else waiting for Esc: an alert or sheet, the Suggestion preview
/// popover, or another window such as Quick Capture.
public func escapeLeavesPresentationMode(isActive: Bool, isMainWindowKey: Bool, hasSheet: Bool, isPreviewOpen: Bool) -> Bool {
    isActive && isMainWindowKey && !hasSheet && !isPreviewOpen
}
