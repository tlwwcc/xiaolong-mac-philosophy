import AppKit
import SwiftUI

// Native semantic roles are shared with companion surfaces, not tied to brand pigment.
let accent = AppVisualStyle.accent
let teal = AppVisualStyle.success
let amber = AppVisualStyle.warning
let ruby = AppVisualStyle.danger
let violet = AppVisualStyle.accent
let ink = AppVisualStyle.textPrimary
let muted = AppVisualStyle.textSecondary
let appBackground = AppVisualStyle.background
let sidebarBackground = AppVisualStyle.background
let surface = AppVisualStyle.surface
let softSurface = AppVisualStyle.background
let line = AppVisualStyle.separator
let indigo = AppVisualStyle.accent
let glowBlue = AppVisualStyle.accent
let glassLine = AppVisualStyle.separator
let chrome = AppVisualStyle.background
let sidebarTint = AppVisualStyle.background
let elevatedSurface = AppVisualStyle.surface
let hairline = AppVisualStyle.separator

func symbolForPrimaryAction(_ title: String) -> String {
  if title.contains("新增") { return "plus" }
  if title.contains("删除") || title.contains("卸载") { return "trash" }
  if title.contains("扫描") || title.contains("检测") || title.contains("恢复") {
    return "arrow.clockwise"
  }
  if title.contains("辅助") || title.contains("权限") { return "figure.stand" }
  if title.contains("配置") || title.contains("说明") { return "doc.text.magnifyingglass" }
  if title.contains("官网") || title.contains("网址") { return "safari" }
  if title.contains("应用") || title.contains("目录") || title.contains("文件") { return "folder" }
  if title.contains("运行") { return "play.fill" }
  if title.contains("确定") { return "checkmark" }
  if title.contains("取消") || title.contains("关闭") { return "xmark" }
  return "circle"
}

struct AppBackdrop: View {
  var body: some View {
    AppVisualStyle.background.ignoresSafeArea()
  }
}

struct PremiumPanel: ViewModifier {
  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        AppVisualStyle.surface,
        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(AppVisualStyle.separator, lineWidth: 1)
      )
  }
}

extension View {
  func premiumPanel(radius: CGFloat = 16) -> some View {
    modifier(PremiumPanel(radius: radius))
  }
}

struct IconBadge: View {
  let systemImage: String
  let tint: Color
  var size: CGFloat = 44
  var iconSize: CGFloat = 18
  var filled = true

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: iconSize, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(filled ? AppVisualStyle.onAccent : tint)
      .frame(width: size, height: size)
      .background(
        filled ? tint : AppVisualStyle.background,
        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

struct GlassLabelButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let tint: Color
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AppVisualStyle.controlFont)
      .foregroundStyle(prominent ? AppVisualStyle.onAccent : (isEnabled ? tint : muted))
      .padding(.horizontal, 12)
      .frame(height: 34)
      .background(
        prominent ? tint : AppVisualStyle.surface,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(prominent ? Color.clear : AppVisualStyle.separator, lineWidth: 1)
      )
      .opacity(isEnabled ? 1 : 0.52)
  }
}

struct IconOnlyButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let tint: Color
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? tint : muted.opacity(0.52))
      .frame(width: 30, height: 30)
      .background(
        (isDestructive ? ruby : tint).opacity(configuration.isPressed ? 0.16 : 0.08),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke((isDestructive ? ruby : tint).opacity(0.16), lineWidth: 1)
      )
      .opacity(isEnabled ? 1 : 0.48)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SidebarActionButton: View {
  @Environment(\.isEnabled) private var isEnabled

  let systemImage: String
  let title: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .semibold))
        Text(title)
          .font(.system(size: 12, weight: .medium))
      }
      .frame(maxWidth: .infinity, minHeight: 36)
    }
    .buttonStyle(GlassLabelButtonStyle(tint: tint, prominent: false))
    .help(title)
    .accessibilityLabel(title)
    .opacity(isEnabled ? 1 : 0.52)
  }
}
