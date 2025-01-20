import AppKit

@MainActor
class HelpViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Welcome to DockAppToggler!")
    private let featuresTextView = NSTextView()
    private let dontShowAgainCheckbox = NSButton(checkboxWithTitle: "Don't show this help on next startup", target: nil, action: nil)
    private let closeButton = NSButton(title: "Got it!", target: nil, action: nil)
    
    override func loadView() {
        // Create main view
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 520))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
        
        // Configure title
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: 440, width: 360, height: 40)
        view.addSubview(titleLabel)
        
        // Configure features text
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 100, width: 460, height: 340))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        
        featuresTextView.isEditable = false
        featuresTextView.font = .systemFont(ofSize: 14)
        featuresTextView.textContainer?.lineFragmentPadding = 0
        
        let features = """
        DockAppToggler enhances your Mac's Dock with powerful window management features:
        
        🖱 Window Selection
        • Hover over a Dock icon to see all windows of that app
        • Single-click on Dock icon to show all non-minimized windows
        • Single-click on List-Item to bring a window to the front
        • Double-click on List-Item to bring a window to front and minimize other windows
        
        🎯 Window Actions
        • Click the close button (×) to close a window
        • Click the minimize button (-) to minimize
        • Click left/right icon to snap window left/right
        • Click center icon to center/maximize a window
        • Double-click center icon to move window to secondary screen

        🔔 Tray Tooltips
        • Hover over tray icon to see a tooltip showing the application name
        """
        
        featuresTextView.string = features
        featuresTextView.frame = scrollView.bounds
        scrollView.documentView = featuresTextView
        view.addSubview(scrollView)
        
        // Configure checkbox
        dontShowAgainCheckbox.frame = NSRect(x: 20, y: 60, width: 360, height: 20)
        dontShowAgainCheckbox.target = self
        dontShowAgainCheckbox.action = #selector(toggleDontShowAgain)
        // Set initial state from UserDefaults
        dontShowAgainCheckbox.state = UserDefaults.standard.bool(forKey: "HideHelpOnStartup") ? .on : .off
        view.addSubview(dontShowAgainCheckbox)
        
        // Configure close button
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 150, y: 20, width: 100, height: 32)
        closeButton.target = self
        closeButton.action = #selector(closeHelp)
        view.addSubview(closeButton)
    }
    
    @objc private func toggleDontShowAgain() {
        UserDefaults.standard.set(dontShowAgainCheckbox.state == .on, forKey: "HideHelpOnStartup")
    }
    
    @objc private func closeHelp() {
        view.window?.close()
    }
    
    static func shouldShowHelp() -> Bool {
        !UserDefaults.standard.bool(forKey: "HideHelpOnStartup")
    }
} 