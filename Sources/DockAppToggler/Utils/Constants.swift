@preconcurrency import Foundation
@preconcurrency import AppKit
@preconcurrency import Carbon

/// Constants used throughout the DockAppToggler application
enum Constants {

    /// Event tap related constants
    enum EventTap {
        static let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue) |
                                          (1 << CGEventType.leftMouseDown.rawValue) |
                                          (1 << CGEventType.leftMouseUp.rawValue) |
                                          (1 << CGEventType.rightMouseDown.rawValue) |
                                          (1 << CGEventType.rightMouseUp.rawValue)
    }

    /// UI-related constants for layout and dimensions
    enum UI {
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
        static func windowHeight(for windowCount: Int) -> CGFloat {
            /*Logger.debug("Window height calculation:")
            Logger.debug("  - Window count: \(windowCount)")*/
            
            // Base height includes title area
            let baseHeight = titleHeight + titlePadding
            //Logger.debug("  - Base height (title + padding): \(baseHeight)")
            
            // Calculate button area height
            let buttonsHeight = CGFloat(windowCount) * buttonSpacing
            //Logger.debug("  - Buttons height (\(windowCount) * \(buttonSpacing)): \(buttonsHeight)")
            
            // Add padding - use less padding for single window
            let totalPadding = windowCount <= 1 ? verticalPadding : (verticalPadding * 2)
            //Logger.debug("  - Total padding: \(totalPadding)")
            
            // Calculate total height
            let totalHeight = baseHeight + buttonsHeight + totalPadding
            //Logger.debug("  - Total height before min check: \(totalHeight)")
            
            // Ensure minimum height but keep it compact for single entries
            let minHeight: CGFloat = windowCount <= 1 ? 70 : 100
            let finalHeight = max(totalHeight, minHeight)
            //Logger.debug("  - Final height (after min height \(minHeight)): \(finalHeight)")
            
            return finalHeight
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
        static let menuDismissalMargin: CGFloat = 20.0  // Margin around menu for dismissal
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
        static let closeKey = "AXCloseAction" as CFString
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