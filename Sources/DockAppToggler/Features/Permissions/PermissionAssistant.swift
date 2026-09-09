import AppKit

/// One permission the wizard walks the user through.
@MainActor
struct PermissionStep {
    let title: String
    let settingsURLString: String
    let isGranted: () -> Bool
    /// Newly granted access may require a relaunch after the remaining steps.
    let needsRestartToTakeEffect: Bool
    /// System consent dialogs (microphone/speech) must finish before the next step.
    let requestAccess: ((@escaping @MainActor @Sendable () -> Void) -> Void)?

    init(title: String, settingsURLString: String, isGranted: @escaping () -> Bool,
         needsRestartToTakeEffect: Bool,
         requestAccess: ((@escaping @MainActor @Sendable () -> Void) -> Void)? = nil) {
        self.title = title
        self.settingsURLString = settingsURLString
        self.isGranted = isGranted
        self.needsRestartToTakeEffect = needsRestartToTakeEffect
        self.requestAccess = requestAccess
    }
}

/// One ordered permission flow: drag the app into supported Privacy lists, or use
/// the system consent dialog. Recheck grants and defer any relaunch until the end.
@MainActor
final class PermissionAssistantWindowController: NSWindowController, NSWindowDelegate {
    private static var current: PermissionAssistantWindowController?

    static func present(steps: [PermissionStep], onGranted: @escaping () -> Void = {}) {
        if let existing = current {
            existing.completions.append(onGranted)
            existing.contentVC.update(steps: steps)
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        guard steps.contains(where: { !$0.isGranted() }) else {
            onGranted()
            return
        }

        let controller = PermissionAssistantWindowController(steps: steps, onGranted: onGranted)
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let contentVC: PermissionAssistantViewController
    private var completions: [() -> Void]

    private init(steps: [PermissionStep], onGranted: @escaping () -> Void) {
        completions = [onGranted]
        contentVC = PermissionAssistantViewController(steps: steps)
        let window = NSWindow(contentViewController: contentVC)
        window.title = "Berechtigungen erteilen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 440, height: 460))
        super.init(window: window)
        window.delegate = self
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.minX + 24, y: frame.midY - window.frame.height / 2))
        }

        contentVC.onFinished = { [weak self] in
            guard let self else { return }
            let callbacks = self.completions
            self.completions.removeAll()
            Self.current = nil
            self.close()
            callbacks.forEach { $0() }
        }
        contentVC.onRestartRequested = {
            Self.relaunchApp()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // Retain an unfinished sequence and its startup callback when dismissed.
        contentVC.stop()
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
    private let nameLabel = NSTextField(labelWithString: Bundle.main.bundleURL.lastPathComponent)
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
        guard view.window?.isVisible == true else { return }
        openButton.isEnabled = progress.requestingIndex == nil
        let nextStage = progress.refresh()
        guard nextStage != stage else { return }
        stage = nextStage

        switch nextStage {
        case .permission(let index):
            if timer == nil { startPolling() }
            let step = progress.steps[index]
            progressLabel.stringValue = "Schritt \(index + 1) von \(progress.steps.count)"
            headingLabel.stringValue = "\(step.title) erlauben"
            dragView.allowsDragging = step.requestAccess == nil
            openButton.title = step.requestAccess == nil ? "Einstellungen erneut öffnen" : "Freigabe erneut prüfen"
            instructionsLabel.stringValue = step.requestAccess != nil
                ? "Erlaube \(step.title) im macOS-Dialog. Wurde die Freigabe bereits abgelehnt, aktiviere die App in den Systemeinstellungen. Danach geht es automatisch weiter."
                : "Aktiviere \(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent) in der Liste \(step.title). Fehlt die App, ziehe das Symbol unten direkt in die Liste der Systemeinstellungen."
            if step.needsRestartToTakeEffect {
                instructionsLabel.stringValue += "\n\nFragt macOS nach einem Neustart, wähle wenn möglich „Später“. Ist der Schalter aktiv, klicke auf „weiter“. Wir starten am Ende neu und prüfen alles erneut."
            }
            statusLabel.stringValue = "Warte auf Erteilung …"
            dragView.isHidden = false
            nameLabel.isHidden = false
            openButton.isHidden = false
            continueButton.isHidden = !step.needsRestartToTakeEffect
            restartButton.isHidden = true
            requestCurrentPermission()
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
            ? "Die App startet jetzt einmal neu und prüft anschließend alle Freigaben erneut."
            : "Alle Funktionen sind bereit."
        statusLabel.stringValue = ""
        dragView.isHidden = true
        nameLabel.isHidden = true
        openButton.isHidden = true
        continueButton.isHidden = true
        restartButton.isHidden = !needsRestart
    }

    @objc private func reopenSettings() {
        requestCurrentPermission()
    }

    private func requestCurrentPermission() {
        guard case .permission(let index) = stage else { return }
        let step = progress.steps[index]
        guard let request = step.requestAccess else {
            openSettings(step.settingsURLString)
            return
        }
        guard progress.beginRequest(at: index) else { return }
        openButton.isEnabled = false
        request { [weak self] in
            guard let self else { return }
            self.progress.finishRequest()
            self.refresh()
        }
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
    var allowsDragging = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

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
        if allowsDragging { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDragging else { return }
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
