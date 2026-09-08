import Foundation

nonisolated enum YoumuResourceBudgetError: LocalizedError, Equatable {
    case fileTooLarge(maximumBytes: Int)
    case tooManyItems(field: String, maximumCount: Int)
    case fieldTooLong(field: String, maximumBytes: Int)
    case requestTooLarge(maximumBytes: Int)
    case responseTooLarge(maximumBytes: Int)
    case insecureEndpoint

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maximumBytes):
            return "配置文件超过 \(maximumBytes / 1_048_576) MiB 安全上限。"
        case .tooManyItems(let field, let maximumCount):
            return "\(field)超过 \(maximumCount) 项安全上限。"
        case .fieldTooLong(let field, let maximumBytes):
            return "\(field)超过 \(maximumBytes) 字节安全上限。"
        case .requestTooLarge(let maximumBytes):
            return "待翻译内容超过 \(maximumBytes / 1_024) KiB 请求上限。"
        case .responseTooLarge(let maximumBytes):
            return "翻译服务响应超过 \(maximumBytes / 1_048_576) MiB 安全上限。"
        case .insecureEndpoint:
            return "在线翻译地址必须是无账号信息的 HTTPS 地址。"
        }
    }
}

nonisolated enum YoumuResourceBudget {
    static let maximumSettingsFileBytes = 1_048_576
    static let maximumPresetCount = 32
    static let maximumPresetNameBytes = 256
    static let maximumEndpointBytes = 2_048
    static let maximumModelNameBytes = 512
    static let maximumSystemPromptBytes = 32 * 1_024
    static let maximumAPIKeyBytes = 16 * 1_024
    static let maximumTranslationInputBytes = 512 * 1_024
    static let maximumTargetLanguageBytes = 256
    static let maximumTranslationRequestBodyBytes = 768 * 1_024
    static let maximumTranslationResponseBytes = 4 * 1_024 * 1_024

    static func loadBoundedSettingsData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try validateFileByteCount(fileSize, maximum: maximumSettingsFileBytes)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validateFileByteCount(data.count, maximum: maximumSettingsFileBytes)
        return data
    }

    static func validatedHTTPSURL(_ rawValue: String) throws -> URL {
        try validateString(rawValue, field: "API 地址", maximum: maximumEndpointBytes)
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            throw YoumuResourceBudgetError.insecureEndpoint
        }
        return url
    }

    static func validateSettings(
        apiEndpoint: String,
        apiKey: String,
        modelName: String,
        systemPrompt: String,
        presetKeys: [String: String],
        credentialPresetNames: [String]
    ) throws {
        _ = try validatedHTTPSURL(apiEndpoint)
        try validateString(apiKey, field: "API Key", maximum: maximumAPIKeyBytes)
        try validateString(modelName, field: "模型名称", maximum: maximumModelNameBytes)
        try validateString(systemPrompt, field: "系统提示词", maximum: maximumSystemPromptBytes)
        guard presetKeys.count <= maximumPresetCount,
              credentialPresetNames.count <= maximumPresetCount else {
            throw YoumuResourceBudgetError.tooManyItems(
                field: "翻译预设",
                maximumCount: maximumPresetCount)
        }
        for (name, key) in presetKeys {
            try validateString(name, field: "预设名称", maximum: maximumPresetNameBytes)
            try validateString(key, field: "预设 API Key", maximum: maximumAPIKeyBytes)
        }
        for name in credentialPresetNames {
            try validateString(name, field: "预设名称", maximum: maximumPresetNameBytes)
        }
    }

    static func validateTranslationRequest(
        text: String,
        targetLanguage: String,
        systemPrompt: String,
        modelName: String,
        apiEndpoint: String,
        apiKey: String
    ) throws {
        guard text.utf8.count <= maximumTranslationInputBytes else {
            throw YoumuResourceBudgetError.requestTooLarge(
                maximumBytes: maximumTranslationInputBytes)
        }
        try validateString(
            targetLanguage,
            field: "目标语言",
            maximum: maximumTargetLanguageBytes)
        try validateString(
            systemPrompt,
            field: "系统提示词",
            maximum: maximumSystemPromptBytes)
        try validateString(modelName, field: "模型名称", maximum: maximumModelNameBytes)
        _ = try validatedHTTPSURL(apiEndpoint)
        try validateString(apiKey, field: "API Key", maximum: maximumAPIKeyBytes)
    }

    static func validateTranslationRequestBody(byteCount: Int) throws {
        guard byteCount <= maximumTranslationRequestBodyBytes else {
            throw YoumuResourceBudgetError.requestTooLarge(
                maximumBytes: maximumTranslationRequestBodyBytes)
        }
    }

    static func validateSettingsData(_ data: Data) throws {
        try validateFileByteCount(data.count, maximum: maximumSettingsFileBytes)
    }

    private static func validateFileByteCount(_ byteCount: Int, maximum: Int) throws {
        guard byteCount >= 0, byteCount <= maximum else {
            throw YoumuResourceBudgetError.fileTooLarge(maximumBytes: maximum)
        }
    }

    private static func validateString(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        guard value.utf8.count <= maximum else {
            throw YoumuResourceBudgetError.fieldTooLong(
                field: field,
                maximumBytes: maximum)
        }
    }
}

nonisolated struct TranslationResponseBudget: Equatable, Sendable {
    private(set) var receivedBytes = 0

    func acceptsExpectedContentLength(_ length: Int64) -> Bool {
        length < 0 || length <= Int64(YoumuResourceBudget.maximumTranslationResponseBytes)
    }

    mutating func reserve(chunkBytes: Int) -> Bool {
        guard chunkBytes >= 0,
              chunkBytes <= YoumuResourceBudget.maximumTranslationResponseBytes - receivedBytes else {
            return false
        }
        receivedBytes += chunkBytes
        return true
    }
}
