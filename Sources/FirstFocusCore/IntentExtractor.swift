import Foundation

/// The on-device model boundary Extraction calls once per Messages
/// message. Detection and rewriting happen in one call: the model decides
/// whether the text names work at all, and if so rewrites it as one or more
/// short imperative Labels — never a conditional two-step.
public protocol IntentExtractor: Sendable {
    /// Runs the model over `text`, returning its raw delimited output
    /// unparsed — see `parseExtractionOutput`. `priority` governs the QoS
    /// the actual model call runs at: automated intake (the chat.db poll,
    /// the foreground refresh, the first-run backfill) passes `.background`
    /// so it never contends with the UI, while the user-initiated "Re-run
    /// Extraction" action passes `.utility` — slower than the default, but
    /// not silently deprioritized behind background work the user isn't
    /// watching a progress readout for.
    func extract(from text: String, priority: TaskPriority) async throws -> String

    /// What Settings' footer shows and what a `HistoryEntry` records as
    /// `modelUsed` — a stable identifier for whichever model this instance
    /// actually loaded, not necessarily one of `ModelCatalog`'s entries.
    var modelDisplayName: String { get }

    /// A rough token count for `text` under this model's own tokenizer.
    /// `Extraction.swift`'s correction-budget trimming (ADR 0031, corrections
    /// spec ticket 04) uses this only to decide how many Correction examples
    /// fit before calling `extract(from:)` — never to guarantee an exact
    /// fit. The real, authoritative check still happens inside `extract(from:)`
    /// itself, which fails closed if the composed prompt is still too long.
    func estimatedTokenCount(for text: String) -> Int

    /// The most input tokens this instance can accept alongside its own
    /// reserved generation headroom — `Extraction.swift` shrinks the
    /// Correction count until `estimatedTokenCount(for:)` fits under this,
    /// or until there are none left to drop.
    var maxPromptTokens: Int { get }

    /// Approved Rules (ADR 0038), in order. Replaces whatever was set
    /// before; takes effect on the next call.
    func setRules(_ rules: [String])
}

public extension IntentExtractor {
    /// An extractor with no prompt to put Rules in ignores them.
    func setRules(_ rules: [String]) {}
}

/// One line of the model's answer (ADR 0040): a new Label, an update that
/// Supersedes open suggestion `suggestion` (numbered from 1 as the prompt
/// listed them) with a new Label, or a cancel that Supersedes it with none. `dueText` is the raw
/// `DUE_TEXT` phrase copied from the line under it, quotes and all, for
/// `resolveDueDate` to turn into a day.
public enum ExtractionResult: Equatable, Sendable {
    case new(label: String, dueText: String?)
    case update(suggestion: Int, label: String, dueText: String?)
    case cancel(suggestion: Int)

    /// The Label a Signal would carry, or `nil` for a cancel.
    public var label: String? {
        switch self {
        case .new(let label, _), .update(_, let label, _): return label
        case .cancel: return nil
        }
    }

    public var dueText: String? {
        switch self {
        case .new(_, let dueText), .update(_, _, let dueText): return dueText
        case .cancel: return nil
        }
    }
}

/// Parses `IntentExtractor`'s raw output into results, one per line, or a
/// literal `NONE` line for nothing found. Deliberately not JSON — JSON
/// invites near-valid output that relocates the parsing problem rather
/// than solving it. `NONE` appearing alongside other lines is inconsistent
/// output, not a partial result, so it fails closed to no results the same
/// as any other malformed output; nothing here is ever promoted on a guess.
///
/// A `DUE_TEXT` line belongs to the result directly above it. One with no
/// result above it, one under a cancel, and one under a line that was
/// dropped as malformed are all ignored. Two under the same result are
/// inconsistent, so that result gets none. `UPDATE <n>: <label>` and
/// `CANCEL <n>` are matched in uppercase only, so a Label that happens to
/// start with the word "Update" or "Cancel" stays a new Label; one with a
/// missing, non-numeric or zero number, or an empty Label, is dropped.
/// The model sometimes writes "None" or "None." for NONE. Taken literally,
/// that became a Suggestion titled "None".
private func isNoneLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .punctuationCharacters).uppercased() == "NONE"
}

public func parseExtractionResults(_ raw: String) -> [ExtractionResult] {
    let lines = raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .map(droppingLeakedOutputPrefix)
        .filter { !$0.isEmpty }

    guard !lines.isEmpty, !lines.contains(where: isNoneLine) else {
        return []
    }

    var results: [ExtractionResult] = []
    // Due lines seen under the most recent line, or `nil` when that line
    // can't take one (nothing above yet, a cancel, or a dropped line).
    var dueLinesForLast: [String]?
    func settleLast() {
        guard let dueLines = dueLinesForLast, let last = results.popLast() else { return }
        let dueText = dueLines.count == 1 ? dueLines[0] : nil
        switch last {
        case .new(let label, _): results.append(.new(label: label, dueText: dueText))
        case .update(let n, let label, _): results.append(.update(suggestion: n, label: label, dueText: dueText))
        case .cancel: results.append(last)
        }
    }

    for line in lines {
        if line.hasPrefix(dueDateLinePrefix) {
            dueLinesForLast?.append(line.dropFirst(dueDateLinePrefix.count).trimmingCharacters(in: .whitespaces))
            continue
        }
        settleLast()
        switch parseResultLine(line) {
        case .some(let result):
            results.append(result)
            if case .cancel = result { dueLinesForLast = nil } else { dueLinesForLast = [] }
        case .none:
            dueLinesForLast = nil
        }
    }
    settleLast()
    return results
}

/// Drops any UPDATE or CANCEL naming a suggestion the prompt didn't list
/// (ADR 0040: a model mistake must never touch the wrong Suggestion).
/// `openSuggestionCount` is how many were listed, numbered from 1.
public func droppingUnknownSuggestions(_ results: [ExtractionResult], openSuggestionCount: Int) -> [ExtractionResult] {
    results.filter { result in
        switch result {
        case .new: return true
        case .update(let n, _, _), .cancel(let n): return n >= 1 && n <= openSuggestionCount
        }
    }
}

/// Drops any new Label that repeats a Suggestion the prompt listed, compared
/// without case or outer spaces. The prompt already forbids this, but a
/// small model still does it, and each repeat would land in the Inbox as a
/// second copy. An UPDATE with the same Label stays: it may carry a new
/// due date.
public func droppingRepeatedSuggestions(_ results: [ExtractionResult], openLabels: [String]) -> [ExtractionResult] {
    let key = { (label: String) in label.trimmingCharacters(in: .whitespaces).lowercased() }
    let open = Set(openLabels.map(key))
    return results.filter { result in
        guard case .new(let label, _) = result else { return true }
        return !open.contains(key(label))
    }
}

/// The Labels of new results only: what extraction turns into Signals
/// until updates are acted on (ticket 07), and what History counts.
public func parseExtractionOutput(_ raw: String) -> [String] {
    parseExtractionResults(raw).compactMap { result in
        if case .new(let label, _) = result { return label }
        return nil
    }
}

/// Whether `line` opens with `keyword` as a word of its own, so "UPDATED
/// resume" is still a new Label but "UPDATE x: …" is a malformed update.
private func isKeyword(_ keyword: String, openingLine line: String) -> Bool {
    guard line.hasPrefix(keyword) else { return false }
    let rest = line.dropFirst(keyword.count)
    return rest.isEmpty || rest.first == " " || rest.first == ":"
}

private func parseResultLine(_ line: String) -> ExtractionResult? {
    if isKeyword("UPDATE", openingLine: line) {
        guard let match = line.wholeMatch(of: /UPDATE\s+(\d+)\s*:\s*(.+)/),
              let n = Int(match.1), n > 0 else { return nil }
        return .update(suggestion: n, label: String(match.2).trimmingCharacters(in: .whitespaces), dueText: nil)
    }
    if isKeyword("CANCEL", openingLine: line) {
        guard let match = line.wholeMatch(of: /CANCEL\s+(\d+)/), let n = Int(match.1), n > 0 else { return nil }
        return .cancel(suggestion: n)
    }
    return .new(label: line, dueText: nil)
}

/// The prompt's worked examples are laid out as `Message:` / `Output:`
/// pairs, and Qwen3-4B sometimes copies the `Output:` label into its own
/// answer (seen in the 2026-09-23 evaluator run on real History rows). The
/// label is never part of a task, so it's removed wherever it opens a line.
/// Only the label with its colon: a Label that starts with the word
/// "Output" is left alone.
private func droppingLeakedOutputPrefix(_ line: String) -> String {
    guard line.hasPrefix("Output:") else { return line }
    return String(line.dropFirst("Output:".count)).trimmingCharacters(in: .whitespaces)
}

/// Resolves a literal temporal phrase (`DUE_TEXT`'s extracted text, e.g.
/// "next Tuesday" or "in the spring", copied by the model under the Label
/// it applies to; see `parseExtractionResults`) to a calendar day using Apple's
/// `NSDataDetector`, deterministically — no LLM math, no guessing. `public`
/// and free of any dependency on `IntentExtractor` so it's independently
/// testable (see `IntentExtractorTests`): NSDataDetector always resolves
/// relative to the live wall clock and Foundation exposes no way to
/// override that, so those tests assert structural properties (weekday,
/// day offset from today) rather than one pinned `Date`.
///
/// Tolerant of the surrounding quotes the prompt teaches
/// (`DUE_TEXT: "next Tuesday"`) but doesn't require them — this model's
/// format adherence is imperfect enough that a missing pair of quotes
/// isn't a sign the phrase itself is untrustworthy. `ModelEvaluator` grades
/// quote adherence separately, as a model-comparison signal, not as a
/// condition for resolving.
///
/// A phrase NSDataDetector can't parse at all (too abstract, like "someday"
/// or "eventually") returns `nil` here rather than a guess, matching this
/// file's fail-closed posture everywhere else. When it can, this takes the
/// first match found even if it only covers part of the phrase (e.g. "EOD
/// Friday" matches just "Friday") — a partial match still names a real
/// date the message pointed at.
///
/// Always collapses to the start of the resolved day: NSDataDetector
/// defaults a day-only phrase like "tomorrow" to noon, which is an
/// artifact of the API, not something the message actually said. Discarding
/// it keeps `dueAt`'s existing "never carries a time of day" contract,
/// at the cost of losing a real stated time like "by 5pm" too.
public func resolveDueDate(fromPhrase phrase: String) -> Date? {
    let unquoted = strippingSurroundingQuotes(phrase.trimmingCharacters(in: .whitespaces))
    guard !unquoted.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
        return nil
    }
    let range = NSRange(unquoted.startIndex..<unquoted.endIndex, in: unquoted)
    guard let date = detector.matches(in: unquoted, options: [], range: range).first?.date else {
        return nil
    }
    return Calendar(identifier: .gregorian).startOfDay(for: date)
}

private func strippingSurroundingQuotes(_ text: String) -> String {
    guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
        return text
    }
    return String(text.dropFirst().dropLast())
}

private let dueDateLinePrefix = "DUE_TEXT:"

/// The `Today's date is` line's format: a calendar date only, no time of
/// day. Fresh per call rather than a shared `static let`: `DateFormatter`
/// isn't documented safe for concurrent use, matching `SQLiteSignalStore`'s
/// own `dateFormatter` posture. Not `private`, so `LlamaCppIntentExtractor`'s
/// system prompt can share it instead of keeping its own copy. No longer
/// shared with due-date parsing — `resolveDueDate` resolves `DUE_TEXT`
/// phrases through `NSDataDetector`, not this formatter.
public func plainDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter
}
