import Foundation

/// What a Section carrying no Signals is reporting (CONTEXT.md: Notice).
/// Identity alone — the instructions, the row shape and the buttons are
/// presentation and stay in the view.
/// `.messagesUnavailable`/`.remindersUnavailable` are a Source whose Gate
/// isn't granted (CONTEXT.md: Unavailable); `.extractionUnavailable` is
/// neither a Source nor a Gate, just the local model failing to load,
/// which is why it's a case of its own rather than a third Source.
public enum Notice: String, Sendable {
    case messagesUnavailable
    case remindersUnavailable
    case extractionUnavailable
}

/// One headed block of the window: the Suggested Tasks Inbox, Focus,
/// Later, the Snoozed Section, or a Notice (CONTEXT.md: Section). Distinct
/// from `Tier`, which has only two values and is about ranking — the
/// Suggested Tasks Inbox and the Snoozed Section are Sections but never
/// Tiers. `.tier` carries `RenderGroup`s, already
/// clustered by `groupForRendering`; `.suggested` carries raw Signals,
/// since grouping has never applied to that Section; `.snoozed` carries raw
/// Signals soonest to return first (ADR 0045); `.notice` carries no
/// Signals at all.
public enum Section: Identifiable, Sendable {
    case suggested([Signal])
    case tier(Tier, [RenderGroup])
    case snoozed([Signal])
    case notice(Notice)

    public var id: String {
        switch self {
        case .suggested: return "suggested"
        case .tier(let tier, _): return "tier-\(tier)"
        case .snoozed: return "snoozed"
        case .notice(let notice): return "notice-\(notice.rawValue)"
        }
    }
}
