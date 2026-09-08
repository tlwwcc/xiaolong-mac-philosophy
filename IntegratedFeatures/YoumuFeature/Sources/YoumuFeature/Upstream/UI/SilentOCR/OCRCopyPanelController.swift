import AppKit

/// 「OCR 复制」三合一工作台：
/// 识别完成先把原文自动写进剪贴板（默认行为不变），再弹出本面板：
/// 上区 原文（可编辑，🔊朗读/复制），下区 译文（点「翻译」后展开，🔊朗读/复制）。
/// 翻译取编辑框实时文本；Esc 关闭并停止朗读。
final class OCRCopyPanelController {

    private static var current: OCRCopyPanelController?

    static func show(
        text: String,
        near region: CGRect,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) {
        current?.teardown()
        let controller = OCRCopyPanelController(owner: owner, onDismiss: onDismiss)
        current = controller
        controller.present(text: text, near: region)
    }

    /// Closes only the OCR workspace created by this exact capture invocation.
    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard let current, current.owner == owner, !current.tornDown else { return false }
        current.teardown()
        return true
    }

    // MARK: - 内部

    private var panel: NSPanel?
    private var originalHeader: NSView?
    private var originalScrollView: NSScrollView?
    private var originalTextView: NSTextView?
    private var translatedTextView: NSTextView?
    private var translatedHeader: NSView?
    private var translatedScrollView: NSScrollView?
    private var translateButton: NSButton?
    private var closeButton: NSButton?
    private var escMonitor: Any?
    private var tornDown = false
    private var translationTask: Task<Void, Never>?
    private var translationRequestID = UUID()
    private let owner: CaptureCommandOwner?
    private let onDismiss: ((CaptureCommandOwner) -> Void)?
    private var didNotifyDismiss = false

    /// 收起/展开尺寸（译文区展开时自适应加高，仍保持迷你）
    private let collapsedSize = NSSize(width: 440, height: 294)
    private let expandedSize = NSSize(width: 440, height: 468)
    private var isExpanded = false
    private var isTranslating = false

    private init(
        owner: CaptureCommandOwner?,
        onDismiss: ((CaptureCommandOwner) -> Void)?
    ) {
        self.owner = owner
        self.onDismiss = onDismiss
    }

    // MARK: - 装配

    private func present(text: String, near region: CGRect) {
        NSApp.activate(ignoringOtherApps: true)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: region.midX, y: primaryHeight - region.midY))
        }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var panelY = (primaryHeight - region.maxY) - collapsedSize.height - 10
        if panelY < visible.minY + 4 {
            panelY = (primaryHeight - region.minY) + 10
        }
        let panelX = min(
            max(region.midX - collapsedSize.width / 2, visible.minX + 8),
            visible.maxX - collapsedSize.width - 8
        )

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: collapsedSize))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = VisionDesign.panelRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = VisionDesign.panelBorder.cgColor
        container.layer?.masksToBounds = true

        // ── 上区：原文（可编辑）──
        let originalHeader = makeSectionHeader(
            title: "OCR 文本   ·   已复制   ·   可编辑",
            y: collapsedSize.height - 34,
            width: collapsedSize.width,
            actions: [
                ("speaker.wave.2", #selector(speakOriginal), "朗读原文"),
                ("doc.on.doc", #selector(copyOriginal), "复制原文"),
            ]
        )
        container.addSubview(originalHeader)
        self.originalHeader = originalHeader

        let originalScroll = makeTextScrollView(
            frame: NSRect(x: 14, y: 72, width: collapsedSize.width - 28, height: 178),
            editable: true, fontSize: 13
        )
        let originalText = originalScroll.documentView as? NSTextView
        originalText?.string = text
        container.addSubview(originalScroll)
        originalScrollView = originalScroll
        originalTextView = originalText

        // ── 中部：翻译主按钮 ──
        let translate = NSButton(
            frame: NSRect(x: 14, y: 20, width: 122, height: 32)
        )
        translate.title = "翻译此文本"
        translate.image = NSImage(
            systemSymbolName: "character.book.closed",
            accessibilityDescription: "翻译此文本"
        )
        translate.imagePosition = .imageLeading
        translate.bezelStyle = .rounded
        translate.controlSize = .regular
        translate.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        translate.bezelColor = .systemBlue
        translate.target = self
        translate.action = #selector(translateClicked)
        container.addSubview(translate)
        translateButton = translate

        // ── 下区：译文（默认隐藏，翻译后展开）──
        let translatedHeader = makeSectionHeader(
            title: "译文   ·   可编辑",
            y: 174,
            width: collapsedSize.width,
            actions: [
                ("speaker.wave.2", #selector(speakTranslated), "朗读译文"),
                ("doc.on.doc", #selector(copyTranslated), "复制译文"),
            ]
        )
        translatedHeader.isHidden = true
        container.addSubview(translatedHeader)
        self.translatedHeader = translatedHeader

        let translatedScroll = makeTextScrollView(
            frame: NSRect(x: 14, y: 58, width: collapsedSize.width - 28, height: 110),
            editable: true, fontSize: 13
        )
        translatedScroll.isHidden = true
        container.addSubview(translatedScroll)
        translatedScrollView = translatedScroll
        translatedTextView = translatedScroll.documentView as? NSTextView

        // ── 底部：关闭 ──
        let closeButton = NSButton(frame: NSRect(x: collapsedSize.width - 82, y: 20, width: 68, height: 30))
        closeButton.title = "关闭"
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.font = NSFont.systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        container.addSubview(closeButton)
        self.closeButton = closeButton

        let panel = OCRWorkspacePanel(
            contentRect: NSRect(origin: NSPoint(x: panelX, y: panelY), size: collapsedSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(originalText)
        originalText?.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        self.panel = panel

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.teardown()
                return nil
            }
            return event
        }
    }

    /// 区块头：标题 + 右侧行内小图标按钮
    private func makeSectionHeader(
        title: String, y: CGFloat, width: CGFloat,
        actions: [(symbol: String, action: Selector, tooltip: String)]
    ) -> NSView {
        let header = NSView(frame: NSRect(x: 14, y: y, width: width - 28, height: 24))
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.frame = NSRect(x: 0, y: 2, width: 305, height: 20)
        header.addSubview(label)

        var buttonX = width - 28 - 26
        for item in actions {
            let button = NSButton(frame: NSRect(x: buttonX, y: 0, width: 24, height: 20))
            button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = item.tooltip
            button.target = self
            button.action = item.action
            header.addSubview(button)
            buttonX -= 28
        }
        return header
    }

    private func makeTextScrollView(frame: NSRect, editable: Bool, fontSize: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autoresizingMask = [.width]
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = VisionDesign.compactRadius
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = VisionDesign.panelBorder.cgColor

        let textView = NSTextView(frame: NSRect(
            x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height
        ))
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    // MARK: - 翻译

    @objc private func translateClicked() {
        guard !isTranslating else { return }
        // 取编辑框里的最新文本（用户可能改过）
        guard let rawText = originalTextView?.string,
              let text = PanelTextNormalizer.textForTranslation(rawText) else {
            showTranslationError("没有可翻译的内容")
            return
        }

        isTranslating = true
        translateButton?.title = "翻译中…"
        translateButton?.isEnabled = false

        translationTask?.cancel()
        let requestID = UUID()
        translationRequestID = requestID
        translationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let settings = AppSettings.load()
                let translated = try await TranslationService.shared.translate(
                    text: text,
                    targetLanguage: settings.targetLanguage
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard !self.tornDown, self.translationRequestID == requestID else { return }
                    self.showTranslation(translated)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard !self.tornDown, self.translationRequestID == requestID else { return }
                    self.showTranslationError(error.localizedDescription)
                }
            }
            await MainActor.run {
                guard !self.tornDown, self.translationRequestID == requestID else { return }
                self.isTranslating = false
                self.translateButton?.title = "翻译此文本"
                self.translateButton?.isEnabled = true
                self.translationTask = nil
            }
        }
    }

    private func showTranslation(_ text: String) {
        translatedTextView?.string = text
        translatedTextView?.textColor = .textColor
        expandIfNeeded()
    }

    private func showTranslationError(_ message: String) {
        translatedTextView?.string = "翻译失败：\(message)"
        translatedTextView?.textColor = .systemRed
        expandIfNeeded()
    }

    /// 译文区展开：面板向下加高（保持顶边不动），显式重排各区块
    private func expandIfNeeded() {
        guard !isExpanded, let panel = panel, let container = panel.contentView else { return }
        isExpanded = true

        var frame = panel.frame
        frame.origin.y -= (expandedSize.height - frame.height)
        frame.size = expandedSize
        panel.setFrame(
            frame,
            display: true,
            animate: VisionMotionPolicy.shouldAnimate(
                reduceMotionEnabled: VisionMotionPolicy.reduceMotionEnabled
            )
        )
        container.frame = NSRect(origin: .zero, size: expandedSize)

        // 显式布局：上区贴顶，中部按钮，下区译文，关闭钉底
        originalHeader?.frame.origin.y = expandedSize.height - 34
        originalScrollView?.frame = NSRect(
            x: 14, y: expandedSize.height - 204,
            width: expandedSize.width - 28, height: 158
        )
        translateButton?.frame.origin.y = expandedSize.height - 246
        translatedHeader?.frame.origin.y = expandedSize.height - 282
        translatedScrollView?.frame = NSRect(
            x: 14, y: 60,
            width: expandedSize.width - 28,
            height: expandedSize.height - 348
        )
        closeButton?.frame.origin.y = 18

        translatedHeader?.isHidden = false
        translatedScrollView?.isHidden = false
    }

    // MARK: - 动作

    @objc private func copyOriginal() {
        guard let text = originalTextView?.string else { return }
        let normalized = PanelTextNormalizer.textForCopy(text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(normalized, forType: .string)
        ToastWindow.show(message: "已复制 \(normalized.count) 个字符")
    }

    @objc private func copyTranslated() {
        guard let text = translatedTextView?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ToastWindow.show(message: "译文已复制")
    }

    @objc private func speakOriginal() {
        SpeechService.shared.toggle(text: originalTextView?.string ?? "")
    }

    @objc private func speakTranslated() {
        SpeechService.shared.toggle(text: translatedTextView?.string ?? "")
    }

    @objc private func closeClicked() {
        teardown()
    }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        translationRequestID = UUID()
        translationTask?.cancel()
        translationTask = nil
        SpeechService.shared.stop()
        notifyDismissIfNeeded()

        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        let oldPanel = panel
        oldPanel?.orderOut(nil)
        panel = nil
        originalHeader = nil
        originalScrollView = nil
        originalTextView = nil
        translatedTextView = nil
        translatedHeader = nil
        translatedScrollView = nil
        translateButton = nil
        closeButton = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = oldPanel
            if OCRCopyPanelController.current === self {
                OCRCopyPanelController.current = nil
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

/// OCR 文本需要真正拿到键盘焦点；非激活面板只能“看起来可编辑”，实际点不进去。
final class OCRWorkspacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
