import AppKit
import Foundation

enum OnlineDataPurpose: String, CaseIterable, Codable, Sendable {
    case translation
    case sharedTranslation
    case edgeSpeech

    var isTranslation: Bool { self != .edgeSpeech }

    var sharedTranslationNotice: String {
        "所选文字将通过小龙哥 Mac 哲学服务发送到智谱进行翻译，截图留在本机。无需登录或提供密钥，模型费用由我们承担。匿名编号仅用于限制使用量，我们的服务不保存原文或译文。拒绝后不会发送，可以选择 Apple 本机翻译。"
    }

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
    typealias Presenter = @MainActor (
        OnlineDataPurpose, OnlineDataOrigin,
        @escaping (OnlineConsentDecision?) -> Void
    ) -> () -> Void

    private struct PendingRequest {
        let purpose: OnlineDataPurpose
        let origin: OnlineDataOrigin
        let continuation: CheckedContinuation<Bool, Error>
        let systemPresentation: (@MainActor (Bool) -> Void)?
        var dismiss: (() -> Void)?
    }

    private let defaultsOverride: UserDefaults?
    private let presenter: Presenter
    private var pending: [UUID: PendingRequest] = [:]

    init(defaults: UserDefaults? = nil, presenter: @escaping Presenter = OnlineConsentPrompt.present) {
        defaultsOverride = defaults
        self.presenter = presenter
    }

    private var defaults: UserDefaults {
        defaultsOverride ?? YoumuFeatureEnvironmentStore.shared.userDefaults()
    }

    /// 翻译等待期间不得进入 runModal 的嵌套事件循环；每个任务只持有自己的确认窗口。
    func requestCancellable(
        _ purpose: OnlineDataPurpose,
        endpoint: URL,
        systemPresentation: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let origin = OnlineDataOrigin.normalizedHTTPS(from: endpoint) else { return false }
        if let allowed = OnlineConsentPolicy.allowsNetwork(
            storedValue: defaults.string(forKey: purpose.defaultsKey),
            purpose: purpose, origin: origin
        ) {
            return allowed
        }

        let id = UUID()
        let allowed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = PendingRequest(
                    purpose: purpose, origin: origin, continuation: continuation,
                    systemPresentation: systemPresentation
                )
                systemPresentation?(true)
                let dismiss = presenter(purpose, origin) { [weak self] decision in
                    self?.finish(id: id, decision: decision)
                }
                if pending[id] != nil {
                    pending[id]?.dismiss = dismiss
                } else {
                    // 可注入的 presenter 也允许同步结束，仍须释放对应窗口。
                    dismiss()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, decision: nil)
            }
        }
        try Task.checkCancellation()
        return allowed
    }

    private func finish(id: UUID, decision: OnlineConsentDecision?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.dismiss?()
        request.systemPresentation?(false)
        guard let decision else {
            request.continuation.resume(throwing: CancellationError())
            return
        }
        if let storedValue = OnlineConsentPolicy.storedValue(
            decision: decision, purpose: request.purpose, origin: request.origin
        ) {
            defaults.set(storedValue, forKey: request.purpose.defaultsKey)
        }
        request.continuation.resume(returning: decision == .allowed)
    }

    // 保留朗读和设置入口的同步调用；截图翻译使用上面的可取消入口。
    func request(_ purpose: OnlineDataPurpose, endpoint: URL) -> Bool {
        guard let origin = OnlineDataOrigin.normalizedHTTPS(from: endpoint) else {
            return false
        }

        if let allowed = OnlineConsentPolicy.allowsNetwork(
            storedValue: defaults.string(forKey: purpose.defaultsKey),
            purpose: purpose,
            origin: origin
        ) {
            return allowed
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = purpose.isTranslation ? "是否允许在线翻译？" : "是否允许 Edge 在线朗读？"
        switch purpose {
        case .sharedTranslation:
            alert.informativeText = purpose.sharedTranslationNotice
            alert.addButton(withTitle: "允许在线翻译")
            alert.addButton(withTitle: "拒绝")
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
        defaults.removeObject(
            forKey: purpose.defaultsKey
        )
    }
}


/// 独立、非模态许可窗口。Esc/关闭只取消本次翻译，不等同于永久拒绝。
@MainActor
private final class OnlineConsentPrompt: NSObject, NSWindowDelegate {
    private let alert = NSAlert()
    private let completion: (OnlineConsentDecision?) -> Void
    private weak var previousWindow: NSWindow?
    private let previousApp: NSRunningApplication?
    private var finished = false

    static func present(
        purpose: OnlineDataPurpose,
        origin: OnlineDataOrigin,
        completion: @escaping (OnlineConsentDecision?) -> Void
    ) -> () -> Void {
        let prompt = OnlineConsentPrompt(purpose: purpose, origin: origin, completion: completion)
        prompt.show()
        return { prompt.dismiss() }
    }

    private init(
        purpose: OnlineDataPurpose,
        origin: OnlineDataOrigin,
        completion: @escaping (OnlineConsentDecision?) -> Void
    ) {
        self.completion = completion
        previousWindow = NSApp.keyWindow
        previousApp = NSWorkspace.shared.frontmostApplication
        super.init()
        alert.alertStyle = .informational
        alert.messageText = purpose.isTranslation ? "是否允许在线翻译？" : "是否允许 Edge 在线朗读？"
        alert.informativeText = purpose.isTranslation
            ? "所选文字会发送到 \(origin.displayValue) 进行翻译。API Key 只从 macOS 钥匙串读取并用于该请求。拒绝后不会发送。"
            : "所选文字会发送到 \(origin.displayValue) 的 Microsoft Edge 在线语音服务。拒绝后可改用 Mac 本机声音。"
        if purpose == .sharedTranslation { alert.informativeText = purpose.sharedTranslationNotice }
        let allow = alert.addButton(withTitle: purpose.isTranslation ? "允许在线翻译" : "允许 Edge 在线朗读")
        let deny = alert.addButton(withTitle: "拒绝")
        let cancel = alert.addButton(withTitle: "取消")
        for (index, button) in [allow, deny, cancel].enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
        }
        allow.keyEquivalent = "\r"
        deny.keyEquivalent = ""
        cancel.keyEquivalent = "\u{1b}"
        alert.layout()
        alert.window.styleMask.insert(.closable)
        alert.window.isReleasedWhenClosed = false
        alert.window.delegate = self
        alert.window.level = .modalPanel
        alert.window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        alert.window.sharingType = .none
    }

    private func show() {
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func choose(_ sender: NSButton) {
        guard !finished else { return }
        completion(sender.tag == 0 ? .allowed : sender.tag == 1 ? .denied : nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finished { completion(nil) }
        return false
    }

    private func dismiss() {
        guard !finished else { return }
        finished = true
        let wasKey = alert.window.isKeyWindow
        alert.window.orderOut(nil)
        alert.window.delegate = nil
        // Keep the alert/window alive until the AppKit action or close callback unwinds.
        DispatchQueue.main.async { [self] in
            withExtendedLifetime(self) {}
        }
        // 取消旧 owner 时不抢走另一确认窗口的焦点。
        guard wasKey else { return }
        if let previousWindow, previousWindow.isVisible {
            previousWindow.makeKeyAndOrderFront(nil)
        } else if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
}
