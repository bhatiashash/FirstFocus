import EventKit
import Foundation

/// A Source's reachability, decided from its Gate's current state. See
/// CONTEXT.md: Unavailable. Pure mappings — no OS call, no I/O — so a
/// caller does the actual permission read (`canOpen()`,
/// `EKEventStore.authorizationStatus(for:)`) and hands the result in.
public enum SourceAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// Full Disk Access has no status query API — the only way to know is to
/// try reading `chat.db`, so `canOpen()`'s result is the Gate reading this
/// maps from.
public func messagesAvailability(canOpen: Bool) -> SourceAvailability {
    canOpen ? .available : .unavailable
}

/// `.fullAccess` is the only status that actually grants
/// `listOpenTasks()`/`complete(id:)`; everything else (`.notDetermined`,
/// `.restricted`, `.denied`, `.writeOnly`, and the deprecated
/// `.authorized`) means the Source contributes nothing.
public func reminderAvailability(authorizationStatus: EKAuthorizationStatus) -> SourceAvailability {
    authorizationStatus == .fullAccess ? .available : .unavailable
}

/// The Full Disk Access re-grant check: true when the running binary's own
/// signing identity (`current`) differs from the identity recorded after
/// the last successful Messages read (`stored`). TCC keys FDA grants to
/// the signing identity, so a changed identity means the old grant no
/// longer applies even though nothing else about the machine's state
/// changed. `stored == nil` (nothing recorded yet, e.g. first run) is never
/// a mismatch — there's nothing to have drifted from.
public func identityMismatch(current: String, stored: String?) -> Bool {
    guard let stored else { return false }
    return current != stored
}
