import Foundation

/// Filtered SMS: a text that Messages' SMS filter sorted as Transactions or
/// Promotions. Messages marks it in the sender's address, with a suffix
/// Apple doesn't document: "(smsft)" for Transactions, "(smsfp)" for
/// Promotions ("23045(smsfp)", "+15551234567(smsft)"). Only texts from
/// senders outside Contacts are sorted this way.
public func isFilteredSMSAddress(_ address: String) -> Bool {
    let lowered = address.lowercased()
    return lowered.hasSuffix("(smsft)") || lowered.hasSuffix("(smsfp)")
}

/// Whether a Batch comes from a Filtered SMS Chat: its Chat's identifier,
/// or any member's sender, carries the suffix.
func isFilteredSMS(_ batch: MessageBatch) -> Bool {
    batch.messages.contains { message in
        [message.chatIdentifier, message.senderAddress].contains { $0.map(isFilteredSMSAddress) ?? false }
    }
}

/// Advanced's Ignore Filtered SMS toggle, on until turned off. While on, a
/// Batch from a Filtered SMS Chat never reaches Extraction. A thin
/// `UserDefaults` wrapper, the same shape as `ExtractionSettings`.
///
/// `@unchecked Sendable`: `UserDefaults` is safe to use from any thread.
public struct FilteredSMSSettings: @unchecked Sendable {
    /// The `UserDefaults` key, shared with the toggle's `@AppStorage`.
    public static let key = "ignoreSystemSMS"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var ignoresFilteredSMS: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
