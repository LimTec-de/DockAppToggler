import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(checkForUpdates: (() -> Void)?, trayLimitChanged: (() -> Void)?) {
        let viewController = SettingsViewController(
            checkForUpdates: checkForUpdates,
            trayLimitChanged: trayLimitChanged
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "DockAppToggler Einstellungen"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 660))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        (window?.contentViewController as? SettingsViewController)?.finishShortcutRecording()
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let checkForUpdates: (() -> Void)?
    private let trayLimitChanged: (() -> Void)?

    private var autostartCheckbox: NSButton!
    private var tooltipsCheckbox: NSButton!
    private var optionTabCheckbox: NSButton!
    private var previewsCheckbox: NSButton!
    private var trayLimitCheckbox: NSButton!
    private var shortcutButton: NSButton!
    private var accessibilityStatusLabel: NSTextField!
    private var inputMonitoringStatusLabel: NSTextField!
    private var screenRecordingStatusLabel: NSTextField!
    private nonisolated(unsafe) var shortcutRecordingMonitor: Any?
    private nonisolated(unsafe) var permissionsObserver: NSObjectProtocol?

    init(checkForUpdates: (() -> Void)?, trayLimitChanged: (() -> Void)?) {
        self.checkForUpdates = checkForUpdates
        self.trayLimitChanged = trayLimitChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(makeTitle("Einstellungen"))
        addSettingsSection(to: stackView)
        stackView.addArrangedSubview(makeSeparator())
        addShortcutSection(to: stackView)
        stackView.addArrangedSubview(makeSeparator())
        addPermissionsSection(to: stackView)
        stackView.addArrangedSubview(makeSeparator())
        addActionSection(to: stackView)

        contentView.addSubview(stackView)
        scrollView.documentView = contentView
        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        view = rootView
        refreshState()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        permissionsObserver = NotificationCenter.default.addObserver(
            forName: .appPermissionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionLabels()
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshState()
        AppPermissionMonitor.shared.start()
    }

    override func viewWillDisappear() {
        finishShortcutRecording()
        super.viewWillDisappear()
    }

    private func addSettingsSection(to stackView: NSStackView) {
        stackView.addArrangedSubview(makeSectionTitle("Allgemein"))

        autostartCheckbox = makeCheckbox(title: "Beim Anmelden starten", action: #selector(toggleAutostart(_:)))
        tooltipsCheckbox = makeCheckbox(title: "Tray-Tooltips aktivieren", action: #selector(toggleTooltips(_:)))
        optionTabCheckbox = makeCheckbox(title: "Window Switching aktivieren", action: #selector(toggleOptionTab(_:)))
        previewsCheckbox = makeCheckbox(title: "Fenstervorschauen aktivieren", action: #selector(toggleWindowPreviews(_:)))
        trayLimitCheckbox = makeCheckbox(title: "Tray-Iconbegrenzung aktivieren", action: #selector(toggleTrayIconLimit(_:)))

        for checkbox in [autostartCheckbox!, tooltipsCheckbox!, optionTabCheckbox!, previewsCheckbox!, trayLimitCheckbox!] {
            stackView.addArrangedSubview(checkbox)
        }
    }

    private func addShortcutSection(to stackView: NSStackView) {
        stackView.addArrangedSubview(makeSectionTitle("Shortcut"))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Window Switching")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        shortcutButton = NSButton(
            title: KeyboardShortcut.savedSwitchingShortcut.displayString,
            target: self,
            action: #selector(startShortcutRecording)
        )
        shortcutButton.bezelStyle = .rounded
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(shortcutButton)
        stackView.addArrangedSubview(row)
    }

    private func addPermissionsSection(to stackView: NSStackView) {
        stackView.addArrangedSubview(makeSectionTitle("Berechtigungen"))
        stackView.addArrangedSubview(makeDescription(
            "macOS zeigt Berechtigungen pro App an. Nach dem Erteilen erkennt DockAppToggler die Änderung automatisch; ein Neustart ist normalerweise nicht nötig."
        ))

        accessibilityStatusLabel = NSTextField(labelWithString: "")
        inputMonitoringStatusLabel = NSTextField(labelWithString: "")
        screenRecordingStatusLabel = NSTextField(labelWithString: "")

        stackView.addArrangedSubview(makePermissionRow(
            title: "Bedienungshilfen",
            description: "Benötigt für Dock-/Fensteraktionen und um Tray-Icons für Tooltips per Accessibility zu erkennen.",
            statusLabel: accessibilityStatusLabel,
            action: #selector(requestAccessibilityAccess)
        ))
        stackView.addArrangedSubview(makePermissionRow(
            title: "Eingabeüberwachung",
            description: "Benötigt für globale Shortcuts wie Window Switching, auch wenn DockAppToggler nicht fokussiert ist.",
            statusLabel: inputMonitoringStatusLabel,
            action: #selector(requestInputMonitoringAccess)
        ))
        stackView.addArrangedSubview(makePermissionRow(
            title: "Bildschirmaufnahme",
            description: "Benötigt für Fenstervorschauen und genaue App-Namen in Tray-Tooltips. Die Tray-Iconbegrenzung verwendet sie nicht.",
            statusLabel: screenRecordingStatusLabel,
            action: #selector(requestScreenRecordingAccess)
        ))

        refreshPermissionLabels()
    }

    private func addActionSection(to stackView: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        if checkForUpdates != nil {
            let updateButton = NSButton(title: "Nach Updates suchen", target: self, action: #selector(checkForUpdatesClicked))
            updateButton.bezelStyle = .rounded
            row.addArrangedSubview(updateButton)
        }

        let restartButton = NSButton(title: "Neustart", target: self, action: #selector(restartClicked))
        restartButton.bezelStyle = .rounded
        row.addArrangedSubview(restartButton)
        stackView.addArrangedSubview(row)
    }

    private func refreshState() {
        autostartCheckbox?.state = LoginItemManager.shared.isLoginItemEnabled ? .on : .off
        tooltipsCheckbox?.state = UserDefaults.standard.bool(forKey: "StatusBarTooltipsEnabled", defaultValue: false) ? .on : .off
        optionTabCheckbox?.state = UserDefaults.standard.bool(forKey: "OptionTabEnabled", defaultValue: false) ? .on : .off
        previewsCheckbox?.state = WindowThumbnailView.arePreviewsDisabled() ? .off : .on
        trayLimitCheckbox?.state = UserDefaults.standard.bool(forKey: "TrayIconLimitEnabled", defaultValue: false) ? .on : .off
        shortcutButton?.title = KeyboardShortcut.savedSwitchingShortcut.displayString
        refreshPermissionLabels()
    }

    private func refreshPermissionLabels() {
        let state = AppPermissionState.current
        updateStatusLabel(accessibilityStatusLabel, granted: state.accessibilityGranted)
        updateStatusLabel(inputMonitoringStatusLabel, granted: state.inputMonitoringGranted)
        updateStatusLabel(screenRecordingStatusLabel, granted: state.screenRecordingGranted)
    }

    private func updateStatusLabel(_ label: NSTextField?, granted: Bool) {
        label?.stringValue = granted ? "Erteilt" : "Fehlt"
        label?.textColor = granted ? .systemGreen : .systemOrange
    }

    @objc private func toggleAutostart(_ sender: NSButton) {
        LoginItemManager.shared.setLoginItemEnabled(sender.state == .on)
        refreshState()
    }

    @objc private func toggleTooltips(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "StatusBarTooltipsEnabled")
        NotificationCenter.default.post(name: .statusBarTooltipsStateChanged, object: nil)
        // Tray tooltips use Accessibility as a fallback and Screen Recording for
        // the menu-bar window names that identify third-party status items.
        if enabled { AppPermissionRequester.presentTrayPopupWizard() }
    }

    @objc private func toggleOptionTab(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "OptionTabEnabled")
        NotificationCenter.default.post(name: .optionTabStateChanged, object: nil, userInfo: ["enabled": enabled])
        // Window Switching needs Accessibility (window control) + Input Monitoring (hotkey).
        if enabled { AppPermissionRequester.presentShortcutWizard() }
    }

    @objc private func toggleWindowPreviews(_ sender: NSButton) {
        let enabled = sender.state == .on
        let currentEnabled = !WindowThumbnailView.arePreviewsDisabled()
        if currentEnabled != enabled {
            WindowThumbnailView.togglePreviews()
        }
        UserDefaults.standard.set(enabled, forKey: "WindowPreviewsEnabled")
        // Window previews capture the windows → Screen Recording.
        if enabled { AppPermissionRequester.requestScreenRecordingIfNeeded() }
    }

    @objc private func toggleTrayIconLimit(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "TrayIconLimitEnabled")
        trayLimitChanged?()
    }

    @objc private func startShortcutRecording() {
        KeyboardShortcutMonitor.shared.setShortcutRecording(true)
        shortcutButton.title = "Shortcut drücken..."
        if let shortcutRecordingMonitor {
            NSEvent.removeMonitor(shortcutRecordingMonitor)
        }

        shortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shortcutRecordingMonitor != nil,
                  event.window === self.view.window else { return event }
            self.handleShortcutRecording(event)
            return nil
        }
    }

    private func handleShortcutRecording(_ event: NSEvent) {
        if event.keyCode == kVK_Escape {
            finishShortcutRecording()
            return
        }

        guard let shortcut = KeyboardShortcut.from(event: event) else { return }
        KeyboardShortcut.saveSwitchingShortcut(shortcut)
        shortcutButton.title = shortcut.displayString
        finishShortcutRecording()
    }

    func finishShortcutRecording() {
        guard let shortcutRecordingMonitor else { return }
        NSEvent.removeMonitor(shortcutRecordingMonitor)
        self.shortcutRecordingMonitor = nil
        KeyboardShortcutMonitor.shared.setShortcutRecording(false)
        shortcutButton.title = KeyboardShortcut.savedSwitchingShortcut.displayString
    }

    @objc private func requestAccessibilityAccess() {
        AppPermissionRequester.requestAccessibilityIfNeeded(openSettings: true)
        refreshPermissionLabels()
    }

    @objc private func requestInputMonitoringAccess() {
        AppPermissionRequester.requestInputMonitoringIfNeeded(openSettings: true)
        refreshPermissionLabels()
    }

    @objc private func requestScreenRecordingAccess() {
        AppPermissionRequester.requestScreenRecordingIfNeeded(openSettings: true)
        refreshPermissionLabels()
    }

    @objc private func checkForUpdatesClicked() {
        checkForUpdates?()
    }

    @objc private func restartClicked() {
        StatusBarController.performRestart()
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 22)
        return label
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func makeDescription(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private func makeCheckbox(title: String, action: Selector) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        return checkbox
    }

    private func makeSmallButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func makePermissionRow(
        title: String,
        description: String,
        statusLabel: NSTextField,
        action: Selector
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        let button = NSButton(title: "Anfordern", target: self, action: action)
        button.bezelStyle = .rounded

        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(statusLabel)
        headerRow.addArrangedSubview(button)

        row.addArrangedSubview(headerRow)
        row.addArrangedSubview(makeDescription(description))
        return row
    }

    deinit {
        if let shortcutRecordingMonitor {
            NSEvent.removeMonitor(shortcutRecordingMonitor)
        }
        if let permissionsObserver {
            NotificationCenter.default.removeObserver(permissionsObserver)
        }
    }
}
