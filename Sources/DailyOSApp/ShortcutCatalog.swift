import Foundation

/// One shortcut: what it does, and the keys that do it. Each string in
/// `keys` is an alternative (⌫ and ⌦ both Dismiss), shown as its own keycap.
public struct ShortcutEntry: Equatable, Sendable {
    public let action: String
    public let keys: [String]
    /// The menu item's key equivalent, for the File and View menu items
    /// that carry one: uppercase means ⇧⌘, lowercase ⌘ alone.
    public let menuKeyEquivalent: String?

    init(action: String, keys: [String], menuKeyEquivalent: String? = nil) {
        self.action = action
        self.keys = keys
        self.menuKeyEquivalent = menuKeyEquivalent
    }
}

/// Shortcuts that work in the same place, under one heading in About.
public struct ShortcutGroup: Equatable, Sendable {
    public let title: String
    public let entries: [ShortcutEntry]
}

/// Every DailyOS-specific keyboard shortcut, for the About screen. Stock
/// macOS menu items (⌘Q, ⌘H, Cut/Copy/Paste, Undo/Redo) and plain sheet
/// buttons are left out.
public enum ShortcutCatalog {
    // The menu items' own entries, so the menus and About can't disagree.
    public static let reRunExtraction = ShortcutEntry(action: "Re-run Extraction", keys: ["⌘R"], menuKeyEquivalent: "r")
    public static let exportHistoryMarkdown = ShortcutEntry(
        action: "Export History as Markdown", keys: ["⇧⌘E"], menuKeyEquivalent: "E"
    )
    public static let zenFocusMode = ShortcutEntry(action: "Zen Focus Mode", keys: ["⇧⌘F"], menuKeyEquivalent: "F")
    public static let minimalView = ShortcutEntry(action: "Minimal View", keys: ["⇧⌘M"], menuKeyEquivalent: "M")
    public static let showUnfilteredHistoryLog = ShortcutEntry(
        action: "Show Unfiltered History Log", keys: ["⇧⌘L"], menuKeyEquivalent: "L"
    )
    public static let checkedOffToday = ShortcutEntry(action: "Checked Off Today", keys: ["⇧⌘C"], menuKeyEquivalent: "C")

    public static func groups(quickCapture: CaptureHotkeyPreset) -> [ShortcutGroup] {
        [
            ShortcutGroup(title: "Anywhere", entries: [
                ShortcutEntry(action: "Quick Capture", keys: [quickCapture.label]),
            ]),
            ShortcutGroup(title: "Quick Capture panel", entries: [
                ShortcutEntry(action: "Create the reminder", keys: ["⏎"]),
                ShortcutEntry(action: "Close", keys: ["Esc"]),
            ]),
            ShortcutGroup(title: "Suggested Tasks Inbox", entries: [
                ShortcutEntry(action: "Move between Suggestions", keys: ["↑", "↓"]),
                ShortcutEntry(action: "Approve", keys: ["⏎"]),
                ShortcutEntry(action: "Dismiss", keys: ["⌫", "⌦"]),
                ShortcutEntry(action: "Preview the conversation", keys: ["Space"]),
                ShortcutEntry(action: "Close the preview", keys: ["Esc"]),
            ]),
            ShortcutGroup(title: "Main", entries: [
                ShortcutEntry(action: "Add the New Reminder", keys: ["⏎"]),
                ShortcutEntry(action: "Close the New Reminder row", keys: ["Esc"]),
                checkedOffToday,
            ]),
            ShortcutGroup(title: "Zen Focus Mode and Minimal View", entries: [
                zenFocusMode,
                minimalView,
                ShortcutEntry(action: "Leave Zen or Minimal View (Zen first)", keys: ["Esc"]),
            ]),
            ShortcutGroup(title: "Menu bar", entries: [
                reRunExtraction,
                exportHistoryMarkdown,
                showUnfilteredHistoryLog,
            ]),
            ShortcutGroup(title: "Advanced", entries: [
                ShortcutEntry(action: "Add or save a Rule", keys: ["⏎"]),
                ShortcutEntry(action: "Cancel editing a Rule", keys: ["Esc"]),
                ShortcutEntry(action: "Save & Reload the Extraction Prompt", keys: ["⌘⏎"]),
            ]),
        ]
    }
}
