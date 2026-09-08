import AppKit

enum EditorHistoryBudget {
    static let maximumAnnotationCount = 512
    static let maximumHistoryEntryCount = 64
    static let maximumHistoryEstimatedBytes = 48 * 1_024 * 1_024
    static let maximumStoredPenPoints = 4_096
    static let maximumPendingPenPoints = 8_192

    private static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? maximumHistoryEstimatedBytes : min(maximumHistoryEstimatedBytes, value)
    }

    private static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? maximumHistoryEstimatedBytes : min(maximumHistoryEstimatedBytes, value)
    }

    static func simplifiedPenPoints(
        _ points: [CGPoint],
        maximumCount: Int = maximumStoredPenPoints
    ) -> [CGPoint] {
        guard maximumCount >= 2, points.count > maximumCount else { return points }
        let step = Double(points.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { offset in
            points[min(points.count - 1, Int((Double(offset) * step).rounded()))]
        }
    }

    static func estimatedBytes(of annotations: [Annotation]) -> Int {
        annotations.reduce(0) { total, annotation in
            let payloadBytes: Int
            switch annotation.payload {
            case .pen(let points):
                payloadBytes = saturatedProduct(points.count, MemoryLayout<CGPoint>.stride)
            case .text(_, let string, _):
                payloadBytes = min(maximumHistoryEstimatedBytes, string.utf8.count)
            case .mosaic(_, _, let image):
                payloadBytes = image?.representations.reduce(0) { subtotal, representation in
                    let pixels = saturatedProduct(
                        max(0, representation.pixelsWide),
                        max(0, representation.pixelsHigh)
                    )
                    return saturatedSum(subtotal, saturatedProduct(pixels, 4))
                } ?? 0
            default:
                payloadBytes = 64
            }
            return saturatedSum(saturatedSum(total, 96), payloadBytes)
        }
    }
}

/// 编辑器画布：显示截图 + 标注层，处理全部绘制交互。
/// 视图 frame 为显示尺寸、bounds 为图像点尺寸（setBoundsSize 缩放），
/// 因此内部所有坐标都是图像点，与导出合成共用同一坐标系。
///
/// 事件入口（mouseDown/Dragged/Up、keyDown）只做坐标/修饰键换算，
/// 逻辑全部在 handleMouse*/handleKeyDown（internal，可被单元自测直接驱动）。
class EditorCanvasView: NSView {

    // MARK: - 外部状态（工具栏驱动）

    var currentTool: EditorTool = .rectangle {
        didSet { updateCursor(); discardTextField(commit: false) }
    }
    var currentColor: NSColor = EditorColorPreset.red.color
    var currentWidth: StrokeWidth = .medium
    var currentArrowStyle: ArrowStyle = ArrowStylePreference.load() {
        didSet { if currentTool == .arrow { needsDisplay = true } }
    }

    /// 输出动作回调（由 EditorWindowController 接线）
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    /// 撤销/重做可用性变化（刷新工具栏按钮态）
    var onHistoryStateChange: ((Bool, Bool) -> Void)?
    /// 键盘请求切换工具（当前绘制工具下按 Esc → 选择/移动），由控制器同步工具栏视觉。
    var onRequestToolSwitch: ((EditorTool) -> Void)?

    // MARK: - 数据

    private let baseCGImage: CGImage
    private let baseImage: NSImage      // 点尺寸 NSImage，用于屏幕绘制
    let imageSizePoints: NSSize
    private let pixelScale: CGFloat

    private(set) var annotations: [Annotation] = [] {
        didSet {
            needsDisplay = true
            onHistoryStateChange?(!undoStack.isEmpty, !redoStack.isEmpty)
        }
    }

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    // MARK: - 交互暂态

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var dragShift = false
    private var penPoints: [CGPoint] = []
    private(set) var selectedIndex: Int?
    private var lastDragPoint: CGPoint?
    private var selectDragSnapshotPending = false
    private(set) var textField: NSTextField?
    /// 双击重编辑中的文字标注下标（编辑期间画布不绘制该标注，避免与输入框重影）
    private var editingTextIndex: Int?

    // MARK: - Init

    init(baseCG: CGImage, pixelScale: CGFloat) {
        self.baseCGImage = baseCG
        self.pixelScale = pixelScale
        self.imageSizePoints = NSSize(
            width: CGFloat(baseCG.width) / pixelScale,
            height: CGFloat(baseCG.height) / pixelScale
        )
        self.baseImage = NSImage(cgImage: baseCG, size: imageSizePoints)
        super.init(frame: NSRect(origin: .zero, size: imageSizePoints))
        updateCursor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未使用") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false } // 左下原点，与标注坐标系一致

    /// 关键：画布区域内的 mouseDown 永远不许被解释成窗口拖拽。
    /// NSView 默认返回 true，配合 isMovableByWindowBackground 会导致
    /// 「按住想画标注，整个窗口跟着鼠标跑」（P0 bug 根因）。
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: NSRect(origin: .zero, size: imageSizePoints))

        // 普通标注先画，聚光遮罩最后覆盖，确保框外的文字/箭头也一起柔和压暗。
        for (index, annotation) in annotations.enumerated() {
            // 正在重编辑的文字标注先藏起来，由输入框呈现
            if index == editingTextIndex, textField != nil { continue }
            if case .highlight = annotation.payload { continue }
            AnnotationRenderer.draw(annotation)
        }

        var spotlightRects = SpotlightRenderer.highlightRects(from: annotations)
        if currentTool == .highlight, let preview = currentDragRect() {
            spotlightRects.append(preview)
        }
        SpotlightRenderer.draw(
            in: NSRect(origin: .zero, size: imageSizePoints),
            highlights: spotlightRects
        )

        // 选中框始终在最上层，暗背景下仍清楚可见。
        if let selectedIndex, annotations.indices.contains(selectedIndex) {
            AnnotationRenderer.drawSelectionHighlight(annotations[selectedIndex])
        }
        drawInProgressPreview()
    }

    /// 拖拽中的半成品预览
    private func drawInProgressPreview() {
        currentColor.setStroke()
        currentColor.setFill()

        switch currentTool {
        case .rectangle:
            guard let rect = currentDragRect() else { return }
            let path = AnnotationRenderer.continuousRoundedRectanglePath(
                in: rect,
                lineWidth: currentWidth.lineWidth
            )
            path.lineWidth = currentWidth.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            guard let rect = currentDragRect() else { return }
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = currentWidth.lineWidth
            path.stroke()

        case .arrow:
            guard let start = dragStart, let end = dragCurrent else { return }
            AnnotationRenderer.draw(Annotation(
                payload: .arrow(start: start, end: end, style: currentArrowStyle),
                color: currentColor,
                lineWidth: currentWidth.lineWidth
            ))

        case .pen:
            guard penPoints.count > 1 else { return }
            AnnotationRenderer.draw(
                Annotation(payload: .pen(points: penPoints),
                           color: currentColor, lineWidth: currentWidth.lineWidth)
            )

        case .highlight:
            // 聚光预览已和现有框一起由 draw(_:) 统一计算，避免叠两层遮罩。
            break

        case .mosaic:
            guard let rect = currentDragRect() else { return }
            NSColor.white.withAlphaComponent(0.25).setFill()
            rect.fill()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()

        case .select, .text, .sequence:
            break
        }
    }

    private func currentDragRect() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let end = constrainedEnd(from: start, to: current, shiftDown: dragShift)
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        return rect.width > 2 && rect.height > 2 ? rect : nil
    }

    /// Shift 约束：矩形/椭圆锁正方形（正圆），箭头锁 45° 倍数角
    private func constrainedEnd(from start: CGPoint, to current: CGPoint, shiftDown: Bool) -> CGPoint {
        guard shiftDown else { return current }
        switch currentTool {
        case .rectangle, .ellipse:
            let side = max(abs(current.x - start.x), abs(current.y - start.y))
            return CGPoint(
                x: start.x + side * (current.x >= start.x ? 1 : -1),
                y: start.y + side * (current.y >= start.y ? 1 : -1)
            )
        case .arrow:
            let dx = current.x - start.x, dy = current.y - start.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { return current }
            let snapped = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: start.x + length * cos(snapped), y: start.y + length * sin(snapped))
        default:
            return current
        }
    }

    // MARK: - 鼠标事件入口（只换算坐标，逻辑在 handler）

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseDown(
            at: convert(event.locationInWindow, from: nil),
            clickCount: event.clickCount,
            shiftDown: event.modifierFlags.contains(.shift)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(
            to: convert(event.locationInWindow, from: nil),
            shiftDown: event.modifierFlags.contains(.shift)
        )
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(
            at: convert(event.locationInWindow, from: nil),
            shiftDown: event.modifierFlags.contains(.shift)
        )
    }

    // MARK: - 鼠标逻辑（internal，单元自测可直接驱动）

    func handleMouseDown(at point: CGPoint, clickCount: Int, shiftDown: Bool) {
        discardTextField(commit: true)

        switch currentTool {
        case .select:
            if clickCount == 2 {
                handleSelectDoubleClick(at: point)
                return
            }
            // 从最上层往下找
            selectedIndex = annotations.indices.reversed().first { annotations[$0].hitTest(point) }
            lastDragPoint = point
            selectDragSnapshotPending = (selectedIndex != nil)
            needsDisplay = true

        case .rectangle, .ellipse, .arrow, .highlight, .mosaic:
            dragStart = point
            dragCurrent = point
            dragShift = shiftDown

        case .pen:
            penPoints = [point]

        case .sequence:
            // 点击即放置，序号 = 已有序号标注数 + 1
            let nextNumber = annotations.reduce(0) { count, annotation in
                if case .sequence = annotation.payload { return count + 1 }
                return count
            } + 1
            pushAnnotation(Annotation(
                payload: .sequence(center: point, number: nextNumber,
                                   diameter: currentWidth.sequenceDiameter),
                color: currentColor, lineWidth: currentWidth.lineWidth
            ))

        case .text:
            placeTextField(at: point)
        }
    }

    /// 双击（选择工具）：文字标注 → 重新编辑内容；空白处 → 确认复制
    private func handleSelectDoubleClick(at point: CGPoint) {
        if let index = annotations.indices.reversed().first(where: { annotations[$0].hitTest(point) }),
           case .text(let origin, let string, let fontSize) = annotations[index].payload {
            selectedIndex = nil
            editingTextIndex = index
            placeTextField(at: origin, initialText: string, fontSize: fontSize)
        } else {
            onConfirm?()
        }
    }

    func handleMouseDragged(to point: CGPoint, shiftDown: Bool) {
        switch currentTool {
        case .select:
            guard let index = selectedIndex, let last = lastDragPoint else { return }
            // 首次真正拖动时才拍快照，单击选中不产生多余的撤销记录
            if selectDragSnapshotPending {
                pushUndoSnapshot()
                selectDragSnapshotPending = false
            }
            let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
            annotations[index] = annotations[index].moved(by: delta)
            lastDragPoint = point

        case .rectangle, .ellipse, .arrow, .highlight, .mosaic:
            dragCurrent = point
            dragShift = shiftDown
            needsDisplay = true

        case .pen:
            if let last = penPoints.last, hypot(point.x - last.x, point.y - last.y) > 1.5 {
                if penPoints.count >= EditorHistoryBudget.maximumPendingPenPoints {
                    penPoints = EditorHistoryBudget.simplifiedPenPoints(
                        penPoints,
                        maximumCount: EditorHistoryBudget.maximumStoredPenPoints / 2
                    )
                }
                penPoints.append(point)
                needsDisplay = true
            }

        case .text, .sequence:
            break
        }
    }

    func handleMouseUp(at point: CGPoint, shiftDown: Bool) {
        switch currentTool {
        case .select:
            lastDragPoint = nil

        case .rectangle, .ellipse, .highlight:
            // 关键修复：终稿必须用 mouseUp 的释放点，而不是最后一次 dragged 的暂存点
            dragCurrent = point
            dragShift = shiftDown
            if let rect = currentDragRect() {
                let payload: Annotation.Payload
                switch currentTool {
                case .rectangle: payload = .rectangle(rect)
                case .ellipse: payload = .ellipse(rect)
                case .highlight: payload = .highlight(rect)
                default: return
                }
                pushAnnotation(Annotation(payload: payload,
                                          color: currentColor, lineWidth: currentWidth.lineWidth))
                finishShapeTool()
            }
            dragStart = nil; dragCurrent = nil; needsDisplay = true

        case .arrow:
            guard let start = dragStart else {
                dragCurrent = nil; needsDisplay = true
                return
            }
            let end = constrainedEnd(from: start, to: point, shiftDown: shiftDown)
            if hypot(end.x - start.x, end.y - start.y) > 4 {
                pushAnnotation(Annotation(
                    payload: .arrow(start: start, end: end, style: currentArrowStyle),
                    color: currentColor,
                    lineWidth: currentWidth.lineWidth
                ))
                finishShapeTool()
            }
            dragStart = nil; dragCurrent = nil; needsDisplay = true

        case .pen:
            if penPoints.count > 1 {
                let simplifiedPenPoints = EditorHistoryBudget.simplifiedPenPoints(penPoints)
                pushAnnotation(Annotation(payload: .pen(points: simplifiedPenPoints),
                                          color: currentColor, lineWidth: currentWidth.lineWidth))
            }
            penPoints = []; needsDisplay = true

        case .mosaic:
            dragCurrent = point
            dragShift = shiftDown
            if let rect = currentDragRect() {
                // 关键修复：像素化图与标注 rect 都用同一份钳制后的区域，不再错位
                let clamped = rect.intersection(NSRect(origin: .zero, size: imageSizePoints))
                if let pixelated = ImageComposer.pixelatedMosaic(
                    rect: clamped, imageSizePoints: imageSizePoints,
                    baseCG: baseCGImage, blockSizePoints: currentWidth.mosaicBlockSize
                ) {
                    pushAnnotation(Annotation(
                        payload: .mosaic(rect: clamped, blockSize: currentWidth.mosaicBlockSize,
                                         image: pixelated),
                        color: currentColor, lineWidth: currentWidth.lineWidth
                    ))
                    finishShapeTool()
                }
            }
            dragStart = nil; dragCurrent = nil; needsDisplay = true

        case .text, .sequence:
            break
        }
    }

    /// 形状画完保持当前工具，让箭头、矩形、椭圆、马赛克都能连续绘制。
    /// 只有用户主动选择“选择/移动”或按 Esc，才退出当前绘制工具。
    private func finishShapeTool() {
        selectedIndex = nil
        needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        if isCommand && keyCode == 6 { // ⌘Z / ⇧⌘Z
            isShift ? redo() : undo()
            return
        }
        switch keyCode {
        case 36, 76: // Enter / 小键盘 Enter → 复制并关闭
            discardTextField(commit: true)
            onConfirm?()
        case 53: // Esc：取消文字/选中；绘制工具 → 选择/移动；选择工具空闲时才退出编辑器
            if textField != nil {
                discardTextField(commit: false)
            } else if selectedIndex != nil {
                selectedIndex = nil
                needsDisplay = true
            } else if currentTool != .select {
                onRequestToolSwitch?(.select)
            } else {
                onCancel?()
            }
        case 51: // Delete → 删除选中标注
            if let index = selectedIndex {
                pushUndoSnapshot()
                annotations.remove(at: index)
                selectedIndex = nil
            }
        default:
            break
        }
    }

    // MARK: - 撤销 / 重做（快照式）

    private func pushUndoSnapshot() {
        undoStack.append(annotations)
        redoStack.removeAll()
        trimHistoryToBudget()
        onHistoryStateChange?(true, false)
    }

    private func pushAnnotation(_ annotation: Annotation) {
        guard annotations.count < EditorHistoryBudget.maximumAnnotationCount else {
            ToastWindow.show(message: "标注已达 512 个上限")
            return
        }
        pushUndoSnapshot()
        selectedIndex = nil
        annotations.append(annotation)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(annotations)
        trimHistoryToBudget()
        selectedIndex = nil
        annotations = snapshot
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(annotations)
        trimHistoryToBudget()
        selectedIndex = nil
        annotations = snapshot
    }

    /// Keep the newest useful history while bounding both array count and payload cost. Mosaic
    /// images are conservatively charged per snapshot even though NSImage storage is shared.
    private func trimHistoryToBudget() {
        while undoStack.count > EditorHistoryBudget.maximumHistoryEntryCount {
            undoStack.removeFirst()
        }
        while redoStack.count > EditorHistoryBudget.maximumHistoryEntryCount {
            redoStack.removeFirst()
        }
        var estimated = (undoStack + redoStack).reduce(0) {
            $0 + EditorHistoryBudget.estimatedBytes(of: $1)
        }
        while estimated > EditorHistoryBudget.maximumHistoryEstimatedBytes {
            if !undoStack.isEmpty {
                estimated -= EditorHistoryBudget.estimatedBytes(of: undoStack.removeFirst())
            } else if !redoStack.isEmpty {
                estimated -= EditorHistoryBudget.estimatedBytes(of: redoStack.removeFirst())
            } else {
                break
            }
        }
    }

    /// 工具栏线宽/字号切换：既影响下一笔，也即时更新当前选中的标注。
    func setWidth(_ width: StrokeWidth) {
        currentWidth = width
        if let field = textField {
            field.font = NSFont.boldSystemFont(ofSize: width.fontSize)
            field.frame.size.height = width.fontSize + 12
        }
        guard let index = selectedIndex else { return }

        var updated = annotations[index]
        updated.lineWidth = width.lineWidth
        switch updated.payload {
        case .text(let origin, let string, _):
            updated.payload = .text(origin: origin, string: string, fontSize: width.fontSize)
        case .sequence(let center, let number, _):
            updated.payload = .sequence(
                center: center, number: number, diameter: width.sequenceDiameter
            )
        default:
            break
        }
        pushUndoSnapshot()
        annotations[index] = updated
    }

    // MARK: - 文字输入

    private func placeTextField(at point: CGPoint, initialText: String = "", fontSize: CGFloat? = nil) {
        let size = fontSize ?? currentWidth.fontSize
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y, width: 240, height: size + 12))
        field.stringValue = initialText
        field.font = NSFont.boldSystemFont(ofSize: size)
        field.textColor = currentColor
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.25)
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "输入文字"
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        needsDisplay = true
    }

    func discardTextField(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 关键修复：文字标注原点取「输入框 cell 的文字绘制区」原点，
        // 而不是输入框 frame 原点 —— 提交后文字位置与输入时所见一致，不跳。
        let cellRect = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        let textOrigin = CGPoint(
            x: field.frame.minX + cellRect.minX,
            y: field.frame.minY + cellRect.minY
        )
        let fontSize = field.font?.pointSize ?? currentWidth.fontSize
        field.removeFromSuperview()

        if let editingIndex = editingTextIndex {
            // 双击重编辑：原位替换内容，取消则保留原文
            editingTextIndex = nil
            if commit, !string.isEmpty {
                pushUndoSnapshot()
                let old = annotations[editingIndex]
                annotations[editingIndex] = Annotation(
                    payload: .text(origin: textOrigin, string: string, fontSize: fontSize),
                    color: old.color, lineWidth: old.lineWidth
                )
            }
        } else if commit, !string.isEmpty {
            pushAnnotation(Annotation(
                payload: .text(origin: textOrigin, string: string, fontSize: fontSize),
                color: currentColor, lineWidth: currentWidth.lineWidth
            ))
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - 光标

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        discardCursorRects()
        let rect = NSRect(origin: .zero, size: imageSizePoints)
        switch currentTool {
        case .select: addCursorRect(rect, cursor: .arrow)
        case .text: addCursorRect(rect, cursor: .iBeam)
        case .rectangle, .ellipse, .arrow, .pen, .highlight, .mosaic:
            addCursorRect(rect, cursor: .crosshair)
        case .sequence: addCursorRect(rect, cursor: .crosshair)
        }
    }
}

// MARK: - 文字输入代理（Enter 提交 / Esc 放弃）

extension EditorCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            discardTextField(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardTextField(commit: false)
            return true
        }
        return false
    }
}
