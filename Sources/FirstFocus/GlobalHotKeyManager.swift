import Carbon.HIToolbox
import FirstFocusApp
import Foundation

/// Global Hotkey Input (ticket 01): registers one system-wide keyboard
/// shortcut via Carbon's `RegisterEventHotKey`, not
/// `NSEvent.addGlobalMonitorForEvents`, which needs Accessibility/Input
/// Monitoring authorization to see key events at all.
/// `RegisterEventHotKey` needs no such grant — this feature reuses the
/// Reminders Gate the app already has and introduces no new one.
@MainActor
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x64_4f_53_31 // 'dOS1'
    private let hotKeyID = EventHotKeyID(signature: GlobalHotKeyManager.signature, id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onTrigger?()
                return noErr
            },
            1, &eventType, selfPointer, &eventHandlerRef
        )
    }

    /// Replaces whatever shortcut was previously registered (a no-op the
    /// first time) with `preset`'s, so switching presets in the menu never
    /// leaves two active at once.
    func register(_ preset: CaptureHotkeyPreset, onTrigger: @escaping () -> Void) {
        unregister()
        self.onTrigger = onTrigger
        RegisterEventHotKey(preset.keyCode, preset.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    // No `deinit` to balance `InstallEventHandler`/`RegisterEventHotKey`:
    // this instance is created once in `main.swift` and held for the
    // process's whole life, the same posture `captureHotkeyController` and
    // `zenWindowSizer` already take there.
}
