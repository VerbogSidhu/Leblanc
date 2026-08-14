import AppKit
import Carbon.HIToolbox

/// Global hotkey registration via the Carbon Event Manager.
/// Unlike CGEventTap, RegisterEventHotKey needs no Accessibility permission,
/// so Cmd+Shift+Home reliably returns to GameDock while Steam/Discord has focus.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onActivate: (() -> Void)?

    private let hotKeySignature: OSType = 0x47444F43 // "GDOC"
    private let hotKeyID: UInt32 = 1

    /// Registers Cmd+Shift+Home.
    func start(onActivate: @escaping () -> Void) {
        guard eventHandlerRef == nil else { return }
        self.onActivate = onActivate

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKey = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKey
                )
                if hotKey.signature == manager.hotKeySignature, hotKey.id == manager.hotKeyID {
                    manager.onActivate?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyIDStruct = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_Home),
            UInt32(cmdKey | shiftKey),
            hotKeyIDStruct,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            Log.warn("GlobalHotkeyManager: RegisterEventHotKey failed (\(status))")
        }
    }
}
