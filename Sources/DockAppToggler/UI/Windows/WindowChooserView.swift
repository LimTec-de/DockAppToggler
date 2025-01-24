import AppKit

/// A custom view that displays a list of windows as buttons with hover effects
/// A custom view that displays a list of windows as buttons with hover effects
class WindowChooserView: NSView {
    // Change from private to internal
    var options: [WindowInfo] = []
    private var callback: ((AXUIElement, Bool) -> Void)?
    private var buttons: [NSButton] = []
    private var hideButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private var titleField: NSTextField!
    private let targetApp: NSRunningApplication
    private var lastMaximizeClickTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.3
    internal var topmostWindow: AXUIElement?
    private var lastClickTime: TimeInterval = 0
    // Add property to store dock icon center
    private let dockIconCenter: NSPoint
    // Add new property to store thumbnail view
    private var thumbnailView: WindowThumbnailView?
    
    // Change from instance method to static method
    private static func sortWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        // First filter out small windows
        let filteredWindows = windows.filter { windowInfo in
            // Always include app elements
            if windowInfo.isAppElement {
                return true
            }
            
            // For regular windows, check size
            if windowInfo.window != nil {
                var sizeValue: AnyObject?
                var size = CGSize.zero
                
                if AXUIElementCopyAttributeValue(windowInfo.window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                   CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() {
                    // Safely convert AnyObject to AXValue
                    let sizeRef = sizeValue as! AXValue
                    AXValueGetValue(sizeRef, .cgSize, &size)
                    
                    // Filter out windows smaller than 200x200
                    return size.width >= 200 && size.height >= 200
                }
            }
            
            // For CGWindows, check their size directly
            if let cgWindowID = windowInfo.cgWindowID,
               let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[CFString: Any]],
               let windowInfo = windowList.first,
               let bounds = windowInfo[kCGWindowBounds] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                
                // Filter out windows smaller than 200x200
                return width >= 200 && height >= 200
            }
            
            return false
        }
        
        // Then sort the filtered windows
        return filteredWindows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    init(windows: [WindowInfo], appName: String, app: NSRunningApplication, iconCenter: NSPoint, callback: @escaping (AXUIElement, Bool) -> Void) {
        // Use static method to filter and sort windows
        self.options = WindowChooserView.sortWindows(windows)
        self.callback = callback
        self.targetApp = app
        self.dockIconCenter = iconCenter
        
        // Find the topmost window from sorted list
        if let frontmost = self.options.first(where: { window in
            var frontValue: AnyObject?
            if AXUIElementCopyAttributeValue(window.window, "AXMain" as CFString, &frontValue) == .success,
               let isFront = frontValue as? Bool {
                return isFront
            }
            return false
        }) {
            self.topmostWindow = frontmost.window
        }
        
        // Use filtered options count for height calculation
        super.init(frame: NSRect(
            x: 0, 
            y: 0, 
            width: Constants.UI.windowWidth, 
            height: Constants.UI.windowHeight(for: self.options.count)
        ))
        
        setupTitle(appName)
        setupButtons()
        
        // Add to init method after super.init
        self.thumbnailView = WindowThumbnailView(
            targetApp: app,
            dockIconCenter: iconCenter,
            options: self.options  // Use filtered options
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupTitle(_ appName: String) {
        titleField = NSTextField(frame: NSRect(
            x: Constants.UI.windowPadding,
            y: frame.height - Constants.UI.titleHeight - Constants.UI.titlePadding,
            width: frame.width - Constants.UI.windowPadding * 2,
            height: Constants.UI.titleHeight
        ))
        
        titleField.stringValue = appName
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.textColor = Constants.UI.Theme.titleColor
        titleField.font = .systemFont(ofSize: 13.5)  // Adjusted title font size to match Dock tooltip
        titleField.alignment = .center
        
        addSubview(titleField)
    }
    
    private func setupButtons() {
        for (index, windowInfo) in options.enumerated() {
            Logger.debug("Creating button for window:")
            Logger.debug("  - Index: \(index)")
            Logger.debug("  - Name: \(windowInfo.name)")
            Logger.debug("  - ID: \(windowInfo.cgWindowID ?? 0)")
            
            let button = createButton(for: windowInfo, at: index)
            let closeButton = createCloseButton(for: windowInfo, at: index)
            
            addSubview(button)
            addSubview(closeButton)
            buttons.append(button)
            closeButtons.append(closeButton)
            
            // Only add minimize and window control buttons for regular AX windows
            if !windowInfo.isAppElement && windowInfo.cgWindowID == nil {
                let hideButton = createHideButton(for: windowInfo, at: index)
                addSubview(hideButton)
                hideButtons.append(hideButton)
                
                // Create window control buttons only for actual windows
                let leftButton = createSideButton(for: windowInfo, at: index, isLeft: true)
                let centerButton = createSideButton(for: windowInfo, at: index, isLeft: false, isCenter: true)
                let rightButton = createSideButton(for: windowInfo, at: index, isLeft: false)
                
                addSubview(leftButton)
                addSubview(centerButton)
                addSubview(rightButton)
            }
            
            // Update minimize button state if it exists
            if let minimizeButton = hideButtons.first(where: { $0.tag == index }) as? MinimizeButton {
                var minimizedValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                 (minimizedValue as? Bool == true)
                minimizeButton.updateMinimizedState(isMinimized)
            }
        }
    }
    
    // Add helper function to check if it's a CGWindow entry
    private func isCGWindowEntry(_ windowInfo: WindowInfo) -> Bool {
        // A CGWindow entry will have a cgWindowID but no AXUIElement window
        return windowInfo.cgWindowID != nil && windowInfo.window == nil
    }
    
    private func createButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton()
        
        // Adjust button width and position based on whether it needs control buttons
        let buttonWidth: CGFloat
        let buttonX: CGFloat
        
        if windowInfo.isAppElement || windowInfo.cgWindowID != nil {
            // For app elements and CGWindow entries, use full width and center position
            buttonWidth = Constants.UI.windowWidth - Constants.UI.windowPadding * 2
            buttonX = Constants.UI.windowPadding
        } else {
            // For regular windows, keep existing layout with space for controls
            buttonWidth = Constants.UI.windowWidth - Constants.UI.windowPadding * 2 - 44 - 
                (Constants.UI.leftSideButtonWidth + Constants.UI.centerButtonWidth + Constants.UI.rightSideButtonWidth + Constants.UI.sideButtonsSpacing * 2) - 8
            buttonX = 44  // Move right to make room for close button
        }
        
        button.frame = NSRect(
            x: buttonX,
            y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: buttonWidth,
            height: Constants.UI.buttonHeight
        )
        
        configureButton(button, title: windowInfo.name, tag: index)
        
        // Add tracking area for hover effect
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: button,
            userInfo: ["isMenuButton": true]  // Mark this as a menu button for line hover handling
        )
        button.addTrackingArea(trackingArea)
        
        return button
    }
    
    private func createHideButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = MinimizeButton(
            frame: NSRect(
                x: Constants.UI.windowPadding + 24,
                y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
                width: 20,
                height: Constants.UI.buttonHeight
            ),
            tag: index,
            target: self,
            action: #selector(hideButtonClicked(_:))
        )
        
        // Check initial minimize state
        var minimizedValue: AnyObject?
        if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
           let isMinimized = minimizedValue as? Bool {
            button.updateMinimizedState(isMinimized)
        }
        
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.masksToBounds = true
        
        // Add tracking area for hover effect
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: button,
            userInfo: ["isControlButton": true]  // Mark this as a control button
        )
        button.addTrackingArea(trackingArea)
        
        return button
    }
    
    private func configureButton(_ button: NSButton, title: String, tag: Int) {
        // Truncate title if too long
        let maxTitleLength = 60
        let truncatedTitle = title.count > maxTitleLength ? 
            title.prefix(maxTitleLength) + "..." : 
            title
        
        let windowInfo = options[tag]
        
        // Different alignment and padding based on window type
        if windowInfo.isAppElement || windowInfo.cgWindowID != nil {
            // Center align for app elements and CGWindows
            button.alignment = .center
            button.title = String(truncatedTitle)
        } else {
            // Left align for normal windows with padding for minimize button
            button.alignment = .left
            let leftPadding = "      "  // 6 spaces for padding
            button.title = leftPadding + String(truncatedTitle)
        }
        
        button.bezelStyle = .inline
        button.tag = tag
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.wantsLayer = true
        
        button.isBordered = false
        button.font = .systemFont(ofSize: 13.5)
        
        // Prevent line wrapping
        button.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false
        
        // Check if window is minimized and if it's the topmost window
        var minimizedValue: AnyObject?
        let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                          (minimizedValue as? Bool == true)
        
        // Set initial color based on window state
        if isMinimized {
            button.contentTintColor = Constants.UI.Theme.minimizedTextColor
        } else if windowInfo.window == topmostWindow {
            button.contentTintColor = Constants.UI.Theme.primaryTextColor
        } else {
            button.contentTintColor = Constants.UI.Theme.secondaryTextColor
        }
        
        // Add hover effect background
        button.layer?.cornerRadius = 4
        button.layer?.masksToBounds = true
    }
    
    override func mouseEntered(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1  // Quick fade in
                
                let isDark = self.effectiveAppearance.isDarkMode
                
                if event.trackingArea?.userInfo?["isMenuButton"] as? Bool == true {
                    // Full line highlight
                    let hoverColor = isDark ? 
                        NSColor(white: 0.3, alpha: 0.4) :  // Darker background in dark mode
                        NSColor(white: 0.8, alpha: 0.4)    // Lighter background in light mode
                    
                    let backgroundView = NSView(frame: NSRect(x: 0, y: button.frame.minY, width: self.bounds.width, height: button.frame.height))
                    backgroundView.wantsLayer = true
                    backgroundView.layer?.backgroundColor = hoverColor.cgColor
                    backgroundView.setAccessibilityIdentifier("hover-background-\(button.tag)")
                    
                    self.addSubview(backgroundView, positioned: .below, relativeTo: nil)
                    
                    // Show thumbnail for this window
                    if button.tag < options.count {
                        let windowInfo = options[button.tag]
                        thumbnailView?.showThumbnail(for: windowInfo)
                    }
                }/* else if event.trackingArea?.userInfo?["isControlButton"] as? Bool == true {
                    // Control button highlight (minimize, close, etc.)
                    let buttonHoverColor = isDark ? 
                        NSColor(white: 0.4, alpha: 0.6) :  // Darker for control buttons
                        NSColor(white: 0.7, alpha: 0.6)
                    
                    button.layer?.backgroundColor = buttonHoverColor.cgColor
                }*/
                
                // Always brighten the button itself
                //button.contentTintColor = Constants.UI.Theme.primaryTextColor
                //button.alphaValue = 1.0
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1  // Quick fade out
                
                if event.trackingArea?.userInfo?["isMenuButton"] as? Bool == true {
                    // Remove the line highlight
                    self.subviews.forEach { view in
                        if view.accessibilityIdentifier() == "hover-background-\(button.tag)" {
                            view.removeFromSuperview()
                        }
                    }
                    
                    // Hide thumbnail
                    thumbnailView?.hideThumbnail()
                } /* else if event.trackingArea?.userInfo?["isControlButton"] as? Bool == true {
                    // Remove control button highlight
                    button.layer?.backgroundColor = .clear
                }*/
                
                // Always restore original button state
                /*if options[button.tag].window != topmostWindow {
                    button.contentTintColor = Constants.UI.Theme.secondaryTextColor
                    button.alphaValue = 0.8
                }*/
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        Logger.debug("Button clicked - tag: \(sender.tag)")
        let windowInfo = options[sender.tag]
        Logger.debug("Selected window info - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        if windowInfo.cgWindowID != nil && windowInfo.window == nil {
            // For CGWindow entries, just activate the app
            targetApp.activate(options: [.activateIgnoringOtherApps])
            callback?(windowInfo.window, false)  // This will trigger the window raise through CGWindow
            
            // Update topmost window and refresh menu
            topmostWindow = windowInfo.window
            updateButtonStates()
            
            // Refresh menu after a small delay to let window state update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if let windowController = self?.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
                }
            }
            return
        }
        
        // Check for double click
        let currentTime = ProcessInfo.processInfo.systemUptime
        let isDoubleClick = (currentTime - lastClickTime) < doubleClickInterval
        lastClickTime = currentTime
        
        // Get window controller reference
        let windowController = self.window?.windowController as? WindowChooserController

        if windowInfo.isAppElement {
            handleAppElementClick()
        } else {
            // Handle window click with new approach
            Logger.debug("Window selection details:")
            Logger.debug("  - Button tag: \(sender.tag)")
            Logger.debug("  - Window name: \(windowInfo.name)")
            Logger.debug("  - Window ID: \(windowInfo.cgWindowID ?? 0)")
            
            // Update topmost window
            topmostWindow = windowInfo.window
            
            // First activate the app
            targetApp.activate(options: [.activateIgnoringOtherApps])
            
            // Then unminimize if needed and raise the window
            var isMinimized = false
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let minimizedState = minimizedValue as? Bool {
                isMinimized = minimizedState
            }
            
            // Handle window raising and minimizing other windows
            let handleDoubleClick = {
                if isDoubleClick {
                    // Double click: minimize all other windows
                    for (index, otherWindow) in self.options.enumerated() {
                        if index != sender.tag && !otherWindow.isAppElement {
                            // Minimize other windows
                            AXUIElementSetAttributeValue(otherWindow.window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                        }
                    }

                    // Update menu after minimizing windows
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                        windowController?.updateWindows(updatedWindows, for: self.targetApp, at: self.dockIconCenter)
                    }
                }
            }
            
            if isMinimized {
                // For minimized windows, we need to:
                // 1. Unminimize
                // 2. Wait for unminimize animation
                // 3. Raise window
                // 4. Handle double-click if needed
                AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                
                // Wait for unminimize animation, then raise and handle double-click
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Set focus attributes
                    AXUIElementSetAttributeValue(windowInfo.window, kAXMainAttribute as CFString, true as CFTypeRef)
                    AXUIElementSetAttributeValue(windowInfo.window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                    
                    // Update topmost window
                    self.topmostWindow = windowInfo.window
                    self.updateButtonStates()
                    
                    // Update minimize button state
                    if let hideButton = self.hideButtons.first(where: { $0.tag == sender.tag }) as? MinimizeButton {
                        hideButton.updateMinimizedState(false)  // Window is now unminimized
                    }
                    
                    self.callback?(windowInfo.window, false)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        handleDoubleClick()

                        // Update menu after a short delay to reflect new window states
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                            guard let self = self else { return }
                            let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                            self.updateWindows(updatedWindows)
                        }
                        
                        // Refresh menu after all operations are complete
                        if let self = self,  // Unwrap self first
                           let windowController = self.window?.windowController as? WindowChooserController {  // Then chain optionals
                            windowController.refreshMenu()
                        }
                    }
                }
            } else {
                // Set focus attributes
                AXUIElementSetAttributeValue(windowInfo.window, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(windowInfo.window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                
                // Update topmost window
                topmostWindow = windowInfo.window
                updateButtonStates()
                
                // Update minimize button state
                if let hideButton = hideButtons.first(where: { $0.tag == sender.tag }) as? MinimizeButton {
                    hideButton.updateMinimizedState(false)  // Window is now unminimized
                }
                
                // Raise window
                callback?(windowInfo.window, false)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    handleDoubleClick()
                    
                    // Refresh menu after all operations are complete
                    if let windowController = self.window?.windowController as? WindowChooserController {
                        windowController.refreshMenu()
                    }
                }
            }
        }
    }
    
    private func handleAppElementClick() {
        Logger.debug("Processing click for app: \(targetApp.localizedName ?? "Unknown")")
        
        let hasVisibleWindows = hasVisibleWindows(for: targetApp)
        
        if targetApp.isActive && hasVisibleWindows {
            Logger.debug("App is active with visible windows, hiding")
            AccessibilityService.shared.hideAllWindows(for: targetApp)
            targetApp.hide()
            closeWindowChooser()
        } else {
            Logger.debug("App needs activation")
            // Keep window chooser alive during app launch
            let currentWindowChooser = self.window?.windowController as? WindowChooserController
            
            launchApp()
            
            // Wait for app to fully launch and windows to appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                
                // Check if windows appeared
                let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                if !updatedWindows.isEmpty {
                    self.updateWindows(updatedWindows)
                    currentWindowChooser?.refreshMenu()
                } else {
                    // If no windows appeared after timeout, close the chooser
                    self.closeWindowChooser()
                }
            }
        }
    }
    
    private func handleWindowClick(_ windowInfo: WindowInfo, hideButton: NSButton) {
        // Show and raise window
        AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: targetApp)
        targetApp.activate(options: [.activateIgnoringOtherApps])
        
        // Update UI
        updateTopmostWindow(windowInfo.window)
        updateHideButton(hideButton)
    }
    
    private func hasVisibleWindows(for app: NSRunningApplication) -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windowList.contains { info in
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer] as? Int32,
                  layer == kCGNormalWindowLevel,
                  let isOnscreen = info[kCGWindowIsOnscreen] as? Bool,
                  isOnscreen else {
                return false
            }
            return true
        }
    }
    
    private func launchApp() {
        // First try regular activation
        targetApp.activate(options: [.activateIgnoringOtherApps])
        
        // If the app is already running but needs window restoration
        if targetApp.isFinishedLaunching {
            Logger.debug("App is already running, trying to restore windows")
            // Give the app a moment to respond to activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                
                // If still no visible windows, try launching again
                if !self.hasVisibleWindows(for: self.targetApp) {
                    Logger.debug("No visible windows after activation, trying relaunch")
                    if let bundleURL = self.targetApp.bundleURL {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        
                        NSWorkspace.shared.openApplication(
                            at: bundleURL,
                            configuration: configuration,
                            completionHandler: nil
                        )
                    }
                }
            }
        } else {
            // App isn't running, do a fresh launch
            if let bundleURL = targetApp.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            }
        }
    }
    
    private func closeWindowChooser() {
        NotificationCenter.default.post(name: NSNotification.Name("WindowChooserDidClose"), object: nil)
        if let windowController = self.window?.windowController as? WindowChooserController {
            windowController.close()
        }
    }
    
    private func updateHideButton(_ button: NSButton) {
        button.isEnabled = true
        button.contentTintColor = Constants.UI.Theme.iconTintColor
        button.alphaValue = 1.0
        
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: button,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
    }
    
    @objc private func hideButtonClicked(_ sender: NSButton) {
        let windowInfo = options[sender.tag]
        let windowController = self.window?.windowController as? WindowChooserController

        // Check current minimized state
        var minimizedValue: AnyObject?
        let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                          (minimizedValue as? Bool == true)
        
        if isMinimized {
            // Unminimize and raise the window
            AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: targetApp)
            
            // Update topmost window
            topmostWindow = windowInfo.window
        } else {
            // Minimize the window
            AccessibilityService.shared.minimizeWindow(windowInfo: windowInfo, for: targetApp)
            
            // If this was the topmost window, clear it
            if windowInfo.window == topmostWindow {
                topmostWindow = nil
            }
        }

        // Update menu with new window states
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
            windowController?.updateWindows(updatedWindows, for: self.targetApp, at: self.dockIconCenter)
        }
    }
    
    deinit {
        // Capture values before async operation
        let buttonsToClean = buttons
        let hideButtonsToClean = hideButtons
        let closeButtonsToClean = closeButtons
        
        // Track destruction
        // Remove: MemoryTracker.shared.track(self) { "destroyed" }
        
        // Clean up tracking areas on main actor
        Task { @MainActor in
            let allButtons = buttonsToClean + hideButtonsToClean + closeButtonsToClean
            for button in allButtons {
                for area in button.trackingAreas {
                    button.removeTrackingArea(area)
                }
            }
        }
    }

    private func createCustomBadgeIcon(baseSymbol: String, badgeNumber: String, config: NSImage.SymbolConfiguration) -> NSImage? {
        // Create the base symbol image with theme-aware color
        let isDark = self.effectiveAppearance.isDarkMode
        let symbolConfig = config.applying(.init(paletteColors: [
            isDark ? .white : NSColor(white: 0.2, alpha: 1.0)
        ]))
        
        guard let baseImage = NSImage(systemSymbolName: baseSymbol, accessibilityDescription: "Base icon")?
                .withSymbolConfiguration(symbolConfig) else {
            return nil
        }
        
        let size = NSSize(width: 15, height: 13) // Custom size for the icon with a badge
        let image = NSImage(size: size)
        
        image.lockFocus()
        baseImage.draw(in: NSRect(origin: .zero, size: size))
        
        // Draw the badge text ("2") at the top-right corner with theme-aware color
        let badgeText = badgeNumber as NSString
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: Constants.UI.Theme.iconSecondaryTintColor
        ]
        
        let badgeSize = badgeText.size(withAttributes: textAttributes)
        let badgeOrigin = NSPoint(x: size.width - badgeSize.width - 5, y: size.height - badgeSize.height - 2)
        badgeText.draw(at: badgeOrigin, withAttributes: textAttributes)
        
        image.unlockFocus()
        return image
    }
    
    // Add new method to create side buttons
    private func createSideButton(for windowInfo: WindowInfo, at index: Int, isLeft: Bool, isCenter: Bool = false) -> NSButton {
        let spacing = Constants.UI.sideButtonsSpacing
        let buttonWidth = Constants.UI.leftSideButtonWidth
        let totalWidth = buttonWidth * 3 + spacing * 2
        
        // Calculate x position based on button type
        let xPosition: CGFloat
        if isLeft {
            xPosition = Constants.UI.windowWidth - Constants.UI.windowPadding - totalWidth
        } else if isCenter {
            xPosition = Constants.UI.windowWidth - Constants.UI.windowPadding - buttonWidth * 2 - spacing
        } else {
            xPosition = Constants.UI.windowWidth - Constants.UI.windowPadding - buttonWidth
        }
        
        let button = NSButton(frame: NSRect(
            x: xPosition,
            y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: buttonWidth,
            height: Constants.UI.buttonHeight
        ))
        
        // Create button image with larger size
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)  // Keep original size of 11

        let imageName: String
        let accessibilityDescription: String

        if isCenter {
            let isOnSecondary = isWindowOnSecondaryDisplay(windowInfo.window)
            let isMaximized = isWindowMaximized(windowInfo.window)  // Add this line
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [isMaximized ? Constants.UI.Theme.iconTintColor : Constants.UI.Theme.iconSecondaryTintColor]))  // Update this line

            button.title = "" // Ensure no fallback text appears

            if isOnSecondary {
                // Create custom icon with "2" badge
                if let badgeIcon = createCustomBadgeIcon(baseSymbol: "square.fill", badgeNumber: "2", config: config) {
                    button.image = badgeIcon
                } else {
                    print("Error: Failed to create custom badge icon")
                    button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error icon")
                }
            } else {
                // Use the plain "square.fill" icon with correct tint
                if let image = NSImage(systemSymbolName: "square.fill", accessibilityDescription: "Toggle Window Size")?.withSymbolConfiguration(config) {
                    button.image = image
                } else {
                    print("Error: square.fill not supported on this system")
                    button.image = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "Fallback icon")
                }
            }
            
            // Set initial color based on maximized state
            button.contentTintColor = isMaximized ? Constants.UI.Theme.iconTintColor : Constants.UI.Theme.iconSecondaryTintColor
            accessibilityDescription = isOnSecondary ? "Move to Primary" : "Toggle Window Size"
        } else {
            // Use rectangle.lefthalf/righthalf.filled icons instead of chevrons
            imageName = isLeft ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled"
            accessibilityDescription = isLeft ? "Snap Left" : "Snap Right"
            let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(config)
            button.image = image
        }

        // Remove the original image setting code since we're handling it in the conditions above
        // let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
        //     .withSymbolConfiguration(config)
        // button.image = image
        
        // Configure button appearance
        button.bezelStyle = .inline
        button.isBordered = false
        button.tag = index
        button.target = self
        button.action = isCenter ? #selector(maximizeWindow(_:)) : (isLeft ? #selector(moveWindowLeft(_:)) : #selector(moveWindowRight(_:)))
        
        // Configure button layer for background color
        button.wantsLayer = true
        button.layer?.cornerRadius = 5.5  // Match minimize button
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = .clear
        
        // Set initial color based on window position/state
        let isInPosition = isCenter ? isWindowMaximized(windowInfo.window) : isWindowInPosition(windowInfo.window, onLeft: isLeft)
        button.contentTintColor = isInPosition ? 
            Constants.UI.Theme.iconTintColor : 
            Constants.UI.Theme.iconSecondaryTintColor
        
        // Add tracking area for hover effect
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: button,
            userInfo: ["isControlButton": true]  // Mark this as a control button
        )
        button.addTrackingArea(trackingArea)
        
        if windowInfo.isAppElement {
            // Hide the button for app elements
            button.isHidden = true
        }
        
        return button
    }
    
    // Add method to check if window is maximized
    private func isWindowMaximized(_ window: AXUIElement) -> Bool {
        guard let screen = NSScreen.main else { return false }
        
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
           let cfPosition = positionValue,
           CFGetTypeID(cfPosition) == AXValueGetTypeID(),
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let cfSize = sizeValue,
           CFGetTypeID(cfSize) == AXValueGetTypeID() {
            let posRef = cfPosition as! AXValue
            let sizeRef = cfSize as! AXValue
            AXValueGetValue(posRef, .cgPoint, &position)
            AXValueGetValue(sizeRef, .cgSize, &size)
            
            let visibleFrame = screen.visibleFrame
            
            // Calculate window coverage percentage
            let windowArea = size.width * size.height
            let screenArea = visibleFrame.width * visibleFrame.height
            let coveragePercentage = (windowArea / screenArea) * 100
            
            // Consider window maximized if it covers more than 80% of screen space
            return coveragePercentage > 80
        }
        return false
    }
    
    // Add maximize window action
    @objc private func maximizeWindow(_ sender: NSButton) {
        let currentTime = ProcessInfo.processInfo.systemUptime
        let isDoubleClick = (currentTime - lastMaximizeClickTime) < doubleClickInterval
        lastMaximizeClickTime = currentTime
        
        let window = options[sender.tag].window
        
        if isDoubleClick && NSScreen.screens.count > 1 {
            // Double-click behavior - move to secondary display
            positionWindow(window, maximize: true, useSecondaryDisplay: true)
            
            // Add refresh after a small delay to ensure window has moved
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                // Update button state
                if let button = self.subviews.compactMap({ $0 as? NSButton })
                    .first(where: { $0.tag == sender.tag && $0.action == #selector(maximizeWindow(_:)) }) {
                    
                    let isOnSecondary = self.isWindowOnSecondaryDisplay(window)
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    
                    if isOnSecondary {
                        // Create custom icon with "2" badge
                        if let badgeIcon = self.createCustomBadgeIcon(baseSymbol: "square.fill", badgeNumber: "2", config: config) {
                            button.image = badgeIcon
                        }
                    } else {
                        if let image = NSImage(systemSymbolName: "square.fill", accessibilityDescription: "Toggle Window Size")?
                            .withSymbolConfiguration(config) {
                            button.image = image
                        }
                    }
                    
                    button.contentTintColor = Constants.UI.Theme.iconTintColor
                }
                
                self.refreshButtons(for: window, at: sender.tag)
                
                // Also refresh the entire menu to update all states
                if let windowController = self.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
                }
            }
        } else {
            // Single click behavior
            if isWindowMaximized(window) {
                centerWindow(window)
            } else {
                positionWindow(window, maximize: true, useSecondaryDisplay: false)
                
                // Update maximize button icon
                if let button = self.subviews.compactMap({ $0 as? NSButton })
                    .first(where: { $0.tag == sender.tag && $0.action == #selector(maximizeWindow(_:)) }) {
                    
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    let image = NSImage(systemSymbolName: "square.fill", 
                                      accessibilityDescription: "Toggle Window Size")?
                        .withSymbolConfiguration(config)
                    
                    button.image = image
                    button.contentTintColor = Constants.UI.Theme.iconTintColor
                }
            }
        }
    }
    
    // Update positionWindow to handle maximization
    private func positionWindow(_ window: AXUIElement, onLeft: Bool? = nil, maximize: Bool = false, useSecondaryDisplay: Bool = false) {
        // Get the appropriate screen
        let screen: NSScreen
        if useSecondaryDisplay {
            guard let secondaryScreen = NSScreen.screens.first(where: { $0 != NSScreen.main }) else {
                return
            }
            screen = secondaryScreen
        } else {
            guard let mainScreen = NSScreen.main else { return }
            screen = mainScreen
        }
        
        // First unminimize and unhide to ensure proper sizing
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, false as CFTypeRef)
        
        // Ensure window is active and raised first
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        targetApp.activate(options: [.activateIgnoringOtherApps])
        
        // Small delay to ensure window is ready
        usleep(5000)
        
        // Get the target screen's frame
        let visibleFrame = screen.visibleFrame
        
        var newSize: CGSize
        var position: CGPoint
        
        if maximize {
            // Use the screen's full dimensions
            newSize = CGSize(
                width: visibleFrame.width,
                height: visibleFrame.height
            )
            position = CGPoint(
                x: visibleFrame.minX,
                y: screen == NSScreen.main ? 0 : visibleFrame.minY  // Set Y to 0 for primary screen only
            )
        } else {
            let margin = Constants.UI.screenEdgeMargin
            let usableWidth = (visibleFrame.width - (margin * 3)) / 2
            newSize = CGSize(width: usableWidth, height: visibleFrame.height)
            position = CGPoint(
                x: onLeft! ? visibleFrame.minX + margin : visibleFrame.maxX - usableWidth - margin,
                y: 0
            )
        }
        
        // Set size and position in a single batch with proper error handling
        if let sizeValue = AXValueCreate(.cgSize, &newSize),
           let positionValue = AXValueCreate(.cgPoint, &position) {
            
            // Set position first
            let posResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            usleep(1000)
            
            // Then set size
            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            usleep(1000)
            
            // Log results for debugging
            Logger.debug("Position set result: \(posResult == .success ? "success" : "failed")")
            Logger.debug("Size set result: \(sizeResult == .success ? "success" : "failed")")
            
            // Force window refresh to ensure it's frontmost
            usleep(5000)
            var refreshPos = CGPoint(x: position.x + 1, y: position.y)
            if let refreshValue = AXValueCreate(.cgPoint, &refreshPos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, refreshValue)
                usleep(1000)
                
                if let originalValue = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originalValue)
                }
            }
            
            // Update all buttons after positioning
            if let index = options.firstIndex(where: { $0.window == window }) {
                refreshButtons(for: window, at: index)
                
                // Also find and update the maximize button specifically
                if let maximizeButton = self.subviews.compactMap({ $0 as? NSButton })
                    .first(where: { $0.tag == index && $0.action == #selector(maximizeWindow(_:)) }) {
                    
                    // Update maximize button appearance for non-maximized state
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                        .applying(.init(paletteColors: [Constants.UI.Theme.iconSecondaryTintColor]))
                    
                    if let image = NSImage(systemSymbolName: "square.fill", 
                                          accessibilityDescription: "Toggle Window Size")?
                        .withSymbolConfiguration(config) {
                        maximizeButton.image = image
                    }
                    maximizeButton.contentTintColor = Constants.UI.Theme.iconSecondaryTintColor
                }
            }
        }
    }
    
    // Add new method to refresh all buttons
    private func refreshButtons(for window: AXUIElement, at index: Int) {
        let buttons = self.subviews.compactMap { $0 as? NSButton }
        for button in buttons {
            if button.tag == index {
                if let minimizeButton = button as? MinimizeButton {
                    // Get window's minimized state and update button
                    var minimizedValue: AnyObject?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                       let isMinimized = minimizedValue as? Bool {
                        minimizeButton.updateMinimizedState(isMinimized)  // Update button state
                    }
                } else if button.action == #selector(maximizeWindow(_:)) {
                    button.contentTintColor = isWindowMaximized(window) ? 
                        Constants.UI.Theme.iconTintColor : 
                        Constants.UI.Theme.iconSecondaryTintColor
                } else if button.action == #selector(moveWindowLeft(_:)) {
                    button.contentTintColor = isWindowInPosition(window, onLeft: true) ? 
                        Constants.UI.Theme.iconTintColor : 
                        Constants.UI.Theme.iconSecondaryTintColor
                } else if button.action == #selector(moveWindowRight(_:)) {
                    button.contentTintColor = isWindowInPosition(window, onLeft: false) ? 
                        Constants.UI.Theme.iconTintColor : 
                        Constants.UI.Theme.iconSecondaryTintColor
                } else if button.action == #selector(buttonClicked(_:)) {
                    // Window title button
                    button.contentTintColor = window == topmostWindow ? 
                        Constants.UI.Theme.buttonHighlightColor : 
                        Constants.UI.Theme.buttonSecondaryTextColor
                }
            }
        }
        
        // Force layout update
        self.needsLayout = true
        self.window?.contentView?.needsLayout = true
    }
    
    // Add method to update all button colors
    private func updateButtonColors(for window: AXUIElement) {
        for (index, windowInfo) in options.enumerated() {
            if windowInfo.window == window {
                let buttons = self.subviews.compactMap { $0 as? NSButton }
                for button in buttons {
                    if button.tag == index {
                        if button.action == #selector(moveWindowLeft(_:)) {
                            button.contentTintColor = isWindowInPosition(window, onLeft: true) ? 
                                Constants.UI.Theme.iconTintColor : 
                                Constants.UI.Theme.iconSecondaryTintColor
                        } else if button.action == #selector(moveWindowRight(_:)) {
                            button.contentTintColor = isWindowInPosition(window, onLeft: false) ? 
                                Constants.UI.Theme.iconTintColor : 
                                Constants.UI.Theme.iconSecondaryTintColor
                        } else if button.action == #selector(maximizeWindow(_:)) {
                            button.contentTintColor = isWindowMaximized(window) ? 
                                Constants.UI.Theme.iconTintColor : 
                                Constants.UI.Theme.iconSecondaryTintColor
                        }
                    }
                }
                break
            }
        }
    }
    
    // Add helper method to WindowChooserView to check window position
    private func isWindowInPosition(_ window: AXUIElement, onLeft: Bool) -> Bool {
        guard let screen = NSScreen.main else { return false }
        
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
           let cfPosition = positionValue,
           CFGetTypeID(cfPosition) == AXValueGetTypeID(),
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let cfSize = sizeValue,
           CFGetTypeID(cfSize) == AXValueGetTypeID() {
            let posRef = cfPosition as! AXValue
            let sizeRef = cfSize as! AXValue
            AXValueGetValue(posRef, .cgPoint, &position)
            AXValueGetValue(sizeRef, .cgSize, &size)
            
            let visibleFrame = screen.visibleFrame
            let margin = Constants.UI.screenEdgeMargin
            let expectedWidth = (visibleFrame.width - (margin * 3)) / 2
            
            // Calculate expected positions
            let leftPosition = visibleFrame.minX + margin
            let rightPosition = visibleFrame.maxX - expectedWidth - margin
            
            // Increase tolerance for position and size checks
            let tolerance: CGFloat = 10.0  // Increased from 5.0
            let widthTolerance: CGFloat = 20.0  // Separate tolerance for width
            
            let isExpectedWidth = abs(size.width - expectedWidth) < widthTolerance
            
            if onLeft {
                return abs(position.x - leftPosition) < tolerance && isExpectedWidth
            } else {
                return abs(position.x - rightPosition) < tolerance && isExpectedWidth
            }
        }
        return false
    }
    
    @objc private func moveWindowLeft(_ sender: NSButton) {
        let window = options[sender.tag].window
        positionWindow(window, onLeft: true)
        // Add small delay to ensure window has moved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshButtons(for: window, at: sender.tag)
        }
    }
    
    @objc private func moveWindowRight(_ sender: NSButton) {
        let window = options[sender.tag].window
        positionWindow(window, onLeft: false)
        // Add small delay to ensure window has moved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshButtons(for: window, at: sender.tag)
        }
    }
    
    // Add method to check if window is on secondary display
    private func isWindowOnSecondaryDisplay(_ window: AXUIElement) -> Bool {
        guard NSScreen.screens.count > 1,
              let mainScreen = NSScreen.main,
              let windowFrame = getWindowFrame(window) else {
            return false
        }
        
        let windowCenter = CGPoint(
            x: windowFrame.midX,
            y: windowFrame.midY
        )
        
        // Check if window center is on any non-main screen
        return NSScreen.screens
            .filter { $0 != mainScreen }
            .contains { screen in
                screen.frame.contains(windowCenter)
            }
    }
    
    // Add helper to get window frame
    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              let cfPosition = positionValue,
              CFGetTypeID(cfPosition) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let cfSize = sizeValue,
              CFGetTypeID(cfSize) == AXValueGetTypeID() else {
            return nil
        }
        
        let posRef = cfPosition as! AXValue
        let sizeRef = cfSize as! AXValue
        AXValueGetValue(posRef, .cgPoint, &position)
        AXValueGetValue(sizeRef, .cgSize, &size)
        
        return CGRect(origin: position, size: size)
    }
    
    // Add method to update button image and color
    private func updateMaximizeButton(for window: AXUIElement, at index: Int) {
        let buttons = self.subviews.compactMap { $0 as? NSButton }
        for button in buttons {
            if button.tag == index && button.action == #selector(maximizeWindow(_:)) {
                // Check if window is on secondary display
                let isOnSecondary = isWindowOnSecondaryDisplay(window)
                
                // Update button image
                let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                let imageName = isOnSecondary ? "2.square.fill" : "square.fill"
                let accessibilityDescription = isOnSecondary ? "Maximize on Primary" : "Maximize"
                let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
                    .withSymbolConfiguration(config)
                
                button.image = image
                
                // Update color based on maximized state
                let isMaximized = isWindowMaximized(window)
                button.contentTintColor = isMaximized ? .white : NSColor.tertiaryLabelColor
            }
        }
    }
    
    // Add method to update topmost window state
    private func updateTopmostWindow(_ window: AXUIElement) {
        topmostWindow = window
        
        // Refresh all window buttons
        for (index, windowInfo) in options.enumerated() {
            let buttons = self.subviews.compactMap { $0 as? NSButton }
            for button in buttons {
                if button.tag == index {
                    if button.action == #selector(buttonClicked(_:)) {
                        // Update window button color based on topmost state
                        button.contentTintColor = windowInfo.window == topmostWindow ? 
                            Constants.UI.Theme.buttonHighlightColor : 
                            Constants.UI.Theme.buttonSecondaryTextColor
                    }
                }
            }
        }
    }
    
    // Add new method to center window
    private func centerWindow(_ window: AXUIElement) {
        guard let screen = NSScreen.main else { return }
        
        let visibleFrame = screen.visibleFrame
        
        // Calculate window size as 70% of screen size
        let width = visibleFrame.width * 0.7
        let height = visibleFrame.height * 0.7
        
        // Calculate center position
        let centerX = visibleFrame.minX + (visibleFrame.width - width) / 2
        let centerY = visibleFrame.minY + (visibleFrame.height - height) / 2
        
        // Set window size
        var size = CGSize(width: width, height: height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        
        // Set window position
        var position = CGPoint(x: centerX, y: centerY)
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        
        // Update button state and icon
        if let index = options.firstIndex(where: { $0.window == window }),
           let button = self.subviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.tag == index && $0.action == #selector(maximizeWindow(_:)) }) {
            
            // Update to regular square icon
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let image = NSImage(systemSymbolName: "square.fill", 
                              accessibilityDescription: "Toggle Window Size")?
                .withSymbolConfiguration(config)
            
            button.image = image
            button.contentTintColor = Constants.UI.Theme.iconSecondaryTintColor
        }
        
        // Update other buttons
        if let index = options.firstIndex(where: { $0.window == window }) {
            refreshButtons(for: window, at: index)
        }
    }
    
    // Add new method to handle close button clicks
    @objc private func closeButtonClicked(_ sender: NSButton) {
        let windowInfo = options[sender.tag]
        
        // Store window controller reference before any operations
        let windowController = self.window?.windowController as? WindowChooserController
        
        if windowInfo.isAppElement {
            // For app elements (entire application), just terminate and close
            targetApp.terminate()
            windowController?.close()
            
        } else if windowInfo.cgWindowID != nil && windowInfo.window == nil {
            // For CGWindow entries, use CGWindow-based closing
            AccessibilityService.shared.closeWindow(windowInfo: windowInfo, for: targetApp)
            
            // Update after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                
                if !updatedWindows.isEmpty {
                    // Refresh the menu with updated windows
                    windowController?.updateWindows(updatedWindows, for: self.targetApp, at: self.dockIconCenter)
                } else {
                    windowController?.close()
                }
            }
            
        } else {
            // For regular AX windows
            let window = windowInfo.window
            
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
               CFGetTypeID(closeButtonRef!) == AXUIElementGetTypeID() {
                let closeButton = closeButtonRef as! AXUIElement
                AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                
                // Update after window closes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                    
                    if !updatedWindows.isEmpty {
                        // Refresh the menu with updated windows
                        windowController?.updateWindows(updatedWindows, for: self.targetApp, at: self.dockIconCenter)
                    } else {
                        windowController?.close()
                    }
                }
            }
        }
    }
    
    // Move createCloseButton back inside WindowChooserView
    private func createCloseButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        return CloseButton(
            frame: NSRect(
                x: Constants.UI.windowPadding,
                y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
                width: 20,
                height: Constants.UI.buttonHeight
            ),
            tag: index,
            target: self,
            action: #selector(closeButtonClicked(_:))
        )
    }
    
    func updateWindows(_ windows: [WindowInfo]) {
        // Use static method to filter and sort
        self.options = WindowChooserView.sortWindows(windows)
        
        // First, find the new topmost window
        topmostWindow = nil  // Reset first
        for windowInfo in self.options {  // Use sorted options
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            if !isMinimized {
                topmostWindow = windowInfo.window
                break
            }
        }
        
        // Update frame height based on filtered windows count
        let newHeight = Constants.UI.windowHeight(for: self.options.count)
        if let windowController = self.window?.windowController as? WindowChooserController {
            windowController.updateWindowSize(to: newHeight)
        }
        
        // Update buttons with sorted windows
        for (index, windowInfo) in self.options.enumerated() {
            // Get window state once for both button updates
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            // Update main button
            if let button = buttons.first(where: { $0.tag == index }) {
                // Update button title
                let truncatedTitle = windowInfo.name.count > 60 ? 
                    windowInfo.name.prefix(60) + "..." : 
                    windowInfo.name
                
                if windowInfo.isAppElement || windowInfo.cgWindowID != nil {
                    button.title = String(truncatedTitle)
                } else {
                    let leftPadding = "      "  // 6 spaces for padding
                    button.title = leftPadding + String(truncatedTitle)
                }
                
                // Update button state
                if isMinimized {
                    button.contentTintColor = Constants.UI.Theme.minimizedTextColor
                } else if windowInfo.window == topmostWindow {
                    button.contentTintColor = Constants.UI.Theme.primaryTextColor
                } else {
                    button.contentTintColor = Constants.UI.Theme.secondaryTextColor
                }
            }
            
            // Update minimize button state if it exists
            if let minimizeButton = hideButtons.first(where: { $0.tag == index }) as? MinimizeButton {
                minimizeButton.updateMinimizedState(isMinimized)
            }
        }
        
        // Force layout update
        needsLayout = true
        window?.contentView?.needsLayout = true
        
        // Update thumbnail view options
        thumbnailView = WindowThumbnailView(
            targetApp: targetApp,
            dockIconCenter: dockIconCenter, 
            options: self.options
        )
    }

    // Add helper method to update a single window's state
    func updateWindowState(_ window: AXUIElement, isMinimized: Bool) {
        if let index = options.firstIndex(where: { $0.window == window }) {
            if let button = buttons.first(where: { $0.tag == index }) {
                button.contentTintColor = isMinimized ? 
                    Constants.UI.Theme.minimizedTextColor : 
                    Constants.UI.Theme.primaryTextColor
            }
            
            if let minimizeButton = hideButtons.first(where: { $0.tag == index }) as? MinimizeButton {
                minimizeButton.updateMinimizedState(isMinimized)
            }
        }
    }

    func cleanup() {
        // Remove tracking areas and clear event monitors
        buttons.forEach { button in
            button.trackingAreas.forEach { button.removeTrackingArea($0) }
            button.target = nil
            button.action = nil
        }
        hideButtons.forEach { button in
            button.trackingAreas.forEach { button.removeTrackingArea($0) }
            button.target = nil
            button.action = nil
        }
        closeButtons.forEach { button in
            button.trackingAreas.forEach { button.removeTrackingArea($0) }
            button.target = nil
            button.action = nil
        }
        
        // Remove buttons from view hierarchy and clear their layers
        buttons.forEach { button in
            button.layer?.removeFromSuperlayer()
            button.removeFromSuperview()
        }
        hideButtons.forEach { button in
            button.layer?.removeFromSuperlayer()
            button.removeFromSuperview()
        }
        closeButtons.forEach { button in
            button.layer?.removeFromSuperlayer()
            button.removeFromSuperview()
        }
        
        // Clear title field
        titleField?.stringValue = ""
        titleField?.removeFromSuperview()
        titleField = nil
        
        // Clear arrays
        buttons.removeAll(keepingCapacity: false)
        hideButtons.removeAll(keepingCapacity: false)
        closeButtons.removeAll(keepingCapacity: false)
        options.removeAll(keepingCapacity: false)
        
        // Clear other references
        callback = nil
        topmostWindow = nil
        
        // Remove self from superview
        self.removeFromSuperview()
        
        // Cleanup thumbnail view
        thumbnailView?.cleanup()
        thumbnailView = nil
    }

    // Add new method to update button states
    private func updateButtonStates() {
        for (index, windowInfo) in options.enumerated() {
            if let button = buttons.first(where: { $0.tag == index }) {
                var minimizedValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                 (minimizedValue as? Bool == true)
                
                if isMinimized {
                    button.contentTintColor = Constants.UI.Theme.minimizedTextColor
                } else if windowInfo.window == topmostWindow {
                    button.contentTintColor = Constants.UI.Theme.primaryTextColor
                } else {
                    button.contentTintColor = Constants.UI.Theme.secondaryTextColor
                }
            }
        }
    }
}
