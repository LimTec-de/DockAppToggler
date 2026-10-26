import AppKit
import ApplicationServices
@preconcurrency import MenuBarVisibility

/// macOS 27 no longer gives each status item a WindowServer window or honors
/// oversized spacers. Visibility assertions replace that geometry-based mechanism.
@MainActor
final class NativeTrayController {
    private let ownBundle: String
    private let boundaryIdentifier: String
    private let alwaysHiddenIdentifier: String
    private let changed: () -> Void
    private var assertion: MenuBarVisibility?
    private var layout: TrayMenuLayout?
    private var task: Task<Void, Never>?
    private var inventoryRefreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var generation = 0
    private let overflow = TrayOverflowPanel()
    private(set) var isCollapsed = false
    private var editing = false
    private var alwaysHidden = false
    private(set) var errorMessage: String?

    init(ownBundle: String, boundaryIdentifier: String, alwaysHiddenIdentifier: String, changed: @escaping () -> Void) {
        self.ownBundle = ownBundle
        self.boundaryIdentifier = boundaryIdentifier
        self.alwaysHiddenIdentifier = alwaysHiddenIdentifier
        self.changed = changed
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleInventoryRefresh() }
            }
            workspaceObservers.append(observer)
        }
    }

    private func scheduleInventoryRefresh() {
        guard assertion != nil || task != nil else { return }
        inventoryRefreshTask?.cancel()
        inventoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func set(collapsed: Bool, editing: Bool, alwaysHidden: Bool) {
        task?.cancel()
        generation += 1
        let request = generation
        isCollapsed = collapsed
        self.editing = editing
        self.alwaysHidden = alwaysHidden
        errorMessage = nil
        overflow.close()
        changed()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if layout == nil {
                    // Allow AppKit to finish inserting the visible section markers.
                    try await Task.sleep(for: .milliseconds(200))
                    let items = try await TrayMenuInventory.snapshot()
                    try Task.checkCancellation()
                    guard let boundary = items.first(where: { $0.bundleIdentifier == ownBundle && $0.identifier == boundaryIdentifier }) else {
                        throw TrayMenuError.message("Die Position des Menüleisten-Trenners konnte nicht gelesen werden.")
                    }
                    let permanent = items.first { $0.bundleIdentifier == ownBundle && $0.identifier == alwaysHiddenIdentifier }
                    guard !alwaysHidden || permanent != nil else {
                        throw TrayMenuError.message("Die Grenze für dauerhaft versteckte Icons konnte nicht gelesen werden. Bitte ordne den Trenner im Bearbeitungsmodus neu an.")
                    }
                    // AX uses one display's menu bar. Never compare positions from
                    // different monitors, especially when they are stacked vertically.
                    guard let primary = NSScreen.screens.first,
                          let screen = NSScreen.screens.first(where: {
                              CGRect(x: $0.frame.minX, y: primary.frame.maxY - $0.frame.maxY,
                                     width: $0.frame.width, height: $0.frame.height).contains(boundary.frame.origin)
                          }) else {
                        throw TrayMenuError.message("Der Bildschirm des Menüleisten-Trenners konnte nicht bestimmt werden.")
                    }
                    let sameBar = items.filter {
                        abs($0.frame.midY - boundary.frame.midY) < 20 &&
                        $0.frame.midX >= screen.frame.minX && $0.frame.midX < screen.frame.maxX
                    }
                    layout = TrayMenuLayout(items: sameBar, boundary: boundary.frame,
                                           alwaysHiddenBoundary: alwaysHidden ? permanent?.frame : nil,
                                           ownBundle: ownBundle)
                }
                guard let layout else { return }
                let bundles = layout.bundles(collapsed: collapsed, editing: editing)
                let notchScreen = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
                    .min { ($0.auxiliaryTopRightArea?.width ?? 0) < ($1.auxiliaryTopRightArea?.width ?? 0) }
                let needsOverflow = layout.needsOverflow(bundles: bundles, safeWidth: notchScreen?.auxiliaryTopRightArea?.width, ownBundle: ownBundle)
                if !needsOverflow && (editing || (!collapsed && !alwaysHidden)) {
                    assertion?.invalidate()
                    assertion = nil
                    self.layout = nil
                    changed()
                    return
                }
                let allowed = needsOverflow ? [] : bundles
                try await apply(allowed: allowed, request: request)
                guard request == generation, !Task.isCancelled else { return }
                if needsOverflow, let notchScreen {
                    try overflow.show(bundles: bundles, on: notchScreen) { [weak self] bundle in
                        self?.openMenu(for: bundle)
                    }
                }
                changed()
            } catch is CancellationError {
                // A newer request owns the presentation.
            } catch {
                guard request == generation else { return }
                stop()
                errorMessage = error.localizedDescription
                Logger.error(error.localizedDescription)
                changed()
            }
        }
    }

    private func apply(allowed: [String], request: Int) async throws {
        // Include system-owned apps as well as system-item identifiers; this keeps
        // Spotlight, input sources and Notification Center out of the hidden zones.
        let bundles = Set(allowed).union(TrayMenuLayout.systemBundles).union([ownBundle])
        let handle: MenuBarVisibility = try await withCheckedThrowingContinuation { continuation in
            MenuBarVisibility.activateAllowingBundles(bundles.sorted()) { handle, error in
                if let handle { continuation.resume(returning: handle) }
                else { continuation.resume(throwing: error ?? TrayMenuError.message("Die Menüleistensteuerung konnte nicht aktiviert werden.")) }
            }
        }
        guard request == generation, !Task.isCancelled else {
            handle.invalidate()
            throw CancellationError()
        }
        let previous = assertion
        assertion = handle
        previous?.invalidate()
    }

    private func openMenu(for bundle: String) {
        task?.cancel()
        generation += 1
        let request = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // While the strip is open, expose only the selected app beside the
                // system controls, so its original menu has a reachable anchor.
                let safeWidth = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
                    .compactMap { $0.auxiliaryTopRightArea?.width }.min()
                if layout?.needsOverflow(bundles: [bundle], safeWidth: safeWidth, ownBundle: ownBundle) == true {
                    throw TrayMenuError.message("Für die Icons dieser App ist rechts neben der Notch zu wenig Platz. Bitte reduziere die sichtbaren System-Icons.")
                }
                try await apply(allowed: [bundle], request: request)
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await TrayMenuInventory.pressFirstItem(of: bundle)
            } catch is CancellationError {
            } catch {
                guard request == generation else { return }
                errorMessage = error.localizedDescription
                changed()
            }
        }
    }

    func refresh() {
        assertion?.invalidate()
        assertion = nil
        layout = nil
        set(collapsed: isCollapsed, editing: editing, alwaysHidden: alwaysHidden)
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        inventoryRefreshTask?.cancel()
        inventoryRefreshTask = nil
        assertion?.invalidate()
        assertion = nil
        layout = nil
        isCollapsed = false
        errorMessage = nil
        overflow.close()
    }

    isolated deinit {
        task?.cancel()
        inventoryRefreshTask?.cancel()
        assertion?.invalidate()
        overflow.close()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
