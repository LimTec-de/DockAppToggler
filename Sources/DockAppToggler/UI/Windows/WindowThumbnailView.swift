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
        
        static let cacheTimeout: TimeInterval = 10 // 2 hours
        
        var isValid: Bool {
            Date().timeIntervalSince(timestamp) < Self.cacheTimeout
        }
    }
    
    // Make activePreviewWindows thread-safe by using main actor
    @MainActor private static var activePreviewWindows: Set<NSPanel> = []
    
    // Add static property to store app thumbnails
    @MainActor private static var appThumbnails: [String: AppThumbnail] = [:]
    
    // Add cache tracking property
    @MainActor private static var cacheClears: Int = 0
    
    private let dockIconCenter: NSPoint
    private let targetApp: NSRunningApplication
    private let titleHeight: CGFloat = 24
    private let options: [WindowInfo]
    
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
    
    // Add new cache key struct
    private struct WindowCacheKey: Hashable {
        let pid: pid_t
        let windowName: String
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(pid)
            hasher.combine(windowName)
        }
        
        static func == (lhs: WindowCacheKey, rhs: WindowCacheKey) -> Bool {
            return lhs.pid == rhs.pid && lhs.windowName == rhs.windowName
        }
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
        let pid = targetApp.processIdentifier
        let cacheKey = WindowCacheKey(pid: pid, windowName: windowInfo.name)
        
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
        
        // Create a data task to handle the window capture
        let imageData: CGImage? = await Task.detached { [targetApp = targetApp, windowInfo = windowInfo] () -> CGImage? in
            // Special handling for Chrome
            if targetApp.bundleIdentifier == "com.google.Chrome" {
                // Get list of all windows
                let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
                
                Logger.debug("Chrome window matching:")
                Logger.debug("Target window: '\(windowInfo.name)'")
                
                // Find Chrome windows that match our criteria
                let chromeWindows = windowList.filter { windowDict in
                    guard let windowPID = windowDict[kCGWindowOwnerPID] as? pid_t,
                          windowPID == pid,
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
                    Logger.debug("Found Chrome window: '\(windowTitle)'")
                    
                    // More flexible title matching for Chrome
                    let normalizedTargetTitle = windowInfo.name
                        .replacingOccurrences(of: " - Google Chrome", with: "")
                        .split(separator: " - ")
                        .first?
                        .trimmingCharacters(in: .whitespaces) ?? ""

                    let normalizedWindowTitle = windowTitle
                        .replacingOccurrences(of: " - Google Chrome", with: "")
                        .split(separator: " - ")
                        .first?
                        .trimmingCharacters(in: .whitespaces) ?? ""

                    Logger.debug("Comparing titles:")
                    Logger.debug("  - Normalized target: '\(normalizedTargetTitle)'")
                    Logger.debug("  - Normalized window: '\(normalizedWindowTitle)'")

                    return normalizedWindowTitle == normalizedTargetTitle
                }
                
                Logger.debug("Matched windows count: \(chromeWindows.count)")
                
                // Try to get thumbnail for the matching window
                if let matchingWindow = chromeWindows.first,
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
        
        // Cache the scaled image
        Self.cachedThumbnails[cacheKey] = CachedThumbnail(
            image: image,
            timestamp: Date()
        )
        
        return image
    }
    
    private func createAndShowPanel(with thumbnail: NSImage, for windowInfo: WindowInfo, isLoading: Bool = false) {
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
            imageView = contentContainer.subviews[0] as! NSImageView
            titleLabel = contentContainer.subviews[1] as! NSTextField

            // Update image and title
            imageView.image = thumbnail
            titleLabel.stringValue = windowInfo.name

            // Update frame if size changed
            if panel.frame.size != panelSize {
                panel.setFrame(NSRect(origin: panel.frame.origin, size: panelSize), display: true)
                containerView.frame = NSRect(origin: .zero, size: panelSize)
                contentContainer.frame = NSRect(
                    x: shadowPadding,
                    y: shadowPadding,
                    width: thumbnailSize.width,
                    height: thumbnailSize.height + titleHeight
                )
                imageView.frame = NSRect(
                    x: contentMargin,
                    y: contentMargin,
                    width: thumbnailSize.width - (contentMargin * 2),
                    height: thumbnailSize.height - (contentMargin * 2) - titleTopMargin - titleHeight
                )
                titleLabel.frame = NSRect(
                    x: contentMargin,
                    y: thumbnailSize.height - titleHeight - titleTopMargin,
                    width: thumbnailSize.width - (contentMargin * 2),
                    height: titleHeight
                )
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

        // Position panel at the bottom of the screen
        guard let screen = NSScreen.main else { return }
        
        // Calculate position to be centered horizontally and at bottom of screen
        let xCenter = screen.visibleFrame.midX - (panelSize.width / 2)
        let yPosition = screen.visibleFrame.minY + 100 // 100px above the Dock
        
        // Set position
        var frame = NSRect(
            x: xCenter,
            y: yPosition,
            width: panelSize.width,
            height: panelSize.height
        )
        
        // Ensure the panel stays within screen bounds
        if frame.minX < screen.visibleFrame.minX {
            frame.origin.x = screen.visibleFrame.minX + 20
        } else if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = screen.visibleFrame.maxX - frame.width - 20
        }
        
        panel.setFrame(frame, display: true)
        
        if !panel.isVisible {
            panel.orderFront(nil)
            panel.makeKey()
            WindowThumbnailView.activePreviewWindows.insert(panel)
        }

        // Update imageView frame to account for title space
        let imageViewFrame = NSRect(
            x: contentMargin,
            y: contentMargin,  // Keep bottom margin
            width: thumbnailSize.width - (contentMargin * 2),
            height: thumbnailSize.height - (contentMargin * 2) - titleHeight - 8  // Add 8px extra padding below title
        )
        
        if isLoading {
            // Center the app icon
            let iconSize: CGFloat = 128
            imageView.frame = NSRect(
                x: (thumbnailSize.width - iconSize) / 2,
                y: (thumbnailSize.height - iconSize - titleHeight) / 2,  // Center vertically in remaining space
                width: iconSize,
                height: iconSize
            )
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.alphaValue = 0.7
            
            // Add spinner below the icon
            let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            spinner.style = .spinning
            spinner.startAnimation(nil)
            spinner.frame = NSRect(
                x: (thumbnailSize.width - spinner.frame.width) / 2,
                y: imageView.frame.minY - 48,  // Position below icon with some spacing
                width: spinner.frame.width,
                height: spinner.frame.height
            )
            contentContainer.addSubview(spinner)
        } else {
            // Normal thumbnail display
            imageView.frame = imageViewFrame
            imageView.imageScaling = .scaleProportionallyDown
            imageView.alphaValue = 1.0
            
            // Remove spinner if it exists
            contentContainer.subviews.filter { $0 is NSProgressIndicator }.forEach { $0.removeFromSuperview() }
        }

        // Update title label position to be at the top
        titleLabel.frame = NSRect(
            x: contentMargin,
            y: thumbnailSize.height - titleHeight - 4,  // 4px from top
            width: thumbnailSize.width - (contentMargin * 2),
            height: titleHeight
        )
    }
    
    func showThumbnail(for windowInfo: WindowInfo) {
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
            
            let pid = targetApp.processIdentifier
            let cacheKey = WindowCacheKey(pid: pid, windowName: windowInfo.name)
            
            // Check cache first
            if let cached = Self.cachedThumbnails[cacheKey],
               cached.isValid(forHiddenApp: targetApp.isHidden) {
                displayThumbnail(cached.image, for: windowInfo)
                return
            }
            
            // Show loading state immediately
            if let appIcon = targetApp.icon {
                displayThumbnail(appIcon, for: windowInfo)
            } else {
                // If no app icon available, skip showing preview until real thumbnail is ready
                return
            }
            isThumbnailLoading = true
            
            // Get the specific window using CGWindowID if available
            if let windowID = windowInfo.cgWindowID {
                // Create thumbnail for the specific window ID
                let imageData: CGImage? = await Task.detached {
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
                }.value
                
                if let cgImage = imageData {
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
                    
                    isThumbnailLoading = false
                    displayThumbnail(image, for: windowInfo)
                    return
                }
            }
            
            // Fallback to regular window thumbnail creation if CGWindowID is not available
            if let thumbnail: NSImage = await createWindowThumbnail(for: windowInfo) {
                displayThumbnail(thumbnail, for: windowInfo)
            } else {
                isThumbnailLoading = false
                if let appIcon = targetApp.icon {
                    displayFallbackPanel(with: appIcon, for: windowInfo)
                }
            }
        }
    }
    
    private func displayThumbnail(_ thumbnail: NSImage, for windowInfo: WindowInfo) {
        // If we're showing the app icon as temporary state, use a different visual style
        let isTemporary = thumbnail === targetApp.icon
        
        autoCloseTimer?.invalidate()
        createAndShowPanel(with: thumbnail, for: windowInfo, isLoading: isTemporary)
        
        // Only cache if not showing temporary state
        if !isTemporary {
            let pid = targetApp.processIdentifier
            let cacheKey = WindowCacheKey(pid: pid, windowName: windowInfo.name)
            
            Self.cachedThumbnails[cacheKey] = CachedThumbnail(
                image: thumbnail,
                timestamp: Date()
            )
            
            manageCacheSize()
        }
        
        setupAutoCloseTimer(for: windowInfo)
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
        
        // Position panel
        guard let screen = NSScreen.main else { return }
        let xCenter = screen.visibleFrame.midX - (panelSize.width / 2)
        let yPosition = screen.visibleFrame.minY + 100
        
        panel.setFrame(NSRect(
            x: xCenter,
            y: yPosition,
            width: panelSize.width,
            height: panelSize.height
        ), display: true)
        
        // Ensure panel stays within screen bounds
        var frame = panel.frame
        if frame.minX < screen.visibleFrame.minX {
            frame.origin.x = screen.visibleFrame.minX + 20
        } else if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = screen.visibleFrame.maxX - frame.width - 20
        }
        
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
        
        self._thumbnailWindow = panel
        
        panel.orderFront(nil)
        panel.makeKey()
        WindowThumbnailView.activePreviewWindows.insert(panel)
        
        // Set up the same auto-close timer as regular thumbnails
        setupAutoCloseTimer(for: windowInfo)
    }
    
    // Extract timer setup to a separate method
    private func setupAutoCloseTimer(for windowInfo: WindowInfo) {
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let mouseLocation = NSEvent.mouseLocation
                guard let screen = NSScreen.main else { return }
                let flippedY = screen.frame.height - mouseLocation.y
                let dockMouseLocation = CGPoint(x: mouseLocation.x, y: flippedY)
                
                // Check if mouse is over thumbnail
                let isOverThumbnail = self._thumbnailWindow?.frame.contains(mouseLocation) ?? false
                
                // Check if mouse is over dock icon
                let dockResult = DockService.shared.findAppUnderCursor(at: dockMouseLocation)
                let isOverCorrectDockIcon = dockResult?.app.bundleIdentifier == self.targetApp.bundleIdentifier
                
                // Check if mouse is over menu entry using passed reference
                let isOverMenu = self.windowChooser?.window?.frame.contains(mouseLocation) ?? false
                
                // Only close if mouse is not over any relevant area
                if !isOverThumbnail && !isOverCorrectDockIcon && !isOverMenu {
                    Logger.debug("Closing thumbnail - mouse outside all areas")
                    self.hideThumbnail()
                    self.autoCloseTimer?.invalidate()
                    self.autoCloseTimer = nil
                }
            }
        }
    }
    
    func hideThumbnail() {
        // Cancel any existing timer
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        
        guard let panel = _thumbnailWindow else { return }
        
        // Store the current thumbnail in cache before closing
        if let imageView = thumbnailView,
           let currentImage = imageView.image,
           let windowName = options.first?.name {  // Get window name from options
            let pid = targetApp.processIdentifier
            let cacheKey = WindowCacheKey(pid: pid, windowName: windowName)
            
            Self.cachedThumbnails[cacheKey] = CachedThumbnail(
                image: currentImage,
                timestamp: Date()
            )
            /*Logger.debug("""
                Stored thumbnail in cache:
                - Window: \(windowName)
                - PID: \(pid)
                - Cache count: \(Self.cachedThumbnails.count)
                """)*/
        }
        
        WindowThumbnailView.activePreviewWindows.remove(panel)
        
        panel.close()
        self._thumbnailWindow = nil
        self.thumbnailView = nil
        currentWindowID = nil
    }
    
    func cleanup() {
        Logger.debug("""
            Starting cleanup:
            - Cache size before: \(Self.cachedThumbnails.count)
            - Hidden app: \(targetApp.isHidden)
            """)
        
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        hideThumbnail()
        
        // Clean expired cache entries
        let oldCount = Self.cachedThumbnails.count
        Self.cachedThumbnails = Self.cachedThumbnails.filter { key, cached in
            let isValid = cached.isValid(forHiddenApp: targetApp.isHidden)
            if !isValid {
                Logger.debug("Removing expired cache for window: \(key.windowName)")
            }
            return isValid
        }
        
        // Clean expired app thumbnails
        let oldAppCount = Self.appThumbnails.count
        Self.appThumbnails = Self.appThumbnails.filter { bundleID, thumbnail in
            let isValid = thumbnail.isValid
            if !isValid {
                Logger.debug("Removing expired app thumbnail for: \(bundleID)")
            }
            return isValid
        }
        
        Logger.debug("""
            Cleanup completed:
            - Cache entries removed: \(oldCount - Self.cachedThumbnails.count)
            - App thumbnails removed: \(oldAppCount - Self.appThumbnails.count)
            - Final cache size: \(Self.cachedThumbnails.count)
            """)
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
        // Configure panel
        panel.level = .popUpMenu // Higher than .modalPanel
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
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
}

// Add extension for chunking
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
} 