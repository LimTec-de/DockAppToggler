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
    
    private init() {
        setupMonitors()
    }
    
    private func setupMonitors() {
        // Monitor option key press and release
        optionKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleOptionKey(event)
        }
        
        // Monitor tab key press
        tabKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleTabKey(event)
        }
        
        // Monitor tab key release
        tabKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleTabKeyUp(event)
        }
    }
    
    private func handleOptionKey(_ event: NSEvent) {
        isOptionPressed = event.modifierFlags.contains(.option)
        
        // Only hide when option is released
        if !isOptionPressed {
            hideWindowChooser()
        }
    }
    
    private func handleTabKey(_ event: NSEvent) {
        guard isOptionPressed,
              event.keyCode == 48 // Tab key code
        else {
            return
        }
        
        isTabPressed = true
        
        if windowChooserController == nil {
            // First Option+Tab press - show window chooser
            showWindowChooser()
        } else {
            // Subsequent Tab presses - cycle through windows
            cycleToNextWindow()
        }
    }
    
    private func handleTabKeyUp(_ event: NSEvent) {
        guard event.keyCode == 48 else { return } // Tab key code
        isTabPressed = false
    }
    
    private func showWindowChooser() {
        currentWindowIndex = 0
        windowChooserController = WindowChooserController(
            at: .zero,  // We'll position it in the center
            windows: WindowHistory.shared.getAllRecentWindows(),
            app: NSRunningApplication.current,
            isHistory: true,
            callback: { element, isMinimized in
                // Handle window selection
                Task { @MainActor in
                    // Raise window to front
                    AXUIElementPerformAction(element, "AXRaise" as CFString)
                    
                    // Get the app that owns this window
                    var appElement: AnyObject?
                    AXUIElementCopyAttributeValue(element, "AXApplication" as CFString, &appElement)
                    
                    if let appElement = appElement,
                       CFGetTypeID(appElement as CFTypeRef) == AXUIElementGetTypeID() {
                        var pid: pid_t = 0
                        let result = AXUIElementGetPid(appElement as! AXUIElement, &pid)
                        if result == .success,
                           let app = NSRunningApplication(processIdentifier: pid) {
                            // Activate the app
                            app.activate(options: .activateIgnoringOtherApps)
                        }
                    }
                }
            }
        )
        windowChooserController?.showChooser()
        highlightCurrentWindow()
    }
    
    private func hideWindowChooser() {
        windowChooserController?.close()
        windowChooserController = nil
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
} 