import AppKit
import ApplicationServices
import Testing
@testable import DockAppToggler

// Opt-in integration test: briefly hides/minimizes a running Chrome window and
// restores its state. Requires Accessibility permission and a Chrome window.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DOCKAPP_TEST_CHROME"] == "1"))
@MainActor
struct WindowActivationTests {
    enum Activation: CaseIterable {
        case chooser, dock, raiseWithWindowID
    }

    @Test(arguments: Activation.allCases, [false, true])
    func restoresChromeWindow(activation: Activation, minimized: Bool) async throws {
        _ = NSApplication.shared
        await settle()
        try #require(AXIsProcessTrusted())
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let wasHidden = app.isHidden
        var windows: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows
        ) == .success)
        let window = try #require((windows as? [AXUIElement])?.first)
        var minimizedValue: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success)
        let wasMinimized = try #require(minimizedValue as? Bool)
        let bounds = try #require(AccessibilityService.shared.listApplicationWindows(for: app).first(where: {
            CFEqual($0.window, window)
        })?.bounds)
        let cgWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        let windowID = try #require(cgWindows?.first(where: {
            guard ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  ($0[kCGWindowLayer as String] as? Int) == 0,
                  let cgBounds = $0[kCGWindowBounds as String] as? NSDictionary else { return false }
            return CGRect(dictionaryRepresentation: cgBounds) == bounds
        })?[kCGWindowNumber as String] as? CGWindowID)

        defer {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, wasMinimized as CFTypeRef)
            if wasHidden { app.hide() } else { app.unhide() }
            previousApp?.activate(options: [.activateIgnoringOtherApps])
            pumpRunLoop()
        }

        app.unhide()
        await settle()
        try #require(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFTypeRef) == .success)
        if !minimized { app.hide() }
        await settle()
        if !minimized { try #require(app.isHidden) }

        switch activation {
        case .chooser:
            AccessibilityService.shared.focusWindow(window, for: app)
        case .dock:
            AccessibilityService.shared.raiseWindowOnly(window, for: app)
        case .raiseWithWindowID:
            AccessibilityService.shared.raiseWindow(
                windowInfo: WindowInfo(window: window, name: "Activation test", cgWindowID: windowID), for: app
            )
        }

        await settle()
        #expect(!app.isHidden)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
        var restoredMinimized: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &restoredMinimized) == .success)
        #expect((restoredMinimized as? Bool) == false)
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        #expect(onScreen?.contains(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) == true)
    }

    private func settle() async {
        // AppKit refreshes running-app state on the run loop; yielding also lets
        // the service's delayed activation callbacks execute on the main queue.
        pumpRunLoop()
        try? await Task.sleep(for: .milliseconds(500))
        pumpRunLoop()
    }

    private func pumpRunLoop() {
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        timer.invalidate()
    }
}
