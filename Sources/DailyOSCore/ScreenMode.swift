import Foundation

/// Which of the five top-level screens `ContentView` should render right
/// now: backfill progress beats "Loading…" beats "Nothing open. Nice."
/// beats Zen Focus Mode beats the normal list, in that order.
/// `AppModel.screenMode` decides it and `ContentView.mainContent` only
/// switches over the result. `AppModel.sections` is what a `.list`/`.zen`
/// result actually draws once chosen; this decides *whether*, not *what*.
public enum ScreenMode: Equatable {
    case backfill(completed: Int, total: Int)
    case loading
    case empty
    case zen
    case list
}
