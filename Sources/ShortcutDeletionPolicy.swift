import Foundation

enum ShortcutDeletionDisabledReason: Equatable {
  case missingRecovery

  var message: String {
    switch self {
    case .missingRecovery:
      return "这条内置快捷键没有可验证的恢复入口，不能删除。"
    }
  }
}

enum ShortcutDeletionDecision: Equatable {
  case allowed(recoveryID: String?)
  case disabled(ShortcutDeletionDisabledReason)

  var canDelete: Bool {
    if case .allowed = self { return true }
    return false
  }

  var recoveryID: String? {
    guard case .allowed(let recoveryID) = self else { return nil }
    return recoveryID
  }

  var disabledMessage: String? {
    guard case .disabled(let reason) = self else { return nil }
    return reason.message
  }
}

enum ShortcutDeletionPolicy {
  static func decision(
    isAppManaged: Bool,
    isUserDefined: Bool,
    isFixedFeature: Bool,
    recoveryID: String?
  ) -> ShortcutDeletionDecision {
    if isFixedFeature {
      guard let recoveryID, !recoveryID.isEmpty else {
        return .disabled(.missingRecovery)
      }
      return .allowed(recoveryID: recoveryID)
    }
    if isUserDefined || !isAppManaged {
      return .allowed(recoveryID: nil)
    }
    guard let recoveryID, !recoveryID.isEmpty else {
      return .disabled(.missingRecovery)
    }
    return .allowed(recoveryID: recoveryID)
  }
}

enum ShortcutActionMutationDecision: Equatable {
  case blockedFixedFeature
  case preserveOwnership
  case convertManagedDefaultToUserRule
}

enum ShortcutActionMutationPolicy {
  static func decision(
    isFixedFeature: Bool,
    isAppManaged: Bool,
    changesSemanticAction: Bool
  ) -> ShortcutActionMutationDecision {
    if isFixedFeature {
      return .blockedFixedFeature
    }
    if isAppManaged && changesSemanticAction {
      return .convertManagedDefaultToUserRule
    }
    return .preserveOwnership
  }
}

enum ShortcutLegacyRecoveryRepairDecision: Equatable {
  case keepManagedDefault
  case restoreFixedFeatureOwnership
  case convertToUserRule(markDefaultDeleted: Bool)
}

enum ShortcutLegacyRecoveryRepairPolicy {
  static func decision(
    isFixedFeature: Bool,
    matchesCanonicalAction: Bool
  ) -> ShortcutLegacyRecoveryRepairDecision {
    if matchesCanonicalAction {
      return isFixedFeature ? .restoreFixedFeatureOwnership : .keepManagedDefault
    }
    return .convertToUserRule(markDefaultDeleted: !isFixedFeature)
  }
}

enum ShortcutDuplicateManagedIdentityDecision: Equatable {
  case removeDuplicate
  case convertToUserRule
}

enum ShortcutDuplicateManagedIdentityPolicy {
  static func decision(
    isFixedFeature: Bool,
    hasSameSemanticActionAndHotkey: Bool
  ) -> ShortcutDuplicateManagedIdentityDecision {
    isFixedFeature || hasSameSemanticActionAndHotkey
      ? .removeDuplicate : .convertToUserRule
  }
}

enum ShortcutRecoveryIdentity {
  static let clipboardHistory = "core.clipboard-history"
  static let networkProbe = "core.network-probe"
  static let processViewer = "core.process-viewer"
  static let sleepManagement = "core.sleep-management"

  static func featureCommandID(from recoveryID: String?) -> String? {
    guard let recoveryID, recoveryID.hasPrefix("feature.") else { return nil }
    let commandID = String(recoveryID.dropFirst("feature.".count))
    return commandID.isEmpty ? nil : commandID
  }

  static func make(
    commandID: String?,
    actionID: String,
    target: String
  ) -> String {
    if let commandID, !commandID.isEmpty {
      return "feature.\(commandID)"
    }
    switch actionID {
    case "showClipboardHistory": return clipboardHistory
    case "showCodexNetworkProbe": return networkProbe
    case "showProcessViewer": return processViewer
    case "showSleepPanel": return sleepManagement
    default:
      return "default.\(actionID).\(target)"
    }
  }

  static func deletionNameAliases(
    recoveryID: String?,
    primaryName: String
  ) -> Set<String> {
    var names = Set([primaryName])
    if recoveryID == networkProbe {
      names.insert("打开测试网速")
    } else if recoveryID == clipboardHistory {
      names.insert("打开剪贴板历史")
    } else if recoveryID == sleepManagement {
      names.formUnion(["打开睡眠面板", "睡眠面板", "保持唤醒", "切换无限保持唤醒"])
    } else if recoveryID
      == make(commandID: nil, actionID: "windowPreset", target: "maximize")
    {
      names.formUnion(["窗口最大化", "窗口化全屏"])
    }
    return names
  }
}
