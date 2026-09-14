import Foundation

private final class TranslationStreamingResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let originalOrigin: OnlineDataOrigin
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var body = Data()
    private var budget = TranslationResponseBudget()
    private var finished = false
    private var cancellationRequested = false

    init(originalOrigin: OnlineDataOrigin) { self.originalOrigin = originalOrigin }

    func load(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancellationRequested || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard TranslationRedirectPolicy.allows(
            redirectedURL: request.url,
            originalOrigin: originalOrigin
        ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let accepts = !finished && budget.acceptsExpectedContentLength(
            response.expectedContentLength)
        if accepts { self.response = response }
        lock.unlock()
        guard accepts else {
            completionHandler(.cancel)
            finish(.failure(TranslationError.responseTooLarge), cancelTask: true)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        guard budget.reserve(chunkBytes: data.count) else {
            lock.unlock()
            finish(.failure(TranslationError.responseTooLarge), cancelTask: true)
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error), cancelTask: false)
            return
        }
        lock.lock()
        let response = response
        let body = body
        lock.unlock()
        guard let response else {
            finish(.failure(URLError(.badServerResponse)), cancelTask: false)
            return
        }
        finish(.success((body, response)), cancelTask: false)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation {
            finish(.failure(CancellationError()), cancelTask: true)
        }
    }

    private func finish(
        _ result: Result<(Data, URLResponse), Error>,
        cancelTask: Bool
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        let session = session
        self.session = nil
        lock.unlock()

        if cancelTask { task?.cancel() }
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

nonisolated enum TranslationRedirectPolicy {
    static func allows(
        redirectedURL: URL?,
        originalOrigin: OnlineDataOrigin
    ) -> Bool {
        guard let redirectedURL,
              redirectedURL.scheme?.lowercased() == "https",
              let redirectedOrigin = OnlineDataOrigin.normalizedHTTPS(from: redirectedURL) else {
            return false
        }
        return redirectedOrigin == originalOrigin
    }
}

/// 大模型翻译器，兼容所有 OpenAI Chat Completions 格式的 API
class LLMTranslator {
    private let config: TranslationConfig

    init(config: TranslationConfig) {
        self.config = config
    }

    func translate(text: String, targetLanguage: String) async throws -> String {
        do {
            try YoumuResourceBudget.validateTranslationRequest(
                text: text,
                targetLanguage: targetLanguage,
                systemPrompt: config.systemPrompt,
                modelName: config.modelName,
                apiEndpoint: config.apiEndpoint,
                apiKey: config.apiKey)
        } catch YoumuResourceBudgetError.insecureEndpoint {
            throw TranslationError.invalidEndpoint
        } catch {
            throw TranslationError.requestTooLarge
        }
        let systemPrompt = config.systemPrompt
            .replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)

        let requestBody: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
            "max_tokens": 4096,
        ]

        let url = try Self.validatedEndpoint(config.apiEndpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let encodedRequest = try JSONSerialization.data(withJSONObject: requestBody)
        do {
            try YoumuResourceBudget.validateTranslationRequestBody(
                byteCount: encodedRequest.count)
        } catch {
            throw TranslationError.requestTooLarge
        }
        request.httpBody = encodedRequest
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            guard let originalOrigin = OnlineDataOrigin.normalizedHTTPS(from: url) else {
                throw TranslationError.invalidEndpoint
            }
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 45
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.urlCache = nil
            let loader = TranslationStreamingResponseLoader(originalOrigin: originalOrigin)
            (data, response) = try await loader.load(
                request: request,
                configuration: sessionConfiguration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.networkError(URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            // 响应正文可能回显用户文字、Key 或供应商诊断信息，绝不进入错误文案或日志。
            throw TranslationError.apiError(statusCode: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(LLMResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw TranslationError.emptyResponse
        }

        let translated = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw TranslationError.emptyResponse }
        return translated
    }

    static func validatedEndpoint(_ rawValue: String) throws -> URL {
        guard let url = try? YoumuResourceBudget.validatedHTTPSURL(rawValue) else {
            throw TranslationError.invalidEndpoint
        }
        return url
    }
}

// MARK: - Response Model

struct LLMResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Errors

enum TranslationError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidEndpoint
    case apiError(statusCode: Int)
    case emptyResponse
    case requestTooLarge
    case responseTooLarge
    case networkError(Error)
    case onlineDataPermissionDenied

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "这个服务需要填写模型名称，请从 API 服务商提供的信息中复制。"
        case .missingAPIKey:
            return "请先在设置中填写 API Key"
        case .invalidEndpoint:
            return "API 地址无效，请在设置中检查"
        case .apiError(let code):
            return "API 请求失败（HTTP \(code)）"
        case .emptyResponse:
            return "翻译结果为空"
        case .requestTooLarge:
            return "待翻译内容过大，已停止在线请求。"
        case .responseTooLarge:
            return "翻译服务返回内容过大，已停止处理。"
        case .networkError:
            return "网络请求失败，请检查连接后重试。"
        case .onlineDataPermissionDenied:
            return "已拒绝发送文字到在线翻译服务；可改用 Apple 本机翻译，或在设置中重新选择联网权限。"
        }
    }
}
