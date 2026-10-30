import Foundation

/// The text of the count at the end of the window that opens the Checked
/// Off sheet (CONTEXT.md: Checked Off).
public func checkedOffCountText(_ count: Int) -> String {
    count == 1 ? "1 reminder completed today" : "\(count) reminders completed today"
}
