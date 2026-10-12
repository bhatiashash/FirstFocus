import Foundation

/// Why a Morning Brief didn't go out.
public enum MorningBriefSendFailure: String, Equatable, Sendable {
    /// The Automation Gate for Messages.app was denied or revoked.
    case notAllowed
    /// Messages.app couldn't send: signed out, or no iMessage account.
    case messagesUnavailable
    /// Anything else Messages.app reported.
    case failed
}

/// Sends one iMessage from this Mac (ADR 0046). The production adapter
/// drives Messages.app through AppleScript; tests use a fake.
public protocol MessageSender: Sendable {
    /// `nil` once Messages.app accepted the message.
    func send(_ text: String, to handle: String) async -> MorningBriefSendFailure?
}

/// What the status line under the toggle reports: the last send, test or
/// scheduled.
public enum MorningBriefStatus: Equatable, Sendable {
    case never
    case sent(Date)
    case failed(Date, MorningBriefSendFailure)
}

/// The Morning Brief's stored settings and record, in `UserDefaults`.
/// `@unchecked Sendable` for the same reason as `ZenFocusModePreference`.
public struct MorningBriefPreference: @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let enabled = "morningBriefEnabled"
        static let lastOutcomeAt = "morningBriefLastOutcomeAt"
        static let lastFailure = "morningBriefLastFailure"
        static let lastDailySentAt = "morningBriefLastDailySentAt"
        static let body = "morningBriefFormatBody"
        static let itemLine = "morningBriefFormatItemLine"
        static let limit = "morningBriefFormatLimit"
        static let sendMinute = "morningBriefSendMinute"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// When the daily Brief goes out; 8:00 AM until you change it.
    public var sendTime: MorningBriefTime {
        get {
            guard let minutes = defaults.object(forKey: Key.sendMinute) as? Int else { return .standard }
            return MorningBriefTime(hour: minutes / 60, minute: minutes % 60)
        }
        nonmutating set { defaults.set(newValue.hour * 60 + newValue.minute, forKey: Key.sendMinute) }
    }

    /// The layout you set in Advanced; the standard one until you edit it.
    public var format: MorningBriefFormat {
        get {
            let standard = MorningBriefFormat.standard
            return MorningBriefFormat(
                body: defaults.string(forKey: Key.body) ?? standard.body,
                itemLine: defaults.string(forKey: Key.itemLine) ?? standard.itemLine,
                limit: defaults.object(forKey: Key.limit) as? Int
            )
        }
        nonmutating set {
            defaults.set(newValue.body, forKey: Key.body)
            defaults.set(newValue.itemLine, forKey: Key.itemLine)
            defaults.set(newValue.limit, forKey: Key.limit)
        }
    }

    /// When the last scheduled Brief went out. A test send never sets it.
    public var lastDailySentAt: Date? {
        get { defaults.object(forKey: Key.lastDailySentAt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastDailySentAt) }
    }

    public var status: MorningBriefStatus {
        get {
            guard let at = defaults.object(forKey: Key.lastOutcomeAt) as? Date else { return .never }
            guard let raw = defaults.string(forKey: Key.lastFailure) else { return .sent(at) }
            return .failed(at, MorningBriefSendFailure(rawValue: raw) ?? .failed)
        }
        nonmutating set {
            switch newValue {
            case .never:
                defaults.removeObject(forKey: Key.lastOutcomeAt)
                defaults.removeObject(forKey: Key.lastFailure)
            case .sent(let at):
                defaults.set(at, forKey: Key.lastOutcomeAt)
                defaults.removeObject(forKey: Key.lastFailure)
            case .failed(let at, let failure):
                defaults.set(at, forKey: Key.lastOutcomeAt)
                defaults.set(failure.rawValue, forKey: Key.lastFailure)
            }
        }
    }
}

/// A time of day for the daily Brief, in the Mac's local time.
public struct MorningBriefTime: Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// 8:00 AM, the same moment Snooze returns (ADR 0045).
    public static let standard = MorningBriefTime(hour: snoozeEndHour, minute: 0)

    /// This time on `moment`'s day.
    func on(_ moment: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: moment)
    }
}

/// How long after the send time a missed Brief still goes out. Four
/// hours keeps 8:00 AM's noon cutoff.
private let catchUpWindow: TimeInterval = 4 * 3600

/// Sends the Morning Brief (ADR 0046) and records how it went: once a day
/// at the send time while the toggle is on, or at the first launch, wake or
/// toggle-on within four hours of it when that moment was missed. The
/// window never runs past midnight. A failure doesn't count, so
/// the next of those tries again. A test send never counts.
@MainActor
public final class MorningBriefDelivery {
    private let preference: MorningBriefPreference
    private let sender: any MessageSender
    private let recipient: @MainActor () -> String?
    private let compose: @MainActor () -> String
    private let now: @MainActor () -> Date
    private let clock: any UndoClock

    /// Tells a stale 8:00 timer from the current one.
    private var timerToken = 0
    /// A wake and the 8:00 timer arriving together send one Brief.
    private var isSendingDaily = false

    public private(set) var status: MorningBriefStatus {
        didSet { onChange?() }
    }
    /// Fires whenever `status` changes.
    public var onChange: (() -> Void)?

    /// `recipient` is your own number, read when sending: the Brief only
    /// ever goes to you. `compose` builds it from the Ranked List as it is
    /// at the moment of sending.
    public init(
        preference: MorningBriefPreference, sender: any MessageSender, recipient: @escaping @MainActor () -> String?,
        compose: @escaping @MainActor () -> String,
        now: @escaping @MainActor () -> Date = { Date() }, clock: any UndoClock = TaskSleepUndoClock()
    ) {
        self.preference = preference
        self.sender = sender
        self.recipient = recipient
        self.compose = compose
        self.now = now
        self.clock = clock
        self.status = preference.status
    }

    /// Sends a Brief now, whether or not the toggle is on. Never counts as
    /// the day's Brief.
    public func sendTest() async {
        _ = await send()
    }

    /// At launch: sends a missed Brief, then sets the 8:00 timer.
    public func start() async {
        await sendIfDue()
        scheduleNext()
    }

    /// On wake from sleep: the same as launch. The timer counts no time
    /// asleep, so it is set again from the real clock.
    public func systemDidWake() async {
        await start()
    }

    public func setEnabled(_ isEnabled: Bool) async {
        preference.isEnabled = isEnabled
        await sendIfDue()
    }

    /// Changing the time sets the timer again; it sends nothing by itself.
    public func setSendTime(_ time: MorningBriefTime) async {
        preference.sendTime = time
        scheduleNext()
    }

    private func sendIfDue() async {
        guard preference.isEnabled else { return }
        let moment = now()
        let calendar = Calendar.current
        guard let sendAt = preference.sendTime.on(moment, calendar: calendar),
              let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: moment)),
              moment >= sendAt, moment < min(sendAt.addingTimeInterval(catchUpWindow), midnight)
        else { return }
        if let last = preference.lastDailySentAt, calendar.isDate(last, inSameDayAs: moment) { return }
        guard !isSendingDaily else { return }
        isSendingDaily = true
        defer { isSendingDaily = false }
        if await send() {
            preference.lastDailySentAt = moment
        }
    }

    private func scheduleNext() {
        timerToken += 1
        let token = timerToken
        let moment = now()
        let calendar = Calendar.current
        guard let todayAt = preference.sendTime.on(moment, calendar: calendar),
              let next = todayAt > moment ? todayAt : calendar.date(byAdding: .day, value: 1, to: todayAt)
        else { return }
        clock.scheduleOnce(after: next.timeIntervalSince(moment)) { [weak self] in
            Task { @MainActor in
                guard let self, self.timerToken == token else { return }
                await self.sendIfDue()
                self.scheduleNext()
            }
        }
    }

    /// Whether Messages.app accepted it. Records the outcome either way.
    private func send() async -> Bool {
        guard let recipient = recipient() else { return false }
        let failure = await sender.send(compose(), to: recipient)
        let outcome: MorningBriefStatus = failure.map { .failed(now(), $0) } ?? .sent(now())
        preference.status = outcome
        status = outcome
        return failure == nil
    }
}
