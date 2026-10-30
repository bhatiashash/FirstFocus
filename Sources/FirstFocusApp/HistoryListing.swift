import FirstFocusCore
import Foundation

/// What History shows for one refresh (history-snapshot): the listed
/// Batches in day Sections, the week's counts, and what each listed Batch
/// offers. A pure function of the Batches and the facts read with them, so
/// the listing rules are tested against `HistoryBatch` values.
package struct HistorySnapshot {
    package var sections: [HistoryDaySection]
    package var weekSummary: HistoryWeekSummary
    package var borderlineCountThisWeek: Int
    /// Each listed Batch's offers, by Batch id.
    package var offers: [String: HistoryBatchOffers]
}

/// The list History draws for `segment`.
///
/// `week` is every Batch in the window; `pinned` are the Muted Chats'
/// latest Batches, listed whatever they produced because a pinned Muted
/// Batch is the way back to Unmute (ADR 0031). The counts cover `week`
/// whatever the segment.
package func historySnapshot(
    week: [HistoryBatch], pinned: [HistoryBatch], facts: HistoryFacts, cutoff: Double, segment: HistorySegment,
    showsUnfilteredLog: Bool, now: Date, calendar: Calendar
) -> HistorySnapshot {
    let showsScreening = facts.showsScreening
    func borderline(_ batch: HistoryBatch) -> Bool {
        // Never true with the Screening toggle off: Borderline exists only
        // while Screening shows (CONTEXT.md: Borderline).
        guard showsScreening else { return false }
        return batch.screeningRow.map { isBorderline($0, cutoff: cutoff) } ?? false
    }
    func producedTask(_ batch: HistoryBatch) -> Bool {
        if case .tasks = batch.result { true } else { false }
    }
    func isListed(_ batch: HistoryBatch) -> Bool {
        switch segment {
        case .overview:
            showsUnfilteredLog || producedTask(batch)
                // A CANCEL finds no task but still changed the Inbox, so
                // Overview lists it where Restore can reach it.
                || !facts.supersessions(of: batch).isEmpty
                || borderline(batch) || facts.isCorrected(batch)
                // A Batch the model failed on is listed: nothing else would
                // show that it was never judged.
                || { if case .extractionFailed = batch.result { true } else { false } }()
        case .borderline: borderline(batch)
        case .corrected: facts.isCorrected(batch)
        case .starred: batch.isStarred
        }
    }

    let listed = week.filter(isListed) + pinned
    return HistorySnapshot(
        sections: historyDaySections(listed, now: now, calendar: calendar),
        weekSummary: HistoryWeekSummary(
            batches: week.count,
            tasks: week.filter(producedTask).count,
            screened: showsScreening ? week.filter(\.wasScreened).count : 0,
            borderline: week.filter(borderline).count,
            corrected: week.filter(facts.isCorrected).count
        ),
        borderlineCountThisWeek: showsScreening
            ? week.filter { $0.rows.contains { isBorderline($0, cutoff: cutoff) } }.count
            : 0,
        offers: Dictionary(listed.map { ($0.id, historyBatchOffers(for: $0, facts: facts)) }) { first, _ in first }
    )
}
