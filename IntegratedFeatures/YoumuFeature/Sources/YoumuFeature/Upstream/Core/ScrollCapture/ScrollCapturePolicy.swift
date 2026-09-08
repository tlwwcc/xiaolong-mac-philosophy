import Foundation

nonisolated enum ScrollCapturePolicy {
    static let absoluteMaximumOutputHeight = 32_768
    /// Pixel storage for accepted rows is bounded independently of display height. Rendering can
    /// temporarily need another buffer of the same size, so 128 MiB keeps the peak predictable.
    static let maximumOutputPixelBytes = 128 * 1_024 * 1_024

    static func maximumOutputHeight(pixelWidth: Int) -> Int {
        guard pixelWidth > 0 else { return 0 }
        let (bytesPerRow, overflow) = pixelWidth.multipliedReportingOverflow(by: 4)
        guard !overflow, bytesPerRow > 0 else { return 0 }
        return min(absoluteMaximumOutputHeight, maximumOutputPixelBytes / bytesPerRow)
    }

    static let firstCompleteFrameTimeout: TimeInterval = 4
}
