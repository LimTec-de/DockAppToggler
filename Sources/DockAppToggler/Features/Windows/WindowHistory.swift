import AppKit

/// Manages history of recently used windows
@MainActor
class WindowHistory {
    // Singleton instance
    static let shared = WindowHistory()
    
    // Maximum number of windows to track per app
    private let maxHistorySize = 5
    
    // Store window info and timestamp
    private struct HistoryEntry: Sendable {
        let window: WindowInfo
        let timestamp: Date
        let appBundleIdentifier: String
    }
    
    // Store recent windows with timestamps, grouped by app
    private var recentWindows: [String: [HistoryEntry]] = [:]
    
    private init() {}
    
    /// Get recent windows for an app
    func getRecentWindows(for bundleIdentifier: String) -> [WindowInfo] {
        Logger.debug("Getting recent windows for app: \(bundleIdentifier)")
        let windows = recentWindows[bundleIdentifier]?
            .sorted { $0.timestamp > $1.timestamp } // Sort by most recent first
            .map { $0.window } ?? []
        
        Logger.debug("  - Found \(windows.count) recent windows")
        return windows
    }
    
    /// Get all recent windows across all apps
    func getAllRecentWindows() -> [WindowInfo] {
        Logger.debug("Getting all recent windows")
        let allWindows = recentWindows.values
            .flatMap { $0 }
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0.window }
        
        Logger.debug("  - Found \(allWindows.count) total recent windows")
        for (index, window) in allWindows.enumerated() {
            Logger.debug("    \(index + 1). \(window.name)")
        }
        
        return allWindows
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
        
        // Remove this window from any other app's history first
        for (otherBundleId, entries) in recentWindows {
            if otherBundleId != bundleId {
                if entries.contains(where: { $0.window.name == window.name }) {
                    Logger.debug("  - Removing duplicate window entry from \(otherBundleId)")
                    recentWindows[otherBundleId]?.removeAll(where: { $0.window.name == window.name })
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
        
        // Check if window with same title already exists
        if let existingIndex = appWindows.firstIndex(where: { $0.window.name == window.name }) {
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
} 