import Contacts
import Foundation

/// Production `ContactsResolver`, backed by the Contacts framework.
/// `@unchecked Sendable`: `CNContactStore` predates Swift concurrency
/// annotations but documents its methods as safe to call from any thread,
/// same posture as `EventKitTaskSource`'s `EKEventStore`.
public final class CNContactsResolver: ContactsResolver, @unchecked Sendable {
    private let store = CNContactStore()

    public init() {}

    /// The Contacts Gate's current state, without prompting — a class-level
    /// query, unlike Full Disk Access which has no such API. Read before
    /// every lookup rather than cached, so a mid-session revocation (ticket
    /// 10's posture, extended here) degrades the very next resolution to
    /// the raw address instead of a stale "still granted" assumption.
    public static func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Requests the Contacts Gate. Call once, before the window appears,
    /// alongside `EventKitTaskSource.requestAccess()`.
    public func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    /// A denied/revoked Gate or a no-match address both return `nil` here —
    /// deliberately not distinguished, since a caller treats them
    /// identically (fall back to the raw address). `address` is matched as
    /// a phone number unless it looks like an email.
    public func resolveName(forAddress address: String) -> String? {
        guard Self.authorizationStatus() == .authorized else { return nil }

        if address.contains("@") {
            return name(matching: CNContact.predicateForContacts(matchingEmailAddress: address))
        }

        return nameMatchingPhoneNumber(address)
    }

    /// Compares phone numbers by their last 10 digits rather than trusting
    /// `CNContact.predicateForContacts(matching: CNPhoneNumber)` to bridge
    /// formatting differences on its own — confirmed unreliable for at
    /// least one real case (a contact saved as "(317) 795-9806," no
    /// country code, never matched chat.db's "+13177959806"), and nothing
    /// says other formatting gaps (dashes, dots, spacing) fare any better.
    /// Comparing digit suffixes means "+13177959806," "(317) 795-9806,"
    /// and "317.795.9806" all match each other regardless of which one
    /// Messages or Contacts happens to use — the same digits are the same
    /// number, independent of how either side chose to write it down.
    private func nameMatchingPhoneNumber(_ address: String) -> String? {
        let targetDigits = lastTenDigits(of: address)
        guard !targetDigits.isEmpty else { return nil }

        // `CNContactFormatter.string(from:style:)` below reads whichever
        // keys a given contact's name actually needs — `middleName` for
        // some, others for others, depending on the contact's own data and
        // locale — not just the four fetched here. A key it needs but
        // wasn't fetched throws an Objective-C `NSException`, which
        // `try?`/`do-catch` cannot catch (it isn't a `Swift.Error`), so it
        // crashed the whole process: confirmed by a real crash report,
        // `-[CNContact middleName]` thrown from inside the formatter,
        // uncaught, aborting. `descriptorForRequiredKeys(for:)` is Apple's
        // documented fix — it names exactly the keys that style of
        // formatting can touch, whatever they turn out to be for a given
        // contact.
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        var matchedName: String?
        try? store.enumerateContacts(with: request) { contact, stop in
            let matches = contact.phoneNumbers.contains { lastTenDigits(of: $0.value.stringValue) == targetDigits }
            guard matches else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName)
            if let name, !name.isEmpty {
                matchedName = name
                stop.pointee = true
            }
        }
        return matchedName
    }

    /// The last 10 digits of `raw`, stripped of everything else — country
    /// code, parens, dashes, spaces, dots. Empty if `raw` has fewer than
    /// 10 digits at all (not a real phone number in the shapes this app
    /// ever sees one). US/Canada-specific by construction, matching every
    /// other phone-number assumption already in this codebase (chat.db
    /// itself only ever ships a US/Canada number in `+1` E.164 form).
    private func lastTenDigits(of raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 10 else { return "" }
        return String(digits.suffix(10))
    }

    private func name(matching predicate: NSPredicate) -> String? {
        // Same fix as `nameMatchingPhoneNumber` above, same reason: this
        // also runs contacts through `CNContactFormatter`, so it needs the
        // same required-keys descriptor to avoid the identical crash.
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        guard
            let matches = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch),
            let contact = matches.first
        else {
            return nil
        }

        let name = CNContactFormatter.string(from: contact, style: .fullName)
        return (name?.isEmpty ?? true) ? nil : name
    }
}
