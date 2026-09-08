import AppKit
import Foundation

enum DockPresencePreference {
  static let defaultsKey = "showDockIconV1"

  static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: defaultsKey) != nil else { return false }
    return defaults.bool(forKey: defaultsKey)
  }

  static func activationPolicy(forVisibleDockIcon visible: Bool) -> NSApplication.ActivationPolicy {
    visible ? .regular : .accessory
  }

  @discardableResult
  @MainActor
  static func apply(
    visible: Bool,
    application: NSApplication? = nil
  ) -> Bool {
    (application ?? .shared).setActivationPolicy(activationPolicy(forVisibleDockIcon: visible))
  }

  static func save(_ visible: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(visible, forKey: defaultsKey)
  }
}
