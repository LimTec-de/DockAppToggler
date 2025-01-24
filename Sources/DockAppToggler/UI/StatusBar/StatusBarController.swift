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
    private let tooltipsMenuItem: NSMenuItem
    
    // Use nonisolated(unsafe) for the monitor since we need to modify it
    private nonisolated(unsafe) var mouseEventMonitor: AnyObject?
    
    // Add menu item property to track state
    private var previewsMenuItem: NSMenuItem?
    
    init(updater: SPUStandardUpdaterController?) {
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        
        // Store the shared updater controller
        updaterController = updater
        
        // Create autostart menu item
        autostartMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleAutostart),
            keyEquivalent: ""
        )
        
        // Create tooltips menu item
        tooltipsMenuItem = NSMenuItem(
            title: "Tray Tooltips",
            action: #selector(toggleTooltips),
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
        // Get current state of window previews
        let previewsEnabled = !WindowThumbnailView.arePreviewsDisabled()
        
        
        // Add autostart toggle
        autostartMenuItem.target = self
        menu.addItem(autostartMenuItem)
        
        // Add tooltips toggle
        tooltipsMenuItem.target = self
        tooltipsMenuItem.state = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled") ? .on : .off
        menu.addItem(tooltipsMenuItem)
        
        // Create menu item with checkmark
        previewsMenuItem = NSMenuItem(
            title: "Window Previews",
            action: #selector(toggleWindowPreviews(_:)),
            keyEquivalent: ""
        )
        previewsMenuItem?.target = self
        previewsMenuItem?.state = previewsEnabled ? .on : .off
        menu.addItem(previewsMenuItem!)

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
    
    @objc private func toggleWindowPreviews(_ sender: NSMenuItem) {
        Task { @MainActor in
            // Toggle previews
            WindowThumbnailView.togglePreviews()
            
            // Update menu item state
            sender.state = WindowThumbnailView.arePreviewsDisabled() ? .off : .on
        }
    }
    
    @objc private func toggleTooltips() {
        let newState = tooltipsMenuItem.state == .off
        UserDefaults.standard.set(newState, forKey: "StatusBarTooltipsEnabled")
        tooltipsMenuItem.state = newState ? .on : .off
        
        // Post notification for StatusBarWatcher
        NotificationCenter.default.post(name: .statusBarTooltipsStateChanged, object: nil)
    }
    
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        // Update menu item state before showing menu
        if let previewsItem = previewsMenuItem {
            previewsItem.state = WindowThumbnailView.arePreviewsDisabled() ? .off : .on
        }
        
        // Show menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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