import Combine
import FirstFocusCore
import Foundation

/// Extraction settings (ticket 04): what Advanced's Extraction Prompt
/// section actually edits — the prompt only. Model selection lives
/// entirely in `ModelsViewModel` now (ADR 0028); re-extraction's own
/// lookback/interval controls stay here too, since Advanced is one shared
/// destination for extraction configuration generally, not split further.
/// Formerly `SettingsWindowController.swift`'s view model, before the
/// window merge (unified-window-and-minimal-view) folded Settings into
/// the same window as the Ranked List — the type keeps its name since it
/// still models the same extraction/re-extraction settings, just no
/// longer behind a window of its own.
///
/// The prompt editor briefly lived on Main (ticket 02) before this — moved
/// here after building it and finding, by actually looking at it, that a
/// prompt-configuration control has no business sitting above a to-do
/// list. Main is "what's on my plate," not extraction settings; this is.
@MainActor
public final class SettingsViewModel: ObservableObject {
    /// Which prompt extraction is using, for Advanced's one-line summary.
    public enum PromptStatus: Equatable {
        /// The built-in prompt, with nothing saved.
        case builtIn
        /// A prompt the user saved.
        case custom
        /// The built-in prompt, because the saved one was written for an
        /// older input format and set aside.
        case setAside
    }

    /// The prompt sheet's draft. Saved only by `saveAndReload()`;
    /// `cancelEditing()` puts it back to what's saved.
    @Published public var prompt: String
    @Published public private(set) var promptStatus: PromptStatus
    /// A saved prompt written for an older input format (batched-extraction
    /// ticket 03). Extraction ignores it; Advanced shows it read-only so the
    /// user can carry anything worth keeping into the editor by hand.
    @Published public private(set) var setAsidePrompt: String?
    @Published public private(set) var isReloading = false
    @Published public private(set) var statusMessage: String?
    /// Edited in hours, not days: `ReExtractionSettings.lookbackDays` is
    /// still the storage unit (nothing downstream does day-boundary math,
    /// so a sub-day value round-trips fine as `lookbackDays * 86400`
    /// seconds), but a whole-days-only Stepper can't represent the new
    /// one-hour default at all. This is the only place the ×24/÷24
    /// conversion happens.
    @Published public var reExtractionLookbackHours: Double {
        didSet { reExtractionSettings.lookbackDays = reExtractionLookbackHours / 24 }
    }
    @Published public var reExtractionMinimumIntervalHours: Double {
        didSet { reExtractionSettings.minimumIntervalHours = reExtractionMinimumIntervalHours }
    }

    private let extractionSettings: ExtractionSettings
    private let reExtractionSettings: ReExtractionSettings
    private let extraction: ExtractionHost

    public init(
        extractionSettings: ExtractionSettings, reExtractionSettings: ReExtractionSettings, extraction: ExtractionHost
    ) {
        self.extractionSettings = extractionSettings
        self.reExtractionSettings = reExtractionSettings
        self.extraction = extraction
        self.prompt = extractionSettings.effectivePromptOverride ?? LlamaCppIntentExtractor.defaultExtractionPrompt
        self.setAsidePrompt = extractionSettings.setAsidePromptOverride
        self.promptStatus = Self.status(of: extractionSettings)
        self.reExtractionLookbackHours = reExtractionSettings.lookbackDays * 24
        self.reExtractionMinimumIntervalHours = reExtractionSettings.minimumIntervalHours
    }

    private static func status(of settings: ExtractionSettings) -> PromptStatus {
        if settings.effectivePromptOverride != nil { return .custom }
        return settings.setAsidePromptOverride != nil ? .setAside : .builtIn
    }

    private var savedPrompt: String {
        extractionSettings.effectivePromptOverride ?? LlamaCppIntentExtractor.defaultExtractionPrompt
    }

    /// Opening the prompt sheet: the draft starts from what's saved.
    public func beginEditing() {
        prompt = savedPrompt
        statusMessage = nil
    }

    /// Closing the prompt sheet without saving throws the draft away.
    public func cancelEditing() {
        beginEditing()
    }

    /// Saves the draft and reloads extraction. Returns whether extraction
    /// came back, so the sheet knows whether to close. A failed reload
    /// still keeps the saved prompt.
    @discardableResult
    public func saveAndReload() async -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmedPrompt.isEmpty || trimmedPrompt == LlamaCppIntentExtractor.defaultExtractionPrompt
        // Saving the default while an old prompt is set aside keeps the old
        // text around to merge from, rather than quietly deleting it.
        if !(isDefault && setAsidePrompt != nil) {
            extractionSettings.promptOverride = isDefault ? nil : prompt
        }
        return await reload()
    }

    /// Drops the saved prompt and reloads extraction with the built-in one.
    /// An old prompt that was set aside stays, the same as saving the
    /// default does, so the user can still copy from it.
    @discardableResult
    public func resetToDefault() async -> Bool {
        if setAsidePrompt == nil {
            extractionSettings.promptOverride = nil
        }
        prompt = LlamaCppIntentExtractor.defaultExtractionPrompt
        return await reload()
    }

    private func reload() async -> Bool {
        setAsidePrompt = extractionSettings.setAsidePromptOverride
        promptStatus = Self.status(of: extractionSettings)

        isReloading = true
        statusMessage = nil
        await extraction.applySettingsChange()
        isReloading = false
        let succeeded = !extraction.isUnavailable
        statusMessage = succeeded
            ? "Saved. Extraction is using the new prompt."
            : "Couldn't load the model — check Models and try again."
        return succeeded
    }
}
