import Foundation

enum AuthorizationGuidePhase: Equatable {
  case drag(serviceDisplayName: String)
  case guidedDrag(serviceDisplayName: String, step: Int, total: Int)
  case systemRelaunch(serviceDisplayName: String, step: Int, total: Int)
  case restartReady
  case restarting
}

struct AuthorizationGuidePresentation: Equatable {
  let stepText: String?
  let title: String
  let subtitle: String
  let symbolName: String
  let accessibilityHelp: String
  let isDraggable: Bool
  let isRegistrationAction: Bool
  let isSystemRelaunchAction: Bool
  let isRestartAction: Bool

  static func make(for phase: AuthorizationGuidePhase) -> AuthorizationGuidePresentation {
    switch phase {
    case .drag(let serviceDisplayName):
      return AuthorizationGuidePresentation(
        stepText: nil,
        title: "将“小龙哥 Mac 哲学”拖进“\(serviceDisplayName)”列表",
        subtitle: "向上拖入列表；松开后打开右侧开关",
        symbolName: "arrow.up.circle.fill",
        accessibilityHelp: "整张卡都可以拖到当前系统权限列表",
        isDraggable: true,
        isRegistrationAction: false,
        isSystemRelaunchAction: false,
        isRestartAction: false)
    case .guidedDrag(let serviceDisplayName, let step, let total):
      return AuthorizationGuidePresentation(
        stepText: "第 \(step)/\(total) 步 · \(serviceDisplayName)",
        title: "列表里没有？拖入或双击这张卡",
        subtitle: "出现“小龙哥 Mac 哲学”后，打开右侧开关",
        symbolName: "hand.draw.fill",
        accessibilityHelp: "拖进当前权限列表，或双击向 macOS 请求登记本 App",
        isDraggable: true,
        isRegistrationAction: true,
        isSystemRelaunchAction: false,
        isRestartAction: false)
    case .systemRelaunch(let serviceDisplayName, let step, let total):
      return AuthorizationGuidePresentation(
        stepText: "第 \(step)/\(total) 步 · \(serviceDisplayName)",
        title: "请在系统提示里点“退出并重新打开”",
        subtitle: "重开后自动继续；若刚点了“稍后”，双击此卡重开",
        symbolName: "arrow.triangle.2.circlepath.circle.fill",
        accessibilityHelp: "在系统提示里退出并重新打开；也可双击此卡重新打开 App",
        isDraggable: false,
        isRegistrationAction: false,
        isSystemRelaunchAction: true,
        isRestartAction: false)
    case .restartReady:
      return AuthorizationGuidePresentation(
        stepText: "最后一步",
        title: "重新打开软件，完成权限验收",
        subtitle: "点此卡重开；新进程会自动核对三项权限",
        symbolName: "arrow.clockwise.circle.fill",
        accessibilityHelp: "点击整张卡重新打开软件",
        isDraggable: false,
        isRegistrationAction: false,
        isSystemRelaunchAction: false,
        isRestartAction: true)
    case .restarting:
      return AuthorizationGuidePresentation(
        stepText: "正在接力",
        title: "正在重新打开软件",
        subtitle: "请稍候，完成后会自动回到授权结果",
        symbolName: "hourglass.circle.fill",
        accessibilityHelp: "软件正在重新打开",
        isDraggable: false,
        isRegistrationAction: false,
        isSystemRelaunchAction: false,
        isRestartAction: false)
    }
  }
}
