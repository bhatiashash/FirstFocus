import Foundation

/// Ticket 01: the messages Extraction shows the model alongside a
/// candidate, so it judges "also grab bread" against "can you grab milk"
/// rather than in isolation. Same-chat, strictly before the target, newest
/// `limit` of them, oldest-first — the order a reader would actually see
/// the conversation in.
public func recentContext(for target: ChatMessage, in messages: [ChatMessage], limit: Int = 6) -> [ChatMessage] {
    messages
        .filter { $0.chatId == target.chatId && $0.id != target.id && $0.createdAt <= target.createdAt }
        .sorted { $0.createdAt < $1.createdAt }
        .suffix(limit)
        .map { $0 }
}

/// How many of a Correction's `[latest messages]` lines its example keeps
/// (ADR 0039): a whole long Batch as an example would crowd out the Batch
/// being judged.
public let correctionExampleBatchLines = 6

/// A Correction's input with the one-message format's `[message to judge]`
/// block renamed to the Batch format's `[latest messages]` (ADR 0039), so
/// a Correction recorded before Batches still reads as the prompt expects.
public func inBatchFormat(_ correctionInput: String) -> String {
    correctionInput.replacingOccurrences(of: "[message to judge]", with: "[latest messages]")
}

/// What a Correction keeps as its worked example (ADR 0031, amended
/// 2026-09-26): the prompt's own `[context]` and `[latest messages]`
/// blocks, and nothing the composer put ahead of them. A prompt carries
/// its earlier examples and open Suggestions too, and keeping those made
/// every later example nest the ones before it. Both kept blocks already
/// use Participant Labels. A bare Self-thread note, or anything else with
/// no `[latest messages]` block, is kept whole.
///
/// `[latest messages]` is always the prompt's last block, so its last
/// marker is the prompt's own. A `[context]` block counts only when
/// nothing but its own lines sits between it and that marker: an earlier
/// example's `[context]` is always followed by that example's
/// `Output:` line.
public func exampleInput(fromPrompt prompt: String) -> String {
    let prompt = inBatchFormat(prompt)
    let latestMarker = "[latest messages]\n"
    guard let latest = prompt.range(of: latestMarker, options: .backwards) else { return prompt }
    let batchBlock = String(prompt[latest.lowerBound...])
    let beforeLatest = prompt[..<latest.lowerBound]
    guard
        beforeLatest.hasSuffix("\n\n"),
        let context = beforeLatest.range(of: "[context]\n", options: .backwards),
        context.lowerBound == beforeLatest.startIndex || beforeLatest[..<context.lowerBound].hasSuffix("\n\n")
    else { return batchBlock }
    let contextBlock = beforeLatest[context.lowerBound...]
    guard !contextBlock.contains("\nOutput: "), !contextBlock.contains("\n\n[") else { return batchBlock }
    return contextBlock + batchBlock
}

/// A Correction's input with its `[latest messages]` block cut to its last
/// `correctionExampleBatchLines` lines; anything before the block is kept.
private func trimmedToLastBatchLines(_ input: String) -> String {
    let marker = "[latest messages]\n"
    guard let range = input.range(of: marker, options: .backwards) else { return input }
    let lines = input[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > correctionExampleBatchLines else { return input }
    return input[..<range.upperBound] + lines.suffix(correctionExampleBatchLines).joined(separator: "\n")
}

/// The context for a Batch: the `limit` messages in its Chat just before
/// its first message, never one of its own members.
public func recentContext(for batch: MessageBatch, in messages: [ChatMessage], limit: Int = 6) -> [ChatMessage] {
    let members = Set(batch.memberIds)
    return recentContext(for: batch.messages[0], in: messages.filter { !members.contains($0.id) }, limit: limit)
}

/// Composes the user turn's blocks into the single string
/// `IntentExtractor.extract(from:)` takes (batched-extraction ticket 03):
/// `[corrections]`, `[open suggestions]`, `[context]`, then
/// `[latest messages]`, each only when it has content. The one exception
/// is a Self-thread note with nothing else to show, which is sent as the
/// bare line, the way the prompt describes a note to yourself. Anything
/// else, including a lone message from someone else, goes under
/// `[latest messages]` with its sender, so the model always knows who
/// said it.
///
/// `senderLabel` names a non-you message's sender — the literal `"Them"`
/// by default. `Extraction.swift`'s `judge` passes one backed by
/// `ParticipantLabelStore` (ADR 0033), so a group Chat's several senders
/// each get a distinct, stable label instead of collapsing into one.
///
/// `corrections` (ADR 0031) render as `Message:`/`Output:` pairs — the
/// same shape as `defaultExtractionPrompt`'s own EXAMPLES, so the model
/// reads a flagged mistake the same way it reads a worked example. One
/// recorded before this format existed still says `[message to judge]`,
/// and is shown with the current block name instead.
///
/// `openSuggestions` are the Labels of this Chat's undecided Suggestions,
/// numbered from 1 in the order given (ADR 0040), which is how an
/// `UPDATE <n>` or `CANCEL <n>` in the answer refers back to them.
public func formatForExtraction(
    target: ChatMessage, context: [ChatMessage], corrections: [Correction] = [], openSuggestions: [String] = [],
    senderLabel: (ChatMessage) -> String = { _ in "Them" }
) -> String {
    formatForExtraction(
        batch: [target], context: context, corrections: corrections, openSuggestions: openSuggestions, senderLabel: senderLabel
    )
}

/// The same, for a Batch (ADR 0039): every message in `batch`, oldest
/// first, goes under `[latest messages]`.
public func formatForExtraction(
    batch: [ChatMessage], context: [ChatMessage], corrections: [Correction] = [], openSuggestions: [String] = [],
    senderLabel: (ChatMessage) -> String = { _ in "Them" }
) -> String {
    if batch.count == 1, batch[0].isSelfThread, context.isEmpty, corrections.isEmpty, openSuggestions.isEmpty {
        return batch[0].text
    }
    func line(_ message: ChatMessage) -> String {
        "\(message.isFromMe ? "You" : senderLabel(message)): \(message.text)"
    }
    var sections: [String] = []
    if !corrections.isEmpty {
        // A bare message is quoted on one line; a block-bearing input is
        // shown unquoted across several lines, exactly as it was composed.
        let rendered = corrections
            .map { correction -> String in
                let input = trimmedToLastBatchLines(inBatchFormat(correction.inputText))
                let messageLine = input.contains("\n") ? "Message:\n\(input)" : "Message: \"\(input)\""
                return "\(messageLine)\nOutput: \(correction.correctedOutput)"
            }
            .joined(separator: "\n\n")
        sections.append("[corrections]\n\(rendered)")
    }
    if !openSuggestions.isEmpty {
        let numbered = openSuggestions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        sections.append("[open suggestions]\n\(numbered)")
    }
    if !context.isEmpty {
        sections.append("[context]\n\(context.map(line).joined(separator: "\n"))")
    }
    sections.append("[latest messages]\n\(batch.map(line).joined(separator: "\n"))")
    return sections.joined(separator: "\n\n")
}
