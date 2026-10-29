import Foundation

/// Extraction settings (ticket 04): the system prompt and the local
/// `.gguf` model path, both fixed values in code until now. A thin
/// `UserDefaults`-backed wrapper, the same shape `ZenFocusModePreference`
/// and `CaptureHotkeyPreference` already use for a persisted setting.
///
/// `promptOverride`/`modelPathOverride` are the raw stored values, exactly
/// as last saved — a Settings text editor binds to these directly, so the
/// user's own formatting round-trips unchanged. `effectiveModelPath`
/// resolves what `LlamaCppIntentExtractor` should actually load; the
/// equivalent resolution for the prompt lives on `LlamaCppIntentExtractor`
/// itself (`systemPrompt(today:promptOverride:)`), since that's the one
/// place "blank means use the default" already needs to be decided for
/// the prompt.
///
/// `@unchecked Sendable`: `UserDefaults` documents itself as safe to use
/// from any thread, the same posture `ZenFocusModePreference` already
/// takes.
public struct ExtractionSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let promptKey = "extractionPromptOverride"
    private static let modelPathKey = "extractionModelPathOverride"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The input format the default prompt is written for (batched-
    /// extraction ticket 03). Version 2 is `[latest messages]` with
    /// `[open suggestions]` and UPDATE/CANCEL answers; an override saved
    /// with no version predates it and is version 1.
    public static let currentPromptFormatVersion = 2
    private static let promptFormatVersionKey = "extractionPromptFormatVersion"

    /// The raw stored override, whatever format it was written for. `nil`
    /// means "use `LlamaCppIntentExtractor.defaultExtractionPrompt`."
    /// Saving stamps the current format version, so a prompt re-saved from
    /// Settings is trusted again.
    public var promptOverride: String? {
        get { defaults.string(forKey: Self.promptKey) }
        nonmutating set {
            defaults.set(newValue, forKey: Self.promptKey)
            if newValue == nil {
                defaults.removeObject(forKey: Self.promptFormatVersionKey)
            } else {
                defaults.set(Self.currentPromptFormatVersion, forKey: Self.promptFormatVersionKey)
            }
        }
    }

    private var storedPromptFormatVersion: Int {
        defaults.object(forKey: Self.promptFormatVersionKey) as? Int ?? 1
    }

    /// The override extraction should actually use: only one written for
    /// the current input format. An older one would describe blocks and
    /// answers the app no longer sends or reads, and fail without any sign.
    public var effectivePromptOverride: String? {
        guard storedPromptFormatVersion == Self.currentPromptFormatVersion else { return nil }
        return promptOverride
    }

    /// An override written for an older format, kept so Settings can show
    /// it and the user can merge it by hand. `nil` when there's none.
    public var setAsidePromptOverride: String? {
        guard storedPromptFormatVersion != Self.currentPromptFormatVersion else { return nil }
        return promptOverride
    }

    /// `nil` means "use `LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier:)`."
    public var modelPathOverride: String? {
        get { defaults.string(forKey: Self.modelPathKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.modelPathKey) }
    }

    /// What `ExtractionHost.load()` should actually pass to
    /// `LlamaCppIntentExtractor.init(modelPath:)`: the stored override if
    /// it's non-blank, the built-in default path otherwise — clearing the
    /// field in Settings falls back cleanly rather than pointing at an
    /// empty path.
    public func effectiveModelPath(bundleIdentifier: String) -> String {
        let trimmed = modelPathOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil)
            ?? LlamaCppIntentExtractor.defaultModelPath(bundleIdentifier: bundleIdentifier)
    }
}
