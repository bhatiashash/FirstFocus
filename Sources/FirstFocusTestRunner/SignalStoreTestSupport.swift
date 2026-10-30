import FirstFocusCore
import Foundation
import SQLite3

extension BatchLedger {
    /// Seeds `messageId` as Processed the way production records it: a
    /// Batch holding just that one message, with `signals` as its result.
    func recordOneMessageBatch(_ messageId: String, chatId: Int = 0, signals: [Signal]) throws {
        let message = ChatMessage(id: messageId, chatId: chatId, isFromMe: false, text: "", createdAt: Date(timeIntervalSince1970: 0))
        try recordProcessedBatch(MessageBatch(messages: [message]), signals: signals)
    }
}

/// Seeds `messageId` in the SQLite store at `path` as a message Processed
/// before Batches existed: Processed, holding `signals`, with no Batch
/// recorded. Production can no longer write this state, so a test that
/// needs it records a one-message Batch and then removes the Batch row.
func seedPreBatchMessage(_ messageId: String, signals: [Signal], inStoreAt path: String) throws {
    try SQLiteSignalStore(path: path).recordOneMessageBatch(messageId, signals: signals)
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    try expect(sqlite3_open(path, &db) == SQLITE_OK)
    try expect(sqlite3_exec(db, "DELETE FROM batches WHERE batch_id = '\(messageId)'", nil, nil, nil) == SQLITE_OK)
}

/// Where this run's store files go. Removed when the run ends
/// (`removeTestStores()`), so each run starts from nothing.
let testStoreDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("firstfocus-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// A path for a fresh SQLite store file of this run's own.
func testStorePath() -> String {
    try? FileManager.default.createDirectory(at: testStoreDirectory, withIntermediateDirectories: true)
    return testStoreDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
}

/// A fresh, empty Signal store on disk: the real adapter, not a fake.
func makeTestSignalStore() -> SQLiteSignalStore {
    SQLiteSignalStore(path: testStorePath())
}

func removeTestStores() {
    try? FileManager.default.removeItem(at: testStoreDirectory)
}
