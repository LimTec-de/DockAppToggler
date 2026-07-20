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
        return modifiersPressed(in: event.modifierFlags)
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
    
    private var optionKeyMonitor: Any?
    private var tabKeyMonitor: Any?
    private var tabKeyUpMonitor: Any?  // Add monitor for key up events
    private var isOptionPressed = false
    private var isTabPressed = false   // Track tab key state
    private var switchingShortcut = KeyboardShortcut.savedSwitchingShortcut
    private var windowChooserController: WindowChooserController?
    private var currentWindowIndex = 0
    private var backdropWindow: NSWindow?
    private var localEventMonitor: Any?  // Add this property
    private var optionKeyLocalMonitor: Any?  // Add this property
    private var eventTap: CFMachPort? {
        willSet {
            // Cleanup old event tap before assigning new one
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
        }
    }
    
    private var isOptionTabEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: false)
    }

    private init() {
        setupEventTap()
        setupMonitors()
        
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
    
    private func setupMonitors() {
        // Set up option key monitors
        setupOptionKeyMonitors()
        
        // Monitor tab key press globally
        tabKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            if self.switchingShortcut.matches(event), self.isOptionPressed {
                // print("🔍 Consuming global tab key event")
                self.handleTabKey(event)
            }
        }
        
        // Monitor tab key press locally to consume events
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // If option is pressed and it's a tab key, consume all tab events
            guard let self else { return event }
            if event.keyCode == self.switchingShortcut.keyCode && self.isOptionPressed {
                // print("🔍 Consuming local tab key event")
                if event.type == .keyDown {
                    self.handleTabKey(event)
                }
                return nil  // Consume both keyDown and keyUp events
            }
            return event  // Pass through other events
        }
        
        // Monitor tab key release
        tabKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self else { return }
            if event.keyCode == self.switchingShortcut.keyCode && self.isOptionPressed {
                // print("🔍 Consuming global tab key up event")
                self.handleTabKeyUp(event)
            }
        }
    }
    
    private func setupOptionKeyMonitors() {
        // print("🔍 Setting up option key monitors")
        // Monitor option key press and release globally (when app is not active)
        if optionKeyMonitor == nil {
            optionKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                // print("🔍 Global flag changed event received")
                self?.handleOptionKey(event)
            }
        }
        
        // Monitor option key press and release locally (when app is active)
        if optionKeyLocalMonitor == nil {
            optionKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                // print("🔍 Local flag changed event received")
                self?.handleOptionKey(event)
                return event
            }
        }
    }
    
    private func handleOptionKey(_ event: NSEvent) {
        // Check if feature is enabled before processing option key
        guard isOptionTabEnabled else { return }
        
        let wasPressed = isOptionPressed
        let isNowPressed = switchingShortcut.modifiersPressed(in: event.modifierFlags)
        
        isOptionPressed = isNowPressed
        
        if wasPressed && !isNowPressed {
            if let chooserView = windowChooserController?.chooserView {
                // Ensure we have a valid selection before proceeding
                if chooserView.selectedIndex >= 0 && chooserView.selectedIndex < chooserView.options.count {
                    // First select the current item
                    chooserView.selectCurrentItem()
                    
                    // Then hide the chooser after a short delay to ensure the selection is processed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.hideWindowChooser()
                    }
                } else {
                    // If no valid selection, just hide the chooser
                    hideWindowChooser()
                }
            } else {
                hideWindowChooser()
            }
        }
    }
    
    private func handleTabKey(_ event: NSEvent) {
        // Check if feature is enabled before processing tab key
        guard isOptionTabEnabled,
              isOptionPressed,
              event.keyCode == switchingShortcut.keyCode
        else {
            return
        }
        
        if windowChooserController == nil {
            // print("  - Creating new window chooser")
            showWindowChooser()
        } else if let chooserView = windowChooserController?.chooserView,
                  !chooserView.options.isEmpty {
            // print("  - Cycling through windows")
            if event.modifierFlags.contains(.shift) {
                // print("  - Selecting previous item")
                chooserView.selectPreviousItem()
            } else {
                // print("  - Selecting next item")
                chooserView.selectNextItem()
            }
        } else {
            // print("  - ⚠️ No windows available for cycling")
        }
    }
    
    private func handleTabKeyUp(_ event: NSEvent) {
        guard event.keyCode == switchingShortcut.keyCode else { return }
        isTabPressed = false
    }
    
    private func showWindowChooser() {
        currentWindowIndex = 0
        
        // Get the main screen
        guard let screen = NSScreen.main else { return }
        
        // Create backdrop window
        let backdropWindow = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure backdrop window with minimal event handling
        let contentView = KeyCaptureView()
        contentView.keyDownHandler = { [weak self] event in
            guard let self else { return }
            if event.keyCode == self.switchingShortcut.keyCode {
                if event.modifierFlags.contains(.shift) {
                    self.windowChooserController?.chooserView?.selectPreviousItem()
                } else {
                    self.windowChooserController?.chooserView?.selectNextItem()
                }
            }
        }
        
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
        let windows = WindowHistory.shared.getAllRecentWindows()
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
                    self?.hideWindowChooser()
                }
            }
        )
        
        windowChooserController?.showChooser(mode: .history)
        highlightCurrentWindow()
    }
    
    private func hideWindowChooser() {
        // print("🔍 Hiding window chooser")
        // Remove monitors
        if let monitor = optionKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            optionKeyLocalMonitor = nil
        }
        if let monitor = optionKeyMonitor {
            NSEvent.removeMonitor(monitor)
            optionKeyMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        
        // Reset all state
        isOptionPressed = false
        isTabPressed = false
        
        // Close windows
        //windowChooserController?.chooserView?.thumbnailView?.hideThumbnail(removePanel: true)
        windowChooserController?.close()
        windowChooserController = nil
        backdropWindow?.close()
        backdropWindow = nil
        
        // Re-initialize monitors
        setupOptionKeyMonitors()
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
        // Don't raise the raw macOS input-monitoring prompt on launch. If the permission
        // isn't granted yet, skip the tap; the permission wizard guides the user, and
        // handlePermissionsChanged() re-runs this once it's granted.
        guard CGPreflightListenEventAccess() else { return }

        // Create event tap to intercept key events
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)  // Add flags changed to catch modifier keys
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,  // Changed from cgSessionEventTap
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyboardShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEventTap(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap - check accessibility permissions")
            return
        }
        
        // Create a run loop source and add it to the current run loop
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            print("Failed to create run loop source")
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        self.eventTap = eventTap
    }
    
    private func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable event tap if macOS disabled it (e.g. due to timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.warning("Event tap was disabled by system, re-enabled")
            }
            return Unmanaged.passRetained(event)
        }
        
        // Check if feature is enabled first
        guard isOptionTabEnabled else {
            return Unmanaged.passRetained(event)
        }
        
        // Handle flags changed events to track option key state
        if type == .flagsChanged {
            if let nsEvent = NSEvent(cgEvent: event) {
                let wasPressed = isOptionPressed
                isOptionPressed = switchingShortcut.modifiersPressed(in: nsEvent.modifierFlags)
                
                // Handle option key release
                if wasPressed && !isOptionPressed {
                    Task { @MainActor in
                        if let chooserView = windowChooserController?.chooserView {
                            chooserView.selectCurrentItem()
                            hideWindowChooser()
                        } else {
                            hideWindowChooser()
                        }
                    }
                }
            }
            return Unmanaged.passRetained(event)
        }
        
        // Check if it's a tab key event
        if let nsEvent = NSEvent(cgEvent: event),
           nsEvent.keyCode == switchingShortcut.keyCode {
            
            // If option is pressed, we need to handle tab key events
            if isOptionPressed {
                // If this is a key up event, reset tab state
                if type == .keyUp {
                    isTabPressed = false
                    return nil  // Consume the event
                }
                
                // For key down events
                if type == .keyDown {
                    Task { @MainActor in
                        if windowChooserController == nil {
                            showWindowChooser()
                        } else {
                            handleTabKey(nsEvent)
                        }
                    }
                    return nil  // Consume the event
                }
            }
        }
        
        // Pass through all other events
        return Unmanaged.passRetained(event)
    }
    
    private nonisolated func cleanup() {
        DispatchQueue.main.sync {
            // Cleanup monitors
            if let monitor = optionKeyMonitor {
                NSEvent.removeMonitor(monitor)
                optionKeyMonitor = nil
            }
            if let monitor = tabKeyMonitor {
                NSEvent.removeMonitor(monitor)
                tabKeyMonitor = nil
            }
            if let monitor = tabKeyUpMonitor {
                NSEvent.removeMonitor(monitor)
                tabKeyUpMonitor = nil
            }
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
            if let monitor = optionKeyLocalMonitor {
                NSEvent.removeMonitor(monitor)
                optionKeyLocalMonitor = nil
            }
            
            // Cleanup event tap
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                eventTap = nil
            }
        }
    }
    
    deinit {
        cleanup()
        NotificationCenter.default.removeObserver(self)
    }
    
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // First check if Option+Tab is enabled
        guard isOptionTabEnabled else {
            return false // Let the system handle the event
        }
        
        // ... rest of existing handleKeyEvent implementation ...
        return true
    }
    
    @objc private func handleOptionTabSettingChanged(_ notification: Notification) {
        if let enabled = notification.userInfo?["enabled"] as? Bool {
            if enabled {
                if eventTap == nil {
                    setupEventTap()
                }
            } else {
                // Clean up when disabled
                hideWindowChooser()
                isOptionPressed = false
                isTabPressed = false
            }
        }
    }

    @objc private func handleSwitchingShortcutChanged() {
        switchingShortcut = KeyboardShortcut.savedSwitchingShortcut
        hideWindowChooser()
        isOptionPressed = false
        isTabPressed = false
    }

    @objc private func handlePermissionsChanged() {
        if eventTap == nil {
            setupEventTap()
        }
    }
}

private class KeyCaptureView: NSView {
    var keyDownHandler: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        keyDownHandler?(event)
    }
} 

extension Notification.Name {
    static let switchingShortcutChanged = Notification.Name("switchingShortcutChanged")
}
