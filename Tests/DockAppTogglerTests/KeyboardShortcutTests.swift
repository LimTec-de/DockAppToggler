import AppKit
import Carbon
import Testing
@testable import DockAppToggler

struct KeyboardShortcutTests {
    @Test func optionTabRegistersForwardAndShiftReverseOnly() {
        let shortcut = KeyboardShortcut.defaultSwitchingShortcut
        #expect(shortcut.keyCode == kVK_Tab)
        #expect(shortcut.registrations.map(\.modifiers) == [UInt32(optionKey), UInt32(optionKey | shiftKey)])
        #expect(shortcut.registrations.map(\.reverse) == [false, true])
        #expect(shortcut.carbonModifiers != UInt32(NSEvent.ModifierFlags.option.rawValue))
    }

    @Test func customShortcutMapsAllModifiersWithoutCapsLock() {
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .control, .option, .capsLock])
        #expect(shortcut.carbonModifiers == UInt32(cmdKey | controlKey | optionKey))
        #expect(shortcut.registrations.count == 2)
    }

    @Test func shiftInRecordedShortcutDoesNotRegisterItTwice() {
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.option, .shift])
        #expect(shortcut.registrations.count == 1)
        #expect(shortcut.registrations.first?.reverse == false)
        #expect(shortcut.registrations.first?.modifiers == UInt32(optionKey | shiftKey))
    }

    @Test func recordingNormalizesModifiersAndRejectsUnmodifiedKeys() {
        func event(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                            timestamp: 0, windowNumber: 0, context: nil,
                            characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                            keyCode: UInt16(kVK_Tab))!
        }
        #expect(KeyboardShortcut.from(event: event([.option, .capsLock])) == .defaultSwitchingShortcut)
        #expect(KeyboardShortcut.from(event: event([])) == nil)
    }

    @Test func repeatedTabReleaseKeepsChooserOpenUntilOptionIsReleased() {
        var state = SwitchingShortcutState()
        for _ in 0..<3 {
            for _ in 0..<2 {
                #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
                #expect(state.checkModifiers(UInt32(optionKey), shortcut: .defaultSwitchingShortcut) == .none)
                #expect(state.isSwitching)
            }
            #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .select)
            #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .none)
        }
    }

    @Test func quickTapSelectsEvenWhenOptionWasReleasedBeforeHandlerRuns() {
        var state = SwitchingShortcutState()
        #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
        #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .select)
        #expect(!state.isSwitching)
    }

    @Test func reverseSwitchingDoesNotSelectOnShiftRelease() {
        var state = SwitchingShortcutState()
        #expect(state.press(reverse: true, isEnabled: true, isRecording: false) == .previous)
        #expect(state.checkModifiers(UInt32(optionKey), shortcut: .defaultSwitchingShortcut) == .none)
        #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
        #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .select)
    }

    @Test func customShortcutSelectsWhenAnyRequiredModifierIsReleased() {
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .control])
        var state = SwitchingShortcutState()
        #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
        #expect(state.checkModifiers(UInt32(cmdKey | controlKey | shiftKey), shortcut: shortcut) == .none)
        #expect(state.checkModifiers(UInt32(controlKey), shortcut: shortcut) == .select)
    }

    @Test func rightHandModifiersAlsoKeepTheChooserOpen() {
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.control, .option, .shift])
        #expect(shortcut.modifiersPressed(in: UInt32(rightControlKey | rightOptionKey | rightShiftKey)))
        #expect(!shortcut.modifiersPressed(in: UInt32(rightControlKey | rightOptionKey)))
    }

    @Test func disabledAndRecordingShortcutsCannotStartSwitching() {
        var state = SwitchingShortcutState()
        #expect(state.press(reverse: false, isEnabled: false, isRecording: false) == .none)
        #expect(state.press(reverse: true, isEnabled: true, isRecording: true) == .none)
        #expect(!state.isSwitching)
        #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .none)
    }

    @Test func cancellationDoesNotSelectAndNextSessionStillWorks() {
        var state = SwitchingShortcutState()
        #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
        state = SwitchingShortcutState()
        #expect(state.checkModifiers(0, shortcut: .defaultSwitchingShortcut) == .none)
        #expect(state.press(reverse: false, isEnabled: true, isRecording: false) == .next)
    }
}
