import Foundation

extension Array {
    func partition(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var nonMatching: [Element] = []
        
        forEach { element in
            if predicate(element) {
                matching.append(element)
            } else {
                nonMatching.append(element)
            }
        }
        
        return (matching, nonMatching)
    }
    
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
} 