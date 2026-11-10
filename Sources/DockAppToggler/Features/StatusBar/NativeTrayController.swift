import AppKit
import ApplicationServices
@preconcurrency import MenuBarVisibility

/// macOS 27 no longer gives each status item a WindowServer window or honors
/// oversized spacers. Visibility assertions replace that geometry-based mechanism.
///
/// An assertion is an allow list, so everything it omits disappears. The
/// controller therefore only ever omits apps the user demonstrably placed in a
/// hidden section, verifies the result against what the menu bar renders, and
/// releases the restriction whenever it would hide something it must not.
@MainActor
final class NativeTrayController {
    private struct State {
        var collapsed: Bool
        var editing: Bool
        var alwaysHidden: Bool
    }

    static let storageKey = "TrayIconNativeLayoutV1"
    /// Icons animate in and out; positions are only trusted after this pause.
    private static let settleTime: Duration = .milliseconds(1200)
    private static let presentationChecks: [Duration] = [.zero, .milliseconds(1300), .milliseconds(2600)]
    /// Apps create their status items at their own pace after launching.
    private static let launchChecks: [Duration] = [.milliseconds(300), .milliseconds(1500), .milliseconds(3500), .seconds(8), .seconds(20)]

    private let ownBundle: String
    private let boundaryIdentifier: String
    private let alwaysHiddenIdentifier: String
    private let defaults: UserDefaults
    private let overflowArea: () -> (screen: NSScreen, width: CGFloat)?
    private let changed: () -> Void
    private let clock = ContinuousClock()
    private let overflow = TrayOverflowPanel()

    private var layout: TrayMenuLayout
    private var state: State?
    /// An editing session whose arrangement has not been read back yet.
    private var arrangementEdited = false
    /// Without a stored layout, the arrangement made with earlier versions is
    /// adopted, including its always-hidden section, until icons are first hidden.
    private var adoptsArrangement: Bool
    private var assertion: MenuBarVisibility?
    private var appliedBundles: Set<String> = []
    private var overflowBundles: [String]?
    private var settledAt: ContinuousClock.Instant
    /// Every app seen running. Apps without a known section stay allowed, so a
    /// new or not yet classified icon is shown instead of silently dropped.
    private var seenBundles: Set<String> = []
    /// Apps (by process) whose icons macOS cannot attribute to a bundle and
    /// which therefore vanish under every restriction.
    private var unplaceable: [String: pid_t] = [:]
    /// Where each app's icons sat when last seen, and in which process: only a
    /// change within one process is the user dragging an icon or the divider.
    private var sightings: [String: (pid: pid_t?, section: TrayMenuSection)] = [:]
    private var placeableProcesses: Set<pid_t> = []
    private var ownItemsUnplaceable = false
    private var missingOwnItems = 0
    private var unreadableBars = 0
    private var repairs = 0
    private var deadlines: [ContinuousClock.Instant] = []
    private var runner: Task<Void, Never>?
    private var generation = 0
    private var runningAppsObservation: NSKeyValueObservation?

    private(set) var isCollapsed = false
    private(set) var errorMessage: String?

    init(ownBundle: String, boundaryIdentifier: String, alwaysHiddenIdentifier: String,
         defaults: UserDefaults = .standard,
         overflowArea: @escaping () -> (screen: NSScreen, width: CGFloat)? = {
             NSScreen.screens.compactMap { screen -> (screen: NSScreen, width: CGFloat)? in
                 guard screen.safeAreaInsets.top > 0, let area = screen.auxiliaryTopRightArea else { return nil }
                 return (screen, area.width)
             }.min { $0.width < $1.width }
         }, changed: @escaping () -> Void) {
        self.ownBundle = ownBundle
        self.boundaryIdentifier = boundaryIdentifier
        self.alwaysHiddenIdentifier = alwaysHiddenIdentifier
        self.defaults = defaults
        self.overflowArea = overflowArea
        self.changed = changed
        layout = TrayMenuLayout(propertyList: defaults.object(forKey: Self.storageKey))
        adoptsArrangement = layout.entries.isEmpty
        settledAt = clock.now
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.runningAppsChanged() }
        }
    }

    // MARK: - Requests

    func set(collapsed: Bool, editing: Bool, alwaysHidden: Bool) {
        state = State(collapsed: collapsed, editing: editing, alwaysHidden: alwaysHidden)
        if editing { arrangementEdited = true }
        isCollapsed = collapsed
        errorMessage = nil
        missingOwnItems = 0
        repairs = 0
        closeOverflow()
        guard !ownItemsUnplaceable else {
            fail(TrayMenuError.message(ownItemsMessage))
            return
        }
        changed()
        schedule(Self.presentationChecks)
    }

    /// Re-reads the arrangement, e.g. after the divider was moved.
    func refresh() {
        guard state != nil else { return }
        schedule(Self.presentationChecks)
    }

    func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        deadlines = []
        release()
        state = nil
        isCollapsed = false
        errorMessage = nil
        closeOverflow()
    }

    private func runningAppsChanged() {
        guard state != nil else { return }
        repairs = 0
        schedule(Self.launchChecks)
    }

    // MARK: - Scheduling

    /// Each check re-reads the bar and corrects the presentation. Checks from
    /// several triggers share one queue, so a click never cancels the late
    /// checks that follow an app launch.
    private func schedule(_ offsets: [Duration]) {
        let now = clock.now
        for deadline in offsets.map({ now + $0 }) {
            let isDuplicate = deadlines.contains { $0 - deadline < .milliseconds(250) && deadline - $0 < .milliseconds(250) }
            if !isDuplicate { deadlines.append(deadline) }
        }
        deadlines.sort()
        generation += 1
        let request = generation
        runner?.cancel()
        runner = Task { [weak self] in
            while let next = self?.nextDeadline(for: request) {
                do {
                    try await ContinuousClock().sleep(until: next)
                    try await self?.check(request)
                } catch is CancellationError {
                    return
                } catch {
                    self?.fail(error, request: request)
                    return
                }
            }
        }
    }

    private func nextDeadline(for request: Int) -> ContinuousClock.Instant? {
        request == generation ? deadlines.first : nil
    }

    private func ensureCurrent(_ request: Int) throws {
        guard request == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private func check(_ request: Int) async throws {
        try ensureCurrent(request)
        let now = clock.now
        deadlines.removeAll { $0 <= now }
        guard let state else { return }
        let apps = runningApps()
        seenBundles.formUnion(apps.keys)
        if now >= settledAt {
            let snapshot = try await TrayMenuInventory.snapshot(ownBundle: ownBundle)
            try ensureCurrent(request)
            try read(snapshot, state: state, apps: apps)
            if assertion != nil, snapshot.isReadable {
                try await verify(snapshot, apps: apps, request: request)
            }
        }
        try await present(state, apps: apps, request: request)
        if unreadableBars >= Self.presentationChecks.count, layout.entries.isEmpty {
            errorMessage = "Die Position des Menüleisten-Trenners konnte nicht gelesen werden."
        }
        changed()
    }

    private func runningApps() -> [String: NSRunningApplication] {
        var apps: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundle = app.bundleIdentifier { apps[bundle] = app }
        }
        return apps
    }

    // MARK: - Reading the bar

    private func read(_ snapshot: TrayMenuSnapshot, state: State, apps: [String: NSRunningApplication]) throws {
        func marker(_ identifier: String, in bar: [TrayMenuItem]) -> TrayMenuItem? {
            bar.first { $0.bundleIdentifier == ownBundle && $0.identifier == identifier }
        }
        guard let bar = snapshot.bar(containing: boundaryIdentifier, of: ownBundle),
              let boundary = marker(boundaryIdentifier, in: bar) else {
            if assertion != nil, snapshot.isReadable, !snapshot.renderedBundles.contains(ownBundle) {
                // Other icons are rendered, ours are not: the restriction hides
                // the divider itself, and nobody could ever expand again. Where
                // the cause is known, do not leave the user waiting for it.
                let isExpected = !Self.isAttributable(Bundle.main.bundleURL)
                missingOwnItems += 1
                if missingOwnItems >= (isExpected ? 1 : 3) {
                    ownItemsUnplaceable = isExpected
                    throw TrayMenuError.message(ownItemsMessage)
                }
                deadlines.append(clock.now + Self.settleTime)
                deadlines.sort()
            } else if assertion == nil {
                unreadableBars += 1
            }
            return
        }
        missingOwnItems = 0
        unreadableBars = 0
        let rule: TrayMenuLayout.AlwaysHiddenRule
        let permanent = marker(alwaysHiddenIdentifier, in: bar)
        // An editing session and the first run take the bar as it is shown.
        // Otherwise only the divider separates sections, and nothing enters
        // the always-hidden one.
        let arranged = state.editing || arrangementEdited || adoptsArrangement
        if let permanent, arranged, state.editing || arrangementEdited || state.alwaysHidden {
            rule = .arranged(permanent.frame)
        } else {
            rule = state.alwaysHidden || state.editing || arrangementEdited ? .kept : .disabled
        }
        if !state.editing { arrangementEdited = false }
        let previous = layout
        layout.observe(bar, boundary: boundary.frame, alwaysHidden: rule, ownBundle: ownBundle) { bundle, section in
            let pid = apps[bundle]?.processIdentifier
            let last = sightings[bundle]
            sightings[bundle] = (pid, section)
            guard !arranged else { return true }
            guard let last else { return false }
            return last.pid == pid && last.section != section
        }
        if layout != previous {
            defaults.set(layout.propertyList, forKey: Self.storageKey)
        }
    }

    /// Compares an active restriction with what the menu bar renders.
    private func verify(_ snapshot: TrayMenuSnapshot, apps: [String: NSRunningApplication], request: Int) async throws {
        let rendered = snapshot.renderedBundles
        let fixed = TrayMenuLayout.systemBundles.union([ownBundle])
        let unexpected = rendered.subtracting(appliedBundles).subtracting(fixed).filter { !$0.hasPrefix("com.apple.") }
        if !unexpected.isEmpty, repairs < 1 {
            // The menu bar lost our restriction, e.g. because it restarted.
            repairs += 1
            appliedBundles = []
        }
        var checked = 0
        for bundle in appliedBundles.subtracting(rendered).subtracting(fixed).sorted() {
            guard checked < 8, let app = apps[bundle], unplaceable[bundle] != app.processIdentifier,
                  !placeableProcesses.contains(app.processIdentifier),
                  !Self.isAttributable(app.bundleURL) else { continue }
            checked += 1
            let pid = app.processIdentifier
            let claims = await TrayMenuInventory.claimsStatusItems(pid: pid)
            try ensureCurrent(request)
            if claims {
                unplaceable[bundle] = pid
            } else if (app.launchDate?.timeIntervalSinceNow ?? -.infinity) < -30 {
                // Long enough running to have created its icons by now.
                placeableProcesses.insert(pid)
            }
        }
    }

    /// The menu bar only attributes status items to a bundle identifier for
    /// apps installed in an Applications folder of the system. Everything else
    /// matches no allow list and is hidden by any restriction.
    private static func isAttributable(_ url: URL?) -> Bool {
        guard let path = url?.resolvingSymlinksInPath().path else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix("/System/")
    }

    private var ownItemsMessage: String {
        let cause = Self.isAttributable(Bundle.main.bundleURL) ? ""
            : "Das passiert, wenn die App nicht im Ordner „Programme“ liegt (aktuell: \(Bundle.main.bundleURL.path)). "
        return "macOS blendet auch die Symbole von DockAppToggler aus, sobald andere Menüleisten-Icons versteckt werden. "
            + cause + "Das Verstecken ist deshalb pausiert; alle Icons bleiben sichtbar."
    }

    // MARK: - Presentation

    private func present(_ state: State, apps: [String: NSRunningApplication], request: Int) async throws {
        let eligible = layout.bundles(collapsed: state.collapsed, editing: state.editing, alwaysHidden: state.alwaysHidden)
        let known = Set(layout.entries.keys)
        let unknown = seenBundles.subtracting(known)
        let blockers = unplaceable.filter { bundle, pid in
            apps[bundle]?.processIdentifier == pid && (unknown.contains(bundle) || eligible.contains(bundle))
        }.keys.sorted()
        let area = overflowArea()
        let needsOverflow = layout.needsOverflow(bundles: eligible, safeWidth: area?.width)

        guard blockers.isEmpty, needsOverflow || eligible.count < known.count else {
            // Nothing to hide, or hiding would take a wanted icon with it.
            release()
            closeOverflow()
            isCollapsed = state.collapsed && blockers.isEmpty
            errorMessage = blockers.isEmpty ? nil : blockerMessage(blockers.map { apps[$0]?.localizedName ?? $0 })
            return
        }
        isCollapsed = state.collapsed
        errorMessage = nil
        // System-owned apps complement the system-item identifiers; this keeps
        // Spotlight, input sources and Notification Center out of the hidden zones.
        let allowed = Set(needsOverflow ? [] : eligible).union(unknown).union(TrayMenuLayout.systemBundles).union([ownBundle])
        if assertion == nil || allowed != appliedBundles {
            try await apply(allowed, request: request)
        }
        if needsOverflow, let area {
            if overflowBundles != eligible {
                try overflow.show(bundles: eligible, on: area.screen) { [weak self] bundle in
                    self?.openMenu(for: bundle)
                }
                overflowBundles = eligible
            }
        } else {
            closeOverflow()
        }
    }

    private func blockerMessage(_ names: [String]) -> String {
        "\(names.joined(separator: ", ")) liegt nicht im Ordner „Programme“. macOS kann die Symbole solcher Apps nicht gezielt einblenden; "
            + "sie würden mit den versteckten Icons verschwinden. Solange die App läuft, bleiben deshalb alle Menüleisten-Icons sichtbar."
    }

    private func apply(_ allowed: Set<String>, request: Int) async throws {
        let handle: MenuBarVisibility = try await withCheckedThrowingContinuation { continuation in
            MenuBarVisibility.activateAllowingBundles(allowed.sorted()) { handle, error in
                if let handle { continuation.resume(returning: handle) }
                else { continuation.resume(throwing: error ?? TrayMenuError.message("Die Menüleistensteuerung konnte nicht aktiviert werden.")) }
            }
        }
        guard request == generation, !Task.isCancelled else {
            handle.invalidate()
            throw CancellationError()
        }
        // Activate before invalidating: concurrent assertions add up, so the
        // bar never passes through an unrestricted state in between.
        let previous = assertion
        assertion = handle
        appliedBundles = allowed
        adoptsArrangement = false
        previous?.invalidate()
        settledAt = clock.now + Self.settleTime
    }

    private func release() {
        guard let assertion else { return }
        assertion.invalidate()
        self.assertion = nil
        appliedBundles = []
        settledAt = clock.now + Self.settleTime
    }

    private func closeOverflow() {
        overflow.close()
        overflowBundles = nil
    }

    private func openMenu(for bundle: String) {
        generation += 1
        let request = generation
        runner?.cancel()
        runner = Task { [weak self] in
            guard let self else { return }
            do {
                // While the strip is open, expose only the selected app beside the
                // system controls, so its original menu has a reachable anchor.
                if layout.needsOverflow(bundles: [bundle], safeWidth: overflowArea()?.width) {
                    throw TrayMenuError.message("Für die Icons dieser App ist rechts neben der Notch zu wenig Platz. Bitte reduziere die sichtbaren System-Icons.")
                }
                try await apply(Set([bundle]).union(TrayMenuLayout.systemBundles).union([ownBundle]), request: request)
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await TrayMenuInventory.pressFirstItem(of: bundle)
            } catch is CancellationError {
            } catch {
                guard request == generation else { return }
                errorMessage = error.localizedDescription
                changed()
            }
        }
    }

    /// Fails open: a problem must never leave icons hidden.
    private func fail(_ error: Error, request: Int? = nil) {
        if let request, request != generation { return }
        stop()
        errorMessage = error.localizedDescription
        Logger.error(error.localizedDescription)
        changed()
    }

    isolated deinit {
        runner?.cancel()
        runningAppsObservation?.invalidate()
        assertion?.invalidate()
        overflow.close()
    }
}
