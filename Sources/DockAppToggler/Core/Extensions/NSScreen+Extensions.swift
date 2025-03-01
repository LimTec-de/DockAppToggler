import AppKit

extension NSScreen {
    /// Checks if "Displays have separate spaces" is enabled in Mission Control settings
    static var displaysHaveSeparateSpaces: Bool {
        // This setting is stored in the com.apple.spaces preference domain
        let defaults = UserDefaults(suiteName: "com.apple.spaces")
        return defaults?.bool(forKey: "spans-displays") == false
    }
    
    /// Returns all screens that should have the app visible based on spaces configuration
    static var screensForAppVisibility: [NSScreen] {
        if displaysHaveSeparateSpaces {
            // When displays have separate spaces, we need to be visible on all screens
            return NSScreen.screens
        } else {
            // When displays share spaces, we only need to be on the main screen
            if let mainScreen = NSScreen.main {
                return [mainScreen]
            } else {
                return NSScreen.screens
            }
        }
    }
} 