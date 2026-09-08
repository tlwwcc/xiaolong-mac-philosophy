import CryptoKit
import Foundation

private final class EdgeSpeechRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let originalOrigin: OnlineDataOrigin

    init(originalOrigin: OnlineDataOrigin) { self.originalOrigin = originalOrigin }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            EdgeSpeechRedirectPolicy.allows(
                redirectedURL: request.url,
                originalOrigin: originalOrigin
            ) ? request : nil
        )
    }
}

nonisolated enum EdgeSpeechRedirectPolicy {
    static func allows(
        redirectedURL: URL?,
        originalOrigin: OnlineDataOrigin
    ) -> Bool {
        guard let redirectedURL,
              let scheme = redirectedURL.scheme?.lowercased(),
              scheme == "https" || scheme == "wss",
              let redirectedOrigin = OnlineDataOrigin.normalizedHTTPS(from: redirectedURL) else {
            return false
        }
        return redirectedOrigin == originalOrigin
    }
}

enum EdgeOnlineSpeechError: LocalizedError {
    case invalidEndpoint
    case emptyAudio
    case malformedAudioFrame
    case timedOut
    case responseTooLarge
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Edge 在线语音地址无效"
        case .emptyAudio: return "Edge 在线语音没有返回音频"
        case .malformedAudioFrame: return "Edge 在线语音返回了无效音频帧"
        case .timedOut: return "Edge 在线语音响应超时"
        case .responseTooLarge: return "Edge 在线语音返回内容过大"
        case .textTooLong: return "朗读文字过长，已改用本机声音"
        }
    }
}

/// Edge 返回的真实词边界。offset/duration 都对应原始 1.0x 音频时间轴。
struct EdgeSpeechBoundary: Equatable, Sendable {
    let offset: TimeInterval
    let duration: TimeInterval
    let text: String
}

struct EdgeSpeechResult: Sendable {
    let audio: Data
    let wordBoundaries: [EdgeSpeechBoundary]
}

private struct IndexedEdgeSpeechResult: Sendable {
    let index: Int
    let result: EdgeSpeechResult
}

/// 精选中文 Edge 神经声音。只保留四个辨识度明确的场景，避免设置页变成音色仓库。
enum EdgeSpeechVoice: String, Codable, CaseIterable {
    case yunjian = "zh-CN-YunjianNeural"
    case xiaoxiao = "zh-CN-XiaoxiaoNeural"
    case xiaoyi = "zh-CN-XiaoyiNeural"
    case yunyang = "zh-CN-YunyangNeural"

    var displayName: String {
        switch self {
        case .yunjian: return "云健 · 沉稳阅读"
        case .xiaoxiao: return "晓晓 · 自然温暖"
        case .xiaoyi: return "晓伊 · 轻柔夜读"
        case .yunyang: return "云扬 · 专业播报"
        }
    }

    var detail: String {
        switch self {
        case .yunjian: return "稳重清晰，适合文章、知识与长文阅读"
        case .xiaoxiao: return "自然亲切，适合日常内容和短文本"
        case .xiaoyi: return "柔和舒缓，适合夜间阅读与慢节奏内容"
        case .yunyang: return "成熟权威，适合新闻、报告和专业材料"
        }
    }
}

/// 原生调用 Microsoft Edge「大声朗读」所用的在线语音服务。
/// 不依赖浏览器、Python 或 API Key；协议不可用时由 SpeechService 回落到 macOS 本机语音。
struct EdgeOnlineSpeechClient: Sendable {
    private static let endpoint = URL(
        string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    )!
    static var onlineConsentEndpoint: URL { endpoint }
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let gecVersion = "1-143.0.3650.75"
    static let maximumInputUTF8Bytes = 100_000
    static let maximumAudioBytes = 32 * 1_024 * 1_024
    static let maximumMetadataMessageBytes = 2 * 1_024 * 1_024
    static let maximumWordBoundaries = 200_000
    static let maximumChunkEscapedUTF8Bytes = 7_500
    static let maximumConcurrentChunks = 4
    static let totalTimeout: TimeInterval = 60

    func synthesize(
        text: String,
        language: String,
        preferredChineseVoice: EdgeSpeechVoice? = nil
    ) async throws -> EdgeSpeechResult {
        guard text.utf8.count <= Self.maximumInputUTF8Bytes else {
            throw EdgeOnlineSpeechError.textTooLong
        }
        let chunks = Self.textChunks(
            text,
            maximumEscapedUTF8Bytes: Self.maximumChunkEscapedUTF8Bytes
        )
        let deadline = Date().addingTimeInterval(Self.totalTimeout)
        let voice = Self.voiceIdentifier(
            for: language,
            preferredChineseVoice: preferredChineseVoice
        )
        let results = try await synthesizeChunks(
            chunks,
            voice: voice,
            locale: language,
            deadline: deadline
        )
        var completeAudio = Data()
        var completeBoundaries: [EdgeSpeechBoundary] = []
        for result in results {
            try Task.checkCancellation()
            // 输出是 48kbps CBR MP3；按累计字节换算跨块时间，避免长文边界逐块归零。
            let offsetCompensation = TimeInterval(completeAudio.count * 8) / 48_000
            completeBoundaries.append(contentsOf: result.wordBoundaries.map {
                EdgeSpeechBoundary(
                    offset: $0.offset + offsetCompensation,
                    duration: $0.duration,
                    text: $0.text
                )
            })
            completeAudio.append(result.audio)
            guard completeAudio.count <= Self.maximumAudioBytes,
                  completeBoundaries.count <= Self.maximumWordBoundaries else {
                throw EdgeOnlineSpeechError.responseTooLarge
            }
        }
        guard !completeAudio.isEmpty else { throw EdgeOnlineSpeechError.emptyAudio }
        return EdgeSpeechResult(audio: completeAudio, wordBoundaries: completeBoundaries)
    }

    /// 长文按原始顺序合并，但最多并发四个分块，避免逐块握手造成首播等待线性增长。
    private func synthesizeChunks(
        _ chunks: [String],
        voice: String,
        locale: String,
        deadline: Date
    ) async throws -> [EdgeSpeechResult] {
        guard !chunks.isEmpty else { return [] }
        if chunks.count == 1 {
            return [
                try await synthesizeChunk(
                    chunks[0],
                    voice: voice,
                    locale: locale,
                    deadline: deadline
                )
            ]
        }

        return try await withThrowingTaskGroup(
            of: IndexedEdgeSpeechResult.self
        ) { group in
            let initialCount = min(Self.maximumConcurrentChunks, chunks.count)
            for index in 0..<initialCount {
                let chunk = chunks[index]
                group.addTask {
                    IndexedEdgeSpeechResult(
                        index: index,
                        result: try await self.synthesizeChunk(
                            chunk,
                            voice: voice,
                            locale: locale,
                            deadline: deadline
                        )
                    )
                }
            }

            var ordered = Array<EdgeSpeechResult?>(repeating: nil, count: chunks.count)
            var nextIndex = initialCount
            while let indexed = try await group.next() {
                ordered[indexed.index] = indexed.result
                if nextIndex < chunks.count {
                    let index = nextIndex
                    let chunk = chunks[index]
                    nextIndex += 1
                    group.addTask {
                        IndexedEdgeSpeechResult(
                            index: index,
                            result: try await self.synthesizeChunk(
                                chunk,
                                voice: voice,
                                locale: locale,
                                deadline: deadline
                            )
                        )
                    }
                }
            }
            return ordered.compactMap { $0 }
        }
    }

    private func synthesizeChunk(
        _ text: String,
        voice: String,
        locale: String,
        deadline: Date
    ) async throws -> EdgeSpeechResult {
        let connectionID = Self.randomID()
        var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: Self.secMSGECToken(at: Date())),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: Self.gecVersion),
            URLQueryItem(name: "ConnectionId", value: connectionID),
        ]
        guard let url = components?.url else { throw EdgeOnlineSpeechError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromiumVersion) "
                + "Safari/537.36 Edg/\(Self.chromiumVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            forHTTPHeaderField: "Origin"
        )
        request.setValue("muid=\(Self.randomID())", forHTTPHeaderField: "Cookie")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        guard let originalOrigin = OnlineDataOrigin.normalizedHTTPS(from: Self.endpoint) else {
            throw EdgeOnlineSpeechError.invalidEndpoint
        }
        let session = URLSession(
            configuration: configuration,
            delegate: EdgeSpeechRedirectDelegate(originalOrigin: originalOrigin),
            delegateQueue: nil
        )
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = Self.maximumMetadataMessageBytes
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await socket.send(.string(Self.speechConfigMessage()))
        try await socket.send(.string(Self.ssmlMessage(text: text, voice: voice, locale: locale)))

        var audio = Data()
        var wordBoundaries: [EdgeSpeechBoundary] = []
        receiveLoop: while true {
            try Task.checkCancellation()
            let message = try await Self.receive(socket, before: deadline)
            switch message {
            case .string(let value):
                guard value.utf8.count <= Self.maximumMetadataMessageBytes else {
                    throw EdgeOnlineSpeechError.responseTooLarge
                }
                if value.localizedCaseInsensitiveContains("Path:turn.end") {
                    break receiveLoop
                }
                wordBoundaries.append(contentsOf: Self.wordBoundaries(fromMessage: value))
                guard wordBoundaries.count <= Self.maximumWordBoundaries else {
                    throw EdgeOnlineSpeechError.responseTooLarge
                }
            case .data(let value):
                guard value.count <= Self.maximumMetadataMessageBytes else {
                    throw EdgeOnlineSpeechError.responseTooLarge
                }
                if let chunk = try Self.audioPayload(from: value) {
                    audio.append(chunk)
                    guard audio.count <= Self.maximumAudioBytes else {
                        throw EdgeOnlineSpeechError.responseTooLarge
                    }
                }
            @unknown default:
                continue
            }
        }
        guard !audio.isEmpty else { throw EdgeOnlineSpeechError.emptyAudio }
        return EdgeSpeechResult(audio: audio, wordBoundaries: wordBoundaries)
    }

    private static func receive(
        _ socket: URLSessionWebSocketTask,
        before deadline: Date
    ) async throws -> URLSessionWebSocketTask.Message {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw EdgeOnlineSpeechError.timedOut }
        return try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw EdgeOnlineSpeechError.timedOut
            }
            guard let first = try await group.next() else {
                throw EdgeOnlineSpeechError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - 可测试的协议纯函数

    static func voiceIdentifier(
        for language: String,
        preferredChineseVoice: EdgeSpeechVoice? = nil
    ) -> String {
        switch language {
        case "zh-CN": return (preferredChineseVoice ?? .yunjian).rawValue
        case "zh-TW": return "zh-TW-HsiaoChenNeural"
        case "ja-JP": return "ja-JP-NanamiNeural"
        case "ko-KR": return "ko-KR-SunHiNeural"
        default: return "en-US-EmmaMultilingualNeural"
        }
    }

    static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func textChunks(_ text: String, maximumEscapedUTF8Bytes: Int = 3_000) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for character in trimmed {
            let fragment = String(character)
            let bytes = xmlEscaped(fragment).utf8.count
            if !current.isEmpty, currentBytes + bytes > maximumEscapedUTF8Bytes {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func secMSGECToken(at date: Date) -> String {
        let windowsEpochOffset = 11_644_473_600.0
        let roundedSeconds = floor((date.timeIntervalSince1970 + windowsEpochOffset) / 300) * 300
        let ticks = UInt64(roundedSeconds * 10_000_000)
        let payload = Data("\(ticks)\(trustedClientToken)".utf8)
        return SHA256.hash(data: payload)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// Edge 二进制帧：2 字节大端 header 长度 + headers + MP3 payload。
    static func audioPayload(from frame: Data) throws -> Data? {
        guard frame.count >= 2 else { throw EdgeOnlineSpeechError.malformedAudioFrame }
        let bytes = [UInt8](frame.prefix(2))
        let headerLength = Int(bytes[0]) << 8 | Int(bytes[1])
        let payloadStart = 2 + headerLength
        guard payloadStart <= frame.count else { throw EdgeOnlineSpeechError.malformedAudioFrame }

        let headerRange = 2..<payloadStart
        guard let headers = String(data: frame.subdata(in: headerRange), encoding: .utf8),
              headers.localizedCaseInsensitiveContains("Path:audio") else {
            return nil
        }

        var start = payloadStart
        while start < frame.count, frame[start] == 0x0D || frame[start] == 0x0A {
            start += 1
        }
        return frame.subdata(in: start..<frame.count)
    }

    /// 解析 Edge `Path:audio.metadata` 文本帧。时间单位是 100ns tick。
    static func wordBoundaries(fromMessage message: String) -> [EdgeSpeechBoundary] {
        guard message.localizedCaseInsensitiveContains("Path:audio.metadata"),
              let separator = message.range(of: "\r\n\r\n") else { return [] }
        let json = String(message[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["Metadata"] as? [[String: Any]] else { return [] }

        return metadata.compactMap { item in
            guard item["Type"] as? String == "WordBoundary",
                  let payload = item["Data"] as? [String: Any],
                  let offset = (payload["Offset"] as? NSNumber)?.doubleValue,
                  let duration = (payload["Duration"] as? NSNumber)?.doubleValue,
                  let textPayload = payload["text"] as? [String: Any],
                  let text = textPayload["Text"] as? String,
                  !text.isEmpty else { return nil }
            return EdgeSpeechBoundary(
                offset: offset / 10_000_000,
                duration: duration / 10_000_000,
                text: text
            )
        }
    }

    private static func speechConfigMessage() -> String {
        let json = "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":"
            + "{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"true\"},"
            + "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
        return "X-Timestamp:\(timestamp())\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n\(json)\r\n"
    }

    private static func ssmlMessage(text: String, voice: String, locale: String) -> String {
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
            + "xml:lang='\(locale)'><voice name='\(voice)'>"
            + "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(xmlEscaped(text))</prosody>"
            + "</voice></speak>"
        return "X-RequestId:\(randomID())\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp())\r\n"
            + "Path:ssml\r\n\r\n\(ssml)"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func randomID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}
