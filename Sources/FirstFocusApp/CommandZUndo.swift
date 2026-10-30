import Foundation

/// Whether ⌘Z should trigger the Undo bar rather than the Edit menu's own
/// Undo: only while the bar offers one, the main window is key with no
/// sheet over it, and no text is being edited, where ⌘Z undoes typing.
public func commandZUndoesOffer(canUndo: Bool, isMainWindowKey: Bool, hasSheet: Bool, isEditingText: Bool) -> Bool {
    canUndo && isMainWindowKey && !hasSheet && !isEditingText
}
