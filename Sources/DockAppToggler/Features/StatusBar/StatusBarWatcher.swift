import AppKit
import Cocoa
import ApplicationServices

extension Notification.Name {
    static let statusBarTooltipsStateChanged = Notification.Name("statusBarTooltipsStateChanged")
}

@MainActor
class TooltipWindow {
    private var window: NSWindow?
    
    func show(text: String, at location: NSPoint) {
        // Hide existing tooltip if any
        hide()
        
        // Create tooltip window
        let tooltip = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure tooltip window
        tooltip.level = .floating
        tooltip.isOpaque = false
        tooltip.hasShadow = true
        tooltip.isMovableByWindowBackground = false
        
        // Create content view with rounded corners and proper system appearance
        let contentView = NSVisualEffectView()
        contentView.wantsLayer = true
        contentView.material = .popover
        contentView.blendingMode = .withinWindow
        contentView.state = .active
        
        // Create a container view to handle the rounded corners
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.cornerRadius = 4
        containerView.layer?.masksToBounds = true
        
        // Set up view hierarchy
        containerView.addSubview(contentView)
        tooltip.contentView = containerView
        tooltip.backgroundColor = .clear
        
        // Create label with system font
        let label = NSTextField(frame: .zero)
        label.stringValue = text
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.textColor = .labelColor // Use system label color for automatic dark mode support
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1.5) // Slightly larger than system small font
        label.alignment = .center
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        
        // Calculate size and set frames
        let textSize = (text as NSString).size(withAttributes: [
            .font: label.font as Any
        ])
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 6
        let textBuffer: CGFloat = 8
        let windowWidth = textSize.width + horizontalPadding * 2 + textBuffer
        let windowHeight = textSize.height + verticalPadding * 2
        
        // Position window
        let windowX = location.x - windowWidth / 2
        
        // Calculate Y position relative to menu bar
        guard let screen = NSScreen.main else { return }
        let menuBarY = screen.frame.maxY
        let tooltipGap: CGFloat = 4
        let menuBarHeight: CGFloat = 24
        let windowY = menuBarY - menuBarHeight - windowHeight - tooltipGap
        
        // Set frames
        containerView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        contentView.frame = containerView.bounds
        
        // Then set window frame
        tooltip.setFrame(NSRect(x: windowX, y: windowY,
                              width: windowWidth, height: windowHeight),
                        display: false)
        
        // Center label in window with buffer space
        label.frame = NSRect(x: horizontalPadding,
                           y: verticalPadding,
                           width: textSize.width + textBuffer,
                           height: textSize.height)
        
        contentView.addSubview(label)
        tooltip.orderFront(nil)
        window = tooltip
    }
    
    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
class StatusBarWatcher {
    private var eventMonitor: Any?
    private var lastHoveredPid: pid_t = 0
    private var lastHoveredElement: AXUIElement?
    private let tooltipWindow = TooltipWindow()
    private var isEnabled: Bool
    
    init() {
        // Initialize with saved preference, default to true
        if UserDefaults.standard.object(forKey: "StatusBarTooltipsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "StatusBarTooltipsEnabled")
            self.isEnabled = true
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled")
        }
        
        if !checkAccessibilityPermissions() {
            print("[StatusBarWatcher] Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }
        
        setupNotificationObserver()
        if isEnabled {
            startWatching()
        }
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTooltipsStateChanged),
            name: .statusBarTooltipsStateChanged,
            object: nil
        )
    }
    
    @objc private func handleTooltipsStateChanged() {
        isEnabled = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled")
        if isEnabled {
            startWatching()
        } else {
            cleanup()
            tooltipWindow.hide()
        }
    }
    
    private nonisolated func checkAccessibilityPermissions() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func startWatching() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMove(event)
            }
        }
    }
    
    nonisolated func cleanup() {
        Task { @MainActor in
            if let monitor = self.eventMonitor {
                NSEvent.removeMonitor(monitor)
                self.eventMonitor = nil
            }
        }
    }
    
    deinit {
        cleanup()
    }
    
    // Helper function to compare AXUIElements
    private func areElementsEqual(_ element1: AXUIElement?, _ element2: AXUIElement?) -> Bool {
        guard let e1 = element1, let e2 = element2 else {
            return false
        }
        
        // Get PIDs for both elements
        var pid1: pid_t = 0
        var pid2: pid_t = 0
        guard AXUIElementGetPid(e1, &pid1) == .success,
              AXUIElementGetPid(e2, &pid2) == .success else {
            return false
        }
        
        // Compare PIDs and roles
        if pid1 != pid2 {
            return false
        }
        
        // Compare roles
        var role1Value: CFTypeRef?
        var role2Value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e1, kAXRoleAttribute as CFString, &role1Value) == .success,
              AXUIElementCopyAttributeValue(e2, kAXRoleAttribute as CFString, &role2Value) == .success else {
            return false
        }
        
        let role1 = (role1Value as? String) ?? ""
        let role2 = (role2Value as? String) ?? ""
        
        if role1 != role2 {
            return false
        }
        
        // Compare positions if possible
        var pos1Value: CFTypeRef?
        var pos2Value: CFTypeRef?
        if AXUIElementCopyAttributeValue(e1, kAXPositionAttribute as CFString, &pos1Value) == .success,
           AXUIElementCopyAttributeValue(e2, kAXPositionAttribute as CFString, &pos2Value) == .success,
           let pos1 = pos1Value as? NSValue,
           let pos2 = pos2Value as? NSValue {
            return pos1 == pos2
        }
        
        // If we can't compare positions, consider them different
        return false
    }
    
    private func handleMouseMove(_ event: NSEvent) {
        guard isEnabled else { return }
        let mouseLocation = NSEvent.mouseLocation
        let menuBarHeight: CGFloat = 24.0
        
        guard let screen = NSScreen.main else { return }
        
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
            
            let axX = Float(mouseLocation.x)
            let axY = Float(screen.frame.maxY - mouseLocation.y)
            
            let result = AXUIElementCopyElementAtPosition(
                sysWideElement,
                axX,
                axY,
                &hoveredElement
            )
            
            if result == .success, let element = hoveredElement {
                var roleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
                let role = (roleValue as? String) ?? ""
                
                var currentElement = element
                var foundStatusItem = false
                var iterations = 0
                let maxIterations = 5
                
                if role == "AXMenuExtra" || role == "AXMenuBarItem" {
                    foundStatusItem = true
                    currentElement = element
                } else {
                    while iterations < maxIterations {
                        var parentValue: CFTypeRef?
                        let parentResult = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue)
                        
                        if parentResult == .success, CFGetTypeID(parentValue!) == AXUIElementGetTypeID(),
                           let parent = parentValue as! AXUIElement? {
                            var parentRoleValue: CFTypeRef?
                            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &parentRoleValue)
                            let parentRole = (parentRoleValue as? String) ?? ""
                            
                            if parentRole == "AXMenuExtra" || parentRole == "AXMenuBarItem" {
                                foundStatusItem = true
                                currentElement = parent
                                break
                            }
                            
                            currentElement = parent
                        } else {
                            break
                        }
                        
                        iterations += 1
                    }
                }
                
                if foundStatusItem {
                    var pid: pid_t = 0
                    let pidResult = AXUIElementGetPid(currentElement, &pid)
                    
                    let isDifferentElement = !areElementsEqual(currentElement, lastHoveredElement)
                    if pidResult == .success && (isDifferentElement || pid != lastHoveredPid) {
                        lastHoveredPid = pid
                        lastHoveredElement = currentElement
                        if let runningApp = NSRunningApplication(processIdentifier: pid) {
                            let appName = runningApp.localizedName ?? "Unknown"
                            tooltipWindow.show(text: appName, at: mouseLocation)
                        }
                    }
                } else {
                    lastHoveredElement = nil
                    tooltipWindow.hide()
                }
            } else {
                lastHoveredElement = nil
                tooltipWindow.hide()
            }
        } else {
            lastHoveredPid = 0
            lastHoveredElement = nil
            tooltipWindow.hide()
        }
    }
} 