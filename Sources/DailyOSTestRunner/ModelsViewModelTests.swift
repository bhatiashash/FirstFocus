import Combine
import DailyOSApp
import DailyOSCore
import Foundation

/// `select(_:)` and `chooseCustomFile(_:)` reload the model through a real
/// `ExtractionHost` whose loader is a test's (`TestExtraction`), so no test
/// reads a real `.gguf` off disk.
private final class ChangeCounter: @unchecked Sendable {
    var count = 0
    var subscription: AnyCancellable?
}

private func freshBundleIdentifier() -> String {
    "com.shashbhatia.DailyOSTests-\(UUID().uuidString)"
}

private func cleanUp(bundleIdentifier: String) {
    try? FileManager.default.removeItem(
        at: LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier).deletingLastPathComponent()
    )
}

@MainActor
private func makeViewModel(
    bundleIdentifier: String, downloader: FakeModelDownloader = FakeModelDownloader(),
    reloader: TestExtraction = TestExtraction(),
    extractionSettings: ExtractionSettings? = nil
) -> ModelsViewModel {
    let defaults = UserDefaults(suiteName: "dailyos-tests-models-viewmodel-\(UUID().uuidString)")!
    return ModelsViewModel(
        modelDownloader: downloader, extractionSettings: extractionSettings ?? ExtractionSettings(defaults: defaults),
        extraction: reloader.host, bundleIdentifier: bundleIdentifier
    )
}

func registerModelsViewModelTests(_ runner: TestRunner) {
    runner.suite("ModelsViewModel") { r in
        r.run("partitions the catalog into downloaded and available based on what's actually on disk") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())

            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier) }
            try await MainActor.run {
                try expect(viewModel.downloadedEntries.map(\.id) == [entry.id])
                try expect(viewModel.availableEntries.count == ModelCatalog.entries.count - 1)
            }
        }

        r.run("a .gguf the catalog doesn't know is listed as downloaded, named after the file") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("TEST.gguf").path, contents: Data())
            FileManager.default.createFile(atPath: directory.appendingPathComponent("notes.txt").path, contents: Data())
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())

            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier) }
            try await MainActor.run {
                let downloaded = viewModel.downloadedEntries
                try expect(downloaded.map(\.id) == [entry.id, "TEST.gguf"])
                try expect(downloaded.last?.displayName == "TEST")
                try expect(downloaded.last?.downloadURL == nil)
                try expect(viewModel.availableEntries.count == ModelCatalog.entries.count - 1)
            }
        }

        r.run("download reports progress as the downloader reports it") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let downloader = FakeModelDownloader()
            let entry = try require(ModelCatalog.entries.first)
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier, downloader: downloader) }

            await MainActor.run { viewModel.download(entry) }
            try await MainActor.run { try expect(viewModel.progress[entry.id]?.state == .downloading(fractionCompleted: 0)) }

            downloader.simulateProgress(for: entry, fraction: 0.4)
            try await settle()
            try await MainActor.run { try expect(viewModel.progress[entry.id]?.state == .downloading(fractionCompleted: 0.4)) }
        }

        r.run("a successful download moves the entry from Available to Downloaded") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let downloader = FakeModelDownloader()
            let entry = try require(ModelCatalog.entries.first)
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier, downloader: downloader) }

            await MainActor.run { viewModel.download(entry) }
            downloader.simulateSuccess(for: entry)
            try await settle()

            try await MainActor.run {
                try expect(viewModel.progress[entry.id]?.state == .completed)
                try expect(viewModel.downloadedEntries.map(\.id).contains(entry.id))
            }
        }

        r.run("a failed download surfaces the failure and leaves the entry Available") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let downloader = FakeModelDownloader()
            let entry = try require(ModelCatalog.entries.first)
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier, downloader: downloader) }

            await MainActor.run { viewModel.download(entry) }
            downloader.simulateFailure(for: entry, message: "boom")
            try await settle()

            try await MainActor.run {
                guard case .failed(let message) = viewModel.progress[entry.id]?.state else {
                    throw TestFailure(message: "expected a failed state")
                }
                try expect(message.contains("boom"))
                try expect(viewModel.availableEntries.map(\.id).contains(entry.id))
            }
        }

        r.run("cancelDownload tells the downloader and clears local progress") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let downloader = FakeModelDownloader()
            let entry = try require(ModelCatalog.entries.first)
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier, downloader: downloader) }

            try await MainActor.run {
                viewModel.download(entry)
                viewModel.cancelDownload(entry)
                try expect(viewModel.progress[entry.id] == nil)
            }
            try expect(downloader.cancelledEntryIds == [entry.id])
        }

        r.run("requiresConfirmationBeforeDeleting is true only for the currently active model") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())

            let defaults = UserDefaults(suiteName: "dailyos-tests-models-viewmodel-\(UUID().uuidString)")!
            let extractionSettings = ExtractionSettings(defaults: defaults)
            let viewModel = await MainActor.run {
                makeViewModel(bundleIdentifier: bundleIdentifier, extractionSettings: extractionSettings)
            }
            try await MainActor.run { try expect(viewModel.requiresConfirmationBeforeDeleting(entry) == false) }

            extractionSettings.modelPathOverride = entry.localPath(bundleIdentifier: bundleIdentifier)
            try await MainActor.run { try expect(viewModel.requiresConfirmationBeforeDeleting(entry)) }
        }

        r.run("delete removes the file from disk") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())

            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier) }
            try await MainActor.run { try viewModel.delete(entry) }
            try expect(entry.isDownloaded(bundleIdentifier: bundleIdentifier) == false)
        }

        r.run("deleting the active model unloads the extractor") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())
            let settings = ExtractionSettings(defaults: UserDefaults(suiteName: "dailyos-tests-models-delete-\(UUID().uuidString)")!)
            settings.modelPathOverride = entry.localPath(bundleIdentifier: bundleIdentifier)
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run {
                makeViewModel(bundleIdentifier: bundleIdentifier, reloader: reloader, extractionSettings: settings)
            }

            try await MainActor.run {
                try viewModel.delete(entry)
                try expect(reloader.host.isUnavailable, "the model is unloaded")
                try expect(reloader.log.loads == 0, "a deleted model must not be reloaded")
            }
        }

        r.run("deleting a model that isn't active leaves the extractor loaded") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleIdentifier), contents: Data())
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier, reloader: reloader) }

            try await MainActor.run {
                try viewModel.delete(entry)
                try expect(!reloader.host.isUnavailable)
            }
        }

        r.run("select points the settings at the entry's own path, then reloads the extractor once") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let defaults = UserDefaults(suiteName: "dailyos-tests-models-select-\(UUID().uuidString)")!
            let settings = ExtractionSettings(defaults: defaults)
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run {
                makeViewModel(bundleIdentifier: bundleIdentifier, reloader: reloader, extractionSettings: settings)
            }

            await viewModel.select(entry)

            try expect(settings.modelPathOverride == entry.localPath(bundleIdentifier: bundleIdentifier))
            try await MainActor.run {
                try expect(reloader.log.loads == 1, "selecting a model must reload the extractor exactly once")
            }
        }

        r.run("select tells the Models list to redraw, so Active and Use follow the new model") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let entry = try require(ModelCatalog.entries.first)
            let viewModel = await MainActor.run { makeViewModel(bundleIdentifier: bundleIdentifier) }
            let changes = ChangeCounter()
            await MainActor.run { changes.subscription = viewModel.objectWillChange.sink { changes.count += 1 } }

            await viewModel.select(entry)

            try await MainActor.run {
                try expect(viewModel.isActive(entry))
                try expect(changes.count > 0, "the list read Active from settings but was never told they changed")
            }
            changes.subscription?.cancel()
        }

        r.run("chooseCustomFile points the settings at the chosen file, then reloads the extractor once") {
            let bundleIdentifier = freshBundleIdentifier()
            defer { cleanUp(bundleIdentifier: bundleIdentifier) }
            let defaults = UserDefaults(suiteName: "dailyos-tests-models-custom-\(UUID().uuidString)")!
            let settings = ExtractionSettings(defaults: defaults)
            let reloader = await MainActor.run { TestExtraction() }
            let viewModel = await MainActor.run {
                makeViewModel(bundleIdentifier: bundleIdentifier, reloader: reloader, extractionSettings: settings)
            }
            let chosen = URL(fileURLWithPath: "/tmp/some-custom-model.gguf")

            await viewModel.chooseCustomFile(chosen)

            try expect(settings.modelPathOverride == chosen.path)
            try await MainActor.run { try expect(reloader.log.loads == 1) }
        }
    }
}

/// `download`'s progress/completion callbacks are dispatched via
/// `Task { @MainActor in ... }` inside `ModelsViewModel`, so a synchronous
/// `simulate*` call on the fake needs the run loop to actually turn before
/// its effect is observable — matching the same reasoning `TestHarness.swift`'s
/// `awaitSync` already documents for `AppModel`'s own `@MainActor` hops.
private func settle() async throws {
    try await Task.sleep(nanoseconds: 50_000_000)
}
