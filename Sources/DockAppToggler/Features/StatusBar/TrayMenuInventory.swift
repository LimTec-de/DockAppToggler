import AppKit
import ApplicationServices

enum TrayMenuInventory {
    @MainActor
    static func snapshot() async throws -> [TrayMenuItem] {
        guard AXIsProcessTrusted() else {
            throw TrayMenuError.message("Zum Ein-/Ausklappen der Menüleisten-Icons wird die Bedienungshilfen-Freigabe benötigt.")
        }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard app.bundleURL?.pathExtension == "app", let bundle = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, bundle)
        }
        return await Task.detached(priority: .userInitiated) {
            apps.flatMap { pid, bundle in
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.1)
                guard let bar = attribute(kAXExtrasMenuBarAttribute, of: application),
                      CFGetTypeID(bar) == AXUIElementGetTypeID(),
                      let children = attribute(kAXChildrenAttribute, of: bar as! AXUIElement) as? [AXUIElement] else {
                    return [TrayMenuItem]()
                }
                return children.compactMap { child in
                    guard let positionValue = attribute(kAXPositionAttribute, of: child),
                          let sizeValue = attribute(kAXSizeAttribute, of: child),
                          CFGetTypeID(positionValue) == AXValueGetTypeID(),
                          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                          size.width > 0, size.height > 0 else { return nil }
                    return TrayMenuItem(
                        bundleIdentifier: bundle,
                        identifier: attribute(kAXIdentifierAttribute, of: child) as? String,
                        frame: CGRect(origin: position, size: size)
                    )
                }
            }
        }.value
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    @MainActor
    static func pressFirstItem(of bundle: String) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            throw TrayMenuError.message("Die Menüleisten-App läuft nicht mehr.")
        }
        let pid = app.processIdentifier
        try await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let bar = attribute(kAXExtrasMenuBarAttribute, of: application),
                  CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let children = attribute(kAXChildrenAttribute, of: bar as! AXUIElement) as? [AXUIElement],
                  let item = children.first,
                  AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                throw TrayMenuError.message("Das Menü dieser App konnte nicht geöffnet werden.")
            }
        }.value
    }
}
