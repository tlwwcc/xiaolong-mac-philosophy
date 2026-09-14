import AppKit

/// 截图选区必须保留 Retina 原始像素。nominalResolution 会把 2x 屏幕冻结成 1x 点尺寸，
/// 再铺回全屏时必然发糊；bestResolution 配合无插值预览，只做纯色暗化，不改底图细节。
enum ScreenCaptureRasterPolicy {
    static let pixelAccurateOptions: CGWindowImageOption = [
        .boundsIgnoreFraming,
        .bestResolution,
    ]
    static let previewInterpolation: NSImageInterpolation = .none
}

/// 选区启动前冻结的一块屏幕。截图 API 返回像素图，cgScreenRect 使用全局 CG 点坐标。
struct FrozenScreenCapture {
    let cgScreenRect: CGRect
    let image: CGImage

    func cropped(to region: CGRect) -> CGImage? {
        let intersection = region.intersection(cgScreenRect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0,
              cgScreenRect.width > 0, cgScreenRect.height > 0 else { return nil }

        let scaleX = CGFloat(image.width) / cgScreenRect.width
        let scaleY = CGFloat(image.height) / cgScreenRect.height
        let pixelRect = CGRect(
            x: (intersection.minX - cgScreenRect.minX) * scaleX,
            y: (intersection.minY - cgScreenRect.minY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return image.cropping(to: pixelRect)
    }
}

struct RegionSelectionResult {
    let region: CGRect
    /// 菜单/弹层可能在 App 激活后消失；非长截图应优先使用这张冻结裁图。
    let frozenImage: CGImage?
    /// 选区出现前的前台进程，仅在精确窗口解析失败时作为普通截图的兜底。
    /// 长截图必须同时取得 sourceWindowID，不再依赖 frontmost 状态识别目标。
    let sourceProcessIdentifier: pid_t?
    /// 选区下最前面的普通窗口。长截图用它建立精确 ScreenCaptureKit 过滤器，
    /// 不再把宿主边框、预览或其他 App 混进实时帧。
    let sourceWindowID: CGWindowID?
}

/// 选区启动前按窗口层级冻结的普通窗口。区域确认后用它找出选区下真正的 App，
/// 而不是假定触发快捷键时的前台 App 一定就是滚动目标。
struct RegionSelectionWindowCandidate: Equatable {
    let ownerProcessIdentifier: pid_t
    let windowID: CGWindowID
    let bounds: CGRect
}

enum RegionSelectionSourceResolver {
    static func preferredCandidate(
        for region: CGRect,
        candidates: [RegionSelectionWindowCandidate],
        hostProcessIdentifier: pid_t
    ) -> RegionSelectionWindowCandidate? {
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        let center = CGPoint(x: region.midX, y: region.midY)
        if let centered = candidates.first(where: { $0.bounds.contains(center) }) {
            return centered.ownerProcessIdentifier == hostProcessIdentifier ? nil : centered
        }

        let candidate = candidates
            .compactMap { candidate -> (RegionSelectionWindowCandidate, CGFloat)? in
                let intersection = candidate.bounds.intersection(region)
                guard !intersection.isNull, !intersection.isEmpty else { return nil }
                return (candidate, intersection.width * intersection.height)
            }
            .max { $0.1 < $1.1 }?.0
        guard candidate?.ownerProcessIdentifier != hostProcessIdentifier else { return nil }
        return candidate
    }

    static func preferredProcessIdentifier(
        for region: CGRect,
        candidates: [RegionSelectionWindowCandidate],
        fallback: pid_t?,
        hostProcessIdentifier: pid_t
    ) -> pid_t? {
        preferredCandidate(
            for: region,
            candidates: candidates,
            hostProcessIdentifier: hostProcessIdentifier
        )?.ownerProcessIdentifier ?? fallback
    }
}

/// 多屏选区控制器：每个 NSScreen 一个遮罩窗口，选区限制在单屏内（简单可靠）。
/// 选区回调给出的 CGRect 是全局 CG 坐标（左上原点），可直接传给 CGWindowListCreateImage。
/// keepOverlayOnSelection=true 时（原图翻译原地覆盖模式），选区完成后灰屏保留进入评审态：
/// 选区高亮冻结消失，Esc 与空白点击改投 enterReviewMode 设置的回调。
class RegionSelectionController {
    private var windows: [RegionSelectionOverlay] = []
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    private var hasFinished = false
    private var sourceProcessIdentifier: pid_t?
    private var sourceWindowCandidates: [RegionSelectionWindowCandidate] = []

    private let keepOverlayOnSelection: Bool
    private let showCrosshair: Bool
    private let spaceConfirmsSelection: Bool
    private let confirmOnMouseUp: Bool
    private let confirmationActionTitle: String?
    private let blocksScrollBeforeConfirmation: Bool
    private let confirmationHint: String
    private let onSelection: (RegionSelectionResult) -> Void
    private let onCancel: () -> Void
    private var reviewCancelHandler: (() -> Void)?
    private var reviewSuspendedForSystemUI = false
    private var isDismissed = false

    init(
        keepOverlayOnSelection: Bool = false,
        showCrosshair: Bool = false,
        spaceConfirmsSelection: Bool = false,
        confirmOnMouseUp: Bool = false,
        confirmationActionTitle: String? = nil,
        blocksScrollBeforeConfirmation: Bool = false,
        confirmationHint: String = "空格 / 回车 / 双击确认 · 拖动调整",
        onSelection: @escaping (RegionSelectionResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.keepOverlayOnSelection = keepOverlayOnSelection
        self.showCrosshair = showCrosshair
        self.spaceConfirmsSelection = spaceConfirmsSelection
        self.confirmOnMouseUp = confirmOnMouseUp
        self.confirmationActionTitle = confirmationActionTitle
        self.blocksScrollBeforeConfirmation = blocksScrollBeforeConfirmation
        self.confirmationHint = confirmationHint
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func show() {
        // 必须先冻结。选区遮罩使用 nonactivatingPanel，不再激活宿主；冻结画面仍用于
        // 选区背景和最终首帧，保证菜单/弹层内容与确认时刻一致。
        sourceProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        sourceWindowCandidates = Self.visibleSourceWindowCandidates()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let frozenScreens: [(NSScreen, FrozenScreenCapture?)] = NSScreen.screens.map { screen in
            let cgRect = Self.cgScreenRect(for: screen, primaryHeight: primaryHeight)
            let image = CGWindowListCreateImage(
                cgRect, .optionOnScreenOnly, kCGNullWindowID,
                ScreenCaptureRasterPolicy.pixelAccurateOptions
            )
            return (screen, image.map { FrozenScreenCapture(cgScreenRect: cgRect, image: $0) })
        }

        // 每个屏幕一个遮罩窗口，各自处理本屏内的拖拽选区
        for (screen, frozenScreen) in frozenScreens {
            let overlay = RegionSelectionOverlay(
                screen: screen,
                frozenImage: frozenScreen?.image,
                showCrosshair: showCrosshair,
                spaceConfirmsSelection: spaceConfirmsSelection,
                confirmOnMouseUp: confirmOnMouseUp,
                confirmationActionTitle: confirmationActionTitle,
                blocksScrollBeforeConfirmation: blocksScrollBeforeConfirmation,
                confirmationHint: confirmationHint,
                onSelection: { [weak self] rect in
                    self?.finish(selection: rect, frozenScreen: frozenScreen)
                },
                onCancel: { [weak self] in self?.finish(selection: nil, frozenScreen: nil) }
            )
            windows.append(overlay)
        }

        // 一次性全部前置，避免逐屏闪烁；鼠标所在屏的窗口作为 key window
        for overlay in windows { overlay.orderFrontRegardless() }
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        let keyOverlay = windows.first(where: { $0.screen == mouseScreen }) ?? windows.first
        keyOverlay?.makeKey()
        keyOverlay?.makeFirstResponder(keyOverlay?.contentView)

        // Escape 监听：key window 可能不在鼠标所在屏，用本地+全局双监听兜底
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.reviewSuspendedForSystemUI != true { // Escape
                self?.handleEscape()
                return nil
            }
            return event
        }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscape()
            }
        }
    }

    /// 评审态（原图翻译原地覆盖）：Esc 与空白点击统一走这个回调。
    /// 由会话方在 onSelection 之后调用。
    func enterReviewMode(onReviewCancel: @escaping () -> Void) {
        reviewCancelHandler = onReviewCancel
        for window in windows {
            (window.contentView as? SelectionView)?.onBlankClick = onReviewCancel
        }
    }

    /// 系统下载/语言选择必须露出且接收键鼠；保留冻结截图，只暂隐评审遮罩。
    func setReviewSuspendedForSystemUI(_ suspended: Bool) {
        guard hasFinished, reviewCancelHandler != nil, !isDismissed else { return }
        reviewSuspendedForSystemUI = suspended
        for window in windows {
            if suspended { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
    }

    private func handleEscape() {
        guard !reviewSuspendedForSystemUI else { return }

        if hasFinished {
            // 评审态：选区已完成，Esc = 退出评审
            reviewCancelHandler?()
        } else {
            finish(selection: nil, frozenScreen: nil)
        }
    }

    /// 只隐藏窗口，不 close —— 回调可能还在 mouseUp/keyDown 事件处理栈里，
    /// 真正的释放（外部置 nil）由调用方延迟 0.3s+ 再做
    func dismiss() {
        isDismissed = true
        reviewSuspendedForSystemUI = false
        if let monitor = escLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escLocalMonitor = nil
        }
        if let monitor = escGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escGlobalMonitor = nil
        }
        for overlay in windows {
            overlay.orderOut(nil)
        }
    }

    private func finish(selection rect: CGRect?, frozenScreen: FrozenScreenCapture?) {
        // 本地/全局监听 + SelectionView 回调可能重复触发，只放行第一次
        guard !hasFinished else { return }
        hasFinished = true

        if rect != nil, keepOverlayOnSelection {
            // 原地覆盖模式：灰屏保留进入评审态 —— 冻结选区（高亮消失），
            // 不 dismiss；Esc/空白点击由 enterReviewMode 的回调接管
            for window in windows {
                (window.contentView as? SelectionView)?.freezeSelection()
            }
            if let rect = rect {
                let selectedSource = RegionSelectionSourceResolver.preferredCandidate(
                    for: rect,
                    candidates: sourceWindowCandidates,
                    hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier
                )
                onSelection(RegionSelectionResult(
                    region: rect,
                    frozenImage: frozenScreen?.cropped(to: rect),
                    sourceProcessIdentifier: selectedSource?.ownerProcessIdentifier
                        ?? sourceProcessIdentifier,
                    sourceWindowID: selectedSource?.windowID
                ))
            }
        } else {
            dismiss()
            if let rect = rect {
                let selectedSource = RegionSelectionSourceResolver.preferredCandidate(
                    for: rect,
                    candidates: sourceWindowCandidates,
                    hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier
                )
                onSelection(RegionSelectionResult(
                    region: rect,
                    frozenImage: frozenScreen?.cropped(to: rect),
                    sourceProcessIdentifier: selectedSource?.ownerProcessIdentifier
                        ?? sourceProcessIdentifier,
                    sourceWindowID: selectedSource?.windowID
                ))
            } else {
                onCancel()
            }
        }
    }

    static func cgScreenRect(for screen: NSScreen, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    static func visibleSourceWindowCandidates() -> [RegionSelectionWindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windowInfo.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 8, bounds.height >= 8 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 { return nil }
            return RegionSelectionWindowCandidate(
                ownerProcessIdentifier: pid_t(owner.int32Value),
                windowID: CGWindowID(windowNumber.uint32Value),
                bounds: bounds
            )
        }
    }
}

// MARK: - 单屏遮罩窗口

/// 单个屏幕的全屏透明遮罩窗口（borderless，frame 与屏幕 frame 完全重合）
private class RegionSelectionOverlay: NSPanel {
    private let selectionView: SelectionView

    // borderless 窗口默认不能成为 key window，必须覆盖以接收键盘事件
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, frozenImage: CGImage?, showCrosshair: Bool,
         spaceConfirmsSelection: Bool, confirmOnMouseUp: Bool,
         confirmationActionTitle: String?, blocksScrollBeforeConfirmation: Bool,
         confirmationHint: String,
         onSelection: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selectionView.frozenImage = frozenImage.map {
            NSImage(cgImage: $0, size: screen.frame.size)
        }
        selectionView.showCrosshair = showCrosshair
        selectionView.spaceConfirmsSelection = spaceConfirmsSelection
        selectionView.confirmOnMouseUp = confirmOnMouseUp
        selectionView.confirmationActionTitle = confirmationActionTitle
        selectionView.blocksScrollBeforeConfirmation = blocksScrollBeforeConfirmation
        selectionView.confirmationHint = confirmationHint

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        hasShadow = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true // 十字准星需要非 key 窗口也收 mouseMoved
        isReleasedWhenClosed = false  // close() 不立即释放窗口，避免事件处理中野指针
        contentView = selectionView

        selectionView.onDragComplete = onSelection
        selectionView.onEscape = onCancel
    }
}

// MARK: - 选区绘制视图

class SelectionView: NSView {
    var onDragComplete: ((CGRect) -> Void)?
    var onEscape: (() -> Void)?
    /// 评审态：选区冻结后，空白处单击的回调（由控制器接线）
    var onBlankClick: (() -> Void)?
    /// 选区激活前的屏幕快照；确保菜单/弹层即使被系统收起仍可见、可选。
    var frozenImage: NSImage?
    /// 是否显示十字准星（quickSnapshot / screenshotEdit 模式启用）
    var showCrosshair = false
    /// 需要复核边界的截图可用空格、回车或选区内双击确认。
    var spaceConfirmsSelection = false
    /// 原图翻译专用：框选松手后直接执行，不增加确认动作。
    var confirmOnMouseUp = false
    /// 需要二次调整的长截图使用可见按钮开始，空格只作为辅助快捷键。
    var confirmationActionTitle: String?
    /// 在截图会话建立前吃掉滚轮，避免页面已动但并未采样的假运行态。
    var blocksScrollBeforeConfirmation = false
    var confirmationHint = "空格 / 回车 / 双击确认 · 拖动调整"
    /// 准星位置（视图坐标；越界值在绘制时钳制）
    var crosshairPoint: CGPoint? {
        didSet { if showCrosshair { needsDisplay = true } }
    }

    private enum Interaction {
        case none
        case selecting(anchor: CGPoint)
        case moving(anchor: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
        case pressingConfirmation
    }

    private(set) var currentRect: CGRect = .zero
    private var interaction: Interaction = .none
    private(set) var isSelectionLocked = false
    /// 锁住一次选区的提交边界：按键重复、双击尾随 mouseUp 与按钮事件最多放行一次。
    private(set) var hasSubmittedSelection = false
    /// 冻结后不再接受新选区，draw 也不再显示高亮（只剩灰屏）
    private var isFrozen = false

    override var acceptsFirstResponder: Bool { true }

    // MARK: - 准星鼠标跟踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard showCrosshair else { return }
        crosshairPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseExited(with event: NSEvent) {
        crosshairPoint = nil
    }

    /// 进入评审态：选区高亮消失，只留灰屏
    func freezeSelection() {
        isFrozen = true
        interaction = .none
        isSelectionLocked = false
        currentRect = .zero
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage {
            let context = NSGraphicsContext.current
            let previousInterpolation = context?.imageInterpolation
            context?.imageInterpolation = ScreenCaptureRasterPolicy.previewInterpolation
            frozenImage.draw(
                in: bounds,
                from: NSRect(origin: .zero, size: frozenImage.size),
                operation: .copy,
                fraction: 1
            )
            if let previousInterpolation {
                context?.imageInterpolation = previousInterpolation
            }
        }
        let hasSelection = !isFrozen && currentRect.width > 1 && currentRect.height > 1
        drawDimOverlay(excluding: hasSelection ? currentRect : nil)

        // 十字准星：未拖拽、未冻结时跟随鼠标（拖拽中只剩选区框）
        if showCrosshair, !hasSelection, !isFrozen, let point = crosshairPoint {
            drawCrosshair(at: point)
        }

        guard hasSelection else { return }

        // 选区边框
        NSColor.white.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1
        border.stroke()

        if isSelectionLocked {
            drawHandles()
        }

        // 尺寸标注
        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let attrLabel = NSAttributedString(string: label, attributes: attrs)
        let labelSize = attrLabel.size()
        let labelOrigin = SelectionGeometry.labelOrigin(
            preferred: NSPoint(x: currentRect.midX - labelSize.width / 2, y: currentRect.maxY + 7),
            labelSize: labelSize,
            within: bounds.insetBy(dx: 4, dy: 4)
        )
        attrLabel.draw(at: labelOrigin)

        if isSelectionLocked {
            drawConfirmationHint()
        }
    }

    private func drawDimOverlay(excluding selection: CGRect?) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        guard let selection else {
            bounds.fill()
            return
        }
        let rect = selection.intersection(bounds)
        NSRect(x: bounds.minX, y: bounds.minY,
               width: bounds.width, height: max(0, rect.minY - bounds.minY)).fill()
        NSRect(x: bounds.minX, y: rect.maxY,
               width: bounds.width, height: max(0, bounds.maxY - rect.maxY)).fill()
        NSRect(x: bounds.minX, y: rect.minY,
               width: max(0, rect.minX - bounds.minX), height: rect.height).fill()
        NSRect(x: rect.maxX, y: rect.minY,
               width: max(0, bounds.maxX - rect.maxX), height: rect.height).fill()
    }

    private func drawHandles() {
        for handle in SelectionHandle.allCases {
            let rect = SelectionGeometry.handleRect(for: handle, in: currentRect)
            NSColor.black.withAlphaComponent(0.35).setFill()
            rect.insetBy(dx: -1, dy: -1).fill()
            NSColor.white.setFill()
            rect.fill()
        }
    }

    private func drawConfirmationHint() {
        if let confirmationActionTitle {
            drawConfirmationAction(title: confirmationActionTitle)
            return
        }
        let text = confirmationHint
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.76),
        ]
        let hint = NSAttributedString(string: text, attributes: attrs)
        let size = hint.size()
        let preferredY = currentRect.minY - size.height - 8
        let fallbackY = currentRect.maxY + 8
        let origin = SelectionGeometry.labelOrigin(
            preferred: NSPoint(
                x: currentRect.midX - size.width / 2,
                y: preferredY >= bounds.minY + 4 ? preferredY : fallbackY
            ),
            labelSize: size,
            within: bounds.insetBy(dx: 4, dy: 4)
        )
        hint.draw(at: origin)
    }

    private func drawConfirmationAction(title: String) {
        let actionRect = confirmationActionRect
        let isPressed: Bool
        if case .pressingConfirmation = interaction {
            isPressed = true
        } else {
            isPressed = false
        }

        let button = NSBezierPath(roundedRect: actionRect, xRadius: 8, yRadius: 8)
        (isPressed
            ? NSColor.controlAccentColor.withAlphaComponent(0.72)
            : NSColor.controlAccentColor.withAlphaComponent(0.96)).setFill()
        button.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        button.lineWidth = 1
        button.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributedTitle = NSAttributedString(string: title, attributes: titleAttributes)
        let titleSize = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(
            x: actionRect.midX - titleSize.width / 2,
            y: actionRect.midY - titleSize.height / 2
        ))

        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let hint = NSAttributedString(string: confirmationHint, attributes: hintAttributes)
        let hintSize = hint.size()
        let preferredBelow = actionRect.minY - hintSize.height - 5
        let preferredAbove = actionRect.maxY + 5
        let hintOrigin = SelectionGeometry.labelOrigin(
            preferred: NSPoint(
                x: actionRect.midX - hintSize.width / 2,
                y: preferredBelow >= bounds.minY + 4 ? preferredBelow : preferredAbove
            ),
            labelSize: hintSize,
            within: bounds.insetBy(dx: 4, dy: 4)
        )
        hint.draw(at: hintOrigin)
    }

    var confirmationActionRect: CGRect {
        SelectionConfirmationLayout.actionRect(for: currentRect, within: bounds)
    }

    // MARK: - 十字准星绘制

    /// 全屏十字参考线：1 物理像素细线（按 backingScale 对齐半点防模糊），
    /// 深色描边+白色主线保证深浅背景都可见，交点旁显示坐标小标签。
    private func drawCrosshair(at point: CGPoint) {
        // NaN/Inf 直接拒画（Swift min/max 不能保证滤掉 NaN，NSBezierPath 遇 NaN 会抛异常）
        guard point.x.isFinite, point.y.isFinite else { return }
        let scale = window?.screen?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        // 钳制到 bounds 内（越界/无穷输入不会画出界）
        let px = min(max(point.x, bounds.minX), bounds.maxX)
        let py = min(max(point.y, bounds.minY), bounds.maxY)
        // 像素对齐：落到物理像素中心（半点）
        let snapX = (round(px * scale) + 0.5) / scale
        let snapY = (round(py * scale) + 0.5) / scale

        // 底层深色描边
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let shadow = NSBezierPath()
        shadow.lineWidth = lineWidth * 3
        shadow.move(to: NSPoint(x: bounds.minX, y: snapY))
        shadow.line(to: NSPoint(x: bounds.maxX, y: snapY))
        shadow.move(to: NSPoint(x: snapX, y: bounds.minY))
        shadow.line(to: NSPoint(x: snapX, y: bounds.maxY))
        shadow.stroke()

        // 主线
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = lineWidth
        cross.move(to: NSPoint(x: bounds.minX, y: snapY))
        cross.line(to: NSPoint(x: bounds.maxX, y: snapY))
        cross.move(to: NSPoint(x: snapX, y: bounds.minY))
        cross.line(to: NSPoint(x: snapX, y: bounds.maxY))
        cross.stroke()

        // 坐标小标签（钳制在屏内）
        let label = "\(Int(px)), \(Int(py))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        let attrLabel = NSAttributedString(string: label, attributes: attrs)
        let labelSize = attrLabel.size()
        let labelX = min(px + 12, bounds.maxX - labelSize.width - 4)
        let labelY = max(py + 10, bounds.minY + 4)
        attrLabel.draw(at: NSPoint(x: labelX, y: labelY))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseDown(
            at: convert(event.locationInWindow, from: nil),
            clickCount: event.clickCount
        )
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if SelectionPreflightInputPolicy.consumesScroll(
            blocksScrollBeforeConfirmation: blocksScrollBeforeConfirmation,
            isFrozen: isFrozen
        ) {
            needsDisplay = true
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - 可测试的两阶段选区状态机

    func handleMouseDown(at point: CGPoint, clickCount: Int) {
        if isFrozen {
            onBlankClick?()
            return
        }
        let point = SelectionGeometry.clamped(point, within: bounds)
        if isSelectionLocked {
            if clickCount >= 2, currentRect.contains(point) {
                interaction = .none
                confirmSelection()
                return
            }
            if confirmationActionTitle != nil, confirmationActionRect.contains(point) {
                interaction = .pressingConfirmation
            } else if let handle = SelectionGeometry.hitHandle(at: point, in: currentRect) {
                interaction = .resizing(handle: handle, original: currentRect)
            } else if currentRect.contains(point) {
                interaction = .moving(anchor: point, original: currentRect)
            } else {
                currentRect = .zero
                isSelectionLocked = false
                interaction = .selecting(anchor: point)
            }
        } else {
            currentRect = .zero
            interaction = .selecting(anchor: point)
        }
        needsDisplay = true
    }

    func handleMouseDragged(to point: CGPoint) {
        let point = SelectionGeometry.clamped(point, within: bounds)
        switch interaction {
        case .selecting(let anchor):
            currentRect = SelectionGeometry.normalized(from: anchor, to: point, within: bounds)
        case .moving(let anchor, let original):
            currentRect = SelectionGeometry.moved(
                original, by: CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y), within: bounds
            )
        case .resizing(let handle, let original):
            currentRect = SelectionGeometry.resized(
                original, handle: handle, to: point, within: bounds
            )
        case .pressingConfirmation:
            needsDisplay = true
            return
        case .none:
            return
        }
        needsDisplay = true
    }

    func handleMouseUp(at point: CGPoint) {
        if case .pressingConfirmation = interaction {
            let releasePoint = SelectionGeometry.clamped(point, within: bounds)
            let confirms = confirmationActionRect.contains(releasePoint)
            interaction = .none
            needsDisplay = true
            if confirms { confirmSelection() }
            return
        }
        handleMouseDragged(to: point) // 终稿永远采用释放点，防止快甩时偏移
        switch interaction {
        case .selecting:
            isSelectionLocked = currentRect.width >= SelectionGeometry.minimumSize
                && currentRect.height >= SelectionGeometry.minimumSize
            if !isSelectionLocked { currentRect = .zero }
        case .moving, .resizing:
            isSelectionLocked = true
        case .pressingConfirmation:
            break
        case .none:
            break
        }
        interaction = .none
        needsDisplay = true
        if confirmOnMouseUp, isSelectionLocked {
            confirmSelection()
        }
    }

    private func confirmSelection() {
        guard !hasSubmittedSelection,
              isSelectionLocked, currentRect.width >= SelectionGeometry.minimumSize,
              currentRect.height >= SelectionGeometry.minimumSize,
              let window = window else { return }
        hasSubmittedSelection = true

        // 坐标转换（多屏安全）：Y 轴翻转必须使用主屏高度。
        let windowOrigin = window.frame.origin
        let globalAppKitY = windowOrigin.y + currentRect.origin.y
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? window.screen?.frame.height
            ?? globalAppKitY + currentRect.height
        onDragComplete?(CGRect(
            x: windowOrigin.x + currentRect.origin.x,
            y: primaryHeight - globalAppKitY - currentRect.height,
            width: currentRect.width,
            height: currentRect.height
        ))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        switch keyCode {
        case let confirmationKey where spaceConfirmsSelection
            && SelectionConfirmationInputPolicy.isPlainConfirmationKey(
                keyCode: confirmationKey,
                modifiers: modifiers
            ):
            confirmSelection()
        case 123, 124, 125, 126: // 方向键微调
            guard isSelectionLocked else { return }
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let delta: CGVector
            switch keyCode {
            case 123: delta = CGVector(dx: -step, dy: 0)
            case 124: delta = CGVector(dx: step, dy: 0)
            case 125: delta = CGVector(dx: 0, dy: -step)
            default: delta = CGVector(dx: 0, dy: step)
            }
            currentRect = SelectionGeometry.moved(currentRect, by: delta, within: bounds)
            needsDisplay = true
        case 53: // Escape
            onEscape?()
        default:
            break
        }
    }
}

// MARK: - 选区几何（纯函数，供 UI 与测试共用）

enum SelectionPreflightInputPolicy {
    static func consumesScroll(
        blocksScrollBeforeConfirmation: Bool,
        isFrozen: Bool
    ) -> Bool {
        blocksScrollBeforeConfirmation && !isFrozen
    }
}

enum SelectionConfirmationInputPolicy {
    static let confirmationKeyCodes: Set<UInt16> = [36, 49, 76]

    static func isPlainConfirmationKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard confirmationKeyCodes.contains(keyCode) else { return false }
        let shortcutModifiers: NSEvent.ModifierFlags = [
            .shift, .control, .option, .command, .function,
        ]
        return modifiers.intersection(shortcutModifiers).isEmpty
    }
}

enum SelectionConfirmationLayout {
    static let actionSize = CGSize(width: 148, height: 34)
    private static let edgeInset: CGFloat = 8
    private static let gap: CGFloat = 12

    static func actionRect(for selection: CGRect, within bounds: CGRect) -> CGRect {
        let available = bounds.insetBy(dx: edgeInset, dy: edgeInset)
        let width = min(actionSize.width, max(0, available.width))
        let height = min(actionSize.height, max(0, available.height))
        guard width > 0, height > 0 else { return .zero }

        let preferredBelow = selection.minY - height - gap
        let preferredAbove = selection.maxY + gap
        let y: CGFloat
        if preferredBelow >= available.minY {
            y = preferredBelow
        } else if preferredAbove + height <= available.maxY {
            y = preferredAbove
        } else {
            y = min(max(selection.minY + gap, available.minY), available.maxY - height)
        }
        let x = min(
            max(selection.midX - width / 2, available.minX),
            available.maxX - width
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum SelectionGeometry {
    static let minimumSize: CGFloat = 12
    private static let handleSize: CGFloat = 7
    private static let handleHitSlop: CGFloat = 5

    static func clamped(_ point: CGPoint, within bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    static func normalized(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        let a = clamped(start, within: bounds)
        let b = clamped(end, within: bounds)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func moved(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        var x = rect.minX + delta.dx
        var y = rect.minY + delta.dy
        x = min(max(x, bounds.minX), bounds.maxX - rect.width)
        y = min(max(y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }

    static func resized(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        let point = clamped(point, within: bounds)
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(point.x, maxX - minimumSize)
        case .topRight, .right, .bottomRight: maxX = max(point.x, minX + minimumSize)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: maxY = max(point.y, minY + minimumSize)
        case .bottomLeft, .bottom, .bottomRight: minY = min(point.y, maxY - minimumSize)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(bounds)
    }

    static func handleRect(for handle: SelectionHandle, in rect: CGRect) -> CGRect {
        let center: CGPoint
        switch handle {
        case .topLeft: center = CGPoint(x: rect.minX, y: rect.maxY)
        case .top: center = CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: center = CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: center = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: center = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: center = CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: center = CGPoint(x: rect.minX, y: rect.minY)
        case .left: center = CGPoint(x: rect.minX, y: rect.midY)
        }
        return CGRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2,
                      width: handleSize, height: handleSize)
    }

    static func hitHandle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        SelectionHandle.allCases.first {
            handleRect(for: $0, in: rect).insetBy(dx: -handleHitSlop, dy: -handleHitSlop).contains(point)
        }
    }

    static func labelOrigin(preferred: CGPoint, labelSize: CGSize, within bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(preferred.x, bounds.minX), max(bounds.minX, bounds.maxX - labelSize.width)),
            y: min(max(preferred.y, bounds.minY), max(bounds.minY, bounds.maxY - labelSize.height))
        )
    }
}
