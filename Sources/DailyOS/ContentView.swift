import AppKit
import DailyOSApp
import DailyOSCore
import Foundation
import SwiftUI

/// Shared leading-icon column width across every row style (checkbox,
/// approve, dismiss) so the checkbox, task text, and trailing metadata
/// all start at the same x-position regardless of which icon a given row
/// happens to show.
private let leadingIconColumnWidth: CGFloat = 24
private let rowVerticalPadding: CGFloat = 8
/// Shared leading/trailing inset for every row, in the scrolling `List`
/// and the Suggested Tasks Inbox alike — `List` on macOS otherwise applies
/// its own default row inset, a few points off from the Suggested
/// section's manually-applied padding, so the leading icon column drifts
/// out of alignment between the two areas.
private let rowHorizontalInset = EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
/// Uniform breathing room above every section header — Suggested, Focus,
/// Later, and the unavailable-source headers alike — now that any of them
/// can end up first depending on what's actually open. A little extra
/// space above the very first header in the list is a fine trade for one
/// rule instead of a special case for whichever section used to always be
/// first.
private let sectionHeaderTopPadding: CGFloat = 10
/// Zen Focus Mode's content-hugging window sizing measures the row stack
/// exactly, which otherwise ends the window right at the last row's own
/// bottom edge — this is the deliberate extra margin below it.
private let zenBottomPadding: CGFloat = 16
/// Trailing clearance reserved inside every scroll container so macOS's own
/// scrollbar track never overlaps a Section chevron or a row's own trailing
/// buttons — a custom-chrome, borderless window like this one gets no such
/// margin for free the way a system-chrome window does. Applied to the
/// scroll container itself (`.contentMargins`), not to `rowHorizontalInset`
/// above: that inset exists to keep the leading icon column aligned between
/// `List` and the Suggested Tasks Inbox, a separate concern from giving the
/// scrollbar its own lane.
private let scrollbarTrailingClearance: CGFloat = 16

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row Rename… was chosen on, while its sheet is open.
    @State private var renamingSignal: Signal?
    @State private var deletingSignal: Signal?
    /// The one Focus or Later row whose Notes drawer is open, if any.
    /// Opening another row closes this one.
    @State private var expandedRowId: String?
    // Which Sections are collapsed is AppModel's (`collapsedSections`), so
    // the Inbox's keys can tell when its rows are hidden.

    /// Apple's default UI spring — critically damped, no overshoot — for
    /// list reordering and row removal. Reduce Motion gets a short
    /// cross-fade instead of a slide/spring, never no feedback at all.
    private var listAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1.0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if model.isAddingTask && !model.presentation.showsFocus {
                    NewReminderRow { title, dueAt in
                        addReminder(title: title, dueAt: dueAt)
                    } onClose: {
                        model.isAddingTask = false
                    }
                    .padding(rowHorizontalInset)
                }
                mainContent
            }

            if let offer = model.undoOffer {
                UndoBar(text: offer.text, onUndo: offer.canUndo ? { Task { await model.undo() } } : nil)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(listAnimation, value: model.undoOffer)
        // No minimum here: the window's floor lives once, on
        // `AppShellView`'s root (`WindowFloor`), so switching screens
        // never changes it. This only pins short content to the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Native materiality (CONTEXT.md: Visual Language): a real system
        // material, not a custom gradient. `ignoresSafeAreaEdges: .all`
        // originally let the material extend up under the old
        // transparent, merged title/toolbar strip (`.fullSizeContentView`)
        // — the window is a standard bordered, titled window now
        // (main.swift), with no transparent chrome left for content to
        // extend under, so this is effectively a no-op today. Left in
        // rather than removed: harmless, and reverting it needs the same
        // by-hand confirmation the frame above does.
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
        // The (+) / Minimal View / overflow buttons are NOT declared here.
        // `AppShellView`'s `.toolbar` modifier owns them — attached there
        // rather than here since they need to stay reachable from every
        // sidebar destination, not just Main. A manual `NSToolbarDelegate`
        // was tried first and abandoned: `NavigationSplitView` claims
        // `window.toolbar` for its own sidebar-toggle button and discards
        // whatever was assigned before it, confirmed by hand (see
        // `main.swift`'s note above `window.toolbarStyle`).
        // A sheet, not an alert: an alert can't show the date badge, and
        // on macOS its TextField came up empty from the second showing on.
        .sheet(item: $renamingSignal) { signal in
            RenameReminderSheet(title: signal.label) { title, dueAt in
                Task { await model.renameTask(signal, to: title, dueAt: dueAt) }
            }
        }
        .alert(
            "Delete this reminder?",
            isPresented: Binding(get: { deletingSignal != nil }, set: { if !$0 { deletingSignal = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let signal = deletingSignal {
                    Task { await model.deleteTask(signal) }
                }
                deletingSignal = nil
            }
            Button("Cancel", role: .cancel) {
                deletingSignal = nil
            }
        }
    }

    /// The precedence among the five screens below is decided by
    /// `ListPresentation.screenMode`, not here — this only switches over it.
    @ViewBuilder
    private var mainContent: some View {
        switch model.presentation.screenMode {
        case .backfill(let completed, let total):
            BackfillProgressView(completed: completed, total: total)
        case .loading:
            Text("Loading…")
                .foregroundStyle(.secondary)
        case .empty:
            VStack(spacing: 0) {
                Text("Nothing open. Nice.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.showsCheckedOffCount {
                    pinnedCheckedOffCount
                }
            }
        case .zen:
            zenContent
        case .list:
            // The count sits under the list, not in it, so it stays pinned
            // to the bottom of the window however short the lists are
            // (CONTEXT.md: Checked Off).
            VStack(spacing: 0) {
                signalList
                if model.showsCheckedOffCount {
                    pinnedCheckedOffCount
                }
            }
        }
    }

    /// The Focus and Later list with its keyboard triage and scroll
    /// handling: the `.list` screen, minus the Checked Off count below it.
    private var signalList: some View {
        ScrollViewReader { proxy in
            List {
                signalListRows
            }
            .onChange(of: model.focusedSuggestionId) { _, focused in
                if let focused { proxy.scrollTo(focused) }
            }
        }
        .listStyle(.plain)
        // Keyboard triage of the Suggested Tasks Inbox (batched-
        // extraction ticket 08). `AppModel.pressInboxKey` decides
        // whether the Inbox claims the press, so the keys never
        // swallow one anything else in the window might want.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .delete, .deleteForward, .space, .escape]) { press in
            let key: AppModel.InboxKey
            switch press.key {
            case .upArrow: key = .up
            case .downArrow: key = .down
            case .return: key = .approve
            case .space: key = .togglePreview
            case .escape: key = .closePreview
            default: key = .dismiss
            }
            return model.pressInboxKey(key) ? .handled : .ignored
        }
        .scrollContentBackground(.hidden)
        // No manual top-safe-area override here. This mattered when the
        // window had a merged, transparent title/toolbar strip
        // (`.fullSizeContentView`) that content laid out underneath —
        // forcing a matching `.ignoresSafeArea`/`.safeAreaInset`
        // override (as `zenContent` below used to as well) was tried
        // and found to be the actual bug then: it made the injected
        // inset land mid-content instead of at the top, crowding the
        // first section header up against the toolbar. Since the
        // unified-window-and-minimal-view merge (main.swift), the
        // window is a standard titled, bordered window instead, whose
        // real title bar provides its own clearance — there is no
        // inset left to override either way.
        .contentMargins(.trailing, scrollbarTrailingClearance, for: .scrollContent)
        .animation(listAnimation, value: model.rankedList)
    }

    /// The Checked Off count at the bottom of the window, outside the
    /// scroll view, under both the list and the empty screen.
    private var pinnedCheckedOffCount: some View {
        CheckedOffCountButton(count: model.checkedOffCount) { model.toggleCheckedOffSheet() }
            .padding(.vertical, sectionHeaderTopPadding)
    }

    /// Zen Focus Mode's content-hugging path: `List` always wants to fill
    /// whatever height it's given (there's no such thing as an "intrinsic
    /// size" for a scroll container), so a `List`-hosted window can only
    /// ever get *smaller* by an outside actor shrinking it, never by the
    /// content itself reporting how tall it actually is. A plain `VStack`
    /// inside a `ScrollView` does have a real intrinsic height along its
    /// scroll axis, so `GeometryReader` here measures it honestly — no
    /// per-row pixel constant to keep in sync with font size, Dynamic
    /// Type, or how many lines a label happens to wrap to. `ZenWindowSizer`
    /// (main.swift) reads `idealZenContentHeight` and resizes the window
    /// to match, clamped to a sane range; the `ScrollView` still scrolls
    /// normally if the window (hence its own viewport) ends up shorter
    /// than the content wants, the same as it would past that clamp.
    /// `.listRowInsets`/`.listRowSeparator` inside `signalListRows` are
    /// silently inert outside a `List`, so the leading/trailing margin
    /// they gave every row there is reapplied once, here, around the whole
    /// stack instead.
    private var zenContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                signalListRows
            }
            // Belt-and-suspenders alongside `rowContent`'s own
            // `.frame(maxWidth: .infinity)`: a plain `VStack` sizes itself
            // to its children's natural width unless something asks it to
            // do otherwise, regardless of how much width `ScrollView`
            // offers it. Without this, a row requesting full width had
            // nothing above it actually providing that width to request.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(rowHorizontalInset)
            // Breathing room below the last row — content-hugging means
            // the measured height is otherwise exactly the last row's own
            // bottom edge, reading as cramped against the window's rounded
            // corner. Included before `.onGeometryChange` below so it's
            // part of what gets measured, not tacked on after.
            .padding(.bottom, zenBottomPadding)
            // `.onGeometryChange` (not the older GeometryReader-as-
            // -background/PreferenceKey pattern, which measured a
            // degenerate first-layout-pass proposal here instead of the
            // content's real height — confirmed empirically, reported 0
            // with real rows on screen) reads the VStack's actual
            // resolved size directly, firing again on every subsequent
            // change.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                model.idealZenContentHeight = newHeight
            }
        }
        // No manual top-safe-area override here either — same finding as
        // the normal-mode `List` above: forcing one via
        // `.ignoresSafeArea`/`.safeAreaInset` was the actual bug (crowded
        // the header up against the toolbar), not a fix for one. A plain
        // `ScrollView` gets the correct automatic top inset on its own.
        .contentMargins(.trailing, scrollbarTrailingClearance, for: .scrollContent)
        .animation(listAnimation, value: model.rankedList)
    }

    /// The rows and section headers themselves — identical content
    /// whether it ends up inside `List` (normal mode) or a plain `VStack`
    /// (`zenContent`, Zen mode). A `@ViewBuilder` group doesn't care which
    /// container it's embedded in, so this is the one place that content
    /// is written, not two drifting copies of it.
    @ViewBuilder
    private var signalListRows: some View {
        // Suggested lives in the same scrolling area as everything else
        // now, as its own leading run of rows — not a separately-capped
        // container above it. Sizing follows straight from the row count:
        // no items, no rows, nothing reserved; a large batch just extends
        // whichever container is currently in use, so Focus and Later are
        // always reachable by scrolling however far, never pushed off
        // with no way back.
        //
        // Zen Focus Mode hides it outright, same as Later: Zen is meant
        // to be Focus and nothing else — an unconfirmed guess competing
        // for the same screen space undercuts that, even though normal
        // mode still shows it.
        // Suggested lives in the same scrolling area as everything else,
        // as its own leading run of rows; Focus renders fully expanded,
        // no chevron — this is a "what should I work on next" tool, and
        // letting its one unmissable tier hide itself would undercut the
        // point; Later gets a chevron, so a long Later list can be tucked
        // away. `ListPresentation.sections` is the one place any of that —
        // including Zen Focus Mode hiding Suggested and Later outright —
        // is decided; this only draws it.
        //
        // Deliberately not `Section(header:)`: on macOS its header slot
        // keeps drawing a divider under itself even with `.plain` list
        // style and every row/section-separator modifier applied — a
        // plain header row in a flat list carries no such built-in chrome
        // to fight, so separation is genuinely padding alone, all the way
        // down. The collapse chevron below is a plain button on that same
        // plain row, not `Section(isExpanded:)`, for the same reason.
        ForEach(model.presentation.sections) { section in
            switch section {
            case .suggested(let suggestedSignals):
                SectionHeaderText("Suggested", isCollapsed: model.isCollapsed(.inbox)) {
                    model.toggleCollapse(.inbox)
                }
                .padding(.top, sectionHeaderTopPadding)
                .listRowSeparator(.hidden)
                .listRowInsets(rowHorizontalInset)
                if !model.isCollapsed(.inbox) {
                    ForEach(suggestedSignals) { signal in
                        SuggestedSignalRow(
                            signal: signal,
                            isKeyboardFocused: model.focusedSuggestionId == signal.id,
                            isPreviewShown: Binding(
                                get: { model.previewedSuggestionId == signal.id },
                                set: { isShown in
                                    if isShown {
                                        model.showPreview(forSuggestionId: signal.id)
                                    } else {
                                        model.hidePreview(forSuggestionId: signal.id)
                                    }
                                }
                            ),
                            onApprove: { Task { await model.approve(signal) } },
                            onApproveAndSnooze: { choice in Task { await model.approve(signal, snoozing: choice) } },
                            onDismiss: { model.dismiss(signal) },
                            onNotForMe: model.notForMeOffers.contains(signal.id)
                                ? { model.notForMe(signal) } : nil,
                            onDeepLink: { MessagesDeepLinkOpener.open(messagesDeepLinkTarget(for: signal)) }
                        )
                    }
                }
            case .tier(let tier, let groups):
                Group {
                    if tier == .later {
                        SectionHeaderText(tier.header, isCollapsed: model.isCollapsed(.later)) {
                            model.toggleCollapse(.later)
                        }
                    } else {
                        SectionHeaderText(tier.header)
                    }
                }
                .padding(.top, sectionHeaderTopPadding)
                .listRowSeparator(.hidden)
                .listRowInsets(rowHorizontalInset)
                // A header takes drops too, so a collapsed Later is still a
                // target.
                .dropDestination(for: String.self) { draggedIds, _ in
                    guard let draggedId = draggedIds.first else { return false }
                    Task { await model.drop(draggedId, onto: .tier(tier)) }
                    return true
                }
                if tier == .focus && model.isAddingTask {
                    NewReminderRow { title, dueAt in
                        addReminder(title: title, dueAt: dueAt)
                    } onClose: {
                        model.isAddingTask = false
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowHorizontalInset)
                }
                if groups.isEmpty {
                    EmptyFocusDropZone { draggedId in Task { await model.drop(draggedId, onto: .tier(.focus)) } }
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowHorizontalInset)
                } else if !(tier == .later && model.isCollapsed(.later)) {
                    signalRows(for: groups)
                }
            case .snoozed(let snoozedSignals):
                // Takes no drops: nothing is dragged into or out of it.
                SectionHeaderText("Snoozed (\(snoozedSignals.count))", isCollapsed: model.isCollapsed(.snoozed)) {
                    model.toggleCollapse(.snoozed)
                }
                .padding(.top, sectionHeaderTopPadding)
                .listRowSeparator(.hidden)
                .listRowInsets(rowHorizontalInset)
                if !model.isCollapsed(.snoozed) {
                    ForEach(snoozedSignals) { signal in
                        signalRow(for: signal, groupPosition: nil)
                    }
                }
            case .notice(let notice):
                SectionHeaderText(noticeHeader(for: notice))
                    .padding(.top, sectionHeaderTopPadding)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowHorizontalInset)
                noticeRow(for: notice)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowHorizontalInset)
            }
        }
    }

    /// A Notice's header and body are presentation, so they live here
    /// rather than in `DailyOSCore.Notice`, which carries identity alone.
    private func noticeHeader(for notice: Notice) -> String {
        switch notice {
        case .messagesUnavailable: return "Messages"
        case .remindersUnavailable: return "Reminders"
        case .extractionUnavailable: return "Extraction"
        }
    }

    @ViewBuilder
    private func noticeRow(for notice: Notice) -> some View {
        switch notice {
        case .messagesUnavailable:
            UnavailableSourceRow(
                instructions: "Full Disk Access is needed to read your messages.",
                onOpenSettings: { model.openFullDiskAccessSettings() },
                onRetry: { Task { await model.reloadMessages() } }
            )
        case .remindersUnavailable:
            UnavailableSourceRow(
                instructions: "Reminders access is needed to rank your open reminders.",
                onOpenSettings: { model.openRemindersSettings() },
                onRetry: { Task { await model.reload() } }
            )
        case .extractionUnavailable:
            ExtractionUnavailableRow(
                onRetry: { Task { await model.retryLoadingExtractor() } }
            )
        }
    }

    /// Shared between every Tier's `Section` so they don't carry separate
    /// copies of the same row-construction code. Rename and delete only
    /// make sense for a Reminders Signal — see `AppModel.renameTask`/
    /// `deleteTask`. Subtask grouping (ticket 04) is computed fresh here,
    /// at render time, from `sourceRef` + `lowConfidence` alone — nothing
    /// about a grouped Signal's own row changes what it can do, only how
    /// adjacent rows from the same message are drawn next to each other.
    @ViewBuilder
    private func signalRows(for groups: [RenderGroup]) -> some View {
        ForEach(groups) { renderGroup in
            switch renderGroup {
            case .single(let signal):
                signalRow(for: signal, groupPosition: nil)
            case .group(let members):
                ForEach(Array(members.enumerated()), id: \.element.id) { offset, signal in
                    signalRow(
                        for: signal,
                        groupPosition: offset == 0 ? .top : (offset == members.count - 1 ? .bottom : .middle)
                    )
                }
            }
        }
    }

    /// Which actions `signal`'s row offers — `ListPresentation.affordances(for:)`
    /// decides this (candidate 4, ADR 0023) against the moment the list
    /// was ranked, not this view.
    @ViewBuilder
    private func signalRow(for signal: Signal, groupPosition: SignalRow.GroupPosition?) -> some View {
        SignalRow(
            signal: signal,
            affordances: model.presentation.affordances(for: signal),
            isOverdue: model.presentation.isOverdue(signal),
            drawer: rowDrawer(for: signal),
            isExpanded: expandedRowId == signal.id,
            perform: { action in perform(action, on: signal) },
            groupPosition: groupPosition
        )
    }

    /// The one place every `SignalRowAction` a row can send is dispatched
    /// — previously scattered across nine separately-constructed closures
    /// at the call site above.
    private func perform(_ action: SignalRowAction, on signal: Signal) {
        switch action {
        case .checkOff:
            model.checkOff(signal)
        case .dismiss:
            model.dismiss(signal)
        case .snooze(let choice):
            model.snooze(signal, choice)
        case .unsnooze:
            model.unsnooze(signal)
        case .toggleDrawer:
            setExpandedRow(expandedRowId == signal.id ? nil : signal.id)
        case .closeDrawer:
            if expandedRowId == signal.id { setExpandedRow(nil) }
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .rename:
            renamingSignal = signal
        case .delete:
            deletingSignal = signal
        case .promote:
            Task { await model.promote(signal) }
        case .demote:
            Task { await model.demote(signal) }
        case .drop(let draggedId):
            Task { await model.drop(draggedId, onto: .row(id: signal.id)) }
        }
    }

    /// Opens or closes a Notes drawer, instantly under Reduce Motion.
    private func setExpandedRow(_ id: String?) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            expandedRowId = id
        }
    }

    /// The `+` field's Return. Where the reminder lands is `AppModel`'s
    /// call, and so is opening Later when that's where it went.
    private func addReminder(title: String, dueAt: Date?) {
        Task { _ = await model.addReminder(title: title, dueAt: dueAt) }
    }

}

/// The count at the end of the list, and under the empty screen, that
/// opens the Checked Off sheet: plain muted text, so it reads as a status
/// line rather than one more row of work.
private struct CheckedOffCountButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(checkedOffCountText(count), action: action)
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

/// Today's checked-off reminders, newest first (CONTEXT.md: Checked Off).
/// Updates while open, and stays open when it empties: only Done, Esc,
/// ⇧⌘C or entering Zen close it. The rows scroll once they outgrow the
/// sheet's 600 pt cap.
struct CheckedOffSheet: View {
    @ObservedObject var model: AppModel
    /// The rows' own height, measured, so the scroll view hugs a short
    /// list: a sheet sizes to its content's ideal height, which a bare
    /// `ScrollView` doesn't report.
    @State private var rowsHeight: CGFloat = 0

    /// What's left of the 600 pt cap after the title and the Done bar.
    private let maxRowsHeight: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            Text("Completed Today")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if model.checkedOff.isEmpty {
                Text("No reminders completed today")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self, of: \.size.height) { rowsHeight = $0 }
                }
                .frame(height: min(rowsHeight, maxRowsHeight))
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 400)
        // Esc: a sheet on macOS closes on it only through a cancel-action
        // button, and the visible one is Done, which takes ⏎.
        .background {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    private func close() {
        model.isCheckedOffSheetPresented = false
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.checkedOff) { reminder in
                CheckedOffRow(reminder: reminder) {
                    Task { await model.uncheck(reminder) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// A row in the Checked Off sheet: a record, not a workspace. A filled
/// checkbox, the title struck through, the due date never red, and no
/// Sender pill, drag, snooze, context menu or Notes drawer. The checkbox
/// is the one control: it unchecks, reopening the reminder. A recurring
/// reminder's checkbox is dimmed and ignores clicks, since reopening it
/// would fork the recurrence.
private struct CheckedOffRow: View {
    let reminder: CheckedOffReminder
    let onUncheck: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUncheck) {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(PressableIconButtonStyle())
            .foregroundStyle(.secondary)
            .disabled(reminder.isRecurring)
            .opacity(reminder.isRecurring ? 0.4 : 1)
            .help(reminder.isRecurring ? "Repeating reminder. Change it in Reminders." : "")
            .frame(width: leadingIconColumnWidth, alignment: .leading)
            Text(reminder.task.title)
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dueAt = reminder.task.dueAt {
                Text(relativeDueDateText(dueAt))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, rowVerticalPadding)
    }
}

/// A muted, Title Case section header — deliberately not the system list
/// style's own header treatment, so casing stays exactly this regardless
/// of platform default (`.textCase(nil)` blocks any implicit uppercasing
/// `List` might otherwise apply). `.title3.weight(.semibold)` reads as a
/// real heading against `.body`-sized row text, not just a slightly-bolder
/// version of it.
///
/// `isCollapsed`/`onToggle` are both-or-neither: passing one without the
/// other has no effect, since there's no sensible default toggle action.
/// When neither is passed, the header renders with no chevron at all —
/// `Focus` and the unavailable-source headers stay this way on purpose.
private struct SectionHeaderText: View {
    let title: String
    private var isCollapsed: Bool?
    private var onToggle: (() -> Void)?

    init(_ title: String) {
        self.title = title
    }

    init(_ title: String, isCollapsed: Bool, onToggle: @escaping () -> Void) {
        self.title = title
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            if let isCollapsed, let onToggle {
                Spacer()
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        // `chevron.right`'s glyph tapers to a point rather
                        // than filling a flat right edge the way a due-date
                        // capsule or badge does, so even though its
                        // bounding box already reaches the same trailing
                        // margin as those, most of its visible ink sits
                        // inset from it — reading as "pulled in" against a
                        // sibling with a flat edge. Nudged out to compensate
                        // for the glyph shape, not the layout; tuned by eye
                        // against the real window, not derived.
                        .offset(x: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isCollapsed)
    }
}

/// Sender-on-approval's pill color — the system accessor, not a fixed
/// `Color`, matching `DueDateText`'s own reasoning for `.systemRed`: it
/// adapts to whatever's behind this window's `.ultraThinMaterial`
/// background instead of staying one fixed hue. Blue rather than red
/// specifically to read as a different kind of meaning than "overdue."
private let senderPillColor = Color(nsColor: .systemBlue)

/// Focus with nothing in it, shown while Later has rows: a drop target, so
/// a Later row can be dragged into Focus.
private struct EmptyFocusDropZone: View {
    let onDrop: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        Text("Drag a task here to move it into Focus.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(isTargeted ? .secondary : .quaternary)
            )
            .dropDestination(for: String.self) { draggedIds, _ in
                guard let draggedId = draggedIds.first else { return false }
                onDrop(draggedId)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

/// Rename…'s sheet. A date phrase typed into the title shows the same badge
/// as `+`, and Save sets it as the due date, without the phrase (ADR 0030
/// amendment). Dates already in the title when it opens count as words:
/// saving an unchanged title never moves its due date.
private struct RenameReminderSheet: View {
    let onSave: (_ title: String, _ dueAt: Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry: TypedTitleEntry
    @FocusState private var isFocused: Bool

    init(title: String, onSave: @escaping (_ title: String, _ dueAt: Date?) -> Void) {
        self.onSave = onSave
        _entry = State(initialValue: TypedTitleEntry(text: title))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Reminder")
                .font(.headline)
            HStack(spacing: 8) {
                TypedTitleField(entry: $entry) { text in
                    TextField("Title", text: text)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onSubmit(save)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.isBlank)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard let saved = entry.submit() else { return }
        onSave(saved.title, saved.dueAt)
        dismiss()
    }
}

/// Inline reminder entry, opened by the toolbar's `+`. Return adds the
/// reminder and clears the field for the next one; Return on an empty
/// field, Esc, or clicking away closes it. It sits under the Focus header
/// and adds with a Priority, so the task stays in Focus; with no Focus on
/// screen it sits at the top and adds with none, landing in Later. A date
/// phrase shows as a badge and is saved as the due date instead (ADR 0030
/// amendment). `AppModel.addReminder` decides the Priority.
private struct NewReminderRow: View {
    let onAdd: (_ title: String, _ dueAt: Date?) -> Void
    let onClose: () -> Void
    @State private var entry = TypedTitleEntry()
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .frame(width: leadingIconColumnWidth, alignment: .leading)
            TypedTitleField(entry: $entry) { text in
                TextField("New Reminder", text: text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onExitCommand(perform: onClose)
            }
        }
        .padding(.vertical, rowVerticalPadding)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in
            if !focused, entry.isBlank { onClose() }
        }
    }

    private func submit() {
        guard let saved = entry.submit() else { return onClose() }
        onAdd(saved.title, saved.dueAt)
        entry.reset()
        isFocused = true
    }
}

/// What a `SignalRow` can be asked to do. One vocabulary standing in for
/// what used to be nine separate optional closures — `perform` is the
/// row's only way of talking back to its caller, and which cases it will
/// ever actually send is decided entirely by `SignalAffordances`
/// (DailyOSCore), not by which of these happen to be wired.
enum SignalRowAction {
    case checkOff
    case dismiss
    /// Tomorrow or Next Week, from the swipe tray or the menu (ADR 0045).
    case snooze(SnoozeChoice)
    /// A Snoozed row back to Focus or Later now.
    case unsnooze
    /// A click on a row with something in its drawer (`RowDrawer`).
    case toggleDrawer
    /// A swipe action is about to act on the row, so its drawer closes.
    case closeDrawer
    /// A link or "Open in Messages" in the drawer.
    case open(URL)
    case rename
    case delete
    case promote
    case demote
    /// Another row, dragged by its handle, dropped on this one. What that
    /// means is `AppModel.drop(_:onto:)`'s call.
    case drop(draggedId: String)
}

struct SignalRow: View {
    /// Subtask grouping (ticket 04): where this row falls within a shared
    /// visual container, or `nil` for an ungrouped row (the common case,
    /// unchanged from before grouping existed).
    enum GroupPosition {
        case top, middle, bottom
    }

    let signal: Signal
    /// Which of `SignalRowAction`'s cases this row currently offers —
    /// `ListPresentation.affordances(for:)` decided this once, upstream, from the
    /// Signal and its Tier alone. Check off and snoozing aren't in
    /// here: every row offers both unconditionally, so there's nothing to
    /// decide about them.
    let affordances: SignalAffordances
    /// Whether its due date draws as overdue, decided by `AppModel` against
    /// the moment the list was ranked.
    let isOverdue: Bool
    /// What the row shows and what its drawer holds, decided by
    /// `rowDrawer(for:)` (DailyOSCore).
    let drawer: RowDrawer
    let isExpanded: Bool
    let perform: (SignalRowAction) -> Void
    var groupPosition: GroupPosition?

    /// Drives the fade for the Inferred chip/source icon/dismiss cluster
    /// below: visible on hover, otherwise out of the way. `.opacity`, not
    /// a conditional `if`, so the row's width never shifts when the
    /// cluster appears — the same reason `DueDateText` reserves its column
    /// whether or not a date exists.
    @State private var isHovered = false

    /// Row-collapse-on-action: set right before a `.swipeActions` button
    /// (Tomorrow/Next Week/Delete/Dismiss) triggers its underlying removal, so
    /// `.transition(.collapse)` below only governs a removal caused by one
    /// of those — check-off and the existing hover Dismiss chip keep
    /// whatever default behavior they already had. SwiftUI reads a view's
    /// `.transition` from its last render before removal, so setting this
    /// synchronously in the same action that triggers the underlying
    /// removal is enough; there's no need to reset it afterward; a fresh
    /// row for a different (or later re-added) Signal starts at `false`.
    /// swipe-actions-migration ticket 02: kept rather than removed —
    /// whether `ContentView`'s own `.animation(listAnimation, value:)`
    /// already reads as a collapse on its own is unconfirmed, and this is
    /// cheap insurance either way.
    @State private var isCollapsingOnAction = false

    var body: some View {
        rowContent
            .listRowSeparator(.hidden)
            .listRowInsets(rowHorizontalInset)
            .transition(isCollapsingOnAction ? .collapse : .identity)
            // swipe-actions-migration ticket 01: native `.swipeActions`
            // replaces the custom `.swipeToReveal`/`SwipeRevealState`
            // mechanism (ADR 0015 — confirmed by hand to track a real
            // trackpad swipe 1-to-1 on a plain `List`, same as the old
            // mechanism). Order matches today's visual arrangement —
            // `secondarySwipeAction` closest to the content, then Tomorrow,
            // then Next Week furthest (ADR 0045). `allowsFullSwipe: false` is a deliberate final
            // choice, not a placeholder — reveal-then-tap confirmed working
            // by hand for Delete and the snooze buttons, and there's no need for a
            // full swipe to auto-trigger anything on top of that.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                secondarySwipeAction
                if isSnoozedRow {
                    unsnoozeSwipeAction
                }
                ForEach(SnoozeChoice.allCases, id: \.self) { snoozeSwipeAction($0) }
            }
    }

    /// swipe-actions-migration ticket 01: native `.swipeActions` button
    /// content, replacing the old custom circular-pill tray. Declared
    /// first in `.swipeActions`'s builder so it renders closest to the
    /// row's own content, matching the old tray's visual order — the
    /// snooze buttons declared after it, further out. Button chrome is now system-styled
    /// (full-height, tinted), not the old clipped pill; there's no way to
    /// reproduce that shape inside a native swipe action.
    ///
    /// Color: Visual Language (CONTEXT.md) still reserves color for
    /// exactly one meaning (an overdue date). Delete keeps its one
    /// narrowly-scoped exception via `role: .destructive` (system red).
    /// The snooze buttons and Dismiss get an explicit `.tint(.gray)` rather than no
    /// tint at all — the untinted default swipe-action color on macOS is
    /// blue (confirmed against the `.swipeActions` viability spike's own
    /// screenshot), which would itself be the unjustified second color
    /// Visual Language forbids. Gray is the neutral choice, not blue.
    /// A row in the Snoozed Section (ADR 0045): it alone offers Unsnooze,
    /// shows when it returns, and is never dragged or dropped on.
    private var isSnoozedRow: Bool { affordances.contains(.unsnooze) }

    private var unsnoozeSwipeAction: some View {
        Button {
            perform(.closeDrawer)
            perform(.unsnooze)
            isCollapsingOnAction = true
        } label: {
            Label("Unsnooze", systemImage: "arrow.uturn.backward")
        }
        .tint(.gray)
    }

    private func snoozeSwipeAction(_ choice: SnoozeChoice) -> some View {
        Button {
            perform(.closeDrawer)
            perform(.snooze(choice))
            isCollapsingOnAction = true
        } label: {
            snoozeLabel(choice)
        }
        .tint(.gray)
    }

    /// Delete for a Reminders Signal (the same `deletingSignal` confirm-
    /// then-delete flow the context menu already triggers — no bypass),
    /// Dismiss for a Messages Signal (the exact same `.dismiss` action the
    /// existing hover chip already sends). Every Signal has a source, so
    /// this is never absent — the tray always shows exactly two actions.
    @ViewBuilder
    private var secondarySwipeAction: some View {
        switch signal.source {
        case .reminders:
            Button(role: .destructive) {
                perform(.closeDrawer)
                perform(.delete)
                isCollapsingOnAction = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .messages:
            Button {
                perform(.closeDrawer)
                perform(.dismiss)
                isCollapsingOnAction = true
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(.gray)
        }
    }

    /// The foreground layer: everything a row has always rendered,
    /// unchanged — `.swipeActions` (above) reveals the actions declared in
    /// `snoozeSwipeAction`/`secondarySwipeAction` when this is swiped.
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainLine
            if isExpanded {
                NotesDrawer(drawer: drawer, perform: perform)
                    .padding(.leading, leadingIconColumnWidth + 8)
                    .padding(.bottom, rowVerticalPadding + 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Subtask grouping (ticket 04): a light shared container across a
        // batch's rows, built from per-row corner rounding rather than one
        // combined List cell, so every row keeps its own independent
        // check-off/dismiss/approve and hover state (ADR 0010) — grouping
        // only changes how adjacent rows are drawn, never how they behave.
        .background {
            if let groupPosition {
                groupBackground(for: groupPosition).fill(Color.secondary.opacity(0.08))
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contextMenu {
            if isSnoozedRow {
                Button("Unsnooze") { perform(.unsnooze) }
            }
            Button("Snooze until Tomorrow") { perform(.snooze(.tomorrow)) }
            Button("Snooze until Next Week") { perform(.snooze(.nextWeek)) }
            Divider()
            if affordances.contains(.promote) {
                Button("Move to Focus") { perform(.promote) }
            }
            if affordances.contains(.demote) {
                Button("Move to Later") { perform(.demote) }
            }
            if affordances.contains(.rename) {
                Button("Rename…") { perform(.rename) }
            }
            if affordances.contains(.delete) {
                Button("Delete", role: .destructive) { perform(.delete) }
            }
        }
        // After `.contentShape`, so pressing anywhere in the row's full
        // height, gutter included, picks it up. A press and hold starts a
        // drag; only a click reaches `mainLine`'s tap gesture.
        .draggableRow(!isSnoozedRow, id: signal.id) { perform(.drop(draggedId: $0)) }
    }

    /// The row's one line: check off, Label, and the trailing columns.
    private var mainLine: some View {
        HStack(spacing: 8) {
            // Flush with the section header's leading edge, as in Things
            // and Reminders. No drag handle: the whole row drags (below).
            Button { perform(.checkOff) } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(PressableIconButtonStyle())
            .foregroundStyle(.secondary)
            .frame(width: leadingIconColumnWidth, alignment: .leading)

            // URLs are left out of the Label here and listed in the
            // drawer instead. The original wording moved into the drawer
            // too, so the row stays one short line.
            Text(drawer.displayLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // Things 3's note glyph: this row opens when clicked. Rows with
            // nothing to show get none, and ignore the click.
            if drawer.hasContent {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has notes")
            }
            Spacer()
            if signal.provenance == .inferred {
                // Hover-only: a text chip on every inferred row read as
                // clutter at rest. `SourceIcon` right after it stays
                // always visible — one subtle glyph carries the same
                // provenance at a fraction of the visual weight.
                Chip(text: "Inferred")
                    .opacity(isHovered ? 1 : 0)
                // Shown only here, not on every Reminders row — nearly
                // every row is Reminders-sourced, so a source icon on all
                // of them was pure repetition; it only earns its place
                // distinguishing the rare inferred one.
                SourceIcon(source: signal.source, sender: signal.sender)
            }
            // One-click promotion (ticket 05): hover-revealed, matching
            // dismiss's own progressive-disclosure treatment. Only ever
            // present on a Later row — `affordances` never carries
            // `.promote` for Focus.
            // Reserved unconditionally (the `DueDateText`-style empty-case
            // trick) so every row carries the same fixed-width slots before
            // the date/sender column — placed BEFORE that column, not
            // after: confirmed by direct pixel measurement that reserving
            // this slot *after* the date pushed the date/sender content
            // left of the true margin on any row that had one, since
            // nothing was left to its right to anchor against. Ordered
            // this way, the date/sender column is unconditionally the
            // last element in the row, so nothing can ever sit to its
            // right — its trailing edge IS the row's trailing edge, on
            // every row, regardless of which buttons are reserved.
            // One slot, not two: `.promote` (Later only) and `.demote`
            // (Focus only, priority-driven rows only — see
            // `ListPresentation.affordances(for:)`'s own doc comment) are mutually
            // exclusive, so sharing a slot keeps every row's total reserved
            // trailing width identical whether it shows an up arrow, a
            // down arrow, or nothing.
            // Messages only: dismissal means "Extraction false positive,"
            // which has no meaning for a Reminders Signal. Same
            // before-the-date-column placement as the promote slot above,
            // for the same reason.
            Group {
                if affordances.contains(.dismiss) {
                    Button { perform(.dismiss) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PressableIconButtonStyle())
                    .help("Dismiss — this was never real work")
                    .opacity(isHovered ? 1 : 0)
                }
            }
            .frame(width: leadingIconColumnWidth, alignment: .center)
            // Due date and sender stack in one trailing-aligned column,
            // date on top, rather than sitting side by side — the due date
            // is the row's primary temporal cue (DailyOS ranks by urgency),
            // so it earns a fixed position every row agrees on. Deliberately
            // the LAST element in this HStack (see the promote/dismiss
            // slots above) so nothing ever sits to its right — its trailing
            // edge is always the row's own trailing edge. `spacing: 2`
            // keeps the pair tight enough that a row with a sender is never
            // taller than one without — the label column, not this stack,
            // is what actually governs row height in the common case.
            VStack(alignment: .trailing, spacing: 2) {
                // The empty date placeholder only holds the column's width.
                // Next to a sender pill it would add a blank line and make
                // the row taller than its neighbors.
                if isSnoozedRow, let until = signal.snoozedUntil {
                    // A Snoozed row's return time sits in the date column,
                    // the same pill as an overdue date but gray, beside the
                    // due date when there is one (ADR 0045).
                    HStack(spacing: 4) {
                        Chip(text: snoozeReturnText(until), color: .secondary)
                            .fixedSize()
                        if signal.dueAt != nil {
                            DueDateText(dueAt: signal.dueAt, isOverdue: isOverdue)
                        }
                    }
                    .frame(minWidth: dueDateColumnWidth, alignment: .trailing)
                } else if signal.dueAt != nil || signal.sender == nil {
                    DueDateText(dueAt: signal.dueAt, isOverdue: isOverdue)
                }
                // Sender-on-approval: `signal.sender` is non-nil here only
                // for a reminder approved from a Messages Signal with a
                // resolved name (`AppModel.applyApprovedSenders`) — an
                // inferred row never reaches `SignalRow` at all
                // (`isSuggestion` keeps it in the Suggested Tasks Inbox
                // instead), so this never overlaps with the block above.
                // Always visible, unlike the hover-only Inferred chip — the
                // whole point is that this context would otherwise be lost
                // the moment the row leaves Suggested.
                if let sender = signal.sender {
                    Chip(text: sender, color: senderPillColor)
                }
            }
        }
        // Without an explicit full-width frame, this HStack sizes to its
        // own content in Zen Focus Mode's `ScrollView`/`VStack` context
        // (unlike a real `List`, which stretches every row automatically)
        // — the trailing `Spacer()` above had no slack to expand into, so
        // the date/sender column landed wherever the row's natural width
        // happened to end, not the true trailing margin, and the label
        // wrapped as if it had less room than it actually did. Forcing the
        // full available width here fixes both at once, in both List and
        // Zen contexts alike.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, rowVerticalPadding)
        .contentShape(Rectangle())
        // The row itself is the click target for its Notes drawer, as in
        // Things 3. Lands on the row's `contentShape` above; a tap that
        // lands on one of the row's own buttons is captured by that button
        // first, never reaching here. Messages opens from the drawer's
        // button, not from this click.
        .onTapGesture {
            if drawer.hasContent {
                perform(.toggleDrawer)
            }
        }
    }

    /// Rounded only on the edge(s) that face outward from the group, so a
    /// multi-row batch reads as one continuous surface rather than a stack
    /// of separately-rounded pills.
    private func groupBackground(for position: GroupPosition) -> AnyShape {
        let radius: CGFloat = 8
        switch position {
        case .top:
            return AnyShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius))
        case .middle:
            return AnyShape(Rectangle())
        case .bottom:
            return AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0))
        }
    }
}

/// Row-collapse-on-action: a row's removal reads as its own height
/// shrinking to nothing (clipped, faded) rather than a plain cross-fade or
/// an un-animated cut. `.frame(maxHeight:)` rather than `.scaleEffect`,
/// since scale would also squeeze the row's width, not just its height.
private struct CollapseModifier: ViewModifier {
    let isCollapsing: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: isCollapsing ? 0 : nil)
            .opacity(isCollapsing ? 0 : 1)
            .clipped()
    }
}

private extension AnyTransition {
    static var collapse: AnyTransition {
        .modifier(
            active: CollapseModifier(isCollapsing: true),
            identity: CollapseModifier(isCollapsing: false)
        )
    }
}


/// A row in the Suggested Tasks Inbox (Focus Mode v2). Approve, not check
/// off: an unconfirmed guess isn't real work yet (CONTEXT.md: Check off),
/// so there's no circle button here, only the (+) that turns it into a
/// real reminder and the (x) that records it as a false positive.
///
/// Every Signal here is Messages-sourced and inferred by construction (see
/// `AppModel.inboxSignals`) — unlike `SignalRow`, there's no Reminders case
/// to guard against, so `SourceIcon`/deep linking apply unconditionally
/// rather than behind an `if signal.provenance == .inferred` check.
struct SuggestedSignalRow: View {
    let signal: Signal
    /// Keyboard triage (batched-extraction ticket 08): the row Return and
    /// Delete act on. Shown the way hover is, plus a faint fill, so the
    /// focused row is findable without the pointer over it.
    var isKeyboardFocused = false
    /// The context popover (batched-extraction ticket 09): opened by Space
    /// on the focused row, or by resting the pointer on the row for half a
    /// second.
    @Binding var isPreviewShown: Bool
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// Only a popover the pointer opened closes when the pointer leaves;
    /// one opened with Space stays until Space or Escape.
    @State private var previewOpenedByHover = false
    let onApprove: () -> Void
    /// Tomorrow or Next Week from the swipe tray: Approve, then Snooze the
    /// new reminder (ADR 0045).
    let onApproveAndSnooze: (SnoozeChoice) -> Void
    let onDismiss: () -> Void
    /// History's "Not for me" on the Suggestion's Batch (inbox-not-for-me):
    /// records a false positive and dismisses the row. `nil` on a row that
    /// doesn't offer it, which keeps the button's space so × never moves.
    var onNotForMe: (() -> Void)?
    /// Deep Linking (ticket 03): reopens this Signal's originating Chat in
    /// Messages — the same behavior `SignalRow` gives every Messages row,
    /// extended here so a pending suggestion can be checked against its
    /// source conversation before you decide to approve or dismiss it.
    let onDeepLink: () -> Void

    /// Progressive disclosure for Approve/Dismiss (window-chrome-and-inbox-
    /// legibility ticket 04): the same `isHovered`/`.opacity` treatment
    /// `SignalRow` already gives its own dismiss button and Provenance chip
    /// (CONTEXT.md: Visual Language), applied here instead of a second,
    /// independently-invented reveal mechanism. Both buttons stay in the
    /// layout at all times — only their opacity changes — so hovering never
    /// shifts the row's text or its neighbors.
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onApprove) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(PressableIconButtonStyle())
            .foregroundStyle(.secondary)
            .frame(width: leadingIconColumnWidth, alignment: .leading)
            .help("Approve — create a real reminder (Return)")
            .opacity(isHovered || isKeyboardFocused ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(signal.label)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isWorthShowingOriginal(label: signal.label, originalText: signal.originalText) {
                    Text(shorteningURLs(in: signal.originalText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            // No "Inferred" chip here — every row in this inbox is
            // inferred by construction (see the type's own doc comment),
            // so the label would repeat what the section itself already
            // says. Shows the sender's first name instead, when there is
            // one — `nil` for a self-thread Signal, which has no second
            // party to name.
            if let sender = signal.sender {
                Chip(text: firstName(from: sender))
            }
            SourceIcon(source: signal.source, sender: signal.sender)

            Group {
                if let onNotForMe {
                    Button(action: onNotForMe) {
                        Image(systemName: "hand.thumbsdown")
                    }
                    .buttonStyle(PressableIconButtonStyle())
                    .foregroundStyle(.secondary)
                    .help("Not for me — the model shouldn't have found a task here")
                    .opacity(isHovered || isKeyboardFocused ? 1 : 0)
                } else {
                    // Holds the button's size without drawing it.
                    Image(systemName: "hand.thumbsdown").hidden()
                }
            }
            .frame(width: leadingIconColumnWidth, alignment: .center)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PressableIconButtonStyle())
            .frame(width: leadingIconColumnWidth, alignment: .center)
            .help("Dismiss — this was never real work (Delete)")
            .opacity(isHovered || isKeyboardFocused ? 1 : 0)
        }
        .padding(.vertical, rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(isKeyboardFocused ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        // Deep Linking (ticket 03): the row itself is the click target,
        // matching `SignalRow`'s own tap-to-open behavior. A tap landing on
        // Approve or Dismiss is captured by that button first, never
        // reaching here — same guarantee `SignalRow`'s own doc comment
        // relies on.
        .onTapGesture {
            onDeepLink()
        }
        .onHover { hovering in
            isHovered = hovering
            hoverPreviewTask?.cancel()
            if hovering {
                hoverPreviewTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, !isPreviewShown else { return }
                    previewOpenedByHover = true
                    isPreviewShown = true
                }
            } else if previewOpenedByHover {
                previewOpenedByHover = false
                isPreviewShown = false
            }
        }
        .popover(isPresented: $isPreviewShown, arrowEdge: .trailing) {
            SuggestionPreviewView(preview: suggestionPreview(for: signal))
        }
        // However it closed, the next one is opened fresh: one reopened with
        // Space must not close just because the pointer later leaves.
        .onChange(of: isPreviewShown) { _, isShown in
            if !isShown { previewOpenedByHover = false }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .listRowSeparator(.hidden)
        .listRowInsets(rowHorizontalInset)
        // The same tray order as `SignalRow`'s: Dismiss closest to the
        // content, then the snooze buttons (ADR 0045). Gray, per Visual
        // Language.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(.gray)
            ForEach(SnoozeChoice.allCases, id: \.self) { choice in
                Button { onApproveAndSnooze(choice) } label: { snoozeLabel(choice) }
                    .tint(.gray)
            }
        }
    }
}

/// The conversation behind a Suggestion: what the model saw before the
/// Batch, muted, then the Batch itself.
private struct SuggestionPreviewView: View {
    let preview: SuggestionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(preview.contextLines.enumerated()), id: \.offset) { _, line in
                Text(line).foregroundStyle(.secondary)
            }
            if !preview.contextLines.isEmpty {
                Divider().padding(.vertical, 2)
            }
            ForEach(Array(preview.batchLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

/// A Signal's originating Source, shown as a single subtle icon rather
/// than a text badge — the full name is still there on hover via `.help`,
/// which is enough for the rare case anyone needs to check it.
private struct SourceIcon: View {
    let source: Source
    /// Sender attribution (tickets 02/03): the resolved Contacts name or
    /// raw address for a Messages Signal, or `nil` for a self-thread
    /// Signal (no second party) or a Reminders Signal (no Sender concept
    /// at all — `sourceHelpText` never reads this for that case).
    var sender: String? = nil

    var body: some View {
        Image(systemName: sourceIconSymbolName(for: source))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(sourceHelpText(for: source, sender: sender))
    }
}

/// A trailing column for a Signal's due date, reserved at at least this
/// width whether or not `dueAt` is set — the common case (undated, or a
/// short badge) keeps a strict right-edge grid, the date sitting at the
/// same x-position on every row, rather than reflowing to fill the gap an
/// absent date would otherwise leave. A minimum, not a fixed width: a
/// longer overdue phrase ("3 weeks ago") needs to widen the column
/// leftward rather than wrap or clip, since `DueDateText` is always the
/// HStack's last element (its trailing edge is the row's own trailing
/// edge either way).
private let dueDateColumnWidth: CGFloat = 64

private struct DueDateText: View {
    let dueAt: Date?
    let isOverdue: Bool

    var body: some View {
        Group {
            if let dueAt {
                Text(relativeDueDateText(dueAt))
                    // Single line, sized to its own text: without this, a
                    // longer relative-date phrase ("3 weeks ago") wrapped
                    // inside the fixed-width column below, turning the
                    // overdue pill into a bulky two-line square and
                    // pushing the whole row taller than its neighbors.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // `Color.red` is a fixed RGBA constant — it doesn't
                    // pick up the vibrancy blending `.primary`/`.secondary`
                    // get for free over this window's `.ultraThinMaterial`
                    // background. `NSColor.systemRed` is the semantic
                    // accessor that does: same "this is overdue" meaning,
                    // but the actual pixel value adapts to whatever's
                    // behind the window instead of staying one fixed red
                    // regardless of wallpaper or light/dark mode.
                    .foregroundStyle(isOverdue ? Color(nsColor: .systemRed) : .secondary)
                    .padding(.horizontal, isOverdue ? 6 : 0)
                    .padding(.vertical, isOverdue ? 2 : 0)
                    // A pill only for the overdue case: still the same one
                    // red meaning this app reserves color for, just given
                    // a boundary instead of floating loose in the row —
                    // the on-time case stays plain text like everything
                    // else in the row.
                    .background {
                        if isOverdue {
                            Capsule().fill(Color(nsColor: .systemRed).opacity(0.15))
                        }
                    }
            } else {
                Text("")
            }
        }
        .font(.caption)
        .frame(minWidth: dueDateColumnWidth, alignment: .trailing)
    }
}

/// Feedback on press, not just on release: a `.plain`-styled icon button
/// gives zero visual response on its own, so this fills that gap with an
/// instant, interruptible scale — the same shape as a native control's
/// press state, just implemented by hand since `.plain` suppresses it.
private struct PressableIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Plain caption text, not a pill — matches `DueDateText`'s own styling so
/// every piece of trailing-edge metadata (tags, dates alike) reads as the
/// same kind of thing rather than a mix of badges and bare text competing
/// in the same space.
struct Chip: View {
    let text: String
    /// `nil` (default) renders plain text, matching every existing use
    /// (the hover-only "Inferred" chip, the Suggested Inbox's sender
    /// chip). Set for the sender-on-approval pill in `SignalRow` — the
    /// same capsule treatment `DueDateText` already uses for overdue, a
    /// second deliberate exception to semantic monochromatism (CONTEXT.md:
    /// Visual Language) rather than a new default — and, in gray, for a
    /// Snoozed row's return time, which adds no color at all.
    var color: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color ?? .secondary)
            .padding(.horizontal, color != nil ? 6 : 0)
            .padding(.vertical, color != nil ? 2 : 0)
            .background {
                if let color {
                    Capsule().fill(color.opacity(0.15))
                }
            }
    }
}

/// Shown in place of the ranked list during the first-run backfill (ticket
/// 08). No cancel control: a cancelled first run would leave a ranked list
/// that claims to show everything open while missing most of it.
struct BackfillProgressView: View {
    let completed: Int
    let total: Int

    var body: some View {
        Text("Reading your self-thread… \(completed.formatted()) of \(total.formatted())")
            .foregroundStyle(.secondary)
    }
}

/// A persistent, non-dismissible row for a Source whose Gate is missing
/// (ticket 10) — the only signal that something needs attention; there's
/// no separate banner. Deep links into the relevant System Settings pane,
/// plus a manual retry for the race where a re-check beats the OS updating
/// its own permission cache.
struct UnavailableSourceRow: View {
    let instructions: String
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Text(instructions)
                .foregroundStyle(.secondary)
            Spacer()
            // `.plain` + `.primary`, not the default accent-tinted bordered
            // style: this window's own content stays monochrome (Visual
            // Language, CONTEXT.md) — these still read as interactive
            // against the `.secondary` instructions beside them, on
            // contrast alone, the same way the rest of the app tells
            // primary from secondary content apart without color.
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, rowVerticalPadding)
    }
}

/// A persistent, non-dismissible row for the local extraction model failing
/// to load (ticket 05) — no "Open System Settings" action, since this isn't
/// a Gate: it's a missing model file or a load failure, and the fix lives
/// outside any settings pane this app can deep-link into.
struct ExtractionUnavailableRow: View {
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Text("The local extraction model failed to load. New messages won't be turned into Signals until this is fixed.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, rowVerticalPadding)
    }
}

/// A row's Notes drawer (CONTEXT.md: Notes; ADR 0041): the Notes or
/// original wording, every link, and "Open in Messages" for a one-to-one
/// Chat. Read-only. Monochrome like the rest of the row: links are
/// underlined secondary text, not accent-colored.
private struct NotesDrawer: View {
    let drawer: RowDrawer
    let perform: (SignalRowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let body = drawer.body {
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(drawer.links, id: \.self) { url in
                Button { perform(.open(url)) } label: {
                    Label(shorteningURLs(in: url.absoluteString), systemImage: "link")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
            }
            if let messagesURL = drawer.messagesURL {
                // `.plain` and `.primary`, like `UnavailableSourceRow`'s
                // buttons: the default bordered style is accent-tinted.
                Button { perform(.open(messagesURL)) } label: {
                    Label("Open in Messages", systemImage: "message")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Floats over the bottom of the window via the body's outer `ZStack`,
/// which overlays rather than reflows — this bar's own appearance and
/// disappearance never resizes the window or shifts anything else in
/// `mainContent`. `.frame(height:)` keeps its own size fixed regardless of
/// label length (already `.lineLimit(1)`-capped) rather than letting it
/// grow.
///
/// One bar for every action (inbox-undo): check off, the Inbox's Approve,
/// Dismiss and "Not for me", and a reminder from `+` that landed in Later,
/// which may be collapsed. That last one only reports where it went, so
/// `onUndo` is `nil` and no button shows.
struct UndoBar: View {
    let text: String
    let onUndo: (() -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1)
            Spacer()
            if let onUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

/// A snooze choice's button label, in the swipe tray (ADR 0045).
@ViewBuilder
func snoozeLabel(_ choice: SnoozeChoice) -> some View {
    switch choice {
    case .tomorrow: Label("Tomorrow", systemImage: "sunrise")
    case .nextWeek: Label("Next Week", systemImage: "calendar")
    }
}

/// "Mon 8 AM": when a Snoozed row comes back, shown on the row.
private func snoozeReturnText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE h a"
    return formatter.string(from: date)
}

private extension View {
    /// The whole row drags, and takes another row dropped on it. Off for
    /// a Snoozed row, which is never dragged or dropped on (ADR 0045).
    /// `.onDrag`, not `.draggable`: inside a macOS `List`, `.draggable`
    /// never starts a drag on a row that also has a tap gesture, so
    /// dragging worked only in Zen's `ScrollView`. `.onDrag` works in
    /// both, and `.dropDestination(for: String.self)` reads it the same.
    @ViewBuilder
    func draggableRow(_ enabled: Bool, id: String, onDrop: @escaping (String) -> Void) -> some View {
        if enabled {
            onDrag { NSItemProvider(object: id as NSString) }
                .dropDestination(for: String.self) { draggedIds, _ in
                    guard let draggedId = draggedIds.first, draggedId != id else { return false }
                    onDrop(draggedId)
                    return true
                }
        } else {
            self
        }
    }
}
