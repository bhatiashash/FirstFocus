import AppKit
import Combine
import CoreGraphics
import FirstFocusApp
import FirstFocusCore
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// llama.framework (llama.cpp's Metal backend) crashes during ordinary
/// process teardown: quitting normally reaches AppKit's own `exit()`,
/// which runs C++ static destructors, and one of those
/// (`ggml_metal_device_free`, freeing a global `std::vector` of Metal
/// devices) calls `ggml_abort()` — confirmed via a real crash report, not
/// assumed. `LlamaCppIntentExtractor.deinit` never even runs in this path
/// (`AppModel` lives for the process's whole life, so nothing releases
/// it), so this is entirely inside the vendored framework's own exit-time
/// cleanup, unreachable from this app's code. `_exit(0)` sidesteps it by
/// skipping that cleanup phase outright — safe here, since the process is
/// about to disappear and the OS reclaims every resource (GPU handles
/// included) the instant it does.
///
/// `_exit(0)` also skips anything AppKit would run later in quitting, so
/// whatever must happen before the process goes is done here first:
/// `beforeQuit` writes a check-off still held on the Undo bar (undo-bar).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var beforeQuit: @MainActor () -> Void = {}

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { beforeQuit() }
        _exit(0)
    }
}

/// Global Hotkey Input (ticket 01): the AppKit half of registering the
/// system-wide capture shortcut. `AppModel.captureHotkeyPreset` is the one
/// place the selection lives (read/written by the SwiftUI "More" menu,
/// `AppShellView`'s `.toolbar`); this watches it and re-registers
/// `GlobalHotKeyManager` whenever it changes, including once at
/// construction — the same Combine-sink "thin adapter" shape
/// `MinimalViewToolbarController` and `ZenWindowSizer` already use to
/// bridge `AppModel`'s published state into AppKit.
@MainActor
final class CaptureHotkeyController {
    private let hotKeyManager: GlobalHotKeyManager
    private let quickCaptureWindowController: QuickCaptureWindowController
    private var cancellable: AnyCancellable?

    init(model: AppModel, hotKeyManager: GlobalHotKeyManager, quickCaptureWindowController: QuickCaptureWindowController) {
        self.hotKeyManager = hotKeyManager
        self.quickCaptureWindowController = quickCaptureWindowController
        cancellable = model.$captureHotkeyPreset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preset in
                self?.register(preset)
            }
    }

    private func register(_ preset: CaptureHotkeyPreset) {
        hotKeyManager.register(preset) { [weak quickCaptureWindowController] in
            quickCaptureWindowController?.toggle()
        }
    }
}

/// Zen Focus Mode's content-hugging window sizing (ticket 06 follow-up):
/// while Zen mode is on, the window's height tracks
/// `AppModel.idealZenContentHeight` — the real, measured height of
/// whatever `ContentView.zenContent` is currently showing — instead of
/// sitting at a fixed floor with empty space below the last row. Off, this
/// does nothing at all: the window behaves exactly as it always has,
/// user-resizable with no automatic changes. Untouched by the unified-
/// window-and-minimal-view merge (Zen Focus Mode's own mechanism is
/// explicitly out of scope there) — it still resizes the whole window,
/// which now also carries a sidebar alongside whatever `ContentView` is
/// showing.
///
/// A thin adapter: reads the live inputs (`window.frame.height`, the
/// toolbar strip's current height) off the real `NSWindow`, hands them to
/// `zenWindowSizing(...)` (FirstFocusApp), and applies whatever it decides.
/// Every clamp, floor and capture-once rule lives there now, tested
/// without a real window.
@MainActor
final class ZenWindowSizer {
    private let window: NSWindow
    private var cancellable: AnyCancellable?
    /// The window's height from just before Zen mode was last turned on —
    /// see `zenWindowSizing`'s `heightBeforeZenMode` for when this is set
    /// and cleared.
    private var heightBeforeZenMode: CGFloat?
    /// The width from before Zen mode, restored on the way out. Zen
    /// narrows the window to `compactWidth`; the lower floor that allows
    /// it comes from `AppShellView`'s root frame (`WindowFloor.zen`).
    private var widthBeforeZenMode: CGFloat?
    private let compactWidth: CGFloat = 380
    private var isNarrowingForZen = false

    init(window: NSWindow, model: AppModel) {
        self.window = window
        cancellable = model.$isZenFocusModeEnabled
            .combineLatest(model.$idealZenContentHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isZen, idealHeight in
                self?.apply(isZen: isZen, idealHeight: idealHeight)
            }
    }

    private func apply(isZen: Bool, idealHeight: CGFloat) {
        // Everything above the content: the title bar, plus the toolbar when
        // it shows. Read from the layout rect, since the content view's safe
        // area reports 0 once Zen hides the toolbar, which let the title
        // bar cover the Focus header.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let outcome = zenWindowSizing(
            isZen: isZen,
            idealContentHeight: idealHeight,
            chromeInset: chrome,
            currentWindowHeight: window.frame.height,
            heightBeforeZenMode: heightBeforeZenMode,
            minWindowHeight: WindowFloor.size(isZen: isZen).height
        )
        heightBeforeZenMode = outcome.heightBeforeZenMode

        var targetWidth: CGFloat?
        if isZen, widthBeforeZenMode == nil {
            widthBeforeZenMode = window.frame.width
            isNarrowingForZen = true
        } else if !isZen, let width = widthBeforeZenMode {
            widthBeforeZenMode = nil
            isNarrowingForZen = false
            targetWidth = width
        }
        // Keeps asking for the compact width until the window takes it: at
        // launch in Zen the sidebar hasn't collapsed yet and holds the
        // window wider. Once reached, a width the user drags to is left alone.
        if isNarrowingForZen {
            if abs(window.frame.width - compactWidth) < 0.5 {
                isNarrowingForZen = false
            } else {
                targetWidth = compactWidth
            }
        }

        switch outcome.decision {
        case .resize(let target), .restore(let target):
            resize(to: target, width: targetWidth)
        case .noChange:
            if let targetWidth { resize(to: window.frame.height, width: targetWidth) }
        }
    }

    private func resize(to targetHeight: CGFloat, width: CGFloat? = nil) {
        var frame = window.frame
        if let width { frame.size.width = width }
        // Growing/shrinking a window by changing only its height moves the
        // *bottom* edge by default (AppKit's screen coordinates put the
        // origin at the bottom-left) — adjusting `origin.y` by exactly the
        // height delta keeps the top edge, where the toolbar lives, fixed
        // in place instead.
        frame.origin.y += frame.height - targetHeight
        frame.size.height = targetHeight
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Minimal View (ticket 03): the AppKit half of the toggle — hides the
/// window's own `NSToolbar` chrome. `AppShellView` (SwiftUI) handles the
/// other half, collapsing the sidebar/footer via `NavigationSplitView`'s
/// own `columnVisibility`. Both read `AppModel.isMinimalViewEnabled`
/// rather than one driving the other, so neither side needs a reference
/// to the other.
@MainActor
final class MinimalViewToolbarController {
    private var cancellable: AnyCancellable?

    init(window: NSWindow, model: AppModel) {
        // Zen hides the toolbar too, leaving only Focus.
        cancellable = model.$isMinimalViewEnabled
            .combineLatest(model.$isZenFocusModeEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] isMinimal, isZen in
                window?.toolbar?.isVisible = !(isMinimal || isZen)
                if let toolbar = window?.toolbar { lockToIconOnly(toolbar) }
            }
    }
}

/// The toolbar shows icons only. Turning off display-mode customization
/// drops Icon and Text / Icon Only / Text Only from the toolbar's
/// right-click menu, so it can't be changed.
@MainActor func lockToIconOnly(_ toolbar: NSToolbar) {
    toolbar.displayMode = .iconOnly
    toolbar.allowsDisplayModeCustomization = false
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate

/// The menu bar. With no SwiftUI `Scene` there's no default menu, and
/// without an Edit menu nothing carries Command-C/V/X/A/Z, so AppKit never
/// sends `copy:` or `paste:` to the focused field. Edit items have nil
/// targets so the responder chain delivers them to whatever field is first
/// responder, and AppKit's own validation greys them out when nothing can
/// take them. Shift-Command-M stays with the Minimal View key monitor below.
@MainActor func makeMainMenu() -> NSMenu {
    // The bundle's name, not the executable's: the executable is still
    // FirstFocus so the bundle identifier and every Gate stay as they were.
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    let mainMenu = NSMenu()

    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(
        withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    mainMenu.addItem(withTitle: appName, action: nil, keyEquivalent: "").submenu = appMenu

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

    return mainMenu
}
app.mainMenu = makeMainMenu()

// Every store and setting AppModel uses, built once (AppDependencies.live).
// The view models below take the same instances from it rather than
// building their own: one instance, not two that happen to agree because
// both read `UserDefaults.standard` or the same SQLite file.
let dependencies = AppDependencies.live(
    settingsOpener: NSWorkspaceSettingsOpener(),
    foregroundObserver: NSApplicationForegroundObserver(),
    messagesChanges: FSEventsMessagesChangeObserver(directory: liveMessagesDirectory),
    morningBriefSender: MessagesAppSender()
)
let extractionSettings = dependencies.extractionSettings
let reExtractionSettings = dependencies.reExtractionSettings
// History (ADR 0029): the extraction pipeline's writes and the History
// destination's reads hit the same table.
let historyStore = dependencies.historyStore
// The Models destination's download seam (ADR 0028). Nothing but the
// Models view touches it, so it never reaches AppModel.
let modelDownloader = URLSessionModelDownloader()
// Screening (ADR 0036): AppModel builds the Screener; Advanced's Screening
// section edits the settings and the key.
let screeningSettings = dependencies.screeningSettings
let apiKeyStore = dependencies.apiKeyStore
// Rules (ADR 0038): AppModel hands them to the extractor; Advanced's
// Rules section edits them.
let ruleStore = dependencies.ruleStore

let model = AppModel(dependencies)
appDelegate.beforeQuit = { model.prepareToQuit() }

// unified-window-and-minimal-view: built once, alongside `model`, rather
// than rebuilt every time a separate Settings window opened (the old
// `SettingsWindowController.show()` did that, since Settings opened
// rarely and a fresh view model starting from what's actually stored was
// worth the rebuild). Now that these back permanent sidebar destinations
// in the one window that's always open, there's no "opening" event left
// to rebuild on — they're constructed once, like `model` itself.
let settingsViewModel = SettingsViewModel(
    extractionSettings: extractionSettings, reExtractionSettings: reExtractionSettings, extraction: model.extraction
)
let historyViewModel = HistoryViewModel(
    historyStore: historyStore, actions: model.historyActions, screeningSettings: screeningSettings
)
let rulesViewModel = RulesViewModel(store: ruleStore, extraction: model.extraction)
let mutedChatsViewModel = MutedChatsViewModel(actions: model.historyActions, historyStore: historyStore)
let screeningViewModel = ScreeningSettingsViewModel(
    settings: screeningSettings, keyStore: apiKeyStore, extraction: model.extraction, historyStore: historyStore,
    correctionLog: dependencies.correctionStore
)
// Morning Brief (ADR 0046): AppModel builds the delivery from `dependencies`
// and sends a missed Brief at launch. Wake from sleep is the other moment
// one can go out.
let morningBriefViewModel = model.morningBriefViewModel
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    Task { @MainActor in await model.systemDidWake() }
}
let openAtLoginViewModel = OpenAtLoginViewModel(loginItem: MainAppLoginItem())
let modelsViewModel = ModelsViewModel(
    modelDownloader: modelDownloader, extractionSettings: extractionSettings, extraction: model.extraction,
    bundleIdentifier: bundleIdentifier
)

// unified-window-and-minimal-view: a standard titled, bordered,
// single-Space window — like the old Settings window was, not like the
// old `DesktopWindow` (borderless, desktop-level, every-Space, grayed
// traffic lights). That overlay character is deliberately given up here:
// see the spec's Further Notes for what it weakens in ADR 0013's own
// reasoning.
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1110, height: 640),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "FirstFocus"
// No `window.minSize`: the floor comes from `AppShellView`'s root frame
// (`WindowFloor`) through the hosting view below.
window.center()

// Global Hotkey Input (ticket 01): the capture panel and its system-wide
// shortcut are independent of the main window entirely — reachable (and
// toggleable) whether that window is open, minimized, or behind a
// full-screen app.
let quickCaptureWindowController = QuickCaptureWindowController(model: model)
let hotKeyManager = GlobalHotKeyManager()
let captureHotkeyController = CaptureHotkeyController(
    model: model, hotKeyManager: hotKeyManager, quickCaptureWindowController: quickCaptureWindowController
)

// unified-window-and-minimal-view: the AppKit glue `SettingsWindowController`
// used to own (file panels, delete confirmation, export save panel) moves
// here as plain functions closing over `window` and the view models above
// — there's no window controller left to own them, and this window is
// never rebuilt the way Settings used to be, so a closure captured once is
// enough.
@MainActor func revealModelDirectory() {
    let directory = LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    } catch {
        presentAlert(messageText: "Couldn't open the model folder", informativeText: error.localizedDescription)
    }
}

@MainActor func chooseCustomModelFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let ggufType = UTType(filenameExtension: "gguf") {
        panel.allowedContentTypes = [ggufType]
    }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        Task { await modelsViewModel.chooseCustomFile(url) }
    }
}

/// Deleting a model the app itself is about to disable extraction with
/// gets a confirmation; deleting any other downloaded model does not
/// (ADR 0028) — the existing missing-path degrade (`extractionUnavailable`)
/// already covers a path going stale for reasons outside the app.
@MainActor func confirmDeleteActiveModel(_ entry: ModelCatalogEntry) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "This is your active model."
    alert.informativeText = "Deleting it will disable extraction until you select a new one."
    alert.addButton(withTitle: "Delete Anyway")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        try? modelsViewModel.delete(entry)
    }
}

@MainActor func presentSavePanel(offering temporaryURL: URL) {
    let panel = NSSavePanel()
    // The temp file's name carries a UUID; offer a readable one with the
    // same extension, since History exports both CSV and Markdown.
    let fileExtension = temporaryURL.pathExtension
    panel.nameFieldStringValue = "FirstFocus History.\(fileExtension)"
    if let fileType = UTType(filenameExtension: fileExtension) {
        panel.allowedContentTypes = [fileType]
    }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
        } catch {
            presentAlert(messageText: "Couldn't save the export", informativeText: error.localizedDescription)
        }
    }
}

@MainActor func presentAlert(messageText: String, informativeText: String) {
    let alert = NSAlert()
    alert.messageText = messageText
    alert.informativeText = informativeText
    alert.beginSheetModal(for: window)
}

// unified-window-and-minimal-view (fix): a manual `NSToolbarDelegate`
// here doesn't work once the window's content is a `NavigationSplitView`
// — confirmed by hand: `NavigationSplitView` claims `window.toolbar` for
// its own sidebar-toggle button and discards whatever was assigned before
// it (verified via a debug dump: `window.toolbar` no longer matched a
// custom toolbar assigned here, and its `isVisible` came back `false`).
// Fighting that by reassigning `window.toolbar` after the fact was
// considered and rejected: fragile timing against SwiftUI's own internal
// scheduling, versus just using the toolbar mechanism `NavigationSplitView`
// already owns. The Add/Minimal View/More items live in `AppShellView`'s
// own `.toolbar` modifier instead — see there. `window.toolbarStyle` is a
// window-level property independent of which toolbar object is attached,
// so it's still set here.
window.toolbarStyle = .unified

// Updates (ADR 0044): Sparkle checks the feed in Info.plist's SUFeedURL on
// its own schedule, and shows its standard window (release notes, Install,
// Skip, Remind Me Later) when there is a newer build. Installing needs the
// app to quit; `AppDelegate`'s `_exit(0)` is fine, since Sparkle's
// installer is a separate process waiting for this one to end.
let updateChecker = UpdateChecker()

let hostingView = NSHostingView(rootView: AppShellView(
    model: model, settingsViewModel: settingsViewModel, historyViewModel: historyViewModel,
    modelsViewModel: modelsViewModel, screeningViewModel: screeningViewModel, rulesViewModel: rulesViewModel,
    mutedChatsViewModel: mutedChatsViewModel, morningBriefViewModel: morningBriefViewModel,
    openAtLoginViewModel: openAtLoginViewModel, updateChecker: updateChecker,
    onChooseCustomModelFile: { chooseCustomModelFile() },
    onRevealModelDirectory: { revealModelDirectory() },
    onExportHistory: { url in presentSavePanel(offering: url) },
    onDeleteActiveModelRequiringConfirmation: { entry in confirmDeleteActiveModel(entry) }
))
// The AppKit form of a `WindowGroup`'s `.windowResizability(.contentSize)`:
// the window's minimum follows the SwiftUI root's minimum. Only `.minSize`,
// since the root sets no maximum, and without `.intrinsicContentSize` a
// screen's ideal size can't move the window when the sidebar switches.
hostingView.sizingOptions = [.minSize]
window.contentView = hostingView
window.makeKeyAndOrderFront(nil)
// unified-window-and-minimal-view (fix): this window's SwiftUI content
// (`AppShellView`, hosted via a bare `NSHostingView` on a raw `NSWindow`
// with no `Scene`) has a first-paint gap confirmed by hand in two
// unrelated places: `NavigationSplitView`'s own `NSToolbar` installs the
// items from `AppShellView`'s `.toolbar` modifier asynchronously, and
// they sit in the toolbar's model — correctly sized, with real backing
// views — without ever being painted; separately, the sidebar's
// initially-selected row (Main) renders as blank space even though
// selection and detail content are both already correct. Both are the
// same symptom (real, laid-out content that AppKit never gives an actual
// paint pass), and both are fixed by the same nudge: forcing a full
// window relayout. A 1pt resize and back, confirmed by hand to repaint
// both the toolbar icons and the sidebar's Main row, is blunter than
// re-toggling just the toolbar's `isVisible` (which only fixed the
// toolbar) but catches whatever else this same gap turns out to affect.
//
// Polled rather than delayed by a guessed duration: launch's own startup
// work (Reminders/Messages/model loading) makes "how long until the
// content is mounted" variable, and a nudge fired before the toolbar's
// custom items exist at all is a no-op. `toolbar.items.count > 3` (more
// than the sidebar-toggle/flexibleSpace/separator NavigationSplitView
// installs on its own) is a proxy for "the view hierarchy has mounted
// far enough to be worth nudging" — the sidebar mounts in the same pass.
// Capped at 5s and self-cancelling either way, so a launch slower than
// that degrades to missing chrome, not a runaway timer.
@MainActor func pollForMountThenNudgeLayout(attempt: Int = 0) {
    if let toolbar = window.toolbar, toolbar.items.count > 3 {
        lockToIconOnly(toolbar)
        var frame = window.frame
        frame.size.width += 1
        window.setFrame(frame, display: true)
        frame.size.width -= 1
        window.setFrame(frame, display: true)
        return
    }
    guard attempt < 25 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        pollForMountThenNudgeLayout(attempt: attempt + 1)
    }
}
pollForMountThenNudgeLayout()

// Held for the process's whole life, same as every other top-level
// controller above — there's no `deinit` any of these would ever need to
// balance against.
let zenWindowSizer = ZenWindowSizer(window: window, model: model)
// Minimal View (ticket 03): reads `window.toolbar` fresh each time it
// fires rather than holding a reference captured at launch, so it still
// finds and hides whatever toolbar `NavigationSplitView` actually
// installed (see the note above `window.toolbarStyle` for why that
// matters here).
let minimalViewToolbarController = MinimalViewToolbarController(window: window, model: model)

// Esc leaves Zen Focus Mode or Minimal View, both of which hide the toolbar
// holding their own buttons.
// ⇧⌘M lives on the View menu now (`MenuCommands`), so this monitor only
// handles Esc, and only when nothing else in the window wants it.
let minimalViewEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let escapeKeyCode: UInt16 = 53
    guard event.keyCode == escapeKeyCode,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
        model.pressEscape(window: WindowFocus(isMainWindowKey: NSApp.keyWindow === window, hasSheet: window.attachedSheet != nil))
    else {
        return event
    }
    return nil
}

// ⌘Z triggers the Undo bar (inbox-undo) before the Edit menu sees it,
// except while text is being edited, where it keeps undoing typing. A
// text field's editor is an `NSText`.
let undoBarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    guard event.charactersIgnoringModifiers?.lowercased() == "z",
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        model.pressCommandZ(window: WindowFocus(
            isMainWindowKey: NSApp.keyWindow === window, hasSheet: window.attachedSheet != nil,
            isEditingText: window.firstResponder is NSText
        ))
    else {
        return event
    }
    return nil
}

/// The menu bar's commands: the only home for Re-run Extraction, History
/// export and the unfiltered History log, and a second one for the
/// toolbar's Zen and Minimal View toggles and for opening the Checked Off
/// sheet, with their shortcuts; plus "About FirstFocus" opening the About
/// screen rather than the stock panel.
@MainActor
final class MenuCommands: NSObject, NSMenuItemValidation {
    @objc func showAbout(_ sender: Any?) {
        NotificationCenter.default.post(name: .showAboutScreen, object: nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func reExtract(_ sender: Any?) {
        Task { await model.reExtract() }
    }

    @objc func toggleZenFocusMode(_ sender: Any?) {
        model.isZenFocusModeEnabled.toggle()
    }

    @objc func toggleMinimalView(_ sender: Any?) {
        model.isMinimalViewEnabled.toggle()
    }

    @objc func toggleCheckedOffSheet(_ sender: Any?) {
        model.toggleCheckedOffSheet()
    }

    @objc func exportHistoryMarkdown(_ sender: Any?) {
        if let url = historyViewModel.exportMarkdown() { presentSavePanel(offering: url) }
    }

    @objc func toggleUnfilteredHistoryLog(_ sender: Any?) {
        historyViewModel.showsUnfilteredLog.toggle()
    }

    @objc func exportHistoryCSV(_ sender: Any?) {
        if let url = historyViewModel.exportCSV() { presentSavePanel(offering: url) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reExtract(_:)):
            menuItem.title = model.reExtractionMenuTitle
            return model.canReExtract
        case #selector(toggleZenFocusMode(_:)):
            menuItem.state = model.isZenFocusModeEnabled ? .on : .off
        case #selector(toggleMinimalView(_:)):
            menuItem.state = model.isMinimalViewEnabled ? .on : .off
        case #selector(toggleCheckedOffSheet(_:)):
            return model.canToggleCheckedOffSheet
        case #selector(toggleUnfilteredHistoryLog(_:)):
            menuItem.state = historyViewModel.showsUnfilteredLog ? .on : .off
        default:
            break
        }
        return true
    }

    func install(in mainMenu: NSMenu) {
        if let aboutItem = mainMenu.items.first?.submenu?.items.first {
            aboutItem.target = self
            aboutItem.action = #selector(showAbout(_:))
        }

        let fileMenu = NSMenu(title: "File")
        add("Re-run Extraction", #selector(reExtract(_:)), key: ShortcutCatalog.reRunExtraction, to: fileMenu)
        fileMenu.addItem(.separator())
        add(
            "Export History as Markdown…", #selector(exportHistoryMarkdown(_:)), key: ShortcutCatalog.exportHistoryMarkdown,
            to: fileMenu
        )
        add("Export History as CSV…", #selector(exportHistoryCSV(_:)), key: nil, to: fileMenu)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.insertItem(fileItem, at: 1)

        let viewMenu = NSMenu(title: "View")
        add("Zen Focus Mode", #selector(toggleZenFocusMode(_:)), key: ShortcutCatalog.zenFocusMode, to: viewMenu)
        add("Minimal View", #selector(toggleMinimalView(_:)), key: ShortcutCatalog.minimalView, to: viewMenu)
        viewMenu.addItem(.separator())
        add("Checked Off Today", #selector(toggleCheckedOffSheet(_:)), key: ShortcutCatalog.checkedOffToday, to: viewMenu)
        viewMenu.addItem(.separator())
        add(
            "Show Unfiltered History Log", #selector(toggleUnfilteredHistoryLog(_:)), key: ShortcutCatalog.showUnfilteredHistoryLog,
            to: viewMenu
        )
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.insertItem(viewItem, at: 3)
    }

    /// The key comes from the item's `ShortcutCatalog` entry, so About
    /// lists the same one. An uppercase key means ⇧⌘, a lowercase one ⌘ alone.
    private func add(_ title: String, _ action: Selector, key: ShortcutEntry?, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key?.menuKeyEquivalent ?? "")
        item.target = self
        menu.addItem(item)
    }
}

// One window, so no window tabs: this also keeps macOS from adding
// "Show Tab Bar" and "Show All Tabs" to the View menu.
NSWindow.allowsAutomaticWindowTabbing = false
let menuCommands = MenuCommands()
if let mainMenu = app.mainMenu {
    menuCommands.install(in: mainMenu)
    let checkForUpdates = NSMenuItem(
        title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: ""
    )
    checkForUpdates.target = updateChecker.controller
    mainMenu.items.first?.submenu?.insertItem(checkForUpdates, at: 1)
}

Task { @MainActor in
    await model.start()
}

app.run()
