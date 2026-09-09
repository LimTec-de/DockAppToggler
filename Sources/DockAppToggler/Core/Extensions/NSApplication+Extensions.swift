import AppKit

extension NSApplication {
    private static var isRestarting = false

    static func restart(skipUpdateCheck: Bool = true) {
        guard !isRestarting else { return }
        isRestarting = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = skipUpdateCheck ? ["--s"] : []

        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("Failed to restart application: %@", error.localizedDescription)
                    let alert = NSAlert()
                    alert.messageText = "Neustart fehlgeschlagen"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    isRestarting = false
                    return
                }

                // Let AppKit post willTerminateNotification and release the old
                // menu-bar items instead of replacing its live process with execv.
                NSApp.terminate(nil)
            }
        }
    }
}
