import AppKit
import Carbon
import Testing
@testable import DockAppToggler

struct KeyboardShortcutTests {
    private func keyEvent(
        _ modifiers: NSEvent.ModifierFlags,
        keyCode: Int = kVK_Tab,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    @Test func testShortcutDoesNotStealChordsWithExtraCommandOrControl() {
        let shortcut = KeyboardShortcut.defaultSwitchingShortcut
        #expect(!shortcut.matches(keyEvent([.option, .command])))
        #expect(!shortcut.matches(keyEvent([.option, .control])))
    }

    @Test func testShiftCanReverseSwitchingAndCapsLockDoesNotPreventMatching() {
        let shortcut = KeyboardShortcut.defaultSwitchingShortcut
        #expect(shortcut.matches(keyEvent(.option)))
        #expect(shortcut.matches(keyEvent([.option, .shift])))
        #expect(shortcut.matches(keyEvent([.option, .capsLock])))
        #expect(!shortcut.matches(keyEvent([])))
        #expect(!shortcut.matches(keyEvent(.option, keyCode: kVK_ANSI_A)))
    }

    @Test func testCustomShortcutRequiresAllRecordedModifiers() {
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .control])
        #expect(shortcut.matches(keyEvent([.command, .control], keyCode: kVK_ANSI_K)))
        #expect(!shortcut.matches(keyEvent(.command, keyCode: kVK_ANSI_K)))
        #expect(!shortcut.matches(keyEvent([.command, .control, .option], keyCode: kVK_ANSI_K)))
    }

    private func handle(
        _ event: NSEvent,
        state: inout SwitchingShortcutState,
        shortcut: KeyboardShortcut = .defaultSwitchingShortcut,
        isEnabled: Bool = true,
        isRecording: Bool = false
    ) -> SwitchingShortcutState.Action {
        state.handle(event, shortcut: shortcut, isEnabled: isEnabled, isRecording: isRecording)
    }

    @Test func testShortcutStartsWithoutAnEarlierModifierEvent() {
        var state = SwitchingShortcutState()
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .control])
        #expect(handle(keyEvent([.command, .control], keyCode: kVK_ANSI_K), state: &state, shortcut: shortcut) == .next)
        #expect(handle(keyEvent(.control, type: .flagsChanged), state: &state, shortcut: shortcut) == .select)
    }

    @Test func testRepeatedSwitchingSessionsKeepWorking() {
        var state = SwitchingShortcutState()
        for _ in 0..<3 {
            #expect(handle(keyEvent(.option), state: &state) == .next)
            #expect(handle(keyEvent(.option, type: .keyUp), state: &state) == .consume)
            #expect(handle(keyEvent(.option), state: &state) == .next)
            #expect(handle(keyEvent(.option, type: .keyUp), state: &state) == .consume)
            #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .select)
            #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .passThrough)
        }
    }

    @Test func testQuickTapSelectsAndConsumesKeyUpAfterModifierRelease() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent(.option), state: &state) == .next)
        let release = handle(keyEvent([], type: .flagsChanged), state: &state)
        #expect(release == .select)
        #expect(!release.consumesEvent)
        #expect(handle(keyEvent([], type: .keyUp), state: &state) == .consume)
        #expect(handle(keyEvent([], type: .keyUp), state: &state) == .passThrough)
    }

    @Test func testRecordingDoesNotTriggerTheCurrentlyConfiguredShortcut() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent(.option), state: &state, isRecording: true) == .passThrough)
        #expect(handle(keyEvent(.option, type: .keyUp), state: &state, isRecording: true) == .passThrough)
        #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .passThrough)
        #expect(handle(keyEvent(.option), state: &state) == .next)
    }

    @Test func testDisabledSwitchingDoesNotConsumeTyping() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent(.option), state: &state, isEnabled: false) == .passThrough)
        #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .passThrough)
        #expect(handle(keyEvent([]), state: &state) == .passThrough)
        #expect(handle(keyEvent(.option, keyCode: kVK_ANSI_A), state: &state) == .passThrough)
    }

    @Test func testShiftReversesOnlyWhenItIsNotPartOfTheRecordedShortcut() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent([.option, .shift]), state: &state) == .previous)
        #expect(handle(keyEvent(.option, type: .flagsChanged), state: &state) == .passThrough)
        #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .select)

        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.option, .shift])
        #expect(handle(keyEvent([.option, .shift]), state: &state, shortcut: shortcut) == .next)
        #expect(handle(keyEvent(.option, type: .flagsChanged), state: &state, shortcut: shortcut) == .select)
    }

    @Test func testEscapeCancelsWithoutSelectingAndAllowsTheNextSession() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent(.option), state: &state) == .next)
        #expect(handle(keyEvent(.option, keyCode: kVK_Escape), state: &state) == .cancel)
        #expect(handle(keyEvent([], keyCode: kVK_Escape, type: .keyUp), state: &state) == .consume)
        #expect(handle(keyEvent([], type: .flagsChanged), state: &state) == .passThrough)
        #expect(handle(keyEvent([], type: .keyUp), state: &state) == .consume)
        #expect(handle(keyEvent(.option), state: &state) == .next)
    }

    @Test func testChangingShortcutResetsThePreviousSession() {
        var state = SwitchingShortcutState()
        #expect(handle(keyEvent(.option), state: &state) == .next)
        state = SwitchingShortcutState()
        let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: .control)
        #expect(handle(keyEvent([], type: .flagsChanged), state: &state, shortcut: shortcut) == .passThrough)
        #expect(handle(keyEvent(.option), state: &state, shortcut: shortcut) == .passThrough)
        #expect(handle(keyEvent(.control, keyCode: kVK_ANSI_K), state: &state, shortcut: shortcut) == .next)
    }
}
