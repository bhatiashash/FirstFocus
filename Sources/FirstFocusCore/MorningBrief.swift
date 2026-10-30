import Foundation

/// The first line of every Morning Brief (ADR 0046). Intake recognizes a
/// Brief by it, so composing and recognizing share this one string.
public let morningBriefHeader = "FirstFocus Morning Brief"

/// Headers earlier Briefs went out with, from before the app was renamed
/// FirstFocus. Still recognized, so re-extracting a day that holds one
/// never turns it into Signals.
private let earlierMorningBriefHeaders: Set<String> = ["[DailyOS Morning Brief]", "DailyOS Morning Brief"]

/// Whether `message` is a Morning Brief: one you sent, in any Chat, whose
/// first line is the header. A received message starting with the header
/// is ordinary text.
public func isMorningBrief(_ message: ChatMessage) -> Bool {
    guard message.isFromMe else { return false }
    let firstLine = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed == morningBriefHeader || earlierMorningBriefHeaders.contains(trimmed)
}

/// How the Morning Brief is laid out below its fixed header, which you
/// can edit in Advanced. `body` is the message, with `{top}` (the first
/// Focus Signal), `{rest}` (every other one listed: its whole line repeats
/// once per Signal), `{more}` ("+2 more in Focus"
/// when `limit` cuts the list) and `{later}` (how many Signals wait in
/// Later). `itemLine` writes each Signal, with `{n}` (the position, from 1),
/// `{label}` and `{overdue}` (" (overdue)" or nothing). `limit` caps how
/// many Focus Signals are listed; `nil` lists them all.
public struct MorningBriefFormat: Equatable, Sendable {
    public var body: String
    public var itemLine: String
    public var limit: Int?

    public init(body: String, itemLine: String, limit: Int?) {
        self.body = body
        self.itemLine = itemLine
        self.limit = limit
    }

    public static let standard = MorningBriefFormat(
        body: "{top}\n{rest}\n{more}\n\n({later} in Later)", itemLine: "{label}{overdue}", limit: nil
    )
}

/// The Morning Brief's text (ADR 0046): the fixed header, a blank line,
/// then `format`'s body. The Suggested Tasks Inbox and the Snoozed Section
/// are left out. A Signal whose due date has passed at `now` is marked
/// overdue, by the same rule the window uses (`isOverdue`). A body line
/// holding only a placeholder that comes out empty is dropped, so an
/// uncut list leaves no blank line where `{more}` was.
public func composeMorningBrief(_ list: RankedList, now: Date, format: MorningBriefFormat = .standard) -> String {
    let listed = format.limit.map { Array(list.focus.prefix(max($0, 0))) } ?? list.focus
    func line(_ template: String, _ signal: Signal, _ position: Int) -> String {
        let overdue = signal.dueAt.map { isOverdue($0, at: now) } ?? false
        return fill(template, ["n": String(position), "label": signal.label, "overdue": overdue ? " (overdue)" : ""])
    }
    let unlisted = list.focus.count - listed.count
    let values = [
        "top": listed.first.map { line(format.itemLine, $0, 1) } ?? "Nothing in Focus.",
        "more": unlisted > 0 ? "+\(unlisted) more in Focus" : "",
        "later": String(list.laterCount),
    ]
    let restLines = listed.dropFirst().enumerated().map { line(format.itemLine, $0.element, $0.offset + 2) }
    var lines = [morningBriefHeader, ""]
    for template in format.body.components(separatedBy: "\n") {
        // A line holding {rest} is repeated once per Signal it lists, so
        // text around it ("- {rest}") lands on every one of them.
        if template.contains("{rest}") {
            lines += restLines.map { fill(template, values.merging(["rest": $0]) { $1 }) }
            continue
        }
        let expanded = fill(template, values)
        let isLonePlaceholder = values.keys.contains { "{\($0)}" == template.trimmingCharacters(in: .whitespaces) }
        if isLonePlaceholder && expanded.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        lines.append(expanded)
    }
    return lines.joined(separator: "\n")
}

/// Replaces each `{name}` in `template` that `values` knows, in one pass,
/// so a Label that happens to contain `{later}` is printed as written.
/// Unknown names are left as typed.
private func fill(_ template: String, _ values: [String: String]) -> String {
    var result = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
        result += rest[..<open]
        guard let close = rest[open...].firstIndex(of: "}"),
              let value = values[String(rest[rest.index(after: open)..<close])]
        else {
            result.append("{")
            rest = rest[rest.index(after: open)...]
            continue
        }
        result += value
        rest = rest[rest.index(after: close)...]
    }
    return result + rest
}
