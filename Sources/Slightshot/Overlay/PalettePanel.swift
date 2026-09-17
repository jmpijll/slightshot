import AppKit

/// The swatch grid that drops out of the colour well, plus a thickness slider —
/// the two things you actually change mid-annotation.
final class PalettePanel: NSView {
    static let swatches: [NSColor] = [
        NSColor(hex: "#FF3B30")!, NSColor(hex: "#FF9500")!, NSColor(hex: "#FFCC00")!,
        NSColor(hex: "#34C759")!, NSColor(hex: "#00C7BE")!, NSColor(hex: "#0A84FF")!,
        NSColor(hex: "#5E5CE6")!, NSColor(hex: "#FF2D55")!, NSColor(hex: "#FFFFFF")!,
        NSColor(hex: "#8E8E93")!, NSColor(hex: "#000000")!, NSColor(hex: "#A2845E")!,
    ]

    private let onPick: (NSColor) -> Void
    private let onWidth: (CGFloat) -> Void
    private let effect = NSVisualEffectView()
    private var swatchButtons: [SwatchCell] = []
    private let slider = NSSlider()

    init(selected: NSColor, width: CGFloat, onPick: @escaping (NSColor) -> Void, onWidth: @escaping (CGFloat) -> Void) {
        self.onPick = onPick
        self.onWidth = onWidth
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

        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        for row in 0..<2 {
            var cells: [NSView] = []
            for column in 0..<6 {
                let color = Self.swatches[row * 6 + column]
                let cell = SwatchCell(color: color) { [weak self] picked in
                    self?.select(picked)
                    onPick(picked)
                }
                cell.isPicked = color.hexString == selected.hexString
                swatchButtons.append(cell)
                cells.append(cell)
            }
            grid.addRow(with: cells)
        }

        slider.minValue = 1
        slider.maxValue = 12
        slider.doubleValue = Double(width)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(widthChanged)
        slider.toolTip = "Thickness"
        slider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [grid, slider])
        column.orientation = .vertical
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])

        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        dropShadow.shadowBlurRadius = 10
        dropShadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow = dropShadow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func widthChanged() { onWidth(CGFloat(slider.doubleValue)) }

    private func select(_ color: NSColor) {
        for cell in swatchButtons { cell.isPicked = cell.color.hexString == color.hexString }
    }

    private final class SwatchCell: NSButton {
        let color: NSColor
        private let onPick: (NSColor) -> Void
        var isPicked = false { didSet { needsDisplay = true } }

        init(color: NSColor, onPick: @escaping (NSColor) -> Void) {
            self.color = color
            self.onPick = onPick
            super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            isBordered = false
            title = ""
            target = self
            action = #selector(fire)
            setAccessibilityLabel(color.hexString)
            toolTip = color.hexString
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
        @objc private func fire() { onPick(color) }

        override func draw(_ dirtyRect: NSRect) {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            color.setFill()
            circle.fill()
            if isPicked {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
        }
    }
}
