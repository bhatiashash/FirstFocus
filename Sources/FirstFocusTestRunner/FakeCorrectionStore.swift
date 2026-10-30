import FirstFocusCore
import Foundation

/// Test double for `CorrectionStore`. Holds corrections in memory and
/// decides nothing about which ones are the same (that is `Corrections`'
/// job); returns newest-first, matching `SQLiteCorrectionStore`'s own
/// `ORDER BY created_at DESC`.
final class FakeCorrectionStore: CorrectionStore, @unchecked Sendable {
    private(set) var stored: [Correction] = []

    func record(_ correction: Correction) throws {
        stored.append(correction)
    }

    func replace(_ correction: Correction) throws {
        if let sourceRef = correction.sourceRef {
            stored.removeAll { $0.sourceRef == sourceRef && $0.correctionType == correction.correctionType }
        }
        stored.append(correction)
    }

    func delete(sourceRef: String, type: CorrectionType) throws {
        stored.removeAll { $0.sourceRef == sourceRef && $0.correctionType == type }
    }

    func correctionTypes(forSourceRefs sourceRefs: Set<String>) -> [String: Set<CorrectionType>] {
        stored.reduce(into: [:]) { types, correction in
            guard let sourceRef = correction.sourceRef, sourceRefs.contains(sourceRef) else { return }
            types[sourceRef, default: []].insert(correction.correctionType)
        }
    }

    func corrections(forChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction] {
        newestFirst { $0.chatId == chatId && $0.correctionType == type }.prefix(limit).map { $0 }
    }

    func globalCorrections(excludingChatId chatId: Int, limit: Int, type: CorrectionType) -> [Correction] {
        newestFirst { $0.chatId != chatId && $0.correctionType == type }.prefix(limit).map { $0 }
    }

    func corrections(ofType type: CorrectionType, createdAfter date: Date?, limit: Int) -> [Correction] {
        stored
            .filter { correction in
                correction.correctionType == type && (date.map { correction.createdAt > $0 } ?? true)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    func globalCorrections(excludingChatId chatId: Int, limit: Int) -> [Correction] {
        stored
            .filter { $0.chatId != chatId }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    private func newestFirst(_ include: (Correction) -> Bool) -> [Correction] {
        stored.filter(include).sorted { $0.createdAt > $1.createdAt }
    }
}
