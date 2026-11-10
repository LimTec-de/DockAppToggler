import AppKit
import ApplicationServices
import Testing
@testable import DockAppToggler

/// A preview whose asynchronous preparation is still running when the hover
/// ends must not appear afterwards: nothing would ever close it again.
@Suite(.serialized)
@MainActor
struct WindowPreviewDismissalTests {
    private func visiblePreviewPanels() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0 is NSPanel && $0.isVisible }
    }

    @Test func previewRequestedBeforeDismissalNeverAppears() async throws {
        _ = NSApplication.shared
        // Volatile: enables previews for this process only, nothing is persisted.
        UserDefaults.standard.setVolatileDomain(["WindowPreviewsEnabled": true], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }

        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let windowInfo = WindowInfo(
            window: AXUIElementCreateApplication(finder.processIdentifier),
            name: "DockAppToggler preview race probe"
        )
        let preview = WindowThumbnailView(
            targetApp: finder,
            dockIconCenter: CGPoint(x: 600, y: 40),
            options: [windowInfo],
            windowChooser: nil
        )

        // Hover a row, then leave before the preview could be prepared.
        preview.showThumbnail(for: windowInfo, withTimer: false, skipDebounce: true)
        preview.hideThumbnail(removePanel: true)
        preview.cleanup()
        // The main thread is routinely busy for this long while a chooser is
        // built. It lets the delayed fade-out (0.1 s) of the dismissal come
        // due before the preparation finishes, so that fade-out cannot mask a
        // preview that shows up late.
        usleep(150_000)

        try await Task.sleep(nanoseconds: 900_000_000)
        let leftovers = visiblePreviewPanels()
        leftovers.forEach { $0.orderOut(nil) }
        #expect(leftovers.isEmpty)
    }
}
