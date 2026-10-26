import Foundation

enum TrayMenuSection: Int {
    case visible, hidden, alwaysHidden
}

struct TrayMenuItem: Sendable {
    let bundleIdentifier: String
    let identifier: String?
    /// Accessibility coordinates (origin at the top left of the primary display).
    let frame: CGRect
}

struct TrayMenuLayout {
    static let systemBundles: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.campo", "com.apple.TextInputMenuAgent", "com.apple.notificationcenterui"
    ]

    let sections: [String: TrayMenuSection]
    let items: [TrayMenuItem]

    init(items: [TrayMenuItem], boundary: CGRect, alwaysHiddenBoundary: CGRect?, ownBundle: String) {
        self.items = items
        var sections: [String: TrayMenuSection] = [:]
        for item in items where item.bundleIdentifier != ownBundle && !Self.systemBundles.contains(item.bundleIdentifier) {
            let section: TrayMenuSection
            if item.frame.midX > boundary.midX {
                section = .visible
            } else if let alwaysHiddenBoundary, item.frame.midX < alwaysHiddenBoundary.midX {
                section = .alwaysHidden
            } else {
                section = .hidden
            }
            // Native visibility is per app; keep a visible sibling visible.
            let previous = sections[item.bundleIdentifier] ?? section
            sections[item.bundleIdentifier] = previous.rawValue < section.rawValue ? previous : section
        }
        self.sections = sections
    }

    func bundles(collapsed: Bool, editing: Bool) -> [String] {
        let eligible = sections.filter { editing || $0.value == .visible || (!collapsed && $0.value == .hidden) }
        return eligible.keys.sorted { lhs, rhs in
            let left = items.filter { $0.bundleIdentifier == lhs }.map(\.frame.maxX).max() ?? 0
            let right = items.filter { $0.bundleIdentifier == rhs }.map(\.frame.maxX).max() ?? 0
            return left == right ? lhs < rhs : left > right
        }
    }

    func needsOverflow(bundles: [String], safeWidth: CGFloat?, ownBundle: String) -> Bool {
        guard let safeWidth else { return false }
        let allowed = Set(bundles).union(Self.systemBundles).union([ownBundle])
        let width = items.filter { allowed.contains($0.bundleIdentifier) }
            .reduce(CGFloat.zero) { $0 + $1.frame.width + 8 }
        return width > safeWidth - 16
    }
}

enum TrayMenuError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
