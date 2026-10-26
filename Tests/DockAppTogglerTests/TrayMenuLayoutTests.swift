import AppKit
import Testing
@testable import DockAppToggler

struct TrayMenuLayoutTests {
    private let own = "com.limtec.dockapptoggler"
    private let boundary = CGRect(x: 600, y: 0, width: 8, height: 24)
    private let permanent = CGRect(x: 400, y: 0, width: 8, height: 24)

    private func item(_ bundle: String, x: CGFloat, width: CGFloat = 24) -> TrayMenuItem {
        TrayMenuItem(bundleIdentifier: bundle, identifier: nil, frame: CGRect(x: x, y: 0, width: width, height: 24))
    }

    @Test func collapseExpandAndEditingRespectAllThreeSections() {
        let layout = TrayMenuLayout(items: [item("visible", x: 700), item("hidden", x: 500), item("permanent", x: 300)],
                                   boundary: boundary, alwaysHiddenBoundary: permanent, ownBundle: own)
        #expect(layout.bundles(collapsed: true, editing: false) == ["visible"])
        #expect(layout.bundles(collapsed: false, editing: false) == ["visible", "hidden"])
        #expect(layout.bundles(collapsed: false, editing: true) == ["visible", "hidden", "permanent"])
    }

    @Test func disablingPermanentSectionMakesThoseIconsOrdinarilyHidden() {
        let layout = TrayMenuLayout(items: [item("permanent", x: 300)],
                                   boundary: boundary, alwaysHiddenBoundary: nil, ownBundle: own)
        #expect(layout.bundles(collapsed: false, editing: false) == ["permanent"])
        #expect(layout.bundles(collapsed: true, editing: false).isEmpty)
    }

    @Test func visibleSiblingKeepsEntireAppVisible() {
        let layout = TrayMenuLayout(items: [item("shared", x: 300), item("shared", x: 700)],
                                   boundary: boundary, alwaysHiddenBoundary: permanent, ownBundle: own)
        #expect(layout.bundles(collapsed: true, editing: false) == ["shared"])
    }

    @Test func systemControlsAndOurMarkersAreNeverHiddenApps() {
        let items = TrayMenuLayout.systemBundles.map { item($0, x: 100) } + [item(own, x: 100)]
        let layout = TrayMenuLayout(items: items, boundary: boundary, alwaysHiddenBoundary: permanent, ownBundle: own)
        #expect(layout.sections.isEmpty)
    }

    @Test func overflowCountsSystemIconsOwnMarkersAndAllSiblingWidths() {
        let layout = TrayMenuLayout(items: [item("visible", x: 700, width: 30), item("visible", x: 740, width: 30),
                                           item(own, x: 800, width: 28), item("com.apple.MenuBarAgent", x: 900, width: 100)],
                                   boundary: boundary, alwaysHiddenBoundary: nil, ownBundle: own)
        #expect(!layout.needsOverflow(bundles: ["visible"], safeWidth: 236, ownBundle: own))
        #expect(layout.needsOverflow(bundles: ["visible"], safeWidth: 235, ownBundle: own))
        #expect(!layout.needsOverflow(bundles: ["visible"], safeWidth: nil, ownBundle: own))
    }

    @Test func permanentIconsDoNotConsumeExpandedNotchBudget() {
        let layout = TrayMenuLayout(items: [item("visible", x: 700), item("permanent", x: 200, width: 300)],
                                   boundary: boundary, alwaysHiddenBoundary: permanent, ownBundle: own)
        let bundles = layout.bundles(collapsed: false, editing: false)
        #expect(!layout.needsOverflow(bundles: bundles, safeWidth: 100, ownBundle: own))
        #expect(layout.needsOverflow(bundles: layout.bundles(collapsed: false, editing: true), safeWidth: 100, ownBundle: own))
    }
}
