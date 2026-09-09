import AppKit
import Carbon

struct KeyboardShortcut: Equatable {
    static let keyCodeDefaultsKey = "SwitchingShortcutKeyCode"
    static let modifiersDefaultsKey = "SwitchingShortcutModifiers"
    static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let defaultSwitchingShortcut = KeyboardShortcut(
        keyCode: UInt16(kVK_Tab),
        modifiers: .option
    )

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static var savedSwitchingShortcut: KeyboardShortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil else {
            return defaultSwitchingShortcut
        }

        let keyCode = UInt16(defaults.integer(forKey: keyCodeDefaultsKey))
        let rawModifiers = UInt(defaults.integer(forKey: modifiersDefaultsKey))
        let modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers).intersection(significantModifiers)

        guard !modifiers.isEmpty else {
            return defaultSwitchingShortcut
        }

        return KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    static func saveSwitchingShortcut(_ shortcut: KeyboardShortcut) {
        UserDefaults.standard.set(Int(shortcut.keyCode), forKey: keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(shortcut.modifiers.rawValue), forKey: modifiersDefaultsKey)
        NotificationCenter.default.post(name: .switchingShortcutChanged, object: nil)
    }

    static func from(event: NSEvent) -> KeyboardShortcut? {
        let modifiers = event.modifierFlags.intersection(significantModifiers)
        guard !modifiers.isEmpty else { return nil }
        return KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var registrations: [(modifiers: UInt32, reverse: Bool)] {
        var result = [(modifiers: carbonModifiers, reverse: false)]
        if !modifiers.contains(.shift) {
            result.append((modifiers: carbonModifiers | UInt32(shiftKey), reverse: true))
        }
        return result
    }

    func modifiersPressed(in carbonFlags: UInt32) -> Bool {
        var flags = carbonFlags
        if flags & UInt32(rightOptionKey) != 0 { flags |= UInt32(optionKey) }
        if flags & UInt32(rightControlKey) != 0 { flags |= UInt32(controlKey) }
        if flags & UInt32(rightShiftKey) != 0 { flags |= UInt32(shiftKey) }
        return flags & carbonModifiers == carbonModifiers
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "Key \(keyCode)"
        }
    }
}

extension Notification.Name {
    static let switchingShortcutChanged = Notification.Name("switchingShortcutChanged")
}
