import DailyOSApp
import DailyOSCore
import Foundation

/// Stands in for `AppModel` at the `ExtractionReloading` seam. Records the
/// reload instead of performing one, which is the whole point: the real
/// `applyExtractionSettingsChange()` drops the loaded extractor and reads a
/// real `.gguf` off disk, so before this seam existed
/// `ModelsViewModel.select(_:)` could not be tested at all.
@MainActor
final class FakeExtractionReloader: ExtractionReloading {
    private(set) var applyCount = 0
    var extractionUnavailable = false

    func applyExtractionSettingsChange() async {
        applyCount += 1
    }

    private(set) var unloadCount = 0

    func unloadExtractor() {
        unloadCount += 1
        extractionUnavailable = true
    }
}
