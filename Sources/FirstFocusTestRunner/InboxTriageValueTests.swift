import FirstFocusApp

/// `InboxTriage` on its own: the key rules, focus and the popover, with no
/// AppModel, task source or stores.

private let ids = ["a", "b", "c"]

func registerInboxTriageValueTests(_ runner: TestRunner) {
    runner.suite("InboxTriage: keys, focus and the popover, as a value") { r in
        r.run("arrows are taken with no focus; Return, Delete and Space need a focused row; Escape needs a popover") {
            var triage = InboxTriage()
            try expect(triage.takes(.down, inboxIds: ids, isZen: false))
            for key in [InboxTriage.Key.approve, .dismiss, .togglePreview, .closePreview] {
                try expect(!triage.takes(key, inboxIds: ids, isZen: false), "\(key) with nothing focused")
            }
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            try expect(triage.takes(.approve, inboxIds: ids, isZen: false))
            try expect(!triage.takes(.closePreview, inboxIds: ids, isZen: false))
            _ = triage.handle(.togglePreview, inboxIds: ids, isZen: false)
            try expect(triage.takes(.closePreview, inboxIds: ids, isZen: false))
        }

        r.run("no key is taken while the Inbox is empty, collapsed or hidden by Zen") {
            var triage = InboxTriage()
            try expect(!triage.takes(.down, inboxIds: [], isZen: false))
            try expect(!triage.takes(.down, inboxIds: ids, isZen: true))
            triage.toggleCollapse(.inbox)
            try expect(!triage.takes(.down, inboxIds: ids, isZen: false))
        }

        r.run("Down starts at the top, Up at the bottom, and both stop at the ends") {
            var triage = InboxTriage()
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            try expect(triage.focusedId == "a")
            _ = triage.handle(.up, inboxIds: ids, isZen: false)
            try expect(triage.focusedId == "a")
            var fromBottom = InboxTriage()
            _ = fromBottom.handle(.up, inboxIds: ids, isZen: false)
            try expect(fromBottom.focusedId == "c")
        }

        r.run("Approve hands back the focused row, and finish moves focus to its neighbour") {
            var triage = InboxTriage()
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            let act = triage.handle(.approve, inboxIds: ids, isZen: false)
            try expect(act?.id == "a" && act?.key == .approve)
            try expect(triage.focusedId == "a", "nothing moves until the caller has acted")
            triage.finish(try require(act), inboxIds: ["b", "c"])
            try expect(triage.focusedId == "b")
        }

        r.run("after acting on the last row, focus goes to the one before it, or nowhere when none is left") {
            var triage = InboxTriage()
            _ = triage.handle(.up, inboxIds: ids, isZen: false)
            let act = try require(triage.handle(.dismiss, inboxIds: ids, isZen: false))
            triage.finish(act, inboxIds: ["a", "b"])
            try expect(triage.focusedId == "b")
            let only = try require(triage.handle(.dismiss, inboxIds: ["b"], isZen: false))
            triage.finish(only, inboxIds: [])
            try expect(triage.focusedId == nil)
        }

        r.run("an open popover follows focus, including after an Approve") {
            var triage = InboxTriage()
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            _ = triage.handle(.togglePreview, inboxIds: ids, isZen: false)
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            try expect(triage.previewedId == "b")
            let act = try require(triage.handle(.approve, inboxIds: ids, isZen: false))
            triage.finish(act, inboxIds: ["a", "c"])
            try expect(triage.focusedId == "c" && triage.previewedId == "c")
        }

        r.run("collapsing the Inbox drops focus and the popover; collapsing Later does not") {
            var triage = InboxTriage()
            _ = triage.handle(.down, inboxIds: ids, isZen: false)
            _ = triage.handle(.togglePreview, inboxIds: ids, isZen: false)
            triage.toggleCollapse(.later)
            try expect(triage.focusedId == "a" && triage.previewedId == "a")
            triage.toggleCollapse(.inbox)
            try expect(triage.focusedId == nil && triage.previewedId == nil)
        }

        r.run("Snoozed starts collapsed, the Inbox and Later expanded, and expand opens a Section") {
            var triage = InboxTriage()
            try expect(triage.isCollapsed(.snoozed) && !triage.isCollapsed(.inbox) && !triage.isCollapsed(.later))
            triage.toggleCollapse(.later)
            triage.expand(.later)
            try expect(!triage.isCollapsed(.later))
        }

        r.run("focus and hover previews ignore a row that isn't in the Inbox") {
            var triage = InboxTriage()
            triage.focus("z", inboxIds: ids)
            triage.showPreview(of: "z", inboxIds: ids)
            try expect(triage.focusedId == nil && triage.previewedId == nil)
            triage.showPreview(of: "b", inboxIds: ids)
            triage.hidePreview(of: "a")
            try expect(triage.previewedId == "b")
            triage.hidePreview(of: "b")
            try expect(triage.previewedId == nil)
        }

        r.run("a row that left the Inbox loses focus and its popover") {
            var triage = InboxTriage()
            triage.focus("a", inboxIds: ids)
            triage.showPreview(of: "a", inboxIds: ids)
            triage.drop { $0 == "a" }
            try expect(triage.focusedId == nil && triage.previewedId == nil)
        }
    }
}
