/// DockAppToggler: A macOS utility that enhances Dock functionality by providing window management
/// and app control features through Dock icon interactions.
///
/// Features:
/// - Window selection for apps with multiple windows
/// - Single-click to hide active apps
/// - Double-click to terminate active apps
/// - Modern UI with hover effects and animations

@preconcurrency import Foundation
import AppKit
import Carbon
import Sparkle
import Cocoa
import ApplicationServices
import UserNotifications
import ServiceManagement

// MARK: - Models

/// Information about a window, including its accessibility element and metadata
struct WindowInfo {
    let window: AXUIElement
    let name: String
    let isAppElement: Bool
    var cgWindowID: CGWindowID?
    var position: CGPoint?
    var size: CGSize?
    var bounds: CGRect?
    
    init(window: AXUIElement, 
         name: String, 
         isAppElement: Bool = false, 
         cgWindowID: CGWindowID? = nil,
         position: CGPoint? = nil,
         size: CGSize? = nil,
         bounds: CGRect? = nil) {
        self.window = window
        self.name = name
        self.isAppElement = isAppElement
        self.cgWindowID = cgWindowID
        self.position = position
        self.size = size
        self.bounds = bounds
    }
}

// MARK: - UI Components

// Update LoginItemManager class
@MainActor
class LoginItemManager {
    static let shared = LoginItemManager()
    
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.dockapptoggler"
    
    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Fallback for older macOS versions
            return false
        }
    }
    
    func setLoginItemEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.error("Failed to \(enabled ? "enable" : "disable") login item: \(error)")
            }
        } else {
            Logger.warning("Auto-start not supported on this macOS version")
        }
    }
}

// MARK: - Application Entry Point

// Add near the start of the application entry point
Logger.info("Starting Dock App Toggler...")

// Check command line arguments
let shouldSkipUpdateCheck = CommandLine.arguments.contains("--s")

// Initialize app components
let app = NSApplication.shared

// Run the accessibility check once at startup
_ = AccessibilityService.shared.requestAccessibilityPermissions()

// Create the shared updater controller - always create it, but control auto-check behavior
let sharedUpdater = SPUStandardUpdaterController(
    startingUpdater: !shouldSkipUpdateCheck,  // Only start the updater if not skipping
    updaterDelegate: nil,
    userDriverDelegate: UpdateController()
)

// Create and store all controllers to prevent deallocation
let appController = (
    watcher: DockWatcher(),
    statusBar: StatusBarController(updater: sharedUpdater),
    updater: sharedUpdater
)

// Configure the app to be a background application
app.setActivationPolicy(.accessory)

// Start the application
app.run()

// Add this new class for handling updates
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
}

// Add this extension near the top of the file with other extensions
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Add extension to check dark mode
extension NSAppearance {
    var isDarkMode: Bool {
        self.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// Update the NSBezierPath extension
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                // Convert quadratic curve to cubic curve
                let startPoint = path.currentPoint
                let controlPoint = points[0]
                let endPoint = points[1]
                
                // Calculate cubic control points from quadratic control point
                let cp1 = CGPoint(
                    x: startPoint.x + ((controlPoint.x - startPoint.x) * 2/3),
                    y: startPoint.y + ((controlPoint.y - startPoint.y) * 2/3)
                )
                let cp2 = CGPoint(
                    x: endPoint.x + ((controlPoint.x - endPoint.x) * 2/3),
                    y: endPoint.y + ((controlPoint.y - endPoint.y) * 2/3)
                )
                
                path.addCurve(to: endPoint, control1: cp1, control2: cp2)
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        
        return path
    }
}

// Update BubbleVisualEffectView class
class BubbleVisualEffectView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        
        // Create bubble shape with arrow
        let path = NSBezierPath()
        let bounds = self.bounds
        let radius: CGFloat = 6
        
        // Start from bottom center (arrow tip)
        let arrowTipX = bounds.midX
        let arrowTipY = Constants.UI.arrowOffset
        
        // Create the main rounded rectangle first, but exclude the bottom edge
        let rect = NSRect(x: bounds.minX,
                         y: bounds.minY + Constants.UI.arrowHeight,
                         width: bounds.width,
                         height: bounds.height - Constants.UI.arrowHeight)
        
        // Create custom path for rounded rectangle with partial bottom edge
        let roundedRect = NSBezierPath()
        
        // Start from the arrow connection point on the left
        roundedRect.move(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Draw left bottom corner and left side
        roundedRect.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 270,
                            endAngle: 180,
                            clockwise: true)
        
        // Left side and top-left corner
        roundedRect.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 180,
                            endAngle: 90,
                            clockwise: true)
        
        // Top edge
        roundedRect.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        
        // Top-right corner and right side
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 90,
                            endAngle: 0,
                            clockwise: true)
        roundedRect.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        
        // Right bottom corner
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 0,
                            endAngle: 270,
                            clockwise: true)
        
        // Bottom edge to arrow
        roundedRect.line(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Create arrow path
        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        arrowPath.line(to: NSPoint(x: arrowTipX, y: arrowTipY))
        arrowPath.line(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Combine paths
        path.append(roundedRect)
        path.append(arrowPath)
        
        // Create mask layer for the entire shape
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        self.layer?.mask = maskLayer
        
        // Add border layer only for the custom rounded rectangle path
        let borderLayer = CAShapeLayer()
        borderLayer.path = roundedRect.cgPath
        borderLayer.lineWidth = 0.5
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        
        // Remove any existing border layers
        self.layer?.sublayers?.removeAll(where: { $0.name == "borderLayer" })
        
        // Add new border layer
        borderLayer.name = "borderLayer"
        self.layer?.addSublayer(borderLayer)
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        
        // Update border color when appearance changes
        if let borderLayer = self.layer?.sublayers?.first(where: { $0.name == "borderLayer" }) as? CAShapeLayer {
            borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        }
    }
}

@MainActor
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

// Add near the top of the file with other extensions
extension Array {
    func partition(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var nonMatching: [Element] = []
        
        forEach { element in
            if predicate(element) {
                matching.append(element)
            } else {
                nonMatching.append(element)
            }
        }
        
        return (matching, nonMatching)
    }
}

// Add this extension to handle application restarts
extension NSApplication {
    static func restart(skipUpdateCheck: Bool = true) {
        guard let executablePath = Bundle.main.executablePath else {
            Logger.error("Failed to get executable path for restart")
            return
        }
        
        // Clean up resources before restart
        Logger.info("Preparing for in-place restart...")
        
        // Prepare arguments
        var args = [executablePath]
        if skipUpdateCheck {
            args.append("--s")
        }
        
        // Convert arguments to C-style
        let cArgs = args.map { strdup($0) } + [nil]
        
        // Execute the new process image
        Logger.info("Executing in-place restart...")
        execv(executablePath, cArgs)
        
        // If we get here, exec failed
        Logger.error("Failed to restart application: \(String(cString: strerror(errno)))")
        
        // Clean up if exec failed
        for ptr in cArgs where ptr != nil {
            free(ptr)
        }
    }
}

