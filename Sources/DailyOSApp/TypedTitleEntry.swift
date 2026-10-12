import DailyOSCore
import Foundation

/// Typing a reminder title into `+`, Rename or Quick Capture (ADR 0030
/// amendment): the text, the badge a date phrase in it shows, and what ⏎
/// saves. The three views bind to this and only lay it out
/// (typed-title-entry).
///
/// Reads `now` each time it parses, never the moment the Ranked List was
/// ranked: that moment stays on yesterday until the day change, and
/// "tomorrow" would parse a day early.
public struct TypedTitleEntry {
    /// The date a typed phrase will set, shown beside the field before ⏎.
    public struct Badge: Equatable {
        public let dueAt: Date
        public let text: String
    }

    public private(set) var text: String
    /// Phrases whose badge was cancelled in this entry, kept as words.
    private var cancelled: Set<String> = []
    private let now: () -> Date

    /// Starting from an existing title (Rename), every date phrase
    /// already in it counts as words, so saving it unchanged never moves
    /// its due date.
    public init(text: String = "", now: @escaping () -> Date = Date.init) {
        self.text = text
        self.now = now
        while let parsed = parse(text, today: now()) {
            cancel(parsed)
        }
    }

    public var badge: Badge? {
        let today = now()
        guard let parsed = parse(text, today: today) else { return nil }
        return Badge(dueAt: parsed.dueAt, text: typedDueDateBadgeText(dueAt: parsed.dueAt, today: today))
    }

    /// The field's text changed to `newText`. ⌫ straight after a badge
    /// appeared, taking one character off the end of text that ended with
    /// the phrase, cancels the badge instead and keeps the text.
    public mutating func edit(to newText: String) {
        if let shown = parse(text, today: now()),
           text.hasSuffix(shown.phrase),
           newText.count == text.count - 1,
           text.hasPrefix(newText) {
            cancel(shown)
            return
        }
        text = newText
    }

    /// The badge's ✕: the phrase stays plain words for the rest of this
    /// entry.
    public mutating func cancelBadge() {
        guard let parsed = parse(text, today: now()) else { return }
        cancel(parsed)
    }

    /// Whether ⏎ has nothing to save. Cheaper than `submit()`, for
    /// deciding what to draw.
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A new entry, for `+` after a save and for Quick Capture reopening:
    /// no text and nothing cancelled.
    public mutating func reset() {
        text = ""
        cancelled = []
    }

    /// What ⏎ saves: the title without the phrase and its date, or the
    /// text as typed with no date. `nil` when there's nothing to save.
    public func submit() -> (title: String, dueAt: Date?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = parse(trimmed, today: now()) else { return (trimmed, nil) }
        return (parsed.title, parsed.dueAt)
    }

    private mutating func cancel(_ parsed: TypedDueDate) {
        cancelled.insert(parsed.phrase.lowercased())
    }

    private func parse(_ text: String, today: Date) -> TypedDueDate? {
        guard let parsed = parseTypedDueDate(in: text, today: today, cancelled: cancelled), !parsed.title.isEmpty else {
            return nil
        }
        return parsed
    }
}
