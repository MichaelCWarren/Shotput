import Carbon.HIToolbox

/// Wraps one Carbon global hotkey registration. Carbon (not the newer
/// NSEvent global monitors) is what still lets a shortcut fire without
/// Accessibility permission and while another app is frontmost.
final class Hotkey {
    static let controlShiftS = (keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | shiftKey))

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let handler: @MainActor () -> Void

    var isRegistered: Bool { hotKeyRef != nil }

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let mainHandler = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().handler
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { mainHandler() }
                }
                return noErr
            },
            1, &eventType, selfPointer, &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            self.eventHandler = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// 'SHOT' as an OSType; RegisterEventHotKey requires an EventHotKeyID signature.
    private static let signature: OSType = 0x53484F54
}
