import AppKit
import FirstFocusCore
import Foundation

/// Deep Linking (ticket 03): the AppKit side of `messagesDeepLinkTarget` —
/// actually opening Messages.app, which needs no automated test (system
/// glue, per the ticket's own testing decision) now that the target itself
/// is decided by a pure, tested function.
enum MessagesDeepLinkOpener {
    private static let messagesBundleIdentifier = "com.apple.MobileSMS"

    static func open(_ target: MessagesDeepLinkTarget) {
        switch target {
        case .none:
            return
        case .chat(let identifier):
            guard let url = messagesChatURL(identifier: identifier) else {
                openMessagesApp()
                return
            }
            NSWorkspace.shared.open(url)
        case .appOnly:
            openMessagesApp()
        }
    }

    /// The group-Chat and missing-identifier fallback: launches Messages
    /// itself with no target, since there's no public, documented way to
    /// address a specific group conversation.
    private static func openMessagesApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleIdentifier) else { return }
        NSWorkspace.shared.open(url)
    }
}
