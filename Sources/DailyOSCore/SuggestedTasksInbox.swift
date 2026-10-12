import Foundation

/// Whether `signal` belongs in the Suggested Tasks Inbox rather than the
/// Focus/Later list: an inferred Signal nobody has approved, checked
/// off, or dismissed yet. See CONTEXT.md: Provenance.
public func isSuggestion(_ signal: Signal) -> Bool {
    signal.provenance == .inferred && signal.state == .open
}

/// The Suggested Tasks Inbox (Focus Mode v2): a derived view over Signals
/// already in the store, not a separate data structure — there is no
/// stored "has items" flag, so an empty result is exactly what an empty
/// inbox looks like. Ordered by recency, newest first, so the newest
/// suggestions are easiest to find.
public func suggestedTasksInbox(_ signals: [Signal]) -> [Signal] {
    signals.filter(isSuggestion).sorted { $0.createdAt > $1.createdAt }
}

/// Which way an arrow key moves keyboard focus through the Inbox.
public enum InboxMove: Sendable {
    case up, down
}

/// Keyboard triage (batched-extraction ticket 08): where focus lands after
/// an arrow key, given the Inbox's ids in display order. With nothing
/// focused, or a focused id that has since left the Inbox, Down starts at
/// the top and Up at the bottom. Focus stops at either end rather than
/// wrapping.
public func inboxFocus(moving move: InboxMove, from focused: String?, in ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let focused, let index = ids.firstIndex(of: focused) else {
        return move == .down ? ids.first : ids.last
    }
    switch move {
    case .down: return ids[min(index + 1, ids.count - 1)]
    case .up: return ids[max(index - 1, 0)]
    }
}

/// Where focus goes once the row `id` is Approved or Dismissed and leaves
/// the Inbox: the row after it, or the one before it when it was last, so
/// a run of keystrokes can clear the whole Inbox.
public func inboxFocus(afterActingOn id: String, in ids: [String]) -> String? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    if index + 1 < ids.count { return ids[index + 1] }
    return index > 0 ? ids[index - 1] : nil
}

/// What the popover on a Suggestion shows (batched-extraction ticket 09):
/// the messages the model saw before the Batch, then the Batch itself,
/// both one line per message with display names. Read only from fields
/// stored on the Signal, so it still works once those messages are older
/// than the Messages lookback. A Signal from before batching has no
/// stored context and shows only its original wording.
public struct SuggestionPreview: Equatable, Sendable {
    public let contextLines: [String]
    public let batchLines: [String]
}

public func suggestionPreview(for signal: Signal) -> SuggestionPreview {
    func lines(_ text: String?) -> [String] {
        text.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
    }
    return SuggestionPreview(contextLines: lines(signal.contextText), batchLines: lines(signal.originalText))
}
