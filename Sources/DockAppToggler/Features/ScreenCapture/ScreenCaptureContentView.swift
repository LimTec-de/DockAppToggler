import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

enum ScreenCaptureState {
    @MainActor static var isOverlayActive = false
}

struct ContentView: View {
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    @State private var screenImage: NSImage?
    @State private var firstPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var isSelecting = false
    @State private var keyMonitor: Any?
    @State private var localMonitor: Any?
    @State private var numCount: Int = 1
    @State private var showPermissionsAlert = false
    @State private var missingPermissions: [String] = []
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .opacity(0)
            .hidden()
            .onAppear {
                print("Setting up keyboard monitors...")
                checkPermissions()
                setupKeyboardMonitor()
            }
            .onDisappear {
                print("Cleaning up keyboard monitors...")
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let local = localMonitor {
                    NSEvent.removeMonitor(local)
                }
            }
            .alert("Permissions Required", isPresented: $showPermissionsAlert) {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(permissionsMessage)
            }
    }
    
    private var permissionsMessage: String {
        var message = "This app requires the following permissions to work properly:\n"
        for permission in missingPermissions {
            message += "\n• \(permission)"
        }
        message += "\n\nPlease enable these permissions in System Settings."
        return message
    }
    
    // Make these methods public so they can be called from AppDelegate
    func checkPermissions() {
        missingPermissions = []
        
        // Check Screen Recording permission
        let screenCaptureAccess = CGPreflightScreenCaptureAccess()
        if !screenCaptureAccess {
            missingPermissions.append("Screen Recording")
            // Request screen recording permission
            CGRequestScreenCaptureAccess()
        }
        
        // Check Accessibility permission
        let accessibilityAccess = AXIsProcessTrustedWithOptions([Self.trustedCheckOptionPrompt: false] as CFDictionary)
        if !accessibilityAccess {
            missingPermissions.append("Accessibility (for global hotkeys)")
            // Request accessibility permission
            AXIsProcessTrustedWithOptions([Self.trustedCheckOptionPrompt: true] as CFDictionary)
        }
        
        // Show alert if any permissions are missing
        if !missingPermissions.isEmpty {
            showPermissionsAlert = true
        }
    }
    
    private func openSystemSettings() {
        for permission in missingPermissions {
            if permission.contains("Screen Recording") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            if permission.contains("Accessibility") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
    
    func captureScreen() {
        print("Starting screen capture...")
        
        // Get current mouse location in screen coordinates
        let mouseLocation = NSEvent.mouseLocation
        
        // Find which screen contains the mouse
        let screenWithMouse = NSScreen.screens.first { screen in
            NSPointInRect(mouseLocation, screen.frame)
        } ?? NSScreen.main
        
        guard let screen = screenWithMouse else {
            print("No screen found for mouse location")
            return
        }
        
        print("Mouse is on screen: \(screen)")
        
        // Get the display ID for the screen containing the mouse
        let displayID = getDisplayIDForPoint(mouseLocation)
        
        print("Capturing display: \(displayID)")
        
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            print("Failed to create screen image")
            return
        }
        
        print("Screen captured, creating NSImage...")
        let image = NSImage(cgImage: cgImage, size: screen.frame.size)
        print("NSImage created with size: \(image.size)")
        showCaptureWindow(with: image, frame: screen.frame, coversEntireScreen: true)
    }

    func capturePickedWindowForEditing() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // Use the native system window picker for selection, then ignore the captured image
            // and use only the selected window coordinates for our own fullscreen editor workflow.
            task.arguments = ["-i", "-w", "-c"]

            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                print("Failed to run window picker capture: \(error)")
                return
            }

            guard task.terminationStatus == 0 else {
                // User likely cancelled.
                return
            }

            DispatchQueue.main.async {
                openEditorForPickedWindow(retryCount: 0)
            }
        }
    }

    private func openEditorForPickedWindow(retryCount: Int) {
        if let windowBounds = focusedWindowBounds() {
            let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
            guard let screen = NSScreen.screens.first(where: { NSPointInRect(center, $0.frame) }) ?? NSScreen.main else {
                print("Failed to resolve screen for focused window")
                return
            }

            let displayID = getDisplayIDForPoint(center)
            guard let cgImage = CGDisplayCreateImage(displayID) else {
                print("Failed to capture full screen image for pick-window flow")
                return
            }

            let image = NSImage(cgImage: cgImage, size: screen.frame.size)
            let localSelection = clampSelectionToImage(
                CGRect(
                    x: windowBounds.origin.x - screen.frame.origin.x,
                    y: windowBounds.origin.y - screen.frame.origin.y,
                    width: windowBounds.width,
                    height: windowBounds.height
                ),
                imageSize: image.size
            )

            showCaptureWindow(
                with: image,
                frame: screen.frame,
                coversEntireScreen: true,
                autoSelectVisibleImage: false,
                initialSelectionRect: localSelection
            )
            return
        }

        if retryCount < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                openEditorForPickedWindow(retryCount: retryCount + 1)
            }
        } else {
            print("Failed to determine focused window bounds after pick")
        }
    }
    
    // Helper function to get the display ID for a point
    private func getDisplayIDForPoint(_ point: CGPoint) -> CGDirectDisplayID {
        var displayID: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        
        if CGGetDisplaysWithPoint(CGPoint(x: point.x, y: point.y), 1, &displayID, &displayCount) != .success {
            return CGMainDisplayID()
        }
        
        return displayID
    }
    
    private func showCaptureWindow(
        with image: NSImage,
        frame: NSRect,
        coversEntireScreen: Bool,
        autoSelectVisibleImage: Bool = false,
        initialSelectionRect: CGRect? = nil
    ) {
        ScreenCaptureState.isOverlayActive = true
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure window to appear above everything
        window.level = .statusBar + 1
        window.backgroundColor = .clear
        window.isOpaque = true
        window.hasShadow = false
        
        // Make window available on all spaces.
        window.collectionBehavior = coversEntireScreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces]
        
        let initialRect = initialSelectionRect ?? (coversEntireScreen ? nil : CGRect(origin: .zero, size: image.size))
        let captureView = CaptureView(
            image: image,
            initialSelectionRect: initialRect,
            autoSelectVisibleImage: autoSelectVisibleImage
        ) { baseImage, selectedArea, drawings, preferredBaseName in
            if let cropped = baseImage.crop(to: selectedArea) {
                let finalImage = NSImage(size: selectedArea.size)
                finalImage.lockFocus()
                
                // Draw the cropped image
                cropped.draw(in: NSRect(origin: .zero, size: selectedArea.size))
                
                // Setup drawing context
                let context = NSGraphicsContext.current!.cgContext
                
                // Draw all elements with adjusted coordinates
                for drawing in drawings {
                    context.saveGState()
                    
                    // Calculate the offset from the selection area
                    let offsetX = selectedArea.origin.x
                    // Flip Y coordinate relative to selection area height
                    let offsetY = selectedArea.origin.y
                    let height = selectedArea.height
                    
                    switch drawing {
                    case .text(let text, let position, let color, let fontSize):
                        let adjustedPosition = CGPoint(
                            x: position.x - offsetX,
                            y: height - (position.y - offsetY) // Flip Y coordinate
                        )
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: fontSize),
                            .foregroundColor: color
                        ]
                        text.draw(at: adjustedPosition, withAttributes: attributes)
                        
                    case .arrow(let start, let end, let color, let lineWidth):
                        let adjustedStart = CGPoint(
                            x: start.x - offsetX,
                            y: height - (start.y - offsetY) // Flip Y coordinate
                        )
                        let adjustedEnd = CGPoint(
                            x: end.x - offsetX,
                            y: height - (end.y - offsetY) // Flip Y coordinate
                        )
                        
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(lineWidth)
                        context.move(to: adjustedStart)
                        context.addLine(to: adjustedEnd)
                        
                        // Draw arrow head with adjusted coordinates
                        let angle = atan2(adjustedEnd.y - adjustedStart.y, adjustedEnd.x - adjustedStart.x)
                        let arrowLength: CGFloat = 20
                        let arrowAngle: CGFloat = .pi / 6
                        
                        let arrowPoint1 = CGPoint(
                            x: adjustedEnd.x - arrowLength * cos(angle - arrowAngle),
                            y: adjustedEnd.y - arrowLength * sin(angle - arrowAngle)
                        )
                        let arrowPoint2 = CGPoint(
                            x: adjustedEnd.x - arrowLength * cos(angle + arrowAngle),
                            y: adjustedEnd.y - arrowLength * sin(angle + arrowAngle)
                        )
                        
                        context.move(to: arrowPoint1)
                        context.addLine(to: adjustedEnd)
                        context.addLine(to: arrowPoint2)
                        context.strokePath()
                        
                    case .numberedArrow(let start, let end, let number, let color, let lineWidth):
                        let adjustedStart = CGPoint(
                            x: start.x - offsetX,
                            y: height - (start.y - offsetY) // Flip Y coordinate
                        )
                        let adjustedEnd = CGPoint(
                            x: end.x - offsetX,
                            y: height - (end.y - offsetY) // Flip Y coordinate
                        )
                        
                        // Draw arrow
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(lineWidth)
                        context.move(to: adjustedStart)
                        context.addLine(to: adjustedEnd)
                        
                        // Draw arrow head with adjusted coordinates
                        let angle = atan2(adjustedEnd.y - adjustedStart.y, adjustedEnd.x - adjustedStart.x)
                        let arrowLength: CGFloat = 20
                        let arrowAngle: CGFloat = .pi / 6
                        
                        let arrowPoint1 = CGPoint(
                            x: adjustedEnd.x - arrowLength * cos(angle - arrowAngle),
                            y: adjustedEnd.y - arrowLength * sin(angle - arrowAngle)
                        )
                        let arrowPoint2 = CGPoint(
                            x: adjustedEnd.x - arrowLength * cos(angle + arrowAngle),
                            y: adjustedEnd.y - arrowLength * sin(angle + arrowAngle)
                        )
                        
                        context.move(to: arrowPoint1)
                        context.addLine(to: adjustedEnd)
                        context.addLine(to: arrowPoint2)
                        context.strokePath()
                        
                        // Draw number with adjusted coordinates
                        let numberText = "\(number)"
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.boldSystemFont(ofSize: 16),
                            .foregroundColor: color
                        ]
                        let numberPoint = CGPoint(
                            x: adjustedStart.x - 30 * cos(angle),
                            y: adjustedStart.y - 30 * sin(angle)
                        )
                        numberText.draw(at: numberPoint, withAttributes: attributes)
                        
                    case .rectangle(let rect, let color):
                        let adjustedRect = CGRect(
                            x: rect.origin.x - offsetX,
                            y: height - (rect.origin.y - offsetY) - rect.height, // Flip Y coordinate
                            width: rect.width,
                            height: rect.height
                        )
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(2)
                        context.stroke(adjustedRect)
                        
                    case .pixelatedRect(let rect, let pixelatedImage):
                        let adjustedRect = CGRect(
                            x: rect.origin.x - offsetX,
                            y: height - (rect.origin.y - offsetY) - rect.height, // Flip Y coordinate
                            width: rect.width,
                            height: rect.height
                        )
                        pixelatedImage.draw(in: adjustedRect)
                    case .smiley(let emoji, let position, let size, let color):
                        let adjustedPosition = CGPoint(
                            x: position.x - offsetX,
                            y: height - (position.y - offsetY) // Flip Y coordinate
                        )
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: size),
                            .foregroundColor: color
                        ]
                        emoji.draw(at: adjustedPosition, withAttributes: attributes)
                    }
                    
                    context.restoreGState()
                }
                
                finalImage.unlockFocus()
                
                // Helper function to create high resolution bitmap representation
                func createHighResolutionBitmap(from image: NSImage) -> NSBitmapImageRep? {
                    // Get the screen that contains the selection area
                    let selectionCenter = NSPoint(
                        x: selectedArea.origin.x + selectedArea.width / 2,
                        y: selectedArea.origin.y + selectedArea.height / 2
                    )
                    let screenWithSelection = NSScreen.screens.first { screen in
                        NSPointInRect(selectionCenter, screen.frame)
                    } ?? NSScreen.main
                    
                    let scaleFactor = screenWithSelection?.backingScaleFactor ?? 2.0
                    let pixelWidth = Int(image.size.width * scaleFactor)
                    let pixelHeight = Int(image.size.height * scaleFactor)
                    
                    let bitmapRep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: pixelWidth,
                        pixelsHigh: pixelHeight,
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0,
                        bitsPerPixel: 0
                    )
                    
                    // Set the size to match the pixel dimensions divided by scale factor
                    // This ensures proper resolution
                    bitmapRep?.size = image.size
                    
                    NSGraphicsContext.saveGraphicsState()
                    if let context = NSGraphicsContext(bitmapImageRep: bitmapRep!) {
                        NSGraphicsContext.current = context
                        
                        // Set interpolation quality to none for sharp text
                        context.cgContext.interpolationQuality = .none
                        
                        // Enable font smoothing and anti-aliasing for text
                        context.cgContext.setShouldSmoothFonts(true)
                        context.cgContext.setShouldAntialias(true)
                        
                        // Draw the image at the correct scale
                        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1.0)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    
                    return bitmapRep
                }
                
                // Copy to clipboard with correct resolution
                if let clipboardRep = createHighResolutionBitmap(from: finalImage) {
                    let clipboardImage = NSImage(size: finalImage.size)
                    clipboardImage.addRepresentation(clipboardRep)
                    
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([clipboardImage])
                    print("Image with drawings copied to clipboard")
                }
                
                do {
                    let screenCaptureURL = try screenCaptureDirectoryURL()
                    let screenCaptureDataURL = try screenCaptureDataDirectoryURL()

                    // Create filename with timestamp
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yy_MM_dd_H_m_s"
                    let timestamp = dateFormatter.string(from: Date())
                    let baseName = preferredBaseName ?? "screenshot_\(timestamp)"

                    let editedURL = screenCaptureURL.appendingPathComponent("\(baseName).png")
                    let originalURL = screenCaptureDataURL.appendingPathComponent("\(baseName)_orig.png")
                    let capURL = screenCaptureDataURL.appendingPathComponent("\(baseName)_cap.json")

                    if let editedRep = createHighResolutionBitmap(from: finalImage),
                       let editedPngData = editedRep.representation(using: .png, properties: [:]) {
                        try editedPngData.write(to: editedURL)
                        print("Image saved to: \(editedURL.path)")
                    }

                    if let originalRep = createHighResolutionBitmap(from: baseImage),
                       let originalPngData = originalRep.representation(using: .png, properties: [:]) {
                        try originalPngData.write(to: originalURL)
                        print("Original image saved to: \(originalURL.path)")
                    }

                    let captureDocument = makeCaptureDocument(from: drawings, selectedArea: selectedArea)
                    let capData = try JSONEncoder().encode(captureDocument)
                    try capData.write(to: capURL, options: .atomic)
                    print("Capture metadata saved to: \(capURL.path)")
                } catch {
                    print("Error saving image or metadata: \(error)")
                }

                
            }
            // Close window on main thread after saving
            DispatchQueue.main.async {
                window.close()
                NSApp.windows.forEach { win in
                    if win.contentView is NSHostingView<CaptureView> {
                        win.close()
                    }
                }
            }
            
        }
        
        window.contentView = NSHostingView(rootView: captureView)
        window.makeKeyAndOrderFront(nil)
    }

    private func focusedWindowBounds() -> CGRect? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var windowRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef)
        if focusedResult != .success {
            _ = AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard let rawWindowRef = windowRef,
              CFGetTypeID(rawWindowRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = rawWindowRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let rawPositionRef = positionRef,
              let rawSizeRef = sizeRef,
              CFGetTypeID(rawPositionRef) == AXValueGetTypeID(),
              CFGetTypeID(rawSizeRef) == AXValueGetTypeID() else {
            return nil
        }
        let positionAX = rawPositionRef as! AXValue
        let sizeAX = rawSizeRef as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 1, size.height > 1 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func clampSelectionToImage(_ rect: CGRect, imageSize: NSSize) -> CGRect {
        let imageRect = CGRect(origin: .zero, size: imageSize)
        let intersection = rect.intersection(imageRect)
        if intersection.isNull || intersection.isEmpty {
            return imageRect
        }
        return intersection
    }
    
    private func checkAccessibilityPermissions() -> Bool {
        let hasPermission = AXIsProcessTrustedWithOptions([Self.trustedCheckOptionPrompt: true] as CFDictionary)
        print("Accessibility permissions check: \(hasPermission)")
        return hasPermission
    }
    
    private func setupKeyboardMonitor() {
        print("Setting up keyboard monitors...")
        
        // Remove existing monitors if they exist
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
        }
        
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            print("Global monitor received keyDown event: \(event.keyCode)")
            handleKeyEvent(event)
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            print("Local monitor received keyDown event: \(event.keyCode)")
            handleKeyEvent(event)
            return event
        }
        
        print("Keyboard monitors setup completed - global: \(keyMonitor != nil), local: \(localMonitor != nil)")
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        // Add ESC key handling at the start of the method
        if event.keyCode == 53 { // ESC key
            closeCaptureWindows()
            return
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Get the current shortcut settings from UserDefaults
        let defaults = UserDefaults.standard
        let savedModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "ShortcutModifiers")))
        let savedKeyCode = UInt16(defaults.integer(forKey: "ShortcutKeyCode"))
        
        // Use default shortcut (Command + Option + P) if no custom shortcut is set
        let shortcutModifiers = savedModifiers.isEmpty ? [.command, .option] : savedModifiers
        let shortcutKeyCode = savedKeyCode == 0 ? UInt16(35) : savedKeyCode // Default to 'P' if not set
        
        if modifierFlags == shortcutModifiers && event.keyCode == shortcutKeyCode && screenImage == nil {
            print("Shortcut detected! Starting screen capture...")
            captureScreen()
        }
        
        // Handle delete key for selected elements in the capture view
        if event.keyCode == 51 || event.keyCode == 117 { // Backspace/Delete key
            if let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<CaptureView> }) {
                if let captureView = window.contentView?.subviews.first?.subviews.first as? NSHostingView<CaptureView> {
                    captureView.rootView.deleteSelectedElement()
                }
            }
        }
    }

    private func closeCaptureWindows() {
        ScreenCaptureState.isOverlayActive = false
        NSApp.windows.forEach { window in
            if window.contentView is NSHostingView<CaptureView> {
                window.close()
            }
        }
    }

    private func screenCaptureDirectoryURL() throws -> URL {
        guard let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pictures directory not found"])
        }
        let screenCaptureURL = picturesURL.appendingPathComponent("ScreenCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: screenCaptureURL, withIntermediateDirectories: true)
        return screenCaptureURL
    }

    private func screenCaptureDataDirectoryURL() throws -> URL {
        let screenCaptureURL = try screenCaptureDirectoryURL()
        let dataURL = screenCaptureURL.appendingPathComponent("_data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        return dataURL
    }

    private func makeCaptureDocument(from drawings: [Drawing], selectedArea: NSRect) -> CaptureDocument {
        var texts: [CaptureText] = []
        var arrows: [CaptureArrow] = []
        var numberedArrows: [CaptureNumberedArrow] = []
        var rectangles: [CaptureRectangle] = []
        var pixelates: [CapturePixelate] = []
        var smileys: [CaptureSmiley] = []

        for drawing in drawings {
            switch drawing {
            case .text(let text, let position, let color, let fontSize):
                texts.append(
                    CaptureText(
                        text: text,
                        position: CodablePoint(x: position.x, y: position.y),
                        fontSize: fontSize,
                        color: CodableColor(color)
                    )
                )
            case .arrow(let start, let end, let color, let lineWidth):
                arrows.append(
                    CaptureArrow(
                        start: CodablePoint(x: start.x, y: start.y),
                        end: CodablePoint(x: end.x, y: end.y),
                        lineWidth: lineWidth,
                        color: CodableColor(color)
                    )
                )
            case .numberedArrow(let start, let end, let number, let color, let lineWidth):
                numberedArrows.append(
                    CaptureNumberedArrow(
                        start: CodablePoint(x: start.x, y: start.y),
                        end: CodablePoint(x: end.x, y: end.y),
                        number: number,
                        lineWidth: lineWidth,
                        color: CodableColor(color)
                    )
                )
            case .rectangle(let rect, let color):
                rectangles.append(
                    CaptureRectangle(
                        rect: CodableRect(
                            x: rect.origin.x,
                            y: rect.origin.y,
                            width: rect.width,
                            height: rect.height
                        ),
                        color: CodableColor(color)
                    )
                )
            case .pixelatedRect(let rect, _):
                pixelates.append(
                    CapturePixelate(
                        rect: CodableRect(
                            x: rect.origin.x,
                            y: rect.origin.y,
                            width: rect.width,
                            height: rect.height
                        )
                    )
                )
            case .smiley(let emoji, let position, let size, let color):
                smileys.append(
                    CaptureSmiley(
                        emoji: emoji,
                        position: CodablePoint(x: position.x, y: position.y),
                        size: size,
                        color: CodableColor(color)
                    )
                )
            }
        }

        return CaptureDocument(
            canvasSize: CodableSize(width: selectedArea.width, height: selectedArea.height),
            selectedRect: CodableRect(
                x: selectedArea.origin.x,
                y: selectedArea.origin.y,
                width: selectedArea.width,
                height: selectedArea.height
            ),
            texts: texts,
            arrows: arrows,
            numberedArrows: numberedArrows,
            rectangles: rectangles,
            pixelates: pixelates,
            smileys: smileys
        )
    }
}

// Add Drawing enum to represent different types of drawings
enum Drawing {
    case text(String, CGPoint, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case numberedArrow(CGPoint, CGPoint, Int, NSColor, CGFloat)
    case rectangle(CGRect, NSColor)
    case pixelatedRect(CGRect, NSImage)  // New case for pixelated rectangles
    case smiley(String, CGPoint, CGFloat, NSColor)  // New case for smileys with emoji, position, size, and color
}

struct CodablePoint: Codable {
    var x: CGFloat
    var y: CGFloat
}

struct CodableSize: Codable {
    var width: CGFloat
    var height: CGFloat
}

struct CodableRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

struct CodableColor: Codable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        self.red = rgb.redComponent
        self.green = rgb.greenComponent
        self.blue = rgb.blueComponent
        self.alpha = rgb.alphaComponent
    }

    var nsColor: NSColor {
        return NSColor(
            calibratedRed: max(0, min(1, red)),
            green: max(0, min(1, green)),
            blue: max(0, min(1, blue)),
            alpha: max(0, min(1, alpha))
        )
    }

    mutating func normalizeLegacy255IfNeeded() -> Bool {
        let needsNormalization = red > 1 || green > 1 || blue > 1 || alpha > 1
        if !needsNormalization { return false }
        red = max(0, min(1, red / 255.0))
        green = max(0, min(1, green / 255.0))
        blue = max(0, min(1, blue / 255.0))
        alpha = max(0, min(1, alpha / 255.0))
        return true
    }
}

struct CaptureText: Codable {
    var text: String
    var position: CodablePoint
    var fontSize: CGFloat
    var color: CodableColor
}

struct CaptureArrow: Codable {
    var start: CodablePoint
    var end: CodablePoint
    var lineWidth: CGFloat
    var color: CodableColor
}

struct CaptureNumberedArrow: Codable {
    var start: CodablePoint
    var end: CodablePoint
    var number: Int
    var lineWidth: CGFloat
    var color: CodableColor
}

struct CaptureRectangle: Codable {
    var rect: CodableRect
    var color: CodableColor
}

struct CapturePixelate: Codable {
    var rect: CodableRect
}

struct CaptureSmiley: Codable {
    var emoji: String
    var position: CodablePoint
    var size: CGFloat
    var color: CodableColor
}

struct CaptureDocument: Codable {
    var canvasSize: CodableSize
    var selectedRect: CodableRect?
    var texts: [CaptureText]
    var arrows: [CaptureArrow]
    var numberedArrows: [CaptureNumberedArrow]
    var rectangles: [CaptureRectangle]
    var pixelates: [CapturePixelate]
    var smileys: [CaptureSmiley]
}

struct ScreenshotHistoryItem: Identifiable {
    var id: String { baseName }
    let baseName: String
    let editedURL: URL
    let originalURL: URL
    let capURL: URL
    let modifiedAt: Date
}

struct CaptureView: View {
    private static let legacyColorMigrationKey = "ScreenCaptureLegacyColorMigrationDoneV1"
    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    let initialSelectionRect: CGRect?
    let autoSelectVisibleImage: Bool
    let onSelection: (NSImage, NSRect, [Drawing], String?) -> Void
    @State private var firstPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var isSelecting = false
    @State private var selectionRect: CGRect?
    @State private var numCount: Int = 1
    @State private var deleteMonitor: Any?
    @State private var showMagnifyingGlass = false
    @State private var cursorPosition: CGPoint = .zero
    @State private var workingImage: NSImage
    private let capturedImage: NSImage
    @State private var showHistoryPanel = false
    @State private var screenshotHistory: [ScreenshotHistoryItem] = []
    @State private var isHoveringHistoryPanel = false
    @State private var hoveredHistoryItemId: String?
    @State private var hoveredHistoryPreviewImage: NSImage?
    @State private var loadedBaseName: String?
    @State private var suppressNextToolHelpUpdate = false
    
    // Drawing states
    @State private var currentTool: DrawingTool = .select
    @State private var lastTool: DrawingTool = .select
    @State var texts: [(text: String, position: CGPoint, id: UUID, isNumberedText: Bool)] = []
    @State private var textFontSizes: [UUID: CGFloat] = [:]
    @State var arrows: [(start: CGPoint, end: CGPoint, id: UUID)] = []
    @State var rectangles: [(rect: CGRect, id: UUID)] = []
    @State var pixelatedRects: [(rect: CGRect, image: NSImage, id: UUID)] = []
    @State var numberedArrows: [(start: CGPoint, end: CGPoint, number: Int, id: UUID)] = []
    @State private var arrowLineWidths: [UUID: CGFloat] = [:]
    @State private var elementColors: [UUID: Color] = [:]
    @State var selectedElementId: UUID?
    @State private var isDraggingElement = false
    @State private var dragOffset: CGPoint?
    @State private var isDrawing = false
    @State private var editingText: String = ""
    @State private var textPrefix: String = ""
    @State private var isEditingText: Bool = false
    @State private var textPosition: CGPoint?
    @State private var textMonitor: Any?
    @State private var activeTextIsNumbered: Bool = false
    @State private var activeTextIncrementsNumCount: Bool = false
    @State private var discardCurrentTextIfEmpty: Bool = false
    @State private var currentEditingFontSize: CGFloat = 20
    @State private var showCursor: Bool = true
    @State private var canDragCurrentElement = false
    @State private var selectedDrawingColor: Color = .red
    private let drawingPalette: [Color] = [
        .red,
        .orange,
        .yellow,
        .green,
        .blue
    ]
    private let minTextEditorWidth: CGFloat = 220
    private let maxTextEditorWidth: CGFloat = 520
    private let textEditorPadding: CGFloat = 16
    private let minTextFontSize: CGFloat = 12
    private let maxTextFontSize: CGFloat = 56
    private let textFontStep: CGFloat = 4
    private let minArrowLineWidth: CGFloat = 1
    private let maxArrowLineWidth: CGFloat = 12
    private let arrowLineWidthStep: CGFloat = 2
    private let minSmileySize: CGFloat = 20
    private let maxSmileySize: CGFloat = 120
    private let smileySizeStep: CGFloat = 8
    
    // Add a new state property for the help text
    @State private var helpText: String = "Select an area to capture"
    
    // Smiley related states
    @State var smileys: [(emoji: String, position: CGPoint, size: CGFloat, id: UUID)] = []
    @State private var showSmileyPicker: Bool = false
    @State private var smileyPickerPosition: CGPoint = .zero
    @State private var selectedSmileySize: CGFloat = 40
    
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(
        image: NSImage,
        initialSelectionRect: CGRect?,
        autoSelectVisibleImage: Bool,
        onSelection: @escaping (NSImage, NSRect, [Drawing], String?) -> Void
    ) {
        self.initialSelectionRect = initialSelectionRect
        self.autoSelectVisibleImage = autoSelectVisibleImage
        self.onSelection = onSelection
        self.capturedImage = image
        _workingImage = State(initialValue: image)
    }
    
    enum DrawingTool {
        case select, text, arrow, rectangle, numberedArrow, elementSelect, pixelate, numberedText, changeSelection, smiley
    }
    
    private func getDrawingColor(at _: CGPoint, isSelected _: Bool = false) -> Color {
        return selectedDrawingColor
    }

    private func drawingColor(for elementId: UUID, fallbackPoint _: CGPoint) -> Color {
        elementColors[elementId] ?? selectedDrawingColor
    }
    
    var body: some View {
        GeometryReader { geometry in
                ZStack {
                    Image(nsImage: workingImage)
                        .resizable()
                        .frame(width: workingImage.size.width, height: workingImage.size.height)
                        .position(x: workingImage.size.width / 2, y: workingImage.size.height / 2)

                // Dimming overlay with cutout for selection
                if let rect = selectionRect ?? makeRect(from: firstPoint, to: currentPoint) {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(rect)
                    }
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundColor(Color.black.opacity(0.5))
                    
                    // Selection border
                    Path { path in
                        path.addRect(rect)
                    }
                    .stroke(isSelecting || currentTool == .elementSelect ? Color.blue : Color.white, lineWidth: 2)
                    
                    // Help text should be visible during selection
                    if isSelecting {
                        Text(helpText)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .position(x: rect.midX, y: rect.maxY + 30)
                    }
                    
                    // FullScreen button above the selection frame
                    if !isSelecting, selectionRect != nil {
                        Button(action: {
                            selectionRect = CGRect(origin: .zero, size: geometry.size)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9))
                                Text("FullScreen")
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.windowBackgroundColor).opacity(0.9))
                            .cornerRadius(4)
                            .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: rect.midX,
                            y: max(14, rect.minY - 14)
                        )
                    }

                    // Drawing tools buttons
                    if !isSelecting, let rect = selectionRect {
                        VStack(spacing: 8) {
                            toolbarView(for: rect, in: geometry.size)
                            
                            // Help text below toolbar
                            Text(helpText)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                        }
                    }
                    
                    // Draw existing elements
                    ForEach(texts.indices, id: \.self) { index in
                        let isSelected = texts[index].id == selectedElementId
                        let textId = texts[index].id
                        let fontSize = textFontSizes[textId] ?? 20
                        let textSize = textBlockSize(for: texts[index].text, fontSize: fontSize)

                        ZStack {
                            Text(texts[index].text)
                                .foregroundColor(drawingColor(for: textId, fallbackPoint: texts[index].position))
                                .font(.system(size: fontSize))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: textSize.width, height: textSize.height, alignment: .leading)
                                .position(x: texts[index].position.x + textSize.width / 2, y: texts[index].position.y)

                            if isSelected {
                                Rectangle()
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: textSize.width + 8, height: textSize.height + 8)
                                    .position(x: texts[index].position.x + textSize.width / 2, y: texts[index].position.y)
                            }

                            if isSelected {
                                HStack(spacing: 6) {
                                    Button(action: {
                                        updateTextFontSize(for: textId, delta: -textFontStep)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        updateTextFontSize(for: textId, delta: textFontStep)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Capsule())
                                .position(
                                    x: texts[index].position.x + 22,
                                    y: texts[index].position.y - textSize.height / 2 - 18
                                )
                            }
                        }
                            .contextMenu {
                                Button(action: {
                                    // Delete this text
                                    let deletedId = texts[index].id
                                    
                                    // Check if this is a numbered text that needs renumbering
                                    var deletedTextNumber: Int? = nil
                                    if texts[index].isNumberedText {
                                        let text = texts[index].text
                                        // Check if this is a numbered text (format: "N. text")
                                        let regex = try? NSRegularExpression(pattern: "^(\\d+)\\.")
                                        if let regex = regex,
                                           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.count)),
                                           match.numberOfRanges > 1,
                                           let numberRange = Range(match.range(at: 1), in: text),
                                           let number = Int(text[numberRange]) {
                                            deletedTextNumber = number
                                        }
                                    }
                                    
                                    // Remove the text
                                    texts.removeAll { $0.id == deletedId }
                                    textFontSizes.removeValue(forKey: deletedId)
                                    elementColors.removeValue(forKey: deletedId)
                                    
                                    // If we deleted a numbered text, renumber all texts with higher numbers
                                    if let deletedNumber = deletedTextNumber {
                                        // We need to update all numbered texts with numbers greater than the deleted one
                                        for i in 0..<texts.count {
                                            // Only process texts that were created with the numbered text tool
                                            if texts[i].isNumberedText {
                                                let text = texts[i].text
                                                // Use the same regex pattern as above
                                                let regex = try? NSRegularExpression(pattern: "^(\\d+)\\.(.*?)$")
                                                if let regex = regex,
                                                   let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.count)),
                                                   match.numberOfRanges > 2,
                                                   let numberRange = Range(match.range(at: 1), in: text),
                                                   let textContentRange = Range(match.range(at: 2), in: text),
                                                   let number = Int(text[numberRange]) {
                                                    
                                                    // If this text has a higher number than the deleted one, decrement it
                                                    if number > deletedNumber {
                                                        let newNumber = number - 1
                                                        let textContent = String(text[textContentRange])
                                                        // Preserve the space after the period if it exists
                                                        let hasSpace = textContent.hasPrefix(" ")
                                                        texts[i].text = "\(newNumber).\(hasSpace ? " " : "")\(hasSpace ? String(textContent.dropFirst()) : textContent)"
                                                    }
                                                }
                                            }
                                        }
                                        
                                        // Also decrement the numCount if it's greater than the deleted number
                                        if numCount > deletedNumber {
                                            numCount -= 1
                                        }
                                    }
                                    
                                    selectedElementId = nil
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .help("Click to select, drag to move, or right-click to delete this text. You can also press Delete key to remove it.")
                    }
                    
                    // Active text being edited
                    if isEditingText, let position = textPosition {
                        let editorSize = textEditorSize()
                        HStack(spacing: 0) {
                            Text(textPrefix + editingText + (showCursor ? "|" : ""))
                                .foregroundColor(getDrawingColor(at: position, isSelected: false))
                                .font(.system(size: currentEditingFontSize))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        .padding(.horizontal, -8)
                                        .padding(.vertical, -4)
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            Spacer(minLength: 0)
                        }
                        .frame(width: editorSize.width, height: editorSize.height, alignment: .leading)
                        .position(adjustTextEditorPosition(position: position, width: editorSize.width, height: editorSize.height))

                        let adjustedEditorPosition = adjustTextEditorPosition(position: position, width: editorSize.width, height: editorSize.height)
                        HStack(spacing: 6) {
                            Button(action: {
                                currentEditingFontSize = max(minTextFontSize, currentEditingFontSize - textFontStep)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                currentEditingFontSize = min(maxTextFontSize, currentEditingFontSize + textFontStep)
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Capsule())
                        .position(
                            x: adjustedEditorPosition.x - editorSize.width / 2 + 22,
                            y: adjustedEditorPosition.y - editorSize.height / 2 - 18
                        )
                    }
                    
                    // Draw pixelated rectangles first (so they appear behind other elements)
                    ForEach(pixelatedRects.indices, id: \.self) { index in
                        let isSelected = pixelatedRects[index].id == selectedElementId
                        Image(nsImage: pixelatedRects[index].image)
                            .resizable()
                            .frame(width: pixelatedRects[index].rect.width, 
                                   height: pixelatedRects[index].rect.height)
                            .position(x: pixelatedRects[index].rect.midX, 
                                    y: pixelatedRects[index].rect.midY)
                            .overlay(
                                ZStack {
                                    Rectangle()
                                        .stroke(
                                            isSelected ? Color.green : Color.clear,
                                            style: StrokeStyle(lineWidth: isSelected ? 2 : 0, dash: [6, 4])
                                        )
                                    
                                    // Show drag handle and delete button when selected
                                    if isSelected {
                                        VStack {
                                            HStack {
                                                Spacer()
                                                
                                                Button(action: {
                                                    // Delete this pixelated rectangle
                                                    let deletedId = pixelatedRects[index].id
                                                    pixelatedRects.remove(at: index)
                                                    elementColors.removeValue(forKey: deletedId)
                                                    selectedElementId = nil
                                                }) {
                                                    Image(systemName: "trash")
                                                        .foregroundColor(.white)
                                                        .padding(4)
                                                        .background(Color.red)
                                                        .clipShape(Circle())
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                                .padding(4)
                                            }
                                            
                                            Spacer()
                                            
                                            HStack {
                                                Spacer()
                                                
                                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                                    .foregroundColor(.white)
                                                    .padding(4)
                                                    .background(Color.blue)
                                                    .clipShape(Circle())
                                                    .padding(4)
                                            }
                                        }
                                    }
                                }
                            )
                            .contextMenu {
                                Button(action: {
                                    // Delete this pixelated rectangle
                                    let deletedId = pixelatedRects[index].id
                                    pixelatedRects.remove(at: index)
                                    elementColors.removeValue(forKey: deletedId)
                                    selectedElementId = nil
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .help("Click to select, drag to move, or right-click to delete this pixelated area. You can also press Delete key to remove it.")
                    }
                    
                    // Draw smileys
                    ForEach(smileys.indices, id: \.self) { index in
                        let isSelected = smileys[index].id == selectedElementId
                        ZStack {
                            Text(smileys[index].emoji)
                                .font(.system(size: smileys[index].size))
                                .foregroundColor(drawingColor(for: smileys[index].id, fallbackPoint: smileys[index].position))
                                .position(smileys[index].position)
                                .contextMenu {
                                    Button(action: {
                                        // Delete this smiley
                                        let deletedId = smileys[index].id
                                        smileys.removeAll { $0.id == deletedId }
                                        elementColors.removeValue(forKey: deletedId)
                                        selectedElementId = nil
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .help("Click to select, drag to move, or right-click to delete this smiley. You can also press Delete key to remove it.")

                            if isSelected {
                                Rectangle()
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: smileys[index].size * 1.2, height: smileys[index].size * 1.2)
                                    .position(smileys[index].position)
                            }

                            if isSelected {
                                HStack(spacing: 6) {
                                    Button(action: {
                                        smileys[index].size = max(minSmileySize, smileys[index].size - smileySizeStep)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        smileys[index].size = min(maxSmileySize, smileys[index].size + smileySizeStep)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Capsule())
                                .position(
                                    x: smileys[index].position.x - smileys[index].size / 2 + 22,
                                    y: smileys[index].position.y - smileys[index].size / 2 - 18
                                )
                            }
                        }
                    }
                    
                    // Show smiley picker if active
                    if showSmileyPicker {
                        // Draw crosshair at the position where the smiley will be placed
                        ZStack {
                            // Horizontal line
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 20, height: 1)
                            // Vertical line
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 1, height: 20)
                        }
                        .position(smileyPickerPosition)
                        
                        // Position the picker below the click point
                        smileyPickerView()
                            .position(adjustSmileyPickerPosition(CGPoint(x: smileyPickerPosition.x, y: smileyPickerPosition.y + 150)))
                    }
                    
                    ForEach(arrows.indices, id: \.self) { index in
                        let isSelected = arrows[index].id == selectedElementId
                        let lineWidth = arrowLineWidths[arrows[index].id] ?? 2
                        ZStack {
                            ArrowShape(start: arrows[index].start, end: arrows[index].end)
                                .stroke(
                                    drawingColor(for: arrows[index].id, fallbackPoint: arrows[index].start),
                                    lineWidth: lineWidth
                                )
                                .contextMenu {
                                    Button(action: {
                                        // Delete this arrow
                                        let deletedId = arrows[index].id
                                        arrows.removeAll { $0.id == deletedId }
                                        arrowLineWidths.removeValue(forKey: deletedId)
                                        elementColors.removeValue(forKey: deletedId)
                                        selectedElementId = nil
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .help("Click to select, drag to move, or right-click to delete this arrow. You can also press Delete key to remove it.")

                            if isSelected {
                                let bounds = boundingRectForLine(start: arrows[index].start, end: arrows[index].end, padding: 10)
                                Rectangle()
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: max(bounds.width, 16), height: max(bounds.height, 16))
                                    .position(x: bounds.midX, y: bounds.midY)

                                let controlPosition = adjustmentControlPositionForArrow(start: arrows[index].start, end: arrows[index].end)
                                HStack(spacing: 6) {
                                    Button(action: {
                                        arrowLineWidths[arrows[index].id] = max(minArrowLineWidth, lineWidth - arrowLineWidthStep)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        arrowLineWidths[arrows[index].id] = min(maxArrowLineWidth, lineWidth + arrowLineWidthStep)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Capsule())
                                .position(controlPosition)
                            }
                        }
                    }
                    
                    // Preview current arrow
                    if currentTool == .arrow && isDrawing,
                       let start = firstPoint,
                       let end = currentPoint {
                        ArrowShape(start: start, end: end)
                            .stroke(getDrawingColor(at: start, isSelected: false), lineWidth: 2)
                    }
                    
                    // Draw numbered arrows
                    ForEach(numberedArrows.indices, id: \.self) { index in
                        let isSelected = numberedArrows[index].id == selectedElementId
                        let lineWidth = arrowLineWidths[numberedArrows[index].id] ?? 2
                        Group {
                            ArrowShape(start: numberedArrows[index].start, end: numberedArrows[index].end)
                                .stroke(
                                    drawingColor(for: numberedArrows[index].id, fallbackPoint: numberedArrows[index].start),
                                    lineWidth: lineWidth
                                )
                                .contextMenu {
                                    Button(action: {
                                        // Delete this numbered arrow
                                        let deletedNumber = numberedArrows[index].number
                                        let deletedId = numberedArrows[index].id
                                        
                                        // Remove the arrow
                                        numberedArrows.removeAll { $0.id == deletedId }
                                        
                                        // Renumber the remaining arrows
                                        // Sort the arrows by their current number to ensure proper renumbering
                                        numberedArrows.sort { $0.number < $1.number }
                                        
                                        // Renumber all arrows that had a number greater than the deleted one
                                        for i in 0..<numberedArrows.count {
                                            if numberedArrows[i].number > deletedNumber {
                                                // Decrement the number by 1
                                                numberedArrows[i] = (
                                                    start: numberedArrows[i].start,
                                                    end: numberedArrows[i].end,
                                                    number: numberedArrows[i].number - 1,
                                                    id: numberedArrows[i].id
                                                )
                                            }
                                        }
                                        
                                        arrowLineWidths.removeValue(forKey: deletedId)
                                        elementColors.removeValue(forKey: deletedId)
                                        selectedElementId = nil
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .help("Click to select, drag to move, or right-click to delete this numbered arrow. You can also press Delete key to remove it.")
                            let angle = atan2(numberedArrows[index].end.y - numberedArrows[index].start.y,
                                           numberedArrows[index].end.x - numberedArrows[index].start.x)
                            Text("\(numberedArrows[index].number)")
                                .foregroundColor(drawingColor(for: numberedArrows[index].id, fallbackPoint: numberedArrows[index].start))
                                .font(.system(size: 16, weight: .bold))
                                .position(x: numberedArrows[index].start.x - 30 * cos(angle),
                                        y: numberedArrows[index].start.y - 30 * sin(angle))

                            if isSelected {
                                let bounds = boundingRectForLine(
                                    start: numberedArrows[index].start,
                                    end: numberedArrows[index].end,
                                    padding: 10
                                )
                                Rectangle()
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: max(bounds.width, 16), height: max(bounds.height, 16))
                                    .position(x: bounds.midX, y: bounds.midY)

                                let controlPosition = adjustmentControlPositionForArrow(
                                    start: numberedArrows[index].start,
                                    end: numberedArrows[index].end
                                )
                                HStack(spacing: 6) {
                                    Button(action: {
                                        arrowLineWidths[numberedArrows[index].id] = max(minArrowLineWidth, lineWidth - arrowLineWidthStep)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        arrowLineWidths[numberedArrows[index].id] = min(maxArrowLineWidth, lineWidth + arrowLineWidthStep)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Capsule())
                                .position(controlPosition)
                            }
                        }
                    }
                    
                    // Preview current numbered arrow
                    if currentTool == .numberedArrow && isDrawing,
                       let start = firstPoint,
                       let end = currentPoint {
                        Group {
                            ArrowShape(start: start, end: end)
                                .stroke(getDrawingColor(at: start, isSelected: false), lineWidth: 2)
                            let angle = atan2(end.y - start.y, end.x - start.x)
                            Text("\(numberedArrows.count + 1)")
                                .foregroundColor(getDrawingColor(at: start, isSelected: false))
                                .font(.system(size: 16, weight: .bold))
                                .position(x: start.x - 30 * cos(angle),
                                        y: start.y - 30 * sin(angle))
                        }
                    }
                    
                    // Draw rectangles after pixelated areas so they appear on top
                    ForEach(rectangles.indices, id: \.self) { index in
                        let isSelected = rectangles[index].id == selectedElementId
                        ZStack {
                            Rectangle()
                                .stroke(drawingColor(for: rectangles[index].id, fallbackPoint: CGPoint(x: rectangles[index].rect.midX, y: rectangles[index].rect.midY)),
                                       lineWidth: 2)
                                .frame(width: rectangles[index].rect.width, height: rectangles[index].rect.height)
                                .position(x: rectangles[index].rect.midX, y: rectangles[index].rect.midY)
                                .contextMenu {
                                    Button(action: {
                                        // Delete this rectangle
                                        let deletedId = rectangles[index].id
                                        rectangles.removeAll { $0.id == deletedId }
                                        elementColors.removeValue(forKey: deletedId)
                                        selectedElementId = nil
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .help("Click to select, drag to move, or right-click to delete this rectangle. You can also press Delete key to remove it.")

                            if isSelected {
                                Rectangle()
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: rectangles[index].rect.width + 8, height: rectangles[index].rect.height + 8)
                                    .position(x: rectangles[index].rect.midX, y: rectangles[index].rect.midY)
                            }
                        }
                    }
                    
                    // Preview current rectangle
                    if currentTool == .rectangle && isDrawing,
                       let start = firstPoint,
                       let current = currentPoint {
                        let rect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                        Rectangle()
                            .stroke(getDrawingColor(at: CGPoint(x: rect.midX, y: rect.midY), isSelected: false), lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    
                    // Preview current pixelated rectangle
                    if currentTool == .pixelate && isDrawing,
                       let start = firstPoint,
                       let current = currentPoint {
                        let rect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                        Rectangle()
                            .stroke(Color.gray, lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }

                    // Add the magnifying glass overlay
                    if (isSelecting || currentTool == .elementSelect) && showMagnifyingGlass {
                        MagnifyingGlassView(cursorPosition: cursorPosition)
                    }
                } else {
                    Color.black.opacity(0.5)
                }

                HStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                loadScreenshotHistory()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showHistoryPanel = true
                                }
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    if !isHoveringHistoryPanel {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            showHistoryPanel = false
                                        }
                                    }
                                }
                            }
                        }
                    Spacer()
                }
                .zIndex(100)

                if showHistoryPanel {
                    screenshotHistoryPanel
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                        .padding(.top, 12)
                        .zIndex(101)
                        .onHover { hovering in
                            isHoveringHistoryPanel = hovering
                            if !hovering {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showHistoryPanel = false
                                }
                            }
                        }
                }
            }
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        print("Tap gesture detected, current tool: \(currentTool)")
                        if let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<CaptureView> }) {
                            let mouseLocation = NSEvent.mouseLocation
                            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
                            if let view = window.contentView {
                                let viewPoint = view.convert(windowPoint, from: nil)

                                // Keep text size controls interactive.
                                if isPointInTextFontControl(point: viewPoint) {
                                    return
                                }
                                
                                // Check if we clicked on the toolbar
                                if let rect = selectionRect {
                                    let toolbarHeight: CGFloat = 36
                                    let margin: CGFloat = 16
                                    let toolbarY = rect.maxY + (toolbarHeight/2 + margin)
                                    let toolbarRect = CGRect(
                                        x: rect.maxX - min(350, rect.width/2) - 350,
                                        y: toolbarY - toolbarHeight/2,
                                        width: 700,
                                        height: toolbarHeight
                                    )
                                    
                                    // If we clicked on the toolbar, don't start text editing
                                    if toolbarRect.contains(viewPoint) {
                                        return
                                    }
                                }
                                
                                if currentTool == .elementSelect {
                                    handleElementSelection(at: viewPoint)
                                } else if currentTool == .text || currentTool == .numberedText {
                                    if let rect = selectionRect, rect.contains(viewPoint) {
                                        startTextEditing(at: viewPoint, in: geometry)
                                    }
                                } else if currentTool == .smiley {
                                    // For smiley tool, show the picker at the clicked position
                                    smileyPickerPosition = viewPoint
                                    showSmileyPicker = true
                                    print("Showing smiley picker at: \(viewPoint)")
                                } else if showSmileyPicker {
                                    // Close the smiley picker when clicking elsewhere
                                    showSmileyPicker = false
                                    print("Closing smiley picker due to click elsewhere")
                                }
                            }
                        }
                    }
            , including: .gesture)
            .gesture(
                DragGesture(minimumDistance: 0.1, coordinateSpace: .local)
                    .onChanged { value in
                            if isPointInTextFontControl(point: value.startLocation) {
                                return
                            }
                            handleDragChange(value)
                    }
                    .onEnded { value in
                            if isPointInTextFontControl(point: value.startLocation) {
                                return
                            }
                            handleDragEnd(value)
                    }
            , including: .gesture)
            .onAppear {
                migrateLegacyCaptureColorDataIfNeeded()
                loadScreenshotHistory()
                if selectionRect == nil, let initialSelectionRect {
                    selectionRect = initialSelectionRect
                    currentTool = .select
                    helpText = "Screenshot-Editor bereit. Waehle ein Tool oder klicke Done."
                } else if selectionRect == nil, autoSelectVisibleImage,
                          let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<CaptureView> }),
                          let contentSize = window.contentView?.bounds.size {
                    selectionRect = fittedImageRect(in: contentSize)
                    currentTool = .select
                    helpText = "Screenshot-Editor bereit. Waehle ein Tool oder klicke Done."
                }

                // Setup delete key monitor
                deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 { // ESC
                        if selectionRect != nil {
                            autoSaveCurrentCaptureIfNeeded()
                        }
                        closeCaptureWindows()
                        return nil
                    }
                    switch event.keyCode {
                    case 123, 126: // Left / Up -> previous (newer)
                        if isEditingText { completeTextEditing() }
                        navigateScreenshotHistory(step: -1)
                        return nil
                    case 124, 125: // Right / Down -> next (older)
                        if isEditingText { completeTextEditing() }
                        navigateScreenshotHistory(step: 1)
                        return nil
                    default:
                        break
                    }
                    if event.keyCode == 51 || event.keyCode == 117 { // Backspace/Delete key
                        if selectedElementId != nil {
                            // Use the deleteSelectedElement method to ensure proper renumbering
                            deleteSelectedElement()
                            return nil
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor = deleteMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                removeTextMonitor()
            }
            .onReceive(timer) { _ in
                if isEditingText {
                    showCursor.toggle()
                }
            }
            .onChange(of: currentTool) { newTool in
                if suppressNextToolHelpUpdate {
                    suppressNextToolHelpUpdate = false
                    return
                }
                // Update help text when tool changes
                updateHelpText(for: newTool)
            }
            .onChange(of: isDrawing) { isDrawing in
                // Update help text for drawing operations
                if isDrawing && (currentTool == .rectangle || currentTool == .arrow || 
                               currentTool == .numberedArrow || currentTool == .pixelate) {
                    helpText = "Drag to define area: Start \(formatPoint(firstPoint)), Current \(formatPoint(currentPoint)), Size: \(formatSize())"
                }
            }
            .onChange(of: selectedElementId) { selectedId in
                if let selectedId, let elementColor = elementColors[selectedId] {
                    selectedDrawingColor = elementColor
                }
            }
        }
    }
    
    private func startTextEditing(
        at position: CGPoint,
        in geometry: GeometryProxy?,
        forcedPrefix: String? = nil,
        isNumbered: Bool? = nil,
        incrementsNumCount: Bool? = nil,
        discardIfEmpty: Bool = false
    ) {
        print("Starting text editing at position: \(position)")
        // Store the position directly, no need for additional conversion
        textPosition = position
        isEditingText = true
        editingText = ""
        discardCurrentTextIfEmpty = discardIfEmpty
        activeTextIsNumbered = isNumbered ?? (currentTool == .numberedText)
        activeTextIncrementsNumCount = incrementsNumCount ?? activeTextIsNumbered
        textPrefix = forcedPrefix ?? ""
        
        setupTextMonitor(respectExistingPrefix: forcedPrefix != nil)
    }
    
    private func setupTextMonitor(respectExistingPrefix: Bool = false) {
        print("Setting up text monitor")
        removeTextMonitor()

        // Only set prefix if it wasn't explicitly set by caller.
        if !respectExistingPrefix && currentTool == .numberedText {
            textPrefix = "\(numCount). "
            print("Setting up numbered text with prefix: '\(textPrefix)' (numCount: \(numCount))")
        } else if !respectExistingPrefix {
            textPrefix = ""  // Ensure prefix is cleared for regular text
        }
        
        // Monitor for key events
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            print("Text monitor received key event: \(event.keyCode)")
            
            if event.keyCode == 53 { // ESC key
                if selectionRect != nil {
                    autoSaveCurrentCaptureIfNeeded()
                }
                closeCaptureWindows()
                return nil
            }

            // Handle delete key (backspace or cmd+backspace) for selected elements
            if event.keyCode == 51 || event.keyCode == 117 { // Backspace/Delete key
                if selectedElementId != nil {
                    // Use the deleteSelectedElement method to ensure proper renumbering
                    deleteSelectedElement()
                    return nil
                }
            }
            
            // Arrow keys always navigate history, even during text editing
            if [123, 124, 125, 126].contains(event.keyCode) {
                return event
            }

            guard isEditingText else {
                return event
            }
            
            if event.keyCode == 36 { // Return key
                if event.modifierFlags.contains(.command) {
                    completeTextEditing()
                    return nil
                }
                if event.modifierFlags.contains(.shift) {
                    editingText += "\n"
                    return nil
                }
                print("Return key pressed")
                completeTextEditing()
                return nil
            }
            else if event.keyCode == 51 || event.keyCode == 117 { // Backspace/Delete key
                if !editingText.isEmpty {
                    editingText.removeLast()
                }
                return nil
            }
            else if let characters = event.characters {
                print("Adding characters: '\(characters)' to text")
                editingText += characters
                return nil
            }
            
            return event
        }
        
        // Add separate monitor for mouse events
        let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            print("Mouse click detected, removing text monitor")
            if isEditingText {
                if let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<CaptureView> }) {
                    let mouseLocation = NSEvent.mouseLocation
                    let windowPoint = window.convertPoint(fromScreen: mouseLocation)
                    if let view = window.contentView {
                        let viewPoint = view.convert(windowPoint, from: nil)
                        if isPointInTextFontControl(point: viewPoint) {
                            return event
                        }
                    }
                }
                completeTextEditing()
            }
            return event
        }
        
        // Store both monitors
        textMonitor = [keyMonitor, mouseMonitor]
    }
    
    // Centralized function to handle text completion
    private func completeTextEditing() {
        if let position = textPosition {
            print("Completing text editing: '\(editingText)' at position: \(position) with prefix: '\(textPrefix)'")
            
            let trimmedText = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if discardCurrentTextIfEmpty && trimmedText.isEmpty {
                editingText = ""
                isEditingText = false
                textPosition = nil
                textPrefix = ""
                activeTextIsNumbered = false
                activeTextIncrementsNumCount = false
                discardCurrentTextIfEmpty = false
                removeTextMonitor()
                return
            }
            
            // Create a tuple with the text, position, ID, and a flag indicating if it's a numbered text
            texts.append((
                text: textPrefix + editingText,
                position: CGPoint(x: position.x, y: position.y),
                id: UUID(),
                isNumberedText: activeTextIsNumbered
            ))
            if let createdId = texts.last?.id {
                textFontSizes[createdId] = currentEditingFontSize
                elementColors[createdId] = selectedDrawingColor
            }
            
            // Always increment numCount for numbered text, regardless of whether text was entered
            if activeTextIncrementsNumCount {
                numCount += 1
                print("Incremented numCount to: \(numCount)")
            }
            
            editingText = ""
            isEditingText = false
            textPosition = nil
            textPrefix = ""  // Reset prefix
            activeTextIsNumbered = false
            activeTextIncrementsNumCount = false
            discardCurrentTextIfEmpty = false
            
            removeTextMonitor()
        }
    }
    
    private func removeTextMonitor() {
        if let monitors = textMonitor as? [Any] {
            monitors.forEach { NSEvent.removeMonitor($0) }
        }
        textMonitor = nil
    }

    private func closeCaptureWindows() {
        ScreenCaptureState.isOverlayActive = false
        NSApp.windows.forEach { window in
            if window.contentView is NSHostingView<CaptureView> {
                window.close()
            }
        }
    }
    
    private func handleTap(_ location: CGPoint, in geometry: GeometryProxy) {
        guard !isSelecting, selectionRect != nil else { return }
        
        switch currentTool {
        case .text, .numberedText:
            startTextEditing(at: location, in: geometry)
        default:
            break
        }
    }
    
    private func handleDragChange(_ value: DragGesture.Value) {
        // Always update cursor position for all tools
        cursorPosition = value.location

        if isDraggingElement,
           let selectedElement = selectedElementId,
           canDragCurrentElement,
           let previousPoint = firstPoint {
            let deltaX = value.location.x - previousPoint.x
            let deltaY = value.location.y - previousPoint.y
            moveElement(selectedElement, deltaX: deltaX, deltaY: deltaY)
            firstPoint = value.location
            showMagnifyingGlass = true
            return
        }

        if beginElementDrag(at: value.startLocation) {
            showMagnifyingGlass = true
            return
        }
        
        switch currentTool {
        case .changeSelection:
            if !isSelecting {
                firstPoint = value.startLocation
                isSelecting = true
            }
            currentPoint = value.location
            // Update help text with detailed coordinates and dimensions
            helpText = "Selection: \(formatPoint(firstPoint)) to \(formatPoint(currentPoint)), Size: \(formatSize())"
            // Show magnifying glass only while selecting
            showMagnifyingGlass = true
            
        case .select:
            if !isSelecting {
                firstPoint = value.startLocation
                isSelecting = true
                selectionRect = nil
                isEditingText = false
                editingText = ""
                textPosition = nil
            }
            currentPoint = value.location
            // Update help text with detailed coordinates and dimensions
            helpText = "Selection: \(formatPoint(firstPoint)) to \(formatPoint(currentPoint)), Size: \(formatSize())"
            // Show magnifying glass only while selecting
            showMagnifyingGlass = true
            
        case .arrow:
            if !isDrawing {
                firstPoint = value.startLocation
                currentPoint = value.startLocation
                isDrawing = true
            }
            currentPoint = value.location
            // Update help text with current dimensions
            helpText = "Arrow: Start \(formatPoint(firstPoint)), End \(formatPoint(currentPoint)), Length: \(formatLength())"
            
        case .rectangle:
            if !isDrawing {
                firstPoint = value.startLocation
                currentPoint = value.startLocation
                isDrawing = true
            }
            currentPoint = value.location
            // Update help text with current dimensions
            helpText = "Rectangle: Start \(formatPoint(firstPoint)), End \(formatPoint(currentPoint)), Size: \(formatSize())"
            
        case .numberedArrow:
            if !isDrawing {
                firstPoint = value.startLocation
                currentPoint = value.startLocation
                isDrawing = true
            }
            currentPoint = value.location
            // Update help text with current dimensions
            helpText = "Numbered Arrow \(numberedArrows.count + 1): Start \(formatPoint(firstPoint)), End \(formatPoint(currentPoint))"
            
        case .text, .numberedText:
            break
            
        case .smiley:
            // For smiley tool, we just need to track cursor position
            // Actual smiley placement happens in handleElementSelection
            if !isDrawing {
                firstPoint = value.startLocation
                currentPoint = value.startLocation
                isDrawing = true
            }
            currentPoint = value.location
            helpText = "Click to place a smiley at: \(formatPoint(currentPoint))"
            
        case .elementSelect:
            showMagnifyingGlass = false
            
        case .pixelate:
            if !isDrawing {
                firstPoint = value.startLocation
                currentPoint = value.startLocation
                isDrawing = true
            }
            currentPoint = value.location
            // Update help text with current dimensions
            helpText = "Pixelate: Start \(formatPoint(firstPoint)), End \(formatPoint(currentPoint)), Size: \(formatSize())"
            // Show magnifying glass for other drawing tools
            showMagnifyingGlass = true
        }
    }
    
    private func handleDragEnd(_ value: DragGesture.Value) {
        if isDraggingElement {
            isDraggingElement = false
            dragOffset = nil
            firstPoint = nil
            currentPoint = nil
            canDragCurrentElement = false
            showMagnifyingGlass = false
            return
        }

        switch currentTool {
        case .changeSelection:
            isSelecting = false
            if let first = firstPoint {
                let second = value.location
                selectionRect = CGRect(
                    x: min(first.x, second.x),
                    y: min(first.y, second.y),
                    width: abs(second.x - first.x),
                    height: abs(second.y - first.y)
                )
                // Reset to element select tool after changing selection
                currentTool = .elementSelect
            }
            // Hide magnifying glass after selection is complete
            showMagnifyingGlass = false
            
        case .select:
            isSelecting = false
            if let first = firstPoint {
                let second = value.location
                selectionRect = CGRect(
                    x: min(first.x, second.x),
                    y: min(first.y, second.y),
                    width: abs(second.x - first.x),
                    height: abs(second.y - first.y)
                )
            }
            // Hide magnifying glass after selection is complete
            showMagnifyingGlass = false
            
        case .arrow:
            if let start = firstPoint {
                let newId = UUID()
                arrows.append((start: start, end: value.location, id: newId))
                arrowLineWidths[newId] = 2
                elementColors[newId] = selectedDrawingColor
                selectedElementId = newId
                helpText = "Pfeil erstellt. +/- passt die Linienstaerke an."
            }
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            
        case .rectangle:
            if let first = firstPoint {
                let rect = CGRect(
                    x: min(first.x, value.location.x),
                    y: min(first.y, value.location.y),
                    width: abs(value.location.x - first.x),
                    height: abs(value.location.y - first.y)
                )
                let newId = UUID()
                rectangles.append((rect, newId))
                elementColors[newId] = selectedDrawingColor
            }
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            
        case .numberedArrow:
            if let start = firstPoint {
                let arrowNumber = numberedArrows.count + 1
                let arrowEnd = value.location
                let newId = UUID()
                numberedArrows.append((
                    start: start,
                    end: arrowEnd,
                    number: arrowNumber,
                    id: newId
                ))
                arrowLineWidths[newId] = 2
                elementColors[newId] = selectedDrawingColor
                selectedElementId = newId
                helpText = "Nummerierter Pfeil erstellt. +/- passt die Linienstaerke an."
                
                // Optional immediate annotation after placing a numbered arrow.
                if selectionRect != nil {
                    let textPosition = suggestedNumberedArrowTextPosition(start: start, end: arrowEnd)
                    startTextEditing(
                        at: textPosition,
                        in: nil,
                        forcedPrefix: "",
                        isNumbered: false,
                        incrementsNumCount: false,
                        discardIfEmpty: true
                    )
                }
            }
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            
        case .text, .numberedText:
            break
            
        case .smiley:
            // Smiley tool doesn't need drag end handling as smileys are added via the picker
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            
        case .elementSelect:
            // Hide magnifying glass when not dragging elements
            showMagnifyingGlass = false
            
        case .pixelate:
            if let first = firstPoint {
                let rect = CGRect(
                    x: min(first.x, value.location.x),
                    y: min(first.y, value.location.y),
                    width: abs(value.location.x - first.x),
                    height: abs(value.location.y - first.y)
                )
                
                if let pixelated = createPixelatedImage(in: rect) {
                    pixelatedRects.append((rect, pixelated, UUID()))
                }
            }
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            // Hide magnifying glass after drawing is complete
            showMagnifyingGlass = false
        }
    }

    private func beginElementDrag(at point: CGPoint) -> Bool {
        if let selected = selectedElementId,
           isPointInsideSelectedBoundingBox(point, selectedElement: selected) {
            // Keep current selection and allow drag from anywhere inside the selected bounding box.
        } else if selectedElementId == nil || !isPointInsideSelectedElement(point, selectedElementId) {
            selectedElementId = elementId(at: point)
        }

        guard let selectedElement = selectedElementId else { return false }
        guard canStartDraggingElement(selectedElement, at: point) else {
            canDragCurrentElement = false
            return false
        }

        canDragCurrentElement = true
        isDraggingElement = true
        firstPoint = point
        dragOffset = .zero
        return true
    }

    private func canStartDraggingElement(_ selectedElement: UUID, at point: CGPoint) -> Bool {
        if let bounds = selectedElementBoundingRect(for: selectedElement) {
            return bounds.contains(point)
        }
        return true
    }

    private func moveElement(_ selectedElement: UUID, deltaX: CGFloat, deltaY: CGFloat) {
        if let index = texts.firstIndex(where: { $0.id == selectedElement }) {
            texts[index].position = CGPoint(
                x: texts[index].position.x + deltaX,
                y: texts[index].position.y + deltaY
            )
            helpText = "Moving text to: \(formatPoint(texts[index].position))"
            return
        }

        if let index = arrows.firstIndex(where: { $0.id == selectedElement }) {
            arrows[index].start = CGPoint(
                x: arrows[index].start.x + deltaX,
                y: arrows[index].start.y + deltaY
            )
            arrows[index].end = CGPoint(
                x: arrows[index].end.x + deltaX,
                y: arrows[index].end.y + deltaY
            )
            helpText = "Moving arrow to: Start \(formatPoint(arrows[index].start)), End \(formatPoint(arrows[index].end))"
            return
        }

        if let index = numberedArrows.firstIndex(where: { $0.id == selectedElement }) {
            numberedArrows[index].start = CGPoint(
                x: numberedArrows[index].start.x + deltaX,
                y: numberedArrows[index].start.y + deltaY
            )
            numberedArrows[index].end = CGPoint(
                x: numberedArrows[index].end.x + deltaX,
                y: numberedArrows[index].end.y + deltaY
            )
            helpText = "Moving numbered arrow \(numberedArrows[index].number) to: Start \(formatPoint(numberedArrows[index].start)), End \(formatPoint(numberedArrows[index].end))"
            return
        }

        if let index = rectangles.firstIndex(where: { $0.id == selectedElement }) {
            rectangles[index].rect = CGRect(
                x: rectangles[index].rect.origin.x + deltaX,
                y: rectangles[index].rect.origin.y + deltaY,
                width: rectangles[index].rect.width,
                height: rectangles[index].rect.height
            )
            let rect = rectangles[index].rect
            helpText = "Moving rectangle to: \(formatPoint(CGPoint(x: rect.minX, y: rect.minY))), Size: \(Int(rect.width))×\(Int(rect.height))"
            return
        }

        if let index = pixelatedRects.firstIndex(where: { $0.id == selectedElement }) {
            pixelatedRects[index].rect = CGRect(
                x: pixelatedRects[index].rect.origin.x + deltaX,
                y: pixelatedRects[index].rect.origin.y + deltaY,
                width: pixelatedRects[index].rect.width,
                height: pixelatedRects[index].rect.height
            )
            let rect = pixelatedRects[index].rect
            helpText = "Moving pixelated area to: \(formatPoint(CGPoint(x: rect.minX, y: rect.minY))), Size: \(Int(rect.width))×\(Int(rect.height))"
            return
        }

        if let index = smileys.firstIndex(where: { $0.id == selectedElement }) {
            smileys[index].position = CGPoint(
                x: smileys[index].position.x + deltaX,
                y: smileys[index].position.y + deltaY
            )
            helpText = "Moving smiley to: \(formatPoint(smileys[index].position)), Size: \(Int(smileys[index].size))"
        }
    }

    private func isPointInsideSelectedElement(_ point: CGPoint, _ selectedElement: UUID?) -> Bool {
        guard let selectedElement else { return false }
        if isPointInsideSelectedBoundingBox(point, selectedElement: selectedElement) {
            return true
        }
        return elementId(at: point) == selectedElement
    }

    private func isPointInsideSelectedBoundingBox(_ point: CGPoint, selectedElement: UUID) -> Bool {
        guard let bounds = selectedElementBoundingRect(for: selectedElement) else { return false }
        return bounds.contains(point)
    }

    private func selectedElementBoundingRect(for elementId: UUID) -> CGRect? {
        if let text = texts.first(where: { $0.id == elementId }) {
            let fontSize = textFontSizes[elementId] ?? 20
            let textSize = textBlockSize(for: text.text, fontSize: fontSize)
            return CGRect(
                x: text.position.x - 4,
                y: text.position.y - textSize.height / 2 - 4,
                width: textSize.width + 8,
                height: textSize.height + 8
            )
        }

        if let pixelRect = pixelatedRects.first(where: { $0.id == elementId }) {
            return pixelRect.rect.insetBy(dx: -4, dy: -4)
        }

        if let smiley = smileys.first(where: { $0.id == elementId }) {
            let size = smiley.size * 1.2
            return CGRect(
                x: smiley.position.x - size / 2,
                y: smiley.position.y - size / 2,
                width: size,
                height: size
            )
        }

        if let arrow = arrows.first(where: { $0.id == elementId }) {
            return boundingRectForLine(start: arrow.start, end: arrow.end, padding: 10)
        }

        if let arrow = numberedArrows.first(where: { $0.id == elementId }) {
            return boundingRectForLine(start: arrow.start, end: arrow.end, padding: 10)
        }

        if let rect = rectangles.first(where: { $0.id == elementId }) {
            return rect.rect.insetBy(dx: -4, dy: -4)
        }

        return nil
    }

    private func elementId(at point: CGPoint) -> UUID? {
        guard let rect = selectionRect, rect.contains(point) else { return nil }

        for text in texts {
            let fontSize = textFontSizes[text.id] ?? 20
            let textSize = textBlockSize(for: text.text, fontSize: fontSize)
            let textBox = CGRect(
                x: text.position.x,
                y: text.position.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            if textBox.contains(point) {
                return text.id
            }
        }

        for smiley in smileys {
            let hitArea = CGRect(
                x: smiley.position.x - smiley.size / 2,
                y: smiley.position.y - smiley.size / 2,
                width: smiley.size,
                height: smiley.size
            )
            if hitArea.contains(point) {
                return smiley.id
            }
        }

        for pixelRect in pixelatedRects where pixelRect.rect.insetBy(dx: -5, dy: -5).contains(point) {
            return pixelRect.id
        }

        for arrow in arrows where isPointNearLine(point: point, start: arrow.start, end: arrow.end) {
            return arrow.id
        }

        for arrow in numberedArrows where isPointNearLine(point: point, start: arrow.start, end: arrow.end) {
            return arrow.id
        }

        for rect in rectangles where rect.rect.insetBy(dx: -5, dy: -5).contains(point) {
            return rect.id
        }

        return nil
    }

    private func suggestedNumberedArrowTextPosition(start: CGPoint, end: CGPoint) -> CGPoint {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let angle = atan2(deltaY, deltaX)
        let numberPosition = CGPoint(
            x: start.x - 30 * cos(angle),
            y: start.y - 30 * sin(angle)
        )

        let sidePadding: CGFloat = 16
        let verticalPadding: CGFloat = 34
        var proposed = numberPosition

        // Position text around the numbered marker depending on arrow orientation.
        if abs(deltaX) >= abs(deltaY) {
            // Mostly horizontal arrow -> text left/right of number.
            if deltaX >= 0 {
                proposed.x = numberPosition.x - minTextEditorWidth - sidePadding
            } else {
                proposed.x = numberPosition.x + sidePadding
            }
        } else {
            // Mostly vertical arrow -> text above/below number.
            proposed.x = numberPosition.x - (minTextEditorWidth / 2)
            if deltaY >= 0 {
                proposed.y = numberPosition.y + verticalPadding
            } else {
                proposed.y = numberPosition.y - verticalPadding
            }
        }

        if let rect = selectionRect {
            let insetRect = rect.insetBy(dx: 14, dy: 14)
            proposed.x = min(max(proposed.x, insetRect.minX), insetRect.maxX)
            proposed.y = min(max(proposed.y, insetRect.minY), insetRect.maxY)
        }

        return proposed
    }
    
    private func makeRect(from: CGPoint?, to: CGPoint?) -> CGRect? {
        guard let start = from, let end = to else { return nil }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
    
    /*private func isPointNearElement(point: CGPoint, elementPosition: CGPoint) -> Bool {
        let distance = sqrt(pow(point.x - elementPosition.x, 2) + pow(point.y - elementPosition.y, 2))
        return distance < 20
    }*/

    private func isPointNearLine(point: CGPoint, start: CGPoint, end: CGPoint) -> Bool {
        let lineLength = sqrt(pow(end.x - start.x, 2) + pow(end.y - start.y, 2))
        let d1 = sqrt(pow(point.x - start.x, 2) + pow(point.y - start.y, 2))
        let d2 = sqrt(pow(point.x - end.x, 2) + pow(point.y - end.y, 2))
        
        // Check if point is near the line using distance formula
        let buffer = 5.0 // Reduced tolerance in pixels
        let distance = abs((end.y - start.y) * point.x - (end.x - start.x) * point.y + end.x * start.y - end.y * start.x) / lineLength
        
        return distance < buffer && d1 + d2 < lineLength + buffer
    }

    private func handleElementSelection(at point: CGPoint) {
        // If we're in smiley mode, show the smiley picker regardless of selection rect
        if currentTool == .smiley {
            smileyPickerPosition = point
            showSmileyPicker = true
            return
        }
        
        guard let rect = selectionRect else { return }
        
        print("Handling element selection at point: \(point)")
        
        // Ensure the point is within the selection area
        guard rect.contains(point) else {
            selectedElementId = nil
            return
        }
        
        // If we're in text mode, start text editing instead of selecting elements
        if currentTool == .text || currentTool == .numberedText {
            startTextEditing(at: point, in: nil)
            return
        }
        
        // Check texts with exact hit box
        for text in texts {
            let fontSize = textFontSizes[text.id] ?? 20
            let textSize = textBlockSize(for: text.text, fontSize: fontSize)
            let textWidth = textSize.width
            let textHeight = textSize.height
            let textBoxX = text.position.x
            let textBoxY = text.position.y - textHeight/2
            let textBox = CGRect(x: textBoxX, y: textBoxY, width: textWidth, height: textHeight)
            
            print("Checking text box: \(textBox) for point: \(point)")
            if textBox.contains(point) {
                print("Selected text element with id: \(text.id)")
                selectedElementId = text.id
                return
            }
        }
        
        // Check smileys
        for smiley in smileys {
            let smileySize = smiley.size
            let hitArea = CGRect(
                x: smiley.position.x - smileySize/2,
                y: smiley.position.y - smileySize/2,
                width: smileySize,
                height: smileySize
            )
            
            if hitArea.contains(point) {
                print("Selected smiley element with id: \(smiley.id)")
                selectedElementId = smiley.id
                return
            }
        }
        
        // Check pixelated rectangles with small tolerance
        for pixelRect in pixelatedRects {
            let expandedRect = pixelRect.rect.insetBy(dx: -5, dy: -5)
            if expandedRect.contains(point) {
                print("Selected pixelated rectangle with id: \(pixelRect.id)")
                selectedElementId = pixelRect.id
                helpText = "Pixelated area selected. Drag to move, press Delete to remove, or right-click for options."
                return
            }
        }
        
        // Check arrows with small tolerance
        for arrow in arrows {
            if isPointNearLine(point: point, start: arrow.start, end: arrow.end) {
                print("Selected arrow element with id: \(arrow.id)")
                selectedElementId = arrow.id
                return
            }
        }
        
        // Check numbered arrows
        for arrow in numberedArrows {
            if isPointNearLine(point: point, start: arrow.start, end: arrow.end) {
                print("Selected numbered arrow element with id: \(arrow.id)")
                selectedElementId = arrow.id
                return
            }
        }
        
        // Check rectangles with small tolerance
        for rect in rectangles {
            let expandedRect = rect.rect.insetBy(dx: -5, dy: -5)
            if expandedRect.contains(point) {
                print("Selected rectangle element with id: \(rect.id)")
                selectedElementId = rect.id
                return
            }
        }
        
        print("No element selected at point: \(point)")
        selectedElementId = nil
    }
    
    private func createPixelatedImage(in rect: CGRect) -> NSImage? {
        // Get the portion of the image we want to pixelate
        guard let cgImage = workingImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let scale = CGFloat(cgImage.width) / workingImage.size.width
        let scaledRect = NSRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        
        guard let imageToPixelate = cgImage.cropping(to: scaledRect) else { return nil }
        
        // Calculate average brightness of the area to determine overlay color
        let averageBrightness = calculateAverageBrightness(of: imageToPixelate)
        
        // Get the current mouse position to determine which screen we're on
        let mouseLocation = NSEvent.mouseLocation
        print("Current mouse location: \(mouseLocation)")
        
        // Find the screen containing the mouse cursor
        let screenWithMouse = NSScreen.screens.first { screen in
            NSPointInRect(mouseLocation, screen.frame)
        } ?? NSScreen.main
        
        // Debug information about screens
        print("Total screens: \(NSScreen.screens.count)")
        
        // Log information about all screens
        for (index, screen) in NSScreen.screens.enumerated() {
            print("Screen \(index): frame=\(screen.frame), backingScaleFactor=\(screen.backingScaleFactor), visibleFrame=\(screen.visibleFrame)")
        }
        
        // Log which screen was detected based on mouse position
        if let screen = screenWithMouse {
            print("Selected screen (based on mouse): frame=\(screen.frame), backingScaleFactor=\(screen.backingScaleFactor)")
        } else {
            print("No screen detected for mouse position")
        }
        
        // More reliable 4K detection - use the screen where the mouse is
        var is4KOrHigher = false
        var basePixelBlockSize: CGFloat = 5 // Default size
        
        if let screen = screenWithMouse {
            let screenWidth = screen.frame.width
            let screenHeight = screen.frame.height
            let backingScaleFactor = screen.backingScaleFactor
            
            // Check if this is a high-resolution display (4K or higher)
            // For Retina displays, the backing scale factor is typically 2.0
            // For 4K displays, either the dimensions will be large or the backing scale factor will be high
            is4KOrHigher = (screenWidth >= 3000 || screenHeight >= 1800 || backingScaleFactor >= 1.5)
            
            print("Screen dimensions: \(screenWidth) x \(screenHeight), backingScaleFactor: \(backingScaleFactor)")
            print("Detected as 4K or higher: \(is4KOrHigher)")
            
            // Adjust block size based on screen properties
            if is4KOrHigher {
                // For 4K displays, use much larger blocks
                basePixelBlockSize = 10
                
                // For extremely high-resolution displays, go even larger
                if screenWidth >= 5000 || screenHeight >= 3000 || backingScaleFactor >= 3.0 {
                    basePixelBlockSize = 20
                }
            }
        } else {
            // Fallback to a simple check if we couldn't determine the screen
            let mainScreenWidth = NSScreen.main?.frame.width ?? 0
            let mainScreenHeight = NSScreen.main?.frame.height ?? 0
            is4KOrHigher = (mainScreenWidth >= 3000 || mainScreenHeight >= 1800)
            basePixelBlockSize = is4KOrHigher ? 10 : 5
            print("Using fallback screen detection. Main screen: \(mainScreenWidth) x \(mainScreenHeight), 4K: \(is4KOrHigher)")
        }
        
        // Add randomization to the pixel block size (±20%)
        let randomVariation = CGFloat.random(in: 0.8...1.2)
        let pixelBlockSize = basePixelBlockSize * randomVariation
        
        print("Using pixel block size: \(pixelBlockSize) (base: \(basePixelBlockSize), variation: \(randomVariation))")
        
        // Create a non-uniform grid by using different block sizes for width and height
        let widthVariation = CGFloat.random(in: 0.9...1.1)
        let heightVariation = CGFloat.random(in: 0.9...1.1)
        
        let contextSize = CGSize(
            width: max(1, rect.width * scale / (pixelBlockSize * widthVariation)),
            height: max(1, rect.height * scale / (pixelBlockSize * heightVariation))
        )
        
        let context = CGContext(
            data: nil,
            width: Int(contextSize.width),
            height: Int(contextSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        context?.interpolationQuality = .none
        context?.draw(imageToPixelate, in: CGRect(origin: .zero, size: contextSize))
        
        guard let smallImage = context?.makeImage() else { return nil }
        
        // Create a final context with the exact dimensions of our target rectangle
        let finalContext = CGContext(
            data: nil,
            width: Int(rect.width * scale),
            height: Int(rect.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        // First, draw the original image to ensure we have content all the way to the edges
        finalContext?.draw(imageToPixelate, in: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        
        // Create a mask for the blur effect that's slightly smaller than the full rectangle
        // to avoid edge artifacts but will still cover the entire visible area
        let maskInset: CGFloat = -2.0 * scale // Negative inset means we expand the mask beyond the edges
        let maskRect = CGRect(
            x: maskInset,
            y: maskInset,
            width: rect.width * scale - 2 * maskInset,
            height: rect.height * scale - 2 * maskInset
        )
        
        // Create a path for the mask
        finalContext?.saveGState()
        finalContext?.addRect(maskRect)
        finalContext?.clip()
        
        // Draw the pixelated image with no interpolation
        finalContext?.interpolationQuality = .none
        finalContext?.draw(smallImage, in: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        
        // Add random color noise to the pixelated image for better privacy
        addRandomNoiseToContext(finalContext, rect: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)), intensity: 0.05)
        
        // Apply a blur effect directly in the context if possible
        if let currentFilter = CIFilter(name: "CIGaussianBlur") {
            guard let pixelatedCGImage = finalContext?.makeImage() else { return nil }
            let ciImage = CIImage(cgImage: pixelatedCGImage)
            
            // Adjust blur radius based on screen resolution with randomization
            let baseBlurRadius: CGFloat = is4KOrHigher ? 6.0 : 3.0
            let randomBlurVariation = CGFloat.random(in: 0.9...1.1)
            let blurRadius = baseBlurRadius * randomBlurVariation
            
            print("Using blur radius: \(blurRadius) (base: \(baseBlurRadius), variation: \(randomBlurVariation))")
            
            currentFilter.setValue(ciImage, forKey: kCIInputImageKey)
            currentFilter.setValue(blurRadius, forKey: kCIInputRadiusKey) // Adjusted blur radius
            
            if let outputImage = currentFilter.outputImage {
                let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                
                // Create the blurred image, ensuring it covers the entire area
                if let blurredCGImage = ciContext.createCGImage(
                    outputImage,
                    from: CGRect(
                        x: 0,
                        y: 0,
                        width: rect.width * scale,
                        height: rect.height * scale
                    )
                ) {
                    // Instead of clearing the context, we'll draw the blurred image on top
                    // with a blend mode that ensures complete coverage
                    finalContext?.saveGState()
                    finalContext?.setBlendMode(.normal)
                    finalContext?.draw(blurredCGImage, in: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
                    finalContext?.restoreGState()
                }
            }
        }
        
        // Ensure we have a final pixelated fallback if blurring failed
        if finalContext?.makeImage() == nil {
            // If blurring failed, make sure we at least have the pixelated image
            finalContext?.draw(smallImage, in: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        }
        
        finalContext?.restoreGState()
        
        // Apply overlay based on brightness with reduced opacity and slight randomization
        let overlayOpacity = CGFloat.random(in: 0.08...0.12) // Random opacity between 0.08 and 0.12
        
        if averageBrightness > 0.5 {
            // Dark overlay for light backgrounds with random color variation
            let darkValue = CGFloat.random(in: 0.0...0.1) // Slight random variation in darkness
            finalContext?.setFillColor(CGColor(gray: darkValue, alpha: overlayOpacity))
        } else {
            // Light overlay for dark backgrounds with random color variation
            let lightValue = CGFloat.random(in: 0.9...1.0) // Slight random variation in lightness
            finalContext?.setFillColor(CGColor(gray: lightValue, alpha: overlayOpacity))
        }
        
        finalContext?.fill(CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        
        guard let finalCGImage = finalContext?.makeImage() else { return nil }
        return NSImage(cgImage: finalCGImage, size: rect.size)
    }
    
    // Helper function to add random noise to a context
    private func addRandomNoiseToContext(_ context: CGContext?, rect: CGRect, intensity: CGFloat) {
        guard let context = context else { return }
        
        // Create a random noise pattern
        let width = Int(rect.width)
        let height = Int(rect.height)
        
        // Only add noise to a subset of pixels for better performance
        let noiseFrequency = 0.1 // Only modify 10% of pixels
        
        for _ in 0..<Int(CGFloat(width * height) * noiseFrequency) {
            // Pick random coordinates
            let x = Int.random(in: 0..<width)
            let y = Int.random(in: 0..<height)
            
            // Create a random color variation
            let r = CGFloat.random(in: 0.0...1.0)
            let g = CGFloat.random(in: 0.0...1.0)
            let b = CGFloat.random(in: 0.0...1.0)
            let a = intensity // Use the provided intensity for alpha
            
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    
    // Helper function to calculate average brightness of an image
    private func calculateAverageBrightness(of image: CGImage) -> CGFloat {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }
        
        // Draw the image into the context
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        
        // Get the raw pixel data
        guard let data = context.data else { return 0.5 }
        
        // Sample pixels to calculate average brightness
        let totalPixels = width * height
        let sampleSize = min(totalPixels, 1000) // Sample at most 1000 pixels for performance
        let sampleInterval = max(1, totalPixels / sampleSize)
        
        var totalBrightness: CGFloat = 0
        var sampledPixels = 0
        
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)
        
        for i in stride(from: 0, to: totalPixels, by: sampleInterval) {
            let pixelOffset = i * bytesPerPixel
            let r = CGFloat(buffer[pixelOffset])
            let g = CGFloat(buffer[pixelOffset + 1])
            let b = CGFloat(buffer[pixelOffset + 2])
            
            // Calculate brightness using perceived luminance formula
            let brightness = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            totalBrightness += brightness
            sampledPixels += 1
        }
        
        return sampledPixels > 0 ? totalBrightness / CGFloat(sampledPixels) : 0.5
    }
    
    private func collectDrawings() -> [Drawing] {
        var drawings: [Drawing] = []
        
        // Add texts
        for text in texts {
            let color = (elementColors[text.id] ?? selectedDrawingColor).nsColor
            let fontSize = textFontSizes[text.id] ?? 20
            drawings.append(.text(text.text, text.position, color, fontSize))
        }
        
        // Add pixelated rectangles first (so they appear behind other elements)
        for pixelRect in pixelatedRects {
            drawings.append(.pixelatedRect(pixelRect.rect, pixelRect.image))
        }
        
        // Add arrows
        for arrow in arrows {
            let color = (elementColors[arrow.id] ?? selectedDrawingColor).nsColor
            let lineWidth = arrowLineWidths[arrow.id] ?? 2
            drawings.append(.arrow(arrow.start, arrow.end, color, lineWidth))
        }
        
        // Add numbered arrows
        for arrow in numberedArrows {
            let color = (elementColors[arrow.id] ?? selectedDrawingColor).nsColor
            let lineWidth = arrowLineWidths[arrow.id] ?? 2
            drawings.append(.numberedArrow(arrow.start, arrow.end, arrow.number, color, lineWidth))
        }
        
        // Add rectangles after pixelated areas so they appear on top
        for rect in rectangles {
            let color = (elementColors[rect.id] ?? selectedDrawingColor).nsColor
            drawings.append(.rectangle(rect.rect, color))
        }
        
        // Add smileys
        for smiley in smileys {
            let color = (elementColors[smiley.id] ?? selectedDrawingColor).nsColor
            drawings.append(.smiley(smiley.emoji, smiley.position, smiley.size, color))
        }
        
        return drawings
    }

    // Add a public method to handle deletion
    public func deleteSelectedElement() {
        if let selectedId = selectedElementId {
            print("Deleting element with ID: \(selectedId)")
            
            // Store the count before removal
            let textsCountBefore = texts.count
            let arrowsCountBefore = arrows.count
            let rectanglesCountBefore = rectangles.count
            let numberedArrowsCountBefore = numberedArrows.count
            let pixelatedRectsCountBefore = pixelatedRects.count
            let smileysCountBefore = smileys.count
            
            // Check if we're deleting a numbered arrow to handle renumbering
            let deletedNumberedArrowIndex = numberedArrows.firstIndex { $0.id == selectedId }
            let deletedArrowNumber = deletedNumberedArrowIndex.map { numberedArrows[$0].number }
            
            // Check if we're deleting a numbered text to handle renumbering
            var deletedTextNumber: Int? = nil
            if let textIndex = texts.firstIndex(where: { $0.id == selectedId }) {
                // Only process as a numbered text if it was created with the numbered text tool
                if texts[textIndex].isNumberedText {
                    let text = texts[textIndex].text
                    // Check if this is a numbered text (format: "N. text")
                    let regex = try? NSRegularExpression(pattern: "^(\\d+)\\.")
                    if let regex = regex,
                       let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.count)),
                       match.numberOfRanges > 1,
                       let numberRange = Range(match.range(at: 1), in: text),
                       let number = Int(text[numberRange]) {
                        deletedTextNumber = number
                        print("Found numbered text with number: \(number)")
                    }
                }
            }
            
            // Remove elements with the selected ID
            texts.removeAll { $0.id == selectedId }
            textFontSizes.removeValue(forKey: selectedId)
            arrows.removeAll { $0.id == selectedId }
            rectangles.removeAll { $0.id == selectedId }
            numberedArrows.removeAll { $0.id == selectedId }
            pixelatedRects.removeAll { $0.id == selectedId }
            smileys.removeAll { $0.id == selectedId }
            arrowLineWidths.removeValue(forKey: selectedId)
            elementColors.removeValue(forKey: selectedId)
            
            // If we deleted a numbered arrow, renumber the remaining arrows to maintain sequence
            if let deletedNumber = deletedArrowNumber {
                // Sort the arrows by their current number to ensure proper renumbering
                numberedArrows.sort { $0.number < $1.number }
                
                // Renumber all arrows that had a number greater than the deleted one
                for i in 0..<numberedArrows.count {
                    if numberedArrows[i].number > deletedNumber {
                        // Decrement the number by 1
                        numberedArrows[i] = (
                            start: numberedArrows[i].start,
                            end: numberedArrows[i].end,
                            number: numberedArrows[i].number - 1,
                            id: numberedArrows[i].id
                        )
                    }
                }
                print("Renumbered arrows after deleting arrow #\(deletedNumber)")
            }
            
            // If we deleted a numbered text, renumber all texts with higher numbers
            if let deletedNumber = deletedTextNumber {
                // We need to update all numbered texts with numbers greater than the deleted one
                for i in 0..<texts.count {
                    // Only process texts that were created with the numbered text tool
                    if texts[i].isNumberedText {
                        let text = texts[i].text
                        // Use the same regex pattern as above
                        let regex = try? NSRegularExpression(pattern: "^(\\d+)\\.(.*?)$")
                        if let regex = regex,
                           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.count)),
                           match.numberOfRanges > 2,
                           let numberRange = Range(match.range(at: 1), in: text),
                           let textContentRange = Range(match.range(at: 2), in: text),
                           let number = Int(text[numberRange]) {
                            
                            // If this text has a higher number than the deleted one, decrement it
                            if number > deletedNumber {
                                let newNumber = number - 1
                                let textContent = String(text[textContentRange])
                                // Preserve the space after the period if it exists
                                let hasSpace = textContent.hasPrefix(" ")
                                texts[i].text = "\(newNumber).\(hasSpace ? " " : "")\(hasSpace ? String(textContent.dropFirst()) : textContent)"
                                print("Renumbered text from \(number) to \(newNumber)")
                            }
                        }
                    }
                }
                
                // Also decrement the numCount if it's greater than the deleted number
                if numCount > deletedNumber {
                    numCount -= 1
                    print("Decremented numCount to \(numCount)")
                }
                
                print("Renumbered texts after deleting text #\(deletedNumber)")
            }
            
            // Check if any elements were removed
            if textsCountBefore > texts.count {
                print("Deleted text element")
            }
            if arrowsCountBefore > arrows.count {
                print("Deleted arrow element")
            }
            if rectanglesCountBefore > rectangles.count {
                print("Deleted rectangle element")
            }
            if numberedArrowsCountBefore > numberedArrows.count {
                print("Deleted numbered arrow element")
            }
            if pixelatedRectsCountBefore > pixelatedRects.count {
                print("Deleted pixelated rectangle element")
            }
            if smileysCountBefore > smileys.count {
                print("Deleted smiley element")
            }
            
            selectedElementId = nil
        }
    }

    // Extract toolbar view to a separate function
    private func toolbarView(for rect: CGRect, in containerSize: CGSize) -> some View {
        let buttonsHeight: CGFloat = 48 // content (36) + vertical padding (6+6)
        let margin: CGFloat = 12
        let edgePadding: CGFloat = 10
        let maxToolbarWidth: CGFloat = 620
        let minToolbarWidth: CGFloat = 300
        let availableWidth = max(180, containerSize.width - edgePadding * 2)
        let preferredWidth = min(maxToolbarWidth, max(minToolbarWidth, availableWidth))
        let toolbarWidth = min(preferredWidth, availableWidth)

        let halfW = toolbarWidth / 2
        let halfH = buttonsHeight / 2
        let minX = halfW + edgePadding
        let maxX = max(minX, containerSize.width - halfW - edgePadding)
        let adjustedX = min(max(rect.midX, minX), maxX)

        let minY = halfH + edgePadding
        let maxY = max(minY, containerSize.height - halfH - edgePadding)
        let preferredBelow = rect.maxY + margin + halfH
        let preferredAbove = rect.minY - margin - halfH

        let adjustedY: CGFloat
        if preferredBelow <= maxY {
            adjustedY = preferredBelow
        } else if preferredAbove >= minY {
            adjustedY = preferredAbove
        } else {
            let clampedBelow = min(max(preferredBelow, minY), maxY)
            let clampedAbove = min(max(preferredAbove, minY), maxY)
            let belowDistance = abs(clampedBelow - rect.maxY)
            let aboveDistance = abs(rect.minY - clampedAbove)
            adjustedY = belowDistance <= aboveDistance ? clampedBelow : clampedAbove
        }

        
        
        return HStack(spacing: 4) {
            // Modify the Adjust button to reset the selection process
            Button(action: { 
                currentTool = .select
                selectedElementId = nil
                isSelecting = false
                selectionRect = nil
                firstPoint = nil
                currentPoint = nil
                helpText = "Select an area to capture"
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "selection")
                        .font(.system(size: 10))
                    Text("Adjust")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(AdjustButtonStyle(isSelected: currentTool == .select && selectionRect == nil))
            .help("Change Selection Area")
            
            // Add a spacer to create a larger margin after the Adjust button
            Spacer()
                .frame(width: 20)
            
            Button(action: { 
                currentTool = .elementSelect
                selectedElementId = nil
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 10))
                    Text("Select")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .elementSelect))
            .help("Select Elements")
            
            Button(action: { 
                currentTool = .text 
                selectedElementId = nil
                isEditingText = false
                editingText = ""
                textPosition = nil
                textPrefix = ""  // Reset text prefix when switching to text tool
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "character")
                        .font(.system(size: 10))
                    Text("Text")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .text))
            .help("Add Text")

            Button(action: { 
                currentTool = .numberedText 
                selectedElementId = nil
                isEditingText = false
                editingText = ""
                textPosition = nil
                // Don't reset textPrefix here, it will be set when setupTextMonitor is called
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "1.circle")
                        .font(.system(size: 10))
                    Text("Number")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .numberedText))
            .help("Numbered Text")
            
            Button(action: { 
                currentTool = .arrow 
                selectedElementId = nil
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                    Text("Arrow")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .arrow))
            .help("Draw Arrow")
            
            Button(action: { 
                currentTool = .numberedArrow 
                selectedElementId = nil
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "arrowshape.turn.up.right.circle")
                        .font(.system(size: 10))
                    Text("N-Arrow")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .numberedArrow))
            .help("Numbered Arrow")
            
            Button(action: { 
                currentTool = .rectangle 
                selectedElementId = nil
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "square")
                        .font(.system(size: 10))
                    Text("Box")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .rectangle))
            .help("Draw Rectangle")
            
            Button(action: { 
                currentTool = .pixelate 
                selectedElementId = nil
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 10))
                    Text("Pixelate")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .pixelate))
            .help("Pixelate Area")
            
            Button(action: { 
                currentTool = .smiley
                selectedElementId = nil
                showSmileyPicker = false // Reset picker state
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 10))
                    Text("Smiley")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isSelected: currentTool == .smiley))
            .help("Add Smiley")

            HStack(spacing: 4) {
                ForEach(Array(drawingPalette.enumerated()), id: \.offset) { _, color in
                    Button(action: {
                        if let selectedId = selectedElementId {
                            elementColors[selectedId] = color
                        } else if let hoveredId = elementId(at: cursorPosition) {
                            elementColors[hoveredId] = color
                            selectedElementId = hoveredId
                        }
                        selectedDrawingColor = color
                    }) {
                        Circle()
                            .fill(color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(
                                        selectedDrawingColor == color ? Color.white : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .help("Drawing Color")

            // Add a delete button that's only enabled when an element is selected
            if selectedElementId != nil {
                Button(action: { 
                    deleteSelectedElement()
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Delete")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(ToolButtonStyle(isSelected: false))
                .help("Delete Selected Element")
            }
            
            Spacer()
            
            // Add OCR Copy Text button
            Button(action: {
                performOCRAndCopyText()
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10))
                    Text("Copy Text")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isPrimary: true))
            .help("Extract and copy text from selection using OCR")
            .disabled(selectionRect == nil) // Only enable when there's a selection
            
            Spacer()
            
            Button(action: {
                let drawings = collectDrawings()
                onSelection(
                    workingImage,
                    NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                    drawings,
                    loadedBaseName
                )
            }) {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("Done")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(ToolButtonStyle(isPrimary: true))
            .help("Finish")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        .frame(width: toolbarWidth)
        .position(
            x: adjustedX,
            y: adjustedY
        )
    }
    
    // Helper function to format a point for display
    private func formatPoint(_ point: CGPoint?) -> String {
        guard let point = point else { return "N/A" }
        return "(\(Int(point.x)), \(Int(point.y)))"
    }
    
    // Helper function to calculate and format the current size
    private func formatSize() -> String {
        guard let first = firstPoint, let current = currentPoint else { return "N/A" }
        let width = abs(current.x - first.x)
        let height = abs(current.y - first.y)
        return "\(Int(width))×\(Int(height))"
    }
    
    // Add a helper function to calculate the length between two points
    private func formatLength() -> String {
        guard let first = firstPoint, let current = currentPoint else { return "N/A" }
        let length = sqrt(pow(current.x - first.x, 2) + pow(current.y - first.y, 2))
        return "\(Int(length))"
    }
    
    // Update help text based on the current tool
    private func updateHelpText(for tool: DrawingTool) {
        switch tool {
        case .changeSelection:
            helpText = "Drag to adjust the selection area"
        case .select:
            helpText = "Select an area to capture"
        case .elementSelect:
            helpText = "Select an item to move it"
        case .text:
            helpText = "Click where you want to add text, then press Enter to confirm"
        case .numberedText:
            helpText = "Click where you want to add numbered text, then press Enter to confirm"
        case .arrow:
            helpText = "Drag to create an arrow"
        case .numberedArrow:
            helpText = "Drag to create a numbered arrow"
        case .rectangle:
            helpText = "Drag to create a rectangle"
        case .pixelate:
            helpText = "Drag to define area to pixelate"
        case .smiley:
            helpText = "Click where you want to add a smiley"
        }
    }

    @ViewBuilder
    private var screenshotHistoryPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshots")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Current screenshot always at the top
                        let isCurrent = (loadedBaseName == nil)
                        Button(action: {
                            restoreCurrentCapture()
                        }) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Aktuell")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text("Aktiver Screenshot")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(
                                hoveredHistoryItemId == "__current__" ? 0.16 : (isCurrent ? 0.2 : 0.08)
                            ))
                            .cornerRadius(6)
                            .overlay(
                                isCurrent
                                    ? RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                                    : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                hoveredHistoryItemId = "__current__"
                                hoveredHistoryPreviewImage = workingImage
                            } else if hoveredHistoryItemId == "__current__" {
                                hoveredHistoryItemId = nil
                                hoveredHistoryPreviewImage = nil
                            }
                        }

                        ForEach(screenshotHistory) { item in
                            let isLoaded = (loadedBaseName == item.baseName)
                            Button(action: {
                                loadScreenshot(item)
                            }) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.baseName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(Self.historyDateFormatter.string(from: item.modifiedAt))
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.55))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(hoveredHistoryItemId == item.id ? 0.16 : 0.08))
                                .cornerRadius(6)
                                .overlay(
                                    isLoaded
                                        ? RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                                        : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering {
                                    hoveredHistoryItemId = item.id
                                    hoveredHistoryPreviewImage = previewImage(for: item)
                                } else if hoveredHistoryItemId == item.id {
                                    hoveredHistoryItemId = nil
                                    hoveredHistoryPreviewImage = nil
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .frame(width: 240)

            ZStack {
                Color.clear
                    .frame(width: 520, height: 340)

                if let preview = hoveredHistoryPreviewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 520, height: 340)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                }
            }
        }
        .padding(10)
        .frame(width: 810, alignment: .leading)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }

    private func loadScreenshotHistory() {
        do {
            let screenCaptureURL = try screenCaptureDirectoryURL()
            let dataDirectory = try screenCaptureDataDirectoryURL()
            let files = try FileManager.default.contentsOfDirectory(
                at: dataDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            let items: [ScreenshotHistoryItem] = files.compactMap { url in
                guard url.pathExtension.lowercased() == "json",
                      url.lastPathComponent.hasSuffix("_cap.json") else {
                    return nil
                }

                let baseName = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_cap", with: "")
                let originalURL = dataDirectory.appendingPathComponent("\(baseName)_orig.png")
                let editedURL = screenCaptureURL.appendingPathComponent("\(baseName).png")

                guard FileManager.default.fileExists(atPath: editedURL.path) else {
                    try? FileManager.default.removeItem(at: url)
                    if FileManager.default.fileExists(atPath: originalURL.path) {
                        try? FileManager.default.removeItem(at: originalURL)
                    }
                    return nil
                }
                guard FileManager.default.fileExists(atPath: originalURL.path) else {
                    return nil
                }

                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return ScreenshotHistoryItem(
                    baseName: baseName,
                    editedURL: editedURL,
                    originalURL: originalURL,
                    capURL: url,
                    modifiedAt: modified
                )
            }

            // Remove orphaned _orig.png files that no longer have a matching screenshot or metadata.
            for originalURL in files where originalURL.lastPathComponent.hasSuffix("_orig.png") {
                let baseName = originalURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_orig", with: "")
                let editedURL = screenCaptureURL.appendingPathComponent("\(baseName).png")
                let capURL = dataDirectory.appendingPathComponent("\(baseName)_cap.json")
                if !FileManager.default.fileExists(atPath: editedURL.path) || !FileManager.default.fileExists(atPath: capURL.path) {
                    try? FileManager.default.removeItem(at: originalURL)
                    if FileManager.default.fileExists(atPath: capURL.path) {
                        try? FileManager.default.removeItem(at: capURL)
                    }
                }
            }

            screenshotHistory = items.sorted { $0.modifiedAt > $1.modifiedAt }
        } catch {
            print("Failed to load screenshot history: \(error)")
            screenshotHistory = []
        }
    }

    private func migrateLegacyCaptureColorDataIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.legacyColorMigrationKey) {
            return
        }

        do {
            let dataDirectory = try screenCaptureDataDirectoryURL()
            let files = try FileManager.default.contentsOfDirectory(
                at: dataDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let capFiles = files.filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasSuffix("_cap.json") }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            for capURL in capFiles {
                guard let data = try? Data(contentsOf: capURL),
                      var document = try? decoder.decode(CaptureDocument.self, from: data) else {
                    continue
                }

                if normalizeLegacyColors(in: &document),
                   let migratedData = try? encoder.encode(document) {
                    try? migratedData.write(to: capURL, options: .atomic)
                }
            }

            UserDefaults.standard.set(true, forKey: Self.legacyColorMigrationKey)
        } catch {
            print("Legacy color migration failed: \(error)")
        }
    }

    private func normalizeLegacyColors(in document: inout CaptureDocument) -> Bool {
        var changed = false

        for idx in document.texts.indices {
            changed = document.texts[idx].color.normalizeLegacy255IfNeeded() || changed
        }
        for idx in document.arrows.indices {
            changed = document.arrows[idx].color.normalizeLegacy255IfNeeded() || changed
        }
        for idx in document.numberedArrows.indices {
            changed = document.numberedArrows[idx].color.normalizeLegacy255IfNeeded() || changed
        }
        for idx in document.rectangles.indices {
            changed = document.rectangles[idx].color.normalizeLegacy255IfNeeded() || changed
        }
        for idx in document.smileys.indices {
            changed = document.smileys[idx].color.normalizeLegacy255IfNeeded() || changed
        }

        return changed
    }

    private func restoreCurrentCapture() {
        guard loadedBaseName != nil else { return }
        autoSaveCurrentCaptureIfNeeded()

        centerCaptureWindow(for: capturedImage.size)
        workingImage = capturedImage
        selectionRect = initialSelectionRect
        firstPoint = nil
        currentPoint = nil
        isSelecting = false
        isDrawing = false
        isEditingText = false
        selectedElementId = nil
        texts = []
        textFontSizes = [:]
        arrows = []
        numberedArrows = []
        rectangles = []
        pixelatedRects = []
        smileys = []
        elementColors = [:]
        arrowLineWidths = [:]
        numCount = 1
        loadedBaseName = nil
        suppressNextToolHelpUpdate = true
        currentTool = selectionRect != nil ? .elementSelect : .select
        helpText = selectionRect != nil
            ? "Screenshot-Editor bereit. Waehle ein Tool oder klicke Done."
            : "Select an area to capture"
        showHistoryPanel = false
    }

    private func loadScreenshot(_ item: ScreenshotHistoryItem) {
        autoSaveCurrentCaptureIfNeeded()

        guard let loadedImage = NSImage(contentsOf: item.originalURL) else {
            print("Failed to load original screenshot at: \(item.originalURL.path)")
            return
        }

        do {
            let data = try Data(contentsOf: item.capURL)
            let document = try JSONDecoder().decode(CaptureDocument.self, from: data)
            centerCaptureWindow(for: loadedImage.size)
            applyCaptureDocument(document, image: loadedImage)
            loadedBaseName = item.baseName
            showHistoryPanel = false
        } catch {
            print("Failed to load capture document: \(error)")
        }
    }

    private func previewImage(for item: ScreenshotHistoryItem) -> NSImage? {
        if let edited = NSImage(contentsOf: item.editedURL) {
            return edited
        }
        return NSImage(contentsOf: item.originalURL)
    }

    private func renderEditedImage(baseImage: NSImage, selectedArea: CGRect, drawings: [Drawing]) -> NSImage? {
        guard let cropped = baseImage.crop(to: selectedArea) else { return nil }
        let finalImage = NSImage(size: selectedArea.size)
        finalImage.lockFocus()
        cropped.draw(in: NSRect(origin: .zero, size: selectedArea.size))

        guard let context = NSGraphicsContext.current?.cgContext else {
            finalImage.unlockFocus()
            return nil
        }

        let offsetX = selectedArea.origin.x
        let offsetY = selectedArea.origin.y
        let height = selectedArea.height

        for drawing in drawings {
            context.saveGState()
            switch drawing {
            case .text(let text, let position, let color, let fontSize):
                let adjustedPosition = CGPoint(x: position.x - offsetX, y: height - (position.y - offsetY))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: color
                ]
                text.draw(at: adjustedPosition, withAttributes: attributes)
            case .arrow(let start, let end, let color, let lineWidth):
                let adjustedStart = CGPoint(x: start.x - offsetX, y: height - (start.y - offsetY))
                let adjustedEnd = CGPoint(x: end.x - offsetX, y: height - (end.y - offsetY))
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(lineWidth)
                context.move(to: adjustedStart)
                context.addLine(to: adjustedEnd)
                let angle = atan2(adjustedEnd.y - adjustedStart.y, adjustedEnd.x - adjustedStart.x)
                let arrowLength: CGFloat = 20
                let arrowAngle: CGFloat = .pi / 6
                let arrowPoint1 = CGPoint(
                    x: adjustedEnd.x - arrowLength * cos(angle - arrowAngle),
                    y: adjustedEnd.y - arrowLength * sin(angle - arrowAngle)
                )
                let arrowPoint2 = CGPoint(
                    x: adjustedEnd.x - arrowLength * cos(angle + arrowAngle),
                    y: adjustedEnd.y - arrowLength * sin(angle + arrowAngle)
                )
                context.move(to: arrowPoint1)
                context.addLine(to: adjustedEnd)
                context.addLine(to: arrowPoint2)
                context.strokePath()
            case .numberedArrow(let start, let end, let number, let color, let lineWidth):
                let adjustedStart = CGPoint(x: start.x - offsetX, y: height - (start.y - offsetY))
                let adjustedEnd = CGPoint(x: end.x - offsetX, y: height - (end.y - offsetY))
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(lineWidth)
                context.move(to: adjustedStart)
                context.addLine(to: adjustedEnd)
                let angle = atan2(adjustedEnd.y - adjustedStart.y, adjustedEnd.x - adjustedStart.x)
                let arrowLength: CGFloat = 20
                let arrowAngle: CGFloat = .pi / 6
                let arrowPoint1 = CGPoint(
                    x: adjustedEnd.x - arrowLength * cos(angle - arrowAngle),
                    y: adjustedEnd.y - arrowLength * sin(angle - arrowAngle)
                )
                let arrowPoint2 = CGPoint(
                    x: adjustedEnd.x - arrowLength * cos(angle + arrowAngle),
                    y: adjustedEnd.y - arrowLength * sin(angle + arrowAngle)
                )
                context.move(to: arrowPoint1)
                context.addLine(to: adjustedEnd)
                context.addLine(to: arrowPoint2)
                context.strokePath()
                let numberText = "\(number)"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: color
                ]
                let numberPoint = CGPoint(
                    x: adjustedStart.x - 30 * cos(angle),
                    y: adjustedStart.y - 30 * sin(angle)
                )
                numberText.draw(at: numberPoint, withAttributes: attributes)
            case .rectangle(let rect, let color):
                let adjustedRect = CGRect(
                    x: rect.origin.x - offsetX,
                    y: height - (rect.origin.y - offsetY) - rect.height,
                    width: rect.width,
                    height: rect.height
                )
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(2)
                context.stroke(adjustedRect)
            case .pixelatedRect(let rect, let pixelatedImage):
                let adjustedRect = CGRect(
                    x: rect.origin.x - offsetX,
                    y: height - (rect.origin.y - offsetY) - rect.height,
                    width: rect.width,
                    height: rect.height
                )
                pixelatedImage.draw(in: adjustedRect)
            case .smiley(let emoji, let position, let size, let color):
                let adjustedPosition = CGPoint(x: position.x - offsetX, y: height - (position.y - offsetY))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: color
                ]
                emoji.draw(at: adjustedPosition, withAttributes: attributes)
            }
            context.restoreGState()
        }

        finalImage.unlockFocus()
        return finalImage
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func makeCaptureDocument(from drawings: [Drawing], selectedArea: CGRect) -> CaptureDocument {
        var texts: [CaptureText] = []
        var arrows: [CaptureArrow] = []
        var numberedArrows: [CaptureNumberedArrow] = []
        var rectangles: [CaptureRectangle] = []
        var pixelates: [CapturePixelate] = []
        var smileys: [CaptureSmiley] = []

        for drawing in drawings {
            switch drawing {
            case .text(let text, let position, let color, let fontSize):
                texts.append(
                    CaptureText(
                        text: text,
                        position: CodablePoint(x: position.x, y: position.y),
                        fontSize: fontSize,
                        color: CodableColor(color)
                    )
                )
            case .arrow(let start, let end, let color, let lineWidth):
                arrows.append(
                    CaptureArrow(
                        start: CodablePoint(x: start.x, y: start.y),
                        end: CodablePoint(x: end.x, y: end.y),
                        lineWidth: lineWidth,
                        color: CodableColor(color)
                    )
                )
            case .numberedArrow(let start, let end, let number, let color, let lineWidth):
                numberedArrows.append(
                    CaptureNumberedArrow(
                        start: CodablePoint(x: start.x, y: start.y),
                        end: CodablePoint(x: end.x, y: end.y),
                        number: number,
                        lineWidth: lineWidth,
                        color: CodableColor(color)
                    )
                )
            case .rectangle(let rect, let color):
                rectangles.append(
                    CaptureRectangle(
                        rect: CodableRect(
                            x: rect.origin.x,
                            y: rect.origin.y,
                            width: rect.width,
                            height: rect.height
                        ),
                        color: CodableColor(color)
                    )
                )
            case .pixelatedRect(let rect, _):
                pixelates.append(
                    CapturePixelate(
                        rect: CodableRect(
                            x: rect.origin.x,
                            y: rect.origin.y,
                            width: rect.width,
                            height: rect.height
                        )
                    )
                )
            case .smiley(let emoji, let position, let size, let color):
                smileys.append(
                    CaptureSmiley(
                        emoji: emoji,
                        position: CodablePoint(x: position.x, y: position.y),
                        size: size,
                        color: CodableColor(color)
                    )
                )
            }
        }

        return CaptureDocument(
            canvasSize: CodableSize(width: selectedArea.width, height: selectedArea.height),
            selectedRect: CodableRect(
                x: selectedArea.origin.x,
                y: selectedArea.origin.y,
                width: selectedArea.width,
                height: selectedArea.height
            ),
            texts: texts,
            arrows: arrows,
            numberedArrows: numberedArrows,
            rectangles: rectangles,
            pixelates: pixelates,
            smileys: smileys
        )
    }

    private func applyCaptureDocument(_ document: CaptureDocument, image loadedImage: NSImage) {
        workingImage = loadedImage

        if let selectedRect = document.selectedRect {
            selectionRect = CGRect(
                x: selectedRect.x,
                y: selectedRect.y,
                width: selectedRect.width,
                height: selectedRect.height
            )
        } else {
            selectionRect = CGRect(origin: .zero, size: loadedImage.size)
        }
        firstPoint = nil
        currentPoint = nil
        isSelecting = false
        isDrawing = false
        isEditingText = false
        selectedElementId = nil

        texts = []
        textFontSizes = [:]
        arrows = []
        numberedArrows = []
        rectangles = []
        pixelatedRects = []
        smileys = []
        elementColors = [:]
        arrowLineWidths = [:]

        var maxNumberedArrow = 0
        var maxNumberedText = 0

        for text in document.texts {
            let id = UUID()
            let position = CGPoint(x: text.position.x, y: text.position.y)
            let isNumberedText = text.text.range(of: #"^\d+\."#, options: .regularExpression) != nil
            texts.append((text: text.text, position: position, id: id, isNumberedText: isNumberedText))
            textFontSizes[id] = text.fontSize
            elementColors[id] = Color(nsColor: text.color.nsColor)

            if isNumberedText,
               let match = text.text.range(of: #"^\d+"#, options: .regularExpression),
               let number = Int(text.text[match]) {
                maxNumberedText = max(maxNumberedText, number)
            }
        }

        for arrow in document.arrows {
            let id = UUID()
            arrows.append((
                start: CGPoint(x: arrow.start.x, y: arrow.start.y),
                end: CGPoint(x: arrow.end.x, y: arrow.end.y),
                id: id
            ))
            arrowLineWidths[id] = arrow.lineWidth
            elementColors[id] = Color(nsColor: arrow.color.nsColor)
        }

        for arrow in document.numberedArrows {
            let id = UUID()
            numberedArrows.append((
                start: CGPoint(x: arrow.start.x, y: arrow.start.y),
                end: CGPoint(x: arrow.end.x, y: arrow.end.y),
                number: arrow.number,
                id: id
            ))
            maxNumberedArrow = max(maxNumberedArrow, arrow.number)
            arrowLineWidths[id] = arrow.lineWidth
            elementColors[id] = Color(nsColor: arrow.color.nsColor)
        }

        for rect in document.rectangles {
            let id = UUID()
            rectangles.append((
                rect: CGRect(x: rect.rect.x, y: rect.rect.y, width: rect.rect.width, height: rect.rect.height),
                id: id
            ))
            elementColors[id] = Color(nsColor: rect.color.nsColor)
        }

        for pixelate in document.pixelates {
            let id = UUID()
            let rect = CGRect(
                x: pixelate.rect.x,
                y: pixelate.rect.y,
                width: pixelate.rect.width,
                height: pixelate.rect.height
            )
            if let pixelated = createPixelatedImage(in: rect) {
                pixelatedRects.append((rect: rect, image: pixelated, id: id))
            }
        }

        for smiley in document.smileys {
            let id = UUID()
            smileys.append((
                emoji: smiley.emoji,
                position: CGPoint(x: smiley.position.x, y: smiley.position.y),
                size: smiley.size,
                id: id
            ))
            elementColors[id] = Color(nsColor: smiley.color.nsColor)
        }

        numCount = max(maxNumberedArrow, maxNumberedText) + 1
        suppressNextToolHelpUpdate = true
        currentTool = .elementSelect
        helpText = "Screenshot geladen. Elemente koennen weiter bearbeitet werden."
    }

    private func autoSaveCurrentCaptureIfNeeded() {
        let selectedArea = selectionRect ?? CGRect(origin: .zero, size: workingImage.size)
        let drawings = collectDrawings()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yy_MM_dd_HH_mm_ss"
        let timestamp = dateFormatter.string(from: Date())
        let baseName = loadedBaseName ?? "screenshot_\(timestamp)"
        persistCurrentCapture(baseName: baseName, selectedArea: selectedArea, drawings: drawings)
        loadedBaseName = baseName
    }

    private func navigateScreenshotHistory(step: Int) {
        if screenshotHistory.isEmpty {
            loadScreenshotHistory()
        }
        guard !screenshotHistory.isEmpty else { return }

        let currentIndex: Int
        if let loadedBaseName,
           let index = screenshotHistory.firstIndex(where: { $0.baseName == loadedBaseName }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }

        let targetIndex = max(0, min(screenshotHistory.count - 1, currentIndex + step))
        guard targetIndex != currentIndex || loadedBaseName == nil else { return }

        loadScreenshot(screenshotHistory[targetIndex])
    }

    private func persistCurrentCapture(baseName: String, selectedArea: CGRect, drawings: [Drawing]) {
        do {
            let screenCaptureURL = try screenCaptureDirectoryURL()
            let dataDirectory = try screenCaptureDataDirectoryURL()
            let editedURL = screenCaptureURL.appendingPathComponent("\(baseName).png")
            let originalURL = dataDirectory.appendingPathComponent("\(baseName)_orig.png")
            let capURL = dataDirectory.appendingPathComponent("\(baseName)_cap.json")

            if let edited = renderEditedImage(baseImage: workingImage, selectedArea: selectedArea, drawings: drawings),
               let editedData = pngData(from: edited) {
                try editedData.write(to: editedURL, options: .atomic)
            }

            if let originalData = pngData(from: workingImage) {
                try originalData.write(to: originalURL, options: .atomic)
            }

            let document = makeCaptureDocument(from: drawings, selectedArea: selectedArea)
            let capData = try JSONEncoder().encode(document)
            try capData.write(to: capURL, options: .atomic)
        } catch {
            print("Auto-save failed: \(error)")
        }
    }

    private func screenCaptureDirectoryURL() throws -> URL {
        guard let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pictures directory not found"])
        }
        let screenCaptureURL = picturesURL.appendingPathComponent("ScreenCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: screenCaptureURL, withIntermediateDirectories: true)
        return screenCaptureURL
    }

    private func screenCaptureDataDirectoryURL() throws -> URL {
        let screenCaptureURL = try screenCaptureDirectoryURL()
        let dataURL = screenCaptureURL.appendingPathComponent("_data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        return dataURL
    }

    private func centerCaptureWindow(for imageSize: CGSize) {
        guard let window = NSApp.windows.first(where: { $0.contentView is NSHostingView<CaptureView> }) else {
            return
        }

        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = imageSize.width
        let height = imageSize.height
        let origin = CGPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )
        let targetFrame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        window.setFrame(targetFrame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
    }
    
    // Smiley picker view
    @ViewBuilder
    private func smileyPickerView() -> some View {
        VStack(spacing: 10) {
            Text("Select a Smiley")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 8)
            
            // Grid of common emojis
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(["😀", "😂", "😍", "😎", "🤔", "😊", "👍", "👎", "❤️", "🔥", 
                         "⭐", "🚀", "🎉", "🎯", "💯", "🤦‍♂️", "🤷‍♀️", "👏", "🙏", "💪"], id: \.self) { emoji in
                    Button(action: {
                        print("Adding emoji: \(emoji) at position: \(smileyPickerPosition)")
                        let newSmileyId = UUID()
                        // Add the selected emoji at the position
                        smileys.append((
                            emoji: emoji,
                            position: smileyPickerPosition,
                            size: selectedSmileySize,
                            id: newSmileyId
                        ))
                        elementColors[newSmileyId] = selectedDrawingColor
                        currentTool = .elementSelect
                        selectedElementId = newSmileyId
                        updateHelpText(for: .elementSelect)
                        // Explicitly set to false and print for debugging
                        showSmileyPicker = false
                        print("Set showSmileyPicker to false")
                        
                        // Force UI update
                        DispatchQueue.main.async {
                            showSmileyPicker = false
                        }
                    }) {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 40, height: 40)
                            .background(Color(.windowBackgroundColor))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            
            Text("Groesse mit +/- am ausgewaehlten Smiley anpassen")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            
            // Close button
            Button("Cancel") {
                showSmileyPicker = false
                print("Cancel button pressed, set showSmileyPicker to false")
            }
            .font(.system(size: 12))
            .padding(.bottom, 8)
        }
        .background(Color(.windowBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 5)
        .padding(10)
        .frame(width: 240)
        .offset(y: 20) // Add a small offset to ensure it appears below the click point
        .alignmentGuide(.top) { _ in 0 }
    }
    
    // Helper function to ensure smiley picker stays within screen boundaries
    private func adjustSmileyPickerPosition(_ position: CGPoint) -> CGPoint {
        // Get the current screen where the position is
        let currentScreen = NSScreen.screens.first { screen in
            NSPointInRect(NSPoint(x: position.x, y: position.y), screen.frame)
        } ?? NSScreen.main
        
        guard let screen = currentScreen else { return position }
        
        // Smiley picker dimensions
        let pickerWidth: CGFloat = 240
        let pickerHeight: CGFloat = 300 // Approximate height of the picker
        
        // Calculate boundaries
        let minX = screen.frame.origin.x + pickerWidth/2
        let maxX = screen.frame.origin.x + screen.frame.width - pickerWidth/2
        let minY = screen.frame.origin.y + pickerHeight/2
        let maxY = screen.frame.origin.y + screen.frame.height - pickerHeight/2
        
        // Adjust position to stay within boundaries
        let adjustedX = max(minX, min(maxX, position.x))
        let adjustedY = max(minY, min(maxY, position.y))
        
        return CGPoint(x: adjustedX, y: adjustedY)
    }

    // Helper function to ensure text editor stays within screen boundaries
    private func textEditorSize() -> CGSize {
        let displayText = textPrefix + editingText + (showCursor ? "|" : "")
        let font = NSFont.systemFont(ofSize: currentEditingFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let bounds = (displayText as NSString).boundingRect(
            with: NSSize(width: maxTextEditorWidth - textEditorPadding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let textWidth = ceil(bounds.width) + textEditorPadding
        let textHeight = ceil(bounds.height) + 12
        let finalWidth = min(max(textWidth, minTextEditorWidth), maxTextEditorWidth)
        let finalHeight = max(textHeight, 50)
        return CGSize(width: finalWidth, height: finalHeight)
    }

    private func textBlockSize(for text: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxTextEditorWidth - textEditorPadding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let width = min(max(ceil(bounds.width) + textEditorPadding, minTextEditorWidth), maxTextEditorWidth)
        let height = max(ceil(bounds.height) + 12, 50)
        return CGSize(width: width, height: height)
    }

    private func updateTextFontSize(for textId: UUID, delta: CGFloat) {
        let current = textFontSizes[textId] ?? 20
        textFontSizes[textId] = min(max(current + delta, minTextFontSize), maxTextFontSize)
    }

    private func boundingRectForLine(start: CGPoint, end: CGPoint, padding: CGFloat = 0) -> CGRect {
        let minX = min(start.x, end.x) - padding
        let minY = min(start.y, end.y) - padding
        let width = abs(end.x - start.x) + padding * 2
        let height = abs(end.y - start.y) + padding * 2
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func adjustmentControlPositionForArrow(start: CGPoint, end: CGPoint) -> CGPoint {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        return CGPoint(x: minX + 22, y: minY - 18)
    }

    private func isPointInTextFontControl(point: CGPoint) -> Bool {
        let controlSize = CGSize(width: 56, height: 24)
        let halfWidth = controlSize.width / 2
        let halfHeight = controlSize.height / 2

        if let selectedId = selectedElementId,
           let text = texts.first(where: { $0.id == selectedId }) {
            let fontSize = textFontSizes[text.id] ?? 20
            let textSize = textBlockSize(for: text.text, fontSize: fontSize)
            let center = CGPoint(
                x: text.position.x + 22,
                y: text.position.y - textSize.height / 2 - 18
            )
            let frame = CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: controlSize.width,
                height: controlSize.height
            )
            if frame.contains(point) {
                return true
            }
        }

        if let selectedId = selectedElementId,
           let smiley = smileys.first(where: { $0.id == selectedId }) {
            let center = CGPoint(
                x: smiley.position.x - smiley.size / 2 + 22,
                y: smiley.position.y - smiley.size / 2 - 18
            )
            let frame = CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: controlSize.width,
                height: controlSize.height
            )
            if frame.contains(point) {
                return true
            }
        }

        if let selectedId = selectedElementId,
           let arrow = arrows.first(where: { $0.id == selectedId }) {
            let center = adjustmentControlPositionForArrow(start: arrow.start, end: arrow.end)
            let frame = CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: controlSize.width,
                height: controlSize.height
            )
            if frame.contains(point) {
                return true
            }
        }

        if let selectedId = selectedElementId,
           let numberedArrow = numberedArrows.first(where: { $0.id == selectedId }) {
            let center = adjustmentControlPositionForArrow(start: numberedArrow.start, end: numberedArrow.end)
            let frame = CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: controlSize.width,
                height: controlSize.height
            )
            if frame.contains(point) {
                return true
            }
        }

        if isEditingText, let position = textPosition {
            let editorSize = textEditorSize()
            let adjustedEditorPosition = adjustTextEditorPosition(
                position: position,
                width: editorSize.width,
                height: editorSize.height
            )
            let center = CGPoint(
                x: adjustedEditorPosition.x - editorSize.width / 2 + 22,
                y: adjustedEditorPosition.y - editorSize.height / 2 - 18
            )
            let frame = CGRect(
                x: center.x - halfWidth,
                y: center.y - halfHeight,
                width: controlSize.width,
                height: controlSize.height
            )
            if frame.contains(point) {
                return true
            }
        }

        return false
    }

    private func fittedImageRect(in _: CGSize) -> CGRect {
        guard workingImage.size.width > 0, workingImage.size.height > 0 else {
            return CGRect(origin: .zero, size: workingImage.size)
        }
        return CGRect(origin: .zero, size: workingImage.size)
    }

    private func adjustTextEditorPosition(position: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        // Get the current screen where the position is
        let currentScreen = NSScreen.screens.first { screen in
            NSPointInRect(NSPoint(x: position.x, y: position.y), screen.frame)
        } ?? NSScreen.main
        
        guard let screen = currentScreen else { return CGPoint(x: position.x + width/2, y: position.y) }
        
        // Text editor dimensions
        let editorWidth: CGFloat = width
        let editorHeight: CGFloat = height
        // Calculate boundaries
        let minX = screen.frame.origin.x + editorWidth/2
        let maxX = screen.frame.origin.x + screen.frame.width - editorWidth/2
        let minY = screen.frame.origin.y + editorHeight/2
        let maxY = screen.frame.origin.y + screen.frame.height - editorHeight/2
        
        // Calculate ideal position (centered at the text position)
        let idealX = position.x + editorWidth/2
        let idealY = position.y
        
        // Adjust X position to stay within boundaries
        let adjustedX = max(minX, min(maxX, idealX))
        let adjustedY = max(minY, min(maxY, idealY))
        
        return CGPoint(x: adjustedX, y: adjustedY)
    }

    // Function to perform OCR on the selected area and copy text to clipboard
    private func performOCRAndCopyText() {
        helpText = "OCR is currently unavailable in DockAppToggler build"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.updateHelpText(for: self.currentTool)
        }
    }
}

struct ToolButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var isPrimary: Bool = false
    let buttonWidth: CGFloat = 80  // Reduced width
    let buttonHeight: CGFloat = 24  // Reduced height
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isPrimary ? .white : (isSelected ? .white : .primary))
            .frame(width: buttonWidth, height: buttonHeight)  // Fixed frame
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isPrimary ? Color.accentColor :
                            (isSelected ? Color.accentColor : Color(.windowBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// Custom button style for the Adjust button
struct AdjustButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    let buttonWidth: CGFloat = 80  // Reduced width
    let buttonHeight: CGFloat = 24  // Reduced height
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? .white : .white)  // Always white text for better contrast on red
            .frame(width: buttonWidth, height: buttonHeight)  // Fixed frame
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.red.opacity(0.8) : Color.red)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.clear : Color.red.opacity(0.2), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // Draw the main line
        path.move(to: start)
        path.addLine(to: end)
        
        // Calculate arrow head
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 20
        let arrowAngle: CGFloat = .pi / 6
        
        let arrowPoint1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let arrowPoint2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )
        
        // Draw arrow head
        path.move(to: arrowPoint1)
        path.addLine(to: end)
        path.addLine(to: arrowPoint2)
        
        return path
    }
}

struct SelectionOverlay: View {
    let firstPoint: CGPoint?
    let currentPoint: CGPoint?
    
    var body: some View {
        if let start = firstPoint, let current = currentPoint {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            
            Path { path in
                path.addRect(rect)
            }
            .stroke(Color.blue, lineWidth: 2)
        }
    }
}

extension NSImage {
    func crop(to rect: NSRect) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let scale = CGFloat(cgImage.width) / self.size.width
        let scaledRect = NSRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        
        guard let croppedCGImage = cgImage.cropping(to: scaledRect) else { return nil }
        return NSImage(cgImage: croppedCGImage, size: rect.size)
    }
}

extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}
