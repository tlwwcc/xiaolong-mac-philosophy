import Foundation

/// 仅翻译代码中固定的夹具文字；不截图、不加载个人设置、不触发下载或在线请求。
/// 宿主可在已安装的唯一稳定 App 中调用，将机器证据与真实模型绑定。
public enum YoumuTranslationDiagnostics {
    @MainActor
    public static func runInstalledModelSmoke() async -> [String: String] {
        guard #available(macOS 15.0, *) else { return ["status": "SKIP", "reason": "macOS 15 required"] }
        guard await AppleLocalModelAvailability.status() == .installed else {
            return ["status": "SKIP", "reason": "English/Chinese models are not installed"]
        }
        let fixtures = [
            "Save this document.", "Open the settings window.",
            "Copy the selected text.", "Close the current window.",
        ]
        var report: [String: String] = [:]
        do {
            for (index, text) in fixtures.enumerated() {
                let result = try await AppleLocalTranslator.shared.translate(texts: [text], targetLanguage: .zhHans)
                guard let result, result.count == 1, !result[0].isEmpty, result[0] != text else {
                    report["status"] = "FAIL"
                    report["reason"] = "Fixture \(index + 1) returned no translation"
                    return report
                }
                report["fixture\(index + 1)"] = result[0]
            }
            report["status"] = "PASS"
            report["count"] = "\(fixtures.count)"
        } catch {
            report["status"] = "FAIL"
            report["reason"] = error.localizedDescription
        }
        return report
    }
}
