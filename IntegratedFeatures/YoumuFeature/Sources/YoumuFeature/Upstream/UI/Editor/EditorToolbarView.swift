import AppKit

/// 编辑器顶部上下文工具栏：工具 | 当前工具参数 | 撤销重做。
/// 输出动作与缩放放在独立底栏，避免所有能力挤在一排。
class EditorToolbarView: NSView {

    var onToolSelected: ((EditorTool) -> Void)?
    var onArrowStyleSelected: ((ArrowStyle) -> Void)?
    var onColorSelected: ((NSColor) -> Void)?
    var onWidthSelected: ((StrokeWidth) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [EditorTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var widthButtons: [StrokeWidth: NSButton] = [:]
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private weak var arrowButton: NSButton?
    private var suppressArrowClick = false

    private var selectedTool: EditorTool = .rectangle
    private var selectedColorIndex = 0
    private var selectedWidth: StrokeWidth = .medium
    private(set) var selectedArrowStyle = ArrowStylePreference.load()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VisionDesign.editorChrome.cgColor
        layer?.borderWidth = 0
        setupButtons()

        let bottomRule = NSView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        bottomRule.wantsLayer = true
        bottomRule.layer?.backgroundColor = VisionDesign.editorDivider.cgColor
        bottomRule.autoresizingMask = [.width, .maxYMargin]
        addSubview(bottomRule)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未使用") }

    // MARK: - 装配

    private func setupButtons() {
        var x: CGFloat = 12
        let centerY = bounds.height / 2

        func place(_ view: NSView, width: CGFloat) {
            view.frame = NSRect(x: x, y: centerY - 15, width: width, height: 30)
            addSubview(view)
            x += width + 3
        }
        func separator() {
            let sep = NSView(frame: NSRect(x: x + 3, y: centerY - 10, width: 1, height: 20))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = VisionDesign.editorDivider.cgColor
            addSubview(sep)
            x += 12
        }

        // 工具组（对标微信分组：选择/形状 | 马赛克 | 序号/文字）
        let toolGroups: [[EditorTool]] = [
            [.select, .rectangle, .ellipse, .arrow, .pen, .highlight],
            [.mosaic],
            [.sequence, .text],
        ]
        for (groupIndex, group) in toolGroups.enumerated() {
            for tool in group {
                let action: () -> Void = { [weak self] in
                    if tool == .arrow, self?.suppressArrowClick == true { return }
                    self?.selectTool(tool)
                }
                let button = tool == .text
                    ? makeTitleButton(title: "A", tooltip: tool.tooltip, action: action)
                    : makeIconButton(symbol: tool.symbolName, tooltip: tool.tooltip, action: action)
                button.identifier = NSUserInterfaceItemIdentifier("editor.tool.\(tool)")
                if tool == .arrow {
                    arrowButton = button
                    let longPress = NSPressGestureRecognizer(
                        target: self,
                        action: #selector(arrowLongPressed(_:))
                    )
                    longPress.minimumPressDuration = 0.45
                    button.addGestureRecognizer(longPress)
                    // 右键快捷菜单是长按之外的原生可访问入口（VoiceOver 可直接打开）。
                    button.menu = makeArrowStyleMenu()
                    button.setAccessibilityHelp(
                        "短按使用上次样式，长按或打开快捷菜单选择箭头样式"
                    )
                }
                toolButtons[tool] = button
                place(button, width: 31)
            }
            if groupIndex < toolGroups.count - 1 { separator() }
        }
        separator()

        // 颜色组
        for (index, preset) in EditorColorPreset.allCases.enumerated() {
            let button = NSButton(frame: .zero)
            button.title = ""
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.backgroundColor = preset.color.cgColor
            button.target = self
            button.action = #selector(colorClicked(_:))
            button.tag = index
            button.toolTip = preset.displayName
            button.setAccessibilityLabel(preset.displayName)
            button.setAccessibilityValue(index == selectedColorIndex ? "已选择" : "未选择")
            colorButtons.append(button)
            place(button, width: 21)
            button.frame = NSRect(x: x - 23, y: centerY - 9, width: 18, height: 18)
        }
        separator()

        // 粗细 / 字号共用三档，直接写“小中大”，不暴露技术数值。
        for width in StrokeWidth.allCases {
            let button = NSButton(frame: .zero)
            button.title = width.displayName
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.target = self
            button.action = #selector(widthClicked(_:))
            button.tag = width == .thin ? 0 : (width == .medium ? 1 : 2)
            button.identifier = NSUserInterfaceItemIdentifier("editor.size.\(width.displayName)")
            widthButtons[width] = button
            place(button, width: 31)
        }
        separator()

        // 撤销/重做
        undoButton = makeIconButton(symbol: "arrow.uturn.backward", tooltip: "撤销 (⌘Z)") { [weak self] in
            self?.onUndo?()
        }
        place(undoButton!, width: 31)
        redoButton = makeIconButton(symbol: "arrow.uturn.forward", tooltip: "重做 (⇧⌘Z)") { [weak self] in
            self?.onRedo?()
        }
        place(redoButton!, width: 31)
        separator()

        refreshSelectionVisuals()
        setHistoryEnabled(canUndo: false, canRedo: false)
    }

    private func makeIconButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.setAccessibilityLabel(tooltip)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.onAction = action
        return button
    }

    private func makeTitleButton(
        title: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = ActionButton()
        button.title = title
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.onAction = action
        return button
    }

    @objc private func colorClicked(_ sender: NSButton) {
        selectedColorIndex = sender.tag
        onColorSelected?(EditorColorPreset.allCases[sender.tag].color)
        refreshSelectionVisuals()
        for (index, button) in colorButtons.enumerated() {
            button.setAccessibilityValue(index == selectedColorIndex ? "已选择" : "未选择")
        }
    }

    @objc private func widthClicked(_ sender: NSButton) {
        selectedWidth = StrokeWidth.allCases[sender.tag]
        onWidthSelected?(selectedWidth)
        refreshSelectionVisuals()
    }

    @objc private func arrowLongPressed(_ recognizer: NSPressGestureRecognizer) {
        guard recognizer.state == .began, let button = arrowButton else { return }
        suppressArrowClick = true
        let menu = makeArrowStyleMenu()
        menu.popUp(
            positioning: menu.items.first(where: { $0.state == .on }),
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
        // NSButton 的 mouseUp 可能在菜单关闭后才送达；本轮事件完成后再解除抑制。
        DispatchQueue.main.async { [weak self] in
            self?.suppressArrowClick = false
        }
    }

    /// 标准 NSMenu 同时承担即时图形预览、当前项勾选与 VoiceOver 可读名称。
    func makeArrowStyleMenu() -> NSMenu {
        let menu = NSMenu(title: "箭头样式")
        for (index, style) in ArrowStyle.allCases.enumerated() {
            let item = NSMenuItem(
                title: style.displayName,
                action: #selector(arrowStyleMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = style == selectedArrowStyle ? .on : .off
            item.image = ArrowStylePreview.image(style: style, size: NSSize(width: 38, height: 18))
            item.toolTip = style.accessibilityDescription
            menu.addItem(item)
        }
        return menu
    }

    @objc private func arrowStyleMenuItemSelected(_ sender: NSMenuItem) {
        guard ArrowStyle.allCases.indices.contains(sender.tag) else { return }
        setArrowStyle(ArrowStyle.allCases[sender.tag])
    }

    func setArrowStyle(
        _ style: ArrowStyle,
        persist: Bool = true,
        notify: Bool = true
    ) {
        selectedArrowStyle = style
        if persist { ArrowStylePreference.save(style) }
        selectedTool = .arrow
        if notify {
            onArrowStyleSelected?(style)
            onToolSelected?(.arrow)
        }
        refreshSelectionVisuals()
    }

    private func selectTool(_ tool: EditorTool) {
        selectedTool = tool
        onToolSelected?(tool)
        refreshSelectionVisuals()
    }

    /// 外部请求切换工具（如画完自动进入选中态）：只更新视觉，不回喷事件
    func setSelectedTool(_ tool: EditorTool) {
        selectedTool = tool
        refreshSelectionVisuals()
    }

    // MARK: - 状态刷新

    func setHistoryEnabled(canUndo: Bool, canRedo: Bool) {
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        undoButton?.contentTintColor = canUndo ? .white : NSColor.white.withAlphaComponent(0.3)
        redoButton?.contentTintColor = canRedo ? .white : NSColor.white.withAlphaComponent(0.3)
    }

    private func refreshSelectionVisuals() {
        if let arrowButton {
            arrowButton.image = ArrowStylePreview.image(
                style: selectedArrowStyle,
                size: NSSize(width: 24, height: 14)
            )
            arrowButton.toolTip = "箭头 · \(selectedArrowStyle.displayName)（长按选择样式）"
            arrowButton.setAccessibilityLabel("箭头，\(selectedArrowStyle.displayName)")
            arrowButton.setAccessibilityValue(
                selectedTool == .arrow ? "已选择" : "未选择"
            )
            arrowButton.menu = makeArrowStyleMenu()
        }
        for (tool, button) in toolButtons {
            let selected = (tool == selectedTool)
            if let actionButton = button as? ActionButton {
                actionButton.persistentFill = selected
                    ? NSColor.controlAccentColor.withAlphaComponent(0.82) : nil
            } else {
                button.layer?.backgroundColor = selected
                    ? NSColor.controlAccentColor.withAlphaComponent(0.82).cgColor : nil
            }
        }
        for (index, button) in colorButtons.enumerated() {
            let selected = (index == selectedColorIndex)
            button.layer?.borderWidth = selected ? 2.5 : 0
            button.layer?.borderColor = NSColor.white.cgColor
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = selected ? 0.28 : 0
            button.layer?.shadowRadius = selected ? 2 : 0
            button.layer?.shadowOffset = .zero
        }
        for (width, button) in widthButtons {
            let selected = (width == selectedWidth)
            button.title = width.displayName
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            button.toolTip = selectedTool == .text
                ? "文字字号：\(width.displayName)"
                : "粗细：\(width.displayName)"
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.82).cgColor
                : nil
            button.layer?.cornerRadius = 7
        }
    }
}

enum ArrowStylePreview {
    static func image(style: ArrowStyle, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            AnnotationRenderer.drawArrow(
                from: CGPoint(x: rect.minX + 3, y: rect.midY - 3),
                to: CGPoint(x: rect.maxX - 3, y: rect.midY + 3),
                lineWidth: 2,
                style: style
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 编辑器底部动作栏：缩放与输出固定分区，窗口缩放时出口始终贴右可见。
final class EditorActionBarView: NSView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onFit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var leftViews: [NSView] = []
    private var rightViews: [NSView] = []
    private var rightWidths: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VisionDesign.editorChrome.cgColor

        let topRule = NSView(frame: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        topRule.wantsLayer = true
        topRule.layer?.backgroundColor = VisionDesign.editorDivider.cgColor
        topRule.autoresizingMask = [.width, .minYMargin]
        addSubview(topRule)

        let minus = makeButton(symbol: "minus.magnifyingglass", tooltip: "缩小") { [weak self] in
            self?.onZoomOut?()
        }
        let fit = makeButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "适合窗口") { [weak self] in
            self?.onFit?()
        }
        let plus = makeButton(symbol: "plus.magnifyingglass", tooltip: "放大") { [weak self] in
            self?.onZoomIn?()
        }
        zoomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        zoomLabel.alignment = .center
        leftViews = [minus, zoomLabel, plus, fit]

        let cancel = makeButton(symbol: "xmark", tooltip: "取消 (Esc)") { [weak self] in
            self?.onCancel?()
        }
        cancel.contentTintColor = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1)
        let save = makeButton(symbol: "square.and.arrow.down", tooltip: "保存 PNG") { [weak self] in
            self?.onSave?()
        }
        let pin = makeButton(symbol: "pin", tooltip: "钉图") { [weak self] in
            self?.onPin?()
        }
        let confirm = makePrimaryButton(title: "完成", symbol: "checkmark", tooltip: "复制到剪贴板 (Enter)") { [weak self] in
            self?.onConfirm?()
        }
        rightViews = [cancel, save, pin, confirm]
        rightWidths = [32, 32, 32, 72]

        (leftViews + rightViews).forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未使用") }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        for (index, view) in leftViews.enumerated() {
            let width: CGFloat = (view === zoomLabel) ? 48 : 30
            view.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: width, height: 26)
            x += width + (index == 2 ? 10 : 4)
        }

        var rightX = bounds.maxX - 12
        for index in rightViews.indices.reversed() {
            let view = rightViews[index]
            let width = rightWidths[index]
            rightX -= width
            view.frame = NSRect(x: rightX, y: (bounds.height - 28) / 2, width: width, height: 28)
            rightX -= 6
        }
    }

    func setZoom(_ value: CGFloat) {
        zoomLabel.stringValue = "\(Int((value * 100).rounded()))%"
    }

    private func makeButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.onAction = action
        return button
    }

    private func makePrimaryButton(
        title: String,
        symbol: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = ActionButton()
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.persistentFill = NSColor.controlAccentColor
        button.onAction = action
        return button
    }
}

/// 带闭包动作的 NSButton（省去 target/action 样板）
private class ActionButton: NSButton {
    var onAction: (() -> Void)?
    var persistentFill: NSColor? {
        didSet { updateFill() }
    }
    private var hover = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(fire)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未使用") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        updateFill()
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        updateFill()
    }

    private func updateFill() {
        let fill = persistentFill ?? (hover ? NSColor.white.withAlphaComponent(0.10) : .clear)
        layer?.backgroundColor = fill.cgColor
    }

    @objc private func fire() { onAction?() }
}
