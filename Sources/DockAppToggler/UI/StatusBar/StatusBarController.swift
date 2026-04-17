import AppKit
import Sparkle
import Cocoa
import CoreGraphics

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private weak var updaterController: SPUStandardUpdaterController?
    private let autostartMenuItem: NSMenuItem
    private let tooltipsMenuItem: NSMenuItem
    private let optionTabMenuItem: NSMenuItem
    
    // Use nonisolated(unsafe) for the monitor since we need to modify it
    private nonisolated(unsafe) var mouseEventMonitor: AnyObject?
    
    // Add menu item property to track state
    private var previewsMenuItem: NSMenuItem?
    
    // Add property to track screen observer
    private var screenObserver: Any?
    
    /// Restores visibility when the system hides the item (menu bar overflow, sleep/wake edge cases).
    private var visibilityObservation: NSKeyValueObservation?
    
    private nonisolated(unsafe) var workspaceWakeObserver: NSObjectProtocol?
    
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
        
        // Create Option+Tab menu item
        optionTabMenuItem = NSMenuItem(
            title: "Option+Tab Switching",
            action: #selector(toggleOptionTab),
            keyEquivalent: ""
        )

        super.init()
        
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
        setupStatusItemPersistence()
        setupScreenObserver()
        setupWorkspaceWakeObserver()
    }
    
    /// Disallow interactive removal and observe `isVisible` so the tray icon is not left hidden by the system.
    private func setupStatusItemPersistence() {
        statusItem.behavior = NSStatusItem.Behavior()
        statusItem.isVisible = true
        
        visibilityObservation?.invalidate()
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { item, _ in
            if !item.isVisible {
                Logger.debug("Status item became invisible; restoring visibility")
                item.isVisible = true
            }
        }
    }
    
    private func setupWorkspaceWakeObserver() {
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureStatusItemVisibleAfterSystemEvent()
            }
        }
    }
    
    private func ensureStatusItemVisibleAfterSystemEvent() {
        statusItem.isVisible = true
        if statusItem.button?.superview == nil {
            Logger.debug("Status bar item missing after wake; recreating")
            recreateStatusItem()
        }
    }
    
    // Add method to observe screen changes
    private func setupScreenObserver() {
        // Remove existing observer if any
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Add observer for screen changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Use Task to call the actor-isolated method from a non-isolated context
            Task { @MainActor [weak self] in
                self?.handleScreenConfigurationChange()
            }
        }
    }
    
    // Add method to handle screen configuration changes
    private func handleScreenConfigurationChange() {
        // Log the change
        Logger.debug("Screen configuration changed in StatusBarController")
        
        // Update status bar item visibility if needed
        if NSScreen.displaysHaveSeparateSpaces {
            // When displays have separate spaces, ensure status bar item is visible
            Logger.debug("Ensuring status bar item visibility with separate spaces")
            
            // The system should automatically handle status bar item visibility
            // but we can force a refresh by recreating it if needed
            if statusItem.button?.superview == nil {
                Logger.debug("Status bar item not visible, recreating")
                recreateStatusItem()
            }
        }
    }
    
    // Add method to recreate status item if needed
    private func recreateStatusItem() {
        // Store current state
        let currentMenu = statusItem.menu
        let oldItem = statusItem
        
        // Create new status item
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        
        // Restore menu
        statusItem.menu = currentMenu
        
        // Restore icon
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
        
        setupStatusItemPersistence()
        statusBar.removeStatusItem(oldItem)
        
        Logger.debug("Status bar item recreated")
    }
    
    private func setupMenu() {
        // Get current state of window previews, defaulting to disabled
        let previewsEnabled = UserDefaults.standard.bool(forKey: "WindowPreviewsEnabled", defaultValue: false)
        
        // Add autostart toggle
        autostartMenuItem.target = self
        menu.addItem(autostartMenuItem)
        
        // Add tooltips toggle - default to enabled
        tooltipsMenuItem.target = self
        tooltipsMenuItem.state = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled", defaultValue: true) ? .on : .off
        menu.addItem(tooltipsMenuItem)
        
        // Add Option+Tab toggle - default to enabled
        optionTabMenuItem.target = self
        let optionTabEnabled = UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: true)
        optionTabMenuItem.state = optionTabEnabled ? .on : .off
        menu.addItem(optionTabMenuItem)

        // Create menu item with checkmark for window previews
        previewsMenuItem = NSMenuItem(
            title: "Window Previews",
            action: #selector(toggleWindowPreviews(_:)),
            keyEquivalent: ""
        )
        previewsMenuItem?.target = self
        previewsMenuItem?.state = previewsEnabled ? .on : .off
        menu.addItem(previewsMenuItem!)

        let screenPermissionItem = NSMenuItem(
            title: "Request Screen Recording Access",
            action: #selector(requestScreenRecordingAccess),
            keyEquivalent: ""
        )
        screenPermissionItem.target = self
        menu.addItem(screenPermissionItem)

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
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        NotificationCenter.default.post(
            name: .statusBarMenuStateChanged,
            object: nil,
            userInfo: ["isOpen": true]
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        NotificationCenter.default.post(
            name: .statusBarMenuStateChanged,
            object: nil,
            userInfo: ["isOpen": false]
        )
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
            
            // Update menu item state and save preference
            let newState = !WindowThumbnailView.arePreviewsDisabled()
            sender.state = newState ? .on : .off
            UserDefaults.standard.set(newState, forKey: "WindowPreviewsEnabled")
        }
    }

    @objc private func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
    }
    
    @objc private func toggleTooltips() {
        let newState = tooltipsMenuItem.state == .off
        UserDefaults.standard.set(newState, forKey: "StatusBarTooltipsEnabled")
        tooltipsMenuItem.state = newState ? .on : .off
        
        // Post notification for StatusBarWatcher
        NotificationCenter.default.post(name: .statusBarTooltipsStateChanged, object: nil)
    }
    
    @objc private func toggleOptionTab() {
        let newState = optionTabMenuItem.state == .off
        UserDefaults.standard.set(newState, forKey: "OptionTabEnabled")
        optionTabMenuItem.state = newState ? .on : .off
        
        // Post notification for any listeners that need to know about the change
        NotificationCenter.default.post(name: .optionTabStateChanged, object: nil, userInfo: ["enabled": newState])
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
    
    
    deinit {
        visibilityObservation?.invalidate()
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
        // Since we're using nonisolated(unsafe), we need to be careful about thread safety
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        
        // Remove screen observer using Task to access actor-isolated property
        Task { @MainActor [weak self] in
            if let self = self, let observer = self.screenObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// Add extension for the notification name
extension Notification.Name {
    static let optionTabStateChanged = Notification.Name("optionTabStateChanged")
    static let statusBarMenuStateChanged = Notification.Name("statusBarMenuStateChanged")
}

// Add extension for UserDefaults to handle default values
extension UserDefaults {
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil {
            set(defaultValue, forKey: key)
            return defaultValue
        }
        return bool(forKey: key)
    }
} 
