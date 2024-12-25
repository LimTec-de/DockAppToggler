/// DockAppToggler: A macOS utility that enhances Dock functionality by providing window management
/// and app control features through Dock icon interactions.
///
/// Features:
/// - Window selection for apps with multiple windows
/// - Single-click to hide active apps
/// - Double-click to terminate active apps
/// - Modern UI with hover effects and animations

@preconcurrency import Foundation
import AppKit
import Carbon
import Sparkle

// MARK: - Type Aliases and Constants

/// Represents information about a window, including its ID and display name
typealias WindowInfo = (windowID: CGWindowID, name: String)

/// Application-wide constants
enum Constants {
    /// UI-related constants
    enum UI {
        static let windowWidth: CGFloat = 200
        static let buttonHeight: CGFloat = 30
        static let buttonSpacing: CGFloat = 32
        static let cornerRadius: CGFloat = 10
        static let windowPadding: CGFloat = 8
        static let animationDuration: TimeInterval = 0.2
        
        // Additional constants for window sizing
        static let verticalPadding: CGFloat = 4
        
        // Calculate total height needed for a given number of buttons
        static func windowHeight(for buttonCount: Int) -> CGFloat {
            return CGFloat(buttonCount) * (buttonHeight + 2) + verticalPadding * 2
        }
    }
    
    /// Bundle identifiers
    enum Identifiers {
        static let dockBundleID = "com.apple.dock"
    }
    
    /// Accessibility-related constants
    enum Accessibility {
        static let windowIDKey = "_AXWindowID" as CFString
        static let windowsKey = kAXWindowsAttribute as CFString
        static let urlKey = kAXURLAttribute as CFString
        static let raiseKey = kAXRaiseAction as CFString
    }
}

// MARK: - Logging

/// Centralized logging functionality with different log levels and emoji indicators
enum Logger {
    static func debug(_ message: String) {
        print("🔍 \(message)")
    }
    
    static func info(_ message: String) {
        print("ℹ️ \(message)")
    }
    
    static func warning(_ message: String) {
        print("⚠️ \(message)")
    }
    
    static func error(_ message: String) {
        print("❌ \(message)")
    }
    
    static func success(_ message: String) {
        print("✅ \(message)")
    }
}

// MARK: - UI Components

/// A custom view that displays a list of windows as buttons with hover effects
class WindowChooserView: NSView {
    private var options: [WindowInfo] = []
    private var callback: ((CGWindowID) -> Void)?
    private var buttons: [NSButton] = []
    
    init(windows: [WindowInfo], callback: @escaping (CGWindowID) -> Void) {
        self.options = windows
        self.callback = callback
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.UI.windowWidth, height: Constants.UI.windowHeight(for: windows.count)))
        setupButtons()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupButtons() {
        for (index, window) in options.enumerated() {
            let button = createButton(for: window, at: index)
            addSubview(button)
            buttons.append(button)
        }
    }
    
    private func createButton(for window: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton(frame: NSRect(
            x: Constants.UI.windowPadding,
            y: frame.height - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: Constants.UI.windowWidth - Constants.UI.windowPadding * 2,
            height: Constants.UI.buttonHeight
        ))
        
        configureButton(button, title: window.name, tag: index)
        addHoverEffect(to: button)
        
        return button
    }
    
    private func configureButton(_ button: NSButton, title: String, tag: Int) {
        button.title = title
        button.bezelStyle = .inline
        button.tag = tag
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.wantsLayer = true
        
        button.isBordered = false
        button.font = .menuFont(ofSize: 13)
        button.contentTintColor = .white
        
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryLight)
    }
    
    private func addHoverEffect(to button: NSButton) {
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: button,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.UI.animationDuration
                button.contentTintColor = .selectedMenuItemTextColor
                button.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.UI.animationDuration
                button.contentTintColor = .labelColor
                button.layer?.backgroundColor = .clear
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        let windowID = options[sender.tag].windowID
        callback?(windowID)
        window?.close()
    }
}

/// A custom window controller that manages the window chooser interface
class WindowChooserController: NSWindowController {
    private let windowCallback: (CGWindowID) -> Void
    private var chooserView: WindowChooserView?
    private let targetApp: NSRunningApplication
    private var trackingArea: NSTrackingArea?
    private let dismissalMargin: CGFloat = 20.0  // Pixels of margin around the window
    
    init(at point: CGPoint, windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (CGWindowID) -> Void) {
        self.windowCallback = callback
        self.targetApp = app
        
        let height = Constants.UI.windowHeight(for: windows.count)
        let width = Constants.UI.windowWidth
        
        let screen = NSScreen.main ?? NSScreen.screens[0]
        
        // Keep x position aligned with the Dock icon click
        let adjustedX = max(Constants.UI.windowPadding, 
                           min(point.x - width/2, 
                               screen.frame.width - width - Constants.UI.windowPadding))
        
        // Position above the Dock (Dock is at the bottom of the screen)
        let dockHeight: CGFloat = 70 // Approximate Dock height
        let adjustedY = dockHeight + Constants.UI.windowPadding
        
        Logger.info("Positioning window chooser at x: \(adjustedX), y: \(adjustedY) (click at: \(point.x), \(point.y))")
        
        let frame = NSRect(x: adjustedX, y: adjustedY, width: width, height: height)
        
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
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func configureWindow() {
        guard let window = window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.appearance = NSAppearance(named: .vibrantDark)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true
    }
    
    private func setupVisualEffect(width: CGFloat, height: CGFloat) {
        guard let window = window else { return }
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        window.contentView = visualEffect
    }
    
    private func setupChooserView(windows: [WindowInfo]) {
        guard let contentView = window?.contentView else { return }
        let chooserView = WindowChooserView(windows: windows) { [weak self] windowID in
            guard let self = self else { return }
            Logger.info("Selected window with ID: \(windowID)")
            // First raise the window
            AccessibilityService.shared.raiseWindow(windowID: windowID, for: self.targetApp)
            // Hide other windows individually
            for window in windows where window.windowID != windowID {
                AccessibilityService.shared.hideWindow(windowID: window.windowID, for: self.targetApp)
            }
            // Close the chooser window
            self.close()
        }
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
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        
        // Add a small delay before closing to prevent accidental dismissals
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self,
                  let window = self.window,
                  let mouseLocation = NSEvent.mouseLocation.cgPoint else { return }
            
            // Create an expanded frame with margin
            let expandedFrame = NSRect(
                x: window.frame.minX - self.dismissalMargin,
                y: window.frame.minY - self.dismissalMargin,
                width: window.frame.width + (self.dismissalMargin * 2),
                height: window.frame.height + (self.dismissalMargin * 2)
            )
            
            // Check if mouse is outside the expanded frame
            if !expandedFrame.contains(mouseLocation) {
                self.close()
            }
        }
    }
}

// Helper extension to convert NSPoint to CGPoint
extension NSPoint {
    var cgPoint: CGPoint? {
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Service

@MainActor
class AccessibilityService {
    static let shared = AccessibilityService()
    
    private init() {}
    
    func requestAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        Logger.info("🔐 Accessibility \(trusted ? "granted" : "not granted - please grant in System Settings")")
        
        if !trusted {
            Logger.warning("⚠️ Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
        }
        
        return trusted
    }
    
    func getWindowInfo(for app: NSRunningApplication) -> [WindowInfo] {
        // First activate the app to ensure windows are accessible
        app.activate(options: [.activateIgnoringOtherApps])
        
        // Try up to 3 times with a small delay
        for attempt in 1...3 {
            var appWindowsInfo: [WindowInfo] = []
            
            // Use CGWindow API with options to include minimized windows
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements, .optionAll]
            guard let cgWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
                continue
            }
            
            // Sort windows by layer and position to maintain consistent order
            let sortedWindows = cgWindows.filter { window -> Bool in
                guard let pid = window[kCGWindowOwnerPID] as? pid_t,
                      pid == app.processIdentifier,
                      let layer = window[kCGWindowLayer] as? Int32,
                      layer == 0 else { // Only normal windows
                    return false
                }
                return true
            }.sorted { first, second -> Bool in
                // Sort by window order (lower numbers are more frontmost)
                let order1 = first[kCGWindowNumber] as? CGWindowID ?? 0
                let order2 = second[kCGWindowNumber] as? CGWindowID ?? 0
                return order1 < order2
            }
            
            for window in sortedWindows {
                if let windowID = window[kCGWindowNumber] as? CGWindowID,
                   let title = window[kCGWindowName as CFString] as? String,
                   !title.isEmpty {
                    // Check if window is minimized
                    let isMinimized = window[kCGWindowIsOnscreen as CFString] as? Bool == false
                    let displayTitle = isMinimized ? "\(title) (minimized)" : title
                    Logger.success("Found window: '\(displayTitle)' with ID: \(windowID)")
                    appWindowsInfo.append((windowID: windowID, name: displayTitle))
                }
            }
            
            if !appWindowsInfo.isEmpty {
                Logger.info("📊 Found \(appWindowsInfo.count) valid windows")
                
                // Log the final window list for verification
                for (index, window) in appWindowsInfo.enumerated() {
                    Logger.info("Window \(index + 1): '\(window.name)' (ID: \(window.windowID))")
                }
                
                return appWindowsInfo
            }
            
            Logger.warning("Attempt \(attempt): No windows found, retrying...")
            Thread.sleep(forTimeInterval: 0.1) // Small delay before retry
        }
        
        Logger.error("Failed to find any windows after 3 attempts")
        return []
    }
    
    private func getWindowID(for window: AXUIElement, app: NSRunningApplication, index: Int) -> WindowInfo? {
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
        
        let windowID = number.uint32Value
        let windowName = windowTitle
        Logger.success("Adding window: '\(windowName)' ID: \(windowID)")
        return (windowID: windowID, name: windowName)
    }
    
    private func getFallbackWindowID(for app: NSRunningApplication, index: Int) -> WindowInfo? {
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
              let windowID = matchingWindows[index][kCGWindowNumber] as? CGWindowID else {
            return nil
        }
        
        // Get the actual window name from CGWindowListCopyWindowInfo
        let windowTitle = matchingWindows[index][kCGWindowName as CFString] as? String
        let windowName = windowTitle ?? "\(app.localizedName ?? "Window") \(index + 1)"
        
        Logger.success("Adding window (fallback): '\(windowName)' ID: \(windowID)")
        return (windowID: windowID, name: windowName)
    }
    
    func raiseWindow(windowID: CGWindowID, for app: NSRunningApplication) {
        // First activate the app
        app.activate(options: [.activateIgnoringOtherApps])
        
        // Get the window list to find the title for our windowID
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return
        }
        
        // Find our window's title
        var targetTitle: String?
        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let wid = window[kCGWindowNumber] as? CGWindowID,
                  wid == windowID,
                  let title = window[kCGWindowName as CFString] as? String else {
                continue
            }
            targetTitle = title
            break
        }
        
        guard let windowTitle = targetTitle else { return }
        Logger.info("Raising window with title: '\(windowTitle)'")
        
        // Use AppleScript to raise the specific window by title
        let script = """
        tell application "System Events"
            tell process "\(app.localizedName ?? "")"
                set frontmost to true
                delay 0.1
                perform action "AXRaise" of window "\(windowTitle)"
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                Logger.error("Failed to execute AppleScript: \(error)")
            }
        }
    }
    
    func hideWindow(windowID: CGWindowID, for app: NSRunningApplication) {
        // Create AX UI element for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get all windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            Logger.error("Failed to get windows from AX UI element")
            return
        }
        
        // Find and minimize the matching window
        for window in windows {
            var windowIDRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDRef) == .success,
                  let numRef = windowIDRef as? NSNumber,
                  numRef.uint32Value == windowID else {
                continue
            }
            
            // Perform minimize action
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            break
        }
    }
}

// MARK: - Dock Service

@MainActor
class DockService {
    static let shared = DockService()
    private let workspace = NSWorkspace.shared
    
    private init() {}
    
    func getDockApp() -> NSRunningApplication? {
        return workspace.runningApplications.first(where: { $0.bundleIdentifier == Constants.Identifiers.dockBundleID })
    }
    
    func getClickedDockItem(at point: CGPoint) -> (app: NSRunningApplication, url: URL)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementUntyped: AXUIElement?
        
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementUntyped) == .success,
              let element = elementUntyped else {
            return nil
        }
        
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let dockApp = getDockApp(),
              pid == dockApp.processIdentifier else {
            return nil
        }
        
        var urlUntyped: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, Constants.Accessibility.urlKey, &urlUntyped) == .success,
              let urlRef = urlUntyped as? NSURL,
              let url = urlRef as URL?,
              let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier,
              let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return nil
        }
        
        Logger.info("Dock icon clicked: \(url.deletingPathExtension().lastPathComponent)")
        return (app: app, url: url)
    }
    
    func handleAppAction(app: NSRunningApplication, clickCount: Int64) -> Bool {
        if app.isActive {
            if clickCount == 2 {
                Logger.info("Double-click detected, terminating app: \(app.localizedName ?? "Unknown")")
                return app.terminate()
            } else {
                Logger.info("Single-click detected, hiding app: \(app.localizedName ?? "Unknown")")
                return app.hide()
            }
        }
        
        Logger.info("Letting Dock handle click: \(app.localizedName ?? "Unknown")")
        return false
    }
}

// Update DockWatcher to use DockService
@MainActor
class DockWatcher {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    private var windowChooser: WindowChooserController?
    private var runLoopSource: CFRunLoopSource?
    
    init() {
        startMonitoring()
        Logger.info("DockWatcher initialized")
    }
    
    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
    
    private func showWindowChooser(for app: NSRunningApplication, at point: CGPoint, windows: [WindowInfo]) {
        guard !windows.isEmpty else {
            Logger.warning("No windows provided")
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            Logger.info("Showing window chooser at \(point.x), \(point.y)")
            
            let chooser = WindowChooserController(
                at: point,
                windows: windows,
                app: app,
                callback: { windowID in
                    Logger.info("Selected window with ID: \(windowID)")
                    // First raise the window
                    AccessibilityService.shared.raiseWindow(windowID: windowID, for: app)
                    // Hide other windows
                    for window in windows where window.windowID != windowID {
                        app.hide()
                    }
                }
            )
            
            self?.windowChooser = chooser
            chooser.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    private func startMonitoring() {
        guard AccessibilityService.shared.requestAccessibilityPermissions() else {
            return
        }
        
        let eventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        
        // Create a static callback function
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard type == .leftMouseDown,
                  let refconUnwrapped = refcon else {
                return Unmanaged.passRetained(event)
            }
            
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refconUnwrapped).takeUnretainedValue()
            let location = event.location
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            
            // Try to handle the click first
            if watcher.handleDockClick(at: location, clickCount: clickCount) {
                // If we handled it, prevent the event from propagating
                return nil
            }
            
            // If we didn't handle it, let the event propagate
            return Unmanaged.passRetained(event)
        }
        
        // Change the event tap to be a CGEventTapLocation.cghidEventTap to intercept events earlier
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,  // Changed from .cgSessionEventTap to intercept earlier
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.warning("Failed to create event tap")
            return
        }
        
        self.eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        self.runLoopSource = runLoopSource
        
        CGEvent.tapEnable(tap: tap, enable: true)
        
        Logger.success("Successfully started monitoring Dock clicks. Press Control + C to stop.")
    }
    
    private func handleDockClick(at point: CGPoint, clickCount: Int64) -> Bool {
        // First check if we clicked on a Dock item
        guard let (app, _) = DockService.shared.getClickedDockItem(at: point) else {
            return false
        }
        
        // If the app is active, handle hide/terminate actions immediately
        if app.isActive {
            _ = DockService.shared.handleAppAction(app: app, clickCount: clickCount)
            // Always return true for active apps to prevent Dock from processing the click
            return true
        }
        
        // Get window information for inactive apps
        let windows = AccessibilityService.shared.getWindowInfo(for: app)
        
        // Show window chooser if:
        // - there are multiple windows OR
        // - there is at least one minimized window (indicated by "(minimized)" in the name)
        let hasMinimizedWindow = windows.contains { $0.name.contains("(minimized)") }
        if windows.count > 1 || hasMinimizedWindow {
            Logger.info("Showing window chooser for \(windows.count) windows (minimized windows present: \(hasMinimizedWindow))")
            showWindowChooser(for: app, at: point, windows: windows)
            return true
        }
        
        // Let the Dock handle the click for other cases
        return false
    }
}

@MainActor
class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private let updateController: UpdateController
    
    init() {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        updateController = UpdateController()
        
        if let button = statusItem.button {
            if let iconPath = Bundle.module.path(forResource: "icon", ofType: "png"),
               let image = NSImage(contentsOfFile: iconPath) {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
        }
        
        setupMenu()
    }
    
    private func setupMenu() {
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc private func checkForUpdates() {
        updateController.checkForUpdates()
    }
}

// MARK: - Application Entry Point

Logger.info("Starting Dock App Toggler...")
let app = NSApplication.shared
// Store references to prevent deallocation
let appController = (
    watcher: DockWatcher(),
    statusBar: StatusBarController()
)
app.run()

// Add this new class for handling updates
@MainActor
class UpdateController {
    private let updater: SPUUpdater
    private let driver: SPUStandardUserDriver
    
    init() {
        driver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        do {
            updater = try SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: driver, delegate: nil)
            try updater.start()
            Logger.info("Sparkle updater initialized successfully")
        } catch {
            Logger.error("Failed to initialize Sparkle: \(error)")
        }
    }
    
    func checkForUpdates() {
        updater.checkForUpdates()
    }
}