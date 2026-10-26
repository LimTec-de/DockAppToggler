import AppKit

// Run only through test_status_bar.py: a real .app is required for status items.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let statusBar = NSStatusBar.system
let boundary = statusBar.statusItem(withLength: 20)
boundary.button?.title = "T"
boundary.button?.setAccessibilityIdentifier("test-boundary")
let permanent = statusBar.statusItem(withLength: 20)
permanent.button?.title = "P"
permanent.button?.setAccessibilityIdentifier("test-permanent")
let controller = NativeTrayController(
    ownBundle: Bundle.main.bundleIdentifier!,
    boundaryIdentifier: "test-boundary", alwaysHiddenIdentifier: "test-permanent", changed: {}
)

@MainActor func require(_ condition: Bool, _ message: String) {
    guard condition else {
        controller.stop()
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

Task { @MainActor in
    try await Task.sleep(for: .seconds(1))
    for collapsed in [true, false, true, false] {
        controller.set(collapsed: collapsed, editing: false, alwaysHidden: true)
        try await Task.sleep(for: .seconds(2))
        require(controller.errorMessage == nil, controller.errorMessage ?? "")
        require(controller.isCollapsed == collapsed, "Incorrect collapse state")
    }
    for _ in 0..<10 {
        controller.set(collapsed: true, editing: false, alwaysHidden: true)
        controller.set(collapsed: false, editing: false, alwaysHidden: true)
    }
    try await Task.sleep(for: .seconds(2))
    require(!controller.isCollapsed && controller.errorMessage == nil, "A stale request replaced the last expand")

    controller.set(collapsed: true, editing: false, alwaysHidden: true)
    controller.stop()
    try await Task.sleep(for: .seconds(2))
    require(!controller.isCollapsed && controller.errorMessage == nil, "A pending activation survived stop")

    controller.set(collapsed: false, editing: true, alwaysHidden: true)
    try await Task.sleep(for: .seconds(2))
    require(!controller.isCollapsed && controller.errorMessage == nil, "Editing failed")
    controller.stop()
    print("PASS: collapse, expand, rapid toggles, stop, editing")
    application.terminate(nil)
}
application.run()
