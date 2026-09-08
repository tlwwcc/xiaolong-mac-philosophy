import Foundation

/// OCR 面板文本处理（纯函数，可独立自测）
enum PanelTextNormalizer {
    /// 取「当前编辑框里的最新文本」作为翻译输入：
    /// 用户可能改过内容，必须读实时值；trim 后为空则不可翻译（返回 nil）
    static func textForTranslation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 复制到剪贴板前的文本规范化（同样 trim，允许用户保留中间空行）
    static func textForCopy(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
