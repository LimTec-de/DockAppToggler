import AppKit

/// A custom close button with hover effects and theme-aware colors
class CloseButton: NSButton {
    private let normalConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        .applying(.init(paletteColors: [.systemGray]))
    private let hoverConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        .applying(.init(paletteColors: [.systemRed]))
    
    init(frame: NSRect, tag: Int, target: AnyObject?, action: Selector) {
        super.init(frame: frame)
        
        self.tag = tag
        self.target = target
        self.action = action
        
        // Basic setup
        self.bezelStyle = .inline
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.setButtonType(.momentaryLight)
        
        // Ensure perfect circle by using square frame
        let size: CGFloat = 16  // Fixed size for perfect circle
        let x = frame.origin.x + (frame.width - size) / 2
        let y = frame.origin.y + (frame.height - size) / 2
        self.frame = NSRect(x: x, y: y, width: size, height: size)
        
        // Add circle background with theme-aware colors
        self.wantsLayer = true
        self.layer?.cornerRadius = size / 2
        
        // Set initial background color
        let isDark = self.effectiveAppearance.isDarkMode
        let initialColor = isDark ?
            Constants.UI.Theme.iconTintColor.withAlphaComponent(0.2) :
            Constants.UI.Theme.iconSecondaryTintColor.withAlphaComponent(0.2)
        self.layer?.backgroundColor = initialColor.cgColor
        
        // Update initial appearance
        updateAppearance(isHovered: false)
        
        // Add tracking area
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateBackgroundColor(isHovered: Bool) {
        let isDark = self.effectiveAppearance.isDarkMode
        let color = isHovered ?
            Constants.UI.Theme.iconTintColor.withAlphaComponent(0.3) :
            (isDark ?
                Constants.UI.Theme.iconTintColor.withAlphaComponent(0.2) :
                Constants.UI.Theme.iconSecondaryTintColor.withAlphaComponent(0.2))
        self.layer?.backgroundColor = color.cgColor
    }
    
    private func updateAppearance(isHovered: Bool) {
        // Update background color
        updateBackgroundColor(isHovered: isHovered)
        
        // Update symbol configuration
        let config = isHovered ? hoverConfig : normalConfig
        let symbol = "xmark"
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Close")?.withSymbolConfiguration(config)
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateAppearance(isHovered: true)
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateAppearance(isHovered: false)
    }
} 