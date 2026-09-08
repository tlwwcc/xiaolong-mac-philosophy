import AppKit

/// 编辑器工具
enum EditorTool: CaseIterable {
    case select     // 选中并拖动已有标注
    case rectangle  // 矩形
    case ellipse    // 椭圆
    case arrow      // 箭头
    case pen        // 画笔
    case highlight  // 聚光灯区域：框内保持原亮度，框外半透明压暗
    case mosaic     // 马赛克
    case sequence   // 序号（①②③ 自动递增）
    case text       // 文字

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow.rays"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlight: return "viewfinder.rectangular"
        case .mosaic: return "square.grid.3x3"
        case .sequence: return "1.circle"
        case .text: return "textformat"
        }
    }

    var tooltip: String {
        switch self {
        case .select: return "选择/移动（双击文字可改内容）"
        case .rectangle: return "矩形（Shift 锁正方形）"
        case .ellipse: return "椭圆（Shift 锁正圆）"
        case .arrow: return "箭头（Shift 锁 45°）"
        case .pen: return "画笔"
        case .highlight: return "聚光高亮（框内明亮、框外柔和变暗）"
        case .mosaic: return "马赛克"
        case .sequence: return "序号（点击放置，自动递增）"
        case .text: return "文字"
        }
    }
}

/// 线宽档（同时驱动马赛克块大小、文字字号、序号直径）
enum StrokeWidth: CaseIterable {
    case thin, medium, thick

    var lineWidth: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 7
        }
    }

    /// 马赛克块边长（单位：图像点，合成时乘以 pixelScale 换算成像素）
    var mosaicBlockSize: CGFloat {
        switch self {
        case .thin: return 8
        case .medium: return 13
        case .thick: return 20
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .thin: return 12
        case .medium: return 18
        case .thick: return 26
        }
    }

    var displayName: String {
        switch self {
        case .thin: return "小"
        case .medium: return "中"
        case .thick: return "大"
        }
    }

    /// 序号圆直径（图像点）
    var sequenceDiameter: CGFloat {
        switch self {
        case .thin: return 22
        case .medium: return 28
        case .thick: return 36
        }
    }

    /// 工具栏图标圆点直径
    var dotDiameter: CGFloat {
        switch self {
        case .thin: return 5
        case .medium: return 9
        case .thick: return 13
        }
    }
}

/// 箭头的三种视觉语言。样式写进每一条标注，后续切换预设不会改掉已经画好的箭头。
enum ArrowStyle: String, CaseIterable, Equatable {
    case hollow
    case filled
    case dotGuide

    var displayName: String {
        switch self {
        case .hollow: return "空心"
        case .filled: return "实心"
        case .dotGuide: return "圆点引导"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .hollow: return "轻量空心箭头，不遮挡内容"
        case .filled: return "醒目实心箭头"
        case .dotGuide: return "圆点起笔的柔和引导箭头"
        }
    }
}

/// 只保存“下一支箭头”的预设；用稳定字符串而不是枚举序号，升级时不会串样式。
enum ArrowStylePreference {
    static let defaultsKey = "youmu.editor.arrow-style"
    static let defaultStyle: ArrowStyle = .dotGuide

    static func load(from defaults: UserDefaults = .standard) -> ArrowStyle {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let style = ArrowStyle(rawValue: rawValue) else {
            return defaultStyle
        }
        return style
    }

    static func save(_ style: ArrowStyle, to defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: defaultsKey)
    }
}

/// 六色预设
enum EditorColorPreset: CaseIterable {
    case red, yellow, green, blue, black, white

    var color: NSColor {
        switch self {
        case .red: return NSColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1)
        case .yellow: return NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)
        case .green: return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: return NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        case .black: return .black
        case .white: return .white
        }
    }

    var displayName: String {
        switch self {
        case .red: return "红色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .black: return "黑色"
        case .white: return "白色"
        }
    }
}

// MARK: - 标注模型（值类型，快照式撤销直接复制数组）

/// 一个标注 = 几何 payload + 样式。
/// 坐标全部使用「图像点」坐标系（左下原点，与 AppKit 一致；1 点 = 截图区域 1 点，
/// Retina 像素 = 点 × pixelScale，仅在马赛克切块和最终导出时换算）。
struct Annotation {
    enum Payload {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(start: CGPoint, end: CGPoint, style: ArrowStyle)
        case pen(points: [CGPoint])
        /// 聚光高亮区域：框内保持原亮度，框外由 SpotlightRenderer 统一压暗。
        case highlight(CGRect)
        /// 马赛克：rect 为图像点坐标；image 为拖放结束时预生成的像素化图（点尺寸）
        case mosaic(rect: CGRect, blockSize: CGFloat, image: NSImage?)
        /// 文字：origin 为文字块左下角（未翻转上下文里 draw(at:) 的原点语义）
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
        /// 序号：center 圆心，number 从 1 开始
        case sequence(center: CGPoint, number: Int, diameter: CGFloat)
    }

    var payload: Payload
    var color: NSColor
    var lineWidth: CGFloat

    /// 命中测试/选中框用的包围盒
    var boundingRect: CGRect {
        switch payload {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect):
            return rect
        case .arrow(let start, let end, let style):
            let centerLine = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            let length = hypot(end.x - start.x, end.y - start.y)
            let padding = AnnotationRenderer.arrowVisualPadding(
                length: length, lineWidth: lineWidth, style: style
            )
            return centerLine.insetBy(dx: -padding, dy: -padding)
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .mosaic(let rect, _, _):
            return rect
        case .text(let origin, let string, let fontSize):
            let size = AnnotationRenderer.textSize(string: string, fontSize: fontSize)
            return CGRect(origin: origin, size: size)
        case .sequence(let center, _, let diameter):
            return CGRect(
                x: center.x - diameter / 2, y: center.y - diameter / 2,
                width: diameter, height: diameter
            )
        }
    }

    func hitTest(_ point: CGPoint) -> Bool {
        // 细线条类标注给点容差，方便点中
        boundingRect.insetBy(dx: -5, dy: -5).contains(point)
    }

    func moved(by delta: CGVector) -> Annotation {
        var copy = self
        switch payload {
        case .rectangle(let rect):
            copy.payload = .rectangle(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .ellipse(let rect):
            copy.payload = .ellipse(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .arrow(let start, let end, let style):
            copy.payload = .arrow(
                start: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy),
                end: CGPoint(x: end.x + delta.dx, y: end.y + delta.dy),
                style: style
            )
        case .pen(let points):
            copy.payload = .pen(points: points.map {
                CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy)
            })
        case .highlight(let rect):
            copy.payload = .highlight(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .mosaic(let rect, let blockSize, let image):
            copy.payload = .mosaic(
                rect: rect.offsetBy(dx: delta.dx, dy: delta.dy),
                blockSize: blockSize, image: image
            )
        case .text(let origin, let string, let fontSize):
            copy.payload = .text(
                origin: CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy),
                string: string, fontSize: fontSize
            )
        case .sequence(let center, let number, let diameter):
            copy.payload = .sequence(
                center: CGPoint(x: center.x + delta.dx, y: center.y + delta.dy),
                number: number, diameter: diameter
            )
        }
        return copy
    }
}

// MARK: - 标注绘制器（画布与导出合成共用同一条代码路径）

/// 使用当前 NSGraphicsContext 绘制；坐标为图像点、左下原点（AppKit 未翻转上下文）。
enum AnnotationRenderer {

    static func draw(_ annotation: Annotation) {
        let color = annotation.color
        color.setStroke()
        color.setFill()

        switch annotation.payload {
        case .rectangle(let rect):
            let path = continuousRoundedRectanglePath(
                in: rect,
                lineWidth: annotation.lineWidth
            )
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse(let rect):
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()

        case .arrow(let start, let end, let style):
            drawArrow(
                from: start, to: end,
                lineWidth: annotation.lineWidth,
                style: style
            )

        case .pen(let points):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .highlight(let rect):
            // 聚光高亮必须掌握完整画布与所有高亮框，统一由 SpotlightRenderer 绘制。
            _ = rect

        case .mosaic(let rect, _, let image):
            if let image = image {
                image.draw(in: rect)
            } else {
                // 兜底：未生成像素化图时用半透明灰块占位
                NSColor.gray.withAlphaComponent(0.6).setFill()
                rect.fill()
            }

        case .text(let origin, let string, let fontSize):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: color
            ]
            NSAttributedString(string: string, attributes: attrs).draw(at: origin)

        case .sequence(let center, let number, let diameter):
            let rect = CGRect(
                x: center.x - diameter / 2, y: center.y - diameter / 2,
                width: diameter, height: diameter
            )
            // 实心圆底
            NSBezierPath(ovalIn: rect).fill()
            // 白色序号数字，水平垂直居中
            let font = NSFont.boldSystemFont(ofSize: diameter * 0.52)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let string = NSAttributedString(string: "\(number)", attributes: attrs)
            let textSize = string.size()
            string.draw(at: NSPoint(
                x: center.x - textSize.width / 2,
                y: center.y - textSize.height / 2 + diameter * 0.04 // 视觉中心微调
            ))
        }
    }

    /// 选中态虚线框
    static func drawSelectionHighlight(_ annotation: Annotation) {
        let rect = annotation.boundingRect.insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    static func textSize(string: String, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize)
        ]
        return (string as NSString).size(withAttributes: attrs)
    }

    /// 比直角框更接近 macOS 卡片语言：半径随短边和线宽变化，大小框都不过圆。
    /// NSBezierPath 的圆角段与直线保持切线连续，画布预览和导出共用同一路径。
    static func continuousRoundedRectanglePath(
        in rect: CGRect,
        lineWidth: CGFloat
    ) -> NSBezierPath {
        let rect = rect.standardized
        let shortSide = min(rect.width, rect.height)
        guard shortSide > 0 else { return NSBezierPath(rect: rect) }
        let radius = min(
            max(shortSide * 0.09, 6 + lineWidth * 0.5),
            min(shortSide * 0.24, 18)
        )
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    struct ArrowMetrics: Equatable {
        let shaftWidth: CGFloat
        let headLength: CGFloat
        let headHalfWidth: CGFloat

        var shaftHalfWidth: CGFloat { shaftWidth / 2 }
    }

    /// 三种预设共用一致的箭头比例，只调整重量，避免短箭头头重脚轻。
    static func arrowMetrics(
        length: CGFloat,
        lineWidth: CGFloat,
        style: ArrowStyle = .filled
    ) -> ArrowMetrics? {
        guard length > 1 else { return nil }
        let shaftWidth: CGFloat
        switch style {
        case .hollow: shaftWidth = max(lineWidth, 2)
        case .filled: shaftWidth = max(lineWidth * 1.5, 4.5)
        case .dotGuide: shaftWidth = max(lineWidth, 2.5)
        }
        let headLength = min(max(shaftWidth * 3.7, 16), length * 0.42)
        let headHalfWidth = min(
            max(headLength * 0.42, shaftWidth * 1.55),
            max(length * 0.25, shaftWidth / 2)
        )
        return ArrowMetrics(
            shaftWidth: shaftWidth,
            headLength: headLength,
            headHalfWidth: headHalfWidth
        )
    }

    static func arrowVisualPadding(
        length: CGFloat,
        lineWidth: CGFloat,
        style: ArrowStyle
    ) -> CGFloat {
        let metrics = arrowMetrics(length: length, lineWidth: lineWidth, style: style)
        let dotRadius = style == .dotGuide ? max(lineWidth * 1.2, 3.5) : 0
        return max(max(metrics?.headHalfWidth ?? lineWidth, dotRadius), lineWidth)
    }

    /// 箭杆、箭肩、箭头和圆润尾帽是一条实心路径，不再是“细线 + 小三角”。
    static func arrowPath(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat,
        style: ArrowStyle = .filled
    ) -> NSBezierPath? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard let metrics = arrowMetrics(
            length: length,
            lineWidth: lineWidth,
            style: style
        ) else { return nil }

        let unit = CGVector(dx: dx / length, dy: dy / length)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let neck = CGPoint(
            x: end.x - unit.dx * metrics.headLength,
            y: end.y - unit.dy * metrics.headLength
        )
        let tailTop = CGPoint(
            x: start.x + normal.dx * metrics.shaftHalfWidth,
            y: start.y + normal.dy * metrics.shaftHalfWidth
        )
        let tailBottom = CGPoint(
            x: start.x - normal.dx * metrics.shaftHalfWidth,
            y: start.y - normal.dy * metrics.shaftHalfWidth
        )
        let upperShaft = CGPoint(
            x: neck.x + normal.dx * metrics.shaftHalfWidth,
            y: neck.y + normal.dy * metrics.shaftHalfWidth
        )
        let upperHead = CGPoint(
            x: neck.x + normal.dx * metrics.headHalfWidth,
            y: neck.y + normal.dy * metrics.headHalfWidth
        )
        let lowerHead = CGPoint(
            x: neck.x - normal.dx * metrics.headHalfWidth,
            y: neck.y - normal.dy * metrics.headHalfWidth
        )
        let lowerShaft = CGPoint(
            x: neck.x - normal.dx * metrics.shaftHalfWidth,
            y: neck.y - normal.dy * metrics.shaftHalfWidth
        )

        let path = NSBezierPath()
        path.move(to: tailTop)
        path.line(to: upperShaft)
        path.line(to: upperHead)
        path.line(to: end)
        path.line(to: lowerHead)
        path.line(to: lowerShaft)
        path.line(to: tailBottom)
        let tailControl = metrics.shaftHalfWidth * 4 / 3
        path.curve(
            to: tailTop,
            controlPoint1: CGPoint(
                x: tailBottom.x - unit.dx * tailControl,
                y: tailBottom.y - unit.dy * tailControl
            ),
            controlPoint2: CGPoint(
                x: tailTop.x - unit.dx * tailControl,
                y: tailTop.y - unit.dy * tailControl
            )
        )
        path.close()
        return path
    }

    static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat,
        style: ArrowStyle
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard let metrics = arrowMetrics(
            length: length,
            lineWidth: lineWidth,
            style: style
        ) else { return }
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let headBase = CGPoint(
            x: end.x - unit.dx * metrics.headLength,
            y: end.y - unit.dy * metrics.headLength
        )
        let upperHead = CGPoint(
            x: headBase.x + normal.dx * metrics.headHalfWidth,
            y: headBase.y + normal.dy * metrics.headHalfWidth
        )
        let lowerHead = CGPoint(
            x: headBase.x - normal.dx * metrics.headHalfWidth,
            y: headBase.y - normal.dy * metrics.headHalfWidth
        )

        switch style {
        case .filled:
            arrowPath(
                from: start,
                to: end,
                lineWidth: lineWidth,
                style: style
            )?.fill()

        case .hollow:
            let shaft = NSBezierPath()
            shaft.move(to: start)
            shaft.line(to: end)
            shaft.lineWidth = metrics.shaftWidth
            shaft.lineCapStyle = .round
            shaft.stroke()

            let head = NSBezierPath()
            head.move(to: upperHead)
            head.line(to: end)
            head.line(to: lowerHead)
            head.lineWidth = metrics.shaftWidth
            head.lineCapStyle = .round
            head.lineJoinStyle = .round
            head.stroke()

        case .dotGuide:
            let dotRadius = max(lineWidth * 1.2, 3.5)
            let shaftStart = CGPoint(
                x: start.x + unit.dx * (dotRadius + 1.5),
                y: start.y + unit.dy * (dotRadius + 1.5)
            )
            let shaft = NSBezierPath()
            shaft.move(to: shaftStart)
            shaft.line(to: headBase)
            shaft.lineWidth = metrics.shaftWidth
            shaft.lineCapStyle = .round
            shaft.stroke()

            NSBezierPath(ovalIn: CGRect(
                x: start.x - dotRadius,
                y: start.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )).fill()

            let head = NSBezierPath()
            head.move(to: upperHead)
            head.curve(
                to: end,
                controlPoint1: CGPoint(
                    x: headBase.x + unit.dx * metrics.headLength * 0.45
                        + normal.dx * metrics.headHalfWidth * 0.42,
                    y: headBase.y + unit.dy * metrics.headLength * 0.45
                        + normal.dy * metrics.headHalfWidth * 0.42
                ),
                controlPoint2: CGPoint(
                    x: end.x - unit.dx * metrics.headLength * 0.08
                        + normal.dx * metrics.headHalfWidth * 0.10,
                    y: end.y - unit.dy * metrics.headLength * 0.08
                        + normal.dy * metrics.headHalfWidth * 0.10
                )
            )
            head.curve(
                to: lowerHead,
                controlPoint1: CGPoint(
                    x: end.x - unit.dx * metrics.headLength * 0.08
                        - normal.dx * metrics.headHalfWidth * 0.10,
                    y: end.y - unit.dy * metrics.headLength * 0.08
                        - normal.dy * metrics.headHalfWidth * 0.10
                ),
                controlPoint2: CGPoint(
                    x: headBase.x + unit.dx * metrics.headLength * 0.45
                        - normal.dx * metrics.headHalfWidth * 0.42,
                    y: headBase.y + unit.dy * metrics.headLength * 0.45
                        - normal.dy * metrics.headHalfWidth * 0.42
                )
            )
            head.close()
            head.fill()
        }
    }
}

// MARK: - 聚光高亮

/// 聚光灯效果：高亮框内完全保留原图，框外只覆盖半透明炭黑，不会压成纯黑。
/// 画布与导出共用这一条绘制路径，避免预览和成品效果不一致。
enum SpotlightRenderer {
    static let dimAlpha: CGFloat = 0.38
    static let cornerRadius: CGFloat = 8

    static func highlightRects(from annotations: [Annotation]) -> [CGRect] {
        annotations.compactMap { annotation in
            guard case .highlight(let rect) = annotation.payload else { return nil }
            return rect
        }
    }

    /// 合并互相重叠的框，避免偶奇填充在交叠区再次变暗。
    static func mergedHighlights(_ input: [CGRect], clippedTo fullRect: CGRect) -> [CGRect] {
        var result = input
            .map { $0.standardized.intersection(fullRect) }
            .filter { !$0.isNull && $0.width > 2 && $0.height > 2 }

        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for first in result.indices {
                for second in result.indices where second > first {
                    if result[first].intersects(result[second]) {
                        result[first] = result[first].union(result[second])
                        result.remove(at: second)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return result
    }

    static func draw(in fullRect: CGRect, highlights: [CGRect]) {
        let holes = mergedHighlights(highlights, clippedTo: fullRect)
        guard !holes.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        let mask = NSBezierPath(rect: fullRect)
        for rect in holes {
            mask.append(NSBezierPath(
                roundedRect: rect,
                xRadius: min(cornerRadius, rect.width / 2),
                yRadius: min(cornerRadius, rect.height / 2)
            ))
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        mask.fill()

        // 一条克制的亮边帮助用户看清高亮范围，但不抢内容。
        NSColor.white.withAlphaComponent(0.78).setStroke()
        for rect in holes {
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                xRadius: min(cornerRadius, rect.width / 2),
                yRadius: min(cornerRadius, rect.height / 2)
            )
            border.lineWidth = 1.5
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
