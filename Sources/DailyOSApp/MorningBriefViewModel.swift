import Combine
import DailyOSCore
import Foundation

/// Advanced's Morning Brief section (ADR 0046): your number, the daily
/// send, the format, Send Test and the status line.
@MainActor
public final class MorningBriefViewModel: ObservableObject {
    /// Your Self-thread's address, where the Brief goes. Not editable:
    /// the Brief only ever goes to you.
    @Published public private(set) var myNumber: String?
    /// When the daily Brief goes out. Set through `setSendTime(_:)`.
    @Published public private(set) var sendTime: MorningBriefTime
    /// The daily send. Set through `setEnabled(_:)`.
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isSending = false
    @Published public private(set) var statusText: String?
    /// The layout below the fixed header, saved as you edit it.
    @Published public var format: MorningBriefFormat {
        didSet { preference.format = format }
    }

    /// What the Brief would say right now with `format`.
    public var preview: String { makePreview(format) }

    /// The choices for how many Focus Signals the Brief lists; `nil` is All.
    public static let limitChoices: [Int?] = [3, 5, 10, nil]

    private let delivery: MorningBriefDelivery
    private let preference: MorningBriefPreference
    private let makePreview: (MorningBriefFormat) -> String
    private let readMyNumber: @MainActor () -> String?

    /// `myNumber` reads your Self-thread's address from Messages; `nil`
    /// without Full Disk Access or a conversation with yourself.
    /// `preview` builds the Brief from the current Ranked List with a
    /// format, for the format editor.
    public init(
        delivery: MorningBriefDelivery, preference: MorningBriefPreference, myNumber: @escaping @MainActor () -> String?,
        preview: @escaping (MorningBriefFormat) -> String
    ) {
        self.delivery = delivery
        self.preference = preference
        self.makePreview = preview
        self.readMyNumber = myNumber
        self.myNumber = myNumber()
        self.format = preference.format
        self.isEnabled = preference.isEnabled
        self.sendTime = preference.sendTime
        self.statusText = Self.describe(delivery.status)
        delivery.onChange = { [weak self] in
            guard let self else { return }
            self.statusText = Self.describe(self.delivery.status)
        }
    }

    public var canSend: Bool {
        !isSending && hasPhoneNumber
    }

    /// Turning the daily send on needs somewhere to send it; turning it
    /// off never does.
    public var canEnable: Bool {
        isEnabled || hasPhoneNumber
    }

    private var hasPhoneNumber: Bool {
        myNumber != nil
    }

    /// Reads the Self-thread's address again, for when Advanced opens.
    public func refresh() {
        myNumber = readMyNumber()
    }

    /// Turning it on between 8:00 AM and noon sends today's Brief if none
    /// went out yet.
    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        isSending = enabled
        await delivery.setEnabled(enabled)
        isSending = false
    }

    public func setSendTime(_ time: MorningBriefTime) async {
        sendTime = time
        await delivery.setSendTime(time)
    }

    public func resetFormat() {
        format = .standard
    }

    public func sendTest() async {
        guard canSend else { return }
        isSending = true
        await delivery.sendTest()
        isSending = false
    }

    private static func describe(_ status: MorningBriefStatus) -> String? {
        switch status {
        case .never:
            return nil
        case .sent(let at):
            return "Last sent \(moment(at))."
        case .failed(let at, let failure):
            return "Last send failed \(moment(at)). \(reason(failure))"
        }
    }

    private static func reason(_ failure: MorningBriefSendFailure) -> String {
        switch failure {
        case .notAllowed:
            "FirstFocus isn't allowed to control Messages. Turn it on in System Settings > Privacy & Security > Automation."
        case .messagesUnavailable:
            "Check that Messages is signed in to iMessage."
        case .failed:
            "Messages couldn't send it."
        }
    }

    private static func moment(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
