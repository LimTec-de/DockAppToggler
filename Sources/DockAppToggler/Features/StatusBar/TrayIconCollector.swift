import AppKit
import ApplicationServices

struct TrayIconInfo {
    let title: String
    let pid: pid_t
    let frame: CGRect
}

enum TrayIconCollector {
    private static let axRequestTimeout: Float = 0.2
    private static let menuBarItemRoles: Set<String> = ["AXMenuBarItem", "AXMenuExtra"]
    private nonisolated(unsafe) static var internalIcons: [TrayIconInfo] = []

    private struct WindowCandidate {
        let info: [String: Any]
        let frame: CGRect
    }

    static func setInternalIcons(_ icons: [TrayIconInfo]) {
        internalIcons = icons
    }

    private static func applyShortTimeout(to element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axRequestTimeout)
    }

    private static func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        into value: inout CFTypeRef?
    ) -> AXError {
        applyShortTimeout(to: element)
        return AXUIElementCopyAttributeValue(element, attribute, &value)
    }

    static func visibleIcons(on screen: NSScreen? = nil) -> [TrayIconInfo] {
        let windowListIcons = iconsFromWindowList(on: screen)
        if !windowListIcons.isEmpty {
            return windowListIcons
        }

        guard AXIsProcessTrusted() else { return [] }

        let systemWideElement = AXUIElementCreateSystemWide()
        applyShortTimeout(to: systemWideElement)
        var extrasMenuBarValue: CFTypeRef?
        guard copyAttributeValue(kAXExtrasMenuBarAttribute as CFString, from: systemWideElement, into: &extrasMenuBarValue) == .success,
              let extrasMenuBar = extrasMenuBarValue,
              CFGetTypeID(extrasMenuBar) == AXUIElementGetTypeID() else {
            return []
        }

        let extrasMenuBarElement = extrasMenuBar as! AXUIElement
        applyShortTimeout(to: extrasMenuBarElement)

        var childrenValue: CFTypeRef?
        guard copyAttributeValue(kAXChildrenAttribute as CFString, from: extrasMenuBarElement, into: &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }

        return children
            .compactMap(makeTrayIconInfo)
            .filter { isPlausibleTrayIcon($0, on: screen) }
            .sorted { $0.frame.midX > $1.frame.midX }
    }

    static func icon(at point: NSPoint) -> TrayIconInfo? {
        if let internalIcon = internalIcon(at: point) {
            return internalIcon
        }

        if let windowListIcon = iconFromWindowList(at: point) {
            return windowListIcon
        }

        let screen = NSScreen.screen(containing: point)
        return visibleIcons(on: screen).first { icon in
            icon.frame.insetBy(dx: -2, dy: -4).contains(point)
        }
    }

    private static func internalIcon(at point: NSPoint) -> TrayIconInfo? {
        bestIcon(from: internalIcons.filter { $0.frame.insetBy(dx: -2, dy: -4).contains(point) })
    }

    private static func bestIcon(from icons: [TrayIconInfo]) -> TrayIconInfo? {
        icons.min { lhs, rhs in
            let lhsRank = titleFallbackRank(lhs.title)
            let rhsRank = titleFallbackRank(rhs.title)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }

    private static func iconFromElementAtPosition(_ point: NSPoint) -> TrayIconInfo? {
        guard let screen = NSScreen.screen(containing: point) ?? NSScreen.main else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        applyShortTimeout(to: systemWideElement)
        var hoveredElement: AXUIElement?
        let axX = Float(point.x)
        let axY = Float(screen.frame.maxY - point.y)

        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            axX,
            axY,
            &hoveredElement
        ) == .success,
              let element = hoveredElement,
              let menuBarItem = menuBarItemElement(from: element) else {
            return nil
        }

        return makeTrayIconInfo(from: menuBarItem)
    }

    private static func menuBarItemElement(from element: AXUIElement) -> AXUIElement? {
        var currentElement = element

        for _ in 0..<6 {
            applyShortTimeout(to: currentElement)
            var roleValue: CFTypeRef?
            if copyAttributeValue(kAXRoleAttribute as CFString, from: currentElement, into: &roleValue) == .success,
               let role = roleValue as? String,
               menuBarItemRoles.contains(role) {
                return currentElement
            }

            var parentValue: CFTypeRef?
            guard copyAttributeValue(kAXParentAttribute as CFString, from: currentElement, into: &parentValue) == .success,
                  let parent = parentValue,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return nil
            }

            currentElement = parent as! AXUIElement
        }

        return nil
    }

    private static func makeTrayIconInfo(from element: AXUIElement) -> TrayIconInfo? {
        applyShortTimeout(to: element)

        var roleValue: CFTypeRef?
        guard copyAttributeValue(kAXRoleAttribute as CFString, from: element, into: &roleValue) == .success,
              let role = roleValue as? String,
              menuBarItemRoles.contains(role) else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let frame = frame(for: element),
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        return TrayIconInfo(
            title: title(for: element, runningApp: runningApp),
            pid: pid,
            frame: frame
        )
    }

    private static func iconFromWindowList(at point: NSPoint) -> TrayIconInfo? {
        let screen = NSScreen.screen(containing: point)
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let icons = windowInfos
            .compactMap { windowCandidate(from: $0, on: screen) }
            .filter { $0.frame.insetBy(dx: -1, dy: -4).contains(point) }
            .map { iconFromWindowInfo($0.info, frame: $0.frame, fallbackPoint: point) }

        return bestIcon(from: icons)
    }

    private static func iconsFromWindowList(on screen: NSScreen?) -> [TrayIconInfo] {
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfos.compactMap { iconFromWindowInfo($0, on: screen, fallbackPoint: nil) }
            .sorted { $0.frame.midX > $1.frame.midX }
    }

    private static func iconFromWindowInfo(_ windowInfo: [String: Any], on screen: NSScreen?, fallbackPoint: NSPoint?) -> TrayIconInfo? {
        guard let candidate = windowCandidate(from: windowInfo, on: screen) else {
            return nil
        }

        return iconFromWindowInfo(candidate.info, frame: candidate.frame, fallbackPoint: fallbackPoint)
    }

    private static func windowCandidate(from windowInfo: [String: Any], on screen: NSScreen?) -> WindowCandidate? {
        guard let layer = windowInfo[kCGWindowLayer as String] as? Int,
              layer == Int(CGWindowLevelForKey(.statusWindow)),
              isStatusItemWindow(windowInfo),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = cgFloat(bounds["X"]),
              let y = cgFloat(bounds["Y"]),
              let width = cgFloat(bounds["Width"]),
              let height = cgFloat(bounds["Height"]),
              y <= 4,
              width >= 4,
              width <= 180,
              height >= 10,
              height <= 40 else {
            return nil
        }

        let frame = appKitFrame(fromCGWindowBounds: CGRect(x: x, y: y, width: width, height: height))
        if let screen, !frame.intersects(menuBarRect(on: screen)) {
            return nil
        }

        return WindowCandidate(info: windowInfo, frame: frame)
    }

    private static func isStatusItemWindow(_ windowInfo: [String: Any]) -> Bool {
        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
        let windowName = (windowInfo[kCGWindowName as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if dockAppTogglerTooltipTitle(forWindowName: windowName) != nil {
            return true
        }

        if bundleIdentifier(fromWindowName: windowName) != nil {
            return true
        }

        if isKnownMenuExtraName(windowName) {
            return true
        }

        return isGenericControlCenterItem(windowName: windowName, ownerName: ownerName)
    }

    private static func iconFromWindowInfo(_ windowInfo: [String: Any], frame: CGRect, fallbackPoint: NSPoint?) -> TrayIconInfo {
        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
        let ownerPID = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        let windowName = windowInfo[kCGWindowName as String] as? String
        let app = appIdentity(
            forWindowName: windowName,
            ownerName: ownerName,
            ownerPID: ownerPID,
            fallbackPoint: fallbackPoint
        )

        return TrayIconInfo(title: app.title, pid: app.pid, frame: frame)
    }

    private static func appIdentity(
        forWindowName windowName: String?,
        ownerName: String?,
        ownerPID: pid_t,
        fallbackPoint: NSPoint?
    ) -> (title: String, pid: pid_t) {
        let trimmedWindowName = windowName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let dockAppTogglerTitle = dockAppTogglerTooltipTitle(forWindowName: trimmedWindowName) {
            return (dockAppTogglerTitle, ownerPID)
        }

        let bundleIdentifier = bundleIdentifier(fromWindowName: trimmedWindowName)

        if let bundleIdentifier,
           let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
           let appName = runningApp.localizedName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (appName, runningApp.processIdentifier)
        }

        if let bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let bundle = Bundle(url: appURL) {
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let appName = (displayName ?? bundleName)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !appName.isEmpty {
                return (appName, ownerPID)
            }
        }

        if let bundleIdentifier,
           let fallbackName = fallbackDisplayName(forBundleIdentifier: bundleIdentifier) {
            let pid = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleIdentifier })?
                .processIdentifier ?? ownerPID
            return (fallbackName, pid)
        }

        if isGenericWindowName(trimmedWindowName),
           let fallbackPoint,
           let axIcon = iconFromElementAtPosition(fallbackPoint),
           !isGenericTitle(axIcon.title) {
            return (axIcon.title, axIcon.pid)
        }

        if !trimmedWindowName.isEmpty,
           !trimmedWindowName.hasPrefix("Item-") {
            return (displayName(forMenuExtraName: trimmedWindowName), ownerPID)
        }

        if let ownerName,
           !isControlCenter(ownerName),
           !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (ownerName, ownerPID)
        }

        if isGenericControlCenterItem(windowName: trimmedWindowName, ownerName: ownerName),
           !CGPreflightScreenCaptureAccess() {
            return ("App-Name erst nach Bildschirmaufnahme-Freigabe sichtbar", ownerPID)
        }

        return ("Tray Icon", ownerPID)
    }

    private static func dockAppTogglerTooltipTitle(forWindowName windowName: String) -> String? {
        switch windowName {
        case "dockapptoggler_hiddenbar_boundary_v2":
            return "Klicken, um versteckte Tray-Icons ein- oder auszublenden"
        case "dockapptoggler_hiddenbar_always_hidden_v1":
            return "Grenze für dauerhaft versteckte Tray-Icons"
        case "dockapptoggler_app_icon_v2":
            return "DockAppToggler"
        default:
            return nil
        }
    }

    private static func isGenericControlCenterItem(windowName: String, ownerName: String?) -> Bool {
        guard let ownerName, isControlCenter(ownerName) else { return false }
        return windowName.isEmpty ||
            windowName.hasPrefix("Item-") ||
            windowName.hasPrefix("BentoBox-") ||
            UUID(uuidString: windowName) != nil
    }

    private static func isKnownMenuExtraName(_ name: String) -> Bool {
        switch name {
        case "Clock", "WiFi", "Sound", "Battery", "Siri":
            return true
        default:
            return false
        }
    }

    private static func isGenericWindowName(_ windowName: String) -> Bool {
        windowName.isEmpty ||
            windowName.hasPrefix("Item-") ||
            windowName.hasPrefix("BentoBox-") ||
            UUID(uuidString: windowName) != nil
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ||
            normalized == "Tray Icon" ||
            normalized == "Kontrollzentrum" ||
            normalized == "Control Center"
    }

    private static func titleFallbackRank(_ title: String) -> Int {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGenericTitle(normalized) {
            return 2
        }
        if normalized.hasPrefix("App-Name erst nach Bildschirmaufnahme-Freigabe") {
            return 1
        }
        return 0
    }

    private static func isControlCenter(_ name: String) -> Bool {
        name == "Kontrollzentrum" || name == "Control Center"
    }

    private static func displayName(forMenuExtraName name: String) -> String {
        switch name {
        case "Clock":
            return "Uhr"
        case "WiFi":
            return "WLAN"
        case "Sound":
            return "Ton"
        case "Battery":
            return "Batterie"
        default:
            return name
        }
    }

    private static func fallbackDisplayName(forBundleIdentifier bundleIdentifier: String) -> String? {
        let knownNames = [
            "net.tunnelblick.tunnelblick": "Tunnelblick"
        ]
        if let knownName = knownNames[bundleIdentifier] {
            return knownName
        }

        let usefulComponents = bundleIdentifier
            .split(separator: ".")
            .map(String.init)
            .filter { component in
                !["com", "net", "org", "de", "io", "app", "macos"].contains(component.lowercased())
            }

        guard let rawName = usefulComponents.last,
              !rawName.isEmpty else {
            return nil
        }

        return rawName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func bundleIdentifier(fromWindowName windowName: String) -> String? {
        if let mainBundleIdentifier = Bundle.main.bundleIdentifier,
           windowName == mainBundleIdentifier {
            return mainBundleIdentifier
        }

        guard windowName.contains("."),
              !windowName.contains(" ") else {
            return nil
        }
        return windowName
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        if let int = value as? Int {
            return CGFloat(int)
        }
        return nil
    }

    private static func isPlausibleTrayIcon(_ icon: TrayIconInfo, on screen: NSScreen?) -> Bool {
        let frame = icon.frame
        guard frame.width >= 4,
              frame.width <= 120,
              frame.height >= 10,
              frame.height <= 40 else {
            return false
        }

        guard let screen else { return true }
        return frame.intersects(menuBarRect(on: screen))
    }

    private static func title(for element: AXUIElement, runningApp: NSRunningApplication?) -> String {
        if let runningApp,
           let appName = runningApp.localizedName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isControlCenter(appName) {
            return appName
        }

        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if copyAttributeValue(attribute as CFString, from: element, into: &value) == .success,
               let title = value as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }

        if let appName = runningApp?.localizedName,
           !isControlCenter(appName) {
            return appName
        }

        return "Tray Icon"
    }

    private static func frame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard copyAttributeValue(kAXPositionAttribute as CFString, from: element, into: &positionValue) == .success,
              copyAttributeValue(kAXSizeAttribute as CFString, from: element, into: &sizeValue) == .success,
              let positionRef = positionValue,
              let sizeRef = sizeValue,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        return appKitFrame(fromAXFrame: CGRect(origin: position, size: size))
    }

    private static func appKitFrame(fromAXFrame axFrame: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { screen in
            axFrame.midX >= screen.frame.minX && axFrame.midX <= screen.frame.maxX
        }) ?? NSScreen.main else {
            return axFrame
        }

        return CGRect(
            x: axFrame.minX,
            y: screen.frame.maxY - axFrame.minY - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )
    }

    private static func appKitFrame(fromCGWindowBounds bounds: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { screen in
            bounds.midX >= screen.frame.minX && bounds.midX <= screen.frame.maxX
        }) ?? NSScreen.main else {
            return bounds
        }

        return CGRect(
            x: bounds.minX,
            y: screen.frame.maxY - bounds.minY - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    private static func menuBarRect(on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - 40,
            width: screen.frame.width,
            height: 40
        )
    }
}
