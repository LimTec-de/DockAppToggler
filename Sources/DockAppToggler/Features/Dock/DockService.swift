import AppKit
import Carbon

// MARK: - Dock Service

@MainActor
class DockService {
    static let shared = DockService()
    private let workspace = NSWorkspace.shared
    
    private init() {}
    
    func getDockMagnificationSize() -> CGFloat {
        let defaults = UserDefaults.init(suiteName: "com.apple.dock")
        let magnificationEnabled = defaults?.bool(forKey: "magnification") ?? false
        if magnificationEnabled {
            let magnifiedSize = defaults?.double(forKey: "largesize") ?? 128.0
            return CGFloat(magnifiedSize)
        }
        return Constants.UI.dockHeight
    }
    
    func findDockProcess() -> NSRunningApplication? {
        return workspace.runningApplications.first(where: { $0.bundleIdentifier == Constants.Identifiers.dockBundleID })
    }
    
    func findAppUnderCursor(at point: CGPoint) -> (app: NSRunningApplication, url: URL, iconCenter: CGPoint)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementUntyped: AXUIElement?
        
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementUntyped) == .success,
              let element = elementUntyped else {
            return nil
        }
        
        // Get the element frame using position and size
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var iconCenter = point
        
        if AXUIElementCopyAttributeValue(element, Constants.Accessibility.frameKey, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, Constants.Accessibility.sizeKey, &sizeValue) == .success,
           CFGetTypeID(positionValue!) == AXValueGetTypeID(),
           CFGetTypeID(sizeValue!) == AXValueGetTypeID() {
            
            let position = positionValue as! AXValue
            let size = sizeValue as! AXValue
            
            var pointValue = CGPoint.zero
            var sizeValue = CGSize.zero
            
            if AXValueGetValue(position, .cgPoint, &pointValue) &&
               AXValueGetValue(size, .cgSize, &sizeValue) {
                iconCenter = CGPoint(x: pointValue.x + sizeValue.width/2,
                                   y: pointValue.y + sizeValue.height)
            }
        }
        
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let dockApp = findDockProcess(),
              pid == dockApp.processIdentifier else {
            return nil
        }
        
        // Get URL attribute
        var urlUntyped: CFTypeRef?
        let urlResult = AXUIElementCopyAttributeValue(element, Constants.Accessibility.urlKey, &urlUntyped)
        
        // Try standard URL method first
        if urlResult == .success,
           let urlRef = urlUntyped as? NSURL,
           let url = urlRef as URL? {
            
            // Check if it's a Wine application (.exe)
            if url.path.lowercased().hasSuffix(".exe") {
                let baseExeName = url.deletingPathExtension().lastPathComponent.lowercased()
                
                // Create a filtered list of potential Wine apps first
                let potentialWineApps = workspace.runningApplications.filter { app in
                    // Only check apps that are:
                    // 1. Active or regular activation policy
                    // 2. Have a name that matches our target or contains "wine"
                    guard let processName = app.localizedName?.lowercased(),
                        app.activationPolicy == .regular else {
                        return false
                    }
                    return processName.contains(baseExeName) || processName.contains("wine")
                }
                
                // First try exact name matches (most likely to be correct)
                if let exactMatch = potentialWineApps.first(where: { app in
                    app.localizedName?.lowercased() == baseExeName
                }) {
                    // Quick validation with a single window check
                    let windows = AccessibilityService.shared.listApplicationWindows(for: exactMatch)
                    if !windows.isEmpty {
                        return (app: exactMatch, url: url, iconCenter: iconCenter)
                    }
                }
                
                // Then try partial matches
                for wineApp in potentialWineApps {
                    // Cache window list to avoid multiple calls
                    let windows = AccessibilityService.shared.listApplicationWindows(for: wineApp)
                    
                    // Check if any window contains our target name
                    if windows.contains(where: { window in
                        window.name.lowercased().contains(baseExeName)
                    }) {
                        return (app: wineApp, url: url, iconCenter: iconCenter)
                    }
                }
            }
            
            // Standard bundle ID matching
            if let bundle = Bundle(url: url),
               let bundleId = bundle.bundleIdentifier,
               let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                return (app: app, url: url, iconCenter: iconCenter)
            }
        }
        
        return nil
    }
    
    func performDockIconAction(app: NSRunningApplication, clickCount: Int64) -> Bool {
        if app.isActive {
            if clickCount == 2 {
                Logger.info("Double-click detected, terminating app: \(app.localizedName ?? "Unknown")")
                return app.terminate()
            } else {
                Logger.info("Single-click detected, hiding app: \(app.localizedName ?? "Unknown")")
                return app.hide()
            }
        }
        
        Logger.info("Letting Dock handle click: \(app.localizedName ?? "Unknown")")
        return false
    }
}