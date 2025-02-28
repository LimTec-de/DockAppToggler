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
    
    // Add static property to store app thumbnails
    @MainActor private static var appThumbnails: [String: AppThumbnail] = [:]
    
    // Add cache tracking property
    @MainActor private static var cacheClears: Int = 0
    
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
    
    private var autoCloseTimer: Timer?
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
        
        // Cache thumbnails for all visible windows only once after startup
        if !Self.hasPerformedInitialCache {
            Task { @MainActor in
                await cacheVisibleWindows()
                Self.hasPerformedInitialCache = true
            }
        }
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
        
        // Create a data task to handle the window capture
        let imageData: CGImage? = await Task.detached { [targetApp = targetApp, windowInfo = windowInfo] () -> CGImage? in
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
        
        // Convert CGImage to NSImage on the main actor
        guard let cgImage = imageData else { return nil }
        
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
    
    private func displayThumbnail(_ thumbnail: NSImage, for windowInfo: WindowInfo, setupTimer: Bool = true) {
        // If we're showing the app icon as temporary state, use a different visual style
        let isTemporary = thumbnail === targetApp.icon
        
        autoCloseTimer?.invalidate()
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
            //setupAutoCloseTimer(for: windowInfo)
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
        // Find the screen that contains the dock icon
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = dockService.getScreenContainingPoint(mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first!
        
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
            panel.orderFront(nil)
            panel.makeKey()
            WindowThumbnailView.activePreviewWindows.insert(panel)
        }

        // Update imageView frame and scaling based on loading state
        let imageViewFrame = NSRect(
            x: contentMargin,
            y: contentMargin,
            width: thumbnailSize.width - (contentMargin * 2),
            height: thumbnailSize.height - (contentMargin * 2) - titleTopMargin - titleHeight
        )

        if isLoading {
            // Center the app icon with fixed size
            let iconSize: CGFloat = 128
            imageView.frame = NSRect(
                x: (thumbnailSize.width - iconSize) / 2,
                y: (thumbnailSize.height - iconSize - titleHeight) / 2,
                width: iconSize,
                height: iconSize
            )
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.alphaValue = 0.7
        } else {
            // Normal thumbnail display - use full available space
            imageView.frame = imageViewFrame
            imageView.imageScaling = .scaleProportionallyDown
            imageView.alphaValue = 1.0
        }

        // Update title label position to be at the top
        titleLabel.frame = NSRect(
            x: contentMargin,
            y: thumbnailSize.height - titleHeight - 4,  // 4px from top
            width: thumbnailSize.width - (contentMargin * 2),
            height: titleHeight
        )
    }
    
    func showThumbnail(for windowInfo: WindowInfo, withTimer: Bool = true) {
        Task { @MainActor in
            // Check if previews are enabled
            guard Self.previewsEnabled else {
                Logger.debug("Window previews are disabled")
                return
            }

            //Logger.debug("Showing thumbnail for window: \(windowInfo.name)")
            
            // Check screen recording permission
            guard Self.checkScreenRecordingPermission() && !isWindowShared(windowName: windowInfo.name) else {
                Logger.debug("No screen recording permission - cannot show thumbnail")
                if let appIcon = targetApp.icon {
                    displayFallbackPanel(with: appIcon, for: windowInfo)
                }
                return
            }

            // Skip thumbnails for app elements
            guard !windowInfo.isAppElement else { return }
            
            let cacheKey = getCacheKey(for: windowInfo)
            
            // Check cache first - even for hidden apps
            if let cached = Self.cachedThumbnails[cacheKey],
               cached.isValid(forHiddenApp: targetApp.isHidden) {
                displayThumbnail(cached.image, for: windowInfo, setupTimer: withTimer)
                return
            }
            
            // Only show loading state and attempt to create new thumbnail if app is not hidden
            if !targetApp.isHidden {
                // Show loading state immediately using existing panel
                if let appIcon = targetApp.icon {
                    displayThumbnail(appIcon, for: windowInfo, setupTimer: withTimer)
                }
                isThumbnailLoading = true

                

                if windowInfo.isCGWindowOnly == true {
                    return
                }

                
                
                
                // Fallback to regular window thumbnail creation
                if let thumbnail: NSImage = await createWindowThumbnail(for: windowInfo) {
                    displayThumbnail(thumbnail, for: windowInfo, setupTimer: withTimer)
                } else {
                    isThumbnailLoading = false
                }
            } else {
                // For hidden apps, try to use cached app thumbnail first
                if let bundleID = targetApp.bundleIdentifier {
                    Logger.debug("""
                        Checking app thumbnail cache:
                        - Bundle ID: \(bundleID)
                        - Has cached thumbnail: \(Self.appThumbnails[bundleID] != nil)
                        - Cache valid: \(Self.appThumbnails[bundleID]?.isValid ?? false)
                        - Cache size: \(Self.appThumbnails.count)
                        """)
                    
                    if let appThumbnail = Self.appThumbnails[bundleID],
                       appThumbnail.isValid {
                        Logger.debug("Using cached app thumbnail for hidden app: \(bundleID)")
                        displayThumbnail(appThumbnail.image, for: windowInfo, setupTimer: withTimer)
                    } else {
                        Logger.debug("No valid cached thumbnail found, using app icon")
                        if let appIcon = targetApp.icon {
                            displayThumbnail(appIcon, for: windowInfo, setupTimer: withTimer)
                        }
                    }
                } else {
                    Logger.debug("No bundle ID available for app")
                    if let appIcon = targetApp.icon {
                        displayThumbnail(appIcon, for: windowInfo, setupTimer: withTimer)
                    }
                }
            }
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
        //setupAutoCloseTimer(for: windowInfo)
        
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
        // Find the screen that contains the dock icon
        let targetScreen = NSScreen.screens.first { screen in
            NSPointInRect(dockIconCenter, screen.frame)
        } ?? NSScreen.main ?? NSScreen.screens.first!
        
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
        
        self._thumbnailWindow = panel
        
        panel.orderFront(nil)
        panel.makeKey()
        WindowThumbnailView.activePreviewWindows.insert(panel)
    }
    
    // Extract timer setup to a separate method
    /*private func setupAutoCloseTimer(for windowInfo: WindowInfo) {
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in  // Remove weak self from Task - it's already captured by timer
                if let self = self {  // Use if let instead of guard
                    let mouseLocation = NSEvent.mouseLocation
                    guard let screen = NSScreen.main else { return }
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
                    
                    // Only close if mouse is not over any relevant area
                    if !isOverCorrectDockIcon && !isOverMenu {
                        self.hideThumbnail()
                        self.autoCloseTimer?.invalidate()
                        self.autoCloseTimer = nil
                    }
                }
            }
        }
    }*/
    
    func hideThumbnail(removePanel: Bool = false) {
        if _thumbnailWindow?.isVisible == false {
            return
        }

        //Logger.debug("Hiding thumbnail window")

        // If preview window is blocked, wait until unblocked
        if previewWindowBlocked {
            Task { @MainActor in
                // Wait for a short time and check again
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 0.1 second delay
                while previewWindowBlocked {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // Once unblocked, proceed with hiding
                hideThumbnailImpl(removePanel: removePanel)
                hideThumbnailImpl(removePanel: removePanel)
                hideThumbnailImpl(removePanel: removePanel)
            }
            return
        }
        
        // If not blocked, proceed immediately
        hideThumbnailImpl(removePanel: removePanel)
    }
    
    // Extract implementation to separate method
    @MainActor private func hideThumbnailImpl(removePanel: Bool) {
        // Cancel any existing timer
        autoCloseTimer?.invalidate()
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
        
        // Cancel timer first
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        
        // Close all preview windows
        let windowsToClose = WindowThumbnailView.activePreviewWindows
        for panel in windowsToClose {
            panel.orderOut(nil)
            panel.close()
            WindowThumbnailView.activePreviewWindows.remove(panel)
        }
        
        // Clear instance variables
        self._thumbnailWindow = nil
        self.thumbnailView = nil
        self.currentWindowID = nil
        
        // Clean expired cache entries
        var newCache: [WindowCacheKey: CachedThumbnail] = [:]
        let oldCount = Self.cachedThumbnails.count
        
        for (key, cached) in Self.cachedThumbnails {
            if cached.isValid(forHiddenApp: targetApp.isHidden) {
                newCache[key] = cached
            }
        }
        
        Self.cachedThumbnails = newCache
        
        // Clean expired app thumbnails
        let oldAppCount = Self.appThumbnails.count
        Self.appThumbnails = Self.appThumbnails.filter { _, thumbnail in
            thumbnail.isValid
        }

        manageCacheSize()
        
        // Clean up other caches
        Self.windowKeyCache.removeAll()
        Self.lastThumbnailCreationTime.removeAll()
        
        /*Logger.debug("""
            Cleanup completed:
            - Removed \(oldCount - newCache.count) expired thumbnails
            - Removed \(oldAppCount - Self.appThumbnails.count) expired app thumbnails
            - Cleared window key cache
            - Cleared thumbnail timing cache
            - Final cache size: \(newCache.count)
            """)*/
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
    
    // Add new method to show thumbnail without timer
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
        Logger.debug("Force closing all thumbnail windows")
        
        // Take a snapshot of active windows
        let windowsToClose = activePreviewWindows
        
        for panel in windowsToClose {
            panel.orderOut(nil)
            panel.close()
            activePreviewWindows.remove(panel)
        }
        
        // Don't clear caches here - they will be cleaned up naturally through expiration
    }
    
    // Add method to update frontmost window
    func updateFrontmostWindow(_ window: AXUIElement) {
        self.frontmostWindow = window
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