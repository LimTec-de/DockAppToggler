import AppKit
import Carbon
import ApplicationServices

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

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let pressed = event.modifierFlags.intersection(Self.significantModifiers)
        return pressed == modifiers || pressed == modifiers.union(.shift)
    }

    func modifiersPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        let pressed = flags.intersection(Self.significantModifiers)
        return (pressed.rawValue & modifiers.rawValue) == modifiers.rawValue
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

@MainActor
class KeyboardShortcutMonitor {
    static let shared = KeyboardShortcutMonitor()

    /// ⌃⌥P (Control+Option+P) für Screenshot.
    private static func isControlOptionScreenshotChord(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskControl), flags.contains(.maskAlternate) else { return false }
        let blocked: CGEventFlags = [.maskCommand, .maskShift]
        return blocked.intersection(flags).isEmpty
    }
    
    private var switchingShortcut = KeyboardShortcut.savedSwitchingShortcut
    private var shortcutState = SwitchingShortcutState()
    private var isRecordingShortcut = false
    private var eventGeneration = 0
    private var windowChooserController: WindowChooserController?
    private var currentWindowIndex = 0
    private var backdropWindow: NSWindow?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    private var isOptionTabEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: false)
    }

    private init() {
        setupEventTap()
        
        // Add observer for option tab setting changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOptionTabSettingChanged(_:)),
            name: .optionTabStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSwitchingShortcutChanged),
            name: .switchingShortcutChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionsChanged),
            name: .appPermissionsChanged,
            object: nil
        )
    }
    
    func setShortcutRecording(_ isRecording: Bool) {
        isRecordingShortcut = isRecording
        cancelSwitching()
    }

    private func cancelSwitching() {
        eventGeneration += 1
        shortcutState = SwitchingShortcutState()
        hideWindowChooser()
    }

    private func showWindowChooser() {
        currentWindowIndex = 0
        
        // Get the main screen
        let windows = WindowHistory.shared.getAllRecentWindows()
        guard !windows.isEmpty, let screen = NSScreen.main else { return }
        
        // Create backdrop window
        let backdropWindow = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure backdrop window with minimal event handling
        let contentView = NSView()

        // Configure backdrop window
        backdropWindow.contentView = contentView
        backdropWindow.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        backdropWindow.isOpaque = false
        backdropWindow.level = .modalPanel - 1  // Lower level so it appears behind other UI elements
        backdropWindow.ignoresMouseEvents = true
        backdropWindow.isMovable = false
        backdropWindow.acceptsMouseMovedEvents = false
        
        // Ensure window is visible on all spaces
        backdropWindow.collectionBehavior = [.canJoinAllSpaces]
        
        // Ensure window becomes key and visible
        (backdropWindow as NSPanel).becomesKeyOnlyIfNeeded = false
        backdropWindow.orderFront(nil)
        backdropWindow.makeKey()
        
        // Ensure proper focus
        NSApp.activate(ignoringOtherApps: true)
        contentView.window?.makeFirstResponder(contentView)
        
        self.backdropWindow = backdropWindow
        
        // Calculate center position for window chooser
        let chooserPoint = NSPoint(
            x: screen.frame.midX,
            y: screen.frame.midY
        )
        
        // Create window chooser controller
        windowChooserController = WindowChooserController(
            at: chooserPoint,
            windows: windows,
            app: NSRunningApplication.current,
            isHistory: true,
            callback: { [weak self] element, isMinimized in
                // Handle window selection
                Task { @MainActor in
                    var pid: pid_t = 0
                    let selectedApp = AXUIElementGetPid(element, &pid) == .success
                        ? NSRunningApplication(processIdentifier: pid)
                        : nil
                    AccessibilityService.shared.focusWindow(element, for: selectedApp)
                    self?.cancelSwitching()
                }
            }
        )
        
        windowChooserController?.showChooser(mode: .history)
        highlightCurrentWindow()
    }
    
    private func hideWindowChooser() {
        windowChooserController?.close()
        windowChooserController = nil
        backdropWindow?.close()
        backdropWindow = nil
    }

    private func cycleToNextWindow() {
        let windows = WindowHistory.shared.getAllRecentWindows()
        guard !windows.isEmpty else { return }
        
        currentWindowIndex = (currentWindowIndex + 1) % windows.count
        highlightCurrentWindow()
    }
    
    private func highlightCurrentWindow() {
        let windows = WindowHistory.shared.getAllRecentWindows()
        guard !windows.isEmpty else { return }
        
        let selectedWindow = windows[currentWindowIndex]
        windowChooserController?.highlightWindow(selectedWindow)
    }
    
    private func setupEventTap() {
        // The permission wizard handles missing grants without prompting on launch.
        guard eventTap == nil, CGPreflightListenEventAccess(), AXIsProcessTrusted() else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEventTap(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.error("Failed to create keyboard event tap - check accessibility and input monitoring permissions")
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            Logger.error("Failed to create keyboard event tap run loop source")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        eventTapRunLoopSource = runLoopSource
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.warning("Keyboard event tap was disabled by system, re-enabled")
            }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        return handleKeyEvent(nsEvent) ? nil : Unmanaged.passUnretained(event)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let action = shortcutState.handle(
            event, shortcut: switchingShortcut,
            isEnabled: isOptionTabEnabled, isRecording: isRecordingShortcut
        )
        guard action != .passThrough, action != .consume else { return action.consumesEvent }

        // Keep the tap fast and preserve key-down/release order, including quick taps.
        // Setting changes cancel actions that were queued for the previous shortcut.
        let generation = eventGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.eventGeneration == generation else { return }
            switch action {
            case .next, .previous:
                if self.windowChooserController == nil { self.showWindowChooser() }
                if action == .previous {
                    self.windowChooserController?.chooserView?.selectPreviousItem()
                } else {
                    self.windowChooserController?.chooserView?.selectNextItem()
                }
            case .select:
                self.windowChooserController?.chooserView?.selectCurrentItem()
                self.hideWindowChooser()
            case .cancel:
                self.hideWindowChooser()
            case .passThrough, .consume:
                break
            }
        }
        return action.consumesEvent
    }

    private nonisolated func cleanup() {
        DispatchQueue.main.sync {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                eventTap = nil
            }
            if let source = eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                eventTapRunLoopSource = nil
            }
        }
    }

    deinit {
        cleanup()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleOptionTabSettingChanged(_ notification: Notification) {
        cancelSwitching()
        if isOptionTabEnabled { setupEventTap() }
    }

    @objc private func handleSwitchingShortcutChanged() {
        switchingShortcut = KeyboardShortcut.savedSwitchingShortcut
        cancelSwitching()
    }

    @objc private func handlePermissionsChanged() {
        setupEventTap()
    }
}

extension Notification.Name {
    static let switchingShortcutChanged = Notification.Name("switchingShortcutChanged")
}
