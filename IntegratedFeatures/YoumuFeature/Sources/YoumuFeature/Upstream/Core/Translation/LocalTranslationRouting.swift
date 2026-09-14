import Foundation
import NaturalLanguage

/// OCR 短词不能直接使用 NSLinguisticTagger 的无置信度结果（Save→hr、Copy→pl）。
/// 有明确语言证据时尊重识别；模糊短词结合图片内同文字系统的上下文，
/// 常见英文菜单/缩写使用英文本义，不把 nil 交给系统再次猜测。
nonisolated enum LocalTranslationRouting {
    struct Pair: Hashable, Sendable {
        let sourceIdentifier: String?
        let targetIdentifier: String?
    }

    struct Group: Sendable {
        let pair: Pair
        var indices: [Int]
    }

    private static let englishInterfaceWords: Set<String> = [
        "ok", "hi", "yes", "no", "on", "off", "save", "copy", "paste", "cut", "open",
        "close", "cancel", "done", "edit", "file", "view", "help", "new", "undo", "redo",
        "delete", "remove", "add", "search", "find", "replace", "settings", "preferences",
        "download", "upload", "install", "update", "next", "back", "apply", "reset",
        "start", "stop", "pause", "play", "share", "print", "select", "all", "none"
    ]

    // 单独的界面词缺少句子上下文，原生模型会把 Open 译作“户外”、Save 译作“挽救”。
    // 只校正完整菜单标签；完整句子和其他源语言继续保留模型结果。
    private static let chineseInterfaceTerms: [String: String] = [
        "ok": "确定", "yes": "是", "no": "否", "on": "开启", "off": "关闭",
        "save": "保存", "copy": "复制", "paste": "粘贴", "cut": "剪切", "open": "打开",
        "close": "关闭", "cancel": "取消", "done": "完成", "edit": "编辑", "file": "文件",
        "view": "查看", "help": "帮助", "new": "新建", "undo": "撤销", "redo": "重做",
        "delete": "删除", "remove": "移除", "add": "添加", "search": "搜索", "find": "查找",
        "replace": "替换", "settings": "设置", "preferences": "偏好设置", "download": "下载",
        "upload": "上传", "install": "安装", "update": "更新", "next": "下一步", "back": "返回",
        "apply": "应用", "reset": "重置", "start": "开始", "stop": "停止", "pause": "暂停",
        "play": "播放", "share": "分享", "print": "打印", "select": "选择", "all": "全部", "none": "无"
    ]

    static func chineseInterfaceTranslation(_ text: String, pair: Pair) -> String? {
        guard pair.sourceIdentifier == "en", let target = pair.targetIdentifier,
              target == "zh-Hans" || target == "zh-Hant",
              let range = text.range(of: #"(?<![A-Za-z])[A-Za-z]+"#, options: .regularExpression) else { return nil }
        let prefix = String(text[..<range.lowerBound])
        let suffix = String(text[range.upperBound...])
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["", "…", "...", ":"].contains(suffix.trimmingCharacters(in: .whitespacesAndNewlines)),
              var translated = chineseInterfaceTerms[String(text[range]).lowercased()] else { return nil }
        if target == "zh-Hant" {
            guard let variant = translated.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) else { return nil }
            translated = variant
        }
        return prefix + translated + suffix
    }

    private struct Evidence {
        let letters: Int
        let latin: Bool
        let han: Bool
        let kana: Bool
        let hangul: Bool
        let hypotheses: [(String, Double)]

        init(_ text: String) {
            let scalars = text.unicodeScalars.filter(LanguageClassifier.isLetter)
            letters = scalars.count
            latin = !scalars.isEmpty && scalars.allSatisfy {
                (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
                    || (0xC0...0x24F).contains($0.value)
            }
            han = scalars.contains { (0x3400...0x9FFF).contains($0.value) }
            kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
            hangul = scalars.contains {
                (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value)
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            hypotheses = recognizer.languageHypotheses(withMaximum: 8)
                .map { ($0.key.rawValue, $0.value) }
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        }

        var confidentLanguage: String? {
            guard let first = hypotheses.first, first.1 >= 0.55,
                  first.1 - (hypotheses.dropFirst().first?.1 ?? 0) >= 0.20 else { return nil }
            return first.0
        }
    }

    static func pair(
        for texts: [String], targetLanguage: Language,
        preferredTargetIdentifier: String = Locale.preferredLanguages.first ?? "en"
    ) -> Pair? {
        let text = texts.joined(separator: "\n")
        guard LanguageClassifier.hasLetters(text) else { return nil }
        let source = sourceIdentifier(for: text, latinContext: nil)
        return Pair(sourceIdentifier: source, targetIdentifier: targetIdentifier(
            targetLanguage, source: source, preferred: preferredTargetIdentifier))
    }

    @concurrent
    static func groupsForTranslation(texts: [String], targetLanguage: Language) async -> [Group] {
        groups(for: texts, targetLanguage: targetLanguage)
    }

    static func groups(
        for texts: [String], targetLanguage: Language,
        preferredTargetIdentifier: String = Locale.preferredLanguages.first ?? "en"
    ) -> [Group] {
        // 只用拉丁文字块提供短词上下文；不能让图片内中文界面把英文块改判成中文。
        let latinTexts = texts.filter { Evidence($0).latin }
        let latinContext = Evidence(latinTexts.joined(separator: "\n")).confidentLanguage
        var groups: [Group] = []
        for (index, text) in texts.enumerated() {
            guard LanguageClassifier.shouldTranslate(text, targetLanguage: targetLanguage) else { continue }
            let source = sourceIdentifier(for: text, latinContext: latinContext)
            let target = targetIdentifier(targetLanguage, source: source, preferred: preferredTargetIdentifier)
            // 同语种会被 Apple availability 判为 unsupported；它实际意味着无需翻译。
            guard source != target else { continue }
            let pair = Pair(sourceIdentifier: source, targetIdentifier: target)
            if let groupIndex = groups.firstIndex(where: { $0.pair == pair }) {
                groups[groupIndex].indices.append(index)
            } else {
                groups.append(Group(pair: pair, indices: [index]))
            }
        }
        return groups
    }

    private static func sourceIdentifier(for text: String, latinContext: String?) -> String? {
        let evidence = Evidence(text)
        guard evidence.letters > 0 else { return nil }
        if evidence.kana { return "ja" }
        if evidence.hangul { return "ko" }
        if evidence.latin {
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let asciiLetters = text.unicodeScalars.filter(LanguageClassifier.isLetter)
            let isASCII = asciiLetters.allSatisfy { $0.value < 128 }
            let isAcronym = isASCII && evidence.letters <= 8
                && asciiLetters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
            if englishInterfaceWords.contains(word) || isAcronym { return "en" }
            if let language = evidence.confidentLanguage { return canonicalIdentifier(language) }
            if evidence.letters < 20, let latinContext { return canonicalIdentifier(latinContext) }
            if evidence.letters >= 20, let language = evidence.hypotheses.first?.0 {
                return canonicalIdentifier(language)
            }
            // 没有足够证据的短拉丁词使用英文界面的常用方向，不请求系统猜缩写。
            if isASCII { return "en" }
        }
        if evidence.han {
            if LanguageClassifier.confidentMatch(text, targetLanguage: .zhHans) { return "zh-Hans" }
            if LanguageClassifier.confidentMatch(text, targetLanguage: .zhHant) { return "zh-Hant" }
            let chineseConfidence = evidence.hypotheses.filter { $0.0.hasPrefix("zh") }
                .reduce(0) { $0 + $1.1 }
            if chineseConfidence >= 0.65 {
                // 使用/保存等共用字形没有繁简差异，不能因候选排序被迫下载另一种语言。
                return "zh-Hans"
            }
        }
        guard let language = evidence.hypotheses.first?.0, language != "und" else { return nil }
        return canonicalIdentifier(language)
    }

    static func canonicalIdentifier(_ identifier: String) -> String {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized == "zh" || normalized.hasPrefix("zh-") {
            return normalized.contains("Hant") || normalized.hasSuffix("TW")
                || normalized.hasSuffix("HK") || normalized.hasSuffix("MO") ? "zh-Hant" : "zh-Hans"
        }
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }

    private static func targetIdentifier(_ target: Language, source: String?, preferred: String) -> String {
        switch target {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .auto:
            let preferred = canonicalIdentifier(preferred)
            // 自动方向仍使用用户系统语言；源文已是该语言时转为英语（英语则转中文）。
            return preferred == source ? (source == "en" ? "zh-Hans" : "en") : preferred
        }
    }

    static func convertChineseVariant(_ text: String, pair: Pair) -> String? {
        guard let source = pair.sourceIdentifier, let target = pair.targetIdentifier,
              source.hasPrefix("zh-"), target.hasPrefix("zh-"), source != target else { return nil }
        let transform = target == "zh-Hans" ? "Traditional-Simplified" : "Simplified-Traditional"
        return text.applyingTransform(StringTransform(transform), reverse: false)
    }

    static func orderedTexts(
        responsePairs: [(clientIdentifier: String?, text: String)], expectedCount: Int
    ) -> [String]? {
        var mapped: [Int: String] = [:]
        for response in responsePairs {
            guard let raw = response.clientIdentifier, let index = Int(raw),
                  (0..<expectedCount).contains(index), mapped[index] == nil,
                  !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            mapped[index] = response.text
        }
        guard mapped.count == expectedCount else { return nil }
        return (0..<expectedCount).compactMap { mapped[$0] }
    }
}

struct LocalTranslationBatchOutcome {
    let blocks: [NumberedBlockTranslation.BlockTranslation]
    let firstError: Error?
    let successfulGroups: Int
}

/// 按源语种串行调用同一个原生会话，保留OCR索引。单语种失败不能擦掉其他语种结果。
enum LocalTranslationBatchExecutor {
    static func run(
        texts: [String], groups: [LocalTranslationRouting.Group],
        translate: (LocalTranslationRouting.Pair, [String]) async throws -> [String]
    ) async throws -> LocalTranslationBatchOutcome {
        var blocks = texts.enumerated().map {
            NumberedBlockTranslation.BlockTranslation(index: $0.offset, text: $0.element, failed: false)
        }
        var firstError: Error?
        var successes = 0
        for group in groups {
            try Task.checkCancellation()
            do {
                let translated = try await translate(group.pair, group.indices.map { texts[$0] })
                try Task.checkCancellation()
                guard translated.count == group.indices.count,
                      translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw AppleLocalTranslationError.incompleteResponse
                }
                for (offset, index) in group.indices.enumerated() {
                    blocks[index] = .init(index: index, text: translated[offset], failed: false)
                }
                successes += 1
            } catch {
                if AppleTranslationCancellation.matches(error) { throw CancellationError() }
                try Task.checkCancellation()
                firstError = firstError ?? error
                for index in group.indices { blocks[index] = .init(index: index, text: texts[index], failed: true) }
            }
        }
        return LocalTranslationBatchOutcome(blocks: blocks, firstError: firstError, successfulGroups: successes)
    }
}
