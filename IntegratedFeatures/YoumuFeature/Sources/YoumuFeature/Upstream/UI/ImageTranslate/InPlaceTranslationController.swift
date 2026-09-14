import AppKit
import UniformTypeIdentifiers

/// ⌃⌥⌘S 原图翻译 — 原地覆盖会话：
/// 选区完成后灰屏保留，后台走 截图→OCR→编号协议翻译→渲染，
/// 译文图用 borderless 面板精确贴在原选区屏幕坐标上，所见即所得。
/// Esc / 点击灰屏空白 / 点关闭 → 全部 orderOut + 延迟释放。
final class InPlaceTranslationController {

    /// 选区遮罩使用 screenSaver 层；翻译结果必须高于它，否则会被灰屏完全盖住。
    static let resultWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.screenSaver.rawValue + 1
    )
    static let controlWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.screenSaver.rawValue + 2
    )

    private enum Phase {
        case translating
        case showing
        case failed
    }

    private let region: CGRect // 全局 CG 坐标（点）
    private let prefetchedImage: CGImage?
    private let overlayController: RegionSelectionController
    private let onPresentationReady: () -> Bool
    private let onTeardownComplete: () -> Void

    private var phase: Phase = .translating
    private var tornDown = false
    private var didNotifyPresentationReady = false
    private var processingTask: Task<Void, Never>?
    private var processingRequestID = UUID()

    private var pixelScale: CGFloat = 2
    private var originalImage: CGImage?
    private var renderedImage: CGImage?
    private var showingOriginal = false

    private var hintPanel: NSPanel?
    private var hintLabel: NSTextField?
    private var imagePanel: NSPanel?
    private var imageView: NSImageView?
    private var widgetPanel: NSPanel?
    private var toggleButton: NSButton?

    /// - Parameters:
    ///   - region: 选区（全局 CG 点坐标）
    ///   - overlayController: 已冻结选区的灰屏遮罩（本会话接管其生命周期）
    ///   - onTeardownComplete: 释放完成后回调（调用方置 nil 引用）
    init(
        region: CGRect,
        prefetchedImage: CGImage? = nil,
        overlayController: RegionSelectionController,
        onPresentationReady: @escaping () -> Bool,
        onTeardownComplete: @escaping () -> Void
    ) {
        self.region = region
        self.prefetchedImage = prefetchedImage
        self.overlayController = overlayController
        self.onPresentationReady = onPresentationReady
        self.onTeardownComplete = onTeardownComplete
    }

    // MARK: - 启动（主线程）

    func start() {
        // Esc / 空白点击 → 退出评审
        overlayController.enterReviewMode { [weak self] in
            self?.teardown()
        }

        showHint(text: "正在翻译…", isError: false)

        // 优先使用选区启动前的冻结裁图，菜单/弹层即使因 App 激活而收起仍能翻译。
        // 冻结失败才在主线程回退实时截图（TCC 安全约束）。
        let image = prefetchedImage ?? CGWindowListCreateImage(
            region, .optionOnScreenOnly, kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
        guard let image else {
            showFailure("截图失败，请确认已授予屏幕录制权限")
            return
        }
        originalImage = image
        pixelScale = region.width > 0 ? CGFloat(image.width) / region.width : 2
        LastCaptureStore.shared.store(image, pixelScale: pixelScale)

        // OCR → 编号协议翻译 → 渲染（全部后台）
        processingTask?.cancel()
        let requestID = UUID()
        processingRequestID = requestID
        processingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let ocrResults = try await OCRService.shared.recognizeText(from: image)
                try Task.checkCancellation()
                guard !ocrResults.isEmpty else {
                    await MainActor.run {
                        guard !self.tornDown, self.processingRequestID == requestID else { return }
                        self.showFailure("未识别到文字")
                    }
                    return
                }

                let settings = AppSettings.load()
                let targetLanguage = settings.targetLanguage

                // 「英语八级眼镜」：已是目标语言的块跳过翻译、跳过覆盖渲染，
                // 只有外文块发给 LLM —— 混排界面里中文部分纹丝不动
                let toTranslate = ocrResults.enumerated().filter {
                    LanguageClassifier.shouldTranslate(
                        $0.element.text,
                        targetLanguage: targetLanguage
                    )
                }
                guard !toTranslate.isEmpty else {
                    await MainActor.run {
                        guard !self.tornDown, self.processingRequestID == requestID else { return }
                        guard self.preparePresentationIfNeeded() else {
                            self.teardown()
                            return
                        }
                        self.showHint(
                            text: "识别内容已是目标语言：\(targetLanguage.displayName)（可在设置中切换）",
                            isError: false
                        )
                    }
                    return
                }

                let results = try await TranslationService.shared.translateBlocks(
                    toTranslate.map(\.element.text),
                    targetLanguage: targetLanguage,
                    systemPresentation: { [weak self] visible in
                        guard let self, !self.tornDown, self.processingRequestID == requestID else { return }
                        self.overlayController.setReviewSuspendedForSystemUI(visible)
                        if visible {
                            self.hintPanel?.orderOut(nil)
                        } else if !Task.isCancelled {
                            self.showHint(text: "正在翻译…", isError: false)
                        }
                    }
                )
                try Task.checkCancellation()
                // 子集下标 → 原始块下标 映射
                var translations: [Int: String] = [:]
                var failed = Set<Int>()
                for (subIndex, result) in results.enumerated() {
                    let originalIndex = toTranslate[subIndex].offset
                    // 目标语言/数字以及翻译后未变化的缩写保留原像素。
                    if !result.failed && result.text == toTranslate[subIndex].element.text { continue }
                    translations[originalIndex] = result.text
                    if result.failed { failed.insert(originalIndex) }
                }

                let rendered = TranslatedImageRenderer.render(
                    original: image,
                    blocks: ocrResults,
                    translations: translations,
                    failedIndices: failed
                )
                let failedCount = failed.count // let 快照，避免 var 被并发闭包捕获
                await MainActor.run {
                    guard !self.tornDown, self.processingRequestID == requestID else { return }
                    if let rendered = rendered {
                        self.showResult(rendered: rendered, failedCount: failedCount)
                    } else {
                        self.showFailure("译文渲染失败")
                    }
                    self.processingTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard !self.tornDown, self.processingRequestID == requestID else { return }
                    self.teardown()
                }
                return
            } catch {
                await MainActor.run {
                    guard !self.tornDown, self.processingRequestID == requestID else { return }
                    self.showFailure(error.localizedDescription)
                    self.processingTask = nil
                }
            }
        }
    }

    // MARK: - 结果展示

    private func showResult(rendered: CGImage, failedCount: Int) {
        guard preparePresentationIfNeeded() else {
            teardown()
            return
        }
        renderedImage = rendered
        phase = .showing

        hintPanel?.orderOut(nil)
        hintPanel = nil
        hintLabel = nil

        // 译文图面板：精确贴在原选区（CG → AppKit 点坐标，主屏高度翻转，多屏安全）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let panelOrigin = NSPoint(
            x: region.minX,
            y: primaryHeight - region.minY - region.height
        )

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: region.size))
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = NSImage(cgImage: rendered, size: region.size)
        self.imageView = imageView

        let imagePanel = NSPanel(
            contentRect: NSRect(origin: panelOrigin, size: region.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        imagePanel.isOpaque = false
        imagePanel.backgroundColor = .clear
        imagePanel.level = Self.resultWindowLevel
        imagePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        imagePanel.hasShadow = false
        imagePanel.isReleasedWhenClosed = false
        // 吞掉点击（不透到灰屏触发退出），但不做任何动作
        imagePanel.ignoresMouseEvents = false
        imagePanel.contentView = imageView
        imagePanel.orderFrontRegardless()
        self.imagePanel = imagePanel

        showWidgetBar(failedCount: failedCount)
    }

    /// 小组件条：仅关闭按钮（用户明确只要原图翻译本身，剔除复制/保存/查看原图）
    /// 样式：深灰半透明胶囊 + 白字 + hover 高亮（macOS 原生浮动工具条观感）
    private func showWidgetBar(failedCount: Int) {
        let barHeight: CGFloat = 34
        let barWidth: CGFloat = failedCount > 0 ? 190 : 56
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080

        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: region.midX, y: primaryHeight - region.midY))
        }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // 贴选区下缘外侧（不遮挡选区内容），出屏则翻上缘
        let selectionBottomY = primaryHeight - region.maxY
        let selectionTopY = primaryHeight - region.minY
        var barY = selectionBottomY - barHeight - 10
        if barY < visible.minY + 4 {
            barY = selectionTopY + 10
        }
        let barX = min(
            max(region.midX - barWidth / 2, visible.minX + 8),
            visible.maxX - barWidth - 8
        )

        // 胶囊容器
        let container = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: barHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.88).cgColor
        container.layer?.cornerRadius = barHeight / 2
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        var x: CGFloat = 10
        @discardableResult
        func addButton(title: String, action: Selector) -> CapsuleButton {
            let button = CapsuleButton(title: title, target: self, action: action)
            button.sizeToFit()
            let width = button.frame.width + 18
            button.frame = NSRect(x: x, y: 4, width: width, height: barHeight - 8)
            container.addSubview(button)
            x += width + 4
            return button
        }

        addButton(title: "✕", action: #selector(closeClicked))

        if failedCount > 0 {
            let label = NSTextField(labelWithString: "⚠ \(failedCount) 处显示原文")
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = NSColor(red: 1.0, green: 0.72, blue: 0.3, alpha: 1)
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x + 2, y: (barHeight - label.frame.height) / 2)
            container.addSubview(label)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: barX, y: barY, width: barWidth, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = Self.controlWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.contentView = container
        panel.orderFrontRegardless()
        widgetPanel = panel
    }

    // MARK: - 提示条（翻译中 / 失败）

    private func showHint(text: String, isError: Bool) {
        // 先撤旧条（「正在翻译…」→ 结果/错误条 的替换路径）
        hintPanel?.orderOut(nil)
        hintPanel = nil
        hintLabel = nil

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let hintSize = NSSize(width: min(max(region.width, 220), 480), height: 30)

        // 优先选区上方（AppKit y 更高），出屏则放选区内顶部
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: region.midX, y: primaryHeight - region.midY))
        }) ?? NSScreen.main
        let visibleMaxY = screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude
        var hintY = (primaryHeight - region.minY) + 8
        if hintY + hintSize.height > visibleMaxY {
            hintY = (primaryHeight - region.minY) - hintSize.height - 8 // 选区内顶部
        }

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 8, y: 0, width: hintSize.width - 16, height: hintSize.height)

        let container = NSView(frame: NSRect(origin: .zero, size: hintSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = isError
            ? NSColor(red: 0.75, green: 0.22, blue: 0.18, alpha: 0.92).cgColor
            : NSColor.black.withAlphaComponent(0.8).cgColor
        container.layer?.cornerRadius = hintSize.height / 2
        container.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(
                x: region.midX - hintSize.width / 2, y: hintY,
                width: hintSize.width, height: hintSize.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = Self.controlWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.orderFrontRegardless()

        hintPanel = panel
        hintLabel = label
    }

    private func showFailure(_ message: String) {
        guard preparePresentationIfNeeded() else {
            teardown()
            return
        }
        phase = .failed
        // 复用提示条位置：先撤掉旧条再弹错误条
        hintPanel?.orderOut(nil)
        hintPanel = nil
        hintLabel = nil
        showHint(text: "\(message)（Esc 或点击退出）", isError: true)
    }

    private func preparePresentationIfNeeded() -> Bool {
        guard !tornDown else { return false }
        if didNotifyPresentationReady { return true }
        guard onPresentationReady(), !tornDown else { return false }
        didNotifyPresentationReady = true
        return true
    }

    // MARK: - 小组件动作

    @objc private func copyImage() {
        guard let rendered = renderedImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rep = NSBitmapImageRep(cgImage: rendered)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        ToastWindow.show(message: "已复制到剪贴板")
    }

    @objc private func savePNG() {
        guard let rendered = renderedImage else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "游目-译文-\(formatter.string(from: Date())).png"

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: rendered)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try png.write(to: url)
                ToastWindow.show(message: "已保存 PNG")
            } catch {
                self?.showFailure("保存失败: \(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleOriginal() {
        guard let original = originalImage, let rendered = renderedImage else { return }
        showingOriginal.toggle()
        let source = showingOriginal ? original : rendered
        imageView?.image = NSImage(cgImage: source, size: region.size)
        toggleButton?.title = showingOriginal ? "查看译文" : "查看原图"
    }

    @objc private func closeClicked() {
        teardown()
    }

    /// Host-side global-input arbitration uses the same safe teardown path as Esc.
    func cancelActiveSession() {
        teardown()
    }

    // MARK: - 退出

    /// 全部窗口 orderOut + 延迟释放（窗口安全约束）
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        processingRequestID = UUID()
        processingTask?.cancel()
        processingTask = nil

        let panels = [hintPanel, imagePanel, widgetPanel]
        panels.forEach { $0?.orderOut(nil) }
        hintPanel = nil
        imagePanel = nil
        widgetPanel = nil
        imageView = nil
        toggleButton = nil
        hintLabel = nil

        overlayController.dismiss()

        let overlay = overlayController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            _ = panels  // 延长面板寿命到事件循环排空后
            _ = overlay
            self?.onTeardownComplete()
        }
    }
}

/// 胶囊按钮：无边框白字，hover 时浅色高亮底（配套深色胶囊工具条）
final class CapsuleButton: NSButton {
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        font = NSFont.systemFont(ofSize: 12, weight: .medium)
        contentTintColor = .white
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未使用") }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )
        sizeToFit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = hovering
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : nil
    }
}
