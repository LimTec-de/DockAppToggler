import AppKit
import ApplicationServices

@MainActor
class AppToggleService {
    static let shared = AppToggleService()
    
    private init() {}
    
    func toggleApp(_ bundleIdentifier: String) {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        
        guard let app = runningApps.first(where: { app in
            app.bundleIdentifier == bundleIdentifier
        }) else {
            Logger.debug("App not found")
            return
        }
        
        // Special handling for Finder
        if bundleIdentifier == "com.apple.finder" {
            if let frontmostApp = NSWorkspace.shared.frontmostApplication,
               frontmostApp == app {
                app.hide()
            } else {
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }
        
        Task {
            // Create an AXUIElement for the app
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            
            // Try to get windows through accessibility API first
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            
            if axResult == .success, 
               let windows = windowsRef as? [AXUIElement], 
               !windows.isEmpty {
                // App has accessibility windows
                Logger.debug("Found \(windows.count) AX windows for \(app.localizedName ?? "")")
                
                if let frontmostApp = NSWorkspace.shared.frontmostApplication,
                   frontmostApp == app {
                    // App is frontmost, hide it
                    app.hide()
                } else {
                    // App is not frontmost, show and activate it
                    app.unhide()
                    app.activate(options: [.activateIgnoringOtherApps])
                    
                    // Try to raise the first window
                    let windowInfo = WindowInfo(
                        window: windows[0],
                        name: app.localizedName ?? "Unknown",
                        isAppElement: false
                    )
                    await AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
                return
            }
            
            // Fallback to CGWindow list for visible windows
            let appWindows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let visibleWindows = appWindows.filter { window in
                guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                      let windowApp = runningApps.first(where: { $0.localizedName == ownerName }),
                      windowApp.bundleIdentifier == bundleIdentifier else {
                    return false
                }
                return true
            }
            
            if visibleWindows.isEmpty {
                // No visible windows, try to show the app
                app.unhide()
                
                // Create a basic WindowInfo for the app
                let windowInfo = WindowInfo(
                    window: axApp,
                    name: app.localizedName ?? "Unknown",
                    isAppElement: true
                )
                
                app.activate(options: [.activateIgnoringOtherApps])
                await AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
            } else {
                app.hide()
            }
        }
    }
} 