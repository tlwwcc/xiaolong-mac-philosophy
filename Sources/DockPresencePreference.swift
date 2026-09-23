import AppKit
import Foundation

enum DockPresencePreference {
  static let defaultsKey = "showDockIconV1"
  /// The product is a normal Dock application. The old menu-bar-only switch was retired; this
  /// marker remains only so upgrades can repair the old hidden state without carrying it forward.
  private static let defaultVisibilityMigrationKey = "dockIconDefaultVisibleV2"

  static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
    true
  }

  /// Repair the retired hidden preference once. Runtime visibility no longer depends on the
  /// stored value, including after importing an older configuration.
  static func migrateLegacyHiddenDefault(in defaults: UserDefaults = .standard) {
    guard defaults.object(forKey: defaultVisibilityMigrationKey) == nil else { return }
    defaults.set(true, forKey: defaultsKey)
    defaults.set(true, forKey: defaultVisibilityMigrationKey)
    defaults.synchronize()
  }

  static func activationPolicy(forVisibleDockIcon visible: Bool) -> NSApplication.ActivationPolicy {
    .regular
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
    defaults.set(true, forKey: defaultsKey)
  }
}
