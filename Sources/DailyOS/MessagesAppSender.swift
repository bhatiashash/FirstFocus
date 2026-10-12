import DailyOSCore
import Foundation

/// Production `MessageSender` (ADR 0046): asks Messages.app, through
/// AppleScript, to send one iMessage. Runs `osascript` as a child process
/// so a slow send or the first Automation prompt never blocks the main
/// thread. The text and handle go in as arguments, never spliced into the
/// script, so nothing in a Label can change what the script does.
struct MessagesAppSender: MessageSender {
    private static let script = """
        on run argv
            set theText to item 1 of argv
            set theHandle to item 2 of argv
            tell application "Messages"
                set theService to 1st account whose service type = iMessage
                send theText to participant theHandle of theService
            end tell
        end run
        """

    func send(_ text: String, to handle: String) async -> MorningBriefSendFailure? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", Self.script, text, handle]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return .failed
            }
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("DailyOS: Morning Brief send failed: %@", message)
            return Self.failure(from: message)
        }.value
    }

    /// osascript reports an AppleScript error as "... (-NNNN)". -1743 is
    /// the Automation Gate refusing; -1728 means Messages has no iMessage
    /// account to send from.
    static func failure(from message: String) -> MorningBriefSendFailure {
        if message.contains("(-1743)") { return .notAllowed }
        if message.contains("(-1728)") { return .messagesUnavailable }
        return .failed
    }
}
