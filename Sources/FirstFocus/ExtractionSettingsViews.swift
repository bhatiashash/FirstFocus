import AppKit
import FirstFocusApp
import FirstFocusCore
import Charts
import SwiftUI

/// Re-extraction's lookback reads in hours below a day, days at or above
/// one: a whole multiple of 24 always reads as days (so the default 1 hour
/// and a dialed-up 72 hours both read naturally), anything else reads in
/// hours even past 24 (30 hours stays "30 hours" rather than rounding to
/// "1 day"), since this is a Stepper a user is actively turning, not a
/// duration picker that owes them a rounded-off summary.
private func reExtractionLookbackLabel(hours: Double) -> String {
    let wholeHours = Int(hours)
    if wholeHours >= 24, wholeHours % 24 == 0 {
        let days = wholeHours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }
    return "\(wholeHours) hour\(wholeHours == 1 ? "" : "s")"
}

private func minimumIntervalLabel(hours: Double) -> String {
    let wholeHours = Int(hours)
    return wholeHours == 0 ? "None" : "\(wholeHours) hour\(wholeHours == 1 ? "" : "s")"
}

/// Advanced (advanced-settings-redesign): a grouped form, one card per
/// section, ordered by how often each is touched. Rules first, since they
/// are the everyday way to steer extraction; the raw prompt last, behind a
/// sheet, since it is edited rarely and is too long to sit on the tab.
struct AdvancedTabView: View {
    @ObservedObject var morningBriefViewModel: MorningBriefViewModel
    @ObservedObject var openAtLoginViewModel: OpenAtLoginViewModel
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var screeningViewModel: ScreeningSettingsViewModel
    @ObservedObject var rulesViewModel: RulesViewModel
    @ObservedObject var mutedChatsViewModel: MutedChatsViewModel
    let activeModelName: String?
    @Binding var captureHotkeyPreset: CaptureHotkeyPreset
    @Binding var isFocusListEnabled: Bool
    let focusListTicks: [FocusListTick]
    let setFocusListTick: (Bool, String) -> Void
    let refreshFocusListTicks: () async -> Void

    var body: some View {
        Form {
            MorningBriefSection(viewModel: morningBriefViewModel)
            FocusListSection(isEnabled: $isFocusListEnabled, ticks: focusListTicks, setTick: setFocusListTick)
            OpenAtLoginSection(viewModel: openAtLoginViewModel)
            RulesSection(viewModel: rulesViewModel)
            ReExtractionSection(viewModel: viewModel)
            ScreeningSection(viewModel: screeningViewModel)
            MutedChatsSection(viewModel: mutedChatsViewModel)
            FilteredSMSSection()
            ExtractionPromptSection(viewModel: viewModel, activeModelName: activeModelName)
            QuickCaptureSection(preset: $captureHotkeyPreset)
        }
        .formStyle(.grouped)
        // On the Form, not on a section: a grouped Form is lazy, so a
        // section scrolled out of view would fire its own onDisappear.
        .onAppear {
            morningBriefViewModel.refresh()
            openAtLoginViewModel.refresh()
            rulesViewModel.refreshProposalStatus()
            screeningViewModel.refreshStatistics()
            mutedChatsViewModel.refresh()
        }
        .task { await refreshFocusListTicks() }
        // Pending proposals are never stored (ADR 0038): leaving Advanced
        // discards whatever wasn't approved. A sheet over this tab doesn't
        // count as leaving it.
        .onDisappear { rulesViewModel.discardPending() }
    }
}

/// The Morning Brief (ADR 0046): where it goes, a test send, and how the
/// last send went. First in Advanced: it is used every day, unlike the
/// extraction tuning below it.
private struct MorningBriefSection: View {
    @ObservedObject var viewModel: MorningBriefViewModel
    @State private var isEditingFormat = false

    var body: some View {
        Section {
            Toggle("Send every day", isOn: Binding(
                get: { viewModel.isEnabled },
                set: { enabled in Task { await viewModel.setEnabled(enabled) } }
            ))
            .disabled(!viewModel.canEnable)
            DatePicker("Time", selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: viewModel.sendTime.hour, minute: viewModel.sendTime.minute, second: 0, of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    Task { await viewModel.setSendTime(MorningBriefTime(hour: parts.hour ?? 8, minute: parts.minute ?? 0)) }
                }
            ), displayedComponents: .hourAndMinute)
            LabeledContent("Sends to your Self-thread") {
                Text(viewModel.myNumber ?? "No number found")
                    .foregroundStyle(viewModel.myNumber == nil ? .secondary : .primary)
            }
            if viewModel.myNumber == nil {
                Text("The Brief only goes to you, in the conversation you have with yourself in Messages. Text yourself once from this Mac or your iPhone, and make sure FirstFocus has Full Disk Access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Focus Signals to list", selection: $viewModel.format.limit) {
                ForEach(MorningBriefViewModel.limitChoices, id: \.self) { limit in
                    Text(limit.map { "Top \($0)" } ?? "All").tag(limit)
                }
            }
            HStack {
                Button("Edit Format…") { isEditingFormat = true }
                Spacer()
                Button("Send Test") { Task { await viewModel.sendTest() } }
                    .disabled(!viewModel.canSend)
                if viewModel.isSending { ProgressView().controlSize(.small) }
            }
            if let status = viewModel.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Morning Brief")
        } footer: {
            Text("Texts your Focus list to you through Messages on this Mac. If the Mac is asleep or FirstFocus isn't running at that time, it goes out when you next wake or open it within four hours. A test send uses the list as it is now and doesn't count as the day's.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isEditingFormat) {
            MorningBriefFormatSheet(viewModel: viewModel)
        }
    }
}

/// The Focus list (ADR 0048): a list in Reminders that holds what is in
/// Focus. Beside the Morning Brief, the other way to see Focus away from
/// the window. Under the toggle, a tick for each list it draws from.
private struct FocusListSection: View {
    @Binding var isEnabled: Bool
    let ticks: [FocusListTick]
    let setTick: (Bool, String) -> Void

    var body: some View {
        Section {
            Toggle("Keep a Focus list in Reminders", isOn: $isEnabled)
            ForEach(ticks) { tick in
                Toggle(tick.list.title, isOn: Binding(get: { tick.isTicked }, set: { setTick($0, tick.id) }))
                    .toggleStyle(.checkbox)
            }
            .disabled(!isEnabled)
        } header: {
            Text("Focus List")
        } footer: {
            Text("Moves every reminder in Focus from a ticked list into a Reminders list called Focus, and back to its own list when it leaves Focus or is snoozed. Putting a reminder in that list yourself, on your phone or in Reminders, moves it to Focus here. Taking one out moves it to Later, unless its due date keeps it in Focus. Lists made later start unticked, and the Focus list leaves them alone; moving a reminder into an unticked list takes it out for good. Turning this off moves everything back and leaves the list empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Morning Brief's layout below its fixed header, with the message as
/// it would go out right now. Edits are saved as you type.
private struct MorningBriefFormatSheet: View {
    @ObservedObject var viewModel: MorningBriefViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Morning Brief Format").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Message").font(.subheadline)
                    TextEditor(text: $viewModel.format.body)
                        .font(.body.monospaced())
                        .frame(height: 110)
                        .border(Color.secondary.opacity(0.3))
                    Text("{top} the first Signal · {rest} the others, its whole line repeated for each · {more} \u{201C}+2 more in Focus\u{201D} when cut · {later} the Later count")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Each item").font(.subheadline)
                    TextField("Each item", text: $viewModel.format.itemLine)
                        .labelsHidden()
                        .font(.body.monospaced())
                    Text("{n} the position · {label} the Signal · {overdue} \u{201C} (overdue)\u{201D} when it is")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 320)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview").font(.subheadline)
                    ScrollView {
                        Text(viewModel.preview)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 260, height: 250)
                    Text("The first line is always \u{201C}\(morningBriefHeader)\u{201D}, so FirstFocus never reads its own Brief as new work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Reset to Default") { viewModel.resetFormat() }
                    .disabled(viewModel.format == .standard)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

/// Open at Login: its own section, since it is useful without the Morning
/// Brief, though the Brief needs the app running to send.
private struct OpenAtLoginSection: View {
    @ObservedObject var viewModel: OpenAtLoginViewModel

    var body: some View {
        Section {
            Toggle("Open FirstFocus at login", isOn: Binding(
                get: { viewModel.isEnabled },
                set: { viewModel.setEnabled($0) }
            ))
            if let error = viewModel.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Startup")
        }
    }
}

/// Every Muted Chat (muted-chats-list), named the way History names it.
/// Chats are muted only from History (ADR 0032); this is a way back.
/// Filtered SMS: texts Messages' SMS filter sorted as Transactions or
/// Promotions, skipped by Extraction while this is on (the default).
private struct FilteredSMSSection: View {
    @AppStorage(FilteredSMSSettings.key) private var ignoresFilteredSMS = true

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Ignore filtered SMS", isOn: $ignoresFilteredSMS)
                Text(
                    ignoresFilteredSMS
                        ? "Texts Messages files under Transactions or Promotions (SMSFT, SMSFP) are left out of extraction."
                        : "Texts Messages files under Transactions or Promotions (SMSFT, SMSFP) are extracted like any other."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Filtered SMS")
        } footer: {
            Text("Affects new messages only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MutedChatsSection: View {
    @ObservedObject var viewModel: MutedChatsViewModel

    var body: some View {
        Section {
            if viewModel.chats.isEmpty {
                Text("No muted chats.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.chats) { chat in
                HStack {
                    Text(chat.name)
                        .help(chat.lastMessage)
                    Spacer()
                    Button("Unmute") { viewModel.unmute(chatId: chat.chatId) }
                }
            }
        } header: {
            Text("Muted Chats")
        } footer: {
            Text("Chats are muted from History. Unmuting affects new messages only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The system-wide shortcut that opens Quick Capture. A choice of presets,
/// since ⌥Space collides with launchers such as Alfred and Raycast.
private struct QuickCaptureSection: View {
    @Binding var preset: CaptureHotkeyPreset

    var body: some View {
        Section {
            Picker("Shortcut", selection: $preset) {
                ForEach(CaptureHotkeyPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
        } header: {
            Text("Quick Capture")
        } footer: {
            Text("Opens the capture panel from any app. Pick another if this one is taken by a launcher such as Alfred or Raycast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Advanced's Rules section (ADR 0038): a field to add one by hand, then
/// the approved Rules as a list, each editable and deletable in place,
/// then model proposals awaiting review.
private struct RulesSection: View {
    @ObservedObject var viewModel: RulesViewModel

    private var draftIsEmpty: Bool {
        viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            HStack {
                TextField("Add a Rule", text: $viewModel.draft, prompt: Text("Add a Rule"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.addDraft() }
                Button("Add") { viewModel.addDraft() }
                    .disabled(draftIsEmpty || viewModel.isAtCap)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.rules.isEmpty {
                Text("No Rules yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.rules) { rule in
                RuleRow(rule: rule, viewModel: viewModel)
            }
            ForEach(viewModel.pending) { proposal in
                PendingRuleRow(proposal: proposal, viewModel: viewModel)
            }
            HStack {
                Button(viewModel.isProposing ? "Proposing…" : "Propose Rules") {
                    Task { await viewModel.propose() }
                }
                .disabled(!viewModel.canPropose)
                if let reason = viewModel.proposeReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text(
                "Instructions the model follows in every Chat, from the next message on. "
                    + "\(viewModel.rules.count) of \(maxRules) used"
                    + (viewModel.isAtCap ? "; delete one to add or approve another." : ".")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// A proposed Rule awaiting review: edit the text, then approve or reject.
private struct PendingRuleRow: View {
    let proposal: PendingRule
    @ObservedObject var viewModel: RulesViewModel
    @State private var text: String

    init(proposal: PendingRule, viewModel: RulesViewModel) {
        self.proposal = proposal
        self.viewModel = viewModel
        _text = State(initialValue: proposal.text)
    }

    var body: some View {
        HStack {
            Text("Proposed")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Proposed Rule", text: $text, prompt: Text("Proposed Rule"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Button("Approve") { viewModel.approve(proposal.id, text: text) }
                .disabled(viewModel.isAtCap)
            Button("Reject") { viewModel.reject(proposal.id) }
        }
    }
}

/// One approved Rule, read as plain text. The pencil turns the row into a
/// field (Return or Save keeps the change, Esc or Cancel drops it); the
/// trash deletes it. Both icons appear on hover, their space reserved so
/// nothing shifts (CONTEXT.md, Progressive disclosure).
private struct RuleRow: View {
    let rule: Rule
    @ObservedObject var viewModel: RulesViewModel
    @State private var text: String
    @State private var isEditing = false
    @State private var isHovered = false
    @FocusState private var isFieldFocused: Bool

    init(rule: Rule, viewModel: RulesViewModel) {
        self.rule = rule
        self.viewModel = viewModel
        _text = State(initialValue: rule.text)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                TextField("Rule", text: $text, prompt: Text("Rule"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                Button("Cancel", action: cancel)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(rule.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    text = rule.text
                    isEditing = true
                    isFieldFocused = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit this Rule")
                .accessibilityLabel("Edit this Rule")
                .opacity(isHovered ? 1 : 0)
                Button {
                    viewModel.delete(id: rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this Rule")
                .accessibilityLabel("Delete this Rule")
                .opacity(isHovered ? 1 : 0)
            }
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func save() {
        viewModel.update(id: rule.id, text: text)
        isEditing = false
    }

    private func cancel() {
        text = rule.text
        isEditing = false
    }
}

/// Re-extraction stays a manual command (the toolbar's "Re-run
/// Extraction"); these two only decide what it covers and how soon it can
/// run again. Steppers rather than a fixed dropdown (ADR 0024, kept by ADR
/// 0027). The lookback range tops out at 720 hours, the same 30 days the
/// old whole-days Stepper reached.
private struct ReExtractionSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            LabeledContent("Look back") {
                HStack {
                    Text(reExtractionLookbackLabel(hours: viewModel.reExtractionLookbackHours))
                        .monospacedDigit()
                    Stepper("Look back", value: $viewModel.reExtractionLookbackHours, in: 1...720, step: 1)
                        .labelsHidden()
                }
            }
            LabeledContent("Minimum time between runs") {
                HStack {
                    Text(minimumIntervalLabel(hours: viewModel.reExtractionMinimumIntervalHours))
                        .monospacedDigit()
                    Stepper(
                        "Minimum time between runs", value: $viewModel.reExtractionMinimumIntervalHours, in: 0...48, step: 1
                    )
                    .labelsHidden()
                }
            }
        } header: {
            Text("Re-extraction")
        } footer: {
            Text("These shape re-extraction, which runs only when started from the toolbar. Nothing runs on a schedule.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Advanced's Screening section (ADR 0036). Off until the user turns it on
/// and stores a key. A one-line disclosure stays on screen whatever the
/// state, so it's always clear that message text leaves the Mac while it's
/// on; the full wording sits behind its Help button. Everything else shows
/// only while the toggle is on, and the cutoff histogram lives in the Tune
/// Cutoff sheet.
private struct ScreeningSection: View {
    @ObservedObject var viewModel: ScreeningSettingsViewModel
    @State private var isEditingKey = false
    @State private var isTuning = false

    private static let disclosure =
        "While on, each batch that passes the local checks is sent as written, with recent context, to TypeSafe AI's Jev. "
        + "Senders appear only as Participant A, B and so on, never by name or number, "
        + "and your notes to yourself are never sent."

    private var modeSummary: String {
        if viewModel.isLive { return "Drops batches that score below the cutoff." }
        return viewModel.canGoLive ? "Records Jev's scores. Drops nothing." : "Records Jev's scores. Set a cutoff to go live."
    }

    private static let modeHelp =
        "Shadow: every batch still reaches the local model, and Jev's answers are only recorded in History.\n\n"
        + "Live: batches scoring below the cutoff are Screened and never reach the local model. "
        + "Recover one from History with \u{201C}This was work\u{201D}.\n\n"
        + "Live needs a cutoff, set from Tune Cutoff."

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Screen with Jev", isOn: $viewModel.isEnabled)
                HStack(spacing: 4) {
                    Text("Sends message text to TypeSafe AI, with senders anonymized.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HelpButton(text: Self.disclosure)
                }
            }

            if viewModel.isEnabled {
                LabeledContent("API key") {
                    HStack {
                        Label(viewModel.hasAPIKey ? "Saved in Keychain" : "No key", systemImage: "key")
                            .foregroundStyle(.secondary)
                        Button(viewModel.hasAPIKey ? "Change Key…" : "Add Key…") { isEditingKey = true }
                    }
                }
                // On the row, not the Section: in a Form a Section's modifiers
                // can be applied to each of its rows.
                .sheet(isPresented: $isEditingKey) {
                    APIKeySheet(viewModel: viewModel, isPresented: $isEditingKey)
                }
                if !viewModel.hasAPIKey {
                    Text("Screening stays off until a key is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // The whole picker, not just the Live segment: macOS doesn't
                    // pass a per-item `.disabled` through to a segmented control.
                    Picker("Mode", selection: $viewModel.isLive) {
                        Text("Shadow").tag(false)
                        Text("Live").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!viewModel.canGoLive)
                    HStack(spacing: 4) {
                        Text(modeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HelpButton(text: Self.modeHelp)
                    }
                }

                LabeledContent("Cutoff") {
                    HStack {
                        Text(viewModel.canGoLive ? String(format: "%.2f", viewModel.cutoff) : "Not set")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Tune Cutoff…") { isTuning = true }
                            .disabled(!viewModel.canTuneCutoff)
                    }
                }
                .sheet(isPresented: $isTuning) {
                    TuneCutoffSheet(viewModel: viewModel, isPresented: $isTuning)
                }
                if let hint = viewModel.tuneCutoffHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Screening")
        }
    }
}

/// The standard round Help button, showing `text` in a popover.
private struct HelpButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        HelpLink { isShown.toggle() }
            .controlSize(.mini)
            .popover(isPresented: $isShown, arrowEdge: .trailing) {
                Text(text)
                    .font(.callout)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
    }
}

/// Choosing the cutoff from data: the score histogram with its draggable
/// line, the readout, and Set Cutoff. Dragging only moves the candidate;
/// the stored cutoff changes only through Set Cutoff.
private struct TuneCutoffSheet: View {
    @ObservedObject var viewModel: ScreeningSettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tune Cutoff").font(.headline)
            CutoffHistogram(viewModel: viewModel)
            HStack {
                Text(viewModel.canGoLive ? "Cutoff: \(String(format: "%.2f", viewModel.cutoff))" : "Cutoff: not set")
                Spacer()
                if !viewModel.points.isEmpty, !viewModel.canGoLive || viewModel.candidateCutoff != viewModel.cutoff {
                    Button("Set Cutoff to \(String(format: "%.2f", viewModel.candidateCutoff))") {
                        viewModel.setCutoff(viewModel.candidateCutoff)
                    }
                }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { viewModel.refreshStatistics() }
    }
}

/// Entering, replacing or removing the TypeSafe key. The key is never
/// shown back, only whether one is stored.
private struct APIKeySheet: View {
    @ObservedObject var viewModel: ScreeningSettingsViewModel
    @Binding var isPresented: Bool

    private var draftIsEmpty: Bool {
        viewModel.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.hasAPIKey ? "Change TypeSafe API Key" : "Add TypeSafe API Key")
                .font(.headline)
            SecureField("API key", text: $viewModel.apiKeyDraft, prompt: Text("TypeSafe API key"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Stored in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if viewModel.hasAPIKey {
                    Button("Remove Key", role: .destructive) {
                        viewModel.removeAPIKey()
                        if viewModel.errorMessage == nil { isPresented = false }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.cancelKeyEntry()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftIsEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard !draftIsEmpty else { return }
        viewModel.saveAPIKey()
        if viewModel.errorMessage == nil { isPresented = false }
    }
}

/// The Extraction Prompt, summarised to one row. The editor lives in a
/// sheet: it's a long text edited rarely, and on the tab it pushed every
/// other setting out of view.
private struct ExtractionPromptSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let activeModelName: String?
    @State private var isEditing = false
    @State private var isConfirmingReset = false

    private var statusText: String {
        switch viewModel.promptStatus {
        case .builtIn, .setAside: "Default"
        case .custom: "Custom"
        }
    }

    var body: some View {
        Section {
            LabeledContent("Prompt", value: statusText)
            if viewModel.promptStatus == .setAside {
                Text("Your saved prompt was written for the old input format, so extraction is using the default. Open Edit Prompt to copy from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Model", value: activeModelName ?? "No model loaded")
            HStack {
                if viewModel.isReloading && !isEditing {
                    ProgressView().controlSize(.small)
                    Text("Reloading extraction…").foregroundStyle(.secondary)
                } else if let statusMessage = viewModel.statusMessage, !isEditing {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to Default") { isConfirmingReset = true }
                    .disabled(viewModel.promptStatus != .custom || viewModel.isReloading)
                Button("Edit Prompt…") {
                    viewModel.beginEditing()
                    isEditing = true
                }
                .disabled(viewModel.isReloading)
            }
            // On the row, not the Section, for the same reason as the key sheet.
            .confirmationDialog("Reset the Extraction Prompt to the default?", isPresented: $isConfirmingReset) {
            Button("Reset to Default", role: .destructive) {
                Task { await viewModel.resetToDefault() }
            }
        } message: {
            Text("Your custom prompt will be deleted and extraction will reload.")
        }
            .sheet(isPresented: $isEditing) {
                PromptEditorSheet(viewModel: viewModel, isPresented: $isEditing)
            }
        } header: {
            Text("Extraction Prompt")
        }
    }
}

private struct PromptEditorSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extraction Prompt")
                .font(.headline)
            TextEditor(text: $viewModel.prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if let setAside = viewModel.setAsidePrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your saved prompt is not in use")
                        .font(.subheadline.weight(.semibold))
                    Text("It was written for the old input format, before messages were judged in batches. Copy anything you still want into the editor, adapt it to the new format, and save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(setAside)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Button("Copy into Editor") { viewModel.prompt = setAside }
                }
            }

            HStack {
                if viewModel.isReloading {
                    ProgressView().controlSize(.small)
                    Text("Reloading extraction…").foregroundStyle(.secondary)
                } else if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.cancelEditing()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isReloading)
                // Command-Return rather than the default action: a plain
                // Return key equivalent fires before the editor sees the
                // key, so a newline would save instead.
                Button("Save & Reload") {
                    Task {
                        if await viewModel.saveAndReload() { isPresented = false }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save & Reload (⌘Return)")
                .disabled(viewModel.isReloading)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Screening scores for every Batch whose outcome is known, one bar per
/// 0.05, split into what turned out to be work and what didn't (batched-
/// extraction ticket 12). Dragging the line moves a candidate cutoff and
/// updates the readout; nothing is stored until "Set cutoff". Monochrome
/// on purpose: color in this app means an overdue date and nothing else
/// (CONTEXT.md: Visual Language), so the two outcomes are two inks with a
/// legend, never two hues.
private struct CutoffHistogram: View {
    @ObservedObject var viewModel: ScreeningSettingsViewModel

    private static let work = "Model found work"
    private static let nothing = "Nothing to do"

    var body: some View {
        let bins = screeningHistogram(viewModel.points)
        let readout = viewModel.readout
        VStack(alignment: .leading, spacing: 6) {
            Text("Screening results: \(viewModel.points.count) batch\(viewModel.points.count == 1 ? "" : "es") with a known outcome")
                .font(.subheadline)
            if viewModel.points.isEmpty {
                Text("The chart appears once Screening has judged some batches and their outcome is known.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(bins, id: \.lower) { bin in
                        ForEach([(Self.work, bin.work), (Self.nothing, bin.nothing)], id: \.0) { outcome, count in
                            if count > 0 {
                                BarMark(
                                    xStart: .value("Score", bin.lower + 0.002),
                                    xEnd: .value("Score", bin.lower + histogramBinWidth - 0.002),
                                    y: .value("Batches", count)
                                )
                                .foregroundStyle(by: .value("Outcome", outcome))
                                .cornerRadius(2)
                                .accessibilityLabel("\(outcome), scores \(String(format: "%.2f", bin.lower)) to \(String(format: "%.2f", bin.lower + histogramBinWidth))")
                                .accessibilityValue("\(count)")
                            }
                        }
                    }
                    RuleMark(x: .value("Cutoff", viewModel.candidateCutoff))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, alignment: .center) {
                            Text(String(format: "%.2f", viewModel.candidateCutoff))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                .chartForegroundStyleScale([Self.work: Color.primary, Self.nothing: Color.secondary.opacity(0.4)])
                .chartXScale(domain: 0...1)
                .chartXAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { drag in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let x = drag.location.x - geometry[plotFrame].origin.x
                                    guard let score: Double = proxy.value(atX: x) else { return }
                                    viewModel.candidateCutoff = clampedCutoff(score)
                                }
                            )
                    }
                }
                .frame(height: 160)
                .accessibilityLabel("Screening score histogram")

                Text(
                    "At \(String(format: "%.2f", viewModel.candidateCutoff)), live mode would Screen "
                        + "\(readout.wouldScreen) of \(viewModel.points.count) batches "
                        + "(\(Int((Double(readout.wouldScreen) / Double(viewModel.points.count) * 100).rounded()))%). "
                        + "\(readout.hadWork) of those \(readout.hadWork == 1 ? "was" : "were") work. Drag the line to try another cutoff."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Read-only reference (the Advanced tab holds everything that changes
/// behavior): version, shortcuts, where data lives, and credits.
struct AboutTabView: View {
    /// Shown in the Quick Capture row, so About matches whatever Advanced
    /// has selected.
    let captureHotkeyPreset: CaptureHotkeyPreset

    private let acknowledgments: [(name: String, license: String)] = [
        ("llama.cpp", "MIT License"),
        ("llama.swift by Mattt", "MIT License"),
        ("Qwen3-4B-Instruct-2507", "Apache License 2.0"),
        ("Qwen2.5-3B-Instruct", "Qwen Research License"),
        ("Llama 3.2 3B Instruct", "Llama 3.2 Community License"),
    ]

    private var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.shashbhatia.FirstFocus" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("FirstFocus \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · built on llama.cpp and Qwen3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                shortcuts
                sideBySide(storage, credits, spacing: 28)
            }
            .padding(20)
        }
    }

    /// Left and right when the window is wide enough, stacked when it isn't,
    /// so About needs little or no scrolling at the default window size.
    private func sideBySide(_ left: some View, _ right: some View, spacing: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                left.frame(maxWidth: .infinity, alignment: .top)
                right.frame(maxWidth: .infinity, alignment: .top)
            }
            VStack(alignment: .leading, spacing: spacing) {
                left
                right
            }
        }
    }

    private var shortcuts: some View {
        let groups = ShortcutCatalog.groups(quickCapture: captureHotkeyPreset)
        let split = columnSplit(groups)
        return VStack(spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            sideBySide(shortcutGrid(groups[..<split]), shortcutGrid(groups[split...]), spacing: 24)
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the right column starts: the split that leaves the two columns
    /// closest in height, counting each group's heading as a row. A group
    /// never splits across columns.
    private func columnSplit(_ groups: [ShortcutGroup]) -> Int {
        let rows = groups.map { $0.entries.count + 1 }
        let total = rows.reduce(0, +)
        return (1..<max(groups.count, 2)).min { a, b in
            abs(2 * rows[..<a].reduce(0, +) - total) < abs(2 * rows[..<b].reduce(0, +) - total)
        } ?? groups.count
    }

    private func shortcutGrid(_ groups: ArraySlice<ShortcutGroup>) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(groups, id: \.title) { group in
                GridRow {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .gridCellColumns(2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                }
                ForEach(group.entries, id: \.action) { shortcut in
                    GridRow {
                        Text(shortcut.action)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        HStack(spacing: 4) {
                            ForEach(shortcut.keys, id: \.self) { Keycap(label: $0) }
                        }
                        .gridColumnAlignment(.leading)
                    }
                }
            }
        }
    }

    /// Everything FirstFocus keeps lives in one SQLite file beside the models
    /// folder. The app writes no log files of its own.
    private var storage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage")
                .font(.headline)
            AboutPathRow(
                title: "Database", url: URL(fileURLWithPath: SQLiteSignalStore.defaultPath(bundleIdentifier: bundleIdentifier))
            )
            AboutPathRow(
                title: "Models", url: LlamaCppIntentExtractor.modelsDirectoryURL(bundleIdentifier: bundleIdentifier)
            )
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acknowledgments")
                .font(.headline)
            ForEach(acknowledgments, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.license).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

/// A read-only path with a button that shows it in Finder.
private struct AboutPathRow: View {
    let title: String
    let url: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 70, alignment: .leading)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// One key drawn like a physical keycap: gray, never colored (CONTEXT.md,
/// Semantic monochromatism).
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 22)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}
