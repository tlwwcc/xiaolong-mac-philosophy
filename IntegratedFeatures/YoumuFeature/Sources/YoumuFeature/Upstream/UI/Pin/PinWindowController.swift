import AppKit

/// 钉图右上角的直接动作。顺序同时也是界面从左到右的顺序。
enum PinWindowAction: CaseIterable {
    case saveAs
    case copy
    case edit
    case close

    var symbolName: String {
        switch self {
        case .saveAs: return "internaldrive.fill"
        case .copy: return "doc.on.doc"
        case .edit: return "pencil"
        case .close: return "xmark"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .saveAs: return "另存为 PNG"
        case .copy: return "复制图片"
        case .edit: return "编辑标注"
        case .close: return "关闭定图"
        }
    }
}

/// 钉图外观与可操作区域的稳定契约，测试通过这些值防止回退为无操作按钮或浅阴影。
enum PinWindowStyle {
    static let shadowInset: CGFloat = 24
    static let shadowOpacity: Float = 0.52
    static let shadowRadius: CGFloat = 22
    static let shadowOffset = NSSize(width: 0, height: -9)
    static let imageCornerRadius: CGFloat = 6
    static let minimumImageSize = NSSize(width: 120, height: 60)

    static var minimumWindowSize: NSSize {
        NSSize(
            width: minimumImageSize.width + shadowInset * 2,
            height: minimumImageSize.height + shadowInset * 2
        )
    }
}

/// A decoded clipboard image already occupies memory before it reaches us. This second gate keeps
/// the long-lived pin collection from retaining an attacker-sized bitmap or growing without bound.
enum PinImageBudget {
    static let maximumInputDimension = 32_768
    static let maximumInputPixelCount = 64 * 1_024 * 1_024
    static let maximumRetainedDimension = 8_192
    static let maximumRetainedPixelCount = 16 * 1_024 * 1_024
    static let maximumRetainedBytes = 64 * 1_024 * 1_024
    static let maximumTotalRetainedBytes = 256 * 1_024 * 1_024
    static let maximumWindowCount = 8

    static func acceptsInputDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumInputDimension,
              height <= maximumInputDimension else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumInputPixelCount
    }

    static func retainedBytes(of image: CGImage) -> Int? {
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow ? nil : bytes
    }

    static func preparedImage(_ image: CGImage) -> CGImage? {
        guard acceptsInputDimensions(width: image.width, height: image.height) else { return nil }
        let pixels = image.width * image.height

        if image.width <= maximumRetainedDimension,
           image.height <= maximumRetainedDimension,
           pixels <= maximumRetainedPixelCount,
           let retained = retainedBytes(of: image),
           retained <= maximumRetainedBytes {
            return image
        }

        let dimensionScale = min(
            Double(maximumRetainedDimension) / Double(image.width),
            Double(maximumRetainedDimension) / Double(image.height)
        )
        let pixelScale = sqrt(Double(maximumRetainedPixelCount) / Double(pixels))
        let scale = min(1, dimensionScale, pixelScale)
        guard scale.isFinite, scale > 0 else { return nil }
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let prepared = context.makeImage(),
              let retained = retainedBytes(of: prepared),
              retained <= maximumRetainedBytes else { return nil }
        return prepared
    }
}

/// 定图初始尺寸：物理像素先按截图倍率还原为屏幕点，超屏时才同比缩小。
enum PinWindowInitialGeometry {
    static let maximumScreenCoverage: CGFloat = 0.95

    static func imageSize(
        pixelSize: NSSize,
        pixelScale: CGFloat,
        visibleScreenSize: NSSize,
        shadowInset: CGFloat = PinWindowStyle.shadowInset
    ) -> NSSize {
        let scale = ImagePasteboardMetadata.validPixelScale(pixelScale) ?? 1
        let pointSize = NSSize(
            width: max(1, pixelSize.width / scale),
            height: max(1, pixelSize.height / scale)
        )
        let windowInset = shadowInset * 2
        let maxWidth = max(1, visibleScreenSize.width * maximumScreenCoverage - windowInset)
        let maxHeight = max(1, visibleScreenSize.height * maximumScreenCoverage - windowInset)
        guard pointSize.width > maxWidth || pointSize.height > maxHeight else {
            return pointSize
        }
        let fitScale = min(maxWidth / pointSize.width, maxHeight / pointSize.height)
        return NSSize(
            width: floor(pointSize.width * fitScale),
            height: floor(pointSize.height * fitScale)
        )
    }
}

/// 右下角抓手的窗口几何。以图片可视区域为基准等比缩放，避免文字和标注变形。
enum PinWindowResizeGeometry {
    static func frame(
        initialFrame: NSRect,
        dragDelta: NSSize,
        minimumSize: NSSize = PinWindowStyle.minimumWindowSize
    ) -> NSRect {
        let inset = PinWindowStyle.shadowInset * 2
        let initialImageSize = NSSize(
            width: max(1, initialFrame.width - inset),
            height: max(1, initialFrame.height - inset)
        )
        let widthScale = (initialImageSize.width + dragDelta.width) / initialImageSize.width
        let heightScale = (initialImageSize.height - dragDelta.height) / initialImageSize.height
        let requestedScale = abs(widthScale - 1) >= abs(heightScale - 1) ? widthScale : heightScale
        let minimumScale = max(
            max(1, minimumSize.width - inset) / initialImageSize.width,
            max(1, minimumSize.height - inset) / initialImageSize.height
        )
        let scale = max(minimumScale, requestedScale)
        let width = initialImageSize.width * scale + inset
        let height = initialImageSize.height * scale + inset
        return NSRect(
            x: initialFrame.minX,
            y: initialFrame.maxY - height,
            width: width,
            height: height
        )
    }
}

enum PinWindowKeyboardShortcut {
    static func isCopy(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control)
        else { return false }
        return charactersIgnoringModifiers?.lowercased() == "c"
    }

    /// 只让纯 Esc 或纯 Command+W 关闭当前定图，避免抢占带修饰键的其他操作。
    static func isClose(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, charactersIgnoringModifiers == "\u{1B}" {
            return true
        }
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control)
        else { return false }
        return charactersIgnoringModifiers?.lowercased() == "w"
    }
}

/// 钉图：把图片贴成桌面最前端的浮动图窗。
/// 按实际点尺寸显示（超屏才等比收）；可拖动、等比缩放、保存、复制、编辑和关闭。
final class PinWindowController {

    private static var pins: [PinWindowController] = []
    private static var ownedPins: [CaptureCommandOwner: PinWindowController] = [:]

    @discardableResult
    static func pin(
        image: CGImage,
        pixelScale: CGFloat,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) -> Bool {
        guard pins.count < PinImageBudget.maximumWindowCount else {
            ToastWindow.show(message: "定图已达 8 张上限，请先关闭一张")
            return false
        }
        guard let preparedImage = PinImageBudget.preparedImage(image),
              let retainedBytes = PinImageBudget.retainedBytes(of: preparedImage),
              retainedBytes <= PinImageBudget.maximumRetainedBytes,
              pins.reduce(0, { $0 + $1.retainedBytes })
                <= PinImageBudget.maximumTotalRetainedBytes - retainedBytes else {
            ToastWindow.show(message: "图片过大，无法安全定图")
            return false
        }
        let controller = PinWindowController(
            image: preparedImage,
            pixelScale: pixelScale,
            retainedBytes: retainedBytes,
            owner: owner,
            onDismiss: onDismiss
        )
        pins.append(controller)
        if let owner {
            ownedPins[owner] = controller
        }
        controller.show()
        return true
    }

    /// 探测剪贴板并钉出其中的图片（菜单栏与 ⌃⌥⌘T 快捷键共用）。
    /// 返回是否有图钉出；false = 剪贴板没有图片（调用方给提示）。
    @discardableResult
    static func pinFromClipboard(
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        guard let nsImage = NSImage(pasteboard: pasteboard) else { return false }
        // Inspect cheap representation metadata before asking AppKit to materialize a CGImage. The
        // post-decode gate below remains authoritative, but this avoids eagerly decoding a known
        // attacker-sized clipboard bitmap first.
        let pixelRepresentations = nsImage.representations.filter {
            $0.pixelsWide > 0 && $0.pixelsHigh > 0
        }
        let pointSizeIsSafe = nsImage.size.width.isFinite && nsImage.size.height.isFinite
            && nsImage.size.width > 0 && nsImage.size.height > 0
            && nsImage.size.width <= CGFloat(PinImageBudget.maximumInputDimension)
            && nsImage.size.height <= CGFloat(PinImageBudget.maximumInputDimension)
        guard pointSizeIsSafe,
              pixelRepresentations.allSatisfy({
                  PinImageBudget.acceptsInputDimensions(
                    width: $0.pixelsWide,
                    height: $0.pixelsHigh
                  )
              }) else {
            ToastWindow.show(message: "图片过大，无法安全定图")
            if let owner { onDismiss?(owner) }
            return true
        }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let encodedScale = ImagePasteboardMetadata.pixelScale(from: pasteboard)
        let representationScale = nsImage.representations.first.flatMap { rep -> CGFloat? in
            guard rep.size.width > 0 else { return nil }
            return ImagePasteboardMetadata.validPixelScale(
                CGFloat(rep.pixelsWide) / rep.size.width
            )
        }
        let pixelScale = encodedScale ?? representationScale ?? 1
        let accepted = pin(
            image: cgImage,
            pixelScale: pixelScale,
            owner: owner,
            onDismiss: onDismiss
        )
        // A valid clipboard image that exceeds the safety budget is a handled request. Close its
        // command owner here so the outer toggle does not strand a presenting session or replace
        // the precise safety message with “剪贴板没有图片”.
        if !accepted, let owner {
            onDismiss?(owner)
        }
        return true
    }

    /// O(1) lookup that closes only the pin owned by this capture invocation.
    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard let controller = ownedPins[owner], !controller.isDismissing else { return false }
        controller.dismiss()
        return true
    }

    // MARK: - 内部

    private var window: PinWindow?
    private let image: CGImage
    private let pixelScale: CGFloat
    private let retainedBytes: Int
    private let owner: CaptureCommandOwner?
    private let onDismiss: ((CaptureCommandOwner) -> Void)?
    private var isDismissing = false
    private var didNotifyDismiss = false

    private init(
        image: CGImage,
        pixelScale: CGFloat,
        retainedBytes: Int,
        owner: CaptureCommandOwner?,
        onDismiss: ((CaptureCommandOwner) -> Void)?
    ) {
        self.image = image
        self.pixelScale = pixelScale
        self.retainedBytes = retainedBytes
        self.owner = owner
        self.onDismiss = onDismiss
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let imageSize = PinWindowInitialGeometry.imageSize(
            pixelSize: NSSize(width: image.width, height: image.height),
            pixelScale: pixelScale,
            visibleScreenSize: visible.size
        )
        let inset = PinWindowStyle.shadowInset
        let windowSize = NSSize(
            width: imageSize.width + inset * 2,
            height: imageSize.height + inset * 2
        )

        let container = PinDraggableView(frame: NSRect(origin: .zero, size: windowSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        // 透明窗内留出阴影缓冲区：自绘阴影比系统默认更暗，像图片贴在桌面上。
        let shadowHost = PinShadowHostView(frame: NSRect(
            x: inset, y: inset, width: imageSize.width, height: imageSize.height
        ))
        shadowHost.autoresizingMask = [.width, .height]
        container.addSubview(shadowHost)

        let imageView = PinDraggableImageView(frame: shadowHost.bounds)
        imageView.image = NSImage(cgImage: image, size: imageSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = PinWindowStyle.imageCornerRadius
        imageView.layer?.masksToBounds = true
        shadowHost.addSubview(imageView)

        addActionBar(to: container, windowSize: windowSize)

        let resizeHandle = PinResizeHandleView(frame: NSRect(
            x: windowSize.width - inset - 27,
            y: inset + 5,
            width: 22,
            height: 22
        ))
        resizeHandle.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(resizeHandle)

        let win = PinWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.onCopy = { [weak self] in self?.copyImage() }
        win.onClose = { [weak self] in self?.dismiss() }
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = false // 使用上面的可控暗色阴影，避免叠两层系统阴影
        win.isMovableByWindowBackground = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.minSize = PinWindowStyle.minimumWindowSize
        win.contentView = container

        // 落在鼠标附近，钳位在屏内。
        win.setFrameOrigin(NSPoint(
            x: min(max(mouse.x - windowSize.width / 2, visible.minX),
                   visible.maxX - windowSize.width),
            y: min(max(mouse.y - windowSize.height / 2, visible.minY),
                   visible.maxY - windowSize.height)
        ))
        win.orderFrontRegardless()
        window = win
    }

    private func addActionBar(to container: NSView, windowSize: NSSize) {
        let actions = PinWindowAction.allCases
        let buttonSize: CGFloat = 28
        let spacing: CGFloat = 4
        let padding: CGFloat = 4
        let separatorGap: CGFloat = 13
        let barWidth = CGFloat(actions.count) * buttonSize
            + CGFloat(actions.count - 2) * spacing
            + separatorGap + padding * 2
        let barHeight: CGFloat = 36
        let inset = PinWindowStyle.shadowInset

        let actionBar = NSView(frame: NSRect(
            x: windowSize.width - inset - barWidth - 7,
            y: windowSize.height - inset - barHeight - 7,
            width: barWidth,
            height: barHeight
        ))
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        actionBar.layer?.cornerRadius = barHeight / 2
        actionBar.layer?.borderWidth = 1
        actionBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        actionBar.layer?.shadowColor = NSColor.black.cgColor
        actionBar.layer?.shadowOpacity = 0.38
        actionBar.layer?.shadowRadius = 8
        actionBar.layer?.shadowOffset = NSSize(width: 0, height: -3)
        actionBar.autoresizingMask = [.minXMargin, .minYMargin]

        for (index, action) in actions.enumerated() {
            let x: CGFloat
            if index < 3 {
                x = padding + CGFloat(index) * (buttonSize + spacing)
            } else {
                x = barWidth - padding - buttonSize
            }
            let button = PinActionButton(frame: NSRect(
                x: x,
                y: (barHeight - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            ))
            button.isBordered = false
            button.image = NSImage(
                systemSymbolName: action.symbolName,
                accessibilityDescription: action.accessibilityTitle
            )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .white
            button.toolTip = action.accessibilityTitle
            button.setAccessibilityLabel(action.accessibilityTitle)
            button.target = self
            if action == .saveAs {
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.96).cgColor
                button.layer?.cornerRadius = buttonSize / 2
                button.layer?.shadowColor = NSColor.systemBlue.cgColor
                button.layer?.shadowOpacity = 0.42
                button.layer?.shadowRadius = 4
                button.layer?.shadowOffset = NSSize(width: 0, height: -1)
            } else if action == .close {
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
                button.layer?.cornerRadius = buttonSize / 2
            }
            switch action {
            case .saveAs: button.action = #selector(saveAsClicked)
            case .copy: button.action = #selector(copyClicked)
            case .edit: button.action = #selector(editClicked)
            case .close: button.action = #selector(closeClicked)
            }
            actionBar.addSubview(button)
        }
        let separator = NSView(frame: NSRect(
            x: barWidth - padding - buttonSize - separatorGap / 2,
            y: 10,
            width: 1,
            height: 16
        ))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        actionBar.addSubview(separator)
        container.addSubview(actionBar)
    }

    // MARK: - 直接动作

    @objc private func saveAsClicked() {
        ImageComposer.savePNGWithPanel(
            base: image, pixelScale: pixelScale, annotations: [], parentWindow: window
        ) { saved in
            if saved { ToastWindow.show(message: "定图已另存为 PNG") }
        }
    }

    @objc private func copyClicked() {
        copyImage()
    }

    private func copyImage() {
        ImageComposer.copyToPasteboard(base: image, pixelScale: pixelScale, annotations: [])
        ToastWindow.show(message: "定图已复制")
    }

    @objc private func editClicked() {
        if let owner {
            // Transfer the shortcut session atomically from Pin to Editor. Do not finish the
            // owner: a second press of the same Pin shortcut must close this downstream editor.
            guard EditorWindowController.show(
                image: image,
                pixelScale: pixelScale,
                owner: owner,
                onDismiss: onDismiss
            ) else { return }
            dismiss(notifyOwner: false)
        } else {
            // Menu/manual pins are intentionally outside the shortcut session family. Their
            // editors remain unowned and lifecycle invalidation must not close them.
            EditorWindowController.show(image: image, pixelScale: pixelScale)
            dismiss()
        }
    }

    @objc private func closeClicked() {
        dismiss()
    }

    private func dismiss(notifyOwner: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        let win = window
        win?.orderOut(nil)
        window = nil
        if notifyOwner {
            notifyDismissIfNeeded()
        } else {
            relinquishOwnerForTransfer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            _ = win
            if let self {
                PinWindowController.pins.removeAll { $0 === self }
            }
        }
    }

    private func relinquishOwnerForTransfer() {
        guard !didNotifyDismiss, let owner else { return }
        didNotifyDismiss = true
        if PinWindowController.ownedPins[owner] === self {
            PinWindowController.ownedPins.removeValue(forKey: owner)
        }
    }

    private func notifyDismissIfNeeded() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        if let owner {
            if PinWindowController.ownedPins[owner] === self {
                PinWindowController.ownedPins.removeValue(forKey: owner)
            }
            onDismiss?(owner)
        }
    }
}

/// borderless 钉图需要在用户点击后主动成为键盘窗口，才可接收 ⌘C；
/// 创建时仍只 orderFront，不抢走用户正在使用的 App 焦点。
final class PinWindow: NSWindow {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if PinWindowKeyboardShortcut.isClose(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
            onClose?()
            return true
        }
        if PinWindowKeyboardShortcut.isCopy(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if PinWindowKeyboardShortcut.isClose(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

/// 暗色立体阴影壳。图片自身在内部裁圆，阴影则不裁切。
final class PinShadowHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = PinWindowStyle.imageCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = PinWindowStyle.shadowOpacity
        layer?.shadowRadius = PinWindowStyle.shadowRadius
        layer?.shadowOffset = PinWindowStyle.shadowOffset
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: PinWindowStyle.imageCornerRadius,
            cornerHeight: PinWindowStyle.imageCornerRadius,
            transform: nil
        )
    }
}

/// 图片和透明边距均可拖定图；第一次点击同时让它成为 ⌘C 的目标。
final class PinDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.performDrag(with: event)
    }
}

final class PinDraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.performDrag(with: event)
    }
}

final class PinActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 可见的右下角缩放抓手；拖动时按窗口几何实时等比缩放图片。
final class PinResizeHandleView: NSView {
    private var initialFrame = NSRect.zero
    private var initialMouseLocation = NSPoint.zero

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动缩放定图"
        setAccessibilityLabel("缩放定图")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.height / 2).fill()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        for offset: CGFloat in [0, 4, 8] {
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: bounds.maxX - 6 - offset, y: bounds.minY + 4))
            path.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + 6 + offset))
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let delta = NSSize(
            width: current.x - initialMouseLocation.x,
            height: current.y - initialMouseLocation.y
        )
        window.setFrame(
            PinWindowResizeGeometry.frame(initialFrame: initialFrame, dragDelta: delta),
            display: true
        )
    }
}
