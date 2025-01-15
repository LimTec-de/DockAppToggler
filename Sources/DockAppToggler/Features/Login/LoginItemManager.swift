import Foundation
import ServiceManagement

@MainActor
class LoginItemManager {
    static let shared = LoginItemManager()
    
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.dockapptoggler"
    
    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Fallback for older macOS versions
            return false
        }
    }
    
    func setLoginItemEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.error("Failed to \(enabled ? "enable" : "disable") login item: \(error)")
            }
        } else {
            Logger.warning("Auto-start not supported on this macOS version")
        }
    }
} 