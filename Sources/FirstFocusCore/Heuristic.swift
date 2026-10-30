import Foundation

/// Exact-match acknowledgments and reactions: cheap to reject outright, and
/// never worth a model call. Anything not on this list passes through —
/// the heuristic only cuts the obvious cases; the model is still the final
/// judge of everything else (Extraction favours precision over recall, but
/// that posture lives in the model call, not here).
private let heuristicFillerPhrases: Set<String> = [
    "ok", "okay", "k", "kk",
    "yes", "no", "yep", "yeah", "nope",
    "lol", "lmao", "haha", "hahaha",
    "thanks", "thank you", "thx", "np",
    "sure", "cool", "nice", "great", "got it", "gotcha",
]

/// The intake pre-filter (Focus Mode v2): a pure, model-free check deciding
/// whether `text` is worth a model call at all. Only rejects empty text and
/// an exact-match acknowledgment/reaction — never a substring match, so an
/// acknowledgment used inside a longer message still passes through.
public func isWorthExtracting(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return !heuristicFillerPhrases.contains(trimmed.lowercased())
}
