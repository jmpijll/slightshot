import AppKit

@MainActor
protocol ToolbarControllerDelegate: AnyObject {
    func toolbarDidChangeTool(_ tool: Tool?)
    func toolbarDidChangeColor(_ color: NSColor)
    func toolbarDidChangeLineWidth(_ width: CGFloat)
    func toolbarDidRequestUndo()
    func toolbarDidRequest(_ action: CaptureAction)
    func toolbarDidRequestClose()
}

/// Owns the two floating bars and the colour popover, and keeps them glued to
/// the selection. Splitting this out of `OverlayView` leaves that type to do one
/// thing — turn mouse and keyboard input into a selection and annotations.
final class ToolbarController {
    weak var delegate: ToolbarControllerDelegate?

    private unowned let host: NSView
    private var toolPanel: ToolbarPanel?
    private var actionPanel: ToolbarPanel?
    private var palette: PalettePanel?
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: ColorSwatchButton?

    private(set) var activeTool: Tool?
    private var color: NSColor
    private var lineWidth: CGFloat

    /// Survives between captures so "remember last tool" works without touching disk.
    private static var lastTool: Tool?

    init(host: NSView, color: NSColor, lineWidth: CGFloat) {
        self.host = host
        self.color = color
        self.lineWidth = lineWidth
    }

    // MARK: - Tools

    func restoreRememberedTool() {
        guard Settings.shared.rememberLastTool, activeTool == nil, let remembered = Self.lastTool else { return }
        select(remembered)
    }

    func select(_ tool: Tool?) {
        activeTool = tool
        for (candidate, button) in toolButtons { button.isSelectedItem = (candidate == tool) }
        if tool == nil { hidePalette() }
        if Settings.shared.rememberLastTool { Self.lastTool = tool }
        delegate?.toolbarDidChangeTool(tool)
    }

    private func toggle(_ tool: Tool) {
        select(activeTool == tool ? nil : tool)
    }

    // MARK: - Layout

    /// Positions both bars around `selection`, or hides them when there is
    /// nothing to act on yet.
    func layout(around selection: CGRect?, in bounds: CGRect, visible: Bool) {
        guard visible, let selection, selection.width >= 8, selection.height >= 8 else {
            toolPanel?.isHidden = true
            actionPanel?.isHidden = true
            palette?.isHidden = true
            return
        }

        buildIfNeeded()
        guard let tools = toolPanel, let actions = actionPanel else { return }
        tools.isHidden = false
        actions.isHidden = false
        palette?.isHidden = false

        let gap: CGFloat = 8
        let margin: CGFloat = 4

        // Tools sit to the right of the selection, flipping to the left or
        // tucking inside when the selection is against a display edge.
        let toolSize = tools.fittingSize
        var toolX = selection.maxX + gap
        if toolX + toolSize.width > bounds.maxX - margin {
            toolX = selection.minX - gap - toolSize.width
        }
        if toolX < margin { toolX = max(margin, selection.maxX - toolSize.width - gap) }
        let toolY = min(max(margin, selection.minY), bounds.maxY - toolSize.height - margin)
        tools.frame = CGRect(origin: CGPoint(x: toolX, y: toolY), size: toolSize)

        // Actions sit below the selection, right-aligned to it.
        let actionSize = actions.fittingSize
        var actionY = selection.maxY + gap
        if actionY + actionSize.height > bounds.maxY - margin {
            actionY = selection.minY - gap - actionSize.height
        }
        if actionY < margin { actionY = max(margin, selection.maxY - actionSize.height - gap) }
        let actionX = min(max(margin, selection.maxX - actionSize.width),
                          bounds.maxX - actionSize.width - margin)
        actions.frame = CGRect(origin: CGPoint(x: actionX, y: actionY), size: actionSize)

        layoutPalette(in: bounds)
    }

    private func buildIfNeeded() {
        guard toolPanel == nil else { return }

        var toolViews: [NSView] = []
        for tool in Tool.allCases {
            let button = ToolbarButton(symbol: tool.symbolName, tooltip: tool.title) { [weak self] in
                self?.toggle(tool)
            }
            button.accentColor = color
            toolButtons[tool] = button
            toolViews.append(button)
        }
        toolViews.append(ToolbarPanel.separator(orientation: .vertical))

        let swatch = ColorSwatchButton { [weak self] in self?.togglePalette() }
        swatch.color = color
        colorButton = swatch
        toolViews.append(swatch)

        toolViews.append(ToolbarButton(symbol: "arrow.uturn.backward", tooltip: "Undo  ⌘Z") { [weak self] in
            self?.delegate?.toolbarDidRequestUndo()
        })

        let tools = ToolbarPanel(orientation: .vertical, views: toolViews)
        host.addSubview(tools)
        toolPanel = tools

        let actions = ToolbarPanel(orientation: .horizontal, views: [
            ToolbarButton(symbol: "printer", tooltip: "Print  ⌘P") { [weak self] in
                self?.delegate?.toolbarDidRequest(.print)
            },
            ToolbarButton(symbol: "doc.on.doc", tooltip: "Copy  ⌘C") { [weak self] in
                self?.delegate?.toolbarDidRequest(.copy)
            },
            ToolbarButton(symbol: "square.and.arrow.down", tooltip: "Save  ⌘S  ·  Save As  ⇧⌘S") { [weak self] in
                self?.delegate?.toolbarDidRequest(.save)
            },
            ToolbarPanel.separator(orientation: .horizontal),
            ToolbarButton(symbol: "xmark", tooltip: "Close  Esc") { [weak self] in
                self?.delegate?.toolbarDidRequestClose()
            },
        ])
        host.addSubview(actions)
        actionPanel = actions

        // Selecting a tool before the bars existed still has to light the button up.
        if let activeTool { toolButtons[activeTool]?.isSelectedItem = true }
    }

    // MARK: - Palette

    private func togglePalette() {
        if palette != nil { hidePalette(); return }
        let panel = PalettePanel(selected: color, width: lineWidth) { [weak self] picked in
            self?.apply(color: picked)
        } onWidth: { [weak self] width in
            self?.lineWidth = width
            Settings.shared.lineWidth = Double(width)
            self?.delegate?.toolbarDidChangeLineWidth(width)
        }
        host.addSubview(panel)
        palette = panel
        layoutPalette(in: host.bounds)
    }

    func hidePalette() {
        palette?.removeFromSuperview()
        palette = nil
    }

    private func layoutPalette(in bounds: CGRect) {
        guard let palette, let tools = toolPanel, let swatch = colorButton else { return }
        let size = palette.fittingSize
        let swatchFrame = swatch.convert(swatch.bounds, to: host)

        var x = tools.frame.maxX + 8
        if x + size.width > bounds.maxX - 4 { x = tools.frame.minX - 8 - size.width }
        x = min(max(4, x), bounds.maxX - size.width - 4)
        let y = min(max(4, swatchFrame.midY - size.height / 2), bounds.maxY - size.height - 4)
        palette.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func apply(color newColor: NSColor) {
        color = newColor
        colorButton?.color = newColor
        for button in toolButtons.values { button.accentColor = newColor }
        Settings.shared.annotationColor = newColor
        delegate?.toolbarDidChangeColor(newColor)
    }
}
