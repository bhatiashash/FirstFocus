import Foundation

/// One Screening decision whose outcome is known (batched-extraction
/// ticket 12): the score JEV gave a Batch, and whether it was real work.
/// "Work" means the model found at least one task in it (from intake,
/// shadow mode or the Audit Sample), or the user said "This was work".
public struct ScreeningPoint: Sendable, Equatable {
    public let probability: Double
    public let hadWork: Bool

    public init(probability: Double, hadWork: Bool) {
        self.probability = probability
        self.hadWork = hadWork
    }
}

/// The histogram's points from `HistoryStore.screeningOutcomes` (ADR 0036,
/// ADR 0039). A decision the model never judged is left out, unless the
/// Batch is in `markedAsWork`, the Batches with a "This was work"
/// Correction, which settles it as work either way.
public func screeningPoints(from outcomes: [ScreeningOutcome], markedAsWork: Set<String> = []) -> [ScreeningPoint] {
    outcomes.compactMap { outcome in
        if markedAsWork.contains(outcome.sourceRef) {
            return ScreeningPoint(probability: outcome.probability, hadWork: true)
        }
        return outcome.modelFoundTask.map { ScreeningPoint(probability: outcome.probability, hadWork: $0) }
    }
}

public let histogramBinWidth = 0.05

/// One bar of the cutoff histogram: scores from `lower` up to the next bin.
public struct HistogramBin: Sendable, Equatable {
    public let lower: Double
    public let work: Int
    public let nothing: Int
}

/// Twenty bins from 0 to 1. A score of exactly 1 goes in the last one.
public func screeningHistogram(_ points: [ScreeningPoint]) -> [HistogramBin] {
    let count = Int((1 / histogramBinWidth).rounded())
    var work = Array(repeating: 0, count: count)
    var nothing = Array(repeating: 0, count: count)
    for point in points {
        // The small nudge keeps a score sitting exactly on an edge, like
        // 0.15, in the bin it starts rather than the one below.
        let index = min(max(Int(point.probability / histogramBinWidth + 1e-9), 0), count - 1)
        if point.hadWork { work[index] += 1 } else { nothing[index] += 1 }
    }
    return (0..<count).map { HistogramBin(lower: Double($0) * histogramBinWidth, work: work[$0], nothing: nothing[$0]) }
}

/// What a cutoff would have cost: how many Batches it would Screen (live
/// mode Screens everything scored strictly below it), and how many of
/// those were work.
public struct CutoffReadout: Sendable, Equatable {
    public let wouldScreen: Int
    public let hadWork: Int

    public init(wouldScreen: Int, hadWork: Int) {
        self.wouldScreen = wouldScreen
        self.hadWork = hadWork
    }
}

public func cutoffReadout(_ points: [ScreeningPoint], cutoff: Double) -> CutoffReadout {
    let screened = points.filter { $0.probability < cutoff }
    return CutoffReadout(wouldScreen: screened.count, hadWork: screened.filter(\.hadWork).count)
}
