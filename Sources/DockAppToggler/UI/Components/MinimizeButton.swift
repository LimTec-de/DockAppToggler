import AppKit

/// A custom minimize button with hover effects and theme-aware colors
class MinimizeButton: NSButton {
    private var isWindowMinimized: Bool = false
    private var isHovered: Bool = false
    
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
        
        // Add circle background
        self.wantsLayer = true
        self.layer?.cornerRadius = size / 2
        
        // Set initial background color
        let isDark = self.effectiveAppearance.isDarkMode
        let initialColor = isDark ?
            Constants.UI.Theme.iconTintColor.withAlphaComponent(0.2) :
            Constants.UI.Theme.iconSecondaryTintColor.withAlphaComponent(0.2)
        self.layer?.backgroundColor = initialColor.cgColor
        
        // Configure the minus symbol with adjusted size
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.systemGray]))
        let minusImage = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize")?
            .withSymbolConfiguration(config)
        self.image = minusImage
        
        self.contentTintColor = .systemGray
        self.alphaValue = 0.8
        
        // Add tracking area
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
        
        // Set initial state
        updateMinimizedState(false)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateMinimizedState(_ minimized: Bool) {
        isWindowMinimized = minimized
        
        // Update symbol based on minimized state
        let symbolName = minimized ? "plus" : "minus"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [minimized ? NSColor.tertiaryLabelColor : .systemGray]))
        
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: minimized ? "Restore" : "Minimize")?
            .withSymbolConfiguration(config)
        
        // Update colors based on current hover state
        if isHovered {
            self.contentTintColor = minimized ? .systemBlue : .systemOrange
        } else {
            self.contentTintColor = minimized ? NSColor.tertiaryLabelColor : .systemGray
        }
        
        updateBackgroundColor()
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if isWindowMinimized {
            self.contentTintColor = .systemBlue
        } else {
            self.contentTintColor = .systemOrange
        }
        updateBackgroundColor()
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if isWindowMinimized {
            self.contentTintColor = NSColor.tertiaryLabelColor
        } else {
            self.contentTintColor = .systemGray
        }
        updateBackgroundColor()
    }
    
    private func updateBackgroundColor() {
        let isDark = self.effectiveAppearance.isDarkMode
        
        if isWindowMinimized {
            let color = isDark ?
                (isHovered ? NSColor(white: 0.3, alpha: 0.3) : NSColor(white: 0.3, alpha: 0.2)) :
                (isHovered ? NSColor(white: 0.85, alpha: 0.3) : NSColor(white: 0.85, alpha: 0.2))
            self.layer?.backgroundColor = color.cgColor
            self.alphaValue = 0.5
        } else {
            // Use more opaque background colors
            let color = isDark ?
                (isHovered ? NSColor(white: 0.3, alpha: 0.5) : NSColor(white: 0.3, alpha: 0.35)) :
                (isHovered ? NSColor(white: 0.85, alpha: 0.5) : NSColor(white: 0.85, alpha: 0.35))
            self.layer?.backgroundColor = color.cgColor
            self.alphaValue = isHovered ? 1.0 : 0.8
        }
    }
} 