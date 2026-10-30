import Foundation

/// What the key window looks like to a key press, read by the executable.
public struct WindowFocus: Equatable, Sendable {
    /// The main window is the key window, not Quick Capture or an alert.
    public var isMainWindowKey: Bool
    /// A sheet is attached to it.
    public var hasSheet: Bool
    /// A text field's editor has focus, where \u{2318}Z undoes typing.
    public var isEditingText: Bool

    public init(isMainWindowKey: Bool, hasSheet: Bool, isEditingText: Bool = false) {
        self.isMainWindowKey = isMainWindowKey
        self.hasSheet = hasSheet
        self.isEditingText = isEditingText
    }
}

/// Zen Focus Mode and Minimal View, and the order Esc leaves them in. Both
/// hide the toolbar that holds their own buttons, so Esc is the visible way
/// out. Esc yields to anything else waiting for it: an alert or sheet, the
/// Suggestion preview popover, or another window such as Quick Capture.
public struct PresentationMode: Equatable, Sendable {
    public enum Exit: Equatable, Sendable {
        case zen, minimalView
    }

    public var isZen: Bool
    public var isMinimalView: Bool

    public init(isZen: Bool, isMinimalView: Bool) {
        self.isZen = isZen
        self.isMinimalView = isMinimalView
    }

    /// The mode one Esc leaves, or `nil` when Esc is not ours to take. Zen
    /// goes first, since it can sit on top of Minimal View.
    public func escapeExit(window: WindowFocus, isPreviewOpen: Bool) -> Exit? {
        guard window.isMainWindowKey, !window.hasSheet, !isPreviewOpen else { return nil }
        if isZen { return .zen }
        if isMinimalView { return .minimalView }
        return nil
    }
}
