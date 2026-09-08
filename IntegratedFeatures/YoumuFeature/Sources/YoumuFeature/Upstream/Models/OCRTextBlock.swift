import Foundation

/// OCR 识别出的单个文字块
struct OCRTextBlock {
    let text: String
    /// Vision 归一化坐标 (0~1)，原点在左下角
    let boundingBox: CGRect
    let confidence: Float
}
