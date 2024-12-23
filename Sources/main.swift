// The Swift Programming Language
// https://docs.swift.org/swift-book

@preconcurrency import Foundation
import AppKit
import Carbon

class WindowChooserView: NSView {
    private var options: [(windowID: CGWindowID, name: String)] = []
    private var callback: ((CGWindowID) -> Void)?
    private var buttons: [NSButton] = []
    
    init(windows: [(windowID: CGWindowID, name: String)], callback: @escaping (CGWindowID) -> Void) {
        self.options = windows
        self.callback = callback
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(windows.count * 40)))
        setupButtons()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupButtons() {
        for (index, window) in options.enumerated() {
            let button = NSButton(frame: NSRect(x: 10, y: frame.height - CGFloat((index + 1) * 35), width: 280, height: 30))
            button.title = window.name
            button.bezelStyle = .rounded
            button.tag = index
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            
            // Style the button
            button.isBordered = false
            button.contentTintColor = .white
            
            // Add hover effect
            let trackingArea = NSTrackingArea(rect: button.bounds,
                                            options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                            owner: button,
                                            userInfo: nil)
            button.addTrackingArea(trackingArea)
            
            addSubview(button)
            buttons.append(button)
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                button.layer?.backgroundColor = NSColor.selectedControlColor.cgColor
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                button.layer?.backgroundColor = nil
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        let windowID = options[sender.tag].windowID
        callback?(windowID)
        window?.close()
    }
}

class WindowChooserWindow: NSWindow {
    init(at point: CGPoint, windows: [(windowID: CGWindowID, name: String)], callback: @escaping (CGWindowID) -> Void) {
        let height = CGFloat(windows.count * 40)
        let width: CGFloat = 300
        
        // Get the main screen and convert the point to proper screen coordinates
        guard let screen = NSScreen.main else {
            // Fallback to a default position if no screen is available
            super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless],
                      backing: .buffered,
                      defer: false)
            return
        }
        
        // Calculate position to be centered horizontally above the clicked point
        let adjustedX = max(20, min(point.x - width/2, screen.frame.width - width - 20))
        
        // Convert CG coordinates (0 at bottom) to NS coordinates (0 at top)
        let nsY = screen.frame.height - point.y
        // We want the window to appear above the click point, so subtract the height and add a small gap
        let adjustedY = nsY - height - 10
        
        print("📏 Screen height: \(screen.frame.height), CG Y: \(point.y), NS Y: \(nsY), Window Y: \(adjustedY)")
        
        let contentRect = NSRect(x: adjustedX, y: adjustedY, width: width, height: height)
        super.init(contentRect: contentRect,
                  styleMask: [.borderless],
                  backing: .buffered,
                  defer: false)
        
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .popUpMenu
        
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        contentView = visualEffect
        
        let chooserView = WindowChooserView(windows: windows, callback: callback)
        visualEffect.addSubview(chooserView)
        
        // Add animation
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
        
        // Ensure window is fully visible on screen
        let screenFrame = screen.visibleFrame
        var windowFrame = frame
        
        // Adjust if window would go off the top of the screen
        if windowFrame.maxY > screenFrame.maxY {
            windowFrame.origin.y = screenFrame.maxY - windowFrame.height - 10
        }
        
        // Adjust if window would go off the bottom of the screen
        if windowFrame.minY < screenFrame.minY {
            windowFrame.origin.y = screenFrame.minY + 10
        }
        
        setFrame(windowFrame, display: true)
    }
}

@MainActor
class DockWatcher {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    private let workspace = NSWorkspace.shared
    private var windowChooser: WindowChooserWindow?
    
    init() {
        startMonitoring()
        print("🔄 DockWatcher initialized")
    }
    
    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
    
    private func isAppActive(_ app: NSRunningApplication) -> Bool {
        return app.isActive
    }
    
    private func showWindowChooser(for app: NSRunningApplication, at point: CGPoint, windows: [(windowID: CGWindowID, name: String)]) {
        guard !windows.isEmpty else {
            print("⚠️ No windows provided")
            return
        }
        
        DispatchQueue.main.async {
            print("🎯 Showing window chooser at \(point.x), \(point.y)")
            self.windowChooser = WindowChooserWindow(at: point, windows: windows, callback: { windowID in
                print("🎯 Selected window with ID: \(windowID)")
                // Activate the chosen window
                app.activate(options: [.activateIgnoringOtherApps])
                
                // Bring the specific window to front using AX API
                let element = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let windowList = windowsRef as? [AXUIElement] {
                    
                    // Find the window with matching ID
                    for window in windowList {
                        var windowIDRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(window, "_AXWindowID" as CFString, &windowIDRef) == .success,
                           let windowNumber = (windowIDRef as? NSNumber)?.uint32Value,
                           windowNumber == windowID {
                            print("🎯 Found matching window, raising it")
                            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                            break
                        }
                    }
                }
            })
            self.windowChooser?.makeKeyAndOrderFront(nil)
        }
    }
    
    private func handleDockClick(at point: CGPoint, clickCount: Int64) -> Bool {
        // Find Dock process
        guard let dockApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return false
        }
        
        let systemWide = AXUIElementCreateSystemWide()
        var elementUntyped: AXUIElement?
        var handled = false
        
        if AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementUntyped) == .success,
           let element = elementUntyped {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success,
               pid == dockApp.processIdentifier {
                
                var urlUntyped: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlUntyped) == .success,
                   let urlRef = urlUntyped as? NSURL,
                   let url = urlRef as URL? {
                    print("🖱️ Dock icon clicked: \(url.deletingPathExtension().lastPathComponent)")
                    
                    if let bundle = Bundle(url: url),
                       let bundleId = bundle.bundleIdentifier,
                       let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                        
                        // Get windows using Accessibility API
                        let element = AXUIElementCreateApplication(app.processIdentifier)
                        var windowsRef: CFTypeRef?
                        
                        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                           let windowList = windowsRef as? [AXUIElement] {
                            
                            let windowCount = windowList.count
                            print("🔍 Found \(windowCount) windows for \(app.localizedName ?? "Unknown")")
                            
                            if windowCount > 1 {
                                print("📱 App active: \(isAppActive(app))")
                                
                                // Build window info list with simple numbered names
                                var appWindowsInfo: [(windowID: CGWindowID, name: String)] = []
                                
                                for (index, window) in windowList.enumerated() {
                                    print("\n🪟 Checking window \(index + 1):")
                                    
                                    // Get all attributes for debugging
                                    var attributeNames: CFArray?
                                    AXUIElementCopyAttributeNames(window, &attributeNames)
                                    if let attributes = attributeNames as? [String] {
                                        print("📝 Available attributes: \(attributes.joined(separator: ", "))")
                                    }
                                    
                                    var windowIDRef: CFTypeRef?
                                    let result = AXUIElementCopyAttributeValue(window, "_AXWindowID" as CFString, &windowIDRef)
                                    print("🔑 Window ID result: \(result)")
                                    
                                    if result == .success,
                                       let numRef = windowIDRef,
                                       let number = numRef as? NSNumber {
                                        let windowID = number.uint32Value
                                        let windowName = "\(app.localizedName ?? "Window") \(index + 1)"
                                        print("✅ Adding window: '\(windowName)' ID: \(windowID)")
                                        appWindowsInfo.append((windowID: windowID, name: windowName))
                                    } else {
                                        print("❌ Failed to get window ID")
                                        
                                        // Try getting window ID from CGWindowList as fallback
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
                                        
                                        if index < matchingWindows.count,
                                           let windowID = matchingWindows[index][kCGWindowNumber] as? CGWindowID {
                                            let windowName = "\(app.localizedName ?? "Window") \(index + 1)"
                                            print("✅ Adding window (fallback): '\(windowName)' ID: \(windowID)")
                                            appWindowsInfo.append((windowID: windowID, name: windowName))
                                        }
                                    }
                                }
                                
                                print("📊 Found \(appWindowsInfo.count) windows")
                                
                                if appWindowsInfo.count > 1 && !isAppActive(app) {
                                    print("🎯 Showing window chooser for multiple windows")
                                    showWindowChooser(for: app, at: point, windows: appWindowsInfo)
                                    handled = true
                                    return handled
                                }
                            }
                            
                            if isAppActive(app) {
                                if clickCount == 2 {
                                    // Double click on active app: terminate
                                    print("🚫 Double-click detected, terminating app: \(app.localizedName ?? "Unknown")")
                                    _ = app.terminate()
                                    handled = true
                                } else {
                                    // Single click on active app: hide
                                    print("👻 Single-click detected, hiding app: \(app.localizedName ?? "Unknown")")
                                    _ = app.hide()
                                    handled = true
                                }
                            } else {
                                print("⬆️ Letting Dock handle click: \(app.localizedName ?? "Unknown")")
                                handled = false
                            }
                        }
                    }
                }
            }
        }
        
        return handled
    }
    
    private func startMonitoring() {
        // Request accessibility permissions
        let trusted = AXIsProcessTrusted()
        print("🔐 Accessibility \(trusted ? "granted" : "not granted - please grant in System Settings")")
        
        guard trusted else {
            print("⚠️ Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }
        
        // Create event tap for mouse clicks
        let eventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                if type != .leftMouseDown {
                    return Unmanaged.passRetained(event)
                }
                
                let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                let location = event.location
                let clickCount = event.getIntegerValueField(.mouseEventClickState)
                
                // If we handled the click (either hide or terminate), consume the event
                if watcher.handleDockClick(at: location, clickCount: clickCount) {
                    return nil
                }
                
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Failed to create event tap")
            return
        }
        
        self.eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        print("✅ Successfully started monitoring Dock clicks. Press Control + C to stop.")
    }
}

@MainActor
class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    
    init() {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        
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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

print("Starting Dock Watcher...")
let app = NSApplication.shared
let watcher = DockWatcher()
let statusBar = StatusBarController()
app.run()
