import Combine
import DailyOSCore
import Foundation

/// Backs Advanced's Screening section (ADR 0036). Lives in this target, not
/// the executable, so it can be driven with fakes the same way
/// `HistoryViewModel` is.
/// A cutoff as it can be stored: kept within 0.05...0.95 and rounded to
/// two decimal places, so dragging or repeated steps never store values
/// like 0.4999999999999996.
public func clampedCutoff(_ value: Double) -> Double {
    (min(max(value, 0.05), 0.95) * 100).rounded() / 100
}

@MainActor
public final class ScreeningSettingsViewModel: ObservableObject {
    @Published public var isEnabled: Bool {
        didSet {
            settings.isEnabled = isEnabled
            extraction.applyScreeningAccessChange()
        }
    }
    /// Live mode (ADR 0036): only offered once a cutoff has been set.
    @Published public var isLive: Bool {
        didSet {
            guard isLive != oldValue else { return }
            if isLive && !canGoLive {
                isLive = false
                return
            }
            settings.isLive = isLive
            extraction.applyScreeningSettings()
        }
    }
    /// The stepper's value. Starts at 0.5 for display, but nothing is
    /// stored until `setCutoff` runs, so live stays unavailable until the
    /// user has actually chosen one.
    @Published public private(set) var cutoff: Double
    @Published public private(set) var canGoLive: Bool

    /// What's typed into the key field. Cleared once saved, so the key is
    /// never shown back, only whether one is stored.
    @Published public var apiKeyDraft = ""
    @Published public private(set) var hasAPIKey: Bool
    @Published public private(set) var errorMessage: String?
    /// Shadow statistics (ADR 0036): the data a cutoff is chosen from.
    /// Every Screening decision whose outcome is known, for the histogram.
    @Published public private(set) var points: [ScreeningPoint] = []
    /// Where the histogram's line sits. Dragging moves only this; the
    /// stored cutoff changes only through `setCutoff`.
    @Published public var candidateCutoff: Double

    /// Tune Cutoff needs a key: without one nothing is being scored
    /// (screening-optional).
    public var canTuneCutoff: Bool { hasAPIKey }

    /// Why Tune Cutoff is disabled, shown under it; `nil` while it isn't.
    public var tuneCutoffHint: String? { canTuneCutoff ? nil : "Add a key to tune the cutoff." }

    public var readout: CutoffReadout { cutoffReadout(points, cutoff: candidateCutoff) }

    private let settings: ScreeningSettings
    private let keyStore: any APIKeyStore
    private let extraction: ExtractionHost
    private let historyStore: (any HistoryStore)?
    private let correctionLog: (any CorrectionLog)?

    public init(
        settings: ScreeningSettings, keyStore: any APIKeyStore, extraction: ExtractionHost,
        historyStore: (any HistoryStore)? = nil, correctionLog: (any CorrectionLog)? = nil
    ) {
        self.settings = settings
        self.keyStore = keyStore
        self.extraction = extraction
        self.historyStore = historyStore
        self.correctionLog = correctionLog
        self.isEnabled = settings.isEnabled
        self.isLive = settings.isLive && settings.cutoff != nil
        self.cutoff = settings.cutoff ?? 0.5
        self.candidateCutoff = settings.cutoff ?? 0.5
        self.canGoLive = settings.cutoff != nil
        self.hasAPIKey = !(keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        refreshStatistics()
    }

    /// Re-reads History. Called when Advanced appears and after each intake
    /// pass while it's showing.
    public func refreshStatistics() {
        guard let historyStore else { return }
        let outcomes = historyStore.screeningOutcomes(questionVersion: screeningQuestionVersion)
        let falseNegatives = correctionLog?.corrections(ofType: .falseNegative, createdAfter: nil, limit: 1_000_000) ?? []
        points = screeningPoints(from: outcomes, markedAsWork: Set(falseNegatives.compactMap(\.sourceRef)))
    }

    public func setCutoff(_ value: Double) {
        // Two decimal places: repeated 0.05 stepper steps otherwise store
        // values like 0.4999999999999996.
        let clamped = clampedCutoff(value)
        settings.cutoff = clamped
        cutoff = clamped
        candidateCutoff = clamped
        canGoLive = true
        extraction.applyScreeningSettings()
    }

    public func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keyStore.write(trimmed)
            apiKeyDraft = ""
            hasAPIKey = true
            errorMessage = nil
            extraction.applyScreeningAccessChange()
        } catch {
            errorMessage = "Couldn't save the key to the Keychain."
        }
    }

    /// Closing the key sheet without saving: what was typed is dropped.
    public func cancelKeyEntry() {
        apiKeyDraft = ""
        errorMessage = nil
    }

    public func removeAPIKey() {
        do {
            try keyStore.delete()
            hasAPIKey = false
            errorMessage = nil
            extraction.applyScreeningAccessChange()
        } catch {
            errorMessage = "Couldn't remove the key from the Keychain."
        }
    }
}
