import AppKit
import SwiftUI

struct MosCheckRow: View {
  let label: String
  let title: String
  let isOn: Bool
  let set: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    HStack(spacing: 14) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)

      Toggle(
        "",
        isOn: Binding(
          get: { isOn },
          set: set
        )
      )
      .toggleStyle(.checkbox)

      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(ink)

      Spacer()
    }
    .frame(height: 30)
  }
}

struct MosKeyRow: View {
  let label: String
  let keyText: String
  let help: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)
        .padding(.top, 8)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(keyText)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: 180, height: 34)
            .background(line.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(muted)
        }

        Text(help)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }

      Spacer()
    }
  }
}

struct MosSliderRow: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let help: String
  let set: @MainActor @Sendable (Double) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(muted)
        .frame(width: 76, alignment: .trailing)
        .padding(.top, 8)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 12) {
          Slider(
            value: Binding(
              get: { value },
              set: set
            ),
            in: range
          )
          .frame(width: 320)

          Text(String(format: "%.2f", value))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: 78, height: 32)
            .background(AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(line, lineWidth: 1))
        }

        Text(help)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted)
      }
    }
  }
}
