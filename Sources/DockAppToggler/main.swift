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

// MARK: - Application Entry Point

// Add near the start of the application entry point
Logger.info("Starting Dock App Toggler...")

// Check command line arguments
let shouldSkipUpdateCheck = CommandLine.arguments.contains("--s")

// Initialize app components
let app = NSApplication.shared

// Run the accessibility check once at startup
_ = AccessibilityService.shared.requestAccessibilityPermissions()

// Show help screen on first launch
DispatchQueue.main.async {
    HelpWindowController.showIfNeeded()
}

// Create the shared updater controller - always create it, but control auto-check behavior
let sharedUpdater = SPUStandardUpdaterController(
    startingUpdater: !shouldSkipUpdateCheck,  // Only start the updater if not skipping
    updaterDelegate: nil,
    userDriverDelegate: UpdateController()
)

// Create and store all controllers to prevent deallocation
let appController = (
    watcher: DockWatcher(),
    statusBar: StatusBarController(updater: sharedUpdater),
    statusBarWatcher: StatusBarWatcher(),
    updater: sharedUpdater
)

// Configure the app to be a background application
app.setActivationPolicy(.accessory)

// Initialize keyboard shortcut monitor
_ = KeyboardShortcutMonitor.shared

// Start the application
app.run()

