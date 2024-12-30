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
import Cocoa
import ApplicationServices
import UserNotifications

// MARK: - Type Aliases and Constants

/// Represents information about a window, including its ID and display name
struct WindowInfo {
    let window: AXUIElement
    let name: String
}

/// Application-wide constants
enum Constants {
    /// UI-related constants
    enum UI {
        static let windowWidth: CGFloat = 240
        static let buttonHeight: CGFloat = 30
        static let buttonSpacing: CGFloat = 32
        static let cornerRadius: CGFloat = 10
        static let windowPadding: CGFloat = 8
        static let animationDuration: TimeInterval = 0.2
        
        // Additional constants for window sizing
        static let verticalPadding: CGFloat = 8
        static let titleHeight: CGFloat = 20
        static let titlePadding: CGFloat = 8
        
        // Window positioning constants
        static let leftSideButtonWidth: CGFloat = 16
        static let centerButtonWidth: CGFloat = 16
        static let rightSideButtonWidth: CGFloat = 16
        static let sideButtonsSpacing: CGFloat = 1
        static let screenEdgeMargin: CGFloat = 8.0
        static let windowHeightMargin: CGFloat = 40.0  // Margin for window height
        static let dockHeight: CGFloat = 70.0  // Approximate Dock height
        
        // Add constants for centered window size
        static let centeredWindowWidth: CGFloat = 1024
        static let centeredWindowHeight: CGFloat = 768
        
        // Calculate total height needed for a given number of buttons
        static func windowHeight(for buttonCount: Int) -> CGFloat {
            return titleHeight + CGFloat(buttonCount) * (buttonHeight + 2) + verticalPadding * 2
        }
        
        // Theme-related constants
        enum Theme {
            // Base colors that adapt to the theme
            static let backgroundColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(calibratedWhite: 0.2, alpha: 0.95) : 
                    NSColor(calibratedWhite: 0.95, alpha: 0.95)
            }
            
            static let primaryTextColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? .white : .black
            }
            
            static let secondaryTextColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(calibratedWhite: 0.6, alpha: 1.0) : 
                    NSColor(calibratedWhite: 0.4, alpha: 1.0)
            }
            
            static let iconTintColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? .white : NSColor(white: 0.2, alpha: 1.0)  // Lighter black in light mode
            }
            
            static let iconSecondaryTintColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(calibratedWhite: 0.6, alpha: 1.0) : 
                    NSColor(calibratedWhite: 0.6, alpha: 1.0)  // Consistent gray in both modes
            }
            
            static let hoverBackgroundColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(white: 1.0, alpha: 0.05) :   // Subtle in dark mode
                    NSColor(white: 0.0, alpha: 0.001)    // Very subtle in light mode
            }
            
            // Alias for semantic usage
            static let titleColor = primaryTextColor
            static let buttonTextColor = primaryTextColor
            static let buttonHighlightColor = primaryTextColor
            static let buttonSecondaryTextColor = secondaryTextColor
        }
        
        // Constants for bubble arrow
        static let arrowHeight: CGFloat = 8
        static let arrowWidth: CGFloat = 16
        static let arrowOffset: CGFloat = 0  // Distance from bottom center
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
        static let frameKey = kAXPositionAttribute as CFString  // Use position attribute instead
        static let sizeKey = kAXSizeAttribute as CFString      // Add size key for completeness
    }
    
    /// Performance-related constants
    enum Performance {
        static let mouseDebounceInterval: TimeInterval = 0.05  // 50ms debounce for mouse events
        static let windowRefreshDelay: TimeInterval = 0.01    // 10ms delay for window refresh
        static let minimumWindowRestoreDelay: TimeInterval = 0.02 // 20ms minimum delay between window operations
        static let maxBatchSize: Int = 5  // Maximum number of windows to process in one batch
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
    private var callback: ((AXUIElement, Bool) -> Void)?
    private var buttons: [NSButton] = []
    private var hideButtons: [NSButton] = []
    private var titleField: NSTextField!
    private let targetApp: NSRunningApplication
    private var lastMaximizeClickTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.3
    private var topmostWindow: AXUIElement?
    
    init(windows: [WindowInfo], appName: String, app: NSRunningApplication, callback: @escaping (AXUIElement, Bool) -> Void) {
        self.options = windows
        self.callback = callback
        self.targetApp = app
        
        // Find the topmost window
        if let frontmost = windows.first(where: { window in
            var frontValue: AnyObject?
            if AXUIElementCopyAttributeValue(window.window, "AXMain" as CFString, &frontValue) == .success,
               let isFront = frontValue as? Bool {
                return isFront
            }
            return false
        }) {
            self.topmostWindow = frontmost.window
        }
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.UI.windowWidth, height: Constants.UI.windowHeight(for: windows.count)))
        setupTitle(appName)
        setupButtons()
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
            let button = createButton(for: windowInfo, at: index)
            let hideButton = createHideButton(for: windowInfo, at: index)
            addSubview(button)
            addSubview(hideButton)
            buttons.append(button)
            hideButtons.append(hideButton)
        }
    }
    
    private func createButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton(frame: NSRect(
            x: 24,
            y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: Constants.UI.windowWidth - Constants.UI.windowPadding * 2 - 24 - 
                  (Constants.UI.leftSideButtonWidth + Constants.UI.centerButtonWidth + Constants.UI.rightSideButtonWidth + Constants.UI.sideButtonsSpacing * 2) - 8,
            height: Constants.UI.buttonHeight
        ))
        
        configureButton(button, title: windowInfo.name, tag: index)
        
        // Highlight the topmost window with brighter text
        if windowInfo.window == topmostWindow {
            button.contentTintColor = Constants.UI.Theme.buttonTextColor
        } else {
            button.contentTintColor = Constants.UI.Theme.buttonSecondaryTextColor
        }
        
        addHoverEffect(to: button)
        
        // Create left side button
        let leftButton = createSideButton(for: windowInfo, at: index, isLeft: true)
        addSubview(leftButton)
        
        // Create center (maximize) button
        let centerButton = createSideButton(for: windowInfo, at: index, isLeft: false, isCenter: true)
        addSubview(centerButton)
        
        // Create right side button
        let rightButton = createSideButton(for: windowInfo, at: index, isLeft: false)
        addSubview(rightButton)
        
        return button
    }
    
    private func createHideButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton(frame: NSRect(
            x: Constants.UI.windowPadding,
            y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: 20,
            height: Constants.UI.buttonHeight
        ))
        
        // Check if window is minimized
        var isVisible = false
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &value) == .success,
           let minimized = value as? Bool {
            isVisible = !minimized
        }
        
        // Create minimize image with proper styling
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Minimize")?
            .withSymbolConfiguration(config)
        button.image = image
        button.imagePosition = .imageOnly
        
        // Configure button appearance
        button.bezelStyle = .inline
        button.tag = index
        button.target = self
        button.action = #selector(hideButtonClicked(_:))
        button.isBordered = false
        button.setButtonType(.momentaryLight)
        
        // Set color based on window state
        let activeColor = Constants.UI.Theme.iconTintColor  // Use same color as other active icons
        let inactiveColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)  // Subtle gray for minimized state
        
        button.wantsLayer = true
        button.layer?.cornerRadius = 5.5
        button.layer?.masksToBounds = true
        
        // Set initial state
        if isVisible {
            button.contentTintColor = activeColor
            button.alphaValue = 1.0
        } else {
            button.contentTintColor = inactiveColor
            button.alphaValue = 0.5
        }
        
        // Always enable the button
        button.isEnabled = true
        
        // Add hover effect
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
        button.font = .systemFont(ofSize: 13.5)  // Adjusted font size to match Dock tooltip
        
        // Set initial color based on window state
        if options[tag].window == topmostWindow {
            button.contentTintColor = Constants.UI.Theme.primaryTextColor
        } else {
            button.contentTintColor = Constants.UI.Theme.secondaryTextColor
        }
        
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
                if hideButtons.contains(button) {
                    // Get window state
                    let window = options[button.tag].window
                    var isMinimized = false
                    var value: AnyObject?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
                       let minimized = value as? Bool {
                        isMinimized = minimized
                    }
                    
                    // Update button appearance based on window state
                    button.contentTintColor = isMinimized ? 
                        NSColor.tertiaryLabelColor.withAlphaComponent(0.5) :
                        Constants.UI.Theme.iconTintColor
                    button.alphaValue = isMinimized ? 0.5 : 1.0
                } else if button.action == #selector(moveWindowLeft(_:)) || 
                          button.action == #selector(moveWindowRight(_:)) ||
                          button.action == #selector(maximizeWindow(_:)) {
                    // Side and maximize button hover effect
                    button.contentTintColor = Constants.UI.Theme.iconTintColor
                    button.layer?.backgroundColor = Constants.UI.Theme.hoverBackgroundColor.cgColor
                    button.needsDisplay = true  // Force redraw
                } else {
                    // Window button hover logic
                    let window = options[button.tag].window
                    if window != topmostWindow {
                        button.contentTintColor = Constants.UI.Theme.primaryTextColor
                    }
                }
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Constants.UI.animationDuration
                if hideButtons.contains(button) {
                    // Existing hide button exit logic
                    // ...
                } else if button.action == #selector(moveWindowLeft(_:)) || 
                          button.action == #selector(moveWindowRight(_:)) ||
                          button.action == #selector(maximizeWindow(_:)) {
                    let window = options[button.tag].window
                    let isMaximize = button.action == #selector(maximizeWindow(_:))
                    let isLeft = button.action == #selector(moveWindowLeft(_:))
                    let isInPosition = isMaximize ? 
                        isWindowMaximized(window) : 
                        isWindowInPosition(window, onLeft: isLeft)
                    button.contentTintColor = isInPosition ? 
                        Constants.UI.Theme.iconTintColor : 
                        Constants.UI.Theme.iconSecondaryTintColor
                    button.layer?.backgroundColor = .clear
                    button.needsDisplay = true  // Force redraw
                } else {
                    // Window button exit logic
                    let window = options[button.tag].window
                    if window != topmostWindow {
                        button.contentTintColor = Constants.UI.Theme.secondaryTextColor
                    }
                }
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        let window = options[sender.tag].window
        
        // Always show and raise the window
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AccessibilityService.shared.raiseWindow(window: window, for: targetApp)
        targetApp.activate(options: [.activateIgnoringOtherApps])
        
        // Update topmost window state
        updateTopmostWindow(window)
        
        // Update corresponding hide button state with correct styling
        let hideButton = hideButtons[sender.tag]
        hideButton.isEnabled = true
        hideButton.contentTintColor = Constants.UI.Theme.iconTintColor
        hideButton.alphaValue = 1.0
        
        // Re-add hover effect
        let trackingArea = NSTrackingArea(
            rect: hideButton.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: hideButton,
            userInfo: nil
        )
        hideButton.addTrackingArea(trackingArea)
    }
    
    @objc private func hideButtonClicked(_ sender: NSButton) {
        let window = options[sender.tag].window
        
        let activeColor = Constants.UI.Theme.iconTintColor  // Use same color as other active icons
        let inactiveColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
        
        // Check current window state
        var minimizedValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
           let isMinimized = minimizedValue as? Bool {
            if isMinimized {
                // Window is minimized - restore it
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                AccessibilityService.shared.raiseWindow(window: window, for: targetApp)
                targetApp.activate(options: [.activateIgnoringOtherApps])
                
                // Update topmost window state
                updateTopmostWindow(window)
                
                // Update button state to active
                sender.contentTintColor = activeColor
                sender.alphaValue = 1.0
            } else {
                // Window is visible - minimize it
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                
                // Handle topmost window changes
                if window == topmostWindow {
                    if let nextWindow = options.first(where: { windowInfo in
                        var minimizedValue: AnyObject?
                        if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                           let isMinimized = minimizedValue as? Bool {
                            return !isMinimized
                        }
                        return false
                    })?.window {
                        updateTopmostWindow(nextWindow)
                    } else {
                        topmostWindow = nil
                    }
                }
                
                // Update button state to inactive
                sender.contentTintColor = inactiveColor
                sender.alphaValue = 0.5
            }
        }
    }
    
    deinit {
        // Remove tracking areas
        let buttonsToClean = buttons + hideButtons
        Task { @MainActor in
            for button in buttonsToClean {
                for area in button.trackingAreas {
                    button.removeTrackingArea(area)
                }
            }
        }
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
        
        // Create button image
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let imageName: String
        let accessibilityDescription: String
        
        if isCenter {
            // Check if window is on secondary display
            let isOnSecondary = isWindowOnSecondaryDisplay(windowInfo.window)
            imageName = isOnSecondary ? "2.square.fill" : "square.fill"
            accessibilityDescription = isOnSecondary ? "Move to Primary" : "Toggle Window Size"
        } else {
            // Use simpler arrow icons for left/right
            imageName = isLeft ? "chevron.left.circle.fill" : "chevron.right.circle.fill"
            accessibilityDescription = isLeft ? "Move Left" : "Move Right"
        }
        
        let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
        button.image = image
        button.imagePosition = .imageOnly
        
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
        
        addHoverEffect(to: button)
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
            // Double-click behavior remains the same - move to secondary display
            positionWindow(window, maximize: true, useSecondaryDisplay: true)
        } else {
            // Single click now toggles between maximized and centered
            if isWindowMaximized(window) {
                // If maximized, center the window with standard dimensions
                centerWindow(window)
            } else {
                // If not maximized, maximize the window
                positionWindow(window, maximize: true, useSecondaryDisplay: false)
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
            
            // Set position first
            if let positionValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            }
            usleep(1000)
            
            // Then set size
            if let sizeValue = AXValueCreate(.cgSize, &newSize) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            usleep(1000)
            
            // Update all buttons after maximizing
            if let index = options.firstIndex(where: { $0.window == window }) {
                refreshButtons(for: window, at: index)  // Use refreshButtons instead of updateButtonColors
            }
        } else {
            let margin = Constants.UI.screenEdgeMargin
            let usableWidth = (visibleFrame.width - (margin * 3)) / 2
            newSize = CGSize(width: usableWidth, height: visibleFrame.height)
            position = CGPoint(
                x: onLeft! ? visibleFrame.minX + margin : visibleFrame.maxX - usableWidth - margin,
                y: 0
            )
        }
        
        // Set size and position in a single batch
        if let sizeValue = AXValueCreate(.cgSize, &newSize),
           let positionValue = AXValueCreate(.cgPoint, &position) {
            // Set size first
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            usleep(1000)
            
            // Set position
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            usleep(1000)
            
            // Update all buttons after positioning
            if let index = options.firstIndex(where: { $0.window == window }) {
                refreshButtons(for: window, at: index)  // Use refreshButtons instead of updateButtonColors
            }
        }
        
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
    }
    
    // Add new method to refresh all buttons
    private func refreshButtons(for window: AXUIElement, at index: Int) {
        let buttons = self.subviews.compactMap { $0 as? NSButton }
        for button in buttons {
            if button.tag == index {
                if button.action == #selector(maximizeWindow(_:)) {
                    // Update maximize button state and icon
                    let isMaximized = isWindowMaximized(window)
                    let isOnSecondary = isWindowOnSecondaryDisplay(window)
                    
                    // Update icon based on screen position
                    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    let imageName = isOnSecondary ? "2.square.fill" : "square.fill"
                    let accessibilityDescription = isOnSecondary ? "Move to Primary" : "Toggle Window Size"
                    
                    if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
                        .withSymbolConfiguration(config) {
                        button.image = image
                    }
                    
                    // Update color based on maximized state
                    button.contentTintColor = isMaximized ? 
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
                }
            }
        }
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
            
            // Allow for some tolerance in position and size
            let tolerance: CGFloat = 5.0
            let isExpectedWidth = abs(size.width - expectedWidth) < tolerance
            
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
    }
    
    @objc private func moveWindowRight(_ sender: NSButton) {
        let window = options[sender.tag].window
        positionWindow(window, onLeft: false)
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
        
        // Update button state
        if let index = options.firstIndex(where: { $0.window == window }) {
            refreshButtons(for: window, at: index)
        }
    }
}

/// A custom window controller that manages the window chooser interface
class WindowChooserController: NSWindowController {
    private let windowCallback: (AXUIElement) -> Void
    private var chooserView: WindowChooserView?
    private let targetApp: NSRunningApplication
    private var trackingArea: NSTrackingArea?
    private let dismissalMargin: CGFloat = 20.0
    private var visualEffectView: NSVisualEffectView?  // Add this property
    private var isClosing = false
    
    init(at point: CGPoint, windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (AXUIElement) -> Void) {
        self.windowCallback = callback
        self.targetApp = app
        
        let height = Constants.UI.windowHeight(for: windows.count)
        let width = Constants.UI.windowWidth
        
        // Calculate position to be centered above the Dock icon
        let dockHeight: CGFloat = 70 // Approximate Dock height
        let tooltipOffset: CGFloat = -4 // Negative offset to overlap the Dock slightly
        
        // Keep x position exactly at click point for perfect centering
        let adjustedX = point.x - width/2
        
        // Position the window just above the Dock
        let adjustedY = dockHeight + tooltipOffset
        
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
            appName: targetApp.localizedName ?? "Application",
            app: targetApp,
            callback: { [weak self] window, isHideAction in
                guard let self = self else { return }
                
                if isHideAction {
                    // Hide the selected window
                    AccessibilityService.shared.hideWindow(window: window, for: self.targetApp)
                } else {
                    // Always show and raise the window
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    AccessibilityService.shared.raiseWindow(window: window, for: self.targetApp)
                    self.targetApp.activate(options: [.activateIgnoringOtherApps])
                }
                
                // Notify DockWatcher about menu closure
                NotificationCenter.default.post(name: NSNotification.Name("WindowChooserDidClose"), object: nil)
                
                // Close the chooser window
                self.close()
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
        super.close()
        isClosing = false
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
    
    // Modify the window state struct to include order
    private var windowStates: [pid_t: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)]] = [:]
    
    private init() {}
    
    func requestAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        Logger.info("🔐 Accessibility \(trusted ? "granted" : "not granted - please grant in System Settings")")
        
        if !trusted {
            Logger.warning("⚠️ Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            
            // Create an alert to guide the user
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "DockAppToggler requires accessibility permissions to function properly. Please grant these permissions in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            // Show the alert and handle the response
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open the Accessibility settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        
        return trusted
    }
    
    func listApplicationWindows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        var windows: [WindowInfo] = []
        
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            return []
        }
        
        // First pass: collect all regular windows and check if we have any with titles
        var hasWindowWithTitle = false
        var allWindows: [(window: AXUIElement, title: String)] = []
        
        for window in windowArray {
            // Skip non-regular windows (like Desktop)
            var roleValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               role != kAXWindowRole as String {
                continue
            }
            
            // Get window title
            var titleValue: AnyObject?
            let title: String
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let windowTitle = titleValue as? String,
               !windowTitle.isEmpty {
                title = windowTitle
                hasWindowWithTitle = true
            } else {
                title = app.localizedName ?? "Window"
            }
            
            allWindows.append((window: window, title: title))
        }
        
        // Second pass: only include windows with titles if we have any
        for (window, title) in allWindows {
            if !hasWindowWithTitle || (hasWindowWithTitle && title != (app.localizedName ?? "Window")) {
                windows.append(WindowInfo(window: window, name: title))
            }
        }
        
        return windows
    }
    
    private func createWindowInfo(for window: AXUIElement, app: NSRunningApplication, index: Int) -> WindowInfo? {
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
        return WindowInfo(window: window, name: windowName)
    }
    
    private func createFallbackWindowInfo(for app: NSRunningApplication, index: Int) -> WindowInfo? {
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
        
        // Create AXUIElement for the window
        let window = AXUIElementCreateApplication(app.processIdentifier)
        
        // Get the actual window name from CGWindowListCopyWindowInfo
        let windowTitle = matchingWindows[index][kCGWindowName as CFString] as? String
        let windowName = windowTitle ?? "\(app.localizedName ?? "Window") \(index + 1)"
        
        Logger.success("Adding window (fallback): '\(windowName)' ID: \(windowID)")
        return WindowInfo(window: window, name: windowName)
    }
    
    func raiseWindow(window: AXUIElement, for app: NSRunningApplication) {
        // First activate the app
        app.activate(options: [.activateIgnoringOtherApps])
        
        // Use AXUIElementPerformAction to raise the window
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    
    func hideWindow(window: AXUIElement, for app: NSRunningApplication) {
        AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef)
    }
    
    func checkWindowVisibility(_ window: AXUIElement) -> Bool {
        // Check hidden state
        var hiddenValue: AnyObject?
        let hiddenResult = AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue)
        let isHidden = (hiddenResult == .success && (hiddenValue as? Bool == true))
        
        // Check minimized state
        var minimizedValue: AnyObject?
        let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        let isMinimized = (minimizedResult == .success && (minimizedValue as? Bool == true))
        
        return !isHidden && !isMinimized
    }
    
    func hideAllWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        Task<Void, Never> { @MainActor in
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            
            guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                return
            }
            
            var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
            for (index, window) in windows.enumerated() {
                let wasVisible = checkWindowVisibility(window)
                states.append((window: window,
                             wasVisible: wasVisible,
                             order: index,
                             stackOrder: index))
            }
            
            // Update window operations with MainActor isolation
            await executeWindowOperationsInBatches(windows) { @MainActor window in
                let _ = AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef)
            }
            
            windowStates[pid] = states
        }
    }
    
    func restoreAllWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        Task<Void, Never> { @MainActor in
            guard let states = windowStates[pid] else { return }
            
            // First pass: restore all windows in their original order (back to front)
            for state in states {
                if state.wasVisible {
                    let _ = AXUIElementSetAttributeValue(state.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    let _ = AXUIElementSetAttributeValue(state.window, kAXHiddenAttribute as CFString, false as CFTypeRef)
                }
            }
            
            // Small delay to allow windows to be restored
            try? await Task.sleep(nanoseconds: UInt64(Constants.Performance.windowRefreshDelay * 1_000_000_000))
            
            // Second pass: raise windows in reverse order to maintain z-order (front to back)
            for state in states.reversed() {
                if state.wasVisible {
                    let _ = AXUIElementPerformAction(state.window, kAXRaiseAction as CFString)
                    try? await Task.sleep(nanoseconds: UInt64(Constants.Performance.windowRefreshDelay * 1_000_000_000))
                }
            }
            
            // Activate the app after all windows are restored
            app.activate(options: [.activateIgnoringOtherApps])
            
            windowStates.removeValue(forKey: pid)
        }
    }
    
    // Fix the clearWindowStates method
    nonisolated func clearWindowStates(for app: NSRunningApplication) {
        // Use @unchecked Sendable to bypass the Sendable check
        Task<Void, Never> { @MainActor [self] in 
            self.windowStates.removeValue(forKey: app.processIdentifier)
        }
    }
    
    // Add a new method to get window stacking order
    private func determineWindowStackOrder(for app: NSRunningApplication) -> [CGWindowID: Int] {
        var stackOrder: [CGWindowID: Int] = [:]
        
        // Get all windows in current stacking order
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return stackOrder
        }
        
        // Create mapping of window IDs to their stacking order
        for (index, windowInfo) in windowList.enumerated() {
            guard let pid = windowInfo[kCGWindowOwnerPID] as? pid_t,
                  pid == app.processIdentifier,
                  let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else {
                continue
            }
            stackOrder[windowID] = index
        }
        
        return stackOrder
    }
    
    func initializeWindowStates(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        // Skip if we already have states for this app
        guard windowStates[pid] == nil else { return }
        
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        
        // Get window stacking order
        let stackOrder = determineWindowStackOrder(for: app)
        var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
        
        // Initialize states for all windows
        for (index, window) in windows.enumerated() {
            let isVisible = checkWindowVisibility(window)
            
            // Get window ID for stack order
            var windowIDRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDRef)
            let windowStackOrder: Int
            if result == .success,
               let numRef = windowIDRef as? NSNumber {
                windowStackOrder = Int.max - (stackOrder[CGWindowID(numRef.uint32Value)] ?? 0)
            } else {
                windowStackOrder = 0
            }
            
            states.append((window: window,
                          wasVisible: isVisible,
                          order: index,
                          stackOrder: windowStackOrder))
        }
        
        // Store states sorted by stack order
        windowStates[pid] = states.sorted { $0.stackOrder < $1.stackOrder }
    }
    
    // Add helper method to check if a window is the Finder desktop
    private func isFinderDesktop(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        // This method is no longer needed as we filter by role instead
        return false
    }
    
    // Update the processBatchedWindows method to handle async operations correctly
    private func executeWindowOperationsInBatches(_ windows: [AXUIElement], operation: @MainActor @escaping (AXUIElement) async -> Void) async {
        let batchSize = Constants.Performance.maxBatchSize
        
        // Process windows in batches
        for batch in stride(from: 0, to: windows.count, by: batchSize) {
            let end = min(batch + batchSize, windows.count)
            let currentBatch = Array(windows[batch..<end])
            
            // Process each window in the batch
            for window in currentBatch {
                // Execute the operation directly since we're already on MainActor
                await operation(window)
            }
            
            // Add delay between batches if needed
            if end < windows.count {
                try? await Task.sleep(nanoseconds: UInt64(Constants.Performance.minimumWindowRestoreDelay * 1_000_000_000))
            }
        }
    }
}

// MARK: - Dock Service

@MainActor
class DockService {
    static let shared = DockService()
    private let workspace = NSWorkspace.shared
    
    private init() {}
    
    func findDockProcess() -> NSRunningApplication? {
        return workspace.runningApplications.first(where: { $0.bundleIdentifier == Constants.Identifiers.dockBundleID })
    }
    
    func findAppUnderCursor(at point: CGPoint) -> (app: NSRunningApplication, url: URL, iconCenter: CGPoint)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementUntyped: AXUIElement?
        
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementUntyped) == .success,
              let element = elementUntyped else {
            return nil
        }
        
        // Get the element frame using position and size
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var iconCenter = point
        
        if AXUIElementCopyAttributeValue(element, Constants.Accessibility.frameKey, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, Constants.Accessibility.sizeKey, &sizeValue) == .success,
           CFGetTypeID(positionValue!) == AXValueGetTypeID(),
           CFGetTypeID(sizeValue!) == AXValueGetTypeID() {
            
            let position = positionValue as! AXValue
            let size = sizeValue as! AXValue
            
            var pointValue = CGPoint.zero
            var sizeValue = CGSize.zero
            
            if AXValueGetValue(position, .cgPoint, &pointValue) &&
               AXValueGetValue(size, .cgSize, &sizeValue) {
                iconCenter = CGPoint(x: pointValue.x + sizeValue.width/2,
                                   y: pointValue.y + sizeValue.height)
            }
        }
        
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let dockApp = findDockProcess(),
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
        
        // Get all windows for the app
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // Only return the app if it has actual windows
        if !windows.isEmpty {
            return (app: app, url: url, iconCenter: iconCenter)
        }
        
        return nil
    }
    
    func performDockIconAction(app: NSRunningApplication, clickCount: Int64) -> Bool {
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
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var windowChooser: WindowChooserController?
    nonisolated(unsafe) private var menuShowTask: DispatchWorkItem?
    private var lastHoveredApp: NSRunningApplication?
    private var lastWindowOrder: [AXUIElement]?
    private let menuShowDelay: TimeInterval = 0.01
    private var lastClickTime: TimeInterval = 0
    private let clickDebounceInterval: TimeInterval = 0.3
    private var clickedApp: NSRunningApplication?
    private let dismissalMargin: CGFloat = 20.0  // Add this line
    private var lastMouseMoveTime: TimeInterval = 0
    private var isContextMenuActive: Bool = false
    // Add strong reference to prevent deallocation
    private var chooserControllers: [NSRunningApplication: WindowChooserController] = [:]
    
    init() {
        setupEventTap()
        setupNotifications()
        Logger.info("DockWatcher initialized")
    }
    
    nonisolated private func cleanup() {
        DispatchQueue.main.async { [weak self] in
            // Cancel any pending tasks
            self?.menuShowTask?.cancel()
            
            // Clean up all window choosers
            self?.chooserControllers.values.forEach { $0.close() }
            self?.chooserControllers.removeAll()
            
            self?.windowChooser?.close()
            self?.windowChooser = nil
        }
    }
    
    deinit {
        // Remove observer
        NotificationCenter.default.removeObserver(self)
        
        // Clean up event tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        
        // Clean up run loop source
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        
        // Clean up references
        eventTap = nil
        runLoopSource = nil
        
        // Call cleanup synchronously before deinit completes
        cleanup()
    }
    
    private func setupEventTap() {
        guard AccessibilityService.shared.requestAccessibilityPermissions() else {
            return
        }
        
        // Break down event mask into individual components
        let mouseMoved = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let leftMouseDown = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let leftMouseUp = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let rightMouseDown = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        let rightMouseUp = CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        
        // Combine event masks
        let eventMask = mouseMoved | leftMouseDown | leftMouseUp | rightMouseDown | rightMouseUp
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refconUnwrapped = refcon else {
                return Unmanaged.passRetained(event)
            }
            
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refconUnwrapped).takeUnretainedValue()
            let location = event.location
            
            switch type {
            case .mouseMoved:
                Task { @MainActor in
                    watcher.processMouseMovement(at: location)
                }
            case .leftMouseDown:
                // Debounce clicks
                let currentTime = ProcessInfo.processInfo.systemUptime
                if currentTime - watcher.lastClickTime >= watcher.clickDebounceInterval {
                    watcher.lastClickTime = currentTime
                    
                    // Store the app being clicked for mouseUp handling
                    if let (app, _, _) = DockService.shared.findAppUnderCursor(at: location) {
                        watcher.clickedApp = app
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                }
            case .leftMouseUp:
                // Process the click on mouseUp if we have a stored app
                if let app = watcher.clickedApp {
                    if watcher.processDockIconClick(app: app) {
                        watcher.clickedApp = nil
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                }
                watcher.clickedApp = nil
            case .rightMouseDown:
                Task { @MainActor in
                    // Set context menu active flag
                    watcher.isContextMenuActive = true
                    // Close any existing window chooser
                    watcher.windowChooser?.close()
                    watcher.windowChooser = nil
                    watcher.lastHoveredApp = nil
                    
                    // Add observer for context menu dismissal
                    NotificationCenter.default.addObserver(
                        watcher,
                        selector: #selector(watcher.contextMenuDidDismiss),
                        name: NSMenu.didEndTrackingNotification,
                        object: nil
                    )
                }
            default:
                break
            }
            
            return Unmanaged.passRetained(event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
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
        
        Logger.success("Successfully started monitoring mouse movements")
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("WindowChooserDidClose"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastHoveredApp = nil
            }
        }
        
        // Fix the app termination notification handler
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Capture the app reference outside the Task
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                // Create a new task with the captured value
                Task { @MainActor in
                    AccessibilityService.shared.clearWindowStates(for: app)
                }
            }
        }
    }
    
    private func displayWindowSelector(for app: NSRunningApplication, at point: CGPoint, windows: [WindowInfo]) {
        // Close any existing window chooser for this app
        chooserControllers[app]?.close()
        
        // Create and show new chooser
        let chooser = WindowChooserController(
            at: point,
            windows: windows,
            app: app,
            callback: { window in
                AccessibilityService.shared.raiseWindow(window: window, for: app)
                Task {
                    // Hide other windows in background
                    for windowInfo in windows where windowInfo.window != window {
                        AccessibilityService.shared.hideWindow(window: windowInfo.window, for: app)
                    }
                }
            }
        )
        
        // Store strong reference
        chooserControllers[app] = chooser
        self.windowChooser = chooser
        chooser.window?.makeKeyAndOrderFront(nil)
    }
    
    private func processMouseMovement(at point: CGPoint) {
        // Debounce mouse move events
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard (currentTime - lastMouseMoveTime) >= Constants.Performance.mouseDebounceInterval else {
            return
        }
        lastMouseMoveTime = currentTime
        
        // Cancel any pending menu show/hide tasks
        menuShowTask?.cancel()
        
        // Check if mouse is over any dock item
        if let (app, _, iconCenter) = DockService.shared.findAppUnderCursor(at: point) {
            // Don't show menu if we're in the middle of a click
            if clickedApp == nil && app != lastHoveredApp {
                let task = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    
                    Task {
                        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
                        
                        if !windows.isEmpty {
                            await MainActor.run {
                                // Close any existing window chooser before showing new one
                                self.windowChooser?.close()
                                self.windowChooser = nil
                                
                                self.displayWindowSelector(for: app, at: iconCenter, windows: windows)
                                self.lastHoveredApp = app
                            }
                        }
                    }
                }
                
                menuShowTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + menuShowDelay, execute: task)
            }
            return
        }
        
        // Mouse is not over a dock item, check if it's over the window chooser
        guard let chooser = windowChooser,
              let window = chooser.window else {
            // If we're not over a dock item and there's no window chooser, clear state
            lastHoveredApp = nil
            return
        }
        
        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = window.frame
        let expandedFrame = NSRect(
            x: windowFrame.minX - dismissalMargin,
            y: windowFrame.minY - dismissalMargin,
            width: windowFrame.width + dismissalMargin * 2,
            height: windowFrame.height + dismissalMargin * 2
        )
        
        // Only close if mouse is outside expanded frame AND not over a dock item
        if !expandedFrame.contains(mouseLocation) {
            let task = DispatchWorkItem { [weak self] in
                guard let self = self,
                      let currentWindow = self.windowChooser?.window else { return }
                
                let currentLocation = NSEvent.mouseLocation
                let currentFrame = currentWindow.frame
                let currentExpandedFrame = NSRect(
                    x: currentFrame.minX - self.dismissalMargin,
                    y: currentFrame.minY - self.dismissalMargin,
                    width: currentFrame.width + self.dismissalMargin * 2,
                    height: currentFrame.height + self.dismissalMargin * 2
                )
                
                // Double-check position before closing
                if !currentExpandedFrame.contains(currentLocation) && 
                   DockService.shared.findAppUnderCursor(at: currentLocation) == nil {
                    self.windowChooser?.close()
                    self.windowChooser = nil
                    self.lastHoveredApp = nil
                }
            }
            
            menuShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + menuShowDelay, execute: task)
        }
    }
    
    private func processDockIconClick(app: NSRunningApplication) -> Bool {
        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")
        
        // Close any existing menu
        windowChooser?.close()
        windowChooser = nil
        lastHoveredApp = nil
        
        // Special handling for Finder
        if app.bundleIdentifier == "com.apple.finder" {
            let windows = AccessibilityService.shared.listApplicationWindows(for: app)
            
            // Only create a new window if there are no existing windows
            if windows.isEmpty {
                Logger.debug("No Finder windows found, creating new window")
                // If Finder is not active, activate it first
                if !app.isActive {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
                
                // Create a new Finder window
                let workspace = NSWorkspace.shared
                workspace.open(URL(fileURLWithPath: NSHomeDirectory()))
                return true
            }
            
            // If there are existing windows, handle like any other app
            Logger.debug("Existing Finder windows found, handling normally")
        }
        
        // Regular handling for all apps (including Finder with existing windows)
        AccessibilityService.shared.initializeWindowStates(for: app)
        
        if app.isActive {
            Logger.debug("App is active, hiding all windows")
            AccessibilityService.shared.hideAllWindows(for: app)
            return app.hide()
        } else {
            Logger.debug("App is inactive, showing and restoring windows")
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
            AccessibilityService.shared.restoreAllWindows(for: app)
            return true
        }
    }
    
    // Add method to handle context menu dismissal
    @objc private func contextMenuDidDismiss(_ notification: Notification) {
        // Remove the observer
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        
        // Reset context menu state immediately
        isContextMenuActive = false
    }
}

@MainActor
class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private let updaterController: SPUStandardUpdaterController
    
    init() {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        
        // Initialize the updater controller
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        if let button = statusItem.button {
            if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
               let image = NSImage(contentsOfFile: iconPath) {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
        }
        
        setupMenu()
    }
    
    private func setupMenu() {
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
}

// MARK: - Application Entry Point

// Add near the start of the application entry point
Logger.info("Starting Dock App Toggler...")

// Create a dedicated service for accessibility checks
@MainActor
final class AccessibilityPermissionService: @unchecked Sendable {
    static let shared = AccessibilityPermissionService()
    
    // Create a static constant for the prompt key
    private static let promptKey = "AXTrustedCheckOptionPrompt"
    
    private init() {}
    
    func checkAccessibility() -> Bool {
        // Use the hardcoded key instead of the global variable
        let options = [Self.promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

// Update the getAccessibilityStatus function to use the service
@MainActor
func getAccessibilityStatus() async -> Bool {
    return AccessibilityPermissionService.shared.checkAccessibility()
}

// Update the handleAccessibilityPermissions function
@MainActor
func handleAccessibilityPermissions() async {
    let accessibilityEnabled = await getAccessibilityStatus()
    Logger.info("Accessibility permissions status: \(accessibilityEnabled)")
    
    if !accessibilityEnabled {
        Logger.warning("Accessibility permissions not granted. Prompting user...")
        // Show a notification or alert to the user
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "DockAppToggler needs accessibility permissions to function. Please grant access in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
        }
    }
}

// Initialize app components
let app = NSApplication.shared

// Run the accessibility check on the main actor
Task { @MainActor in
    await handleAccessibilityPermissions()
}

// Store references to prevent deallocation
let appController = (
    watcher: DockWatcher(),
    statusBar: StatusBarController()
)
app.run()

// Add this new class for handling updates
@MainActor
class UpdateController: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var driver: SPUStandardUserDriver?
    private var statusItem: NSStatusItem?
    
    override init() {
        super.init()
        
        // Get the main bundle
        let bundle = Bundle.main
        Logger.info("Initializing Sparkle with bundle path: \(bundle.bundlePath)")
        
        // Initialize Sparkle components with delegates
        driver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        
        if let driver = driver {
            do {
                let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
                try updater.start()
                self.updater = updater
                
                // Log bundle identifier and appcast URL for debugging
                if let bundleId = bundle.bundleIdentifier {
                    Logger.info("Sparkle initialized with bundle identifier: \(bundleId)")
                } else {
                    Logger.warning("No bundle identifier found")
                }
                
                if let appcastURL = bundle.infoDictionary?["SUFeedURL"] as? String {
                    Logger.info("Appcast URL configured: \(appcastURL)")
                } else {
                    Logger.warning("No SUFeedURL found in Info.plist")
                }
            } catch {
                Logger.error("Failed to initialize Sparkle: \(error)")
            }
        } else {
            Logger.error("Failed to initialize Sparkle driver")
        }
    }
    
    func checkForUpdates() {
        if let updater = updater {
            Logger.info("Checking for updates...")
            updater.checkForUpdates()
        } else {
            Logger.error("Cannot check for updates - Sparkle updater not initialized")
        }
    }
    
    // MARK: - SPUStandardUserDriverDelegate
    
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }
    
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Create an immutable copy of the version string
        let updateInfo = (version: String(update.displayVersionString), userInitiated: state.userInitiated)
        
        Task { @MainActor in
            // When an update alert will be presented, place the app in the foreground
            NSApp.setActivationPolicy(.regular)
            
            if !updateInfo.userInitiated {
                // Add a badge to the app's dock icon indicating one alert occurred
                NSApp.dockTile.badgeLabel = "1"
                
                // Post a user notification
                let content = UNMutableNotificationContent()
                content.title = "A new update is available"
                content.body = "Version \(updateInfo.version) is now available"
                
                let request = UNNotificationRequest(identifier: "UpdateCheck", content: content, trigger: nil)
                
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    Logger.error("Failed to add notification: \(error)")
                }
            }
        }
    }
    
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            // Clear the dock badge indicator for the update
            NSApp.dockTile.badgeLabel = ""
            
            // Dismiss active update notifications
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["UpdateCheck"])
        }
    }
    
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            // Put app back in background when the user session for the update finished
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    // MARK: - SPUUpdaterDelegate
    
    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Task { @MainActor in
            // Request notification permissions when Sparkle schedules an update check
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound])
                Logger.info("Notification authorization granted: \(granted)")
            } catch {
                Logger.error("Failed to request notification authorization: \(error)")
            }
        }
    }
}

// Add this extension near the top of the file
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Add extension to check dark mode
extension NSAppearance {
    var isDarkMode: Bool {
        self.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// Update the NSBezierPath extension
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                // Convert quadratic curve to cubic curve
                let startPoint = path.currentPoint
                let controlPoint = points[0]
                let endPoint = points[1]
                
                // Calculate cubic control points from quadratic control point
                let cp1 = CGPoint(
                    x: startPoint.x + ((controlPoint.x - startPoint.x) * 2/3),
                    y: startPoint.y + ((controlPoint.y - startPoint.y) * 2/3)
                )
                let cp2 = CGPoint(
                    x: endPoint.x + ((controlPoint.x - endPoint.x) * 2/3),
                    y: endPoint.y + ((controlPoint.y - endPoint.y) * 2/3)
                )
                
                path.addCurve(to: endPoint, control1: cp1, control2: cp2)
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        
        return path
    }
}

// Update BubbleVisualEffectView class
class BubbleVisualEffectView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        
        // Create bubble shape with arrow
        let path = NSBezierPath()
        let bounds = self.bounds
        let radius: CGFloat = 6
        
        // Start from bottom center (arrow tip)
        let arrowTipX = bounds.midX
        let arrowTipY = Constants.UI.arrowOffset
        
        path.move(to: NSPoint(x: arrowTipX, y: arrowTipY))
        
        // Draw arrow
        path.line(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: arrowTipY + Constants.UI.arrowHeight))
        path.line(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: arrowTipY + Constants.UI.arrowHeight))
        path.line(to: NSPoint(x: arrowTipX, y: arrowTipY))
        
        // Draw main rounded rectangle
        let rect = NSRect(x: bounds.minX,
                         y: bounds.minY + Constants.UI.arrowHeight,
                         width: bounds.width,
                         height: bounds.height - Constants.UI.arrowHeight)
        
        let roundedRect = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.append(roundedRect)
        
        // Create mask layer
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        self.layer?.mask = maskLayer
        
        // Add border layer
        let borderLayer = CAShapeLayer()
        borderLayer.path = path.cgPath
        borderLayer.lineWidth = 0.5
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        
        // Remove any existing border layers
        self.layer?.sublayers?.removeAll(where: { $0.name == "borderLayer" })
        
        // Add new border layer
        borderLayer.name = "borderLayer"
        self.layer?.addSublayer(borderLayer)
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        
        // Update border color when appearance changes
        if let borderLayer = self.layer?.sublayers?.first(where: { $0.name == "borderLayer" }) as? CAShapeLayer {
            borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        }
    }
}
