import AppKit

/// 最近一次截图的共享存储（菜单栏「钉图」的数据源）。
/// 各捕获路径（单帧选区、原图翻译、长截图拼接）在拿到图后写入。
final class LastCaptureStore {
    static let shared = LastCaptureStore()

    private(set) var image: CGImage?
    private(set) var pixelScale: CGFloat = 2

    func store(_ image: CGImage, pixelScale: CGFloat) {
        self.image = image
        self.pixelScale = pixelScale
    }

    var hasImage: Bool { image != nil }
}
