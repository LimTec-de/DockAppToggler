import SwiftUI
import AppKit

struct MagnifyingGlassView: View {
    let cursorPosition: CGPoint
    let magnification: CGFloat = 4.0
    let size: CGFloat = 200.0

    var body: some View {
        GeometryReader { geometry in
            // Find which screen contains the cursor
            let mouseLocation = NSEvent.mouseLocation
            let screenWithMouse = NSScreen.screens.first { screen in
                NSPointInRect(mouseLocation, screen.frame)
            } ?? NSScreen.main
            
            if let screen = screenWithMouse {
                // Use the backing scale factor for high-resolution displays
                let captureSize = size / magnification
                let captureRect = CGRect(
                    x: cursorPosition.x - captureSize / 2,
                    y: cursorPosition.y - captureSize / 2,
                    width: captureSize,
                    height: captureSize
                )

                // Get the display ID for the screen containing the mouse
                let displayID = getDisplayIDForPoint(mouseLocation)

                if let cgImage = CGDisplayCreateImage(displayID, rect: captureRect) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: captureSize, height: captureSize))
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(radius: 4)
                        .position(x: cursorPosition.x - screen.frame.width / 2 + 200, y: cursorPosition.y - screen.frame.height / 2 + 200)
                        .overlay(
                            CrosshairView()
                                .frame(width: size, height: size)
                                .position(x: cursorPosition.x - screen.frame.width / 2 + 200, y: cursorPosition.y - screen.frame.height / 2 + 200)
                        )
                }
            }
        }
        .frame(width: size, height: size)
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
}

struct CrosshairView: View {
    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let centerY = geometry.size.height / 2
            let lineLength: CGFloat = 30.0

            Path { path in
                // Horizontal line
                path.move(to: CGPoint(x: centerX - lineLength, y: centerY))
                path.addLine(to: CGPoint(x: centerX + lineLength, y: centerY))
                
                // Vertical line
                path.move(to: CGPoint(x: centerX, y: centerY - lineLength))
                path.addLine(to: CGPoint(x: centerX, y: centerY + lineLength))
            }
            .stroke(Color.white, lineWidth: 2)
        }
    }
} 