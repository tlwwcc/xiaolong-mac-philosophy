import Foundation

enum SettingsNavigationPolicy {
  static let general = "通用"
  static let permissions = "权限"
  static let about = "关于与更新"
  static let automation = "CLI"
  static let updates = about

  static func normalized(_ section: String?) -> String {
    guard let section else { return general }
    switch section {
    case general, permissions, about, automation:
      return section
    case "AI 与命令行", "AI命令", "AI 命令":
      return automation
    case "关于", "软件更新", "更新与许可", "更新与创始会员":
      return updates
    case "设置":
      return general
    default:
      return general
    }
  }
}
