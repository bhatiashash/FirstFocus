import FirstFocusCore
import Foundation

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func signal(
    _ label: String, priority: Priority = .none, dueAt: Date? = nil, snoozedUntil: Date? = nil, ageDays: Double = 0
) -> Signal {
    var signal = Signal(
        id: label, source: .reminders, sourceRef: label, label: label, originalText: label,
        createdAt: now.addingTimeInterval(-ageDays * 86400), dueAt: dueAt, priority: priority, provenance: .stated
    )
    signal.snoozedUntil = snoozedUntil
    return signal
}

func registerLaterRuleTests(_ runner: TestRunner) {
    runner.suite("One rule for Later: tiering before the cap") { r in
        r.run("tierSignals leaves out snoozed Signals, deduplicates, and splits Focus from Later") {
            let tiers = tierSignals([
                signal("Pay rent", priority: .high),
                signal("Buy milk"),
                signal("Buy milk."),
                signal("Hidden", snoozedUntil: now.addingTimeInterval(3600)),
                signal("Later task"),
            ], now: now)
            try expect(tiers.focus.map(\.label) == ["Pay rent"])
            try expect(Set(tiers.allLater.map(\.label)).count == tiers.allLater.count)
            try expect(tiers.allLater.count == 2, "the duplicate and the snoozed one are not counted")
        }

        r.run("rank keeps all of Focus and caps only Later, from the same tiers") {
            let focus = (0..<10).map { signal("F\($0)", priority: .high) }
            let later = (0..<30).map { signal("L\($0)", ageDays: Double($0)) }
            let tiers = tierSignals(focus + later, now: now)
            try expect(tiers.allLater.count == 30)
            try expect(tiers.later.count == maxRankedSignals - 10)
            try expect(rank(focus + later, now: now) == tiers.focus + tiers.later)
        }

        r.run("the Ranked List's Later count is the uncapped Later tier, snoozed and duplicates left out") {
            let tasks = (0..<30).map { signal("L\($0)", ageDays: Double($0)) }
                + [signal("L1."), signal("Snoozed", snoozedUntil: now.addingTimeInterval(3600))]
            let tiers = tierSignals(tasks, now: now)
            try expect(tiers.allLater.count == 30)
        }

        r.run("the Board's Later count is the uncapped Later tier") {
            let tasks = (0..<30).map { ReminderTask(id: "L\($0)", title: "L\($0)", dueAt: nil, priority: .none, createdAt: now.addingTimeInterval(-Double($0) * 86400)) }
                + [ReminderTask(id: "dup", title: "L1.", dueAt: nil, priority: .none, createdAt: now)]
            let taskSource = FakeTaskSource(tasks: tasks)
            let store = makeTestSignalStore()
            let (list) = await MainActor.run { () -> SignalBoard in
                SignalBoard(taskSource: taskSource, signalStore: store, now: { now }, snoozes: Snoozes(store: store))
            }
            await list.refreshReminders()
            let ranked = await MainActor.run { list.rankedList(now: now) }
            try expect(ranked.later.count == maxRankedSignals)
            try expect(ranked.laterCount == 30, "got \(ranked.laterCount)")
        }
    }
}
