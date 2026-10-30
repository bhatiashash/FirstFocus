import Combine
import FirstFocusCore
import Foundation

/// History's header: what the last seven days held.
public struct HistoryWeekSummary: Equatable, Sendable {
    public var batches = 0
    public var tasks = 0
    public var screened = 0
    public var borderline = 0
    public var corrected = 0

    public init(batches: Int = 0, tasks: Int = 0, screened: Int = 0, borderline: Int = 0, corrected: Int = 0) {
        self.batches = batches
        self.tasks = tasks
        self.screened = screened
        self.borderline = borderline
        self.corrected = corrected
    }
}

/// The toolbar's views onto History's list.
public enum HistorySegment: String, CaseIterable, Identifiable, Sendable {
    /// The default: Batches that produced a task, plus the exceptions worth
    /// a look (Borderline, Corrected, one that Superseded a Suggestion).
    /// Most Batches are chat filler that produced nothing; those appear
    /// only in the unfiltered log.
    case overview, borderline, corrected, starred

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .borderline: "Borderline"
        case .corrected: "Corrected"
        case .starred: "Starred"
        }
    }

    public var emptyMessage: String {
        switch self {
        case .overview: "No tasks or exceptions in the last 7 days"
        case .borderline: "No Borderline Batches in the last 7 days"
        case .corrected: "No corrected Batches in the last 7 days"
        case .starred: "No starred Batches in the last 7 days"
        }
    }
}

/// Backs the History destination. Lives here, not in the `FirstFocus` executable
/// target, so `FirstFocusTestRunner` can drive it the same way it drives
/// `AppModel` — the executable target holds only the SwiftUI `View`s
/// themselves (ADR 0020's same split, applied to this feature).
///
/// The list shows one `HistoryBatch` per row, for the last seven days only
/// (History dashboard spec). Older rows stay in the store: the window is a
/// query bound, not retention.
///
/// `refresh()` re-reads `historyStore` after every write — batches are
/// never patched in place (ADR 0029). The actions on a Batch belong to
/// `actions`; this re-reads whenever it says something changed.
@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var sections: [HistoryDaySection] = []
    @Published public var segment: HistorySegment = .overview {
        didSet { refresh() }
    }
    /// Widens Overview to every Batch, including the ones that produced
    /// nothing, for debugging the raw log. Off by default.
    @Published public var showsUnfilteredLog = false {
        didSet { refresh() }
    }
    /// The Batch the detail pane shows. Kept across refreshes while its
    /// Batch is still listed; otherwise the first row is selected.
    @Published public var selectedBatchId: String?
    /// How many Borderline rows arrived in the last seven days.
    @Published public private(set) var borderlineCountThisWeek = 0
    /// The week at a glance, over every Batch in the window whatever view
    /// is showing.
    @Published public private(set) var weekSummary = HistoryWeekSummary()
    /// The Screening toggle as of the last refresh. Off hides everything
    /// about Screening, even over stored Screening rows (screening-optional).
    @Published public private(set) var showsScreening = false

    /// Everything History offers on a Batch besides Star and Delete.
    public let actions: HistoryBatchActions
    private let historyStore: any HistoryStore
    private let screeningSettings: ScreeningSettings
    private let now: () -> Date
    private let calendar: Calendar
    /// What History knew at the last refresh (history-snapshot). The list,
    /// the badges and every Batch's offers are drawn from this one read.
    private var facts = HistoryFacts(
        showsScreening: false, isModelLoaded: false, correctionTypes: [:], supersessions: [:], mutedChats: []
    )
    /// Each listed Batch's offers, by Batch id, worked out at refresh.
    private var offers: [String: HistoryBatchOffers] = [:]
    /// The cutoff Borderline is judged against, as of the last refresh.
    private var cutoff = defaultReviewCutoff

    /// How far back History's list reaches.
    public static let window: TimeInterval = 7 * 24 * 60 * 60

    public init(
        historyStore: any HistoryStore, actions: HistoryBatchActions,
        screeningSettings: ScreeningSettings = ScreeningSettings(), now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.historyStore = historyStore
        self.actions = actions
        self.screeningSettings = screeningSettings
        self.now = now
        self.calendar = calendar
        refresh()
        actions.onChange = { [weak self] in self?.refresh() }
    }

    public var batches: [HistoryBatch] { sections.flatMap(\.batches) }

    public var selectedBatch: HistoryBatch? {
        guard let selectedBatchId else { return nil }
        return batches.first { $0.id == selectedBatchId }
    }

    /// The views the toolbar offers: Borderline only while Screening shows.
    public var segments: [HistorySegment] {
        HistorySegment.allCases.filter { showsScreening || $0 != .borderline }
    }

    /// The header's counts line.
    public var weekCounts: String {
        var parts = ["\(weekSummary.batches) Batches", "\(weekSummary.tasks) with a task"]
        if showsScreening {
            parts += ["\(weekSummary.screened) Screened", "\(weekSummary.borderline) Borderline"]
        }
        if weekSummary.corrected > 0 { parts.append("\(weekSummary.corrected) corrected") }
        return parts.joined(separator: " · ")
    }

    public func refresh() {
        // The toggle and Muted Chats decide which Batches to read, so they
        // are read first; the Batches' own facts join them once read.
        let chatFacts = actions.facts(forBatches: [])
        showsScreening = chatFacts.showsScreening
        // Setting the segment refreshes again, with Overview showing.
        guard showsScreening || segment != .borderline else {
            segment = .overview
            return
        }
        let now = now()
        let cutoff = screeningSettings.cutoff ?? defaultReviewCutoff
        self.cutoff = cutoff
        // A pinned Muted Batch is the way back to Unmute (ADR 0031), so
        // Overview lists it whatever it produced.
        let window = historyStore.batches(
            since: now.addingTimeInterval(-Self.window), pinningLatestOf: segment == .overview ? chatFacts.mutedChats : []
        )
        let facts = actions.facts(forBatches: window.batches + window.pinned, over: chatFacts)
        self.facts = facts
        let snapshot = historySnapshot(
            week: window.batches, pinned: window.pinned, facts: facts, cutoff: cutoff, segment: segment,
            showsUnfilteredLog: showsUnfilteredLog, now: now, calendar: calendar
        )
        weekSummary = snapshot.weekSummary
        offers = snapshot.offers
        sections = snapshot.sections
        if selectedBatch == nil {
            selectedBatchId = batches.first?.id
        }
        borderlineCountThisWeek = snapshot.borderlineCountThisWeek
    }

    /// Not filtered by the Screening toggle: a Batch Jev judged keeps its
    /// Screening sections after the toggle goes off.
    public func inspection(for batch: HistoryBatch) -> HistoryInspection {
        HistoryInspection(batch)
    }

    /// The sentence the detail pane shows for a Batch that produced no task.
    public func resultSummary(for batch: HistoryBatch) -> String {
        batch.resultSummary(showsScreening: showsScreening)
    }

    /// What Copy Raw Output copies.
    public func rawOutputToCopy(for batch: HistoryBatch) -> String {
        batch.rawOutputToCopy(showsScreening: showsScreening)
    }

    public func badges(for batch: HistoryBatch) -> [HistoryBadge] {
        historyBadges(
            for: batch, cutoff: cutoff, isCorrected: isCorrected(batch), isMuted: facts.isMuted(batch),
            showsScreening: showsScreening
        )
    }

    /// What `batch` offers, as of the last refresh. The view draws its
    /// buttons from this and never asks the stores itself.
    public func offers(for batch: HistoryBatch) -> HistoryBatchOffers {
        offers[batch.id] ?? historyBatchOffers(for: batch, facts: facts)
    }

    /// One line per Suggestion the Batch Superseded (superseded-restore):
    /// "Replaced: <label>" for an UPDATE, "Withdrew: <label>" for a CANCEL.
    public func supersededLines(for batch: HistoryBatch) -> [String] {
        facts.supersessions(of: batch).map { ($0.replacedBy == nil ? "Withdrew: " : "Replaced: ") + $0.label }
    }

    /// Whether the Batch carries a Correction of any type: "Not for me",
    /// "This was work" or "Add task".
    public func isCorrected(_ batch: HistoryBatch) -> Bool {
        facts.isCorrected(batch)
    }

    // MARK: - Star and Delete

    public func toggleStar(_ batch: HistoryBatch) {
        if batch.isStarred {
            for row in batch.rows where row.isStarred {
                try? historyStore.setStarred(false, id: row.id)
            }
        } else {
            try? historyStore.setStarred(true, id: batch.starRow.id)
        }
        refresh()
    }

    /// Removes every row of the Batch. Never touches Processed state or the
    /// Signal Board (ADR 0029).
    public func delete(_ batch: HistoryBatch) {
        if let sourceRef = batch.sourceRef {
            try? historyStore.delete(sourceRef: sourceRef)
        } else {
            for row in batch.rows {
                try? historyStore.delete(id: row.id)
            }
        }
        refresh()
    }

    // MARK: - Export

    /// Every row of every listed Batch, newest Batch first, to a temp file
    /// the caller offers through a Save panel (ADR 0029).
    public func exportCSV() -> URL? {
        writeHistoryExport(historyCSV(rows: batches.flatMap(\.rows)), extension: "csv")
    }

    /// The listed Batches as a Markdown file, newest first, for keeping a
    /// week's close calls after they leave the list.
    public func exportMarkdown() -> URL? {
        writeHistoryExport(
            historyMarkdown(batches: batches, view: segment.title, cutoff: cutoff, exportedAt: now()), extension: "md"
        )
    }
}
