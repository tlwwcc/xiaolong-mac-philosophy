import Foundation
import PlatformContracts

public enum FeatureRegistryError: Error, Equatable {
  case invalidIdentifier(kind: String, value: String)
  case invalidManifestVersion(featureID: FeatureID, value: Int)
  case invalidSettingsSchemaVersion(featureID: FeatureID, value: Int)
  case blankDisplayName(featureID: FeatureID)
  case blankSummary(featureID: FeatureID)
  case duplicateFeatureID(FeatureID)
  case duplicateCommandID(CommandID)
  case duplicateWindowID(WindowID)
  case duplicateOperationID(OperationID)
  case duplicatePermissionID(PermissionID)
  case duplicateEntitlementID(EntitlementID)
  case unsupportedPermissionID(PermissionID)
  case unsupportedEntitlementID(EntitlementID)
  case emptyEntitlementAlternatives(featureID: FeatureID)
  case commandNotOwned(featureID: FeatureID, commandID: CommandID)
  case windowNotOwned(featureID: FeatureID, windowID: WindowID)
  case operationNotOwned(featureID: FeatureID, operationID: OperationID)
  case unknownFeatureID(FeatureID)
}

extension FeatureRegistryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier(let kind, let value):
      return "\(kind) 使用了不稳定的标识：\(value)"
    case .invalidManifestVersion(let featureID, let value):
      return "\(featureID.rawValue) 的 manifestVersion 必须从 1 开始，当前为 \(value)。"
    case .invalidSettingsSchemaVersion(let featureID, let value):
      return "\(featureID.rawValue) 的 settingsSchemaVersion 必须从 1 开始，当前为 \(value)。"
    case .blankDisplayName(let featureID):
      return "\(featureID.rawValue) 缺少用户可见名称。"
    case .blankSummary(let featureID):
      return "\(featureID.rawValue) 缺少一句话用途说明。"
    case .duplicateFeatureID(let id):
      return "重复注册功能：\(id.rawValue)"
    case .duplicateCommandID(let id):
      return "重复注册命令：\(id.rawValue)"
    case .duplicateWindowID(let id):
      return "重复注册窗口：\(id.rawValue)"
    case .duplicateOperationID(let id):
      return "重复注册操作：\(id.rawValue)"
    case .duplicatePermissionID(let id):
      return "重复声明权限：\(id.rawValue)"
    case .duplicateEntitlementID(let id):
      return "重复声明权益：\(id.rawValue)"
    case .unsupportedPermissionID(let id):
      return "平台尚未登记权限：\(id.rawValue)"
    case .unsupportedEntitlementID(let id):
      return "平台尚未登记权益：\(id.rawValue)"
    case .emptyEntitlementAlternatives(let featureID):
      return "\(featureID.rawValue) 的付费策略至少需要一个候选权益。"
    case .commandNotOwned(let featureID, let commandID):
      return "\(commandID.rawValue) 不属于 \(featureID.rawValue) 的命名空间。"
    case .windowNotOwned(let featureID, let windowID):
      return "\(windowID.rawValue) 不属于 \(featureID.rawValue) 的命名空间。"
    case .operationNotOwned(let featureID, let operationID):
      return "\(operationID.rawValue) 不属于 \(featureID.rawValue) 的命名空间。"
    case .unknownFeatureID(let id):
      return "功能尚未注册：\(id.rawValue)"
    }
  }
}

public struct FeatureEntitlementRouter: EntitlementChecking {
  public typealias DecisionProvider =
    @Sendable (FeatureEntitlementRequest) -> FeatureAccessDecision

  private let decisionProvider: DecisionProvider

  public init(decisionProvider: @escaping DecisionProvider) {
    self.decisionProvider = decisionProvider
  }

  public func decision(for request: FeatureEntitlementRequest) -> FeatureAccessDecision {
    decisionProvider(request)
  }
}

public struct FeaturePermissionRouter: PermissionChecking {
  public typealias DecisionProvider =
    @Sendable (FeaturePermissionRequest) -> FeatureAccessDecision

  private let decisionProvider: DecisionProvider

  public init(decisionProvider: @escaping DecisionProvider) {
    self.decisionProvider = decisionProvider
  }

  public func decision(for request: FeaturePermissionRequest) -> FeatureAccessDecision {
    decisionProvider(request)
  }
}

public struct FeatureAccessScope: Sendable {
  public let manifest: FeatureManifest

  private let entitlementChecker: any EntitlementChecking
  private let permissionChecker: any PermissionChecking

  init(
    manifest: FeatureManifest,
    entitlementChecker: any EntitlementChecking,
    permissionChecker: any PermissionChecking
  ) {
    self.manifest = manifest
    self.entitlementChecker = entitlementChecker
    self.permissionChecker = permissionChecker
  }

  public func decision(for action: FeatureAccessAction) -> FeatureAccessDecision {
    guard owns(action) else {
      return .denied("插件试图执行未在自身清单声明的动作。")
    }
    let requirements = resolvedRequirements(for: action)
    switch requirements.accessPolicy {
    case .free:
      break
    case .anyOf(let entitlementIDs):
      var firstDenialReason: String?
      var hasMatchingEntitlement = false
      for entitlementID in entitlementIDs {
        let decision = entitlementChecker.decision(
          for: FeatureEntitlementRequest(
            featureID: manifest.id,
            entitlementID: entitlementID,
            action: action
          )
        )
        if decision.isAllowed {
          hasMatchingEntitlement = true
          break
        }
        if firstDenialReason == nil {
          firstDenialReason = decision.denialReason
        }
      }
      guard hasMatchingEntitlement else {
        return .entitlementDenied(
          entitlementIDs,
          firstDenialReason ?? "没有满足此插件所需的权益。"
        )
      }
    }
    for permissionID in requirements.requiredPermissions {
      let decision = permissionChecker.decision(
        for: FeaturePermissionRequest(
          featureID: manifest.id,
          permissionID: permissionID,
          action: action
        )
      )
      guard decision.isAllowed else {
        return .permissionDenied(
          permissionID,
          decision.denialReason ?? "需要开启必要的系统权限。"
        )
      }
    }
    return .allowed
  }

  fileprivate func owns(_ action: FeatureAccessAction) -> Bool {
    switch action {
    case .start:
      return true
    case .execute(let id):
      return manifest.commands.contains(where: { $0.id == id })
    case .open(let id):
      return manifest.windows.contains(where: { $0.id == id })
    case .perform(let id):
      return manifest.operations.contains(where: { $0.id == id })
    }
  }

  private func resolvedRequirements(
    for action: FeatureAccessAction
  ) -> (requiredPermissions: [PermissionID], accessPolicy: FeatureAccessPolicy) {
    switch action {
    case .start:
      return (manifest.requiredPermissions, manifest.accessPolicy)
    case .open(let id):
      guard let window = manifest.windows.first(where: { $0.id == id }) else {
        return (manifest.requiredPermissions, manifest.accessPolicy)
      }
      return (
        window.requiredPermissions ?? manifest.requiredPermissions,
        window.accessPolicy ?? manifest.accessPolicy
      )
    case .execute(let id):
      guard let command = manifest.commands.first(where: { $0.id == id }) else {
        return (manifest.requiredPermissions, manifest.accessPolicy)
      }
      return (
        command.requiredPermissions ?? manifest.requiredPermissions,
        command.accessPolicy ?? manifest.accessPolicy
      )
    case .perform(let id):
      guard let operation = manifest.operations.first(where: { $0.id == id }) else {
        return (manifest.requiredPermissions, manifest.accessPolicy)
      }
      return (
        operation.requiredPermissions ?? manifest.requiredPermissions,
        operation.accessPolicy ?? manifest.accessPolicy
      )
    }
  }
}

public struct FeatureRegistryBuilder {
  private var orderedFeatureIDs: [FeatureID] = []
  private var manifestsByID: [FeatureID: FeatureManifest] = [:]
  private var commandOwners: [CommandID: FeatureID] = [:]
  private var windowOwners: [WindowID: FeatureID] = [:]
  private var operationOwners: [OperationID: FeatureID] = [:]
  private let entitlementChecker: any EntitlementChecking
  private let permissionChecker: any PermissionChecking

  public init(
    entitlementChecker: any EntitlementChecking,
    permissionChecker: any PermissionChecking
  ) {
    self.entitlementChecker = entitlementChecker
    self.permissionChecker = permissionChecker
  }

  public mutating func register(_ module: any FeatureModule) throws {
    try register(module.manifest)
  }

  public mutating func register(_ manifest: FeatureManifest) throws {
    try validate(manifest)

    guard manifestsByID[manifest.id] == nil else {
      throw FeatureRegistryError.duplicateFeatureID(manifest.id)
    }
    for command in manifest.commands {
      guard commandOwners[command.id] == nil else {
        throw FeatureRegistryError.duplicateCommandID(command.id)
      }
    }
    for window in manifest.windows {
      guard windowOwners[window.id] == nil else {
        throw FeatureRegistryError.duplicateWindowID(window.id)
      }
    }
    for operation in manifest.operations {
      guard operationOwners[operation.id] == nil else {
        throw FeatureRegistryError.duplicateOperationID(operation.id)
      }
    }

    manifestsByID[manifest.id] = manifest
    orderedFeatureIDs.append(manifest.id)
    for command in manifest.commands {
      commandOwners[command.id] = manifest.id
    }
    for window in manifest.windows {
      windowOwners[window.id] = manifest.id
    }
    for operation in manifest.operations {
      operationOwners[operation.id] = manifest.id
    }
  }

  public func build() -> FeatureRegistry {
    FeatureRegistry(
      orderedFeatureIDs: orderedFeatureIDs,
      manifestsByID: manifestsByID,
      commandOwners: commandOwners,
      windowOwners: windowOwners,
      operationOwners: operationOwners,
      entitlementChecker: entitlementChecker,
      permissionChecker: permissionChecker
    )
  }

  private func validate(_ manifest: FeatureManifest) throws {
    try validateFeatureIdentifier(manifest.id)
    guard manifest.manifestVersion >= 1 else {
      throw FeatureRegistryError.invalidManifestVersion(
        featureID: manifest.id,
        value: manifest.manifestVersion
      )
    }
    guard manifest.settingsSchemaVersion >= 1 else {
      throw FeatureRegistryError.invalidSettingsSchemaVersion(
        featureID: manifest.id,
        value: manifest.settingsSchemaVersion
      )
    }
    guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FeatureRegistryError.blankDisplayName(featureID: manifest.id)
    }
    guard !manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FeatureRegistryError.blankSummary(featureID: manifest.id)
    }

    try validatePermissions(manifest.requiredPermissions)
    try validateAccessPolicy(manifest.accessPolicy, featureID: manifest.id)
    try validateUnique(manifest.commands.map(\.id)) {
      FeatureRegistryError.duplicateCommandID($0)
    }
    try validateUnique(manifest.windows.map(\.id)) {
      FeatureRegistryError.duplicateWindowID($0)
    }
    try validateUnique(manifest.operations.map(\.id)) {
      FeatureRegistryError.duplicateOperationID($0)
    }

    for command in manifest.commands {
      try validateIdentifier(kind: "CommandID", value: command.id.rawValue)
      guard
        isOwnedIdentifier(
          value: command.id.rawValue,
          featureID: manifest.id,
          namespace: "command"
        )
      else {
        throw FeatureRegistryError.commandNotOwned(
          featureID: manifest.id,
          commandID: command.id
        )
      }
      if let requiredPermissions = command.requiredPermissions {
        try validatePermissions(requiredPermissions)
      }
      if let accessPolicy = command.accessPolicy {
        try validateAccessPolicy(accessPolicy, featureID: manifest.id)
      }
    }
    for window in manifest.windows {
      try validateIdentifier(kind: "WindowID", value: window.id.rawValue)
      guard
        isOwnedIdentifier(
          value: window.id.rawValue,
          featureID: manifest.id,
          namespace: "window"
        )
      else {
        throw FeatureRegistryError.windowNotOwned(
          featureID: manifest.id,
          windowID: window.id
        )
      }
      if let requiredPermissions = window.requiredPermissions {
        try validatePermissions(requiredPermissions)
      }
      if let accessPolicy = window.accessPolicy {
        try validateAccessPolicy(accessPolicy, featureID: manifest.id)
      }
    }
    for operation in manifest.operations {
      try validateIdentifier(kind: "OperationID", value: operation.id.rawValue)
      guard
        isOwnedIdentifier(
          value: operation.id.rawValue,
          featureID: manifest.id,
          namespace: "operation"
        )
      else {
        throw FeatureRegistryError.operationNotOwned(
          featureID: manifest.id,
          operationID: operation.id
        )
      }
      if let requiredPermissions = operation.requiredPermissions {
        try validatePermissions(requiredPermissions)
      }
      if let accessPolicy = operation.accessPolicy {
        try validateAccessPolicy(accessPolicy, featureID: manifest.id)
      }
    }
  }

  private func validatePermissions(_ permissionIDs: [PermissionID]) throws {
    try validateUnique(permissionIDs) {
      FeatureRegistryError.duplicatePermissionID($0)
    }
    for permissionID in permissionIDs {
      try validateIdentifier(kind: "PermissionID", value: permissionID.rawValue)
      guard PermissionID.supported.contains(permissionID) else {
        throw FeatureRegistryError.unsupportedPermissionID(permissionID)
      }
    }
  }

  private func validateAccessPolicy(
    _ accessPolicy: FeatureAccessPolicy,
    featureID: FeatureID
  ) throws {
    switch accessPolicy {
    case .free:
      return
    case .anyOf(let entitlementIDs):
      guard !entitlementIDs.isEmpty else {
        throw FeatureRegistryError.emptyEntitlementAlternatives(featureID: featureID)
      }
      try validateUnique(entitlementIDs) {
        FeatureRegistryError.duplicateEntitlementID($0)
      }
      for entitlementID in entitlementIDs {
        try validateIdentifier(kind: "EntitlementID", value: entitlementID.rawValue)
        guard EntitlementID.supported.contains(entitlementID) else {
          throw FeatureRegistryError.unsupportedEntitlementID(entitlementID)
        }
      }
    }
  }

  private func validateFeatureIdentifier(_ id: FeatureID) throws {
    let prefix = "cn.tlww.aixlg.hotkeys.feature."
    let value = id.rawValue
    guard value.hasPrefix(prefix), value.count <= 160 else {
      throw FeatureRegistryError.invalidIdentifier(kind: "FeatureID", value: value)
    }
    let localName = String(value.dropFirst(prefix.count))
    guard isStableLocalName(localName, allowsDots: false) else {
      throw FeatureRegistryError.invalidIdentifier(kind: "FeatureID", value: value)
    }
  }

  private func validateIdentifier(kind: String, value: String) throws {
    guard isStableIdentifier(value) else {
      throw FeatureRegistryError.invalidIdentifier(kind: kind, value: value)
    }
  }

  private func isStableIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 240 else {
      return false
    }
    var previousWasSeparator = true
    for scalar in value.unicodeScalars {
      let isLowercaseLetter = scalar.value >= 97 && scalar.value <= 122
      let isDigit = scalar.value >= 48 && scalar.value <= 57
      let isSeparator = scalar == "." || scalar == "-"
      if isLowercaseLetter || isDigit {
        previousWasSeparator = false
      } else if isSeparator && !previousWasSeparator {
        previousWasSeparator = true
      } else {
        return false
      }
    }
    return !previousWasSeparator
  }

  private func isOwnedIdentifier(
    value: String,
    featureID: FeatureID,
    namespace: String
  ) -> Bool {
    let prefix = "\(featureID.rawValue).\(namespace)."
    guard value.hasPrefix(prefix) else {
      return false
    }
    return isStableLocalName(
      String(value.dropFirst(prefix.count)),
      allowsDots: true
    )
  }

  private func isStableLocalName(_ value: String, allowsDots: Bool) -> Bool {
    guard !value.isEmpty, value.count <= 80 else {
      return false
    }
    var previousWasSeparator = true
    for scalar in value.unicodeScalars {
      let isLowercaseLetter = scalar.value >= 97 && scalar.value <= 122
      let isDigit = scalar.value >= 48 && scalar.value <= 57
      let isSeparator = scalar == "-" || (allowsDots && scalar == ".")
      if isLowercaseLetter || isDigit {
        previousWasSeparator = false
      } else if isSeparator && !previousWasSeparator {
        previousWasSeparator = true
      } else {
        return false
      }
    }
    return !previousWasSeparator
  }

  private func validateUnique<Value: Hashable>(
    _ values: [Value],
    error: (Value) -> FeatureRegistryError
  ) throws {
    var seen = Set<Value>()
    for value in values where !seen.insert(value).inserted {
      throw error(value)
    }
  }
}

public struct FeatureRegistry: Sendable {
  private let orderedFeatureIDs: [FeatureID]
  private let manifestsByID: [FeatureID: FeatureManifest]
  private let commandOwners: [CommandID: FeatureID]
  private let windowOwners: [WindowID: FeatureID]
  private let operationOwners: [OperationID: FeatureID]
  private let entitlementChecker: any EntitlementChecking
  private let permissionChecker: any PermissionChecking

  fileprivate init(
    orderedFeatureIDs: [FeatureID],
    manifestsByID: [FeatureID: FeatureManifest],
    commandOwners: [CommandID: FeatureID],
    windowOwners: [WindowID: FeatureID],
    operationOwners: [OperationID: FeatureID],
    entitlementChecker: any EntitlementChecking,
    permissionChecker: any PermissionChecking
  ) {
    self.orderedFeatureIDs = orderedFeatureIDs
    self.manifestsByID = manifestsByID
    self.commandOwners = commandOwners
    self.windowOwners = windowOwners
    self.operationOwners = operationOwners
    self.entitlementChecker = entitlementChecker
    self.permissionChecker = permissionChecker
  }

  public var manifests: [FeatureManifest] {
    orderedFeatureIDs.compactMap { manifestsByID[$0] }
  }

  public func manifest(for id: FeatureID) -> FeatureManifest? {
    manifestsByID[id]
  }

  public func owner(of commandID: CommandID) -> FeatureID? {
    commandOwners[commandID]
  }

  public func owner(of windowID: WindowID) -> FeatureID? {
    windowOwners[windowID]
  }

  public func owner(of operationID: OperationID) -> FeatureID? {
    operationOwners[operationID]
  }

  public func accessScope(for id: FeatureID) throws -> FeatureAccessScope {
    guard let manifest = manifestsByID[id] else {
      throw FeatureRegistryError.unknownFeatureID(id)
    }
    return FeatureAccessScope(
      manifest: manifest,
      entitlementChecker: entitlementChecker,
      permissionChecker: permissionChecker
    )
  }
}

public enum FeatureDispatcherConfigurationError: Error, Equatable, Sendable {
  case duplicateHandler(featureID: FeatureID, action: FeatureAccessAction)
  case unknownFeatureID(FeatureID)
  case actionNotOwned(featureID: FeatureID, action: FeatureAccessAction)
}

extension FeatureDispatcherConfigurationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .duplicateHandler(let featureID, let action):
      return "\(featureID.rawValue) 重复登记执行入口：\(action)"
    case .unknownFeatureID(let featureID):
      return "功能尚未注册：\(featureID.rawValue)"
    case .actionNotOwned(let featureID, let action):
      return "\(featureID.rawValue) 不能登记不属于自身的动作：\(action)"
    }
  }
}

public typealias FeatureActionHandler = @Sendable () async throws -> Void

public struct FeatureActionHandlerRegistration: Sendable {
  public let featureID: FeatureID
  public let action: FeatureAccessAction
  fileprivate let handler: FeatureActionHandler

  public init(
    featureID: FeatureID,
    action: FeatureAccessAction,
    handler: @escaping FeatureActionHandler
  ) {
    self.featureID = featureID
    self.action = action
    self.handler = handler
  }
}

public enum FeatureDispatchResult: Equatable, Sendable {
  case executed
  case denied(String)
  case permissionDenied(PermissionID, String)
  case entitlementDenied([EntitlementID], String)

  public var didExecute: Bool {
    if case .executed = self {
      return true
    }
    return false
  }
}

private struct FeatureActionKey: Hashable, Sendable {
  let featureID: FeatureID
  let action: FeatureAccessAction
}

public actor FeatureDispatcher {
  private let registry: FeatureRegistry
  private let handlers: [FeatureActionKey: FeatureActionHandler]

  public init(
    registry: FeatureRegistry,
    handlers registrations: [FeatureActionHandlerRegistration]
  ) throws {
    var handlers: [FeatureActionKey: FeatureActionHandler] = [:]
    for registration in registrations {
      let scope: FeatureAccessScope
      do {
        scope = try registry.accessScope(for: registration.featureID)
      } catch {
        throw FeatureDispatcherConfigurationError.unknownFeatureID(registration.featureID)
      }
      guard scope.owns(registration.action) else {
        throw FeatureDispatcherConfigurationError.actionNotOwned(
          featureID: registration.featureID,
          action: registration.action
        )
      }
      let key = FeatureActionKey(
        featureID: registration.featureID,
        action: registration.action
      )
      guard handlers[key] == nil else {
        throw FeatureDispatcherConfigurationError.duplicateHandler(
          featureID: registration.featureID,
          action: registration.action
        )
      }
      handlers[key] = registration.handler
    }
    self.registry = registry
    self.handlers = handlers
  }

  public func dispatch(
    featureID: FeatureID,
    action: FeatureAccessAction
  ) async throws -> FeatureDispatchResult {
    let scope: FeatureAccessScope
    do {
      scope = try registry.accessScope(for: featureID)
    } catch {
      return .denied("功能尚未注册，动作未执行。")
    }
    guard scope.owns(action) else {
      return .denied("插件试图执行未在自身清单声明的动作。")
    }

    switch scope.decision(for: action) {
    case .allowed:
      break
    case .denied(let reason):
      return .denied(reason)
    case .permissionDenied(let permissionID, let reason):
      return .permissionDenied(permissionID, reason)
    case .entitlementDenied(let entitlementIDs, let reason):
      return .entitlementDenied(entitlementIDs, reason)
    }

    let key = FeatureActionKey(featureID: featureID, action: action)
    guard let handler = handlers[key] else {
      return .denied("动作尚未登记执行入口，未执行。")
    }
    try await handler()
    return .executed
  }
}
