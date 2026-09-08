import Vision
import AppKit

/// 基于 Apple Vision 框架的 OCR 服务，支持中英文混合识别
final class OCRService: Sendable {
    static let shared = OCRService()

    /// 识别语言：简中、繁中、英文、日语、韩语
    private let recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
    private let minimumConfidence: VNConfidence = 0.2

    func recognizeText(from image: CGImage) async throws -> [OCRTextBlock] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let blocks = observations.compactMap { observation -> OCRTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, candidate.confidence >= self.minimumConfidence else {
                        return nil
                    }
                    return OCRTextBlock(
                        text: text,
                        boundingBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }

                continuation.resume(returning: blocks)
            }

            // 配置：精确模式 + 多语言
            request.recognitionLevel = .accurate
            request.recognitionLanguages = recognitionLanguages
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 把 OCR 结果按自然阅读顺序拼接成文本：
    /// 1. 按 boundingBox 的 Y 中心从上到下分行（Vision 坐标原点在左下，midY 大者在上）
    /// 2. 垂直中心距离小于行高阈值的块视为同一行
    /// 3. 行内按 X 从左到右排序拼接（CJK 相邻不加空格，否则加空格）
    func assembleText(from blocks: [OCRTextBlock]) -> String {
        if let columns = Self.twoColumnLayout(from: blocks) {
            return [columns.leading, columns.left, columns.right, columns.trailing]
                .map(Self.assembleRows)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return Self.assembleRows(blocks)
    }

    private static func assembleRows(_ blocks: [OCRTextBlock]) -> String {
        let sorted = blocks.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var lines: [[OCRTextBlock]] = []
        for block in sorted {
            if let lastLine = lines.last,
               let lineAnchor = lastLine.first {
                let threshold = max(lineAnchor.boundingBox.height, block.boundingBox.height) * 0.6
                if abs(lineAnchor.boundingBox.midY - block.boundingBox.midY) < threshold {
                    lines[lines.count - 1].append(block)
                    continue
                }
            }
            lines.append([block])
        }

        return lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .reduce(into: "") { partial, next in
                    guard let lastChar = partial.last, let firstChar = next.first else {
                        partial += next
                        return
                    }
                    // CJK 字符之间不需要空格，中日韩排版习惯
                    if Self.isCJK(lastChar) && Self.isCJK(firstChar) {
                        partial += next
                    } else {
                        partial += " " + next
                    }
                }
        }.joined(separator: "\n")
    }

    private struct TwoColumnLayout {
        let leading: [OCRTextBlock]
        let left: [OCRTextBlock]
        let right: [OCRTextBlock]
        let trailing: [OCRTextBlock]
    }

    /// Vision normally returns one observation per line. A real column gutter therefore has no
    /// line crossing it, while ordinary prose lines cross the page centre. Full-width headings and
    /// footers are kept before/after the two columns instead of defeating column detection.
    private static func twoColumnLayout(from blocks: [OCRTextBlock]) -> TwoColumnLayout? {
        let candidates = blocks.filter { $0.boundingBox.width < 0.72 }
          .sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        guard candidates.count >= 4 else { return nil }

        var best: (score: CGFloat, divider: CGFloat, left: [OCRTextBlock], right: [OCRTextBlock])?
        for split in 2...(candidates.count - 2) {
            let left = Array(candidates[..<split])
            let right = Array(candidates[split...])
            let leftEdge = left.map { $0.boundingBox.maxX }.max() ?? 0
            let rightEdge = right.map { $0.boundingBox.minX }.min() ?? 1
            let gutter = rightEdge - leftEdge
            guard gutter >= 0.055 else { continue }

            let leftBottom = left.map { $0.boundingBox.minY }.min() ?? 0
            let leftTop = left.map { $0.boundingBox.maxY }.max() ?? 0
            let rightBottom = right.map { $0.boundingBox.minY }.min() ?? 0
            let rightTop = right.map { $0.boundingBox.maxY }.max() ?? 0
            let verticalOverlap = min(leftTop, rightTop) - max(leftBottom, rightBottom)
            guard verticalOverlap >= 0.12 else { continue }

            let score = gutter + min(verticalOverlap, 0.5) * 0.2
            if best.map({ score > $0.score }) ?? true {
                best = (score, (leftEdge + rightEdge) / 2, left, right)
            }
        }

        guard let best else { return nil }
        let columnTop = max(
            best.left.map { $0.boundingBox.maxY }.max() ?? 0,
            best.right.map { $0.boundingBox.maxY }.max() ?? 0)
        let columnBottom = min(
            best.left.map { $0.boundingBox.minY }.min() ?? 1,
            best.right.map { $0.boundingBox.minY }.min() ?? 1)

        let columnIDs = Set((best.left + best.right).map(ObjectIdentifierBox.init))
        let spanning = blocks.filter { !columnIDs.contains(ObjectIdentifierBox($0)) }
        var leading: [OCRTextBlock] = []
        var trailing: [OCRTextBlock] = []
        for block in spanning {
            if block.boundingBox.midY >= columnTop - 0.02 {
                leading.append(block)
            } else if block.boundingBox.midY <= columnBottom + 0.02 {
                trailing.append(block)
            } else {
                return nil
            }
        }
        return TwoColumnLayout(
            leading: leading,
            left: best.left,
            right: best.right,
            trailing: trailing)
    }

    private struct ObjectIdentifierBox: Hashable {
        let text: String
        let box: CGRect
        let confidence: Float

        init(_ block: OCRTextBlock) {
            text = block.text
            box = block.boundingBox
            confidence = block.confidence
        }
    }

    private static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK 统一表意文字
            (0x3400...0x4DBF).contains(scalar.value) ||   // 扩展 A
            (0x3040...0x30FF).contains(scalar.value) ||   // 平假名+片假名
            (0xAC00...0xD7AF).contains(scalar.value) ||   // 韩文音节
            (0x3000...0x303F).contains(scalar.value) ||   // CJK 标点
            (0xFF00...0xFF65).contains(scalar.value)      // 全角字符+半角片假名/韩文
        }
    }
}
