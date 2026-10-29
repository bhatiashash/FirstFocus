import DailyOSApp
import DailyOSCore
import Foundation

final class FakeRuleStore: RuleStore, @unchecked Sendable {
    private(set) var stored: [Rule] = []
    var proposalWatermark: Date?

    func rules() -> [Rule] { stored }

    func add(_ text: String) throws -> Rule {
        guard stored.count < maxRules else { throw RuleStoreError.capReached }
        let rule = Rule(id: UUID().uuidString, text: text, createdAt: Date(), updatedAt: Date())
        stored.append(rule)
        return rule
    }

    func update(id: String, text: String) throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw RuleStoreError.notFound }
        let existing = stored[index]
        stored[index] = Rule(id: id, text: text, createdAt: existing.createdAt, updatedAt: Date())
    }

    func delete(id: String) throws {
        guard stored.contains(where: { $0.id == id }) else { throw RuleStoreError.notFound }
        stored.removeAll { $0.id == id }
    }
}
