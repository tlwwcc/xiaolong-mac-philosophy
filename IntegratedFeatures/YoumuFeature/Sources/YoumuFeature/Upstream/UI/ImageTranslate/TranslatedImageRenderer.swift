import AppKit

/// 原图翻译渲染器：把译文盖回原图，输出全像素分辨率 CGImage。
/// 纯渲染逻辑，不碰 UI，可独立编译自测。
enum TranslatedImageRenderer {

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - 主渲染入口

    /// - Parameters:
    ///   - original: 原始截图（像素域）
    ///   - blocks: OCR 文字块（boundingBox 为 Vision 归一化坐标，左下原点）
    ///   - translations: 0 基块下标 → 译文
    ///   - failedIndices: 翻译失败的块下标（渲染原文，调用方负责界面标注）
    /// - Returns: 合成后的 CGImage（与 original 同像素尺寸）
    static func render(
        original: CGImage,
        blocks: [OCRTextBlock],
        translations: [Int: String],
        failedIndices: Set<Int> = []
    ) -> CGImage? {
        let width = original.width
        let height = original.height
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high

        // 1. 原图：CGContext 默认 y 向上，CGImage 按像素原样绘制即正立
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 2. 显式翻转为左上原点坐标系 —— 不依赖任何隐式上下文行为。
        //    之后所有覆盖/文本绘制都在 y-down 域进行：
        //    Vision 归一化坐标 → y-down 像素：y = (1 - origin.y - height) * H
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // NSStringDrawing 需要 NSGraphicsContext；显式声明 flipped=true，
        // 文本以「块顶向下」排版且字形正立
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)

        for (index, block) in blocks.enumerated() {
            guard let translated = translations[index],
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let pixelRect = CGRect(
                x: block.boundingBox.origin.x * CGFloat(width),
                y: (1 - block.boundingBox.origin.y - block.boundingBox.height) * CGFloat(height),
                width: block.boundingBox.width * CGFloat(width),
                height: block.boundingBox.height * CGFloat(height)
            ).integral
            let coverRect = pixelRect.insetBy(dx: -4, dy: -3).intersection(imageBounds)
            guard coverRect.width > 4, coverRect.height > 4 else { continue }

            // 块内稳健配色（背景阵营均值 + 文字阵营保底对比）
            let colors = blockColors(of: original, in: pixelRect, imageBounds: imageBounds)
            NSColor(red: colors.background.r, green: colors.background.g,
                    blue: colors.background.b, alpha: 1).setFill()
            ctx.fill(coverRect)

            let textColor: NSColor = colors.textIsDark ? .black : .white

            drawText(translated, in: coverRect, color: textColor)
        }

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - 文本绘制（y-down 域）

    private static func drawText(_ text: String, in rect: CGRect, color: NSColor) {
        let fontSize = chooseFontSize(for: text, in: rect)
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // 行距紧凑 1.15
        let lineHeight = fontSize * 1.15
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size

        // 水平垂直居中；flipped 上下文中 rect 顶部 = minY
        let textRect = NSRect(
            x: rect.minX,
            y: rect.minY + (rect.height - textSize.height) / 2,
            width: rect.width,
            height: textSize.height
        )
        attrStr.draw(in: textRect)
    }

    /// 自适应字号（多行优先）：
    /// 从 rect.height × 0.7 起步递减，块内最多 3 行换行能放下就用；
    /// 3 行也放不下才继续缩，下限 11px（可识别性底线）。
    /// internal 以便单元自测直接断言。
    static func chooseFontSize(for text: String, in rect: CGRect) -> CGFloat {
        var fontSize = min(rect.height * 0.7, 28)
        while fontSize > 11 {
            let measurement = measureWrapped(text, fontSize: fontSize, width: rect.width)
            if measurement.lines <= 3 && measurement.height <= rect.height * 1.02 {
                return fontSize
            }
            fontSize -= 0.5
        }
        return 11
    }

    /// 测量文本在给定字号/宽度下换行后的行数与总高
    private static func measureWrapped(
        _ text: String, fontSize: CGFloat, width: CGFloat
    ) -> (lines: Int, height: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = fontSize * 1.15
        let lines = max(1, Int(ceil(bound.height / lineHeight)))
        return (lines, bound.height)
    }

    // MARK: - 背景采样（格式安全 + 抗文字笔画污染）

    /// 块配色分析结果
    struct BlockColors {
        let background: (r: CGFloat, g: CGFloat, b: CGFloat)
        /// true = 文字用深色（黑），false = 文字用浅色（白）
        let textIsDark: Bool
    }

    /// 稳健的块配色分析：
    /// 在文字块**内部**粗采样（降采样到 ≤64×16 读出全部像素），
    /// 按亮度中位数把像素分成「背景阵营/文字阵营」——文字笔画永远是少数派，
    /// 中位数落在背景上，不受笔画污染（旧实现采样块上方 4px 条带，
    /// 在密集文本/代码场景会采到上一行笔画，均值被拉暗 → 深色块事故）。
    /// 保底：背景亮度与文字亮度差 < 0.4 时强制白底黑字。
    static func blockColors(of image: CGImage, in pixelRect: CGRect, imageBounds: CGRect) -> BlockColors {
        let fallback = BlockColors(background: (1, 1, 1), textIsDark: true)
        let clamped = pixelRect.insetBy(dx: 1, dy: 1).intersection(imageBounds)
        guard clamped.width >= 8, clamped.height >= 6,
              let samples = downsampledPixels(of: image, in: clamped, maxWidth: 64, maxHeight: 16)
        else { return fallback }

        // 每个像素与自身亮度绑定成对（中位数从排序副本取，不打乱配对）
        let pairs: [(r: CGFloat, g: CGFloat, b: CGFloat, lum: CGFloat)] = samples.map {
            ($0.r, $0.g, $0.b, luminance(r: $0.r, g: $0.g, b: $0.b))
        }
        let sortedLums = pairs.map(\.lum).sorted()
        let median = sortedLums[sortedLums.count / 2]
        let bgIsLight = median >= 0.5

        // 分阵营求均值
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgCount: CGFloat = 0
        var fgLumSum: CGFloat = 0, fgCount: CGFloat = 0
        for pair in pairs {
            if (pair.lum >= 0.5) == bgIsLight {
                bgR += pair.r; bgG += pair.g; bgB += pair.b
                bgCount += 1
            } else {
                fgLumSum += pair.lum
                fgCount += 1
            }
        }
        guard bgCount > 0 else { return fallback }
        let bg = (bgR / bgCount, bgG / bgCount, bgB / bgCount)
        let bgLum = luminance(r: bg.0, g: bg.1, b: bg.2)
        let fgLum = fgCount > 0 ? fgLumSum / fgCount : (bgIsLight ? 0 : 1)

        // 保底策略：对比不足（误判风险高）→ 强制白底黑字
        guard abs(bgLum - fgLum) >= 0.4 else { return fallback }
        return BlockColors(background: bg, textIsDark: bgIsLight)
    }

    /// 把 rect 区域降采样重绘到小尺寸 RGBA 上下文并读出全部像素（格式安全）
    private static func downsampledPixels(
        of image: CGImage, in rect: CGRect, maxWidth: Int, maxHeight: Int
    ) -> [(r: CGFloat, g: CGFloat, b: CGFloat)]? {
        guard let cropped = image.cropping(to: rect) else { return nil }
        let outWidth = max(1, min(maxWidth, cropped.width))
        let outHeight = max(1, min(maxHeight, cropped.height))
        var buffer = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let success = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base, width: outWidth, height: outHeight,
                      bitsPerComponent: 8, bytesPerRow: outWidth * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            return true
        }
        guard success else { return nil }
        var result: [(CGFloat, CGFloat, CGFloat)] = []
        result.reserveCapacity(outWidth * outHeight)
        for i in stride(from: 0, to: buffer.count, by: 4) {
            result.append((
                CGFloat(buffer[i]) / 255,
                CGFloat(buffer[i + 1]) / 255,
                CGFloat(buffer[i + 2]) / 255
            ))
        }
        return result
    }

    /// 区域平均色：把目标区域重绘进 1x1 RGBA 上下文，硬件插值即均值。
    /// 绕开 CGDataProvider 直接读字节的所有坑（bytesPerRow/alpha 位置/像素格式）。
    /// rect 为 CGImage 像素坐标（左上原点），cropping 语义一致。
    static func averageColor(
        of image: CGImage,
        in rect: CGRect
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cropped = image.cropping(to: rect) else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let success = pixel.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base, width: 1, height: 1,
                      bitsPerComponent: 8, bytesPerRow: 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard success else { return nil }
        return (
            CGFloat(pixel[0]) / 255,
            CGFloat(pixel[1]) / 255,
            CGFloat(pixel[2]) / 255
        )
    }

    /// 相对亮度（sRGB luma）
    static func luminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        0.299 * r + 0.587 * g + 0.114 * b
    }
}
