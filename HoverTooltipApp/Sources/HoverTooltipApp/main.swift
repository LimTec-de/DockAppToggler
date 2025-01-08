import SwiftUI
import AppKit
import ApplicationServices

@main
struct HoverTooltipApp: App {
    // Hook up the NSApplicationDelegate below
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            // Minimal SwiftUI content
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Hover over the menu bar icons to see tooltips with app names")
            .padding()
            .frame(width: 400, height: 100)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var tooltipWindow: NSWindow?
    private var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Application finished launching.")
        
        // Request accessibility permissions
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
        
        if !accessibilityEnabled {
            print("Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }
        
        // Create global mouse tracking
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMove(event)
        }
        
        print("Global mouse event monitor set up.")
    }
    
    private func handleMouseMove(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation
        let menuBarHeight: CGFloat = 24.0  // approximate menu bar height
        
        guard let screen = NSScreen.main else {
            print("No main screen available.")
            return
        }
        
        // Is mouse in the menu bar?
        let maxY = screen.frame.maxY
        let menuBarRect = NSRect(
            x: screen.frame.minX,
            y: maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        
        if menuBarRect.contains(mouseLocation) {
            let sysWideElement = AXUIElementCreateSystemWide()
            var hoveredElement: AXUIElement?
            
            // Convert coordinates to the accessibility coordinate system
            // The origin is at the top-left corner of the main screen
            let axX = Float(mouseLocation.x)
            let axY = Float(mouseLocation.y)
            
            let result = AXUIElementCopyElementAtPosition(
                sysWideElement,
                axX,
                axY,
                &hoveredElement
            )
            
            if result == .success, let element = hoveredElement {
                var pid: pid_t = 0
                let pidResult = AXUIElementGetPid(element, &pid)
                
                if pidResult == .success {
                    if let runningApp = NSRunningApplication(processIdentifier: pid) {
                        let appName = runningApp.localizedName ?? "Unknown"
                        print("Hovering over process \(pid) appName=\(appName)")
                        showTooltip(title: appName, location: mouseLocation)
                        return
                    } else {
                        print("No NSRunningApplication for process \(pid)")
                    }
                } else {
                    print("Could not get PID: \(pidResult)")
                }
            } else {
                print("Failed to retrieve an AX element at mouse location: \(result)")
            }
        }
        
        // If not in menu bar or no name found, hide tooltip
        hideTooltip()
    }
    
    private func showTooltip(title: String, location: NSPoint) {
        if tooltipWindow == nil {
            tooltipWindow = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            tooltipWindow?.level = .floating
            tooltipWindow?.isOpaque = false
            tooltipWindow?.backgroundColor = .clear
            tooltipWindow?.hasShadow = true
            print("Created tooltip window.")
        }
        
        guard let window = tooltipWindow else { return }

        let label = NSTextField(frame: .zero)
        label.stringValue = title
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.textColor = .white
        
        let textSize = label.intrinsicContentSize
        let padding: CGFloat = 6
        let windowWidth = textSize.width + padding * 2
        let windowHeight = textSize.height + padding * 2
        let windowX = location.x - windowWidth / 2
        let windowY = location.y - windowHeight - 10
        
        window.setFrame(NSRect(x: windowX, y: windowY,
                               width: windowWidth, height: windowHeight),
                        display: true)
        
        label.frame = NSRect(x: padding, y: padding / 2,
                             width: textSize.width, height: textSize.height)
        
        let contentView = NSView(frame: window.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        contentView.layer?.cornerRadius = 5
        contentView.addSubview(label)
        
        window.contentView = contentView
        window.orderFront(nil)
        print("Tooltip shown at (\(windowX), \(windowY)) with text: \(title)")
    }
    
    private func hideTooltip() {
        if tooltipWindow?.isVisible == true {
            print("Hiding tooltip.")
        }
        tooltipWindow?.orderOut(nil)
    }
}
