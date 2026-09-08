import AppKit

/// 「游目经典目声标」：阅读器使用完整 App 艺术图，菜单栏使用同构图的单色光学校正版。
enum YoumuBrandMark {
    private static let designSize = NSSize(width: 48, height: 48)

    private static let bundledArtwork: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    static func drawColor(in rect: NSRect) {
        if let bundledArtwork {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            bundledArtwork.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // 独立测试环境没有 App bundle 资源时，保留同构图的轻量彩色回退。
        withScaledContext(in: rect) {
            let tile = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 1, width: 46, height: 46),
                xRadius: 11,
                yRadius: 11
            )
            NSColor(calibratedRed: 49 / 255, green: 13 / 255, blue: 78 / 255, alpha: 1).setFill()
            tile.fill()
            drawGlyph(strokeColor: NSColor(calibratedWhite: 1, alpha: 0.98))
        }
    }

    static func drawTemplate(in rect: NSRect) {
        withScaledContext(in: rect) {
            drawGlyph(strokeColor: .black)
        }
    }

    /// 48pt 设计坐标。四角、目形与声纹分别做光学校正，缩到 18pt 仍保留三层识别。
    private static func drawGlyph(strokeColor: NSColor) {
        strokeColor.setStroke()
        strokeColor.setFill()

        let corners: [[NSPoint]] = [
            [NSPoint(x: 15.1, y: 38.4), NSPoint(x: 9.2, y: 38.4), NSPoint(x: 9.2, y: 32.5)],
            [NSPoint(x: 32.9, y: 38.4), NSPoint(x: 38.8, y: 38.4), NSPoint(x: 38.8, y: 32.5)],
            [NSPoint(x: 15.1, y: 9.6), NSPoint(x: 9.2, y: 9.6), NSPoint(x: 9.2, y: 15.5)],
            [NSPoint(x: 32.9, y: 9.6), NSPoint(x: 38.8, y: 9.6), NSPoint(x: 38.8, y: 15.5)],
        ]
        for points in corners {
            let corner = NSBezierPath()
            corner.move(to: points[0])
            corner.line(to: points[1])
            corner.line(to: points[2])
            corner.lineWidth = 3.2
            corner.lineCapStyle = .round
            corner.lineJoinStyle = .round
            corner.stroke()
        }

        let upperEye = NSBezierPath()
        upperEye.move(to: NSPoint(x: 11.0, y: 19.6))
        upperEye.curve(
            to: NSPoint(x: 38.1, y: 24.2),
            controlPoint1: NSPoint(x: 18.2, y: 31.8),
            controlPoint2: NSPoint(x: 25.8, y: 35.3)
        )
        upperEye.lineWidth = 3.0
        upperEye.lineCapStyle = .round
        upperEye.lineJoinStyle = .round
        upperEye.stroke()

        let lowerEye = NSBezierPath()
        lowerEye.move(to: NSPoint(x: 12.8, y: 21.8))
        lowerEye.curve(
            to: NSPoint(x: 37.0, y: 22.8),
            controlPoint1: NSPoint(x: 19.0, y: 25.4),
            controlPoint2: NSPoint(x: 26.0, y: 16.1)
        )
        lowerEye.lineWidth = 2.8
        lowerEye.lineCapStyle = .round
        lowerEye.lineJoinStyle = .round
        lowerEye.stroke()

        let soundArc = NSBezierPath()
        soundArc.move(to: NSPoint(x: 15.8, y: 14.4))
        soundArc.curve(
            to: NSPoint(x: 32.2, y: 14.4),
            controlPoint1: NSPoint(x: 20.1, y: 10.6),
            controlPoint2: NSPoint(x: 28.0, y: 10.6)
        )
        soundArc.lineWidth = 2.4
        soundArc.lineCapStyle = .round
        soundArc.stroke()

        let bars: [(x: CGFloat, y: CGFloat, height: CGFloat)] = [
            (20.0, 13.9, 3.0),
            (24.0, 13.4, 4.0),
            (28.0, 13.9, 3.0),
        ]
        for bar in bars {
            let rect = NSRect(
                x: bar.x - 1.0,
                y: bar.y,
                width: 2.0,
                height: bar.height
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: 1.0,
                yRadius: 1.0
            ).fill()
        }
    }

    private static func withScaledContext(in rect: NSRect, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext.current?.cgContext {
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / designSize.width, y: rect.height / designSize.height)
        }
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
}
