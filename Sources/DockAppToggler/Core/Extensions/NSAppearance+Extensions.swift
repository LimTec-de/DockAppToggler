import AppKit

extension NSAppearance {
    var isDarkMode: Bool {
        self.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
} 