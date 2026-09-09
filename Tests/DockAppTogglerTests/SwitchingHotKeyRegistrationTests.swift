import AppKit
import Carbon
import Testing
@testable import DockAppToggler

@Suite(.serialized)
@MainActor
struct SwitchingHotKeyRegistrationTests {
    private let shortcut = KeyboardShortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .command])

    /// Deliver an event to this test process's Carbon handler, without synthesizing keyboard input.
    private func send(id: UInt32, signature: OSType = SwitchingHotKeyRegistration.signature,
                      kind: UInt32 = UInt32(kEventHotKeyPressed)) throws -> OSStatus {
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
        let value = try #require(event)
        defer { ReleaseEvent(value) }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        #expect(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  MemoryLayout<EventHotKeyID>.size, &hotKeyID) == noErr)
        return SendEventToEventTarget(value, GetApplicationEventTarget())
    }

    @Test func nativeHandlerDispatchesForwardReverseAndRelease() throws {
        _ = NSApplication.shared
        let registration = SwitchingHotKeyRegistration()
        defer { registration.unregister() }
        var events: [SwitchingHotKeyRegistration.Event] = []
        try registration.register(shortcut: shortcut) { events.append($0) }
        #expect(registration.directions.count == 2)
        let forward = try #require(registration.directions.first { !$0.value }?.key)
        let reverse = try #require(registration.directions.first { $0.value }?.key)
        #expect(try send(id: forward) == noErr)
        #expect(try send(id: reverse) == noErr)
        #expect(try send(id: forward, kind: UInt32(kEventHotKeyReleased)) == noErr)
        #expect(events == [.pressed(reverse: false), .pressed(reverse: true), .released])
        #expect(try send(id: forward, signature: 0x54657374) == eventNotHandledErr)
        #expect(events.count == 3)
    }

    @Test func changingShortcutRejectsLateEventsAndReleasesOldCombination() throws {
        _ = NSApplication.shared
        let registration = SwitchingHotKeyRegistration()
        let other = SwitchingHotKeyRegistration()
        defer { registration.unregister(); other.unregister() }
        var events: [SwitchingHotKeyRegistration.Event] = []
        try registration.register(shortcut: shortcut) { events.append($0) }
        let oldID = try #require(registration.directions.keys.first)
        let replacement = KeyboardShortcut(keyCode: UInt16(kVK_F18), modifiers: shortcut.modifiers)
        try registration.register(shortcut: replacement) { events.append($0) }
        #expect(try send(id: oldID) == eventNotHandledErr)
        #expect(events.isEmpty)
        try other.register(shortcut: shortcut) { _ in }
        #expect(other.directions.count == 2)
    }

    @Test func reverseConflictRollsBackForwardRegistrationAndCanBeRetried() throws {
        _ = NSApplication.shared
        let blocker = SwitchingHotKeyRegistration()
        let registration = SwitchingHotKeyRegistration()
        let forwardProbe = SwitchingHotKeyRegistration()
        defer { blocker.unregister(); registration.unregister(); forwardProbe.unregister() }
        let reverseOnly = KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.union(.shift))
        try blocker.register(shortcut: reverseOnly) { _ in }
        do {
            try registration.register(shortcut: shortcut) { _ in }
            Issue.record("Expected the native registration conflict to be reported")
        } catch let error as SwitchingHotKeyRegistration.RegistrationError {
            #expect(error.status == eventHotKeyExistsErr)
            #expect(error.localizedDescription.contains("bereits"))
        }
        #expect(registration.directions.isEmpty)
        // The first registration must have been rolled back even though the second failed.
        var forwardRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                        EventHotKeyID(signature: 0x54657374, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &forwardRef)
        #expect(status == noErr)
        if let forwardRef { UnregisterEventHotKey(forwardRef) }
        blocker.unregister()
        try registration.register(shortcut: shortcut) { _ in }
        #expect(registration.directions.count == 2)
        registration.unregister()
        registration.unregister()
        try forwardProbe.register(shortcut: shortcut) { _ in }
    }

    @Test func deinitReleasesNativeRegistrations() throws {
        _ = NSApplication.shared
        var registration: SwitchingHotKeyRegistration? = SwitchingHotKeyRegistration()
        try registration?.register(shortcut: shortcut) { _ in }
        weak var released = registration
        registration = nil
        #expect(released == nil)
        let next = SwitchingHotKeyRegistration()
        defer { next.unregister() }
        try next.register(shortcut: shortcut) { _ in }
        #expect(next.directions.count == 2)
    }
}
