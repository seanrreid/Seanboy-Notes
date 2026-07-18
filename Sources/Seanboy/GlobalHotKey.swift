import AppKit
import Carbon.HIToolbox

let kVK_N: UInt32 = UInt32(kVK_ANSI_N)

/// System-wide hotkey via Carbon's RegisterEventHotKey — no accessibility
/// permission required, still the sanctioned API for global hotkeys.
final class GlobalHotKey {
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    init?(keyCode: UInt32, modifiers: Modifiers, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerProcPtr = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.handler() }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetEventDispatcherTarget(), callback, 1,
                                  &eventType, selfPtr, &eventHandler) == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x544D_4243), id: 1)  // 'TMBC'
        guard RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID,
                                  GetEventDispatcherTarget(), 0, &hotKeyRef) == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
