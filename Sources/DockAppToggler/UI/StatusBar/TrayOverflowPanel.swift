import AppKit

/// App symbols open the corresponding original status menu. A scroll view keeps
/// every entry reachable even on the narrowest built-in display.
@MainActor
final class TrayOverflowPanel: NSObject {
    private var panel: NSPanel?
    private var select: ((String) -> Void)?

    func show(bundles: [String], on screen: NSScreen, select: @escaping (String) -> Void) throws {
        close()
        self.select = select
        let apps = NSWorkspace.shared.runningApplications
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for bundle in bundles {
            guard let app = apps.first(where: { $0.bundleIdentifier == bundle }), let image = app.icon else {
                throw TrayMenuError.message("Das App-Symbol für \(bundle) konnte nicht geladen werden.")
            }
            let button = NSButton(image: image, target: self, action: #selector(openItem(_:)))
            button.imageScaling = .scaleProportionallyDown
            button.bezelStyle = .recessed
            button.identifier = NSUserInterfaceItemIdentifier(bundle)
            button.toolTip = app.localizedName ?? bundle
            button.setAccessibilityLabel(app.localizedName ?? bundle)
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            stack.addArrangedSubview(button)
        }
        stack.layoutSubtreeIfNeeded()
        let width = min(CGFloat(bundles.count) * 42 + 16, screen.visibleFrame.width - 32)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        stack.frame = NSRect(x: 0, y: 0, width: max(width, stack.fittingSize.width), height: 52)
        scroll.documentView = stack

        let panel = NSPanel(contentRect: scroll.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = scroll
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - width - 8,
            y: screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 72
        ))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc private func openItem(_ sender: NSButton) {
        guard let bundle = sender.identifier?.rawValue else { return }
        select?(bundle)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        select = nil
    }
}
