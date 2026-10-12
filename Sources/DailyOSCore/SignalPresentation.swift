import Foundation

// Three pure rules that used to sit `private` inside the view file, where
// no test could reach them even though all three were written test-shaped.
// Moved here unchanged: what they decide is about a Signal's content and a
// due date's phrasing, not about how anything is drawn.

/// Whether `originalText` is worth showing under `label` — skipped when
/// extraction's rewrite left the wording essentially untouched (case,
/// trailing punctuation, and surrounding whitespace aside), since two
/// copies of the same sentence is noise, not the comparison this line
/// exists for (see `SignalRow`'s own comment on why it's shown at all).
/// Scoped to a prefix, not the full strings: a label that's just the
/// original's opening words with a divergence later on (verified against
/// real stored data — e.g. label "Read Procedural Graphs paper", original
/// "Read Procedural Graphs paper from Google") is a real difference worth
/// showing, but a one-line-truncated subtitle only has room to prove that
/// if the divergence falls within roughly the first line's worth of
/// characters — past that, two genuinely different sentences can still
/// look identical at a glance. Comparing a short prefix instead of the
/// full string is deliberately the more conservative direction to be
/// wrong in: it can only fail by showing a subtitle that goes on to add
/// something after all, never by hiding one that had nothing to add.
private let originalTextComparisonPrefixLength = 40

public func isWorthShowingOriginal(label: String, originalText: String) -> Bool {
    func normalizedPrefix(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?…"))
            .lowercased()
        return String(cleaned.prefix(originalTextComparisonPrefixLength))
    }
    return normalizedPrefix(label) != normalizedPrefix(originalText)
}

/// Strips a trailing routing-tag annotation chat.db attaches to some raw
/// handles — e.g. "41064(smsft)" for a short-code business SMS — before
/// display. A resolved Contacts name never carries one (CNContactFormatter
/// doesn't produce parenthetical suffixes), so this only ever touches the
/// unresolved-address case, and only when the whole string ends in a
/// parenthesized group.
private func strippingTrailingParenthetical(_ text: String) -> String {
    guard text.hasSuffix(")"), let openParenIndex = text.lastIndex(of: "(") else { return text }
    return text[..<openParenIndex].trimmingCharacters(in: .whitespaces)
}

/// The first name only, for compact display in the Suggested Tasks Inbox —
/// CONTEXT.md: Sender is either a resolved Contacts name or a raw,
/// unresolved phone number/email. A raw address has no "first name" to
/// split out, so it's shown whole (routing-tag suffix stripped first)
/// rather than mangled by splitting on a space that happens to appear in
/// it.
public func firstName(from sender: String) -> String {
    let sender = strippingTrailingParenthetical(sender)
    guard let firstComponent = sender.split(separator: " ").first else { return sender }
    return String(firstComponent)
}

/// A caption (`Signal.originalText`) can carry a raw URL a model quoted
/// verbatim from message text — a full "https://support.google.com/reserve/"
/// reads as a dominant block of noise in this compact HUD, not as context.
/// Strips the protocol and collapses everything past the host into a
/// trailing ellipsis ("support.google.com/…"), keeping just enough to name
/// the site without the rest of the path. Text with no URL is returned
/// unchanged; a URL with nothing past its host (no trailing slash or path)
/// loses only the protocol.
public func shorteningURLs(in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "https?://([^\\s/]+)(/[^\\s]*)?") else {
        return text
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    guard !matches.isEmpty else { return text }

    var result = text
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result) else { continue }
        let host = nsText.substring(with: match.range(at: 1))
        let pathRange = match.range(at: 2)
        let hasPath = pathRange.location != NSNotFound && pathRange.length > 1
        result.replaceSubrange(fullRange, with: hasPath ? "\(host)/…" : host)
    }
    return result
}

/// "Today"/"Tomorrow"/"Yesterday" for anything near enough to name, a
/// general relative phrase ("in 3 days", capitalized) otherwise — a hard
/// calendar date is rarely what you actually want to read here.
public func relativeDueDateText(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    let phrase = formatter.localizedString(for: date, relativeTo: now)
    return phrase.prefix(1).uppercased() + phrase.dropFirst()
}

/// `SourceIcon`'s symbol (ContentView.swift): a single subtle icon rather
/// than a text badge for a Signal's originating Source.
public func sourceIconSymbolName(for source: Source) -> String {
    switch source {
    case .reminders: return "list.bullet"
    case .messages: return "bubble.left"
    }
}

/// `SourceIcon`'s `.help` text. `sender` is the resolved Contacts name or
/// raw address for a Messages Signal — `nil` for a self-thread Signal (no
/// second party) or a Reminders Signal (no Sender concept at all, so this
/// never reads `sender` for that case).
public func sourceHelpText(for source: Source, sender: String?) -> String {
    switch source {
    case .reminders: return "Reminders"
    case .messages: return sender ?? "Messages"
    }
}
