import AppKit

/// One permission the wizard walks the user through.
@MainActor
struct PermissionStep {
    let title: String
    let settingsURLString: String
    let isGranted: () -> Bool
    /// Some permissions (Screen Recording, Input Monitoring) only take effect after the
    /// app relaunches, so once granted the wizard restarts the app and resumes.
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
        guard steps.contains(where: { !$0.isGranted() }) else {
            AppPermissionRequester.clearPendingWizard()
            return
        }

        if let existing = current, existing.window?.isVisible == true {
            existing.contentVC.update(steps: steps)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = PermissionAssistantWindowController(steps: steps)
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let contentVC: PermissionAssistantViewController
    private var isFinishing = false
    private var isRestarting = false

    private init(steps: [PermissionStep]) {
        contentVC = PermissionAssistantViewController(steps: steps)
        let window = NSWindow(contentViewController: contentVC)
        window.title = "Berechtigungen erteilen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 380, height: 340))
        super.init(window: window)
        window.delegate = self
        window.center()

        contentVC.onFinished = { [weak self] in
            self?.isFinishing = true
            AppPermissionRequester.clearPendingWizard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.close() }
        }
        contentVC.onRestartRequested = { [weak self] in
            // Keep the pending-wizard state so it resumes after the relaunch.
            self?.isRestarting = true
            Self.relaunchApp()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // If the user dismissed the wizard themselves (not finishing, not restarting),
        // forget the pending state so it doesn't pop up again on the next launch.
        if !isFinishing && !isRestarting {
            AppPermissionRequester.clearPendingWizard()
        }
        contentVC.stop()
        Self.current = nil
    }

    override func close() {
        contentVC.stop()
        super.close()
    }

    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

@MainActor
private final class PermissionAssistantViewController: NSViewController {
    private var steps: [PermissionStep]
    private var currentIndex = 0
    private var timer: Timer?
    var onFinished: (() -> Void)?
    var onRestartRequested: (() -> Void)?

    private let progressLabel = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "")
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dragView = AppBundleDragView()
    private lazy var openButton = NSButton(title: "Einstellungen erneut öffnen", target: self, action: #selector(reopenSettings))
    private lazy var restartButton = NSButton(title: "Bereits erteilt? App neu starten", target: self, action: #selector(restartApp))

    init(steps: [PermissionStep]) {
        self.steps = steps
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
        instructionsLabel.preferredMaxLayoutWidth = 320

        let nameLabel = NSTextField(labelWithString: "DockAppToggler.app")
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor

        openButton.bezelStyle = .rounded
        restartButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [openButton, restartButton])
        buttonRow.orientation = .horizontal
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
        moveToFirstUngranted(openPane: true)
        startPolling()
    }

    func update(steps: [PermissionStep]) {
        self.steps = steps
        moveToFirstUngranted(openPane: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard currentIndex < steps.count else { return }
        let step = steps[currentIndex]
        guard step.isGranted() else { return }

        if step.needsRestartToTakeEffect {
            // Granted, but only takes effect after a relaunch — restart and resume.
            stop()
            statusLabel.stringValue = "Erteilt — App wird neu gestartet …"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onRestartRequested?()
            }
        } else {
            moveToFirstUngranted(openPane: true)
        }
    }

    private func moveToFirstUngranted(openPane: Bool) {
        guard let index = steps.firstIndex(where: { !$0.isGranted() }) else {
            showFinished()
            return
        }
        currentIndex = index
        let step = steps[index]

        progressLabel.stringValue = "Schritt \(index + 1) von \(steps.count)"
        headingLabel.stringValue = "\(step.title) erlauben"
        instructionsLabel.stringValue = "Ziehe das Symbol unten in die Liste \(step.title) der geöffneten Systemeinstellungen — wie bei einem Installer."
        statusLabel.stringValue = "Warte auf Erteilung …"
        dragView.isHidden = false
        openButton.isHidden = false
        restartButton.isHidden = false

        if openPane {
            openSettings(step.settingsURLString)
        }
    }

    private func showFinished() {
        stop()
        progressLabel.stringValue = ""
        headingLabel.stringValue = "Alle Berechtigungen erteilt ✓"
        instructionsLabel.stringValue = "Du kannst dieses Fenster schließen."
        statusLabel.stringValue = ""
        dragView.isHidden = true
        openButton.isHidden = true
        restartButton.isHidden = true
        onFinished?()
    }

    @objc private func reopenSettings() {
        guard currentIndex < steps.count else { return }
        openSettings(steps[currentIndex].settingsURLString)
    }

    @objc private func restartApp() {
        // Manual restart fallback — routes through the controller so the pending wizard
        // state is preserved and resumes after relaunch.
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
