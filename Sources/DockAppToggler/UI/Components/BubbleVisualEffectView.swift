import AppKit
import Cocoa

class BubbleVisualEffectView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        
        // Create bubble shape with arrow
        let path = NSBezierPath()
        let bounds = self.bounds
        let radius: CGFloat = 6
        
        // Start from bottom center (arrow tip)
        let arrowTipX = bounds.midX
        let arrowTipY = Constants.UI.arrowOffset
        
        // Create the main rounded rectangle first, but exclude the bottom edge
        let rect = NSRect(x: bounds.minX,
                         y: bounds.minY + Constants.UI.arrowHeight,
                         width: bounds.width,
                         height: bounds.height - Constants.UI.arrowHeight)
        
        // Create custom path for rounded rectangle with partial bottom edge
        let roundedRect = NSBezierPath()
        
        // Start from the arrow connection point on the left
        roundedRect.move(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Draw left bottom corner and left side
        roundedRect.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 270,
                            endAngle: 180,
                            clockwise: true)
        
        // Left side and top-left corner
        roundedRect.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        roundedRect.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 180,
                            endAngle: 90,
                            clockwise: true)
        
        // Top edge
        roundedRect.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        
        // Top-right corner and right side
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                            radius: radius,
                            startAngle: 90,
                            endAngle: 0,
                            clockwise: true)
        roundedRect.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
        
        // Right bottom corner
        roundedRect.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                            radius: radius,
                            startAngle: 0,
                            endAngle: 270,
                            clockwise: true)
        
        // Bottom edge to arrow
        roundedRect.line(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Create arrow path
        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: arrowTipX + Constants.UI.arrowWidth/2, y: rect.minY))
        arrowPath.line(to: NSPoint(x: arrowTipX, y: arrowTipY))
        arrowPath.line(to: NSPoint(x: arrowTipX - Constants.UI.arrowWidth/2, y: rect.minY))
        
        // Combine paths
        path.append(roundedRect)
        path.append(arrowPath)
        
        // Create mask layer for the entire shape
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        self.layer?.mask = maskLayer
        
        // Add border layer only for the custom rounded rectangle path
        let borderLayer = CAShapeLayer()
        borderLayer.path = roundedRect.cgPath
        borderLayer.lineWidth = 0.5
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        
        // Remove any existing border layers
        self.layer?.sublayers?.removeAll(where: { $0.name == "borderLayer" })
        
        // Add new border layer
        borderLayer.name = "borderLayer"
        self.layer?.addSublayer(borderLayer)
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        
        // Update border color when appearance changes
        if let borderLayer = self.layer?.sublayers?.first(where: { $0.name == "borderLayer" }) as? CAShapeLayer {
            borderLayer.strokeColor = NSColor(white: 1.0, alpha: 0.3).cgColor
        }
    }
} 