import EventKit
import Foundation

/// Which of the coordinator's triggers fired. `sourcesToRefresh(for:)`
/// below says which Source(s) that means — the coordinator itself knows
/// nothing about Sources, only about when to ask for a refresh. All three
/// trigger paths call the same `onRefresh` closure; that single callback is
/// what spec's Refresh section means by "one shared recompute-and-rerank
/// call," not that every trigger does the same work once inside it. In
/// particular a Reminders refresh (`.eventKitChange`) must never touch the
/// Messages model — see ticket 11.
public enum RefreshTrigger: Sendable {
    case interval
    case eventKitChange
    case foreground
    /// A write to `chat.db` or its write-ahead log (ADR 0034 amendment),
    /// grouped over `messagesChangeDebounce` so a burst of writes asks for
    /// one refresh. The `.interval` poll stays as the backstop for a missed
    /// event.
    case messagesChanged
    /// A Batch that a pass left open is due to close (ADR 0039), scheduled
    /// by Messages Intake itself rather than by this coordinator.
    case batchDue
    /// The calendar day changed: midnight, or waking after sleeping
    /// through it. Tier and the overdue colour depend on the day
    /// (ADR 0042), so the Ranked List is derived again; no Source has
    /// anything new to say.
    case dayChanged
}

/// Ticket 11's rule for which Source(s) a given trigger means to refresh,
/// named and testable on its own rather than left as a switch inline in
/// `AppModel.handleRefresh`. The interval trigger is `chat.db`-only, since
/// Reminders already has its own free push (`.eventKitChange`); foreground
/// refreshes both, since either Source's Gate could have changed while the
/// window was in the background.
public func sourcesToRefresh(for trigger: RefreshTrigger) -> Set<Source> {
    switch trigger {
    case .interval, .messagesChanged, .batchDue:
        return [.messages]
    case .eventKitChange:
        return [.reminders]
    case .foreground:
        return [.reminders, .messages]
    case .dayChanged:
        return []
    }
}

/// Owns the two triggers a Source port has no business scheduling itself
/// (ticket 11): the `chat.db` poll timer and the EventKit change
/// subscription. Unifying those with Reminders' free push trigger would
/// mean either downgrading it to polling or wrapping `chat.db` in a fake
/// push, so each trigger stays independent and all of them funnel into one
/// callback instead.
///
/// The foreground trigger has no clock or notification source of its own —
/// it's an AppKit window-lifecycle event this EventKit-only, AppKit-free
/// module doesn't depend on — so callers report it directly through
/// `foregroundBecameActive()`, and it still funnels through the same
/// `onRefresh` callback as the other two.
public final class RefreshCoordinator {
    private let onRefresh: @Sendable (RefreshTrigger) -> Void

    public init(
        pollInterval: TimeInterval,
        clock: any RefreshClock,
        eventKitChanges: any EventKitChangeObserver,
        foreground: (any ForegroundObserver)? = nil,
        messagesChanges: (any MessagesChangeObserver)? = nil,
        dayChanges: (any DayChangeObserver)? = nil,
        debounceClock: any UndoClock = TaskSleepUndoClock(),
        messagesChangeDebounce: TimeInterval = 1,
        onRefresh: @escaping @Sendable (RefreshTrigger) -> Void
    ) {
        self.onRefresh = onRefresh
        // Messages writes `chat.db` and its WAL several times per incoming
        // message, so unlike the EventKit notification below, these are
        // grouped: the first change opens a window, later ones inside it
        // are absorbed, and one refresh fires when it closes.
        // `UndoClock` is just the codebase's one-shot timer seam, reused.
        let grouper = ChangeGrouper()
        messagesChanges?.onChange {
            guard grouper.open() else { return }
            debounceClock.scheduleOnce(after: messagesChangeDebounce) {
                grouper.close()
                onRefresh(.messagesChanged)
            }
        }
        clock.scheduleRepeating(interval: pollInterval) {
            onRefresh(.interval)
        }
        // No coalescing: every notification calls onRefresh immediately,
        // rather than debouncing into one call for a burst of edits.
        eventKitChanges.onChange {
            onRefresh(.eventKitChange)
        }
        foreground?.onForeground {
            onRefresh(.foreground)
        }
        dayChanges?.onDayChange {
            onRefresh(.dayChanged)
        }
    }

    public func foregroundBecameActive() {
        onRefresh(.foreground)
    }
}

/// Whether a grouping window for Messages changes is currently open.
/// `open()` returns true only for the change that opens a new window.
/// `@unchecked Sendable`: its one piece of state is only touched under
/// `lock`.
private final class ChangeGrouper: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() -> Bool {
        lock.withLock {
            guard !isOpen else { return false }
            isOpen = true
            return true
        }
    }

    func close() {
        lock.withLock { isOpen = false }
    }
}

/// Writes to `chat.db` and its write-ahead log (ADR 0034 amendment). A
/// protocol so a test can fire a change without touching the filesystem;
/// `FSEventsMessagesChangeObserver` is the real one.
public protocol MessagesChangeObserver {
    func onChange(_ handler: @escaping @Sendable () -> Void)
}

/// Reports nothing. `AppModel`'s default, so a test (or any caller that
/// doesn't pass the real `FSEventsMessagesChangeObserver`) never starts
/// watching this machine's real Messages folder; `main.swift` passes the
/// real one.
public struct NoMessagesChangeObserver: MessagesChangeObserver {
    public init() {}
    public func onChange(_ handler: @escaping @Sendable () -> Void) {}
}

/// The window coming to the foreground, the one trigger whose only real
/// source is AppKit. A protocol so this module stays AppKit-free and so a
/// test can fire the trigger without a running application; the
/// `NSApplication` adapter lives in the executable. Optional in
/// `RefreshCoordinator.init`, since `foregroundBecameActive()` remains a
/// perfectly good way for a caller to report it directly.
public protocol ForegroundObserver {
    func onForeground(_ handler: @escaping @Sendable () -> Void)
}

/// The interval timer `RefreshCoordinator` schedules `chat.db` polling
/// through. A protocol, not a direct `Timer` call, so tests can fire the
/// interval trigger on demand instead of waiting on a real clock.
public protocol RefreshClock {
    func scheduleRepeating(interval: TimeInterval, _ action: @escaping @Sendable () -> Void)
}

/// The EventKit change subscription `RefreshCoordinator` reads Reminders
/// edits and revocation through. A protocol, not a direct
/// `NotificationCenter` observer, so tests can fire the change-notification
/// trigger without a real EventKit connection.
public protocol EventKitChangeObserver {
    func onChange(_ handler: @escaping @Sendable () -> Void)
}

/// Production `RefreshClock`, backed by a repeating `Foundation.Timer` on
/// the current run loop.
public final class TimerRefreshClock: RefreshClock {
    private var timer: Timer?

    public init() {}

    public func scheduleRepeating(interval: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
    }
}

/// The calendar day changing. A protocol so a test can fire midnight on
/// demand; `NotificationCenterDayChangeObserver` is the real one.
public protocol DayChangeObserver {
    func onDayChange(_ handler: @escaping @Sendable () -> Void)
}

/// Production `DayChangeObserver`, backed by `.NSCalendarDayChanged`. The
/// system posts it at midnight and, if the Mac slept through midnight, on
/// wake, which a timer set for midnight would miss.
public final class NotificationCenterDayChangeObserver: DayChangeObserver {
    public init() {}

    public func onDayChange(_ handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { _ in
            handler()
        }
    }
}

/// Production `EventKitChangeObserver`, backed by `.EKEventStoreChanged` — the
/// same notification ticket 10's Reminders revocation detection reads.
public final class NotificationCenterEventKitChangeObserver: EventKitChangeObserver {
    public init() {}

    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { _ in
            handler()
        }
    }
}
