import AppKit
import Sparkle
import Cocoa

@MainActor
class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private weak var updaterController: SPUStandardUpdaterController?
    private let autostartMenuItem: NSMenuItem
    
    // Use nonisolated(unsafe) for the monitor since we need to modify it
    private nonisolated(unsafe) var mouseEventMonitor: AnyObject?
    
    init(updater: SPUStandardUpdaterController?) {
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
                
                // Add tooltip
                button.toolTip = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String ?? "DockAppToggler"
            }
        }
        
        setupMenu()
        updateAutostartState()
        setupMouseEventMonitoring()
    }
    
    private func setupMenu() {
        // Add autostart toggle
        autostartMenuItem.target = self
        menu.addItem(autostartMenuItem)
        
        // Add separator
        menu.addItem(NSMenuItem.separator())
        
        // Add help menu item
        let helpItem = NSMenuItem(title: "Show Help...", action: #selector(showHelp), keyEquivalent: "h")
        helpItem.target = self
        menu.addItem(helpItem)
        
        // Add update menu item only if updater is available
        if let updaterController = updaterController {
            let updateItem = NSMenuItem(title: "Check for Updates...", 
                                      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), 
                                      keyEquivalent: "")
            updateItem.target = updaterController
            menu.addItem(updateItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // Add restart option
        let restartItem = NSMenuItem(
            title: "Restart",
            action: #selector(restartApp),
            keyEquivalent: "r"
        )
        restartItem.target = self
        menu.addItem(restartItem)
        
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
    
    @objc private func showHelp() {
        HelpWindowController.show()
    }
    
    @objc private func restartApp() {
        StatusBarController.performRestart()
    }
    
    static func performRestart() {
        // Set flag to skip help on next launch
        UserDefaults.standard.set(true, forKey: "HideHelpOnStartup")
        
        // Restart without checking for updates
        NSApplication.restart(skipUpdateCheck: true)
    }
    
    private func setupMouseEventMonitoring() {
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                Task { @MainActor in
                    self?.handleMouseEvent(event)
                }
            }
        ) as AnyObject
    }
    
    deinit {
        // Since we're using nonisolated(unsafe), we need to be careful about thread safety
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard statusItem.button?.isEnabled == true else { return }
        switch event.type {
        case .mouseMoved:
            // Handle mouse movement
            break
        case .leftMouseDown, .rightMouseDown:
            // Handle mouse clicks
            break
        default:
            break
        }
    }
} 