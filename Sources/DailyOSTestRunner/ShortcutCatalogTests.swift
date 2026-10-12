import DailyOSApp
import Foundation

/// The shortcut list About renders: every DailyOS-specific key, grouped by
/// where it works.
func registerShortcutCatalogTests(_ runner: TestRunner) {
    runner.suite("Shortcut catalog") { r in
        r.run("Quick Capture shows whichever preset is selected") {
            let expected: [CaptureHotkeyPreset: String] = [
                .optionSpace: "⌥ Space", .controlOptionSpace: "⌃⌥ Space", .shiftCommandSpace: "⇧⌘ Space",
            ]
            for (preset, label) in expected {
                let anywhere = try require(ShortcutCatalog.groups(quickCapture: preset).first)
                try expect(anywhere.title == "Anywhere", "got \(anywhere.title)")
                try expect(anywhere.entries.map(\.action) == ["Quick Capture"])
                try expect(anywhere.entries.first?.keys == [label], "got \(String(describing: anywhere.entries.first?.keys))")
            }
        }

        r.run("groups run from anywhere in the system down to the Advanced screen, none empty") {
            let groups = ShortcutCatalog.groups(quickCapture: .optionSpace)
            try expect(groups.map(\.title) == [
                "Anywhere", "Quick Capture panel", "Suggested Tasks Inbox", "Main",
                "Zen Focus Mode and Minimal View", "Menu bar", "Advanced",
            ], "got \(groups.map(\.title))")
            for group in groups {
                try expect(!group.entries.isEmpty, "\(group.title) is empty")
            }
        }

        // The keys ContentView's Inbox handler claims: ↑ ↓ ⏎ ⌫ ⌦ Space Esc.
        r.run("the Inbox group lists every key the Inbox answers to") {
            let inbox = try require(ShortcutCatalog.groups(quickCapture: .optionSpace).first { $0.title == "Suggested Tasks Inbox" })
            let keys = Set(inbox.entries.flatMap(\.keys))
            try expect(keys == ["↑", "↓", "⏎", "⌫", "⌦", "Space", "Esc"], "got \(keys.sorted())")
        }

        r.run("no key does two things in the same place") {
            for group in ShortcutCatalog.groups(quickCapture: .optionSpace) {
                let keys = group.entries.flatMap(\.keys)
                try expect(Set(keys).count == keys.count, "\(group.title) repeats a key: \(keys)")
            }
        }

        // The File and View menus take their keys from these entries. An
        // uppercase key equivalent means ⇧⌘, a lowercase one ⌘ alone.
        r.run("each menu shortcut's key equivalent matches the keys About shows") {
            let expected: [(ShortcutEntry, String, String)] = [
                (ShortcutCatalog.reRunExtraction, "r", "⌘R"),
                (ShortcutCatalog.exportHistoryMarkdown, "E", "⇧⌘E"),
                (ShortcutCatalog.zenFocusMode, "F", "⇧⌘F"),
                (ShortcutCatalog.minimalView, "M", "⇧⌘M"),
                (ShortcutCatalog.showUnfilteredHistoryLog, "L", "⇧⌘L"),
                (ShortcutCatalog.checkedOffToday, "C", "⇧⌘C"),
            ]
            for (entry, menuKey, shown) in expected {
                try expect(entry.menuKeyEquivalent == menuKey, "\(entry.action): got \(String(describing: entry.menuKeyEquivalent))")
                try expect(entry.keys == [shown], "\(entry.action): got \(entry.keys)")
            }
            let listed = ShortcutCatalog.groups(quickCapture: .optionSpace).flatMap(\.entries)
            for (entry, _, _) in expected {
                try expect(listed.contains(entry), "\(entry.action) is missing from About")
            }
        }

        r.run("every catalog entry with a menu key shows it the way the menu reads it") {
            let withMenuKeys = ShortcutCatalog.groups(quickCapture: .optionSpace).flatMap(\.entries).filter { $0.menuKeyEquivalent != nil }
            try expect(withMenuKeys.count == 6, "got \(withMenuKeys.map(\.action))")
            for entry in withMenuKeys {
                let key = try require(entry.menuKeyEquivalent)
                let shown = key == key.uppercased() ? "⇧⌘\(key)" : "⌘\(key.uppercased())"
                try expect(entry.keys == [shown], "\(entry.action): menu key \(key) but About shows \(entry.keys)")
            }
        }

        r.run("Advanced lists ⏎ for adding a Rule as well as saving an edited one") {
            let advanced = try require(ShortcutCatalog.groups(quickCapture: .optionSpace).first { $0.title == "Advanced" })
            let returnEntry = try require(advanced.entries.first { $0.keys == ["⏎"] })
            try expect(returnEntry.action == "Add or save a Rule", "got \(returnEntry.action)")
        }
    }
}
