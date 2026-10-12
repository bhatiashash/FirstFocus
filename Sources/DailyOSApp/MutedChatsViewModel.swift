import Combine
import DailyOSCore
import Foundation

/// The hover text for a Muted Chat History has no row for.
public let noRecentMessages = "No recent messages"

/// One Muted Chat as Advanced lists it.
public struct MutedChat: Identifiable, Equatable, Sendable {
    public let chatId: Int
    public let name: String
    /// The newest message History has for the Chat, shown on hover.
    public let lastMessage: String

    public var id: Int { chatId }

    public init(chatId: Int, name: String, lastMessage: String) {
        self.chatId = chatId
        self.name = name
        self.lastMessage = lastMessage
    }
}

/// Backs Advanced's Muted Chats section (muted-chats-list): every Chat
/// that is Muted now, named the way History names it. A Chat with no row
/// left in History still shows, so deleting rows never strands it.
@MainActor
public final class MutedChatsViewModel: ObservableObject {
    @Published public private(set) var chats: [MutedChat] = []

    private let actions: HistoryBatchActions
    private let historyStore: any HistoryStore

    public init(actions: HistoryBatchActions, historyStore: any HistoryStore) {
        self.actions = actions
        self.historyStore = historyStore
        refresh()
    }

    public func refresh() {
        let muted = actions.facts(forBatches: []).mutedChats
        let latest = historyStore.latestBatches(ofChats: muted)
        var byChat: [Int: HistoryBatch] = [:]
        for batch in latest {
            if let chatId = batch.chatId { byChat[chatId] = batch }
        }
        chats = muted.map { chatId in
            let batch = byChat[chatId]
            return MutedChat(
                chatId: chatId, name: batch?.title ?? chatNotRecordedTitle,
                lastMessage: batch?.latestMessage ?? noRecentMessages
            )
        }.sorted { a, b in
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.chatId < b.chatId
            }
        }
    }

    public func unmute(chatId: Int) {
        actions.unmute(chatId: chatId)
        refresh()
    }
}
