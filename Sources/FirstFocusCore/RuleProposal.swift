import Foundation

/// Free-form generation from the local model, with a system prompt of the
/// caller's choosing (ADR 0038's Rule proposals). Separate from
/// `IntentExtractor`, whose one call always wraps its input in the
/// extraction prompt.
public protocol FreeTextGenerating: Sendable {
    func generateText(system: String, user: String, maxTokens: Int, priority: TaskPriority) async throws -> String
}

/// Proposing Rules needs at least this many new "Not for me" Corrections
/// since the last proposal, so the model has a pattern to generalize from.
public let minimumCorrectionsForProposal = 5

/// Room for up to three short Rules, one per line.
public let ruleProposalMaxTokens = 256

/// At most this many Rules come back from one proposal.
public let maxProposedRules = 3

/// Whether "Propose rules" can run right now, and if not, why.
public enum RuleProposalStatus: Sendable, Equatable {
    case noModel
    case passRunning
    case needsMoreCorrections(have: Int)
    case ready(newCorrections: Int)
}

public let ruleProposalSystemPrompt = """
    You help tune a task extractor. It reads chat messages and outputs a short task label, or NONE when a message \
    holds no task for the user. Below are messages it wrongly turned into tasks; the correct output for each was NONE.

    Write at most \(maxProposedRules) short, general, plain-English rules that would have prevented these mistakes \
    and would apply to any conversation. One rule per line, no numbering, no other text. \
    Never name a person, a participant, a chat, a phone number or an email address. \
    If the mistakes share no general pattern, output fewer rules.
    """

/// The Corrections as a numbered list of the inputs the extractor saw.
public func ruleProposalUserPrompt(corrections: [Correction]) -> String {
    corrections.enumerated()
        .map { index, correction in "Mistake \(index + 1):\n\(correction.inputText)" }
        .joined(separator: "\n\n")
}

/// One Rule per non-blank line, list markers stripped, at most
/// `maxProposedRules`. A line carrying seven or more digits in a row
/// (spaces, dashes, dots and brackets between them allowed) is dropped as a
/// likely phone number, whatever the prompt asked for.
public func parseProposedRules(_ raw: String) -> [String] {
    let marker = /^\s*(?:[-*•]|\d+[.)])\s*/
    let phoneLike = /(?:\d[\s\-.()]?){7,}/
    return raw.split(whereSeparator: \.isNewline)
        .map { String($0).replacing(marker, with: "").trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .filter { $0.firstMatch(of: phoneLike) == nil }
        .prefix(maxProposedRules)
        .map { $0 }
}
