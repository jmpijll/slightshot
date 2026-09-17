import AppKit

/// A single icon button in one of the floating overlay toolbars.
final class ToolbarButton: NSButton {
    private let onClick: () -> Void
    private var hovering = false
    var accentColor: NSColor = .systemRed { didSet { refresh() } }

    var isSelectedItem = false { didSet { refresh() } }

    init(symbol: String, tooltip: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tooltip
        setAccessibilityLabel(tooltip)

        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        action = #selector(fire)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    @objc private func fire() { onClick() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    private func refresh() {
        if isSelectedItem {
            layer?.backgroundColor = accentColor.cgColor
            contentTintColor = .white
        } else if hovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.85)
        }
    }
}

/// The colour well in the tool bar: a filled circle showing the active colour.
final class ColorSwatchButton: NSButton {
    private let onClick: () -> Void
    private var hovering = false
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        isBordered = false
        title = ""
        toolTip = "Colour"
        setAccessibilityLabel("Colour")
        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }
    @objc private func fire() { onClick() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8))
        color.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
    }
}

/// A rounded, frosted bar that floats beside the selection.
final class ToolbarPanel: NSView {
    private let stack: NSStackView
    private let effect = NSVisualEffectView()

    init(orientation: NSUserInterfaceLayoutOrientation, views: [NSView]) {
        stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effect)
        addSubview(stack)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        dropShadow.shadowBlurRadius = 10
        dropShadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow = dropShadow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fits the panel to its buttons and returns the size, so the overlay can
    /// place it relative to the selection.
    var fittedSize: NSSize { stack.fittingSize }

    static func separator(orientation: NSUserInterfaceLayoutOrientation) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        if orientation == .vertical {
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.widthAnchor.constraint(equalToConstant: 22).isActive = true
        } else {
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        return line
    }
}
