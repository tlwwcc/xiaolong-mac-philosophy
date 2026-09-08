import AppKit

/// 截图标注编辑器：⌃⌥⌘1 选区截图后打开。
/// 布局 = 顶部上下文工具栏 + 可滚动/缩放画布 + 底部动作栏。
/// 画布始终使用图像点坐标系；缩放由 NSScrollView magnification 完成，不改标注坐标。
class EditorWindowController: NSObject {

    // MARK: - 入口（ScreenCaptureService 调用）

    private static var ownedEditors: [CaptureCommandOwner: EditorWindowController] = [:]
    private static var unownedEditors: [UUID: EditorWindowController] = [:]

    @discardableResult
    static func show(
        image: CGImage,
        pixelScale: CGFloat,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) -> Bool {
        // An exact command owner may present only once. Different owners and manual Pin editors
        // intentionally coexist instead of sharing a process-global singleton.
        if let owner, ownedEditors[owner] != nil { return false }
        let controller = EditorWindowController(
            image: image,
            pixelScale: pixelScale,
            owner: owner,
            onDismiss: onDismiss
        )
        if let owner {
            ownedEditors[owner] = controller
        } else {
            unownedEditors[controller.editorID] = controller
        }
        controller.present()
        return true
    }

    /// Closes only the editor created by this exact capture invocation.
    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard let controller = ownedEditors[owner], !controller.isClosing else { return false }
        controller.closeWindow()
        return true
    }

    // MARK: - 内部

    private var window: NSWindow?
    private let canvas: EditorCanvasView
    private let toolbar = EditorToolbarView(frame: NSRect(x: 0, y: 0, width: 10, height: 50))
    private let actionBar = EditorActionBarView(frame: NSRect(x: 0, y: 0, width: 10, height: 44))
    private let scrollView = EditorScrollView(frame: .zero)
    private let baseCGImage: CGImage
    private let pixelScale: CGFloat
    private let owner: CaptureCommandOwner?
    private let onDismiss: ((CaptureCommandOwner) -> Void)?
    private let editorID = UUID()

    private let toolbarHeight: CGFloat = 50
    private let actionBarHeight: CGFloat = 44
    private var fitMode = true
    private var isClosing = false
    private var didNotifyDismiss = false

    private init(
        image: CGImage,
        pixelScale: CGFloat,
        owner: CaptureCommandOwner?,
        onDismiss: ((CaptureCommandOwner) -> Void)?
    ) {
        self.baseCGImage = image
        self.pixelScale = pixelScale
        self.owner = owner
        self.onDismiss = onDismiss
        self.canvas = EditorCanvasView(baseCG: image, pixelScale: pixelScale)
        super.init()
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)

        let imageSize = canvas.imageSizePoints
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first

        let visibleSize = mouseScreen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let contentSize = EditorViewportLayout.initialContentSize(
            imageSize: imageSize,
            visibleScreenSize: visibleSize
        )

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = VisionDesign.editorChrome.cgColor
        container.autoresizesSubviews = false // 尺寸变化由 layoutContents 显式重排

        scrollView.drawsBackground = true
        scrollView.backgroundColor = VisionDesign.editorChromeRaised
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.onMagnificationGesture = { [weak self] value in
            self?.fitMode = false
            self?.actionBar.setZoom(value)
        }
        scrollView.contentView = CenteredClipView()
        canvas.setFrameSize(imageSize)
        canvas.setBoundsSize(imageSize)
        scrollView.documentView = canvas

        container.addSubview(scrollView)
        container.addSubview(toolbar)
        container.addSubview(actionBar)

        // 标准 macOS 工作台窗口；内容区仍禁止背景拖拽，画布手势不会带着窗口跑。
        let win = EditorWindow(
            contentRect: NSRect(origin: .zero, size: contentSize)
        )
        win.title = "游目 · 标注"
        win.contentView = container
        win.minSize = NSSize(width: 720, height: 460)
        win.delegate = self
        if let screenFrame = mouseScreen?.visibleFrame {
            win.setFrameOrigin(NSPoint(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.midY - contentSize.height / 2
            ))
        }
        window = win
        layoutContents(contentSize: contentSize)
        applyFitMagnification()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(canvas)
        wireCallbacks()
    }

    /// 只重排稳定的三段工作区；documentView 尺寸与标注坐标均不随窗口变化。
    private func layoutContents(contentSize: NSSize) {
        toolbar.frame = NSRect(
            x: 0, y: contentSize.height - toolbarHeight,
            width: contentSize.width, height: toolbarHeight
        )
        actionBar.frame = NSRect(
            x: 0, y: 0,
            width: contentSize.width, height: actionBarHeight
        )
        scrollView.frame = NSRect(
            x: 0, y: actionBarHeight,
            width: contentSize.width,
            height: max(80, contentSize.height - toolbarHeight - actionBarHeight)
        )
    }

    private func applyFitMagnification() {
        let mode: EditorViewportLayout.FitMode = canvas.imageSizePoints.height
            > canvas.imageSizePoints.width * 1.5 ? .width : .window
        let value = EditorViewportLayout.fitMagnification(
            imageSize: canvas.imageSizePoints,
            viewportSize: scrollView.contentSize,
            mode: mode
        )
        scrollView.setMagnification(value, centeredAt: NSPoint(
            x: canvas.imageSizePoints.width / 2,
            y: canvas.imageSizePoints.height / 2
        ))
        actionBar.setZoom(value)
    }

    private func changeZoom(multiplier: CGFloat) {
        fitMode = false
        let next = min(max(scrollView.magnification * multiplier, 0.25), 4)
        scrollView.setMagnification(next, centeredAt: NSPoint(
            x: canvas.visibleRect.midX,
            y: canvas.visibleRect.midY
        ))
        actionBar.setZoom(next)
    }

    private func wireCallbacks() {
        toolbar.onToolSelected = { [weak self] tool in self?.canvas.currentTool = tool }
        toolbar.onArrowStyleSelected = { [weak self] style in
            self?.canvas.currentArrowStyle = style
        }
        toolbar.onColorSelected = { [weak self] color in self?.canvas.currentColor = color }
        toolbar.onWidthSelected = { [weak self] width in self?.canvas.setWidth(width) }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        toolbar.onRedo = { [weak self] in self?.canvas.redo() }
        actionBar.onZoomOut = { [weak self] in self?.changeZoom(multiplier: 0.8) }
        actionBar.onZoomIn = { [weak self] in self?.changeZoom(multiplier: 1.25) }
        actionBar.onFit = { [weak self] in
            self?.fitMode = true
            self?.applyFitMagnification()
        }
        actionBar.onCancel = { [weak self] in self?.cancel() }
        actionBar.onSave = { [weak self] in self?.save() }
        actionBar.onConfirm = { [weak self] in self?.confirm() }
        actionBar.onPin = { [weak self] in self?.pin() }

        canvas.onConfirm = { [weak self] in self?.confirm() }
        canvas.onCancel = { [weak self] in self?.cancel() }
        canvas.onSave = { [weak self] in self?.save() }
        canvas.onHistoryStateChange = { [weak self] canUndo, canRedo in
            self?.toolbar.setHistoryEnabled(canUndo: canUndo, canRedo: canRedo)
        }
        // 绘制工具按 Esc 退出时，画布与工具栏同步回“选择/移动”。
        canvas.onRequestToolSwitch = { [weak self] tool in
            self?.canvas.currentTool = tool
            self?.toolbar.setSelectedTool(tool)
        }
    }

    // MARK: - 输出动作

    /// ✓ / Enter：合成 → 复制剪贴板（PNG+TIFF）→ 关闭
    private func confirm() {
        ImageComposer.copyToPasteboard(
            base: baseCGImage, pixelScale: pixelScale, annotations: canvas.annotations
        )
        ToastWindow.show(message: "已复制到剪贴板")
        closeWindow()
    }

    /// 💾：合成 → NSSavePanel 存 PNG → 保存成功后关闭
    private func save() {
        ImageComposer.savePNGWithPanel(
            base: baseCGImage, pixelScale: pixelScale, annotations: canvas.annotations
        ) { [weak self] saved in
            if saved {
                ToastWindow.show(message: "已保存 PNG")
                self?.closeWindow()
            }
        }
    }

    /// 📌：合成当前编辑结果 → 钉成桌面最前端的浮动图窗（编辑器保持打开）
    private func pin() {
        guard let rep = ImageComposer.composedRep(
            base: baseCGImage, pixelScale: pixelScale, annotations: canvas.annotations
        ), let composed = rep.cgImage else { return }
        if PinWindowController.pin(image: composed, pixelScale: pixelScale) {
            ToastWindow.show(message: "已钉图")
        }
    }

    /// ✕ / Esc：放弃，不输出
    private func cancel() {
        closeWindow()
    }

    /// 只 orderOut 不 close；0.3s+ 后再释放引用（窗口生命周期安全约束）
    private func closeWindow() {
        guard !isClosing else { return }
        isClosing = true
        window?.orderOut(nil)
        notifyDismissIfNeeded()
        let win = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            _ = win // 延长窗口活到事件循环排空之后
            self?.window = nil
            guard let self else { return }
            if let owner = self.owner {
                if EditorWindowController.ownedEditors[owner] === self {
                    EditorWindowController.ownedEditors.removeValue(forKey: owner)
                }
            } else if EditorWindowController.unownedEditors[self.editorID] === self {
                EditorWindowController.unownedEditors.removeValue(forKey: self.editorID)
            }
        }
    }

    private func notifyDismissIfNeeded() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        if let owner {
            onDismiss?(owner)
        }
    }
}

// MARK: - 窗口 resize → 画布自适应

extension EditorWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let contentView = window?.contentView else { return }
        layoutContents(contentSize: contentView.bounds.size)
        if fitMode { applyFitMagnification() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow()
        return false
    }
}

/// 标准编辑器窗口。红色关闭按钮由 delegate 转成 orderOut，绝不直接 close 释放。
class EditorWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = NSColor(white: 0.12, alpha: 1)
        level = .normal
        hasShadow = true
        // P0 修复：关闭背景拖动。开着时 padding/工具栏空隙甚至画布本身
        // （NSView.mouseDownCanMoveWindow 默认 true）都会被当成窗口拖拽
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false // 硬约束：不用 close() 释放窗口
    }
}

/// 文档小于 viewport 时保持居中；大于 viewport 时保持正常滚动原点。
final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if documentView.frame.width < rect.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if documentView.frame.height < rect.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// 只把用户的触控板捏合标记为手动缩放；程序化“适合窗口”不会误关 fitMode。
final class EditorScrollView: NSScrollView {
    var onMagnificationGesture: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnificationGesture?(magnification)
    }
}

/// 编辑器 viewport 几何（纯函数，供布局与回归测试共用）。
enum EditorViewportLayout {
    enum FitMode { case window, width }

    static func initialContentSize(imageSize: CGSize, visibleScreenSize: CGSize) -> CGSize {
        let maxSize = CGSize(width: visibleScreenSize.width * 0.86,
                             height: visibleScreenSize.height * 0.86)
        let preferred = CGSize(width: max(800, min(imageSize.width, 1120)),
                               height: max(600, min(imageSize.height, 760)))
        return CGSize(width: min(preferred.width, maxSize.width),
                      height: min(preferred.height, maxSize.height))
    }

    static func fitMagnification(
        imageSize: CGSize,
        viewportSize: CGSize,
        mode: FitMode
    ) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let widthScale = max(0.01, (viewportSize.width - 24) / imageSize.width)
        let heightScale = max(0.01, (viewportSize.height - 24) / imageSize.height)
        let raw = mode == .width ? widthScale : min(widthScale, heightScale)
        return min(max(raw, 0.25), 4)
    }
}
