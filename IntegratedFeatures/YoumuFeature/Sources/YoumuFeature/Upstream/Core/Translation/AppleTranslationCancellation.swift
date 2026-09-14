import Foundation
@preconcurrency import Translation

// SwiftUI 同时声明名为 Translation 的类型；独立文件保留系统模块限定，
// 避免与 SwiftUI.Translation 以及本工程在线 TranslationError 混淆。
@available(macOS 15.0, *)
typealias AppleFrameworkTranslationError = Translation.TranslationError

enum AppleTranslationCancellation {
    static func matches(_ error: Error) -> Bool {
        if #available(macOS 26.0, *),
           case Translation.TranslationError.alreadyCancelled = error {
            return true
        }
        return error is CancellationError
    }
}
