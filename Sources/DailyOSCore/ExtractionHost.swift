import Foundation

/// The extraction model's life, and everything that follows the model
/// loaded: Rules pushed into it, Rule proposals made with it, and
/// Screening set beside it (extraction-host). The only writer of
/// Intake's extractor and Screening, so nothing else can swap them while a
/// pass runs.
///
/// Loading (reading a ~2.5GB file, allocating KV cache buffers) goes
/// through the loader it is given, off the main actor. A missing or
/// unloadable model degrades to `isUnavailable`, never blocking Messages
/// reading or Reminders (ticket 10). Once loaded, the context stays loaded
/// until a settings change or an unload (ADR 0026).
@MainActor
public final class ExtractionHost {
    /// Loads the model at `modelPath` with `promptOverride`, or returns
    /// `nil` when it can't.
    public typealias Loader = @Sendable (_ modelPath: String, _ promptOverride: String?) async -> (any IntentExtractor)?

    /// Called after every load, reload, unload and Screening access change:
    /// whether a model is loaded, and what History offers, may have changed.
    public var onChange: () -> Void = {}
    /// Whether a Messages pass or a re-extraction is running. A Rule
    /// proposal waits for neither (ADR 0034). Settable rather than an init
    /// parameter, since its owner reads its own state.
    public var isPassRunning: @MainActor () -> Bool = { false }
    /// The last load failed, or the model was unloaded.
    public private(set) var isUnavailable = false

    private let intake: MessagesIntake
    private let loader: Loader
    private let extractionSettings: ExtractionSettings
    private let bundleIdentifier: String
    private let ruleStore: any RuleStore
    private let corrections: Corrections
    private let screeningSettings: ScreeningSettings
    private let apiKeyStore: any APIKeyStore
    private let makeScreener: @Sendable (String) -> any Screener
    /// Wraps the Screener Intake is given, and outlives passes so an outage
    /// found by one pass spares the next (screening-optional). Rebuilt,
    /// which closes it, when the toggle or key changes; kept with the key
    /// its Screener was built from, so a new key always gets its own.
    private var screeningBreaker: (key: String, breaker: ScreeningBreaker)?

    public init(
        intake: MessagesIntake, loader: @escaping Loader, extractionSettings: ExtractionSettings, bundleIdentifier: String,
        ruleStore: any RuleStore, corrections: Corrections, screeningSettings: ScreeningSettings, apiKeyStore: any APIKeyStore,
        makeScreener: @escaping @Sendable (String) -> any Screener
    ) {
        self.intake = intake
        self.loader = loader
        self.extractionSettings = extractionSettings
        self.bundleIdentifier = bundleIdentifier
        self.ruleStore = ruleStore
        self.corrections = corrections
        self.screeningSettings = screeningSettings
        self.apiKeyStore = apiKeyStore
        self.makeScreener = makeScreener
    }

    // MARK: - The model

    /// Loads the model unless one is loaded. Whichever ends up loaded
    /// starts with the current Rules (ADR 0038).
    public func load() async {
        defer {
            applyRules()
            onChange()
        }
        guard intake.extractor == nil else { return }
        let loaded = await loader(
            extractionSettings.effectiveModelPath(bundleIdentifier: bundleIdentifier),
            extractionSettings.effectivePromptOverride
        )
        intake.extractor = loaded
        isUnavailable = loaded == nil
    }

    /// The extraction Notice's Retry.
    public func retry() async {
        isUnavailable = false
        await load()
    }

    /// The model or prompt changed in settings: drops the loaded model,
    /// which shows History's model-bound actions disabled while the new
    /// one loads, then loads it.
    public func applySettingsChange() async {
        intake.extractor = nil
        isUnavailable = false
        onChange()
        await load()
    }

    /// The active model's file was deleted: nothing is loaded until
    /// another is chosen.
    public func unload() {
        intake.extractor = nil
        isUnavailable = true
        onChange()
    }

    /// Whether a model is loaded.
    public var isLoaded: Bool { intake.extractor != nil }

    /// The loaded model's name, `nil` with none loaded.
    public var displayName: String? { intake.extractor?.modelDisplayName }

    /// Whether the chosen model's file is on disk, loaded or not.
    public var hasModelFile: Bool {
        FileManager.default.fileExists(atPath: extractionSettings.effectiveModelPath(bundleIdentifier: bundleIdentifier))
    }

    // MARK: - Rules

    /// Hands the approved Rules to the loaded model (ADR 0038).
    public func applyRules() {
        intake.extractor?.setRules(ruleStore.rules().map(\.text))
    }

    /// Whether a Rule proposal can run now, and if not, why.
    public func ruleProposalStatus() -> RuleProposalStatus {
        guard intake.extractor is FreeTextGenerating else { return .noModel }
        guard !isPassRunning() else { return .passRunning }
        let count = newFalsePositives().count
        return count >= minimumCorrectionsForProposal ? .ready(newCorrections: count) : .needsMoreCorrections(have: count)
    }

    /// Asks the loaded model for Rules from the false positives since the
    /// last proposal, as many as fit its prompt. Only a proposal that
    /// produced something uses the Corrections up: a failed or empty one
    /// leaves the count where it was, so the user can try again.
    public func proposeRules() async -> [String] {
        guard case .ready = ruleProposalStatus(), let extractor = intake.extractor,
              let generator = extractor as? FreeTextGenerating else { return [] }
        let tokenBudget = extractor.maxPromptTokens - ruleProposalMaxTokens
        var chosen: [Correction] = []
        for correction in newFalsePositives() {
            let candidate = chosen + [correction]
            guard extractor.estimatedTokenCount(for: ruleProposalUserPrompt(corrections: candidate)) <= tokenBudget else { break }
            chosen = candidate
        }
        guard !chosen.isEmpty else { return [] }
        let startedAt = Date()
        let raw = (try? await generator.generateText(
            system: ruleProposalSystemPrompt, user: ruleProposalUserPrompt(corrections: chosen),
            maxTokens: ruleProposalMaxTokens, priority: .userInitiated
        )) ?? ""
        let proposed = parseProposedRules(raw)
        if !proposed.isEmpty {
            ruleStore.proposalWatermark = startedAt
        }
        return proposed
    }

    private func newFalsePositives() -> [Correction] {
        corrections.falsePositives(since: ruleStore.proposalWatermark)
    }

    // MARK: - Screening

    /// Sets Intake's Screening from the settings and the stored key (ADR
    /// 0036). The breaker is kept while the key stays the same.
    public func applyScreeningSettings() {
        let key = apiKeyStore.read()
        let mode = effectiveScreeningMode(settings: screeningSettings, apiKey: key)
        guard mode != .off, let key else {
            intake.setScreening(nil, mode: .off)
            return
        }
        if screeningBreaker?.key != key {
            screeningBreaker = (key, ScreeningBreaker(screener: makeScreener(key)))
        }
        intake.setScreening(screeningBreaker?.breaker, mode: mode)
    }

    /// The Screening toggle or the key changed: a new breaker, and History
    /// redraws, since the toggle decides what it shows about Screening.
    public func applyScreeningAccessChange() {
        screeningBreaker = nil
        applyScreeningSettings()
        onChange()
    }
}

/// The production loader: the llama.cpp model, loaded off the main actor.
/// A model that can't load is reported on standard error and read as none.
public let llamaExtractorLoader: ExtractionHost.Loader = { modelPath, promptOverride in
    await Task.detached {
        do {
            return try LlamaCppIntentExtractor(modelPath: modelPath, promptOverride: promptOverride)
        } catch {
            FileHandle.standardError.write(Data("DailyOS: failed to load the local extraction model: \(error)\n".utf8))
            return nil
        }
    }.value
}
