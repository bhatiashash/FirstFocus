import DailyOSCore
import Foundation

// list-presentation: what the window asks about the list, answered by a
// `ListPresentation` built from a Ranked List, a moment and flags. Table
// tests on a value: no AppModel, no clocks.

private func reminder(_ id: String, priority: Priority = .none, dueAt: Date? = nil) -> Signal {
    makeSignal(from: ReminderTask(id: id, title: id, dueAt: dueAt, priority: priority, createdAt: Date()))
}

private func suggestion(_ id: String, sourceRef: String = "m1", lowConfidence: Bool = false) -> Signal {
    Signal(
        id: id, source: .messages, sourceRef: sourceRef, label: id, originalText: id, createdAt: Date(),
        provenance: .inferred, lowConfidence: lowConfidence
    )
}

private func presentation(
    focus: [Signal] = [], later: [Signal] = [], suggested: [Signal] = [], snoozed: [Signal] = [],
    at moment: Date = Date(), _ flags: ListPresentation.Flags = .init()
) -> ListPresentation {
    ListPresentation(
        rankedList: RankedList(focus: focus, later: later, suggested: suggested, snoozed: snoozed), rankedAt: moment, flags: flags
    )
}

private func startOfDay(daysFromToday days: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))!
}

func registerListPresentationTests(_ runner: TestRunner) {
    runner.suite("ListPresentation: which of the five screens wins") { r in
        let f1 = reminder("f1", priority: .high)
        let cases: [(String, ListPresentation, ScreenMode)] = [
            ("nothing open shows empty", presentation(), .empty),
            ("an open row shows the list", presentation(focus: [f1]), .list),
            ("backfill beats loading", presentation(.init(isLoading: true, backfillProgress: (1, 10))), .backfill(completed: 1, total: 10)),
            ("loading beats empty and Zen", presentation(.init(isLoading: true, isZen: true)), .loading),
            ("an unreadable Messages shows the list, for its Notice", presentation(.init(messagesNeedFullDiskAccess: true)), .list),
            ("an unreadable Reminders shows the list", presentation(.init(remindersUnavailable: true)), .list),
            ("no model shows the list", presentation(.init(extractionUnavailable: true)), .list),
            ("empty beats Zen", presentation(.init(isZen: true)), .empty),
            ("Zen wins with an open row", presentation(focus: [f1], .init(isZen: true)), .zen),
            ("only Snoozed rows show the list, not empty", presentation(snoozed: [reminder("z1")]), .list),
        ]
        for (name, value, expected) in cases {
            r.run(name) { try expect(value.screenMode == expected, "got \(value.screenMode)") }
        }
    }

    runner.suite("ListPresentation: which Sections exist, in order") { r in
        let f1 = reminder("f1", priority: .high), l1 = reminder("l1"), s1 = suggestion("s1"), z1 = reminder("z1")
        let allNotices = ListPresentation.Flags(messagesNeedFullDiskAccess: true, remindersUnavailable: true, extractionUnavailable: true)
        let cases: [(String, ListPresentation, [String])] = [
            ("Suggested, Focus, then Later", presentation(focus: [f1], later: [l1], suggested: [s1]), ["suggested", "tier-focus", "tier-later"]),
            ("an empty Tier or Inbox has no Section", presentation(focus: [f1]), ["tier-focus"]),
            ("an empty Focus shows beside Later, as a drop target", presentation(later: [l1]), ["tier-focus", "tier-later"]),
            ("Zen keeps only Focus", presentation(focus: [f1], later: [l1], suggested: [s1], .init(isZen: true)), ["tier-focus"]),
            ("Zen with an empty Focus has no Section", presentation(later: [l1], suggested: [s1], .init(isZen: true)), []),
            ("the Snoozed Section comes after Later", presentation(focus: [f1], later: [l1], snoozed: [z1]), ["tier-focus", "tier-later", "snoozed"]),
            ("Zen hides the Snoozed Section", presentation(focus: [f1], snoozed: [z1], .init(isZen: true)), ["tier-focus"]),
            ("Notices go Messages, Reminders, Extraction", presentation(allNotices), [
                "notice-messagesUnavailable", "notice-remindersUnavailable", "notice-extractionUnavailable",
            ]),
            ("a Notice sorts after every Signal Section", presentation(focus: [f1], later: [l1], snoozed: [z1], .init(messagesNeedFullDiskAccess: true)), [
                "tier-focus", "tier-later", "snoozed", "notice-messagesUnavailable",
            ]),
            ("a Notice survives Zen", presentation(focus: [f1], later: [l1], .init(isZen: true, messagesNeedFullDiskAccess: true)), [
                "tier-focus", "notice-messagesUnavailable",
            ]),
            ("a Notice survives Zen with an empty Focus", presentation(.init(isZen: true, messagesNeedFullDiskAccess: true)), ["notice-messagesUnavailable"]),
            ("no flag set has no Notice", presentation(), []),
        ]
        for (name, value, expected) in cases {
            r.run(name) { try expect(value.sections.map(\.id) == expected, "got \(value.sections.map(\.id))") }
        }

        r.run("Suggested carries raw Signals, never grouped") {
            let value = presentation(suggested: [suggestion("s1", lowConfidence: true), suggestion("s2", lowConfidence: true)])
            guard case .suggested(let signals) = value.sections.first else { throw TestFailure(message: "expected .suggested first") }
            try expect(signals.count == 2)
        }

        r.run("a Tier groups a same-source, low-confidence run") {
            let stated = ["b1", "b2"].map {
                Signal(
                    id: $0, source: .messages, sourceRef: "m1", label: $0, originalText: "milk and eggs",
                    createdAt: Date(), provenance: .stated, lowConfidence: true
                )
            }
            guard case .tier(.later, let groups) = presentation(later: stated).sections.last else {
                throw TestFailure(message: "expected .tier(.later, _) last")
            }
            try expect(groups.count == 1)
        }
    }

    runner.suite("ListPresentation: what a drop does (ADR 0011, ADR 0042)") { r in
        let f1 = reminder("f1", priority: .high), f2 = reminder("f2", priority: .high), l1 = reminder("l1"), l2 = reminder("l2")
        let heldByDate = reminder("d1", priority: .high, dueAt: startOfDay(daysFromToday: 1))
        let farOff = reminder("x1", priority: .high, dueAt: startOfDay(daysFromToday: 30))
        let value = presentation(focus: [f1, f2, heldByDate, farOff], later: [l1, l2])
        let cases: [(String, String, ListPresentation.DropTarget, ListPresentation.Drop?)] = [
            ("a Focus row onto another takes its place", "f2", .row(id: "f1"), .reorder(draggedId: "f2", ontoId: "f1")),
            ("a Focus row on its own header does nothing", "f1", .tier(.focus), nil),
            ("a row onto itself does nothing", "f1", .row(id: "f1"), nil),
            ("a Later row onto a Focus row gets a Priority there", "l1", .row(id: "f2"), .promote(l1, ontoId: "f2")),
            ("a Later row on the Focus header gets a Priority", "l1", .tier(.focus), .promote(l1, ontoId: nil)),
            ("a Focus row held by its Priority alone moves to Later", "f1", .tier(.later), .demote(f1)),
            ("onto a Later row, too", "f1", .row(id: "l1"), .demote(f1)),
            ("a Focus row due tomorrow stays", "d1", .tier(.later), nil),
            ("a Focus row with a far-off date moves to Later", "x1", .tier(.later), .demote(farOff)),
            ("Later has no manual order", "l1", .row(id: "l2"), nil),
            ("a row not on the list does nothing", "gone", .tier(.focus), nil),
        ]
        for (name, dragged, target, expected) in cases {
            r.run(name) {
                let drop = value.drop(dragged, onto: target)
                try expect(drop == expected, "got \(String(describing: drop))")
            }
        }
    }

    runner.suite("ListPresentation: judged at the moment the list was ranked (ADR 0020)") { r in
        // A row with a Priority due the day after tomorrow: just before
        // midnight its Priority alone holds it in Focus; just after, the
        // date is tomorrow and holds it there too.
        let beforeMidnight = startOfDay(daysFromToday: 1).addingTimeInterval(-60)
        let afterMidnight = startOfDay(daysFromToday: 1).addingTimeInterval(60)
        let row = reminder("r1", priority: .high, dueAt: startOfDay(daysFromToday: 2))

        r.run("before midnight it offers Move to Later and moves on a drop") {
            let value = presentation(focus: [row], at: beforeMidnight)
            try expect(value.affordances(for: row).contains(.demote))
            try expect(value.drop("r1", onto: .tier(.later)) == .demote(row))
        }

        r.run("after midnight it offers neither") {
            let value = presentation(focus: [row], at: afterMidnight)
            try expect(!value.affordances(for: row).contains(.demote))
            try expect(value.drop("r1", onto: .tier(.later)) == nil)
        }

        r.run("a date with no time due today isn't overdue at noon; yesterday's is") {
            let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            let today = reminder("t", dueAt: Calendar.current.startOfDay(for: noon))
            let yesterday = reminder("y", dueAt: startOfDay(daysFromToday: -1))
            let value = presentation(later: [today, yesterday], at: noon)
            try expect(!value.isOverdue(today))
            try expect(value.isOverdue(yesterday))
        }
    }

    runner.suite("ListPresentation: Snoozed and Suggested rows") { r in
        r.run("a Snoozed Reminders row offers Unsnooze, Rename and Delete only") {
            let z1 = reminder("z1", priority: .high)
            try expect(presentation(snoozed: [z1]).affordances(for: z1) == [.unsnooze, .rename, .delete])
        }

        r.run("a Snoozed Messages row offers Unsnooze and Dismiss") {
            let z1 = suggestion("z1")
            try expect(presentation(snoozed: [z1]).affordances(for: z1) == [.unsnooze, .dismiss])
        }

        r.run("Focus shows only under the list or Zen, with a Focus Section") {
            try expect(presentation(focus: [reminder("f1", priority: .high)]).showsFocus)
            try expect(presentation(later: [reminder("l1")]).showsFocus, "the empty Focus is drawn beside Later")
            try expect(!presentation(suggested: [suggestion("s1")]).showsFocus)
            try expect(!presentation(focus: [reminder("f1", priority: .high)], .init(isLoading: true)).showsFocus)
        }

        r.run("a Suggestion id is valid only while it is in the Inbox") {
            let value = presentation(suggested: [suggestion("s1")])
            try expect(value.isSuggested("s1"))
            try expect(!value.isSuggested("s2"))
        }
    }
}
