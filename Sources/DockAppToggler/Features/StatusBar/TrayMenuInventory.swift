import AppKit
import ApplicationServices

/// The icons the menu bars really show, one list per display.
struct TrayMenuSnapshot: Sendable {
    let bars: [[TrayMenuItem]]

    /// False while the menu bar's accessibility tree cannot be read at all.
    var isReadable: Bool { bars.contains { !$0.isEmpty } }

    var renderedBundles: Set<String> { Set(bars.joined().map(\.bundleIdentifier)) }

    /// The bar on which one of our own markers can be identified.
    func bar(containing identifier: String, of bundle: String) -> [TrayMenuItem]? {
        bars.first { $0.contains { $0.bundleIdentifier == bundle && $0.identifier == identifier } }
    }
}

/// Reads the menu bar's own accessibility tree. An app's `AXExtrasMenuBar` is
/// useless for layout on macOS 27: hidden icons keep stale frames, never-shown
/// ones report a parked position, and busy apps time out. The menu bar lists
/// exactly the rendered slots, each wrapping an element of the owning process.
enum TrayMenuInventory {
    private static let menuBarBundle = "com.apple.MenuBarAgent"
    private static let maximumBarHeight: CGFloat = 64

    private struct Slot: Sendable {
        let pid: pid_t
        let identifier: String?
        let frame: CGRect
    }

    @MainActor
    static func snapshot(ownBundle: String) async throws -> TrayMenuSnapshot {
        guard AXIsProcessTrusted() else {
            throw TrayMenuError.message("Zum Ein-/Ausklappen der Menüleisten-Icons wird die Bedienungshilfen-Freigabe benötigt.")
        }
        guard let menuBar = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarBundle).first else {
            return TrayMenuSnapshot(bars: [])
        }
        let menuBarPID = menuBar.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bars = await Task.detached(priority: .userInitiated) { () -> [[Slot]] in
            let application = AXUIElementCreateApplication(menuBarPID)
            AXUIElementSetMessagingTimeout(application, 1)
            guard let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] else { return [] }
            return windows.compactMap { window -> [Slot]? in
                // Menus and Control Center panels are windows of the same process.
                guard let bar = frame(of: window), bar.height <= maximumBarHeight,
                      let slots = attribute(kAXChildrenAttribute, of: window) as? [AXUIElement] else { return nil }
                return slots.compactMap { slot in
                    guard let frame = frame(of: slot), frame.width > 0,
                          let content = (attribute(kAXChildrenAttribute, of: slot) as? [AXUIElement])?.first else { return nil }
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(content, &pid) == .success else { return nil }
                    var identifier: String?
                    if pid == ownPID {
                        AXUIElementSetMessagingTimeout(content, 1)
                        identifier = attribute(kAXIdentifierAttribute, of: content) as? String
                    }
                    return Slot(pid: pid, identifier: identifier, frame: frame)
                }
            }
        }.value

        var bundles: [pid_t: String?] = [ownPID: ownBundle]
        return TrayMenuSnapshot(bars: bars.map { slots in
            slots.compactMap { slot in
                if bundles[slot.pid] == nil {
                    bundles[slot.pid] = .some(NSRunningApplication(processIdentifier: slot.pid)?.bundleIdentifier)
                }
                guard let bundle = bundles[slot.pid] ?? nil else { return nil }
                return TrayMenuItem(bundleIdentifier: bundle, identifier: slot.identifier, frame: slot.frame)
            }
        })
    }

    /// Whether the app itself reports status items, rendered or not.
    static func claimsStatusItems(pid: pid_t) async -> Bool {
        await Task.detached(priority: .utility) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.5)
            guard let children = extras(of: application) else { return false }
            return !children.isEmpty
        }.value
    }

    @MainActor
    static func pressFirstItem(of bundle: String) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            throw TrayMenuError.message("Die Menüleisten-App läuft nicht mehr.")
        }
        let pid = app.processIdentifier
        try await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.5)
            guard let item = extras(of: application)?.first,
                  AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                throw TrayMenuError.message("Das Menü dieser App konnte nicht geöffnet werden.")
            }
        }.value
    }

    private static func extras(of application: AXUIElement) -> [AXUIElement]? {
        guard let bar = attribute(kAXExtrasMenuBarAttribute, of: application),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return attribute(kAXChildrenAttribute, of: bar as! AXUIElement) as? [AXUIElement]
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(kAXPositionAttribute, of: element),
              let sizeValue = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
