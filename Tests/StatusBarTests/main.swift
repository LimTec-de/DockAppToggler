import AppKit

// Run only through test_status_bar.py. It installs this binary under several
// bundle identifiers, because macOS 27 attributes status items to a bundle only
// for apps in /Applications, and asks it to launch or quit the fixture apps.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let statusBar = NSStatusBar.system
setvbuf(stdout, nil, _IOLBF, 0)

if let role = CommandLine.arguments.firstIndex(of: "--fixture") {
    let item = statusBar.statusItem(withLength: 24)
    item.button?.title = CommandLine.arguments[role + 1]
    application.run()
    exit(0)
}

let own = Bundle.main.bundleIdentifier!
// The menu bar remembers icon positions per bundle identifier, so every run
// uses fresh identifiers: macOS then inserts each new icon at the far left.
let run = own.split(separator: ".").last!
func fixture(_ role: String) -> String { "com.limtec.dockapptoggler.tray-test.\(role).\(run)" }
let suite = "\(own).layout"
let defaults = UserDefaults(suiteName: suite)!
let boundary = statusBar.statusItem(withLength: 20)
boundary.button?.title = "T"
boundary.button?.setAccessibilityIdentifier("test-boundary")
var permanent: NSStatusItem?

@MainActor func makeController() -> NativeTrayController {
    NativeTrayController(ownBundle: own, boundaryIdentifier: "test-boundary", alwaysHiddenIdentifier: "test-permanent",
                         defaults: defaults, changed: {})
}
var controller = makeController()

@MainActor func finish(_ failure: String?) -> Never {
    controller.stop()
    defaults.removePersistentDomain(forName: suite)
    if let failure { FileHandle.standardError.write(Data("FAILED: \(failure)\n".utf8)) }
    exit(failure == nil ? 0 : 1)
}

@MainActor func snapshot() async -> TrayMenuSnapshot {
    do { return try await TrayMenuInventory.snapshot(ownBundle: own) } catch { finish(error.localizedDescription) }
}

/// Waits until the menu bar renders what `condition` asks for and keeps doing so.
@MainActor func expect(_ what: String, within timeout: Duration = .seconds(8), _ condition: @MainActor (Set<String>) -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    var stableSince: ContinuousClock.Instant?
    while ContinuousClock.now < deadline + .milliseconds(1500) {
        if condition(await snapshot().renderedBundles) {
            let since = stableSince ?? ContinuousClock.now
            stableSince = since
            if ContinuousClock.now - since >= .milliseconds(1200) {
                print("ok: \(what)")
                return
            }
        } else {
            stableSince = nil
            if ContinuousClock.now >= deadline { break }
        }
        try? await Task.sleep(for: .milliseconds(150))
    }
    finish("\(what) — rendered: \(await snapshot().renderedBundles.filter { $0.contains("tray-test") }.sorted()), "
        + "collapsed: \(controller.isCollapsed), message: \(controller.errorMessage ?? "none")")
}

@MainActor func require(_ condition: Bool, _ what: String) {
    if !condition { finish("\(what) — collapsed: \(controller.isCollapsed), message: \(controller.errorMessage ?? "none")") }
}

@MainActor func set(collapsed: Bool, editing: Bool = false, alwaysHidden: Bool = true) {
    controller.set(collapsed: collapsed, editing: editing, alwaysHidden: alwaysHidden)
}

let visible = fixture("visible"), hidden = fixture("hidden"), permanentApp = fixture("permanent")
let new = fixture("new"), outside = fixture("outside"), late = fixture("late")

@MainActor func relaunch(_ bundle: String) async {
    let previous = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
    print("REQUEST relaunch \(bundle.split(separator: ".").dropLast().last!)")
    let deadline = ContinuousClock.now + .seconds(10)
    while NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first.map({ $0.processIdentifier == previous }) ?? true {
        require(ContinuousClock.now < deadline, "\(bundle) was not relaunched")
        try? await Task.sleep(for: .milliseconds(50))
    }
}

/// The copy of this controller outside /Applications: macOS hides its own divider
/// together with the hidden icons, which must end the restriction.
@MainActor func runOutsideApplications() async {
    print("REQUEST launch late")
    await expect("fixture left of the divider is on screen") { $0.contains(late) }
    set(collapsed: true, alwaysHidden: false)
    await expect("restriction that hides our own divider is released") { $0.contains(own) && $0.contains(late) }
    require(!controller.isCollapsed && controller.errorMessage != nil, "Hidden divider was not reported")
    set(collapsed: true, alwaysHidden: false)
    for _ in 0..<12 {
        try? await Task.sleep(for: .milliseconds(150))
        require(await snapshot().renderedBundles.contains(own), "A later request hid the divider again")
    }
    require(!controller.isCollapsed && controller.errorMessage != nil, "Hidden divider was not reported again")
    print("PASS: own icons outside /Applications")
    finish(nil)
}

@MainActor func run() async {
    // macOS inserts new icons at the far left, so launch order defines the sections:
    // permanent | marker | hidden | divider | visible (already running).
    print("REQUEST launch hidden")
    await expect("hidden fixture is on screen") { $0.contains(hidden) && $0.contains(visible) }
    let marker = statusBar.statusItem(withLength: 20)
    marker.button?.title = "P"
    marker.button?.setAccessibilityIdentifier("test-permanent")
    permanent = marker
    try? await Task.sleep(for: .milliseconds(500))
    print("REQUEST launch permanent")
    await expect("permanent fixture is on screen") { $0.contains(permanentApp) }
    guard let bar = await snapshot().bar(containing: "test-boundary", of: own) else { finish("Divider is not rendered") }
    func x(_ bundle: String, _ identifier: String? = nil) -> CGFloat {
        bar.first { $0.bundleIdentifier == bundle && $0.identifier == identifier }?.frame.midX ?? .nan
    }
    require(x(permanentApp) < x(own, "test-permanent") && x(own, "test-permanent") < x(hidden)
        && x(hidden) < x(own, "test-boundary") && x(own, "test-boundary") < x(visible), "Fixtures are not in section order")

    let collapsed: @MainActor (Set<String>) -> Bool = {
        $0.contains(own) && $0.contains(visible) && !$0.contains(hidden) && !$0.contains(permanentApp)
    }
    let expanded: @MainActor (Set<String>) -> Bool = {
        $0.contains(own) && $0.contains(visible) && $0.contains(hidden) && !$0.contains(permanentApp)
    }
    set(collapsed: true)
    await expect("collapsing hides everything left of the divider but neither divider nor visible icon", collapsed)
    require(controller.isCollapsed && controller.errorMessage == nil, "Collapse was not reported")
    set(collapsed: false)
    await expect("without an editing session no icon is always hidden, wherever the marker sits") {
        Set([own, visible, hidden, permanentApp]).isSubset(of: $0)
    }
    controller.stop()
    set(collapsed: false, editing: true)
    await expect("editing shows every icon") { Set([own, visible, hidden, permanentApp]).isSubset(of: $0) }
    controller.stop()
    set(collapsed: true)
    await expect("collapsed after arranging the always-hidden section", collapsed)
    set(collapsed: false)
    await expect("expanding shows the hidden section only", expanded)
    for _ in 0..<10 {
        set(collapsed: true)
        set(collapsed: false)
    }
    await expect("the last of many rapid toggles wins", expanded)
    require(!controller.isCollapsed && controller.errorMessage == nil, "A stale request replaced the last expand")
    set(collapsed: true)
    await expect("collapsed again", collapsed)

    print("REQUEST launch new")
    await expect("an app launched while collapsed shows its icon at first", within: .seconds(10)) { $0.contains(new) }
    await expect("its icon left of the divider then joins the hidden section", within: .seconds(25)) {
        !$0.contains(new) && collapsed($0)
    }
    set(collapsed: false)
    await expect("and is not always hidden without the user's doing") { $0.contains(new) && expanded($0) }

    // Bar is now: new | permanent | marker | hidden | divider | visible.
    controller.stop()
    set(collapsed: false, editing: true)
    await expect("editing shows every icon") { Set([own, visible, hidden, permanentApp, new]).isSubset(of: $0) }
    controller.stop()
    set(collapsed: true)
    await expect("collapsed after editing") { !$0.contains(new) && collapsed($0) }
    set(collapsed: false)
    await expect("editing put the icon left of the marker into the always-hidden section") { !$0.contains(new) && expanded($0) }
    set(collapsed: true)
    await expect("collapsed before relaunches") { !$0.contains(new) && collapsed($0) }

    // macOS inserts the icon of a relaunched app at the far left again unless
    // the user once dragged it. Neither app may change its section over that.
    await relaunch(hidden)
    for _ in 0..<40 {
        let rendered = await snapshot().renderedBundles
        require(collapsed(rendered), "A relaunched hidden app showed its icon or changed the bar: \(rendered.filter { $0.contains("tray-test") }.sorted())")
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("ok: a relaunched hidden app stays hidden")
    await relaunch(visible)
    await expect("a relaunched visible app keeps its icon", within: .seconds(12), collapsed)
    try? await Task.sleep(for: .seconds(4))
    await expect("also after its new position was read", collapsed)
    if let bar = await snapshot().bar(containing: "test-boundary", of: own) {
        print("note: order after relaunches: " + bar.filter { $0.bundleIdentifier.contains("tray-test") }.sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.identifier ?? String($0.bundleIdentifier.split(separator: ".").dropLast().last!) }.joined(separator: " "))
    }
    set(collapsed: false)
    await expect("and the relaunched hidden app is still only hidden") { !$0.contains(new) && expanded($0) }

    print("REQUEST launch outside")
    await expect("an app macOS cannot allow-list suspends hiding instead of vanishing", within: .seconds(15)) {
        $0.contains(outside) && $0.contains(permanentApp) && $0.contains(hidden)
    }
    require(controller.errorMessage != nil, "Suspended hiding was not reported")
    print("REQUEST quit outside")
    await expect("hiding resumes once that app quits", within: .seconds(15), expanded)
    require(controller.errorMessage == nil, "Report was not cleared")

    controller.stop()
    await expect("stopping shows every icon") { Set([own, visible, hidden, permanentApp, new]).isSubset(of: $0) }
    controller = makeController()
    set(collapsed: true)
    await expect("a new instance restores the stored arrangement", within: .seconds(3)) { !$0.contains(new) && collapsed($0) }
    controller.stop()
    print("PASS: sections, toggles, launches, editing, unplaceable apps, persistence")
    finish(nil)
}

Task { @MainActor in
    try? await Task.sleep(for: .seconds(1))
    if !(await snapshot().isReadable) { finish("The menu bar cannot be read. Is the screen locked?") }
    if CommandLine.arguments.contains("--outside-applications") { await runOutsideApplications() } else { await run() }
}
application.run()
