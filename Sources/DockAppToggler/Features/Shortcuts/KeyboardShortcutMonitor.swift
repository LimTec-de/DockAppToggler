import AppKit
import Carbon
import ApplicationServices

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
    private let hotKeys = SwitchingHotKeyRegistration()
    private var modifierTimer: Timer?
    private var escapeMonitor: Any?
    private(set) var registrationError: String?

    private var isOptionTabEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: false)
    }

    private init() {
        updateRegistration()
        
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
        updateRegistration()
    }

    private func cancelSwitching() {
        eventGeneration += 1
        finishSwitching()
    }

    private func finishSwitching() {
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
                var pid: pid_t = 0
                let selectedApp = AXUIElementGetPid(element, &pid) == .success
                    ? NSRunningApplication(processIdentifier: pid)
                    : nil
                AccessibilityService.shared.focusWindow(element, for: selectedApp)
                self?.finishSwitching()
            }
        )
        
        windowChooserController?.showChooser(mode: .history)
        highlightCurrentWindow()
    }
    
    private func hideWindowChooser() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
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
    
    private func updateRegistration() {
        cancelSwitching()
        hotKeys.unregister()
        registrationError = nil
        guard isOptionTabEnabled, !isRecordingShortcut else { return }
        let permissions = AppPermissionState.current
        guard permissions.accessibilityGranted, permissions.screenRecordingGranted else { return }

        do {
            try hotKeys.register(shortcut: switchingShortcut) { [weak self] event in
                guard let self else { return }
                let generation = self.eventGeneration
                // Keep the native handler fast; discard actions from an obsolete registration.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.eventGeneration == generation else { return }
                    self.handleHotKey(event)
                }
            }
        } catch {
            registrationError = error.localizedDescription
            Logger.error(error.localizedDescription)
        }
    }

    private func handleHotKey(_ event: SwitchingHotKeyRegistration.Event) {
        switch event {
        case .pressed(let reverse):
            let action = shortcutState.press(
                reverse: reverse, isEnabled: isOptionTabEnabled, isRecording: isRecordingShortcut
            )
            guard action != .none else { return }
            if windowChooserController == nil { showWindowChooser() }
            guard windowChooserController != nil else { cancelSwitching(); return }
            if action == .previous {
                windowChooserController?.chooserView?.selectPreviousItem()
            } else {
                windowChooserController?.chooserView?.selectNextItem()
            }
            startModifierTracking()
        case .released:
            break // Releasing Tab keeps the chooser open while Option is still held.
        }
    }

    private func startModifierTracking() {
        guard modifierTimer == nil else { return }
        // Read only current modifiers while switching; no global keyboard event monitor.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModifiers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shortcutState.isSwitching,
                  event.keyCode == kVK_Escape else { return event }
            self.cancelSwitching()
            return nil
        }
    }

    private func checkModifiers() {
        guard shortcutState.isSwitching else { return }
        guard windowChooserController?.window?.isVisible == true else {
            cancelSwitching()
            return
        }
        if shortcutState.checkModifiers(GetCurrentKeyModifiers(), shortcut: switchingShortcut) == .select {
            windowChooserController?.chooserView?.selectCurrentItem()
            finishSwitching()
        }
    }

    isolated deinit {
        hotKeys.unregister()
        modifierTimer?.invalidate()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleOptionTabSettingChanged(_ notification: Notification) {
        updateRegistration()
    }

    @objc private func handleSwitchingShortcutChanged() {
        switchingShortcut = KeyboardShortcut.savedSwitchingShortcut
        updateRegistration()
    }

    @objc private func handlePermissionsChanged() {
        updateRegistration()
    }
}
