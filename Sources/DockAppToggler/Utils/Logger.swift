import Foundation

/// Centralized logging functionality with different log levels and emoji indicators
enum Logger {
    private static let perfLoggingEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["DOCKAPP_HOVER_DEBUG"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }()

    static func debug(_ message: String) {
        #if DEBUG
        print("🔍 \(message)")
        #endif
    }
    
    static func info(_ message: String) {
        #if DEBUG
        print("ℹ️ \(message)")
        #endif
    }
    
    static func warning(_ message: String) {
        print("⚠️ \(message)")
    }
    
    static func error(_ message: String) {
        print("❌ \(message)")
    }
    
    static func success(_ message: String) {
        #if DEBUG
        print("✅ \(message)")
        #endif
    }

    static func perf(_ category: String, _ message: String) {
        guard perfLoggingEnabled else { return }
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        print("⏱️ [\(uptime)] [\(category)] \(message)")
    }
}
