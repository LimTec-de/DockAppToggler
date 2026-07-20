import AppKit
import Sparkle
import Cocoa
import CoreGraphics

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private weak var updaterController: SPUStandardUpdaterController?

    private static let toggleAutosaveName = "dockapptoggler_app_icon_v2"
    private static let separatorAutosaveName = "dockapptoggler_hiddenbar_separate_v4"
    private static let boundaryAutosaveName = "dockapptoggler_hiddenbar_boundary_v2"
    private static let alwaysHiddenSeparatorAutosaveName = "dockapptoggler_hiddenbar_always_hidden_v1"
    private static let statusIconImageLength: CGFloat = 18
    private static let boundaryIconImageLength: CGFloat = 8
    private static let toggleStatusItemLength: CGFloat = 28
    private static let boundaryStatusItemLength: CGFloat = 8

    private var trayLimitSeparatorItem: NSStatusItem?
    private var trayBoundarySeparatorItem: NSStatusItem?
    private var alwaysHiddenSeparatorItem: NSStatusItem?
    private let trayLimitNormalLength: CGFloat = 20
    private var alwaysHiddenEditLength: CGFloat { Self.boundaryStatusItemLength }
    private var trayLimitCollapsedLength: CGFloat = 2_000
    private var trayLimitReapplyTask: Task<Void, Never>?
    private var trayToggleMoveRecalcTask: Task<Void, Never>?
    private var trayLimitCollapseRetryCount = 0
    private var isApplyingInternalTrayPositionChange = false
    private var isEditingAlwaysHiddenTraySection = false
    private var restoreCollapseAfterAlwaysHiddenEditing = false

    private var settingsWindowController: SettingsWindowController?

    private var statusMenu: NSMenu?
    private var statusMenuPreviousAppAppearance: NSAppearance?
    private var statusMenuPreviousButtonAppearance: NSAppearance?

    private var visibilityObservation: NSKeyValueObservation?
    private var screenObserver: Any?
    private nonisolated(unsafe) var workspaceWakeObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var tooltipTargetRefreshObserver: NSObjectProtocol?
    private nonisolated(unsafe) var userDefaultsObserver: NSObjectProtocol?
    private var lastObservedBoundaryPosition: Double?

    private var isTrayLimitEnabled: Bool {
        UserDefaults.standard.bool(forKey: "TrayIconLimitEnabled", defaultValue: false)
    }

    private var isAlwaysHiddenTraySectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "TrayIconAlwaysHiddenSectionEnabled", defaultValue: false)
    }

    private var isTrayLimitCollapsed: Bool {
        if let separatorWidth = trayLimitSeparatorWindow()?.frame.width {
            return separatorWidth > max(100, trayLimitNormalLength)
        }
        return (trayLimitSeparatorItem?.length ?? 0) > trayLimitNormalLength
    }

    private var isTrayLimitSeparatorValidPosition: Bool {
        guard let boundaryX = trayBoundarySeparatorWindow()?.frame.origin.x
                  ?? trayBoundarySeparatorItem?.button?.window?.frame.origin.x,
              let separatorX = trayLimitSeparatorWindow()?.frame.origin.x
                  ?? trayLimitSeparatorItem?.button?.window?.frame.origin.x else {
            return false
        }

        return boundaryX >= separatorX
    }

    init(updater: SPUStandardUpdaterController?) {
        statusBar = NSStatusBar.system
        Self.clearLegacyTrayLimitStatusItemPositions()
        Self.clearLegacyMenuBarSpacingPreferencesIfNeeded()
        statusItem = statusBar.statusItem(withLength: Self.toggleStatusItemLength)
        updaterController = updater
        super.init()

        // Seed the toggle/separator positions *before* their autosave names are assigned
        // below, so each item is created already at its slot. Writing the position after
        // the item exists cannot reliably move it back onto a full menu bar.
        ensureDefaultTrayPositions()

        configureStatusItem()
        setupTrayLimitSeparator()
        setupTrayBoundarySeparator()
        setupAlwaysHiddenSeparator()
        setupStatusItemPersistence()
        setupScreenObserver()
        setupWorkspaceWakeObserver()
        setupPermissionObserver()
        setupTooltipTargetRefreshObserver()
        setupTrayBoundaryPositionObserver()
        updateTrayIconLimiter()

        // If a permission wizard was mid-flow when the app last relaunched, resume it.
        DispatchQueue.main.async {
            AppPermissionRequester.resumePendingWizardIfNeeded()
        }
    }

    private func configureStatusItem() {
        statusItem.autosaveName = Self.toggleAutosaveName
        statusItem.length = Self.toggleStatusItemLength
        statusItem.menu = nil
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.image = makeStatusIcon()
        configureStatusButtonTooltip(button, text: Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String ?? "DockAppToggler")
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateInternalTrayTooltipTargetsSoon()
    }

    private func configureStatusButtonTooltip(_ button: NSStatusBarButton?, text: String) {
        button?.toolTip = nil
        button?.setAccessibilityLabel(text)
        button?.setAccessibilityHelp(text)
    }

    private func updateInternalTrayTooltipTargetsSoon() {
        updateInternalTrayTooltipTargets()
        DispatchQueue.main.async { [weak self] in
            self?.updateInternalTrayTooltipTargets()
        }
    }

    private func updateInternalTrayTooltipTargets() {
        let pid = ProcessInfo.processInfo.processIdentifier
        var icons: [TrayIconInfo] = []

        func add(_ item: NSStatusItem?, title: String, visible: Bool) {
            guard visible,
                  let frame = item?.button?.window?.frame,
                  frame.width > 0,
                  frame.height > 0 else {
                return
            }
            icons.append(TrayIconInfo(title: title, pid: pid, frame: frame))
        }

        add(statusItem, title: Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String ?? "DockAppToggler", visible: true)
        add(
            trayBoundarySeparatorItem,
            title: trayBoundarySeparatorToolTip,
            visible: isTrayLimitEnabled && (trayBoundarySeparatorItem?.length ?? 0) > 0
        )
        add(
            alwaysHiddenSeparatorItem,
            title: "Grenze für dauerhaft versteckte Tray-Icons",
            visible: (alwaysHiddenSeparatorItem?.length ?? 0) > 0
        )

        TrayIconCollector.setInternalIcons(icons)
    }

    private func makeStatusIcon() -> NSImage? {
        let iconImage: NSImage?
        if let bundleIconPath = Bundle.main.path(forResource: "trayicon", ofType: "png") {
            iconImage = NSImage(contentsOfFile: bundleIconPath)
        } else {
            iconImage = NSImage(contentsOfFile: "Sources/DockAppToggler/Resources/trayicon.png")
        }

        guard let image = iconImage else { return nil }

        let resizedImage = NSImage(size: NSSize(width: Self.statusIconImageLength, height: Self.statusIconImageLength))
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: NSSize(width: Self.statusIconImageLength, height: Self.statusIconImageLength)))
        resizedImage.unlockFocus()
        resizedImage.isTemplate = true
        return resizedImage
    }

    private func setupTrayLimitSeparator() {
        guard trayLimitSeparatorItem == nil else { return }

        let separator = statusBar.statusItem(withLength: 0)
        separator.autosaveName = Self.separatorAutosaveName
        separator.behavior = NSStatusItem.Behavior()
        separator.isVisible = true
        trayLimitSeparatorItem = separator
    }

    private func setupTrayBoundarySeparator() {
        guard trayBoundarySeparatorItem == nil else { return }

        let separator = statusBar.statusItem(withLength: isTrayLimitEnabled ? Self.boundaryStatusItemLength : 0)
        separator.autosaveName = Self.boundaryAutosaveName
        separator.length = isTrayLimitEnabled ? Self.boundaryStatusItemLength : 0
        separator.behavior = NSStatusItem.Behavior()
        separator.button?.image = makeTrayBoundarySeparatorImage(collapsed: isTrayLimitCollapsed)
        configureStatusButtonTooltip(separator.button, text: trayBoundarySeparatorToolTip)
        separator.button?.target = self
        separator.button?.action = #selector(trayBoundarySeparatorClicked(_:))
        separator.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        separator.isVisible = true
        trayBoundarySeparatorItem = separator
        updateInternalTrayTooltipTargetsSoon()
    }

    private func setupAlwaysHiddenSeparator() {
        guard alwaysHiddenSeparatorItem == nil else { return }

        let separator = statusBar.statusItem(withLength: 0)
        separator.autosaveName = Self.alwaysHiddenSeparatorAutosaveName
        separator.behavior = NSStatusItem.Behavior()
        separator.button?.image = makeTrayBoundarySeparatorImage(collapsed: isTrayLimitCollapsed)
        configureStatusButtonTooltip(separator.button, text: "Dauerhaft versteckte Tray-Icons")
        separator.isVisible = true
        alwaysHiddenSeparatorItem = separator
        updateInternalTrayTooltipTargetsSoon()
    }

    private func makeTrayBoundarySeparatorImage(collapsed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: Self.boundaryIconImageLength, height: 18))
        image.lockFocus()
        NSColor.black.withAlphaComponent(0.7).setStroke()

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 1.4
        if collapsed {
            path.move(to: NSPoint(x: 5.5, y: 5.5))
            path.line(to: NSPoint(x: 2.5, y: 9))
            path.line(to: NSPoint(x: 5.5, y: 12.5))
        } else {
            path.move(to: NSPoint(x: 2.5, y: 5.5))
            path.line(to: NSPoint(x: 5.5, y: 9))
            path.line(to: NSPoint(x: 2.5, y: 12.5))
        }
        path.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private var trayBoundarySeparatorToolTip: String {
        isTrayLimitCollapsed
            ? "Klicken, um versteckte Tray-Icons einzublenden"
            : "Klicken, um versteckte Tray-Icons auszublenden"
    }

    private func updateTrayBoundarySeparatorAppearance() {
        trayBoundarySeparatorItem?.button?.image = makeTrayBoundarySeparatorImage(collapsed: isTrayLimitCollapsed)
        configureStatusButtonTooltip(trayBoundarySeparatorItem?.button, text: trayBoundarySeparatorToolTip)
        alwaysHiddenSeparatorItem?.button?.image = makeTrayBoundarySeparatorImage(collapsed: isTrayLimitCollapsed)
        updateInternalTrayTooltipTargetsSoon()
    }


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

    private func setupScreenObserver() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenConfigurationChange()
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

        // Restore any pushed-off icons when the app is about to quit (covers quit paths
        // other than our own menu item).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreHiddenIconsBeforeExit() }
        }
    }

    private func setupPermissionObserver() {
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .appPermissionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateTrayIconLimiter()
            }
        }
    }

    private func setupTooltipTargetRefreshObserver() {
        tooltipTargetRefreshObserver = NotificationCenter.default.addObserver(
            forName: .statusBarTooltipTargetsShouldRefresh,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateInternalTrayTooltipTargets()
            }
        }
    }

    private func setupTrayBoundaryPositionObserver() {
        lastObservedBoundaryPosition = savedPreferredPosition(for: Self.boundaryAutosaveName)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrayBoundaryPositionMaybeChanged()
            }
        }
    }

    private func handleTrayBoundaryPositionMaybeChanged() {
        guard isTrayLimitEnabled,
              let currentPosition = savedPreferredPosition(for: Self.boundaryAutosaveName) else { return }

        guard !isApplyingInternalTrayPositionChange else {
            lastObservedBoundaryPosition = currentPosition
            return
        }

        defer { lastObservedBoundaryPosition = currentPosition }

        guard let lastPosition = lastObservedBoundaryPosition,
              abs(currentPosition - lastPosition) >= 0.5 else { return }

        scheduleHiddenTrayIconRecalculation()
    }

    private func scheduleHiddenTrayIconRecalculation() {
        trayToggleMoveRecalcTask?.cancel()
        trayToggleMoveRecalcTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.recalculateHiddenTrayIconsAfterToggleMove()
            }
        }
    }

    private func recalculateHiddenTrayIconsAfterToggleMove() {
        guard isTrayLimitEnabled else { return }

        let shouldReCollapse = isTrayLimitCollapsed
        trayLimitCollapseRetryCount = 0
        trayLimitReapplyTask?.cancel()
        trayLimitReapplyTask = nil
        updateTrayLimitCollapsedLength()
        positionItemsAroundBoundary()
        ensureAlwaysHiddenSeparatorDefaultPosition()

        guard shouldReCollapse else { return }

        trayLimitSeparatorItem?.length = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.collapseTrayIcons()
        }
    }

    private func handleScreenConfigurationChange() {
        Logger.debug("Screen configuration changed in StatusBarController")
        if statusItem.button?.superview == nil {
            Logger.debug("Status bar item not visible, recreating")
            recreateStatusItem()
        }
        updateTrayIconLimiter()
    }

    private func ensureStatusItemVisibleAfterSystemEvent() {
        statusItem.isVisible = true
        if statusItem.button?.superview == nil {
            Logger.debug("Status bar item missing after wake; recreating")
            recreateStatusItem()
        }
        updateTrayIconLimiter()
    }

    private func recreateStatusItem() {
        let oldItem = statusItem
        statusItem = statusBar.statusItem(withLength: Self.toggleStatusItemLength)
        configureStatusItem()
        setupStatusItemPersistence()
        positionItemsAroundBoundary()
        statusBar.removeStatusItem(oldItem)
        Logger.debug("Status bar item recreated")
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showStatusMenu(from: sender)
            return
        }

        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            showStatusMenu(from: sender)
        }
    }

    private func toggleTrayIconsFromBoundary() {
        guard isTrayLimitEnabled else { return }
        if isTrayLimitCollapsed {
            expandTrayIcons()
        } else {
            collapseTrayIcons()
        }
    }

    @objc private func trayBoundarySeparatorClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleTrayIconsFromBoundary()
            return
        }

        if event.type == .rightMouseUp {
            toggleTrayIconsFromBoundary()
            return
        }

        guard event.type == .leftMouseUp else { return }
        toggleTrayIconsFromBoundary()
    }

    private func applyInternalTrayPositionChange(_ updates: () -> Void) {
        isApplyingInternalTrayPositionChange = true
        updates()
        lastObservedBoundaryPosition = savedPreferredPosition(for: Self.boundaryAutosaveName)
        isApplyingInternalTrayPositionChange = false
    }

    private struct TrayMenuBarWindow {
        let windowID: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }

    private func trayLimitSeparatorWindow() -> TrayMenuBarWindow? {
        ownStatusItemWindows(named: Self.separatorAutosaveName)
            .max { lhs, rhs in lhs.frame.width < rhs.frame.width }
    }

    private func trayBoundarySeparatorWindow() -> TrayMenuBarWindow? {
        ownStatusItemWindows(named: Self.boundaryAutosaveName).first
    }

    private func ownStatusItemWindows(named name: String? = nil) -> [TrayMenuBarWindow] {
        let options = CGWindowListOption([.optionAll, .excludeDesktopElements])
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  isStatusItemLayer(layer),
                  name == nil || (info[kCGWindowName as String] as? String) == name,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  var frame = windowFrame(from: info) else {
                return nil
            }

            if let freshFrame = screenRectForWindow(windowID), freshFrame.width > 0, freshFrame.height > 0 {
                frame = freshFrame
            }
            return TrayMenuBarWindow(
                windowID: windowID,
                pid: ProcessInfo.processInfo.processIdentifier,
                frame: frame
            )
        }
    }

    private func windowFrame(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private func isStatusItemLayer(_ layer: Int) -> Bool {
        layer == Int(CGWindowLevelForKey(.statusWindow))
    }

    private func screenRectForWindow(_ windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        let result = DockAppTogglerCGSGetScreenRectForWindow(
            DockAppTogglerCGSMainConnectionID(),
            windowID,
            &rect
        )
        guard result == .success else { return nil }
        return rect
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                checkForUpdates: { [weak updaterController] in
                    updaterController?.checkForUpdates(nil)
                },
                trayLimitChanged: { [weak self] in
                    self?.updateTrayIconLimiter()
                }
            )
        }

        settingsWindowController?.showAndFocus()
    }

    private func updateTrayIconLimiter() {
        updateTrayLimitCollapsedLength()
        setupTrayBoundarySeparator()
        setupAlwaysHiddenSeparator()

        if isTrayLimitEnabled {
            trayLimitCollapseRetryCount = 0
            // Collapsed is the default resting state: it frees menu-bar space so the
            // boundary and app icon keep visible slots. Re-assert it a few times because
            // at login the menu bar is still settling (other apps registering items).
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.collapseTrayIcons()
                }
            }
        } else {
            expandTrayIcons()
        }
    }

    private func updateTrayLimitCollapsedLength() {
        let widestScreenWidth = NSScreen.screens.map(\.frame.width).max() ?? 1728
        trayLimitCollapsedLength = max(500, min(widestScreenWidth * 2, 10_000))
    }

    private func collapseTrayIcons() {
        guard isTrayLimitEnabled else { return }
        setupTrayLimitSeparator()
        setupTrayBoundarySeparator()
        setupAlwaysHiddenSeparator()
        updateTrayLimitCollapsedLength()

        guard !isTrayLimitCollapsed else { return }

        // Glue the invisible spacer immediately left of the visible boundary separator.
        // Expanding it pushes everything left of the boundary off screen, while the
        // separator, DockAppToggler icon, and icons to its right stay put.
        positionItemsAroundBoundary()

        if !isTrayLimitSeparatorValidPosition, trayLimitCollapseRetryCount < 3 {
            trayLimitCollapseRetryCount += 1
            scheduleTrayLimitCollapseReapply()
            return
        }

        trayLimitReapplyTask?.cancel()
        trayLimitReapplyTask = nil
        trayLimitCollapseRetryCount = 0

        finishCollapse()
    }

    private func finishCollapse() {
        guard isTrayLimitEnabled else { return }
        trayBoundarySeparatorItem?.length = Self.boundaryStatusItemLength
        alwaysHiddenSeparatorItem?.length = 0
        trayLimitSeparatorItem?.length = trayLimitCollapsedLength
        updateTrayBoundarySeparatorAppearance()
        // Once the boundary is placed, nudge it clear of the notch if it would be covered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.adjustBoundaryForNotch()
        }
    }

    private func scheduleTrayLimitCollapseReapply() {
        trayLimitReapplyTask?.cancel()
        trayLimitReapplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.collapseTrayIcons()
            }
        }
    }

    private func expandTrayIcons() {
        trayLimitReapplyTask?.cancel()
        trayLimitReapplyTask = nil
        trayLimitCollapseRetryCount = 0
        setupTrayLimitSeparator()
        setupTrayBoundarySeparator()
        setupAlwaysHiddenSeparator()
        positionItemsAroundBoundary()
        // Shrink the separator back to zero width (keep the item). This makes the menu bar
        // relayout and the pushed-off icons slide back into place. Removing the item does
        // not reliably trigger that restore, so we keep it and just collapse its width.
        trayLimitSeparatorItem?.length = 0
        trayBoundarySeparatorItem?.length = isTrayLimitEnabled ? Self.boundaryStatusItemLength : 0
        applyAlwaysHiddenSeparatorLengthForExpandedState()
        updateTrayBoundarySeparatorAppearance()
    }

    private func beginAlwaysHiddenTraySectionEditing() {
        guard isTrayLimitEnabled else { return }

        restoreCollapseAfterAlwaysHiddenEditing = isTrayLimitCollapsed
        isEditingAlwaysHiddenTraySection = true

        trayLimitReapplyTask?.cancel()
        trayLimitReapplyTask = nil
        setupTrayLimitSeparator()
        setupTrayBoundarySeparator()
        setupAlwaysHiddenSeparator()
        updateTrayLimitCollapsedLength()
        positionItemsAroundBoundary()
        ensureAlwaysHiddenSeparatorDefaultPosition()

        trayLimitSeparatorItem?.length = 0
        trayBoundarySeparatorItem?.length = Self.boundaryStatusItemLength
        alwaysHiddenSeparatorItem?.length = alwaysHiddenEditLength
        updateTrayBoundarySeparatorAppearance()
    }

    private func finishAlwaysHiddenTraySectionEditing() {
        isEditingAlwaysHiddenTraySection = false
        UserDefaults.standard.set(true, forKey: "TrayIconAlwaysHiddenSectionEnabled")

        if restoreCollapseAfterAlwaysHiddenEditing {
            collapseTrayIcons()
        } else {
            expandTrayIcons()
        }
        restoreCollapseAfterAlwaysHiddenEditing = false
    }

    private func applyAlwaysHiddenSeparatorLengthForExpandedState() {
        guard isTrayLimitEnabled,
              isAlwaysHiddenTraySectionEnabled || isEditingAlwaysHiddenTraySection else {
            alwaysHiddenSeparatorItem?.length = 0
            return
        }

        ensureAlwaysHiddenSeparatorDefaultPosition()
        alwaysHiddenSeparatorItem?.length = isEditingAlwaysHiddenTraySection
            ? alwaysHiddenEditLength
            : trayLimitCollapsedLength
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.delegate = self
        menu.appearance = NSAppearance(named: .aqua)

        if isTrayLimitEnabled {
            menu.addItem(makeMenuItem(
                title: isEditingAlwaysHiddenTraySection
                    ? "Dauerhaft versteckte Icons anwenden"
                    : "Dauerhaft versteckte Icons bearbeiten",
                action: #selector(toggleAlwaysHiddenTraySectionEditingFromStatusMenu)
            ))
            if isAlwaysHiddenTraySectionEnabled {
                menu.addItem(makeMenuItem(
                    title: "Dauerhaft verstecken deaktivieren",
                    action: #selector(disableAlwaysHiddenTraySectionFromStatusMenu)
                ))
            }
        } else {
            menu.addItem(makeMenuItem(
                title: "Tray-Iconbegrenzung aktivieren",
                action: #selector(enableTrayLimitFromStatusMenu)
            ))
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Einstellungen...", action: #selector(showSettingsWindowFromStatusMenu)))
        menu.addItem(.separator())

        let quitItem = makeMenuItem(title: "DockAppToggler beenden", action: #selector(quitFromStatusMenu))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)

        statusMenuPreviousAppAppearance = NSApp.appearance
        statusMenuPreviousButtonAppearance = button.appearance
        let aqua = NSAppearance(named: .aqua)
        NSApp.appearance = aqua
        button.appearance = aqua
        statusMenu = menu

        let selector = NSSelectorFromString("popUpStatusItemMenu:")
        if statusItem.responds(to: selector) {
            _ = statusItem.perform(selector, with: menu)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        }
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        NotificationCenter.default.post(
            name: .statusBarMenuStateChanged,
            object: nil,
            userInfo: ["isOpen": true]
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.button?.appearance = statusMenuPreviousButtonAppearance
        NSApp.appearance = statusMenuPreviousAppAppearance
        statusMenuPreviousButtonAppearance = nil
        statusMenuPreviousAppAppearance = nil
        statusMenu = nil

        NotificationCenter.default.post(
            name: .statusBarMenuStateChanged,
            object: nil,
            userInfo: ["isOpen": false]
        )
    }

    @objc private func enableTrayLimitFromStatusMenu() {
        UserDefaults.standard.set(true, forKey: "TrayIconLimitEnabled")
        updateTrayIconLimiter()
    }

    @objc private func toggleAlwaysHiddenTraySectionEditingFromStatusMenu() {
        if isEditingAlwaysHiddenTraySection {
            finishAlwaysHiddenTraySectionEditing()
        } else {
            beginAlwaysHiddenTraySectionEditing()
        }
    }

    @objc private func disableAlwaysHiddenTraySectionFromStatusMenu() {
        isEditingAlwaysHiddenTraySection = false
        UserDefaults.standard.set(false, forKey: "TrayIconAlwaysHiddenSectionEnabled")
        alwaysHiddenSeparatorItem?.length = 0

        if isTrayLimitCollapsed {
            collapseTrayIcons()
        } else {
            expandTrayIcons()
        }
    }

    @objc private func showSettingsWindowFromStatusMenu() {
        showSettingsWindow()
    }

    @objc private func quitFromStatusMenu() {
        restoreHiddenIconsBeforeExit()
        // Give the menu bar a moment to slide the icons back before we quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    /// Brings any pushed-off icons back into the menu bar so they aren't left hidden after
    /// the app goes away.
    private func restoreHiddenIconsBeforeExit() {
        expandTrayIcons()
        // Drop the toggle's forced divider position too, so a future run / other launch
        // doesn't inherit a layout that hides icons.
        trayLimitSeparatorItem?.length = 0
        trayBoundarySeparatorItem?.length = 0
        alwaysHiddenSeparatorItem?.length = 0
    }

    static func performRestart() {
        UserDefaults.standard.set(true, forKey: "HideHelpOnStartup")
        NSApplication.restart(skipUpdateCheck: true)
    }

    // MARK: - Divider positioning (HiddenBar trick)
    //
    // A dedicated boundary separator acts as the visible divider: icons to its left are
    // hidden, icons to its right stay visible. macOS orders status items by a
    // per-autosave-name "Preferred Position" number where a *smaller* value sits further
    // right, and a live item only moves when this key is rewritten *and* its `autosaveName`
    // is re-assigned (verified empirically).
    //
    // To hide the left side we glue the invisible spacer immediately to the left of the
    // boundary separator, then expand it. The DockAppToggler icon keeps its own normal
    // menu-bar position and is only the menu button, not the divider itself.

    /// Offset added to the boundary's preferred position to place the spacer just to
    /// its left (larger value = further left). Small enough that no icon slips between.
    private static let separatorLeftOffset: Double = 1
    private static let appIconDefaultRightOffset: Double = 32
    private static let alwaysHiddenSeparatorDefaultOffset: Double = 96
    /// Default boundary position.
    private static let boundaryDefaultPosition: Double = 2

    private func preferredPositionKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private func setPreferredPosition(_ value: Double, for autosaveName: String) {
        UserDefaults.standard.set(value, forKey: preferredPositionKey(for: autosaveName))
    }

    private func savedPreferredPosition(for autosaveName: String) -> Double? {
        UserDefaults.standard.object(forKey: preferredPositionKey(for: autosaveName)) as? Double
    }

    /// Seeds the divider positions before the autosave names are assigned so macOS creates
    /// them already positioned. The DockAppToggler icon only gets an initial visible-side
    /// slot when it has no saved position yet; after that it keeps its own menu-bar position.
    private func ensureDefaultTrayPositions() {
        let boundaryPosition =
            savedPreferredPosition(for: Self.boundaryAutosaveName)
                ?? Self.boundaryDefaultPosition

        if savedPreferredPosition(for: Self.toggleAutosaveName) == nil {
            setPreferredPosition(
                max(0, boundaryPosition - Self.appIconDefaultRightOffset),
                for: Self.toggleAutosaveName
            )
        }
        if savedPreferredPosition(for: Self.boundaryAutosaveName) == nil {
            setPreferredPosition(boundaryPosition, for: Self.boundaryAutosaveName)
        }
        setPreferredPosition(boundaryPosition + Self.separatorLeftOffset, for: Self.separatorAutosaveName)
        if savedPreferredPosition(for: Self.alwaysHiddenSeparatorAutosaveName) == nil {
            setPreferredPosition(boundaryPosition + Self.alwaysHiddenSeparatorDefaultOffset, for: Self.alwaysHiddenSeparatorAutosaveName)
        }
    }

    /// Re-parks the spacer around the boundary separator. The boundary may have been
    /// ⌘-dragged to a new divider spot; DockAppToggler keeps its own position.
    private func positionItemsAroundBoundary() {
        let boundaryPosition = savedPreferredPosition(for: Self.boundaryAutosaveName) ?? Self.boundaryDefaultPosition

        applyInternalTrayPositionChange {
            setPreferredPosition(boundaryPosition, for: Self.boundaryAutosaveName)
            setPreferredPosition(boundaryPosition + Self.separatorLeftOffset, for: Self.separatorAutosaveName)
            trayBoundarySeparatorItem?.autosaveName = Self.boundaryAutosaveName
            trayLimitSeparatorItem?.autosaveName = Self.separatorAutosaveName
        }
    }

    private func ensureAlwaysHiddenSeparatorDefaultPosition() {
        guard savedPreferredPosition(for: Self.alwaysHiddenSeparatorAutosaveName) == nil else {
            alwaysHiddenSeparatorItem?.autosaveName = Self.alwaysHiddenSeparatorAutosaveName
            return
        }

        let boundaryPosition = savedPreferredPosition(for: Self.boundaryAutosaveName) ?? Self.boundaryDefaultPosition
        setPreferredPosition(
            boundaryPosition + Self.alwaysHiddenSeparatorDefaultOffset,
            for: Self.alwaysHiddenSeparatorAutosaveName
        )
        alwaysHiddenSeparatorItem?.autosaveName = Self.alwaysHiddenSeparatorAutosaveName
    }

    // MARK: - Notch avoidance (built-in display only)

    /// Remembers the boundary's pre-shift divider position while it is nudged off the
    /// notch, so we can restore it once the notch no longer covers it.
    private static let notchBasePrefKey = "TrayBoundaryNotchBasePref"

    /// On a built-in display with a notch, the menu-bar centre is unusable. If the
    /// boundary would sit under the notch, shift it right until it clears the notch.
    private func adjustBoundaryForNotch() {
        let defaults = UserDefaults.standard

        guard let notchScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let leftArea = notchScreen.auxiliaryTopLeftArea,
              let rightArea = notchScreen.auxiliaryTopRightArea,
              let coveredFrame = trayBoundarySeparatorWindow()?.frame,
              coveredFrame.minX < rightArea.minX,
              coveredFrame.maxX > leftArea.maxX else {
            restoreBoundaryFromNotchShift()
            return
        }

        let notchMinX = leftArea.maxX
        let notchMaxX = rightArea.minX
        let coversNotch = coveredFrame.minX < notchMaxX && coveredFrame.maxX > notchMinX
        guard coversNotch else {
            restoreBoundaryFromNotchShift()
            return
        }

        let basePosition = (defaults.object(forKey: Self.notchBasePrefKey) as? Double)
            ?? savedPreferredPosition(for: Self.boundaryAutosaveName)
            ?? Self.boundaryDefaultPosition
        if defaults.object(forKey: Self.notchBasePrefKey) == nil {
            defaults.set(basePosition, forKey: Self.notchBasePrefKey)
        }

        // Smaller preferred position = further right; move right by the overlap distance.
        let shiftRightPixels = (notchMaxX - coveredFrame.minX) + 8
        setPreferredPosition(max(0, basePosition - shiftRightPixels), for: Self.boundaryAutosaveName)
        positionItemsAroundBoundary()
    }

    private func restoreBoundaryFromNotchShift() {
        let defaults = UserDefaults.standard
        guard let basePosition = defaults.object(forKey: Self.notchBasePrefKey) as? Double else { return }
        setPreferredPosition(basePosition, for: Self.boundaryAutosaveName)
        positionItemsAroundBoundary()
        defaults.removeObject(forKey: Self.notchBasePrefKey)
    }

    private static func clearLegacyTrayLimitStatusItemPositions() {
        // Only purge positions from *older* autosave names; the current keys must persist
        // so the user's divider position survives across launches.
        let keys = [
            "NSStatusItem Preferred Position Item-0",
            "NSStatusItem VisibleCC Item-0",
            "NSStatusItem Preferred Position dockapptoggler_expandcollapse",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_separate",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_expandcollapse_v2",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_separate_v2",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_expandcollapse_v3",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_separate_v3",
            "NSStatusItem Preferred Position dockapptoggler_hiddenbar_boundary_v1",
            "NSStatusItem Preferred Position dockapptoggler_app_icon_v1",
            "TrayBoundaryNotchBasePref"
        ]

        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func clearLegacyMenuBarSpacingPreferencesIfNeeded() {
        let cleanupFlag = "DidClearLegacyMenuBarSpacingPreferencesV1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: cleanupFlag) else { return }

        let keys = [
            "NSStatusItemSpacing",
            "NSStatusItemSelectionPadding"
        ]
        let hosts = [
            kCFPreferencesCurrentHost,
            kCFPreferencesAnyHost
        ]
        var changed = false

        for key in keys {
            for host in hosts {
                let value = CFPreferencesCopyValue(
                    key as CFString,
                    kCFPreferencesAnyApplication,
                    kCFPreferencesCurrentUser,
                    host
                )
                if value != nil { changed = true }
                CFPreferencesSetValue(
                    key as CFString,
                    nil,
                    kCFPreferencesAnyApplication,
                    kCFPreferencesCurrentUser,
                    host
                )
            }
        }

        for host in hosts {
            CFPreferencesSynchronize(
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                host
            )
        }
        defaults.set(true, forKey: cleanupFlag)

        guard changed else { return }
        for processName in ["ControlCenter", "SystemUIServer"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [processName]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
        }
    }

    deinit {
        trayLimitReapplyTask?.cancel()
        trayToggleMoveRecalcTask?.cancel()
        visibilityObservation?.invalidate()

        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
        if let tooltipTargetRefreshObserver {
            NotificationCenter.default.removeObserver(tooltipTargetRefreshObserver)
        }
    }
}

extension Notification.Name {
    static let optionTabStateChanged = Notification.Name("optionTabStateChanged")
    static let statusBarMenuStateChanged = Notification.Name("statusBarMenuStateChanged")
    static let statusBarTooltipTargetsShouldRefresh = Notification.Name("statusBarTooltipTargetsShouldRefresh")
}

extension UserDefaults {
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil {
            set(defaultValue, forKey: key)
            return defaultValue
        }
        return bool(forKey: key)
    }
}

@_silgen_name("CGSMainConnectionID")
private func DockAppTogglerCGSMainConnectionID() -> Int32

@_silgen_name("CGSGetScreenRectForWindow")
private func DockAppTogglerCGSGetScreenRectForWindow(
    _ cid: Int32,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError
