import AppKit
import SwiftUI

struct StatusPill: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(color.opacity(0.10), in: Capsule())
  }
}

struct ScrollModeButton: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 30, height: 30)
          .foregroundStyle(selected ? AppVisualStyle.onAccent : accent)
          .background(
            selected ? accent : accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
          Text(subtitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
        Spacer()
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(teal)
        }
      }
      .padding(.horizontal, 12)
      .frame(width: 244, height: 58)
      .background(
        selected ? accent.opacity(0.08) : softSurface, in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(
            selected ? accent.opacity(0.55) : line.opacity(0.7), lineWidth: selected ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct ScrollMetric: View {
  let title: String
  let value: String

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(softSurface, in: Capsule())
    .overlay(Capsule().stroke(line.opacity(0.65), lineWidth: 1))
  }
}

struct ScrollToggle: View {
  let title: String
  let value: Bool
  let set: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    Toggle(
      title,
      isOn: Binding(
        get: { value },
        set: set
      )
    )
    .font(.system(size: 12, weight: .bold))
    .toggleStyle(.checkbox)
  }
}

struct ScrollSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let set: @MainActor @Sendable (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(muted)
        Spacer()
        Text(String(format: "%.1f", value))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(ink)
      }
      Slider(
        value: Binding(
          get: { value },
          set: set
        ),
        in: range
      )
    }
    .frame(minWidth: 138)
  }
}

struct StatusChip: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(muted)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
    }
    .padding(.horizontal, 10)
    .frame(height: 28)
    .background(
      LinearGradient(
        colors: [AppVisualStyle.surface.opacity(0.86), color.opacity(0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: Capsule()
    )
    .overlay(Capsule().stroke(AppVisualStyle.separator, lineWidth: 1))
  }
}

struct HeaderWarningChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(amber.opacity(0.92))
      .padding(.horizontal, 7)
      .frame(height: 20)
      .background(amber.opacity(0.08), in: Capsule())
      .overlay(Capsule().stroke(amber.opacity(0.16), lineWidth: 1))
  }
}
