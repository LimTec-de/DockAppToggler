import AppKit
import Carbon

@MainActor
class AccessibilityService {
    static let shared = AccessibilityService()
    private var hasShownPermissionDialog = false
    private var isCheckingPermissions = false
    private var permissionCheckTimer: Timer?
    
    // Add static constant for the prompt key
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
    
    // Modify the window state struct to include order
    private var windowStates: [pid_t: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)]] = [:]
    
    private init() {}
    
    func requestAccessibilityPermissions() -> Bool {
        // First check if we already have permissions
        if AXIsProcessTrusted() {
            return true
        }
        
        // If not, and we haven't shown the dialog yet, request permissions
        if !hasShownPermissionDialog {
            hasShownPermissionDialog = true
            
            // Request permissions with prompt using static string
            let options = [Self.trustedCheckOptionPrompt: true] as CFDictionary
            let result = AXIsProcessTrustedWithOptions(options)
            
            // Start checking for permission changes if we don't have them yet
            if !result && !isCheckingPermissions {
                isCheckingPermissions = true
                startPermissionCheck()
            }
            
            return result
        }
        
        return false
    }
    
    private func startPermissionCheck() {
        // Invalidate existing timer if any
        permissionCheckTimer?.invalidate()
        
        // Create new timer on the main thread
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if AXIsProcessTrusted() {
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.isCheckingPermissions = false
                    await self.offerRestart()
                }
            }
        }
    }
    
    private func offerRestart() async {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Granted"
        alert.informativeText = "DockAppToggler needs to restart to function properly. Would you like to restart now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Get the path to the current executable
            if let executablePath = Bundle.main.executablePath {
                // Launch a new instance of the app
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                try? process.run()
                
                // Terminate the current instance
                NSApp.terminate(nil)
            }
        }
    }
    
    func listApplicationWindows(for app: NSRunningApplication) -> [WindowInfo] {
        var windows: [WindowInfo] = []
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        // Clean app name by removing special characters
        let cleanAppName = app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "Application"
        
        // First get all windows using CGWindow API
        let cgWindowListOptions = CGWindowListOption([.optionAll])
        let windowList = CGWindowListCopyWindowInfo(cgWindowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Store CGWindow information for debugging and matching
        var cgWindows: [(id: CGWindowID, name: String?, bounds: CGRect)] = []
        
        // Create a set of window IDs belonging to this app
        let cgWindowIDs = Set(windowList.compactMap { window -> CGWindowID? in
            // Check multiple identifiers to ensure we catch all windows
            let ownerPIDMatches = (window[kCGWindowOwnerPID as String] as? pid_t) == pid
            let ownerNameMatches = (window[kCGWindowOwnerName as String] as? String) == app.localizedName
            let bundleIDMatches = window["kCGWindowOwnerBundleID" as String] as? String == app.bundleIdentifier
            
            // Get window properties
            let windowName = window[kCGWindowName as String] as? String
            let windowLayer = window[kCGWindowLayer as String] as? Int32
            let windowAlpha = window[kCGWindowAlpha as String] as? Float
            let windowSharingState = window[kCGWindowSharingState as String] as? Int32
            
            // Check if the app name starts with any of the allowed prefixes
            let allowedPrefixes = ["NoMachine", "Parallels"]
            let trayAppPrefixes = ["KeePassXC", "Bitwarden"]
            let appName = app.localizedName ?? ""
            let specialWindowApp = allowedPrefixes.contains { appName.starts(with: $0) }
            let isTrayApp = trayAppPrefixes.contains { appName.starts(with: $0) }

            // Ensure the application is active
            guard app.isActive && isTrayApp || specialWindowApp else { return nil }
            
            // Filter conditions for regular windows:
            // 1. Must belong to the app
            // 2. Must have a valid window ID and non-empty name
            // 3. Must be on the normal window layer (0)
            // 4. Must have normal alpha (1.0)
            // 5. Must have normal sharing state (0) unless it's an allowed app
            guard (ownerPIDMatches || ownerNameMatches || bundleIDMatches),
                let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                let name = windowName,
                !name.isEmpty,
                windowLayer == 0,  // Normal window layer
                windowAlpha == nil || windowAlpha! > 0.9,  // Normal opacity
                specialWindowApp || windowSharingState == 0  // Modified sharing state check
            else {
                return nil
            }
            
            // Store window info for debugging
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let rect = CGRect(x: bounds["X"] ?? 0,
                                y: bounds["Y"] ?? 0,
                                width: bounds["Width"] ?? 0,
                                height: bounds["Height"] ?? 0)
                
                // Additional size check to filter out tiny windows (likely toolbars/panels)
                guard rect.width >= 200 && rect.height >= 100 else {
                    Logger.debug("Skipping small window '\(name)' (\(rect.width) x \(rect.height))")
                    return nil
                }
                
                cgWindows.append((
                    id: windowID,
                    name: name,
                    bounds: rect
                ))
            }
            
            return windowID
        })
        
        //Logger.debug("Found \(cgWindowIDs.count) CGWindows for \(cleanAppName)")
        
        // Get windows using Accessibility API
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
           let windowArray = windowsRef as? [AXUIElement] {
            
            //Logger.debug("Found \(windowArray.count) AX windows for \(cleanAppName)")
            
            for window in windowArray {
                var titleValue: AnyObject?
                var windowIDValue: AnyObject?
                var subroleValue: AnyObject?
                var roleValue: AnyObject?
                
                // Get all window attributes
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDValue)
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
                AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
                
                let title = (titleValue as? String) ?? cleanAppName
                let windowID = (windowIDValue as? NSNumber)?.uint32Value
                let subrole = subroleValue as? String
                let role = roleValue as? String
                
                // Skip only definitely invalid windows
                if role == "AXDesktop" && app.bundleIdentifier == "com.apple.finder" {
                    Logger.debug("Skipping Finder desktop window")
                    continue
                }
                
                var hiddenValue: AnyObject?
                let isHidden = AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
                              (hiddenValue as? Bool == true)
                
                var minimizedValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                (minimizedValue as? Bool == true)
                
                // More permissive window inclusion logic
                let isValidWindow = (cgWindowIDs.contains(windowID ?? 0) || // Either exists in CGWindow list
                                    isMinimized || // Or is minimized
                                    role == "AXWindow" || // Or is a standard window
                                    role == "AXDialog" || // Or is a dialog
                                    subrole == "AXStandardWindow") // Or has standard window subrole
                
                if !isHidden && isValidWindow {
                    // Get window position and size
                    var positionValue: CFTypeRef?
                    var sizeValue: CFTypeRef?
                    var position: CGPoint?
                    var size: CGSize?
                    
                    // Safely get position
                    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                       let posRef = positionValue {
                        // Check if it's an AXValue and has the right type
                        if CFGetTypeID(posRef) == AXValueGetTypeID() {
                            var point = CGPoint.zero
                            if AXValueGetValue(posRef as! AXValue, .cgPoint, &point) {
                                position = point
                            }
                        }
                    }
                    
                    // Safely get size
                    if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                       let sizeRef = sizeValue {
                        // Check if it's an AXValue and has the right type
                        if CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                            var windowSize = CGSize.zero
                            if AXValueGetValue(sizeRef as! AXValue, .cgSize, &windowSize) {
                                size = windowSize
                            }
                        }
                    }
                    
                    Logger.debug("Adding window: '\(title)' ID: \(windowID ?? 0) role: \(role ?? "none") subrole: \(subrole ?? "none") minimized: \(isMinimized) position: \(position?.debugDescription ?? "unknown") size: \(size?.debugDescription ?? "unknown")")
                    
                    // Create window info with all available data
                    let windowInfo = WindowInfo(
                        window: window,
                        name: title.isEmpty ? cleanAppName : title,
                        cgWindowID: windowID,
                        isCGWindowOnly: false,
                        isAppElement: false,
                        bundleIdentifier: app.bundleIdentifier,
                        position: position,
                        size: size,
                        bounds: getWindowBounds(window)
                    )
                    windows.append(windowInfo)
                } else {
                    Logger.debug("Skipping window: '\(title)' - hidden: \(isHidden), valid: \(isValidWindow), role: \(role ?? "none"), subrole: \(subrole ?? "none")")
                }
            }
        }
        
        // If we found CGWindows but no AX windows, add just the app itself
        if windows.isEmpty && !cgWindows.isEmpty {
            Logger.debug("CGWindow-only application detected, adding app element")
            let appWindowInfo = WindowInfo(
                window: axApp,
                name: cleanAppName,
                cgWindowID: nil,
                isCGWindowOnly: true,
                isAppElement: true,
                bundleIdentifier: app.bundleIdentifier,
                position: nil,
                size: nil,
                bounds: nil
            )
            windows.append(appWindowInfo)
        }
        
        // If no windows were found at all, add the app itself
        if windows.isEmpty {
            let appWindowInfo = WindowInfo(
                window: axApp,
                name: cleanAppName,
                cgWindowID: nil,
                isCGWindowOnly: false,
                isAppElement: true,
                bundleIdentifier: app.bundleIdentifier,
                position: nil,
                size: nil,
                bounds: nil
            )
            windows.append(appWindowInfo)
        }
        
        // Sort windows and log the final count
        let sortedWindows = windows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Logger.debug("Found \(sortedWindows.count) valid windows for \(cleanAppName)")
        
        return sortedWindows
    }

    private func createWindowInfo(for window: AXUIElement, app: NSRunningApplication, index: Int) -> WindowInfo? {
        var windowIDRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDRef)
        
        // Get window title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let windowTitle = (titleRef as? String) ?? ""
        
        // Skip windows with no ID or empty titles
        guard result == .success,
              let numRef = windowIDRef,
              let number = numRef as? NSNumber,
              !windowTitle.isEmpty else {
            return nil
        }
        
        let _ = number.uint32Value  // Explicitly ignore
        let windowName = windowTitle
        //Logger.success("Adding window: '\(windowName)' ID: \(windowID)")
        return WindowInfo(window: window, name: windowName)
    }
    
    private func createFallbackWindowInfo(for app: NSRunningApplication, index: Int) -> WindowInfo? {
        let appWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let matchingWindows = appWindows.filter { windowInfo -> Bool in
            guard let pid = windowInfo[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let layer = windowInfo[kCGWindowLayer] as? Int32,
                  layer == kCGNormalWindowLevel else {
                return false
            }
            return true
        }
        
        guard index < matchingWindows.count,
              let _ = matchingWindows[index][kCGWindowNumber] as? CGWindowID else {
            return nil
        }
        
        // Create AXUIElement for the window
        let window = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get the actual window name from CGWindowListCopyWindowInfo
        let windowTitle = matchingWindows[index][kCGWindowName as CFString] as? String
        let windowName = windowTitle ?? "\(app.localizedName ?? "Window") \(index + 1)"
        
        //Logger.success("Adding window (fallback): '\(windowName)' ID: \(windowID)")
        return WindowInfo(window: window, name: windowName)
    }
    
    func raiseWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== RAISING WINDOW/APP ===")
        Logger.debug("Raising - Name: \(windowInfo.name), IsAppElement: \(windowInfo.isAppElement)")

        // Add window to history before raising
        /*Task { @MainActor in
            WindowHistory.shared.addWindow(windowInfo, for: app)
        }*/

        if windowInfo.isAppElement {
            // For app elements, just activate the application
            app.activate(options: [.activateIgnoringOtherApps])
            Logger.debug("Activated application directly")
        } else {
            // Existing window raising logic
            // Get the window's owner PID
            var pid: pid_t = 0
            AXUIElementGetPid(windowInfo.window, &pid)
            
            // First try using CGWindow APIs if we have a window ID
            if let windowID = windowInfo.cgWindowID {
                Logger.debug("Using CGWindow APIs with ID: \(windowID)")
                raiseCGWindow(windowID: windowID, ownerPID: pid)
            } else {
                Logger.debug("No CGWindowID available, using AX APIs")
                // Unminimize first if needed
                AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                
                // Then raise the window
                AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
            }
            
            // Activate the app
            app.activate(options: [.activateIgnoringOtherApps])
        }
        
        Logger.debug("=== RAISING COMPLETE ===")
        
        // Signal completion
        Task { @MainActor in
            NotificationCenter.default.post(name: NSNotification.Name("WindowRaiseComplete"), object: nil)
        }
    }

    // Move raiseWindowWithCGWindow inside AccessibilityService as a private method
    private func raiseCGWindow(windowID: CGWindowID, ownerPID: pid_t) {
        // Get current window list
        let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Find our window
        guard let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) else {
            return
        }
        
        // Get window owner PID
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            return
        }
        
        // Try multiple methods to raise the window
        
        // 1. Activate the app
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            app.activate(options: [.activateIgnoringOtherApps])
            usleep(5000)
        }
        
        // 2. Try to reorder window list
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .optionIncludingWindow)
        let _ = CGWindowListCopyWindowInfo(options, windowID)
        
        // 3. Try to bring window to front using window list manipulation
        let windowArray = [windowID] as CFArray
        let _ = CGWindowListCreateDescriptionFromArray(windowArray)
        
        Logger.debug("Attempted to raise window \(windowID) using multiple methods")
    }
    
    func hideWindow(window: AXUIElement, for app: NSRunningApplication) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        
        // Special handling for Finder
        let isFinderApp = app.bundleIdentifier == "com.apple.finder"
        
        // Get window role and subrole for Finder-specific checks
        var roleValue: AnyObject?
        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
        let role = roleValue as? String
        let subrole = subroleValue as? String
        
        // Check if this is a CGWindow-only application
        var windowsRef: CFTypeRef?
        let hasAXWindows = AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowsKey, &windowsRef) == .success &&
                          (windowsRef as? [AXUIElement])?.isEmpty == false
        
        // Check if this is the app element and if the hidden attribute is settable
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(window, kAXHiddenAttribute as CFString, &isSettable)
        
        // For Finder, we need special handling
        if isFinderApp {
            // Skip desktop window
            if role == "AXDesktop" {
                Logger.debug("Skipping Finder desktop window")
                return
            }
            
            // For Finder windows, try multiple approaches
            var success = false
            
            // First try setting hidden attribute
            if settableResult == .success && isSettable.boolValue {
                success = AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef) == .success
            }
            
            // If that fails, try minimizing
            if !success {
                success = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef) == .success
            }
            
            // If both fail, try hiding the app
            if !success {
                app.hide()
            }
            
            return
        }
        
        // For non-Finder apps, use the original logic
        if pid == app.processIdentifier && (!hasAXWindows || settableResult != .success || !isSettable.boolValue) {
            Logger.debug("Hiding entire application: \(app.localizedName ?? "Unknown")")
            app.hide()
        } else {
            Logger.debug("Hiding individual window")
            AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef)
        }
    }
    
    func checkWindowVisibility(_ window: AXUIElement) -> Bool {
        // Get window role and subrole
        var roleValue: AnyObject?
        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
        let role = roleValue as? String
        let subrole = subroleValue as? String
        
        // Skip desktop window
        if role == "AXDesktop" {
            return false
        }
        
        // Check hidden state
        var hiddenValue: AnyObject?
        let hiddenResult = AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue)
        let isHidden = (hiddenResult == .success && (hiddenValue as? Bool == true))
        
        // Check minimized state
        var minimizedValue: AnyObject?
        let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        let isMinimized = (minimizedResult == .success && (minimizedValue as? Bool == true))
        
        // Check if window is a standard window
        let isStandardWindow = role == "AXWindow" && subrole == "AXStandardWindow"
        
        // A window is considered visible only if:
        // 1. It's a standard window
        // 2. Not hidden
        // 3. Not minimized
        return isStandardWindow && !isHidden && !isMinimized
    }
    
    func hideAllWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        Task<Void, Never> { @MainActor in
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            
            guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                return
            }

            Logger.debug("test1")
            
            var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
            for (index, window) in windows.enumerated() {
                let wasVisible = checkWindowVisibility(window)
                Logger.debug("test2: \(wasVisible)")
                states.append((window: window,
                             wasVisible: wasVisible,
                             order: index,
                             stackOrder: index))
            }
            
            // Update window operations with MainActor isolation
            await executeWindowOperationsInBatches(windows) { @MainActor window in
                let _ = AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef)
            }
            
            windowStates[pid] = states
        }
    }
    
    func restoreAllWindows(for app: NSRunningApplication) {
        Logger.debug("restoreAllWindows called for: \(app.localizedName ?? "Unknown")")
        let pid = app.processIdentifier
        let isFinderApp = app.bundleIdentifier == "com.apple.finder"
        
        Task<Void, Never> { @MainActor in
            // Get current windows if no states are stored
            if windowStates[pid] == nil {
                let axApp = AXUIElementCreateApplication(pid)
                var windowsRef: CFTypeRef?
                
                if AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
                   let windows = windowsRef as? [AXUIElement] {
                    var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
                    
                    for (index, window) in windows.enumerated() {
                        // Skip desktop window for Finder
                        if isFinderApp {
                            var roleValue: AnyObject?
                            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
                            if roleValue as? String == "AXDesktop" {
                                continue
                            }
                        }
                        
                        // Only include non-minimized windows
                        var minimizedValue: AnyObject?
                        let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                        (minimizedValue as? Bool == true)
                        
                        if !isMinimized {
                            states.append((window: window,
                                         wasVisible: true,
                                         order: index,
                                         stackOrder: index))
                        }
                    }
                    windowStates[pid] = states
                }
            }
            
            guard let states = windowStates[pid] else {
                Logger.warning("No window states found for app with pid: \(pid)")
                return
            }
            
            Logger.info("Restoring windows for app: \(app.localizedName ?? "Unknown")")
            Logger.info("Total window states: \(states.count)")
            
            // For Finder, ensure app is activated first
            if isFinderApp {
                app.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
            }
            
            // First pass: unhide all windows (they're already non-minimized)
            for state in states {
                // For Finder, try multiple approaches
                if isFinderApp {
                    // First try unhiding
                    var success = AXUIElementSetAttributeValue(state.window, kAXHiddenAttribute as CFString, false as CFTypeRef) == .success
                    
                    // If that fails, try unminimizing
                    if !success {
                        success = AXUIElementSetAttributeValue(state.window, kAXMinimizedAttribute as CFString, false as CFTypeRef) == .success
                    }
                    
                    // If either succeeded, raise the window
                    if success {
                        AXUIElementPerformAction(state.window, kAXRaiseAction as CFString)
                    }
                } else {
                    AXUIElementSetAttributeValue(state.window, kAXHiddenAttribute as CFString, false as CFTypeRef)
                }
                try? await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
            }
            
            // Give windows time to restore
            try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
            
            // Second pass: only raise the last window
            if let lastState = states.last {
                let windowInfo = WindowInfo(window: lastState.window, name: "")  // Name not needed for raising
                raiseWindow(windowInfo: windowInfo, for: app)
            }
            
            // Final activation of the app
            app.activate(options: [.activateIgnoringOtherApps])
            
            // Clear the stored states
            windowStates.removeValue(forKey: pid)
            Logger.info("Window restoration completed")
        }
    }
    
    // Fix the clearWindowStates method
    nonisolated func clearWindowStates(for app: NSRunningApplication) {
        // Use @unchecked Sendable to bypass the Sendable check
        Task<Void, Never> { @MainActor [self] in 
            self.windowStates.removeValue(forKey: app.processIdentifier)
        }
    }
    
    // Add a new method to get window stacking order
    private func determineWindowStackOrder(for app: NSRunningApplication) -> [CGWindowID: Int] {
        var stackOrder: [CGWindowID: Int] = [:]
        
        // Get all windows in current stacking order
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return stackOrder
        }
        
        // Create mapping of window IDs to their stacking order
        for (index, windowInfo) in windowList.enumerated() {
            guard let pid = windowInfo[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else {
                continue
            }
            stackOrder[windowID] = index
        }
        
        return stackOrder
    }
    
    func initializeWindowStates(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        // Skip if we already have states for this app
        guard windowStates[pid] == nil else { return }
        
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        
        // Get window stacking order
        let stackOrder = determineWindowStackOrder(for: app)
        var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
        
        for (index, window) in windows.enumerated() {
            // Check if window is minimized
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            // Only store non-minimized windows
            if !isMinimized {
                // Get window ID for stack order
                var windowIDValue: AnyObject?
                if AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDValue) == .success,
                   let windowID = (windowIDValue as? NSNumber)?.uint32Value {
                    states.append((
                        window: window,
                        wasVisible: true,
                        order: index,
                        stackOrder: stackOrder[windowID] ?? index
                    ))
                }
            }
            
            Logger.debug("Window \(index) initial state - minimized: \(isMinimized), hidden: \(checkWindowHidden(window)), visible: \(checkWindowVisibility(window))")
        }
        
        windowStates[pid] = states
    }
    
    // Helper method to check hidden state
    private func checkWindowHidden(_ window: AXUIElement) -> Bool {
        var hiddenValue: AnyObject?
        return AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
               (hiddenValue as? Bool == true)
    }
    
    // Add helper method to check if a window is the Finder desktop
    private func isFinderDesktop(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        // This method is no longer needed as we filter by role instead
        return false
    }
    
    // Update the processBatchedWindows method to handle async operations correctly
    private func executeWindowOperationsInBatches(_ windows: [AXUIElement], operation: @MainActor @escaping (AXUIElement) async -> Void) async {
        let batchSize = Constants.Performance.maxBatchSize
        
        // Process windows in batches
        for batch in stride(from: 0, to: windows.count, by: batchSize) {
            let end = min(batch + batchSize, windows.count)
            let currentBatch = Array(windows[batch..<end])
            
            // Process each window in the batch
            for window in currentBatch {
                // Execute the operation directly since we're already on MainActor
                await operation(window)
            }
            
            // Add delay between batches if needed
            if end < windows.count {
                try? await Task.sleep(nanoseconds: UInt64(Constants.Performance.minimumWindowRestoreDelay * 1_000_000_000))
            }
        }
    }

    func minimizeWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== MINIMIZING WINDOW ===")
        Logger.debug("Minimizing window - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        if let cgWindowID = windowInfo.cgWindowID {
            // Use CGWindow APIs for minimize
            minimizeWindowWithCGWindow(windowID: cgWindowID)
        } else {
            // Fallback to AX APIs
            AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }
        
        Logger.debug("=== MINIMIZE COMPLETE ===")
    }

    func closeWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== CLOSING WINDOW ===")
        Logger.debug("Closing window - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        if let cgWindowID = windowInfo.cgWindowID {
            // Use CGWindow APIs for close
            closeWindowWithCGWindow(windowID: cgWindowID)
        } else {
            // Fallback to AX APIs
            AXUIElementPerformAction(windowInfo.window, Constants.Accessibility.closeKey)
        }
        
        Logger.debug("=== CLOSE COMPLETE ===")
    }

    private func minimizeWindowWithCGWindow(windowID: CGWindowID) {
        Logger.debug("Attempting to minimize window with ID: \(windowID)")
        
        // Get the list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? else {
            Logger.debug("❌ Unable to retrieve window list")
            return
        }
        
        // Find our target window info
        guard let targetWindow = (windowList as? [[String: Any]])?.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let ownerPID = targetWindow[kCGWindowOwnerPID as String] as? pid_t,
              let targetTitle = targetWindow[kCGWindowName as String] as? String else {
            Logger.debug("❌ Could not find target window info")
            return
        }
        
        // Create AXUIElement for the application
        let appRef = AXUIElementCreateApplication(ownerPID)
        
        // Get the list of windows
        var windowsRef: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard windowResult == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            Logger.debug("❌ No accessible windows found for PID \(ownerPID)")
            return
        }
        
        // Try to find matching window by title and PID
        for window in windowArray {
            var titleRef: CFTypeRef?
            var pid: pid_t = 0
            
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let pidResult = AXUIElementGetPid(window, &pid)
            
            if titleResult == .success,
               pidResult == .success,
               let title = titleRef as? String,
               title == targetTitle && pid == ownerPID {
                
                Logger.debug("Found matching window, minimizing without animation")
                
                // Get current window position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                
                // Store original position and size
                if CFGetTypeID(positionRef!) == AXValueGetTypeID(),
                   CFGetTypeID(sizeRef!) == AXValueGetTypeID() {
                    let posValue = positionRef as! AXValue
                    let sizeValue = sizeRef as! AXValue
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(posValue, .cgPoint, &position)
                    AXValueGetValue(sizeValue, .cgSize, &size)
                    
                    // Set minimized state directly without animation
                    let minimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    Logger.debug(minimizeResult == .success ? "✓ Window minimized successfully" : "❌ Failed to minimize window")
                } else {
                    // Fallback to standard minimization if we can't get position/size
                    let minimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    Logger.debug(minimizeResult == .success ? "✓ Window minimized using fallback method" : "❌ Failed to minimize window")
                }
                return
            }
        }
        
        Logger.debug("❌ No matching window found")
    }

    private func closeWindowWithCGWindow(windowID: CGWindowID) {
        Logger.debug("Attempting to close window with ID: \(windowID)")
        
        // Get the list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? else {
            Logger.debug("❌ Unable to retrieve window list")
            return
        }
        
        // Find our target window info
        guard let targetWindow = (windowList as? [[String: Any]])?.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let ownerPID = targetWindow[kCGWindowOwnerPID as String] as? pid_t,
              let targetTitle = targetWindow[kCGWindowName as String] as? String,
              let targetBounds = targetWindow[kCGWindowBounds as String] as? [String: CGFloat] else {
            Logger.debug("❌ Could not find target window info")
            return
        }
        
        let targetRect = CGRect(x: targetBounds["X"] ?? 0,
                               y: targetBounds["Y"] ?? 0,
                               width: targetBounds["Width"] ?? 0,
                               height: targetBounds["Height"] ?? 0)
        
        Logger.debug("Found target window - Title: '\(targetTitle)', PID: \(ownerPID), Bounds: \(targetRect)")
        
        // Create AXUIElement for the application
        let appRef = AXUIElementCreateApplication(ownerPID)
        
        // Get the list of windows
        var windowsRef: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard windowResult == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            Logger.debug("❌ No accessible windows found for PID \(ownerPID)")
            return
        }
        
        Logger.debug("Found \(windowArray.count) windows for application")
        
        // Try to find matching window by title, bounds, and PID
        for window in windowArray {
            var titleRef: CFTypeRef?
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pid: pid_t = 0
            
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let positionResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
            let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
            let pidResult = AXUIElementGetPid(window, &pid)
            
            if titleResult == .success,
               positionResult == .success,
               sizeResult == .success,
               pidResult == .success,
               let title = titleRef as? String,
               let positionValue = positionRef as! AXValue?,
               let sizeValue = sizeRef as! AXValue? {
                
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue, .cgPoint, &position)
                AXValueGetValue(sizeValue, .cgSize, &size)
                let windowRect = CGRect(origin: position, size: size)
                
                Logger.debug("Checking window - Title: '\(title)', PID: \(pid), Bounds: \(windowRect)")
                
                if title == targetTitle && windowRect.equalTo(targetRect) && pid == ownerPID {
                    Logger.debug("Found matching window")
                    
                    // Try to get the close button
                    var closeButtonRef: CFTypeRef?
                    let buttonResult = AXUIElementCopyAttributeValue(window, Constants.Accessibility.closeButtonAttribute, &closeButtonRef)
                    
                    if buttonResult == .success,
                       let closeButton = closeButtonRef as! AXUIElement? {
                        Logger.debug("Found close button, attempting to press")
                        let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                        Logger.debug(pressResult == .success ? "✓ Window closed successfully" : "❌ Failed to press close button")
                        return
                    } else {
                        Logger.debug("❌ No close button found, trying direct close")
                        // Fallback to direct close
                        let closeResult = AXUIElementPerformAction(window, Constants.Accessibility.closeKey)
                        Logger.debug(closeResult == .success ? "✓ Window closed successfully" : "❌ Failed to close window")
                    }
                    return
                }
            }
        }
        
        Logger.debug("❌ No matching window found")
    }

    @MainActor
    func activateApp(_ app: NSRunningApplication) {
        // Get all windows before activating
        let windows = listApplicationWindows(for: app)
        
        // Activate the app
        app.unhide()
        app.activate(options: [.activateIgnoringOtherApps])
        
        // Add first non-app-element window to history if available
        /*if let firstWindow = windows.first(where: { !$0.isAppElement }) {
            WindowHistory.shared.addWindow(firstWindow, for: app)
        } else if let appElement = windows.first {
            // Fallback to app element if no regular windows
            WindowHistory.shared.addWindow(appElement, for: app)
        }*/
    }
}

// Add helper function to get window bounds
private func getWindowBounds(_ window: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    
    guard AXUIElementCopyAttributeValue(window, Constants.Accessibility.frameKey, &positionValue) == .success,
          AXUIElementCopyAttributeValue(window, Constants.Accessibility.sizeKey, &sizeValue) == .success,
          CFGetTypeID(positionValue!) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue!) == AXValueGetTypeID() else {
        return nil
    }
    
    var position = CGPoint.zero
    var size = CGSize.zero
    
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
        return nil
    }
    
    return CGRect(origin: position, size: size)
}