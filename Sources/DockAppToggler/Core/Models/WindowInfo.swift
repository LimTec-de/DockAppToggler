import Foundation
import ApplicationServices

/// Information about a window, including its accessibility element and metadata
struct WindowInfo: @unchecked Sendable {
    let window: AXUIElement
    let name: String
    let cgWindowID: CGWindowID?
    let isAppElement: Bool
    let bundleIdentifier: String?
    var position: CGPoint?
    var size: CGSize?
    var bounds: CGRect?
    
    init(window: AXUIElement, 
         name: String, 
         cgWindowID: CGWindowID? = nil,
         isAppElement: Bool = false,
         bundleIdentifier: String? = nil,
         position: CGPoint? = nil,
         size: CGSize? = nil,
         bounds: CGRect? = nil) {
        self.window = window
        self.name = name
        self.cgWindowID = cgWindowID
        self.isAppElement = isAppElement
        self.bundleIdentifier = bundleIdentifier
        self.position = position
        self.size = size
        self.bounds = bounds
    }
} 