import Foundation

/// 带编号标记的结构化翻译协议：
/// 把 OCR 块按顺序编号 ⟦1⟧⟦2⟧… 发给 LLM，要求译文保留编号，
/// 响应按编号解析回每个块 —— 绝不依赖行号/行数对齐。
///
/// 本文件只有纯函数，不碰网络，可独立编译自测。
enum NumberedBlockTranslation {

    /// 单个块的翻译结果（index 为 OCR 块数组的 0 基下标）
    struct BlockTranslation {
        let index: Int
        let text: String
        /// true = 编号解析与单独重试均失败，显示原文（界面应标注）
        let failed: Bool
    }

    // MARK: - 构造请求

    /// user 消息：每块一行，⟦n⟧ 前缀（n 从 1 开始）
    static func buildUserMessage(blockTexts: [String]) -> String {
        blockTexts.enumerated()
            .map { "⟦\($0.offset + 1)⟧\($0.element)" }
            .joined(separator: "\n")
    }

    /// 追加在用户 system prompt 之后的编号协议说明
    static func numberedProtocolSuffix(targetLanguage: String) -> String {
        """

        本次用户消息由若干带编号标记 ⟦n⟧ 的文本块组成。请逐块翻译为\(targetLanguage)，并严格遵守：
        1. 每块译文必须以相同的 ⟦n⟧ 标记开头
        2. 编号不得遗漏、不得新增、不得改变与原文的对应关系
        3. 不要合并或拆分块，即使相邻块语义相关
        4. 不要输出任何额外解释
        """
    }

    // MARK: - 解析响应

    /// 把 LLM 响应解析成「编号 → 译文」字典。
    /// 规则：⟦n⟧ 标记切分；标记前的序言忽略；重复编号保留第一个；
    /// 乱序不受影响（按键索引）。返回 key 为 1 基编号。
    static func parseNumberedResponse(_ response: String) -> [Int: String] {
        // 容忍标记内空白：⟦ 3 ⟧
        let pattern = "⟦\\s*(\\d+)\\s*⟧"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }

        let nsResponse = response as NSString
        let matches = regex.matches(in: response, range: NSRange(location: 0, length: nsResponse.length))
        guard !matches.isEmpty else { return [:] }

        var result: [Int: String] = [:]
        for (i, match) in matches.enumerated() {
            guard let number = Int(nsResponse.substring(with: match.range(at: 1))) else { continue }
            let contentStart = match.range.location + match.range.length
            let contentEnd = (i + 1 < matches.count)
                ? matches[i + 1].range.location
                : nsResponse.length
            guard contentEnd > contentStart else { continue }
            let content = nsResponse
                .substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 重复编号保留第一个（后出现的视为模型幻觉，忽略）
            if result[number] == nil, !content.isEmpty {
                result[number] = content
            }
        }
        return result
    }

    /// 对照期望块数，找出缺失编号的 0 基下标（需要单独重试的块）
    static func missingIndices(parsed: [Int: String], expectedCount: Int) -> [Int] {
        (0..<expectedCount).filter { parsed[$0 + 1] == nil }
    }
}
