import Combine
import DailyOSCore
import Foundation

/// Backs Advanced's Rules section (ADR 0038): the approved list, adding one
/// by hand, editing and deleting. Every change is pushed to the app so the
/// next extraction sees it.
@MainActor
public final class RulesViewModel: ObservableObject {
    @Published public private(set) var rules: [Rule] = []
    @Published public var draft = ""
    @Published public private(set) var errorMessage: String?
    /// Proposed Rules awaiting approve, edit or reject (ADR 0038). Never
    /// stored: `discardPending()` (Advanced closing) drops them.
    @Published public private(set) var pending: [PendingRule] = []
    @Published public private(set) var proposalStatus: RuleProposalStatus = .noModel
    @Published public private(set) var isProposing = false

    private let store: any RuleBook
    private let extraction: ExtractionHost

    public init(store: any RuleBook, extraction: ExtractionHost) {
        self.store = store
        self.extraction = extraction
        rules = store.rules()
        refreshProposalStatus()
    }

    public var canPropose: Bool {
        guard !isProposing, case .ready = proposalStatus else { return false }
        return true
    }

    /// Why "Propose rules" is disabled, or nil when it isn't.
    public var proposeReason: String? {
        switch proposalStatus {
        case .ready: return nil
        case .noModel: return "Needs a loaded model"
        case .passRunning: return "Waiting for Messages to finish"
        case .needsMoreCorrections(let have):
            return "\(have) of \(minimumCorrectionsForProposal) new \u{201C}Not for me\u{201D} Corrections so far"
        }
    }

    public func refreshProposalStatus() {
        proposalStatus = extraction.ruleProposalStatus()
    }

    public func propose() async {
        isProposing = true
        let texts = await extraction.proposeRules()
        isProposing = false
        pending = texts.map { PendingRule(id: UUID().uuidString, text: $0) }
        errorMessage = texts.isEmpty ? "The model didn't propose any Rules." : nil
        refreshProposalStatus()
    }

    /// Adds the pending Rule (as edited) to the approved set. At the cap it
    /// stays pending, with the reason shown.
    public func approve(_ id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, add(trimmed) else { return }
        pending.removeAll { $0.id == id }
    }

    public func reject(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    public func discardPending() {
        pending = []
    }

    public var isAtCap: Bool { rules.count >= maxRules }

    public func addDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if add(trimmed) { draft = "" }
    }

    /// Adds `text` as an approved Rule. Returns false, with a reason in
    /// `errorMessage`, when the cap is reached or the write fails.
    @discardableResult
    public func add(_ text: String) -> Bool {
        do {
            _ = try store.add(text)
        } catch RuleStoreError.capReached {
            errorMessage = "You already have \(maxRules) Rules. Delete one first."
            return false
        } catch {
            errorMessage = "Couldn't save the Rule."
            return false
        }
        changed()
        return true
    }

    public func update(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.update(id: id, text: trimmed)
            changed()
        } catch {
            errorMessage = "Couldn't save the Rule."
        }
    }

    public func delete(id: String) {
        do {
            try store.delete(id: id)
            changed()
        } catch {
            errorMessage = "Couldn't delete the Rule."
        }
    }

    private func changed() {
        rules = store.rules()
        errorMessage = nil
        extraction.applyRules()
    }
}

/// A proposed Rule shown for review, not yet stored.
public struct PendingRule: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
}
