import AppKit
import Carbon
import Cocoa
import ApplicationServices
import UserNotifications

/// A custom window controller that manages the window chooser interface
@MainActor
class WindowChooserController: NSWindowController {
    // Change chooserView access level to internal (default)
    var chooserView: WindowChooserView?
    
    // Keep other properties private
    private var app: NSRunningApplication
    private let iconCenter: CGPoint
    private var visualEffectView: NSVisualEffectView?
    private var trackingArea: NSTrackingArea?
    private var isClosing: Bool = false
    private let callback: (AXUIElement, Bool) -> Void
    
    // Add dockService property
    private let dockService = DockService.shared
    
    // Alternative: Add a public method to get the topmost window
    var topmostWindow: AXUIElement? {
        return chooserView?.topmostWindow
    }
    
    private var isHandlingToggle = false
    
    // Add new properties
    private var isHistoryMenu = false
    private var menuTitle: String
    
    private var selectedWindow: WindowInfo?
    
    // Regular init for dock menu
    init(at point: CGPoint, 
         windows: [WindowInfo], 
         app: NSRunningApplication, 
         isHistory: Bool = false,  // Add default parameter
         callback: @escaping (AXUIElement, Bool) -> Void) {
        
        self.app = app
        self.iconCenter = point
        self.callback = callback
        self.menuTitle = app.localizedName ?? "Unknown"
        self.isHistoryMenu = isHistory
        
        // Filter and sort windows before creating the view
        let filteredWindows = WindowChooserView.sortWindows(windows, app: app, isHistory: isHistory)
        
        super.init(window: nil)
        
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: Constants.UI.windowWidth,
            height: Constants.UI.windowHeight(for: filteredWindows.count)
        )
        
        // Create window with proper type specifications
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = NSScreen.displaysHaveSeparateSpaces 
            ? NSWindow.Level.popUpMenu + 12  // Higher level for separate spaces
            : NSWindow.Level.popUpMenu + 12  // Regular level otherwise
        window.appearance = NSApp.effectiveAppearance
        
        // Configure window behavior for multiple spaces
        if NSScreen.displaysHaveSeparateSpaces {
            window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        } else {
            window.collectionBehavior = [.transient, .ignoresCycle]
        }
        
        // Disable mouse moved events by default
        window.acceptsMouseMovedEvents = false
        
        self.window = window
        
        // First configure the window to set up visual effect view
        configureWindow()
        
        // Create and configure the chooser view
        let chooserView = WindowChooserView(
            windows: filteredWindows,  // Use filtered windows
            appName: app.localizedName ?? "Unknown",
            app: app,
            iconCenter: point,
            isHistory: isHistory,
            callback: callback
        )
        
        // Add chooser view to the visual effect view instead of window's content view
        if let visualEffect = self.visualEffectView {
            visualEffect.addSubview(chooserView)
            chooserView.frame = visualEffect.bounds
        }
        
        self.chooserView = chooserView
        
        // Set up tracking area and animate
        setupTrackingArea()
        //animateAppearance()
        
        // Get the screen containing the point
        let pointScreen = dockService.getScreenContainingPoint(point) ?? NSScreen.main ?? NSScreen.screens.first!
        
        // Position window for history menu
        if isHistory {
            // Calculate position on the current screen
            let screenWidth = pointScreen.frame.width
            let screenHeight = pointScreen.frame.height
            
            // Center horizontally on the current screen
            let adjustedX = pointScreen.frame.minX + (screenWidth - contentRect.width) / 2
            
            // Position vertically - centered with slight upward offset
            let adjustedY = pointScreen.frame.minY + (screenHeight - contentRect.height) / 2 + 100
            
            window.setFrameOrigin(NSPoint(x: adjustedX, y: adjustedY))
        } else {
            // Position for regular dock menu
            let adjustedX = point.x - contentRect.width/2

            let dockHeight = DockService.shared.getDockMagnificationSize()

            let adjustedY = pointScreen.frame.minY + dockHeight + Constants.UI.arrowOffset - 4

            
            window.setFrameOrigin(NSPoint(x: adjustedX, y: adjustedY))
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func configureWindow() {
        guard let window = window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        
        // Set appropriate window level based on whether displays have separate spaces
        window.level = NSScreen.displaysHaveSeparateSpaces 
            ? NSWindow.Level.popUpMenu + 12  // Higher level for separate spaces
            : NSWindow.Level.popUpMenu + 12  // Regular level otherwise
            
        window.appearance = NSApp.effectiveAppearance
        
        // Configure window behavior for multiple spaces
        if NSScreen.displaysHaveSeparateSpaces {
            window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        } else {
            window.collectionBehavior = [.transient, .ignoresCycle]
        }
        
        // Disable mouse moved events by default
        window.acceptsMouseMovedEvents = false
        
        // Create container view for shadow
        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.15
        containerView.layer?.shadowRadius = 3.0
        containerView.layer?.shadowOffset = .zero
        
        // Create and configure the visual effect view with bubble arrow
        let visualEffect = BubbleVisualEffectView(frame: containerView.bounds)
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        visualEffect.showsArrow = !isHistoryMenu
        
        window.contentView = containerView
        containerView.addSubview(visualEffect)
        visualEffect.frame = containerView.bounds
        
        self.visualEffectView = visualEffect
    }
    
    private func setupTrackingArea() {
        guard let window = window, let contentView = window.contentView else { return }
        
        // Only track mouse enter/exit events, not movement
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        
        contentView.addTrackingArea(trackingArea!)
    }
    
    private func animateAppearance() {
        guard let window = window else { return }
        window.alphaValue = 0
        window.level = NSWindow.Level.popUpMenu + 12
        window.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.UI.animationDuration
            window.animator().alphaValue = 1
        }
    }
    
    override func close() {
        guard !isClosing else { return }
        isClosing = true
        
        // Remove tracking area and event monitors immediately
        cleanup()
        
        // Close window immediately without animation
        window?.close()
        finishClosing()
    }
    
    @MainActor private func cleanup() {
        // Add thumbnail cleanup logic
        chooserView?.thumbnailView?.hideThumbnail()
        
        // Remove tracking area
        if let trackingArea = trackingArea,
           let contentView = window?.contentView {
            contentView.removeTrackingArea(trackingArea)
        }
        trackingArea = nil

        
        
        // Clean up view hierarchy immediately
        if let window = window {
            window.contentView?.subviews.forEach { view in
                view.trackingAreas.forEach { area in
                    view.removeTrackingArea(area)
                }
                view.removeFromSuperview()
            }
            
            window.contentView = nil
            window.delegate = nil
        }
    }
    
    @MainActor func prepareForReuse() {
        cleanup()
    }
    
    @MainActor private func finishClosing() {
        cleanup()
        
        // Clear window reference
        

        window?.close()
        window = nil
        
        // Clear other properties
        trackingArea = nil
        visualEffectView = nil
        isClosing = false
        
        // Force a cleanup cycle
        autoreleasepool {
            // Clear graphics memory
            CATransaction.begin()
            CATransaction.flush()
            CATransaction.commit()
        }
        
        // Post notification that window chooser is closed
        NotificationCenter.default.post(name: NSNotification.Name("WindowChooserDidClose"), object: self)
    }
    
    deinit {
        // Remove observer
        NotificationCenter.default.removeObserver(self)
        
        // Ensure cleanup runs on main thread synchronously
        if !Thread.isMainThread {
            _ = DispatchQueue.main.sync {
                Task { @MainActor in
                    cleanup()
                }
            }
        }
    }
    
    func updateWindowSize(to height: CGFloat) {
        guard let window = window else { return }
        
        // Calculate new frame
        let newFrame = NSRect(
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: Constants.UI.windowWidth,
            height: height
        )
        
        // Update window frame
        window.setFrame(newFrame, display: true)
        
        // Update container view and its subviews
        if let containerView = window.contentView {
            containerView.frame = NSRect(origin: .zero, size: newFrame.size)
            containerView.subviews.forEach { view in
                view.frame = containerView.bounds
            }
        }
    }

    func updateWindows(_ windows: [WindowInfo], for app: NSRunningApplication, at point: CGPoint) {
        // Update app reference
        self.app = app
        
        // Ensure window level and ordering
        window?.level = NSWindow.Level.popUpMenu + 2
        window?.orderFront(nil)
        
        // Update existing chooser view if it exists
        if let existingView = chooserView {
            existingView.updateWindows(windows, forceNormalMode: true)
        } else {
            // Only create new view if one doesn't exist
            let newView = WindowChooserView(
                windows: windows,
                appName: app.localizedName ?? "Unknown",
                app: app,
                iconCenter: point,
                isHistory: false,  // Explicitly set to false for normal mode
                callback: callback
            )
            
            // Add and position new view immediately
            if let containerView = window?.contentView?.subviews.first {
                containerView.addSubview(newView)
                newView.frame = containerView.bounds
            }
            
            // Update reference
            chooserView = newView
        }
        
        // Update position
        updatePosition(point)
    }

    func updatePosition(_ iconCenter: CGPoint) {
        guard let window = window else { return }
        
        // Ensure window stays above previews
        window.level = NSWindow.Level.popUpMenu + 12  // Higher than thumbnail's level of +9
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.hidesOnDeactivate = false
        window.canHide = false
        window.orderFront(nil)
        
        // Calculate new window position
        let menuWidth = window.frame.width
        let menuHeight = window.frame.height
        let screenFrame = window.screen?.visibleFrame ?? .zero
        
        // Position menu above dock icon
        let xPos = max(screenFrame.minX, min(iconCenter.x - menuWidth / 2, screenFrame.maxX - menuWidth))
        let dockHeight = DockService.shared.getDockMagnificationSize()
        let yPos = dockHeight + Constants.UI.arrowOffset - 4
        
        let newFrame = NSRect(x: xPos, y: yPos, width: menuWidth, height: menuHeight)
        
        // Check if this is a significant position change (different dock icon)
        let currentCenterX = window.frame.origin.x + (window.frame.width / 2)
        let isSignificantMove = abs(currentCenterX - iconCenter.x) > window.frame.width / 2
        
        /*if window.isVisible && isSignificantMove {
            // Use fade transition only for significant position changes
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 0.0
            }) { [weak self] in
                self?.window?.setFrame(newFrame, display: true)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self?.window?.animator().alphaValue = 1.0
                })
            }
        } else {*/
            // Direct update for initial display or small movements
            window.setFrame(newFrame, display: true)
            window.alphaValue = 1.0
        //}
    }

    func refreshMenu(force: Bool = false) {
        if let windows = chooserView?.options {
            if force || needsWindowUpdate(windows: windows) {
                // Update content without recreating window
                chooserView?.updateWindows(windows, forceNormalMode: true)  // Force normal mode
                
                // Update window size
                let newHeight = Constants.UI.windowHeight(for: windows.count)
                updateWindowSize(to: newHeight)
            }
        }
    }
    
    private func createWindow(with windows: [WindowInfo]) {
        // Create new window
        let newWindow = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Constants.UI.windowWidth,
                height: Constants.UI.windowHeight(for: windows.count)
            ),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        newWindow.hasShadow = true
        newWindow.level = NSWindow.Level.popUpMenu + 12  // Higher than thumbnail's level of +9
        newWindow.appearance = NSApp.effectiveAppearance
        newWindow.alphaValue = 0
        
        // Ensure window stays above others and is visible on all spaces
        newWindow.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        
        // Create container view for shadow
        let containerView = NSView(frame: newWindow.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.15
        containerView.layer?.shadowRadius = 3.0
        containerView.layer?.shadowOffset = .zero
        
        // Create and configure the visual effect view
        let visualEffect = BubbleVisualEffectView(frame: containerView.bounds)
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        
        // Create chooser view
        let newView = WindowChooserView(
            windows: windows,
            appName: app.localizedName ?? "Unknown",
            app: app,
            iconCenter: iconCenter,
            isHistory: isHistoryMenu,
            callback: callback
        )
        
        // Set up view hierarchy
        newWindow.contentView = containerView
        containerView.addSubview(visualEffect)
        visualEffect.addSubview(newView)
        
        // Update frames
        visualEffect.frame = containerView.bounds
        newView.frame = visualEffect.bounds
        
        // Store references
        self.window = newWindow
        self.chooserView = newView
        
        // Show window
        newWindow.makeKeyAndOrderFront(nil)
        
        // Fade in with animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.UI.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            newWindow.animator().alphaValue = 1
        }
        
        // Setup tracking area after window is shown
        setupTrackingArea()
    }
    
    func needsWindowUpdate(windows: [WindowInfo]) -> Bool {
        // Compare current windows with new windows
        guard let currentWindows = chooserView?.options else { return true }
        
        if currentWindows.count != windows.count { return true }
        
        // Compare window IDs only - skip minimized state check for performance
        for (current, new) in zip(currentWindows, windows) {
            if current.cgWindowID != new.cgWindowID { return true }
        }
        
        return false
    }
    
    private func handleAppToggle(_ bundleIdentifier: String) {
        // Prevent multiple simultaneous toggles
        guard !isHandlingToggle else { return }
        isHandlingToggle = true
        
        // First close the window immediately
        close()
        
        // Then handle the app toggle
        Task {
            do {
                try await dockService.toggleApp(bundleIdentifier)
                
                // Add a delay to allow window state to update
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Update window states
                await MainActor.run {
                    updateWindowStates()
                }
            } catch {
                // Show error notification after a short delay to ensure window is closed
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await MainActor.run {
                    showErrorNotification(error.localizedDescription)
                }
                Logger.error("Failed to toggle app: \(error)")
            }
            
            isHandlingToggle = false
        }
    }
    
    private func updateWindowStates() {
        // Get fresh window list
        let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // Update window states in chooser view
        chooserView?.updateWindows(updatedWindows)
        
        // If all windows are minimized, close the menu
        if updatedWindows.allSatisfy({ windowInfo in
            var minimizedValue: AnyObject?
            return AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                   (minimizedValue as? Bool == true)
        }) {
            close()
        }
    }
    
    private func showErrorNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "DockAppToggler"
        content.body = message
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("Failed to show notification: \(error)")
            }
        }
    }
    
    private func refreshMenuState() {
        // Get fresh window list
        let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // Update window chooser view with new windows
        chooserView?.updateWindows(updatedWindows)
        
        // If all windows are minimized, close the menu
        let allMinimized = updatedWindows.allSatisfy { windowInfo in
            var minimizedValue: AnyObject?
            return AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                   (minimizedValue as? Bool == true)
        }
        
        if allMinimized {
            close()
        }
    }
    
    func highlightWindow(_ window: WindowInfo) {
        selectedWindow = window
        // Update UI to highlight the selected window
        chooserView?.setNeedsDisplay(chooserView?.bounds ?? .zero)
    }
    
    func showChooser(mode: WindowChooserMode = .normal) {
        // Reset the view state before showing
        if let chooserView = window?.contentView as? WindowChooserView {
            chooserView.configureForMode(mode)
        }
        
        guard let window = self.window else { return }
        
        // Ensure proper window level and behavior
        window.level = NSWindow.Level.popUpMenu + 12  // Higher than thumbnail's level of +9
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.hidesOnDeactivate = false
        window.canHide = false
        
        // Show the window chooser UI
        // Get the screen containing the mouse cursor position
        let mouseLocation = NSEvent.mouseLocation
        let screen = dockService.getScreenContainingPoint(mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first!
        let frame = NSRect(
            x: (screen.frame.width - window.frame.width) / 2 + screen.frame.minX,
            y: (screen.frame.height - window.frame.height) / 2 + screen.frame.minY + 200,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(frame, display: true)
        window.orderFront(nil)
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        // Configure window
        window?.isMovableByWindowBackground = true
        window?.level = NSWindow.Level.popUpMenu + 12  // Higher than thumbnail's level of +9
        window?.backgroundColor = .clear
        
        // Set style mask to allow becoming key window
        window?.styleMask.insert(.titled)  // This allows the window to become key
        window?.acceptsMouseMovedEvents = true
        
        // Position window appropriately - use current mouse location to determine screen
        let mouseLocation = NSEvent.mouseLocation
        let screen = dockService.getScreenContainingPoint(mouseLocation) ?? 
                     dockService.getScreenContainingPoint(iconCenter) ?? 
                     NSScreen.main ?? 
                     NSScreen.screens.first!
        
        let screenFrame = screen.frame
        let windowFrame = window?.frame ?? .zero
        let x = (screenFrame.width - windowFrame.width) / 2 + screenFrame.minX
        let y = (screenFrame.height - windowFrame.height) / 2 + screenFrame.minY
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        
        // Ensure window is visible on all spaces if needed
        if NSScreen.displaysHaveSeparateSpaces, let window = window {
            MultiDisplayManager.shared.ensureWindowVisibleOnAllSpaces(window)
            Logger.debug("Ensuring window chooser is visible on all spaces")
        }
        
        // Animate appearance
        animateAppearance()
    }
} 