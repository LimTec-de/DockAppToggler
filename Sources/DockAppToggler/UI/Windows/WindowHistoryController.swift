import AppKit

@MainActor
class WindowHistoryController: NSWindowController {
    private var historyView: WindowChooserView?
    private var visualEffectView: NSVisualEffectView?
    private var trackingArea: NSTrackingArea?
    private var isClosing: Bool = false
    private let callback: (AXUIElement, Bool) -> Void
    private var trackingWindow: NSWindow?
    private var screenTrackingArea: NSTrackingArea?
    private var screenView: NSView?
    
    // Add throttled mouse movement handling
    private var lastMouseMovementTime: TimeInterval = 0
    private let mouseMovementThrottle: TimeInterval = 0.1 // 30fps max
    
    init(windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (AXUIElement, Bool) -> Void) {
        Logger.debug("Initializing WindowHistoryController...")
        self.callback = callback
        
        let height = Constants.UI.windowHeight(for: windows.count)
        let width = Constants.UI.windowWidth
        Logger.debug("  - Window dimensions: \(width)x\(height)")
        
        // Position at bottom of screen
        guard let screen = NSScreen.main else {
            Logger.error("No main screen available")
            fatalError("No main screen available")
        }
        
        // Position window at the absolute bottom of screen
        let frame = NSRect(
            x: (screen.frame.width - width) / 2,
            y: 0, // Place at bottom of screen
            width: width,
            height: height
        )
        Logger.debug("  - Window frame: \(frame)")
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        Logger.debug("  - Configuring window")
        configureWindow()
        setupVisualEffect(width: width, height: height)
        //setupChooserView(windows: windows, app: app)
        setupScreenTracking()
        animateAppearance()
        Logger.debug("WindowHistoryController initialization complete")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func configureWindow() {
        guard let window = window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .modalPanel
        window.appearance = NSApp.effectiveAppearance
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.transient, .canJoinAllSpaces]
        
        // Disable mouse moved events
        window.acceptsMouseMovedEvents = false
        
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true
        
        // Only track mouse enter/exit
        let trackingArea = NSTrackingArea(
            rect: window.contentView?.bounds ?? .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        window.contentView?.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }
    
    private func setupVisualEffect(width: CGFloat, height: CGFloat) {
        guard let window = window else { return }
        
        let visualEffect = BubbleVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.showsArrow = false  // Disable arrow for history window
        
        window.contentView = visualEffect
        self.visualEffectView = visualEffect
    }
    
    /*private func setupChooserView(windows: [WindowInfo], app: NSRunningApplication) {
        /*guard let contentView = window?.contentView else { return }
        
        let chooserView = WindowChooserView(
            windows: windows,
            appName: "Recent Windows",
            app: app,
            iconCenter: .zero,
            callback: callback
        )
        
        contentView.addSubview(chooserView)
        chooserView.frame = contentView.bounds
        self.historyView = chooserView*/
    }*/
    
    private func setupScreenTracking() {
        guard let screen = NSScreen.main else { return }
        
        // Create a minimal tracking window
        let trackingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: screen.frame.width, height: 50), // Only track bottom area
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        trackingWindow.backgroundColor = .clear
        trackingWindow.isOpaque = false
        trackingWindow.level = .popUpMenu - 1
        trackingWindow.ignoresMouseEvents = false
        trackingWindow.collectionBehavior = [.transient, .canJoinAllSpaces]
        
        // Create minimal tracking view
        let view = NSView(frame: trackingWindow.frame)
        trackingWindow.contentView = view
        self.screenView = view
        
        // Only track mouse enter/exit in bottom area
        let trackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea)
        self.screenTrackingArea = trackingArea
        
        // Position at bottom of screen
        trackingWindow.setFrameOrigin(NSPoint(x: 0, y: 0))
        trackingWindow.orderFront(nil)
        self.trackingWindow = trackingWindow
    }
    
    private func animateAppearance() {
        Logger.debug("Animating window appearance")
        guard let window = window else { return }
        
        window.alphaValue = 0
        window.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        // Only check if mouse moved up significantly
        let location = NSEvent.mouseLocation
        if location.y > 100 { // Increased threshold
            close()
        }
    }
    
    override func close() {
        Logger.debug("Closing history window")
        guard !isClosing else { return }
        isClosing = true
        
        // Clean up tracking
        if let trackingArea = screenTrackingArea {
            screenView?.removeTrackingArea(trackingArea)
        }
        screenView?.window?.close()
        screenView = nil
        screenTrackingArea = nil
        trackingWindow = nil
        
        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
            self?.cleanup()
        })
    }
    
    private func cleanup() {
        // Clean up tracking area
        if let trackingArea = trackingArea {
            window?.contentView?.removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        
        // Clean up views
        historyView = nil
        visualEffectView = nil
    }
} 