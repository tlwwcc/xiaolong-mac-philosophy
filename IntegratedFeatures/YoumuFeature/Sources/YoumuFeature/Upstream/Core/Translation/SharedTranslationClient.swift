import Foundation

enum SharedTranslationError: LocalizedError {
    case selectionTooLarge
    case busy
    case unavailable
    case invalidResponse
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .selectionTooLarge: return "这次文字较多，请缩小选区后再翻译。"
        case .busy: return "翻译请求较多，请稍后重试；也可以在游目设置中选择 Apple 本机翻译。"
        case .unavailable: return "共享翻译暂时不可用，请稍后重试，或选择 Apple 本机翻译。"
        case .invalidResponse: return "译文不完整，已停止本次翻译，请重试。"
        case .unsupportedLanguage: return "请先选择要翻译成的语言。"
        }
    }
}

/// The vendor credential never exists in the client. Every batch remains cancellable.
final class SharedTranslationClient {
    static let endpoint = URL(string: "https://aixlg.com/api/translation/v1/translate")!
    typealias Transport = @MainActor (URLRequest, URLSessionConfiguration) async throws -> (Data, URLResponse)
    private let transport: Transport
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil, transport: @escaping Transport = SharedTranslationClient.load) {
        self.defaults = defaults
        self.transport = transport
    }

    static func load(_ request: URLRequest, _ configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        let origin = OnlineDataOrigin.normalizedHTTPS(from: Self.endpoint)!
        return try await TranslationStreamingResponseLoader(originalOrigin: origin)
            .load(request: request, configuration: configuration)
    }
    private struct Request: Encodable {
        let texts: [String]
        let target: String
        let deviceId: String
    }
    private struct Response: Decodable { let translations: [String] }

    static func languageCode(_ language: Language) throws -> String {
        switch language {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .auto: throw SharedTranslationError.unsupportedLanguage
        }
    }

    /// Keep OCR blocks intact. Limit encoded size too, since JSON escaping adds bytes.
    static func batches(_ texts: [String]) throws -> [[String]] {
        guard texts.count <= 72 else { throw SharedTranslationError.selectionTooLarge }
        var batches: [[String]] = []
        var batch: [String] = []
        func fits(_ values: [String]) throws -> Bool {
            let segments = values.enumerated().map { ["id": $0.offset, "text": $0.element] as [String: Any] }
            let encoded = try JSONSerialization.data(withJSONObject: ["segments": segments])
            return values.count <= 12 && encoded.count <= 2_400
                && values.reduce(0, { $0 + $1.utf8.count }) <= 2_000
        }
        for text in texts {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 1_800, try fits([text]) else {
                throw SharedTranslationError.selectionTooLarge
            }
            if try !fits(batch + [text]) { batches.append(batch); batch = [] }
            batch.append(text)
        }
        if !batch.isEmpty { batches.append(batch) }
        guard batches.count <= 6 else { throw SharedTranslationError.selectionTooLarge }
        return batches
    }

    static func deviceID(defaults: UserDefaults) -> String {
        let key = YoumuFeatureEnvironmentStore.shared.userDefaultsKey("shared-translation-device-id")
        if let value = defaults.string(forKey: key), let uuid = UUID(uuidString: value),
           uuid.uuid.6 >> 4 == 4, uuid.uuid.8 >> 6 == 2 {
            return uuid.uuidString.lowercased()
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    static func decode(_ data: Data, expectedCount: Int) throws -> [String] {
        guard data.count <= 65_536,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.translations.count == expectedCount,
              decoded.translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SharedTranslationError.invalidResponse
        }
        return decoded.translations
    }

    func translate(_ texts: [String], target: Language) async throws -> [String] {
        let language = try Self.languageCode(target)
        let batches = try Self.batches(texts)
        let id = Self.deviceID(defaults: defaults ?? YoumuFeatureEnvironmentStore.shared.userDefaults())
        var result: [String] = []
        for batch in batches {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Request(texts: batch, target: language, deviceId: id))
            request.timeoutInterval = 22
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 22
            configuration.timeoutIntervalForResource = 25
            let (data, response) = try await transport(request, configuration)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw SharedTranslationError.unavailable }
            switch response.statusCode {
            case 200: result += try Self.decode(data, expectedCount: batch.count)
            case 413: throw SharedTranslationError.selectionTooLarge
            case 429, 503: throw SharedTranslationError.busy
            case 502: throw SharedTranslationError.invalidResponse
            default: throw SharedTranslationError.unavailable
            }
        }
        return result
    }
}
