import Foundation

/// A general plain-English instruction to Extraction that the user has
/// approved (CONTEXT.md: Rule; ADR 0038). Applies to every Chat and sits in
/// the fixed system turn.
public struct Rule: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, text: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// At most this many Rules exist at once (ADR 0038), so Rules never crowd
/// out context and Corrections in the prompt.
public let maxRules = 5

public enum RuleStoreError: Error, Equatable {
    case capReached
    case notFound
    case writeFailed
}

/// The approved Rules themselves: what Advanced's Rules section edits and
/// what `AppModel` hands to the extractor (ADR 0021: stores split by
/// caller).
public protocol RuleBook: AnyObject, Sendable {
    /// Oldest first, the order they appear in the prompt.
    func rules() -> [Rule]
    /// Throws `capReached` when `maxRules` already exist.
    func add(_ text: String) throws -> Rule
    func update(id: String, text: String) throws
    func delete(id: String) throws
}

/// When Rules were last proposed, which the next proposal counts new
/// Corrections from. Only `AppModel`'s proposal flow reads or moves it.
public protocol RuleProposalWatermark: AnyObject, Sendable {
    /// `nil` until the first proposal that produced Rules.
    var proposalWatermark: Date? { get set }
}

/// Both halves, for the adapters that provide them and for `AppModel`.
public typealias RuleStore = RuleBook & RuleProposalWatermark
