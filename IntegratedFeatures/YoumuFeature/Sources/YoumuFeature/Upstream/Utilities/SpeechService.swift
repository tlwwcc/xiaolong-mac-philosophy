import AVFoundation

enum SpeechPlaybackState: String {
    case idle
    case loading
    case playing
    case paused
    case finished
    case failed
}

enum SpeechPlaybackBackend: String {
    case edge
    case local
}

struct SpeechTimedRange: Equatable {
    let offset: TimeInterval
    let duration: TimeInterval
    let range: NSRange
}

struct SpeechPlaybackSnapshot {
    let state: SpeechPlaybackState
    let elapsed: TimeInterval
    let duration: TimeInterval
    let progress: Double
    let currentRange: NSRange?
    let rate: Float
    let backend: SpeechPlaybackBackend?
    let canSeek: Bool
    let notice: String?
    let voiceIdentifier: String?

    var backendDescription: String {
        guard let backend else { return "声音未启动" }
        guard backend == .edge else { return "Mac 本机声音 · 文字不离开本机" }
        if let voiceIdentifier, let voice = EdgeSpeechVoice(rawValue: voiceIdentifier) {
            return "Edge · " + voice.displayName
        }
        return "Edge 神经声音 · 自然朗读"
    }
}

struct SpeechRequestFence {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ request: UInt64) -> Bool {
        request == generation
    }
}

enum SpeechRateChangePolicy {
    static func canApplyImmediately(
        backend: SpeechPlaybackBackend?,
        state: SpeechPlaybackState
    ) -> Bool {
        guard backend == .local else { return true }
        return state != .playing && state != .paused
    }
}

/// 朗读服务：遵守选定来源；只有自动模式允许明示后回落到本机声音。
///
/// Edge 使用真实 WordBoundary 时间轴驱动“歌词式”高亮；本机声音使用 Apple 的
/// willSpeakRangeOfSpeechString 回调。所有公开控制均由主线程 UI 调用。
@MainActor
final class SpeechService: NSObject, @unchecked Sendable {
    static let shared = SpeechService()
    static var stateDidChangeNotification: Notification.Name {
        YoumuFeatureEnvironmentStore.shared.notificationName(
            "speech-service.state-did-change"
        )
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var edgeTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var timedRanges: [SpeechTimedRange] = []
    private var sourceText = ""
    private var sourceLanguage = "en-US"
    private var sourceVoice: EdgeSpeechVoice = .yunjian
    private var sourcePreference: SpeechBackendPreference = .automatic
    private var loadSettings: () -> AppSettings = { AppSettings.load() }
    private var requestConsent: () -> Bool = {
        OnlineDataConsentManager.shared.request(.edgeSpeech, endpoint: EdgeOnlineSpeechClient.onlineConsentEndpoint)
    }
    private var synthesize: (String, String, EdgeSpeechVoice) async throws -> EdgeSpeechResult = { text, language, voice in
        try await EdgeOnlineSpeechClient().synthesize(text: text, language: language, preferredChineseVoice: voice)
    }
    private var reportNotice: (String) -> Void = { ToastWindow.show(message: $0) }
    private var localSpeechHandler: ((AVSpeechUtterance) -> Void)?
    private var requestFence = SpeechRequestFence()
    private var localUtteranceOwner: (identity: ObjectIdentifier, generation: UInt64)?
    private var localUtteranceGeneration: UInt64 = 0

    private(set) var state: SpeechPlaybackState = .idle
    private(set) var playbackRate: Float = 1
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var currentRange: NSRange?
    private(set) var backend: SpeechPlaybackBackend?
    private(set) var notice: String?

    var isSpeaking: Bool {
        state == .loading || state == .playing || state == .paused
    }

    var snapshot: SpeechPlaybackSnapshot {
        SpeechPlaybackSnapshot(
            state: state,
            elapsed: elapsed,
            duration: duration,
            progress: duration > 0 ? min(max(elapsed / duration, 0), 1) : 0,
            currentRange: currentRange,
            rate: playbackRate,
            backend: backend,
            canSeek: audioPlayer != nil,
            notice: notice,
            voiceIdentifier: backend == .edge
                ? EdgeOnlineSpeechClient.voiceIdentifier(for: sourceLanguage, preferredChineseVoice: sourceVoice)
                : nil
        )
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Isolated dependencies keep provider/error/late-response tests off the network and speakers.
    init(
        loadSettings: @escaping () -> AppSettings,
        requestConsent: @escaping () -> Bool,
        synthesize: @escaping (String, String, EdgeSpeechVoice) async throws -> EdgeSpeechResult,
        reportNotice: @escaping (String) -> Void,
        localSpeechHandler: ((AVSpeechUtterance) -> Void)? = nil
    ) {
        self.loadSettings = loadSettings
        self.requestConsent = requestConsent
        self.synthesize = synthesize
        self.reportNotice = reportNotice
        self.localSpeechHandler = localSpeechHandler
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 朗读控制

    /// 供 OCR 面板沿用的“播放 / 停止”切换。
    func toggle(text: String, language: String? = nil) {
        if isSpeaking {
            stop()
        } else {
            speak(text: text, language: language)
        }
    }

    func speak(
        text: String,
        language: String? = nil,
        preferredVoice explicitVoice: EdgeSpeechVoice? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        sourceText = trimmed
        let resolvedLanguage = language ?? Self.voiceLanguage(for: trimmed)
        sourceLanguage = resolvedLanguage
        let settings = loadSettings()
        sourcePreference = settings.speechBackend
        let preferredVoice = Self.resolvedVoice(
            explicit: explicitVoice,
            configured: settings.speechVoice
        )
        sourceVoice = preferredVoice
        if settings.speechBackend == .macLocal {
            speakLocally(text: trimmed, language: resolvedLanguage)
            return
        }

        let requestID = requestFence.begin()
        backend = .edge
        setState(.loading)

        edgeTask = Task { [weak self] in
            guard let service = self, !Task.isCancelled,
                  service.requestFence.accepts(requestID),
                  service.state == .loading else { return }
            let allowed = service.requestConsent()
            guard allowed else {
                await MainActor.run {
                    guard service.requestFence.accepts(requestID),
                          service.state == .loading else { return }
                    service.edgeTask = nil
                    service.handleEdgeFailure(EdgeOnlineSpeechError.consentRequired)
                }
                return
            }
            do {
                let result = try await service.synthesize(trimmed, resolvedLanguage, preferredVoice)
                try Task.checkCancellation()
                await MainActor.run {
                    guard service.requestFence.accepts(requestID),
                          service.state == .loading else { return }
                    service.edgeTask = nil
                    service.startEdgePlayback(result: result)
                }
            } catch is CancellationError {
                // 用户停止：不启动本机兜底。
            } catch {
                await MainActor.run {
                    guard service.requestFence.accepts(requestID),
                          service.state == .loading else { return }
                    service.edgeTask = nil
                    service.handleEdgeFailure(error)
                }
            }
        }
    }

    /// 阅读器空格键语义：播放中暂停、暂停后继续、读完后重播。
    func togglePause() {
        switch state {
        case .playing:
            if let player = audioPlayer {
                player.pause()
                setState(.paused)
            } else if synthesizer.isSpeaking {
                if synthesizer.pauseSpeaking(at: .word) { setState(.paused) }
            }
        case .paused:
            if let player = audioPlayer {
                guard player.play() else {
                    handleEdgeFailure(EdgeOnlineSpeechError.playbackFailed)
                    return
                }
                setState(.playing)
            } else {
                if synthesizer.continueSpeaking() { setState(.playing) }
            }
        case .finished, .idle, .failed:
            guard !sourceText.isEmpty else { return }
            speak(
                text: sourceText,
                language: sourceLanguage,
                preferredVoice: sourceVoice
            )
        case .loading:
            break
        }
    }

    @discardableResult
    func setPlaybackRate(_ value: Float) -> Bool {
        guard SpeechRateChangePolicy.canApplyImmediately(backend: backend, state: state) else {
            return false
        }
        playbackRate = Self.normalizedRate(value)
        if let player = audioPlayer {
            player.enableRate = true
            player.rate = playbackRate
        }
        postUpdate()
        return true
    }

    func seek(to progress: Double) {
        guard let player = audioPlayer, player.duration > 0 else { return }
        player.currentTime = min(max(progress, 0), 1) * player.duration
        updateProgress()
    }

    func stop() {
        requestFence.invalidate()
        // Invalidate ownership before stopSpeaking: AVSpeechSynthesizer may deliver didCancel
        // synchronously or much later, and neither callback may finish a newer request.
        localUtteranceGeneration &+= 1
        localUtteranceOwner = nil
        edgeTask?.cancel()
        edgeTask = nil
        invalidateProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        timedRanges = []
        elapsed = 0
        duration = 0
        currentRange = nil
        backend = nil
        notice = nil
        setState(.idle)
    }

    private func startEdgePlayback(result: EdgeSpeechResult) {
        do {
            let player = try AVAudioPlayer(data: result.audio)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            guard player.prepareToPlay(), player.duration > 0 else {
                throw EdgeOnlineSpeechError.playbackFailed
            }
            audioPlayer = player
            backend = .edge
            duration = player.duration
            elapsed = 0
            timedRanges = Self.timedRanges(in: sourceText, boundaries: result.wordBoundaries)
            guard player.play() else { throw EdgeOnlineSpeechError.playbackFailed }
            setState(.playing)
            startProgressTimer()
        } catch {
            handleEdgeFailure(error)
        }
    }

    private func handleEdgeFailure(_ error: Error) {
        PrivacySafeLog.event("edge_speech_failed", error: error)
        invalidateProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        currentRange = nil
        let consentDenied = (error as? EdgeOnlineSpeechError) == .consentRequired
        if sourcePreference == .automatic {
            notice = consentDenied
                ? "未开启在线朗读，正在使用 Mac 本机声音"
                : "Edge 暂不可用，已改用 Mac 本机声音"
            reportNotice(notice!)
            speakLocally(text: sourceText, language: sourceLanguage)
        } else {
            notice = consentDenied
                ? "请在朗读设置中允许联网后重试"
                : "Edge 声音暂不可用，请重试"
            elapsed = 0
            duration = 0
            backend = .edge
            setState(.failed)
            reportNotice(notice!)
        }
    }

    private func speakLocally(text: String, language: String) {
        backend = .local
        timedRanges = []
        elapsed = 0
        currentRange = nil
        // 本机声音没有媒体时长；用保守中文阅读速度给进度尺一个稳定估算。
        duration = max(1, Double((text as NSString).length) / (4.8 * Double(playbackRate)))
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(
                AVSpeechUtteranceMinimumSpeechRate,
                AVSpeechUtteranceDefaultSpeechRate * playbackRate
            )
        )
        localUtteranceGeneration &+= 1
        localUtteranceOwner = (ObjectIdentifier(utterance), localUtteranceGeneration)
        setState(.playing)
        if let localSpeechHandler {
            localSpeechHandler(utterance)
        } else {
            synthesizer.speak(utterance)
        }
    }

    private func ownsLocalUtterance(_ identity: ObjectIdentifier) -> Bool {
        guard let owner = localUtteranceOwner else { return false }
        return backend == .local
            && owner.generation == localUtteranceGeneration
            && owner.identity == identity
    }

    private func handleLocalWillSpeak(
        identity: ObjectIdentifier,
        characterRange: NSRange,
        sourceLength: Int
    ) {
        guard ownsLocalUtterance(identity) else { return }
        currentRange = characterRange
        let progress = Double(NSMaxRange(characterRange)) / Double(max(sourceLength, 1))
        elapsed = duration * progress
        postUpdate()
    }

    private func handleLocalPause(identity: ObjectIdentifier) {
        guard ownsLocalUtterance(identity) else { return }
        setState(.paused)
    }

    private func handleLocalContinue(identity: ObjectIdentifier) {
        guard ownsLocalUtterance(identity) else { return }
        setState(.playing)
    }

    private func handleLocalFinish(identity: ObjectIdentifier, cancelled: Bool) {
        guard ownsLocalUtterance(identity) else { return }
        localUtteranceOwner = nil
        if cancelled {
            if state != .idle { setState(.finished) }
        } else {
            elapsed = duration
            currentRange = nil
            setState(.finished)
        }
    }

    // MARK: - 进度与词边界

    private func startProgressTimer() {
        invalidateProgressTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func invalidateProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard let player = audioPlayer else { return }
        elapsed = player.currentTime
        duration = player.duration
        if let timed = Self.range(at: elapsed, in: timedRanges) {
            currentRange = timed.range
        } else if timedRanges.isEmpty {
            currentRange = Self.fallbackRange(
                in: sourceText,
                progress: duration > 0 ? elapsed / duration : 0
            )
        }
        postUpdate()
    }

    private func setState(_ newState: SpeechPlaybackState) {
        state = newState
        postUpdate()
    }

    private func postUpdate() {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self,
            userInfo: [
                "isSpeaking": isSpeaking,
                "state": state.rawValue
            ]
        )
    }

    static let supportedRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    static func resolvedVoice(
        explicit: EdgeSpeechVoice?,
        configured: EdgeSpeechVoice
    ) -> EdgeSpeechVoice {
        explicit ?? configured
    }

    static func normalizedRate(_ value: Float) -> Float {
        supportedRates.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    static func timedRanges(
        in text: String,
        boundaries: [EdgeSpeechBoundary]
    ) -> [SpeechTimedRange] {
        let source = text as NSString
        var cursor = 0
        var result: [SpeechTimedRange] = []
        for boundary in boundaries {
            guard cursor < source.length else { break }
            let searchRange = NSRange(location: cursor, length: source.length - cursor)
            let found = source.range(of: boundary.text, options: [], range: searchRange)
            guard found.location != NSNotFound else { continue }
            result.append(
                SpeechTimedRange(
                    offset: boundary.offset,
                    duration: boundary.duration,
                    range: found
                )
            )
            cursor = NSMaxRange(found)
        }
        return result
    }

    static func range(at time: TimeInterval, in ranges: [SpeechTimedRange]) -> SpeechTimedRange? {
        guard !ranges.isEmpty else { return nil }
        if let exact = ranges.last(where: { $0.offset <= time }) {
            return exact
        }
        return ranges.first
    }

    static func fallbackRange(in text: String, progress: Double) -> NSRange? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let location = min(
            source.length - 1,
            max(0, Int(Double(source.length - 1) * min(max(progress, 0), 1)))
        )
        return source.rangeOfComposedCharacterSequence(at: location)
    }

    // MARK: - voice 语言选择（纯函数，可测）

    static func voiceLanguage(for text: String) -> String {
        let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
        tagger.string = text
        switch tagger.dominantLanguage {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "zh": return "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return "en-US"
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate / AVAudioPlayerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        let sourceLength = max((utterance.speechString as NSString).length, 1)
        Task { @MainActor [weak self] in
            self?.handleLocalWillSpeak(
                identity: identity,
                characterRange: characterRange,
                sourceLength: sourceLength
            )
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.handleLocalPause(identity: identity) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.handleLocalContinue(identity: identity) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleLocalFinish(identity: identity, cancelled: false)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleLocalFinish(identity: identity, cancelled: true)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.handleAudioFinished(identity: identity, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        let errorCode = (error as NSError?)?.code
        Task { @MainActor [weak self] in
            self?.handleAudioDecodeError(identity: identity, errorCode: errorCode)
        }
    }
}

private extension SpeechService {
    func handleAudioFinished(identity: ObjectIdentifier, successfully: Bool) {
        guard let player = audioPlayer, ObjectIdentifier(player) == identity else { return }
        guard successfully else {
            handleEdgeFailure(EdgeOnlineSpeechError.playbackFailed)
            return
        }
        invalidateProgressTimer()
        elapsed = duration
        currentRange = nil
        audioPlayer = nil
        setState(.finished)
    }

    func handleAudioDecodeError(identity: ObjectIdentifier, errorCode: Int?) {
        guard let player = audioPlayer, ObjectIdentifier(player) == identity else { return }
        handleEdgeFailure(EdgeOnlineSpeechError.playbackFailed)
    }
}
