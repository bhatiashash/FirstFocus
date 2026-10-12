import Foundation

/// One of the three local models the Models tab knows how to fetch (ADR
/// 0028). `expectedFilename` is what `isDownloaded` checks for under
/// `LlamaCppIntentExtractor.modelsDirectoryURL` — the catalog has no
/// separate "have I downloaded this" flag of its own, since the filesystem
/// is already the source of truth.
public struct ModelCatalogEntry: Sendable, Equatable, Identifiable {
    public var id: String { expectedFilename }
    public let displayName: String
    public let quantization: String
    /// `nil` for a `.gguf` found in the models folder that the catalog
    /// doesn't know (`ModelCatalog.localEntry(forFilename:)`).
    public let downloadURL: URL?
    public let expectedFilename: String

    public init(displayName: String, quantization: String, downloadURL: URL?, expectedFilename: String) {
        self.displayName = displayName
        self.quantization = quantization
        self.downloadURL = downloadURL
        self.expectedFilename = expectedFilename
    }

    public func localPath(bundleIdentifier: String) -> String {
        LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(expectedFilename)
            .path
    }

    public func isDownloaded(bundleIdentifier: String) -> Bool {
        FileManager.default.fileExists(atPath: localPath(bundleIdentifier: bundleIdentifier))
    }
}

public enum ModelCatalog {
    /// All Q4_K_M — matches the quantization already in production use
    /// (`LlamaCppIntentExtractor.defaultModelPath`'s Qwen3-4B entry below),
    /// not the Q3_K_M or the 1.5B/3B/7B tier list floated in an earlier,
    /// unrelated proposal.
    public static let entries: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            displayName: "Qwen2.5-3B-Instruct",
            quantization: "Q4_K_M",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
            expectedFilename: "Qwen2.5-3B-Instruct-Q4_K_M.gguf"
        ),
        ModelCatalogEntry(
            displayName: "Llama-3.2-3B-Instruct",
            quantization: "Q4_K_M",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            expectedFilename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ),
        // Filename matches `LlamaCppIntentExtractor.defaultModelPath` exactly
        // on purpose: a machine that already has the shipped default
        // downloaded shows this catalog entry as already-downloaded, with
        // nothing to re-fetch.
        ModelCatalogEntry(
            displayName: "Qwen3-4B-Instruct",
            quantization: "Q4_K_M",
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            expectedFilename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        ),
    ]

    /// A friendlier name than a raw `.gguf` filename for the footer/History
    /// display, for a model that happens to match a catalog entry. Falls
    /// back to `fallback` (`IntentExtractor.modelDisplayName`) for anything
    /// downloaded or chosen outside the catalog.
    public static func displayName(forFilename filename: String, fallback: String) -> String {
        entries.first { $0.expectedFilename == filename }?.displayName ?? fallback
    }

    /// The entry for a `.gguf` in the models folder: its catalog entry, or
    /// for a file the catalog doesn't know, one named after the file (no
    /// extension), with no quantization and nothing to download.
    public static func localEntry(forFilename filename: String) -> ModelCatalogEntry {
        entries.first { $0.expectedFilename == filename } ?? ModelCatalogEntry(
            displayName: (filename as NSString).deletingPathExtension,
            quantization: "",
            downloadURL: nil,
            expectedFilename: filename
        )
    }
}
