import DailyOSCore
import Foundation

/// Test double for `ContactsResolver`. Maps a raw address to the name a
/// real Contacts match would have produced; an address absent from `names`
/// resolves to `nil`, standing in for both "no match" and "the Contacts
/// Gate is denied or revoked" — `CNContactsResolver` collapses both to the
/// same `nil` result, so a test doesn't need to distinguish them either.
///
/// `@unchecked Sendable`: every test calls this synchronously on one
/// thread, same justification as `FakeIntentExtractor`.
final class FakeContactsResolver: ContactsResolver, @unchecked Sendable {
    private let names: [String: String]
    private(set) var calls: [String] = []

    init(names: [String: String] = [:]) {
        self.names = names
    }

    func requestAccess() async throws -> Bool { true }

    func resolveName(forAddress address: String) -> String? {
        calls.append(address)
        return names[address]
    }
}
