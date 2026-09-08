import AppKit

/// A frozen registration snapshot, read only by the existing event-tap generation.
struct CommandWProtectionPolicy {
  static let defaultsKey = "commandWProtectionBundleIDs"
  let bundleIDs: Set<String>

  static func load(defaults: UserDefaults = .standard) -> Self {
    Self(bundleIDs: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
  }

  func blocks(keyCode: UInt32, flags: CGEventFlags, bundleID: String?) -> Bool {
    let modifiers: CGEventFlags = [
      .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
    ]
    guard keyCode == 13, flags.intersection(modifiers) == .maskCommand,
      let bundleID
    else { return false }
    return bundleIDs.contains(bundleID)
  }
}
