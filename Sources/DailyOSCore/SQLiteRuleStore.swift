import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Production `RuleStore`, in the same SQLite file as the other stores.
/// Opens and closes a connection per call, the same posture
/// `SQLiteHistoryStore` takes.
public final class SQLiteRuleStore: RuleStore, @unchecked Sendable {
    private let path: String
    private var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    public static func defaultPath(bundleIdentifier: String) -> String {
        SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier)
    }

    public func rules() -> [Rule] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id, text, created_at, updated_at FROM rules ORDER BY created_at ASC, rowid ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var results: [Rule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = text(statement!, 0), let body = text(statement!, 1),
                let created = text(statement!, 2).flatMap(dateFormatter.date(from:)),
                let updated = text(statement!, 3).flatMap(dateFormatter.date(from:))
            else { continue }
            results.append(Rule(id: id, text: body, createdAt: created, updatedAt: updated))
        }
        return results
    }

    public func add(_ ruleText: String) throws -> Rule {
        guard rules().count < maxRules else { throw RuleStoreError.capReached }
        let now = Date()
        let rule = Rule(id: UUID().uuidString, text: ruleText, createdAt: now, updatedAt: now)
        try execute("INSERT INTO rules (id, text, created_at, updated_at) VALUES (?, ?, ?, ?)", [
            rule.id, rule.text, dateFormatter.string(from: now), dateFormatter.string(from: now),
        ])
        return rule
    }

    public func update(id: String, text ruleText: String) throws {
        let changed = try execute(
            "UPDATE rules SET text = ?, updated_at = ? WHERE id = ?", [ruleText, dateFormatter.string(from: Date()), id]
        )
        guard changed > 0 else { throw RuleStoreError.notFound }
    }

    public func delete(id: String) throws {
        let changed = try execute("DELETE FROM rules WHERE id = ?", [id])
        guard changed > 0 else { throw RuleStoreError.notFound }
    }

    public var proposalWatermark: Date? {
        get {
            guard let db = open() else { return nil }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM rule_meta WHERE key = 'proposal_watermark'", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW
            else { return nil }
            return text(statement!, 0).flatMap(dateFormatter.date(from:))
        }
        set {
            if let newValue {
                _ = try? execute(
                    "INSERT INTO rule_meta (key, value) VALUES ('proposal_watermark', ?) "
                        + "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                    [dateFormatter.string(from: newValue)]
                )
            } else {
                _ = try? execute("DELETE FROM rule_meta WHERE key = 'proposal_watermark'", [])
            }
        }
    }

    /// Runs one write and returns how many rows it changed.
    @discardableResult
    private func execute(_ sql: String, _ values: [String]) throws -> Int {
        guard let db = open() else { throw RuleStoreError.writeFailed }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RuleStoreError.writeFailed }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw RuleStoreError.writeFailed }
        return Int(sqlite3_changes(db))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS rules (
            id TEXT PRIMARY KEY, text TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rule_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }
}
