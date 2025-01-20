import Foundation
import ApplicationServices

/// Information about a window, including its accessibility element and metadata
struct WindowInfo {
    let window: AXUIElement
    let name: String
    let isAppElement: Bool
    var cgWindowID: CGWindowID?
    var position: CGPoint?
    var size: CGSize?
    var bounds: CGRect?
    
    init(window: AXUIElement, 
         name: String, 
         isAppElement: Bool = false, 
         cgWindowID: CGWindowID? = nil,
         position: CGPoint? = nil,
         size: CGSize? = nil,
         bounds: CGRect? = nil) {
        self.window = window
        self.name = name
        self.isAppElement = isAppElement
        self.cgWindowID = cgWindowID
        self.position = position
        self.size = size
        self.bounds = bounds
    }
} 