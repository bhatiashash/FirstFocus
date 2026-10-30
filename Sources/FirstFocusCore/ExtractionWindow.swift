import Foundation

/// How far back automatic Messages extraction reaches: the self-thread's
/// first-run backfill and every later on-demand pass, across every Chat
/// (ADR 0007), both only ever consider messages from the last week. For a
/// non-self Chat this is on top of, not instead of, `nonSelfMessagesCutoff`
/// — whichever bound is tighter wins. Older history is never walked, so it
/// never mints a Signal — a deliberate scope narrower than "everything
/// available," fixed in code, not user-tunable.
///
/// Ticket 12's manual re-extraction used to be exempt from any window at
/// all — genuinely unbounded, by design, since it was meant as a rare
/// override. It now has its own window instead (see `ReExtractionSettings`),
/// user-tunable and defaulting to a much narrower 2 days rather than this
/// constant's 7 — the two scopes answer different questions (how far
/// automatic intake reaches vs. how far a manual re-run reaches) and were
/// kept as two separate numbers on purpose, not folded into one.
public let extractionLookbackDays: Double = 7

/// Keeps only `messages` created within `lookbackDays` of `now`.
/// `messages` is expected newest-first (as `MessagesSource` already
/// returns it); order is preserved, nothing is re-sorted. `lookbackDays`
/// defaults to `extractionLookbackDays` for automatic intake's own call
/// site; `MessagesIntake.reExtract` passes a separately-configured value.
public func withinExtractionWindow(_ messages: [ChatMessage], now: Date, lookbackDays: Double = extractionLookbackDays) -> [ChatMessage] {
    let cutoff = now.addingTimeInterval(-lookbackDays * 86400)
    return messages.filter { $0.createdAt >= cutoff }
}
