import DailyOSCore
import Foundation

/// The slices of `AppModel` the Settings tabs actually reach for, split by
/// caller rather than by concept — ADR 0021's posture applied one level up
/// from the store. A tab's view model takes the two-line slice it uses
/// instead of the whole app model, which is what lets a fake stand in for
/// it: `ModelsViewModel` has exactly one such call.
///
/// The seams are real rather than hypothetical: `AppModel` satisfies them
/// in the app and a fake satisfies them in `DailyOSTestRunner`. Before they
/// existed, a test had to build an entire `AppModel` out of fakes, which left
/// `ModelsViewModel.select(_:)` untestable outright — it ends in a real
/// model load, so the fake extractor a test had injected was dropped on
/// the floor and a 2.5GB `.gguf` was read off disk instead.

/// Reloading the extraction model after a settings change (the Models tab,
/// ADR 0028). Deliberately one method: the tab changes
/// `ExtractionSettings` itself and only needs the reload afterward.
@MainActor
public protocol ExtractionReloading: AnyObject {
    /// Drops whatever extractor is loaded and loads whatever
    /// `ExtractionSettings` now points at. Unconditional, unlike
    /// `retryLoadingExtractor` — the common case is a working extractor
    /// whose settings just changed.
    func applyExtractionSettingsChange() async
    /// Drops the loaded extractor without loading another, for when the
    /// active model's file was just deleted.
    func unloadExtractor()
    /// Whether the last load failed, so a caller can report it.
    var extractionUnavailable: Bool { get }
}

/// Advanced's Screening section pushes a settings or key change through
/// this, so it takes effect from the next Batch without a relaunch.
@MainActor
public protocol ScreeningConfiguring: AnyObject {
    /// A mode or cutoff change. Leaves the circuit breaker as it is.
    func applyScreeningSettings()
    /// The toggle flipped or the key was saved or removed. Also closes the
    /// circuit breaker, since the user may just have fixed what tripped it.
    func applyScreeningAccessChange()
}

/// Advanced's Rules section pushes an approved, edited or deleted Rule
/// through this, so the next extraction sees it (ADR 0038).
@MainActor
public protocol RulesConfiguring: AnyObject {
    func applyRules()
}

/// "Propose rules" (ADR 0038): whether it can run, and running it.
@MainActor
public protocol RuleProposing: AnyObject {
    func ruleProposalStatus() -> RuleProposalStatus
    /// The proposed Rule texts, not yet approved. Empty when proposing
    /// isn't allowed or the model returned nothing usable.
    func proposeRules() async -> [String]
}

extension AppModel: ExtractionReloading, ScreeningConfiguring, RulesConfiguring, RuleProposing {}
