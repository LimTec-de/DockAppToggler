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
        window.setContentSize(NSSize(width: 540, height: 560))
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
    private var automaticallyRequestedStage: PermissionWizardProgress.Stage?
    private var timer: Timer?
    var onFinished: (() -> Void)?
    var onRestartRequested: (() -> Void)?

    private let appDisplayName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    private let progressLabel = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "")
    private let overviewView = PermissionOverviewView()
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dragGuideView = PermissionDragGuideView()
    private lazy var openButton = NSButton(title: "Einstellungen erneut öffnen", target: self, action: #selector(reopenSettings))
    private lazy var continueButton = NSButton(title: "Ich habe es aktiviert", target: self, action: #selector(confirmGrant))
    private lazy var restartButton = NSButton(title: "\(appDisplayName) neu starten", target: self, action: #selector(restartApp))
    private lazy var laterButton = NSButton(title: "Später", target: self, action: #selector(closeForLater))

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
        instructionsLabel.preferredMaxLayoutWidth = 492

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor

        openButton.bezelStyle = .rounded
        continueButton.bezelStyle = .rounded
        restartButton.bezelStyle = .rounded
        laterButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [openButton, continueButton, restartButton, laterButton])
        buttonRow.orientation = .vertical
        buttonRow.spacing = 8

        stack.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(headingLabel)
        stack.addArrangedSubview(overviewView)
        stack.addArrangedSubview(instructionsLabel)
        stack.addArrangedSubview(dragGuideView)
        stack.addArrangedSubview(statusLabel)
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
        automaticallyRequestedStage = nil
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
        let currentIndex: Int?
        if case .permission(let index) = nextStage {
            currentIndex = index
        } else {
            currentIndex = nil
        }
        overviewView.update(steps: progress.steps, currentIndex: currentIndex)
        let stageChanged = nextStage != stage
        if stageChanged {
            stage = nextStage
        }

        switch nextStage {
        case .permission(let index):
            if stageChanged {
                if timer == nil { startPolling() }
                let step = progress.steps[index]
                let missingTitles = progress.steps.filter { !$0.isGranted() }.map(\.title)
                progressLabel.stringValue = missingTitles.isEmpty
                    ? "Alles erledigt"
                    : "Noch offen: \(missingTitles.joined(separator: ", "))"
                headingLabel.stringValue = "Berechtigungen einrichten"
                dragGuideView.permissionTitle = step.title
                dragGuideView.allowsDragging = step.requestAccess == nil
                openButton.title = step.requestAccess == nil ? "Zu \(step.title) öffnen" : "Freigabe erneut prüfen"
                instructionsLabel.stringValue = step.requestAccess != nil
                    ? "Erlaube \(step.title) im macOS-Dialog. Wurde die Freigabe bereits abgelehnt, öffnet der Assistent die passende Systemeinstellung automatisch. Danach geht es automatisch weiter."
                    : "Aktiviere \(appDisplayName) in der automatisch geöffneten Liste \(step.title). Fehlt die App dort, ziehe das App-Symbol aus der Grafik direkt in die Liste."
                if step.needsRestartToTakeEffect {
                    instructionsLabel.stringValue += "\n\nWenn macOS nach einem Neustart fragt, wähle erstmal „Später“. Am Ende bietet \(appDisplayName) genau einen App-Neustart an."
                }
                statusLabel.stringValue = "Prüfe im Hintergrund …"
                dragGuideView.isHidden = step.requestAccess != nil
                openButton.isHidden = false
                continueButton.isHidden = !step.needsRestartToTakeEffect
                restartButton.isHidden = true
                laterButton.isHidden = true
            }
            if automaticallyRequestedStage != nextStage {
                automaticallyRequestedStage = nextStage
                requestCurrentPermission()
            }
        case .restart:
            guard stageChanged else { return }
            showFinished(needsRestart: true)
        case .complete:
            guard stageChanged else { return }
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
        headingLabel.stringValue = needsRestart ? "Ein Neustart reicht" : "Alle Berechtigungen erteilt ✓"
        instructionsLabel.stringValue = needsRestart
            ? "macOS übernimmt manche Freigaben erst nach einem App-Neustart. Du kannst jetzt \(appDisplayName) einmal neu starten oder das Fenster schließen und später neu starten."
            : "Alle Funktionen sind bereit."
        statusLabel.stringValue = ""
        dragGuideView.isHidden = true
        openButton.isHidden = true
        continueButton.isHidden = true
        restartButton.isHidden = !needsRestart
        laterButton.isHidden = !needsRestart
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

    @objc private func closeForLater() {
        stop()
        view.window?.close()
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

@MainActor
private final class PermissionOverviewView: NSStackView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 492).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(steps: [PermissionStep], currentIndex: Int?) {
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, step) in steps.enumerated() {
            let granted = step.isGranted()
            let active = index == currentIndex
            addArrangedSubview(PermissionOverviewRow(title: step.title, granted: granted, active: active))
        }
    }
}

@MainActor
private final class PermissionOverviewRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let active: Bool

    init(title: String, granted: Bool, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor

        let stateLabel = NSTextField(labelWithString: granted ? "✓" : active ? "●" : "○")
        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.textColor = granted ? .systemGreen : active ? .controlAccentColor : .tertiaryLabelColor
        stateLabel.alignment = .center
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor

        statusLabel.stringValue = granted ? "Erteilt" : active ? "Jetzt aktivieren" : "Offen"
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = granted ? .systemGreen : active ? .controlAccentColor : .secondaryLabelColor

        let row = NSStackView(views: [stateLabel, titleLabel, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            stateLabel.widthAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class PermissionDragGuideView: NSView {
    private let appDragView = AppBundleDragView()
    private let appCaption = NSTextField(labelWithString: "Dieses Symbol ziehen")
    private let targetCaption = NSTextField(labelWithString: "in die Liste fallen lassen")
    private let targetView = PermissionDropTargetIllustrationView()

    var permissionTitle: String = "" {
        didSet { targetView.permissionTitle = permissionTitle }
    }

    var allowsDragging: Bool {
        get { appDragView.allowsDragging }
        set {
            appDragView.allowsDragging = newValue
            alphaValue = newValue ? 1.0 : 0.55
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor

        appCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        appCaption.textColor = .labelColor
        appCaption.alignment = .center

        targetCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        targetCaption.textColor = .labelColor
        targetCaption.alignment = .center

        [appDragView, appCaption, targetView, targetCaption].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 492),
            heightAnchor.constraint(equalToConstant: 152),

            appDragView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            appDragView.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            appCaption.centerXAnchor.constraint(equalTo: appDragView.centerXAnchor),
            appCaption.topAnchor.constraint(equalTo: appDragView.bottomAnchor, constant: 8),
            appCaption.widthAnchor.constraint(equalToConstant: 150),

            targetView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            targetView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            targetView.widthAnchor.constraint(equalToConstant: 192),
            targetView.heightAnchor.constraint(equalToConstant: 94),

            targetCaption.centerXAnchor.constraint(equalTo: targetView.centerXAnchor),
            targetCaption.topAnchor.constraint(equalTo: targetView.bottomAnchor, constant: 8),
            targetCaption.widthAnchor.constraint(equalToConstant: 190)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let start = NSPoint(x: 132, y: 88)
        let end = NSPoint(x: bounds.width - 242, y: 88)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: NSPoint(x: 178, y: 116), controlPoint2: NSPoint(x: 222, y: 116))
        path.lineWidth = 3
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - 12, y: end.y + 8))
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - 4, y: end.y - 14))
        head.lineWidth = 3
        head.stroke()
    }
}

@MainActor
private final class PermissionDropTargetIllustrationView: NSView {
    var permissionTitle: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        drawText("Datenschutz", in: NSRect(x: 12, y: 9, width: bounds.width - 24, height: 18),
                 font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        drawText(permissionTitle.isEmpty ? "Berechtigung" : permissionTitle,
                 in: NSRect(x: 12, y: 28, width: bounds.width - 24, height: 18),
                 font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)

        let dropRect = NSRect(x: 10, y: 54, width: bounds.width - 20, height: 28)
        let dropPath = NSBezierPath(roundedRect: dropRect, xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        dropPath.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        dropPath.setLineDash([4, 3], count: 2, phase: 0)
        dropPath.lineWidth = 1.4
        dropPath.stroke()

        let appIconRect = NSRect(x: dropRect.minX + 8, y: dropRect.minY + 6, width: 16, height: 16)
        let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        appIcon.draw(in: appIconRect)
        let appName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        drawText("\(appName) hier ablegen",
                 in: NSRect(x: dropRect.minX + 30, y: dropRect.minY + 6, width: dropRect.width - 38, height: 17),
                 font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
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
