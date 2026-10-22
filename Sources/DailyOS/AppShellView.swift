import DailyOSApp
import DailyOSCore
import SwiftUI

/// Unified window (supersedes ADR 0013/0024/0027's two-window split):
/// `DesktopWindow` and `SettingsWindowController` collapse into one
/// `NavigationSplitView`. Main replaces General, carrying the Ranked List
/// `DesktopWindow` used to show via its own separate window — General's
/// Extraction Prompt content moved to Advanced instead (see
/// `AdvancedTabView`'s own doc comment for why), not onto Main.
extension Notification.Name {
    /// Posted by the menu bar's "About DailyOS".
    static let showAboutScreen = Notification.Name("DailyOSShowAboutScreen")
}

/// The window's minimum content size, set once on `AppShellView`'s root.
/// The floor never moves when switching screens, so macOS never resizes
/// the window to fit one. Its width is History's widest layout: sidebar
/// column (200 + 8 inset) + Batch list (250) + detail (400) + Inspector
/// (250) + two 1pt dividers. Below that the content overflows the window
/// and SwiftUI squeezes or hides a column. Zen gets its own floor so the window can shrink
/// into a corner.
enum WindowFloor {
    static let standard = CGSize(width: 1110, height: 520)
    static let zen = CGSize(width: 350, height: 120)

    static func size(isZen: Bool) -> CGSize { isZen ? zen : standard }
}

/// The sidebar's one width. `.navigationSplitViewColumnWidth` alone
/// doesn't take in this window: the sidebar's `NSSplitViewItem` keeps
/// SwiftUI's default (min 140, no max) and SwiftUI resets it if AppKit
/// changes it. A fixed frame on the sidebar content does hold.
enum SidebarWidth {
    static let points: CGFloat = 200
}

enum AppDestination: String, CaseIterable, Identifiable {
    case main, history, models, advanced, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .main: "Main"
        case .history: "History"
        case .models: "Models"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .main: "list.bullet"
        case .history: "clock.arrow.circlepath"
        case .models: "cpu"
        case .advanced: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// The unified window's footer: read-only — model switching happens only
/// in Models, never here (ADR 0027). Adds a build version on the trailing
/// edge, which the shipped ADR 0027 footer never carried (only About did)
/// — ticket 01 asks for it explicitly, so this restores it rather than
/// silently dropping a requirement the ticket wrote down on purpose. The
/// version is also the Check for Updates button (ADR 0044).
private struct AppFooterView: View {
    let isAvailable: Bool
    /// False once the active model's file is deleted: gray dot, "No model
    /// selected". Red stays for a model file that won't load.
    let hasModelFile: Bool
    let modelName: String?
    /// What intake is doing right now, if anything.
    let status: String?
    /// While true, the version reads "Checking for updates…".
    let isCheckingForUpdates: Bool
    let onCheckForUpdates: () -> Void

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            modelRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dotColor: NSColor {
        if modelName == nil && !hasModelFile { return .systemGray }
        return isAvailable ? .systemGreen : .systemRed
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: dotColor))
                .frame(width: 8, height: 8)
            Text(modelName ?? (hasModelFile ? "No model loaded" : "No model selected"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // The icon says the version can be clicked; it turns while a
            // check waits on the feed.
            Button(action: onCheckForUpdates) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isCheckingForUpdates)
                    Text(isCheckingForUpdates ? "Checking for updates…" : buildVersion)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCheckingForUpdates)
            .help("Check for Updates")
        }
    }
}

struct AppShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var historyViewModel: HistoryViewModel
    @ObservedObject var modelsViewModel: ModelsViewModel
    @ObservedObject var screeningViewModel: ScreeningSettingsViewModel
    @ObservedObject var rulesViewModel: RulesViewModel
    @ObservedObject var mutedChatsViewModel: MutedChatsViewModel
    @ObservedObject var morningBriefViewModel: MorningBriefViewModel
    @ObservedObject var openAtLoginViewModel: OpenAtLoginViewModel
    @ObservedObject var updateChecker: UpdateChecker
    @State private var selectedDestination: AppDestination? = .main
    /// Minimal View (ticket 03): where the sidebar was pointed before
    /// Minimal View forced it to Main, so turning Minimal View back off
    /// can return there — `nil` means Minimal View was entered from Main
    /// itself, so there's nothing to restore.
    @State private var destinationBeforeMinimalView: AppDestination?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Where the window was before Zen Focus Mode took it over, restored
    /// when Zen ends.
    @State private var destinationBeforeZen: AppDestination?
    @State private var columnVisibilityBeforeZen: NavigationSplitViewVisibility?
    var onChooseCustomModelFile: () -> Void
    var onRevealModelDirectory: () -> Void
    var onExportHistory: (URL) -> Void
    var onDeleteActiveModelRequiringConfirmation: (ModelCatalogEntry) -> Void

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(width: SidebarWidth.points)
                .navigationSplitViewColumnWidth(SidebarWidth.points)
                .layoutPriority(1)
                // The system toggle sits at the sidebar's trailing edge and
                // jumps left when the sidebar collapses. Ours, below, stays
                // at the window's leading edge either way.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            destinationView(for: selectedDestination ?? .main)
                // With the sidebar hidden, its footer can't show progress,
                // so a small capsule does, top right, while it lasts.
                .overlay(alignment: .topTrailing) {
                    if columnVisibility == .detailOnly, let intakeStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(intakeStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: intakeStatus)
        }
        // The one minimum for the whole window (`WindowFloor`).
        .frame(
            minWidth: WindowFloor.size(isZen: model.isZenFocusModeEnabled).width,
            minHeight: WindowFloor.size(isZen: model.isZenFocusModeEnabled).height
        )
        // Attached to the whole shell, not Main, so ⇧⌘C opens it from any
        // sidebar destination (CONTEXT.md: Checked Off).
        .sheet(isPresented: $model.isCheckedOffSheetPresented) {
            CheckedOffSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Show or hide the sidebar")
            }
            // No More menu: Re-run Extraction, export and the unfiltered
            // History log live in the menu bar (`MenuCommands`).
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.isZenFocusModeEnabled) {
                    Label("Zen Focus Mode", systemImage: "leaf")
                }
                .toggleStyle(.button)
                .help("Zen Focus Mode: show Focus only (⇧⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // The entry field lives on Main, so + goes there first.
                    selectedDestination = .main
                    model.isAddingTask = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a reminder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isMinimalViewEnabled.toggle()
                } label: {
                    Label("Minimal View", systemImage: "arrow.down.right.and.arrow.up.left.square")
                }
                .help("Minimal View (⇧⌘M, Esc to leave)")
            }
        }
        // "About DailyOS" in the menu bar (`MenuCommands`) opens this
        // window's About screen, leaving Minimal View and Zen first since
        // both pin the window to Main. The saved screens are cleared so
        // leaving them doesn't restore an earlier screen over About.
        .onReceive(NotificationCenter.default.publisher(for: .showAboutScreen)) { _ in
            destinationBeforeMinimalView = nil
            destinationBeforeZen = nil
            model.isMinimalViewEnabled = false
            model.isZenFocusModeEnabled = false
            selectedDestination = .about
        }
        // Shadow statistics (ADR 0036) change as each pass writes Screening
        // and extraction rows, so the table re-reads History when one ends.
        .onChange(of: model.isMessagesPassRunning) { _, isRunning in
            if !isRunning { screeningViewModel.refreshStatistics() }
            rulesViewModel.refreshProposalStatus()
        }
        // Minimal View (ticket 03) is driven from `AppModel` rather than
        // local `@State`, since the toolbar toggle that sets it lives in
        // AppKit (`main.swift`'s `MinimalViewToolbarController`, hiding
        // the window's toolbar chrome), not only in this view —
        // `AppModel.isMinimalViewEnabled` is the one place both sides
        // read and write the same state, the same pattern Zen Focus Mode
        // already uses for the same reason.
        // Zen Focus Mode is Focus alone: it shows Main, collapses the
        // sidebar (the toolbar is hidden by `MinimalViewToolbarController`),
        // and puts both back when it ends.
        // Zen is remembered across launches, and `onChange` doesn't fire for
        // the starting value.
        .onAppear {
            if model.isZenFocusModeEnabled {
                selectedDestination = .main
                columnVisibility = .detailOnly
                columnVisibilityBeforeZen = .all
            }
        }
        .onChange(of: model.isZenFocusModeEnabled) { _, isZen in
            if isZen {
                destinationBeforeZen = selectedDestination
                columnVisibilityBeforeZen = columnVisibility
                selectedDestination = .main
                columnVisibility = .detailOnly
            } else {
                if let previous = destinationBeforeZen { selectedDestination = previous }
                if !model.isMinimalViewEnabled, let previous = columnVisibilityBeforeZen { columnVisibility = previous }
                destinationBeforeZen = nil
                columnVisibilityBeforeZen = nil
            }
        }
        .onChange(of: model.isMinimalViewEnabled) { _, isMinimal in
            if isMinimal {
                if selectedDestination != .main {
                    destinationBeforeMinimalView = selectedDestination
                }
                selectedDestination = .main
                columnVisibility = .detailOnly
            } else {
                columnVisibility = .all
                if let previous = destinationBeforeMinimalView {
                    selectedDestination = previous
                    destinationBeforeMinimalView = nil
                }
            }
        }
    }

    /// Hidden by `NavigationSplitView` itself once `columnVisibility` is
    /// `.detailOnly` (Minimal View) — the footer lives inside this same
    /// closure, so it disappears along with the sidebar with no separate
    /// visibility rule needed.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(AppDestination.allCases, selection: $selectedDestination) { destination in
                Label(destination.label, systemImage: destination.systemImage).tag(destination)
            }
            Divider()
            AppFooterView(
                isAvailable: !model.extractionUnavailable, hasModelFile: model.hasModelFile,
                modelName: model.activeModelDisplayName, status: intakeStatus,
                isCheckingForUpdates: updateChecker.isChecking,
                onCheckForUpdates: { updateChecker.checkForUpdates() }
            )
        }
    }

    /// Shown only for a re-extraction you started. Routine intake passes
    /// run often and stay silent.
    private var intakeStatus: String? {
        model.reExtractionProgress.map { "Re-extracting… \($0.completed) of \($0.total)" }
    }

    @ViewBuilder
    private func destinationView(for destination: AppDestination) -> some View {
        switch destination {
        case .main:
            ContentView(model: model)
        case .history:
            HistoryView(viewModel: historyViewModel)
        case .models:
            ModelsView(
                viewModel: modelsViewModel, onChooseCustomFile: onChooseCustomModelFile,
                onRevealModelDirectory: onRevealModelDirectory,
                onDeleteRequiringConfirmation: onDeleteActiveModelRequiringConfirmation
            )
        case .advanced:
            AdvancedTabView(
                morningBriefViewModel: morningBriefViewModel, openAtLoginViewModel: openAtLoginViewModel,
                viewModel: settingsViewModel, screeningViewModel: screeningViewModel, rulesViewModel: rulesViewModel,
                mutedChatsViewModel: mutedChatsViewModel, activeModelName: model.activeModelDisplayName, captureHotkeyPreset: $model.captureHotkeyPreset,
                isFocusListEnabled: $model.isFocusListEnabled
            )
        case .about:
            AboutTabView(captureHotkeyPreset: model.captureHotkeyPreset)
        }
    }
}
