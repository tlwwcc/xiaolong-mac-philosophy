import AppKit
import CoreImage
import UniformTypeIdentifiers

/// PNG/TIFF 自身不一定保留 macOS 截图的 Retina 点尺寸。
/// 游目复制图片时额外写入一个私有剪贴板类型，让后续定图能恢复原始视觉尺寸。
enum ImagePasteboardMetadata {
    static var pixelScaleType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(
            YoumuFeatureEnvironmentStore.shared.pasteboardPixelScaleType()
        )
    }

    static func validPixelScale(_ value: CGFloat) -> CGFloat? {
        guard value.isFinite, value >= 1, value <= 4 else { return nil }
        return value
    }

    static func write(pixelScale: CGFloat, to pasteboard: NSPasteboard) {
        guard let value = validPixelScale(pixelScale) else { return }
        pasteboard.setString(String(Double(value)), forType: pixelScaleType)
    }

    static func pixelScale(from pasteboard: NSPasteboard) -> CGFloat? {
        guard let raw = pasteboard.string(forType: pixelScaleType),
              let value = Double(raw)
        else { return nil }
        return validPixelScale(CGFloat(value))
    }
}

/// 图像合成与导出：最终成图 = 原图 + 标注层，全像素分辨率输出。
enum ImageComposer {

    // MARK: - 马赛克（CoreImage CIPixellate 局部处理）

    /// 对 baseCG 的 rect 区域（图像点坐标，左下原点）生成像素化图。
    /// blockSizePoints 会乘以 pixelScale 换算成实际像素块边长。
    static func pixelatedMosaic(
        rect: CGRect,
        imageSizePoints: NSSize,
        baseCG: CGImage,
        blockSizePoints: CGFloat
    ) -> NSImage? {
        let clamped = rect.intersection(NSRect(origin: .zero, size: imageSizePoints))
        guard clamped.width > 2, clamped.height > 2 else { return nil }

        // 图像点 → CG 像素坐标（左上原点，Y 翻转）
        let scale = CGFloat(baseCG.width) / imageSizePoints.width
        let cgRegion = CGRect(
            x: clamped.minX * scale,
            y: (imageSizePoints.height - clamped.minY - clamped.height) * scale,
            width: clamped.width * scale,
            height: clamped.height * scale
        )
        guard let cropped = baseCG.cropping(to: cgRegion) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(blockSizePoints * scale, 4), forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY),
            forKey: kCIInputCenterKey
        )

        guard let output = filter.outputImage,
              let outputCG = CIContext().createCGImage(output, from: ciImage.extent)
        else { return nil }

        return NSImage(cgImage: outputCG, size: clamped.size)
    }

    // MARK: - 合成

    /// 原图 + 标注层合成，输出与 baseCG 同像素分辨率的位图。
    /// 用「点尺寸 + 像素尺寸」的 NSBitmapImageRep：AppKit 按图像点坐标绘制，
    /// 底层自动映射到 2x 像素，避免手工翻转/缩放出错。
    static func composedRep(
        base baseCG: CGImage,
        pixelScale: CGFloat,
        annotations: [Annotation]
    ) -> NSBitmapImageRep? {
        let pixelWidth = baseCG.width
        let pixelHeight = baseCG.height
        let pointSize = NSSize(
            width: CGFloat(pixelWidth) / pixelScale,
            height: CGFloat(pixelHeight) / pixelScale
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // 关键：点尺寸告诉 AppKit 绘制坐标系，像素尺寸决定输出分辨率
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let fullRect = NSRect(origin: .zero, size: pointSize)
        NSImage(cgImage: baseCG, size: pointSize).draw(in: fullRect)
        for annotation in annotations {
            if case .highlight = annotation.payload { continue }
            AnnotationRenderer.draw(annotation)
        }
        SpotlightRenderer.draw(
            in: fullRect,
            highlights: SpotlightRenderer.highlightRects(from: annotations)
        )

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - 输出

    /// 复制到剪贴板：PNG + TIFF 两种格式都写
    static func copyToPasteboard(base baseCG: CGImage, pixelScale: CGFloat, annotations: [Annotation]) {
        guard let rep = composedRep(base: baseCG, pixelScale: pixelScale, annotations: annotations) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        ImagePasteboardMetadata.write(pixelScale: pixelScale, to: pasteboard)
    }

    /// 弹 NSSavePanel 保存 PNG；completion 报告是否真正保存了
    static func savePNGWithPanel(
        base baseCG: CGImage,
        pixelScale: CGFloat,
        annotations: [Annotation],
        parentWindow: NSWindow? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard let rep = composedRep(base: baseCG, pixelScale: pixelScale, annotations: annotations),
              let png = rep.representation(using: .png, properties: [:])
        else {
            completion(false)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "游目-\(formatter.string(from: Date())).png"

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            do {
                try png.write(to: url)
                completion(true)
            } catch {
                PrivacySafeLog.event("png_save_failed", error: error)
                completion(false)
            }
        }
        // 浮动定图必须把保存面板附着到自身，避免被 always-on-top 窗口遮挡。
        if let parentWindow {
            panel.beginSheetModal(for: parentWindow, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
