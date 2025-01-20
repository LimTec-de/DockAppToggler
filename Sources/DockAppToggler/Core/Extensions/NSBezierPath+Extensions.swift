import AppKit

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                // Convert quadratic curve to cubic curve
                let startPoint = path.currentPoint
                let controlPoint = points[0]
                let endPoint = points[1]
                
                // Calculate cubic control points from quadratic control point
                let cp1 = CGPoint(
                    x: startPoint.x + ((controlPoint.x - startPoint.x) * 2/3),
                    y: startPoint.y + ((controlPoint.y - startPoint.y) * 2/3)
                )
                let cp2 = CGPoint(
                    x: endPoint.x + ((controlPoint.x - endPoint.x) * 2/3),
                    y: endPoint.y + ((controlPoint.y - endPoint.y) * 2/3)
                )
                
                path.addCurve(to: endPoint, control1: cp1, control2: cp2)
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        
        return path
    }
} 