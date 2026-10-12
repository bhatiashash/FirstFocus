import DailyOSCore
import Foundation

/// Test double for `MessagesSource`. `listMessages` ignores its
/// parameters and returns `messages` as given — tests that need
/// `shouldIncludeMessage`'s own filtering exercise that pure function
/// directly rather than through this fake.
final class FakeMessagesSource: MessagesSource, @unchecked Sendable {
    var messages: [ChatMessage]
    private let confirmedGoneRefs: Set<String>
    private let unknownRefs: Set<String>

    /// Settable so a test can drive Full Disk Access being denied or
    /// revoked mid-read, which ticket 10 probes for twice around every
    /// fetch and which nothing could reach before this fake had it.
    var gateAvailability: SourceAvailability

    init(
        messages: [ChatMessage] = [],
        confirmedGoneRefs: Set<String> = [],
        unknownRefs: Set<String> = [],
        availability: SourceAvailability = .available
    ) {
        self.messages = messages
        self.confirmedGoneRefs = confirmedGoneRefs
        self.unknownRefs = unknownRefs
        self.gateAvailability = availability
    }

    func availability() -> SourceAvailability {
        gateAvailability
    }

    /// Counts fetches, the Messages half of ticket 11's routing check.
    private(set) var listCallCount = 0

    /// What `selfChatIds()` reports, and the exclusions the last read got.
    var selfChatIdSet: Set<Int> = []
    private(set) var lastExcludedChatIds: Set<Int>?

    func selfChatIds() -> Set<Int> {
        selfChatIdSet
    }

    func listMessages(excludingChatIds: Set<Int>, nonSelfCutoff: Date) -> [ChatMessage] {
        listCallCount += 1
        lastExcludedChatIds = excludingChatIds
        return messages
    }

    /// Defaults to "still there" (`false`) for anything not explicitly
    /// listed as gone or unknown — matching the real adapter's behaviour
    /// for a ROWID it can actually find and read.
    func isGone(sourceRef: String) -> Bool? {
        if unknownRefs.contains(sourceRef) { return nil }
        return confirmedGoneRefs.contains(sourceRef)
    }
}
