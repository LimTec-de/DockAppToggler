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
import ServiceManagement

// MARK: - Type Aliases and Constants
struct Constants {
    struct UI {
        // Window dimensions
        static let windowWidth: CGFloat = 280
        static let windowHeight: CGFloat = 40
        static let windowPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 8
        
        // Button dimensions
        static let buttonHeight: CGFloat = 32
        static let buttonSpacing: CGFloat = buttonHeight + 2
        
        // Title dimensions
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
        static let minimizeButtonRightMargin: CGFloat = 8  // Add this new constant
        
        // Add constants for centered window size
        static let centeredWindowWidth: CGFloat = 1024
        static let centeredWindowHeight: CGFloat = 768
        
        // Animation duration
        static let animationDuration: TimeInterval = 0.15
        
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
                appearance.isDarkMode ? .white : NSColor(white: 0.2, alpha: 1.0)
            }
            
            static let iconSecondaryTintColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(calibratedWhite: 0.6, alpha: 1.0) : 
                    NSColor(calibratedWhite: 0.6, alpha: 1.0)
            }
            
            static let hoverBackgroundColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(white: 1.0, alpha: 0.05) :
                    NSColor(white: 0.0, alpha: 0.001)
            }
            
            static let minimizedTextColor = NSColor(name: nil) { appearance in
                appearance.isDarkMode ? 
                    NSColor(calibratedWhite: 0.6, alpha: 0.4) : 
                    NSColor(calibratedWhite: 0.6, alpha: 0.4)
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
        static let frameKey = kAXPositionAttribute as CFString
        static let sizeKey = kAXSizeAttribute as CFString
        static let focusedKey = kAXFocusedAttribute as CFString
        static let closeKey = "AXCloseAction" as CFString  // Add this line
        static let closeButtonAttribute = kAXCloseButtonAttribute as CFString
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

// MARK: - Models

/// Information about a window, including its accessibility element and metadata
struct WindowInfo {
    let window: AXUIElement
    let name: String
    let isAppElement: Bool
    var cgWindowID: CGWindowID?
    var position: CGPoint?
    var size: CGSize?
    var bounds: CGRect?
    
    init(window: AXUIElement, 
         name: String, 
         isAppElement: Bool = false, 
         cgWindowID: CGWindowID? = nil,
         position: CGPoint? = nil,
         size: CGSize? = nil,
         bounds: CGRect? = nil) {
        self.window = window
        self.name = name
        self.isAppElement = isAppElement
        self.cgWindowID = cgWindowID
        self.position = position
        self.size = size
        self.bounds = bounds
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
        
        // Set initial background color
        let isDark = self.effectiveAppearance.isDarkMode
        let initialColor = isDark ?
            Constants.UI.Theme.iconTintColor.withAlphaComponent(0.2) :
            Constants.UI.Theme.iconSecondaryTintColor.withAlphaComponent(0.2)
        self.layer?.backgroundColor = initialColor.cgColor
        
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
        
        // Use more opaque background colors
        let color = isDark ?
            (isHovered ? NSColor(white: 0.3, alpha: 0.5) : NSColor(white: 0.3, alpha: 0.35)) :
            (isHovered ? NSColor(white: 0.85, alpha: 0.5) : NSColor(white: 0.85, alpha: 0.35))
        
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
    private var isHovered: Bool = false
    
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
        
        // Set initial background color
        let isDark = self.effectiveAppearance.isDarkMode
        let initialColor = isDark ?
            Constants.UI.Theme.iconTintColor.withAlphaComponent(0.2) :
            Constants.UI.Theme.iconSecondaryTintColor.withAlphaComponent(0.2)
        self.layer?.backgroundColor = initialColor.cgColor
        
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
        
        // Update colors based on current hover state
        if isHovered {
            self.contentTintColor = minimized ? .systemBlue : .systemOrange
        } else {
            self.contentTintColor = minimized ? NSColor.tertiaryLabelColor : .systemGray
        }
        
        updateBackgroundColor()
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if isWindowMinimized {
            self.contentTintColor = .systemBlue
        } else {
            self.contentTintColor = .systemOrange
        }
        updateBackgroundColor()
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if isWindowMinimized {
            self.contentTintColor = NSColor.tertiaryLabelColor
        } else {
            self.contentTintColor = .systemGray
        }
        updateBackgroundColor()
    }
    
    private func updateBackgroundColor() {
        let isDark = self.effectiveAppearance.isDarkMode
        
        if isWindowMinimized {
            let color = isDark ?
                (isHovered ? NSColor(white: 0.3, alpha: 0.3) : NSColor(white: 0.3, alpha: 0.2)) :
                (isHovered ? NSColor(white: 0.85, alpha: 0.3) : NSColor(white: 0.85, alpha: 0.2))
            self.layer?.backgroundColor = color.cgColor
            self.alphaValue = 0.5
        } else {
            // Use more opaque background colors
            let color = isDark ?
                (isHovered ? NSColor(white: 0.3, alpha: 0.5) : NSColor(white: 0.3, alpha: 0.35)) :
                (isHovered ? NSColor(white: 0.85, alpha: 0.5) : NSColor(white: 0.85, alpha: 0.35))
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
            // Skip for app elements and CGWindow entries
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
        
        // Check if window is minimized
        var minimizedValue: AnyObject?
        let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                          (minimizedValue as? Bool == true)
        
        // Set initial color based on window state
        if isMinimized {
            button.contentTintColor = Constants.UI.Theme.minimizedTextColor
        } else if options[tag].window == topmostWindow {
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
                } /* else if event.trackingArea?.userInfo?["isControlButton"] as? Bool == true {
                    // Remove control button highlight
                    button.layer?.backgroundColor = .clear
                }*/
                
                // Always restore original button state
                if options[button.tag].window != topmostWindow {
                    button.contentTintColor = Constants.UI.Theme.secondaryTextColor
                    button.alphaValue = 0.8
                }
            }
        }
    }
    
    @objc private func buttonClicked(_ sender: NSButton) {
        Logger.debug("Button clicked - tag: \(sender.tag)")
        let windowInfo = options[sender.tag]
        Logger.debug("Selected window info - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
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
                
                // Schedule window chooser to appear after app launch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Task { @MainActor in
                        // Get fresh window list
                        let updatedWindows = AccessibilityService.shared.listApplicationWindows(for: self.targetApp)
                        if !updatedWindows.isEmpty && !updatedWindows[0].isAppElement {
                            // Only show if we have actual windows now
                            self.callback?(updatedWindows[0].window, false)
                        }
                    }
                }
            }
            
            // Close the menu
            if let windowController = self.window?.windowController as? WindowChooserController {
                windowController.close()
            }
        } else {
            // Handle window click with new approach
            Logger.debug("Window selection details:")
            Logger.debug("  - Button tag: \(sender.tag)")
            Logger.debug("  - Window name: \(windowInfo.name)")
            Logger.debug("  - Window ID: \(windowInfo.cgWindowID ?? 0)")
            
            // Update topmost window
            topmostWindow = windowInfo.window
            
            // First unminimize if needed
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                
                // Add a small delay to allow unminimization
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Pass the clicked window info
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: self.targetApp)
                }
            } else {
                // Pass the clicked window info
                AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: targetApp)
            }
            
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
        
        // Check current minimized state
        var minimizedValue: AnyObject?
        let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                          (minimizedValue as? Bool == true)
        
        if isMinimized {
            // Unminimize and raise the window
            AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: targetApp)
        } else {
            // Minimize the window
            AccessibilityService.shared.minimizeWindow(windowInfo: windowInfo, for: targetApp)
        }
        
        // Add a small delay to ensure window state has updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Refresh the menu to update all states
            if let windowController = self?.window?.windowController as? WindowChooserController {
                windowController.refreshMenu()
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
                self?.refreshButtons(for: window, at: sender.tag)
                // Also refresh the entire menu to update all states
                if let windowController = self?.window?.windowController as? WindowChooserController {
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
    @objc private func closeWindowButtonClicked(_ sender: NSButton) {
        let windowInfo = options[sender.tag]
        
        if windowInfo.isAppElement {
            // For app elements, terminate the app
            targetApp.terminate()
            
            // Close the window chooser
            if let windowController = self.window?.windowController as? WindowChooserController {
                windowController.close()
            }
        } else if windowInfo.cgWindowID != nil {
            // For CGWindow entries, use CGWindow-based closing
            AccessibilityService.shared.closeWindow(windowInfo: windowInfo, for: targetApp)
            
            // Add a small delay to ensure window state has updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // Refresh the menu to update all states
                if let windowController = self?.window?.windowController as? WindowChooserController {
                    windowController.refreshMenu()
                }
            }
        } else {
            // For regular AX windows, use the close button
            let window = windowInfo.window
            
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
    
    
}

/// A custom window controller that manages the window chooser interface
class WindowChooserController: NSWindowController {
    // Change chooserView access level to internal (default)
    var chooserView: WindowChooserView?
    
    // Keep other properties private
    private let app: NSRunningApplication
    private let iconCenter: CGPoint
    private var visualEffectView: NSVisualEffectView?
    private var trackingArea: NSTrackingArea?
    private var isClosing: Bool = false
    private let callback: (AXUIElement, Bool) -> Void

    // Alternative: Add a public method to get the topmost window
    var topmostWindow: AXUIElement? {
        return chooserView?.topmostWindow
    }
    
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
            callback: { [weak self] window, isHideAction in
                guard let self = self else { return }
                
                // Get the window info from our windows list to ensure we have the correct ID
                if let windowInfo = windows.first(where: { $0.window == window }),
                   let windowID = windowInfo.cgWindowID {
                    // Store the CGWindowID in the AXUIElement
                    AXUIElementSetAttributeValue(window, Constants.Accessibility.windowIDKey, windowID as CFTypeRef)
                    Logger.debug("Callback: Set window ID \(windowID) on AXUIElement")
                }
                
                if isHideAction {
                    // Hide the selected window
                    AccessibilityService.shared.hideWindow(window: window, for: self.app)
                } else {
                    // Always show and raise the window
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    var titleValue: AnyObject?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    let windowName = (titleValue as? String) ?? ""
                    let windowInfo = WindowInfo(window: window, name: windowName)
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: self.app)
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
    private var hasShownPermissionDialog = false
    private var isCheckingPermissions = false
    private var permissionCheckTimer: Timer?
    
    // Add static constant for the prompt key
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
    
    // Modify the window state struct to include order
    private var windowStates: [pid_t: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)]] = [:]
    
    private init() {}
    
    func requestAccessibilityPermissions() -> Bool {
        // First check if we already have permissions
        if AXIsProcessTrusted() {
            return true
        }
        
        // If not, and we haven't shown the dialog yet, request permissions
        if !hasShownPermissionDialog {
            hasShownPermissionDialog = true
            
            // Request permissions with prompt using static string
            let options = [Self.trustedCheckOptionPrompt: true] as CFDictionary
            let result = AXIsProcessTrustedWithOptions(options)
            
            // Start checking for permission changes if we don't have them yet
            if !result && !isCheckingPermissions {
                isCheckingPermissions = true
                startPermissionCheck()
            }
            
            return result
        }
        
        return false
    }
    
    private func startPermissionCheck() {
        // Invalidate existing timer if any
        permissionCheckTimer?.invalidate()
        
        // Create new timer on the main thread
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if AXIsProcessTrusted() {
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.isCheckingPermissions = false
                    await self.offerRestart()
                }
            }
        }
    }
    
    private func offerRestart() async {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Granted"
        alert.informativeText = "DockAppToggler needs to restart to function properly. Would you like to restart now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Get the path to the current executable
            if let executablePath = Bundle.main.executablePath {
                // Launch a new instance of the app
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                try? process.run()
                
                // Terminate the current instance
                NSApp.terminate(nil)
            }
        }
    }
    
    func listApplicationWindows(for app: NSRunningApplication) -> [WindowInfo] {
        var windows: [WindowInfo] = []
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        // Clean app name by removing special characters
        let cleanAppName = app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "Application"
        
        // First get all windows using CGWindow API
        let cgWindowListOptions = CGWindowListOption([.optionAll])
        let windowList = CGWindowListCopyWindowInfo(cgWindowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Store CGWindow information for debugging and matching
        var cgWindows: [(id: CGWindowID, name: String?, bounds: CGRect)] = []
        
            
        // Create a set of window IDs belonging to this app
        let cgWindowIDs = Set(windowList.compactMap { window -> CGWindowID? in
            // Check multiple identifiers to ensure we catch all windows
            let ownerPIDMatches = (window[kCGWindowOwnerPID as String] as? pid_t) == pid
            let ownerNameMatches = (window[kCGWindowOwnerName as String] as? String) == app.localizedName
            let bundleIDMatches = window["kCGWindowOwnerBundleID" as String] as? String == app.bundleIdentifier
            
            // Get window properties
            let windowName = window[kCGWindowName as String] as? String
            let windowLayer = window[kCGWindowLayer as String] as? Int32
            let windowAlpha = window[kCGWindowAlpha as String] as? Float
            let windowSharingState = window[kCGWindowSharingState as String] as? Int32
            
            // Check if the app name starts with any of the allowed prefixes
            let allowedPrefixes = ["NoMachine", "Parallels"]
            let appName = app.localizedName ?? ""
            let allowNonZeroSharingState = allowedPrefixes.contains { appName.starts(with: $0) }
            
            // Filter conditions for regular windows:
            // 1. Must belong to the app
            // 2. Must have a valid window ID and non-empty name
            // 3. Must be on the normal window layer (0)
            // 4. Must have normal alpha (1.0)
            // 5. Must have normal sharing state (0) unless it's an allowed app
            guard (ownerPIDMatches || ownerNameMatches || bundleIDMatches),
                let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                let name = windowName,
                !name.isEmpty,
                windowLayer == 0,  // Normal window layer
                windowAlpha == nil || windowAlpha! > 0.9,  // Normal opacity
                allowNonZeroSharingState || windowSharingState == 0  // Modified sharing state check
            else {
                return nil
            }
            
            // Store window info for debugging
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let rect = CGRect(x: bounds["X"] ?? 0,
                                y: bounds["Y"] ?? 0,
                                width: bounds["Width"] ?? 0,
                                height: bounds["Height"] ?? 0)
                
                // Additional size check to filter out tiny windows (likely toolbars/panels)
                guard rect.width >= 200 && rect.height >= 100 else {
                    Logger.debug("Skipping small window '\(name)' (\(rect.width) x \(rect.height))")
                    return nil
                }
                
                Logger.debug("Adding window '\(name)' (\(rect.width) x \(rect.height))")
                cgWindows.append((
                    id: windowID,
                    name: name,
                    bounds: rect
                ))
            }
            
            return windowID
        })
        
        Logger.debug("Found \(cgWindowIDs.count) CGWindows for \(cleanAppName):")
        for window in cgWindows {
            Logger.debug("  - ID: \(window.id), Name: \(window.name ?? "unnamed"), Bounds: \(window.bounds)")
        }
        
        
        // Get windows using Accessibility API
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
           let windowArray = windowsRef as? [AXUIElement] {
            
            Logger.debug("Found \(windowArray.count) AX windows for \(cleanAppName)")
            
            for window in windowArray {
                var titleValue: AnyObject?
                var windowIDValue: AnyObject?
                var subroleValue: AnyObject?
                var roleValue: AnyObject?
                
                // Get all window attributes
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDValue)
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
                AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
                
                let title = (titleValue as? String) ?? cleanAppName
                let windowID = (windowIDValue as? NSNumber)?.uint32Value
                let subrole = subroleValue as? String
                let role = roleValue as? String
                
                // Skip only definitely invalid windows
                if role == "AXDesktop" && app.bundleIdentifier == "com.apple.finder" {
                    Logger.debug("Skipping Finder desktop window")
                    continue
                }
                
                var hiddenValue: AnyObject?
                let isHidden = AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
                              (hiddenValue as? Bool == true)
                
                var minimizedValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                (minimizedValue as? Bool == true)
                
                // More permissive window inclusion logic
                let isValidWindow = (cgWindowIDs.contains(windowID ?? 0) || // Either exists in CGWindow list
                                    isMinimized || // Or is minimized
                                    role == "AXWindow" || // Or is a standard window
                                    role == "AXDialog" || // Or is a dialog
                                    subrole == "AXStandardWindow") // Or has standard window subrole
                
                

                if !isHidden && isValidWindow {
                    // Get window position and size
                    var positionValue: CFTypeRef?
                    var sizeValue: CFTypeRef?
                    var position: CGPoint?
                    var size: CGSize?
                    
                    // Safely get position
                    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                       let posRef = positionValue {
                        // Check if it's an AXValue and has the right type
                        if CFGetTypeID(posRef) == AXValueGetTypeID() {
                            var point = CGPoint.zero
                            if AXValueGetValue(posRef as! AXValue, .cgPoint, &point) {
                                position = point
                            }
                        }
                    }
                    
                    // Safely get size
                    if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                       let sizeRef = sizeValue {
                        // Check if it's an AXValue and has the right type
                        if CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                            var windowSize = CGSize.zero
                            if AXValueGetValue(sizeRef as! AXValue, .cgSize, &windowSize) {
                                size = windowSize
                            }
                        }
                    }
                    
                    Logger.debug("Adding window: '\(title)' ID: \(windowID ?? 0) role: \(role ?? "none") subrole: \(subrole ?? "none") minimized: \(isMinimized) position: \(position?.debugDescription ?? "unknown") size: \(size?.debugDescription ?? "unknown")")
                    
                    // Create window info with all available data
                    windows.append(WindowInfo(
                        window: window,
                        name: title.isEmpty ? cleanAppName : title,
                        isAppElement: false,
                        cgWindowID: windowID,
                        position: position,
                        size: size,
                        bounds: getWindowBounds(window)
                    ))
                } else {
                    Logger.debug("Skipping window: '\(title)' - hidden: \(isHidden), valid: \(isValidWindow), role: \(role ?? "none"), subrole: \(subrole ?? "none")")
                }
            }
        }
        
        // If we found CGWindows but no AX windows, try to create windows from CGWindow info
        if windows.isEmpty && !cgWindows.isEmpty {
            Logger.debug("No AX windows found, creating from \(cgWindows.count) CGWindows")
            for cgWindow in cgWindows {
                // Create a new AXUIElement for each window
                let axWindow = AXUIElementCreateApplication(app.processIdentifier)
                
                // Store the CGWindowID in the AXUIElement immediately
                let windowID = cgWindow.id  // This is already a CGWindowID (UInt32)
                let numValue = windowID as CFNumber
                Logger.debug("Setting window ID \(windowID) on AXUIElement")
                
                // Set both the window ID and title
                AXUIElementSetAttributeValue(axWindow, Constants.Accessibility.windowIDKey, numValue)
                if let title = cgWindow.name {
                    AXUIElementSetAttributeValue(axWindow, kAXTitleAttribute as CFString, title as CFTypeRef)
                }
                
                windows.append(WindowInfo(
                    window: axWindow,
                    name: cgWindow.name ?? cleanAppName,
                    isAppElement: false,
                    cgWindowID: windowID,
                    position: CGPoint(x: cgWindow.bounds.minX, y: cgWindow.bounds.minY),
                    size: CGSize(width: cgWindow.bounds.width, height: cgWindow.bounds.height),
                    bounds: cgWindow.bounds
                ))
            }
        }
        
        // Sort windows alphabetically by name
        windows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        // If no windows were found, add the app itself
        if windows.isEmpty {
            windows.append(WindowInfo(window: axApp,
                                    name: cleanAppName,
                                    isAppElement: true))
        }
        
        Logger.debug("Found \(windows.count) total windows for \(cleanAppName)")
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
    
    func raiseWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== RAISING WINDOW ===")
        Logger.debug("Raising window - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        // Get the window's owner PID
        var pid: pid_t = 0
        AXUIElementGetPid(windowInfo.window, &pid)
        
        // First try using CGWindow APIs if we have a window ID
        if let windowID = windowInfo.cgWindowID {
            Logger.debug("Using CGWindow APIs with ID: \(windowID)")
            raiseCGWindow(windowID: windowID, ownerPID: pid)
        } else {
            Logger.debug("No CGWindowID available, using AX APIs")
            // Unminimize first if needed
            AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            
            // Then raise the window
            AXUIElementPerformAction(windowInfo.window, kAXRaiseAction as CFString)
        }
        
        // Activate the app
        app.activate(options: [.activateIgnoringOtherApps])
        
        Logger.debug("Completed raising window")
        Logger.debug("=== RAISING COMPLETE ===")
        
        // Important: Signal completion
        Task { @MainActor in
            NotificationCenter.default.post(name: NSNotification.Name("WindowRaiseComplete"), object: nil)
        }
    }

    // Move raiseWindowWithCGWindow inside AccessibilityService as a private method
    private func raiseCGWindow(windowID: CGWindowID, ownerPID: pid_t) {
        // Get current window list
        let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Find our window
        guard let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) else {
            return
        }
        
        // Get window owner PID
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            return
        }
        
        // Try multiple methods to raise the window
        
        // 1. Activate the app
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            app.activate(options: [.activateIgnoringOtherApps])
            usleep(5000)
        }
        
        // 2. Try to reorder window list
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .optionIncludingWindow)
        let _ = CGWindowListCopyWindowInfo(options, windowID)
        
        // 3. Try to bring window to front using window list manipulation
        let windowArray = [windowID] as CFArray
        let _ = CGWindowListCreateDescriptionFromArray(windowArray)
        
        Logger.debug("Attempted to raise window \(windowID) using multiple methods")
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
        
        // A window is considered visible only if it's neither hidden nor minimized
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
        Logger.debug("restoreAllWindows called for: \(app.localizedName ?? "Unknown")")
        let pid = app.processIdentifier
        
        Task<Void, Never> { @MainActor in
            // Get current windows if no states are stored
            if windowStates[pid] == nil {
                let axApp = AXUIElementCreateApplication(pid)
                var windowsRef: CFTypeRef?
                
                if AXUIElementCopyAttributeValue(axApp, Constants.Accessibility.windowsKey, &windowsRef) == .success,
                   let windows = windowsRef as? [AXUIElement] {
                    var states: [(window: AXUIElement, wasVisible: Bool, order: Int, stackOrder: Int)] = []
                    for (index, window) in windows.enumerated() {
                        // Only include non-minimized windows
                        var minimizedValue: AnyObject?
                        let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                        (minimizedValue as? Bool == true)
                        
                        if !isMinimized {
                            states.append((window: window,
                                         wasVisible: true,
                                         order: index,
                                         stackOrder: index))
                        }
                    }
                    windowStates[pid] = states
                }
            }
            
            guard let states = windowStates[pid] else {
                Logger.warning("No window states found for app with pid: \(pid)")
                return
            }
            
            Logger.info("Restoring windows for app: \(app.localizedName ?? "Unknown")")
            Logger.info("Total window states: \(states.count)")
            
            // First pass: unhide all windows (they're already non-minimized)
            for state in states {
                AXUIElementSetAttributeValue(state.window, kAXHiddenAttribute as CFString, false as CFTypeRef)
                try? await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
            }
            
            // Give windows time to restore
            try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
            
            // Second pass: only raise the last window
            if let lastState = states.last {
                let windowInfo = WindowInfo(window: lastState.window, name: "")  // Name not needed for raising
                raiseWindow(windowInfo: windowInfo, for: app)
            }
            
            // Final activation of the app
            app.activate(options: [.activateIgnoringOtherApps])
            
            // Clear the stored states
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
        
        for (index, window) in windows.enumerated() {
            // Check if window is minimized
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                             (minimizedValue as? Bool == true)
            
            // Only store non-minimized windows
            if !isMinimized {
                // Get window ID for stack order
                var windowIDValue: AnyObject?
                if AXUIElementCopyAttributeValue(window, Constants.Accessibility.windowIDKey, &windowIDValue) == .success,
                   let windowID = (windowIDValue as? NSNumber)?.uint32Value {
                    states.append((
                        window: window,
                        wasVisible: true,
                        order: index,
                        stackOrder: stackOrder[windowID] ?? index
                    ))
                }
            }
            
            Logger.debug("Window \(index) initial state - minimized: \(isMinimized), hidden: \(checkWindowHidden(window)), visible: \(checkWindowVisibility(window))")
        }
        
        windowStates[pid] = states
    }
    
    // Helper method to check hidden state
    private func checkWindowHidden(_ window: AXUIElement) -> Bool {
        var hiddenValue: AnyObject?
        return AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
               (hiddenValue as? Bool == true)
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

    func minimizeWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== MINIMIZING WINDOW ===")
        Logger.debug("Minimizing window - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        if let cgWindowID = windowInfo.cgWindowID {
            // Use CGWindow APIs for minimize
            minimizeWindowWithCGWindow(windowID: cgWindowID)
        } else {
            // Fallback to AX APIs
            AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }
        
        Logger.debug("=== MINIMIZE COMPLETE ===")
    }

    func closeWindow(windowInfo: WindowInfo, for app: NSRunningApplication) {
        Logger.debug("=== CLOSING WINDOW ===")
        Logger.debug("Closing window - Name: \(windowInfo.name), ID: \(windowInfo.cgWindowID ?? 0)")
        
        if let cgWindowID = windowInfo.cgWindowID {
            // Use CGWindow APIs for close
            closeWindowWithCGWindow(windowID: cgWindowID)
        } else {
            // Fallback to AX APIs
            AXUIElementPerformAction(windowInfo.window, Constants.Accessibility.closeKey)
        }
        
        Logger.debug("=== CLOSE COMPLETE ===")
    }

    private func minimizeWindowWithCGWindow(windowID: CGWindowID) {
        Logger.debug("Attempting to minimize window with ID: \(windowID)")
        
        // Get the list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? else {
            Logger.debug("❌ Unable to retrieve window list")
            return
        }
        
        // Find our target window info
        guard let targetWindow = (windowList as? [[String: Any]])?.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let ownerPID = targetWindow[kCGWindowOwnerPID as String] as? pid_t,
              let targetTitle = targetWindow[kCGWindowName as String] as? String else {
            Logger.debug("❌ Could not find target window info")
            return
        }
        
        // Create AXUIElement for the application
        let appRef = AXUIElementCreateApplication(ownerPID)
        
        // Get the list of windows
        var windowsRef: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard windowResult == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            Logger.debug("❌ No accessible windows found for PID \(ownerPID)")
            return
        }
        
        // Try to find matching window by title and PID
        for window in windowArray {
            var titleRef: CFTypeRef?
            var pid: pid_t = 0
            
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let pidResult = AXUIElementGetPid(window, &pid)
            
            if titleResult == .success,
               pidResult == .success,
               let title = titleRef as? String,
               title == targetTitle && pid == ownerPID {
                
                Logger.debug("Found matching window, minimizing without animation")
                
                // Get current window position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                
                // Store original position and size
                if CFGetTypeID(positionRef!) == AXValueGetTypeID(),
                   CFGetTypeID(sizeRef!) == AXValueGetTypeID() {
                    let posValue = positionRef as! AXValue
                    let sizeValue = sizeRef as! AXValue
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(posValue, .cgPoint, &position)
                    AXValueGetValue(sizeValue, .cgSize, &size)
                    
                    // Set minimized state directly without animation
                    let minimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    Logger.debug(minimizeResult == .success ? "✓ Window minimized successfully" : "❌ Failed to minimize window")
                } else {
                    // Fallback to standard minimization if we can't get position/size
                    let minimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    Logger.debug(minimizeResult == .success ? "✓ Window minimized using fallback method" : "❌ Failed to minimize window")
                }
                return
            }
        }
        
        Logger.debug("❌ No matching window found")
    }

    private func closeWindowWithCGWindow(windowID: CGWindowID) {
        Logger.debug("Attempting to close window with ID: \(windowID)")
        
        // Get the list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? else {
            Logger.debug("❌ Unable to retrieve window list")
            return
        }
        
        // Find our target window info
        guard let targetWindow = (windowList as? [[String: Any]])?.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let ownerPID = targetWindow[kCGWindowOwnerPID as String] as? pid_t,
              let targetTitle = targetWindow[kCGWindowName as String] as? String,
              let targetBounds = targetWindow[kCGWindowBounds as String] as? [String: CGFloat] else {
            Logger.debug("❌ Could not find target window info")
            return
        }
        
        let targetRect = CGRect(x: targetBounds["X"] ?? 0,
                               y: targetBounds["Y"] ?? 0,
                               width: targetBounds["Width"] ?? 0,
                               height: targetBounds["Height"] ?? 0)
        
        Logger.debug("Found target window - Title: '\(targetTitle)', PID: \(ownerPID), Bounds: \(targetRect)")
        
        // Create AXUIElement for the application
        let appRef = AXUIElementCreateApplication(ownerPID)
        
        // Get the list of windows
        var windowsRef: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard windowResult == .success,
              let windowArray = windowsRef as? [AXUIElement] else {
            Logger.debug("❌ No accessible windows found for PID \(ownerPID)")
            return
        }
        
        Logger.debug("Found \(windowArray.count) windows for application")
        
        // Try to find matching window by title, bounds, and PID
        for window in windowArray {
            var titleRef: CFTypeRef?
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pid: pid_t = 0
            
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let positionResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
            let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
            let pidResult = AXUIElementGetPid(window, &pid)
            
            if titleResult == .success,
               positionResult == .success,
               sizeResult == .success,
               pidResult == .success,
               let title = titleRef as? String,
               let positionValue = positionRef as! AXValue?,
               let sizeValue = sizeRef as! AXValue? {
                
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue, .cgPoint, &position)
                AXValueGetValue(sizeValue, .cgSize, &size)
                let windowRect = CGRect(origin: position, size: size)
                
                Logger.debug("Checking window - Title: '\(title)', PID: \(pid), Bounds: \(windowRect)")
                
                if title == targetTitle && windowRect.equalTo(targetRect) && pid == ownerPID {
                    Logger.debug("Found matching window")
                    
                    // Try to get the close button
                    var closeButtonRef: CFTypeRef?
                    let buttonResult = AXUIElementCopyAttributeValue(window, Constants.Accessibility.closeButtonAttribute, &closeButtonRef)
                    
                    if buttonResult == .success,
                       let closeButton = closeButtonRef as! AXUIElement? {
                        Logger.debug("Found close button, attempting to press")
                        let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                        Logger.debug(pressResult == .success ? "✓ Window closed successfully" : "❌ Failed to press close button")
                        return
                    } else {
                        Logger.debug("❌ No close button found, trying direct close")
                        // Fallback to direct close
                        let closeResult = AXUIElementPerformAction(window, Constants.Accessibility.closeKey)
                        Logger.debug(closeResult == .success ? "✓ Window closed successfully" : "❌ Failed to close window")
                    }
                    return
                }
            }
        }
        
        Logger.debug("❌ No matching window found")
    }
}

// Add helper function to get window bounds
private func getWindowBounds(_ window: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    
    guard AXUIElementCopyAttributeValue(window, Constants.Accessibility.frameKey, &positionValue) == .success,
          AXUIElementCopyAttributeValue(window, Constants.Accessibility.sizeKey, &sizeValue) == .success,
          CFGetTypeID(positionValue!) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue!) == AXValueGetTypeID() else {
        return nil
    }
    
    var position = CGPoint.zero
    var size = CGSize.zero
    
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
        return nil
    }
    
    return CGRect(origin: position, size: size)
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
        
        // Get URL attribute
        var urlUntyped: CFTypeRef?
        let urlResult = AXUIElementCopyAttributeValue(element, Constants.Accessibility.urlKey, &urlUntyped)
        
        // Try standard URL method first
        if urlResult == .success,
           let urlRef = urlUntyped as? NSURL,
           let url = urlRef as URL? {
            
            // Check if it's a Wine application (.exe)
            if url.path.lowercased().hasSuffix(".exe") {
                let baseExeName = url.deletingPathExtension().lastPathComponent.lowercased()
                
                // Create a filtered list of potential Wine apps first
                let potentialWineApps = workspace.runningApplications.filter { app in
                    // Only check apps that are:
                    // 1. Active or regular activation policy
                    // 2. Have a name that matches our target or contains "wine"
                    guard let processName = app.localizedName?.lowercased(),
                        app.activationPolicy == .regular else {
                        return false
                    }
                    return processName.contains(baseExeName) || processName.contains("wine")
                }
                
                // First try exact name matches (most likely to be correct)
                if let exactMatch = potentialWineApps.first(where: { app in
                    app.localizedName?.lowercased() == baseExeName
                }) {
                    // Quick validation with a single window check
                    let windows = AccessibilityService.shared.listApplicationWindows(for: exactMatch)
                    if !windows.isEmpty {
                        return (app: exactMatch, url: url, iconCenter: iconCenter)
                    }
                }
                
                // Then try partial matches
                for wineApp in potentialWineApps {
                    // Cache window list to avoid multiple calls
                    let windows = AccessibilityService.shared.listApplicationWindows(for: wineApp)
                    
                    // Check if any window contains our target name
                    if windows.contains(where: { window in
                        window.name.lowercased().contains(baseExeName)
                    }) {
                        return (app: wineApp, url: url, iconCenter: iconCenter)
                    }
                }
            }
            
            // Standard bundle ID matching
            if let bundle = Bundle(url: url),
               let bundleId = bundle.bundleIdentifier,
               let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                return (app: app, url: url, iconCenter: iconCenter)
            }
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
    // Private backing storage
    private var _heartbeatTimer: Timer?
    private var _lastEventTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var _isEventTapActive: Bool = false
    private var _chooserControllers: [NSRunningApplication: WindowChooserController] = [:]
    private var _windowChooser: WindowChooserController?
    private var _menuShowTask: DispatchWorkItem?
    
    // Public MainActor properties
    @MainActor var heartbeatTimer: Timer? {
        get { _heartbeatTimer }
        set {
            _heartbeatTimer?.invalidate()
            _heartbeatTimer = newValue
        }
    }
    
    @MainActor var chooserControllers: [NSRunningApplication: WindowChooserController] {
        get { _chooserControllers }
        set { _chooserControllers = newValue }
    }
    
    @MainActor var windowChooser: WindowChooserController? {
        get { _windowChooser }
        set { _windowChooser = newValue }
    }
    
    @MainActor var menuShowTask: DispatchWorkItem? {
        get { _menuShowTask }
        set { _menuShowTask = newValue }
    }
    
    // Other properties
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var lastHoveredApp: NSRunningApplication?
    private var lastWindowOrder: [AXUIElement]?
    private let menuShowDelay: TimeInterval = 0.01
    private var lastClickTime: TimeInterval = 0
    private let clickDebounceInterval: TimeInterval = 0.3
    private var clickedApp: NSRunningApplication?
    private let dismissalMargin: CGFloat = 20.0
    private var lastMouseMoveTime: TimeInterval = 0
    private var isContextMenuActive: Bool = false
    private var contextMenuMonitor: Any?
    private var dockMenu: NSMenu?
    private var lastClickedDockIcon: NSRunningApplication?
    private var lastRightClickedDockIcon: NSRunningApplication?
    private var showingWindowChooserOnClick: Bool = false
    private var skipNextClickProcessing: Bool = false
    private let eventTimeoutInterval: TimeInterval = 5.0  // 5 seconds timeout
    
    override init() {
        super.init()
        setupEventTap()
        setupNotifications()
        setupDockMenuTracking()
        startHeartbeat()  // Add heartbeat monitoring
        Logger.info("DockWatcher initialized")
    }
    
    private func startHeartbeat() {
        // Stop existing timer if any
        heartbeatTimer?.invalidate()
        
        // Create new timer
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                let currentTime = ProcessInfo.processInfo.systemUptime
                let timeSinceLastEvent = currentTime - self._lastEventTime
                
                if timeSinceLastEvent > self.eventTimeoutInterval {
                    Logger.warning("Event tap appears inactive (no events for \(Int(timeSinceLastEvent)) seconds). Reinitializing...")
                    self.reinitializeEventTap()
                }
            }
        }
    }

    @MainActor private func reinitializeEventTap() {
        Logger.info("Reinitializing event tap...")
        
        // Clean up existing event tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        // Reset properties
        eventTap = nil
        runLoopSource = nil
        _isEventTapActive = false
        
        // Reinitialize
        setupEventTap()
        
        // Verify the event tap was created successfully
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            _isEventTapActive = true
            Logger.success("Event tap reinitialized successfully")
        } else {
            Logger.error("Failed to reinitialize event tap")
        }
        
        // Update last event time to prevent immediate retry
        _lastEventTime = ProcessInfo.processInfo.systemUptime
    }

    @MainActor private func updateLastEventTime() {
        _lastEventTime = ProcessInfo.processInfo.systemUptime
        _isEventTapActive = true
    }

    nonisolated private func cleanup() {
        // Clean up event tap synchronously
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        
        // Clean up run loop source synchronously
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        
        // Clean up references
        eventTap = nil
        runLoopSource = nil
        
        // Clean up timer and tasks on main thread
        _ = DispatchQueue.main.sync {
            Task { @MainActor in
                _menuShowTask?.cancel()
                _menuShowTask = nil
                _heartbeatTimer?.invalidate()
                _heartbeatTimer = nil
            }
        }
    }

    @MainActor private func cleanupWindows() {
        // Hide windows immediately
        for controller in _chooserControllers.values {
            controller.window?.orderOut(nil)
        }
        _windowChooser?.window?.orderOut(nil)
        
        // Clear references
        _chooserControllers.removeAll()
        _windowChooser = nil
    }

    deinit {
        // Remove observer
        NotificationCenter.default.removeObserver(self)
        
        // Call cleanup
        cleanup()
        
        // Clean up UI components synchronously on main thread
        DispatchQueue.main.sync {
            // Hide windows immediately
            chooserControllers.values.forEach { $0.window?.orderOut(nil) }
            windowChooser?.window?.orderOut(nil)
            
            // Clear references
            chooserControllers.removeAll()
            windowChooser = nil
        }
    }
    
    private func setupEventTap() {
        guard AccessibilityService.shared.requestAccessibilityPermissions() else {
            Logger.error("Failed to get accessibility permissions")
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
            
            // Update last event time for heartbeat
            Task { @MainActor in
                watcher.updateLastEventTime()
            }
            
            // Check if the event tap is enabled
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in
                    watcher.reinitializeEventTap()
                }
                return Unmanaged.passRetained(event)
            }
            
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
            Logger.error("Failed to create event tap")
            return
        }
        
        self.eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        self.runLoopSource = runLoopSource
        
        CGEvent.tapEnable(tap: tap, enable: true)
        _isEventTapActive = true
        
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
        if windows.count == 1 && windows[0].isAppElement {
            // Don't try to launch the app on hover - only show the menu
            let chooser = WindowChooserController(
                at: point,
                windows: windows,
                app: app,
                callback: { window, isHideAction in
                    // Find the WindowInfo for this window
                    if let windowInfo = windows.first(where: { $0.window == window }) {
                        AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                    }
                }
            )
            
            // Store strong reference
            chooserControllers[app] = chooser
            self.windowChooser = chooser
            chooser.window?.makeKeyAndOrderFront(self)
            return
        }
        
        // If no windows at all, don't show anything
        if windows.isEmpty {
            return
        }
        
        // Create and show new chooser for multiple windows
        let chooser = WindowChooserController(
            at: point,
            windows: windows,
            app: app,
            callback: { window, isHideAction in
                // Find the WindowInfo for this window
                if let windowInfo = windows.first(where: { $0.window == window }) {
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
                Task {
                    // Hide other windows in background
                    for otherWindow in windows where otherWindow.window != window {
                        AccessibilityService.shared.hideWindow(window: otherWindow.window, for: app)
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

        // Store the current mouse location and icon center before closing
        let mouseLocation = NSEvent.mouseLocation
        let iconCenter = DockService.shared.findAppUnderCursor(at: mouseLocation)?.iconCenter

        // Process the click
        let result = handleDockIconClick(app: app)
        
        // Don't reopen the window chooser - let the hover behavior handle it
        windowChooser?.close()
        windowChooser = nil
        lastHoveredApp = nil
        
        return result
    }

    // Add new helper method to handle the actual click logic
    private func handleDockIconClick(app: NSRunningApplication) -> Bool {
        Logger.debug("Processing click for app: \(app.localizedName ?? "Unknown")")

        // Special handling for Finder
        if app.bundleIdentifier == "com.apple.finder" {
            // Get all windows and check for visible, non-desktop windows
            let windows = AccessibilityService.shared.listApplicationWindows(for: app)
            let hasVisibleTopmostWindow = app.isActive && windows.contains { windowInfo in
                // Skip desktop window and app elements
                guard !windowInfo.isAppElement else { return false }
                
                // Get window role and subrole
                var roleValue: AnyObject?
                var subroleValue: AnyObject?
                let roleResult = AXUIElementCopyAttributeValue(windowInfo.window, kAXRoleAttribute as CFString, &roleValue)
                let subroleResult = AXUIElementCopyAttributeValue(windowInfo.window, kAXSubroleAttribute as CFString, &subroleValue)
                
                let role = (roleValue as? String) ?? ""
                let subrole = (subroleValue as? String) ?? ""
                
                // Check if window is visible and not minimized
                var minimizedValue: AnyObject?
                var hiddenValue: AnyObject?
                let isMinimized = AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                                 (minimizedValue as? Bool == true)
                let isHidden = AXUIElementCopyAttributeValue(windowInfo.window, kAXHiddenAttribute as CFString, &hiddenValue) == .success &&
                              (hiddenValue as? Bool == true)
                
                // Log window details for debugging
                Logger.debug("Window '\(windowInfo.name)' - role: \(role) subrole: \(subrole) minimized: \(isMinimized) hidden: \(isHidden)")
                
                // Consider window visible if:
                // 1. It's a regular window (AXWindow) with standard dialog subrole
                // 2. Not minimized or hidden
                // 3. Not the desktop window
                let isRegularWindow = role == "AXWindow" && subrole == "AXStandardWindow"
                let isVisible = !isMinimized && !isHidden && isRegularWindow
                
                return isVisible
            }
            
            Logger.debug("Finder active: \(app.isActive), has visible windows: \(hasVisibleTopmostWindow)")
            
            if hasVisibleTopmostWindow {
                Logger.debug("Finder has visible topmost windows, hiding")
                AccessibilityService.shared.hideAllWindows(for: app)
                return app.hide()
            } else {
                Logger.debug("Finder has no visible topmost windows, showing")
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
                
                // Only restore non-minimized windows
                let nonMinimizedWindows = windows.filter { windowInfo in
                    guard !windowInfo.isAppElement else { return false }
                    var minimizedValue: AnyObject?
                    return !(AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
                            (minimizedValue as? Bool == true))
                }
                
                if nonMinimizedWindows.isEmpty {
                    // Open home directory in a new Finder window if no non-minimized windows
                    let homeURL = FileManager.default.homeDirectoryForCurrentUser
                    NSWorkspace.shared.open(homeURL)
                } else {
                    // Find the highlighted window from the window chooser if it exists
                    let highlightedWindow = windowChooser?.chooserView?.topmostWindow
                    
                    // Split windows into highlighted and others
                    let (highlighted, others) = nonMinimizedWindows.partition { windowInfo in
                        windowInfo.window == highlightedWindow
                    }
                    
                    // First restore all other windows
                    for windowInfo in others {
                        AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                    }
                    
                    // Then restore the highlighted window last to make it frontmost
                    if let lastWindow = highlighted.first {
                        // Add a small delay to ensure other windows are restored
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            AccessibilityService.shared.raiseWindow(windowInfo: lastWindow, for: app)
                        }
                    }
                }
                return true
            }
        }

        // Get all windows
        let windows = AccessibilityService.shared.listApplicationWindows(for: app)
        
        // If we only have the app entry (no real windows), handle launch
        if windows.count == 0 || windows[0].isAppElement {
            Logger.debug("App has no windows, launching")
            app.activate(options: [.activateIgnoringOtherApps])
            if let bundleURL = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            }
            return true
        }

        // Check if there's exactly one window and if it's minimized
        if windows.count == 1 && !windows[0].isAppElement {
            let window = windows[0].window
            var minimizedValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                Logger.debug("Single minimized window found, restoring")
                // First unminimize
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                
                // Then activate and raise after a small delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    app.activate(options: [.activateIgnoringOtherApps])
                    // Create WindowInfo for the window
                    var titleValue: AnyObject?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    let windowName = (titleValue as? String) ?? app.localizedName ?? "Unknown"
                    let windowInfo = WindowInfo(
                        window: window,
                        name: windowName,
                        isAppElement: false
                    )
                    AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
                }
            }
        }
        
        // Initialize window states before checking app status
        AccessibilityService.shared.initializeWindowStates(for: app)
        
        // Check if there are any visible windows
        let hasVisibleWindows = windows.contains { windowInfo in
            AccessibilityService.shared.checkWindowVisibility(windowInfo.window)
        }
        
        // Check if app is both active AND has visible windows
        if app.isActive && hasVisibleWindows {
            Logger.debug("App is active with visible windows, hiding all windows")
            AccessibilityService.shared.hideAllWindows(for: app)
            return app.hide()
        } else if !hasVisibleWindows {
            Logger.debug("App has no visible windows, restoring last active window")
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
            
            // Get the highlighted window from the window chooser if it exists
            let highlightedWindow = windowChooser?.chooserView?.topmostWindow
            
            // Split windows into highlighted and others
            let (highlighted, others) = windows.partition { windowInfo in
                windowInfo.window == highlightedWindow
            }
            
            Task { @MainActor in
                // First unminimize all windows without raising them
                for windowInfo in windows {
                    var minimizedValue: AnyObject?
                    if AXUIElementCopyAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                       let isMinimized = minimizedValue as? Bool,
                       isMinimized {
                        AXUIElementSetAttributeValue(windowInfo.window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
                    }
                }
                
                // Add delay before raising windows
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms delay
                
                // Then raise only the highlighted window if it exists
                if let lastWindow = highlighted.first {
                    AccessibilityService.shared.raiseWindow(windowInfo: lastWindow, for: app)
                } else if let firstWindow = windows.first {
                    // If no highlighted window, just raise the first one
                    AccessibilityService.shared.raiseWindow(windowInfo: firstWindow, for: app)
                }
                
                // Close the window chooser after window restoration is complete
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
                windowChooser?.close()
                windowChooser = nil
                lastHoveredApp = nil
            }
            return true
        } else {
            // Just activate the app if it has visible windows but isn't active
            Logger.debug("App has visible windows but isn't active, activating")
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
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
    private weak var updaterController: SPUStandardUpdaterController?
    private let autostartMenuItem: NSMenuItem
    
    init(updater: SPUStandardUpdaterController) {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        
        // Store the shared updater controller
        updaterController = updater
        
        // Create autostart menu item
        autostartMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleAutostart),
            keyEquivalent: ""
        )
        
        if let button = statusItem.button {
            // Try multiple paths to find the icon
            let iconImage: NSImage?
            if let bundleIconPath = Bundle.main.path(forResource: "trayicon", ofType: "png") {
                // App bundle path
                iconImage = NSImage(contentsOfFile: bundleIconPath)
            } else {
                // Development path
                let devIconPath = "Sources/DockAppToggler/Resources/trayicon.png"
                iconImage = NSImage(contentsOfFile: devIconPath)
            }
            
            if let image = iconImage {
                // Create a copy of the image at the desired size
                let resizedImage = NSImage(size: NSSize(width: 18, height: 18))
                resizedImage.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: NSSize(width: 18, height: 18)))
                resizedImage.unlockFocus()
                
                // Set as template
                resizedImage.isTemplate = true
                button.image = resizedImage
            }
        }
        
        setupMenu()
        updateAutostartState()
    }
    
    private func setupMenu() {
        // Add autostart toggle
        autostartMenuItem.target = self
        menu.addItem(autostartMenuItem)
        
        // Add separator
        menu.addItem(NSMenuItem.separator())
        
        // Update menu item
        let updateItem = NSMenuItem(title: "Check for Updates...", 
                                  action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), 
                                  keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", 
                                action: #selector(NSApplication.terminate(_:)), 
                                keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func toggleAutostart() {
        let isEnabled = !LoginItemManager.shared.isLoginItemEnabled
        LoginItemManager.shared.setLoginItemEnabled(isEnabled)
        updateAutostartState()
    }
    
    private func updateAutostartState() {
        autostartMenuItem.state = LoginItemManager.shared.isLoginItemEnabled ? .on : .off
    }
}

// Update LoginItemManager class
@MainActor
class LoginItemManager {
    static let shared = LoginItemManager()
    
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.dockapptoggler"
    
    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Fallback for older macOS versions
            return false
        }
    }
    
    func setLoginItemEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.error("Failed to \(enabled ? "enable" : "disable") login item: \(error)")
            }
        } else {
            Logger.warning("Auto-start not supported on this macOS version")
        }
    }
}

// MARK: - Application Entry Point

// Add near the start of the application entry point
Logger.info("Starting Dock App Toggler...")

// Initialize app components
let app = NSApplication.shared

// Run the accessibility check once at startup
_ = AccessibilityService.shared.requestAccessibilityPermissions()

// Create the shared updater controller first
let sharedUpdater = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: UpdateController()
)

// Create and store all controllers to prevent deallocation
let appController = (
    watcher: DockWatcher(),
    statusBar: StatusBarController(updater: sharedUpdater),
    updater: sharedUpdater
)

// Configure the app to be a background application
app.setActivationPolicy(.accessory)

// Start the application
app.run()

// Add this new class for handling updates
@MainActor
class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }
    
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Capture the values we need before starting the task
        let version = update.displayVersionString
        let isUserInitiated = state.userInitiated
        
        Task { @MainActor in
            // When an update alert will be presented, place the app in the foreground
            NSApp.setActivationPolicy(.regular)
            
            if !isUserInitiated {
                // Add a badge to the app's dock icon indicating one alert occurred
                NSApp.dockTile.badgeLabel = "1"
                
                // Post a user notification
                let content = UNMutableNotificationContent()
                content.title = "A new update is available"
                content.body = "Version \(version) is now available"
                
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
            
            // Dismiss active update notifications without await since it's not async
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["UpdateCheck"])
        }
    }
    
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            // Put app back in background when the user session for the update finished
            NSApp.setActivationPolicy(.accessory)
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

func toggleApp(_ bundleIdentifier: String) {
    let workspace = NSWorkspace.shared
    let runningApps = workspace.runningApplications
    
    guard let app = runningApps.first(where: { app in
        app.bundleIdentifier == bundleIdentifier
    }) else {
        print("App not found")
        return
    }
    
    // Special handling for Finder - check if frontmost
    if bundleIdentifier == "com.apple.finder" {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp == app {
            app.hide()
        } else {
            app.unhide()
            app.activate(options: [.activateIgnoringOtherApps])
        }
        return
    }
    
    // Regular handling for other apps
    let appWindows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let visibleWindows = appWindows.filter { window in
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let app = runningApps.first(where: { app in
                  app.localizedName == ownerName
              }),
              app.bundleIdentifier == bundleIdentifier else {
            return false
        }
        return true
    }
    
    if visibleWindows.isEmpty {
        app.unhide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            app.activate(options: [.activateIgnoringOtherApps])
            
            // Create an AXUIElement for the app
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            
            // Create a basic WindowInfo for the app
            let windowInfo = WindowInfo(
                window: axApp,
                name: app.localizedName ?? "Unknown",
                isAppElement: true
            )
            
            AccessibilityService.shared.raiseWindow(windowInfo: windowInfo, for: app)
        }
    } else {
        app.hide()
    }
}

// Add near the top of the file with other extensions
extension Array {
    func partition(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var nonMatching: [Element] = []
        
        forEach { element in
            if predicate(element) {
                matching.append(element)
            } else {
                nonMatching.append(element)
            }
        }
        
        return (matching, nonMatching)
    }
}
