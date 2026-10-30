import Combine
import FirstFocusCore
import Foundation

/// Backs the Models tab (ADR 0028). Lives here, not in the `FirstFocus`
/// executable target, for the same reason `HistoryViewModel` does — so
/// `FakeModelDownloader` can drive it in `FirstFocusTestRunner`.
///
/// "Downloaded" vs. "Available" is never stored here — it's
/// `ModelCatalogEntry.isDownloaded`'s own filesystem check, re-read on every
/// access, so a completed download or a delete shows up the moment
/// `objectWillChange` fires with no separate state to keep in sync.
@MainActor
public final class ModelsViewModel: ObservableObject {
    @Published public private(set) var progress: [String: ModelDownloadProgress] = [:]

    private let modelDownloader: any ModelDownloading
    private let extractionSettings: ExtractionSettings
    private let extraction: ExtractionHost
    private let bundleIdentifier: String

    public init(
        modelDownloader: any ModelDownloading, extractionSettings: ExtractionSettings,
        extraction: ExtractionHost, bundleIdentifier: String
    ) {
        self.modelDownloader = modelDownloader
        self.extractionSettings = extractionSettings
        self.extraction = extraction
        self.bundleIdentifier = bundleIdentifier
    }

    /// Every `.gguf` in the models folder, catalog models first in catalog
    /// order, then any others by name. A file the catalog doesn't know
    /// still gets a card, named after the file.
    public var downloadedEntries: [ModelCatalogEntry] {
        let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
        let filenames = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }
        let catalog = ModelCatalog.entries.filter { filenames.contains($0.expectedFilename) }
        let others = filenames
            .filter { name in !ModelCatalog.entries.contains { $0.expectedFilename == name } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(ModelCatalog.localEntry(forFilename:))
        return catalog + others
    }

    /// Re-reads the models folder, for a file added outside the app.
    public func refresh() {
        objectWillChange.send()
    }

    public var availableEntries: [ModelCatalogEntry] {
        ModelCatalog.entries.filter { !$0.isDownloaded(bundleIdentifier: bundleIdentifier) }
    }

    public func isActive(_ entry: ModelCatalogEntry) -> Bool {
        extractionSettings.effectiveModelPath(bundleIdentifier: bundleIdentifier) == entry.localPath(bundleIdentifier: bundleIdentifier)
    }

    public func download(_ entry: ModelCatalogEntry) {
        var starting = ModelDownloadProgress()
        starting.start()
        progress[entry.id] = starting

        let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        modelDownloader.startDownload(
            for: entry,
            destinationPath: entry.localPath(bundleIdentifier: bundleIdentifier),
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.progress[entry.id]?.update(fractionCompleted: fraction)
                }
            },
            onCompletion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.progress[entry.id]?.finish()
                        // Downloaded/Available are derived from disk, not
                        // `@Published` themselves — this is what tells
                        // SwiftUI the card just moved sections.
                        self.objectWillChange.send()
                    case .failure(let error):
                        self.progress[entry.id]?.fail(message: String(describing: error))
                    }
                }
            }
        )
    }

    public func cancelDownload(_ entry: ModelCatalogEntry) {
        modelDownloader.cancelDownload(for: entry)
        progress[entry.id] = nil
    }

    /// The UI layer decides how to ask (an `NSAlert`) — this only decides
    /// when asking is required.
    public func requiresConfirmationBeforeDeleting(_ entry: ModelCatalogEntry) -> Bool {
        isActive(entry)
    }

    /// Deleting the active model also unloads it, so nothing tries to run
    /// a model whose file is gone.
    public func delete(_ entry: ModelCatalogEntry) throws {
        let wasActive = isActive(entry)
        try FileManager.default.removeItem(atPath: entry.localPath(bundleIdentifier: bundleIdentifier))
        if wasActive { extraction.unload() }
        objectWillChange.send()
    }

    /// Tapping a downloaded card, or confirming a custom file from the
    /// picker: both set the path and run the exact same reload sequence the
    /// manual file picker already used before this feature existed — no new
    /// teardown path, no runtime hot-swap of a live `llama_context` (ADR
    /// 0026 is unaffected by this).
    public func select(_ entry: ModelCatalogEntry) async {
        await switchModel(to: entry.localPath(bundleIdentifier: bundleIdentifier))
    }

    public func chooseCustomFile(_ url: URL) async {
        await switchModel(to: url.path)
    }

    /// `isActive` reads the model path from `ExtractionSettings`, which
    /// isn't `@Published`, so the list is told to redraw by hand: once when
    /// the choice changes, so Active and Use move at once, and again when
    /// the reload finishes, alongside the footer.
    private func switchModel(to path: String) async {
        extractionSettings.modelPathOverride = path
        objectWillChange.send()
        await extraction.applySettingsChange()
        objectWillChange.send()
    }
}
