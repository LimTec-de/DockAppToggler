import AppKit
import ApplicationServices
import Testing
@testable import DockAppToggler

/// The chooser menu must always be exactly as tall as the rows it shows, and
/// its title and rows must stay attached to the top edge.
///
/// Regression: a reused chooser was sized for the unfiltered window list
/// while the view only shows windows of at least 200x200, and the view kept
/// its old height inside the resized window. Both left an empty row above
/// the title. The windows are never ordered on screen here.
@Suite(.serialized)
@MainActor
struct WindowChooserLayoutTests {
    private let anchor = CGPoint(x: 600, y: 40)

    private func finder() throws -> NSRunningApplication {
        _ = NSApplication.shared
        return try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    }

    private func appEntry(for app: NSRunningApplication) -> WindowInfo {
        WindowInfo(window: AXUIElementCreateApplication(app.processIdentifier), name: "App", isAppElement: true)
    }

    /// A row the chooser shows. The element is the app's, so state queries fail fast.
    private func window(_ name: String, id: CGWindowID, for app: NSRunningApplication) -> WindowInfo {
        WindowInfo(
            window: AXUIElementCreateApplication(app.processIdentifier),
            name: name,
            cgWindowID: id,
            size: CGSize(width: 800, height: 600)
        )
    }

    /// A window the chooser filters out (smaller than 200x200).
    private func tinyWindow(for app: NSRunningApplication) -> WindowInfo {
        WindowInfo(
            window: AXUIElementCreateApplication(app.processIdentifier),
            name: "Tiny palette",
            size: CGSize(width: 120, height: 80)
        )
    }

    private func expectConsistentLayout(_ controller: WindowChooserController, rows: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let height = Constants.UI.windowHeight(for: rows)
        let view = try #require(controller.chooserView, sourceLocation: sourceLocation)
        let host = try #require(view.superview, sourceLocation: sourceLocation)
        #expect(view.options.count == rows, sourceLocation: sourceLocation)
        #expect(controller.window?.frame.height == height, sourceLocation: sourceLocation)
        #expect(view.frame == host.bounds, sourceLocation: sourceLocation)
        #expect(view.frame.height == height, sourceLocation: sourceLocation)

        let layout = view.layoutSnapshot
        #expect(layout.title.maxY == height - Constants.UI.titlePadding, sourceLocation: sourceLocation)
        #expect(layout.rows.count == rows, sourceLocation: sourceLocation)
        for (index, row) in layout.rows.enumerated() {
            let expectedY = height - Constants.UI.titleHeight - CGFloat(index + 1) * Constants.UI.buttonSpacing - Constants.UI.verticalPadding
            #expect(row.minY == expectedY, "row \(index)", sourceLocation: sourceLocation)
            #expect(row.minY >= 0, "row \(index) is cut off at the bottom", sourceLocation: sourceLocation)
        }
    }

    @Test func reusedChooserForSameAppIgnoresFilteredWindowsInItsHeight() throws {
        let app = try finder()
        let controller = WindowChooserController(at: anchor, windows: [appEntry(for: app)], app: app, callback: { _, _ in })
        defer { controller.close() }
        try expectConsistentLayout(controller, rows: 1)

        controller.applyWindows([appEntry(for: app), tinyWindow(for: app)], for: app, at: anchor)

        try expectConsistentLayout(controller, rows: 1)
    }

    @Test func reusedChooserForOtherAppIgnoresFilteredWindowsInItsHeight() throws {
        let other = try finder()
        let app = NSRunningApplication.current
        let controller = WindowChooserController(at: anchor, windows: [appEntry(for: app)], app: app, callback: { _, _ in })
        defer { controller.close() }

        controller.applyWindows([appEntry(for: other), tinyWindow(for: other)], for: other, at: anchor)

        try expectConsistentLayout(controller, rows: 1)
    }

    @Test func rowsStayAttachedToTheTopWhenTheWindowListGrowsAndShrinks() throws {
        let app = try finder()
        let one = [window("Alpha", id: 9_000_001, for: app)]
        let three = one + [window("Beta", id: 9_000_002, for: app), window("Gamma", id: 9_000_003, for: app)]

        let controller = WindowChooserController(at: anchor, windows: one, app: app, callback: { _, _ in })
        defer { controller.close() }
        try expectConsistentLayout(controller, rows: 1)

        controller.applyWindows(three + [tinyWindow(for: app)], for: app, at: anchor)
        try expectConsistentLayout(controller, rows: 3)

        controller.applyWindows(Array(three.prefix(2)), for: app, at: anchor)
        try expectConsistentLayout(controller, rows: 2)

        // Same rows again, but the caller still passes a filtered-out window.
        controller.applyWindows(Array(three.prefix(2)) + [tinyWindow(for: app)], for: app, at: anchor)
        try expectConsistentLayout(controller, rows: 2)
    }

    @Test func refreshingARowListThroughTheViewKeepsWindowAndViewInSync() throws {
        let app = try finder()
        let two = [window("Alpha", id: 9_000_011, for: app), window("Beta", id: 9_000_012, for: app)]
        let controller = WindowChooserController(at: anchor, windows: two, app: app, callback: { _, _ in })
        defer { controller.close() }

        controller.chooserView?.updateWindows(two + [window("Gamma", id: 9_000_013, for: app), tinyWindow(for: app)])
        try expectConsistentLayout(controller, rows: 3)

        controller.chooserView?.updateWindows([two[0]])
        try expectConsistentLayout(controller, rows: 1)
    }
}
