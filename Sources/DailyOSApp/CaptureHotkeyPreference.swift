import Carbon.HIToolbox
import Foundation

/// Global Hotkey Input (ticket 01): the fixed set of shortcut choices
/// offered in the "More" menu, rather than a full free-form key recorder —
/// the same one-click-from-a-short-list pattern snoozing uses for
/// Tomorrow and Next Week, applied here to keep this ticket from also having
/// to build and validate an arbitrary key-capture control. All three use
/// Space, which nothing else on this system already claims system-wide.
public enum CaptureHotkeyPreset: Int, CaseIterable {
    case optionSpace
    case controlOptionSpace
    case shiftCommandSpace

    public var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .shiftCommandSpace: return "⇧⌘ Space"
        }
    }

    public var keyCode: UInt32 { UInt32(kVK_Space) }

    public var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .shiftCommandSpace: return UInt32(shiftKey | cmdKey)
        }
    }
}

/// UserDefaults-backed, same thin-wrapper shape `ZenFocusModePreference`
/// already uses for a single persisted setting.
public struct CaptureHotkeyPreference {
    private let defaults: UserDefaults
    private static let key = "captureHotkeyPreset"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selected: CaptureHotkeyPreset {
        get {
            guard let raw = defaults.object(forKey: Self.key) as? Int, let preset = CaptureHotkeyPreset(rawValue: raw) else {
                return .optionSpace
            }
            return preset
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
