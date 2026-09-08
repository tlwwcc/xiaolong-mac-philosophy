import AppKit
import SwiftUI

/// 截图翻译 — 浮动结果窗口
class TranslationPopupWindow {
    private static var panel: NSPanel?
    private static var owner: CaptureCommandOwner?
    private static var onDismiss: ((CaptureCommandOwner) -> Void)?

    static func show(
        originalText: String,
        translatedText: String,
        owner: CaptureCommandOwner? = nil,
        onDismiss: ((CaptureCommandOwner) -> Void)? = nil
    ) {
        // 关闭已有窗口（同时停止可能在进行的朗读）
        SpeechService.shared.stop()
        hideCurrentPanel()

        let viewModel = TranslationResultViewModel(
            originalText: originalText,
            translatedText: translatedText
        )
        let contentView = TranslationResultView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)

        // 窗口尺寸
        let windowWidth: CGFloat = 430
        let estimatedHeight = min(560, max(300, CGFloat(translatedText.count) * 0.7 + 210))

        // 定位：屏幕右上角
        guard let screen = NSScreen.main else {
            if let owner { onDismiss?(owner) }
            return
        }
        let x = screen.visibleFrame.maxX - windowWidth - 24
        let y = screen.visibleFrame.maxY - estimatedHeight - 24

        let newPanel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: windowWidth, height: estimatedHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.title = "游目 · 翻译"
        newPanel.contentView = hostingView
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        // 结果窗保留内容区拖动，这是交接文档 §5 的刻意例外；编辑器仍必须关闭。
        newPanel.isMovableByWindowBackground = true
        newPanel.titlebarAppearsTransparent = false
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false

        newPanel.orderFrontRegardless()
        newPanel.delegate = SpeechStopper.shared // 用户点关闭按钮时也停朗读
        panel = newPanel
        self.owner = owner
        self.onDismiss = onDismiss
    }

    /// Closes only the translation window created by this exact capture invocation.
    @discardableResult
    static func dismiss(owner: CaptureCommandOwner) -> Bool {
        guard self.owner == owner else { return false }
        SpeechService.shared.stop()
        return hideCurrentPanel()
    }

    @discardableResult
    fileprivate static func hideCurrentPanel(_ requestedPanel: NSWindow? = nil) -> Bool {
        guard let oldPanel = panel,
              requestedPanel == nil || requestedPanel === oldPanel else { return false }
        let dismissedOwner = owner
        let dismissHandler = onDismiss
        oldPanel.orderOut(nil)
        panel = nil
        owner = nil
        onDismiss = nil
        if let dismissedOwner {
            dismissHandler?(dismissedOwner)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = oldPanel
        }
        return true
    }
}

/// 弹窗关闭时自动停止朗读
private final class SpeechStopper: NSObject, NSWindowDelegate {
    static let shared = SpeechStopper()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        SpeechService.shared.stop()
        TranslationPopupWindow.hideCurrentPanel(sender)
        return false
    }
}
