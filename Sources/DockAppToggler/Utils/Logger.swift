import Foundation

/// Centralized logging functionality with different log levels and emoji indicators
///
/// Messages are autoclosures: the hover and mouse-move paths log on every
/// event, and building the interpolated string (frames, app names, window
/// lists) must cost nothing while the corresponding switch is off.
enum Logger {
    private static let debugLoggingEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["DOCKAPP_DEBUG_LOGS"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }()

    private static let perfLoggingEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["DOCKAPP_HOVER_DEBUG"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }()

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard debugLoggingEnabled else { return }
        print("🔍 \(message())")
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard debugLoggingEnabled else { return }
        print("ℹ️ \(message())")
        #endif
    }

    static func warning(_ message: @autoclosure () -> String) {
        print("⚠️ \(message())")
    }

    static func error(_ message: @autoclosure () -> String) {
        print("❌ \(message())")
    }

    static func success(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard debugLoggingEnabled else { return }
        print("✅ \(message())")
        #endif
    }

    static func perf(_ category: String, _ message: @autoclosure () -> String) {
        guard perfLoggingEnabled else { return }
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        print("⏱️ [\(uptime)] [\(category)] \(message())")
    }
}
