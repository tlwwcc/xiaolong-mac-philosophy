import AppKit
import SwiftUI

/// Window-lifetime presentation only; no user configuration or selection is changed.
@MainActor
final class ShortcutTableViewportStore {
  private var positions: [String: NSPoint] = [:]

  func position(for key: String) -> NSPoint? { positions[key] }
  func save(_ position: NSPoint, for key: String) { positions[key] = position }
}
