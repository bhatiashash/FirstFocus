import Foundation

// Pure pieces of the ModelEvaluator study, kept here rather than in its
// executable target so FirstFocusTestRunner can reach them.

/// One case's transcript entry in `model_evaluation_report.md`, which is
/// committed to git. A synthetic case is quoted in full. A real one (a
/// History row or a Correction) is not: its input is someone's real
/// message (ADR 0007, ADR 0036), and its raw output can copy names and
/// details straight out of that input, so both stay in the Desktop CSV.
/// `rawOutput` is `nil` when the call failed and there is none to show.
public func evaluationTranscriptBody(input: String, rawOutput: String?, isRealData: Bool) -> String {
    guard !isRealData else {
        return "_Real message text: input and output are only in the Desktop CSV._\n\n"
    }
    var body = "> \(input.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
    if let rawOutput {
        body += "```\n\(rawOutput)\n```\n\n"
    }
    return body
}

/// A case's format violations as the committed report may show them. A
/// real case's violation can quote a line of the model's output (a
/// `DUE_TEXT` cue is usually copied from the input), so only the kind
/// before the quoted part is kept.
public func reportableViolations(_ violations: [String], isRealData: Bool) -> [String] {
    guard isRealData else { return violations }
    return violations.map { violation in
        violation.range(of: " (\"").map { String(violation[..<$0.lowerBound]) } ?? violation
    }
}

/// A stored Correction turned into a ModelEvaluator case: the input the
/// model saw, replayed as-is, and what a right answer looks like.
public struct CorrectionCase: Sendable, Equatable {
    public let correctionType: CorrectionType
    public let input: String
    /// `false`: the right answer is NONE. `true`: at least one task,
    /// whatever its wording.
    public let expectsTask: Bool
    /// The Label typed with "Add task", shown beside the model's output
    /// but never matched against it: greedy decoding rarely reproduces a
    /// hand-typed Label word for word.
    public let typedLabel: String?
}

/// `nil` for a Correction with no answer the model should give: "This
/// was work" records a Screening miss, not the model's, and a field
/// correction has no UI yet. A model miss after "This was work" shows up
/// as its own "Add task" Correction, which is scored.
public func correctionCase(from correction: Correction) -> CorrectionCase? {
    let expectsTask: Bool
    switch correction.correctionType {
    case .falsePositive: expectsTask = false
    case .missedTask: expectsTask = true
    case .falseNegative, .fieldCorrection: return nil
    }
    return CorrectionCase(
        correctionType: correction.correctionType, input: inBatchFormat(correction.inputText), expectsTask: expectsTask,
        typedLabel: expectsTask ? correction.correctedOutput : nil
    )
}
