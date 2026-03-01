import Carbon
import Foundation

@MainActor
final class GlobalHotkeyService {
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?

    func startListening(
        shortcut: HotkeyShortcut,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        stopListening()

        self.onPress = onPress
        self.onRelease = onRelease

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(eventRef)
                let serviceRef = userData
                DispatchQueue.main.async {
                    let service = Unmanaged<GlobalHotkeyService>.fromOpaque(serviceRef).takeUnretainedValue()
                    service.handleHotkeyEventKind(kind)
                }
                return noErr
            },
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode(from: "TLVH"), id: 1)
        RegisterEventHotKey(
            shortcut.key.carbonKeyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    func stopListening() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotkeyRef = nil
        eventHandlerRef = nil
        onPress = nil
        onRelease = nil
    }

    private func handleHotkeyEventKind(_ kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) {
            onPress?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            onRelease?()
        }
    }

    private func fourCharCode(from string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
