import DailyOSApp
import SwiftUI

/// The date a typed phrase will set, shown beside the field before ⏎.
/// Monochrome: color stays reserved for an overdue date.
struct TypedDueDateBadge: View {
    let badge: TypedTitleEntry.Badge
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(badge.text)
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Keep the words as text")
            .accessibilityLabel("Remove due date")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .fixedSize()
    }
}

/// A reminder title's text field and its badge, for `+`, Rename and Quick
/// Capture, which each style the field their own way in `field`.
///
/// The field edits its own copy of the text, handed to the entry on every
/// change. When the entry keeps its old text instead (⌫ over the badge),
/// the copy is set back: a real change the field redraws from. A binding
/// whose setter just ignores the edit would leave the field showing the
/// deleted character.
struct TypedTitleField<Field: View>: View {
    @Binding var entry: TypedTitleEntry
    let field: (Binding<String>) -> Field
    @State private var typed: String

    init(entry: Binding<TypedTitleEntry>, @ViewBuilder field: @escaping (Binding<String>) -> Field) {
        _entry = entry
        self.field = field
        _typed = State(initialValue: entry.wrappedValue.text)
    }

    var body: some View {
        field($typed)
            .onChange(of: typed) { _, newText in
                entry.edit(to: newText)
                if entry.text != newText { typed = entry.text }
            }
            .onChange(of: entry.text) { _, text in
                if typed != text { typed = text }
            }
        if let badge = entry.badge {
            TypedDueDateBadge(badge: badge) { entry.cancelBadge() }
        }
    }
}
