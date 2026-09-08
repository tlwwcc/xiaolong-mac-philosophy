import AppKit

/// 轻量 toast 提示：无边框浮动面板，自动淡出消失。
/// 用于静默 OCR 结果反馈、占位功能提示等不需要用户交互的场景。
class ToastWindow {
    private static var currentPanel: NSPanel?

    /// 在鼠标所在屏顶部居中展示一条 toast
    static func show(message: String, duration: TimeInterval = 2.0) {
        // 替换已有 toast
        currentPanel?.orderOut(nil)
        currentPanel = nil

        // 内容视图：深色圆底 + 白字
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.sizeToFit()

        let paddingH: CGFloat = 18
        let paddingV: CGFloat = 10
        let contentWidth = min(label.frame.width + paddingH * 2, 480)
        let contentHeight = label.frame.height + paddingV * 2

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = contentHeight / 2
        label.frame.origin = NSPoint(
            x: (contentWidth - label.frame.width) / 2,
            y: paddingV - 1
        )
        container.addSubview(label)

        // 定位：鼠标所在屏顶部居中
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: screenFrame.midX - contentWidth / 2,
            y: screenFrame.maxY - contentHeight - 90
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: contentWidth, height: contentHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        // 运行中的长截图使用 on-screen window capture；提示层不能进入下一帧污染拼接。
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.orderFrontRegardless()

        currentPanel = panel

        // 停留后淡出，淡出动画走完再延迟释放引用
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard VisionMotionPolicy.shouldAnimate(
                reduceMotionEnabled: VisionMotionPolicy.reduceMotionEnabled
            ) else {
                panel.orderOut(nil)
                if currentPanel === panel { currentPanel = nil }
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    // 与窗口释放安全约束一致：orderOut 后延迟再置 nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if currentPanel === panel {
                            currentPanel = nil
                        }
                    }
                }
            }
        }
    }
}
