import Foundation

/// What `ZenWindowSizer` should do to the real `NSWindow` this tick, and
/// the updated `heightBeforeZenMode` it should hold onto for next time —
/// see `zenWindowSizing(...)` below for the decision itself.
public struct ZenWindowSizingOutcome: Equatable {
    public enum Decision: Equatable {
        case resize(to: CGFloat)
        case restore(to: CGFloat)
        case noChange
    }

    public let decision: Decision
    public let heightBeforeZenMode: CGFloat?
}

/// Zen Focus Mode's content-hugging window sizing (ticket 06 follow-up):
/// decides whether `ZenWindowSizer` should resize the window, restore it
/// to its pre-Zen height, or leave it alone, plus what
/// `heightBeforeZenMode` should hold afterward. Pure — no `NSWindow`, no
/// AppKit — so every clamp, floor, capture-once and no-op rule that used
/// to be verifiable only by resizing a real window can be tested directly.
///
/// `minWindowHeight` (520) matches Apple Reminders' own minimum window
/// height, applied to the *window* height, after `chromeInset` is added —
/// flooring the content height first would leave the actual window taller
/// than 520 by however tall the toolbar strip is. `maxContentHeight` (640)
/// is where Focus starts scrolling within the window rather than the
/// window growing to swallow most of the screen.
///
/// Deliberately doesn't resolve why `idealContentHeight` is sometimes
/// still 0 at launch (see `ZenWindowSizer`'s own doc comment) — that's
/// upstream, in whether `ContentView`'s `.onGeometryChange` ever fires.
/// Given a 0, this still produces a well-defined answer (floor at
/// `minWindowHeight`); it just can't tell you whether 0 was the right
/// input.
public func zenWindowSizing(
    isZen: Bool,
    idealContentHeight: CGFloat,
    chromeInset: CGFloat,
    currentWindowHeight: CGFloat,
    heightBeforeZenMode: CGFloat?,
    minWindowHeight: CGFloat = 520,
    maxContentHeight: CGFloat = 640
) -> ZenWindowSizingOutcome {
    if isZen {
        // Captured once, the first tick Zen mode is on — a later tick with
        // `heightBeforeZenMode` already set must not overwrite it with
        // whatever the window's height happens to be mid-Zen-mode.
        let capturedHeight = heightBeforeZenMode ?? currentWindowHeight
        let clampedContent = min(idealContentHeight, maxContentHeight)
        let target = max(chromeInset + clampedContent, minWindowHeight).rounded()
        let decision: ZenWindowSizingOutcome.Decision =
            abs(currentWindowHeight - target) > 0.5 ? .resize(to: target) : .noChange
        return ZenWindowSizingOutcome(decision: decision, heightBeforeZenMode: capturedHeight)
    }

    guard let restoreHeight = heightBeforeZenMode else {
        return ZenWindowSizingOutcome(decision: .noChange, heightBeforeZenMode: nil)
    }
    let decision: ZenWindowSizingOutcome.Decision =
        abs(currentWindowHeight - restoreHeight) > 0.5 ? .restore(to: restoreHeight) : .noChange
    return ZenWindowSizingOutcome(decision: decision, heightBeforeZenMode: nil)
}
