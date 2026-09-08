import Foundation

/// 翻译执行路径。新安装默认 Apple 本机；自动模式保留给主动需要在线兜底的用户。
enum TranslationBackendPreference: String, Codable, CaseIterable {
    case automatic
    case appleLocal
    case onlineAPI

    var displayName: String {
        switch self {
        case .automatic: return "自动最快（本机优先）"
        case .appleLocal: return "Apple 本机（离线）"
        case .onlineAPI: return "在线 API"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "优先使用 Apple 本机模型；系统不支持或本机失败时才切换在线 API。"
        case .appleLocal:
            return "免费且不需要账号；首次使用由 macOS 确认下载英中模型，之后完全离线。"
        case .onlineAPI:
            return "跳过本机模型，始终使用下方配置的在线翻译服务。"
        }
    }
}

enum SpeechBackendPreference: String, Codable, CaseIterable {
    case automatic
    case macLocal
    case edgeOnline

    var displayName: String {
        switch self {
        case .automatic: return "自动（Edge 失败回退本机）"
        case .macLocal: return "Mac 本机声音（离线）"
        case .edgeOnline: return "Edge 在线神经声音"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "首次说明并征得同意后使用 Edge；拒绝或网络失败时只用 Mac 本机声音。"
        case .macLocal:
            return "文字只在本机处理，不发送到在线语音服务。"
        case .edgeOnline:
            return "文字会发送到 Microsoft Edge 在线语音服务；该网络接口可能随服务变化。"
        }
    }
}

struct AppSettings: Codable {
    var translationConfig: TranslationConfig = TranslationConfig()
    /// 新安装默认使用 Apple 免费本机模型；模型缺失时由系统征得许可后下载。
    var translationBackend: TranslationBackendPreference = .appleLocal
    var targetLanguage: Language = .zhHans
    /// 各平台预设记住的 API Key（预设名 → Key），切换预设时自动回填
    var presetKeys: [String: String] = [:]
    /// OCR 复制默认松手即识别复制；需要精调边界的用户可改为空格确认。
    var ocrCopyRequiresConfirmation: Bool = false
    /// Caps + 1 截图默认松手立即复制；需要精调边界时可主动开启确认。
    var quickSnapshotRequiresConfirmation: Bool = false
    /// “选哪读哪”与各朗读按钮共用的精选 Edge 中文声音。
    var speechVoice: EdgeSpeechVoice = .yunjian
    var speechBackend: SpeechBackendPreference = .automatic
    /// 仅运行时使用；永不编码进 settings.json。
    var credentialErrorMessage: String?
    private var credentialPresetNames: [String] = []

    private enum CodingKeys: String, CodingKey {
        case translationConfig, translationBackend, targetLanguage
        case presetKeys, ocrCopyRequiresConfirmation
        case quickSnapshotRequiresConfirmation, speechVoice, speechBackend
        case credentialPresetNames
    }

    private static var settingsURL: URL {
        YoumuFeatureEnvironmentStore.shared.settingsURL
    }

    /// 旧版（≤1.0）settings.json 把翻译配置平铺在顶层，而非嵌套在 translationConfig 里
    private enum LegacyFlatCodingKeys: String, CodingKey {
        case apiEndpoint, apiKey, modelName, systemPrompt
    }

    /// 旧版 targetLanguage 存的是 case 名（"zhHans"），新版存显示名（"中文简体"）
    private static let legacyLanguageMap: [String: Language] = [
        "auto": .auto, "zhHans": .zhHans, "zhHant": .zhHant,
        "en": .en, "ja": .ja, "ko": .ko,
    ]

    // 旧版本 settings.json 里缺少 hotkeys 字段时，用默认值补齐所有模式
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try container.decodeIfPresent(TranslationConfig.self, forKey: .translationConfig) {
            translationConfig = nested
        } else {
            // 兼容旧版扁平字段（apiEndpoint/apiKey/modelName/systemPrompt 在顶层）
            let legacy = try decoder.container(keyedBy: LegacyFlatCodingKeys.self)
            var config = TranslationConfig()
            if let v = try legacy.decodeIfPresent(String.self, forKey: .apiEndpoint) { config.apiEndpoint = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .apiKey) { config.apiKey = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .modelName) { config.modelName = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .systemPrompt) { config.systemPrompt = v }
            translationConfig = config
        }
        if let lang = try? container.decodeIfPresent(Language.self, forKey: .targetLanguage) {
            targetLanguage = lang
        } else if let raw = try container.decodeIfPresent(String.self, forKey: .targetLanguage) {
            // 兼容旧版写法（"zhHans" 等 case 名）
            targetLanguage = AppSettings.legacyLanguageMap[raw] ?? .zhHans
        } else {
            targetLanguage = .zhHans
        }
        translationBackend = try container.decodeIfPresent(
            TranslationBackendPreference.self, forKey: .translationBackend
        ) ?? .appleLocal
        ocrCopyRequiresConfirmation = try container.decodeIfPresent(
            Bool.self, forKey: .ocrCopyRequiresConfirmation
        ) ?? false
        quickSnapshotRequiresConfirmation = try container.decodeIfPresent(
            Bool.self, forKey: .quickSnapshotRequiresConfirmation
        ) ?? false
        speechVoice = try container.decodeIfPresent(
            EdgeSpeechVoice.self, forKey: .speechVoice
        ) ?? .yunjian
        speechBackend = try container.decodeIfPresent(
            SpeechBackendPreference.self, forKey: .speechBackend
        ) ?? .automatic
        presetKeys = try container.decodeIfPresent([String: String].self, forKey: .presetKeys) ?? [:]
        credentialPresetNames = try container.decodeIfPresent(
            [String].self, forKey: .credentialPresetNames
        ) ?? []
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translationConfig, forKey: .translationConfig)
        try container.encode(translationBackend, forKey: .translationBackend)
        try container.encode(targetLanguage, forKey: .targetLanguage)
        try container.encode(ocrCopyRequiresConfirmation, forKey: .ocrCopyRequiresConfirmation)
        try container.encode(quickSnapshotRequiresConfirmation, forKey: .quickSnapshotRequiresConfirmation)
        try container.encode(speechVoice, forKey: .speechVoice)
        try container.encode(speechBackend, forKey: .speechBackend)
        // 仅保存非秘密索引；presetKeys 的值始终只进钥匙串。
        try container.encode(presetKeys.keys.sorted(), forKey: .credentialPresetNames)
    }

    static func load() -> AppSettings {
        prepareFeatureDirectory()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return AppSettings()
        }
        var loadedData: Data?
        do {
            let data = try YoumuResourceBudget.loadBoundedSettingsData(from: settingsURL)
            loadedData = data
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
            return try decodeAndMigrate(data: data, vault: CredentialVault(store: KeychainCredentialStore.shared)) {
                try $0.write(to: settingsURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: settingsURL.path
                )
            }
        } catch {
            KeychainCredentialStore.shared.record(error)
            var fallback = loadedData.flatMap { try? decodeValidated(data: $0) } ?? AppSettings()
            fallback.translationConfig.apiKey = ""
            fallback.presetKeys = [:]
            fallback.credentialErrorMessage = error.localizedDescription
            return fallback
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            Self.prepareFeatureDirectory()
            let knownNames = Set(credentialPresetNames)
                .union(TranslationConfig.presetOrder)
                .union(presetKeys.keys)
            try CredentialVault(store: KeychainCredentialStore.shared).persist(
                currentKey: translationConfig.apiKey,
                presetKeys: presetKeys,
                knownPresetNames: knownNames
            )
            let data = try Self.sanitizedData(self)
            try data.write(to: Self.settingsURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.settingsURL.path
            )
            KeychainCredentialStore.shared.record(nil)
            return true
        } catch {
            KeychainCredentialStore.shared.record(error)
            PrivacySafeLog.event("settings_save_failed", error: error)
            return false
        }
    }

    static func decodeAndMigrate(
        data: Data,
        vault: CredentialVault,
        persistSanitized: (Data) throws -> Void
    ) throws -> AppSettings {
        var settings = try decodeValidated(data: data)
        let hasInlineCredentials = containsLegacyCredentialFields(data)
        let knownNames = Set(settings.credentialPresetNames)
            .union(TranslationConfig.presetOrder)
            .union(settings.presetKeys.keys)

        if hasInlineCredentials {
            try vault.persist(
                currentKey: settings.translationConfig.apiKey,
                presetKeys: settings.presetKeys,
                knownPresetNames: knownNames
            )
            try persistSanitized(sanitizedData(settings))
        } else {
            try vault.hydrate(
                currentKey: &settings.translationConfig.apiKey,
                presetKeys: &settings.presetKeys,
                presetNames: knownNames
            )
        }
        settings.credentialPresetNames = Array(knownNames).sorted()
        settings.credentialErrorMessage = nil
        KeychainCredentialStore.shared.record(nil)
        return settings
    }

    static func sanitizedData(_ settings: AppSettings) throws -> Data {
        try validate(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try YoumuResourceBudget.validateSettingsData(data)
        return data
    }

    static func containsLegacyCredentialFields(_ data: Data) -> Bool {
        guard (try? YoumuResourceBudget.validateSettingsData(data)) != nil else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if root["presetKeys"] != nil || root["apiKey"] != nil { return true }
        if let config = root["translationConfig"] as? [String: Any], config["apiKey"] != nil {
            return true
        }
        return false
    }

    private static func decodeValidated(data: Data) throws -> AppSettings {
        try YoumuResourceBudget.validateSettingsData(data)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        try validate(settings)
        return settings
    }

    private static func validate(_ settings: AppSettings) throws {
        try YoumuResourceBudget.validateSettings(
            apiEndpoint: settings.translationConfig.apiEndpoint,
            apiKey: settings.translationConfig.apiKey,
            modelName: settings.translationConfig.modelName,
            systemPrompt: settings.translationConfig.systemPrompt,
            presetKeys: settings.presetKeys,
            credentialPresetNames: settings.credentialPresetNames
        )
        let knownNames = Set(settings.credentialPresetNames)
            .union(TranslationConfig.presetOrder)
            .union(settings.presetKeys.keys)
        guard knownNames.count <= YoumuResourceBudget.maximumPresetCount else {
            throw YoumuResourceBudgetError.tooManyItems(
                field: "翻译预设",
                maximumCount: YoumuResourceBudget.maximumPresetCount)
        }
    }

    private static func prepareFeatureDirectory() {
        let directory = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
