import Foundation

public struct FeatureID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public struct CommandID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public struct WindowID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public struct OperationID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public struct PermissionID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public static let accessibility = PermissionID("macos.accessibility")
  public static let inputMonitoring = PermissionID("macos.input-monitoring")
  public static let screenRecording = PermissionID("macos.screen-recording")
  public static let microphone = PermissionID("macos.microphone")
  public static let userSelectedFiles = PermissionID("macos.user-selected-files")
  public static let supported: Set<PermissionID> = [
    .accessibility,
    .inputMonitoring,
    .screenRecording,
    .microphone,
    .userSelectedFiles,
  ]
}

public struct EntitlementID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public static let macFull = EntitlementID("cn.tlww.aixlg.entitlement.mac-full")
  public static let legacyYoumuFull = EntitlementID(
    "cn.tlww.aixlg.entitlement.legacy-youmu-full"
  )
  public static let supported: Set<EntitlementID> = [
    .macFull,
    .legacyYoumuFull,
  ]
}

public enum FeatureCategory: String, Codable, CaseIterable, Sendable {
  case controlMac
  case captureAndUnderstand
  case files
  case listenAndWatch
  case systemUtilities
}

public enum FeatureActivationPolicy: String, Codable, Sendable {
  case onDemand
  case whenEnabled
  case atAppLaunch
}

public enum FeatureAccessPolicy: Codable, Equatable, Sendable {
  case free
  case anyOf([EntitlementID])

  public static let macFullBundledWithHost: FeatureAccessPolicy = .anyOf([.macFull])
  public static let legacyYoumuOrMacFull: FeatureAccessPolicy = .anyOf([
    .legacyYoumuFull,
    .macFull,
  ])
}

public enum FeatureWindowRole: String, Codable, Sendable {
  case primary
  case settings
  case auxiliary
}

public struct FeatureCommandDescriptor: Codable, Equatable, Sendable {
  public let id: CommandID
  public let displayName: String
  public let requiredPermissions: [PermissionID]?
  public let accessPolicy: FeatureAccessPolicy?

  public init(
    id: CommandID,
    displayName: String,
    requiredPermissions: [PermissionID]? = nil,
    accessPolicy: FeatureAccessPolicy? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.requiredPermissions = requiredPermissions
    self.accessPolicy = accessPolicy
  }
}

public struct FeatureWindowDescriptor: Codable, Equatable, Sendable {
  public let id: WindowID
  public let role: FeatureWindowRole
  public let requiredPermissions: [PermissionID]?
  public let accessPolicy: FeatureAccessPolicy?

  public init(
    id: WindowID,
    role: FeatureWindowRole,
    requiredPermissions: [PermissionID]? = nil,
    accessPolicy: FeatureAccessPolicy? = nil
  ) {
    self.id = id
    self.role = role
    self.requiredPermissions = requiredPermissions
    self.accessPolicy = accessPolicy
  }
}

public struct FeatureOperationDescriptor: Codable, Equatable, Sendable {
  public let id: OperationID
  public let displayName: String
  public let requiredPermissions: [PermissionID]?
  public let accessPolicy: FeatureAccessPolicy?

  public init(
    id: OperationID,
    displayName: String,
    requiredPermissions: [PermissionID]? = nil,
    accessPolicy: FeatureAccessPolicy? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.requiredPermissions = requiredPermissions
    self.accessPolicy = accessPolicy
  }
}

public struct FeatureManifest: Codable, Equatable, Sendable {
  public let id: FeatureID
  public let manifestVersion: Int
  public let displayName: String
  public let summary: String
  public let category: FeatureCategory
  public let isEnabledByDefault: Bool
  public let activationPolicy: FeatureActivationPolicy
  public let requiredPermissions: [PermissionID]
  public let accessPolicy: FeatureAccessPolicy
  public let commands: [FeatureCommandDescriptor]
  public let windows: [FeatureWindowDescriptor]
  public let operations: [FeatureOperationDescriptor]
  public let settingsSchemaVersion: Int

  public init(
    id: FeatureID,
    manifestVersion: Int,
    displayName: String,
    summary: String,
    category: FeatureCategory,
    isEnabledByDefault: Bool,
    activationPolicy: FeatureActivationPolicy,
    requiredPermissions: [PermissionID],
    accessPolicy: FeatureAccessPolicy,
    commands: [FeatureCommandDescriptor],
    windows: [FeatureWindowDescriptor],
    operations: [FeatureOperationDescriptor],
    settingsSchemaVersion: Int
  ) {
    self.id = id
    self.manifestVersion = manifestVersion
    self.displayName = displayName
    self.summary = summary
    self.category = category
    self.isEnabledByDefault = isEnabledByDefault
    self.activationPolicy = activationPolicy
    self.requiredPermissions = requiredPermissions
    self.accessPolicy = accessPolicy
    self.commands = commands
    self.windows = windows
    self.operations = operations
    self.settingsSchemaVersion = settingsSchemaVersion
  }
}

public protocol FeatureModule: Sendable {
  var manifest: FeatureManifest { get }
}

public enum FeatureAccessAction: Equatable, Hashable, Sendable {
  case start
  case execute(CommandID)
  case open(WindowID)
  case perform(OperationID)
}

public struct FeaturePermissionRequest: Equatable, Sendable {
  public let featureID: FeatureID
  public let permissionID: PermissionID
  public let action: FeatureAccessAction

  public init(
    featureID: FeatureID,
    permissionID: PermissionID,
    action: FeatureAccessAction
  ) {
    self.featureID = featureID
    self.permissionID = permissionID
    self.action = action
  }
}

public struct FeatureEntitlementRequest: Equatable, Sendable {
  public let featureID: FeatureID
  public let entitlementID: EntitlementID
  public let action: FeatureAccessAction

  public init(
    featureID: FeatureID,
    entitlementID: EntitlementID,
    action: FeatureAccessAction
  ) {
    self.featureID = featureID
    self.entitlementID = entitlementID
    self.action = action
  }
}

public enum FeatureAccessDecision: Equatable, Sendable {
  case allowed
  case denied(String)
  case permissionDenied(PermissionID, String)
  case entitlementDenied([EntitlementID], String)

  public var isAllowed: Bool {
    if case .allowed = self {
      return true
    }
    return false
  }

  public var denialReason: String? {
    switch self {
    case .allowed:
      return nil
    case .denied(let reason),
      .permissionDenied(_, let reason),
      .entitlementDenied(_, let reason):
      return reason
    }
  }
}

public protocol EntitlementChecking: Sendable {
  func decision(for request: FeatureEntitlementRequest) -> FeatureAccessDecision
}

public protocol PermissionChecking: Sendable {
  func decision(for request: FeaturePermissionRequest) -> FeatureAccessDecision
}
