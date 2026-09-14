import Foundation

struct TranslationBackendPolicy: Equatable {
    let triesAppleLocal: Bool
    let allowsOnline: Bool

    static func resolve(_ preference: TranslationBackendPreference) -> TranslationBackendPolicy {
        switch preference {
        case .automatic:
            return TranslationBackendPolicy(triesAppleLocal: true, allowsOnline: true)
        case .appleLocal:
            return TranslationBackendPolicy(triesAppleLocal: true, allowsOnline: false)
        case .onlineAPI:
            return TranslationBackendPolicy(triesAppleLocal: false, allowsOnline: true)
        }
    }
}

enum TranslationBackendError: LocalizedError {
    case appleLocalUnavailable

    var errorDescription: String? {
        "Apple 暂不支持这组语言，或当前系统低于 macOS 15。可在游目设置中选择在线 API。"
    }
}

/// 翻译服务统一入口
class TranslationService {
    static let shared = TranslationService()

    /// 整段文本翻译（截图翻译弹窗用）
    func translate(text: String, targetLanguage: Language) async throws -> String {
        let settings = AppSettings.load()
        let policy = TranslationBackendPolicy.resolve(settings.translationBackend)

        if policy.triesAppleLocal {
            do {
                if let local = try await AppleLocalTranslator.shared.translate(
                    texts: [text], targetLanguage: targetLanguage
                )?.first {
                    return local
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard policy.allowsOnline else { throw error }
                // 不记录原文/译文；本机快路失败时静默回到现有在线链路。
                PrivacySafeLog.event("apple_translation_fallback", error: error)
            }
            guard policy.allowsOnline else {
                throw TranslationBackendError.appleLocalUnavailable
            }
        }

        let config = try loadValidConfig(from: settings)
        try await requireOnlineConsent(for: config)
        let translator = LLMTranslator(config: config)
        return try await translator.translate(
            text: text,
            targetLanguage: targetLanguage.displayName
        )
    }

    /// 结构化逐块翻译（原图翻译用）：
    /// 1. OCR 块按顺序编号 ⟦n⟧ 一次请求发完，按编号解析回每个块
    /// 2. 编号缺失的块单独重试一次
    /// 3. 仍失败的块返回原文并标记 failed（界面标注），绝不整批错位
    ///
    /// 仅当整体请求失败（网络/API 错误）时才 throw。
    func translateBlocks(
        _ blockTexts: [String],
        targetLanguage: Language,
        systemPresentation: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> [NumberedBlockTranslation.BlockTranslation] {
        guard !blockTexts.isEmpty else { return [] }
        let settings = AppSettings.load()
        let policy = TranslationBackendPolicy.resolve(settings.translationBackend)

        if policy.triesAppleLocal {
            do {
                if let local = try await AppleLocalTranslator.shared.translateBlocks(
                    texts: blockTexts, targetLanguage: targetLanguage,
                    systemPresentation: systemPresentation
                ) {
                    if let error = local.firstError,
                       local.successfulGroups == 0 || policy.allowsOnline { throw error }
                    return local.blocks
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard policy.allowsOnline else { throw error }
                PrivacySafeLog.event("apple_batch_translation_fallback", error: error)
            }
            guard policy.allowsOnline else {
                throw TranslationBackendError.appleLocalUnavailable
            }
        }

        let config = try loadValidConfig(from: settings)
        try await requireOnlineConsent(for: config)
        let translator = LLMTranslator(config: config)

        // 编号协议请求：system prompt 追加协议说明，user 消息带 ⟦n⟧ 前缀
        let numberedConfig = TranslationConfig(
            apiEndpoint: config.apiEndpoint,
            apiKey: config.apiKey,
            modelName: config.modelName,
            systemPrompt: config.systemPrompt
                + NumberedBlockTranslation.numberedProtocolSuffix(
                    targetLanguage: targetLanguage.displayName
                )
        )
        let numberedTranslator = LLMTranslator(config: numberedConfig)
        let response = try await numberedTranslator.translate(
            text: NumberedBlockTranslation.buildUserMessage(blockTexts: blockTexts),
            targetLanguage: targetLanguage.displayName
        )

        let parsed = NumberedBlockTranslation.parseNumberedResponse(response)
        let missing = NumberedBlockTranslation.missingIndices(
            parsed: parsed, expectedCount: blockTexts.count
        )
        if !missing.isEmpty {
            PrivacySafeLog.event(
                "numbered_translation_missing",
                metadata: ["count": missing.count]
            )
        }

        // 逐块组装结果；缺失块单独重试，再失败降级为原文 + failed 标记
        var results: [NumberedBlockTranslation.BlockTranslation] = []
        results.reserveCapacity(blockTexts.count)

        for index in 0..<blockTexts.count {
            if let translated = parsed[index + 1] {
                results.append(.init(index: index, text: translated, failed: false))
                continue
            }
            // 降级路径：单独翻译这一块（不带编号协议）
            do {
                let single = try await translator.translate(
                    text: blockTexts[index],
                    targetLanguage: targetLanguage.displayName
                )
                results.append(.init(index: index, text: single, failed: false))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                PrivacySafeLog.event(
                    "single_block_translation_failed",
                    error: error,
                    metadata: ["block": index + 1]
                )
                results.append(.init(index: index, text: blockTexts[index], failed: true))
            }
        }
        return results
    }

    // MARK: - Private

    private func loadValidConfig(from settings: AppSettings) throws -> TranslationConfig {
        let config = try settings.translationConfig.normalizedForUse()
        guard !config.requiresAPIKey || !config.apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }
        return config
    }

    private func requireOnlineConsent(for config: TranslationConfig) async throws {
        let endpoint = try LLMTranslator.validatedEndpoint(config.apiEndpoint)
        let allowed = OnlineDataConsentManager.shared.request(
            .translation,
            endpoint: endpoint
        )
        guard allowed else { throw TranslationError.onlineDataPermissionDenied }
    }
}
