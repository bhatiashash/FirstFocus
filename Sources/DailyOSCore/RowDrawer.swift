import Foundation

/// What a Focus or Later row shows, and what its drawer holds once
/// clicked (ADR 0041; CONTEXT.md: Notes). Decided once here, like
/// `affordances(for:isLater:now:)` (ADR 0023), so the row view only reads
/// the answer.
public struct RowDrawer: Equatable, Sendable {
    /// The Label as the row shows it: URLs taken out, since they move into
    /// `links`. The reminder's real title is never changed.
    public let displayLabel: String
    /// Notes for a reminder; the original wording for a Messages Signal.
    /// `nil` when there is none.
    public let body: String?
    /// Every link in the body, the title and a reminder URL that isn't a
    /// Messages link, each once, in that order.
    public let links: [URL]
    /// Where "Open in Messages" goes: a one-to-one Chat only. A group Chat
    /// gets none, since Messages can't be opened at a specific one.
    public let messagesURL: URL?

    /// Whether clicking the row opens anything. A row with nothing to show
    /// ignores the click and carries no note glyph.
    public var hasContent: Bool {
        body != nil || !links.isEmpty || messagesURL != nil
    }
}

public func rowDrawer(for signal: Signal) -> RowDrawer {
    let body: String?
    let messagesURL: URL?
    var extraLinks: [URL] = []
    switch signal.source {
    case .reminders:
        body = signal.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let url = signal.url, url.scheme?.lowercased() == "sms" {
            messagesURL = url
        } else {
            messagesURL = nil
            extraLinks = signal.url.map { [$0] } ?? []
        }
    case .messages:
        body = signal.originalText
        messagesURL = signal.chatIdentifier.flatMap(messagesChatURL(identifier:))
    }

    var links: [URL] = []
    for url in linkMatches(in: body ?? "").map(\.url) + linkMatches(in: signal.label).map(\.url) + extraLinks
    where !links.contains(url) {
        links.append(url)
    }

    return RowDrawer(
        displayLabel: removingURLs(from: signal.label),
        body: body,
        links: links,
        messagesURL: messagesURL
    )
}

private func linkMatches(in text: String) -> [(range: NSRange, url: URL)] {
    guard !text.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        match.url.map { (match.range, $0) }
    }
}

/// A Label that is nothing but a URL keeps a short form of it
/// (`shorteningURLs`), so the row is never blank.
private func removingURLs(from label: String) -> String {
    let matches = linkMatches(in: label)
    guard !matches.isEmpty else { return label }
    let stripped = NSMutableString(string: label)
    for match in matches.reversed() {
        stripped.replaceCharacters(in: match.range, with: " ")
    }
    let collapsed = (stripped as String).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.isEmpty ? shorteningURLs(in: label) : collapsed
}
