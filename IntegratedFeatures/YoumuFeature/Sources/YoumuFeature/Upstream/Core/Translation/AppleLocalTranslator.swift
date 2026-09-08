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

/// 本机快路只覆盖当前最稳定、已验证的英中双向；其余语言继续走在线编号协议。
enum LocalTranslationRouting {
    struct Pair: Equatable {
        let sourceIdentifier: String
        let targetIdentifier: String
    }

    static func pair(for texts: [String], targetLanguage: Language) -> Pair? {
        let text = texts.joined(separator: "\n")
        switch targetLanguage {
        case .zhHans where LanguageClassifier.confidentMatch(text, targetLanguage: .en):
            return Pair(sourceIdentifier: "en", targetIdentifier: "zh-Hans")
        case .en where LanguageClassifier.confidentMatch(text, targetLanguage: .zhHans):
            return Pair(sourceIdentifier: "zh-Hans", targetIdentifier: "en")
        default:
            return nil
        }
    }

    /// Apple 批量响应可乱序返回，必须按 clientIdentifier 归位，绝不按响应顺序对齐。
    static func orderedTexts(
        responsePairs: [(clientIdentifier: String?, text: String)],
        expectedCount: Int
    ) -> [String]? {
        var mapped: [Int: String] = [:]
        for response in responsePairs {
            guard let raw = response.clientIdentifier,
                  let index = Int(raw),
                  (0..<expectedCount).contains(index),
                  mapped[index] == nil,
                  !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            mapped[index] = response.text
        }
        guard mapped.count == expectedCount else { return nil }
        return (0..<expectedCount).compactMap { mapped[$0] }
    }
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

    var errorDescription: String? {
        switch self {
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

/// 对 Translation.framework 的安全包装：
/// - 已安装模型时直接离线翻译；
/// - Apple 标记为 supported 时调用 prepareTranslation()，由系统征得用户许可并下载；
/// - 不支持的语言对或旧系统返回 nil，交给上层决定是否走在线兜底。
final class AppleLocalTranslator {
    static let shared = AppleLocalTranslator()

    private init() {}

    func translate(texts: [String], targetLanguage: Language) async throws -> [String]? {
        guard !texts.isEmpty,
              let pair = LocalTranslationRouting.pair(for: texts, targetLanguage: targetLanguage),
              #available(macOS 15.0, *) else { return nil }

        let source = Locale.Language(identifier: pair.sourceIdentifier)
        let target = Locale.Language(identifier: pair.targetIdentifier)
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            try await AppleLocalTranslationBridge.shared.prepare(
                source: source,
                target: target
            )
        case .unsupported:
            return nil
        @unknown default:
            return nil
        }

        return try await AppleLocalTranslationBridge.shared.translate(
            texts: texts,
            source: source,
            target: target
        )
    }
}

@available(macOS 15.0, *)
@MainActor
private final class AppleLocalTranslationCoordinator: ObservableObject {
    struct Job {
        let id: UUID
        let texts: [String]
        let continuation: CheckedContinuation<[String], Error>
    }

    struct PreparationJob {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    @Published var configuration: TranslationSession.Configuration?
    private var job: Job?
    private var preparationJob: PreparationJob?
    private var timeoutTask: Task<Void, Never>?

    func translate(
        texts: [String],
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard job == nil, preparationJob == nil else {
            throw AppleLocalTranslationError.busy
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job = Job(id: id, texts: texts, continuation: continuation)

                let next = TranslationSession.Configuration(source: source, target: target)
                switch AppleLocalSessionConfigurationPolicy.action(
                    hasConfiguration: configuration != nil,
                    usesSameLanguages: next == configuration
                ) {
                case .install:
                    configuration = next
                case .invalidate:
                    configuration?.invalidate()
                }

                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.finish(id: id, result: .failure(AppleLocalTranslationError.timedOut))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel(id: id)
            }
        }
    }

    func prepare(
        source: Locale.Language,
        target: Locale.Language
    ) async throws {
        try Task.checkCancellation()
        guard job == nil, preparationJob == nil else {
            throw AppleLocalTranslationError.busy
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparationJob = PreparationJob(id: id, continuation: continuation)
                let next = TranslationSession.Configuration(source: source, target: target)
                switch AppleLocalSessionConfigurationPolicy.action(
                    hasConfiguration: configuration != nil,
                    usesSameLanguages: next == configuration
                ) {
                case .install:
                    configuration = next
                case .invalidate:
                    configuration?.invalidate()
                }

                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self?.finishPreparation(
                        id: id,
                        result: .failure(AppleLocalTranslationError.modelDownloadTimedOut)
                    )
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel(id: id)
            }
        }
    }

    /// Caller cancellation owns only its exact in-flight operation. A late session callback or
    /// timeout therefore cannot finish a newer request that reused the persistent host view.
    func cancel(id: UUID) {
        if let current = preparationJob, current.id == id {
            timeoutTask?.cancel()
            preparationJob = nil
            timeoutTask = nil
            current.continuation.resume(throwing: CancellationError())
            return
        }
        if let current = job, current.id == id {
            timeoutTask?.cancel()
            job = nil
            timeoutTask = nil
            current.continuation.resume(throwing: CancellationError())
        }
    }

    func run(session: TranslationSession) async {
        if let preparationJob {
            do {
                try await session.prepareTranslation()
                finishPreparation(id: preparationJob.id, result: .success(()))
            } catch {
                finishPreparation(id: preparationJob.id, result: .failure(error))
            }
            return
        }

        guard let job else { return }
        do {
            // Translation.framework 的 Request 未声明 Sendable，但该数组仅在当前 session 任务中创建和消费。
            nonisolated(unsafe) let requests = job.texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            let ordered = LocalTranslationRouting.orderedTexts(
                responsePairs: responses.map { ($0.clientIdentifier, $0.targetText) },
                expectedCount: job.texts.count
            )
            guard let ordered else { throw AppleLocalTranslationError.incompleteResponse }
            finish(id: job.id, result: .success(ordered))
        } catch {
            finish(id: job.id, result: .failure(error))
        }
    }

    private func finishPreparation(id: UUID, result: Result<Void, Error>) {
        guard let current = preparationJob, current.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        preparationJob = nil
        current.continuation.resume(with: result)
    }

    private func finish(id: UUID, result: Result<[String], Error>) {
        guard let current = job, current.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        job = nil
        // 保留语言配置。同一英中语种的下一次翻译必须在它上面 invalidate，
        // SwiftUI 才会再次执行 translationTask；清 nil 会让连续请求丢触发信号。
        current.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct AppleLocalTranslationHostView: View {
    @ObservedObject var coordinator: AppleLocalTranslationCoordinator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(coordinator.configuration) { session in
                await coordinator.run(session: session)
            }
    }
}

/// pinned SDK 没有 TranslationSession 公共初始化器，所以用常驻、不可见 SwiftUI host 取得 session。
@available(macOS 15.0, *)
@MainActor
private final class AppleLocalTranslationBridge {
    static let shared = AppleLocalTranslationBridge()

    private let coordinator = AppleLocalTranslationCoordinator()
    private let hostPanel: NSPanel

    private init() {
        let host = NSHostingView(rootView: AppleLocalTranslationHostView(coordinator: coordinator))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFrontRegardless()
        hostPanel = panel
    }

    func translate(
        texts: [String],
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> [String] {
        _ = hostPanel // 常驻持有，确保 translationTask 生命周期覆盖整个 App 会话
        return try await coordinator.translate(texts: texts, source: source, target: target)
    }

    func prepare(
        source: Locale.Language,
        target: Locale.Language
    ) async throws {
        _ = hostPanel
        try await coordinator.prepare(source: source, target: target)
    }
}
