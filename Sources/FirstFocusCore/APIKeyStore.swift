import Foundation
import Security

/// Where Screening's API key is kept. A protocol so tests never touch the
/// real Keychain.
public protocol APIKeyStore: Sendable {
    func read() -> String?
    func write(_ key: String) throws
    func delete() throws
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

/// Production `APIKeyStore`: one generic-password item in the login
/// Keychain, so the key survives rebuilds and never sits in preferences.
public struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "typesafe-api-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var add = baseQuery
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
