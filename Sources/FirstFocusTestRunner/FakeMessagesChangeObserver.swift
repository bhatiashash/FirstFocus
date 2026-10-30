import FirstFocusCore
import Foundation

final class FakeMessagesChangeObserver: MessagesChangeObserver {
    private var handler: (@Sendable () -> Void)?

    func onChange(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler?()
    }
}
