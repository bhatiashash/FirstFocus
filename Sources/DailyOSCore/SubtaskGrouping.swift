import Foundation

/// Subtask grouping (ticket 04, ADR 0010): a rendering-only grouping of the
/// ranked list, computed fresh from `sourceRef` + `lowConfidence` on every
/// call rather than stored — there is no persisted "group" concept
/// anywhere in `Signal` or `SignalStore`. `Identifiable` by the member
/// id(s) it wraps, so a `List`/`ForEach` over the result stays stable
/// across recomputation the same way a bare `[Signal]` already does.
public enum RenderGroup: Identifiable, Equatable, Sendable {
    case single(Signal)
    case group([Signal])

    public var id: String {
        switch self {
        case .single(let signal):
            return signal.id
        case .group(let signals):
            return signals.map(\.id).joined(separator: "+")
        }
    }
}

/// Groups a maximal *consecutive* run of Signals sharing one `sourceRef`,
/// all `lowConfidence`, into one `.group` — everything else, including a
/// lone `lowConfidence` Signal whose former batch-mates have all since been
/// checked off, dismissed, or approved (and so no longer appear in
/// `signals` at all), renders as `.single`. Order is preserved exactly:
/// this never reorders `signals`, only clusters adjacent runs that already
/// share a batch — the same order `rank` already produced.
public func groupForRendering(_ signals: [Signal]) -> [RenderGroup] {
    var result: [RenderGroup] = []
    var index = 0
    while index < signals.count {
        let current = signals[index]
        guard current.lowConfidence else {
            result.append(.single(current))
            index += 1
            continue
        }

        var runEnd = index + 1
        while runEnd < signals.count, signals[runEnd].lowConfidence, signals[runEnd].sourceRef == current.sourceRef {
            runEnd += 1
        }

        let run = Array(signals[index..<runEnd])
        result.append(run.count > 1 ? .group(run) : .single(current))
        index = runEnd
    }
    return result
}
