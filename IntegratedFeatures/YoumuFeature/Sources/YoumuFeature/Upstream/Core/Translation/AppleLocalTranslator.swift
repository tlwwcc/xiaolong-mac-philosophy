import AppKit
import Foundation
import SwiftUI
@preconcurrency import Translation

enum AppleLocalModelCapability: Equatable {
    case installed
    case downloadable
    case unsupported
}

enum AppleLocalModelStatus: Equatable {
    case checking
    case installed
    case downloadable
    case downloading
    case unsupported
    case systemUnavailable
    case failed

    static func combined(_ capabilities: [AppleLocalModelCapability]) -> AppleLocalModelStatus {
        guard !capabilities.isEmpty else { return .unsupported }
        if capabilities.contains(.unsupported) { return .unsupported }
        if capabilities.allSatisfy({ $0 == .installed }) { return .installed }
        return .downloadable
    }

    var displayName: String {
        switch self {
        case .checking: return "正在检查"
        case .installed: return "已安装"
        case .downloadable: return "可下载"
        case .downloading: return "等待系统下载"
        case .unsupported: return "此 Mac 不支持"
        case .systemUnavailable: return "需要 macOS 15 或更新版本"
        case .failed: return "下载未完成"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "arrow.triangle.2.circlepath"
        case .installed: return "checkmark.circle.fill"
        case .downloadable: return "arrow.down.circle.fill"
        case .downloading: return "hourglass.circle.fill"
        case .unsupported, .systemUnavailable, .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum AppleLocalModelCatalog {
    static let sourceIdentifier = "en"
    static let targetIdentifier = "zh-Hans"
    static let displayName = "英语 ↔ 简体中文"
    static let privacyDetail = "模型由 macOS 管理；安装后翻译内容只在本机处理。"
}

@available(macOS 15.0, *)
enum AppleLocalModelAvailability {
    static func status() async -> AppleLocalModelStatus {
        let english = Locale.Language(identifier: AppleLocalModelCatalog.sourceIdentifier)
        let chinese = Locale.Language(identifier: AppleLocalModelCatalog.targetIdentifier)
        let availability = LanguageAvailability()
        let forward = await availability.status(from: english, to: chinese)
        let reverse = await availability.status(from: chinese, to: english)
        return AppleLocalModelStatus.combined([capability(forward), capability(reverse)])
    }

    private static func capability(
        _ status: LanguageAvailability.Status
    ) -> AppleLocalModelCapability {
        switch status {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

enum AppleLocalTranslationError: LocalizedError {
    case busy
    case timedOut
    case incompleteResponse
    case modelDownloadTimedOut
    case sourceLanguageUnidentified
    case unsupportedLanguages(source: String, target: String)

    var errorDescription: String? {
        switch self {
        case .sourceLanguageUnidentified: return "文字不足以判断语言，请扩大截图范围后重试"
        case let .unsupportedLanguages(source, target):
            let locale = Locale(identifier: "zh-Hans")
            let sourceName = locale.localizedString(forIdentifier: source) ?? source
            let targetName = locale.localizedString(forIdentifier: target) ?? target
            return "Apple 暂不支持从\(sourceName)翻译为\(targetName)，其他可翻译部分会保留"
        case .busy: return "本机翻译正忙"
        case .timedOut: return "本机翻译超时"
        case .incompleteResponse: return "本机翻译结果不完整"
        case .modelDownloadTimedOut: return "Apple 本机翻译模型下载等待超时，请稍后重试"
        }
    }
}

enum AppleLocalSessionConfigurationAction: Equatable {
    case install
    case invalidate
}

/// Apple 的 translationTask 只会在配置变化时重跑；同一语种的后续内容必须
/// 保留上一份配置并 invalidate，不能在每个任务结束后把配置清成 nil。
enum AppleLocalSessionConfigurationPolicy {
    static func action(
        hasConfiguration: Bool,
        usesSameLanguages: Bool
    ) -> AppleLocalSessionConfigurationAction {
        hasConfiguration && usesSameLanguages ? .invalidate : .install
    }
}

/// 模型由 macOS 管理。需要下载/语言确认时使用可见窗口，不能将系统 UI 挂到离屏像素。
final class AppleLocalTranslator {
    static let shared = AppleLocalTranslator()
    private init() {}

    func translate(
        texts: [String], targetLanguage: Language,
        systemPresentation: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> [String]? {
        guard let outcome = try await translateBlocks(
            texts: texts, targetLanguage: targetLanguage, systemPresentation: systemPresentation
        ) else { return nil }
        if let error = outcome.firstError { throw error }
        return outcome.blocks.map(\.text)
    }

    func translateBlocks(
        texts: [String], targetLanguage: Language,
        systemPresentation: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> LocalTranslationBatchOutcome? {
        try Task.checkCancellation()
        guard #available(macOS 15.0, *) else { return nil }
        let groups = await LocalTranslationRouting.groupsForTranslation(texts: texts, targetLanguage: targetLanguage)
        try Task.checkCancellation()
        return try await LocalTranslationBatchExecutor.run(texts: texts, groups: groups) { pair, groupTexts in
            guard let sourceID = pair.sourceIdentifier, let targetID = pair.targetIdentifier else {
                throw AppleLocalTranslationError.sourceLanguageUnidentified
            }
            // Apple 不支持同一语言的繁简变体对；这里仅做本机字形转换，不请求模型。
            if sourceID.hasPrefix("zh-"), targetID.hasPrefix("zh-") {
                return try groupTexts.map {
                    guard let text = LocalTranslationRouting.convertChineseVariant($0, pair: pair) else {
                        throw AppleLocalTranslationError.incompleteResponse
                    }
                    return text
                }
            }
            let source = Locale.Language(identifier: sourceID)
            let target = Locale.Language(identifier: targetID)
            let status = await LanguageAvailability().status(from: source, to: target)
            try Task.checkCancellation()
            let needsPreparation: Bool
            switch status {
            case .installed: needsPreparation = false
            case .supported: needsPreparation = true
            case .unsupported:
                throw AppleLocalTranslationError.unsupportedLanguages(source: sourceID, target: targetID)
            @unknown default:
                throw AppleLocalTranslationError.unsupportedLanguages(source: sourceID, target: targetID)
            }
            let translated = try await AppleLocalTranslationBridge.shared.perform(
                texts: groupTexts, source: source, target: target,
                prepareFirst: needsPreparation, showsSystemUI: needsPreparation,
                systemPresentation: systemPresentation
            )
            try Task.checkCancellation()
            guard translated.count == groupTexts.count else { throw AppleLocalTranslationError.incompleteResponse }
            return zip(groupTexts, translated).map {
                LocalTranslationRouting.chineseInterfaceTranslation($0.0, pair: pair) ?? $0.1
            }
        }
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleLocalTranslationCoordinator: ObservableObject {
    struct Job {
        let id: UUID
        let texts: [String]
        let prepareFirst: Bool
        let continuation: CheckedContinuation<[String], Error>
    }

    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var requestID: UUID?
    private var job: Job?
    private var timeoutTask: Task<Void, Never>?

    func perform(
        id: UUID, texts: [String], source: Locale.Language?, target: Locale.Language?,
        prepareFirst: Bool, allowsSystemInteraction: Bool
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard job == nil else { throw AppleLocalTranslationError.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                job = Job(id: id, texts: texts, prepareFirst: prepareFirst, continuation: continuation)
                requestID = id
                // Configuration == 包含 version，不能拿新建 version=0 与已 invalidate 的配置比较。
                if configuration != nil,
                   configuration?.source == source, configuration?.target == target {
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                }
                timeoutTask = Task { [weak self] in
                    // 冷启动/整图批量不能套 3 秒在线兜底阈值；系统下载允许用户完整处理。
                    try? await Task.sleep(for: .seconds(allowsSystemInteraction ? 600 : 60))
                    guard !Task.isCancelled else { return }
                    self?.finish(id: id, result: .failure(
                        allowsSystemInteraction
                            ? AppleLocalTranslationError.modelDownloadTimedOut
                            : AppleLocalTranslationError.timedOut
                    ), invalidateSession: true)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id: id) }
        }
    }

    func cancel(id: UUID) {
        finish(id: id, result: .failure(CancellationError()), invalidateSession: true)
    }

    func run(session: TranslationSession, requestID: UUID?) async {
        // 捕获 view 本次 render 的 owner；迟到的旧回调不可认领后来新任务。
        guard let job, job.id == requestID else { return }
        do {
            try Task.checkCancellation()
            if job.prepareFirst { try await session.prepareTranslation() }
            try Task.checkCancellation()
            guard self.job?.id == job.id else { return }
            if job.texts.isEmpty {
                finish(id: job.id, result: .success([]))
                return
            }
            nonisolated(unsafe) let requests = job.texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            try Task.checkCancellation()
            let ordered = LocalTranslationRouting.orderedTexts(
                responsePairs: responses.map { ($0.clientIdentifier, $0.targetText) },
                expectedCount: job.texts.count
            )
            guard let ordered else { throw AppleLocalTranslationError.incompleteResponse }
            finish(id: job.id, result: .success(ordered))
        } catch {
            finishSessionFailure(id: job.id, error: error)
        }
    }

    func finishSessionFailure(id: UUID, error: Error) {
        // 原生下载/语言确认的取消有独立错误类型；归一后上层取消分支才不会
        // 将它当成图片错误，或在 automatic 模式继续发起在线翻译。
        if AppleTranslationCancellation.matches(error) {
            cancel(id: id)
        } else {
            finish(id: id, result: .failure(error))
        }
    }

    func finish(
        id: UUID, result: Result<[String], Error>, invalidateSession: Bool = false
    ) {
        guard let current = job, current.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        job = nil
        requestID = nil
        // invalidate 取消旧 SwiftUI 任务，同时保留递增 version，快速重试不会丢触发。
        if invalidateSession { configuration?.invalidate() }
        current.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct AppleLocalTranslationHostView: View {
    @ObservedObject var coordinator: AppleLocalTranslationCoordinator
    let cancel: () -> Void

    var body: some View {
        let owner = coordinator.requestID
        VStack(alignment: .leading, spacing: 16) {
            Label("准备 Apple 本机翻译", systemImage: "character.book.closed")
                .font(.title3.weight(.semibold))
            Text("首次使用请在系统提示中下载语言。准备好后会继续本次翻译，之后可离线使用。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ProgressView().controlSize(.small)
                Text("正在等待 macOS…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消本次翻译", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 410, height: 170)
        .translationTask(coordinator.configuration) { session in
            await coordinator.run(session: session, requestID: owner)
        }
    }
}

/// SwiftUI host 持续存在；系统准备期间临时前置，完成后按本次 owner 归还焦点。
@available(macOS 15.0, *)
@MainActor
final class AppleLocalTranslationBridge: NSObject, NSWindowDelegate {
    static let shared = AppleLocalTranslationBridge()
    private let coordinator = AppleLocalTranslationCoordinator()
    private var hostPanel: NSPanel!
    private var owner: UUID?

    private override init() {
        super.init()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 458, height: 218),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Apple 本机翻译"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AppleLocalTranslationHostView(
            coordinator: coordinator, cancel: { [weak self] in self?.cancelCurrent() }
        ))
        panel.center()
        hostPanel = panel
    }

    func perform(
        texts: [String], source: Locale.Language?, target: Locale.Language?,
        prepareFirst: Bool, showsSystemUI: Bool,
        systemPresentation: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard owner == nil else { throw AppleLocalTranslationError.busy }
        let id = UUID()
        owner = id
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousWindow = NSApp.keyWindow
        if showsSystemUI {
            systemPresentation?(true)
            hostPanel.center()
            hostPanel.alphaValue = 1
            hostPanel.ignoresMouseEvents = false
            NSApp.activate(ignoringOtherApps: true)
            hostPanel.makeKeyAndOrderFront(nil)
        } else {
            // 保持 host 的 view 生命周期以供 macOS 15 的已安装 session 使用。
            hostPanel.alphaValue = 0
            hostPanel.ignoresMouseEvents = true
            hostPanel.orderFrontRegardless()
        }
        defer {
            if owner == id {
                owner = nil
                hostPanel.alphaValue = 0
                hostPanel.ignoresMouseEvents = true
                if showsSystemUI {
                    hostPanel.orderOut(nil)
                    systemPresentation?(false)
                    if let previousWindow, previousWindow.isVisible {
                        previousWindow.makeKeyAndOrderFront(nil)
                    } else if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        previousApp?.activate(options: [])
                    }
                }
            }
        }
        return try await coordinator.perform(
            id: id, texts: texts, source: source, target: target,
            prepareFirst: prepareFirst, allowsSystemInteraction: showsSystemUI
        )
    }

    func prepareModels() async throws {
        _ = try await perform(
            texts: [],
            source: Locale.Language(identifier: AppleLocalModelCatalog.sourceIdentifier),
            target: Locale.Language(identifier: AppleLocalModelCatalog.targetIdentifier),
            prepareFirst: true, showsSystemUI: true
        )
    }

    private func cancelCurrent() {
        guard let owner else { return }
        coordinator.cancel(id: owner)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelCurrent()
        return false
    }
}
