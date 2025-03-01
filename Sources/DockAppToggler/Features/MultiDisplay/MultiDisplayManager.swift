import AppKit

/// Manages the application's presence on multiple displays when "displays have separate spaces" is enabled
@MainActor
class MultiDisplayManager {
    // Singleton instance
    static let shared = MultiDisplayManager()
    
    // Keep track of screen observers
    private var screenObserver: Any?
    
    // Keep track of event monitors
    private var eventMonitors: [Any] = []
    
    // Keep track of the app's presence on each screen
    private var screenPresence: [NSScreen: Bool] = [:]
    
    // Initialize
    private init() {
        // Start monitoring for screen changes
        setupScreenObserver()
    }
    
    /// Start monitoring for screen configuration changes
    func setupScreenObserver() {
        // Remove existing observer if any
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Add observer for screen changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Use Task to call the actor-isolated method from a non-isolated context
            Task { @MainActor [weak self] in
                self?.handleScreenConfigurationChange()
            }
        }
        
        // Initial setup
        handleScreenConfigurationChange()
    }
    
    /// Handle changes in screen configuration
    func handleScreenConfigurationChange() {
        Logger.debug("Screen configuration changed. Displays have separate spaces: \(NSScreen.displaysHaveSeparateSpaces)")
        
        // Only take action if displays have separate spaces
        guard NSScreen.displaysHaveSeparateSpaces else {
            Logger.debug("Displays do not have separate spaces, no action needed")
            return
        }
        
        // Check if we need to ensure presence on all screens
        ensureAppPresenceOnAllScreens()
    }
    
    /// Ensure the app is present on all screens when needed
    func ensureAppPresenceOnAllScreens() {
        // Only take action if displays have separate spaces
        guard NSScreen.displaysHaveSeparateSpaces else { return }
        
        // Get all screens
        let screens = NSScreen.screens
        
        //Logger.info("Ensuring app presence on \(screens.count) screens")
        
        // For each screen, ensure we have an event tap
        for screen in screens {
            if screenPresence[screen] != true {
                Logger.debug("Setting up presence on screen: \(screen)")
                setupPresenceOnScreen(screen)
            }
        }
    }
    
    /// Ensure a specific window is visible on all spaces
    func ensureWindowVisibleOnAllSpaces(_ window: NSWindow) {
        // Only take action if displays have separate spaces
        guard NSScreen.displaysHaveSeparateSpaces else { return }
        
        // Configure window for all spaces
        if !window.collectionBehavior.contains(.canJoinAllSpaces) {
            Logger.debug("Configuring window to be visible on all spaces")
            window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        }
        
        // Set appropriate window level
        if window.level < NSWindow.Level.floating {
            window.level = NSWindow.Level.floating
        }
        
        // Ensure window is visible
        if !window.isVisible {
            window.orderFront(nil)
        }
    }
    
    /// Set up app presence on a specific screen
    private func setupPresenceOnScreen(_ screen: NSScreen) {
        // Create a minimal, invisible window on the screen to ensure our app is present there
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure the window to be invisible but present
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        
        // Show the window
        window.orderFront(nil)
        
        // Mark this screen as having presence
        screenPresence[screen] = true
        
        Logger.success("Successfully established presence on screen: \(screen)")
    }
    
    /// Clean up resources
    func cleanup() {
        // Remove screen observer
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        
        // Remove event monitors
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
    
    deinit {
        // Use Task to call the actor-isolated method from a non-isolated context
        Task { @MainActor [weak self] in
            self?.cleanup()
        }
    }
} 