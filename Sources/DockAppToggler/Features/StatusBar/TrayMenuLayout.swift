import Foundation

enum TrayMenuSection: Int, Sendable {
    case visible, hidden, alwaysHidden
}

struct TrayMenuItem: Sendable, Equatable {
    let bundleIdentifier: String
    /// Accessibility identifier; only read for our own markers.
    let identifier: String?
    /// Slot the menu bar renders, in accessibility coordinates (origin at the
    /// top left of the primary display).
    let frame: CGRect
}

/// The user's arrangement per app. macOS 27 only reports trustworthy positions
/// for icons it currently renders, so assignments persist and are updated
/// solely from rendered icons: a hidden icon keeps the section it was last seen in.
struct TrayMenuLayout: Equatable {
    static let systemBundles: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.campo", "com.apple.TextInputMenuAgent", "com.apple.notificationcenterui"
    ]

    enum AlwaysHiddenRule: Equatable {
        /// The user arranged all sections around this marker in editing mode.
        case arranged(CGRect)
        /// The marker is not being edited: existing assignments stay, and no
        /// icon enters the section just because macOS inserted it far left.
        case kept
        /// The section is switched off; its icons are ordinary hidden icons.
        case disabled
    }

    struct Entry: Equatable {
        var section: TrayMenuSection
        /// Menu-bar width of all icons of the app, including spacing.
        var width: CGFloat
        /// Right edge of the app's rightmost icon when it was last rendered.
        var position: CGFloat
    }

    private static let itemSpacing: CGFloat = 8
    private static let overflowMargin: CGFloat = 16

    private(set) var entries: [String: Entry] = [:]
    /// Width of the system controls and our own markers, which always stay.
    private(set) var reservedWidth: CGFloat = 0

    var sections: [String: TrayMenuSection] { entries.mapValues(\.section) }

    init() {}

    /// Updates the arrangement from the icons one menu bar currently renders.
    ///
    /// A position is not always the user's choice: macOS only remembers where
    /// an icon was dragged to, and otherwise inserts it at the far left on every
    /// launch of its app. `isChoice` is asked for every rendered app and decides
    /// whether the section its icons now sit in replaces a stored one.
    mutating func observe(_ items: [TrayMenuItem], boundary: CGRect, alwaysHidden rule: AlwaysHiddenRule, ownBundle: String,
                          isChoice: (_ bundle: String, _ section: TrayMenuSection) -> Bool = { _, _ in true }) {
        var reserved: CGFloat = 0
        var rendered: [String: Entry] = [:]
        for item in items {
            let bundle = item.bundleIdentifier
            let width = item.frame.width + Self.itemSpacing
            guard bundle != ownBundle, !Self.systemBundles.contains(bundle) else {
                reserved += width
                continue
            }
            let section: TrayMenuSection
            if item.frame.midX > boundary.midX {
                section = .visible
            } else {
                switch rule {
                case .arranged(let marker): section = item.frame.midX < marker.midX ? .alwaysHidden : .hidden
                case .kept: section = entries[bundle]?.section == .alwaysHidden ? .alwaysHidden : .hidden
                case .disabled: section = .hidden
                }
            }
            if var entry = rendered[bundle] {
                // Native visibility is per app; keep a visible sibling visible.
                if section.rawValue < entry.section.rawValue { entry.section = section }
                entry.width += width
                entry.position = max(entry.position, item.frame.maxX)
                rendered[bundle] = entry
            } else {
                rendered[bundle] = Entry(section: section, width: width, position: item.frame.maxX)
            }
        }
        if reserved > 0 { reservedWidth = reserved }
        for (bundle, var entry) in rendered {
            let isChoice = isChoice(bundle, entry.section)
            if let stored = entries[bundle], !isChoice { entry.section = stored.section }
            entries[bundle] = entry
        }
    }

    /// Apps whose icons belong in the bar for this state, rightmost first.
    func bundles(collapsed: Bool, editing: Bool, alwaysHidden: Bool) -> [String] {
        entries.filter { _, entry in
            editing || entry.section == .visible || (!collapsed && (entry.section == .hidden || !alwaysHidden))
        }.sorted { lhs, rhs in
            lhs.value.position == rhs.value.position ? lhs.key < rhs.key : lhs.value.position > rhs.value.position
        }.map(\.key)
    }

    func needsOverflow(bundles: [String], safeWidth: CGFloat?) -> Bool {
        guard let safeWidth else { return false }
        let width = bundles.reduce(reservedWidth) { $0 + (entries[$1]?.width ?? 0) }
        return width > safeWidth - Self.overflowMargin
    }

    // MARK: - Persistence

    init(propertyList: Any?) {
        guard let stored = propertyList as? [String: Any] else { return }
        reservedWidth = CGFloat(stored["reserved"] as? Double ?? 0)
        for (bundle, value) in stored["apps"] as? [String: [Double]] ?? [:] {
            guard value.count == 3, let section = TrayMenuSection(rawValue: Int(value[0])) else { continue }
            entries[bundle] = Entry(section: section, width: CGFloat(value[1]), position: CGFloat(value[2]))
        }
    }

    var propertyList: [String: Any] {
        [
            "reserved": Double(reservedWidth),
            "apps": entries.mapValues { [Double($0.section.rawValue), Double($0.width), Double($0.position)] }
        ]
    }
}

enum TrayMenuError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
