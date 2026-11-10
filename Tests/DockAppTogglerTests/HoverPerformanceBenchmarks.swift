import AppKit
import ApplicationServices
import Testing
@testable import DockAppToggler

// Opt-in measurement of the dock-hover pipeline against the apps that are
// really running: DOCKAPP_BENCH=1 swift test ... --filter HoverPerformanceBenchmarks
// Read-only (no window is shown, nothing is raised or moved). Needs
// Accessibility permission for the process that starts the test run.
// Every stage below runs on the main thread in the app, i.e. it is time in
// which neither the hover highlight nor the event tap can make progress.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DOCKAPP_BENCH"] == "1"))
@MainActor
struct HoverPerformanceBenchmarks {
    private struct Sample {
        var values: [Double] = []
        var median: Double { percentile(0.5) }
        var p90: Double { percentile(0.9) }

        func percentile(_ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))]
        }
    }

    private func measure(_ iterations: Int, _ body: () -> Void) -> Sample {
        var sample = Sample()
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            sample.values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return sample
    }

    private func row(_ label: String, _ sample: Sample) {
        let padded = label.padding(toLength: 44, withPad: " ", startingAt: 0)
        print("BENCH \(padded) median \(String(format: "%7.3f", sample.median)) ms   p90 \(String(format: "%7.3f", sample.p90)) ms")
    }

    /// Centre points (CG coordinates) of Dock tiles that belong to running apps.
    private func runningDockTileCenters() -> [CGPoint] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
                return []
            }
            return value as? [AXUIElement] ?? []
        }

        var centers: [CGPoint] = []
        for list in children(AXUIElementCreateApplication(dock.processIdentifier)) {
            for tile in children(list) {
                var running: CFTypeRef?
                var position: CFTypeRef?
                var size: CFTypeRef?
                guard AXUIElementCopyAttributeValue(tile, "AXIsApplicationRunning" as CFString, &running) == .success,
                      (running as? Bool) == true,
                      AXUIElementCopyAttributeValue(tile, kAXPositionAttribute as CFString, &position) == .success,
                      AXUIElementCopyAttributeValue(tile, kAXSizeAttribute as CFString, &size) == .success,
                      let position, let size,
                      CFGetTypeID(position) == AXValueGetTypeID(),
                      CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero
                var extent = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
                centers.append(CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2))
            }
        }
        return centers
    }

    @Test func hoverPipeline() throws {
        _ = NSApplication.shared
        try #require(AXIsProcessTrusted())
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        print("BENCH screenLocked=\(session?["CGSSessionScreenIsLocked"] as? Bool ?? false)")

        // 1. Filter that runs for every mouse move (20 Hz) anywhere on screen.
        row("mouse move: isPointNearDockArea", measure(300) {
            _ = DockService.shared.isPointNearDockArea(CGPoint(x: 900, y: 500))
        })

        // 2. Dock hit test, runs every ~80 ms while the pointer is near the Dock.
        let centers = runningDockTileCenters()
        print("BENCH running dock tiles=\(centers.count)")
        var hitTest = Sample()
        var hits = 0
        for center in centers {
            let sample = measure(15) {
                if DockService.shared.findAppUnderCursor(at: center) != nil { hits += 1 }
            }
            hitTest.values.append(contentsOf: sample.values)
        }
        print("BENCH dock hit tests resolved=\(hits)/\(centers.count * 15)")
        row("dock hover: findAppUnderCursor", hitTest)

        // 3. Menu construction per app.
        var totalList = 0.0, totalSort = 0.0, totalBuild = 0.0, totalWindows = 0
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            let windows = AccessibilityService.shared.listApplicationWindows(for: app)
            let realWindows = windows.filter { !$0.isAppElement }.count
            guard realWindows > 0 else { continue }

            let list = measure(12) { _ = AccessibilityService.shared.listApplicationWindows(for: app) }
            let sort = measure(12) { _ = WindowChooserView.sortWindows(windows, app: app) }
            let build = measure(8) {
                let controller = WindowChooserController(
                    at: CGPoint(x: 900, y: 60), windows: windows, app: app, callback: { _, _ in }
                )
                controller.close()
            }
            let name = String((app.localizedName ?? "?").prefix(18))
            print("BENCH app \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) windows=\(String(format: "%2d", realWindows))"
                + "  list \(String(format: "%7.2f", list.median))  sort \(String(format: "%6.2f", sort.median))"
                + "  build \(String(format: "%7.2f", build.median))  hover→menu \(String(format: "%7.2f", list.median + build.median)) ms")
            totalList += list.median
            totalSort += sort.median
            totalBuild += build.median
            totalWindows += realWindows
        }
        print("BENCH TOTAL windows=\(totalWindows)  list \(String(format: "%.2f", totalList))  sort \(String(format: "%.2f", totalSort))"
            + "  build \(String(format: "%.2f", totalBuild))  hover→menu \(String(format: "%.2f", totalList + totalBuild)) ms")
    }
}
