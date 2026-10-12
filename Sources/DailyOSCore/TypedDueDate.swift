import Foundation

/// A due date found in text typed into `+` or Quick Capture, with what the
/// reminder's title becomes once the phrase is taken out.
public struct TypedDueDate: Equatable, Sendable {
    /// The typed text without the phrase (and a connecting "on", "by" or
    /// "due" before it), whitespace collapsed.
    public let title: String
    /// The start of the day the phrase names (ADR 0030: no time of day).
    public let dueAt: Date
    /// The phrase exactly as typed, for the badge. Cancelling the badge
    /// passes it back in `cancelled`.
    public let phrase: String

    public init(title: String, dueAt: Date, phrase: String) {
        self.title = title
        self.dueAt = dueAt
        self.phrase = phrase
    }
}

/// Finds a due date in typed text (ADR 0030 amendment). A fixed list of
/// phrases is tried alongside `NSDataDetector`: "next week", "this
/// weekend", "end of (the) month", "in N day(s)/week(s)", and bare weekday
/// names. Weekdays are in the list because `NSDataDetector` resolves
/// today's weekday name to next week, and the list takes `today` so its
/// answers can be tested against a pinned date. Where a detector match
/// contains a fixed one ("next monday" around "monday"), the longer
/// detector phrase wins. The match that ends last wins, so "Pay the May 3
/// invoice by friday" is due Friday. `cancelled` holds phrases whose badge
/// was cancelled for this entry, compared ignoring case; they are never
/// matched again, and an earlier phrase can match instead.
///
/// `nil` when nothing matches. Extraction never calls this: its dates go
/// through `resolveDueDate` alone, since nobody reviews them before they
/// are saved.
public func parseTypedDueDate(in text: String, today: Date, cancelled: Set<String> = []) -> TypedDueDate? {
    let nsText = text as NSString
    let cancelledKeys = Set(cancelled.map { $0.lowercased() })
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: today)

    let fixed = fixedPhraseMatches(in: text, startOfToday: startOfToday, calendar: calendar)
    var candidates = fixed
    for detected in detectorMatches(in: text) {
        let overlapping = fixed.filter { NSIntersectionRange($0.range, detected.range).length > 0 }
        if overlapping.isEmpty {
            candidates.append(detected)
        } else if overlapping.allSatisfy({ strictlyContains(detected.range, $0.range) }) {
            candidates.removeAll { candidate in overlapping.contains { $0.range == candidate.range } }
            candidates.append(detected)
        }
    }

    let chosen = candidates
        .filter { !cancelledKeys.contains(nsText.substring(with: $0.range).lowercased()) }
        .max { lhs, rhs in
            let (lhsEnd, rhsEnd) = (NSMaxRange(lhs.range), NSMaxRange(rhs.range))
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return lhs.range.length < rhs.range.length
        }
    guard let chosen else { return nil }

    let removed = extendedOverConnectingWord(chosen.range, in: nsText)
    let title = nsText.replacingCharacters(in: removed, with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return TypedDueDate(
        title: title,
        dueAt: calendar.startOfDay(for: chosen.date),
        phrase: nsText.substring(with: chosen.range)
    )
}

/// The words on a typed due date's badge: "Today" and "Tomorrow" by name,
/// any other day as its date ("Fri, Sep 25").
public func typedDueDateBadgeText(dueAt: Date, today: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(dueAt, inSameDayAs: today) { return "Today" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)),
       calendar.isDate(dueAt, inSameDayAs: tomorrow) {
        return "Tomorrow"
    }
    return dueAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

private struct DateMatch {
    let range: NSRange
    let date: Date
}

private func strictlyContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
    outer.location <= inner.location && NSMaxRange(outer) >= NSMaxRange(inner) && outer.length > inner.length
}

private let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

private func fixedPhraseMatches(in text: String, startOfToday: Date, calendar: Calendar) -> [DateMatch] {
    var matches: [DateMatch] = []
    func each(_ pattern: String, _ resolve: (NSTextCheckingResult) -> Date?) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        for result in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let date = resolve(result) { matches.append(DateMatch(range: result.range, date: date)) }
        }
    }
    let todayWeekday = calendar.component(.weekday, from: startOfToday)
    func daysUntil(weekday: Int) -> Int { (weekday - todayWeekday + 7) % 7 }

    each(#"\bnext week\b"#) { _ in
        // The first Monday after today; Calendar weekday 2 is Monday.
        let days = daysUntil(weekday: 2)
        return calendar.date(byAdding: .day, value: days == 0 ? 7 : days, to: startOfToday)
    }
    each(#"\bthis weekend\b"#) { _ in
        // Saturday is 7 and Sunday is 1: both already are the weekend.
        todayWeekday == 1 ? startOfToday : calendar.date(byAdding: .day, value: daysUntil(weekday: 7), to: startOfToday)
    }
    each(#"\bend of (?:the )?month\b"#) { _ in
        guard let days = calendar.range(of: .day, in: .month, for: startOfToday)?.count else { return nil }
        let dayOfMonth = calendar.component(.day, from: startOfToday)
        return calendar.date(byAdding: .day, value: days - dayOfMonth, to: startOfToday)
    }
    each(#"\bin (\d{1,3}) (day|days|week|weeks)\b"#) { result in
        let nsText = text as NSString
        guard let count = Int(nsText.substring(with: result.range(at: 1))) else { return nil }
        let unit = nsText.substring(with: result.range(at: 2)).lowercased()
        return calendar.date(byAdding: .day, value: unit.hasPrefix("week") ? count * 7 : count, to: startOfToday)
    }
    each(#"\b(\#(weekdayNames.joined(separator: "|")))\b"#) { result in
        let name = (text as NSString).substring(with: result.range(at: 1)).lowercased()
        guard let index = weekdayNames.firstIndex(of: name) else { return nil }
        return calendar.date(byAdding: .day, value: daysUntil(weekday: index + 1), to: startOfToday)
    }
    return matches
}

/// `NSDataDetector` reads "due tomorrow" and "due monday" as today, so the
/// word "due" is blanked out (same length, so ranges still line up) before
/// it looks. The word is still removed with the phrase afterwards.
private func detectorMatches(in text: String) -> [DateMatch] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
          let due = try? NSRegularExpression(pattern: #"\bdue\b"#, options: .caseInsensitive) else { return [] }
    let fullRange = NSRange(text.startIndex..., in: text)
    let masked = due.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "   ")
    return detector.matches(in: masked, range: fullRange).compactMap { result in
        result.date.map { DateMatch(range: result.range, date: $0) }
    }
}

/// `range` widened backwards over a connecting "on", "by" or "due" and the
/// space before the phrase, so "Call dentist on friday" loses "on" too.
private func extendedOverConnectingWord(_ range: NSRange, in text: NSString) -> NSRange {
    let before = text.substring(to: range.location)
    guard let regex = try? NSRegularExpression(pattern: #"\b(?:on|by|due)\s+$"#, options: .caseInsensitive),
          let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
    else { return range }
    return NSRange(location: match.range.location, length: NSMaxRange(range) - match.range.location)
}
