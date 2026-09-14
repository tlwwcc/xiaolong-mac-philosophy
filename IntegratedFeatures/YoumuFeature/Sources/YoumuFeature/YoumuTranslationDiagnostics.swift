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
            let imageTexts = ["Save", "使用", "Copy", "100%", "Open", "AI", "CPU 66%", "⚙️"]
            guard let batch = try await AppleLocalTranslator.shared.translateBlocks(
                texts: imageTexts, targetLanguage: .zhHans
            ), batch.firstError == nil, batch.blocks.count == imageTexts.count,
               !batch.blocks.contains(where: \.failed) else {
                report["status"] = "FAIL"
                report["reason"] = "Mixed OCR fixture returned a failed or incomplete translation"
                return report
            }
            for (index, expected) in [(0, "保存"), (2, "复制"), (4, "打开")] {
                guard batch.blocks[index].text == expected else {
                    report["status"] = "FAIL"
                    report["reason"] = "English menu fixture \(index) did not preserve its interface meaning"
                    return report
                }
                report["imageBlock\(index)"] = batch.blocks[index].text
            }
            for index in [1, 3, 7] {
                guard batch.blocks[index].text == imageTexts[index] else {
                    report["status"] = "FAIL"
                    report["reason"] = "Existing Chinese, numbers or emoji were modified"
                    return report
                }
            }
            guard let reverse = try await AppleLocalTranslator.shared.translate(
                texts: ["请保存这份文档。"], targetLanguage: .en
            )?.first, !reverse.isEmpty, LanguageClassifier.cjkLatinCounts(reverse).latin > 0 else {
                report["status"] = "FAIL"
                report["reason"] = "Chinese to English fixture failed after mixed OCR translation"
                return report
            }
            report["reverse"] = reverse
            report["status"] = "PASS"
            report["count"] = "\(fixtures.count + imageTexts.count + 1)"
            report["imageBlockCount"] = "\(imageTexts.count)"
        } catch {
            report["status"] = "FAIL"
            report["reason"] = error.localizedDescription
        }
        return report
    }
}
