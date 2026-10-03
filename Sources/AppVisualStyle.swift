import AppKit
import SwiftUI

/// Brand system 3.0 · endorsed product · native-paper.
/// Product assets carry identity; native semantic roles carry interaction and status.
/// Every UI pigment resolves at drawing time, including after an in-place appearance change.
enum AppVisualStyle {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
  static let textPrimary = Color(nsColor: .labelColor)
  static let textSecondary = dynamicColor("secondary") { _ in
    NSColor.secondaryLabelColor.blended(withFraction: 0.20, of: .labelColor) ?? .secondaryLabelColor
  }
  static let separator = Color(nsColor: .separatorColor)
  static let accent = dynamicColor("accent") { dark in
    dark ? NSColor.systemBlue.blended(withFraction: 0.30, of: .white) ?? .systemBlue
      : .selectedContentBackgroundColor
  }
  static let emphasizedSelection = Color(nsColor: .selectedContentBackgroundColor)
  static let onAccent = dynamicColor("onAccent") { dark in dark ? .black : .white }
  static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
  static let hover = Color(nsColor: .labelColor).opacity(0.04)
  static let success = statusInk(.systemGreen)
  static let warning = statusInk(.systemOrange)
  static let danger = statusInk(.systemRed)

  private static func statusInk(_ color: NSColor) -> Color {
    dynamicColor("status-\(color.description)") { dark in
      color.blended(withFraction: dark ? 0.20 : 0.40, of: dark ? .white : .black) ?? color
    }
  }

  private static func dynamicColor(_ role: String, resolve: @escaping (Bool) -> NSColor) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name("MacPhilosophy.\(role)")) { appearance in
      var result = NSColor.labelColor
      appearance.performAsCurrentDrawingAppearance {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        result = resolve(dark)
      }
      return result
    })
  }

  // Existing repeated desktop metrics, kept stable during visual convergence.
  static let controlFont = Font.system(size: 12, weight: .medium)
  static let labelFont = Font.system(size: 13, weight: .semibold)
  static let detailFont = Font.system(size: 11, weight: .medium)
  static let panelInset: CGFloat = 16
}
