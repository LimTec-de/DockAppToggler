struct SwitchingShortcutState {
    enum Action {
        case none, next, previous, select
    }

    private(set) var isSwitching = false

    mutating func press(reverse: Bool, isEnabled: Bool, isRecording: Bool) -> Action {
        guard isEnabled, !isRecording else { return .none }
        isSwitching = true
        return reverse ? .previous : .next
    }

    mutating func checkModifiers(_ flags: UInt32, shortcut: KeyboardShortcut) -> Action {
        guard isSwitching, !shortcut.modifiersPressed(in: flags) else { return .none }
        isSwitching = false
        return .select
    }
}
