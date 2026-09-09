import AppKit
import Carbon

struct SwitchingShortcutState {
    enum Action {
        case passThrough, consume, next, previous, select, cancel

        var consumesEvent: Bool {
            self != .passThrough && self != .select
        }
    }

    private var isSwitching = false
    private var consumedKeys: Set<UInt16> = []

    mutating func handle(
        _ event: NSEvent,
        shortcut: KeyboardShortcut,
        isEnabled: Bool,
        isRecording: Bool
    ) -> Action {
        guard isEnabled, !isRecording else { return .passThrough }

        switch event.type {
        case .keyDown:
            if shortcut.matches(event) {
                isSwitching = true
                consumedKeys.insert(event.keyCode)
                let reverse = event.modifierFlags.contains(.shift) && !shortcut.modifiers.contains(.shift)
                return reverse ? .previous : .next
            }
            if isSwitching, event.keyCode == kVK_Escape {
                isSwitching = false
                consumedKeys.insert(event.keyCode)
                return .cancel
            }
        case .keyUp:
            // The modifier may have been released before the shortcut key.
            if consumedKeys.remove(event.keyCode) != nil { return .consume }
        case .flagsChanged:
            if isSwitching, !shortcut.modifiersPressed(in: event.modifierFlags) {
                isSwitching = false
                return .select
            }
        default:
            break
        }

        return .passThrough
    }
}
