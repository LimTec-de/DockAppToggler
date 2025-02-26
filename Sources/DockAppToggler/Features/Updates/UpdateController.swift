import AppKit
import Sparkle
import UserNotifications

@MainActor
class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }
    
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Capture the values we need before starting the task
        let version = update.displayVersionString
        let isUserInitiated = state.userInitiated
        
        Task { @MainActor in
            // When an update alert will be presented, place the app in the foreground
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            // Set the update window to appear topmost
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.setSparkleWindowsTopmost()
                
                // Check again after a short delay to catch any windows that appear later
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.setSparkleWindowsTopmost()
                }
            }
            
            if !isUserInitiated {
                // Add a badge to the app's dock icon indicating one alert occurred
                NSApp.dockTile.badgeLabel = "1"
                
                // Post a user notification
                let content = UNMutableNotificationContent()
                content.title = "A new update is available"
                content.body = "Version \(version) is now available"
                
                let request = UNNotificationRequest(identifier: "UpdateCheck", content: content, trigger: nil)
                
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    Logger.error("Failed to add notification: \(error)")
                }
            }
        }
    }
    
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            // Clear the dock badge indicator for the update
            NSApp.dockTile.badgeLabel = ""
            
            // Dismiss active update notifications without await since it's not async
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["UpdateCheck"])
        }
    }
    
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            // Put app back in background when the user session for the update finished
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    // MARK: - Private Methods
    
    /// Sets all Sparkle-related windows to appear topmost
    private func setSparkleWindowsTopmost() {
        // Find all windows that belong to Sparkle
        for window in NSApp.windows {
            // Check if this is a Sparkle window by examining its title or delegate class
            if window.title.contains("Update") || 
               String(describing: type(of: window.delegate)).contains("Sparkle") {
                // Set window level to a very high level (above popUpMenu which is used by other UI elements)
                window.level = NSWindow.Level.popUpMenu + 10
                
                // Ensure window is ordered front
                window.orderFrontRegardless()
                
                // Set window collection behavior to stay visible and on active space
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                
                // Log that we found and modified a Sparkle window
                Logger.debug("Set Sparkle window topmost: \(window.title)")
            }
        }
    }
} 