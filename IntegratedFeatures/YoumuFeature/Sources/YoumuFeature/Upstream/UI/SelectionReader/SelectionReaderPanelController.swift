import AppKit

enum SelectionReaderVisualContract {
    static let textCardCornerRadius: CGFloat = 18
    static let controlBarCornerRadius: CGFloat = 14
    static let usesContinuousCorners = true
    static let supportsWindowResizing = true
    static let supportsNativeFullScreen = true
    static let usesStandardWindowControls = true
    static let manualNavigationPausesFollowing = true
    static let usesIncrementalHighlighting = true
    static let minimumSize = NSSize(width: 700, height: 500)
    static let preferredSize = NSSize(width: 840, height: 620)
    static let maximumReadingLineWidth: CGFloat = 760
}

enum SelectionReaderFontScale: Int, CaseIterable {
    case small
    case medium
    case large

    static let defaultScale: SelectionReaderFontScale = .medium

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: return 18
        case .medium: return 22
        case .large: return 27
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .small: return 7
        case .medium: return 10
        case .large: return 14
        }
    }
}

/// “选哪读哪”沉浸阅读器：完整文本、逐词跟读、真实进度、倍速与空格暂停/继续。
/// 窗口停留到用户主动关闭，读完后可直接重播。
final class SelectionReaderPanelController: NSObject, NSWindowDelegate {
    private static var current: SelectionReaderPanelController?
    private static var rateDefaultsKey: String {
        YoumuFeatureEnvironmentStore.shared.userDefaultsKey(
            "selection-reader.playback-rate"
        )
    }
    private static var fontScaleDefaultsKey: String {
        YoumuFeatureEnvironmentStore.shared.userDefaultsKey(
            "selection-reader.font-scale"
        )
    }

    static func show(
        text: String,
        near region: CGRect,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) {
        current?.teardown(stopSpeech: true)
        let controller = SelectionReaderPanelController(owner: owner, onDismiss: onDismiss)
        current = controller
        controller.present(text: text, near: region)
    }

    /// Closes only the reader created by this exact capture invocation.
    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard let current, current.owner == owner, !current.tornDown else { return false }
        current.teardown(stopSpeech: true)
        return true
    }

    private var panel: SelectionReaderWindow?
    private var speechObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private var tornDown = false
    private var sourceText = ""
    private var lastHighlightedRange: NSRange?
    private var lastHighlightedSentenceRange: NSRange?
    private var lastHighlightState: SpeechPlaybackState?
    private var followsReading = true
    private var isProgrammaticScroll = false
    private var programmaticScrollGeneration: UInt64 = 0
    private var sessionVoice: EdgeSpeechVoice = .yunjian
    private var sessionUsesLocalVoice = false
    private var fontScale: SelectionReaderFontScale = .defaultScale
    private let owner: CaptureCommandOwner?
    private let onDismiss: ((CaptureCommandOwner) -> Void)?
    private var didNotifyDismiss = false

    private weak var textView: NSTextView?
    private weak var statusLabel: NSTextField?
    private weak var backendLabel: NSTextField?
    private weak var voiceLabel: NSTextField?
    private weak var progressSlider: NSSlider?
    private weak var elapsedLabel: NSTextField?
    private weak var durationLabel: NSTextField?
    private weak var playPauseButton: NSButton?
    private weak var speedButton: NSPopUpButton?
    private weak var voiceButton: NSPopUpButton?
    private weak var followButton: NSButton?
    private weak var fontSizeControl: NSSegmentedControl?

    private init(
        owner: CaptureCommandOwner?,
        onDismiss: ((CaptureCommandOwner) -> Void)?
    ) {
        self.owner = owner
        self.onDismiss = onDismiss
        super.init()
    }

    private func present(text: String, near region: CGRect) {
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else {
            teardown(stopSpeech: false)
            return
        }
        let settings = AppSettings.load()
        sessionVoice = settings.speechVoice
        sessionUsesLocalVoice = settings.speechBackend == .macLocal
        fontScale = Self.storedFontScale()
        NSApp.activate(ignoringOtherApps: true)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: region.midX, y: primaryHeight - region.midY))
        }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(SelectionReaderVisualContract.preferredSize.width, visible.width - 28),
            height: min(SelectionReaderVisualContract.preferredSize.height, visible.height - 28)
        )
        let x = min(
            max(region.midX - size.width / 2, visible.minX + 14),
            visible.maxX - size.width - 14
        )
        let proposedY = (primaryHeight - region.midY) - size.height / 2
        let y = min(
            max(proposedY, visible.minY + 14),
            visible.maxY - size.height - 14
        )

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.autoresizingMask = [.width, .height]

        buildHeader(in: root, size: size)
        buildTextSurface(in: root, size: size)
        buildPlaybackControls(in: root, size: size)

        let panel = SelectionReaderWindow(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "选哪读哪"
        panel.titleVisibility = .visible
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.tabbingMode = .disallowed
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentMinSize = SelectionReaderVisualContract.minimumSize
        panel.minSize = SelectionReaderVisualContract.minimumSize
        panel.contentView = root
        panel.setFrameAutosaveName("YoumuSelectionReaderWindow")
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        speechObserver = NotificationCenter.default.addObserver(
            forName: SpeechService.stateDidChangeNotification,
            object: SpeechService.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(with: SpeechService.shared.snapshot)
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  Self.shouldHandleKeyboardShortcut(
                    readerIsKeyWindow: self.panel?.isKeyWindow == true
                  ) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) {
                switch event.keyCode {
                case 24: // ⌘+ 或 ⌘=
                    self.stepFontScale(by: 1)
                    return nil
                case 27: // ⌘-
                    self.stepFontScale(by: -1)
                    return nil
                case 29: // ⌘0
                    self.setFontScale(.defaultScale)
                    return nil
                default:
                    break
                }
            }
            switch event.keyCode {
            case 49: // Space：全窗口统一为暂停 / 继续，不让滚动区吞掉。
                SpeechService.shared.togglePause()
                return nil
            case 53: // Esc
                if self.panel?.styleMask.contains(.fullScreen) == true {
                    return event
                }
                self.teardown(stopSpeech: true)
                return nil
            default:
                return event
            }
        }

        let storedRate = YoumuFeatureEnvironmentStore.shared.userDefaults().float(
            forKey: Self.rateDefaultsKey
        )
        let rate = SpeechService.normalizedRate(storedRate > 0 ? storedRate : 1)
        SpeechService.shared.setPlaybackRate(rate)
        selectRate(rate)
        refresh(with: SpeechService.shared.snapshot)
        SpeechService.shared.speak(
            text: sourceText,
            preferredVoice: sessionVoice
        )
    }

    private func buildHeader(in root: NSView, size: NSSize) {
        let header = NSView(
            frame: NSRect(x: 0, y: size.height - 82, width: size.width, height: 72)
        )
        header.autoresizingMask = [.width, .minYMargin]
        header.setAccessibilityLabel("阅读器状态与字号")
        root.addSubview(header)

        let icon = VisionReaderBrandMarkView(frame: NSRect(x: 28, y: 17, width: 38, height: 38))
        icon.autoresizingMask = [.maxXMargin, .minYMargin]
        header.addSubview(icon)

        let voice = NSTextField(labelWithString: sessionVoice.displayName)
        voice.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        voice.textColor = .labelColor
        voice.frame = NSRect(x: 80, y: 34, width: 265, height: 20)
        voice.autoresizingMask = [.width, .maxXMargin, .minYMargin]
        header.addSubview(voice)
        voiceLabel = voice

        let backend = NSTextField(
            labelWithString: sessionUsesLocalVoice ? "Mac 本机声音 · 文字不离开本机" : "Edge 神经声音 · 自然朗读"
        )
        backend.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        backend.textColor = .secondaryLabelColor
        backend.frame = NSRect(x: 80, y: 13, width: 280, height: 18)
        backend.autoresizingMask = [.width, .maxXMargin, .minYMargin]
        header.addSubview(backend)
        backendLabel = backend

        let status = NSTextField(labelWithString: "准备语音")
        status.alignment = .center
        status.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        status.textColor = VisionDesign.brandPurple
        status.wantsLayer = true
        status.layer?.cornerRadius = 10
        status.layer?.backgroundColor = VisionDesign.brandPurpleSoft.cgColor
        status.layer?.cornerCurve = .continuous
        status.frame = NSRect(x: size.width - 322, y: 25, width: 104, height: 22)
        status.autoresizingMask = [.minXMargin, .minYMargin]
        header.addSubview(status)
        statusLabel = status

        let fontSize = NSSegmentedControl(
            labels: SelectionReaderFontScale.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(fontScaleChanged)
        )
        fontSize.segmentStyle = .rounded
        fontSize.selectedSegment = fontScale.rawValue
        fontSize.frame = NSRect(x: size.width - 198, y: 20, width: 164, height: 30)
        fontSize.autoresizingMask = [.minXMargin, .minYMargin]
        fontSize.toolTip = "阅读字号：小、中、大；也可使用 ⌘+ 与 ⌘-"
        fontSize.setAccessibilityLabel("阅读字号")
        header.addSubview(fontSize)
        fontSizeControl = fontSize

        let divider = NSBox(frame: NSRect(x: 28, y: 0, width: size.width - 56, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .maxYMargin]
        header.addSubview(divider)
    }

    private func buildTextSurface(in root: NSView, size: NSSize) {
        let cardFrame = NSRect(x: 28, y: 136, width: size.width - 56, height: size.height - 232)
        let card = NSView(frame: cardFrame)
        card.wantsLayer = true
        card.layer?.cornerRadius = SelectionReaderVisualContract.textCardCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = VisionDesign.paperWhite.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.08
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        card.autoresizingMask = [.width, .height]
        root.addSubview(card)

        let scroll = NSScrollView(frame: card.bounds.insetBy(dx: 1, dy: 1))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        card.addSubview(scroll)

        let text = ReaderTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.maximumReadingLineWidth = SelectionReaderVisualContract.maximumReadingLineWidth
        text.updateReadingInsets(for: scroll.contentSize.width)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        text.layoutManager?.allowsNonContiguousLayout = true
        text.textStorage?.setAttributedString(baseAttributedText())
        scroll.documentView = text
        textView = text

        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isProgrammaticScroll else { return }
                self.setFollowsReading(false)
            }
        }
    }

    private func buildPlaybackControls(in root: NSView, size: NSSize) {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(progressChanged))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.trackFillColor = VisionDesign.brandPurple
        slider.frame = NSRect(x: 24, y: 101, width: size.width - 48, height: 18)
        slider.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(slider)
        progressSlider = slider

        let elapsed = timeLabel(alignment: .left)
        elapsed.frame = NSRect(x: 24, y: 81, width: 80, height: 18)
        elapsed.autoresizingMask = [.maxXMargin, .maxYMargin]
        root.addSubview(elapsed)
        elapsedLabel = elapsed

        let total = timeLabel(alignment: .right)
        total.frame = NSRect(x: size.width - 104, y: 81, width: 80, height: 18)
        total.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(total)
        durationLabel = total

        let shortcut = NSTextField(labelWithString: "空格  播放 / 暂停    ·    ⌃⌘F  全屏    ·    ⌘±  字号")
        shortcut.alignment = .center
        shortcut.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.frame = NSRect(x: 112, y: 81, width: size.width - 224, height: 18)
        shortcut.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(shortcut)

        let controlBar = NSView(frame: NSRect(x: 28, y: 17, width: size.width - 56, height: 58))
        controlBar.wantsLayer = true
        controlBar.layer?.cornerRadius = SelectionReaderVisualContract.controlBarCornerRadius
        controlBar.layer?.cornerCurve = .continuous
        controlBar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.62).cgColor
        controlBar.layer?.borderWidth = 0.75
        controlBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        controlBar.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(controlBar)

        let controls = NSStackView(frame: controlBar.bounds.insetBy(dx: 12, dy: 9))
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.distribution = .fill
        controls.autoresizingMask = [.width, .height]
        controlBar.addSubview(controls)

        let speed = NSPopUpButton(frame: .zero, pullsDown: false)
        SpeechService.supportedRates.forEach { speed.addItem(withTitle: Self.rateTitle($0)) }
        speed.toolTip = "朗读倍速"
        speed.setAccessibilityLabel("朗读倍速")
        speed.target = self
        speed.action = #selector(speedChanged)
        speed.widthAnchor.constraint(equalToConstant: 76).isActive = true
        controls.addArrangedSubview(speed)
        speedButton = speed

        let voice = NSPopUpButton(frame: .zero, pullsDown: false)
        EdgeSpeechVoice.allCases.forEach {
            voice.addItem(withTitle: Self.voiceTitle($0))
        }
        voice.selectItem(withTitle: Self.voiceTitle(sessionVoice))
        voice.isEnabled = !sessionUsesLocalVoice
        voice.toolTip = sessionUsesLocalVoice
            ? "后台当前使用 Mac 本机声音；可在设置中切换朗读方式。"
            : "当前文章固定使用这个主播；切换后从开头重新朗读。"
        voice.setAccessibilityLabel("朗读主播")
        voice.target = self
        voice.action = #selector(voiceChanged)
        voice.widthAnchor.constraint(equalToConstant: 168).isActive = true
        controls.addArrangedSubview(voice)
        voiceButton = voice

        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.addArrangedSubview(spacer)

        let play = NSButton(frame: .zero)
        play.title = "暂停"
        play.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停朗读")
        play.imagePosition = .imageLeading
        play.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        play.bezelStyle = .rounded
        play.bezelColor = VisionDesign.brandPurple
        play.contentTintColor = .white
        play.target = self
        play.action = #selector(playPauseClicked)
        play.widthAnchor.constraint(equalToConstant: 112).isActive = true
        play.heightAnchor.constraint(equalToConstant: 38).isActive = true
        controls.addArrangedSubview(play)
        playPauseButton = play

        let follow = NSButton(frame: .zero)
        follow.bezelStyle = .rounded
        follow.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        follow.imagePosition = .imageLeading
        follow.target = self
        follow.action = #selector(followClicked)
        follow.widthAnchor.constraint(equalToConstant: 108).isActive = true
        follow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        controls.addArrangedSubview(follow)
        followButton = follow
        updateFollowButton()
    }

    private func timeLabel(alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "00:00")
        label.alignment = alignment
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func baseAttributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontScale.lineSpacing
        paragraph.paragraphSpacing = fontScale.pointSize * 0.72
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: sourceText,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontScale.pointSize, weight: .regular),
                .foregroundColor: VisionDesign.ink.withAlphaComponent(0.82),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func refresh(with snapshot: SpeechPlaybackSnapshot) {
        let stateTitle: String
        let buttonTitle: String
        let symbol: String
        switch snapshot.state {
        case .idle:
            stateTitle = "已停止"
            buttonTitle = "播放"
            symbol = "play.fill"
        case .loading:
            stateTitle = "准备自然语音"
            buttonTitle = "准备中"
            symbol = "waveform"
        case .playing:
            stateTitle = "正在朗读"
            buttonTitle = "暂停"
            symbol = "pause.fill"
        case .paused:
            stateTitle = "已暂停"
            buttonTitle = "继续"
            symbol = "play.fill"
        case .finished:
            stateTitle = "朗读完成"
            buttonTitle = "重新播放"
            symbol = "arrow.counterclockwise"
        }
        statusLabel?.stringValue = stateTitle
        statusLabel?.textColor = snapshot.state == .playing || snapshot.state == .loading
            ? VisionDesign.brandPurple
            : NSColor.secondaryLabelColor
        statusLabel?.layer?.backgroundColor = (
            snapshot.state == .playing || snapshot.state == .loading
                ? VisionDesign.brandPurpleSoft
                : NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        ).cgColor
        playPauseButton?.title = buttonTitle
        playPauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: buttonTitle)
        playPauseButton?.isEnabled = snapshot.state != .loading
        backendLabel?.stringValue = snapshot.backend == .local
            ? "Mac 本机声音 · 文字不离开本机"
            : "Edge 神经声音 · 自然朗读"
        elapsedLabel?.stringValue = Self.timeString(snapshot.elapsed)
        durationLabel?.stringValue = Self.timeString(snapshot.duration)
        progressSlider?.doubleValue = snapshot.progress
        progressSlider?.isEnabled = snapshot.canSeek
        selectRate(snapshot.rate)
        applyReadingHighlight(range: snapshot.currentRange, state: snapshot.state)
    }

    private func applyReadingHighlight(range: NSRange?, state: SpeechPlaybackState) {
        guard range != lastHighlightedRange || state != lastHighlightState else { return }
        guard let storage = textView?.textStorage else { return }
        let validRange = range.flatMap {
            Self.isValidTextRange($0, length: storage.length) ? $0 : nil
        }
        let nextSentence = validRange.map {
            Self.sentenceRange(containing: $0, in: sourceText)
        }

        storage.beginEditing()
        if lastHighlightedSentenceRange != nextSentence {
            if let previousSentence = lastHighlightedSentenceRange,
               Self.isValidTextRange(previousSentence, length: storage.length) {
                storage.removeAttribute(.backgroundColor, range: previousSentence)
                storage.addAttributes(baseReadingAppearance, range: previousSentence)
            }
            if let nextSentence,
               Self.isValidTextRange(nextSentence, length: storage.length) {
                storage.addAttributes(activeSentenceAppearance, range: nextSentence)
            }
        } else if let previousWord = lastHighlightedRange,
                  Self.isValidTextRange(previousWord, length: storage.length) {
            storage.removeAttribute(.backgroundColor, range: previousWord)
            storage.addAttributes(activeSentenceAppearance, range: previousWord)
        }

        if let validRange {
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: fontScale.pointSize, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: state == .paused
                        ? NSColor.systemOrange.withAlphaComponent(0.78)
                        : VisionDesign.brandPurple.withAlphaComponent(0.92)
                ],
                range: validRange
            )
        }
        storage.endEditing()

        lastHighlightedRange = validRange
        lastHighlightedSentenceRange = nextSentence
        lastHighlightState = state
        if let validRange, followsReading {
            scrollReadingRangeToVisible(validRange)
        }
    }

    private var baseReadingAppearance: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontScale.pointSize, weight: .regular),
            .foregroundColor: VisionDesign.ink.withAlphaComponent(0.82)
        ]
    }

    private var activeSentenceAppearance: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontScale.pointSize, weight: .regular),
            .foregroundColor: VisionDesign.ink
        ]
    }

    private func scrollReadingRangeToVisible(_ range: NSRange) {
        guard let textView else { return }
        programmaticScrollGeneration &+= 1
        let generation = programmaticScrollGeneration
        isProgrammaticScroll = true
        textView.scrollRangeToVisible(range)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.programmaticScrollGeneration == generation else { return }
            self.isProgrammaticScroll = false
        }
    }

    private func selectRate(_ rate: Float) {
        speedButton?.selectItem(withTitle: Self.rateTitle(rate))
    }

    @objc private func playPauseClicked() {
        SpeechService.shared.togglePause()
    }

    @objc private func followClicked() {
        setFollowsReading(true)
        if let range = SpeechService.shared.snapshot.currentRange {
            scrollReadingRangeToVisible(range)
        }
    }

    private func setFollowsReading(_ enabled: Bool) {
        guard followsReading != enabled else {
            updateFollowButton()
            return
        }
        followsReading = enabled
        updateFollowButton()
    }

    private func updateFollowButton() {
        followButton?.title = followsReading ? "自动跟随" : "继续跟随"
        followButton?.image = NSImage(
            systemSymbolName: followsReading ? "location.fill" : "location",
            accessibilityDescription: followsReading ? "正在自动跟随朗读" : "继续跟随朗读"
        )
        followButton?.contentTintColor = followsReading
            ? VisionDesign.brandPurple
            : NSColor.secondaryLabelColor
        followButton?.toolTip = followsReading
            ? "翻页或滚动后会暂停自动跟随，正文不会跳回。"
            : "回到当前朗读位置，并继续自动跟随。"
    }

    @objc private func fontScaleChanged() {
        guard let control = fontSizeControl,
              let next = SelectionReaderFontScale(rawValue: control.selectedSegment) else { return }
        setFontScale(next)
    }

    private func stepFontScale(by delta: Int) {
        let nextRawValue = min(
            SelectionReaderFontScale.allCases.count - 1,
            max(0, fontScale.rawValue + delta)
        )
        guard let next = SelectionReaderFontScale(rawValue: nextRawValue) else { return }
        setFontScale(next)
    }

    private func setFontScale(_ next: SelectionReaderFontScale) {
        fontSizeControl?.selectedSegment = next.rawValue
        guard fontScale != next else { return }
        fontScale = next
        YoumuFeatureEnvironmentStore.shared.userDefaults().set(
            next.rawValue,
            forKey: Self.fontScaleDefaultsKey
        )

        lastHighlightedRange = nil
        lastHighlightedSentenceRange = nil
        lastHighlightState = nil
        textView?.textStorage?.setAttributedString(baseAttributedText())
        applyReadingHighlight(
            range: SpeechService.shared.snapshot.currentRange,
            state: SpeechService.shared.snapshot.state
        )
    }

    @objc private func speedChanged() {
        guard let title = speedButton?.titleOfSelectedItem,
              let rate = Self.rate(from: title) else { return }
        if SpeechService.shared.setPlaybackRate(rate) {
            YoumuFeatureEnvironmentStore.shared.userDefaults().set(
                rate,
                forKey: Self.rateDefaultsKey
            )
        } else {
            selectRate(SpeechService.shared.snapshot.rate)
            ToastWindow.show(message: "本机声音播放中，请暂停结束后再改倍速")
        }
    }

    @objc private func voiceChanged() {
        guard let title = voiceButton?.titleOfSelectedItem,
              let selectedVoice = Self.voice(from: title) else { return }
        var settings = AppSettings.load()
        let previousVoice = settings.speechVoice
        guard selectedVoice != previousVoice else { return }
        settings.speechVoice = selectedVoice
        guard settings.save() else {
            voiceButton?.selectItem(withTitle: Self.voiceTitle(previousVoice))
            NSSound.beep()
            return
        }
        sessionVoice = selectedVoice
        voiceLabel?.stringValue = selectedVoice.displayName
        // Edge 音色在合成阶段确定，切换后重合成当前全文，确保眼前选择立即生效。
        SpeechService.shared.speak(
            text: sourceText,
            preferredVoice: sessionVoice
        )
    }

    @objc private func progressChanged() {
        guard let slider = progressSlider else { return }
        SpeechService.shared.seek(to: slider.doubleValue)
    }

    private func teardown(stopSpeech: Bool) {
        guard !tornDown else { return }
        tornDown = true
        if let speechObserver {
            NotificationCenter.default.removeObserver(speechObserver)
            self.speechObserver = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if stopSpeech { SpeechService.shared.stop() }
        notifyDismissIfNeeded()

        let oldPanel = panel
        oldPanel?.orderOut(nil)
        panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = oldPanel
            if SelectionReaderPanelController.current === self {
                SelectionReaderPanelController.current = nil
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        teardown(stopSpeech: true)
        return false
    }

    // MARK: - 可测试纯函数

    static func summary(_ text: String, limit: Int = 110) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        return String(format: "%02d:%02d", minutes, total % 60)
    }

    static func isValidTextRange(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && NSMaxRange(range) <= length
    }

    static func voiceTitle(_ voice: EdgeSpeechVoice) -> String {
        voice.displayName
    }

    static func voice(from title: String) -> EdgeSpeechVoice? {
        EdgeSpeechVoice.allCases.first { voiceTitle($0) == title }
    }

    static func sentenceRange(containing range: NSRange, in text: String) -> NSRange {
        let source = text as NSString
        guard source.length > 0,
              range.location != NSNotFound,
              range.location < source.length else { return NSRange(location: 0, length: 0) }
        let separators = CharacterSet(charactersIn: "。！？!?；;\n")
        var start = range.location
        while start > 0 {
            let value = source.substring(with: NSRange(location: start - 1, length: 1))
            if value.rangeOfCharacter(from: separators) != nil { break }
            start -= 1
        }
        var end = min(NSMaxRange(range), source.length)
        while end < source.length {
            let value = source.substring(with: NSRange(location: end, length: 1))
            end += 1
            if value.rangeOfCharacter(from: separators) != nil { break }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    static func rateTitle(_ rate: Float) -> String {
        let hundredths = Int((rate * 100).rounded())
        if hundredths.isMultiple(of: 100) { return String(format: "%.0f×", rate) }
        if hundredths.isMultiple(of: 10) { return String(format: "%.1f×", rate) }
        return String(format: "%.2f×", rate)
    }

    static func rate(from title: String) -> Float? {
        Float(title.replacingOccurrences(of: "×", with: ""))
    }

    static func shouldHandleKeyboardShortcut(readerIsKeyWindow: Bool) -> Bool {
        readerIsKeyWindow
    }

    static func storedFontScale(in defaults: UserDefaults? = nil) -> SelectionReaderFontScale {
        let defaults = defaults ?? YoumuFeatureEnvironmentStore.shared.userDefaults()
        guard defaults.object(forKey: fontScaleDefaultsKey) != nil else {
            return .defaultScale
        }
        return SelectionReaderFontScale(rawValue: defaults.integer(forKey: fontScaleDefaultsKey))
            ?? .defaultScale
    }
}

private final class SelectionReaderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ReaderTextView: NSTextView {
    var maximumReadingLineWidth: CGFloat = SelectionReaderVisualContract.maximumReadingLineWidth

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadingInsets(for: newSize.width)
    }

    func updateReadingInsets(for availableWidth: CGFloat) {
        let horizontalInset = max(30, (availableWidth - maximumReadingLineWidth) / 2)
        let next = NSSize(width: horizontalInset, height: 28)
        guard textContainerInset != next else { return }
        textContainerInset = next
    }
}

private final class VisionReaderBrandMarkView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        YoumuBrandMark.drawColor(in: bounds)
    }
}
