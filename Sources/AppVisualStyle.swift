import AppKit
import SwiftUI

/// Brand system 3.0 · endorsed product · native-paper.
/// Product assets carry identity; native semantic roles carry interaction and status.
/// Aqua remains intentional until every main and auxiliary window has a verified dark palette.
enum AppVisualStyle {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
  static let textPrimary = Color(nsColor: .labelColor)
  static let textSecondary = Color(
    nsColor: NSColor.secondaryLabelColor.blended(withFraction: 0.20, of: .labelColor)
      ?? .secondaryLabelColor
  )
  static let separator = Color(nsColor: .separatorColor)
  static let accent = Color(nsColor: .selectedContentBackgroundColor)
  static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
  static let hover = Color(nsColor: .labelColor).opacity(0.04)
  static let success = statusInk(.systemGreen)
  static let warning = statusInk(.systemOrange)
  static let danger = statusInk(.systemRed)

  // Aqua status ink retains the system hue while remaining legible in small labels.
  // The unmodified system green/orange are intended for larger indicators on this surface.
  private static func statusInk(_ color: NSColor) -> Color {
    Color(nsColor: color.blended(withFraction: 0.40, of: .black) ?? color)
  }

  // Existing repeated desktop metrics, kept stable during visual convergence.
  static let controlFont = Font.system(size: 12, weight: .medium)
  static let labelFont = Font.system(size: 13, weight: .semibold)
  static let detailFont = Font.system(size: 11, weight: .medium)
  static let panelInset: CGFloat = 16
}
