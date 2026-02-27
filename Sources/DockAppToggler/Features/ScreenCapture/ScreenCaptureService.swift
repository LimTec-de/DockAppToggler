import Foundation
import AppKit

enum ScreenCaptureService {
    static func captureInteractiveToClipboard() {
        Task { @MainActor in
            let captureView = ContentView()
            captureView.captureScreen()
        }
    }

    static func captureWindowPickToClipboard() {
        Task { @MainActor in
            let captureView = ContentView()
            captureView.capturePickedWindowForEditing()
        }
    }
}
