import Foundation

/// Builds the Signal a Reminder reads as. Reminders Signals are never
/// persisted (ADR 0006: every write goes through to Reminders itself, so
/// there is nothing to keep durable locally), so this runs fresh on every
/// fetch rather than once ever like self-thread extraction does.
public func makeSignal(from task: ReminderTask) -> Signal {
    Signal(
        id: task.id,
        source: .reminders,
        sourceRef: task.id,
        label: task.title,
        originalText: task.title,
        createdAt: task.createdAt,
        dueAt: task.dueAt,
        priority: task.priority,
        provenance: .stated,
        notes: task.notes,
        url: task.url
    )
}

/// Whether `sender` looks like a resolved Contacts name rather than the
/// raw phone number or email `CNContactsResolver` falls back to when
/// nothing matches (ADR 0008). `chat.db` always reports an address as a
/// `+`-prefixed phone number or an email; a resolved name is neither
/// shape, so checking for those is enough without needing to track
/// resolution success as a separate flag.
public func isResolvedSenderName(_ sender: String) -> Bool {
    !sender.hasPrefix("+") && !sender.contains("@")
}

/// Sender-on-approval: what `AppModel` hands to `TaskSource.create` when
/// turning a Suggested Signal into a real reminder. `EKReminder` has no
/// Sender field of its own, and the title is the only part of a reminder
/// visible outside DailyOS (Reminders.app, widgets, Siri) — so a resolved
/// Sender is folded into the title here, the one chance for that context
/// to survive the trip. An unresolved sender (still a raw phone number or
/// email) is dropped rather than appended: that reads as noise in a
/// reminder title, not context.
public func approvedReminderDraft(from signal: Signal) -> ReminderDraft {
    let title: String
    if let sender = signal.sender, isResolvedSenderName(sender) {
        title = "\(signal.label) (from \(sender))"
    } else {
        title = signal.label
    }
    return ReminderDraft(
        title: title, dueAt: signal.dueAt, priority: signal.priority,
        notes: signal.originalText,
        url: signal.chatIdentifier.flatMap(messagesChatURL(identifier:))
    )
}
