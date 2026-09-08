import AppKit
import ApplicationServices
import Foundation

nonisolated private struct ScrollCaptureInitialWorkResult: @unchecked Sendable {
    let update: ScrollingCaptureStitchUpdate?
    let preview: CGImage?
}

nonisolated private struct ScrollCaptureCommitWorkResult: @unchecked Sendable {
    let update: ScrollingCaptureStitchUpdate?
    let preview: CGImage?
    let queueDelayMs: Int
    let workMs: Int
}

nonisolated private struct ScrollCaptureFinalWorkResult: @unchecked Sendable {
    let image: CGImage?
    let acceptedFrameCount: Int
}

nonisolated enum ScrollCaptureCommand: Equatable, Sendable {
    case finish
    case cancel
}

nonisolated enum ScrollCaptureCommandDisposition: Equatable, Sendable {
    case passThrough
    case consume
    case consumeAndDispatch(ScrollCaptureCommand)
}

nonisolated enum ScrollCaptureCommandPolicy {
    static func disposition(
        keyCode: UInt16,
        flags: CGEventFlags,
        eventType: CGEventType,
        isCapturing: Bool,
        isFinishing: Bool,
        isRepeat: Bool
    ) -> ScrollCaptureCommandDisposition {
        guard isCapturing || isFinishing else { return .passThrough }

        if keyCode == 49 { // Space
            let shortcutModifiers: CGEventFlags = [
                .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
            ]
            guard flags.intersection(shortcutModifiers).isEmpty else {
                return .passThrough
            }
            if eventType == .keyUp || isRepeat || isFinishing {
                return .consume
            }
            return eventType == .keyDown
                ? .consumeAndDispatch(.finish)
                : .passThrough
        }

        if keyCode == 53 { // Escape
            if eventType == .keyUp || isRepeat || isFinishing {
                return .consume
            }
            return eventType == .keyDown
                ? .consumeAndDispatch(.cancel)
                : .passThrough
        }
        return .passThrough
    }
}

/// Locks the routing decision for one physical key press. Modifier flags can change between
/// keyDown and keyUp; Chrome must either receive the complete pair or neither half of it.
nonisolated struct ScrollCaptureCommandRouter {
    private var consumesPressByKeyCode: [UInt16: Bool] = [:]

    mutating func disposition(
        keyCode: UInt16,
        flags: CGEventFlags,
        eventType: CGEventType,
        isCapturing: Bool,
        isFinishing: Bool,
        isRepeat: Bool
    ) -> ScrollCaptureCommandDisposition {
        let isCommandKey = keyCode == 49 || keyCode == 53
        guard isCommandKey else { return .passThrough }

        if eventType == .keyDown, !isRepeat {
            let decision = ScrollCaptureCommandPolicy.disposition(
                keyCode: keyCode,
                flags: flags,
                eventType: eventType,
                isCapturing: isCapturing,
                isFinishing: isFinishing,
                isRepeat: false
            )
            consumesPressByKeyCode[keyCode] = decision != .passThrough
            return decision
        }

        if let consumesPress = consumesPressByKeyCode[keyCode] {
            if eventType == .keyUp {
                consumesPressByKeyCode.removeValue(forKey: keyCode)
            }
            return consumesPress ? .consume : .passThrough
        }

        // The tap is installed after the selection Space keyDown, so its first observed event can
        // legitimately be that press's repeat or keyUp. Fall back to the stateless policy for it.
        return ScrollCaptureCommandPolicy.disposition(
            keyCode: keyCode,
            flags: flags,
            eventType: eventType,
            isCapturing: isCapturing,
            isFinishing: isFinishing,
            isRepeat: isRepeat
        )
    }
}

/// 捕获期间唯一的键盘过滤器。NSEvent 全局 monitor 只能旁听，无法阻止 Chrome
/// 同时收到 Space；这里仅吞裸 Space / Escape，不接管任何滚轮或其他按键。
private final class ScrollCaptureCommandKeyTap: @unchecked Sendable {
    private enum Phase { case capturing, finishing }

    private let onCommand: @Sendable (ScrollCaptureCommand) -> Void
    private var phase: Phase = .capturing
    private var commandRouter = ScrollCaptureCommandRouter()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onCommand: @escaping @Sendable (ScrollCaptureCommand) -> Void) {
        self.onCommand = onCommand
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ScrollCaptureCommandKeyTap>
                .fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.reenable()
                return Unmanaged.passUnretained(event)
            }
            return owner.filter(event: event, type: type)
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, eventTap, 0
        ) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            return false
        }
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func beginFinishing() {
        phase = .finishing
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func reenable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func filter(
        event: CGEvent,
        type: CGEventType
    ) -> Unmanaged<CGEvent>? {
        let disposition = commandRouter.disposition(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            eventType: type,
            isCapturing: phase == .capturing,
            isFinishing: phase == .finishing,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        switch disposition {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .consumeAndDispatch(let command):
            DispatchQueue.main.async { [onCommand] in onCommand(command) }
            return nil
        }
    }
}

/// ScreenCaptureKit-based long screenshot coordinator.
///
/// The source application's wheel input is never intercepted or replayed. A passive global
/// monitor supplies an expected displacement, while the SCStream is the only frame producer.
@MainActor
final class ScrollCaptureController {
    enum SessionResult {
        case cancelled
        case finished(image: CGImage, pixelScale: CGFloat, partialReason: String?)
    }

    static let shared = ScrollCaptureController()

    private enum State {
        case idle
        case waitingFirstCompleteFrame
        case initializingFirstCompleteFrame
        case capturing
        case finishing
    }

    private enum CommitOrigin: String {
        case manualWheel = "manual-wheel"
        case streamChange = "stream-change"
        case recovery = "recovery"
        case finalFrame = "final-frame"
    }

    private struct CommitRequest: @unchecked Sendable {
        let frame: ScrollCaptureStreamFrame
        let expectedDeltaPixels: Int?
        let expectedDeltaPoints: CGFloat?
        let origin: CommitOrigin

        init(
            frame: ScrollCaptureStreamFrame,
            expectedDeltaPixels: Int?,
            expectedDeltaPoints: CGFloat? = nil,
            origin: CommitOrigin
        ) {
            self.frame = frame
            self.expectedDeltaPixels = expectedDeltaPixels
            self.expectedDeltaPoints = expectedDeltaPoints
            self.origin = origin
        }
    }

    private var state: State = .idle
    private var region: CGRect = .zero
    private var sourceProcessIdentifier: pid_t?
    private var sourceWindowID: CGWindowID?
    private var sessionID = UUID()
    private var onSessionEnd: ((SessionResult) -> Void)?
    private var discardFinishedOutput = false

    private let processingQueue = DispatchQueue(
        label: "cn.tlww.aixlg.youmu.long-capture.commit",
        qos: .userInitiated
    )
    private var frameSource: ScrollCaptureFrameSource?
    private var frameRing = ScrollCaptureFrameRing(capacity: 8)
    private var stitcher: ScrollingCaptureStitcher?
    /// Highest stream sequence that the stitcher safely consumed. Alignment failures never move
    /// this anchor; a later buffered frame may still bridge the missing overlap.
    private var lastAcceptedSequenceNumber = 0
    /// Diagnostic/progress watermark only. It must never be used as the stitch baseline.
    private var lastAttemptedSequenceNumber = 0
    private var commitInFlight = false
    private var activeCommitRequest: CommitRequest?
    /// Oldest-first, bounded requests. Each request owns its frame even after ring eviction.
    private var pendingCommits: [CommitRequest] = []
    private var failedCommitSequences: Set<Int> = []
    private var acceptedFrameCount = 0
    private var consecutiveAlignmentFailures = 0
    private var pixelScale: CGFloat = 1
    private var pendingExpectedScrollPoints: CGFloat = 0
    private var lastCommitRequestedAt: TimeInterval?
    private var lastStreamFrameAt: TimeInterval?
    private var latestStreamSequenceNumber = 0
    private var finishCutoffSequenceNumber: Int?
    private var finishDrainAttemptsRemaining = 0
    private var finishExplicitPartialReason: String?
    private var finishRequestedBeforeFirstFrame = false
    private var firstCompleteFrameGate = ScrollCaptureFirstCompleteFrameGate()

    private var scrollGlobalMonitor: Any?
    private var commandKeyTap: ScrollCaptureCommandKeyTap?
    private var streamStartupTask: Task<Void, Never>?
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    private var streamSettleWorkItem: DispatchWorkItem?
    private var periodicCommitTimer: Timer?

    private var statusPanel: NSPanel?
    private var statusLabel: NSTextField?
    private var controlPanel: NSPanel?
    private var finishButton: NSButton?
    private var boundaryPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var previewImageView: NSImageView?
    private var previewTruthLabel: NSTextField?

    private init() {}

    @discardableResult
    func start(
        region: CGRect,
        sourceProcessIdentifier: pid_t?,
        sourceWindowID: CGWindowID?,
        sessionIdentifier: UUID? = nil,
        onSessionEnd: ((SessionResult) -> Void)? = nil
    ) -> Bool {
        guard state == .idle else { return false }
        guard region.width >= 8, region.height >= 8,
              let sourceProcessIdentifier,
              sourceProcessIdentifier != ProcessInfo.processInfo.processIdentifier,
              let sourceWindowID else {
            ToastWindow.show(message: "未找到选区对应的目标窗口，长截图未开始")
            return false
        }
        guard ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
            region: region,
            candidates: RegionSelectionController.visibleSourceWindowCandidates(),
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier,
            sourceWindowID: sourceWindowID
        ) else {
            ToastWindow.show(message: "目标窗口已切换，请重新框选长截图区域")
            return false
        }

        self.region = region
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.sourceWindowID = sourceWindowID
        self.sessionID = sessionIdentifier ?? UUID()
        self.onSessionEnd = onSessionEnd
        state = .waitingFirstCompleteFrame
        discardFinishedOutput = false
        frameRing.reset()
        stitcher = ScrollingCaptureStitcher()
        lastAcceptedSequenceNumber = 0
        lastAttemptedSequenceNumber = 0
        commitInFlight = false
        activeCommitRequest = nil
        pendingCommits.removeAll(keepingCapacity: true)
        failedCommitSequences.removeAll()
        acceptedFrameCount = 0
        consecutiveAlignmentFailures = 0
        pixelScale = 1
        pendingExpectedScrollPoints = 0
        lastCommitRequestedAt = nil
        lastStreamFrameAt = nil
        latestStreamSequenceNumber = 0
        finishCutoffSequenceNumber = nil
        finishDrainAttemptsRemaining = 0
        finishExplicitPartialReason = nil
        finishRequestedBeforeFirstFrame = false
        firstCompleteFrameGate.reset()
        showStatusPanel(text: "正在锁定实时画面…")
        installPassiveInputObservers()
        installCommandKeyTap()
        logDiagnostic(
            "long_capture_stream_preparing",
            metadata: [
                "regionWidth": Int(region.width.rounded()),
                "regionHeight": Int(region.height.rounded()),
            ]
        )

        let frameSource = ScrollCaptureFrameSource()
        self.frameSource = frameSource
        let capturedSessionID = self.sessionID
        scheduleFirstFrameTimeout(sessionID: capturedSessionID)
        let startupTask = Task { @MainActor [weak self, frameSource] in
            guard let self else { return }
            do {
                try await frameSource.start(
                    region: region,
                    sourceWindowID: sourceWindowID,
                    frameHandler: { [weak self] frame in
                        self?.handleStreamFrame(frame, sessionID: capturedSessionID)
                    },
                    failureHandler: { [weak self] error in
                        self?.handleStreamFailure(error, sessionID: capturedSessionID)
                    }
                )
                guard self.sessionID == capturedSessionID,
                      self.frameSource === frameSource,
                      self.state != .idle else {
                    frameSource.stop()
                    return
                }
                self.streamStartupTask = nil
                self.logDiagnostic("long_capture_stream_started")
            } catch {
                frameSource.stop()
                guard self.sessionID == capturedSessionID,
                      self.state != .idle else { return }
                self.streamStartupTask = nil
                if error is CancellationError {
                    self.cancel(showToast: false, reason: "stream_start_cancelled")
                    return
                }
                self.logDiagnostic("long_capture_stream_start_failed")
                ToastWindow.show(message: "长截图实时取帧启动失败：\(error.localizedDescription)")
                self.cancel(showToast: false, reason: "stream_start_failed")
            }
        }
        streamStartupTask = startupTask
        return true
    }

    private func handleStreamFrame(_ frame: ScrollCaptureStreamFrame, sessionID: UUID) {
        guard self.sessionID == sessionID,
              state == .waitingFirstCompleteFrame
                || state == .initializingFirstCompleteFrame
                || state == .capturing
                || state == .finishing
        else { return }
        guard frame.sequenceNumber > latestStreamSequenceNumber else { return }
        if state == .finishing,
           let finishCutoffSequenceNumber,
           frame.sequenceNumber > finishCutoffSequenceNumber {
            return
        }

        frameRing.append(frame)
        latestStreamSequenceNumber = frame.sequenceNumber
        lastStreamFrameAt = frame.capturedAt

        if state == .waitingFirstCompleteFrame {
            guard firstCompleteFrameGate.claim() else { return }
            state = .initializingFirstCompleteFrame
            initializeWithFirstLiveFrame(frame)
            return
        }
        if state == .initializingFirstCompleteFrame { return }

        guard state == .capturing, frame.containsVisualChange else { return }

        // Covers scrollbar drags and scripted scrolling without coupling screenshot creation to
        // an input event. During physical wheel scrolling, the shorter wheel settle timer wins.
        scheduleSettledCommit(origin: .streamChange, delay: 0.085)
    }

    private func initializeWithFirstLiveFrame(_ frame: ScrollCaptureStreamFrame) {
        guard state == .initializingFirstCompleteFrame,
              let stitcher else { return }
        commitInFlight = true
        let capturedSessionID = sessionID
        let completion: @MainActor @Sendable (ScrollCaptureInitialWorkResult) -> Void = {
            [weak self, stitcher] result in
            guard let self,
                  self.sessionID == capturedSessionID,
                  self.state == .initializingFirstCompleteFrame,
                  self.stitcher === stitcher else { return }
            self.commitInFlight = false
            guard result.update != nil else {
                self.logDiagnostic("long_capture_first_live_frame_invalid")
                ToastWindow.show(message: "首个实时画面无法读取，长截图未开始")
                self.cancel(showToast: false, reason: "first_frame_invalid")
                return
            }
            self.firstFrameTimeoutWorkItem?.cancel()
            self.firstFrameTimeoutWorkItem = nil
            self.lastAcceptedSequenceNumber = frame.sequenceNumber
            self.lastAttemptedSequenceNumber = frame.sequenceNumber
            self.acceptedFrameCount = 1
            self.pixelScale = self.region.width > 0
                ? CGFloat(frame.image.width) / self.region.width
                : 1
            self.state = .capturing
            self.showCaptureUI()
            self.startPeriodicCommitTimer()
            self.updatePreview(result.preview ?? frame.image, truth: "已拼")
            self.updateStatus()
            self.logDiagnostic(
                "long_capture_first_live_frame_ready",
                metadata: [
                    "frameWidth": frame.image.width,
                    "frameHeight": frame.image.height,
                    "sequence": frame.sequenceNumber,
                ]
            )
            if self.finishRequestedBeforeFirstFrame {
                self.finishRequestedBeforeFirstFrame = false
                self.finish()
            }
        }
        processingQueue.async { [stitcher, completion] in
            let update = stitcher.start(with: frame.image)
            let preview = stitcher.previewImage(maxPixelWidth: 192, maxPixelHeight: 1_600)
            let result = ScrollCaptureInitialWorkResult(update: update, preview: preview)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private func handleStreamFailure(_ error: Error, sessionID: UUID) {
        guard self.sessionID == sessionID, state != .idle else { return }
        logDiagnostic("long_capture_stream_failed")
        ToastWindow.show(message: "长截图实时画面已中断：\(error.localizedDescription)")
        cancel(showToast: false, reason: "stream_failed")
    }

    private func scheduleFirstFrameTimeout(sessionID: UUID) {
        firstFrameTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionID == sessionID,
                  self.state == .waitingFirstCompleteFrame
                    || self.state == .initializingFirstCompleteFrame else { return }
            self.logDiagnostic("long_capture_first_frame_timeout")
            ToastWindow.show(message: "实时预览启动超时，请重新框选后再试")
            self.cancel(showToast: false, reason: "first_frame_timeout")
        }
        firstFrameTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScrollCapturePolicy.firstCompleteFrameTimeout,
            execute: workItem
        )
    }

    // MARK: Passive input observation

    private func installPassiveInputObservers() {
        guard scrollGlobalMonitor == nil else { return }
        scrollGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.observeWheel(event)
            }
        }
    }

    private func observeWheel(_ event: NSEvent) {
        guard state == .capturing else { return }

        let cursor = ScrollCapturePanelLayout.currentQuartzMouseLocation()
        guard region.insetBy(dx: -24, dy: -24).contains(cursor) else { return }
        let vertical = abs(event.scrollingDeltaY)
        let horizontal = abs(event.scrollingDeltaX)
        guard vertical >= max(horizontal, 0.01) else { return }

        // NSEvent uses a negative deltaY for the common downward/content-forward gesture. The
        // stitcher contract uses positive for appending from the bottom and negative for moving
        // back upward, so preserve the sign instead of collapsing both directions with abs().
        let rawPoints = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 18
        let signedPoints = -rawPoints
        guard abs(signedPoints) >= 0.25 else { return }
        pendingExpectedScrollPoints += signedPoints

        let now = ProcessInfo.processInfo.systemUptime
        let shouldForce = abs(pendingExpectedScrollPoints) >= 36
            || now - (lastCommitRequestedAt ?? 0) >= 0.12
        if shouldForce {
            requestCommit(origin: .manualWheel)
        } else {
            scheduleSettledCommit(origin: .manualWheel, delay: 0.05)
        }
    }

    private func removePassiveInputObservers() {
        if let scrollGlobalMonitor {
            NSEvent.removeMonitor(scrollGlobalMonitor)
            self.scrollGlobalMonitor = nil
        }
    }

    private func installCommandKeyTap() {
        guard commandKeyTap == nil else { return }
        let capturedSessionID = sessionID
        let tap = ScrollCaptureCommandKeyTap { [weak self] command in
            Task { @MainActor [weak self] in
                self?.handleCaptureCommand(command, sessionID: capturedSessionID)
            }
        }
        guard tap.start() else {
            logDiagnostic("long_capture_command_key_tap_unavailable")
            ToastWindow.show(message: "空格结束暂不可用，请点击“完成”")
            return
        }
        commandKeyTap = tap
        logDiagnostic("long_capture_command_key_tap_started")
    }

    private func removeCommandKeyTap() {
        commandKeyTap?.stop()
        commandKeyTap = nil
    }

    private func handleCaptureCommand(
        _ command: ScrollCaptureCommand,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID else { return }
        switch command {
        case .finish:
            switch state {
            case .waitingFirstCompleteFrame, .initializingFirstCompleteFrame:
                finishRequestedBeforeFirstFrame = true
                statusLabel?.stringValue = "首帧就绪后完成…"
                logDiagnostic("long_capture_space_finish_queued")
            case .capturing:
                logDiagnostic("long_capture_space_finish_pressed")
                finish()
            case .idle, .finishing:
                break
            }
        case .cancel:
            guard state != .idle else { return }
            cancel()
        }
    }

    // MARK: Commit lane

    private func scheduleSettledCommit(origin: CommitOrigin, delay: TimeInterval) {
        streamSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.requestCommit(origin: origin)
        }
        streamSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func requestCommit(
        origin: CommitOrigin,
        afterSequenceNumber: Int? = nil,
        displayedAfter displayTimeBarrier: UInt64? = nil
    ) {
        guard state == .capturing || state == .finishing else { return }
        guard sourceWindowIsStillTarget() || state == .finishing else {
            ToastWindow.show(message: "目标窗口已切换，长截图已取消")
            cancel(showToast: false, reason: "source_window_changed")
            return
        }
        let sequenceFloor = max(
            lastAcceptedSequenceNumber,
            afterSequenceNumber ?? lastAcceptedSequenceNumber
        )
        var excludedSequences = failedCommitSequences
        if let activeCommitRequest {
            excludedSequences.insert(activeCommitRequest.frame.sequenceNumber)
        }
        excludedSequences.formUnion(pendingCommits.map { $0.frame.sequenceNumber })
        let frame: ScrollCaptureStreamFrame?
        if origin == .recovery,
           let recoverySequence = ScrollCaptureRecoveryPolicy.nextSequence(
            lastAcceptedSequence: sequenceFloor,
            recoveryCeilingSequence: finishCutoffSequenceNumber
                ?? latestStreamSequenceNumber,
            failedSequences: excludedSequences,
            availableSequences: frameRing.frames.map(\.sequenceNumber)
           ) {
            frame = frameRing.frame(sequenceNumber: recoverySequence)
        } else {
            frame = frameRing.earliest(
                after: sequenceFloor,
                through: finishCutoffSequenceNumber,
                excluding: excludedSequences,
                displayedAfter: displayTimeBarrier
            )
        }
        guard let frame else {
            if state == .finishing, !commitInFlight {
                drainAndFinalize()
            }
            return
        }

        let alreadyCarriesExpectedDelta = activeCommitRequest?.expectedDeltaPoints != nil
            || pendingCommits.contains(where: { $0.expectedDeltaPoints != nil })
        let expectedPoints: CGFloat? = origin == .recovery || origin == .finalFrame
            || alreadyCarriesExpectedDelta || abs(pendingExpectedScrollPoints) < 2
                ? nil
                : pendingExpectedScrollPoints
        let expectedPixels = expectedPoints.map { points -> Int in
            let rounded = Int((points * pixelScale).rounded())
            if rounded != 0 { return rounded }
            return points < 0 ? -1 : 1
        }
        let request = CommitRequest(
            frame: frame,
            expectedDeltaPixels: expectedPixels,
            expectedDeltaPoints: expectedPoints,
            origin: origin
        )
        lastCommitRequestedAt = ProcessInfo.processInfo.systemUptime
        enqueueCommit(request)
    }

    private func enqueueCommit(_ request: CommitRequest, launchIfIdle: Bool = true) {
        let sequenceNumber = request.frame.sequenceNumber
        guard sequenceNumber > lastAcceptedSequenceNumber,
              !failedCommitSequences.contains(sequenceNumber),
              activeCommitRequest?.frame.sequenceNumber != sequenceNumber,
              !pendingCommits.contains(where: { $0.frame.sequenceNumber == sequenceNumber }) else {
            return
        }

        pendingCommits.append(request)
        pendingCommits.sort { $0.frame.sequenceNumber < $1.frame.sequenceNumber }
        if pendingCommits.count > frameRing.capacity {
            // Never overwrite the first pending anchor with a newer frame. Keeping the oldest
            // bounded bridge is what lets the stitcher survive a fast multi-viewport burst.
            pendingCommits.removeLast(pendingCommits.count - frameRing.capacity)
        }
        updatePreviewTruth("同步中")
        if launchIfIdle { launchNextPendingCommit() }
    }

    private func launchNextPendingCommit() {
        guard !commitInFlight else { return }
        while !pendingCommits.isEmpty {
            let next = pendingCommits.removeFirst()
            let sequenceNumber = next.frame.sequenceNumber
            guard sequenceNumber > lastAcceptedSequenceNumber,
                  !failedCommitSequences.contains(sequenceNumber) else { continue }
            launchCommit(next)
            return
        }
    }

    private func launchCommit(_ request: CommitRequest) {
        guard let stitcher, !commitInFlight else { return }
        commitInFlight = true
        activeCommitRequest = request
        lastAttemptedSequenceNumber = max(
            lastAttemptedSequenceNumber,
            request.frame.sequenceNumber
        )
        updatePreviewTruth("同步中")
        let capturedSessionID = sessionID
        let queuedAt = ProcessInfo.processInfo.systemUptime
        let completion: @MainActor @Sendable (ScrollCaptureCommitWorkResult) -> Void = {
            [weak self, stitcher] result in
            self?.handleCommitResult(
                result.update,
                preview: result.preview,
                request: request,
                stitcher: stitcher,
                sessionID: capturedSessionID,
                queueDelayMs: result.queueDelayMs,
                workMs: result.workMs
            )
        }
        processingQueue.async { [stitcher, completion] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let update = stitcher.append(
                request.frame.image,
                maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(
                    pixelWidth: request.frame.image.width
                ),
                expectedSignedDeltaPixels: request.expectedDeltaPixels,
                renderMergedImage: false
            )
            let preview: CGImage?
            if let update {
                switch update.outcome {
                case .initialized, .appended, .reachedHeightLimit:
                    preview = stitcher.previewImage(maxPixelWidth: 192, maxPixelHeight: 1_600)
                case .ignoredNoMovement, .ignoredAlignmentFailed:
                    preview = nil
                }
            } else {
                preview = nil
            }
            let queueDelayMs = Int(max(0, (startedAt - queuedAt) * 1_000).rounded())
            let workMs = Int(max(
                0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            ).rounded())
            let result = ScrollCaptureCommitWorkResult(
                update: update,
                preview: preview,
                queueDelayMs: queueDelayMs,
                workMs: workMs
            )
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private func handleCommitResult(
        _ update: ScrollingCaptureStitchUpdate?,
        preview: CGImage?,
        request: CommitRequest,
        stitcher: ScrollingCaptureStitcher,
        sessionID: UUID,
        queueDelayMs: Int,
        workMs: Int
    ) {
        guard self.sessionID == sessionID,
              self.stitcher === stitcher,
              state == .capturing || state == .finishing else { return }

        commitInFlight = false
        activeCommitRequest = nil
        var alignmentFailed = false
        var consumedFrame = false
        var reachedHeightLimit = false
        if let update {
            switch update.outcome {
            case .initialized:
                acceptSequence(request.frame.sequenceNumber)
                consumedFrame = true
            case .appended(let deltaY):
                acceptSequence(request.frame.sequenceNumber)
                consumedFrame = true
                acceptedFrameCount = update.acceptedFrameCount
                consecutiveAlignmentFailures = 0
                if let preview { updatePreview(preview, truth: "已拼") }
                logDiagnostic(
                    "long_capture_stream_frame_appended",
                    metadata: [
                        "delta": deltaY,
                        "segments": acceptedFrameCount,
                        "sequence": request.frame.sequenceNumber,
                        "queueDelayMs": queueDelayMs,
                        "workMs": workMs,
                    ]
                )
            case .ignoredNoMovement:
                acceptSequence(request.frame.sequenceNumber)
                consumedFrame = true
                consecutiveAlignmentFailures = 0
                updatePreviewTruth(update.likelyReachedBoundary ? "已到边界" : "已拼")
            case .ignoredAlignmentFailed:
                alignmentFailed = true
            case .reachedHeightLimit:
                acceptSequence(request.frame.sequenceNumber)
                consumedFrame = true
                acceptedFrameCount = update.acceptedFrameCount
                reachedHeightLimit = true
                if let preview { updatePreview(preview, truth: "已达上限") }
            }
        } else {
            alignmentFailed = true
        }

        if consumedFrame {
            consumeExpectedDelta(from: request)
        }

        if alignmentFailed {
            // Do not advance lastAcceptedSequenceNumber. The next oldest buffered sample may
            // restore overlap. The failed set plus the bounded queue/finish budget make this
            // finite without throwing away the already complete stitched prefix.
            failedCommitSequences.insert(request.frame.sequenceNumber)
            consecutiveAlignmentFailures += 1
            updatePreviewTruth(state == .finishing ? "收尾补齐中" : "补齐中")
            logDiagnostic(
                "long_capture_stream_alignment_failed",
                metadata: [
                    "consecutive": consecutiveAlignmentFailures,
                    "sequence": request.frame.sequenceNumber,
                    "lastAccepted": lastAcceptedSequenceNumber,
                    "lastAttempted": lastAttemptedSequenceNumber,
                ]
            )
        }

        updateStatus()
        if reachedHeightLimit {
            finishExplicitPartialReason = ScrollCaptureFinishDrainPolicy.heightLimitPartialReason
            if state == .capturing {
                finish(partialReason: ScrollCaptureFinishDrainPolicy.heightLimitPartialReason)
                return
            }
        }

        if state == .finishing {
            drainAndFinalize()
            return
        }

        launchNextPendingCommit()
        if alignmentFailed, !commitInFlight, pendingCommits.isEmpty {
            requestCommit(origin: .recovery)
        }
    }

    private func acceptSequence(_ sequenceNumber: Int) {
        lastAcceptedSequenceNumber = max(lastAcceptedSequenceNumber, sequenceNumber)
        pendingCommits.removeAll { $0.frame.sequenceNumber <= lastAcceptedSequenceNumber }
        failedCommitSequences = failedCommitSequences.filter {
            $0 > lastAcceptedSequenceNumber
        }
    }

    private func consumeExpectedDelta(from request: CommitRequest) {
        guard let expectedDeltaPoints = request.expectedDeltaPoints else { return }
        pendingExpectedScrollPoints -= expectedDeltaPoints
        if abs(pendingExpectedScrollPoints) < 0.25 {
            pendingExpectedScrollPoints = 0
        }
    }

    private func startPeriodicCommitTimer() {
        guard periodicCommitTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .capturing,
                      self.latestStreamSequenceNumber > self.lastAcceptedSequenceNumber else {
                    return
                }
                self.requestCommit(origin: .streamChange)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicCommitTimer = timer
    }

    private func stopPeriodicCommitTimer() {
        periodicCommitTimer?.invalidate()
        periodicCommitTimer = nil
    }

    // MARK: Finish / cancel

    @objc private func handleCompletionButton() {
        logDiagnostic("long_capture_completion_button_pressed")
        finish()
    }

    func finishActiveSession() {
        if state == .capturing { finish() }
    }

    private func finish(partialReason: String? = nil) {
        guard state == .capturing else { return }
        commandKeyTap?.beginFinishing()
        state = .finishing
        finishExplicitPartialReason = partialReason
        removePassiveInputObservers()
        stopPeriodicCommitTimer()
        streamSettleWorkItem?.cancel()
        streamSettleWorkItem = nil
        statusLabel?.stringValue = partialReason ?? "正在收齐最后画面…"
        finishButton?.isEnabled = false
        updatePreviewTruth("收尾中")
        logDiagnostic("long_capture_finish_requested")

        // Allow compositor/lazy content to settle; the stream remains live during this window.
        let finishingSessionID = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self,
                  self.sessionID == finishingSessionID,
                  self.state == .finishing else { return }
            // Close frame admission before draining. Leaving a 30 fps stream live here can
            // continuously create a newer tail while the serial stitcher is processing the
            // previous one, so "finish" would never converge on animated pages.
            self.finishCutoffSequenceNumber = self.latestStreamSequenceNumber
            self.frameSource?.stop()
            self.frameSource = nil
            self.prepareFinishDrain(through: self.latestStreamSequenceNumber)
            self.drainAndFinalize()
        }
    }

    private func prepareFinishDrain(through cutoffSequenceNumber: Int) {
        let activeSequenceNumber = activeCommitRequest?.frame.sequenceNumber
        var retainedBySequence: [Int: CommitRequest] = [:]
        for request in pendingCommits {
            let sequenceNumber = request.frame.sequenceNumber
            retainedBySequence[sequenceNumber] = request
        }
        for frame in frameRing.ordered(
            after: lastAcceptedSequenceNumber,
            through: cutoffSequenceNumber,
            excluding: failedCommitSequences
        ) {
            if retainedBySequence[frame.sequenceNumber] == nil {
                retainedBySequence[frame.sequenceNumber] = CommitRequest(
                    frame: frame,
                    expectedDeltaPixels: nil,
                    origin: .finalFrame
                )
            }
        }
        let snapshotSequences = ScrollCaptureFinishDrainPolicy.snapshotSequences(
            pendingSequences: pendingCommits.map { $0.frame.sequenceNumber },
            ringSequences: frameRing.frames.map(\.sequenceNumber),
            activeSequence: activeSequenceNumber,
            lastAcceptedSequence: lastAcceptedSequenceNumber,
            cutoffSequence: cutoffSequenceNumber,
            failedSequences: failedCommitSequences
        )
        pendingCommits = snapshotSequences.compactMap { retainedBySequence[$0] }
        // pendingCommits and frameRing are each bounded to eight. Their frozen de-duplicated
        // union is therefore at most sixteen frames; every retained sequence gets one attempt.
        finishDrainAttemptsRemaining = pendingCommits.count
    }

    private func drainAndFinalize() {
        guard state == .finishing,
              let finishCutoffSequenceNumber else { return }
        if commitInFlight { return }

        pendingCommits.removeAll { request in
            request.frame.sequenceNumber <= lastAcceptedSequenceNumber
                || request.frame.sequenceNumber > finishCutoffSequenceNumber
                || failedCommitSequences.contains(request.frame.sequenceNumber)
        }
        if !pendingCommits.isEmpty {
            guard finishDrainAttemptsRemaining > 0 else {
                logDiagnostic(
                    "long_capture_finish_drain_budget_exhausted",
                    metadata: [
                        "lastAccepted": lastAcceptedSequenceNumber,
                        "lastAttempted": lastAttemptedSequenceNumber,
                        "pending": pendingCommits.count,
                    ]
                )
                finalizeOutput(partialReason: resolvedFinishPartialReason())
                return
            }
            let request = pendingCommits.removeFirst()
            finishDrainAttemptsRemaining -= 1
            launchCommit(CommitRequest(
                frame: request.frame,
                expectedDeltaPixels: request.expectedDeltaPixels,
                expectedDeltaPoints: request.expectedDeltaPoints,
                origin: .finalFrame
            ))
            return
        }
        finalizeOutput(partialReason: resolvedFinishPartialReason())
    }

    private func resolvedFinishPartialReason() -> String? {
        guard let finishCutoffSequenceNumber else { return finishExplicitPartialReason }
        return ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
            explicitReason: finishExplicitPartialReason,
            lastAcceptedSequence: lastAcceptedSequenceNumber,
            cutoffSequence: finishCutoffSequenceNumber
        )
    }

    private func finalizeOutput(partialReason: String?) {
        guard state == .finishing, !commitInFlight,
              let stitcher else { return }
        frameSource?.stop()
        frameSource = nil
        let capturedSessionID = sessionID
        let scale = pixelScale
        let capturedPartialReason = partialReason
        let completion: @MainActor @Sendable (ScrollCaptureFinalWorkResult) -> Void = {
            [weak self, stitcher] result in
            guard let self,
                  self.sessionID == capturedSessionID,
                  self.state == .finishing,
                  self.stitcher === stitcher else { return }
            let shouldDiscard = self.discardFinishedOutput
            self.logDiagnostic(
                "long_capture_output_ready",
                metadata: [
                    "width": result.image?.width ?? 0,
                    "height": result.image?.height ?? 0,
                    "segments": result.acceptedFrameCount,
                    "complete": capturedPartialReason == nil ? 1 : 0,
                ]
            )
            self.finishTeardown()
            guard !shouldDiscard, let image = result.image else {
                self.notifySessionEnded(.cancelled)
                return
            }
            self.notifySessionEnded(.finished(
                image: image,
                pixelScale: scale,
                partialReason: capturedPartialReason
            ))
        }
        processingQueue.async { [stitcher, completion] in
            let image = stitcher.mergedImage()
            let result = ScrollCaptureFinalWorkResult(
                image: image,
                acceptedFrameCount: stitcher.acceptedFrameCount
            )
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private func finishTeardown() {
        streamStartupTask?.cancel()
        streamStartupTask = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        removePassiveInputObservers()
        removeCommandKeyTap()
        stopPeriodicCommitTimer()
        streamSettleWorkItem?.cancel()
        frameSource?.stop()
        frameSource = nil
        hidePanels()
        state = .idle
        commitInFlight = false
        activeCommitRequest = nil
        pendingCommits.removeAll(keepingCapacity: true)
        failedCommitSequences.removeAll()
        stitcher = nil
        frameRing.reset()
        sourceProcessIdentifier = nil
        sourceWindowID = nil
        finishCutoffSequenceNumber = nil
        finishDrainAttemptsRemaining = 0
        finishExplicitPartialReason = nil
        finishRequestedBeforeFirstFrame = false
    }

    private func cancel(showToast: Bool = true, reason: String = "user_cancel") {
        guard state != .idle else { return }
        logDiagnostic(
            "long_capture_session_ended_\(reason)",
            metadata: ["segments": max(acceptedFrameCount, 1)]
        )
        sessionID = UUID()
        discardFinishedOutput = true
        streamStartupTask?.cancel()
        streamStartupTask = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        removePassiveInputObservers()
        removeCommandKeyTap()
        stopPeriodicCommitTimer()
        streamSettleWorkItem?.cancel()
        frameSource?.stop()
        frameSource = nil
        hidePanels()
        state = .idle
        commitInFlight = false
        activeCommitRequest = nil
        pendingCommits.removeAll(keepingCapacity: true)
        failedCommitSequences.removeAll()
        stitcher = nil
        frameRing.reset()
        sourceProcessIdentifier = nil
        sourceWindowID = nil
        finishCutoffSequenceNumber = nil
        finishDrainAttemptsRemaining = 0
        finishExplicitPartialReason = nil
        finishRequestedBeforeFirstFrame = false
        notifySessionEnded(.cancelled)
        if showToast { ToastWindow.show(message: "已取消长截图") }
    }

    func cancelActiveSession() {
        cancel(showToast: false, reason: "host_yield")
    }

    private func notifySessionEnded(_ result: SessionResult) {
        let callback = onSessionEnd
        onSessionEnd = nil
        callback?(result)
    }

    private func sourceWindowIsStillTarget() -> Bool {
        guard let sourceProcessIdentifier,
              let sourceWindowID else { return false }
        return ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
            region: region,
            candidates: RegionSelectionController.visibleSourceWindowCandidates(),
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier,
            sourceWindowID: sourceWindowID
        )
    }

    // MARK: UI

    private func showCaptureUI() {
        hidePanels()
        showBoundaryPanel()
        showStatusPanel(text: "滚轮捕获 · 空格完成")
        showControlPanel()
        showPreviewPanel()
    }

    private func showStatusPanel(text: String) {
        statusPanel?.orderOut(nil)
        let size = NSSize(width: min(max(region.width, 260), 420), height: 30)
        let frame = ScrollCapturePanelLayout.outsideFrame(
            for: region,
            size: size,
            role: .status
        )
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(origin: .zero, size: size)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle

        let panel = Self.makePassivePanel(frame: frame, cornerRadius: 15)
        panel.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        panel.contentView?.addSubview(label)
        panel.orderFrontRegardless()
        statusPanel = panel
        statusLabel = label
    }

    private func showControlPanel() {
        let size = NSSize(width: 88, height: 32)
        let frame = ScrollCapturePanelLayout.outsideFrame(
            for: region,
            size: size,
            role: .controls
        )
        let finish = ScrollCaptureActionButton(title: "完成", emphasis: .secondary)
        finish.frame = NSRect(x: 4, y: 4, width: 80, height: 24)
        finish.target = self
        finish.action = #selector(handleCompletionButton)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(finish)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.orderFrontRegardless()
        controlPanel = panel
        finishButton = finish
    }

    private func showBoundaryPanel() {
        let frame = ScrollCapturePanelLayout.appKitFrame(for: region)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.borderWidth = 2
        container.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = Self.makePassivePanel(frame: frame, cornerRadius: 0)
        panel.contentView = container
        panel.orderFrontRegardless()
        boundaryPanel = panel
    }

    private func showPreviewPanel() {
        let previewWidth: CGFloat = 174
        let height = min(max(region.height, 180), 520)
        let size = NSSize(width: previewWidth, height: height)
        let frame = ScrollCapturePanelLayout.previewFrame(for: region, size: size)

        let truth = NSTextField(labelWithString: "已拼")
        truth.frame = NSRect(x: 8, y: height - 26, width: previewWidth - 16, height: 18)
        truth.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        truth.textColor = .white
        truth.alignment = .center

        let imageView = NSImageView(
            frame: NSRect(x: 5, y: 5, width: previewWidth - 10, height: height - 34)
        )
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        container.layer?.cornerRadius = 8
        container.addSubview(imageView)
        container.addSubview(truth)

        let panel = Self.makePassivePanel(frame: frame, cornerRadius: 8)
        panel.contentView = container
        panel.orderFrontRegardless()
        previewPanel = panel
        previewImageView = imageView
        previewTruthLabel = truth
    }

    static func makePassivePanel(frame: CGRect, cornerRadius: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        panel.contentView = container
        return panel
    }

    private func updatePreview(_ image: CGImage, truth: String) {
        guard let imageView = previewImageView else { return }
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        updatePreviewTruth(truth)
    }

    private func updatePreviewTruth(_ text: String) {
        previewTruthLabel?.stringValue = text
    }

    private func updateStatus() {
        guard state == .capturing else { return }
        if consecutiveAlignmentFailures > 0 {
            statusLabel?.stringValue = "对齐暂停 · 放慢滚轮，或按空格完成"
        } else {
            statusLabel?.stringValue = "滚轮捕获 · 空格完成 · 已拼 \(acceptedFrameCount) 段"
        }
        finishButton?.isEnabled = true
    }

    private func hidePanels() {
        let retained = [statusPanel, controlPanel, boundaryPanel, previewPanel]
        retained.forEach { $0?.orderOut(nil) }
        statusPanel = nil
        controlPanel = nil
        boundaryPanel = nil
        previewPanel = nil
        statusLabel = nil
        finishButton = nil
        previewImageView = nil
        previewTruthLabel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { _ = retained }
    }

    // MARK: Diagnostics

    private func logDiagnostic(_ name: String, metadata: [String: Int] = [:]) {
        var fields = metadata
        fields["session"] = sessionID.hashValue & Int(Int32.max)
        fields["uptimeMs"] = Int((ProcessInfo.processInfo.systemUptime * 1_000).rounded())
        PrivacySafeLog.event(name, metadata: fields)
    }
}

final class ScrollCaptureActionButton: NSButton {
    enum Emphasis { case primary, secondary }

    private let emphasis: Emphasis
    static let primaryForegroundColor = NSColor.white
    static let primaryBackgroundColor = NSColor(
        srgbRed: 0.00,
        green: 0.36,
        blue: 0.82,
        alpha: 1
    )
    static let secondaryForegroundColor = NSColor.black
    static let secondaryBackgroundColor = NSColor.white.withAlphaComponent(0.94)

    init(title: String, emphasis: Emphasis) {
        self.emphasis = emphasis
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        self.title = title
    }

    required init?(coder: NSCoder) { nil }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.55 } }
    override var title: String {
        get { super.title }
        set {
            super.title = newValue
            applyExplicitAppearance(to: newValue)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.78
        defer { alphaValue = isEnabled ? 1 : 0.55 }
        super.mouseDown(with: event)
    }

    private func applyExplicitAppearance(to title: String) {
        let foreground = emphasis == .primary
            ? Self.primaryForegroundColor
            : Self.secondaryForegroundColor
        let background = emphasis == .primary
            ? Self.primaryBackgroundColor
            : Self.secondaryBackgroundColor
        layer?.backgroundColor = background.cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: foreground,
            ]
        )
    }
}

enum ScrollCapturePanelRole { case status, controls }

enum ScrollCapturePanelLayout {
    static func appKitFrame(for quartzRegion: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1_080
        return CGRect(
            x: quartzRegion.minX,
            y: primaryHeight - quartzRegion.minY - quartzRegion.height,
            width: quartzRegion.width,
            height: quartzRegion.height
        )
    }

    static func currentQuartzMouseLocation() -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1_080
        let appKit = NSEvent.mouseLocation
        return CGPoint(x: appKit.x, y: primaryHeight - appKit.y)
    }

    static func outsideFrame(
        for quartzRegion: CGRect,
        size: NSSize,
        role: ScrollCapturePanelRole
    ) -> CGRect {
        let selection = appKitFrame(for: quartzRegion)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let gap: CGFloat = role == .status ? 8 : 44
        let centeredX = min(
            max(selection.midX - size.width / 2, available.minX + 4),
            available.maxX - size.width - 4
        )
        if selection.maxY + gap + size.height <= available.maxY {
            return CGRect(x: centeredX, y: selection.maxY + gap, width: size.width, height: size.height)
        }
        if selection.minY - gap - size.height >= available.minY {
            return CGRect(
                x: centeredX,
                y: selection.minY - gap - size.height,
                width: size.width,
                height: size.height
            )
        }
        let rightX = selection.maxX + 8
        if rightX + size.width <= available.maxX {
            return CGRect(
                x: rightX,
                y: min(max(selection.maxY - size.height, available.minY), available.maxY - size.height),
                width: size.width,
                height: size.height
            )
        }
        let leftX = selection.minX - size.width - 8
        if leftX >= available.minX {
            return CGRect(
                x: leftX,
                y: min(max(selection.maxY - size.height, available.minY), available.maxY - size.height),
                width: size.width,
                height: size.height
            )
        }
        // Full-screen selections leave no outside surface. Keep the unavoidable clickable area
        // to the single compact completion button rather than a wide interactive HUD.
        return CGRect(
            x: available.maxX - size.width - 8,
            y: available.maxY - size.height - 8,
            width: size.width,
            height: size.height
        )
    }

    static func previewFrame(for quartzRegion: CGRect, size: NSSize) -> CGRect {
        let selection = appKitFrame(for: quartzRegion)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let y = min(max(selection.minY, available.minY), available.maxY - size.height)
        if selection.maxX + 12 + size.width <= available.maxX {
            return CGRect(x: selection.maxX + 12, y: y, width: size.width, height: size.height)
        }
        if selection.minX - 12 - size.width >= available.minX {
            return CGRect(
                x: selection.minX - 12 - size.width,
                y: y,
                width: size.width,
                height: size.height
            )
        }
        return CGRect(
            x: available.maxX - size.width - 8,
            y: available.minY + 8,
            width: size.width,
            height: size.height
        )
    }
}

struct ScrollCaptureFirstCompleteFrameGate {
    private(set) var hasClaimedFrame = false

    mutating func claim() -> Bool {
        guard !hasClaimedFrame else { return false }
        hasClaimedFrame = true
        return true
    }

    mutating func reset() {
        hasClaimedFrame = false
    }
}

enum ScrollCaptureSourceWindowPolicy {
    static func matchesSelectedWindow(
        region: CGRect,
        candidates: [RegionSelectionWindowCandidate],
        hostProcessIdentifier: pid_t,
        sourceProcessIdentifier: pid_t,
        sourceWindowID: CGWindowID
    ) -> Bool {
        guard let topmost = RegionSelectionSourceResolver.preferredCandidate(
            for: region,
            candidates: candidates,
            hostProcessIdentifier: hostProcessIdentifier
        ) else { return false }
        return topmost.ownerProcessIdentifier == sourceProcessIdentifier
            && topmost.windowID == sourceWindowID
    }
}

enum ScrollCaptureFinishDrainPolicy {
    static let heightLimitPartialReason = "达到安全长度上限，当前结果已截断"
    static let incompleteTailPartialReason = "尾部未能对齐，已保留完整部分"

    static func snapshotSequences(
        pendingSequences: [Int],
        ringSequences: [Int],
        activeSequence: Int?,
        lastAcceptedSequence: Int,
        cutoffSequence: Int,
        failedSequences: Set<Int>
    ) -> [Int] {
        Set(pendingSequences + ringSequences)
            .filter {
                $0 > lastAcceptedSequence
                    && $0 <= cutoffSequence
                    && $0 != activeSequence
                    && !failedSequences.contains($0)
            }
            .sorted()
    }

    static func isComplete(
        lastAcceptedSequence: Int,
        cutoffSequence: Int
    ) -> Bool {
        lastAcceptedSequence >= cutoffSequence
    }

    static func resolvedPartialReason(
        explicitReason: String?,
        lastAcceptedSequence: Int,
        cutoffSequence: Int
    ) -> String? {
        if let explicitReason { return explicitReason }
        return isComplete(
            lastAcceptedSequence: lastAcceptedSequence,
            cutoffSequence: cutoffSequence
        ) ? nil : incompleteTailPartialReason
    }
}

enum ScrollCaptureRecoveryPolicy {
    static func nextSequence(
        lastAcceptedSequence: Int,
        recoveryCeilingSequence: Int,
        failedSequences: Set<Int>,
        availableSequences: [Int]
    ) -> Int? {
        availableSequences
            .filter {
                $0 > lastAcceptedSequence
                    && $0 <= recoveryCeilingSequence
                    && !failedSequences.contains($0)
            }
            .min()
    }
}
