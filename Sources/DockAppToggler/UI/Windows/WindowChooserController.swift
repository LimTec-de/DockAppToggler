import AppKit
import Carbon
import Cocoa
import ApplicationServices

/// A custom window controller that manages the window chooser interface
@MainActor
class WindowChooserController: NSWindowController {
    // Change chooserView access level to internal (default)
    var chooserView: WindowChooserView?
    
    // Keep other properties private
    private let app: NSRunningApplication
    private let iconCenter: CGPoint
    private var visualEffectView: NSVisualEffectView?
    private var trackingArea: NSTrackingArea?
    private var isClosing: Bool = false
    private let callback: (AXUIElement, Bool) -> Void

    // Alternative: Add a public method to get the topmost window
    var topmostWindow: AXUIElement? {
        return chooserView?.topmostWindow
    }
    
    init(at point: CGPoint, windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (AXUIElement, Bool) -> Void) {
        self.app = app
        self.iconCenter = point
        self.callback = callback
        
        let height = Constants.UI.windowHeight(for: windows.count)
        let width = Constants.UI.windowWidth
        
        // Get the main screen and its frame
        guard let screen = NSScreen.main else {
            fatalError("No main screen available")
        }
        
        // Keep x position exactly at click point for perfect centering
        let adjustedX = point.x - width/2
        
        // Position the window above the Dock with magnification consideration
        let dockHeight = DockService.shared.getDockMagnificationSize()
        let adjustedY = dockHeight + Constants.UI.arrowOffset - 4
        
        let frame = NSRect(x: adjustedX, 
                          y: adjustedY, 
                          width: width, 
                          height: height)
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        configureWindow()
        setupVisualEffect(width: width, height: height)
        setupChooserView(windows: windows)
        setupTrackingArea()
        animateAppearance()
        
        window.ignoresMouseEvents = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func configureWindow() {
        guard let window = window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .popUpMenu
        window.appearance = NSApp.effectiveAppearance
        
        // Create container view for shadow
        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.15  // Adjusted shadow opacity
        containerView.layer?.shadowRadius = 3.0    // Adjusted shadow radius
        containerView.layer?.shadowOffset = .zero   // Center shadow
        
        // Create and configure the visual effect view with bubble arrow
        let visualEffect = BubbleVisualEffectView(frame: containerView.bounds)
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        
        // Set up view hierarchy
        window.contentView = containerView
        containerView.addSubview(visualEffect)
        visualEffect.frame = containerView.bounds
        
        // Store the visual effect view for later use
        self.visualEffectView = visualEffect
    }
    
    // Remove the separate setupVisualEffect method since it's now handled in configureWindow
    private func setupVisualEffect(width: CGFloat, height: CGFloat) {
        // This method is no longer needed
    }
    
    private func setupChooserView(windows: [WindowInfo]) {
        guard let contentView = window?.contentView else { return }
        let chooserView = WindowChooserView(
            windows: windows,
            appName: app.localizedName ?? "Unknown",
            app: app,
            callback: { [weak self] window, isHideAction in
                guard let self = self else { return }
                
                // Get the window info from our windows list to ensure we have the correct ID
                if let windowInfo = windows.first(where: { $0.window == window }),
                   let windowID = windowInfo.cgWindowID {
                    // Store the CGWindowID in the AXUIElement
                    AXUIElementSetAttributeValue(window, Constants.Accessibility.windowIDKey, windowID as CFTypeRef)
                    Logger.debug("Callback: Set window ID \(windowID) on AXUIElement")
                }
                
                if isHideAction {
                    // Hide the selected window
                    AccessibilityService.shared.hideWindow(window: window, for: self.app)
                } else {
                    // Always show and raise the window
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    var titleValue: AnyObject?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    let windowName = (titleValue as? String) ?? ""
                    let windowInfo = WindowInfo(window: window, name: windowName)
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: self.app)
                    self.app.activate(options: [.activateIgnoringOtherApps])
                }
                
                // Add a small delay to ensure window state has updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    // Refresh the menu to update all states
                    self?.refreshMenu()
                }
            }
        )
        contentView.addSubview(chooserView)
        self.chooserView = chooserView
    }
    
    private func setupTrackingArea() {
        guard let window = window, let contentView = window.contentView else { return }
        
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        
        contentView.addTrackingArea(trackingArea!)
    }
    
    private func animateAppearance() {
        guard let window = window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.UI.animationDuration
            window.animator().alphaValue = 1
        }
    }
    
    override func close() {
        guard !isClosing else { return }
        isClosing = true
        
        // Remove tracking area
        if let trackingArea = trackingArea,
           let contentView = window?.contentView {
            contentView.removeTrackingArea(trackingArea)
        }
        
        // Store self reference before animation
        let controller = self
        
        // Animate window closing
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.UI.animationDuration
            window?.animator().alphaValue = 0
        }, completionHandler: {
            // Use stored reference to call super and update state
            controller.finishClosing()
        })
    }
    
    private func finishClosing() {
        // Clean up resources
        trackingArea = nil
        chooserView = nil
        
        super.close()
        isClosing = false
        
        // Post notification that window chooser is closed
        NotificationCenter.default.post(name: NSNotification.Name("WindowChooserDidClose"), object: self)
    }
    
    func refreshMenu() {
        // Get fresh window list
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // If no windows left, close the menu
        if windows.isEmpty {
            self.close()
            return
        }
        
        // Store current window position
        let currentFrame = self.window?.frame ?? NSRect.zero
        
        // Create entirely new window
        let newWindow = NSWindow(
            contentRect: NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: Constants.UI.windowWidth,
                height: Constants.UI.windowHeight(for: windows.count)
            ),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        // Configure new window
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        newWindow.hasShadow = true
        newWindow.level = .popUpMenu
        newWindow.appearance = NSApp.effectiveAppearance
        
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
        
        // Create new chooser view
        let newView = WindowChooserView(
            windows: windows,
            appName: app.localizedName ?? "Unknown",
            app: app,
            callback: callback
        )
        
        // Set up view hierarchy
        newWindow.contentView = containerView
        containerView.addSubview(visualEffect)
        visualEffect.addSubview(newView)
        
        // Update frames
        visualEffect.frame = containerView.bounds
        newView.frame = visualEffect.bounds
        
        // Replace old window with new one
        let oldWindow = self.window
        self.window = newWindow
        
        // Show new window and close old one
        newWindow.makeKeyAndOrderFront(nil)
        oldWindow?.close()
    }

    func needsWindowUpdate(windows: [WindowInfo]) -> Bool {
        // Compare current windows with new windows
        guard let currentWindows = chooserView?.options else { return true }
        
        if currentWindows.count != windows.count { return true }
        
        // Compare window IDs and states
        for (current, new) in zip(currentWindows, windows) {
            if current.cgWindowID != new.cgWindowID { return true }
            
            // Check if minimized state changed
            var currentMinimized: AnyObject?
            var newMinimized: AnyObject?
            let currentState = AXUIElementCopyAttributeValue(current.window, kAXMinimizedAttribute as CFString, &currentMinimized) == .success && (currentMinimized as? Bool == true)
            let newState = AXUIElementCopyAttributeValue(new.window, kAXMinimizedAttribute as CFString, &newMinimized) == .success && (newMinimized as? Bool == true)
            
            if currentState != newState { return true }
        }
        
        return false
    }

    func updateWindows(_ windows: [WindowInfo], for app: NSRunningApplication, at point: CGPoint) {
        // Update the chooser view with new windows
        chooserView?.updateWindows(windows, app: app)
        
        // Update window size if needed
        let newHeight = Constants.UI.windowHeight(for: windows.count)
        if window?.frame.height != newHeight {
            var frame = window?.frame ?? .zero
            frame.size.height = newHeight
            window?.setFrame(frame, display: true, animate: true)
        }
    }

    func updatePosition(_ point: CGPoint) {
        guard let window = window else { return }
        var frame = window.frame
        frame.origin.x = point.x - frame.width/2
        let dockHeight = DockService.shared.getDockMagnificationSize()
        frame.origin.y = dockHeight + Constants.UI.arrowOffset - 4
        window.setFrame(frame, display: true)
    }

    func prepareForReuse() {
        // Remove tracking area
        if let trackingArea = trackingArea,
           let contentView = window?.contentView {
            contentView.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        
        // Clean up view references
        chooserView = nil
    }
    
    deinit {
        // Remove observer
        NotificationCenter.default.removeObserver(self)
    }
} 