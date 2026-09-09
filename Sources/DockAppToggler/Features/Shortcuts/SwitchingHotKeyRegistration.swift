import AppKit
import Carbon

/// Owns the native macOS registrations for forward and reverse window switching.
@MainActor
final class SwitchingHotKeyRegistration {
    enum Event: Equatable {
        case pressed(reverse: Bool), released
    }

    struct RegistrationError: LocalizedError {
        let shortcut: String
        let status: OSStatus

        var errorDescription: String? {
            if status == eventHotKeyExistsErr {
                return "\(shortcut) ist bereits von einer anderen App belegt. Beende deren Shortcut oder wähle hier ein anderes Kürzel."
            }
            return "\(shortcut) konnte nicht bei macOS registriert werden (Fehler \(status)). Wähle ein anderes Kürzel oder starte die App erneut."
        }
    }

    static let signature: OSType = 0x446F636B // Dock
    private static var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private(set) var directions: [UInt32: Bool] = [:]
    private var onEvent: ((Event) -> Void)?

    func register(shortcut: KeyboardShortcut, onEvent: @escaping (Event) -> Void) throws {
        unregister()
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let registration = Unmanaged<SwitchingHotKeyRegistration>.fromOpaque(context).takeUnretainedValue()
                return registration.handle(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            unregister()
            throw RegistrationError(shortcut: shortcut.displayString, status: status)
        }

        for registration in shortcut.registrations {
            let id = Self.nextID
            Self.nextID += 1 // Never reuse IDs: late events must not trigger a new shortcut.
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode), registration.modifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
            )
            guard status == noErr, let hotKey else {
                unregister() // Roll back the forward shortcut if reverse registration failed.
                let label = registration.reverse ? "⇧" + shortcut.displayString : shortcut.displayString
                throw RegistrationError(shortcut: label, status: status)
            }
            hotKeys.append(hotKey)
            directions[id] = registration.reverse
        }
        self.onEvent = onEvent
    }

    func unregister() {
        onEvent = nil
        directions.removeAll()
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard status == noErr, id.signature == Self.signature,
              let reverse = directions[id.id] else { return OSStatus(eventNotHandledErr) }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): onEvent?(.pressed(reverse: reverse))
        case UInt32(kEventHotKeyReleased): onEvent?(.released)
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    isolated deinit {
        unregister()
    }
}
