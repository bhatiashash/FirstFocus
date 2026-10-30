import Foundation

/// Sender attribution's Contacts Gate (ADR 0008): resolves a raw Messages
/// address to a real name, once, at Extraction time. Production adapter is
/// `CNContactsResolver`, backed by the Contacts framework; test adapter is a
/// fixture-backed fake, symmetric with `TaskSource`/`MessagesSource`.
public protocol ContactsResolver: Sendable {
    /// Requests the Contacts Gate, fire-and-forget: a denied or ignored
    /// prompt means `resolveName` returns `nil` later and Sender degrades
    /// to the raw address, never that anything blocks.
    func requestAccess() async throws -> Bool

    /// `nil` covers every reason there's no name to show — no Contacts
    /// match, or the Contacts Gate itself denied or revoked — so a caller
    /// always falls back to `address` itself rather than branching on why
    /// resolution came back empty (CONTEXT.md: Unavailable "never blocks").
    func resolveName(forAddress address: String) -> String?
}

/// The default `contactsResolver` for `ExtractionDependencies`: never
/// resolves anything, so `Signal.sender` stays `nil` wherever nothing
/// supplies a real resolver, the same as a denied Contacts Gate would
/// produce.
public struct NoopContactsResolver: ContactsResolver {
    public init() {}
    public func requestAccess() async throws -> Bool { false }
    public func resolveName(forAddress address: String) -> String? { nil }
}
