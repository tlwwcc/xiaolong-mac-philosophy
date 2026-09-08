import Foundation

enum SettingsNavigationPolicy {
  static let general = "通用"
  static let permissions = "权限"
  static let updates = "更新与许可"
  static let about = "关于"

  static func normalized(_ section: String?) -> String {
    guard let section else { return general }
    switch section {
    case general, permissions, updates, about:
      return section
    case "设置":
      return general
    default:
      return general
    }
  }
}
