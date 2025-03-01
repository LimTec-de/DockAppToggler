import AppKit

@MainActor
class HelpWindowController: NSWindowController {
    // Keep a static reference to prevent deallocation
    private static var shared: HelpWindowController?
    
    convenience init() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockAppToggler Help"
        window.center()
        
        // Create and set the view controller
        let viewController = HelpViewController()
        window.contentViewController = viewController
        
        // Set window to be visible on all spaces
        window.collectionBehavior = [.canJoinAllSpaces]
        
        self.init(window: window)
    }
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        
        // Ensure window is key and front
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        
        // Center window if not already positioned
        window?.center()
    }
    
    static func showIfNeeded() {
        guard HelpViewController.shouldShowHelp() else { return }
        show()
    }
    
    static func show() {
        shared = HelpWindowController()
        shared?.showWindow(nil)
    }
} 