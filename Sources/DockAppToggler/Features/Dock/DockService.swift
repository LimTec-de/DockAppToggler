import AppKit
import Carbon

// MARK: - Dock Service

@MainActor
class DockService {
    static let shared = DockService()
    private let workspace = NSWorkspace.shared
    
    private init() {}
    
    private let timeout: TimeInterval = 3.0 // 3 second timeout
    
    func getDockMagnificationSize() -> CGFloat {
        let defaults = UserDefaults.init(suiteName: "com.apple.dock")
        let magnificationEnabled = defaults?.bool(forKey: "magnification") ?? false
        if magnificationEnabled {
            let magnifiedSize = defaults?.double(forKey: "largesize") ?? 128.0
            return CGFloat(magnifiedSize + 20)
        }
        return Constants.UI.dockHeight
    }
    
    func findDockProcess() -> NSRunningApplication? {
        return workspace.runningApplications.first(where: { $0.bundleIdentifier == Constants.Identifiers.dockBundleID })
    }
    
    func findAppUnderCursor(at point: CGPoint) -> (app: NSRunningApplication, url: URL, iconCenter: CGPoint)? {
        // Early return if point is not near dock
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let dockHeight = getDockHeight()
        let magnificationHeight = getDockMagnificationSize()
        let maxDockHeight = max(dockHeight, magnificationHeight)
        
        // Check if point is within dock area (adding some padding for magnification)
        let dockAreaY = screen.frame.maxY - maxDockHeight - 20 // 20px padding
        if point.y < dockAreaY {
            return nil
        }

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
        
        if urlResult == .success,
           let urlRef = urlUntyped as? NSURL,
           let url = urlRef as URL? {
            
            // Find the corresponding running application
            if let app = findRunningApp(for: url) {
                return (app: app, url: url, iconCenter: iconCenter)
            }
        }
        
        return nil
    }
    
    private func findRunningApp(for url: URL) -> NSRunningApplication? {
        // First try standard bundle ID matching
        if let bundle = Bundle(url: url),
           let bundleId = bundle.bundleIdentifier,
           let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app
        }
        
        // Handle Wine applications
        if url.path.lowercased().hasSuffix(".exe") {
            let baseExeName = url.deletingPathExtension().lastPathComponent.lowercased()
            
            // Try exact name matches first
            if let exactMatch = workspace.runningApplications.first(where: { app in
                guard let processName = app.localizedName?.lowercased(),
                      app.activationPolicy == .regular else {
                    return false
                }
                return processName == baseExeName
            }) {
                return exactMatch
            }
            
            // Then try partial matches
            return workspace.runningApplications.first(where: { app in
                guard let processName = app.localizedName?.lowercased(),
                      app.activationPolicy == .regular else {
                    return false
                }
                return processName.contains(baseExeName) || processName.contains("wine")
            })
        }
        
        return nil
    }
    
    func performDockIconAction(app: NSRunningApplication, clickCount: Int64) -> Bool {
        // Always return false for right-clicks to let the Dock handle them
        if clickCount < 0 {
            Logger.info("Right-click detected, letting Dock handle it: \(app.localizedName ?? "Unknown")")
            return false
        }
        
        // Don't handle the click if the app is not active
        if !app.isActive {
            Logger.info("App not active, letting Dock handle click: \(app.localizedName ?? "Unknown")")
            return false
        }
        
        if clickCount == 2 {
            Logger.info("Double-click detected, terminating app: \(app.localizedName ?? "Unknown")")
            return app.terminate()
        } else {
            Logger.info("Single-click detected, hiding app: \(app.localizedName ?? "Unknown")")
            return app.hide()
        }
    }
    
    func toggleApp(_ bundleIdentifier: String) async throws {
        // Get app reference on main actor
        guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw DockServiceError.appNotFound
        }
        
        // Create a task with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(2.0 * 1_000_000_000))
                throw DockServiceError.timeout
            }
            
            // Add toggle task
            group.addTask { [app] in
                if app.isActive {
                    Logger.debug("Hiding app: \(app.localizedName ?? bundleIdentifier)")
                    if !app.hide() {
                        throw DockServiceError.operationFailed
                    }
                } else {
                    Logger.debug("Activating app: \(app.localizedName ?? bundleIdentifier)")
                    if !app.activate(options: [.activateIgnoringOtherApps]) {
                        throw DockServiceError.operationFailed
                    }
                }
            }
            
            // Wait for first completion or error
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                Logger.error("App toggle failed: \(error)")
                throw error
            }
        }
    }
    
    private func withTimeout<T: Sendable>(_ timeout: TimeInterval = 3.0, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            let operation = operation
            
            // Main operation task
            group.addTask { @Sendable in
                try await operation()
            }
            
            // Timeout task
            group.addTask { @Sendable in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                Logger.warning("Operation timed out after \(timeout) seconds")
                throw DockServiceError.timeout
            }
            
            // Wait for first completion
            do {
                guard let result = try await group.next() else {
                    throw DockServiceError.unknown
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
    
    // Add method to reset tracking state
    func resetDockTracking() {
        // Force the Dock to reset its tracking state
        if let dockApp = findDockProcess() {
            let pid = dockApp.processIdentifier
            let axElement = AXUIElementCreateApplication(pid)
            
            // Send a notification to reset tracking
            var value: CFTypeRef?  // Make this optional
            if AXUIElementCopyAttributeValue(axElement, "AXFocused" as CFString, &value) == .success {
                AXUIElementSetAttributeValue(axElement, "AXFocused" as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(axElement, "AXFocused" as CFString, false as CFTypeRef)
            }
        }
    }
    
    // Add method to get dock height
    func getDockHeight() -> CGFloat {
        // Get the dock's frame
        guard let dockFrame = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            return 70
        }
        
        let dockElement = AXUIElementCreateApplication(dockFrame)
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        // Get dock position and size
        guard AXUIElementCopyAttributeValue(dockElement, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(dockElement, kAXSizeAttribute as CFString, &size) == .success,
              let positionRef = position,
              let sizeRef = size,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return 70
        }
        
        var point = CGPoint.zero
        var dockSize = CGSize.zero
        
        // Force cast is safe here because we checked the type IDs above
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &dockSize)
        
        // Return dock height
        return dockSize.height
    }
    
    enum DockServiceError: Error {
        case timeout
        case appNotFound
        case operationFailed
        case unknown
    }
}

// Add Task timeout extension
extension Task where Success == Never, Failure == Never {
    static func timeout(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}