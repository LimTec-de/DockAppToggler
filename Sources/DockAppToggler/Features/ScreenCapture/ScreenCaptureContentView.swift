import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

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
        showCaptureWindow(with: image, on: screen)
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
    
    private func showCaptureWindow(with image: NSImage, on screen: NSScreen) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure window to appear above everything
        window.level = .statusBar + 1
        window.backgroundColor = .clear
        window.isOpaque = true
        window.hasShadow = false
        
        // Make window cover the entire screen including dock and menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let captureView = CaptureView(image: image) { selectedArea, drawings in
            if let cropped = image.crop(to: selectedArea) {
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
                        
                    case .arrow(let start, let end, let color):
                        let adjustedStart = CGPoint(
                            x: start.x - offsetX,
                            y: height - (start.y - offsetY) // Flip Y coordinate
                        )
                        let adjustedEnd = CGPoint(
                            x: end.x - offsetX,
                            y: height - (end.y - offsetY) // Flip Y coordinate
                        )
                        
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(2)
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
                        
                    case .numberedArrow(let start, let end, let number, let color):
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
                        context.setLineWidth(2)
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
                
                // Create ScreenCapture directory if it doesn't exist
                if let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
                    let screenCaptureURL = picturesURL.appendingPathComponent("ScreenCapture", isDirectory: true)
                    
                    do {
                        // Create directory if it doesn't exist
                        try FileManager.default.createDirectory(at: screenCaptureURL, withIntermediateDirectories: true)
                        
                        // Create filename with timestamp
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yy_MM_dd_H_m_s"
                        let timestamp = dateFormatter.string(from: Date())
                        let filename = "screenshot_\(timestamp).png"
                        
                        // Save to ScreenCapture folder
                        let fileURL = screenCaptureURL.appendingPathComponent(filename)
                        
                        if let bitmapRep = createHighResolutionBitmap(from: finalImage),
                           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                            try pngData.write(to: fileURL)
                            print("Image saved to: \(fileURL.path)")
                        }
                    } catch {
                        print("Error saving image: \(error)")
                    }
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
        NSApp.windows.forEach { window in
            if window.contentView is NSHostingView<CaptureView> {
                window.close()
            }
        }
    }
}

// Add Drawing enum to represent different types of drawings
enum Drawing {
    case text(String, CGPoint, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor)
    case numberedArrow(CGPoint, CGPoint, Int, NSColor)
    case rectangle(CGRect, NSColor)
    case pixelatedRect(CGRect, NSImage)  // New case for pixelated rectangles
    case smiley(String, CGPoint, CGFloat, NSColor)  // New case for smileys with emoji, position, size, and color
}

struct CaptureView: View {
    let image: NSImage
    let onSelection: (NSRect, [Drawing]) -> Void
    @State private var firstPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var isSelecting = false
    @State private var selectionRect: CGRect?
    @State private var numCount: Int = 1
    @State private var deleteMonitor: Any?
    @State private var showMagnifyingGlass = false
    @State private var cursorPosition: CGPoint = .zero
    
    // Drawing states
    @State private var currentTool: DrawingTool = .select
    @State private var lastTool: DrawingTool = .select
    @State var texts: [(text: String, position: CGPoint, id: UUID, isNumberedText: Bool)] = []
    @State private var textFontSizes: [UUID: CGFloat] = [:]
    @State var arrows: [(start: CGPoint, end: CGPoint, id: UUID)] = []
    @State var rectangles: [(rect: CGRect, id: UUID)] = []
    @State var pixelatedRects: [(rect: CGRect, image: NSImage, id: UUID)] = []
    @State var numberedArrows: [(start: CGPoint, end: CGPoint, number: Int, id: UUID)] = []
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
    private let minTextEditorWidth: CGFloat = 220
    private let maxTextEditorWidth: CGFloat = 520
    private let textEditorPadding: CGFloat = 16
    private let minTextFontSize: CGFloat = 12
    private let maxTextFontSize: CGFloat = 56
    private let textFontStep: CGFloat = 2
    
    // Add a new state property for the help text
    @State private var helpText: String = "Select an area to capture"
    
    // Smiley related states
    @State var smileys: [(emoji: String, position: CGPoint, size: CGFloat, id: UUID)] = []
    @State private var showSmileyPicker: Bool = false
    @State private var smileyPickerPosition: CGPoint = .zero
    @State private var selectedSmileySize: CGFloat = 40
    
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    enum DrawingTool {
        case select, text, arrow, rectangle, numberedArrow, elementSelect, pixelate, numberedText, changeSelection, smiley
    }
    
    private func getDrawingColor(at point: CGPoint, isSelected: Bool = false) -> Color {
        if isSelected {
            return Color.green
        }
        
        // Convert point to image coordinates
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let imageSize = image.size
            let x = Int((point.x / imageSize.width) * CGFloat(cgImage.width))
            let y = Int(((imageSize.height - point.y) / imageSize.height) * CGFloat(cgImage.height))
            
            if let provider = cgImage.dataProvider,
               let data = provider.data,
               let ptr = CFDataGetBytePtr(data) {
                let bytesPerPixel = 4
                let index = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                
                if index >= 0 && index < CFDataGetLength(data) - 4 {
                    let brightness = (Int(ptr[index]) + Int(ptr[index + 1]) + Int(ptr[index + 2])) / 3
                    return brightness < 128 ? Color(red: 1.0, green: 0.3, blue: 0.3) : Color.red
                }
            }
        }
        return Color.red
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
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
                    
                    // Drawing tools buttons
                    if !isSelecting, let rect = selectionRect {
                        VStack(spacing: 8) {
                            toolbarView(for: rect)
                            
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
                                .foregroundColor(getDrawingColor(at: texts[index].position, isSelected: isSelected))
                                .font(.system(size: fontSize))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: textSize.width, height: textSize.height, alignment: .leading)
                                .position(x: texts[index].position.x + textSize.width / 2, y: texts[index].position.y)

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
                                        .stroke(isSelected ? Color.green : Color.clear, 
                                               lineWidth: isSelected ? 2 : 0)
                                    
                                    // Show drag handle and delete button when selected
                                    if isSelected {
                                        VStack {
                                            HStack {
                                                Spacer()
                                                
                                                Button(action: {
                                                    // Delete this pixelated rectangle
                                                    pixelatedRects.remove(at: index)
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
                                    pixelatedRects.remove(at: index)
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
                        Text(smileys[index].emoji)
                            .font(.system(size: smileys[index].size))
                            .foregroundColor(getDrawingColor(at: smileys[index].position, isSelected: isSelected))
                            .background(
                                Circle()
                                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: isSelected ? 2 : 0)
                                    .background(isSelected ? Color.green.opacity(0.2) : Color.clear)
                                    .frame(width: smileys[index].size * 1.2, height: smileys[index].size * 1.2)
                            )
                            .position(smileys[index].position)
                            .contextMenu {
                                Button(action: {
                                    // Delete this smiley
                                    smileys.removeAll { $0.id == smileys[index].id }
                                    selectedElementId = nil
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .help("Click to select, drag to move, or right-click to delete this smiley. You can also press Delete key to remove it.")
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
                        ArrowShape(start: arrows[index].start, end: arrows[index].end)
                            .stroke(getDrawingColor(at: arrows[index].start, isSelected: isSelected), 
                                   lineWidth: isSelected ? 4 : 2)
                            .contextMenu {
                                Button(action: {
                                    // Delete this arrow
                                    arrows.removeAll { $0.id == arrows[index].id }
                                    selectedElementId = nil
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .help("Click to select, drag to move, or right-click to delete this arrow. You can also press Delete key to remove it.")
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
                        Group {
                            ArrowShape(start: numberedArrows[index].start, end: numberedArrows[index].end)
                                .stroke(getDrawingColor(at: numberedArrows[index].start, isSelected: isSelected), 
                                      lineWidth: isSelected ? 4 : 2)
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
                                        
                                        selectedElementId = nil
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .help("Click to select, drag to move, or right-click to delete this numbered arrow. You can also press Delete key to remove it.")
                            let angle = atan2(numberedArrows[index].end.y - numberedArrows[index].start.y,
                                           numberedArrows[index].end.x - numberedArrows[index].start.x)
                            Text("\(numberedArrows[index].number)")
                                .foregroundColor(getDrawingColor(at: numberedArrows[index].start, isSelected: isSelected))
                                .font(.system(size: 16, weight: .bold))
                                .background(isSelected ? Color.green.opacity(0.2) : Color.clear)
                                .padding(isSelected ? 4 : 0)
                                .position(x: numberedArrows[index].start.x - 30 * cos(angle),
                                        y: numberedArrows[index].start.y - 30 * sin(angle))
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
                        Rectangle()
                            .stroke(getDrawingColor(at: CGPoint(x: rectangles[index].rect.midX, y: rectangles[index].rect.midY), 
                                  isSelected: isSelected), 
                                   lineWidth: isSelected ? 4 : 2)
                            .frame(width: rectangles[index].rect.width, height: rectangles[index].rect.height)
                            .position(x: rectangles[index].rect.midX, y: rectangles[index].rect.midY)
                            .contextMenu {
                                Button(action: {
                                    // Delete this rectangle
                                    rectangles.removeAll { $0.id == rectangles[index].id }
                                    selectedElementId = nil
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .help("Click to select, drag to move, or right-click to delete this rectangle. You can also press Delete key to remove it.")
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
            )
            .gesture(
                DragGesture(minimumDistance: 0.1, coordinateSpace: .local)
                    .onChanged { value in
                            handleDragChange(value)
                    }
                    .onEnded { value in
                            handleDragEnd(value)
                    }
            )
            .onAppear {
                // Setup delete key monitor
                deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 { // ESC
                        closeCaptureWindows()
                        return nil
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
            
            // Add ESC key handling
            if event.keyCode == 53 { // ESC key
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
                arrows.append((start: start, end: value.location, id: UUID()))
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
                rectangles.append((rect, UUID()))
            }
            isDrawing = false
            firstPoint = nil
            currentPoint = nil
            
        case .numberedArrow:
            if let start = firstPoint {
                let arrowNumber = numberedArrows.count + 1
                let arrowEnd = value.location
                numberedArrows.append((
                    start: start,
                    end: arrowEnd,
                    number: arrowNumber,
                    id: UUID()
                ))
                
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
        if selectedElementId == nil || !isPointInsideSelectedElement(point, selectedElementId) {
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
        if let index = texts.firstIndex(where: { $0.id == selectedElement }) {
            let fontSize = textFontSizes[selectedElement] ?? 20
            let textSize = textBlockSize(for: texts[index].text, fontSize: fontSize)
            let textBox = CGRect(
                x: texts[index].position.x,
                y: texts[index].position.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            return textBox.contains(point)
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
        return elementId(at: point) == selectedElement
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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let scale = CGFloat(cgImage.width) / image.size.width
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
            let color = getDrawingColor(at: text.position).nsColor
            let fontSize = textFontSizes[text.id] ?? 20
            drawings.append(.text(text.text, text.position, color, fontSize))
        }
        
        // Add pixelated rectangles first (so they appear behind other elements)
        for pixelRect in pixelatedRects {
            drawings.append(.pixelatedRect(pixelRect.rect, pixelRect.image))
        }
        
        // Add arrows
        for arrow in arrows {
            let color = getDrawingColor(at: arrow.start).nsColor
            drawings.append(.arrow(arrow.start, arrow.end, color))
        }
        
        // Add numbered arrows
        for arrow in numberedArrows {
            let color = getDrawingColor(at: arrow.start).nsColor
            drawings.append(.numberedArrow(arrow.start, arrow.end, arrow.number, color))
        }
        
        // Add rectangles after pixelated areas so they appear on top
        for rect in rectangles {
            let color = getDrawingColor(at: CGPoint(x: rect.rect.midX, y: rect.rect.midY)).nsColor
            drawings.append(.rectangle(rect.rect, color))
        }
        
        // Add smileys
        for smiley in smileys {
            let color = getDrawingColor(at: smiley.position).nsColor
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
    @ViewBuilder
    private func toolbarView(for rect: CGRect) -> some View {
        // Get the current screen where the selection is
        let selectionCenter = NSPoint(
            x: rect.origin.x + rect.width / 2,
            y: rect.origin.y + rect.height / 2
        )
        let currentScreen = NSScreen.screens.first { screen in
            NSPointInRect(selectionCenter, screen.frame)
        } ?? NSScreen.main
        
        let screenHeight = currentScreen?.frame.height ?? 0
        let screenWidth = currentScreen?.frame.width ?? 0
        let screenOriginX = currentScreen?.frame.origin.x ?? 0
        let buttonsHeight: CGFloat = 36  // Height of buttons + padding
        let margin: CGFloat = 16  // Margin from selection rect
        
        // Calculate space below the selection
        let spaceBelow = screenHeight - rect.maxY
        
        // Calculate space above the selection
        let spaceAbove = rect.minY
        
        // Determine if we should show above based on available space
        // Only show above if there's not enough space below AND there's more space above than below
        let shouldShowAbove = spaceBelow < (buttonsHeight + margin) && spaceAbove > spaceBelow
        
        // Calculate toolbar width - ensure it's never wider than the screen
        let maxToolbarWidth: CGFloat = 700
        let minToolbarWidth: CGFloat = 400 // Minimum width to ensure buttons are visible
        let availableScreenWidth = screenWidth - 40 // Leave 20px margin on each side
        let toolbarWidth = min(maxToolbarWidth, max(minToolbarWidth, min(rect.width, availableScreenWidth)))
        
        // Calculate horizontal position
        // If selection is near screen edge or smaller than toolbar, position toolbar to stay fully on screen
        /*let idealX: CGFloat = {
            if rect.minX < (screenOriginX + toolbarWidth/2 + 20)  {
                return screenOriginX + (toolbarWidth/2 + 20)
            } else if rect.maxX > (screenOriginX + screenWidth - 20) {
                return screenOriginX + (screenWidth - (toolbarWidth/2 + 20))
            } else {
                // Otherwise center on selection
                return rect.midX
            }
        }()*/
        let adjustedX = screenOriginX + toolbarWidth > rect.midX ? screenOriginX + (toolbarWidth + 50) : (rect.midX + toolbarWidth > screenOriginX + screenWidth ? screenOriginX + (screenWidth - toolbarWidth - 50) : rect.midX)

        
        
        HStack(spacing: 4) {
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
                    Image(systemName: "1.circle")
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
                onSelection(NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height), drawings)
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
            y: shouldShowAbove ? rect.minY - (buttonsHeight/2 + margin) : rect.maxY + (buttonsHeight/2 + margin)
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
                        // Add the selected emoji at the position
                        smileys.append((
                            emoji: emoji,
                            position: smileyPickerPosition,
                            size: selectedSmileySize,
                            id: UUID()
                        ))
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
            
            // Size slider
            HStack {
                Text("Size:")
                    .font(.system(size: 12))
                Slider(value: $selectedSmileySize, in: 20...80, step: 5)
                    .frame(width: 120)
                Text("\(Int(selectedSmileySize))")
                    .font(.system(size: 12))
                    .frame(width: 30, alignment: .trailing)
            }
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
