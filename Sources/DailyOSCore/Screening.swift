import Foundation

/// What Screening sends off the Mac for one message (ADR 0036): the message
/// to judge and its recent same-chat context, rendered with Participant
/// Labels exactly as Extraction's own `[context]`/`[latest messages]`
/// blocks are, but never with Corrections. Never carries a Contacts name,
/// phone number or email address.
public struct ScreeningInput: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Screening (CONTEXT.md): a remote check that answers, for one message,
/// how likely it is to ask for or commit to something the user should do.
/// `JEVScreener` is the real one. Every failure (timeout, network, bad
/// response) throws, and the caller treats every error the same way: the
/// message goes to the model as if Screening didn't exist.
public protocol Screener: Sendable {
    /// Recorded as the `modelUsed` of the History row a Screening decision
    /// writes.
    var serviceName: String { get }
    func probability(for input: ScreeningInput) async throws -> Double
}

/// How Extraction uses Screening for a pass. `.shadow` (ADR 0036) calls
/// the Screener and records its answer but never keeps a message from the
/// model. `.live` Screens any message scoring below `cutoff`: it is marked
/// Processed with no Signals and never reaches the model.
public enum ScreeningMode: Sendable, Equatable {
    case off
    case shadow
    case live(cutoff: Double)
}

/// The Screener and mode intake is set to right now. Intake reads it at
/// the start of each Batch rather than once per pass, so turning Screening
/// off stops text leaving the Mac from the next Batch, and a Batch already
/// waiting on the Screener finishes that call.
///
/// `@unchecked Sendable`: every access goes through `lock`.
public final class CurrentScreening: @unchecked Sendable {
    private let lock = NSLock()
    private var screener: (any Screener)?
    private var mode: ScreeningMode

    public init(screener: (any Screener)? = nil, mode: ScreeningMode = .off) {
        self.screener = screener
        self.mode = mode
    }

    public var current: (screener: (any Screener)?, mode: ScreeningMode) {
        lock.withLock { (screener, mode) }
    }

    public func set(screener: (any Screener)?) {
        lock.withLock { self.screener = screener }
    }

    /// Both at once, so no Batch reads one changed and not the other.
    public func set(screener: (any Screener)?, mode: ScreeningMode) {
        lock.withLock {
            self.screener = screener
            self.mode = mode
        }
    }

    public func set(mode: ScreeningMode) {
        lock.withLock { self.mode = mode }
    }
}

/// What `ScreeningBreaker` throws instead of calling a Screener it has
/// stopped calling. The Batch goes straight to the model and History
/// records Screening Unavailable (CONTEXT.md).
public struct ScreeningUnavailable: Error, Equatable {
    public init() {}
}

/// How long `ScreeningBreaker` stays open once tripped.
public let screeningBreakerOpenInterval: TimeInterval = 15 * 60

/// Failures in a row, other than a rejected key, that trip `ScreeningBreaker`.
public let screeningBreakerFailureLimit = 3

/// Stops calling a Screener that keeps failing (screening-optional), so an
/// outage doesn't cost every Batch a two-second timeout. A 401 or 403 trips
/// it at once, since a rejected key won't fix itself. Any other failure
/// counts, three in a row trip it, and an answer clears the count. While
/// tripped it throws `ScreeningUnavailable` without calling through. It
/// closes `screeningBreakerOpenInterval` after tripping; the app closes it
/// sooner by building a new one when the key or toggle changes.
///
/// `@unchecked Sendable`: its state is only touched under `lock`.
public final class ScreeningBreaker: Screener, @unchecked Sendable {
    public var serviceName: String { screener.serviceName }
    private let screener: any Screener
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var failures = 0
    private var trippedAt: Date?

    public init(screener: any Screener, now: @escaping @Sendable () -> Date = { Date() }) {
        self.screener = screener
        self.now = now
    }

    public func probability(for input: ScreeningInput) async throws -> Double {
        let isTripped = lock.withLock { () -> Bool in
            guard let trippedAt else { return false }
            guard now().timeIntervalSince(trippedAt) >= screeningBreakerOpenInterval else { return true }
            self.trippedAt = nil
            return false
        }
        if isTripped { throw ScreeningUnavailable() }
        do {
            let probability = try await screener.probability(for: input)
            lock.withLock { failures = 0 }
            return probability
        } catch {
            lock.withLock {
                failures += 1
                if isKeyRejection(error) || failures >= screeningBreakerFailureLimit {
                    trippedAt = now()
                    failures = 0
                }
            }
            throw error
        }
    }
}

private func isKeyRejection(_ error: Error) -> Bool {
    if case .httpStatus(let status) = error as? JEVResponseError { return status == 401 || status == 403 }
    return false
}

/// The one question Screening asks, about a whole Batch (ADR 0039). Version
/// 2 tells JEV what the sender labels mean and to judge only the Batch:
/// version 1 ("Do these messages ask for, or commit to, something the user
/// should do?") never said that "You" is the user, so a request between two
/// other Participants could score as the user's (ADR 0036 amendment).
public let screeningQuestion =
    "'You' is the user; every other label is someone else. In [latest messages], does anyone ask You to do something, or does You commit to doing something?"

/// Bumped whenever `screeningQuestion`'s wording changes. Recorded on every
/// Screening decision so scores from an older wording stay out of the
/// cutoff histogram.
public let screeningQuestionVersion = 2

/// The key the question is filed under in a JEV request and read back
/// from in its answer.
public let jevQuestionKey = "asks_for_action"

/// Pinned rather than `jev-latest`: a cutoff chosen from shadow data is
/// only meaningful against the model version that produced that data.
public let jevModelID = "jev-1.13.0"

public let jevEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

/// The body of one `POST /v1/systemone` call: the rendered message as
/// `state`, and one `noul` (Yes/No probability) question.
public func jevRequestBody(for input: ScreeningInput) throws -> Data {
    let body: [String: Any] = [
        "state": input.text,
        "model": jevModelID,
        "questions": [
            jevQuestionKey: ["type": "noul", "instructions": screeningQuestion],
        ],
    ]
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

public enum JEVResponseError: Error, Equatable {
    case malformed
    case httpStatus(Int)
}

/// Reads `answers.<jevQuestionKey>.noul` out of a JEV response. Anything
/// else, including a probability outside 0...1, is `malformed`.
public func parseJevProbability(_ data: Data) throws -> Double {
    guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let answers = json["answers"] as? [String: Any],
        let answer = answers[jevQuestionKey] as? [String: Any],
        let probability = (answer["noul"] as? NSNumber)?.doubleValue,
        (0...1).contains(probability)
    else { throw JEVResponseError.malformed }
    return probability
}

/// What a Screening failure row's raw output starts with.
public let screeningFailurePrefix = "Screening failed: "

/// A short, plain description of why a Screening call failed, for the
/// History row that records it.
public func screeningFailureReason(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut: return "timed out"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "no network connection"
        default: return "network error (\(urlError.code.rawValue))"
        }
    }
    switch error as? JEVResponseError {
    case .httpStatus(let status) where status == 401 || status == 403: return "HTTP \(status): API key rejected"
    case .httpStatus(429): return "HTTP 429: rate limited"
    case .httpStatus(529): return "HTTP 529: TypeSafe overloaded"
    case .httpStatus(let status): return "HTTP \(status): request rejected"
    case .malformed: return "unreadable response"
    case nil: return "\(error)"
    }
}

/// The mode Extraction should actually run in: `.off` unless Screening is
/// enabled *and* a non-blank API key exists, since there is nothing to call
/// without one.
public func effectiveScreeningMode(settings: ScreeningSettings, apiKey: String?) -> ScreeningMode {
    guard settings.isEnabled, let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .off
    }
    return settings.mode
}

/// Screening's preferences (ADR 0036), in the same thin `UserDefaults`
/// shape `ReExtractionSettings` uses. The API key is deliberately not here:
/// it lives in the Keychain (`APIKeyStore`), never in preferences.
///
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe.
public struct ScreeningSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let enabledKey = "screeningEnabled"
    private static let liveKey = "screeningLive"
    private static let cutoffKey = "screeningCutoff"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off by default: sending message text off the Mac is a choice the
    /// user makes visibly, in Advanced.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Whether the user has switched from shadow to live. Takes effect only
    /// once a cutoff exists (see `mode`).
    public var isLive: Bool {
        get { defaults.bool(forKey: Self.liveKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.liveKey) }
    }

    /// The probability below which a message is Screened in live mode.
    /// `nil` until the user sets one, which is what keeps live mode from
    /// running on a guessed default.
    public var cutoff: Double? {
        get { defaults.object(forKey: Self.cutoffKey) as? Double }
        nonmutating set { defaults.set(newValue, forKey: Self.cutoffKey) }
    }

    /// Live only when chosen *and* a cutoff has been set; shadow otherwise.
    public var mode: ScreeningMode {
        guard isLive, let cutoff else { return .shadow }
        return .live(cutoff: cutoff)
    }
}
