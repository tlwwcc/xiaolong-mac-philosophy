import AppKit
import Foundation

enum OnlineDataPurpose: String, CaseIterable, Codable, Sendable {
    case translation
    case edgeSpeech

    var defaultsKey: String {
        YoumuFeatureEnvironmentStore.shared.userDefaultsKey(
            "online-data-consent." + rawValue
        )
    }
}

enum OnlineConsentDecision: String, Codable, Sendable {
    case allowed
    case denied
}

/// 许可只绑定网络 origin，不持久化完整 endpoint 的路径、查询参数或凭据。
nonisolated struct OnlineDataOrigin: Codable, Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    /// HTTPS 和安全 WebSocket 都归一为 HTTPS origin。WSS 是 Edge 在线朗读的传输形式。
    static func normalizedHTTPS(from endpoint: URL) -> OnlineDataOrigin? {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        let rawScheme = components.scheme?.lowercased(),
        rawScheme == "https" || rawScheme == "wss",
        components.user == nil,
        components.password == nil,
        var host = components.host?.lowercased(),
        !host.isEmpty
        else { return nil }

        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        let effectivePort = components.port ?? 443
        guard (1...65_535).contains(effectivePort) else { return nil }
        return OnlineDataOrigin(scheme: "https", host: host, port: effectivePort)
    }

    static func normalizedHTTPS(from rawEndpoint: String) -> OnlineDataOrigin? {
        guard let endpoint = URL(string: rawEndpoint) else { return nil }
        return normalizedHTTPS(from: endpoint)
    }

    var displayValue: String {
        let authorityHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(authorityHost):\(port)"
    }
}

struct StoredOnlineConsent: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let purpose: OnlineDataPurpose
    let origin: OnlineDataOrigin
    let decision: OnlineConsentDecision
}

struct OnlineConsentPolicy {
    static func allowsNetwork(
        storedValue: String?,
        purpose: OnlineDataPurpose,
        origin: OnlineDataOrigin
    ) -> Bool? {
        guard let storedValue,
              let data = storedValue.data(using: .utf8),
              let record = try? JSONDecoder().decode(StoredOnlineConsent.self, from: data),
              record.version == StoredOnlineConsent.currentVersion,
              record.purpose == purpose,
              record.origin == origin else {
            // 旧版只保存 "allowed" / "denied"，没有 origin，不得自动继承。
            return nil
        }

        switch record.decision {
        case .allowed: return true
        case .denied: return false
        }
    }

    static func storedValue(
        decision: OnlineConsentDecision,
        purpose: OnlineDataPurpose,
        origin: OnlineDataOrigin
    ) -> String? {
        let record = StoredOnlineConsent(
            version: StoredOnlineConsent.currentVersion,
            purpose: purpose,
            origin: origin,
            decision: decision
        )
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class OnlineDataConsentManager {
    static let shared = OnlineDataConsentManager()
    private init() {}

    func request(_ purpose: OnlineDataPurpose, endpoint: URL) -> Bool {
        guard let origin = OnlineDataOrigin.normalizedHTTPS(from: endpoint) else {
            return false
        }

        let defaults = YoumuFeatureEnvironmentStore.shared.userDefaults()
        if let allowed = OnlineConsentPolicy.allowsNetwork(
            storedValue: defaults.string(forKey: purpose.defaultsKey),
            purpose: purpose,
            origin: origin
        ) {
            return allowed
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = purpose == .translation ? "是否允许在线翻译？" : "是否允许 Edge 在线朗读？"
        switch purpose {
        case .translation:
            alert.informativeText = "仅在本机翻译不可用或你主动选择在线 API 时，所选文字会发送到 \(origin.displayValue)。API Key 只从 macOS 钥匙串读取并用于该请求。拒绝后不会发送。"
            alert.addButton(withTitle: "允许在线翻译")
            alert.addButton(withTitle: "拒绝")
        case .edgeSpeech:
            alert.informativeText = "所选文字会发送到 \(origin.displayValue) 的 Microsoft Edge 在线语音服务以生成声音。该接口依赖网络，可能随服务变化；你可以拒绝并改用 Mac 本机声音，文字不会上传。"
            alert.addButton(withTitle: "允许 Edge 在线朗读")
            alert.addButton(withTitle: "改用 Mac 本机")
        }
        let allowed = alert.runModal() == .alertFirstButtonReturn
        let decision: OnlineConsentDecision = allowed ? .allowed : .denied
        if let storedValue = OnlineConsentPolicy.storedValue(
            decision: decision,
            purpose: purpose,
            origin: origin
        ) {
            defaults.set(storedValue, forKey: purpose.defaultsKey)
        }
        return allowed
    }

    func reset(_ purpose: OnlineDataPurpose) {
        YoumuFeatureEnvironmentStore.shared.userDefaults().removeObject(
            forKey: purpose.defaultsKey
        )
    }
}
