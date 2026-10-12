import Foundation

/// The network transfer only — no catalog logic, no filesystem-existence
/// checks, no progress state machine. `startDownload` may be called again
/// for the same `entry` after a prior call's `onCompletion` fired; a caller
/// mid-download for the same entry should `cancelDownload` first.
public protocol ModelDownloading: Sendable {
    func startDownload(
        for entry: ModelCatalogEntry,
        destinationPath: String,
        onProgress: @escaping @Sendable (Double) -> Void,
        onCompletion: @escaping @Sendable (Result<Void, Error>) -> Void
    )
    func cancelDownload(for entry: ModelCatalogEntry)
}

public enum ModelDownloadState: Sendable, Equatable {
    case queued
    case downloading(fractionCompleted: Double)
    case completed
    case failed(message: String)
}

/// Pure progress tracking for one catalog entry's download (ticket 04),
/// independent of `URLSession` entirely so it needs no fake to test. The
/// Models tab drives one of these per card from a `ModelDownloading`
/// adapter's callbacks.
public struct ModelDownloadProgress: Sendable, Equatable {
    public private(set) var state: ModelDownloadState = .queued

    public init() {}

    public mutating func start() {
        state = .downloading(fractionCompleted: 0)
    }

    /// Ignored once the download has already reached a terminal state — a
    /// stray late progress callback from a cancelled or superseded task must
    /// never resurrect `.completed`/`.failed` back into `.downloading`.
    public mutating func update(fractionCompleted: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fractionCompleted: fractionCompleted)
    }

    public mutating func finish() {
        state = .completed
    }

    public mutating func fail(message: String) {
        state = .failed(message: message)
    }
}

public enum ModelDownloadError: Error, Equatable {
    case cancelled
    case transferFailed(message: String)
    case couldNotMoveFile
}

/// Real `ModelDownloading`: one plain foreground `URLSession` download task
/// per entry. Not iOS-style background-session-with-relaunch-continuation —
/// DailyOS is a regular Mac app that stays running for the length of a
/// download, so that machinery buys nothing a foreground session doesn't
/// already give.
public final class URLSessionModelDownloader: NSObject, ModelDownloading, @unchecked Sendable {
    private struct Handlers {
        let destinationPath: String
        let onProgress: @Sendable (Double) -> Void
        let onCompletion: @Sendable (Result<Void, Error>) -> Void
    }

    // `@unchecked Sendable`: every mutable access below goes through `lock`.
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var tasksByEntryId: [String: URLSessionDownloadTask] = [:]
    private var handlersByTaskId: [Int: Handlers] = [:]

    override public init() {
        super.init()
    }

    public func startDownload(
        for entry: ModelCatalogEntry,
        destinationPath: String,
        onProgress: @escaping @Sendable (Double) -> Void,
        onCompletion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let downloadURL = entry.downloadURL else {
            onCompletion(.failure(URLError(.unsupportedURL)))
            return
        }
        let task = session.downloadTask(with: downloadURL)
        lock.lock()
        tasksByEntryId[entry.id] = task
        handlersByTaskId[task.taskIdentifier] = Handlers(
            destinationPath: destinationPath, onProgress: onProgress, onCompletion: onCompletion
        )
        lock.unlock()
        task.resume()
    }

    public func cancelDownload(for entry: ModelCatalogEntry) {
        lock.lock()
        let task = tasksByEntryId[entry.id]
        lock.unlock()
        task?.cancel()
    }

    private func handlers(forTaskId taskId: Int) -> Handlers? {
        lock.lock()
        defer { lock.unlock() }
        return handlersByTaskId[taskId]
    }

    private func cleanUp(taskId: Int) {
        lock.lock()
        handlersByTaskId.removeValue(forKey: taskId)
        tasksByEntryId = tasksByEntryId.filter { $0.value.taskIdentifier != taskId }
        lock.unlock()
    }
}

extension URLSessionModelDownloader: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let handlers = handlers(forTaskId: downloadTask.taskIdentifier), totalBytesExpectedToWrite > 0 else { return }
        handlers.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Fires only on a fully successful transfer — a cancelled or otherwise
    /// failed task never reaches this, only `didCompleteWithError`. `location`
    /// is a temp file `URLSession` deletes right after this method returns,
    /// so the move to `destinationPath` has to happen synchronously here.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let handlers = handlers(forTaskId: downloadTask.taskIdentifier) else { return }
        do {
            try? FileManager.default.removeItem(atPath: handlers.destinationPath)
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: handlers.destinationPath))
            handlers.onCompletion(.success(()))
        } catch {
            handlers.onCompletion(.failure(ModelDownloadError.couldNotMoveFile))
        }
        cleanUp(taskId: downloadTask.taskIdentifier)
    }

    /// Called for every task on completion, success or failure — the success
    /// path is already handled by `didFinishDownloadingTo`, so this only acts
    /// when `error` is non-nil.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let handlers = handlers(forTaskId: task.taskIdentifier) else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            handlers.onCompletion(.failure(ModelDownloadError.cancelled))
        } else {
            handlers.onCompletion(.failure(ModelDownloadError.transferFailed(message: error.localizedDescription)))
        }
        cleanUp(taskId: task.taskIdentifier)
    }
}
