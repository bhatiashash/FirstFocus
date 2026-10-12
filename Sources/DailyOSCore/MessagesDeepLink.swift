import Foundation

/// Deep Linking (ticket 03): what clicking a row should do, decided purely
/// from the Signal itself — no chat.db query, no Messages.app launch, so
/// this stays unit-testable on its own. `.chat` names a one-to-one Chat's
/// resolved identifier (ticket 02); `.appOnly` is the group-Chat and
/// missing-identifier fallback (open Messages.app, untargeted — there's no
/// public, documented way to deep-link a specific group conversation on
/// macOS); `.none` is every non-Messages Signal, where a row click stays
/// exactly the no-op it already is today.
public enum MessagesDeepLinkTarget: Equatable, Sendable {
    case chat(identifier: String)
    case appOnly
    case none
}

/// `sms:<address>` opens Messages.app directly to the one-to-one
/// conversation with that phone number or email — the same scheme
/// Messages itself registers for both SMS and iMessage addresses. Also
/// what Approve writes into a reminder's URL (ADR 0041), so Reminders.app
/// can open the Chat too.
public func messagesChatURL(identifier: String) -> URL? {
    guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    return URL(string: "sms:\(encoded)")
}

/// Pure: reads only `signal.source` and `signal.chatIdentifier`, both
/// already resolved once at Extraction (ADR 0008's one-time-resolution
/// treatment, extended to Deep Linking by ticket 02).
public func messagesDeepLinkTarget(for signal: Signal) -> MessagesDeepLinkTarget {
    guard signal.source == .messages else { return .none }
    if let chatIdentifier = signal.chatIdentifier {
        return .chat(identifier: chatIdentifier)
    }
    return .appOnly
}
