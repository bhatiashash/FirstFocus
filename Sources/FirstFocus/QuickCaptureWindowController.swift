import AppKit
import Combine
import FirstFocusApp
import FirstFocusCore
import SwiftUI

/// Holds the capture panel's text and Reminders-availability state as
/// `@Published` properties so `QuickCaptureView` re-renders through
/// ordinary SwiftUI observation — the window controller below builds the
/// hosting view exactly once rather than replacing its `rootView` on every
/// keystroke.
@MainActor
final class QuickCaptureViewModel: ObservableObject {
    /// The text and its typed due date, the same as the `+` field (ADR
    /// 0030 amendment).
    @Published var entry = TypedTitleEntry()
    @Published var isUnavailable = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
}

struct QuickCaptureView: View {
    @ObservedObject var viewModel: QuickCaptureViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TypedTitleField(entry: $viewModel.entry) { text in
                    TextField("What do you need to do?", text: text)
                        // A closure that reads `onSubmit` when Return is
                        // pressed. The old `onCommit:` argument copied it
                        // when the view was built, before the window
                        // controller set it, so Return ran the empty default.
                        .onSubmit { viewModel.onSubmit() }
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onExitCommand(perform: viewModel.onCancel)
                }
            }
            // Global Hotkey Input (ticket 01): the Gate never blocks —
            // the panel stays open and keeps whatever was typed rather
            // than losing it, the same "surface it, never block" posture
            // every other Gate in this app already has.
            if viewModel.isUnavailable {
                Text("Reminders needs access — this will be added once it's granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The capture panel is non-activating, so it takes keystrokes while
/// another app stays active, and AppKit only routes menu key equivalents
/// for the active app. Handing them to the main menu here is what makes
/// Command-V and the other Edit shortcuts work in the panel.
private final class CapturePanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Global Hotkey Input (ticket 01): a floating capture panel, reachable
/// from anywhere via `GlobalHotKeyManager`, independent of whether the main
/// FirstFocus window is open, minimized, or behind a full-screen app.
/// Submitting writes straight through to Reminders via
/// `AppModel.createTask(title:dueAt:)` — the same write-through path Approve
/// already uses — so a captured Task is a stated Signal from the moment
/// it's created, with no new local store or Signal type of its own.
@MainActor
final class QuickCaptureWindowController: NSWindowController {
    private let model: AppModel
    private let viewModel = QuickCaptureViewModel()
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)

        viewModel.isUnavailable = model.remindersUnavailable
        panel.contentViewController = NSHostingController(rootView: QuickCaptureView(viewModel: viewModel))
        viewModel.onSubmit = { [weak self] in self?.submit() }
        viewModel.onCancel = { [weak self] in self?.hide() }

        // A submission typed while the Reminders Gate is still ungranted
        // is held, not lost: the panel stays open with the text intact,
        // and this fires the same submit path the instant the Gate flips
        // available — matching AppModel's own "never block" posture.
        cancellable = model.$remindersUnavailable
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unavailable in
                guard let self else { return }
                viewModel.isUnavailable = unavailable
                if !unavailable, window?.isVisible == true {
                    submit()
                }
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        window.isVisible ? hide() : show()
    }

    private func show() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = window.frame
        // Centered, but above the screen's vertical midpoint — Spotlight's
        // own resting position, and clear of wherever a centered
        // FirstFocus main window would otherwise sit underneath it.
        window.setFrameOrigin(NSPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.frame.midY - frame.height / 2 + 120
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        window?.orderOut(nil)
        viewModel.entry.reset()
    }

    private func submit() {
        guard let saved = viewModel.entry.submit(), !model.remindersUnavailable else { return }
        Task { await model.createTask(title: saved.title, dueAt: saved.dueAt) }
        hide()
    }
}
