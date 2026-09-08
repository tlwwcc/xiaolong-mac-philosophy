import AppKit
import Foundation

struct LegacyScrollProfile {
  var installed: Bool
  var running: Bool
  var profileFound: Bool
  var smooth: Bool
  var reverse: Bool
  var speed: Double?
  var step: Double?
  var duration: Double?
  var hideStatusItem: Bool
  var appRuleCount: Int

  static let empty = LegacyScrollProfile(
    installed: FileManager.default.fileExists(atPath: Self.legacyAppURL.path),
    running: false,
    profileFound: false,
    smooth: false,
    reverse: false,
    speed: nil,
    step: nil,
    duration: nil,
    hideStatusItem: false,
    appRuleCount: 0)

  static let legacyBundleID = "com.caldis.Mos"
  static let legacyAppURL = URL(fileURLWithPath: "/Applications/Mos.app")
  static let legacyPlistURL =
    FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/com.caldis.Mos.plist")

  static func load() -> LegacyScrollProfile {
    let installed = FileManager.default.fileExists(atPath: legacyAppURL.path)
    let running = NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == legacyBundleID
    }
    guard
      let data = try? Data(contentsOf: legacyPlistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      return LegacyScrollProfile(
        installed: installed,
        running: running,
        profileFound: false,
        smooth: false,
        reverse: false,
        speed: nil,
        step: nil,
        duration: nil,
        hideStatusItem: false,
        appRuleCount: 0)
    }

    return LegacyScrollProfile(
      installed: installed,
      running: running,
      profileFound: true,
      smooth: bool(plist["smooth"]),
      reverse: bool(plist["reverse"]),
      speed: number(plist["speed"]),
      step: number(plist["step"]),
      duration: number(plist["duration"]),
      hideStatusItem: bool(plist["hideStatusItem"]),
      appRuleCount: appRuleCount(plist["applications"]))
  }

  private static func bool(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
    return false
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Float { return Double(value) }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  private static func appRuleCount(_ value: Any?) -> Int {
    guard let data = value as? Data,
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return 0
    }
    return array.count
  }
}
