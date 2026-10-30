import Darwin
import FirstFocusCore
import Foundation

// One-off model comparison study, not part of the shipped app. Run with
// `swift run -c release ModelEvaluator` from the package root — writes
// model_evaluation_report.md there and FirstFocus_Model_Evaluation.csv to
// the Desktop. See the report's own Methodology Note for the caveats
// this run is subject to (corpus is mostly synthetic, not real History;
// one shared ChatML prompt template across all three models; token/ms
// and hallucination figures are disclosed heuristics, not exact).

let bundleIdentifier = "com.shashbhatia.FirstFocus"

/// Where a case came from. Everything but `.synthetic` is someone's real
/// message, so the committed report never quotes it (see
/// `evaluationTranscriptBody`).
enum CorpusSource {
    case synthetic
    case realHistory
    case correction

    var isRealData: Bool {
        switch self {
        case .synthetic: false
        case .realHistory, .correction: true
        }
    }
}

struct CorpusItem {
    let id: String
    let category: String
    let source: CorpusSource
    /// What a correct model should decide: real work (`true`) or `NONE`
    /// (`false`). `nil` for a real History row — there's no independent
    /// ground truth for those, so they're logged and never scored.
    /// Authored by hand against the extraction prompt's own stated rules
    /// for every synthetic item — this is the study's ground truth for
    /// "extraction fidelity" and "zero-signal accuracy", not derived from
    /// any model.
    let expectedSignal: Bool?
    let text: String
    /// For a Batch fixture whose right answer is more than task-or-NONE
    /// (batched-extraction ticket 03): an UPDATE or CANCEL of a numbered
    /// open suggestion. When set, it decides correctness instead of
    /// `expectedSignal` alone.
    let check: (@Sendable ([ExtractionResult]) -> Bool)?
    /// The Label typed with "Add task", for a Correction-based case only.
    /// Shown in the CSV beside the models' output, never matched.
    var typedLabel: String? = nil
    var isRealData: Bool { source.isRealData }

    init(
        id: String, category: String, expectedSignal: Bool, text: String,
        check: (@Sendable ([ExtractionResult]) -> Bool)? = nil
    ) {
        self.id = id
        self.category = category
        self.source = .synthetic
        self.expectedSignal = expectedSignal
        self.text = text
        self.check = check
    }

    init(realHistoryID id: String, text: String) {
        self.id = "real-\(id.prefix(8))"
        self.category = "real history (unscored)"
        self.source = .realHistory
        self.expectedSignal = nil
        self.text = text
        self.check = nil
    }

    /// Numbered by position rather than named from the Correction, so the
    /// id carries none of its text.
    init(correctionCase: CorrectionCase, number: Int) {
        self.id = "correction-\(number)"
        self.category = correctionCategory(correctionCase.correctionType)
        self.source = .correction
        self.expectedSignal = correctionCase.expectsTask
        self.text = correctionCase.input
        self.check = nil
        self.typedLabel = correctionCase.typedLabel
    }
}

/// The report's Correction section groups by these.
func correctionCategory(_ type: CorrectionType) -> String {
    switch type {
    case .falsePositive: "correction, Not for me (expects NONE)"
    case .missedTask: "correction, Add task (expects a task)"
    case .falseNegative, .fieldCorrection: "correction, \(type.rawValue) (unscored)"
    }
}

// Deliberately NOT copies of `LlamaCppIntentExtractor.defaultExtractionPrompt`'s
// own few-shot examples — a model would trivially ace an example it was
// already shown verbatim in its own system prompt, which would measure
// prompt-following, not generalization. Every item below is a fresh
// message written to exercise the same rule the prompt states, never the
// same sentence. 50 items, matching this round's "at least 50" spec —
// the previous run used 24; this one adds 26 more of the same shape
// rather than replacing what already held up.
let syntheticCorpus: [CorpusItem] = [
    CorpusItem(id: "task-simple-1", category: "simple task", expectedSignal: true, text: "Need to renew my passport before the trip"),
    CorpusItem(id: "task-simple-2", category: "simple task", expectedSignal: true, text: "Pick up dry cleaning from the place on 5th"),
    CorpusItem(id: "task-simple-3", category: "simple task", expectedSignal: true, text: "Should look into switching our CI provider, current one keeps flaking"),
    CorpusItem(id: "task-simple-4", category: "simple task", expectedSignal: true, text: "Refill the propane tank for the grill"),
    CorpusItem(id: "task-simple-5", category: "simple task", expectedSignal: true, text: "Circle back with the landlord about the leaky faucet"),
    CorpusItem(id: "task-simple-6", category: "simple task", expectedSignal: true, text: "Order a new set of running shoes, mine are falling apart"),
    CorpusItem(id: "task-simple-7", category: "simple task", expectedSignal: true, text: "Draft the intro paragraph for the grant proposal"),
    CorpusItem(id: "task-simple-8", category: "simple task", expectedSignal: true, text: "Text mom back about Thanksgiving plans"),
    CorpusItem(id: "task-simple-9", category: "simple task", expectedSignal: true, text: "Need to follow up with the insurance company about the claim"),
    CorpusItem(id: "task-simple-10", category: "simple task", expectedSignal: true, text: "Reminder to myself: water the plants"),
    CorpusItem(id: "task-due-1", category: "due date", expectedSignal: true, text: "Submit the expense report by tomorrow"),
    CorpusItem(id: "task-due-2", category: "due date", expectedSignal: true, text: "Meet Priya for coffee next Tuesday"),
    CorpusItem(id: "task-due-3", category: "due date", expectedSignal: true, text: "Pay the storage unit rent before the 1st"),
    CorpusItem(id: "task-due-4", category: "due date (vague)", expectedSignal: true, text: "Get the car inspected sometime soon"),
    CorpusItem(id: "task-due-5", category: "due date", expectedSignal: true, text: "Finish reading chapter 4 by Sunday"),
    CorpusItem(id: "task-due-6", category: "due date (vague)", expectedSignal: true, text: "Renew the gym membership before it lapses at the end of the week"),
    CorpusItem(id: "task-multi-1", category: "multi-task", expectedSignal: true, text: "Can you order stamps and also drop the packages at the post office"),
    CorpusItem(id: "task-multi-2", category: "multi-task", expectedSignal: true, text: "Book flights for the offsite and reserve a rental car"),
    CorpusItem(id: "task-multi-3", category: "multi-task", expectedSignal: true, text: "Ping the landlord and also schedule the AC repair"),
    CorpusItem(id: "task-multi-4", category: "multi-task", expectedSignal: true, text: "Update the resume and send it to the recruiter"),
    CorpusItem(id: "filler-1", category: "zero-signal", expectedSignal: false, text: "haha that's hilarious"),
    CorpusItem(id: "filler-2", category: "zero-signal", expectedSignal: false, text: "Just got back from the gym, feeling good"),
    CorpusItem(id: "filler-3", category: "zero-signal", expectedSignal: false, text: "The weather has been really nice this week"),
    CorpusItem(id: "filler-4", category: "zero-signal", expectedSignal: false, text: "Thanks, appreciate it!"),
    CorpusItem(id: "filler-5", category: "zero-signal", expectedSignal: false, text: "That restaurant was pretty mid honestly"),
    CorpusItem(id: "filler-6", category: "zero-signal", expectedSignal: false, text: "lmaooo no way"),
    CorpusItem(id: "filler-7", category: "zero-signal (question)", expectedSignal: false, text: "did you end up going"),
    CorpusItem(id: "filler-8", category: "zero-signal (question)", expectedSignal: false, text: "what time works for you tomorrow"),
    CorpusItem(id: "filler-9", category: "zero-signal", expectedSignal: false, text: "sure, sounds good"),
    CorpusItem(id: "filler-10", category: "zero-signal (emoji only)", expectedSignal: false, text: "🎉🎉🎉"),
    CorpusItem(id: "filler-11", category: "zero-signal (third-party task)", expectedSignal: false, text: "he said he'd handle the invoice himself"),
    CorpusItem(id: "filler-12", category: "zero-signal (already done)", expectedSignal: false, text: "already submitted the report this morning"),
    CorpusItem(id: "filler-13", category: "zero-signal (link share)", expectedSignal: false, text: "check out this link lol https://example.com/funny-video"),
    CorpusItem(id: "confidential-1", category: "confidentiality", expectedSignal: false, text: "Don't mention this to anyone but I'm thinking about quitting"),
    CorpusItem(id: "confidential-2", category: "confidentiality", expectedSignal: false, text: "Keep this between us — can you cancel the reservation for Saturday"),
    CorpusItem(id: "confidential-3", category: "confidentiality", expectedSignal: false, text: "please don't repeat this to the team but the layoffs are next week"),
    CorpusItem(id: "confidential-4", category: "confidentiality", expectedSignal: false, text: "this stays between us — I might be leaving the company"),
    CorpusItem(
        id: "context-1", category: "context block, task in latest messages", expectedSignal: true,
        text: "[context]\nYou: did you see the game\nThem: yeah it was wild\n\n[latest messages]\nThem: anyway can you send me that doc"
    ),
    CorpusItem(
        id: "context-2", category: "context block, task only in context (must be ignored)", expectedSignal: false,
        text: "[context]\nThem: I need to buy a new laptop\nYou: nice, any model in mind\n\n[latest messages]\nThem: still deciding, probably next month"
    ),
    CorpusItem(
        id: "context-3", category: "context block, task in latest messages", expectedSignal: true,
        text: "[context]\nYou: how's the new apartment\nThem: pretty good so far\n\n[latest messages]\nThem: still need to hang the curtains though"
    ),
    CorpusItem(
        id: "context-4", category: "context block, no task anywhere", expectedSignal: false,
        text: "[context]\nThem: my flight got delayed\nYou: ugh that's rough\n\n[latest messages]\nThem: yeah just gonna grab dinner at the airport"
    ),
    CorpusItem(id: "edge-1", category: "edge case", expectedSignal: false, text: "ok"),
    CorpusItem(id: "edge-2", category: "edge case", expectedSignal: false, text: "idk maybe later"),
    CorpusItem(id: "task-research-1", category: "research/project", expectedSignal: true, text: "Should dig into why the staging deploy is slow, feels like a DB query issue"),
    CorpusItem(id: "task-research-2", category: "research/project", expectedSignal: true, text: "Want to try rewriting the onboarding flow in the new framework at some point"),
    CorpusItem(id: "task-research-3", category: "research/project", expectedSignal: true, text: "Look into whether we should migrate off the old auth library"),
    CorpusItem(id: "task-research-4", category: "research/project", expectedSignal: true, text: "Want to benchmark the new caching layer against the old one at some point"),
    CorpusItem(id: "task-fitness-1", category: "routine/fitness", expectedSignal: true, text: "Need to stretch more before runs, keep tweaking my hip"),
    CorpusItem(id: "task-fitness-2", category: "routine/fitness", expectedSignal: true, text: "Stretch goal: get back into a regular sleep schedule"),
    CorpusItem(id: "task-fitness-3", category: "routine/fitness", expectedSignal: true, text: "Sign up for the 10k in the spring"),
    // Batches (batched-extraction ticket 03): several lines judged as one,
    // sometimes against numbered open suggestions.
    CorpusItem(
        id: "batch-withdrawn", category: "batch, request withdrawn in the same batch", expectedSignal: false,
        text: "[latest messages]\nThem: hey\nThem: can you pick up the package from the front desk\nThem: never mind, my roommate got it"
    ),
    CorpusItem(
        id: "batch-update", category: "batch, UPDATE of an open suggestion", expectedSignal: true,
        text: "[open suggestions]\n1. Book a table for Friday\n\n[latest messages]\nThem: actually can we do Saturday instead\nThem: same place",
        check: { results in results.contains { if case .update(1, _, _) = $0 { return true } else { return false } } }
    ),
    CorpusItem(
        id: "batch-cancel-and-new", category: "batch, CANCEL plus a new task", expectedSignal: true,
        text: "[open suggestions]\n1. Buy printer ink\n\n[latest messages]\nThem: I picked up the ink already\nThem: can you return the library books tomorrow",
        check: { results in
            results.contains(.cancel(suggestion: 1)) && results.contains { if case .new = $0 { return true } else { return false } }
        }
    ),
    CorpusItem(
        id: "batch-new-beside-open", category: "batch, new task beside an unrelated open suggestion", expectedSignal: true,
        text: "[open suggestions]\n1. Call the plumber\n\n[latest messages]\nThem: can you also pick up dog food on the way home",
        check: { results in
            !results.isEmpty && results.allSatisfy { if case .new = $0 { return true } else { return false } }
        }
    ),
    CorpusItem(
        id: "batch-group-other", category: "batch, group request addressed to someone else", expectedSignal: false,
        text: "[context]\nParticipant A: who's bringing what on saturday\n\n[latest messages]\nParticipant B: Participant A can you bring the chips\nParticipant A: sure"
    ),
    // Group-Chat rule (CONTEXT.md, Chat): a request made of another
    // Participant or of the whole group is not the user's task unless
    // they take it on, in the same Batch or a later one.
    CorpusItem(
        id: "group-other-by-name", category: "group Chat, request to another Participant by name", expectedSignal: false,
        text: "[latest messages]\nParticipant A: Priya, can you book the table for Friday?\nParticipant A: somewhere near the station"
    ),
    CorpusItem(
        id: "group-whole-group", category: "group Chat, request to the whole group", expectedSignal: false,
        text: "[latest messages]\nParticipant A: heading over around 7\nParticipant A: can someone grab ice on the way?"
    ),
    CorpusItem(
        id: "group-taken-on-same-batch", category: "group Chat, whole-group request taken on in the same Batch", expectedSignal: true,
        text: "[latest messages]\nParticipant A: heading over around 7\nParticipant A: can someone grab ice on the way?\nYou: I'll get it"
    ),
    CorpusItem(
        id: "group-taken-on-later-batch", category: "group Chat, whole-group request taken on in a later Batch", expectedSignal: true,
        text: "[context]\nParticipant A: heading over around 7\nParticipant A: can someone grab ice on the way?\n\n[latest messages]\nYou: I'll get it"
    ),
    CorpusItem(
        id: "batch-filler", category: "batch, filler burst", expectedSignal: false,
        text: "[latest messages]\nThem: lol\nThem: did you see that\nThem: 😂😂\nYou: haha yes"
    ),
    CorpusItem(id: "batch-self-line", category: "batch, single Self-thread line", expectedSignal: true, text: "Renew the car registration this week"),
]

/// Matches `IntentExtractor.swift`'s own private `dueDateLinePrefix` — kept
/// as a separate constant here rather than shared across modules, since
/// `formatViolations` below checks it for its own model-comparison purposes,
/// not to parse production output.
private let dueTextLinePrefix = "DUE_TEXT:"

/// How many numbered lines the input's `[open suggestions]` block holds.
func openSuggestionCount(in input: String) -> Int {
    guard let range = input.range(of: "[open suggestions]\n") else { return 0 }
    return input[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        .prefix { !$0.isEmpty }.count
}

struct RunResult {
    let item: CorpusItem
    let rawOutput: String
    let parsedLabels: [String]
    let latencySeconds: Double
    let error: String?

    /// Every result the output parsed into, updates and cancels included.
    /// UPDATE or CANCEL lines naming a suggestion the input didn't list are
    /// dropped, as extraction itself does.
    var results: [ExtractionResult] {
        droppingUnknownSuggestions(parseExtractionResults(rawOutput), openSuggestionCount: openSuggestionCount(in: item.text))
    }
    var producedSignal: Bool { !results.isEmpty }
    /// `nil` when `item.expectedSignal` is `nil` (a real History row) —
    /// there's nothing to grade it against.
    var correctSignalDecision: Bool? {
        guard let expected = item.expectedSignal else { return nil }
        if let check = item.check { return error == nil && check(results) }
        return producedSignal == expected
    }

    /// Specific violations found, empty when clean. No literal stop-token
    /// string exists to check (see the report's Methodology Note) — this
    /// checks leaked chat-template tokens, leaked conversational filler
    /// (the spec's own "Here are your tasks:" example and its relatives),
    /// and DUE_TEXT-line well-formedness instead.
    var formatViolations: [String] {
        guard error == nil else { return ["call failed"] }
        var violations: [String] = []
        let leakedTokens = ["<|im_end|>", "<|im_start|>", "<|eot_id|>", "<|endoftext|>", "Output:", "Message:"]
        for token in leakedTokens where rawOutput.contains(token) {
            violations.append("leaked token \(token)")
        }
        let fillerPhrases = ["here are", "here's", "here is", "certainly", "i think", "let me know", "based on the message", "in summary", "sure!"]
        let lowered = rawOutput.lowercased()
        for phrase in fillerPhrases where lowered.contains(phrase) {
            violations.append("conversational filler (\"\(phrase)\")")
        }
        let lines = rawOutput.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let dueLines = lines.filter { $0.hasPrefix(dueTextLinePrefix) }
        // Each Label may carry its own DUE_TEXT line (batched-extraction
        // ticket 02), so every one is graded on its own.
        for dueLine in dueLines {
            if resolveDueDate(fromPhrase: String(dueLine.dropFirst(dueTextLinePrefix.count))) == nil {
                violations.append("unresolvable DUE_TEXT line (\"\(dueLine)\")")
            }
            // Checked independently of resolution success, not as an `else`:
            // `resolveDueDate` itself doesn't require quotes (a missing pair
            // isn't reason to distrust the phrase), but dropping them is a
            // real instruction-following miss worth tracking even on a line
            // that also fails to resolve — e.g. a vague taught example like
            // "sometime next week" is both unresolvable and a fair place to
            // check whether the model still wrapped it in quotes.
            if !hasQuotedValue(dueLine) {
                violations.append("DUE_TEXT missing quotes (\"\(dueLine)\")")
            }
        }
        if lines.contains("NONE") && !dueLines.isEmpty {
            violations.append("DUE_TEXT line paired with NONE")
        }
        return violations
    }

    /// Whether a `DUE_TEXT:` line follows the taught `DUE_TEXT: "<cue>"`
    /// shape exactly. Only used for `formatViolations`'s own model-comparison
    /// signal — production parsing (`resolveDueDate`) accepts the phrase
    /// with or without quotes.
    private func hasQuotedValue(_ dueLine: String) -> Bool {
        let value = dueLine.dropFirst(dueTextLinePrefix.count).trimmingCharacters(in: .whitespaces)
        return value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
    }

    /// Coarse, disclosed heuristic, not semantic judgment: what fraction
    /// of the label's own meaningful words (length > 2, letters/digits
    /// only) appear anywhere in the source text. Flagged as a possible
    /// hallucination only when a non-NONE label shares literally no words
    /// with its source — loose on purpose, to keep false positives low;
    /// a real "does this logically map back to the source" judgment needs
    /// a human (or a second model) reading the transcript, not a word-set
    /// intersection. See the report's Methodology Note.
    var possibleHallucination: Bool {
        guard error == nil, producedSignal else { return false }
        func normalizedWords(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let labelWords = normalizedWords(parsedLabels.joined(separator: " "))
        guard !labelWords.isEmpty else { return false }
        let sourceWords = normalizedWords(item.text)
        return labelWords.isDisjoint(with: sourceWords)
    }

    /// Whitespace-token estimate, not `llama.cpp`'s real subword count —
    /// getting the exact generated-token count would mean changing
    /// `LlamaCppIntentExtractor.extract(from:priority:)`'s return type to
    /// carry it, which felt like the wrong tradeoff for a one-off study
    /// (see the report's Methodology Note). ~1.3 tokens/word is a common
    /// rough ratio for English subword tokenizers; treat this as an
    /// order-of-magnitude figure, not a measured one.
    var estimatedGeneratedTokens: Int {
        let words = rawOutput.split { $0.isWhitespace }.count
        return max(1, Int(Double(words) * 1.3))
    }

    var msPerEstimatedToken: Double {
        (latencySeconds * 1000) / Double(estimatedGeneratedTokens)
    }
}

struct ModelResult {
    let displayName: String
    let modelPath: String
    var runs: [RunResult] = []
    var loadSeconds: Double = 0
    var loadError: String?
    var residentMemoryBeforeLoadMB: Double = 0
    var residentMemoryAfterLoadMB: Double = 0

    /// Synthetic cases only: Correction cases have their own section, and
    /// mixing them in would make the headline numbers incomparable with
    /// runs from before Corrections were scored.
    var scoredRuns: [RunResult] { runs.filter { $0.item.source == .synthetic } }
    var accuracy: Double {
        guard !scoredRuns.isEmpty else { return 0 }
        return Double(scoredRuns.filter { $0.correctSignalDecision == true }.count) / Double(scoredRuns.count)
    }
    var zeroSignalItems: [RunResult] { scoredRuns.filter { $0.item.expectedSignal == false } }
    var zeroSignalAccuracy: Double {
        guard !zeroSignalItems.isEmpty else { return 0 }
        return Double(zeroSignalItems.filter { $0.correctSignalDecision == true }.count) / Double(zeroSignalItems.count)
    }
    var formatAdherenceRate: Double {
        guard !runs.isEmpty else { return 0 }
        return Double(runs.filter(\.formatViolations.isEmpty).count) / Double(runs.count)
    }
    var possibleHallucinationCount: Int { runs.filter(\.possibleHallucination).count }
    var averageLatency: Double {
        guard !runs.isEmpty else { return 0 }
        return runs.map(\.latencySeconds).reduce(0, +) / Double(runs.count)
    }
    var averageMsPerEstimatedToken: Double {
        guard !runs.isEmpty else { return 0 }
        return runs.map(\.msPerEstimatedToken).reduce(0, +) / Double(runs.count)
    }
    var residentMemoryDeltaMB: Double { residentMemoryAfterLoadMB - residentMemoryBeforeLoadMB }
}

func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
func seconds(_ value: Double) -> String { String(format: "%.2fs", value) }
func mb(_ value: Double) -> String { String(format: "%.0f MB", value) }

/// Resident set size of this process, via the standard Mach `task_info`
/// API — no AppKit involved, works in a plain command-line tool. GPU
/// utilization has no equivalent standard-framework API (Instruments/
/// private `IOKit` calls could get closer, but that's a different scope
/// of tool); the spec's own fallback ("otherwise focus strictly on time")
/// is what this falls back to for GPU specifically, while still reporting
/// process memory since that much is accessible.
func currentResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / 1024.0 / 1024.0
}

@MainActor
func run() async {
    // Redirected stdout is fully buffered by default, and `_exit(0)` below
    // (needed to sidestep llama.framework's exit-time crash) skips the
    // flush a normal `exit()` would do — without this, every `print()`
    // below silently vanishes when stdout isn't a terminal. Confirmed by
    // hand in the previous run of this script: a complete report, an
    // empty log file, for exactly this reason.
    setvbuf(stdout, nil, _IOLBF, 0)

    print("Model Evaluator: reading History for a real-world spot check...")
    let historyStore = SQLiteHistoryStore(path: SQLiteHistoryStore.defaultPath(bundleIdentifier: bundleIdentifier))
    // Read-only: this script never calls historyStore.record(...) — a
    // benchmark run has no business writing synthetic rows into the same
    // database the real app's History tab reads from. Starred rows first,
    // per this round's spec — falls back to the latest extraction rows if
    // none are starred.
    let realRows = historyStore.evaluationRows(limit: 50)
    if realRows.isEmpty {
        print("  No real History rows found.")
    } else {
        print("  Found \(realRows.count) real row(s) (starred-first); included as an unscored spot check.")
    }
    let realItems = realRows.map { CorpusItem(realHistoryID: $0.id, text: $0.sourceRawText) }

    // Every stored Correction with an answer the model should give
    // becomes a scored case (extraction-accuracy-baseline ticket 03).
    // Read-only, like the History read above.
    print("Model Evaluator: reading Corrections...")
    let correctionStore = SQLiteCorrectionStore(path: SQLiteCorrectionStore.defaultPath(bundleIdentifier: bundleIdentifier))
    let storedCorrections = [CorrectionType.falsePositive, .missedTask, .falseNegative, .fieldCorrection]
        .flatMap { correctionStore.corrections(ofType: $0, createdAfter: nil, limit: 10_000) }
    let correctionCases = storedCorrections.compactMap(correctionCase(from:))
    let correctionItems = correctionCases.enumerated().map { CorpusItem(correctionCase: $0.element, number: $0.offset + 1) }
    if storedCorrections.isEmpty {
        print("  No Corrections stored.")
    } else {
        print("  Found \(storedCorrections.count) Correction(s): \(correctionItems.count) scored, \(storedCorrections.count - correctionItems.count) skipped (\"This was work\" and field corrections carry no answer for the model).")
    }

    let allItems = syntheticCorpus + correctionItems + realItems
    print("  Full corpus: \(syntheticCorpus.count) synthetic + \(correctionItems.count) Correction + \(realItems.count) real History = \(allItems.count) items.")

    var modelResults: [ModelResult] = []

    for entry in ModelCatalog.entries {
        let path = entry.localPath(bundleIdentifier: bundleIdentifier)
        print("\n=== \(entry.displayName) (\(entry.quantization)) ===")
        guard FileManager.default.fileExists(atPath: path) else {
            print("  Not downloaded at \(path) — skipping.")
            modelResults.append(ModelResult(displayName: entry.displayName, modelPath: path, loadError: "not downloaded"))
            continue
        }

        var result = ModelResult(displayName: entry.displayName, modelPath: path)
        result.residentMemoryBeforeLoadMB = currentResidentMemoryMB()
        let loadStart = Date()
        let extractor: LlamaCppIntentExtractor
        do {
            extractor = try LlamaCppIntentExtractor(modelPath: path)
        } catch {
            print("  Load failed: \(error)")
            result.loadError = "\(error)"
            modelResults.append(result)
            continue
        }
        result.loadSeconds = Date().timeIntervalSince(loadStart)
        result.residentMemoryAfterLoadMB = currentResidentMemoryMB()
        print("  Loaded in \(seconds(result.loadSeconds)), resident memory +\(mb(result.residentMemoryDeltaMB))")

        for item in allItems {
            let callStart = Date()
            do {
                let raw = try await extractor.extract(from: item.text, priority: .utility)
                let latency = Date().timeIntervalSince(callStart)
                let labels = parseExtractionOutput(raw)
                result.runs.append(RunResult(item: item, rawOutput: raw, parsedLabels: labels, latencySeconds: latency, error: nil))
                print("  [\(item.id)] \(seconds(latency)) -> \(labels.isEmpty ? "NONE" : labels.joined(separator: " | "))")
            } catch {
                let latency = Date().timeIntervalSince(callStart)
                result.runs.append(RunResult(item: item, rawOutput: "", parsedLabels: [], latencySeconds: latency, error: "\(error)"))
                print("  [\(item.id)] ERROR: \(error)")
            }
        }

        modelResults.append(result)
        // `extractor` goes out of scope at the end of this iteration,
        // freeing its Metal-resident model/context before the next one
        // loads (the spec's "cleanly tear down the context... do not
        // hot-swap" requirement) — running three ~2-2.5GB models loaded
        // simultaneously was avoided on purpose, not because it was tried
        // and failed.
    }

    writeReport(
        modelResults: modelResults, syntheticItemCount: syntheticCorpus.count, realItemCount: realItems.count,
        correctionItemCount: correctionItems.count
    )
    writeCSV(modelResults: modelResults, allItems: allItems)
    print("\nWrote model_evaluation_report.md and Desktop/FirstFocus_Model_Evaluation.csv")

    // llama.framework's known exit-time crash (documented in main.swift's
    // AppDelegate, FirstFocus target): normal process exit runs C++ static
    // destructors, one of which aborts inside ggml_metal_device_free.
    // `_exit` sidesteps that the same way the real app does, once there is
    // nothing left to do but leave.
    _exit(0)
}

/// `--compare-prefix-reuse` (ADR 0037): runs the synthetic corpus through
/// the default model twice, once recomputing the system turn before every
/// call and once reusing it, and reports any disagreement in task-versus-
/// NONE or in the Labels, plus average latency for each. Cached reuse can
/// shift floating-point results in the last digits; this is how to see
/// whether that ever changes an output.
func comparePrefixReuse() async {
    let path = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: bundleIdentifier)
    print("Prefix reuse comparison against \((path as NSString).lastPathComponent)")
    let extractor: LlamaCppIntentExtractor
    do {
        extractor = try LlamaCppIntentExtractor(modelPath: path)
    } catch {
        print("  Load failed: \(error)")
        _exit(1)
    }

    func pass(reusing: Bool) async -> (outputs: [String: [String]], seconds: [Double]) {
        var outputs: [String: [String]] = [:]
        var latencies: [Double] = []
        // One untimed call first, so the reused pass isn't charged for
        // computing the prefix the first time.
        extractor.invalidateCachedPrefix()
        _ = try? await extractor.extract(from: "warm up", priority: .utility)
        for item in syntheticCorpus {
            if !reusing { extractor.invalidateCachedPrefix() }
            let start = Date()
            let raw = (try? await extractor.extract(from: item.text, priority: .utility)) ?? "ERROR"
            latencies.append(Date().timeIntervalSince(start))
            outputs[item.id] = parseExtractionOutput(raw)
        }
        return (outputs, latencies)
    }

    let fresh = await pass(reusing: false)
    let reused = await pass(reusing: true)
    // ADR 0038: a Rule proposal swaps a different system turn into the
    // cache. The first extraction after it must recompute the extraction
    // prefix and answer exactly as before.
    _ = try? await extractor.generateText(
        system: ruleProposalSystemPrompt, user: "Mistake 1:\nParticipant A: your parcel is out for delivery",
        maxTokens: ruleProposalMaxTokens, priority: .utility
    )
    var afterProposal: [String: [String]] = [:]
    for item in syntheticCorpus.prefix(10) {
        let raw = (try? await extractor.extract(from: item.text, priority: .utility)) ?? "ERROR"
        afterProposal[item.id] = parseExtractionOutput(raw)
    }
    let proposalMismatches = syntheticCorpus.prefix(10).filter { afterProposal[$0.id] != fresh.outputs[$0.id] }.map(\.id)
    var taskDisagreements: [String] = []
    var labelDisagreements: [String] = []
    for item in syntheticCorpus {
        let a = fresh.outputs[item.id] ?? []
        let b = reused.outputs[item.id] ?? []
        if a.isEmpty != b.isEmpty {
            taskDisagreements.append("\(item.id): fresh=\(a) reused=\(b)")
        } else if a != b {
            labelDisagreements.append("\(item.id): fresh=\(a) reused=\(b)")
        }
    }
    let average = { (values: [Double]) in values.reduce(0, +) / Double(max(values.count, 1)) }
    print("  Items: \(syntheticCorpus.count)")
    print("  Avg latency, recomputing the prefix every call: \(seconds(average(fresh.seconds)))")
    print("  Avg latency, reusing the cached prefix:         \(seconds(average(reused.seconds)))")
    print("  Task-vs-NONE disagreements: \(taskDisagreements.count)")
    taskDisagreements.forEach { print("    \($0)") }
    print("  Label disagreements: \(labelDisagreements.count)")
    labelDisagreements.forEach { print("    \($0)") }
    print("  After a Rule proposal, first 10 items differing from the fresh run: \(proposalMismatches.count) \(proposalMismatches)")
    // `_exit` skips stdio's buffers, which hold everything above when
    // stdout is a pipe or file rather than a terminal.
    fflush(stdout)
    _exit(0)
}

/// The fixed system turn's size under the default model's own tokenizer,
/// for the ADR 0037 budget (batched-extraction ticket 03).
func measurePrompt() {
    let path = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: bundleIdentifier)
    guard let extractor = try? LlamaCppIntentExtractor(modelPath: path) else {
        print("  Load failed")
        _exit(1)
    }
    print("System turn: \(extractor.estimatedTokenCount(for: LlamaCppIntentExtractor.systemTurn())) tokens")
    print("Left for Corrections, open suggestions, context and the Batch: \(extractor.maxPromptTokens) tokens")
    fflush(stdout)
    _exit(0)
}

/// Raw output from the default model for the items whose id starts with
/// `prefix`, for iterating on the prompt without a full three-model run.
func rawOutputs(prefix: String) async {
    let path = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: bundleIdentifier)
    guard let extractor = try? LlamaCppIntentExtractor(modelPath: path) else {
        print("  Load failed")
        _exit(1)
    }
    for item in syntheticCorpus where item.id.hasPrefix(prefix) {
        let raw = (try? await extractor.extract(from: item.text, priority: .utility)) ?? "ERROR"
        print("[\(item.id)]\n\(raw)\n")
    }
    fflush(stdout)
    _exit(0)
}

/// The synthetic corpus against the default model only, printing each
/// miss with its raw output and the overall score: a fast check while
/// tuning the prompt, before a full three-model run.
func quickScore() async {
    let path = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: bundleIdentifier)
    guard let extractor = try? LlamaCppIntentExtractor(modelPath: path) else {
        print("  Load failed")
        _exit(1)
    }
    var correct = 0
    for item in syntheticCorpus {
        let raw = (try? await extractor.extract(from: item.text, priority: .utility)) ?? "ERROR"
        let run = RunResult(item: item, rawOutput: raw, parsedLabels: parseExtractionOutput(raw), latencySeconds: 0, error: nil)
        if run.correctSignalDecision == true {
            correct += 1
        } else {
            print("MISS [\(item.id)] \(raw.replacingOccurrences(of: "\n", with: " / "))")
        }
    }
    print("Score: \(correct)/\(syntheticCorpus.count)")
    fflush(stdout)
    _exit(0)
}

if CommandLine.arguments.contains("--quick") {
    await quickScore()
} else if let index = CommandLine.arguments.firstIndex(of: "--raw"), index + 1 < CommandLine.arguments.count {
    await rawOutputs(prefix: CommandLine.arguments[index + 1])
} else if CommandLine.arguments.contains("--measure-prompt") {
    measurePrompt()
} else if CommandLine.arguments.contains("--compare-prefix-reuse") {
    await comparePrefixReuse()
} else {
    await run()
}
