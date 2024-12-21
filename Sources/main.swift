// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import AppKit
import Carbon

class DockWatcher {
    private var eventTap: CFMachPort?
    private let workspace = NSWorkspace.shared
    
    init() {
        startMonitoring()
        print("🔄 DockWatcher initialized")
    }
    
    private func isAppActive(_ app: NSRunningApplication) -> Bool {
        return app.isActive
    }
    
    private func handleWindows(_ app: NSRunningApplication) -> Bool {
        // Check if app is active
        if isAppActive(app) {
            // If app is active, hide it
            print("👻 Hiding app: \(app.localizedName ?? "Unknown")")
            _ = app.hide()
            return true // Indicate we handled it and should consume the event
        } else {
            // If app wasn't active, let Dock handle activation
            print("⬆️ Letting Dock activate: \(app.localizedName ?? "Unknown")")
            return false // Let the event pass through to the Dock
        }
    }
    
    private func handleDockClick(at point: CGPoint) -> Bool {
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
                        handled = handleWindows(app)
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
                
                // If we handled an active app click, consume the event
                if watcher.handleDockClick(at: location) {
                    return nil // Consume the event when we hide an active app
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
    
    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
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
