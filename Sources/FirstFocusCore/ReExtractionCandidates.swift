import Foundation

/// Processed Batches with no live Signal (open, checked off, approved or
/// Superseded), so manual re-extraction knows which ones are worth
/// revisiting (ADR 0004), sorted. The Batch Ledger's rule, reached through
/// `BatchLedger.reExtractionCandidates()`. Every Processed message is a
/// candidate under its own id unless a recorded Batch absorbs it, which is
/// how a message Processed before batching comes back as a Batch of one.
func reExtractionCandidates(
    processedRefs: Set<String>,
    signalStates: [(sourceRef: String, state: SignalState)],
    recordedBatches: [String: [String]]
) -> [String] {
    let liveRefs = Set(signalStates.filter(isLiveSignalState).map(\.sourceRef))
    // A Batch (ADR 0039) is one candidate, under its own id; the rest of its
    // members were never judged on their own and never are.
    let absorbed = Set(recordedBatches.flatMap { batchId, members in members.filter { $0 != batchId } })
    return processedRefs.filter { !liveRefs.contains($0) && !absorbed.contains($0) }.sorted()
}

private func isLiveSignalState(_ entry: (sourceRef: String, state: SignalState)) -> Bool {
    switch entry.state {
    case .open, .checkedOff, .approved, .superseded:
        return true
    case .dismissed:
        return false
    }
}
