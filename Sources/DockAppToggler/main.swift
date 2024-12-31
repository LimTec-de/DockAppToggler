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
    let isAppElement: Bool  // Add this property
    
    init(window: AXUIElement, name: String, isAppElement: Bool = false) {
        self.window = window
        self.name = name
        self.isAppElement = isAppElement
    }
}

/// Application-wide constants
enum Constants {
    /// UI-related constants
    enum UI {
        static let windowWidth: CGFloat = 280  // Increased from 240 to 280
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

// Define CloseButton class before WindowChooserView
private class CloseButton: NSButton {
    private let normalConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        .applying(.init(paletteColors: [.systemGray]))
    private let hoverConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        .applying(.init(paletteColors: [.systemRed]))
    
    init(frame: NSRect, tag: Int, target: AnyObject?, action: Selector) {
        super.init(frame: frame)
        
        self.tag = tag
        self.target = target
        self.action = action
        
        // Basic setup
        self.bezelStyle = .inline
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.setButtonType(.momentaryLight)
        
        // Ensure perfect circle by using square frame
        let size: CGFloat = 16  // Fixed size for perfect circle
        let x = frame.origin.x + (frame.width - size) / 2
        let y = frame.origin.y + (frame.height - size) / 2
        self.frame = NSRect(x: x, y: y, width: size, height: size)
        
        // Add circle background with theme-aware colors
        self.wantsLayer = true
        self.layer?.cornerRadius = size / 2
        updateBackgroundColor(isHovered: false)
        
        // Update initial appearance
        updateAppearance(isHovered: false)
        
        // Add tracking area
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateBackgroundColor(isHovered: Bool) {
        let isDark = self.effectiveAppearance.isDarkMode
        
        // Use more contrasting colors for both themes
        let color = isDark ?
            (isHovered ? NSColor(white: 1.0, alpha: 0.2) : NSColor(white: 1.0, alpha: 0.15)) :
            (isHovered ? NSColor(white: 0.0, alpha: 0.15) : NSColor(white: 0.0, alpha: 0.1))
        
        self.layer?.backgroundColor = color.cgColor
    }
    
    private func updateAppearance(isHovered: Bool) {
        let config = isHovered ? hoverConfig : normalConfig
        self.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        self.alphaValue = isHovered ? 1.0 : 0.8
        
        updateBackgroundColor(isHovered: isHovered)
    }
    
    override func mouseEntered(with event: NSEvent) {
        updateAppearance(isHovered: true)
    }
    
    override func mouseExited(with event: NSEvent) {
        updateAppearance(isHovered: false)
    }
}

// Update MinimizeButton class
private class MinimizeButton: NSButton {
    private var isWindowMinimized: Bool = false
    
    init(frame: NSRect, tag: Int, target: AnyObject?, action: Selector) {
        super.init(frame: frame)
        
        self.tag = tag
        self.target = target
        self.action = action
        
        // Basic setup
        self.bezelStyle = .inline
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.setButtonType(.momentaryLight)
        
        // Ensure perfect circle by using square frame
        let size: CGFloat = 16  // Fixed size for perfect circle
        let x = frame.origin.x + (frame.width - size) / 2
        let y = frame.origin.y + (frame.height - size) / 2
        self.frame = NSRect(x: x, y: y, width: size, height: size)
        
        // Add circle background
        self.wantsLayer = true
        self.layer?.cornerRadius = size / 2
        self.layer?.backgroundColor = NSColor(deviceWhite: 0.3, alpha: 0.2).cgColor
        
        // Configure the minus symbol with adjusted size
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.systemGray]))
        let minusImage = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize")?
            .withSymbolConfiguration(config)
        self.image = minusImage
        
        self.contentTintColor = .systemGray
        self.alphaValue = 0.8
        
        // Add tracking area
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
        
        // Set initial state
        updateMinimizedState(false)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateMinimizedState(_ minimized: Bool) {
        isWindowMinimized = minimized
        
        // Update symbol based on minimized state
        let symbolName = minimized ? "plus" : "minus"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [minimized ? NSColor.tertiaryLabelColor : .systemGray]))
        
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: minimized ? "Restore" : "Minimize")?
            .withSymbolConfiguration(config)
        
        updateBackgroundColor(isHovered: false)
    }
    
    override func mouseEntered(with event: NSEvent) {
        if isWindowMinimized {
            self.contentTintColor = .systemBlue
        } else {
            self.contentTintColor = .systemOrange
        }
        updateBackgroundColor(isHovered: true)
    }
    
    override func mouseExited(with event: NSEvent) {
        if isWindowMinimized {
            self.contentTintColor = NSColor.tertiaryLabelColor
        } else {
            self.contentTintColor = .systemGray
        }
        updateBackgroundColor(isHovered: false)
    }
    
    private func updateBackgroundColor(isHovered: Bool) {
        let isDark = self.effectiveAppearance.isDarkMode
        
        if isWindowMinimized {
            let color = isDark ?
                (isHovered ? NSColor(white: 1.0, alpha: 0.15) : NSColor(white: 1.0, alpha: 0.1)) :
                (isHovered ? NSColor(white: 0.0, alpha: 0.1) : NSColor(white: 0.0, alpha: 0.07))
            self.layer?.backgroundColor = color.cgColor
            self.alphaValue = 0.5
        } else {
            let color = isDark ?
                (isHovered ? NSColor(white: 1.0, alpha: 0.2) : NSColor(white: 1.0, alpha: 0.15)) :
                (isHovered ? NSColor(white: 0.0, alpha: 0.15) : NSColor(white: 0.0, alpha: 0.1))
            self.layer?.backgroundColor = color.cgColor
            self.alphaValue = isHovered ? 1.0 : 0.8
        }
    }
}

/// A custom view that displays a list of windows as buttons with hover effects
class WindowChooserView: NSView {
    private var options: [WindowInfo] = []
    private var callback: ((AXUIElement, Bool) -> Void)?
    private var buttons: [NSButton] = []
    private var hideButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private var titleField: NSTextField!
    private let targetApp: NSRunningApplication
    private var lastMaximizeClickTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.3
    internal var topmostWindow: AXUIElement?
    
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
            let closeButton = createCloseButton(for: windowInfo, at: index)
            
            addSubview(button)
            addSubview(hideButton)
            addSubview(closeButton)
            
            buttons.append(button)
            hideButtons.append(hideButton)
            closeButtons.append(closeButton)
            
            // Check initial minimize state for the window
            if let minimizeButton = hideButton as? MinimizeButton {
                var minimizedValue: AnyObject?
                if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                   let isMinimized = minimizedValue as? Bool {
                    minimizeButton.updateMinimizedState(isMinimized)
                }
            }
        }
    }
    
    private func createButton(for windowInfo: WindowInfo, at index: Int) -> NSButton {
        let button = NSButton(frame: NSRect(
            x: 44,  // Move right to make room for both minimize and close buttons
            y: frame.height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding,
            width: Constants.UI.windowWidth - Constants.UI.windowPadding * 2 - 44 - 
                  (Constants.UI.leftSideButtonWidth + Constants.UI.centerButtonWidth + Constants.UI.rightSideButtonWidth + Constants.UI.sideButtonsSpacing * 2) - 8,  // Adjust width
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
                context.duration = 0.0  // Make color change immediate
                if button.action == #selector(closeWindowButtonClicked(_:)) {
                    // Close button hover - red color
                    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .thin)
                        .applying(.init(paletteColors: [.systemRed]))
                    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                        .withSymbolConfiguration(config)
                    button.alphaValue = 1.0
                } else if button.action == #selector(hideButtonClicked(_:)) {
                    // Minimize button hover - orange color
                    button.contentTintColor = .systemOrange
                    button.alphaValue = 1.0
                } else {
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
    }
    
    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.owner as? NSButton {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.0  // Make color change immediate
                if button.action == #selector(closeWindowButtonClicked(_:)) {
                    // Reset close button color
                    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .thin)
                        .applying(.init(paletteColors: [.systemGray]))
                    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                        .withSymbolConfiguration(config)
                    button.alphaValue = 0.8
                } else if button.action == #selector(hideButtonClicked(_:)) {
                    // Reset color for both close and minimize buttons
                    button.contentTintColor = NSColor.systemGray.withAlphaComponent(0.8)
                    button.alphaValue = 0.8
                } else {
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
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        let windowInfo = options[sender.tag]
        
        if windowInfo.isAppElement {
            // Handle app element click - try to open/activate the app
            if let bundleURL = targetApp.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            }
            
            // Close the menu
            if let windowController = self.window?.windowController as? WindowChooserController {
                windowController.close()
            }
        } else {
            // Handle window click
            let window = windowInfo.window
            
            // Update topmost window
            topmostWindow = window
            
            // Call the callback
            callback?(window, false)
            
            // Add a small delay to ensure window state has updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // Refresh the menu to update all states
                if let windowController = self?.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
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
        } else {
            Logger.debug("App needs activation")
            launchApp()
        }
        
        closeWindowChooser()
    }
    
    private func handleWindowClick(_ windowInfo: WindowInfo, hideButton: NSButton) {
        // Show and raise window
        AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AccessibilityService.shared.raiseWindow(window: windowInfo.window, for: targetApp)
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
                
                // Update topmost window
                topmostWindow = window
            } else {
                // Window is visible - minimize it
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                
                // If this was the topmost window, find new topmost
                if window == topmostWindow {
                    topmostWindow = options.first { windowInfo in
                        var minimizedValue: AnyObject?
                        if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                           let isMinimized = minimizedValue as? Bool {
                            return !isMinimized
                        }
                        return false
                    }?.window
                }
            }
            
            // Add a small delay to ensure window state has updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // Refresh the entire menu to update all states
                if let windowController = self?.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
                }
            }
        }
    }
    
    deinit {
        // Remove tracking areas
        let buttonsToClean = buttons + hideButtons + closeButtons
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
        
        // Create button image with larger size
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)  // Back to original size of 11
        
        let imageName: String
        let accessibilityDescription: String
        
        if isCenter {
            let isOnSecondary = isWindowOnSecondaryDisplay(windowInfo.window)
            imageName = isOnSecondary ? "2.square.fill" : "square.fill"
            accessibilityDescription = isOnSecondary ? "Move to Primary" : "Toggle Window Size"
        } else {
            // Use filled chevron icons for left/right
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
                if button.action == #selector(hideButtonClicked(_:)) {
                    // Update minimize button state
                    var minimizedValue: AnyObject?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                       let isMinimized = minimizedValue as? Bool {
                        // Update icon
                        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                        let symbolName = isMinimized ? "plus" : "minus"
                        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isMinimized ? "Restore" : "Minimize")?
                            .withSymbolConfiguration(config)
                        button.image = image
                        
                        // Update colors
                        button.contentTintColor = isMinimized ? 
                            Constants.UI.Theme.iconSecondaryTintColor : 
                            Constants.UI.Theme.iconTintColor
                        button.alphaValue = isMinimized ? 0.5 : 1.0
                    }
                } else if button.action == #selector(maximizeWindow(_:)) {
                    // Existing maximize button logic...
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
                } else {
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
    
    // Add new method to handle close button clicks
    @objc private func closeWindowButtonClicked(_ sender: NSButton) {
        let window = options[sender.tag].window
        
        // Try to find and press the close button
        var closeButtonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           CFGetTypeID(closeButtonRef!) == AXUIElementGetTypeID() {
            let closeButton = closeButtonRef as! AXUIElement
            AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            
            // Add a small delay to ensure the window has closed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // Refresh the menu
                if let windowController = self?.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
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
            action: #selector(closeWindowButtonClicked(_:))
        )
    }
    
    // ... rest of WindowChooserView implementation ...
}

/// A custom window controller that manages the window chooser interface
class WindowChooserController: NSWindowController {
    private let app: NSRunningApplication
    private let iconCenter: CGPoint
    private var visualEffectView: NSVisualEffectView?
    private var chooserView: WindowChooserView?
    private var trackingArea: NSTrackingArea?
    private var isClosing: Bool = false
    private let callback: (AXUIElement, Bool) -> Void
    
    init(at point: CGPoint, windows: [WindowInfo], app: NSRunningApplication, callback: @escaping (AXUIElement, Bool) -> Void) {
        self.app = app
        self.iconCenter = point
        self.callback = callback
        
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
            appName: app.localizedName ?? "Unknown",
            app: app,
            callback: { [weak self] window, isHideAction in  // Add isHideAction parameter
                guard let self = self else { return }
                
                if isHideAction {
                    // Hide the selected window
                    AccessibilityService.shared.hideWindow(window: window, for: self.app)
                } else {
                    // Always show and raise the window
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    AccessibilityService.shared.raiseWindow(window: window, for: self.app)
                    self.app.activate(options: [.activateIgnoringOtherApps])
                }
                
                // Add a small delay to ensure window state has updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    // Refresh the menu to update all states
                    self?.refreshMenu()
                }
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
    
    func refreshMenu() {
        // Get fresh window list
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // If no windows left, close the menu
        if windows.isEmpty {
            self.close()
            return
        }
        
        // Store current window position
        let currentFrame = self.window?.frame ?? NSRect.zero
        
        // Create entirely new window
        let newWindow = NSWindow(
            contentRect: NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: Constants.UI.windowWidth,
                height: Constants.UI.windowHeight(for: windows.count)
            ),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        // Configure new window
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        newWindow.hasShadow = true
        newWindow.level = .popUpMenu
        newWindow.appearance = NSApp.effectiveAppearance
        
        // Create container view for shadow
        let containerView = NSView(frame: newWindow.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.15
        containerView.layer?.shadowRadius = 3.0
        containerView.layer?.shadowOffset = .zero
        
        // Create and configure the visual effect view
        let visualEffect = BubbleVisualEffectView(frame: containerView.bounds)
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        
        // Create new chooser view
        let newView = WindowChooserView(
            windows: windows,
            appName: app.localizedName ?? "Unknown",
            app: app,
            callback: callback
        )
        
        // Set up view hierarchy
        newWindow.contentView = containerView
        containerView.addSubview(visualEffect)
        visualEffect.addSubview(newView)
        
        // Update frames
        visualEffect.frame = containerView.bounds
        newView.frame = visualEffect.bounds
        
        // Replace old window with new one
        let oldWindow = self.window
        self.window = newWindow
        
        // Show new window and close old one
        newWindow.makeKeyAndOrderFront(nil)
        oldWindow?.close()
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
        
        // Clean app name by removing special characters
        let cleanAppName = app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "Application"
        
        // Check app status
        let isAppActive = app.isActive
        
        // Simpler dock indicator check
        let hasDockIndicator = {
            // Must be a regular app (shows in Dock)
            guard app.activationPolicy == .regular else { return false }
            
            // Get all windows for this app
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
            let appWindows = windowList.filter { info in
                guard let pid = info[kCGWindowOwnerPID] as? pid_t else { return false }
                return pid == app.processIdentifier
            }
            
            return isAppActive || 
                   !appWindows.isEmpty || 
                   (app.isFinishedLaunching && !app.isTerminated)
        }()
        
        let shouldShowApp = isAppActive || hasDockIndicator
        
        // If app should be shown, always include it
        if shouldShowApp {
            // Try to get windows first
            if AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
               let windowArray = windowsRef as? [AXUIElement],
               !windowArray.isEmpty {
                
                // Process regular windows
                for window in windowArray {
                    var titleValue: AnyObject?
                    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                       let title = titleValue as? String {
                        windows.append(WindowInfo(window: window, 
                                               name: title.isEmpty ? cleanAppName : title, 
                                               isAppElement: false))
                    }
                }
                
                // Sort windows alphabetically by name
                windows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            
            // If no windows were found or processed, add the app itself
            if windows.isEmpty {
                windows.append(WindowInfo(window: axApp,
                                        name: cleanAppName,
                                        isAppElement: true))
            }
        }
        
        Logger.debug("Final windows count for \(cleanAppName): \(windows.count)")
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
        Logger.debug("restoreAllWindows called for: \(app.localizedName ?? "Unknown")")  // Add this line
        let pid = app.processIdentifier
        
        Task<Void, Never> { @MainActor in
            guard let states = windowStates[pid] else {
                Logger.warning("No window states found for app with pid: \(pid)")
                return
            }
            
            Logger.info("Restoring windows for app: \(app.localizedName ?? "Unknown")")
            Logger.info("Total window states: \(states.count)")
            
            // Log details of each window state
            for (index, state) in states.enumerated() {
                Logger.debug("Window \(index): wasVisible=\(state.wasVisible), order=\(state.order), stackOrder=\(state.stackOrder)")
                
                // Check current window state
                var minimizedValue: AnyObject?
                var hiddenValue: AnyObject?
                if AXUIElementCopyAttributeValue(state.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                   AXUIElementCopyAttributeValue(state.window, kAXHiddenAttribute as CFString, &hiddenValue) == .success {
                    Logger.debug("  Current state: minimized=\(minimizedValue as? Bool ?? false), hidden=\(hiddenValue as? Bool ?? false)")
                }
            }
            
            // Special handling for single window case
            if states.count == 1, let singleState = states.first {
                Logger.info("Single window case detected")
                if singleState.wasVisible {
                    Logger.info("Attempting to raise single window")
                    AccessibilityService.shared.raiseWindow(window: singleState.window, for: app)
                } else {
                    Logger.info("Single window was not previously visible, skipping")
                }
            } else {
                Logger.info("Multiple windows case: \(states.count) windows")
                // Original logic for multiple windows
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
            }
            
            windowStates.removeValue(forKey: pid)
            Logger.info("Window restoration completed")
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
            // Consider minimized windows as "visible" since we want to restore them
            var minimizedValue: AnyObject?
            var hiddenValue: AnyObject?
            
            let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            let isHidden = AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
                          (hiddenValue as? Bool == true)
            
            // A window should be considered "visible" if it exists and isn't hidden
            // (minimized windows should be considered visible since we want to restore them)
            let isVisible = !isHidden
            
            Logger.debug("Window state check - minimized: \(isMinimized), hidden: \(isHidden), considering visible: \(isVisible)")
            
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
class DockWatcher: NSObject, NSMenuDelegate {
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
    // In DockWatcher class, add a new property
    private var contextMenuMonitor: Any?
    // In DockWatcher class, add NSMenuDelegate conformance and a new property
    private var dockMenu: NSMenu?
    // Add a new property to DockWatcher class
    private var lastClickedDockIcon: NSRunningApplication?
    // Add property to track the last right-clicked dock icon
    private var lastRightClickedDockIcon: NSRunningApplication?
    // Add a property to track if we're showing the window chooser on click
    private var showingWindowChooserOnClick: Bool = false
    // Add a new property to DockWatcher class
    private var skipNextClickProcessing: Bool = false
    
    override init() {
        super.init()  // Add super.init() call
        setupEventTap()
        setupNotifications()
        setupDockMenuTracking()  // Add this line
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
                    if let (app, _, iconCenter) = DockService.shared.findAppUnderCursor(at: location) {
                        watcher.clickedApp = app
                        watcher.lastClickedDockIcon = app
                        watcher.skipNextClickProcessing = false  // Reset the flag
                        
                        // Show window chooser immediately on click
                        Task { @MainActor in
                            let windows = AccessibilityService.shared.listApplicationWindows(for: app)
                            if !windows.isEmpty {
                                watcher.showingWindowChooserOnClick = true
                                watcher.windowChooser?.close()
                                watcher.windowChooser = nil
                                watcher.displayWindowSelector(for: app, at: iconCenter, windows: windows)
                                watcher.lastHoveredApp = app
                            }
                        }
                        
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                }
                // Let the event propagate only if we're not clicking on a dock item
                return Unmanaged.passRetained(event)
            case .leftMouseUp:
                // Process the click on mouseUp if we have a stored app
                if let app = watcher.clickedApp {
                    // Always process the dock icon click
                    if watcher.processDockIconClick(app: app) {
                        // If we're showing the window chooser, don't close it
                        if !watcher.showingWindowChooserOnClick {
                            watcher.windowChooser?.close()
                            watcher.windowChooser = nil
                        }
                        watcher.clickedApp = nil
                        // Return nil to prevent the event from propagating
                        return nil
                    }
                    // Reset the flag
                    watcher.showingWindowChooserOnClick = false
                }
                watcher.clickedApp = nil
            case .rightMouseDown:
                // Check if we're clicking on a dock item
                if let (app, _, _) = DockService.shared.findAppUnderCursor(at: location) {
                    Task { @MainActor in
                        // Store the right-clicked app
                        watcher.lastRightClickedDockIcon = app
                        // Close any existing window chooser
                        watcher.windowChooser?.close()
                        watcher.windowChooser = nil
                        watcher.lastHoveredApp = nil
                    }
                } else {
                    // Clear the last right-clicked app when clicking elsewhere
                    watcher.lastRightClickedDockIcon = nil
                }
                return Unmanaged.passRetained(event)
            case .rightMouseUp:
                Task { @MainActor in
                    // Reset context menu state after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak watcher] in
                        watcher?.isContextMenuActive = false
                    }
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
        
        // Check if the only "window" is actually the app itself - only when clicking
        if windows.count == 1 && windows[0].isAppElement && showingWindowChooserOnClick {
            if let bundleURL = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
                
                // Schedule window chooser to appear after 100ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self,
                          self.windowChooser == nil else { return }
                    
                    Task { @MainActor in
                        // Get fresh window list
                        let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: app)
                        if !updatedWindows.isEmpty && updatedWindows[0].isAppElement == false {
                            // Only show if we have actual windows now
                            self.displayWindowSelector(for: app, at: point, windows: updatedWindows)
                        }
                    }
                }
                
                // Skip further click processing
                showingWindowChooserOnClick = false
                skipNextClickProcessing = true
                clickedApp = nil
            }
            return
        }
        
        // If no windows at all, try to launch/activate the app
        if windows.isEmpty {
            if let bundleURL = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            }
            return
        }
        
        // Check if there are any visible windows
        let hasVisibleWindows = windows.contains { windowInfo in
            AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }
        
        // If there's only one window, we're handling a click (not hover),
        // and there are no visible windows, handle it directly here
        if windows.count == 1 && showingWindowChooserOnClick && !hasVisibleWindows {
            // Initialize window states before restoring
            AccessibilityService.shared.initializeWindowStates(for: app)
            app.unhide()
            AccessibilityService.shared.restoreAllWindows(for: app)
            showingWindowChooserOnClick = false
            skipNextClickProcessing = true  // Set flag to skip next click processing
            clickedApp = nil  // Clear clicked app
            return
        }
        
        // Create and show new chooser for multiple windows
        let chooser = WindowChooserController(
            at: point,
            windows: windows,
            app: app,
            callback: { window, isHideAction in
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
        chooser.window?.makeKeyAndOrderFront(self)
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
            if clickedApp != nil {
                return
            }

            // If this is a different app than the last right-clicked one,
            // clear the lastRightClickedDockIcon
            if app != lastRightClickedDockIcon {
                lastRightClickedDockIcon = nil
            }

            if app != lastHoveredApp && app != lastRightClickedDockIcon {
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
        } else {
            // Mouse is not over any dock item, clear the right-clicked state
            lastRightClickedDockIcon = nil
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
        // Skip processing if flag is set
        if skipNextClickProcessing {
            skipNextClickProcessing = false  // Reset the flag
            return true
        }

        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")
        
        // Initialize window states before checking app status
        AccessibilityService.shared.initializeWindowStates(for: app)
        
        // Get all windows
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // Check if there are any visible windows
        let hasVisibleWindows = windows.contains { windowInfo in
            AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }
        
        // Check if app is both active AND has visible windows
        if app.isActive && hasVisibleWindows {
            Logger.debug("App is active with visible windows, hiding all windows")
            AccessibilityService.shared.hideAllWindows(for: app)
            return app.hide()
        } else {
            Logger.debug("App is inactive or has no visible windows, showing and restoring windows")
            app.unhide()
            // First activate the app
            app.activate(options: [.activateIgnoringOtherApps])
            // Then restore windows
            AccessibilityService.shared.restoreAllWindows(for: app)
            return true
        }
    }
    
    // Add NSMenuDelegate methods
    func menuWillOpen(_ menu: NSMenu) {
        // Check if this is the Dock's context menu by checking its parent
        if menu.supermenu == dockMenu || menu == dockMenu {
            isContextMenuActive = true
            // Close any existing window chooser
            windowChooser?.close()
            windowChooser = nil
            lastHoveredApp = nil
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu.supermenu == dockMenu || menu == dockMenu {
            // Add a small delay to ensure menu is fully dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isContextMenuActive = false
            }
        }
    }
    
    private func setupDockMenuTracking() {
        // Get the Dock process
        if let dockApp = DockService.shared.findDockProcess() {
            // Get all menus from the Dock
            let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
            var menuBarValue: CFTypeRef?
            
            if AXUIElementCopyAttributeValue(axDock, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
               CFGetTypeID(menuBarValue!) == AXUIElementGetTypeID() {
                let menuBar = menuBarValue as! AXUIElement
                var menusValue: CFTypeRef?
                
                if AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &menusValue) == .success,
                   CFGetTypeID(menusValue!) == AXUIElementGetTypeID(),
                   let menus = menusValue as? [AXUIElement] {
                    // Get the Dock menu
                    for menu in menus {
                        var roleValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(menu, kAXRoleAttribute as CFString, &roleValue) == .success,
                           let role = roleValue as? String,
                           role == "AXMenu" {
                            var menuRef: AnyObject?
                            // Use AXMenuItemCopyAttributeValue instead
                            if AXUIElementCopyAttributeValue(menu, "AXMenu" as CFString, &menuRef) == .success,
                               let dockMenu = menuRef as? NSMenu {
                                self.dockMenu = dockMenu
                                dockMenu.delegate = self
                                break
                            }
                        }
                    }
                }
            }
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
            // Try multiple paths to find the icon
            let iconImage: NSImage?
            if let bundleIconPath = Bundle.main.path(forResource: "icon", ofType: "icns") {
                // App bundle path
                iconImage = NSImage(contentsOfFile: bundleIconPath)
            } else {
                // Development path
                let devIconPath = "Sources/DockAppToggler/Resources/icon.icns"
                iconImage = NSImage(contentsOfFile: devIconPath) ?? 
                           NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "DockAppToggler")
            }
            
            if let image = iconImage {
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
        
        // Create the main rounded rectangle first, but exclude the bottom edge
        let rect = NSRect(x: bounds.minX,
                         y: bounds.minY + Constants.UI.arrowHeight,
                         width: bounds.width,
                         height: bounds.height - Constants.UI.arrowHeight)
        
        // Create custom path for rounded rectangle with partial bottom edge
        let roundedRect = NSBezierPath()
        
        // Start from the arrow connection point on the left
        roundedRect.move(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Draw left bottom corner and left side
        roundedRect.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 270,
                            endAngle: 180,
                            clockwise: true)
        
        // Left side and top-left corner
        roundedRect.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 180,
                            endAngle: 90,
                            clockwise: true)
        
        // Top edge
        roundedRect.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        
        // Top-right corner and right side
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 90,
                            endAngle: 0,
                            clockwise: true)
        roundedRect.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        
        // Right bottom corner
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 0,
                            endAngle: 270,
                            clockwise: true)
        
        // Bottom edge to arrow
        roundedRect.line(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Create arrow path
        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        arrowPath.line(to: NSPoint(x: arrowTipX, y: arrowTipY))
        arrowPath.line(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Combine paths
        path.append(roundedRect)
        path.append(arrowPath)
        
        // Create mask layer for the entire shape
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        self.layer?.mask = maskLayer
        
        // Add border layer only for the custom rounded rectangle path
        let borderLayer = CAShapeLayer()
        borderLayer.path = roundedRect.cgPath
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
