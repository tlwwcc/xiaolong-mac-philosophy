import Foundation

struct AuthorizationPermissionSnapshot: Equatable {
  let accessibility: Bool
  let inputMonitoring: Bool
  let screenRecording: Bool

  init(
    accessibility: Bool,
    inputMonitoring: Bool,
    screenRecording: Bool = false
  ) {
    self.accessibility = accessibility
    self.inputMonitoring = inputMonitoring
    self.screenRecording = screenRecording
  }

  var allEventTapPermissionsGranted: Bool {
    accessibility && inputMonitoring
  }

  var allRequiredPermissionsGranted: Bool {
    accessibility && screenRecording && inputMonitoring
  }
}

enum AuthorizationRepairService: String, CaseIterable, Equatable {
  case accessibility = "Accessibility"
  case screenRecording = "ScreenCapture"
  case inputMonitoring = "ListenEvent"

  var displayName: String {
    switch self {
    case .accessibility: return "辅助功能"
    case .screenRecording: return "屏幕录制"
    case .inputMonitoring: return "输入监控"
    }
  }

  var mayRequireRelaunch: Bool {
    switch self {
    case .screenRecording, .inputMonitoring: return true
    case .accessibility: return false
    }
  }

  func isGranted(in snapshot: AuthorizationPermissionSnapshot) -> Bool {
    switch self {
    case .accessibility: return snapshot.accessibility
    case .screenRecording: return snapshot.screenRecording
    case .inputMonitoring: return snapshot.inputMonitoring
    }
  }
}

struct AuthorizationRecoveryPolicy {
  static func servicesEligibleForRepair(
    isInstalledInApplications: Bool,
    snapshot: AuthorizationPermissionSnapshot,
    explicitRecheckFailed: Bool
  ) -> [AuthorizationRepairService] {
    guard isInstalledInApplications, explicitRecheckFailed else { return [] }
    return AuthorizationRepairService.allCases.filter { !$0.isGranted(in: snapshot) }
  }

  static func servicesEligibleForExplicitClear(
    isInstalledInApplications: Bool,
    bundleIdentifier: String,
    expectedBundleIdentifier: String,
    userConfirmed: Bool
  ) -> [AuthorizationRepairService] {
    guard isInstalledInApplications,
      bundleIdentifier == expectedBundleIdentifier,
      userConfirmed
    else {
      return []
    }
    return AuthorizationRepairService.allCases
  }

  static func targetedResetArguments(
    service: AuthorizationRepairService,
    bundleIdentifier: String
  ) -> [String] {
    ["reset", service.rawValue, bundleIdentifier]
  }

  static func remainingRepairServices(
    _ services: [AuthorizationRepairService],
    snapshot: AuthorizationPermissionSnapshot
  ) -> [AuthorizationRepairService] {
    services.filter { !$0.isGranted(in: snapshot) }
  }
}

struct AuthorizationRelaunchStatePolicy {
  static func processAlreadyRelaunched(
    flowOwnerProcessIdentifier: Int32?,
    currentProcessIdentifier: Int32
  ) -> Bool {
    guard let flowOwnerProcessIdentifier, flowOwnerProcessIdentifier > 0 else {
      return false
    }
    return flowOwnerProcessIdentifier != currentProcessIdentifier
  }
}

enum AuthorizationRelaunchAttemptPhase: Equatable {
  case ready
  case automaticRelaunchRequested
  case manualRelaunchRequired
  case finished
}

enum AuthorizationRelaunchAttemptEvent: Equatable {
  case requestAutomaticRelaunch
  case automaticRelaunchFailed
  case relaunchedProcessVerified
  case reset
}

enum AuthorizationRelaunchAttemptEffect: Equatable {
  case beginAutomaticRelaunch
  case showManualRelaunchOnly
  case finish
}

/// One gate owns every authorization restart trigger. The system prompt detector and the
/// all-permissions preflight can race, but the old process may request termination only once.
struct AuthorizationRelaunchAttemptStateMachine {
  private(set) var phase: AuthorizationRelaunchAttemptPhase = .ready

  @discardableResult
  mutating func handle(
    _ event: AuthorizationRelaunchAttemptEvent
  ) -> AuthorizationRelaunchAttemptEffect? {
    switch event {
    case .requestAutomaticRelaunch:
      guard phase == .ready else { return nil }
      phase = .automaticRelaunchRequested
      return .beginAutomaticRelaunch
    case .automaticRelaunchFailed:
      guard phase == .ready || phase == .automaticRelaunchRequested else { return nil }
      phase = .manualRelaunchRequired
      return .showManualRelaunchOnly
    case .relaunchedProcessVerified:
      guard phase != .finished else { return nil }
      phase = .finished
      return .finish
    case .reset:
      phase = .ready
      return nil
    }
  }
}

enum AuthorizationFlowContinuation: Equatable {
  case inactive
  case continueWith(AuthorizationRepairService)
  case awaitRelaunch
  case finished
}

struct AuthorizationFlowContinuationPolicy {
  static func next(
    pendingServices: [AuthorizationRepairService],
    snapshot: AuthorizationPermissionSnapshot,
    requiresRelaunch: Bool,
    processAlreadyRelaunched: Bool
  ) -> AuthorizationFlowContinuation {
    guard !pendingServices.isEmpty else { return .inactive }
    if let nextService = AuthorizationRecoveryPolicy.remainingRepairServices(
      pendingServices,
      snapshot: snapshot
    ).first {
      return .continueWith(nextService)
    }
    if requiresRelaunch && !processAlreadyRelaunched {
      return .awaitRelaunch
    }
    return .finished
  }
}

struct AuthorizationRelaunchPresentationPolicy {
  static let maximumRequestAge: TimeInterval = 10 * 60

  static func shouldPresent(
    sourceProcessIdentifier: Int32?,
    currentProcessIdentifier: Int32,
    requestedAt: TimeInterval?,
    now: TimeInterval
  ) -> Bool {
    guard let sourceProcessIdentifier, sourceProcessIdentifier > 0,
      sourceProcessIdentifier != currentProcessIdentifier,
      let requestedAt,
      requestedAt > 0
    else {
      return false
    }
    let age = now - requestedAt
    return age >= 0 && age <= maximumRequestAge
  }
}

struct AuthorizationListenerVerification: Equatable {
  let required: [String]
  let failed: [String]

  var succeeded: Bool {
    failed.isEmpty
  }
}

enum AuthorizationHotReloadDecision: Equatable {
  case permissionsIncomplete
  case hotReloadSucceeded
  case retryHotReload(attempt: Int)
  case scheduleSingleRelaunch
  case manualRelaunchRequired
}

struct AuthorizationHotReloadStateMachine {
  static let maximumHotReloadAttempts = 4

  private(set) var permissions: AuthorizationPermissionSnapshot
  private(set) var hotReloadAttempt = 0
  private(set) var relaunchAttemptedForCurrentGrant: Bool

  init(
    permissions: AuthorizationPermissionSnapshot,
    relaunchAttemptedForCurrentGrant: Bool = false
  ) {
    self.permissions = permissions
    self.relaunchAttemptedForCurrentGrant = relaunchAttemptedForCurrentGrant
  }

  mutating func observe(_ next: AuthorizationPermissionSnapshot) -> Bool {
    let changed = next != permissions
    permissions = next
    if !next.allEventTapPermissionsGranted {
      hotReloadAttempt = 0
      relaunchAttemptedForCurrentGrant = false
    }
    return changed
  }

  mutating func recordReload(
    verification: AuthorizationListenerVerification
  ) -> AuthorizationHotReloadDecision {
    guard permissions.allEventTapPermissionsGranted else {
      hotReloadAttempt = 0
      return .permissionsIncomplete
    }
    if verification.succeeded {
      hotReloadAttempt = 0
      relaunchAttemptedForCurrentGrant = false
      return .hotReloadSucceeded
    }

    hotReloadAttempt += 1
    if hotReloadAttempt < Self.maximumHotReloadAttempts {
      return .retryHotReload(attempt: hotReloadAttempt + 1)
    }
    guard !relaunchAttemptedForCurrentGrant else {
      return .manualRelaunchRequired
    }
    relaunchAttemptedForCurrentGrant = true
    return .scheduleSingleRelaunch
  }

  mutating func markRelaunchAttempted() {
    relaunchAttemptedForCurrentGrant = true
  }
}
