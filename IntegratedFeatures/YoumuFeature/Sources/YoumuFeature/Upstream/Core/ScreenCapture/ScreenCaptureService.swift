import AppKit

/// 把各截图模式的人体工学确认方式集中到一处，避免入口之间再次出现重复确认。
struct CaptureConfirmationPolicy: Equatable {
    let spaceConfirmsSelection: Bool
    let confirmOnMouseUp: Bool
    let showsExplicitStartAction: Bool
    let blocksScrollBeforeConfirmation: Bool

    static func resolve(mode: TranslateMode, settings: AppSettings) -> CaptureConfirmationPolicy {
        let submitsImmediately = mode == .imageTranslate
            || mode == .selectionReader
            || (mode == .silentOCR && !settings.ocrCopyRequiresConfirmation)
            || (mode == .quickSnapshot && !settings.quickSnapshotRequiresConfirmation)
        let isLongScreenshot = mode == .longScreenshot
        return CaptureConfirmationPolicy(
            spaceConfirmsSelection: !submitsImmediately,
            confirmOnMouseUp: submitsImmediately,
            // 长截图保留二次调整选区，但不再把“开始”藏在空格键里。
            showsExplicitStartAction: isLongScreenshot,
            // 真正开始前不允许底下页面滚动，否则用户会误以为正在截图。
            blocksScrollBeforeConfirmation: isLongScreenshot
        )
    }
}

enum CaptureSessionGate {
    static func canStart(
        hasSelection: Bool,
        hasInPlaceSession: Bool,
        hasLongScreenshotSession: Bool
    ) -> Bool {
        !hasSelection && !hasInPlaceSession && !hasLongScreenshotSession
    }
}

/// 屏幕截图服务：触发区域选择 → 截图 → 按模式交给后续流程
@MainActor
final class ScreenCaptureService {
    /// Host receives only a success signal, never pixels, text, or customer content.
    var successfulUse: (@MainActor () -> Void)?

    static let shared = ScreenCaptureService()

    private var selectionController: RegionSelectionController?
    private var inPlaceController: InPlaceTranslationController?
    private var retiringInPlaceControllers: [UUID: InPlaceTranslationController] = [:]
    private var activeSelectionOwner: CaptureCommandOwner?
    private var inPlaceOwner: CaptureCommandOwner?
    private var activeLongScreenshotOwner: CaptureCommandOwner?
    private var sessions = CaptureCommandSessionRegistry()
    private var processingTasks: [CaptureCommandOwner: Task<Void, Never>] = [:]
    private var longScreenshotActivityChanged: ((Bool) -> Void)?

    func setLongScreenshotActivityHandler(_ handler: ((Bool) -> Void)?) {
        longScreenshotActivityChanged = handler
    }

    /// Removes every command session before another build channel takes over or the app exits.
    func cancelActiveGlobalInputSessions() {
        cancelAllCommandSessions()
    }

    func cancelAllCommandSessions() {
        let invalidated = sessions.takeAll()
        invalidated.forEach(cancel(session:))
    }

    func invalidateCommandSessions(for reason: YoumuCommandSessionInvalidationReason) {
        let modes = CaptureCommandInvalidationPolicy.modes(affectedBy: reason)
        let phases = CaptureCommandInvalidationPolicy.phases(affectedBy: reason)
        let invalidated = sessions.take(modes: modes, phases: phases)
        invalidated.forEach(cancel(session:))
    }

    /// Host preflight calls this before entitlement and permission gates. Therefore an existing
    /// result can always honor the family toggle contract even if new invocations are now denied.
    @discardableResult
    func cancelIfActive(mode: TranslateMode) -> Bool {
        guard let active = sessions.take(mode: mode) else { return false }
        cancel(session: active)
        return true
    }

    /// 完整切换入口（快捷键与菜单栏共用）：同模式第二次取消/隐藏，不靠时间猜测。
    func toggleCapture(mode: TranslateMode) {
        // Same mode is a semantic toggle. Remove its intent synchronously, then tear down only
        // resources carrying that exact owner token.
        if cancelIfActive(mode: mode) { return }

        guard CaptureSessionGate.canStart(
            hasSelection: activeSelectionOwner != nil,
            hasInPlaceSession: inPlaceController != nil,
            hasLongScreenshotSession: activeLongScreenshotOwner != nil
        ) else {
            ToastWindow.show(message: "请先完成或取消当前截图")
            return
        }
        // 钉截图：探测剪贴板直接钉出，不需要选区，也不需要屏幕录制权限
        if mode == .pinClipboard {
            guard let owner = sessions.begin(mode: mode, phase: .presenting) else { return }
            if !PinWindowController.pinFromClipboard(
                owner: owner,
                onDismiss: presentationDidDismiss
            ) {
                sessions.finish(owner)
                ToastWindow.show(message: "剪贴板没有图片")
            } else {
                successfulUse?()
            }
            return
        }

        // macOS 26：无屏幕录制权限时调截图 API 会 SIGSEGV，必须先检查
        guard Permissions.screenRecordingStatus == .granted else {
            Permissions.openScreenRecordingSettingsIfNeeded()
            ToastWindow.show(message: "请在系统设置中开启游目的录屏与声音权限")
            return
        }
        guard let owner = sessions.begin(mode: mode) else { return }
        activeSelectionOwner = owner
        if mode == .longScreenshot {
            activeLongScreenshotOwner = owner
            longScreenshotActivityChanged?(true)
            logLongScreenshot("long_capture_requested", sessionID: owner.sessionID)
        }
        showRegionSelection(mode: mode, owner: owner)
    }

    // MARK: - 区域选择（多屏）

    private func showRegionSelection(mode: TranslateMode, owner: CaptureCommandOwner) {
        // 原图翻译走「原地覆盖」：选区后灰屏保留，会话接管遮罩生命周期
        let inPlace = (mode == .imageTranslate)
        let confirmation = CaptureConfirmationPolicy.resolve(
            mode: mode, settings: AppSettings.load()
        )
        // 十字准星只在 截图到剪贴板 / 截图标注 两模式启用（翻译类保持干净，长截图用户明确不要）
        let crosshair = (mode == .quickSnapshot || mode == .screenshotEdit)
        let controller = RegionSelectionController(
            keepOverlayOnSelection: inPlace,
            showCrosshair: crosshair,
            // 原图翻译、默认 OCR 复制及可选快速剪贴板截图松手即执行；其余用空格确认。
            spaceConfirmsSelection: confirmation.spaceConfirmsSelection,
            confirmOnMouseUp: confirmation.confirmOnMouseUp,
            confirmationActionTitle: confirmation.showsExplicitStartAction
                ? "开始长截图"
                : nil,
            blocksScrollBeforeConfirmation: confirmation.blocksScrollBeforeConfirmation,
            confirmationHint: mode == .longScreenshot
                ? "拖动边框调整 · 空格 / 回车 / 双击开始"
                : (mode == .quickSnapshot
                    ? (confirmation.confirmOnMouseUp
                        ? "松开立即复制 · Esc 取消"
                        : "空格 / 回车 / 双击复制 · 拖动调整")
                    : "空格 / 回车 / 双击确认 · 拖动调整"),
            onSelection: { [weak self] selection in
                guard let self = self else { return }
                guard self.activeSelectionOwner == owner,
                      self.sessions.isCurrent(owner, phase: .selecting) else { return }
                if mode == .longScreenshot {
                    self.logLongScreenshot(
                        "long_capture_selection_submitted",
                        sessionID: owner.sessionID,
                        metadata: [
                            "regionWidth": Int(selection.region.width.rounded()),
                            "regionHeight": Int(selection.region.height.rounded()),
                            "hasSource": selection.sourceProcessIdentifier == nil ? 0 : 1,
                            "hasSourceWindow": selection.sourceWindowID == nil ? 0 : 1,
                        ]
                    )
                }
                if inPlace {
                    self.startInPlaceTranslation(selection: selection, owner: owner)
                    return
                }
                guard self.sessions.transition(owner, to: .processing) else { return }
                // dismiss() 只 orderOut 不 close —— mouseUp 还在执行，close 会野指针
                self.selectionController?.dismiss()
                // 下一轮主事件循环再截图即可：窗口对象仍保留 0.3s，不需要额外等待 150ms。
                // 这样确认时刻与截图时刻之间不再有明显的动态内容漂移。
                DispatchQueue.main.async {
                    guard self.activeSelectionOwner == owner,
                          self.sessions.isCurrent(owner, phase: .processing) else { return }
                    self.captureAndProcess(selection, owner: owner)
                    self.retireSelectionController(owner: owner)
                }
            },
            onCancel: { [weak self] in
                guard let self,
                      self.activeSelectionOwner == owner,
                      self.sessions.isCurrent(owner, phase: .selecting) else { return }
                self.sessions.finish(owner)
                self.retireSelectionController(owner: owner)
                if mode == .longScreenshot {
                    self.logLongScreenshot(
                        "long_capture_selection_cancelled", sessionID: owner.sessionID)
                    self.clearLongScreenshotActivity(owner: owner)
                }
            }
        )
        selectionController = controller
        if mode == .longScreenshot {
            logLongScreenshot("long_capture_selection_shown", sessionID: owner.sessionID)
        }
        controller.show()
    }

    // MARK: - 原图翻译（原地覆盖会话）

    private func startInPlaceTranslation(
        selection: RegionSelectionResult,
        owner: CaptureCommandOwner
    ) {
        guard activeSelectionOwner == owner,
              sessions.transition(owner, to: .processing),
              let overlay = selectionController else { return }
        let session = InPlaceTranslationController(
            region: selection.region,
            prefetchedImage: selection.frozenImage,
            overlayController: overlay,
            onPresentationReady: { [weak self] in
                guard let self,
                      self.inPlaceOwner == owner,
                      self.canCompleteProcessing(owner),
                      self.sessions.transition(owner, to: .presenting) else { return false }
                self.successfulUse?()
                return true
            },
            onTeardownComplete: { [weak self] in
                // 会话退场完成：释放全部引用
                guard let self else { return }
                self.retiringInPlaceControllers.removeValue(forKey: owner.sessionID)
                if self.inPlaceOwner == owner {
                    self.inPlaceController = nil
                    self.inPlaceOwner = nil
                    self.selectionController = nil
                    self.activeSelectionOwner = nil
                }
                self.sessions.finish(owner)
            }
        )
        inPlaceController = session
        inPlaceOwner = owner
        session.start()
    }

    // MARK: - 截图 + 后续处理

    private func captureAndProcess(
        _ selection: RegionSelectionResult,
        owner: CaptureCommandOwner
    ) {
        guard canCompleteProcessing(owner) else { return }
        let mode = owner.mode
        let region = selection.region
        // 长截图：选区冻结图只服务选区 UI，绝不再混作实时拼接首帧。目标身份由精确
        // PID + Window ID + 选区覆盖关系决定，不再把“是否 frontmost”误当成窗口身份。
        if mode == .longScreenshot {
            guard activeLongScreenshotOwner == owner else { return }
            let startController: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self,
                      self.activeLongScreenshotOwner == owner,
                      self.canCompleteProcessing(owner) else { return }
                let started = ScrollCaptureController.shared.start(
                    region: region,
                    sourceProcessIdentifier: selection.sourceProcessIdentifier,
                    sourceWindowID: selection.sourceWindowID,
                    sessionIdentifier: owner.sessionID
                ) { [weak self] result in
                    self?.handleLongScreenshotResult(result, owner: owner)
                }
                self.logLongScreenshot(
                    started
                        ? "long_capture_controller_start_accepted"
                        : "long_capture_controller_start_rejected",
                    sessionID: owner.sessionID
                )
                if !started {
                    ToastWindow.show(message: "请先完成或取消当前长截图")
                    self.clearLongScreenshotActivity(owner: owner)
                    self.sessions.finish(owner)
                }
            }

            startLongScreenshotWhenSourceIsReady(
                processIdentifier: selection.sourceProcessIdentifier,
                owner: owner,
                startController: startController
            )
            return
        }

        // 截图必须在主线程做 —— CGWindowListCreateImage 内部会触发 TCC XPC 检查，
        // 后台线程调用会跟主线程 autorelease pool 冲突导致 SIGSEGV
        // 普通截图优先裁选区启动前的冻结画面：即使菜单随后被系统收起，成品仍保留。
        let image = selection.frozenImage ?? CGWindowListCreateImage(
            region, .optionOnScreenOnly, kCGNullWindowID,
            ScreenCaptureRasterPolicy.pixelAccurateOptions
        )
        guard let image else {
            sessions.finish(owner)
            showErrorAlert(CaptureError.captureFailed)
            return
        }

        // 记录最近一次截图（菜单栏「钉图」数据源；quickSnapshot 只进剪贴板，不写）
        if mode != .quickSnapshot && mode != .selectionReader {
            LastCaptureStore.shared.store(
                image, pixelScale: region.width > 0 ? CGFloat(image.width) / region.width : 2
            )
        }

        switch mode {
        case .silentOCR:
            processSilentOCR(image, region: region, owner: owner)
        case .screenshotEdit:
            processScreenshotEdit(image, region: region, owner: owner)
        case .quickSnapshot:
            processQuickSnapshot(image, region: region)
            successfulUse?()
            sessions.finish(owner)
        case .screenshotTranslate:
            processTranslation(image, owner: owner)
        case .imageTranslate:
            break // 原地覆盖会话已在选区回调接管，不会走到这里
        case .longScreenshot:
            break // 已在上方提前拦截，交给 ScrollCaptureController
        case .pinClipboard:
            break // 已在 toggleCapture 入口分流，不走选区
        case .selectionReader:
            processSelectionReader(image, region: region, owner: owner)
        }
    }

    /// nonactivating 选区不改变前台 App。完成上一张后编辑器可能仍让宿主保持 active，
    /// 但只要选中的目标进程还存活，后续由精确 Window ID 校验决定是否允许开始。
    /// 这里不主动 activate 任何进程，避免关闭菜单/弹层或唤醒宿主主窗口。
    private func startLongScreenshotWhenSourceIsReady(
        processIdentifier: pid_t?,
        owner: CaptureCommandOwner,
        startController: @escaping @MainActor @Sendable () -> Void
    ) {
        guard activeLongScreenshotOwner == owner,
              canCompleteProcessing(owner) else { return }
        guard let processIdentifier,
              processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logLongScreenshot("long_capture_source_missing", sessionID: owner.sessionID)
            ToastWindow.show(message: "未找到选区对应的目标窗口，长截图未开始")
            clearLongScreenshotActivity(owner: owner)
            sessions.finish(owner)
            return
        }
        guard let sourceApplication = NSRunningApplication(
            processIdentifier: processIdentifier
        ), !sourceApplication.isTerminated else {
            logLongScreenshot("long_capture_source_terminated", sessionID: owner.sessionID)
            ToastWindow.show(message: "目标窗口已经关闭，长截图未开始")
            clearLongScreenshotActivity(owner: owner)
            sessions.finish(owner)
            return
        }

        logLongScreenshot("long_capture_source_ready", sessionID: owner.sessionID)
        DispatchQueue.main.async(execute: startController)
    }

    private func retireSelectionController(owner: CaptureCommandOwner) {
        guard activeSelectionOwner == owner else { return }
        let retired = selectionController
        retired?.dismiss()
        selectionController = nil
        activeSelectionOwner = nil
        // The property is cleared immediately so a true next press is accepted. This local strong
        // capture preserves the overlay through the AppKit event-loop safety window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = retired
        }
    }

    private func retireInPlaceController(owner: CaptureCommandOwner) {
        guard inPlaceOwner == owner, let controller = inPlaceController else { return }
        retiringInPlaceControllers[owner.sessionID] = controller
        inPlaceController = nil
        inPlaceOwner = nil
        activeSelectionOwner = nil
        selectionController = nil
        controller.cancelActiveSession()
    }

    private func clearLongScreenshotActivity(owner: CaptureCommandOwner) {
        guard activeLongScreenshotOwner == owner else { return }
        activeLongScreenshotOwner = nil
        longScreenshotActivityChanged?(false)
    }

    private func handleLongScreenshotResult(
        _ result: ScrollCaptureController.SessionResult,
        owner: CaptureCommandOwner
    ) {
        clearLongScreenshotActivity(owner: owner)
        switch result {
        case .cancelled:
            sessions.finish(owner)
        case .finished(let image, let pixelScale, let partialReason):
            guard canCompleteProcessing(owner),
                  sessions.transition(owner, to: .presenting) else { return }
            LastCaptureStore.shared.store(image, pixelScale: pixelScale)
            successfulUse?()
            EditorWindowController.show(
                image: image,
                pixelScale: pixelScale,
                owner: owner,
                onDismiss: presentationDidDismiss
            )
            if let partialReason {
                ToastWindow.show(message: partialReason)
            }
            PrivacySafeLog.event(
                "long_capture_editor_presented",
                metadata: ["session": owner.sessionID.hashValue & Int(Int32.max)]
            )
        }
    }

    private func presentationDidDismiss(_ owner: CaptureCommandOwner) {
        processingTasks.removeValue(forKey: owner)?.cancel()
        sessions.finish(owner)
    }

    /// External TCC state can change while the host is inactive, before AppModel observes the
    /// lifecycle edge. Recheck at every processing boundary so a completed background task cannot
    /// publish a result first and thereby escape the processing-only invalidation policy.
    private func canCompleteProcessing(_ owner: CaptureCommandOwner) -> Bool {
        guard sessions.isCurrent(owner, phase: .processing) else { return false }
        guard Permissions.screenRecordingStatus == .granted else {
            invalidateCommandSessions(for: .screenRecordingPermissionLost)
            return false
        }
        if owner.mode == .longScreenshot, !Permissions.inputMonitoringGranted {
            invalidateCommandSessions(for: .inputMonitoringPermissionLost)
            return false
        }
        return sessions.isCurrent(owner, phase: .processing)
    }

    private func cancel(session: CaptureCommandSession) {
        let owner = session.owner
        processingTasks.removeValue(forKey: owner)?.cancel()

        if inPlaceOwner == owner {
            retireInPlaceController(owner: owner)
        } else if activeSelectionOwner == owner {
            retireSelectionController(owner: owner)
        }

        if activeLongScreenshotOwner == owner {
            clearLongScreenshotActivity(owner: owner)
            ScrollCaptureController.shared.cancelActiveSession()
        }

        guard session.phase == .presenting else { return }
        switch owner.mode {
        case .screenshotEdit, .longScreenshot:
            EditorWindowController.dismiss(owner: owner)
        case .pinClipboard:
            // The owner may still be on the Pin surface or may have been atomically transferred
            // to its downstream editor. Both lookups are exact-owner O(1) and cannot hit manual
            // unowned editors or another capture mode.
            PinWindowController.dismiss(owner: owner)
            EditorWindowController.dismiss(owner: owner)
        case .selectionReader:
            SelectionReaderPanelController.dismiss(owner: owner)
        case .imageTranslate:
            // The in-place controller was handled above because it also owns the selection overlay.
            break
        case .screenshotTranslate:
            TranslationPopupWindow.dismiss(owner: owner)
        case .silentOCR:
            OCRCopyPanelController.dismiss(owner: owner)
        case .quickSnapshot:
            break
        }
    }

    private func logLongScreenshot(
        _ name: String,
        sessionID: UUID,
        metadata: [String: Int] = [:]
    ) {
        var fields = metadata
        fields["session"] = sessionID.hashValue & Int(Int32.max)
        PrivacySafeLog.event(name, metadata: fields)
    }

    // MARK: - 截图到剪贴板：选区 → 剪贴板（PNG+TIFF）→ 系统音效，无任何窗口

    private func processQuickSnapshot(_ image: CGImage, region: CGRect) {
        // 成品保留物理像素，同时把截图当时的点/像素倍率写进剪贴板。
        // 后续“钉截图”据此还原原选区视觉尺寸，不会在 Retina 屏上放大一倍。
        let pixelScale = region.width > 0
            ? CGFloat(image.width) / region.width
            : (NSScreen.main?.backingScaleFactor ?? 1)
        ImageComposer.copyToPasteboard(
            base: image, pixelScale: pixelScale, annotations: []
        )
        // 系统截图音效（Grab.aif），找不到时退回通用提示音
        let grabPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        let sound = NSSound(contentsOfFile: grabPath, byReference: true)
            ?? NSSound(named: "Pop")
        sound?.play()
    }

    // MARK: - OCR 复制：选区 → OCR → 剪贴板 + 可编辑迷你框

    private func processSilentOCR(
        _ image: CGImage,
        region: CGRect,
        owner: CaptureCommandOwner
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let ocrResults = try await OCRService.shared.recognizeText(from: image)
                let text = OCRService.shared.assembleText(from: ocrResults)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !Task.isCancelled,
                      self.canCompleteProcessing(owner) else { return }
                self.processingTasks.removeValue(forKey: owner)
                guard !text.isEmpty else {
                    self.sessions.finish(owner)
                    // 识别失败：只提示，不弹框
                    ToastWindow.show(message: "未识别到文字")
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.setString(text, forType: .string) { self.successfulUse?() }
                ToastWindow.show(message: "已复制 \(text.count) 个字符")
                guard self.sessions.transition(owner, to: .presenting) else { return }
                // 弹出可编辑迷你框（编辑后可重新复制、可朗读）
                OCRCopyPanelController.show(
                    text: text,
                    near: region,
                    owner: owner,
                    onDismiss: self.presentationDidDismiss
                )
            } catch {
                self.processingTasks.removeValue(forKey: owner)
                guard self.sessions.finish(owner) else { return }
                if error is CancellationError { return }
                self.showErrorAlert(error)
            }
        }
        processingTasks[owner] = task
    }

    // MARK: - 选哪读哪：选区 → 本机 OCR → 极简朗读器（松手即执行）

    private func processSelectionReader(
        _ image: CGImage,
        region: CGRect,
        owner: CaptureCommandOwner
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let blocks = try await OCRService.shared.recognizeText(from: image)
                let text = OCRService.shared.assembleText(from: blocks)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled,
                      self.canCompleteProcessing(owner) else { return }
                self.processingTasks.removeValue(forKey: owner)
                guard !text.isEmpty else {
                    self.sessions.finish(owner)
                    ToastWindow.show(message: "未识别到可朗读文字")
                    return
                }
                guard self.sessions.transition(owner, to: .presenting) else { return }
                self.successfulUse?()
                SelectionReaderPanelController.show(
                    text: text,
                    near: region,
                    owner: owner,
                    onDismiss: self.presentationDidDismiss
                )
            } catch {
                self.processingTasks.removeValue(forKey: owner)
                guard self.sessions.finish(owner) else { return }
                if error is CancellationError { return }
                self.showErrorAlert(error)
            }
        }
        processingTasks[owner] = task
    }

    // MARK: - 截图标注：打开编辑器（矩形/箭头/画笔/马赛克/文字）

    private func processScreenshotEdit(
        _ image: CGImage,
        region: CGRect,
        owner: CaptureCommandOwner
    ) {
        // Retina 像素倍率：截图按 bestResolution 保留物理像素，像素 = 点 × scale
        let pixelScale = region.width > 0 ? CGFloat(image.width) / region.width : 2
        guard canCompleteProcessing(owner),
              sessions.transition(owner, to: .presenting) else { return }
        successfulUse?()
        EditorWindowController.show(
            image: image,
            pixelScale: pixelScale,
            owner: owner,
            onDismiss: presentationDidDismiss
        )
    }

    // MARK: - 翻译流程（截图翻译弹窗）

    private func processTranslation(_ image: CGImage, owner: CaptureCommandOwner) {
        // OCR + 翻译放后台
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let ocrResults = try await OCRService.shared.recognizeText(from: image)
                guard !Task.isCancelled,
                      self.canCompleteProcessing(owner) else { return }
                guard !ocrResults.isEmpty else {
                    self.processingTasks.removeValue(forKey: owner)
                    self.sessions.finish(owner)
                    self.showNoTextAlert()
                    return
                }

                let settings = AppSettings.load()
                let sourceText = ocrResults.map(\.text).joined(separator: "\n")
                let translatedText = try await TranslationService.shared.translate(
                    text: sourceText,
                    targetLanguage: settings.targetLanguage
                )
                guard !Task.isCancelled,
                      self.canCompleteProcessing(owner) else { return }
                self.processingTasks.removeValue(forKey: owner)
                guard self.sessions.transition(owner, to: .presenting) else { return }
                self.successfulUse?()
                TranslationPopupWindow.show(
                    originalText: sourceText,
                    translatedText: translatedText,
                    owner: owner,
                    onDismiss: self.presentationDidDismiss
                )
            } catch {
                self.processingTasks.removeValue(forKey: owner)
                guard self.sessions.finish(owner) else { return }
                if error is CancellationError { return }
                self.showErrorAlert(error)
            }
        }
        processingTasks[owner] = task
    }

    // MARK: - Alerts

    private func showNoTextAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "未识别到文字"
        alert.informativeText = "截图区域中没有可识别的文字内容，请重新选择。"
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showErrorAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "出错了"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

enum CaptureError: LocalizedError {
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "截图失败，请确认已授予屏幕录制权限"
        }
    }
}
