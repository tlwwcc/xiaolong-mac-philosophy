import AppKit
import SwiftUI

struct ToolbarIconButton: View {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  let systemImage: String
  let title: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isEnabled ? tint : muted.opacity(0.45))
        .frame(width: 34, height: 32)
        .background(
          LinearGradient(
            colors: buttonColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
              hovering ? tint.opacity(0.34) : AppVisualStyle.surface.opacity(0.82), lineWidth: 1)
        )
        .shadow(
          color: isEnabled ? tint.opacity(hovering ? 0.16 : 0.07) : Color.clear, radius: 7, x: 0,
          y: 4
        )
        .scaleEffect(hovering && isEnabled ? 1.035 : 1)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var buttonColors: [Color] {
    if !isEnabled {
      return [AppVisualStyle.surface.opacity(0.46), chrome.opacity(0.36)]
    }
    if hovering {
      return [AppVisualStyle.surface.opacity(0.98), tint.opacity(0.15)]
    }
    return [AppVisualStyle.surface.opacity(0.94), tint.opacity(0.08)]
  }
}

struct HeaderUpdateButton: View {
  let title: String
  let isBusy: Bool
  let busyTitle: String
  let helpText: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(
        isBusy ? busyTitle : title,
        systemImage: isBusy ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill"
      )
      .font(.system(size: 11, weight: .semibold))
      .labelStyle(.titleAndIcon)
      .foregroundStyle(UpdateReminderAppearance.blue)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(UpdateReminderAppearance.blue.opacity(0.09), in: Capsule())
      .overlay(Capsule().stroke(UpdateReminderAppearance.blue.opacity(0.24), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help(helpText)
    .accessibilityLabel(isBusy ? busyTitle : accessibilityLabel)
    .accessibilityIdentifier("titlebar.update")
  }
}

struct HeaderToolIconButton: View {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  let systemImage: String
  let title: String
  let tint: Color
  var isDestructive = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(iconColor)
        .frame(width: 30, height: 29)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
        )
        .scaleEffect(hovering && isEnabled ? 1.025 : 1)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .onHover { inside in hovering = inside }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var iconColor: Color {
    guard isEnabled else { return muted.opacity(0.38) }
    if isDestructive { return ruby.opacity(hovering ? 0.90 : 0.72) }
    return tint.opacity(hovering ? 0.88 : 0.68)
  }

  private var backgroundColor: Color {
    guard isEnabled else { return AppVisualStyle.surface.opacity(0.30) }
    return hovering ? AppVisualStyle.surface.opacity(0.78) : AppVisualStyle.surface.opacity(0.48)
  }

  private var borderColor: Color {
    if !isEnabled { return AppVisualStyle.surface.opacity(0.30) }
    return hovering ? iconColor.opacity(0.18) : AppVisualStyle.surface.opacity(0.50)
  }
}
