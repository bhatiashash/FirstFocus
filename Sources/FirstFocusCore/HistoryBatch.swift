import Foundation

/// What History calls a Chat it has no name for.
public let chatNotRecordedTitle = "Chat not recorded"

/// Every History row recorded for one Batch (CONTEXT.md: Batch, History):
/// its Screening decision, the model call intake made, an Audit Sample
/// and any Re-runs. History's list shows one of these per row, not one per
/// `HistoryEntry`. Rows are grouped by `sourceRef`, the Batch's newest
/// message id, which every row for a Batch carries. A row written before
/// History recorded one is a Batch of its own.
public struct HistoryBatch: Identifiable, Equatable, Sendable {
    public let id: String
    /// Oldest first.
    public let rows: [HistoryEntry]
    /// Where the list files the Batch: its earliest row inside the window
    /// it was read for. A Batch judged before the window and Re-run inside
    /// it is filed under the Re-run's day, not under Earlier.
    public let listedAt: Date

    public init(id: String, rows: [HistoryEntry], listedAt: Date? = nil) {
        precondition(!rows.isEmpty, "a History Batch always has at least one row")
        self.id = id
        self.rows = rows
        self.listedAt = listedAt ?? rows[0].timestamp
    }

    /// When the Batch was first judged: its earliest row.
    public var timestamp: Date { rows[0].timestamp }
    public var sourceRef: String? { rows[0].sourceRef }
    public var chatId: Int? { rows.lazy.compactMap(\.chatId).first }
    public var sourceText: String { (intakeRow ?? rows[0]).sourceRawText }

    /// Who History names the Batch after (CONTEXT.md: Sender): the Sender
    /// intake recorded, or "You" when every message was yours and there
    /// was nobody else. `nil` for rows written before History recorded a
    /// Sender.
    public var sender: String? {
        if let sender = rows.lazy.compactMap(\.sender).first { return sender }
        return rows.contains(where: \.isAllMine) ? "You" : nil
    }

    public var isSelfThread: Bool { rows.contains(where: \.isSelfThread) }

    /// The Batch's messages under real names. `nil` for rows written before
    /// History recorded a transcript; the detail pane then shows
    /// `sourceText` as one block.
    public var transcript: [HistoryTranscriptLine]? { rows.lazy.compactMap(\.transcript).first }

    /// A group Chat's name, or `selfThreadTitle`. `nil` for a one-to-one
    /// Chat.
    public var chatTitle: String? { isSelfThread ? selfThreadTitle : groupTitle }

    private var groupTitle: String? { rows.lazy.compactMap(\.chatTitle).first }

    /// The list row's headline: who the Batch is from.
    public var title: String { chatTitle ?? sender ?? chatNotRecordedTitle }

    private var isGroupChat: Bool { !isSelfThread && groupTitle != nil }

    /// The Batch's first message, one line, for the list row. A group's
    /// preview names who wrote it, since the title names the group.
    public var preview: String {
        if let first = transcript?.first(where: { !$0.isContext }) {
            return isGroupChat ? "\(first.speaker): \(first.text)" : first.text
        }
        return sourceText.split(separator: "\n").first.map(String.init) ?? sourceText
    }

    /// The Batch's newest message, one line, shaped like `preview`.
    /// Advanced shows it on hover over a Muted Chat, since a name alone
    /// can be a bare phone number (muted-chats-list).
    public var latestMessage: String {
        if let last = transcript?.last(where: { !$0.isContext }) {
            return isGroupChat ? "\(last.speaker): \(last.text)" : last.text
        }
        return sourceText.split(separator: "\n").last.map(String.init) ?? sourceText
    }

    public var screeningRow: HistoryEntry? { rows.last { $0.isScreening } }

    public var screeningFailureRow: HistoryEntry? {
        rows.last { if case .screeningFailed = $0.kind { return true } else { return false } }
    }

    /// The latest model call that failed (CONTEXT.md: Processed).
    public var extractionFailureRow: HistoryEntry? {
        rows.last { if case .extractionFailed = $0.kind { return true } else { return false } }
    }

    /// Whether the Batch skipped Screening because the breaker was open
    /// (CONTEXT.md: Screening Unavailable).
    public var wasScreeningUnavailable: Bool { rows.contains { $0.kind == .screeningUnavailable } }

    /// The model call intake made (or "This was work" made, for a Screened
    /// Batch): the earliest extraction row. Re-runs are recorded under
    /// their own kind now, but a row written before that existed is an
    /// extraction row too, and always later than intake's.
    public var intakeRow: HistoryEntry? { rows.first { $0.kind == .extraction } }

    public var reruns: [HistoryEntry] {
        let intakeId = intakeRow?.id
        return rows.filter { $0.kind == .rerun || ($0.kind == .extraction && $0.id != intakeId) }
    }

    public var auditRow: HistoryEntry? { rows.last { $0.kind == .audit } }

    /// The model call the list reports: intake's, or the latest Re-run when
    /// intake's row is gone. History reads whole Batches, so a Re-run never
    /// stands in for an intake row that merely fell outside a read.
    public var resultRow: HistoryEntry? { intakeRow ?? reruns.last }

    public var wasScreened: Bool { screeningRow?.wasScreened ?? false }

    /// Starred if any of its rows is, so a star set on a single row before
    /// History grouped by Batch still shows.
    public var isStarred: Bool { rows.contains { $0.isStarred } }

    /// Which row a star lands on: the model call, since that is what the
    /// model evaluator replays.
    public var starRow: HistoryEntry { resultRow ?? rows[rows.count - 1] }

    /// What "Copy raw output" copies: the model's answer, or Screening's
    /// when the model never saw the Batch.
    public var rawOutputToCopy: String { (resultRow ?? screeningRow ?? starRow).rawOutput }

    /// `rawOutputToCopy` for the Screening toggle's state: with it off,
    /// only the model's answer, since Screening's is Screening data
    /// (screening-optional).
    public func rawOutputToCopy(showsScreening: Bool) -> String {
        showsScreening ? rawOutputToCopy : resultRow?.rawOutput ?? ""
    }

    public var result: HistoryBatchResult {
        if let resultRow {
            let labels = parseExtractionResults(resultRow.rawOutput).compactMap(\.label)
            return labels.isEmpty ? .noTask : .tasks(labels)
        }
        if let failure = extractionFailureRow, case .extractionFailed(let reason) = failure.kind {
            return .extractionFailed(reason: reason)
        }
        if let screening = screeningRow?.screening {
            return screening.wasScreened
                ? .screened(probability: screening.probability, cutoff: screening.cutoff)
                : .letThrough(probability: screening.probability)
        }
        if let failure = screeningFailureRow, case .screeningFailed(let reason) = failure.kind {
            return .screeningFailed(reason: reason)
        }
        return .noTask
    }

    /// `resultSummary` for the Screening toggle's state. With it off,
    /// History says nothing about Screening, so a Batch the model never
    /// judged just says so (screening-optional).
    public func resultSummary(showsScreening: Bool) -> String {
        guard !showsScreening else { return resultSummary }
        switch result {
        case .screened, .letThrough, .screeningFailed: return "Not read by the model."
        case .tasks, .noTask, .extractionFailed: return resultSummary
        }
    }

    /// One plain sentence for a Batch that produced no task. Empty when it
    /// did, since the tasks themselves are the answer.
    public var resultSummary: String {
        switch result {
        case .tasks: ""
        case .noTask: "The model found no task."
        case .screened(let probability, let cutoff):
            if let cutoff {
                "Screened at \(formatScore(probability)), below the \(formatScore(cutoff)) cutoff."
            } else {
                "Screened at \(formatScore(probability))."
            }
        case .letThrough(let probability):
            "Let through Screening at \(formatScore(probability)). No model result recorded."
        case .screeningFailed(let reason):
            "Screening failed (\(reason)). No model result recorded."
        case .extractionFailed(let reason):
            "The model call failed (\(reason))."
        }
    }
}

/// The title History gives the Self-thread's Batches.
public let selfThreadTitle = "Self-thread"

/// What happened to a Batch, as History's list reports it.
public enum HistoryBatchResult: Equatable, Sendable {
    case tasks([String])
    case noTask
    case screened(probability: Double, cutoff: Double?)
    /// Screening let the Batch through but no model row is recorded for it.
    case letThrough(probability: Double)
    case screeningFailed(reason: String)
    /// The model was called and threw; no later call answered.
    case extractionFailed(reason: String)
}

public func formatScore(_ value: Double) -> String {
    String(format: "%.2f", value)
}

/// Groups History rows into Batches, newest first by `listedAt`. Rows keep
/// their own order within a Batch, oldest first. With `since`, a Batch is
/// listed at its earliest row at or after it.
public func groupHistoryIntoBatches(_ entries: [HistoryEntry], since: Date? = nil) -> [HistoryBatch] {
    var order: [String] = []
    var rowsById: [String: [HistoryEntry]] = [:]
    for entry in entries {
        let id = entry.sourceRef ?? "row:\(entry.id)"
        if rowsById[id] == nil { order.append(id) }
        rowsById[id, default: []].append(entry)
    }
    return order
        .map { id in
            let rows = rowsById[id]!.sorted { $0.timestamp < $1.timestamp }
            let listedAt = since.flatMap { since in rows.first { $0.timestamp >= since }?.timestamp }
            return HistoryBatch(id: id, rows: rows, listedAt: listedAt)
        }
        .sorted { $0.listedAt > $1.listedAt }
}

/// One headed block of History's list.
public struct HistoryDaySection: Identifiable, Equatable, Sendable {
    public let title: String
    public let batches: [HistoryBatch]
    public var id: String { title }

    public init(title: String, batches: [HistoryBatch]) {
        self.title = title
        self.batches = batches
    }
}

/// The title "Earlier" goes under: anything a full week or more before
/// `now`.
public let earlierSectionTitle = "Earlier"

/// Splits `batches` (newest first) into Today, Yesterday, then weekday
/// names for the rest of the week ("Last Wednesday" for today's weekday a
/// week back), then Earlier. Takes `now` and a
/// calendar so the result never depends on the wall clock.
public func historyDaySections(_ batches: [HistoryBatch], now: Date, calendar: Calendar) -> [HistoryDaySection] {
    let today = calendar.startOfDay(for: now)
    let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
    var titles: [String] = []
    var byTitle: [String: [HistoryBatch]] = [:]
    for batch in batches {
        let day = calendar.startOfDay(for: batch.listedAt)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let title: String = switch daysAgo {
        case ...0: "Today"
        case 1: "Yesterday"
        case 2...6: calendar.weekdaySymbols[calendar.component(.weekday, from: day) - 1]
        // Today's weekday a week back, still inside the seven days.
        case 7 where batch.listedAt >= weekAgo: "Last " + calendar.weekdaySymbols[calendar.component(.weekday, from: day) - 1]
        default: earlierSectionTitle
        }
        if byTitle[title] == nil { titles.append(title) }
        byTitle[title, default: []].append(batch)
    }
    return titles.map { HistoryDaySection(title: $0, batches: byTitle[$0]!) }
}

/// One status pill on a History row. Always a symbol and words, never
/// colour alone: CONTEXT.md reserves colour for an overdue date.
public struct HistoryBadge: Equatable, Sendable {
    public let text: String
    /// An SF Symbol name.
    public let symbol: String

    public init(text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }
}

/// What a History row says about its Batch. Only exceptions get a badge:
/// a task, a failed Screening, a failed model call, Borderline, Corrected
/// and Muted. The routine
/// outcomes (no task, Screened, let through) carry none, since most of a
/// week's Batches are chat filler and a badge on each would be noise; the
/// detail pane still says what happened.
///
/// With the Screening toggle off (`showsScreening` false), no badge speaks
/// of Screening: no failed Screening and no Borderline (screening-optional).
public func historyBadges(
    for batch: HistoryBatch, cutoff: Double, isCorrected: Bool, isMuted: Bool, showsScreening: Bool = true
) -> [HistoryBadge] {
    // A failed Screening leads even when the model then judged the Batch:
    // it is the exception a review is looking for.
    let failure: HistoryBatchResult? = batch.screeningFailureRow.flatMap { row in
        if case .screeningFailed(let reason) = row.kind { return .screeningFailed(reason: reason) }
        return nil
    }
    let result = (showsScreening ? failure : nil) ?? batch.result
    var badges: [HistoryBadge] = switch result {
    case .tasks(let labels):
        [HistoryBadge(text: labels.count == 1 ? "Task" : "\(labels.count) tasks", symbol: "checkmark.circle")]
    case .screeningFailed:
        showsScreening ? [HistoryBadge(text: "Screening failed", symbol: "xmark.octagon")] : []
    case .extractionFailed:
        [HistoryBadge(text: "Model failed", symbol: "exclamationmark.octagon")]
    case .noTask, .screened, .letThrough:
        []
    }
    if showsScreening, let screening = batch.screeningRow, let probability = screening.screeningProbability,
       isBorderline(screening, cutoff: cutoff) {
        badges.append(HistoryBadge(text: "Borderline \(formatScore(probability))", symbol: "exclamationmark.triangle"))
    }
    if isCorrected {
        badges.append(HistoryBadge(text: "Corrected", symbol: "arrow.uturn.backward.circle"))
    }
    if isMuted {
        badges.append(HistoryBadge(text: "Muted", symbol: "bell.slash"))
    }
    return badges
}

/// Everything History's Inspector shows about how a Batch was judged.
/// Each part is `nil` or empty when the Batch has no matching row.
public struct HistoryInspection: Equatable, Sendable {
    public enum ScreeningMode: Equatable, Sendable { case shadow, live }

    public struct Screening: Equatable, Sendable {
        public let probability: Double
        /// The cutoff in force at the time; `nil` in shadow mode.
        public let cutoff: Double?
        public let mode: ScreeningMode
        public let wasScreened: Bool
        public let service: String

        /// "JEV confidence": the score is the service's own probability
        /// that the Batch holds work.
        public var confidenceLabel: String { "\(service) confidence" }
    }

    public struct ScreeningFailure: Equatable, Sendable {
        public let reason: String
        public let service: String
    }

    public let screening: Screening?
    public let screeningFailure: ScreeningFailure?
    /// The Batch skipped Screening because the breaker was open.
    public let screeningUnavailable: Bool
    /// Intake's model call, or the latest Re-run when intake's row is gone.
    public let modelCall: HistoryEntry?
    /// The exact prompt the model saw, Participant Labels and all; the
    /// Screening input when the model never saw the Batch.
    public let prompt: String?
    public let reruns: [HistoryEntry]
    public let audit: HistoryEntry?
    public let messageId: String?
    public let chatId: Int?

    /// Everything the Batch stored, whatever the Screening toggle says now:
    /// the Inspector is the record of how the Batch was judged at the time.
    public init(_ batch: HistoryBatch) {
        if let row = batch.screeningRow, let decision = row.screening {
            let mode: ScreeningMode = switch decision.mode {
            case .shadow: .shadow
            case .live: .live
            }
            screening = Screening(
                probability: decision.probability, cutoff: decision.cutoff, mode: mode,
                wasScreened: decision.wasScreened, service: row.modelUsed
            )
        } else {
            screening = nil
        }
        if let row = batch.screeningFailureRow, case .screeningFailed(let reason) = row.kind {
            screeningFailure = ScreeningFailure(reason: reason, service: row.modelUsed)
        } else {
            screeningFailure = nil
        }
        screeningUnavailable = batch.wasScreeningUnavailable
        let modelCall = batch.resultRow
        self.modelCall = modelCall
        let reruns = batch.reruns.filter { $0.id != modelCall?.id }
        self.reruns = reruns
        prompt = (modelCall ?? batch.screeningRow ?? batch.screeningFailureRow)?.renderedContext
        audit = batch.auditRow
        messageId = batch.sourceRef
        chatId = batch.chatId
    }
}
