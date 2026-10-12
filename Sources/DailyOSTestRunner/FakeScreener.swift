import DailyOSCore
import Foundation

/// Stands in for JEV at the `Screener` port. Answers every input with
/// `probability`, or throws when `failure` is set.
final class FakeScreener: Screener, @unchecked Sendable {
    let serviceName = "Fake Screener"
    var probability: Double
    var failure: Error?
    /// Runs inside each call, after the input is recorded and before the
    /// answer, so a test can change settings while a pass is mid-flight.
    var onCall: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var recorded: [ScreeningInput] = []
    /// What one scripted call does.
    enum Outcome {
        case answer
        case fail(Error)
    }

    /// Per-call outcomes, used up in order before `failure` and
    /// `probability` apply.
    private var script: [Outcome] = []

    func script(_ outcomes: [Outcome]) { lock.withLock { script = outcomes } }

    var inputs: [ScreeningInput] { lock.withLock { recorded } }

    init(probability: Double = 0.9, failure: Error? = nil) {
        self.probability = probability
        self.failure = failure
    }

    func probability(for input: ScreeningInput) async throws -> Double {
        lock.withLock { recorded.append(input) }
        await onCall?()
        let scripted: Outcome? = lock.withLock { script.isEmpty ? nil : script.removeFirst() }
        switch scripted {
        case .answer: return probability
        case .fail(let error): throw error
        case nil: break
        }
        if let failure { throw failure }
        return probability
    }
}

/// In-memory `APIKeyStore`, so no test touches the real Keychain.
final class FakeAPIKeyStore: APIKeyStore, @unchecked Sendable {
    var key: String?
    init(key: String? = nil) { self.key = key }
    func read() -> String? { key }
    func write(_ key: String) throws { self.key = key }
    func delete() throws { key = nil }
}

struct FakeScreeningFailure: Error {}
