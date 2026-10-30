import FirstFocusCore

/// A Section that can be collapsed from its header.
public enum CollapsibleSection: Hashable, Sendable {
    case inbox
    case later
    case snoozed
}

/// Keyboard triage of the Suggested Tasks Inbox (batched-extraction tickets
/// 08 and 09), and which Sections are collapsed. Holds which Suggestion has
/// keyboard focus, which one's popover is open, and every rule for when
/// those change. The caller passes in the Inbox's ids and whether Zen Focus
/// Mode hides it, and carries out the Approve or Dismiss a key asks for.
public struct InboxTriage: Equatable, Sendable {
    /// A key the Inbox answers to: arrows move focus, Return Approves,
    /// Delete Dismisses.
    public enum Key: Sendable {
        case up, down, approve, dismiss
        /// Space: opens or closes the focused Suggestion's popover.
        /// `closePreview` is Escape.
        case togglePreview, closePreview
    }

    /// An Approve or Dismiss a key asked for, which the caller carries out
    /// and then hands back to `finish`.
    public struct Act: Equatable, Sendable {
        public let key: Key
        public let id: String
        fileprivate let next: String?
        fileprivate let wasPreviewing: Bool
    }

    /// The Suggestion keyboard triage acts on, or `nil` when nothing is
    /// focused. Cleared whenever that Suggestion leaves the Inbox by any
    /// route.
    public internal(set) var focusedId: String?
    /// The Suggestion whose context popover is open, or `nil`. Cleared,
    /// like focus, once it leaves the Inbox.
    public internal(set) var previewedId: String?
    /// Which Sections are collapsed (CONTEXT.md: Section). The Snoozed
    /// Section starts collapsed (ADR 0045); the Suggested Tasks Inbox and
    /// Later start expanded. Not saved between launches. Focus never
    /// collapses.
    public private(set) var collapsed: Set<CollapsibleSection> = [.snoozed]

    public init() {}

    public func isCollapsed(_ section: CollapsibleSection) -> Bool {
        collapsed.contains(section)
    }

    /// Whether the Inbox takes `key`, answered at once: `true` when it
    /// does, `false` to leave the key for anything else listening. Return,
    /// Delete and Space mean something only with a Suggestion focused,
    /// Escape only with a popover open, and nothing does while the Inbox is
    /// empty, collapsed or hidden by Zen Focus Mode.
    public func takes(_ key: Key, inboxIds ids: [String], isZen: Bool) -> Bool {
        guard !isZen, !isCollapsed(.inbox), !ids.isEmpty else { return false }
        switch key {
        case .approve, .dismiss, .togglePreview: return focusedId != nil
        case .closePreview: return previewedId != nil
        case .up, .down: return true
        }
    }

    /// Applies `key` to focus and the popover. For Approve and Dismiss it
    /// moves nothing yet and returns the `Act` the caller must carry out on
    /// the focused row; everything else is done here and returns `nil`.
    public mutating func handle(_ key: Key, inboxIds ids: [String], isZen: Bool) -> Act? {
        guard !isZen, !isCollapsed(.inbox) else { return nil }
        // Read before acting: dismissing the previewed row clears it.
        let wasPreviewing = previewedId != nil
        switch key {
        case .up:
            focusedId = inboxFocus(moving: .up, from: focusedId, in: ids)
        case .down:
            focusedId = inboxFocus(moving: .down, from: focusedId, in: ids)
        case .approve, .dismiss:
            guard let focused = focusedId, ids.contains(focused) else { return nil }
            return Act(
                key: key, id: focused, next: inboxFocus(afterActingOn: focused, in: ids), wasPreviewing: wasPreviewing
            )
        case .togglePreview:
            previewedId = previewedId == nil ? focusedId : nil
            return nil
        case .closePreview:
            previewedId = nil
            return nil
        }
        // An open popover follows focus, the way Quick Look follows the
        // selection in Finder.
        if wasPreviewing { previewedId = focusedId }
        return nil
    }

    /// Moves focus on to the neighbour of the row `act` acted on, so the
    /// next keystroke acts on the next row. `ids` are the Inbox's ids now,
    /// after the action.
    public mutating func finish(_ act: Act, inboxIds ids: [String]) {
        focusedId = act.next.flatMap { ids.contains($0) ? $0 : nil }
        if act.wasPreviewing { previewedId = focusedId }
    }

    /// Keyboard focus on `id`, if it's in the Inbox: after Undo brings a
    /// Suggestion back, the next key acts on it.
    public mutating func focus(_ id: String, inboxIds ids: [String]) {
        if ids.contains(id) { focusedId = id }
    }

    /// Hover: the view calls this once the pointer has rested on a
    /// Suggestion for half a second.
    public mutating func showPreview(of id: String, inboxIds ids: [String]) {
        guard ids.contains(id) else { return }
        previewedId = id
    }

    /// The pointer left `id`'s row; closes its popover if it's the open one.
    public mutating func hidePreview(of id: String) {
        if previewedId == id { previewedId = nil }
    }

    /// Drops focus and the popover from a Suggestion that left the Inbox.
    public mutating func drop(leftInbox: (String) -> Bool) {
        if let focusedId, leftInbox(focusedId) { self.focusedId = nil }
        if let previewedId, leftInbox(previewedId) { self.previewedId = nil }
    }

    /// A Section header's chevron. Collapsing the Inbox drops keyboard
    /// focus and any open preview, since its keys do nothing while it is
    /// collapsed: none of them may act on a row you can't see.
    public mutating func toggleCollapse(_ section: CollapsibleSection) {
        if collapsed.remove(section) == nil {
            collapsed.insert(section)
            if section == .inbox {
                focusedId = nil
                previewedId = nil
            }
        }
    }

    /// Opens `section`, so a row added to it shows where it went.
    public mutating func expand(_ section: CollapsibleSection) {
        collapsed.remove(section)
    }
}
