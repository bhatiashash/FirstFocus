import FirstFocusApp
import Foundation

func registerZenWindowSizingTests(_ runner: TestRunner) {
    runner.suite("zenWindowSizing (candidate 1 deepening)") { r in
        r.run("first tick with Zen on captures the current window height") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 700, heightBeforeZenMode: nil
            )
            try expect(outcome.heightBeforeZenMode == 700, "must capture the height Zen mode found the window at")
        }

        r.run("a later tick with Zen still on does not re-capture") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 560, heightBeforeZenMode: 700
            )
            try expect(outcome.heightBeforeZenMode == 700, "must not overwrite the captured height with the mid-Zen-mode height")
        }

        r.run("content taller than maxContentHeight clamps to it") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 900, chromeInset: 40,
                currentWindowHeight: 520, heightBeforeZenMode: nil,
                minWindowHeight: 520, maxContentHeight: 640
            )
            try expect(outcome.decision == .resize(to: 680), "chrome (40) + clamped content (640) = 680")
        }

        r.run("content shorter than the floor still produces minWindowHeight") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 50, chromeInset: 40,
                currentWindowHeight: 700, heightBeforeZenMode: nil,
                minWindowHeight: 520, maxContentHeight: 640
            )
            try expect(outcome.decision == .resize(to: 520), "chrome (40) + content (50) = 90, well under the 520 floor")
        }

        r.run("idealContentHeight of 0 still floors cleanly, without resolving why it's 0") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 0, chromeInset: 40,
                currentWindowHeight: 700, heightBeforeZenMode: nil,
                minWindowHeight: 520, maxContentHeight: 640
            )
            try expect(outcome.decision == .resize(to: 520), "an unmeasured (0) content height must still floor at minWindowHeight, not crash or produce a negative/zero target")
        }

        r.run("an open Notes drawer grows the window, and closing it returns the window to its earlier height") {
            // The drawer sits inside the measured Zen content, so opening
            // one simply arrives as a taller `idealContentHeight`.
            let closed = zenWindowSizing(
                isZen: true, idealContentHeight: 200, chromeInset: 40,
                currentWindowHeight: 240, heightBeforeZenMode: 700, minWindowHeight: 120
            )
            try expect(closed.decision == .noChange)
            let opened = zenWindowSizing(
                isZen: true, idealContentHeight: 290, chromeInset: 40,
                currentWindowHeight: 240, heightBeforeZenMode: 700, minWindowHeight: 120
            )
            try expect(opened.decision == .resize(to: 330))
            let closedAgain = zenWindowSizing(
                isZen: true, idealContentHeight: 200, chromeInset: 40,
                currentWindowHeight: 330, heightBeforeZenMode: 700, minWindowHeight: 120
            )
            try expect(closedAgain.decision == .resize(to: 240))
            try expect(closedAgain.heightBeforeZenMode == 700, "the height to restore on leaving Zen is untouched")
        }

        r.run("turning Zen off restores the captured height and clears it") {
            let outcome = zenWindowSizing(
                isZen: false, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 560, heightBeforeZenMode: 700
            )
            try expect(outcome.decision == .restore(to: 700))
            try expect(outcome.heightBeforeZenMode == nil, "must clear the captured height once restored")
        }

        r.run("turning Zen off with nothing captured is a no-op") {
            let outcome = zenWindowSizing(
                isZen: false, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 560, heightBeforeZenMode: nil
            )
            try expect(outcome.decision == .noChange)
            try expect(outcome.heightBeforeZenMode == nil)
        }

        r.run("resize is a no-op once the window is already within 0.5pt of the target") {
            let outcome = zenWindowSizing(
                isZen: true, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 520.3, heightBeforeZenMode: nil,
                minWindowHeight: 520, maxContentHeight: 640
            )
            try expect(outcome.decision == .noChange, "chrome (40) + content (300) floors to 520; 520.3 is within 0.5pt of it")
        }

        r.run("restore is a no-op once the window is already within 0.5pt of the restore height") {
            let outcome = zenWindowSizing(
                isZen: false, idealContentHeight: 300, chromeInset: 40,
                currentWindowHeight: 700.2, heightBeforeZenMode: 700
            )
            try expect(outcome.decision == .noChange)
            try expect(outcome.heightBeforeZenMode == nil, "still clears the captured height even when no resize was needed")
        }
    }
}
