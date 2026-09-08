import Foundation

/// 八个功能模式。快捷键注册和权益判定由宿主 Platform dispatcher 统一负责。
enum TranslateMode: String, Codable, CaseIterable {
    case screenshotTranslate // OCR 翻译：弹窗显示译文
    case imageTranslate      // 原图翻译：译文覆盖在图上
    case silentOCR           // OCR 复制：识别文字进剪贴板 + 迷你工作台
    case screenshotEdit      // 截图加标注
    case quickSnapshot       // 截图到剪贴板：无窗口，仅音效
    case longScreenshot      // 长截图
    case pinClipboard        // 钉截图：剪贴板图片钉到桌面（不走选区）
    case selectionReader     // 选哪读哪：框选 → 本机 OCR → Edge / Mac 朗读

    var displayName: String {
        switch self {
        case .screenshotTranslate: return "OCR 翻译"
        case .imageTranslate: return "原图翻译"
        case .silentOCR: return "OCR 复制"
        case .screenshotEdit: return "截图加标注"
        case .quickSnapshot: return "截图到剪贴板"
        case .longScreenshot: return "长截图"
        case .pinClipboard: return "钉截图"
        case .selectionReader: return "选哪读哪"
        }
    }

    var menuIcon: String {
        switch self {
        case .screenshotTranslate: return "camera.viewfinder"
        case .imageTranslate: return "photo.on.rectangle.angled"
        case .silentOCR: return "text.viewfinder"
        case .screenshotEdit: return "scribble.variable"
        case .quickSnapshot: return "camera"
        case .longScreenshot: return "rectangle.expand.vertical"
        case .pinClipboard: return "pin"
        case .selectionReader: return "speaker.wave.2"
        }
    }

}

enum Language: String, CaseIterable, Codable {
    case auto = "自动检测"
    case zhHans = "中文简体"
    case zhHant = "中文繁体"
    case en = "English"
    case ja = "日本語"
    case ko = "한국어"

    var displayName: String { rawValue }
}
