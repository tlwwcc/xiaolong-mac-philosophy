import AppKit
import SwiftUI

/// 游目的统一视觉令牌。
///
/// 原则：内容优先、只在浮层使用材质、颜色全部来自系统语义色，确保浅色、深色和
/// “提高对比度”模式下仍然清晰。AppKit 与 SwiftUI 共用同一套值，避免不同窗口各画各的。
enum VisionDesign {
    static let compactRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 16

    /// AI 小龙哥 VI 的 canonical 主紫色。只用于品牌记忆点与主播放动作。
    static let brandPurple = NSColor(
        calibratedRed: 107 / 255, green: 35 / 255, blue: 142 / 255, alpha: 1
    )
    static let brandViolet = NSColor(
        calibratedRed: 122 / 255, green: 63 / 255, blue: 160 / 255, alpha: 1
    )
    /// Keep the canonical purple for white-on-purple controls; use the brighter accent for text.
    static let brandAccent = NSColor(name: "YoumuBrandAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.80, green: 0.65, blue: 0.91, alpha: 1)
            : NSColor(calibratedRed: 107 / 255, green: 35 / 255, blue: 142 / 255, alpha: 1)
    }
    static let failureText = NSColor(name: "YoumuFailureText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.58, alpha: 1)
            : NSColor(srgbRed: 0.69, green: 0.0, blue: 0.13, alpha: 1)
    }
    static let paperWhite = NSColor.textBackgroundColor
    static let ink = NSColor.labelColor
    static var brandPurpleSoft: NSColor { brandAccent.withAlphaComponent(0.12) }

    static let editorChrome = NSColor.windowBackgroundColor
    static let editorChromeRaised = NSColor.controlBackgroundColor
    static let editorDivider = NSColor.separatorColor
    static let editorForeground = NSColor.labelColor
    static let editorSecondary = NSColor.secondaryLabelColor
    static let selectionFill = brandPurple
    static let selectionForeground = NSColor.white
    static let pausedHighlight = NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.02, alpha: 1)

    // Content overlays stay dark over arbitrary photographs; opaque surfaces also work when
    // Reduce Transparency is enabled, without changing captured/translated image pixels.
    static let overlayBackground = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let overlayBorder = NSColor(calibratedWhite: 0.65, alpha: 1)

    static var panelBorder: NSColor { NSColor.separatorColor }

    static var quietFill: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.10)
    }
}

/// CALayer stores resolved CGColor values; refresh them in the actual view appearance whenever
/// the host changes its appearance. AppKit text and control colors remain dynamic NSColors.
class VisionSurfaceView: NSView {
    var surfaceColor: NSColor = .clear { didSet { refreshSurface() } }
    var outlineColor: NSColor = .clear { didSet { refreshSurface() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSurface()
    }

    private func refreshSurface() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor.cgColor
            layer?.borderColor = outlineColor.cgColor
        }
    }
}

final class VisionStatusField: NSTextField {
    var surfaceColor: NSColor = .clear { didSet { refreshSurface() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSurface()
    }

    private func refreshSurface() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor.cgColor
        }
    }
}

final class VisionMaterialView: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBorder()
    }

    private func refreshBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = VisionDesign.panelBorder.cgColor
        }
    }
}

final class VisionTextScrollView: NSScrollView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBorder()
    }

    private func refreshBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = VisionDesign.panelBorder.cgColor
        }
    }
}

enum VisionMotionPolicy {
    static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func shouldAnimate(reduceMotionEnabled: Bool) -> Bool {
        !reduceMotionEnabled
    }
}

extension Color {
    static var visionAccentSoft: Color {
        Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.11))
    }

    static var visionCard: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var visionBorder: Color {
        Color(nsColor: VisionDesign.panelBorder)
    }
}

/// 设置页统一页头：用一句话回答“这页管什么”，避免一进页面就是密集表单。
struct VisionPaneHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.visionAccentSoft)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

/// 语义状态胶囊。只承担“当前会发生什么”，不重复开关标题。
struct VisionStatusPill: View {
    let text: String
    var active = true

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(active ? .accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(active ? Color.visionAccentSoft : Color.secondary.opacity(0.10))
            )
    }
}

struct VisionKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.visionBorder, lineWidth: 0.75)
            )
    }
}
