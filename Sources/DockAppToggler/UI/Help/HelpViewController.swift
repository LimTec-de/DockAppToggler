import AppKit

@MainActor
class HelpViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Willkommen bei DockAppToggler")
    private let featuresTextView = NSTextView()
    private let dontShowAgainCheckbox = NSButton(checkboxWithTitle: "Diese Hilfe beim naechsten Start nicht anzeigen", target: nil, action: nil)
    private let closeButton = NSButton(title: "Schliessen", target: nil, action: nil)
    
    override func loadView() {
        // Create main view
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 520))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
        
        // Configure title
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: 440, width: 460, height: 40)
        view.addSubview(titleLabel)
        
        // Configure features text
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 100, width: 460, height: 340))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        
        featuresTextView.isEditable = false
        featuresTextView.font = .systemFont(ofSize: 14)
        featuresTextView.textContainer?.lineFragmentPadding = 0
        
        let features = """
        DockAppToggler erweitert das Dock um schnelle Fenstersteuerung:

        Fensterauswahl
        - Fahre mit der Maus ueber ein Dock-Icon, um die Fenster der App im Menu zu sehen.
        - Klicke auf einen Eintrag, um genau dieses Fenster in den Vordergrund zu holen.
        - Doppelklick auf einen Eintrag: Fenster fokussieren und andere minimieren.

        Fensteraktionen im Menu
        - Schliessen, minimieren, links/rechts andocken
        - Zentrieren oder maximieren
        - Fenster auf einen anderen Bildschirm verschieben

        Preview-Panel
        - Wenn "Window Previews" aktiv ist, wird beim Hover eine Vorschau angezeigt.
        - Falls keine Vorschau verfuegbar ist, wird stattdessen das App-Icon angezeigt.

        Screenshot
        - "Take Screenshot (⌥P)" startet den Capture-Editor.
        - Optionaler globaler Shortcut: "Option+P Screenshot" (im Tray-Menue aktivierbar).
        - Im Editor: ESC beendet, Entf/Backspace loescht ausgewaehlte Elemente.

        Tastatur
        - Option+Tab Switching: Fensterumschaltung ueber die Tastatur.
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
        closeButton.frame = NSRect(x: 200, y: 20, width: 100, height: 32)
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
