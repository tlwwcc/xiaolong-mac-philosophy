import Foundation

enum RetiredShiftInputSourcePreferences {
  static let keys: Set<String> = [
    "shiftInputSourceToggleEnabledV1",
    "shiftInputSourceChineseSelectionIDV1",
    "shiftInputSourceLastChineseSelectionIDV1",
    "shiftInputSourceIndicatorEnabledV1",
    "shiftInputSourceSwitchModeV2",
  ]

  static func purge(from defaults: UserDefaults = .standard) {
    for key in keys {
      defaults.removeObject(forKey: key)
    }
    defaults.synchronize()
  }
}
