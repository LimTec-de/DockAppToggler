import Foundation

/// Centralized logging functionality with different log levels and emoji indicators
enum Logger {
    static func debug(_ message: String) {
        print("🔍 \(message)")
    }
    
    static func info(_ message: String) {
        print("ℹ️ \(message)")
    }
    
    static func warning(_ message: String) {
        print("⚠️ \(message)")
    }
    
    static func error(_ message: String) {
        print("❌ \(message)")
    }
    
    static func success(_ message: String) {
        print("✅ \(message)")
    }
} 