import AppKit

/// One permission the wizard walks the user through.
@MainActor
struct PermissionStep {
    let title: String
    let settingsURLString: String
    let isGranted: () -> Bool
    /// Newly granted access may require a relaunch after the remaining steps.
    let needsRestartToTakeEffect: Bool
}

/// An installer-style, self-advancing wizard. It shows the DockAppToggler.app icon to drag
/// into the Privacy list, opens the matching System Settings pane automatically, and polls
/// the grant state — once a step is granted it jumps to the next ungranted one (opening its
/// pane without asking again). Closes itself when everything is granted.
@MainActor
final class PermissionAssistantWindowController: NSWindowController, NSWindowDelegate {
    private static var current: PermissionAssistantWindowController?

    static func present(steps: [PermissionStep]) {
        if let existing = current, existing.window?.isVisible == true {
            existing.contentVC.update(steps: steps)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        guard steps.contains(where: { !$0.isGranted() }) else {
            AppPermissionRequester.wizardDidFinish()
            return
        }

        let controller = PermissionAssistantWindowController(steps: steps)
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let contentVC: PermissionAssistantViewController

    private init(steps: [PermissionStep]) {
        contentVC = PermissionAssistantViewController(steps: steps)
        let window = NSWindow(contentViewController: contentVC)
        window.title = "Berechtigungen erteilen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 440, height: 460))
        super.init(window: window)
        window.delegate = self
        window.center()

        contentVC.onFinished = { [weak self] in
            self?.close()
            AppPermissionRequester.wizardDidFinish()
        }
        contentVC.onRestartRequested = {
            Self.relaunchApp()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        contentVC.stop()
        Self.current = nil
    }

    override func close() {
        contentVC.stop()
        super.close()
    }

    static func relaunchApp() {
        NSApplication.restart()
    }
}

@MainActor
private final class PermissionAssistantViewController: NSViewController {
    private var progress: PermissionWizardProgress
    private var stage: PermissionWizardProgress.Stage?
    private var timer: Timer?
    var onFinished: (() -> Void)?
    var onRestartRequested: (() -> Void)?

    private let progressLabel = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "")
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dragView = AppBundleDragView()
    private let nameLabel = NSTextField(labelWithString: "DockAppToggler.app")
    private lazy var openButton = NSButton(title: "Einstellungen erneut öffnen", target: self, action: #selector(reopenSettings))
    private lazy var continueButton = NSButton(title: "In Einstellungen erlaubt – weiter", target: self, action: #selector(confirmGrant))
    private lazy var restartButton = NSButton(title: "Jetzt neu starten", target: self, action: #selector(restartApp))

    init(steps: [PermissionStep]) {
        progress = PermissionWizardProgress(steps: steps)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor

        headingLabel.font = .boldSystemFont(ofSize: 16)
        headingLabel.alignment = .center

        instructionsLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.alignment = .center
        instructionsLabel.preferredMaxLayoutWidth = 392

        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor

        openButton.bezelStyle = .rounded
        continueButton.bezelStyle = .rounded
        restartButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [openButton, continueButton, restartButton])
        buttonRow.orientation = .vertical
        buttonRow.spacing = 8

        stack.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(headingLabel)
        stack.addArrangedSubview(instructionsLabel)
        stack.addArrangedSubview(dragView)
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(4, after: dragView)
        stack.setCustomSpacing(16, after: statusLabel)
        stack.addArrangedSubview(buttonRow)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startPolling()
        refresh()
    }

    func update(steps: [PermissionStep]) {
        progress.include(steps: steps)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let nextStage = progress.refresh()
        guard nextStage != stage else { return }
        stage = nextStage

        switch nextStage {
        case .permission(let index):
            if timer == nil { startPolling() }
            let step = progress.steps[index]
            progressLabel.stringValue = "Schritt \(index + 1) von \(progress.steps.count)"
            headingLabel.stringValue = "\(step.title) erlauben"
            instructionsLabel.stringValue = "Aktiviere DockAppToggler in der Liste \(step.title). Fehlt die App, ziehe das Symbol unten in die Liste."
            if step.needsRestartToTakeEffect {
                instructionsLabel.stringValue += "\n\nFragt macOS nach einem Neustart, wähle wenn möglich „Später“. Ist der Schalter aktiv, klicke auf „weiter“. Wir starten am Ende neu und prüfen alles erneut."
            }
            statusLabel.stringValue = "Warte auf Erteilung …"
            dragView.isHidden = false
            nameLabel.isHidden = false
            openButton.isHidden = false
            continueButton.isHidden = !step.needsRestartToTakeEffect
            restartButton.isHidden = true
            openSettings(step.settingsURLString)
        case .restart:
            showFinished(needsRestart: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view.window?.isVisible == true, self.stage == .restart else { return }
                self.onRestartRequested?()
            }
        case .complete:
            showFinished(needsRestart: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stage == .complete else { return }
                self.onFinished?()
            }
        }
    }

    private func showFinished(needsRestart: Bool) {
        stop()
        progressLabel.stringValue = ""
        headingLabel.stringValue = needsRestart ? "Einrichtung abgeschlossen" : "Alle Berechtigungen erteilt ✓"
        instructionsLabel.stringValue = needsRestart
            ? "DockAppToggler startet jetzt einmal neu und prüft anschließend alle Freigaben erneut."
            : "Alle Funktionen sind bereit."
        statusLabel.stringValue = ""
        dragView.isHidden = true
        nameLabel.isHidden = true
        openButton.isHidden = true
        continueButton.isHidden = true
        restartButton.isHidden = !needsRestart
    }

    @objc private func reopenSettings() {
        guard case .permission(let index) = stage else { return }
        openSettings(progress.steps[index].settingsURLString)
    }

    @objc private func confirmGrant() {
        guard case .permission(let index) = stage else { return }
        progress.confirmGrant(at: index)
        refresh()
    }

    @objc private func restartApp() {
        guard stage == .restart else { return }
        stop()
        onRestartRequested?()
    }

    private func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stop()
    }
}

/// Shows the app's own icon and acts as a drag source providing the .app bundle's file URL,
/// so it can be dropped onto the Privacy & Security permission list.
@MainActor
private final class AppBundleDragView: NSView, NSDraggingSource {
    private let iconSize: CGFloat = 84

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: iconSize),
            heightAnchor.constraint(equalToConstant: iconSize)
        ])

        let imageView = NSImageView()
        imageView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Route mouse events to this view, not the image subview, so dragging starts.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let bundleURL = Bundle.main.bundleURL
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = bounds.size

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
