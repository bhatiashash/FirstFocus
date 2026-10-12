import DailyOSCore
import Foundation

private func testSignal(
    id: String,
    createdAt: Date,
    dueAt: Date? = nil,
    priority: Priority = .none,
    provenance: Provenance = .stated,
    label: String? = nil,
    source: Source = .reminders,
    focusOrder: Int? = nil,
    snoozedUntil: Date? = nil
) -> Signal {
    Signal(
        id: id,
        source: source,
        sourceRef: id,
        label: label ?? id,
        originalText: id,
        createdAt: createdAt,
        dueAt: dueAt,
        priority: priority,
        provenance: provenance,
        focusOrder: focusOrder,
        snoozedUntil: snoozedUntil
    )
}

func registerRankingTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86400
    // Due dates carry no time of day (ADR 0030), so the tier boundary is
    // counted in local days from the start of today, not in 24-hour steps
    // from `now`. The test run's own time zone has no DST change here.
    let startOfToday = Calendar.current.startOfDay(for: now)

    runner.suite("Tier assignment") { r in
        r.run("a past due date is Focus") {
            let s = testSignal(id: "a", createdAt: now, dueAt: now - day)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("high priority without a due date is Focus") {
            let s = testSignal(id: "a", createdAt: now, priority: .high)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("normal priority without a due date is Focus") {
            let s = testSignal(id: "a", createdAt: now, priority: .normal)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("a future due date without any priority is Focus") {
            let s = testSignal(id: "a", createdAt: now, dueAt: now + day)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("a due date later today is Focus") {
            let s = testSignal(id: "a", createdAt: now, dueAt: startOfToday + day - 1)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("a due date tomorrow is Focus (ADR 0042)") {
            let s = testSignal(id: "a", createdAt: now, dueAt: startOfToday + day)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("a due date the day after tomorrow is Later (ADR 0042)") {
            let s = testSignal(id: "a", createdAt: now, dueAt: startOfToday + 2 * day)
            try expect(tier(for: s, now: now) == .later)
        }
        r.run("a due date years out is Later") {
            let s = testSignal(id: "a", createdAt: now, dueAt: now + (day * 365 * 5))
            try expect(tier(for: s, now: now) == .later)
        }
        r.run("a far due date with a Priority is Focus") {
            let s = testSignal(id: "a", createdAt: now, dueAt: now + (day * 30), priority: .normal)
            try expect(tier(for: s, now: now) == .focus)
        }
        r.run("the same Signal moves from Later to Focus once midnight brings its due date within tomorrow") {
            let s = testSignal(id: "a", createdAt: now, dueAt: startOfToday + 2 * day)
            try expect(tier(for: s, now: startOfToday + day - 1) == .later, "one second before midnight")
            try expect(tier(for: s, now: startOfToday + day) == .focus, "at midnight")
        }
        r.run("no due date and no priority is Later") {
            let s = testSignal(id: "a", createdAt: now)
            try expect(tier(for: s, now: now) == .later)
        }
    }

    runner.suite("Recency score") { r in
        r.run("a signal exactly one half-life old scores half of a brand-new one") {
            let fresh = testSignal(id: "fresh", createdAt: now)
            let aged = testSignal(id: "aged", createdAt: now - (recencyHalfLifeInDays * day))
            let freshScore = recencyScore(for: fresh, now: now)
            let agedScore = recencyScore(for: aged, now: now)
            try expect(abs(agedScore - freshScore / 2) < 0.0001, "expected \(agedScore) to be half of \(freshScore)")
        }
        r.run("older signals score lower than newer ones") {
            let older = testSignal(id: "older", createdAt: now - (10 * day))
            let newer = testSignal(id: "newer", createdAt: now - day)
            try expect(recencyScore(for: older, now: now) < recencyScore(for: newer, now: now))
        }
    }

    runner.suite("rank") { r in
        r.run("Focus sorts entirely above Later") {
            let focus = testSignal(id: "focus", createdAt: now, dueAt: now + day)
            let later = testSignal(id: "later", createdAt: now)
            let ranked = rank([later, focus], now: now)
            try expect(ranked.map(\.id) == ["focus", "later"])
        }
        r.run("Date-First: an overdue signal outranks a higher-priority one due later") {
            let overdueNormal = testSignal(id: "overdue-normal", createdAt: now, dueAt: now - (10 * day), priority: .normal)
            let highNotYetDue = testSignal(id: "high-not-due", createdAt: now, dueAt: now + day, priority: .high)
            let ranked = rank([highNotYetDue, overdueNormal], now: now)
            try expect(ranked.map(\.id) == ["overdue-normal", "high-not-due"], "due date orders before priority")
        }
        r.run("Date-First: any dated signal outranks an undated high-priority one") {
            let datedNone = testSignal(id: "dated", createdAt: now - (30 * day), dueAt: now + day)
            let undatedHigh = testSignal(id: "undated-high", createdAt: now, priority: .high)
            let ranked = rank([undatedHigh, datedNone], now: now)
            try expect(ranked.map(\.id) == ["dated", "undated-high"])
        }
        r.run("on the same due date, priority breaks the tie") {
            let normal = testSignal(id: "normal", createdAt: now, dueAt: now + day, priority: .normal)
            let high = testSignal(id: "high", createdAt: now - (5 * day), dueAt: now + day, priority: .high)
            let ranked = rank([normal, high], now: now)
            try expect(ranked.map(\.id) == ["high", "normal"])
        }
        r.run("among undated signals, priority orders before recency") {
            let newerNormal = testSignal(id: "newer-normal", createdAt: now, priority: .normal)
            let olderHigh = testSignal(id: "older-high", createdAt: now - (10 * day), priority: .high)
            let ranked = rank([newerNormal, olderHigh], now: now)
            try expect(ranked.map(\.id) == ["older-high", "newer-normal"])
        }
        r.run("within a priority band, due date breaks ties, most overdue first") {
            let mostOverdue = testSignal(id: "most", createdAt: now, dueAt: now - (10 * day), priority: .high)
            let lessOverdue = testSignal(id: "less", createdAt: now, dueAt: now - day, priority: .high)
            let ranked = rank([lessOverdue, mostOverdue], now: now)
            try expect(ranked.map(\.id) == ["most", "less"])
        }
        r.run("within a priority band, due date breaks ties, soonest first") {
            let soon = testSignal(id: "soon", createdAt: now, dueAt: now + day, priority: .normal)
            let later = testSignal(id: "later", createdAt: now, dueAt: now + (10 * day), priority: .normal)
            let ranked = rank([later, soon], now: now)
            try expect(ranked.map(\.id) == ["soon", "later"])
        }
        r.run("an overdue signal sorts above a not-yet-due one in the same priority band") {
            // Direct regression coverage for a reported symptom ("2 days
            // ago" rendering below "In 1 day"): neither signal here has a
            // `focusOrder`, so this isolates the plain comparator from
            // ADR 0011's manual-order override, which the suite below
            // covers separately.
            let overdue = testSignal(id: "overdue", createdAt: now, dueAt: now - (2 * day))
            let notYetDue = testSignal(id: "not-yet-due", createdAt: now, dueAt: now + day)
            let ranked = rank([notYetDue, overdue], now: now)
            try expect(ranked.map(\.id) == ["overdue", "not-yet-due"])
        }
        r.run("within a priority band, a dated signal outranks an undated one") {
            let dated = testSignal(id: "dated", createdAt: now - (30 * day), dueAt: now + (365 * day), priority: .high)
            let undated = testSignal(id: "undated", createdAt: now, priority: .high)
            let ranked = rank([undated, dated], now: now)
            try expect(ranked.map(\.id) == ["dated", "undated"])
        }
        r.run("among undated signals in the same priority band, recency breaks the tie") {
            let older = testSignal(id: "older", createdAt: now - (10 * day), priority: .high)
            let newer = testSignal(id: "newer", createdAt: now - day, priority: .high)
            let ranked = rank([older, newer], now: now)
            try expect(ranked.map(\.id) == ["newer", "older"])
        }
        r.run("Later sorts by recency, most recent first") {
            let older = testSignal(id: "older", createdAt: now - (10 * day))
            let newer = testSignal(id: "newer", createdAt: now - day)
            let ranked = rank([older, newer], now: now)
            try expect(ranked.map(\.id) == ["newer", "older"])
        }
        r.run("Later puts dated Signals first, soonest first, ahead of undated ones (ADR 0042)") {
            let undatedNew = testSignal(id: "undated-new", createdAt: now)
            let dueInAMonth = testSignal(id: "month", createdAt: now - (20 * day), dueAt: startOfToday + 30 * day)
            let dueInAWeek = testSignal(id: "week", createdAt: now - (40 * day), dueAt: startOfToday + 7 * day)
            let ranked = rank([undatedNew, dueInAMonth, dueInAWeek], now: now)
            try expect(ranked.map(\.id) == ["week", "month", "undated-new"])
        }
        r.run("the Later cap drops undated Signals before dated ones, however old the dated one is") {
            let oldDated = testSignal(id: "old-dated", createdAt: now - (400 * day), dueAt: startOfToday + 21 * day, label: "old-dated")
            let undated = (0..<maxRankedSignals).map { i in
                testSignal(id: "u\(i)", createdAt: now - Double(i) * day, label: "u\(i)")
            }
            let ranked = rank(undated + [oldDated], now: now)
            try expect(ranked.count == maxRankedSignals)
            try expect(ranked.first?.id == "old-dated")
            try expect(!ranked.contains { $0.id == "u\(maxRankedSignals - 1)" }, "the oldest undated Signal is the one dropped")
        }
        r.run("an undated, unprioritized signal still appears, neither boosted nor penalised") {
            let later = testSignal(id: "later", createdAt: now)
            try expect(rank([later], now: now).count == 1)
        }
        r.run("provenance does not affect ordering") {
            let stated = testSignal(id: "stated", createdAt: now - day, provenance: .stated)
            let inferred = testSignal(id: "inferred", createdAt: now, provenance: .inferred)
            let ranked = rank([stated, inferred], now: now)
            // Both Later (no due date, no priority); ordered purely by
            // recency: inferred (newer) first, regardless of provenance.
            try expect(ranked.map(\.id) == ["inferred", "stated"])
        }
        r.run("empty input ranks to empty output") {
            try expect(rank([], now: now).isEmpty)
        }

        r.run("the ranked list never exceeds maxRankedSignals") {
            let signals = (0..<(maxRankedSignals + 10)).map { i in
                testSignal(id: "s\(i)", createdAt: now - Double(i) * day, label: "s\(i)")
            }
            try expect(rank(signals, now: now).count == maxRankedSignals)
        }

        r.run("truncation drops the least-ranked signal to make room, not an arbitrary one") {
            let focus = testSignal(id: "focus", createdAt: now, dueAt: now - day)
            // 25 Later signals plus the one Focus signal is 26 total — one
            // over the cap, so exactly the oldest (least recent) Later
            // signal should be the one dropped.
            let later = (0..<maxRankedSignals).map { i in
                testSignal(id: "b\(i)", createdAt: now - Double(i) * day, label: "b\(i)")
            }
            let ranked = rank([focus] + later, now: now)
            try expect(ranked.count == maxRankedSignals)
            try expect(ranked.first?.id == "focus", "the Focus signal must survive the cut")
            try expect(ranked.contains { $0.id == "b\(maxRankedSignals - 1)" } == false, "the oldest Later signal should be the one dropped")
            try expect(ranked.contains { $0.id == "b0" }, "the most recent Later signal should survive")
        }

        r.run("Focus is never truncated, even past maxRankedSignals, only Later absorbs the cut") {
            let focus = (0..<(maxRankedSignals + 5)).map { i in
                testSignal(id: "f\(i)", createdAt: now, dueAt: now - Double(i) * day, label: "f\(i)")
            }
            let later = testSignal(id: "later", createdAt: now, label: "later")
            let ranked = rank(focus + [later], now: now)
            try expect(ranked.count == maxRankedSignals + 5, "every Focus signal must survive regardless of the cap")
            try expect(focus.allSatisfy { f in ranked.contains { $0.id == f.id } })
            try expect(!ranked.contains { $0.id == "later" }, "Later gets nothing once Focus alone already fills the cap")
        }

        r.run("duplicate labels are collapsed before the cap is applied") {
            let signals = [
                testSignal(id: "a", createdAt: now, label: "call the dentist"),
                testSignal(id: "b", createdAt: now - day, label: "Call The Dentist"),
                testSignal(id: "c", createdAt: now - (2 * day), label: "  call the dentist  "),
            ]
            try expect(rank(signals, now: now).count == 1)
        }
    }

    runner.suite("Manual Focus ordering (ADR 0011, supersedes ADR 0009)") { r in
        r.run("a manually-ordered Signal outranks Date-First entirely, even a higher-priority one") {
            let manual = testSignal(id: "manual", createdAt: now, dueAt: now + day, priority: .none, focusOrder: 0)
            let highPriority = testSignal(id: "high", createdAt: now, priority: .high)
            let ranked = rank([highPriority, manual], now: now)
            try expect(ranked.map(\.id) == ["manual", "high"], "manual placement wins over Date-First for a Signal that's been dragged")
        }

        r.run("two manually-ordered Signals sort by their stored position, ignoring priority") {
            // Both still need a real claim on Focus (priority or a due
            // date) to land in that tier at all — `focusOrder` only
            // decides position *within* Focus, never tier membership.
            let second = testSignal(id: "second", createdAt: now, priority: .high, focusOrder: 1)
            let first = testSignal(id: "first", createdAt: now, priority: .normal, focusOrder: 0)
            let ranked = rank([second, first], now: now)
            try expect(ranked.map(\.id) == ["first", "second"])
        }

        r.run("a Signal with no manual order falls back to Date-First, and sorts after every manually-ordered one") {
            let manual = testSignal(id: "manual", createdAt: now, priority: .normal, focusOrder: 0)
            let unordered = testSignal(id: "unordered", createdAt: now, priority: .high)
            let ranked = rank([unordered, manual], now: now)
            try expect(ranked.map(\.id) == ["manual", "unordered"], "even a lower-priority manual placement still sorts ahead of an unordered high-priority Signal")
        }

        r.run("Later is never touched by manual ordering — tier membership stays purely computed") {
            let s = testSignal(id: "a", createdAt: now, priority: .none, focusOrder: 0)
            try expect(tier(for: s, now: now) == .later, "focusOrder alone gives no claim on Focus; that's still dueAt/priority only")
        }
    }

    runner.suite("Snooze (ticket 04, ADR 0045)") { r in
        r.run("isSnoozed is true while snoozedUntil is still in the future") {
            let s = testSignal(id: "a", createdAt: now, snoozedUntil: now + day)
            try expect(isSnoozed(s, now: now))
        }
        r.run("isSnoozed is false once snoozedUntil has passed") {
            let s = testSignal(id: "a", createdAt: now, snoozedUntil: now - day)
            try expect(isSnoozed(s, now: now) == false)
        }
        r.run("isSnoozed is false for a Signal that's never been snoozed") {
            let s = testSignal(id: "a", createdAt: now)
            try expect(isSnoozed(s, now: now) == false)
        }
        r.run("a currently-snoozed Signal is excluded from rank entirely, not just from Focus") {
            let snoozed = testSignal(id: "snoozed", createdAt: now, priority: .high, snoozedUntil: now + day)
            let visible = testSignal(id: "visible", createdAt: now)
            let ranked = rank([snoozed, visible], now: now)
            try expect(ranked.map(\.id) == ["visible"], "a snoozed Signal must not appear even though it would otherwise land in Focus")
        }
        r.run("a Signal whose snooze has expired reappears in whatever tier its own fields produce") {
            let expired = testSignal(id: "expired", createdAt: now, priority: .high, snoozedUntil: now - day)
            let ranked = rank([expired], now: now)
            try expect(ranked.map(\.id) == ["expired"])
            let reappeared = try require(ranked.first)
            try expect(tier(for: reappeared, now: now) == .focus, "no special 'just reappeared' treatment — it lands via the ordinary priority rule")
        }
        r.run("snoozing applies the same way regardless of source") {
            let snoozedReminder = testSignal(id: "r", createdAt: now, source: .reminders, snoozedUntil: now + day)
            let snoozedMessage = testSignal(id: "m", createdAt: now, source: .messages, snoozedUntil: now + day)
            try expect(rank([snoozedReminder, snoozedMessage], now: now).isEmpty)
        }
    }

    runner.suite("deduplicateByLabel") { r in
        r.run("labels differing only by case or surrounding whitespace are treated as the same") {
            let a = testSignal(id: "a", createdAt: now, label: "Call the dentist")
            let b = testSignal(id: "b", createdAt: now, label: "  call the dentist  ")
            try expect(deduplicateByLabel([a, b]).count == 1)
        }
        r.run("distinct labels are all kept") {
            let a = testSignal(id: "a", createdAt: now, label: "call the dentist")
            let b = testSignal(id: "b", createdAt: now, label: "buy milk")
            try expect(Set(deduplicateByLabel([a, b]).map(\.id)) == Set(["a", "b"]))
        }
        r.run("a trailing period alone doesn't make two labels distinct") {
            let a = testSignal(id: "a", createdAt: now, label: "Call the dentist")
            let b = testSignal(id: "b", createdAt: now, label: "Call the dentist.")
            try expect(deduplicateByLabel([a, b]).count == 1)
        }
        r.run("other punctuation differences are ignored the same way") {
            let a = testSignal(id: "a", createdAt: now, label: "call the dentist!")
            let b = testSignal(id: "b", createdAt: now, label: "Call, the dentist")
            try expect(deduplicateByLabel([a, b]).count == 1)
        }
        r.run("a substantively different label is never merged just because it shares a prefix") {
            let a = testSignal(id: "a", createdAt: now, label: "call the dentist")
            let b = testSignal(id: "b", createdAt: now, label: "call the dentist re: insurance")
            try expect(deduplicateByLabel([a, b]).count == 2)
        }
        r.run("a Reminders signal wins over a Messages signal with the same label") {
            let reminder = testSignal(id: "r", createdAt: now - day, label: "call the dentist", source: .reminders)
            let messages = testSignal(id: "s", createdAt: now, label: "call the dentist", source: .messages)
            let kept = try require(deduplicateByLabel([messages, reminder]).first)
            try expect(kept.id == "r", "checking off the Reminders one completes the real reminder; the Messages one only records local state")
        }
        r.run("among same-source duplicates, the more recently created one wins") {
            let older = testSignal(id: "older", createdAt: now - day, label: "call the dentist", source: .messages)
            let newer = testSignal(id: "newer", createdAt: now, label: "call the dentist", source: .messages)
            let kept = try require(deduplicateByLabel([older, newer]).first)
            try expect(kept.id == "newer")
        }
        r.run("empty input dedupes to empty output") {
            try expect(deduplicateByLabel([]).isEmpty)
        }
    }
}
