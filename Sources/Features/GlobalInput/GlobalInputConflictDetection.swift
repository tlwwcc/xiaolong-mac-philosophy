import AppKit
import Foundation

enum CapsCoreConflict: Equatable {
  case standaloneApp
  case karabinerRule

  var displayText: String {
    switch self {
    case .standaloneApp: return "小龙哥 Caps 正在运行"
    case .karabinerRule: return "Karabiner 已有同类规则"
    }
  }

  var detailText: String {
    switch self {
    case .standaloneApp:
      return "为避免重复映射，主 App 已停止监听。请只保留一个 Caps 开关。"
    case .karabinerRule:
      return "为避免重复映射，主 App 已停止监听。请先关闭 Karabiner 的 Caps 规则。"
    }
  }
}

enum CapsCorePluginStatus: Equatable {
  case stopped
  case running
  case paused
  case waitingForPermission(String)
  case conflict(CapsCoreConflict)
  case failed(String)

  var displayText: String {
    switch self {
    case .stopped: return "已关闭"
    case .running: return "监听中"
    case .paused: return "已暂停"
    case .waitingForPermission: return "待授权"
    case .conflict: return "冲突，已停止"
    case .failed: return "启动失败"
    }
  }

  var detailText: String {
    switch self {
    case .stopped: return "关闭时不会监听 Caps Lock。"
    case .running: return "按住 Caps Lock 等于按住左 Control + 左 Option。"
    case .paused: return "后台快捷键已暂停，Caps 监听同时停止。"
    case .waitingForPermission(let message),
      .failed(let message):
      return message
    case .conflict(let conflict): return conflict.detailText
    }
  }
}

@MainActor
enum GlobalInputConflictDetection {
  private static var karabinerCapsRuleCache: (mtime: TimeInterval, hasRule: Bool)?
  static func current() -> CapsCoreConflict? {
    if NSWorkspace.shared.runningApplications.contains(where: {
      !$0.isTerminated && $0.bundleIdentifier == "cn.tlww.aixlg.capscore"
    }) {
      return .standaloneApp
    }
    guard karabinerCoreServiceIsRunning(), karabinerConfigHasCapsCoreRule() else { return nil }
    return .karabinerRule
  }
  private static func karabinerCoreServiceIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
      guard !app.isTerminated else { return false }
      if app.bundleIdentifier == "org.pqrs.Karabiner-Core-Service" { return true }
      return (app.localizedName ?? "").localizedCaseInsensitiveContains("Karabiner-Core-Service")
    }
  }
  private static func karabinerConfigHasCapsCoreRule() -> Bool {
    let url = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".config/karabiner/karabiner.json")
    let mtime =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)??
      .timeIntervalSince1970 ?? 0
    if let cache = karabinerCapsRuleCache, cache.mtime == mtime {
      return cache.hasRule
    }
    let hasRule =
      (try? LocalConfigurationFileCodec.readData(from: url)).map {
        CapsCoreKarabinerRuleDetector.selectedProfileHasCapsMapping(data: $0)
      } ?? false
    karabinerCapsRuleCache = (mtime, hasRule)
    return hasRule
  }
}
