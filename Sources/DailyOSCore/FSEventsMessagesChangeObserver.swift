import CoreServices
import Foundation

/// Production `MessagesChangeObserver`: an FSEvents stream on the Messages
/// directory, filtered to `chat.db` and its `-wal`/`-shm` siblings. FSEvents
/// rather than a per-file dispatch source because SQLite deletes and
/// recreates the WAL on checkpoint, which would silently orphan a watch
/// held on the old file. Reading these paths needs nothing beyond the Full
/// Disk Access the Messages read already requires.
///
/// Delivers on the main queue, the same as
/// `NotificationCenterEventKitChangeObserver`.
///
/// `@unchecked Sendable`: `stream` and `handler` are set once, from the main
/// thread, before the stream starts, and only read on the main queue after.
/// The stream holds `self` unretained, so the owner must keep this alive for
/// as long as it watches; `main.swift` hands it to the app-lifetime
/// `AppModel`.
public final class FSEventsMessagesChangeObserver: MessagesChangeObserver, @unchecked Sendable {
    private let directory: String
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable () -> Void)?

    /// `directory` is the folder holding `chat.db`, normally
    /// `~/Library/Messages`.
    public init(directory: String) {
        self.directory = directory
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let observer = Unmanaged<FSEventsMessagesChangeObserver>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            guard changed.prefix(count).contains(where: isChatDatabasePath) else { return }
            observer.handler?()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }
}

/// Whether an FSEvents path is `chat.db` itself or one of SQLite's sidecar
/// files for it. Messages' attachments and other databases in the same
/// folder are ignored.
func isChatDatabasePath(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name == "chat.db" || name == "chat.db-wal" || name == "chat.db-shm"
}
