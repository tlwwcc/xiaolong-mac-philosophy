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
    static let paperWhite = NSColor(
        calibratedRed: 252 / 255, green: 251 / 255, blue: 253 / 255, alpha: 1
    )
    static let ink = NSColor(
        calibratedRed: 23 / 255, green: 19 / 255, blue: 28 / 255, alpha: 1
    )
    static var brandPurpleSoft: NSColor {
        brandPurple.withAlphaComponent(0.12)
    }

    static let editorChrome = NSColor(
        calibratedRed: 0.075, green: 0.082, blue: 0.10, alpha: 0.98
    )
    static let editorChromeRaised = NSColor(
        calibratedRed: 0.115, green: 0.125, blue: 0.15, alpha: 0.98
    )
    static let editorDivider = NSColor.white.withAlphaComponent(0.10)

    static var panelBorder: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.72)
    }

    static var quietFill: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.10)
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
