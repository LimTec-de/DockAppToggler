import AppKit
import ApplicationServices

/// Manages history of recently used windows
@MainActor
class WindowHistory {
    // Singleton instance
    static let shared = WindowHistory()
    
    // Maximum number of windows to track per app
    private let maxHistorySize = 5
    
    // Timer for capturing active window
    @MainActor private var activeWindowTimer: Timer?
    
    // Wrapper to make Timer reference Sendable
    private class SendableTimerRef: @unchecked Sendable {
        let timer: Timer
        init(_ timer: Timer) {
            self.timer = timer
        }
    }
    
    // Nonisolated copy for cleanup
    private var cleanupTimerRef: SendableTimerRef?
    
    // Store last active window for mouse-triggered history
    private var lastActiveWindow: WindowInfo?
    private var lastActiveApp: NSRunningApplication?
    
    private init() {
        setupActiveWindowTimer()
    }
    
    private func setupActiveWindowTimer() {
        // Check active window every 1 second
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureActiveWindow()
            }
        }
        activeWindowTimer = timer
        cleanupTimerRef = SendableTimerRef(timer)  // Store in Sendable wrapper
    }
    
    private func captureActiveWindow() {
        // Get frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        
        // Get the frontmost window using Accessibility API
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        
        guard result == .success,
              let windowRef = windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return
        }
        
        let windowElement = windowRef as! AXUIElement
        
        // Get window name
        var nameRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &nameRef
        ) == .success,
        let windowName = nameRef as? String else {
            return
        }
        
        // Create WindowInfo
        lastActiveWindow = WindowInfo(
            window: windowElement,
            name: windowName,
            cgWindowID: nil,
            isAppElement: false
        )
        lastActiveApp = frontApp
    }
    
    /// Get recent windows for an app
    func getRecentWindows(for bundleIdentifier: String) -> [WindowInfo] {
        // Get top 5 windows from the system
        return getTopWindows()
    }
    
    /// Get all recent windows across all apps
    func getAllRecentWindows() -> [WindowInfo] {
        // Get top 5 windows from the system
        return getTopWindows()
    }
    
    /// Get windows for mouse-triggered history view
    func getMouseTriggeredWindows() -> [WindowInfo] {
        var windows = getTopWindows()
        
        // If we have a last active window, ensure it's included and at the top
        if let lastWindow = lastActiveWindow,
           let lastApp = lastActiveApp,
           lastApp.isTerminated == false {
            // Remove any existing instance of the last active window
            windows.removeAll { $0.name == lastWindow.name }
            // Add it at the beginning
            windows.insert(lastWindow, at: 0)
            // Keep only 5 windows
            if windows.count > 5 {
                windows.removeLast()
            }
        }
        
        return windows
    }
    
    /// Get the top 5 windows from the system
    private func getTopWindows() -> [WindowInfo] {
        // Get all windows using CGWindow API with proper ordering
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Filter and sort windows
        let validWindows = windowList
            .filter { window in
                // Only include normal windows
                guard let layer = window[kCGWindowLayer as String] as? Int32,
                      layer == kCGNormalWindowLevel,
                      // Must have a title
                      let title = window[kCGWindowName as String] as? String,
                      !title.isEmpty,
                      // Must have an owner PID
                      let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                      // Must have a window ID
                      let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                      // Must have bounds
                      let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                      // Window must be visible
                      let alpha = window[kCGWindowAlpha as String] as? Float,
                      alpha > 0,
                      // Get owner name for filtering
                      let ownerName = window[kCGWindowOwnerName as String] as? String,
                      // Filter out some system windows
                      !ownerName.contains("Window Server"),
                      !ownerName.contains("Dock") else {
                    return false
                }
                
                // Check window size
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                return width >= 200 && height >= 200
            }
            // Windows are already sorted by z-order due to CGWindowListCopyWindowInfo options
            .prefix(5) // Only take top 5 windows
        
        // Convert to WindowInfo objects with proper window bounds
        return validWindows.compactMap { window -> WindowInfo? in
            guard let title = window[kCGWindowName as String] as? String,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            
            // Create AXUIElement for the window's application
            let appRef = AXUIElementCreateApplication(ownerPID)
            
            // Get all windows for the app
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windowArray = windowsRef as? [AXUIElement] else {
                return nil
            }
            
            // Find matching window by title and position
            for axWindow in windowArray {
                var titleRef: CFTypeRef?
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                
                // Get window title
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let axTitle = titleRef as? String else {
                    continue
                }
                
                // Get window position
                guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                      CFGetTypeID(positionRef!) == AXValueGetTypeID() else {
                    continue
                }
                let posValue = positionRef as! AXValue
                
                // Get window size
                guard AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
                      CFGetTypeID(sizeRef!) == AXValueGetTypeID() else {
                    continue
                }
                let sizeValue = sizeRef as! AXValue
                
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posValue, .cgPoint, &position)
                AXValueGetValue(sizeValue, .cgSize, &size)
                
                // Create window bounds from AX values
                let axBounds = CGRect(origin: position, size: size)
                
                // Create window bounds from CGWindow info
                let cgBounds = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
                
                // Compare titles and bounds with some tolerance
                let tolerance: CGFloat = 10.0
                let boundsMatch = abs(axBounds.origin.x - cgBounds.origin.x) < tolerance &&
                                 abs(axBounds.origin.y - cgBounds.origin.y) < tolerance &&
                                 abs(axBounds.size.width - cgBounds.size.width) < tolerance &&
                                 abs(axBounds.size.height - cgBounds.size.height) < tolerance
                
                // Normalize titles for comparison
                let normalizedAxTitle = axTitle.trimmingCharacters(in: .whitespaces)
                let normalizedCGTitle = title.trimmingCharacters(in: .whitespaces)
                
                if normalizedAxTitle == normalizedCGTitle || boundsMatch {
                    return WindowInfo(
                        window: axWindow,
                        name: title,
                        cgWindowID: windowID,
                        isAppElement: false,
                        bounds: cgBounds
                    )
                }
            }
            
            return nil
        }
    }
    
    /// Add a window to history - kept for API compatibility but no longer stores history
    func addWindow(_ window: WindowInfo, for app: NSRunningApplication) {
        // Store as last active window
        lastActiveWindow = window
        lastActiveApp = app
    }
    
    /// Clear history for an app - kept for API compatibility but no longer stores history
    func clearHistory(for bundleIdentifier: String) {
        if let lastApp = lastActiveApp,
           lastApp.bundleIdentifier == bundleIdentifier {
            lastActiveWindow = nil
            lastActiveApp = nil
        }
    }
    
    /// Clear all history - kept for API compatibility but no longer stores history
    func clearAllHistory() {
        lastActiveWindow = nil
        lastActiveApp = nil
    }
    
    deinit {
        cleanupTimerRef?.timer.invalidate()
    }
} 