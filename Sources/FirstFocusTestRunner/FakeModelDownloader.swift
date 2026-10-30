import FirstFocusCore
import Foundation

/// Test double for `ModelDownloading`. Records what it was asked to do and
/// lets a test drive its callbacks by hand (`simulateProgress`/
/// `simulateSuccess`/`simulateFailure`) — no real network call, matching
/// `FakeIntentExtractor`'s own "map exact input to a controlled response"
/// shape.
///
/// `@unchecked Sendable`: every test calls this synchronously on one
/// thread, same justification `FakeIntentExtractor` already carries.
final class FakeModelDownloader: ModelDownloading, @unchecked Sendable {
    private struct Handlers {
        let destinationPath: String
        let onProgress: @Sendable (Double) -> Void
        let onCompletion: @Sendable (Result<Void, Error>) -> Void
    }

    private var handlersByEntryId: [String: Handlers] = [:]
    private(set) var startedEntryIds: [String] = []
    private(set) var cancelledEntryIds: [String] = []

    func startDownload(
        for entry: ModelCatalogEntry, destinationPath: String,
        onProgress: @escaping @Sendable (Double) -> Void, onCompletion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        startedEntryIds.append(entry.id)
        handlersByEntryId[entry.id] = Handlers(destinationPath: destinationPath, onProgress: onProgress, onCompletion: onCompletion)
    }

    func cancelDownload(for entry: ModelCatalogEntry) {
        cancelledEntryIds.append(entry.id)
    }

    func simulateProgress(for entry: ModelCatalogEntry, fraction: Double) {
        handlersByEntryId[entry.id]?.onProgress(fraction)
    }

    /// Matches the real adapter's own behavior: a successful download
    /// actually places a file at `destinationPath`, since a caller
    /// (`ModelsViewModel.downloadedEntries`) determines "downloaded" from
    /// the filesystem, never from state this fake or the real adapter carry.
    func simulateSuccess(for entry: ModelCatalogEntry) {
        guard let handlers = handlersByEntryId[entry.id] else { return }
        FileManager.default.createFile(atPath: handlers.destinationPath, contents: Data())
        handlers.onCompletion(.success(()))
    }

    func simulateFailure(for entry: ModelCatalogEntry, message: String) {
        handlersByEntryId[entry.id]?.onCompletion(.failure(ModelDownloadError.transferFailed(message: message)))
    }
}
