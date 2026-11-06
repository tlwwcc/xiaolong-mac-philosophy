import AppKit
import SwiftUI

struct LauncherUtilityCard: View {
  @State private var isHovering = false
  let item: LauncherUtilityItem
  var compact = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if compact {
        HStack(spacing: 12) {
          Image(systemName: iconName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

          Text(primaryText)
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(ink)
            .lineLimit(1)

          Spacer(minLength: 8)

          Image(systemName: item.kind == .calculator ? "doc.on.doc" : "arrow.up.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(
          isHovering ? AppVisualStyle.hover : Color.clear,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        HStack(spacing: 15) {
          Image(systemName: iconName)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 50, height: 50)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 5) {
            Text(headerText)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(tint)

            Text(primaryText)
              .font(.system(size: 26, weight: .semibold, design: .rounded))
              .foregroundStyle(ink)
              .lineLimit(1)

            Text(item.subtitle)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(muted)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          Text(item.actionTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .background(isHovering ? Color.accentColor.opacity(0.07) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(accessibilityText)
    .accessibilityLabel(accessibilityText)
  }

  private var tint: Color {
    item.kind == .calculator ? amber : accent
  }

  private var iconName: String {
    item.kind == .calculator ? "function" : "safari.fill"
  }

  private var headerText: String {
    item.kind == .calculator ? "计算器" : item.title
  }

  private var primaryText: String {
    item.value
  }

  private var accessibilityText: String {
    "\(headerText)，\(primaryText)，\(item.actionTitle)"
  }
}
