import AppKit
import ApplicationServices
import CoreGraphics

struct AppPermissionState: Equatable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let screenRecordingGranted: Bool

    static var current: AppPermissionState {
        AppPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }
}

@MainActor
enum AppPermissionRequester {
    @discardableResult
    static func requestAccessibilityIfNeeded(openSettings: Bool = true) -> Bool {
        AppPermissionMonitor.shared.start()
        if AXIsProcessTrusted() { return true }
        // No system prompt — the self-advancing wizard guides the user instead.
        if openSettings {
            presentWizard(titles: ["Bedienungshilfen"])
        }
        return false
    }

    @discardableResult
    static func requestInputMonitoringIfNeeded(openSettings: Bool = true) -> Bool {
        AppPermissionMonitor.shared.start()
        if CGPreflightListenEventAccess() { return true }
        if openSettings {
            presentWizard(titles: ["Eingabeüberwachung"])
        }
        return false
    }

    @discardableResult
    static func requestScreenRecordingIfNeeded(openSettings: Bool = true) -> Bool {
        AppPermissionMonitor.shared.start()
        if CGPreflightScreenCaptureAccess() { return true }
        if openSettings {
            presentWizard(titles: ["Bildschirmaufnahme"])
        }
        return false
    }

    // MARK: - Wizard

    private static let startupTitles = ["Bedienungshilfen", "Eingabeüberwachung", "Bildschirmaufnahme"]
    private static var startupCompletion: (() -> Void)?

    /// Always recheck all permissions, including after a restart or dismissed setup.
    static func checkStartupPermissions(onGranted: @escaping () -> Void) {
        startupCompletion = onGranted
        presentWizard(titles: startupTitles)
    }

    /// Permissions the tray popup needs: Accessibility (to read the other apps' icons) and
    /// Screen Recording (to render the real tray-icon images).
    static func presentTrayPopupWizard() {
        presentWizard(titles: ["Bedienungshilfen", "Bildschirmaufnahme"])
    }

    /// Permissions Window Switching needs: Accessibility (control windows) and Input
    /// Monitoring (global hotkey).
    static func presentShortcutWizard() {
        presentWizard(titles: ["Bedienungshilfen", "Eingabeüberwachung"])
    }

    static func wizardDidFinish() {
        let completion = startupCompletion
        startupCompletion = nil
        completion?()
    }

    private static func presentWizard(titles: [String]) {
        // Feature-specific requests must not replace an ongoing startup check.
        let steps = (startupCompletion == nil ? titles : startupTitles).map { step(for: $0) }
        PermissionAssistantWindowController.present(steps: steps)
    }

    private static func step(for title: String) -> PermissionStep {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch title {
        case "Bedienungshilfen":
            return PermissionStep(title: title, settingsURLString: base + "Privacy_Accessibility",
                                  isGranted: { AXIsProcessTrusted() }, needsRestartToTakeEffect: false)
        case "Bildschirmaufnahme":
            return PermissionStep(title: title, settingsURLString: base + "Privacy_ScreenCapture",
                                  isGranted: { CGPreflightScreenCaptureAccess() }, needsRestartToTakeEffect: true)
        default: // Eingabeüberwachung
            return PermissionStep(title: title, settingsURLString: base + "Privacy_ListenEvent",
                                  isGranted: { CGPreflightListenEventAccess() }, needsRestartToTakeEffect: true)
        }
    }
}

@MainActor
final class AppPermissionMonitor {
    static let shared = AppPermissionMonitor()

    private var timer: Timer?
    private var lastState = AppPermissionState.current

    private init() {}

    func start() {
        timer?.invalidate()
        lastState = AppPermissionState.current

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                AppPermissionMonitor.shared.publishIfNeeded()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func publishIfNeeded() {
        let currentState = AppPermissionState.current
        guard currentState != lastState else { return }

        lastState = currentState
        NotificationCenter.default.post(
            name: .appPermissionsChanged,
            object: nil,
            userInfo: ["state": currentState]
        )
    }
}

extension Notification.Name {
    static let appPermissionsChanged = Notification.Name("appPermissionsChanged")
}
