import AppKit
import DailyOSApp
import DailyOSCore
import SwiftUI

/// History (dashboard spec): a list of Batches on the left, the selected
/// Batch in a detail pane on the right. Export and the unfiltered log live
/// in the window's More menu (`AppShellView`).
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    /// Hidden until asked for, and remembered across launches.
    @AppStorage("historyInspectorShown") private var isInspectorShown = false

    var body: some View {
        // The Batch list sits in an HStack, not an `HSplitView`. An
        // `HSplitView` is an AppKit split view, and a pane at the window's
        // leading edge counts the floating sidebar's 208pt safe-area inset
        // into its minimum width. `NavigationSplitView` adds the sidebar
        // again, so History needed 1318pt and overflowed the window. The
        // detail pane and Inspector sit clear of the sidebar, so they keep
        // a draggable split.
        HStack(spacing: 0) {
            HistoryListView(viewModel: viewModel)
                .frame(minWidth: 250)
            Divider()
            HSplitView {
                Group {
                    if let batch = viewModel.selectedBatch {
                        HistoryDetailView(batch: batch, viewModel: viewModel)
                    } else {
                        ContentUnavailableView(viewModel.segment.emptyMessage, systemImage: "clock.arrow.circlepath")
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                // A pane of the split rather than `.inspector`, which grows
                // this hosted window to fit the column. Here the detail
                // pane gives up the width instead.
                if isInspectorShown {
                    Group {
                        if let batch = viewModel.selectedBatch {
                            HistoryInspectorView(inspection: viewModel.inspection(for: batch))
                        } else {
                            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
                        }
                    }
                    .frame(minWidth: 250, maxHeight: .infinity)
                }
            }
            // Without these the split stays at its minimum and the Batch
            // list takes every point the window grows by.
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $viewModel.segment) {
                    ForEach(viewModel.segments) { segment in
                        Text(segmentLabel(segment)).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(viewModel.showsScreening ? "Borderline: Screening scored within \(borderlineBandWidth.formatted()) of the cutoff" : "")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isInspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(isInspectorShown ? "Hide how this Batch was judged" : "Show how this Batch was judged")
            }
        }
        // Re-read on every visit, so the list follows a cutoff changed in
        // Advanced and whatever intake recorded since History was last shown.
        .onAppear { viewModel.refresh() }
    }

    private func segmentLabel(_ segment: HistorySegment) -> String {
        guard segment == .borderline, viewModel.borderlineCountThisWeek > 0 else { return segment.title }
        return "\(segment.title) (\(viewModel.borderlineCountThisWeek))"
    }
}

private struct HistoryListView: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HistoryWeekHeader(counts: viewModel.weekCounts)
            Divider()
            list
        }
    }

    private var list: some View {
        List(selection: $viewModel.selectedBatchId) {
            ForEach(viewModel.sections) { section in
                Section(section.title) {
                    ForEach(section.batches) { batch in
                        HistoryRowView(batch: batch, badges: viewModel.badges(for: batch))
                            .tag(batch.id)
                            .contextMenu { HistoryActionsMenu(batch: batch, viewModel: viewModel) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The week at a glance, pinned above the list.
private struct HistoryWeekHeader: View {
    let counts: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Past 7 days").font(.headline)
            Text(counts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct HistoryRowView: View {
    let batch: HistoryBatch
    let badges: [HistoryBadge]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(batch.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(batch.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(badges, id: \.text) { badge in
                    HistoryBadgeView(badge: badge)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A status pill: symbol and words in `.secondary`, never colour alone
/// (CONTEXT.md: Semantic monochromatism).
private struct HistoryBadgeView: View {
    let badge: HistoryBadge

    var body: some View {
        Label(badge.text, systemImage: badge.symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

private struct HistoryDetailView: View {
    let batch: HistoryBatch
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(batch.timestamp.formatted(date: .complete, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let transcript = batch.transcript {
                    HistoryTranscriptView(lines: transcript)
                } else {
                    Text(batch.sourceText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                HistoryResultView(batch: batch, summary: viewModel.resultSummary(for: batch))

                // What an UPDATE or CANCEL took out of Suggestions.
                let superseded = viewModel.supersededLines(for: batch)
                if !superseded.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(superseded, id: \.self) { line in
                            Text(line)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                HistoryDetailActions(batch: batch, viewModel: viewModel)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A Batch as a conversation: my messages on the trailing side, everyone
/// else's on the leading side under their name. The earlier messages the
/// model saw as context come first, dimmed. Bubbles use system
/// materials only, so no colour carries meaning.
private struct HistoryTranscriptView: View {
    let lines: [HistoryTranscriptLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if !line.isContext, index > 0, lines[index - 1].isContext {
                    Text("Judged from here")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                let showsSpeaker = !line.isFromMe && (index == 0 || lines[index - 1].speaker != line.speaker)
                VStack(alignment: line.isFromMe ? .trailing : .leading, spacing: 2) {
                    if showsSpeaker {
                        Text(line.speaker)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(line.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            line.isFromMe ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                }
                .frame(maxWidth: .infinity, alignment: line.isFromMe ? .trailing : .leading)
                .padding(line.isFromMe ? .leading : .trailing, 40)
                // Context the model saw, not the Batch it judged.
                .opacity(line.isContext ? 0.5 : 1)
            }
        }
    }
}

/// The task(s) a Batch produced in large type, or one plain sentence when
/// it produced none.
private struct HistoryResultView: View {
    let batch: HistoryBatch
    let summary: String

    var body: some View {
        switch batch.result {
        case .tasks(let labels):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                }
            }
        default:
            Text(summary)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

/// The review actions, as labelled buttons, with the less common ones in a
/// More menu. Each shows only where the Batch offers it; one the app can't
/// take right now shows disabled, with the reason as its help text.
private struct HistoryDetailActions: View {
    let batch: HistoryBatch
    @ObservedObject var viewModel: HistoryViewModel
    @State private var isAddingTask = false
    @State private var newTaskLabel = ""

    private var actions: HistoryBatchActions { viewModel.actions }
    private var offers: HistoryBatchOffers { viewModel.offers(for: batch) }

    var body: some View {
        HStack(spacing: 8) {
            if let state = offers[.addTask] {
                Button(state == .taken ? "Task Added" : "Add Task…") {
                    newTaskLabel = ""
                    isAddingTask = true
                }
                .historyActionState(state, help: "The model missed a task: name it, add it to Suggestions, and teach future extractions")
            }
            if let state = offers[.notForMe] {
                Button(state == .taken ? "Marked Not for me" : "Not for me") {
                    actions.notForMe(batch)
                }
                .historyActionState(state, help: "Dismiss this task and teach future extractions in this chat")
                if state == .taken {
                    Button("Undo") { actions.undoNotForMe(batch) }
                        .help("Delete this Correction and put the task back in Suggestions")
                }
            }
            if let state = offers[.restore] {
                Button(state == .taken ? "Restored" : "Restore") {
                    actions.restore(batch)
                }
                .historyActionState(state, help: "Put back in Suggestions what this Batch replaced or withdrew")
            }
            if let state = offers[.thisWasWork] {
                Button("This was work") {
                    Task { await actions.thisWasWork(batch) }
                }
                .historyActionState(state, help: "Send this Batch to the local model now")
            }
            if let state = offers[.tryAgain] {
                Button("Try Again") {
                    Task { await actions.tryAgain(batch) }
                }
                .historyActionState(state, help: "Send this Batch to the local model once more")
            }
            if offers[.mute] != nil {
                Button(offers.isMuted ? "Unmute Thread" : "Mute Thread") {
                    actions.toggleMute(batch)
                }
            }
            Menu("More") {
                HistoryActionsMenu(batch: batch, viewModel: viewModel, includesPrimary: false)
            }
            .fixedSize()
        }
        .alert("Add Task", isPresented: $isAddingTask) {
            TextField("Task", text: $newTaskLabel)
            Button("Add") { actions.addTask(newTaskLabel, to: batch) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The task goes to Suggestions, and future extractions learn from it.")
        }
    }
}

private extension View {
    /// Enabled, disabled as done, or disabled with the reason as help text.
    func historyActionState(_ state: HistoryActionState, help: String) -> some View {
        let reason: String? = if case .unavailable(let reason) = state { reason } else { nil }
        return disabled(state != .enabled).help(reason ?? help)
    }
}

/// Every action on a Batch, for a list row's context menu. The detail
/// pane's More menu reuses it without the actions it already shows as
/// buttons. A menu item can't carry help text, so one the app can't take
/// right now names the reason in its title.
private struct HistoryActionsMenu: View {
    let batch: HistoryBatch
    @ObservedObject var viewModel: HistoryViewModel
    var includesPrimary = true

    private var actions: HistoryBatchActions { viewModel.actions }
    private var offers: HistoryBatchOffers { viewModel.offers(for: batch) }

    var body: some View {
        if includesPrimary {
            switch offers[.notForMe] {
            case .enabled: Button("Not for me") { actions.notForMe(batch) }
            case .taken: Button("Undo Not for me") { actions.undoNotForMe(batch) }
            default: EmptyView()
            }
            if offers[.restore] == .enabled {
                Button("Restore") { actions.restore(batch) }
            }
            if let state = offers[.thisWasWork] {
                Button(menuTitle("This was work", state)) { Task { await actions.thisWasWork(batch) } }
                    .disabled(state != .enabled)
            }
            if let state = offers[.tryAgain] {
                Button(menuTitle("Try Again", state)) { Task { await actions.tryAgain(batch) } }
                    .disabled(state != .enabled)
            }
            if offers[.mute] != nil {
                Button(offers.isMuted ? "Unmute Thread" : "Mute Thread") { actions.toggleMute(batch) }
            }
            Divider()
        }
        if let state = offers[.rerun] {
            Button(menuTitle("Re-run Against Active Model", state)) { Task { await actions.rerun(batch) } }
                .disabled(state != .enabled)
        }
        Button(batch.isStarred ? "Unstar" : "Star") { viewModel.toggleStar(batch) }
        Button("Copy Raw Output") { copyToPasteboard(viewModel.rawOutputToCopy(for: batch)) }
        Divider()
        Button("Delete", role: .destructive) { viewModel.delete(batch) }
    }

    private func menuTitle(_ title: String, _ state: HistoryActionState) -> String {
        if case .unavailable(let reason) = state { "\(title) (\(reason))" } else { title }
    }
}

/// How a Batch was judged: Screening, the model's raw output, the prompt it
/// saw, Re-runs and the Audit Sample. Raw strings are shown exactly as
/// stored.
private struct HistoryInspectorView: View {
    let inspection: HistoryInspection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let screening = inspection.screening {
                    InspectorSection("Screening") {
                        InspectorField(screening.confidenceLabel, formatScore(screening.probability))
                        InspectorField("Cutoff", screening.cutoff.map(formatScore) ?? "None (shadow mode)")
                        InspectorField("Mode", modeText(screening.mode))
                        InspectorField("Decision", screening.wasScreened ? "Screened" : "Let through")
                        InspectorField("Service", screening.service)
                    }
                }
                if let failure = inspection.screeningFailure {
                    InspectorSection("Screening failed") {
                        InspectorField("Reason", failure.reason)
                        InspectorField("Service", failure.service)
                    }
                }
                if inspection.screeningUnavailable {
                    InspectorSection("Screening unavailable") {
                        Text("Jev kept failing or rejected the key, so this Batch went straight to the model.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let call = inspection.modelCall {
                    InspectorSection("Model output") {
                        InspectorField("Model", call.modelUsed)
                        RawBlock(text: call.rawOutput)
                    }
                }
                if let prompt = inspection.prompt {
                    InspectorSection("Prompt the model saw") {
                        RawBlock(text: prompt)
                    }
                }
                if !inspection.reruns.isEmpty {
                    InspectorSection("Re-runs") {
                        ForEach(inspection.reruns, id: \.id) { rerun in
                            InspectorField("Model", rerun.modelUsed)
                            RawBlock(text: rerun.rawOutput)
                        }
                    }
                }
                if let audit = inspection.audit {
                    InspectorSection("Audit Sample") {
                        InspectorField("Model", audit.modelUsed)
                        RawBlock(text: audit.rawOutput)
                    }
                }
                InspectorSection("Identifiers") {
                    InspectorField("Message id", inspection.messageId ?? "Not recorded")
                    InspectorField("Chat id", inspection.chatId.map(String.init) ?? "Not recorded")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func modeText(_ mode: HistoryInspection.ScreeningMode) -> String {
        switch mode {
        case .shadow: "Shadow (nothing dropped)"
        case .live: "Live"
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct InspectorField: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// A raw string in monospace with its own Copy button.
private struct RawBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy") { copyToPasteboard(text) }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
