import AppKit
import Carbon
import Darwin

// Add ProcessInfo extension at file scope
@MainActor private extension ProcessInfo {
    func machTaskForPID() -> mach_port_t {
        let pid = self.processIdentifier
        var task: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &task) { taskPtr in
            task_name_for_pid(mach_host_self(), pid_t(pid), taskPtr)
        }
        return result == KERN_SUCCESS ? task : 0
    }
}

// MARK: - Dock Watcher

@MainActor
class DockWatcher: NSObject, NSMenuDelegate {
    // Private backing storage
    private var _heartbeatTimer: Timer?
    private var _lastEventTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var _isEventTapActive: Bool = false
    private var _chooserControllers: [NSRunningApplication: WindowChooserController] = [:]
    private var _windowChooser: WindowChooserController?
    private var _menuShowTask: DispatchWorkItem?
    private var _memoryCleanupTimer: Timer?
    
    // Public MainActor properties
    @MainActor var heartbeatTimer: Timer? {
        get { _heartbeatTimer }
        set {
            _heartbeatTimer?.invalidate()
            _heartbeatTimer = newValue
        }
    }
    
    @MainActor var chooserControllers: [NSRunningApplication: WindowChooserController] {
        get { _chooserControllers }
        set { _chooserControllers = newValue }
    }
    
    @MainActor var windowChooser: WindowChooserController? {
        get { _windowChooser }
        set { _windowChooser = newValue }
    }
    
    @MainActor var menuShowTask: DispatchWorkItem? {
        get { _menuShowTask }
        set { _menuShowTask = newValue }
    }
    
    // Other properties
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var lastHoveredApp: NSRunningApplication?
    private var lastWindowOrder: [AXUIElement]?
    private let menuShowDelay: TimeInterval = 0.01
    private var lastClickTime: TimeInterval = 0
    private let clickDebounceInterval: TimeInterval = 0.3
    private var clickedApp: NSRunningApplication?
    private let dismissalMargin: CGFloat = 20.0
    private var lastMouseMoveTime: TimeInterval = 0
    private var isContextMenuActive: Bool = false
    private var contextMenuMonitor: Any?
    private var dockMenu: NSMenu?
    private var lastClickedDockIcon: NSRunningApplication?
    private var lastRightClickedDockIcon: NSRunningApplication?
    private var showingWindowChooserOnClick: Bool = false
    private var skipNextClickProcessing: Bool = false
    private let eventTimeoutInterval: TimeInterval = 5.0  // 5 seconds timeout
    
    // Add currentApp property
    @MainActor private var currentApp: NSRunningApplication?

    private var isMouseOverDock: Bool = false
    private var cleanupTimer: Timer?
    private let cleanupDelay: TimeInterval = 5.0 // 5 seconds after mouse leaves dock
    
    // Add property for memory cleanup timer
    private var memoryCleanupTimer: Timer?
    private let memoryThreshold: Double = 100.0 // MB
    
    // Add memory usage types
    private struct MemoryUsage {
        let resident: Double    // RSS (Resident Set Size)
        let virtual: Double     // Virtual Memory Size
        let compressed: Double  // Compressed Memory
        
        var total: Double {
            // Convert all values to MB for consistency
            let residentMB = resident
            let compressedMB = compressed / 1024.0  // Convert from bytes to MB
            return residentMB + compressedMB
        }
    }
    
    // Add memory thresholds as static properties
    private static let memoryThresholds = (
        warning: 80.0,     // MB - Start cleaning up
        critical: 120.0,   // MB - Force cleanup
        restart: 150.0     // MB - Restart app
    )
    
    // Add memory reporting function
    @MainActor private func reportMemoryUsage() -> Double {
        let pid = ProcessInfo.processInfo.processIdentifier
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        if result == size {
            return Double(info.pti_resident_size) / 1024.0 / 1024.0
        }
        return 0.0
    }
    
    // Add detailed memory reporting function
    @MainActor private func reportDetailedMemoryUsage() -> MemoryUsage {
        let pid = ProcessInfo.processInfo.processIdentifier
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        if result != size {
            return MemoryUsage(resident: 0, virtual: 0, compressed: 0)
        }
        
        // Use static divisors
        let mbDivisor = 1024.0 * 1024.0
        let gbDivisor = mbDivisor * 1024.0
        
        // Calculate values once
        let resident = Double(info.pti_resident_size) / mbDivisor
        let virtual = Double(info.pti_virtual_size) / gbDivisor
        
        // Get compressed memory more efficiently
        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let hostPort = mach_host_self()
        let vmResult: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size) { pointer in
                host_statistics64(hostPort,
                                HOST_VM_INFO64,
                                pointer,
                                &vmCount)
            }
        }
        
        guard vmResult == KERN_SUCCESS else {
            return MemoryUsage(resident: resident, virtual: virtual, compressed: 0)
        }
        
        let pagesize = getpagesize()
        let compressed = Double(vmStats.compressions) * Double(pagesize) / gbDivisor
        
        return MemoryUsage(resident: resident, virtual: virtual, compressed: compressed)
    }
    
    // Update setupMemoryMonitoring to use detailed memory reporting
    private func setupMemoryMonitoring() {
        memoryCleanupTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let usage = self.reportDetailedMemoryUsage()
                
                // Use static strings and format once
                Logger.debug("""
                    Memory Usage:
                    - Resident: \(String(format: "%.1f", usage.resident))MB
                    - Total: \(String(format: "%.1f", usage.total))MB
                    """)
                
                // Use static thresholds
                if usage.total > Self.memoryThresholds.restart {
                    Logger.warning("Memory usage critical (\(String(format: "%.1f", usage.total))MB). Restarting app...")
                    StatusBarController.performRestart()
                } else if usage.total > Self.memoryThresholds.critical {
                    Logger.warning("Memory usage high (\(String(format: "%.1f", usage.total))MB). Performing aggressive cleanup...")
                    await self.performAggressiveCleanup()
                } else if usage.total > Self.memoryThresholds.warning {
                    Logger.info("Memory usage elevated (\(String(format: "%.1f", usage.total))MB). Performing routine cleanup...")
                    await self.cleanupResources()
                }
            }
        }
    }
    
    override init() {
        super.init()
        setupEventTap()
        setupNotifications()
        setupDockMenuTracking()
        startHeartbeat()
        setupMemoryMonitoring()
    }
    
    @MainActor private func performAggressiveCleanup() async {
        // Force close any open menus
        windowChooser?.close()
        windowChooser = nil
        
        // Clear all caches
        autoreleasepool {
            // Clear all window controllers
            chooserControllers.values.forEach { controller in
                controller.prepareForReuse()
            }
            chooserControllers.removeAll()
            
            // Clear all tracking areas from window chooser
            if let chooser = windowChooser,
               let contentView = chooser.window?.contentView {
                contentView.trackingAreas.forEach { area in
                    contentView.removeTrackingArea(area)
                }
            }
        }
        
        // Perform main cleanup
        await cleanupResources()
        
        // Force a garbage collection cycle
        if #available(macOS 10.15, *) {
            await Task.yield()
            await Task.yield()
        }
        
        // If memory is still too high, restart the app
        let currentUsage = reportMemoryUsage()
        if currentUsage > memoryThreshold * 1.5 {
            Logger.warning("Memory still too high after cleanup. Initiating restart...")
            StatusBarController.performRestart()
        }
    }

    @MainActor private func cleanupResources() async {
        guard !isMouseOverDock else { return }
        
        Logger.debug("Starting memory cleanup")
        
        // Cancel pending operations
        menuShowTask?.cancel()
        menuShowTask = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        
        autoreleasepool {
            // Clear window chooser
            if let chooser = windowChooser {
                chooser.prepareForReuse()
                windowChooser = nil
            }
            
            // Clear app references
            currentApp = nil
            lastHoveredApp = nil
            clickedApp = nil
            lastClickedDockIcon = nil
            lastRightClickedDockIcon = nil
            lastWindowOrder = nil
            
            // Clear window controllers
            for controller in chooserControllers.values {
                if let window = controller.window {
                    // Clear tracking areas
                    window.contentView?.trackingAreas.forEach { area in
                        window.contentView?.removeTrackingArea(area)
                    }
                    
                    // Clear view hierarchy
                    window.contentView?.subviews.forEach { view in
                        view.layer?.removeAllAnimations()
                        view.layer?.removeFromSuperlayer()
                        view.removeFromSuperview()
                    }
                    
                    window.contentView = nil
                    window.delegate = nil
                }
                controller.prepareForReuse()
            }
            chooserControllers.removeAll()
        }
        
        // Disable updates during cleanup
        NSDisableScreenUpdates()
        
        // Clear graphics memory
        autoreleasepool {
            CATransaction.begin()
            CATransaction.flush()
            CATransaction.commit()
        }
        
        // Force garbage collection
        if #available(macOS 10.15, *) {
            await Task.yield()
        }
        
        NSEnableScreenUpdates()
        
        let memoryUsage = reportMemoryUsage()
        Logger.debug("Memory cleanup completed. Current usage: \(memoryUsage) MB")
    }
    
    deinit {
        cleanupEventTap()
        // Clean up event tap and resources (these are already nonisolated)
        cleanup()
        
        // Remove observer (this is thread-safe)
        NotificationCenter.default.removeObserver(self)
        
        // Schedule timer cleanup on main actor
        Task { @MainActor [weak self] in
            // Clean up timers
            self?.memoryCleanupTimer?.invalidate()
            self?.heartbeatTimer?.invalidate()
            self?.memoryCleanupTimer = nil
            self?.heartbeatTimer = nil
        }
    }
    
    private func startHeartbeat() {
        // Stop existing timer if any
        heartbeatTimer?.invalidate()
        
        // Create new timer
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                let currentTime = ProcessInfo.processInfo.systemUptime
                let timeSinceLastEvent = currentTime - self._lastEventTime
                
                if timeSinceLastEvent > self.eventTimeoutInterval {
                    Logger.warning("Event tap appears inactive (no events for \(Int(timeSinceLastEvent)) seconds). Reinitializing...")
                    await self.reinitializeEventTap()
                }
            }
        }
    }

    @MainActor private func reinitializeEventTap() async {
        Logger.info("Reinitializing event tap...")
        
        // Check memory usage first
        let currentUsage = reportMemoryUsage()
        
        if currentUsage > 100.0 {
            Logger.warning("Memory usage too high (\(String(format: "%.1f", currentUsage))MB). Performing full restart...")
            StatusBarController.performRestart()
            return
        }
        
        // If we're here, either memory check failed or usage is acceptable
        // Proceed with normal reinitialization
        //await cleanupResources()
        
        // Reset all state
        /*currentApp = nil
        lastHoveredApp = nil
        clickedApp = nil
        lastClickedDockIcon = nil
        lastRightClickedDockIcon = nil
        isContextMenuActive = false
        showingWindowChooserOnClick = false
        skipNextClickProcessing = false
        isMouseOverDock = false
        
        

        // Reinitialize core functionality
        setupEventTap()
        setupNotifications()
        setupDockMenuTracking)
        startHeartbeat()*/
        
        Logger.success("Event tap reinitialized successfully")
        _lastEventTime = ProcessInfo.processInfo.systemUptime
    }

    @MainActor private func updateLastEventTime() {
        _lastEventTime = ProcessInfo.processInfo.systemUptime
        _isEventTapActive = true
    }

    nonisolated private func cleanup() {
        // Move timer cleanup to MainActor
        Task { @MainActor in
            _memoryCleanupTimer?.invalidate()
            _memoryCleanupTimer = nil
        }
        
        // Clean up event tap synchronously
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        
        // Clean up run loop source synchronously
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        
        // Clean up references
        eventTap = nil
        runLoopSource = nil
        
        // Clean up timer and tasks on main thread
        _ = DispatchQueue.main.sync {
            Task { @MainActor in
                _menuShowTask?.cancel()
                _menuShowTask = nil
                _heartbeatTimer?.invalidate()
                _heartbeatTimer = nil
            }
        }
    }

    @MainActor private func cleanupWindows() {
        // Hide windows immediately
        for controller in _chooserControllers.values {
            controller.prepareForReuse()
            controller.close()
        }
        
        if let chooser = _windowChooser {
            chooser.prepareForReuse()
            chooser.close()
        }
        
        // Reset state variables
        lastHoveredApp = nil
        clickedApp = nil
        isMouseOverDock = false
        showingWindowChooserOnClick = false
        lastClickTime = 0
        lastMouseMoveTime = 0
        currentApp = nil
        lastWindowOrder = nil
        
        // Clear references
        _chooserControllers.removeAll()
        _windowChooser = nil
        
        // Cancel any pending tasks
        menuShowTask?.cancel()
        menuShowTask = nil
        
        // Force a cleanup cycle
        autoreleasepool {
            // Clear graphics memory
            CATransaction.begin()
            CATransaction.flush()
            CATransaction.commit()
        }
    }

    
    
     private func setupEventTap() {
        guard AccessibilityService.shared.requestAccessibilityPermissions() else {
            Logger.error("Failed to get accessibility permissions")
            return
        }
        
        // Optimize event mask creation by directly computing the bitmask
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue) |
                                     (1 << CGEventType.leftMouseDown.rawValue) |
                                     (1 << CGEventType.leftMouseUp.rawValue) |
                                     (1 << CGEventType.rightMouseDown.rawValue) |
                                     (1 << CGEventType.rightMouseUp.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            // Wrap the entire callback in autoreleasepool
            return autoreleasepool {
                guard let refconUnwrapped = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let watcher = Unmanaged<DockWatcher>.fromOpaque(refconUnwrapped).takeUnretainedValue()
                let location = event.location // Capture location before async work
                
                // Update last event time for heartbeat
                Task { @MainActor in
                    watcher.updateLastEventTime()
                    
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        await watcher.reinitializeEventTap()
                        return
                    }
                    
                    // Use another autoreleasepool for event processing
                    autoreleasepool {
                        switch type {
                        case .mouseMoved:
                            watcher.processMouseMovement(at: location)
                        case .leftMouseDown:
                            // Debounce clicks
                            let currentTime = ProcessInfo.processInfo.systemUptime
                            if currentTime - watcher.lastClickTime >= watcher.clickDebounceInterval {
                                watcher.lastClickTime = currentTime
                                
                                // Store the app being clicked for mouseUp handling
                                if let (app, _, iconCenter) = DockService.shared.findAppUnderCursor(at: location) {
                                    watcher.clickedApp = app
                                    watcher.lastClickedDockIcon = app
                                    watcher.skipNextClickProcessing = false
                                    
                                    // Show window chooser immediately on click
                                    let windows = AccessibilityService.shared.listApplicationWindows(for: app)
                                    if !windows.isEmpty {
                                        watcher.showingWindowChooserOnClick = true
                                        //watcher.windowChooser?.close()
                                        //watcher.windowChooser = nil
                                        watcher.windowChooser?.refreshMenu()
                                        watcher.displayWindowSelector(for: app, at: iconCenter, windows: windows)
                                        watcher.lastHoveredApp = app
                                    }
                                }
                            }
                        case .leftMouseUp:
                            if let app = watcher.clickedApp {
                                if watcher.processDockIconClick(app: app) {
                                    if !watcher.showingWindowChooserOnClick {
                                        //watcher.windowChooser?.close()
                                        //watcher.windowChooser = nil
                                        watcher.windowChooser?.refreshMenu()
                                    }
                                    watcher.clickedApp = nil
                                }
                                watcher.showingWindowChooserOnClick = false
                            }
                            watcher.clickedApp = nil
                        case .rightMouseDown:
                            if let (app, _, _) = DockService.shared.findAppUnderCursor(at: location) {
                                watcher.lastRightClickedDockIcon = app
                                watcher.windowChooser?.close()
                                watcher.windowChooser = nil
                                watcher.lastHoveredApp = nil
                            } else {
                                watcher.lastRightClickedDockIcon = nil
                            }
                        case .rightMouseUp:
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak watcher] in
                                watcher?.isContextMenuActive = false
                            }
                        default:
                            break
                        }
                    }
                }
                
                // Return the event without retaining it
                return Unmanaged.passUnretained(event)
            }
        }
        
        // Setup the event tap with explicit error handling
        if let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) {
            self.eventTap = eventTap
            
            // Create and add run loop source with explicit cleanup
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                self.runLoopSource = source
                
                // Enable the event tap
                CGEvent.tapEnable(tap: eventTap, enable: true)
                Logger.success("Event tap successfully created and enabled")
            } else {
                Logger.error("Failed to create run loop source")
                // Clean up the event tap if we couldn't create the source
                CFMachPortInvalidate(eventTap)
            }
        } else {
            Logger.error("Failed to create event tap")
        }
    }
    
    // Add cleanup method for event tap resources
    private nonisolated func cleanupEventTap() {
        autoreleasepool {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            
            eventTap = nil
            runLoopSource = nil
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("WindowChooserDidClose"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastHoveredApp = nil
            }
        }
        
        // Fix the app termination notification handler
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Capture the app reference outside the Task
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                // Create a new task with the captured value
                Task { @MainActor in
                    AccessibilityService.shared.clearWindowStates(for: app)
                }
            }
        }
    }
    
    private func displayWindowSelector(for app: NSRunningApplication, at point: CGPoint, windows: [WindowInfo]) {
        // For different app, always create a new chooser
        if app != currentApp {
            // Clean up existing chooser
            if let existingChooser = windowChooser {
                existingChooser.prepareForReuse()
                existingChooser.close()
            }
            windowChooser = nil
            
            // Create new chooser
            let chooser = WindowChooserController(
                at: point,
                windows: windows,
                app: app,
                callback: { window, isHideAction in
                    // Get the window info from our windows list to ensure we have the correct ID
                    if let windowInfo = windows.first(where: { $0.window == window }) {
                        if let windowID = windowInfo.cgWindowID {
                            // Store the CGWindowID in the AXUIElement
                            AXUIElementSetAttributeValue(window, Constants.Accessibility.windowIDKey, windowID as CFTypeRef)
                            Logger.debug("Callback: Set window ID \(windowID) on AXUIElement")
                        }
                        
                        if isHideAction {
                            // Hide the selected window
                            AccessibilityService.shared.hideWindow(window: window, for: app)
                        } else {
                            // First activate the app
                            app.activate(options: [.activateIgnoringOtherApps])
                            
                            // Then unminimize if needed
                            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                            
                            // Get window info for raising
                            var titleValue: AnyObject?
                            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                            let windowName = (titleValue as? String) ?? ""
                            let windowInfo = WindowInfo(window: window, name: windowName)
                            
                            // Raise window
                            AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                            
                            // Ensure window gets focus
                            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
                            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                            
                            // Final app activation to ensure focus
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                app.activate(options: [.activateIgnoringOtherApps])
                            }
                        }
                    }
                }
            )
            
            windowChooser = chooser
            currentApp = app
            chooser.window?.makeKeyAndOrderFront(nil)
        } else if let existingChooser = windowChooser {
            // Same app, update if windows changed
            if existingChooser.needsWindowUpdate(windows: windows) {
                existingChooser.updateWindows(windows, for: app, at: point)
            }
            // Always update position
            existingChooser.updatePosition(point)
            existingChooser.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    @MainActor private func processMouseMovement(at point: CGPoint) {
        // Debounce mouse move events
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard (currentTime - lastMouseMoveTime) >= Constants.Performance.mouseDebounceInterval else {
            return
        }
        lastMouseMoveTime = currentTime
        
        // Check if mouse is over any dock item
        if let (app, _, iconCenter) = DockService.shared.findAppUnderCursor(at: point) {
            isMouseOverDock = true
            
            // Don't show menu if context menu is active
            if isContextMenuActive {
                return
            }
            
            // Handle transition between apps
            if app != lastHoveredApp {
                // Get windows for the new app
                let windows = AccessibilityService.shared.listApplicationWindows(for: app)
                
                if !windows.isEmpty {
                    if let existingChooser = windowChooser {
                        // Reuse existing chooser for smooth transition
                        existingChooser.updateWindows(windows, for: app, at: iconCenter)
                        existingChooser.updatePosition(iconCenter)
                        lastHoveredApp = app
                        currentApp = app
                    } else {
                        // Create new chooser if none exists
                        displayWindowSelector(for: app, at: iconCenter, windows: windows)
                    }
                } else {
                    // No windows, close any existing chooser
                    windowChooser?.close()
                    windowChooser = nil
                    lastHoveredApp = nil
                }
            } else if let chooser = windowChooser {
                // Same app, just update position
                chooser.updatePosition(iconCenter)
            }
            return
        }
        
        // Mouse is not over dock - check if it's over the window chooser
        isMouseOverDock = false
        
        if let chooser = windowChooser,
           let window = chooser.window {
            let mouseLocation = NSEvent.mouseLocation
            let windowFrame = window.frame
            
            // Create expanded frame for hysteresis
            let expandedFrame = NSRect(
                x: windowFrame.minX - Constants.UI.menuDismissalMargin,
                y: windowFrame.minY - Constants.UI.menuDismissalMargin,
                width: windowFrame.width + Constants.UI.menuDismissalMargin * 2,
                height: windowFrame.height + Constants.UI.menuDismissalMargin * 2
            )
            
            // If mouse is outside both dock and expanded window frame, close the chooser
            if !expandedFrame.contains(mouseLocation) {
                Task { @MainActor in
                    // Double check position before closing
                    let currentLocation = NSEvent.mouseLocation
                    if !expandedFrame.contains(currentLocation) &&
                        DockService.shared.findAppUnderCursor(at: currentLocation) == nil {
                        chooser.prepareForReuse()
                        chooser.close()
                        windowChooser = nil
                        lastHoveredApp = nil
                        await cleanupResources()
                    }
                }
            }
        } else {
            // No window chooser is visible, reset state
            lastHoveredApp = nil
            isMouseOverDock = false
        }
    }
    
    private func processDockIconClick(app: NSRunningApplication) -> Bool {
        // Skip processing if flag is set
        if skipNextClickProcessing {
            skipNextClickProcessing = false  // Reset the flag
            return true
        }

        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")

        // Get all windows
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // Special handling for CGWindow-only applications (like NoMachine)
        let hasCGWindowsOnly = windows.allSatisfy { $0.cgWindowID != nil && $0.window == nil }
        if hasCGWindowsOnly {
            if app.isActive {
                Logger.debug("CGWindow-only app is active, hiding")
                app.hide()
                return true
            } else {
                Logger.debug("CGWindow-only app is not active, activating")
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
                
                // Force raise all windows
                for windowInfo in windows {
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
                return true
            }
        }

        // Special handling for Finder
        if app.bundleIdentifier == "com.apple.finder" {
            // Get all windows and check for visible, non-desktop windows
            let windows = AccessibilityService.shared.listApplicationWindows(for: app)
            let hasVisibleTopmostWindow = app.isActive && windows.contains { windowInfo in
                // Skip desktop window and app elements
                guard !windowInfo.isAppElement else { return false }
                
                // Get window role and subrole
                var roleValue: AnyObject?
                var subroleValue: AnyObject?
                let roleResult = AXUIElementCopyAttributeValue(windowInfo.window, kAXRoleAttribute as CFString, &roleValue)
                let subroleResult = AXUIElementCopyAttributeValue(windowInfo.window, kAXSubroleAttribute as CFString, &subroleValue)
                
                let role = (roleValue as? String) ?? ""
                let subrole = (subroleValue as? String) ?? ""
                
                // Check if window is visible and not minimized
                var minimizedValue: AnyObject?
                var hiddenValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                 (minimizedValue as? Bool == true)
                let isHidden = AXUIElementCopyAttributeValue(windowInfo.window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
                              (hiddenValue as? Bool == true)
                
                // Log window details for debugging
                Logger.debug("Window '\(windowInfo.name)' - role: \(role) subrole: \(subrole) minimized: \(isMinimized) hidden: \(isHidden)")
                
                // Consider window visible if:
                // 1. It's a regular window (AXWindow) with standard dialog subrole
                // 2. Not minimized or hidden
                // 3. Not the desktop window
                let isRegularWindow = role == "AXWindow" && subrole == "AXStandardWindow"
                let isVisible = !isMinimized && !isHidden && isRegularWindow
                
                return isVisible
            }
            
            Logger.debug("Finder active: \(app.isActive), has visible windows: \(hasVisibleTopmostWindow)")
            
            if hasVisibleTopmostWindow {
                Logger.debug("Finder has visible topmost windows, hiding")
                AccessibilityService.shared.hideAllWindows(for: app)
                return app.hide()
            } else {
                Logger.debug("Finder has no visible topmost windows, showing")
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
                
                // Only restore non-minimized windows
                let nonMinimizedWindows = windows.filter { windowInfo in
                    guard !windowInfo.isAppElement else { return false }
                    var minimizedValue: AnyObject?
                    return !(AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                            (minimizedValue as? Bool == true))
                }
                
                if nonMinimizedWindows.isEmpty {
                    // Open home directory in a new Finder window if no non-minimized windows
                    let homeURL = FileManager.default.homeDirectoryForCurrentUser
                    NSWorkspace.shared.open(homeURL)
                } else {
                    // Find the highlighted window from the window chooser if it exists
                    let highlightedWindow = windowChooser?.chooserView?.topmostWindow
                    
                    // Split windows into highlighted and others
                    let (highlighted, others) = nonMinimizedWindows.partition { windowInfo in
                        windowInfo.window == highlightedWindow
                    }
                    
                    // First restore all other windows
                    for windowInfo in others {
                        AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                    }
                    
                    // Then restore the highlighted window last to make it frontmost
                    if let lastWindow = highlighted.first {
                        // Add a small delay to ensure other windows are restored
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            AccessibilityService.shared.raiseWindow(windowInfo: lastWindow, for: app)
                        }
                    }
                }
                return true
            }
        }

        // If we only have the app entry (no real windows), handle launch
        if windows.count == 0 || windows[0].isAppElement {
            Logger.debug("App has no windows, launching")
            app.activate(options: [.activateIgnoringOtherApps])
            if let bundleURL = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            }
            return true
        }

        // Check if there's exactly one window and if it's minimized
        if windows.count == 1 && !windows[0].isAppElement {
            let window = windows[0].window
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                Logger.debug("Single minimized window found, restoring")
                // First unminimize
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                
                // Then activate and raise after a small delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    app.activate(options: [.activateIgnoringOtherApps])
                    // Create WindowInfo for the window
                    var titleValue: AnyObject?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    let windowName = (titleValue as? String) ?? app.localizedName ?? "Unknown"
                    let windowInfo = WindowInfo(
                        window: window,
                        name: windowName,
                        isAppElement: false
                    )
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
            }
        }
        
        // Initialize window states before checking app status
        AccessibilityService.shared.initializeWindowStates(for: app)
        
        // Check if there are any visible windows
        let hasVisibleWindows = windows.contains { windowInfo in
            AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }
        

        // Check if app is both active AND has visible windows or has only CGWindows and has visible windows
        if app.isActive && hasVisibleWindows {
            Logger.debug("App is active with visible windows or has only CGWindows with visible windows, hiding all windows")
            AccessibilityService.shared.hideAllWindows(for: app)
            return app.hide()
        } else if !hasVisibleWindows {
            Logger.debug("App has no visible windows, restoring last active window")
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
            
            // Get the highlighted window from the window chooser if it exists
            let highlightedWindow = windowChooser?.chooserView?.topmostWindow
            
            // Split windows into highlighted and others
            let (highlighted, others) = windows.partition { windowInfo in
                windowInfo.window == highlightedWindow
            }
            
            Task { @MainActor in
                // First unminimize all windows without raising them
                for windowInfo in windows {
                    var minimizedValue: AnyObject?
                    if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                       let isMinimized = minimizedValue as? Bool,
                       isMinimized {
                        AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
                    }
                }
                
                // Add delay before raising windows
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms delay
                
                // Then raise only the highlighted window if it exists
                if let lastWindow = highlighted.first {
                    AccessibilityService.shared.raiseWindow(windowInfo: lastWindow, for: app)
                } else if let firstWindow = windows.first {
                    // If no highlighted window, just raise the first one
                    AccessibilityService.shared.raiseWindow(windowInfo: firstWindow, for: app)
                }
            }
            return true
        } else {
            // Just activate the app if it has visible windows but isn't active
            Logger.debug("App has visible windows but isn't active, activating")
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
            return true
        }
    }
    
    // Add NSMenuDelegate methods
    func menuWillOpen(_ menu: NSMenu) {
        // Check if this is the Dock's context menu by checking its parent
        if menu.supermenu == dockMenu || menu == dockMenu {
            isContextMenuActive = true
            // Close any existing window chooser
            windowChooser?.close()
            windowChooser = nil
            lastHoveredApp = nil
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu.supermenu == dockMenu || menu == dockMenu {
            // Add a small delay to ensure menu is fully dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isContextMenuActive = false
            }
        }
    }
    
    private func setupDockMenuTracking() {
        // Get the Dock process
        if let dockApp = DockService.shared.findDockProcess() {
            // Get all menus from the Dock
            let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
            var menuBarValue: CFTypeRef?
            
            if AXUIElementCopyAttributeValue(axDock, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
               CFGetTypeID(menuBarValue!) == AXUIElementGetTypeID() {
                let menuBar = menuBarValue as! AXUIElement
                var menusValue: CFTypeRef?
                
                if AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &menusValue) == .success,
                   CFGetTypeID(menusValue!) == AXUIElementGetTypeID(),
                   let menus = menusValue as? [AXUIElement] {
                    // Get the Dock menu
                    for menu in menus {
                        var roleValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(menu, kAXRoleAttribute as CFString, &roleValue) == .success,
                           let role = roleValue as? String,
                           role == "AXMenu" {
                            var menuRef: AnyObject?
                            // Use AXMenuItemCopyAttributeValue instead
                            if AXUIElementCopyAttributeValue(menu, "AXMenu" as CFString, &menuRef) == .success,
                               let dockMenu = menuRef as? NSMenu {
                                self.dockMenu = dockMenu
                                dockMenu.delegate = self
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    private var isClosing: Bool = false
}