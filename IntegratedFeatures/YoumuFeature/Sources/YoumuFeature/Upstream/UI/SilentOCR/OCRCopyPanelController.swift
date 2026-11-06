import AppKit

nonisolated enum OCRCopyPanelDismissalPolicy {
    static func shouldDismiss(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        eventBelongsToPanel: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        keyCode == 53 && eventBelongsToPanel && !hasMarkedText
            && flags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}


/// OCR completes in the clipboard; this compact, editable card remains available for follow-up.
final class OCRCopyPanelController {
    private static var current: OCRCopyPanelController?

    static func show(
        text: String,
        near region: CGRect,
        copySucceeded: Bool = false,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) {
        current?.teardown()
        let controller = OCRCopyPanelController(owner: owner, onDismiss: onDismiss)
        current = controller
        controller.present(text: text, near: region, copySucceeded: copySucceeded)
    }

    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard let current, current.owner == owner, !current.tornDown else { return false }
        current.teardown()
        return true
    }

    private var panel: NSPanel?
    private var content: OCRCopyPanelContentView?
    private var escMonitor: Any?
    private var tornDown = false
    private var translationTask: Task<Void, Never>?
    private var translationRequestID = UUID()
    private var isTranslating = false
    private let owner: CaptureCommandOwner?
    private let onDismiss: ((CaptureCommandOwner) -> Void)?
    private var didNotifyDismiss = false

    private init(owner: CaptureCommandOwner?, onDismiss: ((CaptureCommandOwner) -> Void)?) {
        self.owner = owner
        self.onDismiss = onDismiss
    }

    private func present(text: String, near region: CGRect, copySucceeded: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let card = OCRCopyPanelContentView(text: text, target: self, actions: .init(
            copyOriginal: #selector(copyOriginal), speakOriginal: #selector(speakOriginal),
            translate: #selector(translateClicked), copyTranslated: #selector(copyTranslated),
            speakTranslated: #selector(speakTranslated), close: #selector(closeClicked)
        ))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let point = NSPoint(x: region.midX, y: primaryHeight - region.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = OCRCopyPanelLayout.placement(
            size: card.preferredSize, near: region, primaryHeight: primaryHeight, visible: visible
        )
        let panel = OCRWorkspacePanel(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = card
        self.content = card
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(card.originalTextView)
        card.originalTextView.setSelectedRange(NSRange(location: 0, length: 0))
        card.showCopyFeedback(succeeded: copySucceeded)

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel,
                  OCRCopyPanelDismissalPolicy.shouldDismiss(
                    keyCode: event.keyCode, flags: event.modifierFlags,
                    eventBelongsToPanel: panel.isVisible && event.window === panel,
                    hasMarkedText: (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
                  ) else { return event }
            self.teardown()
            return nil
        }
    }

    @objc private func translateClicked() {
        guard !isTranslating else { return }
        // 取编辑框里的最新文本（用户可能改过）
        guard let rawText = content?.originalTextView.string,
              let text = PanelTextNormalizer.textForTranslation(rawText) else {
            showTranslationError("没有可翻译的内容")
            return
        }

        isTranslating = true
        content?.translateButton.title = "翻译中…"
        content?.translateButton.isEnabled = false

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
                self.content?.translateButton.title = "翻译"
                self.content?.translateButton.isEnabled = true
                self.translationTask = nil
            }
        }
    }


    private func showTranslation(_ text: String) {
        content?.showTranslation(text, isError: false)
        resizeForContent()
    }

    private func showTranslationError(_ message: String) {
        content?.showTranslation("翻译失败：\(message)", isError: true)
        resizeForContent()
    }

    private func resizeForContent() {
        guard let panel, let content else { return }
        let size = content.preferredSize
        var frame = NSRect(
            x: panel.frame.minX, y: panel.frame.maxY - size.height,
            width: size.width, height: size.height
        )
        if let visible = panel.screen?.visibleFrame {
            frame.origin.y = min(max(frame.minY, visible.minY + 12), visible.maxY - size.height - 12)
        }
        panel.setFrame(frame, display: true, animate: VisionMotionPolicy.shouldAnimate(
            reduceMotionEnabled: VisionMotionPolicy.reduceMotionEnabled
        ))
        content.frame.size = size
        content.needsLayout = true
    }

    @objc private func copyOriginal() {
        guard let text = content?.originalTextView.string else { return }
        copyToClipboard(PanelTextNormalizer.textForCopy(text))
    }

    @objc private func copyTranslated() {
        guard let text = content?.translatedTextView.string, !text.isEmpty else { return }
        copyToClipboard(text)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        content?.showCopyFeedback(succeeded: pasteboard.setString(text, forType: .string))
    }

    @objc private func speakOriginal() {
        SpeechService.shared.toggle(text: content?.originalTextView.string ?? "")
    }

    @objc private func speakTranslated() {
        SpeechService.shared.toggle(text: content?.translatedTextView.string ?? "")
    }

    @objc private func closeClicked() { teardown() }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        translationRequestID = UUID()
        translationTask?.cancel()
        translationTask = nil
        content?.invalidateCopyFeedback()
        SpeechService.shared.stop()
        notifyDismissIfNeeded()
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        let oldPanel = panel
        oldPanel?.orderOut(nil)
        panel = nil
        content = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = oldPanel
            if OCRCopyPanelController.current === self { OCRCopyPanelController.current = nil }
        }
    }

    private func notifyDismissIfNeeded() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        if let owner { onDismiss?(owner) }
    }
}

/// Single clipped paper surface. Editors are transparent so they cannot paint square corners.
final class OCRCopyPanelContentView: VisionSurfaceView {
    struct Actions {
        let copyOriginal: Selector
        let speakOriginal: Selector
        let translate: Selector
        let copyTranslated: Selector
        let speakTranslated: Selector
        let close: Selector
    }

    let originalTextView: NSTextView
    let translatedTextView: NSTextView
    let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    let copyFeedbackLabel = NSTextField(labelWithString: "")
    private let originalScroll: NSScrollView
    private let translatedScroll: NSScrollView
    private let title = NSTextField(labelWithString: "识别文本")
    private let translatedTitle = NSTextField(labelWithString: "译文")
    private let footerDivider = VisionSurfaceView()
    private let sectionDivider = VisionSurfaceView()
    private let feedbackView = NSView()
    private let feedbackIcon = NSImageView()
    private var headerButtons: [NSButton] = []
    private var translationButtons: [NSButton] = []
    private var originalHeight: CGFloat
    private var translatedHeight: CGFloat?
    private var feedbackGeneration = UUID()
    private var feedbackDismissal: DispatchWorkItem?

    var preferredSize: NSSize {
        OCRCopyPanelLayout.size(originalHeight: originalHeight, translatedHeight: translatedHeight)
    }

    init(text: String, target: AnyObject, actions: Actions) {
        originalHeight = OCRCopyPanelLayout.textHeight(text, minimum: 96, maximum: 216)
        (originalScroll, originalTextView) = Self.makeEditor(text: text)
        (translatedScroll, translatedTextView) = Self.makeEditor(text: "")
        super.init(frame: NSRect(origin: .zero, size: .zero))
        surfaceColor = .textBackgroundColor
        outlineColor = .separatorColor
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        setAccessibilityIdentifier("ocr.copy.card")

        for label in [title, translatedTitle] {
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }
        headerButtons = [
            Self.iconButton("doc.on.doc", label: "复制文本", target: target, action: actions.copyOriginal),
            Self.iconButton("speaker.wave.2", label: "朗读文本", target: target, action: actions.speakOriginal),
            Self.iconButton("xmark", label: "关闭", target: target, action: actions.close),
        ]
        translationButtons = [
            Self.iconButton("doc.on.doc", label: "复制译文", target: target, action: actions.copyTranslated),
            Self.iconButton("speaker.wave.2", label: "朗读译文", target: target, action: actions.speakTranslated),
        ]
        (headerButtons + translationButtons).forEach(addSubview)
        addSubview(originalScroll)
        addSubview(translatedScroll)
        translatedTextView.setAccessibilityLabel("译文，可编辑")
        originalTextView.setAccessibilityLabel("识别文本，可编辑")

        translateButton.target = target
        translateButton.action = actions.translate
        translateButton.bezelStyle = .rounded
        translateButton.controlSize = .small
        translateButton.font = .systemFont(ofSize: 11, weight: .medium)
        translateButton.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        translateButton.imagePosition = .imageLeading
        translateButton.image?.size = NSSize(width: 13, height: 13)
        translateButton.setAccessibilityLabel("翻译此文本")
        addSubview(translateButton)
        for divider in [footerDivider, sectionDivider] {
            divider.surfaceColor = .separatorColor
            addSubview(divider)
        }
        copyFeedbackLabel.font = .systemFont(ofSize: 11)
        copyFeedbackLabel.textColor = .secondaryLabelColor
        feedbackIcon.contentTintColor = .secondaryLabelColor
        feedbackIcon.imageScaling = .scaleProportionallyDown
        feedbackView.wantsLayer = true
        feedbackView.addSubview(feedbackIcon)
        feedbackView.addSubview(copyFeedbackLabel)
        addSubview(feedbackView)
        feedbackView.isHidden = true
        frame.size = preferredSize
        applyLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        applyLayout()
    }

    private func applyLayout() {
        let width = bounds.width
        let originalY: CGFloat = translatedHeight.map { 52 + $0 + 48 } ?? 52
        title.frame = NSRect(x: 20, y: bounds.height - 34, width: width - 152, height: 20)
        for (index, button) in headerButtons.enumerated() {
            button.frame = NSRect(x: width - 106 + CGFloat(index) * 30, y: bounds.height - 38, width: 26, height: 26)
        }
        originalScroll.frame = NSRect(x: 20, y: originalY, width: width - 40, height: originalHeight)
        footerDivider.frame = NSRect(x: 20, y: 44, width: width - 40, height: 0.5)
        translateButton.frame = NSRect(x: width - 100, y: 10, width: 80, height: 26)
        feedbackView.frame = NSRect(x: 20, y: 13, width: width - 134, height: 18)
        feedbackIcon.frame = NSRect(x: 0, y: 2, width: 13, height: 13)
        copyFeedbackLabel.frame = NSRect(x: 19, y: 0, width: feedbackView.bounds.width - 19, height: 18)

        let expanded = translatedHeight != nil
        (translationButtons + [translatedTitle, translatedScroll, sectionDivider]).forEach { $0.isHidden = !expanded }
        if let height = translatedHeight {
            translatedScroll.frame = NSRect(x: 20, y: 52, width: width - 40, height: height)
            translatedTitle.frame = NSRect(x: 20, y: 52 + height + 8, width: width - 112, height: 24)
            for (index, button) in translationButtons.enumerated() {
                button.frame = NSRect(x: width - 76 + CGFloat(index) * 30, y: 52 + height + 7, width: 26, height: 26)
            }
            sectionDivider.frame = NSRect(x: 20, y: 52 + height + 38, width: width - 40, height: 0.5)
        }
    }

    func showTranslation(_ text: String, isError: Bool) {
        translatedTextView.string = text
        translatedTextView.textColor = isError ? VisionDesign.failureText : .textColor
        translatedHeight = OCRCopyPanelLayout.textHeight(text, minimum: 88, maximum: 164)
    }

    /// Feedback stays inside the card and never takes focus, plays a sound, or opens a window.
    func showCopyFeedback(succeeded: Bool) {
        invalidateCopyFeedback()
        feedbackView.isHidden = false
        feedbackView.layer?.removeAllAnimations()
        feedbackView.alphaValue = 1
        copyFeedbackLabel.stringValue = succeeded ? "已复制进剪贴板" : "复制失败，请重试"
        let feedbackColor: NSColor = succeeded ? VisionDesign.brandAccent : .secondaryLabelColor
        copyFeedbackLabel.textColor = feedbackColor
        feedbackIcon.contentTintColor = feedbackColor
        feedbackIcon.image = NSImage(
            systemSymbolName: succeeded ? "checkmark.circle" : "exclamationmark.circle",
            accessibilityDescription: nil
        )
        guard succeeded else { return }
        let generation = feedbackGeneration
        let dismissal = DispatchWorkItem { [weak self] in
            guard let self, self.feedbackGeneration == generation else { return }
            let hide = { [weak self] in
                guard let self, self.feedbackGeneration == generation else { return }
                self.feedbackView.isHidden = true
            }
            guard VisionMotionPolicy.shouldAnimate(
                reduceMotionEnabled: VisionMotionPolicy.reduceMotionEnabled
            ) else { hide(); return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.feedbackView.animator().alphaValue = 0
            } completionHandler: { hide() }
        }
        feedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: dismissal)
    }

    func invalidateCopyFeedback() {
        feedbackGeneration = UUID()
        feedbackDismissal?.cancel()
        feedbackDismissal = nil
    }

    private static func iconButton(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = target
        button.action = action
        return button
    }

    private static func makeEditor(text: String) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 96))
        editor.string = text
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = .textColor
        editor.insertionPointColor = .controlAccentColor
        editor.font = .systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        editor.defaultParagraphStyle = paragraph
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return (scroll, editor)
    }
}

enum OCRCopyPanelLayout {
    static func textHeight(_ text: String, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: 400, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]
        )
        return min(maximum, max(minimum, ceil(rect.height) + 8))
    }

    static func size(originalHeight: CGFloat, translatedHeight: CGFloat?) -> NSSize {
        NSSize(width: 440, height: originalHeight + 100 + (translatedHeight.map { $0 + 48 } ?? 0))
    }

    static func placement(size: NSSize, near region: CGRect, primaryHeight: CGFloat, visible: CGRect) -> CGRect {
        let below = primaryHeight - region.maxY - size.height - 12
        let above = primaryHeight - region.minY + 12
        let preferredY = below >= visible.minY + 12 ? below : above
        return CGRect(
            x: min(max(region.midX - size.width / 2, visible.minX + 12), visible.maxX - size.width - 12),
            y: min(max(preferredY, visible.minY + 12), visible.maxY - size.height - 12),
            width: size.width, height: size.height
        )
    }
}

final class OCRWorkspacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
