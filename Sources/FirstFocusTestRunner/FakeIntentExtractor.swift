import FirstFocusCore
import Foundation

/// Test double for `IntentExtractor`. Maps exact message text to the raw
/// delimited output a real model would have produced, so a test controls
/// exactly what `parseExtractionOutput` sees without depending on any real
/// model. Unmapped text gets `defaultResponse` — `"NONE"` by default, so a
/// test only has to name the messages it cares about.
///
/// `@unchecked Sendable`: every test calls this synchronously on one
/// thread, so `calls`' mutability is never actually raced.
final class FakeIntentExtractor: IntentExtractor, @unchecked Sendable {
    private let responses: [String: String]
    private let defaultResponse: String
    let modelDisplayName: String
    /// A deliberately generous default: a test only cares about token
    /// pressure when it sets this to something small on purpose (see the
    /// correction-budget-shrink tests), and every other test's composed
    /// prompt should sail under it without having to think about token
    /// counts at all.
    let maxPromptTokens: Int
    private(set) var calls: [String] = []
    /// One entry per call, in order, alongside `calls` — lets a test assert
    /// which QoS a given code path actually requested (e.g. AppModel's
    /// automated refresh versus its manual re-extraction).
    private(set) var callPriorities: [TaskPriority] = []
    /// Runs inside each call before it answers, so a test can change
    /// settings while a pass is mid-flight.
    var onExtract: (@Sendable () async -> Void)?
    /// While set, every call is counted and then throws this, the way a
    /// real model throws on a prompt too long or a failed decode.
    var failure: Error?

    init(
        responses: [String: String] = [:], defaultResponse: String = "NONE", modelDisplayName: String = "Fake Model",
        maxPromptTokens: Int = 10_000
    ) {
        self.responses = responses
        self.defaultResponse = defaultResponse
        self.modelDisplayName = modelDisplayName
        self.maxPromptTokens = maxPromptTokens
    }

    func extract(from text: String, priority: TaskPriority = .userInitiated) async throws -> String {
        calls.append(text)
        callPriorities.append(priority)
        await onExtract?()
        if let failure { throw failure }
        return responses[text] ?? responses[judgedText(in: text)] ?? defaultResponse
    }

    /// Lets a test key `responses` by the message text alone, even though
    /// every message from someone else now reaches the model under a
    /// `[latest messages]` block with a sender prefix (batched-extraction
    /// ticket 03). An exact match on the whole prompt still wins.
    private func judgedText(in prompt: String) -> String {
        guard let range = prompt.range(of: "[latest messages]\n") else { return prompt }
        return prompt[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// A simple, deterministic proxy — whitespace-separated word count —
    /// rather than any real tokenizer: a test driving the budget-shrink
    /// path only needs *some* number that grows with input length and
    /// shrinks in a predictable way as Corrections are dropped, not a
    /// realistic one.
    /// What `generateText` returns, and every request it received.
    var freeTextResponse = ""
    private(set) var freeTextRequests: [(system: String, user: String)] = []

    func recordFreeTextRequest(_ request: (system: String, user: String)) {
        freeTextRequests.append(request)
    }

    /// The Rule texts most recently handed over (ADR 0038).
    private(set) var rules: [String] = []

    func setRules(_ rules: [String]) {
        self.rules = rules
    }

    func estimatedTokenCount(for text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// ADR 0038: the fake also stands in for the local model's free-text call
/// that Rule proposals use.
extension FakeIntentExtractor: FreeTextGenerating {
    func generateText(system: String, user: String, maxTokens: Int, priority: TaskPriority) async throws -> String {
        recordFreeTextRequest((system, user))
        return freeTextResponse
    }
}

