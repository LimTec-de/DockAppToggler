import AppKit
import Carbon
import ApplicationServices

@MainActor
class KeyboardShortcutMonitor {
    static let shared = KeyboardShortcutMonitor()
    
    private var optionKeyMonitor: Any?
    private var tabKeyMonitor: Any?
    private var tabKeyUpMonitor: Any?  // Add monitor for key up events
    private var isOptionPressed = false
    private var isTabPressed = false   // Track tab key state
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
        UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: true)
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
    }
    
    private func setupMonitors() {
        // Set up option key monitors
        setupOptionKeyMonitors()
        
        // Monitor tab key press globally
        tabKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 48 && self?.isOptionPressed == true {
                // print("🔍 Consuming global tab key event")
                self?.handleTabKey(event)
            }
        }
        
        // Monitor tab key press locally to consume events
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // If option is pressed and it's a tab key, consume all tab events
            if event.keyCode == 48 && self?.isOptionPressed == true {
                // print("🔍 Consuming local tab key event")
                if event.type == .keyDown {
                    self?.handleTabKey(event)
                }
                return nil  // Consume both keyDown and keyUp events
            }
            return event  // Pass through other events
        }
        
        // Monitor tab key release
        tabKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            if event.keyCode == 48 && self?.isOptionPressed == true {
                // print("🔍 Consuming global tab key up event")
                self?.handleTabKeyUp(event)
            }
        }
    }
    
    private func setupOptionKeyMonitors() {
        // print("🔍 Setting up option key monitors")
        // Monitor option key press and release globally (when app is not active)
        optionKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            // print("🔍 Global flag changed event received")
            self?.handleOptionKey(event)
        }
        
        // Monitor option key press and release locally (when app is active)
        optionKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            // print("🔍 Local flag changed event received")
            self?.handleOptionKey(event)
            return event
        }
    }
    
    private func handleOptionKey(_ event: NSEvent) {
        // Check if feature is enabled before processing option key
        guard isOptionTabEnabled else { return }
        
        let wasPressed = isOptionPressed
        let isNowPressed = event.modifierFlags.contains(.option)
        
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
              event.keyCode == 48 // Tab key code
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
        guard event.keyCode == 48 else { return } // Tab key code
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
            if event.keyCode == 48 { // Tab key
                if event.modifierFlags.contains(.shift) {
                    self?.windowChooserController?.chooserView?.selectPreviousItem()
                } else {
                    self?.windowChooserController?.chooserView?.selectNextItem()
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
                    if AXUIElementGetPid(element, &pid) == .success,
                       let app = NSRunningApplication(processIdentifier: pid) {
                        app.activate(options: .activateIgnoringOtherApps)
                        let _ = AXUIElementPerformAction(element, "AXRaise" as CFString)
                    } else {
                        AXUIElementPerformAction(element, "AXRaise" as CFString)
                    }
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
        // Check if feature is enabled first
        guard isOptionTabEnabled else {
            return Unmanaged.passRetained(event)
        }
        
        // Handle flags changed events to track option key state
        if type == .flagsChanged {
            if let nsEvent = NSEvent(cgEvent: event) {
                let wasPressed = isOptionPressed
                isOptionPressed = nsEvent.modifierFlags.contains(.option)
                
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
           nsEvent.keyCode == 48 {  // Tab key
            
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
                // Restart the app when the feature is enabled
                StatusBarController.performRestart()
            } else {
                // Clean up when disabled
                hideWindowChooser()
                isOptionPressed = false
                isTabPressed = false
            }
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