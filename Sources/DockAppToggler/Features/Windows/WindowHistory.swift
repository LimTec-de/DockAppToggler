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
    private let timerInterval: TimeInterval = 2.0 // Check every 2 seconds
    
    // Store window info and timestamp
    private struct HistoryEntry: Sendable {
        let window: WindowInfo
        let timestamp: Date
        let appBundleIdentifier: String
    }
    
    // Store recent windows with timestamps, grouped by app
    private var recentWindows: [String: [HistoryEntry]] = [:]
    
    private init() {
        setupActiveWindowTimer()
    }
    
    deinit {
        cleanupTimerRef?.timer.invalidate()
    }
    
    private func setupActiveWindowTimer() {
        Logger.debug("Setting up active window timer")
        let timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureActiveWindow()
            }
        }
        activeWindowTimer = timer
        cleanupTimerRef = SendableTimerRef(timer)  // Store in Sendable wrapper
    }
    
    private func captureActiveWindow() {
        // Get frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return
        }
        
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
        
        // Create WindowInfo and add to history
        let windowInfo = WindowInfo(
            window: windowElement,
            name: windowName,
            cgWindowID: nil,
            isAppElement: false
        )
        
        addWindow(windowInfo, for: frontApp)
    }
    
    /// Get recent windows for an app
    func getRecentWindows(for bundleIdentifier: String) -> [WindowInfo] {
        //Logger.debug("Getting recent windows for app: \(bundleIdentifier)")
        
        // Clean up non-existent windows first
        cleanupNonExistentWindows(for: bundleIdentifier)
        
        let windows = recentWindows[bundleIdentifier]?
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0.window } ?? []
        
        //Logger.debug("  - Found \(windows.count) valid recent windows")
        return windows
    }
    
    /// Get all recent windows across all apps
    func getAllRecentWindows() -> [WindowInfo] {
        //Logger.debug("Getting all recent windows")
        
        // Clean up non-existent windows for all apps
        for bundleId in recentWindows.keys {
            cleanupNonExistentWindows(for: bundleId)
        }
        
        let allWindows = recentWindows.values
            .flatMap { $0 }
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0.window }
            .prefix(maxHistorySize) // Limit to same max size as per-app history
        
        //Logger.debug("  - Found \(allWindows.count) valid recent windows")
        
        return Array(allWindows)
    }
    
    /// Add a window to history
    func addWindow(_ window: WindowInfo, for app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }
        
        Logger.debug("Adding window to history:")
        Logger.debug("  - App: \(app.localizedName ?? "Unknown")")
        Logger.debug("  - Window: \(window.name)")
        Logger.debug("  - ID: \(window.cgWindowID ?? 0)")
        
        // Verify window belongs to the specified app
        if let windowId = window.cgWindowID {
            guard verifyWindowOwnership(windowId: windowId, app: app) else {
                Logger.debug("  - Window ownership verification failed, skipping")
                return
            }
        }
        
        // Remove this window from any other app's history first by checking AX element equality
        for (otherBundleId, entries) in recentWindows {
            if otherBundleId != bundleId {
                if entries.contains(where: { isEqualAXElement($0.window.window, window.window) }) {
                    Logger.debug("  - Removing duplicate window entry from \(otherBundleId)")
                    recentWindows[otherBundleId]?.removeAll(where: { isEqualAXElement($0.window.window, window.window) })
                }
            }
        }
        
        // Create window info with bundle identifier
        let windowWithBundle = WindowInfo(
            window: window.window,
            name: window.name,
            cgWindowID: window.cgWindowID,
            isAppElement: window.isAppElement,
            bundleIdentifier: bundleId
        )
        
        // Get or create array for this app
        var appWindows = recentWindows[bundleId] ?? []
        
        // Check if window already exists by comparing AX elements
        if let existingIndex = appWindows.firstIndex(where: { isEqualAXElement($0.window.window, window.window) }) {
            // Update timestamp of existing entry instead of adding duplicate
            let updatedEntry = HistoryEntry(
                window: windowWithBundle,
                timestamp: Date(),
                appBundleIdentifier: bundleId
            )
            appWindows.remove(at: existingIndex)
            appWindows.insert(updatedEntry, at: 0)
            Logger.debug("  - Updated timestamp for existing window: \(window.name)")
        } else {
            // Add new entry
            let entry = HistoryEntry(
                window: windowWithBundle,
                timestamp: Date(),
                appBundleIdentifier: bundleId
            )
            appWindows.insert(entry, at: 0)
            Logger.debug("  - Added new window entry: \(window.name)")
        }
        
        // Trim to max size for this app
        if appWindows.count > maxHistorySize {
            let removed = appWindows.removeLast()
            Logger.debug("  - Removed oldest entry: \(removed.window.name)")
        }
        
        // Update the dictionary
        recentWindows[bundleId] = appWindows
        
        // Log current history state
        logCurrentHistory()
    }
    
    /// Verify that a window belongs to the specified application
    private func verifyWindowOwnership(windowId: CGWindowID, app: NSRunningApplication) -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]]
        
        guard let windowList = windowList else { return false }
        
        for windowInfo in windowList {
            guard let windowNumber = windowInfo[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = windowInfo[kCGWindowOwnerPID] as? pid_t else {
                continue
            }
            
            if windowNumber == windowId {
                return ownerPID == app.processIdentifier
            }
        }
        
        return false
    }
    
    /// Clear history for an app
    func clearHistory(for bundleIdentifier: String) {
        Logger.debug("Clearing history for app: \(bundleIdentifier)")
        let countBefore = recentWindows[bundleIdentifier]?.count ?? 0
        recentWindows.removeValue(forKey: bundleIdentifier)
        Logger.debug("  - Removed \(countBefore) entries")
    }
    
    /// Clear all history
    func clearAllHistory() {
        Logger.debug("Clearing all window history")
        let totalEntries = recentWindows.values.map { $0.count }.reduce(0, +)
        Logger.debug("  - Removing \(totalEntries) entries")
        recentWindows.removeAll()
    }
    
    /// Log current state of window history
    private func logCurrentHistory() {
        Logger.debug("Current window history state:")
        let totalEntries = recentWindows.values.map { $0.count }.reduce(0, +)
        Logger.debug("  Total entries: \(totalEntries)")
        
        for (bundleId, entries) in recentWindows {
            Logger.debug("  App: \(bundleId)")
            for (index, entry) in entries.enumerated() {
                let timeAgo = Date().timeIntervalSince(entry.timestamp)
                Logger.debug("    \(index + 1). \(entry.window.name) (added \(String(format: "%.1f", timeAgo))s ago)")
            }
        }
    }
    
    /// Remove windows that no longer exist from history
    private func cleanupNonExistentWindows(for bundleIdentifier: String) {
        guard var entries = recentWindows[bundleIdentifier] else { return }
        
        let countBefore = entries.count
        entries.removeAll { entry in
            // Check if window still exists using its AXUIElement
            var windowRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                entry.window.window,
                kAXRoleAttribute as CFString,
                &windowRef
            )
            
            // Verify we got a valid window reference and it's a window
            let exists = status == .success && 
                        windowRef != nil && 
                        (windowRef as? String) == "AXWindow"
            
            if !exists {
                Logger.debug("  - Removing non-existent window: \(entry.window.name)")
            }
            return !exists
        }
        
        if entries.count < countBefore {
            Logger.debug("  - Removed \(countBefore - entries.count) non-existent windows")
            recentWindows[bundleIdentifier] = entries
        }
    }
    
    /// Helper function to compare AXUIElement references
    private func isEqualAXElement(_ element1: AXUIElement, _ element2: AXUIElement) -> Bool {
        // First try direct pointer comparison
        if CFEqual(element1, element2) {
            return true
        }
        
        // If direct comparison fails, try comparing window IDs if available
        var windowID1: CFTypeRef?
        var windowID2: CFTypeRef?
        
        let success1 = AXUIElementCopyAttributeValue(
            element1,
            "AXWindowID" as CFString,
            &windowID1
        ) == .success
        
        let success2 = AXUIElementCopyAttributeValue(
            element2,
            "AXWindowID" as CFString,
            &windowID2
        ) == .success
        
        if success1 && success2,
           let id1 = (windowID1 as? NSNumber)?.uint32Value,
           let id2 = (windowID2 as? NSNumber)?.uint32Value {
            return id1 == id2
        }
        
        return false
    }
} 