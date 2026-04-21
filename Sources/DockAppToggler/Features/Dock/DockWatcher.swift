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
    private struct RememberedFrontmostWindow {
        let cgWindowID: CGWindowID?
        let name: String
    }

    // Private backing storage
    private var _heartbeatTimer: Timer?
    private var _lastEventTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var _isEventTapActive: Bool = false
    private var _chooserControllers: [NSRunningApplication: WindowChooserController] = [:]
    private var _windowChooser: WindowChooserController?
    private var _menuShowTask: DispatchWorkItem?
    private var _memoryCleanupTimer: Timer?
    private var _lastCleanupTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastDockAccessTime: TimeInterval = ProcessInfo.processInfo.systemUptime

    
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
        set {
            _windowChooser = newValue
            _isChooserVisibleUnsafe = newValue != nil
            _chooserFrameUnsafe = newValue?.window?.frame ?? .zero
        }
    }
    
    @MainActor var menuShowTask: DispatchWorkItem? {
        get { _menuShowTask }
        set { _menuShowTask = newValue }
    }
    
    // Cross-thread state for event tap callback filtering (reduces MainActor dispatch overhead)
    nonisolated(unsafe) private var _lastMouseEventTimeUnsafe: TimeInterval = 0
    nonisolated(unsafe) private var _lastChooserHoverTickUnsafe: TimeInterval = 0
    nonisolated(unsafe) private var _lastEventTimeUnsafe: TimeInterval = 0
    nonisolated(unsafe) private var _isChooserVisibleUnsafe: Bool = false
    /// Height of the primary AppKit screen (the one whose origin is at the
    /// AppKit-coords origin (0,0)). Used to flip CG-event Y coordinates to
    /// AppKit Y coordinates in the event-tap callback. Refreshed on
    /// `NSApplication.didChangeScreenParametersNotification`.
    nonisolated(unsafe) private var _primaryScreenHeightUnsafe: CGFloat = 0
    nonisolated(unsafe) private var _chooserFrameUnsafe: NSRect = .zero
    nonisolated(unsafe) private var _isOverDockIconUnsafe: Bool = false
    
    // Other properties
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var lastHoveredApp: NSRunningApplication?
    private var lastWindowOrder: [AXUIElement]?
    private let menuShowDelay: TimeInterval = 0.01
    @MainActor var lastClickTime: TimeInterval = 0
    private let clickDebounceInterval: TimeInterval = 0.1
    private var lastTouchpadClickTime: TimeInterval = 0
    private let touchpadClickDebounceInterval: TimeInterval = 0.15
    private var clickedApp: NSRunningApplication?
    private let dismissalMargin: CGFloat = 20.0
    private var lastMouseMoveTime: TimeInterval = 0
    private var lastDockHitTestTime: TimeInterval = 0
    private var lastDockHitTestPoint: CGPoint = .zero
    private var lastDockHitTestResult: (app: NSRunningApplication, url: URL, iconCenter: CGPoint)?
    private var contextMenuMonitor: Any?
    private var dockMenu: NSMenu?
    private var lastClickedDockIcon: NSRunningApplication?
    private var lastRightClickedDockIcon: NSRunningApplication?
    private var showingWindowChooserOnClick: Bool = false
    private var skipNextClickProcessing: Bool = false
    private let eventTimeoutInterval: TimeInterval = 15.0
    private let mouseMoveThrottleInterval: TimeInterval = 0.08
    private let dockHitTestCacheInterval: TimeInterval = 0.08
    private let dockHitTestMinimumMovement: CGFloat = 6.0
    private let heartbeatMissesBeforeReinit: Int = 3
    private let minReinitInterval: TimeInterval = 60.0
    private var consecutiveEventTapMisses: Int = 0
    private var lastReinitTime: TimeInterval = 0
    private var isReinitializingEventTap = false
    
    // Add currentApp property
    @MainActor private var currentApp: NSRunningApplication?
    @MainActor private var chooserRequestSequence: UInt64 = 0
    /// In-flight accessibility task issued for the most recent dock-hover.
    /// Cancelling it as soon as the user moves to another icon prevents the
    /// AX daemon from chewing through queries whose results we already
    /// throw away (cascade across multiple icons during a swipe).
    @MainActor private var inflightChooserTask: Task<Void, Never>?

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
    
    // Memory thresholds. The previous values (80/120/150) caused the routine
    // cleanup to fire on virtually every 60s tick because a healthy app that
    // captures window thumbnails and holds Accessibility caches comfortably
    // sits at ~90-120MB. Each cleanup tossed the windows cache, so the very
    // next dock hover had to re-query Accessibility and felt sluggish.
    private static let memoryThresholds = (
        warning: 250.0,    // MB - Start cleaning up (gentle)
        critical: 400.0,   // MB - Force cleanup
        restart: 700.0     // MB - Restart app
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
        memoryCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
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
    
    // Add new property for tracking menu state
    private var lastMenuInteractionTime: TimeInterval = 0
    private var menuWatchdogTimer: Timer?
    private let menuTimeoutInterval: TimeInterval = 30.0 // 30 seconds timeout
    
    private func startMenuWatchdog() {
        guard menuWatchdogTimer == nil else { return }
        menuWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                guard self.windowChooser != nil else {
                    self.menuWatchdogTimer?.invalidate()
                    self.menuWatchdogTimer = nil
                    return
                }
                
                let currentTime = ProcessInfo.processInfo.systemUptime
                if let chooser = self.windowChooser,
                   currentTime - self.lastMenuInteractionTime > self.menuTimeoutInterval {
                    Logger.warning("Window chooser appears hung, forcing cleanup...")
                    chooser.prepareForReuse()
                    chooser.close()
                    
                    self.windowChooser = nil
                    self.lastHoveredApp = nil
                    self.isMouseOverDock = false
                    await self.cleanupResources(aggressive: true)

                    self.menuWatchdogTimer?.invalidate()
                    self.menuWatchdogTimer = nil
                }
            }
        }
    }
    
    // Add new property to track menu blocking
    private var menuBlocked: Bool = false
    private var lastClickedIconApp: NSRunningApplication?
    private var rememberedFrontmostWindows: [String: RememberedFrontmostWindow] = [:]
    private var lastDockClickProcessedApp: NSRunningApplication?
    private var lastDockClickProcessedTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.4
    
    // Add new property to track thumbnails
    //private var currentThumbnailView: WindowThumbnailView?
    
    // Add properties to track last processed app and its windows
    private var lastProcessedApp: NSRunningApplication?
    private var lastProcessedWindows: [WindowInfo]?
    private var lastProcessedTime: TimeInterval = 0
    private let windowsCacheTimeout: TimeInterval = 15.0  // Cache windows for 2 seconds
    
    // Add new properties
    //private var historyController: WindowHistoryController?
    private var historyCheckTimer: Timer?
    private let historyShowThreshold: CGFloat = 20 // pixels from bottom
    
    // Add new property to track mouse position time
    private var mouseNearBottomSince: TimeInterval?
    private let historyShowDelay: TimeInterval = 0.2 // 200ms
    
    override init() {
        super.init()
        windowChooser = nil
        setupEventTap()
        setupNotifications()
        setupDockMenuTracking()
        startHeartbeat()
        setupMemoryMonitoring()
        startHistoryCheck()
    }
    
    @MainActor private func performAggressiveCleanup() async {
        let chooserVisible = windowChooser?.window?.isVisible == true
        Logger.perf("memory", "aggressive cleanup start chooserVisible=\(chooserVisible) isMouseOverDock=\(isMouseOverDock)")

        if !chooserVisible && !isMouseOverDock {
            windowChooser?.close()
            windowChooser = nil
        }
        
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
        await cleanupResources(aggressive: true)

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

    @MainActor private func cleanupResources(aggressive: Bool = false) async {
        let chooserVisible = windowChooser?.window?.isVisible == true
        let shouldPreserveChooser = chooserVisible || isMouseOverDock
        Logger.perf(
            "memory",
            "cleanup start chooserVisible=\(chooserVisible) isMouseOverDock=\(isMouseOverDock) preserveChooser=\(shouldPreserveChooser) aggressive=\(aggressive)"
        )

        Logger.debug("Starting memory cleanup")

        // Only blow away the windows cache when we really mean it. The cache is
        // tiny but its loss forces the next dock hover to re-query Accessibility,
        // which is the slow part the user notices.
        if aggressive {
            lastProcessedApp = nil
            lastProcessedWindows = nil
            lastProcessedTime = 0
        }

        if !shouldPreserveChooser {
            Logger.perf("memory", "cleanup closing chooser before cache reset")
            windowChooser?.close()
            windowChooser = nil
        }
        
        // Cancel pending operations
        menuShowTask?.cancel()
        menuShowTask = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        
        autoreleasepool {
            // Clear window chooser
            if let chooser = windowChooser, !shouldPreserveChooser {
                // Ensure thumbnail is hidden and cleaned up
                chooser.chooserView?.thumbnailView?.hideThumbnail(removePanel: true)
                chooser.chooserView?.thumbnailView?.cleanup()
                chooser.prepareForReuse()
                windowChooser = nil
            }

            // App references that drive the dock-hover state machine should only
            // be cleared on aggressive cleanups. Wiping them on every routine tick
            // breaks "reuse the chooser when hovering a neighbouring icon".
            if aggressive {
                currentApp = nil
                lastHoveredApp = nil
                clickedApp = nil
                lastClickedDockIcon = nil
                lastRightClickedDockIcon = nil
                lastWindowOrder = nil
            }
            
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
        
        // Use NSAnimationContext with proper async handling
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                
                // Clear graphics memory
                autoreleasepool {
                    CATransaction.begin()
                    CATransaction.flush()
                    CATransaction.commit()
                }
            }, completionHandler: {
                continuation.resume()
            })
        }
        
        // Force garbage collection after animation
        if #available(macOS 10.15, *) {
            await Task.yield()
        }
        
        let memoryUsage = reportMemoryUsage()
        Logger.debug("Memory cleanup completed. Current usage: \(memoryUsage) MB")
        Logger.perf("memory", "cleanup done usageMB=\(String(format: "%.1f", memoryUsage)) preservedChooser=\(shouldPreserveChooser)")
    }
    
    deinit {
        cleanupEventTap()
        cleanup()
        NotificationCenter.default.removeObserver(self)
        
        Task { @MainActor [weak self] in
            self?.menuWatchdogTimer?.invalidate()
            self?.menuWatchdogTimer = nil
            self?.memoryCleanupTimer?.invalidate()
            self?.heartbeatTimer?.invalidate()
            self?.memoryCleanupTimer = nil
            self?.heartbeatTimer = nil
            self?.historyCheckTimer?.invalidate()
            self?.historyCheckTimer = nil
            self?.cleanupTimer?.invalidate()
            self?.cleanupTimer = nil
        }
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                let currentTime = ProcessInfo.processInfo.systemUptime
                // Use the nonisolated(unsafe) timestamp set directly in the event tap callback
                let timeSinceLastEvent = currentTime - self._lastEventTimeUnsafe

                guard timeSinceLastEvent > self.eventTimeoutInterval else {
                    self.consecutiveEventTapMisses = 0
                    return
                }

                // Distinguish "user is idle" from "our event tap is dead". Ask
                // the system how long ago the user actually moved the mouse;
                // if they've been idle just as long, our tap is fine — don't
                // burn the windows cache and chooser state on a needless
                // reinit.
                let systemIdle = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: .mouseMoved
                )
                if systemIdle > Double(self.eventTimeoutInterval) {
                    self.consecutiveEventTapMisses = 0
                    return
                }

                self.consecutiveEventTapMisses += 1
                if self.consecutiveEventTapMisses >= self.heartbeatMissesBeforeReinit,
                   currentTime - self.lastReinitTime >= self.minReinitInterval {
                    Logger.warning("Event tap appears inactive (no events for \(Int(timeSinceLastEvent))s, system idle for \(Int(systemIdle))s). Reinitializing...")
                    await self.reinitializeEventTap()
                    self.lastReinitTime = currentTime
                    self.consecutiveEventTapMisses = 0
                }
            }
        }
    }

    @MainActor private func reinitializeEventTap() async {
        guard !isReinitializingEventTap else { return }
        isReinitializingEventTap = true
        defer { isReinitializingEventTap = false }

        Logger.info("Reinitializing event tap...")
        
        // First clean up existing resources
        cleanupEventTap()
        
        // Force cleanup window chooser and its resources
        forceCleanupWindowChooser()
        
        // Reset all state
        lastHoveredApp = nil
        currentApp = nil
        clickedApp = nil
        lastClickedDockIcon = nil
        lastRightClickedDockIcon = nil
        showingWindowChooserOnClick = false
        skipNextClickProcessing = false
        isMouseOverDock = false
        lastClickTime = 0
        
        // Clear all timers
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        menuShowTask?.cancel()
        menuShowTask = nil
        
        // Perform thorough cleanup
        await cleanupResources(aggressive: true)

        // Add small delay to ensure cleanup is complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Reinitialize event tap
        setupEventTap()
        
        // Reset event time after successful reinitialization
        _lastEventTime = ProcessInfo.processInfo.systemUptime
        _isEventTapActive = true
        consecutiveEventTapMisses = 0
        
        Logger.success("Event tap and window chooser resources reinitialized successfully")
    }

    @MainActor private func updateLastEventTime() {
        _lastEventTime = ProcessInfo.processInfo.systemUptime
        _isEventTapActive = true
    }

    nonisolated private func cleanup() {

        print("cleanup dockwatcher")

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
        let eventMask: CGEventMask = Constants.EventTap.eventMask
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            return autoreleasepool {
                guard let refconUnwrapped = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let watcher = Unmanaged<DockWatcher>.fromOpaque(refconUnwrapped).takeUnretainedValue()
                let location = event.location
                
                // For mouse moved events: throttle + proximity filter BEFORE creating Task
                if type == .mouseMoved {
                    let now = ProcessInfo.processInfo.systemUptime
                    watcher._lastEventTimeUnsafe = now

                    // Chooser-hover hot path: when chooser is visible and
                    // the cursor is over it, drive the hover update directly
                    // from the global tap on a tighter (~60 Hz) cadence.
                    // Reason: AppKit's NSTrackingArea / mouseMoved delivery
                    // to our chooser window goes through the WindowServer's
                    // per-window event queue, which after a long idle (e.g.
                    // 5 min) coalesces mouseMoved events for our LSUIElement
                    // background process — diagnostics show gaps of
                    // 300–800 ms between deliveries while the user is
                    // actively moving the mouse. The CGEventTap sees every
                    // event from the kernel with no such coalescing, so
                    // this path keeps the highlight responsive even when
                    // AppKit is starving the view.
                    if watcher._isChooserVisibleUnsafe {
                        // event.location is in CG (Quartz) screen coords:
                        // origin top-left, Y grows down. _chooserFrameUnsafe
                        // is in AppKit screen coords: origin bottom-left, Y
                        // grows up. We must convert before comparing or the
                        // contains-check is always false at the bottom of
                        // the screen (chooser AppKit-y ≈ 66 vs cursor CG-y
                        // ≈ screenHeight - 200), which silently disables
                        // this whole fast path.
                        let appKitLocation = watcher.appKitPoint(fromCGEventPoint: location)
                        let chooserHotZone = watcher._chooserFrameUnsafe.insetBy(
                            dx: -Constants.UI.menuDismissalMargin,
                            dy: -Constants.UI.menuDismissalMargin
                        )

                        if chooserHotZone.contains(appKitLocation) {
                            // The cursor moved off the dock onto the chooser.
                            // We must clear the "over dock icon" flag here
                            // because we are about to early-return and skip
                            // processMouseMovement, which is normally where
                            // this flag gets reset. If we leave it `true`,
                            // the leftMouseDown/Up consume-guard further
                            // down (`return nil` when over dock icon) will
                            // silently drop clicks on chooser entries — the
                            // entry hover works but clicks do nothing.
                            watcher._isOverDockIconUnsafe = false

                            // ~60 Hz throttle for the hover path — the work
                            // itself is trivial (frame contains-check on a
                            // handful of buttons + a CALayer mutation), so
                            // a higher cadence than the dock-hit-test path
                            // is safe and gives a smoother feel.
                            if now - watcher._lastChooserHoverTickUnsafe >= 0.016 {
                                watcher._lastChooserHoverTickUnsafe = now
                                Task { @MainActor in
                                    watcher.windowChooser?.chooserView?.syncHoverToCurrentMouseLocation()
                                }
                            }
                            return Unmanaged.passUnretained(event)
                        }
                    }

                    // Dock-hit-test path: heavier work, throttle to 20 Hz.
                    if now - watcher._lastMouseEventTimeUnsafe < 0.05 {
                        return Unmanaged.passUnretained(event)
                    }
                    watcher._lastMouseEventTimeUnsafe = now

                    if !watcher._isChooserVisibleUnsafe,
                       !DockService.shared.isPointNearDockArea(location) {
                        return Unmanaged.passUnretained(event)
                    }
                    
                    Task { @MainActor in
                        watcher.processMouseMovement(at: location)
                    }
                    return Unmanaged.passUnretained(event)
                }
                
                // Re-enable the tap SYNCHRONOUSLY in the callback before
                // anything else. macOS disables the tap on timeout / secure
                // input — once disabled NO further mouse events flow through
                // until we call tapEnable again. Doing this inside a
                // dispatched Task means the runloop has to wake up first,
                // which after a long idle can take hundreds of ms. During
                // that window the user's mouse moves are dropped on the
                // floor → highlight in the chooser appears to lag by ~1 s
                // when returning to the icon after a screen-sleep / idle.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = watcher.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    watcher._lastEventTimeUnsafe = ProcessInfo.processInfo.systemUptime
                    Logger.perf("eventtap", "re-enabled type=\(type == .tapDisabledByTimeout ? "timeout" : "userInput")")
                    return Unmanaged.passUnretained(event)
                }

                // For non-mouse-moved events (clicks), always dispatch
                Task { @MainActor in
                    watcher.updateLastEventTime()
                    
                    autoreleasepool {
                        switch type {
                        case .leftMouseDown, .rightMouseDown:
                            if watcher.isMouseOverOpenChooser() {
                                watcher.clickedApp = nil
                                watcher.skipNextClickProcessing = false
                                return
                            }

                            if let (app, _, _) = DockService.shared.findAppUnderCursor(at: location) {
                                let isTouchpadClick = event.flags.contains(.maskSecondaryFn) || 
                                                    event.flags.contains(.maskControl) ||
                                                    event.getIntegerValueField(.eventSourceUserData) != 0
                                
                                let currentTime = ProcessInfo.processInfo.systemUptime
                                let lastTime = isTouchpadClick ? watcher.lastTouchpadClickTime : watcher.lastClickTime
                                let debounceInterval = isTouchpadClick ? watcher.touchpadClickDebounceInterval : watcher.clickDebounceInterval
                                
                                if currentTime - lastTime >= debounceInterval {
                                    watcher.menuBlocked = true
                                    watcher.lastClickedIconApp = app
                                    
                                    watcher.windowChooser?.chooserView?.thumbnailView?.hideThumbnail()
                                    watcher.windowChooser?.close()
                                    
                                    Logger.debug("Blocked menu and thumbnail")
                                    
                                    if type == .leftMouseDown {
                                        Logger.debug("Left mouse down - \(isTouchpadClick ? "Touchpad" : "Mouse") click")
                                        
                                        if isTouchpadClick {
                                            watcher.lastTouchpadClickTime = currentTime
                                        } else {
                                            watcher.lastClickTime = currentTime
                                        }
                                        
                                        watcher.clickedApp = app
                                        watcher.lastClickedDockIcon = app
                                        watcher.skipNextClickProcessing = false
                                        watcher.showingWindowChooserOnClick = false
                                    }
                                } else {
                                    Logger.debug("Ignoring \(isTouchpadClick ? "touchpad" : "mouse") click - too soon after previous (\(currentTime - lastTime)s)")
                                    watcher.skipNextClickProcessing = true
                                }
                            }
                        case .leftMouseUp:
                            if watcher.isMouseOverOpenChooser() {
                                watcher.clickedApp = nil
                                watcher.showingWindowChooserOnClick = false
                                watcher.menuBlocked = false
                                watcher.lastClickedIconApp = nil
                                return
                            }

                            if let app = watcher.clickedApp {
                                if watcher.processDockIconClick(app: app) {
                                    if !watcher.showingWindowChooserOnClick {
                                        watcher.windowChooser?.refreshMenu()
                                    }
                                    watcher.clickedApp = nil
                                }
                                watcher.showingWindowChooserOnClick = false
                            }
                            watcher.clickedApp = nil
                            watcher.menuBlocked = false
                            watcher.lastClickedIconApp = nil
                            watcher.processMouseMovement(at: location)
                        case .rightMouseUp:
                            let showWork = DispatchWorkItem { [weak watcher] in
                                Task { @MainActor in
                                    guard let watcher = watcher else { return }
                                    watcher.isMouseOverDock = false
                                    
                                    if let chooser = watcher.windowChooser,
                                       let app = watcher.lastHoveredApp,
                                       let (hoveredApp, _, iconCenter) = DockService.shared.findAppUnderCursor(at: NSEvent.mouseLocation) {
                                        if hoveredApp == app {
                                            chooser.updatePosition(iconCenter)
                                            chooser.window?.makeKeyAndOrderFront(nil)
                                        }
                                    }
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: showWork)
                        default:
                            break
                        }
                    }
                }
                
                // Consume left clicks on dock icons so the dock doesn't
                // activate the app (which would bring ALL windows forward).
                // Our processDockIconClick handles activation instead.
                if (type == .leftMouseDown || type == .leftMouseUp) && watcher._isOverDockIconUnsafe {
                    return nil
                }

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
    
    @MainActor
    private func displayWindowSelector(for app: NSRunningApplication, at point: CGPoint, windows: [WindowInfo]) {
        Logger.perf(
            "chooser",
            "display request app=\(app.localizedName ?? "Unknown") pid=\(app.processIdentifier) windows=\(windows.count) point=(\(Int(point.x)),\(Int(point.y)))"
        )

        // Reuse the existing chooser window for ANY app — the controller will
        // swap in a fresh inner view if the app changed. This avoids the
        // close+reopen flicker when sliding from one dock icon to its neighbor.
        if let existingChooser = windowChooser,
           existingChooser.window != nil {
            let sameApp = currentApp?.processIdentifier == app.processIdentifier
            Logger.perf("chooser", "reusing existing chooser sameApp=\(sameApp)")
            existingChooser.updateWindows(windows, for: app, at: point)
            existingChooser.updatePosition(point)
            existingChooser.window?.makeKeyAndOrderFront(nil)
            _chooserFrameUnsafe = existingChooser.window?.frame ?? .zero
            currentApp = app
            lastMenuInteractionTime = ProcessInfo.processInfo.systemUptime
            return
        }

        if let _ = windowChooser,
           ProcessInfo.processInfo.systemUptime - lastMenuInteractionTime > menuTimeoutInterval {
            Logger.warning("Forcing cleanup of potentially hung window chooser")
            Logger.perf("chooser", "force cleanup due to watchdog timeout")
            forceCleanupWindowChooser()
        }
        
        if let existingChooser = windowChooser,
            existingChooser.window != nil {
            Logger.perf("chooser", "closing existing chooser before replacement")
            existingChooser.prepareForReuse()
            existingChooser.close()
            windowChooser = nil
        }

        let chooser = WindowChooserController(
            at: point,
            windows: windows,
            app: app,
            callback: { window, isHideAction in
                if let windowInfo = windows.first(where: { $0.window == window }) {
                    if let windowID = windowInfo.cgWindowID {
                        AXUIElementSetAttributeValue(window, Constants.Accessibility.windowIDKey, windowID as CFTypeRef)
                        Logger.debug("Callback: Set window ID \(windowID) on AXUIElement")
                    }
                    
                    if isHideAction {
                        AccessibilityService.shared.hideWindow(window: window, for: app)
                    } else {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
                        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                    }
                }
            }
        )
        
        guard chooser.window != nil else {
            Logger.error("Failed to create window chooser window")
            return
        }
        
        windowChooser = chooser
        currentApp = app
        Logger.perf(
            "chooser",
            "chooser created app=\(app.localizedName ?? "Unknown") frame=\(chooser.window.map { NSStringFromRect($0.frame) } ?? "nil")"
        )
        
        chooser.window?.makeKeyAndOrderFront(nil)
        _chooserFrameUnsafe = chooser.window?.frame ?? .zero

        lastMenuInteractionTime = ProcessInfo.processInfo.systemUptime
        startMenuWatchdog()
    }
    
    @MainActor private func processMouseMovement(at point: CGPoint) {
        // Throttle updates to reduce continuous accessibility hit-testing.
        let currentTime = ProcessInfo.processInfo.systemUptime
        if currentTime - lastMouseMoveTime < mouseMoveThrottleInterval {
            return
        }
        lastMouseMoveTime = currentTime
        lastMenuInteractionTime = currentTime

        let mouseLocation = NSEvent.mouseLocation
        let chooserFrame: NSRect? = {
            if let frame = windowChooser?.window?.frame {
                _chooserFrameUnsafe = frame
                return frame
            }
            if windowChooser != nil, !_chooserFrameUnsafe.isEmpty {
                return _chooserFrameUnsafe
            }
            return nil
        }()
        let isOverChooserArea = chooserFrame.map { frame in
            frame.insetBy(dx: -Constants.UI.menuDismissalMargin,
                          dy: -Constants.UI.menuDismissalMargin).contains(mouseLocation)
        } ?? false

        // Avoid expensive Dock hit-tests while the pointer is moving inside the chooser.
        if isOverChooserArea {
            _isOverDockIconUnsafe = false
            updateHistoryTracking(mouseLocation: mouseLocation)
            return
        }

        // Early exit if menu is blocked
        if menuBlocked {
            let dockResult = cachedDockHitTest(at: point, now: currentTime)
            if let (app, _, _) = dockResult {
                if app == lastClickedIconApp { return }
                menuBlocked = false
                lastClickedIconApp = nil
            } else {
                menuBlocked = false
                lastClickedIconApp = nil
            }
        }

        let dockCheckResult = cachedDockHitTest(at: point, now: currentTime)
        let isOverDock = dockCheckResult != nil
        
        if isOverDock {
            guard let (app, _, iconCenter) = dockCheckResult else { return }
            
            // Update state once
            lastDockAccessTime = ProcessInfo.processInfo.systemUptime
            isMouseOverDock = true
            _isOverDockIconUnsafe = true
            cleanupTimer?.invalidate()
            
            // Check if windows need reloading using cached values
            let shouldReloadWindows = app != lastProcessedApp || 
                                    (lastProcessedWindows?.isEmpty ?? true) ||
                                    (currentTime - lastProcessedTime) > windowsCacheTimeout ||
                                    (lastProcessedApp?.bundleIdentifier != app.bundleIdentifier)

            if shouldReloadWindows {
                chooserRequestSequence &+= 1
                let requestSequence = chooserRequestSequence
                // Cancel any in-flight accessibility query whose result we
                // are about to discard anyway. During a fast swipe across
                // several dock icons this stops the AX daemon from queueing
                // up multiple full window enumerations in a row.
                inflightChooserTask?.cancel()
                inflightChooserTask = Task { [weak self] in
                    let detached = Task.detached(priority: .userInitiated) {
                        await AccessibilityService.shared.listApplicationWindows(for: app)
                    }
                    let windows: [WindowInfo]
                    if Task.isCancelled {
                        detached.cancel()
                        return
                    }
                    windows = await detached.value
                    if Task.isCancelled { return }

                    await MainActor.run {
                        guard let self else { return }
                        guard self.chooserRequestSequence == requestSequence else {
                            Logger.perf(
                                "chooser",
                                "discard stale chooser request seq=\(requestSequence) latest=\(self.chooserRequestSequence) app=\(app.localizedName ?? "Unknown")"
                            )
                            return
                        }

                        // Let displayWindowSelector decide between reusing the
                        // existing chooser window (sliding it to the new dock
                        // icon, possibly with a fresh inner view for a new
                        // app) or creating one from scratch when there is no
                        // chooser yet.
                        if self.windowChooser == nil {
                            if !windows.isEmpty {
                                Logger.debug("Creating new window chooser for \(app.isActive ? "active" : "hidden") app")
                                self.displayWindowSelector(for: app, at: iconCenter, windows: windows)
                            }
                        } else if !windows.isEmpty {
                            autoreleasepool {
                                Logger.debug("Updating existing chooser for \(app.isActive ? "active" : "hidden") app")
                                self.displayWindowSelector(for: app, at: iconCenter, windows: windows)
                            }
                        }

                        self.lastProcessedApp = app
                        self.lastProcessedWindows = windows
                        self.lastProcessedTime = currentTime
                        self.lastHoveredApp = app
                        self.currentApp = app
                        if self.chooserRequestSequence == requestSequence {
                            self.inflightChooserTask = nil
                        }
                    }
                }
            } /*else if app != lastHoveredApp {
                // Only update position for different app
                if let (_, _, iconCenter) = dockCheckResult {
                    if !app.isActive && windowChooser == nil {
                        // For hidden apps, always create a new chooser
                        Logger.debug("Creating new chooser for hidden app on hover")
                        Task {
                            let windows = await AccessibilityService.shared.listApplicationWindows(for: app)
                            if !windows.isEmpty {
                                displayWindowSelector(for: app, at: iconCenter, windows: windows)
                            }
                        }
                    } else {
                        autoreleasepool {
                            windowChooser?.updatePosition(iconCenter)
                            windowChooser?.window?.makeKeyAndOrderFront(nil)
                        }
                    }
                    lastHoveredApp = app
                }
            }*/
        } else {
            // Mouse not over dock or chooser
            if !isOverChooserArea {
                Logger.perf(
                    "chooser",
                    "mouse outside chooser+dock point=(\(Int(mouseLocation.x)),\(Int(mouseLocation.y))) chooserFrame=\(chooserFrame.map(NSStringFromRect) ?? "nil")"
                )
                isMouseOverDock = false
                _isOverDockIconUnsafe = false
                lastHoveredApp = nil
                lastProcessedApp = nil
                lastProcessedWindows = nil
                lastProcessedTime = 0
                
                updateHistoryTracking(mouseLocation: mouseLocation)

                dismissChooserAndThumbnail()
            } else {
                updateHistoryTracking(mouseLocation: mouseLocation)
            }
        }
    }
    
    @MainActor private func dismissChooserAndThumbnail() {
        guard windowChooser != nil else { return }
        Logger.perf(
            "chooser",
            "dismiss chooser mouse=(\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))) frame=\(windowChooser?.window.map { NSStringFromRect($0.frame) } ?? NSStringFromRect(_chooserFrameUnsafe))"
        )
        
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        // Drop any in-flight chooser request so its eventual MainActor.run
        // continuation cannot resurrect a chooser we just dismissed.
        inflightChooserTask?.cancel()
        inflightChooserTask = nil

        windowChooser?.chooserView?.thumbnailView?.hideThumbnail(removePanel: true)
        windowChooser?.chooserView?.thumbnailView?.cleanup()
        windowChooser?.close()
        windowChooser = nil
    }

    private func appStorageKey(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    private func currentTopWindow(for app: NSRunningApplication, windows: [WindowInfo]) -> WindowInfo? {
        let highlightedWindow = windowChooser?.chooserView?.topmostWindow

        if let highlightedWindow,
           let targetWindow = windows.first(where: { $0.window == highlightedWindow }) {
            return targetWindow
        }

        if let mainWindow = windows.first(where: { windowInfo in
            guard !windowInfo.isAppElement else { return false }
            var mainValue: AnyObject?
            return AXUIElementCopyAttributeValue(windowInfo.window, kAXMainAttribute as CFString, &mainValue) == .success &&
                (mainValue as? Bool == true)
        }) {
            return mainWindow
        }

        if let visibleWindow = windows.first(where: { windowInfo in
            !windowInfo.isAppElement && AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }) {
            return visibleWindow
        }

        return windows.first(where: { !$0.isAppElement }) ?? windows.first
    }

    private func rememberTopWindow(for app: NSRunningApplication, windows: [WindowInfo]) {
        guard let topWindow = currentTopWindow(for: app, windows: windows) else {
            rememberedFrontmostWindows.removeValue(forKey: appStorageKey(for: app))
            return
        }

        rememberedFrontmostWindows[appStorageKey(for: app)] = RememberedFrontmostWindow(
            cgWindowID: topWindow.cgWindowID,
            name: topWindow.name
        )
    }

    private func rememberedTopWindow(for app: NSRunningApplication, windows: [WindowInfo]) -> WindowInfo? {
        let key = appStorageKey(for: app)
        guard let rememberedWindow = rememberedFrontmostWindows[key] else {
            return currentTopWindow(for: app, windows: windows)
        }

        if let cgWindowID = rememberedWindow.cgWindowID,
           let matchingWindow = windows.first(where: { $0.cgWindowID == cgWindowID }) {
            return matchingWindow
        }

        if let matchingWindow = windows.first(where: { !$0.isAppElement && $0.name == rememberedWindow.name }) {
            return matchingWindow
        }

        return currentTopWindow(for: app, windows: windows)
    }

    private func restoreWindows(
        for app: NSRunningApplication,
        windows: [WindowInfo],
        bringAllToFront: Bool
    ) -> Bool {
        let targetWindow = rememberedTopWindow(for: app, windows: windows)

        Task { @MainActor in
            let regularWindows = windows.filter { !$0.isAppElement }

            if bringAllToFront {
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])

                for windowInfo in regularWindows {
                    AXUIElementSetAttributeValue(windowInfo.window, kAXHiddenAttribute as CFString, false as CFTypeRef)

                    var minimizedValue: AnyObject?
                    if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                       let isMinimized = minimizedValue as? Bool,
                       isMinimized {
                        AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                }

                try? await Task.sleep(nanoseconds: 120_000_000)

                let (highlightedWindows, otherWindows) = regularWindows.partition { windowInfo in
                    windowInfo.window == targetWindow?.window
                }
                let orderedWindows = otherWindows + highlightedWindows

                for windowInfo in orderedWindows {
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
            } else if let targetWindow {
                let backgroundWindows = regularWindows.filter { $0.window != targetWindow.window }

                for windowInfo in backgroundWindows {
                    AccessibilityService.shared.prepareWindowForBackground(windowInfo.window)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }

                AccessibilityService.shared.prepareWindowForBackground(targetWindow.window)
                try? await Task.sleep(nanoseconds: 60_000_000)
                AccessibilityService.shared.raiseWindowOnly(targetWindow.window, for: app)
            } else if let firstWindow = regularWindows.first {
                let backgroundWindows = Array(regularWindows.dropFirst())

                for windowInfo in backgroundWindows {
                    AccessibilityService.shared.prepareWindowForBackground(windowInfo.window)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }

                AccessibilityService.shared.prepareWindowForBackground(firstWindow.window)
                try? await Task.sleep(nanoseconds: 60_000_000)
                AccessibilityService.shared.raiseWindowOnly(firstWindow.window, for: app)
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        return true
    }

    @MainActor
    private func openNewFinderWindow(for app: NSRunningApplication) -> Bool {
        Logger.debug("Opening a new Finder window")
        app.activate(options: [.activateIgnoringOtherApps])
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        NSWorkspace.shared.open(homeURL)
        return true
    }

    @MainActor
    private func openPrimaryWindow(for app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier == "com.apple.finder" {
            return openNewFinderWindow(for: app)
        }

        Logger.debug("Opening primary window for \(app.localizedName ?? "Unknown")")
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
    
    private func processDockIconClick(app: NSRunningApplication) -> Bool {
        // Skip processing if flag is set
        if skipNextClickProcessing {
            skipNextClickProcessing = false  // Reset the flag
            return true
        }

        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")

        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick = app == lastDockClickProcessedApp &&
            (now - lastDockClickProcessedTime) < doubleClickInterval
        lastDockClickProcessedApp = app
        lastDockClickProcessedTime = now

        // Get all windows
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        let nonAppWindows = windows.filter { !$0.isAppElement }
        
        // Special handling for CGWindow-only applications (like NoMachine)
        let hasCGWindowsOnly = windows.allSatisfy { windowInfo in 
            windowInfo.cgWindowID != nil && windowInfo.isAppElement
        }
        if hasCGWindowsOnly {
            if app.isActive {
                Logger.debug("CGWindow-only app is active, hiding on click")
                rememberTopWindow(for: app, windows: windows)
                app.hide()
                return true
            } else if !app.isActive {
                Logger.debug("CGWindow-only app is not active, activating")
                app.unhide()
                if isDoubleClick {
                    app.activate(options: [.activateIgnoringOtherApps])
                } else {
                    Task { @MainActor in
                        AccessibilityService.shared.activateApp(app)
                    }
                }
                for windowInfo in windows {
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
            }
            return true
        }

        // Special handling for Finder
        if app.bundleIdentifier == "com.apple.finder" {
            // Get all windows and check for visible, non-desktop windows
            let hasVisibleTopmostWindow = app.isActive && windows.contains { windowInfo in
                // Skip desktop window and app elements
                guard !windowInfo.isAppElement else { return false }
                
                // Get window role and subrole
                var roleValue: AnyObject?
                var subroleValue: AnyObject?
                _ = AXUIElementCopyAttributeValue(windowInfo.window, kAXRoleAttribute as CFString, &roleValue)
                _ = AXUIElementCopyAttributeValue(windowInfo.window, kAXSubroleAttribute as CFString, &subroleValue)
                
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
                Logger.debug("Finder is active with visible windows, hiding on click")
                rememberTopWindow(for: app, windows: windows)
                AccessibilityService.shared.hideAllWindows(for: app)
                return app.hide()
            } else {
                let highlightedWindow = windowChooser?.chooserView?.topmostWindow
                let finderHasVisibleWindows = windows.contains { windowInfo in
                    guard !windowInfo.isAppElement else { return false }
                    return AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
                }

                if finderHasVisibleWindows && !app.isHidden {
                    Logger.debug("Finder has visible windows but isn't active, raising frontmost only")
                    let targetWindow = isDoubleClick
                        ? windows.first(where: { !$0.isAppElement && AccessibilityService.shared.checkWindowVisibility($0.window) })
                        : (rememberedTopWindow(for: app, windows: windows) ??
                           windows.first(where: { $0.window == highlightedWindow }) ??
                           windows.first(where: { !$0.isAppElement && AccessibilityService.shared.checkWindowVisibility($0.window) }))
                    if let targetWindow = targetWindow {
                        if isDoubleClick {
                            for windowInfo in windows where !windowInfo.isAppElement {
                                AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                            }
                        } else {
                            AccessibilityService.shared.raiseWindowOnly(targetWindow.window, for: app)
                        }
                    } else {
                        app.activate(options: [.activateIgnoringOtherApps])
                    }
                } else if app.isHidden {
                    Logger.debug("Finder is hidden, restoring windows")
                    if nonAppWindows.isEmpty {
                        return openNewFinderWindow(for: app)
                    } else {
                        return restoreWindows(for: app, windows: nonAppWindows, bringAllToFront: isDoubleClick)
                    }
                } else {
                    Logger.debug("Finder not hidden, restoring only frontmost minimized window")
                    guard !nonAppWindows.isEmpty else {
                        Logger.debug("Finder has no real windows, opening a new Finder window")
                        return openNewFinderWindow(for: app)
                    }

                    let targetWindow = rememberedTopWindow(for: app, windows: nonAppWindows) ??
                        nonAppWindows.first(where: { $0.window == highlightedWindow }) ??
                        nonAppWindows.first

                    if let targetWindow = targetWindow {
                        if isDoubleClick {
                            return restoreWindows(for: app, windows: nonAppWindows, bringAllToFront: true)
                        } else {
                            AXUIElementSetAttributeValue(targetWindow.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                AccessibilityService.shared.raiseWindowOnly(targetWindow.window, for: app)
                            }
                        }
                    } else {
                        return openNewFinderWindow(for: app)
                    }
                }
                return true
            }
        }

        // If we only have the app entry (no real windows), handle launch
        if nonAppWindows.isEmpty {
            Logger.debug("App has no real windows, opening primary window")
            return openPrimaryWindow(for: app)
        }

        // Check if there's exactly one window and if it's minimized
        if nonAppWindows.count == 1 {
            let window = nonAppWindows[0].window
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
                    
                    // Schedule window chooser refresh
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  let (_, _, iconCenter) = DockService.shared.findAppUnderCursor(at: NSEvent.mouseLocation) else {
                                return
                            }
                            
                            // Get fresh window list
                            let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: app)
                            if !updatedWindows.isEmpty {
                                if let existingChooser = self.windowChooser {
                                    existingChooser.updateWindows(updatedWindows, for: app, at: iconCenter)
                                    existingChooser.updatePosition(iconCenter)
                                    existingChooser.window?.makeKeyAndOrderFront(nil)
                                } else if self.isMouseOverDock {
                                    // Create new chooser if mouse is still over dock
                                    self.displayWindowSelector(for: app, at: iconCenter, windows: updatedWindows)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Initialize window states before checking app status
        AccessibilityService.shared.initializeWindowStates(for: app)
        
        // Check if there are any visible windows
        let hasVisibleWindows = nonAppWindows.contains { windowInfo in
            AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }
        

        if app.isActive && hasVisibleWindows {
            Logger.debug("Active app click, hiding all windows")
            rememberTopWindow(for: app, windows: nonAppWindows)
            AccessibilityService.shared.hideAllWindows(for: app)
            return app.hide()
        } else if !hasVisibleWindows {
            if app.isHidden {
                Logger.debug("App is hidden, restoring windows")
                return restoreWindows(for: app, windows: nonAppWindows, bringAllToFront: isDoubleClick)
            } else {
                Logger.debug("App not hidden, restoring only frontmost minimized window")
                if isDoubleClick {
                    return restoreWindows(for: app, windows: nonAppWindows, bringAllToFront: true)
                }

                let targetWindow = rememberedTopWindow(for: app, windows: nonAppWindows) ?? nonAppWindows.first

                if let targetWindow = targetWindow {
                    AXUIElementSetAttributeValue(targetWindow.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        AccessibilityService.shared.raiseWindowOnly(targetWindow.window, for: app)
                    }
                } else {
                    return openPrimaryWindow(for: app)
                }
            }
            return true
        } else {
            Logger.debug("App has visible windows but isn't active, raising frontmost window only")
            let targetWindow = isDoubleClick
                ? nonAppWindows.first(where: { AccessibilityService.shared.checkWindowVisibility($0.window) })
                : (rememberedTopWindow(for: app, windows: nonAppWindows) ??
                   nonAppWindows.first(where: { AccessibilityService.shared.checkWindowVisibility($0.window) })
                )

            if isDoubleClick {
                return restoreWindows(for: app, windows: nonAppWindows, bringAllToFront: true)
            } else if let targetWindow = targetWindow {
                AccessibilityService.shared.raiseWindowOnly(targetWindow.window, for: app)
            } else {
                return openPrimaryWindow(for: app)
            }
            return true
        }
    }

    @MainActor private func isMouseOverOpenChooser() -> Bool {
        guard let chooserFrame = windowChooser?.window?.frame else {
            return false
        }

        return chooserFrame.insetBy(
            dx: -Constants.UI.menuDismissalMargin,
            dy: -Constants.UI.menuDismissalMargin
        ).contains(NSEvent.mouseLocation)
    }

    @MainActor private func cachedDockHitTest(
        at point: CGPoint,
        now: TimeInterval
    ) -> (app: NSRunningApplication, url: URL, iconCenter: CGPoint)? {
        let deltaX = point.x - lastDockHitTestPoint.x
        let deltaY = point.y - lastDockHitTestPoint.y
        let movement = hypot(deltaX, deltaY)

        if now - lastDockHitTestTime < dockHitTestCacheInterval,
           movement < dockHitTestMinimumMovement {
            return lastDockHitTestResult
        }

        let result = DockService.shared.findAppUnderCursor(at: point)
        lastDockHitTestTime = now
        lastDockHitTestPoint = point
        lastDockHitTestResult = result
        return result
    }
    
    private func setupDockMenuTracking() {
        // This can be removed if we're not using menu delegate anymore
    }

    private var isClosing: Bool = false
    
    // Add force cleanup method
    @MainActor private func forceCleanupWindowChooser() {
        if let chooser = windowChooser {
            chooser.prepareForReuse()
            chooser.close()
            windowChooser = nil
        }
        //currentThumbnailView?.cleanup()
        //currentThumbnailView = nil
        lastHoveredApp = nil
        isMouseOverDock = false
        Task {
            await cleanupResources(aggressive: true)
        }
    }
    
    private func startHistoryCheck() {
        refreshPrimaryScreenHeight()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.refreshPrimaryScreenHeight()
                if NSScreen.displaysHaveSeparateSpaces {
                    self.handleMultipleDisplays()
                }
            }
        }
    }

    /// Recompute the cached primary-screen height. The "primary" display
    /// in AppKit terms is the one whose frame origin is (0,0). That screen
    /// determines the flip we need to translate CG-event coordinates
    /// (top-left origin) to AppKit screen coordinates (bottom-left origin).
    @MainActor private func refreshPrimaryScreenHeight() {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        _primaryScreenHeightUnsafe = primary?.frame.height ?? 0
    }

    /// Convert a CG (Quartz) screen point — as produced by `CGEvent.location`
    /// — into AppKit screen coordinates so it can be compared against
    /// `NSWindow.frame` rectangles. Safe to call from the event-tap thread:
    /// only reads the cached primary-screen height.
    nonisolated func appKitPoint(fromCGEventPoint cgPoint: CGPoint) -> CGPoint {
        let primaryHeight = _primaryScreenHeightUnsafe
        return CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
    }
    
    /// Called from processMouseMovement to handle history menu triggering event-driven
    /// instead of polling with a continuous timer.
    private func updateHistoryTracking(mouseLocation: NSPoint) {
        guard let mouseScreen = DockService.shared.getScreenContainingPoint(mouseLocation) else {
            stopHistoryTracking()
            return
        }
        
        let orientation = DockService.shared.getDockOrientation()
        let edgeThreshold: CGFloat = 5
        var isNearDockEdge = false
        
        switch orientation {
        case "bottom":
            let mouseDistanceFromBottom = mouseLocation.y - mouseScreen.frame.minY
            isNearDockEdge = mouseDistanceFromBottom <= edgeThreshold
        case "left":
            isNearDockEdge = mouseLocation.x - mouseScreen.frame.minX <= edgeThreshold
        case "right":
            isNearDockEdge = mouseScreen.frame.maxX - mouseLocation.x <= edgeThreshold
        default:
            let mouseDistanceFromBottom = mouseLocation.y - mouseScreen.frame.minY
            isNearDockEdge = mouseDistanceFromBottom <= edgeThreshold
        }
        
        if isNearDockEdge {
            if mouseNearBottomSince == nil {
                mouseNearBottomSince = ProcessInfo.processInfo.systemUptime
                historyCheckTimer?.invalidate()
                historyCheckTimer = Timer.scheduledTimer(withTimeInterval: historyShowDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.checkMouseForHistory()
                    }
                }
            }
        } else {
            stopHistoryTracking()
        }
    }
    
    private func stopHistoryTracking() {
        if mouseNearBottomSince != nil {
            mouseNearBottomSince = nil
            historyCheckTimer?.invalidate()
            historyCheckTimer = nil
        }
    }
    
    private func checkMouseForHistory() {
        let mouseLocation = NSEvent.mouseLocation
        let currentTime = ProcessInfo.processInfo.systemUptime
        
        // Handle multiple displays if needed
        if NSScreen.displaysHaveSeparateSpaces {
            handleMultipleDisplays()
        }
        
        // Only check window chooser's window visibility
        if let chooserWindow = windowChooser?.window, chooserWindow.isVisible {
            // Close only if mouse is not near bottom AND not over the menu
            if mouseLocation.y > 2 && !chooserWindow.frame.contains(mouseLocation) && !isMouseOverDock {
                Logger.debug("  - Mouse moved away (not near dock or menu), closing window chooser")
                windowChooser?.chooserView?.thumbnailView?.hideThumbnail()
                windowChooser?.close()
                windowChooser = nil
            }
            mouseNearBottomSince = nil  // Reset timer when menu is visible
            return
        }
        
        // Get the screen containing the mouse cursor
        guard let mouseScreen = DockService.shared.getScreenContainingPoint(mouseLocation) else {
            Logger.debug("Mouse not on any screen")
            mouseNearBottomSince = nil
            return
        }

        // In macOS, the origin (0,0) is at the bottom-left corner of the screen
        // Calculate distance from top by subtracting y from screen height
        let mouseDistanceFromTop = mouseScreen.frame.height - (mouseLocation.y - mouseScreen.frame.minY)

        // Check if mouse is near the bottom edge of the current screen
        if (mouseDistanceFromTop < (mouseScreen.frame.height - 5)) {
            //Logger.debug("Mouse is not near bottom of screen, not showing history menu")
            mouseNearBottomSince = nil
            return
        }

        // Get the screen containing the dock
        let dockScreen = DockService.shared.getScreenWithDock()
        
        // Check if dock is on the same screen as the mouse cursor
        let isOnDockScreen = (mouseScreen == dockScreen)
        
        // If displays have separate spaces, we should allow history menu on any screen
        let shouldAllowOnThisScreen = isOnDockScreen || NSScreen.displaysHaveSeparateSpaces
        
        if !shouldAllowOnThisScreen {
            Logger.debug("Mouse not on dock screen and displays don't have separate spaces")
            mouseNearBottomSince = nil
            return
        }
        
        // Check if dock process is running
        let dockProcess = DockService.shared.findDockProcess()
        let isDockRunning = (dockProcess != nil)
        if !isDockRunning {
            Logger.debug("Dock process not running")
            mouseNearBottomSince = nil
            return
        }
        
        // Check if dock is set to autohide in preferences - do not show history menu if autohide is enabled
        let isAutohideEnabled = isDockAutohidden()
        if isAutohideEnabled {
            Logger.debug("Dock autohide is enabled, not showing history menu")
            mouseNearBottomSince = nil
            return
        }
        
        // Get dock orientation
        let orientation = DockService.shared.getDockOrientation()
        
        // Check if mouse is near the dock edge based on orientation
        var isNearDockEdge = false
        
        if orientation == "bottom" {
            // For bottom dock, check if mouse is at bottom of screen
            isNearDockEdge = mouseDistanceFromTop >= (mouseScreen.frame.height - 5)
        } else if orientation == "left" {
            // For left dock, check if mouse is at left edge of screen
            isNearDockEdge = mouseLocation.x <= 5
        } else if orientation == "right" {
            // For right dock, check if mouse is at right edge of screen
            isNearDockEdge = mouseLocation.x >= (mouseScreen.frame.width - 5)
        }
        
        // Log all conditions
        Logger.debug("""
            History menu conditions:
            - Distance from top: \(mouseDistanceFromTop)
            - On dock screen: \(isOnDockScreen)
            - Displays have separate spaces: \(NSScreen.displaysHaveSeparateSpaces)
            - Should allow on this screen: \(shouldAllowOnThisScreen)
            - Dock autohide enabled: \(isAutohideEnabled)
            - Dock running: \(isDockRunning)
            - Dock orientation: \(orientation)
            - Near dock edge: \(isNearDockEdge)
        """)
        
        // Simplified check: just ensure mouse is near dock edge and on appropriate screen
        if isNearDockEdge && shouldAllowOnThisScreen && isDockRunning {
            // Start tracking time if not already tracking
            if mouseNearBottomSince == nil {
                mouseNearBottomSince = currentTime
                Logger.debug("Started tracking mouse at dock edge")
            }
            
            // Check if enough time has passed
            if let startTime = mouseNearBottomSince,
               currentTime - startTime >= historyShowDelay {
                Logger.debug("  - Mouse held at dock edge for required duration, showing history menu")
                showHistoryMenu(at: mouseLocation)
                mouseNearBottomSince = nil  // Reset timer after showing menu
            }
        } else {
            // Reset timer if mouse moves away from dock edge
            if mouseNearBottomSince != nil {
                Logger.debug("Mouse moved away from dock edge")
                mouseNearBottomSince = nil
            }
        }
    }
    
    // Check if the dock is autohidden
    private func isDockAutohidden() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        return defaults?.bool(forKey: "autohide") ?? false
    }
    
    // Simplified check for dock visibility
    private func isSimplifiedDockVisible() -> Bool {
        // Get the dock process
        guard let dockProcess = DockService.shared.findDockProcess() else {
            return false
        }
        
        // For debugging, just assume dock is visible if process is running
        return true
    }
    
    // Original more complex check
    private func isDockVisible() -> Bool {
        // Get the dock process
        guard let dockProcess = DockService.shared.findDockProcess() else {
            return false
        }
        
        // Get the dock element
        let dockElement = AXUIElementCreateApplication(dockProcess.processIdentifier)
        
        // Get dock position and size
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(dockElement, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(dockElement, kAXSizeAttribute as CFString, &size) == .success,
              let positionRef = position,
              let sizeRef = size,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return false
        }
        
        var point = CGPoint.zero
        var dockSize = CGSize.zero
        
        // Get the position and size values
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &dockSize)
        
        // Check if dock has a reasonable size (not hidden)
        let orientation = DockService.shared.getDockOrientation()
        
        if orientation == "bottom" {
            // For bottom dock, check height
            return dockSize.height > 10
        } else if orientation == "left" {
            // For left dock, check width
            return dockSize.width > 10
        } else if orientation == "right" {
            // For right dock, check width
            return dockSize.width > 10
        }
        
        return false
    }
    
    private func showHistoryMenu(at mouseLocation: NSPoint) {
        Logger.debug("Showing history menu")
        
        // Create window chooser controller
        let controller = WindowChooserController(
            at: mouseLocation,
            windows:  WindowHistory.shared.getAllRecentWindows(),
            app: NSRunningApplication.current,
            isHistory: true,
            callback: { [weak self] window, isHideAction in
                guard let self = self else { return }
                
                // Get window info and app
                var pid: pid_t = 0
                if AXUIElementGetPid(window, &pid) == .success,
                   let app = NSRunningApplication(processIdentifier: pid) {
                    let windowInfo = WindowInfo(window: window, name: "", isAppElement: false)
                    if isHideAction {
                        AccessibilityService.shared.hideWindow(window: window, for: app)
                    } else {
                        AccessibilityService.shared.focusWindow(windowInfo.window, for: app)
                    }
                }
            }
        )
        
        // Position based on dock orientation
        if let window = controller.window {
            let orientation = DockService.shared.getDockOrientation()
            
            // Get the screen containing the mouse cursor
            let screenWithMouse = DockService.shared.getScreenContainingPoint(mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first!
            
            // Use the screen with the mouse cursor if displays have separate spaces
            // Otherwise use the screen with the dock
            let screenToUse = NSScreen.displaysHaveSeparateSpaces 
                ? screenWithMouse 
                : (DockService.shared.getScreenWithDock() ?? NSScreen.main ?? NSScreen.screens.first!)
            
            switch orientation {
            case "bottom":
                // Position at bottom of screen at mouse x position
                let xPos = mouseLocation.x - window.frame.width / 2  // Center on mouse x position
                let yPos: CGFloat = screenToUse.frame.minY  // Bottom of screen
                window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
                
            case "left":
                // Position at left of screen at mouse y position
                let xPos: CGFloat = screenToUse.frame.minX  // Left edge of screen
                let yPos = mouseLocation.y - window.frame.height / 2  // Center on mouse y position
                window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
                
            case "right":
                // Position at right of screen at mouse y position
                let xPos = screenToUse.frame.maxX - window.frame.width  // Right edge of screen
                let yPos = mouseLocation.y - window.frame.height / 2  // Center on mouse y position
                window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
                
            default:
                // Default to bottom positioning
                let xPos = mouseLocation.x - window.frame.width / 2  // Center on mouse x position
                let yPos: CGFloat = screenToUse.frame.minY  // Bottom of screen
                window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
            }
            
            // Configure window
            window.level = NSScreen.displaysHaveSeparateSpaces 
                ? NSWindow.Level.floating  // Higher level for separate spaces
                : NSWindow.Level.popUpMenu
            window.collectionBehavior = NSWindow.CollectionBehavior([.transient, .canJoinAllSpaces])
            
            // Log position for debugging
            Logger.debug("Positioned history menu at \(window.frame.origin) with orientation \(orientation) on screen \(screenToUse)")
        }
        
        // Store and show the controller
        Logger.debug("  - Showing history menu")
        self.windowChooser = controller
        controller.showWindow(self)
    }

    // Add method to check if window chooser is really visible
    private func isWindowChooserVisible() -> Bool {
        guard let chooser = windowChooser,
              let window = chooser.window else {
            return false
        }
        return window.isVisible
    }
    
    // Handle multiple displays with separate spaces
    private func handleMultipleDisplays() {
        // Only take action if displays have separate spaces
        guard NSScreen.displaysHaveSeparateSpaces else { return }
        
        //Logger.debug("Handling multiple displays with separate spaces")
        
        // Ensure event tap is active on all screens
        if !_isEventTapActive {
            Logger.warning("Event tap not active, reinitializing for multiple displays")
            Task { @MainActor in
                await reinitializeEventTap()
            }
        }
        
        // Ensure window chooser is configured for all spaces
        if let chooser = windowChooser,
           let window = chooser.window {
            // Make sure window is configured to be visible on all spaces
            if !window.collectionBehavior.contains(.canJoinAllSpaces) {
                Logger.debug("Updating window chooser to be visible on all spaces")
                window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
                window.level = NSWindow.Level.floating + 12
                
                // Force window to front to ensure visibility
                window.orderFront(nil)
            }
        }
        
        // Ensure MultiDisplayManager is aware of the current screen configuration
        MultiDisplayManager.shared.ensureAppPresenceOnAllScreens()
    }
    
    // Check if mouse is on a different screen than the dock
    private func isMouseOnDifferentScreenThanDock() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = DockService.shared.getScreenContainingPoint(mouseLocation)
        let dockScreen = DockService.shared.getScreenWithDock()
        
        return mouseScreen != nil && dockScreen != nil && mouseScreen != dockScreen
    }
}
