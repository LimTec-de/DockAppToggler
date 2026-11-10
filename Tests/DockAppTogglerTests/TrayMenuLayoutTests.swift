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

    private func layout(_ items: [TrayMenuItem], _ rule: TrayMenuLayout.AlwaysHiddenRule) -> TrayMenuLayout {
        var layout = TrayMenuLayout()
        layout.observe(items, boundary: boundary, alwaysHidden: rule, ownBundle: own)
        return layout
    }

    private var arranged: TrayMenuLayout {
        layout([item("visible", x: 700), item("hidden", x: 500), item("permanent", x: 300)], .arranged(permanent))
    }

    @Test func collapseExpandAndEditingRespectAllThreeSections() {
        #expect(arranged.bundles(collapsed: true, editing: false, alwaysHidden: true) == ["visible"])
        #expect(arranged.bundles(collapsed: false, editing: false, alwaysHidden: true) == ["visible", "hidden"])
        #expect(arranged.bundles(collapsed: false, editing: true, alwaysHidden: true) == ["visible", "hidden", "permanent"])
    }

    @Test func disablingPermanentSectionMakesThoseIconsOrdinarilyHidden() {
        #expect(arranged.bundles(collapsed: false, editing: false, alwaysHidden: false) == ["visible", "hidden", "permanent"])
        #expect(arranged.bundles(collapsed: true, editing: false, alwaysHidden: false) == ["visible"])
        var layout = arranged
        layout.observe([item("permanent", x: 300)], boundary: boundary, alwaysHidden: .disabled, ownBundle: own)
        #expect(layout.sections["permanent"] == .hidden)
    }

    @Test func visibleSiblingKeepsEntireAppVisible() {
        let layout = layout([item("shared", x: 300), item("shared", x: 700)], .arranged(permanent))
        #expect(layout.bundles(collapsed: true, editing: false, alwaysHidden: true) == ["shared"])
    }

    @Test func systemControlsAndOurMarkersAreNeverHiddenApps() {
        let items = TrayMenuLayout.systemBundles.map { item($0, x: 100) } + [item(own, x: 100)]
        #expect(layout(items, .arranged(permanent)).sections.isEmpty)
    }

    /// Hidden icons are not rendered, so an observation of the collapsed bar
    /// must not forget, re-sort or drop them.
    @Test func iconsThatAreNotRenderedKeepTheirSection() {
        var layout = arranged
        layout.observe([item("visible", x: 620)], boundary: boundary, alwaysHidden: .kept, ownBundle: own)
        #expect(layout.sections == ["visible": .visible, "hidden": .hidden, "permanent": .alwaysHidden])
        #expect(layout.bundles(collapsed: false, editing: true, alwaysHidden: true) == ["visible", "hidden", "permanent"])
    }

    @Test func draggingAcrossTheDividerMovesAnIconBetweenVisibleAndHidden() {
        var layout = arranged
        layout.observe([item("visible", x: 500), item("hidden", x: 700)], boundary: boundary, alwaysHidden: .kept, ownBundle: own)
        #expect(layout.sections["visible"] == .hidden)
        #expect(layout.sections["hidden"] == .visible)
    }

    /// macOS inserts the icons of newly launched apps at the far left. Outside
    /// editing mode that never makes them permanently hidden.
    @Test func onlyEditingAssignsTheAlwaysHiddenSection() {
        var layout = arranged
        layout.observe([item("new", x: 10), item("permanent", x: 20)], boundary: boundary, alwaysHidden: .kept, ownBundle: own)
        #expect(layout.sections["new"] == .hidden)
        #expect(layout.sections["permanent"] == .alwaysHidden)
        layout.observe([item("new", x: 10)], boundary: boundary, alwaysHidden: .arranged(permanent), ownBundle: own)
        #expect(layout.sections["new"] == .alwaysHidden)
    }

    /// macOS re-inserts icons the user never dragged at the far left whenever
    /// their app launches. That must not move a known app to another section.
    @Test func positionThatIsNotTheUsersChoiceOnlyPlacesUnknownApps() {
        var layout = arranged
        layout.observe([item("visible", x: 10), item("fresh", x: 20)], boundary: boundary, alwaysHidden: .kept, ownBundle: own) { _, _ in false }
        #expect(layout.sections["visible"] == .visible)
        #expect(layout.sections["fresh"] == .hidden)
        #expect(layout.bundles(collapsed: true, editing: false, alwaysHidden: true) == ["visible"])
    }

    @Test func overflowCountsSystemIconsOwnMarkersAndAllSiblingWidths() {
        let layout = layout([item("visible", x: 700, width: 30), item("visible", x: 740, width: 30),
                             item(own, x: 800, width: 28), item("com.apple.MenuBarAgent", x: 900, width: 100)], .disabled)
        #expect(!layout.needsOverflow(bundles: ["visible"], safeWidth: 236))
        #expect(layout.needsOverflow(bundles: ["visible"], safeWidth: 235))
        #expect(!layout.needsOverflow(bundles: ["visible"], safeWidth: nil))
    }

    @Test func permanentIconsDoNotConsumeExpandedNotchBudget() {
        let layout = layout([item("visible", x: 700), item("permanent", x: 200, width: 300)], .arranged(permanent))
        let bundles = layout.bundles(collapsed: false, editing: false, alwaysHidden: true)
        #expect(!layout.needsOverflow(bundles: bundles, safeWidth: 100))
        #expect(layout.needsOverflow(bundles: layout.bundles(collapsed: false, editing: true, alwaysHidden: true), safeWidth: 100))
    }

    @Test func arrangementSurvivesRestartsAndIgnoresCorruptStorage() {
        #expect(TrayMenuLayout(propertyList: arranged.propertyList) == arranged)
        #expect(TrayMenuLayout(propertyList: ["apps": ["broken": [9.0, 1, 2], "short": [1.0]]]) == TrayMenuLayout())
        #expect(TrayMenuLayout(propertyList: "garbage") == TrayMenuLayout())
    }
}
