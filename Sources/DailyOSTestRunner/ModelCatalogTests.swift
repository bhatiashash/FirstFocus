import DailyOSCore
import Foundation

func registerModelCatalogTests(_ runner: TestRunner) {
    runner.suite("ModelCatalog") { r in
        r.run("the catalog carries exactly the three confirmed entries, all Q4_K_M") {
            try expect(ModelCatalog.entries.count == 3)
            try expect(ModelCatalog.entries.allSatisfy { $0.quantization == "Q4_K_M" })
            try expect(Set(ModelCatalog.entries.map(\.displayName)) == Set([
                "Qwen2.5-3B-Instruct", "Llama-3.2-3B-Instruct", "Qwen3-4B-Instruct",
            ]))
        }

        r.run("the Qwen3-4B entry's expected filename matches the app's own shipped default model path") {
            let entry = try require(ModelCatalog.entries.first { $0.displayName == "Qwen3-4B-Instruct" })
            let defaultPath = LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: "com.shashbhatia.DailyOS")
            try expect(defaultPath.hasSuffix(entry.expectedFilename), "an existing default-model install must be recognized as already downloaded")
        }

        r.run("isDownloaded is false with nothing on disk, true once the expected file exists") {
            let bundleId = "com.shashbhatia.DailyOSTests-\(UUID().uuidString)"
            let entry = try require(ModelCatalog.entries.first)
            defer {
                try? FileManager.default.removeItem(
                    at: LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleId).deletingLastPathComponent()
                )
            }
            try expect(entry.isDownloaded(bundleIdentifier: bundleId) == false)

            let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleId)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: entry.localPath(bundleIdentifier: bundleId), contents: Data())

            try expect(entry.isDownloaded(bundleIdentifier: bundleId))
        }

        r.run("displayName matches a catalog entry's filename and otherwise falls back") {
            let entry = try require(ModelCatalog.entries.first { $0.displayName == "Llama-3.2-3B-Instruct" })
            try expect(ModelCatalog.displayName(forFilename: entry.expectedFilename, fallback: "unused") == "Llama-3.2-3B-Instruct")
            try expect(ModelCatalog.displayName(forFilename: "some-custom-model.gguf", fallback: "some-custom-model") == "some-custom-model")
        }
    }

    runner.suite("ModelDownloadProgress (pure state machine)") { r in
        r.run("starts queued") {
            try expect(ModelDownloadProgress().state == .queued)
        }

        r.run("start moves to downloading at 0") {
            var progress = ModelDownloadProgress()
            progress.start()
            try expect(progress.state == .downloading(fractionCompleted: 0))
        }

        r.run("update advances the fraction while downloading") {
            var progress = ModelDownloadProgress()
            progress.start()
            progress.update(fractionCompleted: 0.5)
            try expect(progress.state == .downloading(fractionCompleted: 0.5))
        }

        r.run("finish moves to completed") {
            var progress = ModelDownloadProgress()
            progress.start()
            progress.update(fractionCompleted: 0.9)
            progress.finish()
            try expect(progress.state == .completed)
        }

        r.run("fail moves to failed with a message") {
            var progress = ModelDownloadProgress()
            progress.start()
            progress.fail(message: "network error")
            try expect(progress.state == .failed(message: "network error"))
        }

        r.run("a stray update after completion is ignored, never resurrecting downloading") {
            var progress = ModelDownloadProgress()
            progress.start()
            progress.finish()
            progress.update(fractionCompleted: 0.5)
            try expect(progress.state == .completed)
        }

        r.run("a stray update after failure is ignored") {
            var progress = ModelDownloadProgress()
            progress.start()
            progress.fail(message: "network error")
            progress.update(fractionCompleted: 0.5)
            try expect(progress.state == .failed(message: "network error"))
        }

        r.run("update before start is ignored — queued is not downloading") {
            var progress = ModelDownloadProgress()
            progress.update(fractionCompleted: 0.5)
            try expect(progress.state == .queued)
        }
    }
}
