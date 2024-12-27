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
        
        // Calculate total height needed for a given number of buttons
        static func windowHeight(for buttonCount: Int) -> CGFloat {
            return titleHeight + CGFloat(buttonCount) * (buttonHeight + 2) + verticalPadding * 2
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
        titleField.textColor = .labelColor
        titleField.font = .boldSystemFont(ofSize: 12)
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
            button.contentTintColor = .white
        } else {
            button.contentTintColor = .secondaryLabelColor
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
        
        // Create minimize image
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Minimize")?.withSymbolConfiguration(config)
        button.image = image
        button.imagePosition = .imageOnly
        
        // Set color based on window state
        button.contentTintColor = isVisible ? 
            NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0) : // Yellow minimize button color
            .tertiaryLabelColor
        
        button.bezelStyle = .inline
        button.tag = index
        button.target = self
        button.action = #selector(hideButtonClicked(_:))
        button.isBordered = false
        button.setButtonType(.momentaryLight)
        
        // Always enable the button, but use different colors to show state
        button.isEnabled = true
        
        // Always add hover effect
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
                if hideButtons.contains(button) {
                    // Existing hide button hover logic
                    // ...
                } else if button.action == #selector(moveWindowLeft(_:)) || 
                          button.action == #selector(moveWindowRight(_:)) ||
                          button.action == #selector(maximizeWindow(_:)) {
                    // Side and maximize button hover effect
                    button.contentTintColor = .labelColor
                    button.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
                } else {
                    // Window button hover logic
                    let window = options[button.tag].window
                    if window != topmostWindow {
                        button.contentTintColor = .labelColor
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
                    // Side and maximize button exit effect
                    let window = options[button.tag].window
                    let isMaximize = button.action == #selector(maximizeWindow(_:))
                    let isLeft = button.action == #selector(moveWindowLeft(_:))
                    let isInPosition = isMaximize ? 
                        isWindowMaximized(window) : 
                        isWindowInPosition(window, onLeft: isLeft)
                    button.contentTintColor = isInPosition ? .white : .tertiaryLabelColor
                    button.layer?.backgroundColor = .clear
                } else {
                    // Window button exit logic
                    let window = options[button.tag].window
                    if window != topmostWindow {
                        button.contentTintColor = .secondaryLabelColor
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
        
        // Update corresponding hide button state
        let hideButton = hideButtons[sender.tag]
        hideButton.isEnabled = true
        hideButton.contentTintColor = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)  // Yellow minimize button color
        
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
                sender.contentTintColor = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
            } else {
                // Window is visible - minimize it
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                
                // If this was the topmost window, find new topmost
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
                sender.contentTintColor = .tertiaryLabelColor
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
            accessibilityDescription = isOnSecondary ? "Maximize on Primary" : "Maximize"
        } else {
            imageName = isLeft ? "arrow.left.square.fill" : "arrow.right.square.fill"
            accessibilityDescription = isLeft ? "Move Left" : "Move Right"
        }
        
        let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?.withSymbolConfiguration(config)
        button.image = image
        button.imagePosition = .imageOnly
        
        button.bezelStyle = .inline
        button.isBordered = false
        button.tag = index
        button.target = self
        button.action = isCenter ? #selector(maximizeWindow(_:)) : (isLeft ? #selector(moveWindowLeft(_:)) : #selector(moveWindowRight(_:)))
        
        // Set initial color based on window position/state
        let isInPosition = isCenter ? isWindowMaximized(windowInfo.window) : isWindowInPosition(windowInfo.window, onLeft: isLeft)
        button.contentTintColor = isInPosition ? .white : NSColor.tertiaryLabelColor
        
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
            // On double-click, maximize on secondary display
            positionWindow(window, maximize: true, useSecondaryDisplay: true)
        } else {
            // Single click, maximize on current/primary display
            positionWindow(window, maximize: true, useSecondaryDisplay: false)
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
                refreshButtons(for: window, at: index)
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
                refreshButtons(for: window, at: index)
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
                if button.action == #selector(moveWindowLeft(_:)) {
                    button.contentTintColor = isWindowInPosition(window, onLeft: true) ? .white : NSColor.tertiaryLabelColor
                } else if button.action == #selector(moveWindowRight(_:)) {
                    button.contentTintColor = isWindowInPosition(window, onLeft: false) ? .white : NSColor.tertiaryLabelColor
                } else if button.action == #selector(maximizeWindow(_:)) {
                    // Update both color and image for maximize button
                    let isOnSecondary = isWindowOnSecondaryDisplay(window)
                    let isMaximized = isWindowMaximized(window)
                    
                    // Update image
                    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    let imageName = isOnSecondary ? "2.square.fill" : "square.fill"
                    let accessibilityDescription = isOnSecondary ? "Maximize on Primary" : "Maximize"
                    if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
                        .withSymbolConfiguration(config) {
                        button.image = image
                    }
                    
                    // Update color
                    button.contentTintColor = isMaximized ? .white : NSColor.tertiaryLabelColor
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
                            button.contentTintColor = isWindowInPosition(window, onLeft: true) ? .white : NSColor.tertiaryLabelColor
                        } else if button.action == #selector(moveWindowRight(_:)) {
                            button.contentTintColor = isWindowInPosition(window, onLeft: false) ? .white : NSColor.tertiaryLabelColor
                        } else if button.action == #selector(maximizeWindow(_:)) {
                            button.contentTintColor = isWindowMaximized(window) ? .white : NSColor.tertiaryLabelColor
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
                        button.contentTintColor = windowInfo.window == topmostWindow ? .white : .secondaryLabelColor
                    }
                }
            }
        }
    }
}

/// A custom window controller that manages the window chooser interface
class WindowChooserController: NSWindowController {
    private let windowCallback: (AXUIElement) -> Void
    private var chooserView: WindowChooserView?
    private let targetApp: NSRunningApplication
    private var trackingArea: NSTrackingArea?
    private let dismissalMargin: CGFloat = 20.0  // Pixels of margin around the window
    
    init(at point: CGPoint, windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (AXUIElement) -> Void) {
        self.windowCallback = callback
        self.targetApp = app
        
        let height = Constants.UI.windowHeight(for: windows.count)
        let width = Constants.UI.windowWidth
        
        let screen = NSScreen.main ?? NSScreen.screens[0]
        
        // Calculate position to be just above the Dock
        let dockHeight: CGFloat = 70 // Approximate Dock height
        let tooltipOffset: CGFloat = -4 // Negative offset to overlap the Dock slightly
        
        // Keep x position aligned with the Dock icon click
        let adjustedX = max(Constants.UI.windowPadding, 
                           min(point.x - width/2, 
                               screen.frame.width - width - Constants.UI.windowPadding))
        
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
        window.hasShadow = false
        window.level = .screenSaver
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
    
    func getWindowInfo(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        var windows: [WindowInfo] = []
        
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            return []
        }
        
        for window in windowArray {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                // Skip the Finder desktop window
                if !isFinderDesktop(window, app: app) {
                    windows.append(WindowInfo(window: window, name: title))
                }
            }
        }
        
        return windows
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
        return WindowInfo(window: window, name: windowName)
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
    
    func isWindowVisible(_ window: AXUIElement) -> Bool {
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
        let axApp = AXUIElementCreateApplication(pid)
        
        // Get current window stacking order
        let stackOrder = getWindowStackOrder(for: app)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            Logger.error("Failed to get windows for app: \(app.localizedName ?? "Unknown")")
            return
        }
        
        // If there's only one window and it's minimized, don't store any state
        if windows.count == 1 {
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(windows[0], kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                Logger.debug("Single minimized window detected - skipping state storage")
                return
            }
        }
        
        var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
        var visibleCount = 0
        
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        
        // Process windows and store their states
        for (index, window) in windows.enumerated() {
            let wasVisible = isWindowVisible(window)
            if wasVisible {
                visibleCount += 1
            }
            
            // Get window ID for stack order
            var windowIDRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDRef)
            let windowStackOrder: Int
            if result == .success,
               let numRef = windowIDRef as? NSNumber {
                // Invert the stack order so higher numbers are in front
                windowStackOrder = Int.max - (stackOrder[CGWindowID(numRef.uint32Value)] ?? 0)
            } else {
                windowStackOrder = 0
            }
            
            states.append((window: window,
                          wasVisible: wasVisible,
                          order: index,
                          stackOrder: windowStackOrder))
            
            if wasVisible {
                AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, true as CFTypeRef)
            }
        }
        
        NSAnimationContext.endGrouping()
        
        // Store states sorted by stack order (back to front)
        windowStates[pid] = states.sorted { $0.stackOrder < $1.stackOrder }
        Logger.debug("Stored states for \(visibleCount) visible windows of \(app.localizedName ?? "Unknown")")
    }
    
    func restoreAllWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        // Get current windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        
        // If there's only one window, use simple restore
        if windows.count == 1 {
            let window = windows[0]
            // Unminimize if needed
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            // Unhide if needed
            var hiddenValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success,
               let isHidden = hiddenValue as? Bool,
               isHidden {
                AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, false as CFTypeRef)
            }
            // Raise the window
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Logger.debug("Restored single window for \(app.localizedName ?? "Unknown")")
            return
        }
        
        // For multiple windows, use the full restore procedure
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        
        // First pass: Show all windows from back to front (normal stack order)
        for state in windowStates[pid] ?? [] where state.wasVisible {
            AXUIElementSetAttributeValue(state.window, kAXHiddenAttribute as CFString, false as CFTypeRef)
            AXUIElementSetAttributeValue(state.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        
        usleep(20000) // 20ms delay
        
        // Second pass: Raise windows from back to front to maintain z-order
        for state in (windowStates[pid] ?? []).reversed() where state.wasVisible {
            // Force window refresh
            var position = CGPoint.zero
            var valueRef: AnyObject?
            
            if AXUIElementCopyAttributeValue(state.window, kAXPositionAttribute as CFString, &valueRef) == .success,
               let cfValue = valueRef,
               CFGetTypeID(cfValue) == AXValueGetTypeID() {
                // Since we already checked the CFTypeID, we can safely force cast
                let axValue = cfValue as! AXValue
                AXValueGetValue(axValue, .cgPoint, &position)
                
                // Raise the window
                AXUIElementPerformAction(state.window, kAXRaiseAction as CFString)
                usleep(5000) // Small delay after raising
                
                // Force refresh by moving slightly
                var newPos = CGPoint(x: position.x + 1, y: position.y)
                if let posValue = AXValueCreate(.cgPoint, &newPos) {
                    AXUIElementSetAttributeValue(state.window, kAXPositionAttribute as CFString, posValue)
                    usleep(5000)
                    
                    if let originalPosValue = AXValueCreate(.cgPoint, &position) {
                        AXUIElementSetAttributeValue(state.window, kAXPositionAttribute as CFString, originalPosValue)
                    }
                }
            }
        }
        
        NSAnimationContext.endGrouping()
        
        windowStates.removeValue(forKey: pid)
        Logger.debug("Restored \(windowStates[pid]?.filter { $0.wasVisible }.count ?? 0) windows for \(app.localizedName ?? "Unknown")")
    }
    
    // Fix the clearWindowStates method
    nonisolated func clearWindowStates(for app: NSRunningApplication) {
        // Use @unchecked Sendable to bypass the Sendable check
        Task<Void, Never> { @MainActor [self] in 
            self.windowStates.removeValue(forKey: app.processIdentifier)
        }
    }
    
    // Add a new method to get window stacking order
    private func getWindowStackOrder(for app: NSRunningApplication) -> [CGWindowID: Int] {
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
        let stackOrder = getWindowStackOrder(for: app)
        var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
        
        // Initialize states for all windows
        for (index, window) in windows.enumerated() {
            let isVisible = isWindowVisible(window)
            
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
        // Only check for Finder windows
        guard app.bundleIdentifier == "com.apple.finder" else { return false }
        
        // Check window title
        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String {
            return title == "Desktop"
        }
        return false
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
        
        // Check if app has any non-minimized windows before returning
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        
        // Check if there are any non-minimized windows
        let hasVisibleWindows = windows.contains { window in
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool {
                return !isMinimized
            }
            return false
        }
        
        if !hasVisibleWindows {
            Logger.debug("No visible windows for \(app.localizedName ?? "Unknown"), ignoring click")
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
    
    init() {
        setupEventTap()
        setupNotifications()
        Logger.info("DockWatcher initialized")
    }
    
    nonisolated private func cleanup() {
        // Since we're nonisolated, we need to use DispatchQueue.main
        DispatchQueue.main.async { [windowChooser, menuShowTask] in
            // Cancel any pending tasks
            menuShowTask?.cancel()
            
            // Clean up window chooser
            windowChooser?.close()
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
        
        // Add rightMouseDown to event mask
        let eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue | 
                                   1 << CGEventType.leftMouseDown.rawValue |
                                   1 << CGEventType.leftMouseUp.rawValue |
                                   1 << CGEventType.rightMouseDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refconUnwrapped = refcon else {
                return Unmanaged.passRetained(event)
            }
            
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refconUnwrapped).takeUnretainedValue()
            let location = event.location
            
            switch type {
            case .mouseMoved:
                Task { @MainActor in
                    watcher.handleMouseMove(at: location)
                }
            case .leftMouseDown:
                // Debounce clicks
                let currentTime = ProcessInfo.processInfo.systemUptime
                if currentTime - watcher.lastClickTime >= watcher.clickDebounceInterval {
                    watcher.lastClickTime = currentTime
                    
                    // Store the app being clicked for mouseUp handling
                    if let (app, _) = DockService.shared.getClickedDockItem(at: location) {
                        watcher.clickedApp = app
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                }
            case .leftMouseUp:
                // Process the click on mouseUp if we have a stored app
                if let app = watcher.clickedApp {
                    if watcher.handleDockClick(app: app) {
                        watcher.clickedApp = nil
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                }
                watcher.clickedApp = nil
            case .rightMouseDown:
                // Immediately close menu on right click
                Task { @MainActor in
                    watcher.windowChooser?.close()
                    watcher.windowChooser = nil
                    watcher.lastHoveredApp = nil
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
    
    private func showWindowChooser(for app: NSRunningApplication, at point: CGPoint, windows: [WindowInfo]) {
        // Close any existing window chooser immediately
        if let existingChooser = windowChooser {
            existingChooser.close()
            windowChooser = nil
        }
        
        // Create and show new chooser immediately
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
        
        self.windowChooser = chooser
        chooser.window?.makeKeyAndOrderFront(nil)
    }
    
    private func handleMouseMove(at point: CGPoint) {
        // Cancel any pending task immediately
        menuShowTask?.cancel()
        menuShowTask = nil
        
        // Check if mouse is over a dock item
        if let (app, _) = DockService.shared.getClickedDockItem(at: point) {
            // Don't show menu if we're in the middle of a click
            if clickedApp == nil && app != lastHoveredApp {
                let task = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    
                    // Get windows info immediately
                    let windows = AccessibilityService.shared.getWindowInfo(for: app)
                    
                    if !windows.isEmpty {
                        self.showWindowChooser(for: app, at: point, windows: windows)
                        self.lastHoveredApp = app
                    }
                }
                
                menuShowTask = task
                // Execute almost immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + menuShowDelay, execute: task)
            }
            return
        }
        
        // Mouse is not over a dock item, check if it's over the window chooser
        guard let chooser = windowChooser,
              let window = chooser.window else {
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
                guard let self = self else { return }
                let currentLocation = NSEvent.mouseLocation
                if !expandedFrame.contains(currentLocation) && 
                   DockService.shared.getClickedDockItem(at: currentLocation) == nil {
                    self.windowChooser?.close()
                    self.windowChooser = nil
                    self.lastHoveredApp = nil
                }
            }
            
            menuShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + menuShowDelay, execute: task)
        }
    }
    
    private func handleDockClick(app: NSRunningApplication) -> Bool {
        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")
        
        // Close any existing menu
        windowChooser?.close()
        windowChooser = nil
        lastHoveredApp = nil
        
        // Special handling for Finder
        if app.bundleIdentifier == "com.apple.finder" {
            let windows = AccessibilityService.shared.getWindowInfo(for: app)
            
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
                let updater = try SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
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
