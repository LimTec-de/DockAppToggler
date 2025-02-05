import AppKit

// Add at the top of the file, before the class declaration
protocol WindowChooserViewDelegate: AnyObject {
    func windowChooserView(_ view: WindowChooserView, didSelectItem item: WindowInfo)
}

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
    internal var thumbnailView: WindowThumbnailView?
    // Change from let to var
    private var isHistoryMode: Bool
    // Add new properties for icon image view and minimize/maximize buttons
    private var iconImageView: NSImageView?
    private var minimizeButton: NSButton?
    private var maximizeButton: NSButton?
    
    // Change from private to internal
    var selectedIndex: Int = 0
    
    // Add near other properties
    weak var delegate: WindowChooserViewDelegate?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab key
            if event.modifierFlags.contains(.shift) {
                selectPreviousItem()
            } else {
                selectNextItem()
            }
        case 36: // Return/Enter key
            selectCurrentItem()
        case 53: // Escape key
            window?.close()
        default:
            super.keyDown(with: event)
        }
    }
    
    // Change from instance method to static method
    static func sortWindows(_ windows: [WindowInfo], app: NSRunningApplication, isHistory: Bool = false) -> [WindowInfo] {
        Logger.debug("Filtering windows - Initial count: \(windows.count)")
        
        // First filter out small windows
        let filteredWindows = windows.filter { windowInfo in
            // Always include app elements
            if windowInfo.isAppElement {
                return true
            }
            
            // For regular windows, check size
            var pid: pid_t = 0
            if AXUIElementGetPid(windowInfo.window, &pid) == .success {
                var sizeValue: AnyObject?
                var size = CGSize.zero
                
                if AXUIElementCopyAttributeValue(windowInfo.window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                   CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() {
                    // Safely convert AnyObject to AXValue
                    let sizeRef = sizeValue as! AXValue
                    AXValueGetValue(sizeRef, .cgSize, &size)
                    
                    // Filter out windows smaller than 200x200
                    let isValidSize = size.width >= 200 && size.height >= 200
                    if !isValidSize {
                        Logger.debug("Filtering out window due to size: \(windowInfo.name) (\(size.width) x \(size.height))")
                    }
                    return isValidSize
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
                let isValidSize = width >= 200 && height >= 200
                if !isValidSize {
                    let windowName = windowInfo[kCGWindowName as CFString] as? String ?? "Unknown"
                    Logger.debug("Filtering out CGWindow due to size: \(windowName) (\(width) x \(height))")
                }
                return isValidSize
            }
            
            return false
        }
        
        Logger.debug("Windows after size filtering: \(filteredWindows.count)")
        
        // Get recent windows for this app
        let recentWindows = WindowHistory.shared.getRecentWindows(for: app.bundleIdentifier ?? "")
        let recentWindowIds = Set(recentWindows.compactMap { $0.cgWindowID })
        
        // Sort windows based on history mode
        if isHistory {
            // In history mode, sort purely by recency (newest first)
            return filteredWindows.sorted { win1, win2 in
                // Get indices from recent windows list for sorting
                let index1 = recentWindows.firstIndex { $0.cgWindowID == win1.cgWindowID } ?? Int.max
                let index2 = recentWindows.firstIndex { $0.cgWindowID == win2.cgWindowID } ?? Int.max
                return index1 < index2
            }
        } else {
            // In normal mode, sort with recent ones first, then alphabetically
            return filteredWindows.sorted { win1, win2 in
                let isRecent1 = recentWindowIds.contains(win1.cgWindowID ?? 0)
                let isRecent2 = recentWindowIds.contains(win2.cgWindowID ?? 0)
                
                if isRecent1 != isRecent2 {
                    return isRecent1
                }
                
                return win1.name.localizedCaseInsensitiveCompare(win2.name) == .orderedAscending
            }
        }
    }
    
    init(windows: [WindowInfo], appName: String, app: NSRunningApplication, iconCenter: NSPoint, isHistory: Bool = false, callback: @escaping (AXUIElement, Bool) -> Void) {
        // Store history mode
        self.isHistoryMode = isHistory
        
        Logger.debug("WindowChooserView init - Initial windows count: \(windows.count)")
        
        // Use static method to filter and sort windows, passing the app and history mode
        self.options = WindowChooserView.sortWindows(windows, app: app, isHistory: isHistory)
        Logger.debug("WindowChooserView init - After filtering count: \(self.options.count)")
        
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
        
        // Calculate height based on filtered options count
        let validWindowCount = self.options.count
        let calculatedHeight = Constants.UI.windowHeight(for: validWindowCount)
        Logger.debug("Height calculation details:")
        Logger.debug("  - Valid window count: \(validWindowCount)")
        Logger.debug("  - Calculated height: \(calculatedHeight)")
        
        super.init(frame: NSRect(
            x: 0, 
            y: 0, 
            width: Constants.UI.windowWidth, 
            height: calculatedHeight
        ))
        
        // Set title based on mode immediately
        setupTitle(isHistory ? "Recent Windows" : appName)
        setupButtons()
        
        // Create thumbnail view only for non-history mode
        if !isHistory {
            self.thumbnailView = WindowThumbnailView(
                targetApp: app,
                dockIconCenter: iconCenter,
                options: self.options,
                windowChooser: self.window?.windowController as? WindowChooserController
            )
            
            // Show initial preview of topmost window if available
            if let topmostWindow = self.topmostWindow,
               let windowInfo = self.options.first(where: { $0.window == topmostWindow }),
               !windowInfo.isAppElement && windowInfo.cgWindowID == nil {
                // Use DispatchQueue to ensure view is fully loaded
                //DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    thumbnailView?.showThumbnail(for: windowInfo, withTimer: true)
                //}
            }
        }
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
        
        // Set title based on mode
        if isHistoryMode {
            titleField.stringValue = "Recent Windows"
        } else {
            titleField.stringValue = appName
        }
        
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
        // Clear existing buttons first
        buttons.forEach { $0.removeFromSuperview() }
        hideButtons.forEach { $0.removeFromSuperview() }
        closeButtons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        hideButtons.removeAll()
        closeButtons.removeAll()
        
        // Remove any existing app icons
        subviews.forEach { view in
            if view is NSImageView {
                view.removeFromSuperview()
            }
        }
        
        for (index, windowInfo) in options.enumerated() {
            /*Logger.debug("Creating button for window:")
            Logger.debug("  - Index: \(index)")
            Logger.debug("  - Name: \(windowInfo.name)")
            Logger.debug("  - ID: \(windowInfo.cgWindowID ?? 0)")*/
            
            let button = createButton(for: windowInfo, at: index)
            let closeButton = createCloseButton(for: windowInfo, at: index)
            
            addSubview(button)
            addSubview(closeButton)
            buttons.append(button)
            closeButtons.append(closeButton)
            
            // Add app icon only in history mode
            if isHistoryMode {
                addAppIcon(for: windowInfo, at: index, button: button)
            }
            
            // Only add minimize button in normal mode, but always add window control buttons for regular windows
            if !windowInfo.isAppElement {  // Remove the cgWindowID check
                // Add minimize button only in normal mode
                if !isHistoryMode {
                    let hideButton = createHideButton(for: windowInfo, at: index)
                    addSubview(hideButton)
                    hideButtons.append(hideButton)
                    
                    // Update minimize button state
                    if let minimizeButton = hideButtons.first(where: { $0.tag == index }) as? MinimizeButton {
                        var minimizedValue: AnyObject?
                        let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                         (minimizedValue as? Bool == true)
                        minimizeButton.updateMinimizedState(isMinimized)
                    }
                }
                
                // Always create window control buttons for actual windows
                let leftButton = createSideButton(for: windowInfo, at: index, isLeft: true)
                let centerButton = createSideButton(for: windowInfo, at: index, isLeft: false, isCenter: true)
                let rightButton = createSideButton(for: windowInfo, at: index, isLeft: false)
                
                addSubview(leftButton)
                addSubview(centerButton)
                addSubview(rightButton)
            }
        }
    }
    
    // Add helper function to check if it's a CGWindow entry
    private func isCGWindowEntry(_ windowInfo: WindowInfo) -> Bool {
        return windowInfo.cgWindowID != nil && windowInfo.isAppElement
    }
    
    private func addAppIcon(for windowInfo: WindowInfo, at index: Int, button: NSButton) {
        let iconSize: CGFloat = 16
        let iconY = frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding + 
            (Constants.UI.buttonHeight - iconSize) / 2
        
        // Position icon between close and minimize buttons
        let iconImageView = NSImageView(frame: NSRect(
            x: Constants.UI.windowPadding + 24,  // Same x position as minimize button
            y: iconY,
            width: iconSize,
            height: iconSize
        ))
        
        // Try to get app icon from running app
        if let cgWindowID = windowInfo.cgWindowID,
           let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[CFString: Any]],
           let cgWindowInfo = windowList.first,
           let ownerPID = cgWindowInfo[kCGWindowOwnerPID] as? pid_t,
           let runningApp = NSRunningApplication(processIdentifier: ownerPID) {
            iconImageView.image = runningApp.icon
        } else {
            // Fallback for AX windows
            var pid: pid_t = 0
            if AXUIElementGetPid(windowInfo.window, &pid) == .success,
               let runningApp = NSRunningApplication(processIdentifier: pid) {
                iconImageView.image = runningApp.icon
            }
        }
        
        // Configure icon view
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 2
        iconImageView.layer?.masksToBounds = true
        
        addSubview(iconImageView)
        
        // No need to adjust button position since we're using padding in the title
    }
    
    private func createButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton()
        
        // Adjust button width and position based on whether it needs control buttons
        let buttonWidth: CGFloat
        let buttonX: CGFloat
        
        if windowInfo.isAppElement {
            // For app elements only
            buttonWidth = Constants.UI.windowWidth - Constants.UI.windowPadding * 2
            buttonX = Constants.UI.windowPadding
        } else {
            // For all regular windows (both normal and history mode)
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
            userInfo: ["isMenuButton": true]
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
        let maxTitleLength = isHistoryMode ? 45 : 60  // Shorter titles in history mode
        let truncatedTitle = title.count > maxTitleLength ? 
            title.prefix(maxTitleLength) + "..." : 
            title
        
        let windowInfo = options[tag]
        
        // Different alignment and padding based on window type and mode
        if windowInfo.isAppElement {
            // Center align for app elements
            button.alignment = .center
            button.title = String(truncatedTitle)
        } else {
            // Left align for normal windows
            button.alignment = .left
            
            // Clear any existing padding first
            let baseTitle = String(truncatedTitle)
            
            if isHistoryMode {
                // In history mode: more space for app icon
                let leftPadding = "            "  // 12 spaces for app icon and padding
                button.title = leftPadding + baseTitle
            } else {
                // In normal mode: space for minimize button
                let leftPadding = "      "  // 6 spaces for minimize button
                button.title = leftPadding + baseTitle
            }
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
    
    private func applyHoverEffect(for button: NSButton) {
        // print("🔍 applyHoverEffect called for button with tag: \(button.tag)")
        
        // First clear any existing hover effects
        self.subviews.forEach { view in
            let identifier = view.accessibilityIdentifier()
            if identifier.starts(with: "hover-background-") {
                // print("  - Removing existing hover effect: \(identifier)")
                view.removeFromSuperview()
            }
        }
        
        // Create hover effect
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            
            let isDark = self.effectiveAppearance.isDarkMode
            // print("  - Dark mode: \(isDark)")
            
            let hoverColor = isDark ? 
                NSColor(white: 0.3, alpha: 0.8) :
                NSColor(white: 0.8, alpha: 0.8)
            
            let backgroundView = NSView(frame: NSRect(
                x: 0,
                y: button.frame.minY,
                width: self.bounds.width,
                height: button.frame.height
            ))
            // print("  - Creating background view at y: \(button.frame.minY), height: \(button.frame.height)")
            
            backgroundView.wantsLayer = true
            backgroundView.layer?.backgroundColor = hoverColor.cgColor
            backgroundView.layer?.cornerRadius = 4
            backgroundView.layer?.masksToBounds = true
            backgroundView.setAccessibilityIdentifier("hover-background-\(button.tag)")
            
            self.addSubview(backgroundView, positioned: .below, relativeTo: button)
            // print("  - Added background view to hierarchy")
            
            // Update button color based on window state
            if let windowInfo = options[safe: button.tag] {
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
            
            // Show thumbnail
            if button.tag < options.count {
                let windowInfo = options[button.tag]
                
                
                    // Normal mode - use existing thumbnail logic
                    if !windowInfo.isAppElement {
                        Logger.debug("""
                            Showing thumbnail for window:
                            - Name: \(windowInfo.name)
                            - CGWindowID: \(windowInfo.cgWindowID ?? 0)
                            - Is App Element: \(windowInfo.isAppElement)
                            """)
                        
                        if let cgWindowID = windowInfo.cgWindowID {
                            Logger.debug("History mode - Using window ID: \(cgWindowID)")
                            
                            // Create thumbnail view if needed
                            if thumbnailView == nil {
                                thumbnailView = WindowThumbnailView(
                                    targetApp: targetApp,  // Use the current app, not looking up by PID
                                    dockIconCenter: dockIconCenter,
                                    options: [windowInfo],
                                    windowChooser: self.window?.windowController as? WindowChooserController
                                )
                            }
                            
                            // Show thumbnail directly using the existing CGWindowID
                            thumbnailView?.showThumbnail(for: windowInfo, withTimer: false)
                        } else {
                            // If no CGWindowID, try to find it like in normal mode
                            Logger.debug("History mode - No CGWindowID, attempting to find window")
                            var pid: pid_t = 0
                            if AXUIElementGetPid(windowInfo.window, &pid) == .success {
                                // Use .optionAll to get all windows including minimized ones
                                let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] ?? []
                                //print("🔍 History mode - Window list: \(windowList)")
                                let appWindows = windowList.filter { dict in
                                    guard let windowPID = dict[kCGWindowOwnerPID] as? pid_t,
                                          windowPID == pid,
                                          let layer = dict[kCGWindowLayer] as? Int32,
                                          layer == 0 else {
                                        return false
                                    }
                                    return true
                                }
                                
                                // Try to find matching window
                                if let matchingWindow = appWindows.first(where: { dict in
                                    guard let windowTitle = dict[kCGWindowName] as? String else {
                                        return false
                                    }
                                    
                                    // Use the same normalization function as before
                                    func normalizeTitle(_ title: String) -> String {
                                        let baseTitle = title
                                            .replacingOccurrences(of: " - \(targetApp.localizedName ?? "")", with: "")
                                            .trimmingCharacters(in: .whitespaces)
                                        
                                        if baseTitle.contains(" - ") {
                                            return baseTitle.components(separatedBy: " - ")[0]
                                                .trimmingCharacters(in: .whitespaces)
                                        }
                                        return baseTitle
                                    }
                                    
                                    let normalizedTarget = normalizeTitle(windowInfo.name)
                                    let normalizedCurrent = normalizeTitle(windowTitle)
                                    
                                    return normalizedTarget == normalizedCurrent
                                }),
                                let windowID = matchingWindow[kCGWindowNumber] as? CGWindowID {
                                    // Create updated window info with the found ID
                                    let updatedWindowInfo = WindowInfo(
                                        window: windowInfo.window,
                                        name: windowInfo.name,
                                        cgWindowID: windowID,
                                        isAppElement: windowInfo.isAppElement
                                    )
                                    
                                    if thumbnailView == nil {
                                        thumbnailView = WindowThumbnailView(
                                            targetApp: targetApp,
                                            dockIconCenter: dockIconCenter,
                                            options: [updatedWindowInfo],
                                            windowChooser: self.window?.windowController as? WindowChooserController
                                        )
                                    }
                                    
                                    thumbnailView?.showThumbnail(for: updatedWindowInfo, withTimer: false)
                                }
                            }
                        }
                    }
                
            }
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let button = event.trackingArea?.owner as? NSButton,
           event.trackingArea?.userInfo?["isMenuButton"] as? Bool == true {
            
            // Get the window info for this button
            let windowInfo = options[button.tag]
            
            // In history mode, we need to find the correct app for each window
            if isHistoryMode {
                if let cgWindowID = windowInfo.cgWindowID,
                   let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[CFString: Any]],
                   let cgWindowInfo = windowList.first,
                   let ownerPID = cgWindowInfo[kCGWindowOwnerPID] as? pid_t,
                   let runningApp = NSRunningApplication(processIdentifier: ownerPID) {
                    
                    // Create a proper WindowInfo object from the CGWindow info
                    let updatedWindowInfo = WindowInfo(
                        window: windowInfo.window,
                        name: windowInfo.name,
                        cgWindowID: cgWindowID,
                        isAppElement: windowInfo.isAppElement
                    )
                    
                    // Create thumbnail view with the correct app and window info
                    thumbnailView = WindowThumbnailView(
                        targetApp: runningApp,
                        dockIconCenter: dockIconCenter,
                        options: [updatedWindowInfo],
                        windowChooser: self.window?.windowController as? WindowChooserController
                    )
                } else {
                    // Fallback for AX windows
                    var pid: pid_t = 0
                    if AXUIElementGetPid(windowInfo.window, &pid) == .success,
                       let runningApp = NSRunningApplication(processIdentifier: pid) {
                        thumbnailView = WindowThumbnailView(
                            targetApp: runningApp,
                            dockIconCenter: dockIconCenter,
                            options: [windowInfo], // Use original windowInfo since it's already correct type
                            windowChooser: self.window?.windowController as? WindowChooserController
                        )
                    }
                }
            }
            
            applyHoverEffect(for: button)
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
                    
                    // Only hide thumbnail if mouse is not over any menu entry
                    let mouseLocation = NSEvent.mouseLocation
                    let isOverAnyButton = buttons.contains { button in
                        guard let window = self.window else { return false }
                        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
                        let buttonFrameInScreen = window.convertPoint(toScreen: buttonFrameInWindow.origin)
                        let buttonScreenFrame = NSRect(
                            origin: buttonFrameInScreen,
                            size: buttonFrameInWindow.size
                        )
                        return buttonScreenFrame.contains(mouseLocation)
                    }
                    
                    //if !isOverAnyButton {
                        //thumbnailView?.hideThumbnail()
                    //}
                }
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        Logger.debug("Button clicked - tag: \(sender.tag)")
        
        // Hide thumbnail immediately and force close
        thumbnailView?.hideThumbnail(removePanel: true)
        
        let windowInfo = options[sender.tag]
        Logger.debug("Selected window info - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        // In history mode, we need special handling
        if isHistoryMode {
            if let cgWindowID = windowInfo.cgWindowID,
               let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[CFString: Any]],
               let cgWindowInfo = windowList.first,
               let ownerPID = cgWindowInfo[kCGWindowOwnerPID] as? pid_t,
               let app = NSRunningApplication(processIdentifier: ownerPID) {
                
                // Get fresh window list for the app
                let windows = AccessibilityService.shared.listApplicationWindows(for: app)
                
                // Try to find matching window by ID or name
                if let matchingWindow = windows.first(where: { $0.cgWindowID == cgWindowID }) ?? 
                                      windows.first(where: { $0.name == windowInfo.name }) {
                    // Use AccessibilityService to raise the window properly
                    AccessibilityService.shared.raiseWindow(windowInfo: matchingWindow, for: app)
                } else {
                    // Fallback: just activate the app if window not found
                    AccessibilityService.shared.activateApp(app)
                }
                
                // Close the history window chooser
                if let windowController = self.window?.windowController as? WindowChooserController {
                    windowController.close()
                }
                return
            }
        }
        
        // Rest of the existing code for non-history mode...
        // Add window to history when clicked
        WindowHistory.shared.addWindow(windowInfo, for: targetApp)
        
        var pid: pid_t = 0
        if windowInfo.cgWindowID != nil && AXUIElementGetPid(windowInfo.window, &pid) != .success {
            // For CGWindow entries, just activate the app
            targetApp.activate(options: [.activateIgnoringOtherApps])
            callback?(windowInfo.window, false)  // This will trigger the window raise through CGWindow
            
            // Update topmost window and refresh menu
            topmostWindow = windowInfo.window
            updateButtonStates()
            
            // Close window chooser after selection in history mode
            if isHistoryMode {
                if let windowController = self.window?.windowController as? WindowChooserController {
                    windowController.close()
                }
                return
            }
            
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
        
        // Define handleDoubleClick closure
        let handleDoubleClick = {
            if isDoubleClick {
                // Double click: minimize all other windows
                for (index, otherWindow) in self.options.enumerated() {
                    if index != sender.tag && !otherWindow.isAppElement {
                        // Minimize other windows
                        AXUIElementSetAttributeValue(otherWindow.window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    }
                }
            }
        }

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
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            if isMinimized {
                // Unminimize and raise
                AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
                
                // Update minimize button state
                if let hideButton = hideButtons.first(where: { $0.tag == sender.tag }) as? MinimizeButton {
                    hideButton.updateMinimizedState(false)
                }
                
                // Update topmost window
                self.topmostWindow = windowInfo.window
                self.updateButtonStates()
                
                // Ensure window gets focus
                AXUIElementSetAttributeValue(windowInfo.window, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(windowInfo.window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                
                self.callback?(windowInfo.window, false)
                
                // Close window chooser in history mode
                if self.isHistoryMode {
                    windowController?.close()
                    return
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    handleDoubleClick()
                    
                    // Update menu after a short delay
                    if let self = self {
                        if let windowController = self.window?.windowController as? WindowChooserController {
                            windowController.refreshMenu()
                        }
                    }
                }
            } else {
                // Just raise the window
                AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
                
                // Ensure window gets focus
                AXUIElementSetAttributeValue(windowInfo.window, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(windowInfo.window, kAXFocusedAttribute as CFString, true as CFTypeRef)
                
                callback?(windowInfo.window, false)
                
                // Close window chooser in history mode
                if isHistoryMode {
                    windowController?.close()
                    return
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    handleDoubleClick()
                    
                    // Refresh menu after all operations
                    if let windowController = self.window?.windowController as? WindowChooserController {
                        windowController.refreshMenu()
                    }
                }
            }
        }
    }
    
    private func handleAppElementClick() {
        // print("Processing click for app: \(targetApp.localizedName ?? "Unknown")")
        
        let hasVisibleWindows = hasVisibleWindows(for: targetApp)
        
        if targetApp.isActive && hasVisibleWindows {
            // print("App is active with visible windows, hiding")
            AccessibilityService.shared.hideAllWindows(for: targetApp)
            targetApp.hide()
            closeWindowChooser()
        } else {
            // print("App needs activation")
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
        // Use .optionAll to get all windows including minimized ones
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] ?? []
        
        return windowList.contains { info in
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer] as? Int32,
                  layer == kCGNormalWindowLevel else {
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
        print("WindowChooserView deinit")
        
        

        // Capture values before async operation
        let thumbnailViewToClean = thumbnailView
        let buttonsToClean = buttons
        let hideButtonsToClean = hideButtons
        let closeButtonsToClean = closeButtons

        Task { @MainActor in
            thumbnailViewToClean?.hideThumbnail(removePanel: true)
        }
        
        // Force close all thumbnails
        /*Task { @MainActor in
            WindowThumbnailView.forceCloseAllThumbnails()
            
            // Clean up thumbnail view
            await thumbnailViewToClean?.cleanup()
            
            // Clean up tracking areas
            let allButtons = buttonsToClean + hideButtonsToClean + closeButtonsToClean
            for button in allButtons {
                for area in button.trackingAreas {
                    button.removeTrackingArea(area)
                }
            }
        }*/
        
        // Clear reference
        thumbnailView = nil
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
            
        } else {
            // Add pid declaration here
            var pid: pid_t = 0
            if windowInfo.cgWindowID != nil && AXUIElementGetPid(windowInfo.window, &pid) != .success {
                // For CGWindow entries, use CGWindow-based closing
                AccessibilityService.shared.closeWindow(windowInfo: windowInfo, for: targetApp)
                
                // Close window chooser after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    windowController?.close()
                    
                    // Reopen window chooser after another short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let (_, _, iconCenter) = DockService.shared.findAppUnderCursor(at: NSEvent.mouseLocation) {
                            let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                            if !updatedWindows.isEmpty {
                                windowController?.updateWindows(updatedWindows, for: self.targetApp, at: iconCenter)
                                windowController?.window?.makeKeyAndOrderFront(nil)
                            }
                        }
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
                    
                    // Close window chooser after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        windowController?.close()
                        
                        // Reopen window chooser after another short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if let (_, _, iconCenter) = DockService.shared.findAppUnderCursor(at: NSEvent.mouseLocation) {
                                let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                                if !updatedWindows.isEmpty {
                                    windowController?.updateWindows(updatedWindows, for: self.targetApp, at: iconCenter)
                                    windowController?.window?.makeKeyAndOrderFront(nil)
                                }
                            }
                        }
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
    
    func updateWindows(_ windows: [WindowInfo], forceNormalMode: Bool = false) {
        // Reset history mode if needed
        if forceNormalMode {
            self.isHistoryMode = false
            
            // Also update title immediately
            titleField.stringValue = targetApp.localizedName ?? "Unknown"
        }
        
        // Use static method to filter and sort
        self.options = WindowChooserView.sortWindows(windows, app: targetApp, isHistory: isHistoryMode)
        
        // First, find the new topmost window
        topmostWindow = nil  // Reset first
        for windowInfo in self.options {
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
        
        // Recreate all buttons with updated windows
        setupButtons()
        
        // Force layout update
        needsLayout = true
        window?.contentView?.needsLayout = true
        
        // Update thumbnail view options instead of recreating
        if !isHistoryMode {
            if thumbnailView == nil {
                thumbnailView = WindowThumbnailView(
                    targetApp: targetApp,
                    dockIconCenter: dockIconCenter,
                    options: self.options,
                    windowChooser: self.window?.windowController as? WindowChooserController
                )
            } else {
                // Just update the options for existing thumbnailView
                thumbnailView?.updateOptions(self.options)
            }
        }
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
        // Cleanup thumbnail view without destroying it
        //thumbnailView?.hideThumbnail()
        
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

    func configureForMode(_ mode: WindowChooserMode) {
        switch mode {
        case .normal:
            titleField.stringValue = "Choose Window"
            // Ensure we reset to showing minimize/maximize buttons
            iconImageView?.isHidden = true
            minimizeButton?.isHidden = false
            maximizeButton?.isHidden = false
            
        case .history:
            titleField.stringValue = "Recent Windows"
            // Show icon instead of minimize/maximize buttons
            iconImageView?.isHidden = false
            minimizeButton?.isHidden = true
            maximizeButton?.isHidden = true
        }
        
        // Force layout update
        self.needsLayout = true
    }

    // When window becomes key, make this view first responder
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        
        // Ensure view is layer-backed
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        
        // Update thumbnail view's window chooser reference
        if let controller = window?.windowController as? WindowChooserController {
            Task { @MainActor in
                thumbnailView?.updateWindowChooser(controller)
                Logger.debug("Updated thumbnail view's window chooser from viewDidMoveToWindow")
            }
        }
    }

    func selectNextItem() {
        // print("🔍 selectNextItem called")
        // print("  - Current index: \(selectedIndex)")
        // print("  - Options count: \(options.count)")
        // print("  - Buttons count: \(buttons.count)")
        
        // Guard against empty options
        guard !options.isEmpty else {
            // print("  - ⚠️ No options available")
            return
        }
        
        selectedIndex = (selectedIndex + 1) % options.count
        // print("  - New index: \(selectedIndex)")
        updateSelection()
    }
    
    func selectPreviousItem() {
        // print("🔍 selectPreviousItem called")
        // print("  - Current index: \(selectedIndex)")
        // print("  - Options count: \(options.count)")
        // print("  - Buttons count: \(buttons.count)")
        
        // Guard against empty options
        guard !options.isEmpty else {
            // print("  - ⚠️ No options available")
            return
        }
        
        selectedIndex = (selectedIndex - 1 + options.count) % options.count
        // print("  - New index: \(selectedIndex)")
        updateSelection()
    }
    
    func selectCurrentItem() {
        guard selectedIndex >= 0 && selectedIndex < options.count else { return }
        
        let windowInfo = options[selectedIndex]
        
        // Hide thumbnail without destroying
        thumbnailView?.hideThumbnail(removePanel: true)
        
        // Add window to history
        WindowHistory.shared.addWindow(windowInfo, for: targetApp)
        
        // Get the app for this window
        var pid: pid_t = 0
        if AXUIElementGetPid(windowInfo.window, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            
            // First activate the app
            app.activate(options: .activateIgnoringOtherApps)
            
            // Unminimize if needed
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            if isMinimized {
                AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            
            // Ensure window gets focus and is frontmost
            AXUIElementSetAttributeValue(windowInfo.window, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementSetAttributeValue(windowInfo.window, kAXFocusedAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
            
            // Additional raise action after a tiny delay to ensure it takes effect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
                self.callback?(windowInfo.window, false)
            }
        } else {
            // Fallback to CGWindow-based activation
            targetApp.activate(options: .activateIgnoringOtherApps)
            
            // Try to raise window using accessibility API even for CGWindow
            AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
            
            // Call callback after a tiny delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.callback?(windowInfo.window, false)
            }
        }
        
        // Update topmost window and refresh menu
        topmostWindow = windowInfo.window
        updateButtonStates()
    }
    
    private func updateSelection() {
        // Guard against empty options
        guard !options.isEmpty else { return }
        
        if let selectedButton = buttons.first(where: { $0.tag == selectedIndex }) {
            let windowInfo = options[selectedIndex]
            
            // In history mode, we need to find the correct app for each window
            if isHistoryMode {
                if let cgWindowID = windowInfo.cgWindowID,
                   let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[CFString: Any]],
                   let cgWindowInfo = windowList.first,
                   let ownerPID = cgWindowInfo[kCGWindowOwnerPID] as? pid_t,
                   let runningApp = NSRunningApplication(processIdentifier: ownerPID) {
                    
                    // Create a proper WindowInfo object from the CGWindow info
                    let updatedWindowInfo = WindowInfo(
                        window: windowInfo.window,
                        name: windowInfo.name,
                        cgWindowID: cgWindowID,
                        isAppElement: windowInfo.isAppElement
                    )
                    
                    // Create thumbnail view with the correct app and window info
                    if thumbnailView == nil {
                        thumbnailView = WindowThumbnailView(
                            targetApp: runningApp,
                            dockIconCenter: dockIconCenter,
                            options: [updatedWindowInfo],
                            windowChooser: self.window?.windowController as? WindowChooserController
                        )
                    } else {
                        thumbnailView?.updateTargetApp(runningApp)
                        thumbnailView?.updateOptions([updatedWindowInfo])
                    }
                    thumbnailView?.showThumbnail(for: updatedWindowInfo, withTimer: false)
                } else {
                    // Fallback for AX windows
                    var pid: pid_t = 0
                    if AXUIElementGetPid(windowInfo.window, &pid) == .success,
                       let runningApp = NSRunningApplication(processIdentifier: pid) {
                        if thumbnailView == nil {
                            thumbnailView = WindowThumbnailView(
                                targetApp: runningApp,
                                dockIconCenter: dockIconCenter,
                                options: [windowInfo],
                                windowChooser: self.window?.windowController as? WindowChooserController
                            )
                        } else {
                            thumbnailView?.updateTargetApp(runningApp)
                            thumbnailView?.updateOptions([windowInfo])
                        }
                        thumbnailView?.showThumbnail(for: windowInfo, withTimer: false)
                    }
                }
            } else {
                // Normal mode - use existing thumbnail logic
                if !windowInfo.isAppElement {
                    if thumbnailView == nil {
                        thumbnailView = WindowThumbnailView(
                            targetApp: targetApp,
                            dockIconCenter: dockIconCenter,
                            options: [windowInfo],
                            windowChooser: self.window?.windowController as? WindowChooserController
                        )
                    } else {
                        thumbnailView?.updateOptions([windowInfo])
                    }
                    thumbnailView?.showThumbnail(for: windowInfo, withTimer: false)
                }
            }
            
            applyHoverEffect(for: selectedButton)
        }
    }

    func updateWindowHeight() {
        let newHeight = Constants.UI.windowHeight(for: self.options.count)
        if let windowController = self.window?.windowController as? WindowChooserController {
            windowController.updateWindowSize(to: newHeight)
        }
    }
}

// Add WindowChooserMode enum if it doesn't exist
enum WindowChooserMode {
    case normal
    case history
}
