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

enum EdgeOnlineSpeechError: LocalizedError, Equatable {
    case invalidEndpoint
    case emptyAudio
    case malformedAudioFrame
    case timedOut
    case responseTooLarge
    case textTooLong
    case consentRequired
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Edge 在线语音地址无效"
        case .emptyAudio: return "Edge 在线语音没有返回音频"
        case .malformedAudioFrame: return "Edge 在线语音返回了无效音频帧"
        case .timedOut: return "Edge 在线语音响应超时"
        case .responseTooLarge: return "Edge 在线语音返回内容过大"
        case .textTooLong: return "朗读文字过长，请分段朗读"
        case .consentRequired: return "尚未允许 Edge 在线朗读"
        case .playbackFailed: return "Edge 音频无法播放"
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
/// 不依赖浏览器、Python 或 API Key；失败交给 SpeechService 按用户所选来源处理。
struct EdgeOnlineSpeechClient: Sendable {
    private static let endpoint = URL(
        string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    )!
    static var onlineConsentEndpoint: URL { endpoint }
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let gecVersion = "2-143.0.3650.75"
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
                // URLSession receive can otherwise keep the task group alive after its deadline.
                socket.cancel(with: .goingAway, reason: nil)
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
        return EdgeSpeechTokenV2.token(payload)
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

    static func ssmlMessage(text: String, voice: String, locale: String) -> String {
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

/// Edge's v2 handshake uses a fixed SHA-256 prefix state followed by a CS64 check.
/// Protocol parameters were checked against edge-tts' upstream interoperability implementation:
/// https://github.com/rany2/edge-tts/blob/master/src/edge_tts/drm.py
/// This implementation uses ordinary SHA-256 rounds rather than its optimized/unrolled code.
private enum EdgeSpeechTokenV2 {
    private static let initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    private static let constants: [UInt32] = [
        0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,
        0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,
        0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,
        0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,
        0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,
        0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,
        0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,
        0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2,
    ]
    private static let prefixState: [UInt32] = [
        0xFD9FBEA2,0x91243CE7,0xBE499094,0xCD2E1E0A,0x6C006F49,0x04BD35AB,0xFEB0A7E4,0x03EFFBD2,
    ]
    private static let prefixSchedule: [UInt32] = [
        0xEB24BF9E,0x1558691F,0xA0C09EE2,0x0CFA32BA,0xA622EE8C,0xD1DD9491,0xC0DD25A0,
        0xF9E70AB6,0xF0C31573,0x7058CE4E,0x7188E606,0x00E5AB33,0xD258B060,0x72766564,
    ]
    private static let checkParameters: [(UInt32, UInt32)] = [
        (0xE82E91B1,0xB32700D0),(0x44DE24C6,0x88DFF51D),(0x3BEB65BC,0x29514038),
        (0xC89C5933,0xB328CBDF),(0x8D1EC211,0xD405B4D5),(0x314EF5D5,0x26E55F3C),
        (0xE92491B1,0x607801C6),(0xF0A5B9D5,0x82B2C1FB),(0x06064CF3,0xFA51A3DA),
        (0xDA79FA60,0x207CC464),(0xBED20560,0x3C3C74F3),(0x89F9C9F8,0xD2D14B61),
        (0x35FA38C6,0xBB04A2C1),(0xCB49E3C6,0xC5626167),
    ]

    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
    private static func sigma0(_ x: UInt32) -> UInt32 { rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3) }
    private static func sigma1(_ x: UInt32) -> UInt32 { rotate(x, 17) ^ rotate(x, 19) ^ (x >> 10) }
    private static func expand(_ words: inout [UInt32]) {
        while words.count < 64 {
            let i = words.count
            words.append(sigma1(words[i - 2]) &+ words[i - 7] &+ sigma0(words[i - 15]) &+ words[i - 16])
        }
    }
    private static func compress(_ state: [UInt32], _ words: [UInt32], start: Int = 0) -> [UInt32] {
        var v = state
        for i in start..<64 {
            let k = start == 14 && i == 14 ? UInt32(0xC9DC06A7) : constants[i]
            let upper = rotate(v[4], 6) ^ rotate(v[4], 11) ^ rotate(v[4], 25)
            let choose = (v[4] & v[5]) ^ (~v[4] & v[6])
            let t1 = v[7] &+ upper &+ choose &+ k &+ words[i]
            let lower = rotate(v[0], 2) ^ rotate(v[0], 13) ^ rotate(v[0], 22)
            let majority = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
            v = [t1 &+ lower &+ majority, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
        }
        return v
    }
    private static func word(_ bytes: ArraySlice<UInt8>, littleEndian: Bool = false) -> UInt32 {
        let values = littleEndian ? Array(bytes.reversed()) : Array(bytes)
        return values.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func digest(_ payload: [UInt8]) -> [UInt8] {
        var words = Array(repeating: UInt32(0), count: 14)
        words.append(word(payload[0..<3]))
        words.append(word(payload[3..<7]))
        for i in 16..<30 {
            var next = prefixSchedule[i - 16]
            if i - 2 >= 14 { next &+= sigma1(words[i - 2]) ^ (i == 16 ? 0x000B92C0 : 0) }
            if i - 7 >= 14 { next &+= words[i - 7] }
            if i - 15 >= 14 { next &+= sigma0(words[i - 15]) ^ (i == 29 ? 0x059C0B80 : 0) }
            words.append(next)
        }
        words.append(sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14] &+ 0xC9DC06A7 &- constants[14])
        expand(&words)
        var state = zip(initial, compress(prefixState, words, start: 14)).map { $0 &+ $1 }
        var tail = Array(payload.dropFirst(7))
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bitCount = UInt64(57 + payload.count) * 8
        tail += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) }
        for offset in stride(from: 0, to: tail.count, by: 64) {
            var block = stride(from: offset, to: offset + 64, by: 4).map { word(tail[$0..<$0 + 4]) }
            expand(&block)
            state = zip(state, compress(state, block)).map { $0 &+ $1 }
        }
        return state.flatMap { value in (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }
    static func token(_ payload: Data) -> String {
        let bytes = [UInt8](payload)
        let sha = digest(bytes)
        let keys = [word(sha[0..<4], littleEndian: true) | 1, word(sha[4..<8], littleEndian: true) | 1]
        let factors = keys.map { $0 &* 0x82893933 }
        var terms = checkParameters.enumerated().map { $0.element.0 &* factors[$0.offset % 2] }
        var offsets = checkParameters.map { $0.1 }
        var padded = [UInt8(0)] + bytes
        while padded.count % 8 != 0 { padded.append(0) }
        for offset in stride(from: 0, to: padded.count, by: 4) {
            let i = offset / 4
            let value = word(padded[offset..<offset + 4], littleEndian: true)
            var term = value &* keys[i % 2]
            var addend = rotate(value, 16) &* (i % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if i == 0 { term &+= 0xF2F90B1A &* factors[0]; addend &+= 0x0B1A0000 }
            terms.append(term)
            offsets.append(addend)
        }
        var check: UInt32 = 0, last: UInt32 = 0, state: UInt32 = 0, sum: UInt32 = 0
        for i in stride(from: 0, to: terms.count, by: 2) {
            let q0 = rotate(offsets[i] &+ terms[i], 16) &* 0x76F50F34
            let q1 = rotate(offsets[i + 1] &+ terms[i + 1], 16) &* 0x1881CE3C
            last = rotate(q1, 16) &* 0x35BD1EC9 &+ q1
            check &+= rotate(q0, 16) &* 0xC3EFEA97 &+ q0 &+ last
            state = state &* keys[0] &+ terms[i]
            for multiplier: UInt32 in [0xCF98B111, 0x87085B9F, 0x12CEB96D, 0x257E1D83] {
                state = rotate(state, 16) &* multiplier
            }
            sum &+= state
            state = state &* keys[1] &+ terms[i + 1]
            for multiplier: UInt32 in [0xA27416F5, 0xD38396FF, 0x7C932B89, 0xBFA49F69] {
                state = rotate(state, 16) &* multiplier
            }
            sum &+= state
        }
        let checksum = [last ^ state, check ^ sum].flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        let hex: ([UInt8]) -> String = { $0.map { String(format: "%02X", $0) }.joined() }
        return hex(checksum) + "-" + hex(sha)
    }
}
