import AppKit

@MainActor // Make the entire class main actor-isolated
class WindowThumbnailView {
    // Keep this - it was the key fix
    @MainActor private static var cachedThumbnails: [WindowCacheKey: CachedThumbnail] = [:]
    
    // Remove instance cache
    private var _thumbnailWindow: NSPanel?
    private var thumbnailView: NSImageView?
    private var appLastThumbnail: CachedThumbnail?  // Add this to store app's last preview
    private var currentWindowID: CGWindowID?
    
    // Add new CachedThumbnail struct
    @MainActor private struct CachedThumbnail: Sendable {
        let image: NSImage  // NSImage is not Sendable, but we'll only access it on MainActor
        let timestamp: Date // Date is already Sendable
        
        // Increase timeouts
        static let hiddenAppCacheTimeout: TimeInterval = 7200  // 2 hours for hidden apps
        static let visibleAppCacheTimeout: TimeInterval = 30   // 30 seconds for visible apps (increased from 10)
        
        func isValid(forHiddenApp: Bool) -> Bool {
            let timeout = forHiddenApp ? Self.hiddenAppCacheTimeout : Self.visibleAppCacheTimeout
            let age = Date().timeIntervalSince(timestamp)
            let isValid = age < timeout
            
            /*Logger.debug("""
                Cache validity check:
                - Hidden app: \(forHiddenApp)
                - Cache age: \(String(format: "%.1f", age))s
                - Timeout: \(String(format: "%.1f", timeout))s
                - Valid: \(isValid)
                """)*/
            
            return isValid
        }
    }
    
    // Add new property to store app thumbnail
    private struct AppThumbnail {
        let image: NSImage
        let timestamp: Date
        let appBundleIdentifier: String
        
        // Increase timeout from 10 seconds to 2 hours to match window cache
        static let cacheTimeout: TimeInterval = 7200 // 2 hours
        
        var isValid: Bool {
            let age = Date().timeIntervalSince(timestamp)
            let isValid = age < Self.cacheTimeout
            /*Logger.debug("""
                App thumbnail validity check:
                - Bundle ID: \(appBundleIdentifier)
                - Age: \(String(format: "%.1f", age))s
                - Timeout: \(Self.cacheTimeout)s
                - Valid: \(isValid)
                """)*/
            return isValid
        }
    }
    
    // Make activePreviewWindows thread-safe by using main actor
    @MainActor private static var activePreviewWindows: Set<NSPanel> = []
    
    // Add static tracking for active thumbnail instances
    @MainActor private static var activeThumbnailViews: Set<ObjectIdentifier> = []
    
    // Add static property to store app thumbnails
    @MainActor private static var appThumbnails: [String: AppThumbnail] = [:]
    
    // Add cache tracking property
    @MainActor private static var cacheClears: Int = 0
    
    // Add static property for shared thumbnail window reuse
    @MainActor private static var sharedThumbnailWindow: NSPanel?
    @MainActor private static var sharedThumbnailView: NSImageView?
    @MainActor private static var sharedTitleLabel: NSTextField?
    @MainActor private static var currentSharedInstance: ObjectIdentifier?
    
    // Add transition delay properties
    @MainActor private static var pendingCleanupTimer: DispatchSourceTimer?
    private static let transitionGracePeriod: TimeInterval = 0.15  // 150ms delay before fade-out
    
    // Add cancellation support for thumbnail creation
    @MainActor private static var currentThumbnailTask: Task<Void, Never>?
    
    // Add debouncing support for better performance
    @MainActor private static var thumbnailDebounceTimer: DispatchSourceTimer?
    @MainActor private static var pendingThumbnailRequest: PendingThumbnailRequest?
    @MainActor private static var lastThumbnailRequestTime: Date = Date.distantPast
    private static let fastMovementThreshold: TimeInterval = 0.1 // If requests come faster than 100ms, we're moving fast
    
    // Add struct for pending requests
    private struct PendingThumbnailRequest {
        let windowInfo: WindowInfo
        let targetApp: NSRunningApplication
        let instance: ObjectIdentifier
        let timestamp: Date
    }
    
    private let dockIconCenter: NSPoint
    private var targetApp: NSRunningApplication
    private let titleHeight: CGFloat = 24
    private var options: [WindowInfo]
    
    // Add DockService property
    private let dockService = DockService.shared
    
    // Add property to store window chooser reference
    private weak var windowChooser: WindowChooserController?
    
    private var thumbnailSize: NSSize {
        guard let screen = NSScreen.main else {
            return NSSize(width: 320, height: 200)  // Fallback size
        }
        
        // Reduce from 60% to 40% of screen size
        let width = min(screen.visibleFrame.width * 0.4, 800)  // Cap at 800px
        let height = min(screen.visibleFrame.height * 0.4, 600)  // Cap at 600px
        
        return NSSize(width: width, height: height)
    }
    
    private var autoCloseTimer: DispatchSourceTimer?
    private static let previewDuration: TimeInterval = 1.5
    
    @MainActor private static var hasPerformedInitialCache = false
    
    // Update static property to use UserDefaults
    @MainActor private static var previewsEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "WindowPreviewsEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WindowPreviewsEnabled")
        }
    }
    
    // Add static method to toggle previews
    @MainActor static func togglePreviews() {
        previewsEnabled.toggle()
        
        // Close any active previews if disabling
        if !previewsEnabled {
            activePreviewWindows.forEach { panel in
                panel.close()
            }
            activePreviewWindows.removeAll()
        }
        
        Logger.debug("Window previews \(previewsEnabled ? "enabled" : "disabled")")
    }
    
    // Add static method to get current state
    @MainActor static func arePreviewsDisabled() -> Bool {
        return !previewsEnabled
    }
    
    // Update the WindowCacheKey struct
    private struct WindowCacheKey: Hashable {
        let pid: pid_t
        let windowID: CGWindowID?
        let windowName: String
        private let uniqueID: UUID  // Add a unique identifier
        
        init(pid: pid_t, windowID: CGWindowID?, windowName: String) {
            self.pid = pid
            self.windowID = windowID
            self.windowName = windowName
            self.uniqueID = UUID()  // Generate a unique ID for each key
        }
        
        func hash(into hasher: inout Hasher) {
            if let windowID = windowID {
                // If we have a window ID, use only that and pid
                hasher.combine(pid)
                hasher.combine(windowID)
            } else {
                // Otherwise use pid, name, and unique ID
                hasher.combine(pid)
                hasher.combine(windowName)
                hasher.combine(uniqueID)
            }
        }
        
        static func == (lhs: WindowCacheKey, rhs: WindowCacheKey) -> Bool {
            // If either has a window ID, compare by ID
            if let lhsID = lhs.windowID, let rhsID = rhs.windowID {
                return lhs.pid == rhs.pid && lhsID == rhsID
            }
            // Otherwise compare by all fields including unique ID
            return lhs.pid == rhs.pid && 
                   lhs.windowName == rhs.windowName && 
                   lhs.uniqueID == rhs.uniqueID
        }
    }
    
    // Add a cache for window keys to maintain consistency
    private static var windowKeyCache: [String: WindowCacheKey] = [:]
    
    // Add method to get or create a cache key
    private func getCacheKey(for windowInfo: WindowInfo) -> WindowCacheKey {
        let identifier = "\(targetApp.processIdentifier):\(windowInfo.name):\(windowInfo.cgWindowID ?? 0)"
        
        if let existingKey = Self.windowKeyCache[identifier] {
            return existingKey
        }
        
        let newKey = WindowCacheKey(
            pid: targetApp.processIdentifier,
            windowID: windowInfo.cgWindowID,
            windowName: windowInfo.name
        )
        Self.windowKeyCache[identifier] = newKey
        return newKey
    }
    
    // Add at top of class
    private static var lastThumbnailCreationTime: [CGWindowID: Date] = [:]
    private static let minimumThumbnailInterval: TimeInterval = 0.5  // Half second minimum between captures
    
    // Add near top of class
    private static let maxCacheSize = 50  // Maximum number of cached thumbnails
    
    // Add near the top of the class after other static properties
    @MainActor private static var hasCheckedPermissions = false
    
    // Add near the top of the class
    @MainActor private static var hasCheckedScreenRecordingPermission = false
    
    // Add property to track if thumbnail creation is in progress
    private var isThumbnailLoading = false
    
    // Add property to track frontmost window
    private var frontmostWindow: AXUIElement?
    
    // Add near the top of the class with other properties
    @MainActor private var previewWindowBlocked: Bool = false
    
    init(targetApp: NSRunningApplication, dockIconCenter: NSPoint, options: [WindowInfo], windowChooser: WindowChooserController?) {
        self.targetApp = targetApp
        self.dockIconCenter = dockIconCenter
        self.options = options
        self.windowChooser = windowChooser
        
        self._thumbnailWindow = nil
        
        // Register this instance
        Self.activeThumbnailViews.insert(ObjectIdentifier(self))
        
        // Cancel any pending cleanup - we want to reuse the window
        Self.cancelPendingCleanup()
        
        // Cache thumbnails for all visible windows only once after startup
        if !Self.hasPerformedInitialCache {
            Task { @MainActor in
                await cacheVisibleWindows()
                Self.hasPerformedInitialCache = true
            }
        }
    }
    
    // Add new method to cancel pending cleanup
    @MainActor private static func cancelPendingCleanup() {
        pendingCleanupTimer?.cancel()
        pendingCleanupTimer = nil
    }
    
    // Add new method to schedule cleanup with delay
    @MainActor private static func scheduleOtherInstancesCleanup(except currentInstance: ObjectIdentifier) {
        // Cancel any existing cleanup timer
        pendingCleanupTimer?.cancel()
        pendingCleanupTimer = nil
        
        // Create a new timer with grace period
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + transitionGracePeriod)
        
        timer.setEventHandler { [currentInstance] in
            // Only cleanup if current instance is still active
            if activeThumbnailViews.contains(currentInstance) {
                cleanupOtherInstances(except: currentInstance)
            }
            pendingCleanupTimer?.cancel()
            pendingCleanupTimer = nil
        }
        
        pendingCleanupTimer = timer
        timer.resume()
    }
    
    private func cacheVisibleWindows() async {
        Logger.debug("Starting initial thumbnail cache for \(targetApp.localizedName ?? "unknown app")")
        
        // Skip if app is hidden
        guard !targetApp.isHidden else {
            Logger.debug("App is hidden, skipping initial cache")
            return
        }
        
        // Process windows in smaller batches
        let batchSize = 3
        var cachedCount = 0
        
        for batch in options.chunked(into: batchSize) {
            for windowInfo in batch {
                // Skip app elements
                guard !windowInfo.isAppElement else { continue }
                
                // Create thumbnail with existing logic - add await
                if await createWindowThumbnail(for: windowInfo) != nil {
                    cachedCount += 1
                }
                
                // Add small delay between batches to prevent system overload
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second delay
            }
        }
        
        Logger.debug("Completed initial thumbnail cache. Cached \(cachedCount) windows")
    }
    
    @MainActor
    private func createWindowThumbnail(for windowInfo: WindowInfo) async -> NSImage? {
        let cacheKey = getCacheKey(for: windowInfo)
        
        // Check cache first
        if let cached = Self.cachedThumbnails[cacheKey] {
            if cached.isValid(forHiddenApp: targetApp.isHidden) {
                Logger.debug("Using valid cached thumbnail")
                return cached.image
            } else {
                Logger.debug("Cache expired, removing entry")
                Self.cachedThumbnails.removeValue(forKey: cacheKey)
            }
        }

        previewWindowBlocked = true
        
        // Check for cancellation before starting expensive operation
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }
        
        // Create a data task to handle the window capture
        let imageData: CGImage? = await Task.detached { [targetApp = targetApp, windowInfo = windowInfo] () -> CGImage? in
            // Check for cancellation at start of detached task
            guard !Task.isCancelled else { return nil }
            
            // Special handling for Chrome and Firefox
            if targetApp.bundleIdentifier == "com.google.Chrome" || 
               targetApp.bundleIdentifier == "org.mozilla.firefox" {
                // Get list of all windows
                let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
                
                let browserName = targetApp.bundleIdentifier == "com.google.Chrome" ? "Chrome" : "Firefox"
                Logger.debug("\(browserName) window matching:")
                Logger.debug("Target window: '\(windowInfo.name)'")
                
                // Find browser windows that match our criteria
                let browserWindows = windowList.filter { windowDict in
                    guard let windowPID = windowDict[kCGWindowOwnerPID] as? pid_t,
                          windowPID == targetApp.processIdentifier,
                          let layer = windowDict[kCGWindowLayer] as? Int32,
                          layer == 0,
                          let bounds = windowDict[kCGWindowBounds] as? [String: Any],
                          let width = bounds["Width"] as? CGFloat,
                          let height = bounds["Height"] as? CGFloat,
                          width > 100 && height > 100,
                          let windowTitle = windowDict[kCGWindowName as CFString] as? String
                    else {
                        return false
                    }
                    
                    // Log each window's title for debugging
                    Logger.debug("Found \(browserName) window: '\(windowTitle)'")
                    
                    // More flexible title matching for browsers
                    let normalizedTargetTitle = windowInfo.name
                        .replacingOccurrences(of: " - Google Chrome", with: "")
                        .replacingOccurrences(of: " - Mozilla Firefox", with: "")
                        .split(separator: " - ")
                        .first?
                        .trimmingCharacters(in: .whitespaces) ?? ""

                    let normalizedWindowTitle = windowTitle
                        .replacingOccurrences(of: " - Google Chrome", with: "")
                        .replacingOccurrences(of: " - Mozilla Firefox", with: "")
                        .split(separator: " - ")
                        .first?
                        .trimmingCharacters(in: .whitespaces) ?? ""

                    Logger.debug("Comparing titles:")
                    Logger.debug("  - Normalized target: '\(normalizedTargetTitle)'")
                    Logger.debug("  - Normalized window: '\(normalizedWindowTitle)'")

                    return normalizedWindowTitle == normalizedTargetTitle
                }
                
                Logger.debug("Matched windows count: \(browserWindows.count)")
                
                // Try to get thumbnail for the matching window
                if let matchingWindow = browserWindows.first,
                   let windowID = matchingWindow[kCGWindowNumber] as? CGWindowID {
                    
                    // Check for cancellation before expensive screen capture
                    guard !Task.isCancelled else { return nil }
                    
                    // Check if we should create a new thumbnail
                    let shouldCreate = await MainActor.run { Self.shouldCreateNewThumbnail(for: windowID) }
                    if !shouldCreate {
                        Logger.debug("Skipping thumbnail creation - too soon since last capture")
                        return nil
                    }
                    
                    let captureOptions: CGWindowImageOption = [
                        .boundsIgnoreFraming,
                        .nominalResolution,
                        .bestResolution
                    ]
                    
                    return CGWindowListCreateImage(
                        .null,
                        .optionIncludingWindow,
                        windowID,
                        captureOptions
                    )
                }
            }
            
            // Check for cancellation before regular window handling
            guard !Task.isCancelled else { return nil }
            
            // Regular window handling
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
            
            if let windowDict = windowList.first(where: { dict in
                guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                      windowPID == targetApp.processIdentifier,
                      let windowTitle = dict[kCGWindowName] as? String,
                      windowTitle == windowInfo.name else {
                    return false
                }
                return true
            }),
               let windowID = windowDict[kCGWindowNumber] as? CGWindowID {
                
                // Check for cancellation before expensive screen capture
                guard !Task.isCancelled else { return nil }
                
                // Check if we should create a new thumbnail
                let shouldCreate = await MainActor.run { Self.shouldCreateNewThumbnail(for: windowID) }
                if !shouldCreate {
                    Logger.debug("Skipping thumbnail creation - too soon since last capture")
                    return nil
                }
                
                let captureOptions: CGWindowImageOption = [
                    .boundsIgnoreFraming,
                    .nominalResolution,
                    .bestResolution
                ]
                
                return CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    captureOptions
                )
            }
            
            return nil
        }.value
        
        // Check for cancellation after expensive operation
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }
        
        // Convert CGImage to NSImage on the main actor
        guard let cgImage = imageData else { 
            previewWindowBlocked = false
            return nil 
        }
        
        let scaleFactor: CGFloat = 0.5
        let scaledSize = NSSize(
            width: CGFloat(cgImage.width) * scaleFactor,
            height: CGFloat(cgImage.height) * scaleFactor
        )
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        let rect = NSRect(origin: .zero, size: scaledSize)
        NSImage(cgImage: cgImage, size: .zero).draw(in: rect)
        image.unlockFocus()

        // Check for cancellation before final caching operations
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }

        // Only cache app thumbnail if this is the frontmost window
        if let windowInfo = options.first, 
           windowInfo.cgWindowID == currentWindowID,
           let bundleId = targetApp.bundleIdentifier {  // Safely unwrap bundleIdentifier
            Self.appThumbnails[bundleId] = AppThumbnail(
                image: image,
                timestamp: Date(),
                appBundleIdentifier: bundleId  // Use unwrapped value
            )
        }

        // Cache the scaled image
        Self.cachedThumbnails[cacheKey] = CachedThumbnail(
            image: image,
            timestamp: Date()
        )
        

        previewWindowBlocked = false
        return image
    }
    
    // Add optimized thumbnail creation for fast movement
    @MainActor
    private func createOptimizedThumbnail(for windowInfo: WindowInfo) async -> NSImage? {
        let cacheKey = getCacheKey(for: windowInfo)
        
        // Check cache first (same as regular method)
        if let cached = Self.cachedThumbnails[cacheKey] {
            if cached.isValid(forHiddenApp: targetApp.isHidden) {
                return cached.image
            } else {
                Self.cachedThumbnails.removeValue(forKey: cacheKey)
            }
        }

        previewWindowBlocked = true
        
        // Check for cancellation before starting expensive operation
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }
        
        // Use faster, lower quality capture for optimized thumbnails
        let imageData: CGImage? = await Task.detached { [targetApp = targetApp, windowInfo = windowInfo] () -> CGImage? in
            // Check for cancellation at start of detached task
            guard !Task.isCancelled else { return nil }
            
            // Get window list - use simpler approach for optimization
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
            
            // Find the target window more efficiently
            guard let windowDict = windowList.first(where: { dict in
                guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                      windowPID == targetApp.processIdentifier,
                      let windowTitle = dict[kCGWindowName] as? String,
                      windowTitle == windowInfo.name else {
                    return false
                }
                return true
            }),
                  let windowID = windowDict[kCGWindowNumber] as? CGWindowID else {
                return nil
            }
            
            // Check for cancellation before expensive screen capture
            guard !Task.isCancelled else { return nil }
            
            // Use optimized capture options for speed
            let captureOptions: CGWindowImageOption = [
                .boundsIgnoreFraming,
                .nominalResolution  // Remove .bestResolution for speed
            ]
            
            return CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                captureOptions
            )
        }.value
        
        // Check for cancellation after expensive operation
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }
        
        // Convert CGImage to NSImage with more aggressive scaling for speed
        guard let cgImage = imageData else { 
            previewWindowBlocked = false
            return nil 
        }
        
        // Use more aggressive scaling for optimized thumbnails
        let scaleFactor: CGFloat = 0.3  // Reduced from 0.5 for speed
        let scaledSize = NSSize(
            width: CGFloat(cgImage.width) * scaleFactor,
            height: CGFloat(cgImage.height) * scaleFactor
        )
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .low  // Use low quality for speed
        let rect = NSRect(origin: .zero, size: scaledSize)
        NSImage(cgImage: cgImage, size: .zero).draw(in: rect)
        image.unlockFocus()

        // Check for cancellation before final caching operations
        guard !Task.isCancelled else { 
            previewWindowBlocked = false
            return nil 
        }

        // Cache the optimized image (with shorter timeout for optimized thumbnails)
        Self.cachedThumbnails[cacheKey] = CachedThumbnail(
            image: image,
            timestamp: Date()
        )

        previewWindowBlocked = false
        return image
    }
    
    private func displayThumbnail(_ thumbnail: NSImage, for windowInfo: WindowInfo, setupTimer: Bool = true) {
        // If we're showing the app icon as temporary state, use a different visual style
        let isTemporary = thumbnail === targetApp.icon
        
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        
        // Store current imageView for fade transition
        let oldImageView = thumbnailView
        
        // Resize icon to 128x128 if it's temporary/loading state
        let displayThumbnail: NSImage
        if isTemporary {
            let iconSize = NSSize(width: 128, height: 128)
            let resizedIcon = NSImage(size: iconSize)
            resizedIcon.lockFocus()
            thumbnail.draw(in: NSRect(origin: .zero, size: iconSize),
                          from: NSRect(origin: .zero, size: thumbnail.size),
                          operation: .sourceOver,
                          fraction: 1.0)
            resizedIcon.unlockFocus()
            displayThumbnail = resizedIcon
        } else {
            displayThumbnail = thumbnail
        }
        
        // Create new panel or update existing one without removing old view yet
        createAndShowPanel(with: displayThumbnail, for: windowInfo, isLoading: isTemporary, keepExistingView: true)
        
        // Perform fade transition if we have both old and new image views
        if let oldView = oldImageView, let newView = thumbnailView {
            // Set initial state
            oldView.alphaValue = 1.0
            newView.alphaValue = 0.0
            
            // Important: Set the correct scaling before animation
            if isTemporary {
                newView.imageScaling = .scaleProportionallyUpOrDown
            } else {
                newView.imageScaling = .scaleProportionallyDown
            }
            
            // Animate fade
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                
                oldView.animator().alphaValue = 0.0
                newView.animator().alphaValue = 1.0
            }, completionHandler: {
                // Only remove old view after animation completes
                oldView.removeFromSuperview()
            })
        } else {
            // No previous view, just show new one
            thumbnailView?.alphaValue = 1.0
        }
        
        // Only cache if not showing temporary state
        if !isTemporary {
            let cacheKey = getCacheKey(for: windowInfo)
            
            Self.cachedThumbnails[cacheKey] = CachedThumbnail(
                image: displayThumbnail,
                timestamp: Date()
            )
            
            //manageCacheSize()
        }
        
        // Only setup timer if requested
        if setupTimer {
            setupAutoCloseTimer(for: windowInfo)
        }
    }
    
    private func createAndShowPanel(with thumbnail: NSImage, for windowInfo: WindowInfo, isLoading: Bool = false, keepExistingView: Bool = false) {
        let shadowPadding: CGFloat = 80
        let contentMargin: CGFloat = 20
        let titleTopMargin: CGFloat = 2
        let panelSize = NSSize(
            width: thumbnailSize.width + (shadowPadding * 2),
            height: thumbnailSize.height + titleHeight + shadowPadding * 2
        )

        // Reuse existing panel if available
        let panel: NSPanel
        let containerView: NSView
        let contentContainer: NSView
        let imageView: NSImageView
        let titleLabel: NSTextField

        if let existingPanel = _thumbnailWindow {
            // Reuse existing panel and views
            panel = existingPanel
            containerView = panel.contentView!
            contentContainer = containerView.subviews[0]
            
            // Find views by type instead of assuming order
            imageView = contentContainer.subviews.first { $0 is NSImageView } as! NSImageView
            titleLabel = contentContainer.subviews.first { $0 is NSTextField } as! NSTextField

            // Calculate frame based on loading state
            let frame: NSRect
            if isLoading {
                // Center the app icon with fixed size for loading state
                let iconSize: CGFloat = 128
                frame = NSRect(
                    x: (thumbnailSize.width - iconSize) / 2,
                    y: (thumbnailSize.height - iconSize - titleHeight) / 2,
                    width: iconSize,
                    height: iconSize
                )
            } else {
                // Full size frame for normal thumbnails
                frame = NSRect(
                    x: contentMargin,
                    y: contentMargin,
                    width: thumbnailSize.width - (contentMargin * 2),
                    height: thumbnailSize.height - (contentMargin * 2) - titleTopMargin - titleHeight
                )
            }

            // Only remove old image view if not keeping it for transition
            if !keepExistingView {
                contentContainer.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }
            }
            
            // Create new image view with correct frame and scaling
            let newImageView = NSImageView(frame: frame)
            newImageView.image = thumbnail
            newImageView.imageScaling = isLoading ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
            newImageView.wantsLayer = true
            newImageView.layer?.cornerRadius = 8
            newImageView.layer?.masksToBounds = true
            
            contentContainer.addSubview(newImageView)
            
            // Store new imageView
            self.thumbnailView = newImageView
            
            // Update title
            titleLabel.stringValue = windowInfo.name

            // Update frame if size changed
            if panel.frame.size != panelSize {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    
                    panel.animator().setFrame(NSRect(origin: panel.frame.origin, size: panelSize), display: true)
                    containerView.animator().frame = NSRect(origin: .zero, size: panelSize)
                    contentContainer.animator().frame = NSRect(
                        x: shadowPadding,
                        y: shadowPadding,
                        width: thumbnailSize.width,
                        height: thumbnailSize.height + titleHeight
                    )
                    newImageView.animator().frame = frame
                    titleLabel.animator().frame = NSRect(
                        x: contentMargin,
                        y: thumbnailSize.height - titleHeight - titleTopMargin,
                        width: thumbnailSize.width - (contentMargin * 2),
                        height: titleHeight
                    )
                })
            }
        } else {
            // Create new panel and views if none exist
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            
            // Configure panel
            configurePanel(panel)
            
            // Create views
            containerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
            containerView.wantsLayer = true
            
            contentContainer = NSView(frame: NSRect(
                x: shadowPadding,
                y: shadowPadding,
                width: thumbnailSize.width,
                height: thumbnailSize.height + titleHeight
            ))
            contentContainer.wantsLayer = true
            contentContainer.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
            contentContainer.layer?.cornerRadius = 12
            contentContainer.layer?.shadowColor = NSColor.black.cgColor
            contentContainer.layer?.shadowOpacity = 0.6
            contentContainer.layer?.shadowRadius = 20
            contentContainer.layer?.shadowOffset = CGSize(width: 0, height: -15)
            
            imageView = NSImageView(frame: NSRect(
                x: contentMargin,
                y: contentMargin,
                width: thumbnailSize.width - (contentMargin * 2),
                height: thumbnailSize.height - (contentMargin * 2) - titleTopMargin - titleHeight
            ))
            imageView.image = thumbnail
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
            
            titleLabel = NSTextField(frame: NSRect(
                x: contentMargin,
                y: thumbnailSize.height - titleHeight - titleTopMargin,
                width: thumbnailSize.width - (contentMargin * 2),
                height: titleHeight
            ))
            titleLabel.stringValue = windowInfo.name
            titleLabel.alignment = .center
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.backgroundColor = .clear
            titleLabel.isBezeled = false
            titleLabel.isEditable = false
            titleLabel.isSelectable = false
            
            // Set up view hierarchy
            contentContainer.addSubview(imageView)
            contentContainer.addSubview(titleLabel)
            containerView.addSubview(contentContainer)
            panel.contentView = containerView
            
            self._thumbnailWindow = panel
            self.thumbnailView = imageView
        }

        // Position panel on the correct monitor
        positionAndShowWindow(panel)
    }
    
    func showThumbnail(for windowInfo: WindowInfo, withTimer: Bool = true) {
        Task { @MainActor in
            // Check if previews are enabled
            guard Self.previewsEnabled else {
                Logger.debug("Window previews are disabled")
                return
            }

            // Cancel any existing thumbnail creation task
            Self.currentThumbnailTask?.cancel()
            Self.currentThumbnailTask = nil

            // Cancel any pending cleanup - we want to reuse the window
            Self.cancelPendingCleanup()
            
            // Cancel any existing timer for this instance
            autoCloseTimer?.cancel()
            autoCloseTimer = nil

            // Detect if we're moving fast between icons
            let now = Date()
            let timeSinceLastRequest = now.timeIntervalSince(Self.lastThumbnailRequestTime)
            let isMovingFast = timeSinceLastRequest < Self.fastMovementThreshold
            Self.lastThumbnailRequestTime = now

            // If moving fast, use debouncing to avoid expensive operations
            if isMovingFast {
                // Cancel any existing debounce timer
                Self.thumbnailDebounceTimer?.cancel()
                Self.thumbnailDebounceTimer = nil
                
                // Store the request
                Self.pendingThumbnailRequest = PendingThumbnailRequest(
                    windowInfo: windowInfo,
                    targetApp: targetApp,
                    instance: ObjectIdentifier(self),
                    timestamp: now
                )
                
                // Show app icon immediately for fast response
                if let appIcon = targetApp.icon {
                    displayThumbnailInSharedWindow(appIcon, for: windowInfo, isLoading: true)
                }
                
                // Set up auto-close timer immediately for fast response
                if withTimer {
                    setupAutoCloseTimer(for: windowInfo)
                }
                
                // Set up debounce timer for 80ms
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + 0.08) // 80ms debounce
                
                timer.setEventHandler { [weak self] in
                    guard let self = self,
                          let pending = Self.pendingThumbnailRequest,
                          pending.instance == ObjectIdentifier(self) else {
                        Self.thumbnailDebounceTimer?.cancel()
                        Self.thumbnailDebounceTimer = nil
                        Self.pendingThumbnailRequest = nil
                        return
                    }
                    
                    // Process the debounced request
                    Task { @MainActor in
                        await self.processThumbnailRequest(pending.windowInfo, withTimer: false, isDebounced: true) // Don't setup timer again
                    }
                    
                    Self.thumbnailDebounceTimer?.cancel()
                    Self.thumbnailDebounceTimer = nil
                    Self.pendingThumbnailRequest = nil
                }
                
                Self.thumbnailDebounceTimer = timer
                timer.resume()
                
                return
            }
            
            // Normal processing for slower movement
            await processThumbnailRequest(windowInfo, withTimer: withTimer, isDebounced: false)
        }
    }
    
    // Extract thumbnail processing logic
    @MainActor private func processThumbnailRequest(_ windowInfo: WindowInfo, withTimer: Bool, isDebounced: Bool) async {
        //Logger.debug("Processing thumbnail for window: \(windowInfo.name), debounced: \(isDebounced)")
        
        // Check screen recording permission
        guard Self.checkScreenRecordingPermission() && !isWindowShared(windowName: windowInfo.name) else {
            Logger.debug("No screen recording permission - cannot show thumbnail")
            if let appIcon = targetApp.icon {
                displayThumbnailInSharedWindow(appIcon, for: windowInfo, isLoading: true)
            }
            return
        }

        // Skip thumbnails for app elements
        guard !windowInfo.isAppElement else { return }
        
        let cacheKey = getCacheKey(for: windowInfo)
        
        // Check cache first - even for hidden apps
        if let cached = Self.cachedThumbnails[cacheKey],
           cached.isValid(forHiddenApp: targetApp.isHidden) {
            displayThumbnailInSharedWindow(cached.image, for: windowInfo, isLoading: false)
            if withTimer {
                setupAutoCloseTimer(for: windowInfo)
            }
            return
        }
        
        // Only show loading state and attempt to create new thumbnail if app is not hidden
        if !targetApp.isHidden {
            // Show loading state immediately using shared window
            if let appIcon = targetApp.icon {
                displayThumbnailInSharedWindow(appIcon, for: windowInfo, isLoading: true)
            }
            isThumbnailLoading = true

            if windowInfo.isCGWindowOnly == true {
                return
            }
            
            // For debounced requests, use faster but lower quality capture
            let useOptimizedCapture = isDebounced
            
            // Create a new task for thumbnail creation with cancellation support
            Self.currentThumbnailTask = Task { @MainActor in
                // Use optimized thumbnail creation for debounced requests
                let thumbnail: NSImage?
                if useOptimizedCapture {
                    thumbnail = await createOptimizedThumbnail(for: windowInfo)
                } else {
                    thumbnail = await createWindowThumbnail(for: windowInfo)
                }
                
                if let thumbnail = thumbnail {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    displayThumbnailInSharedWindow(thumbnail, for: windowInfo, isLoading: false)
                } else {
                    guard !Task.isCancelled else { return }
                    isThumbnailLoading = false
                }
            }
        } else {
            // For hidden apps, try to use cached app thumbnail first
            if let bundleID = targetApp.bundleIdentifier {
                if let appThumbnail = Self.appThumbnails[bundleID],
                   appThumbnail.isValid {
                    Logger.debug("Using cached app thumbnail for hidden app: \(bundleID)")
                    displayThumbnailInSharedWindow(appThumbnail.image, for: windowInfo, isLoading: false)
                } else {
                    Logger.debug("No valid cached thumbnail found, using app icon")
                    if let appIcon = targetApp.icon {
                        displayThumbnailInSharedWindow(appIcon, for: windowInfo, isLoading: true)
                    }
                }
            } else {
                Logger.debug("No bundle ID available for app")
                if let appIcon = targetApp.icon {
                    displayThumbnailInSharedWindow(appIcon, for: windowInfo, isLoading: true)
                }
            }
        }
        
        // Setup timer if requested
        if withTimer {
            setupAutoCloseTimer(for: windowInfo)
        }
    }
    
    private func displayFallbackPanel(with icon: NSImage, for windowInfo: WindowInfo) {
        let shadowPadding: CGFloat = 80
        let contentMargin: CGFloat = 20
        let titleTopMargin: CGFloat = 2  // Add margin above title
        let panelSize = NSSize(
            width: thumbnailSize.width + (shadowPadding * 2),
            height: thumbnailSize.height + titleHeight + shadowPadding * 2
        )
        
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        // Configure panel same as normal thumbnail
        configurePanel(panel)
        
        // Create views
        let containerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        containerView.wantsLayer = true
        
        let contentContainer = NSView(frame: NSRect(
            x: shadowPadding,
            y: shadowPadding,
            width: thumbnailSize.width,
            height: thumbnailSize.height + titleHeight
        ))
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
        contentContainer.layer?.cornerRadius = 12
        contentContainer.layer?.shadowColor = NSColor.black.cgColor
        contentContainer.layer?.shadowOpacity = 0.6
        contentContainer.layer?.shadowRadius = 20
        contentContainer.layer?.shadowOffset = CGSize(width: 0, height: -15)

        // Set up the same auto-close timer as regular thumbnails
        setupAutoCloseTimer(for: windowInfo)
        
        // Create icon view with centered position considering margins
        let iconSize = NSSize(width: 128, height: 128)
        let iconView = NSImageView(frame: NSRect(
            x: (thumbnailSize.width - iconSize.width) / 2,
            y: contentMargin + (thumbnailSize.height - iconSize.height - contentMargin * 2 - titleTopMargin - titleHeight) / 2,
            width: iconSize.width,
            height: iconSize.height
        ))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        
        let titleLabel = NSTextField(frame: NSRect(
            x: contentMargin,
            y: thumbnailSize.height - titleHeight - titleTopMargin,
            width: thumbnailSize.width - (contentMargin * 2),
            height: titleHeight
        ))
        titleLabel.stringValue = windowInfo.name
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        
        // Set up view hierarchy
        contentContainer.addSubview(iconView)
        contentContainer.addSubview(titleLabel)
        containerView.addSubview(contentContainer)
        panel.contentView = containerView
        
        // Position panel on the correct monitor
        positionAndShowWindow(panel)
    }
    
    // Extract timer setup to a separate method
    private func setupAutoCloseTimer(for windowInfo: WindowInfo) {
        // Cancel any existing timer first
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        
        // Create a dispatch timer that runs on main queue
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            
            let mouseLocation = NSEvent.mouseLocation
            guard let screen = NSScreen.main else { 
                self.hideThumbnail()
                timer.cancel()
                return 
            }
            
            let flippedY = screen.frame.height - mouseLocation.y
            let dockMouseLocation = CGPoint(x: mouseLocation.x, y: flippedY)
            
            // Check if mouse is over dock icon
            let dockResult = DockService.shared.findAppUnderCursor(at: dockMouseLocation)
            let isOverCorrectDockIcon = dockResult?.app.bundleIdentifier == self.targetApp.bundleIdentifier
            
            // Improved menu detection
            var isOverMenu = false
            if let chooserWindow = self.windowChooser?.window {
                let windowFrame = chooserWindow.frame
                isOverMenu = NSPointInRect(mouseLocation, windowFrame)
            }
            
            // Check if mouse is over the thumbnail itself
            var isOverThumbnail = false
            if let thumbnailWindow = self._thumbnailWindow {
                let thumbnailFrame = thumbnailWindow.frame
                isOverThumbnail = NSPointInRect(mouseLocation, thumbnailFrame)
            }
            
            // Also check shared thumbnail window
            if let sharedWindow = Self.sharedThumbnailWindow {
                let sharedFrame = sharedWindow.frame
                isOverThumbnail = isOverThumbnail || NSPointInRect(mouseLocation, sharedFrame)
            }
            
            // Only close if mouse is not over any relevant area and no pending debounce
            if !isOverCorrectDockIcon && !isOverMenu && !isOverThumbnail && Self.pendingThumbnailRequest == nil {
                self.hideThumbnail()
                timer.cancel()
                self.autoCloseTimer = nil
            }
        }
        
        autoCloseTimer = timer
        timer.resume()
    }
    
    func hideThumbnail(removePanel: Bool = false) {
        // Cancel timer immediately
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        
        // Cancel any debouncing timer and pending requests
        Self.thumbnailDebounceTimer?.cancel()
        Self.thumbnailDebounceTimer = nil
        Self.pendingThumbnailRequest = nil
        
        // Cancel any existing thumbnail creation task
        Self.currentThumbnailTask?.cancel()
        Self.currentThumbnailTask = nil
        
        // Cancel any existing pending cleanup
        Self.cancelPendingCleanup()
        
        // Schedule delayed fade-out
        Self.scheduleDelayedFadeOut()
    }
    
    // Add method to schedule delayed fade-out
    @MainActor private static func scheduleDelayedFadeOut() {
        // Cancel any existing cleanup timer
        pendingCleanupTimer?.cancel()
        pendingCleanupTimer = nil
        
        // Also cancel any debouncing timers that might interfere
        thumbnailDebounceTimer?.cancel()
        thumbnailDebounceTimer = nil
        pendingThumbnailRequest = nil
        
        // Create a new timer with delay
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + transitionGracePeriod)
        
        timer.setEventHandler {
            // Fade out and close the shared window
            if let sharedWindow = sharedThumbnailWindow {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    sharedWindow.animator().alphaValue = 0.0
                }) {
                    sharedWindow.orderOut(nil)
                    sharedWindow.close()
                    activePreviewWindows.remove(sharedWindow)
                    sharedThumbnailWindow = nil
                    sharedThumbnailView = nil
                    sharedTitleLabel = nil
                    currentSharedInstance = nil
                }
            }
            
            // Also clean up any remaining preview windows
            let windowsToClose = activePreviewWindows
            for panel in windowsToClose {
                panel.orderOut(nil)
                panel.close()
                activePreviewWindows.remove(panel)
            }
            
            pendingCleanupTimer?.cancel()
            pendingCleanupTimer = nil
        }
        
        pendingCleanupTimer = timer
        timer.resume()
    }
    
    // Extract implementation to separate method
    @MainActor private func hideThumbnailImpl(removePanel: Bool) {
        // Cancel any existing timer
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        
        // Store current thumbnail in cache before closing
        if let imageView = thumbnailView,
           let currentImage = imageView.image,
           let windowInfo = options.first {
            let cacheKey = getCacheKey(for: windowInfo)
            
            // Only cache if not showing app icon
            if currentImage != targetApp.icon {
                Self.cachedThumbnails[cacheKey] = CachedThumbnail(
                    image: currentImage,
                    timestamp: Date()
                )
                
                // Also update app thumbnail if this is the frontmost window
                if let bundleId = targetApp.bundleIdentifier,
                   windowInfo.window == frontmostWindow {
                    Self.appThumbnails[bundleId] = AppThumbnail(
                        image: currentImage,
                        timestamp: Date(),
                        appBundleIdentifier: bundleId
                    )
                }
            }
        }
        
        // Close all active preview windows
        // Take a snapshot of active windows to avoid mutation during iteration
        let windowsToClose = WindowThumbnailView.activePreviewWindows
        
        for panel in windowsToClose {
            // Ensure window is closed on main thread
            panel.orderOut(nil)
            panel.close()
            WindowThumbnailView.activePreviewWindows.remove(panel)
        }
        
        // Clear instance variables
        self._thumbnailWindow = nil
        self.thumbnailView = nil
        self.currentWindowID = nil
    }

    func getActiveWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowInfoList
    }

    func isWindowShared(windowName: String) -> Bool {
        // Get all windows and check if Teams or Webex is running
        let windows = self.getActiveWindows()
        
        // Check if Teams or Webex is running
        var hasTeamsOrWebex = false
        for window in windows {
            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                if ownerName.contains("Teams") || ownerName.contains("Webex") {
                    hasTeamsOrWebex = true
                    break
                }
            }
        }
        
        // Only check sharing indicators if Teams or Webex is running
        if hasTeamsOrWebex {
            // Common sharing indicator phrases in different languages
            let sharingIndicators = [
                "is being shared",      // English
                "sharing a window",     // English
                "wird geteilt",         // German
                "está compartiendo",    // Spanish
                "est partagé",         // French
                "está sendo compartilhada", // Portuguese
                "viene condiviso",      // Italian
                "wordt gedeeld",        // Dutch
                "共有中",               // Japanese
                "正在共享"             // Chinese
            ]
            
            for window in windows {
                if let windowTitle = window[kCGWindowName as String] as? String {
                    for indicator in sharingIndicators {
                        if windowTitle.localizedCaseInsensitiveContains(indicator) {
                            print("⚠️ Window \(windowName) appears to be shared")
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    
    func cleanup() {
        // Check if previews are enabled
        guard Self.previewsEnabled else {
            Logger.debug("Window previews are disabled")
            return
        }

        //Logger.debug("Starting thumbnail view cleanup")
        
        // Cancel any ongoing thumbnail creation task
        Self.currentThumbnailTask?.cancel()
        Self.currentThumbnailTask = nil
        
        // Cancel any debouncing timer and clear pending requests
        Self.thumbnailDebounceTimer?.cancel()
        Self.thumbnailDebounceTimer = nil
        Self.pendingThumbnailRequest = nil
        
        // Cancel timer first
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        
        // Unregister this instance
        Self.activeThumbnailViews.remove(ObjectIdentifier(self))
        
        // Cancel any pending cleanup timer if this is the current instance
        if Self.currentSharedInstance == ObjectIdentifier(self) {
            Self.cancelPendingCleanup()
            Self.currentSharedInstance = nil
        }
        
        // Always schedule fade-out when cleanup is called, regardless of other instances
        // This ensures thumbnails disappear when user moves away
        Self.scheduleDelayedFadeOut()
        
        // Clear instance variables
        self._thumbnailWindow = nil
        self.thumbnailView = nil
        self.currentWindowID = nil
        
        // Simplified cache cleanup - only remove obviously expired entries
        if Self.cachedThumbnails.count > Self.maxCacheSize * 2 {
            var newCache: [WindowCacheKey: CachedThumbnail] = [:]
            
            for (key, cached) in Self.cachedThumbnails {
                if cached.isValid(forHiddenApp: targetApp.isHidden) {
                    newCache[key] = cached
                }
            }
            
            Self.cachedThumbnails = newCache
            
            // Clean expired app thumbnails only if cache is large
            if Self.appThumbnails.count > 20 {
                Self.appThumbnails = Self.appThumbnails.filter { _, thumbnail in
                    thumbnail.isValid
                }
            }
        }
        
        // Less frequent cache cleanup for better performance
        manageCacheSize()
    }
    
    func clearCache() {
        Self.cachedThumbnails.removeAll()
        appLastThumbnail = nil
        Logger.debug("Thumbnail cache cleared")
    }
    
    // Add method to manually trigger cache refresh if needed
    func refreshCache() {
        Task { @MainActor in
            await cacheVisibleWindows()
        }
    }
    
    // Add method to clear app thumbnails
    @MainActor static func clearAppThumbnails() {
        appThumbnails.removeAll()
        Logger.debug("Cleared all app thumbnails")
    }
    
    // Add this public method
    @MainActor func getFirstWindow() -> WindowInfo? {
        return options.first
    }
    
    internal var thumbnailWindow: NSPanel? {
        get { _thumbnailWindow }
    }
    
    private func manageCacheSize() {
        if Self.cachedThumbnails.count > Self.maxCacheSize {
            // Remove oldest entries first
            let sortedEntries = Self.cachedThumbnails.sorted { $0.value.timestamp < $1.value.timestamp }
            let entriesToRemove = sortedEntries.prefix(sortedEntries.count - Self.maxCacheSize)
            
            for entry in entriesToRemove {
                Self.cachedThumbnails.removeValue(forKey: entry.key)
            }
            
            Logger.debug("Cache cleaned: removed \(entriesToRemove.count) old thumbnails")
        }
    }
    
    private func configurePanel(_ panel: NSPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .popUpMenu + 9  // Changed from 15 to 9 as requested
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        
        // Add to active panels set
        Self.activePreviewWindows.insert(panel)
    }
    
    // Add after togglePreviews() method
    @MainActor static func checkScreenRecordingPermission() -> Bool {
        // Skip if already checked
        if hasCheckedScreenRecordingPermission {
            return CGPreflightScreenCaptureAccess()
        }
        
        hasCheckedScreenRecordingPermission = true
        
        // Check if we have screen recording permission
        if !CGPreflightScreenCaptureAccess() {
            Logger.debug("Requesting screen recording permission")
            
            // Request permission
            CGRequestScreenCaptureAccess()
            
            // Check result after request
            let hasPermission = CGPreflightScreenCaptureAccess()
            Logger.debug("Screen recording permission status: \(hasPermission)")
            
            return hasPermission
        }
        
        return true
    }
    
    // Make shouldCreateNewThumbnail static since it's used in detached tasks
    @MainActor private static func shouldCreateNewThumbnail(for windowID: CGWindowID) -> Bool {
        if let lastTime = lastThumbnailCreationTime[windowID] {
            let timeSinceLastCapture = Date().timeIntervalSince(lastTime)
            if timeSinceLastCapture < minimumThumbnailInterval {
                return false
            }
        }
        lastThumbnailCreationTime[windowID] = Date()
        return true
    }
    
    // Add method to show thumbnail without timer
    /*@MainActor func showThumbnailWithoutTimer(for windowInfo: WindowInfo) {
        Task { @MainActor in
            // Check if previews are enabled
            guard Self.previewsEnabled else {
                Logger.debug("Window previews are disabled")
                return
            }
            
            // Check screen recording permission
            guard Self.checkScreenRecordingPermission() else {
                Logger.debug("No screen recording permission - cannot show thumbnail")
                if let appIcon = targetApp.icon {
                    displayFallbackPanel(with: appIcon, for: windowInfo)
                }
                return
            }
            
            // First close any existing thumbnail
            hideThumbnail()
            
            // Then close all other active preview windows
            WindowThumbnailView.activePreviewWindows.forEach { panel in
                panel.close()
            }
            WindowThumbnailView.activePreviewWindows.removeAll()
            
            // Skip thumbnails for app elements
            guard !windowInfo.isAppElement else { return }
            
            let cacheKey = getCacheKey(for: windowInfo)
            
            // Check cache first
            if let cached = Self.cachedThumbnails[cacheKey],
               cached.isValid(forHiddenApp: targetApp.isHidden) {
                displayThumbnail(cached.image, for: windowInfo)
                return
            }
            
            // Show loading state immediately
            if let appIcon = targetApp.icon {
                displayThumbnail(appIcon, for: windowInfo)
            }
            
            // Create and display the actual thumbnail
            if let thumbnail: NSImage = await createWindowThumbnail(for: windowInfo) {
                displayThumbnail(thumbnail, for: windowInfo)
            }
        }
    }*/
    
    func updateOptions(_ newOptions: [WindowInfo]) {
        self.options = newOptions
    }
    
    func updateTargetApp(_ newApp: NSRunningApplication) {
        self.targetApp = newApp
    }
    
    // Add method to update window chooser reference
    func updateWindowChooser(_ controller: WindowChooserController) {
        self.windowChooser = controller
    }
    
    // Add a new method to force close all thumbnails but preserve cache
    @MainActor static func forceCloseAllThumbnails() {
        // Use smooth closing instead of immediate closing for better UX
        smoothCloseAllThumbnails()
    }
    
    // Add method to update frontmost window
    func updateFrontmostWindow(_ window: AXUIElement) {
        self.frontmostWindow = window
    }
    
    // Add method to cleanup other instances
    @MainActor private static func cleanupOtherInstances(except currentInstance: ObjectIdentifier) {
        // Use smooth closing instead of immediate force closing
        smoothCloseAllThumbnails()
    }
    
    // Add new method to check if we can reuse the current window
    @MainActor private static func canReuseCurrentWindow(for app: NSRunningApplication, windowInfo: WindowInfo) -> Bool {
        // Check if there's a shared window and if it's for the same app
        guard let sharedWindow = sharedThumbnailWindow,
              let currentInstance = currentSharedInstance,
              activeThumbnailViews.contains(currentInstance) else {
            return false
        }
        
        // For now, allow reuse within the same app (can be expanded to cross-app reuse later)
        return true
    }
    
    // Add new method for smooth closing with fade animation
    @MainActor private static func smoothCloseAllThumbnails() {
        Logger.debug("Smooth closing all thumbnail windows")
        
        // Take a snapshot of active windows
        let windowsToClose = activePreviewWindows
        
        for panel in windowsToClose {
            // Animate fade out before closing
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0.0
            }) {
            panel.orderOut(nil)
            panel.close()
            activePreviewWindows.remove(panel)
            }
        }
    }
    
    // New method to display thumbnails in the shared window
    private func displayThumbnailInSharedWindow(_ thumbnail: NSImage, for windowInfo: WindowInfo, isLoading: Bool) {
        // Get or create the shared window
        let panel = getOrCreateSharedWindow()
        
        // Update content more efficiently
        updateSharedWindowContentFast(panel, thumbnail: thumbnail, windowInfo: windowInfo, isLoading: isLoading)
        
        // Position and show the window
        positionAndShowWindow(panel)
    }
    
    private func getOrCreateSharedWindow() -> NSPanel {
        if let sharedWindow = Self.sharedThumbnailWindow {
            return sharedWindow
        }
        
        // Create a new shared window
        let shadowPadding: CGFloat = 80
        let panelSize = NSSize(
            width: thumbnailSize.width + (shadowPadding * 2),
            height: thumbnailSize.height + titleHeight + shadowPadding * 2
        )
        
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        // Configure panel
        configurePanel(panel)
        
        // Create container view for shadow
        let containerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        containerView.wantsLayer = true
        
        let contentContainer = NSView(frame: NSRect(
            x: shadowPadding,
            y: shadowPadding,
            width: thumbnailSize.width,
            height: thumbnailSize.height + titleHeight
        ))
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
        contentContainer.layer?.cornerRadius = 12
        contentContainer.layer?.shadowColor = NSColor.black.cgColor
        contentContainer.layer?.shadowOpacity = 0.6
        contentContainer.layer?.shadowRadius = 20
        contentContainer.layer?.shadowOffset = CGSize(width: 0, height: -15)
        
        // Set up view hierarchy
        containerView.addSubview(contentContainer)
        panel.contentView = containerView
        
        Self.sharedThumbnailWindow = panel
        return panel
    }
    
    // Optimized version of updateSharedWindowContent for better performance
    private func updateSharedWindowContentFast(_ panel: NSPanel, thumbnail: NSImage, windowInfo: WindowInfo, isLoading: Bool) {
        let containerView = panel.contentView!
        let contentContainer = containerView.subviews[0]
        
        // Find existing views instead of creating new ones when possible
        let existingImageView = contentContainer.subviews.first { $0 is NSImageView } as? NSImageView
        let existingTitleLabel = contentContainer.subviews.first { $0 is NSTextField } as? NSTextField
        
        // Update title efficiently
        if let titleLabel = existingTitleLabel {
            if titleLabel.stringValue != windowInfo.name {
                titleLabel.stringValue = windowInfo.name
            }
        } else {
            // Create title label only if it doesn't exist
            let titleLabel = NSTextField(frame: NSRect(
                x: 20,
                y: thumbnailSize.height - titleHeight - 4,
                width: thumbnailSize.width - 40,
                height: titleHeight
            ))
            titleLabel.alignment = .center
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.backgroundColor = .clear
            titleLabel.isBezeled = false
            titleLabel.isEditable = false
            titleLabel.isSelectable = false
            titleLabel.stringValue = windowInfo.name
            contentContainer.addSubview(titleLabel)
        }
        
        // Handle image view updates more efficiently
        let contentMargin: CGFloat = 20
        let imageFrame: NSRect
        
        if isLoading {
            // Center the app icon with fixed size for loading state
            let iconSize: CGFloat = 128
            imageFrame = NSRect(
                x: (thumbnailSize.width - iconSize) / 2,
                y: (thumbnailSize.height - iconSize - titleHeight) / 2,
                width: iconSize,
                height: iconSize
            )
        } else {
            // Full size frame for normal thumbnails
            imageFrame = NSRect(
                x: contentMargin,
                y: contentMargin,
                width: thumbnailSize.width - (contentMargin * 2),
                height: thumbnailSize.height - (contentMargin * 2) - titleHeight - 4
            )
        }
        
        if let imageView = existingImageView {
            // Update existing image view
            imageView.image = thumbnail
            imageView.frame = imageFrame
            imageView.imageScaling = isLoading ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
            imageView.alphaValue = isLoading ? 0.7 : 1.0
        } else {
            // Create new image view only if needed
            let imageView = NSImageView(frame: imageFrame)
            imageView.image = thumbnail
            imageView.imageScaling = isLoading ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
            imageView.alphaValue = isLoading ? 0.7 : 1.0
            contentContainer.addSubview(imageView)
        }
        
        // Store reference to the current image view
        self.thumbnailView = contentContainer.subviews.first { $0 is NSImageView } as? NSImageView
        self._thumbnailWindow = panel
    }
    
    private func positionAndShowWindow(_ panel: NSPanel) {
        // Find the screen that contains the dock icon
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = dockService.getScreenContainingPoint(mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first!
        
        // Get the actual panel size
        let panelSize = panel.frame.size
        
        // Calculate position to be centered horizontally and at bottom of the target screen
        let xCenter = targetScreen.visibleFrame.midX - (panelSize.width / 2)
        let yPosition = targetScreen.visibleFrame.minY + 100 // 100px above the Dock
        
        // Set position
        var frame = NSRect(
            x: xCenter,
            y: yPosition,
            width: panelSize.width,
            height: panelSize.height
        )
        
        // Ensure the panel stays within the target screen bounds
        if frame.minX < targetScreen.visibleFrame.minX {
            frame.origin.x = targetScreen.visibleFrame.minX + 20
        } else if frame.maxX > targetScreen.visibleFrame.maxX {
            frame.origin.x = targetScreen.visibleFrame.maxX - frame.width - 20
        }
        
        panel.setFrame(frame, display: true)
        
        if !panel.isVisible {
            panel.alphaValue = 1.0  // Ensure window is fully visible
            panel.orderFront(nil)
            panel.makeKey()
            WindowThumbnailView.activePreviewWindows.insert(panel)
        }
    }
}

// Add extension for chunking
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
} 