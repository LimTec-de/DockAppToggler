import AppKit
import Cocoa
import ApplicationServices

extension Notification.Name {
    static let statusBarTooltipsStateChanged = Notification.Name("statusBarTooltipsStateChanged")
}

@MainActor
class TooltipWindow {
    private var window: NSWindow?
    private var containerView: NSView?
    private var contentView: NSVisualEffectView?
    private var label: NSTextField?

    func show(text: String, at location: NSPoint) {
        let tooltip = window ?? makeWindow()
        guard let containerView, let contentView, let label else { return }
        tooltip.title = text
        label.stringValue = text

        let textSize = (text as NSString).size(withAttributes: [
            .font: label.font as Any
        ])
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 6
        let textBuffer: CGFloat = 8
        let windowWidth = textSize.width + horizontalPadding * 2 + textBuffer
        let windowHeight = textSize.height + verticalPadding * 2
        
        // Position window
        let windowX = location.x - windowWidth / 2
        
        // Calculate Y position relative to menu bar
        guard let screen = NSScreen.screen(containing: location) ?? NSScreen.main else { return }
        let menuBarY = screen.frame.maxY
        let tooltipGap: CGFloat = 4
        let menuBarHeight = max(NSStatusBar.system.thickness, 30)
        let windowY = menuBarY - menuBarHeight - windowHeight - tooltipGap
        let clampedWindowX = min(
            max(windowX, screen.visibleFrame.minX + 4),
            screen.visibleFrame.maxX - windowWidth - 4
        )
        
        // Set frames
        containerView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        contentView.frame = containerView.bounds
        
        // Then set window frame
        tooltip.setFrame(NSRect(x: clampedWindowX, y: windowY,
                              width: windowWidth, height: windowHeight),
                        display: false)
        
        // Center label in window with buffer space
        label.frame = NSRect(x: horizontalPadding,
                           y: verticalPadding,
                           width: textSize.width + textBuffer,
                           height: textSize.height)

        tooltip.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let tooltip = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        tooltip.level = .floating
        tooltip.isOpaque = false
        tooltip.hasShadow = true
        tooltip.isMovableByWindowBackground = false
        tooltip.ignoresMouseEvents = true

        let contentView = NSVisualEffectView()
        contentView.wantsLayer = true
        contentView.material = .popover
        contentView.blendingMode = .withinWindow
        contentView.state = .active

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.cornerRadius = 4
        containerView.layer?.masksToBounds = true

        let label = NSTextField(frame: .zero)
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1.5)
        label.alignment = .center
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1

        contentView.addSubview(label)
        containerView.addSubview(contentView)
        tooltip.contentView = containerView
        tooltip.backgroundColor = .clear

        window = tooltip
        self.containerView = containerView
        self.contentView = contentView
        self.label = label
        return tooltip
    }
    
    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
    }
}

@MainActor
class StatusBarWatcher {
    private var lastMouseMoveTime: TimeInterval = 0
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var lastHoveredPid: pid_t = 0
    private var lastHoveredFrame: CGRect = .null
    private let tooltipWindow = TooltipWindow()
    private var isEnabled: Bool
    private var isSuspendedForMenu: Bool = false
    private var isTrackingMenuBarArea: Bool = false
    private var isTooltipVisible = false
    private var lastTooltipTitle = ""
    private static let mouseMoveThrottleInterval: TimeInterval = 0.003
    private static let missRetryInterval: TimeInterval = 0.04
    private static let tooltipPermissionPromptKey = "DidPromptForTrayTooltipPermissionsV1"
    private var lastIconMissTime: TimeInterval = 0
    
    init() {
        // Initialize with saved preference, default to OFF (opt-in).
        if UserDefaults.standard.object(forKey: "StatusBarTooltipsEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "StatusBarTooltipsEnabled")
            self.isEnabled = false
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled")
        }
        
        setupNotificationObserver()
        if isEnabled {
            startWatching()
            requestMissingTooltipPermissionsIfNeeded()
        }
    }

    private func startWatchingIfEnabled() {
        guard isEnabled else {
            cleanupOnMain()
            tooltipWindow.hide()
            isTooltipVisible = false
            lastTooltipTitle = ""
            return
        }

        startWatching()
        requestMissingTooltipPermissionsIfNeeded()
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTooltipsStateChanged),
            name: .statusBarTooltipsStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusBarMenuStateChanged(_:)),
            name: .statusBarMenuStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionsChanged),
            name: .appPermissionsChanged,
            object: nil
        )
    }
    
    @objc private func handleTooltipsStateChanged() {
        isEnabled = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled")
        startWatchingIfEnabled()
    }

    @objc private func handleStatusBarMenuStateChanged(_ notification: Notification) {
        let isOpen = notification.userInfo?["isOpen"] as? Bool ?? false
        isSuspendedForMenu = isOpen

        if isOpen {
            tooltipWindow.hide()
            isTooltipVisible = false
            lastTooltipTitle = ""
            // Must run synchronously: if we deferred this onto a Task, the
            // `menuDidClose` handler that calls startWatching() could run
            // before the cleanup, see a still-installed monitor, bail out via
            // the `guard eventMonitor == nil` check, and then the queued
            // cleanup would tear the monitor down. Result: tooltips stayed
            // dead after the very first time the user opened the tray menu.
            cleanupOnMain()
        } else if isEnabled {
            startWatching()
        }
    }

    @objc private func handlePermissionsChanged() {
        startWatchingIfEnabled()
    }
    
    private nonisolated func checkAccessibilityPermissions() -> Bool {
        AXIsProcessTrusted()
    }

    private func requestMissingTooltipPermissionsIfNeeded() {
        let state = AppPermissionState.current
        guard !state.accessibilityGranted || !state.screenRecordingGranted else { return }

        if !state.accessibilityGranted {
            Logger.warning("[StatusBarWatcher] Bedienungshilfen fehlen; Tray-Tooltips nutzen AX-Fallbacks nur eingeschränkt")
        }
        if !state.screenRecordingGranted {
            Logger.warning("[StatusBarWatcher] Bildschirmaufnahme fehlt; App-Namen in Tray-Tooltips können generisch sein")
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.tooltipPermissionPromptKey) else { return }
        defaults.set(true, forKey: Self.tooltipPermissionPromptKey)
        AppPermissionRequester.presentTrayPopupWizard()
    }
    
    private var _lastStatusBarCheckTime: TimeInterval = 0
    
    private func startWatching() {
        guard eventMonitor == nil, localEventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self = self, self.isEnabled, !self.isSuspendedForMenu else { return }

            Task { @MainActor in
                self.handleObservedMouseMove()
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }

            Task { @MainActor in
                guard self.isEnabled, !self.isSuspendedForMenu else { return }
                self.handleObservedMouseMove()
            }

            return event
        }

        handleObservedMouseMove()
    }

    private func handleObservedMouseMove() {
        let mouseLocation = NSEvent.mouseLocation
        guard isMouseInMenuBarArea(mouseLocation) else {
            endDetailedTracking()
            return
        }

        if handleMouseMove(force: !isTrackingMenuBarArea) {
            beginDetailedTrackingIfNeeded()
        } else {
            endDetailedTracking()
        }
    }

    private func beginDetailedTrackingIfNeeded() {
        guard !isTrackingMenuBarArea else { return }
        isTrackingMenuBarArea = true
    }

    private func endDetailedTracking() {
        guard isTrackingMenuBarArea || lastHoveredPid != 0 || isTooltipVisible else { return }
        isTrackingMenuBarArea = false
        lastHoveredPid = 0
        lastHoveredFrame = .null
        tooltipWindow.hide()
        isTooltipVisible = false
        lastTooltipTitle = ""
    }
    
    @MainActor private func cleanupOnMain() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        isTrackingMenuBarArea = false
    }

    nonisolated func cleanup() {
        Task { @MainActor in
            self.cleanupOnMain()
        }
    }

    deinit {
        cleanup()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func isMouseInMenuBarArea(_ mouseLocation: NSPoint) -> Bool {
        guard let screen = NSScreen.screen(containing: mouseLocation) ?? NSScreen.main else { return false }
        let menuBarHeight = max(NSStatusBar.system.thickness, 30)
        let maxY = screen.frame.maxY
        let menuBarRect = NSRect(
            x: screen.frame.minX,
            y: maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        return menuBarRect.contains(mouseLocation)
    }

    private func handleMouseMove(force: Bool = false) -> Bool {
        guard isEnabled else { return false }

        // Add throttling to prevent too frequent updates
        let currentTime = ProcessInfo.processInfo.systemUptime
        if !force && currentTime - lastMouseMoveTime < Self.mouseMoveThrottleInterval {
            return lastHoveredPid != 0
        }
        lastMouseMoveTime = currentTime
        
        let mouseLocation = NSEvent.mouseLocation

        if lastHoveredPid != 0,
           lastHoveredFrame.insetBy(dx: -2, dy: -4).contains(mouseLocation) {
            return true
        }

        if lastHoveredPid == 0,
           !force,
           currentTime - lastIconMissTime < Self.missRetryInterval {
            return false
        }
        
        NotificationCenter.default.post(name: .statusBarTooltipTargetsShouldRefresh, object: nil)

        guard isMouseInMenuBarArea(mouseLocation),
              let icon = TrayIconCollector.icon(at: mouseLocation) else {
            lastHoveredPid = 0
            lastHoveredFrame = .null
            lastIconMissTime = currentTime
            tooltipWindow.hide()
            isTooltipVisible = false
            lastTooltipTitle = ""
            return false
        }

        if shouldKeepCurrentTooltip(over: icon) {
            return true
        }

        if icon.pid != lastHoveredPid || !icon.frame.equalTo(lastHoveredFrame) {
            lastHoveredPid = icon.pid
            lastHoveredFrame = icon.frame
            lastIconMissTime = 0
            tooltipWindow.show(text: icon.title, at: mouseLocation)
            isTooltipVisible = true
            lastTooltipTitle = icon.title
        }
        return true
    }

    private func shouldKeepCurrentTooltip(over icon: TrayIconInfo) -> Bool {
        guard isTooltipVisible,
              !lastTooltipTitle.isEmpty,
              !isFallbackTooltipTitle(lastTooltipTitle),
              isFallbackTooltipTitle(icon.title),
              lastHoveredFrame.insetBy(dx: -6, dy: -6).intersects(icon.frame) else {
            return false
        }

        return true
    }

    private func isFallbackTooltipTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ||
            normalized == "Tray Icon" ||
            normalized == "Kontrollzentrum" ||
            normalized == "Control Center" ||
            normalized.hasPrefix("App-Name erst nach Bildschirmaufnahme-Freigabe")
    }
} 
