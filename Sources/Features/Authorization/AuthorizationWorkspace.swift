import AppKit
import Combine
import Foundation

/// Owns the permission flow; host engines are reached only through narrow main-actor ports.
@MainActor
final class AuthorizationWorkspace: ObservableObject {
  @Published private(set) var advancedListeningAuthorized = false
  @Published private(set) var inputMonitoringAuthorized = false
  @Published private(set) var screenRecordingAuthorized = false
  @Published var isAccessibilityAuthorizationPresented = false
  @Published private(set) var authorizationRelaunchCompleted = false
  @Published private(set) var authorizationAutomaticRelaunchInProgress = false
  @Published private(set) var authorizationManualRelaunchRequired = false
  @Published private(set) var appSignatureSummary = "未检测"
  @Published private(set) var isRepairingAuthorization = false
  @Published private(set) var authorizationRepairResultText = ""
  @Published private(set) var authorizationRecheckFailed = false

  var onStatus: ((String) -> Void)?
  var presentMainWindow: (() -> Void)?
  var requestPolling: ((String) -> Void)?
  var requestTermination: ((AuthorizationTerminationIntent) -> Bool)?
  var featurePermissionsChanged: ((AuthorizationPermissionSnapshot, AuthorizationPermissionSnapshot) -> Void)?
  var refreshCapsConflict: (() -> Void)?
  var reloadListeners: (() -> Void)?
  var listenerVerification: (() -> AuthorizationListenerVerification)?

  private let defaults: UserDefaults
  private let dependencies: Dependencies
  private let context: Context
  private let session = AuthorizationFlowSession()
  var isStopped: Bool { session.isStopped }
  private var authorizationRepairOpenedSettingsService: AuthorizationRepairService?
  private var authorizationRelaunchRelayMarkerURL: URL?
  private var authorizationRelaunchRelayProcess: RelayHandle?
  private var authorizationRelaunchRelayToken: UUID?
  private var authorizationSystemPromptRelaunchScheduled = false
  private var authorizationRegistrationRequestOwner: AuthorizationFlowSession.Token?
  private var authorizationRelaunchAttemptState = AuthorizationRelaunchAttemptStateMachine()
  private var authorizationHotReloadState: AuthorizationHotReloadStateMachine
  private var statusMessage: String {
    get { lastStatus }
    set { guard !isStopped else { return }; lastStatus = newValue; onStatus?(newValue) }
  }
  private var lastStatus = ""
  private final class ProcessTicket {
    var resourceID: UUID?
    var finished = false
  }
  private var appBundleIdentifier: String { context.bundleIdentifier }
  private var appBundlePath: String { context.applicationURL.path }
  private var isInstalledInApplications: Bool { context.isInstalledInApplications }
  private static let pendingAuthorizationRepairServicesDefaultsKey = "pendingAuthorizationRepairServicesV2"
  private static let restartAfterAuthorizationRepairGrantDefaultsKey = "restartAfterAuthorizationRepairGrantV2"
  private static let authorizationFlowOwnerPIDDefaultsKey = "authorizationFlowOwnerPIDV1"
  private static let authorizationHotReloadRelaunchAttemptedDefaultsKey = "authorizationHotReloadRelaunchAttemptedV1"
  private static let authorizationRelaunchPresentationSourcePIDDefaultsKey = "authorizationRelaunchPresentationSourcePIDV1"
  private static let authorizationRelaunchPresentationRequestedAtDefaultsKey = "authorizationRelaunchPresentationRequestedAtV1"
  private static let authorizationLastPromptedMissingFingerprintDefaultsKey = "authorizationLastPromptedMissingFingerprintV1"
  private static let authorizationWasCompleteDefaultsKey = "authorizationWasCompleteV1"

  init(runtimeIdentity: AppRuntimeIdentity, defaults: UserDefaults = .standard,
       dependencies: Dependencies? = nil) {
    let dependencies = dependencies ?? Dependencies()
    self.dependencies = dependencies
    self.defaults = defaults
    self.context = dependencies.context ?? Context.live(runtimeIdentity)
    let snapshot = dependencies.snapshot()
    authorizationHotReloadState = AuthorizationHotReloadStateMachine(
      permissions: snapshot, relaunchAttemptedForCurrentGrant: defaults.bool(
        forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey))
    advancedListeningAuthorized = snapshot.accessibility
    inputMonitoringAuthorized = snapshot.inputMonitoring
    screenRecordingAuthorized = snapshot.screenRecording
    session.issue(.flow)
  }

  func initializePermissions() {
    guard !isStopped else { return }
    refreshAccessibilityStatus()
    authorizationRelaunchCompleted = allRequiredPermissionsComplete
  }

  func shutdown(intent: AuthorizationTerminationIntent = .ordinary) {
    guard !isStopped else { return }
    let keepRelay = intent.relayToken != nil && intent.relayToken == authorizationRelaunchRelayToken
    // Invalidate callback delivery before any cancellation can reenter.
    authorizationRelaunchRelayToken = nil
    authorizationRegistrationRequestOwner = nil
    session.stop()
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
    if keepRelay {
      authorizationRelaunchRelayProcess?.detach()
      authorizationRelaunchRelayProcess = nil
      authorizationRelaunchRelayMarkerURL = nil
    } else {
      disarmAuthorizationRelaunchRelay(reason: "ordinaryShutdown")
    }
  }

  private func runOwnedProcess(
    token: AuthorizationFlowSession.Token, executable: URL, arguments: [String],
    timeout: TimeInterval, limit: Int,
    completion: @escaping @MainActor (BoundedProcessResult) -> Void
  ) {
    guard session.isCurrent(token) else { return }
    let ticket = ProcessTicket()
    let process = dependencies.makeProcess(executable, arguments, timeout, limit) { [weak self] result in
      guard let self, !ticket.finished else { return }
      ticket.finished = true
      if let id = ticket.resourceID { self.session.release(id) }
      guard self.session.isCurrent(token) else { return }
      completion(result)
    }
    guard session.isCurrent(token), !ticket.finished else { process.cancel(); return }
    ticket.resourceID = session.retain(token, cancel: process.cancel)
    guard ticket.resourceID != nil, session.isCurrent(token) else { return }
    process.start()
  }

  private func scheduleFlow(
    after delay: TimeInterval, action: @escaping @MainActor () -> Void
  ) {
    guard let token = session.current(.flow) else { return }
    session.schedule(token, after: delay, scheduler: dependencies.schedule, action: action)
  }

  private func beginFlow() {
    session.issue(.flow)
    session.invalidate(.registration)
    authorizationRegistrationRequestOwner = nil
    session.invalidate(.hotReload)
  }

  private func performPermissionReset(
    services: [AuthorizationRepairService], expectedBundleID: String, explicitClear: Bool
  ) {
    beginFlow()
    guard let token = session.issue(.repair) else { return }
    resetNextPermission(services, position: 0, succeeded: [], failures: [],
      expectedBundleID: expectedBundleID, explicitClear: explicitClear, token: token)
  }

  private func resetNextPermission(
    _ services: [AuthorizationRepairService], position: Int,
    succeeded: [AuthorizationRepairService], failures: [String],
    expectedBundleID: String, explicitClear: Bool, token: AuthorizationFlowSession.Token
  ) {
    guard session.isCurrent(token) else { return }
    guard position < services.count else {
      session.complete(token)
      guard !isStopped else { return }
      isRepairingAuthorization = false
      if !explicitClear { _ = refreshAuthorizationAndReloadIfNeeded() }
      guard !isStopped else { return }
      if !succeeded.isEmpty {
        let names = succeeded.map(\.displayName).joined(separator: "和")
        let failureText = failures.isEmpty ? "" : "；未清除：\(failures.joined(separator: "；"))"
        authorizationRepairResultText = explicitClear
          ? "已清除本 App 的\(names)\(failureText)。正在重启并重新进入授权引导。"
          : "只清除了本 App 当前未生效的\(names)记录\(failureText)。即将自动重启软件，并按顺序直接打开对应系统设置。"
        statusMessage = authorizationRepairResultText
        guard !isStopped else { return }
        isAccessibilityAuthorizationPresented = false
        scheduleAuthorizationRepairRelaunch(pendingServices: succeeded)
      } else {
        authorizationRepairResultText = explicitClear
          ? "清除失败，现有权限没有被改变。\(failures.joined(separator: "；"))"
          : "定向修复失败，未清除任何权限。\(failures.joined(separator: "；"))"
        statusMessage = authorizationRepairResultText
      }
      return
    }
    let service = services[position]
    let prefix = explicitClear ? "authorization_explicit_clear" : "authorization_tcc_reset"
    AppDiagnostics.log("\(prefix)_start", ["bundle": expectedBundleID, "service": service.rawValue])
    runOwnedProcess(token: token, executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
      arguments: AuthorizationRecoveryPolicy.targetedResetArguments(
        service: service, bundleIdentifier: expectedBundleID),
      timeout: 5, limit: 32_768
    ) { [weak self] result in
      guard let self, self.session.isCurrent(token) else { return }
      let detail = [result.standardOutput, result.standardError]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }.joined(separator: " ")
      AppDiagnostics.log("\(prefix)_result", [
        "bundle": expectedBundleID, "service": service.rawValue,
        "exitCode": result.terminationStatus.map(String.init) ?? "unavailable",
        "timedOut": "\(result.timedOut)",
        "truncated": "\(result.outputWasTruncated || result.errorWasTruncated)",
        "launchError": result.launchError ?? "", "detail": detail])
      self.resetNextPermission(services, position: position + 1,
        succeeded: succeeded + (result.succeeded ? [service] : []),
        failures: failures + (result.succeeded ? []
          : ["\(service.displayName)\(explicitClear ? "未能重置" : "未能修复")"]),
        expectedBundleID: expectedBundleID, explicitClear: explicitClear, token: token)
    }
  }

  var permissionTitle: String {
    authorizationPermissionsComplete ? "后台监听权限完整" : "后台监听权限不完整"
  }

  var permissionDetail: String {
    if authorizationPermissionsComplete {
      return "辅助功能和输入监控均已授权。"
    }
    if !advancedListeningAuthorized && !inputMonitoringAuthorized {
      return "普通快捷键仍可用；高级监听需要分别开启辅助功能和输入监控。"
    }
    return advancedListeningAuthorized
      ? "辅助功能已授权，仍需开启输入监控。"
      : "输入监控已授权，仍需开启辅助功能。"
  }

  var authorizationPermissionsComplete: Bool {
    advancedListeningAuthorized && inputMonitoringAuthorized
  }

  var allRequiredPermissionsComplete: Bool {
    authorizationPermissionSnapshot.allRequiredPermissionsGranted
  }

  var authorizationSetupDetail: String {
    let missing = coreAuthorizationServices.filter {
      !$0.isGranted(in: authorizationPermissionSnapshot)
    }
    guard !missing.isEmpty else {
      return "辅助功能、屏幕录制和输入监控均已授权。"
    }
    return "仍需开启\(missing.map(\.displayName).joined(separator: "、"))。"
  }

  private var coreAuthorizationServices: [AuthorizationRepairService] {
    AuthorizationRepairService.allCases
  }

  var authorizationPermissionSnapshot: AuthorizationPermissionSnapshot {
    AuthorizationPermissionSnapshot(
      accessibility: advancedListeningAuthorized,
      inputMonitoring: inputMonitoringAuthorized,
      screenRecording: screenRecordingAuthorized)
  }

  var authorizationRepairServices: [AuthorizationRepairService] {
    AuthorizationRecoveryPolicy.servicesEligibleForRepair(
      isInstalledInApplications: isInstalledInApplications,
      snapshot: authorizationPermissionSnapshot,
      explicitRecheckFailed: authorizationRecheckFailed
    )
  }

  var authorizationNeedsTargetedRepair: Bool {
    !authorizationRepairServices.isEmpty
  }

  var authorizationRepairServiceNames: String {
    authorizationRepairServices.map(\.displayName).joined(separator: "和")
  }

  var authorizationPrimaryButtonTitle: String {
    if authorizationManualRelaunchRequired {
      return "退出软件，随后手动打开"
    }
    if authorizationAutomaticRelaunchInProgress {
      return "正在重新打开..."
    }
    if allRequiredPermissionsComplete {
      return authorizationRelaunchCompleted ? "完成" : "重新打开软件"
    }
    if isRepairingAuthorization { return "正在准备授权..." }
    return "开始授权"
  }

  var authorizationEntryButtonTitle: String {
    allRequiredPermissionsComplete ? "查看权限" : "开始授权"
  }

  var authorizationPrimarySafetyText: String {
    if authorizationManualRelaunchRequired {
      return "授权进度已保存。退出后请从“应用程序”重新打开；不会再回到拖入步骤。"
    }
    if authorizationAutomaticRelaunchInProgress {
      return "正在退出旧进程；新进程会自动续上当前步骤。"
    }
    if allRequiredPermissionsComplete {
      return authorizationRelaunchCompleted
        ? "权限已生效，软件也已重新打开。"
        : "权限已经开启；重新打开后，软件会自动核对三项必要权限。"
    }
    return "软件会依次引导辅助功能、屏幕录制和输入监控；屏幕录制用于截图、识字与译图。"
  }

  var authorizationPrimaryButtonDisabled: Bool {
    isRepairingAuthorization || authorizationAutomaticRelaunchInProgress
  }

  var authorizationOverallStatusText: String {
    if allRequiredPermissionsComplete { return "权限完整" }
    let missing = coreAuthorizationServices.filter {
      !$0.isGranted(in: authorizationPermissionSnapshot)
    }
    if authorizationNeedsTargetedRepair {
      return missing.count == 1 ? "\(missing[0].displayName)需修复" : "\(missing.count) 项需修复"
    }
    return missing.count == 1 ? "待\(missing[0].displayName)" : "待补齐"
  }

  var accessibilityAuthorizationStatusText: String {
    if authorizationPermissionsComplete { return "权限完整" }
    if authorizationNeedsTargetedRepair {
      return authorizationRepairServices.count == 1
        ? "\(authorizationRepairServiceNames)需修复" : "\(authorizationRepairServices.count) 项权限需修复"
    }
    if !advancedListeningAuthorized && !inputMonitoringAuthorized { return "待补齐" }
    return advancedListeningAuthorized ? "待输入监控" : "待辅助功能"
  }

  var accessibilityAuthorizationGuidanceText: String {
    if authorizationPermissionsComplete {
      return "辅助功能和输入监控均已生效，现有授权不会被重复清除。"
    }
    if authorizationNeedsTargetedRepair {
      return
        "系统列表仍显示旧版本，但当前 App 检测到\(authorizationRepairServiceNames)未生效；只修复这些失效项。"
    }
    return permissionDetail
  }

  func presentAuthorizationCenter() {
    guard !isStopped else { return  }
    presentMainWindow?()
    guard !isStopped else { return }
    _ = refreshAuthorizationAndReloadIfNeeded()
    guard !isStopped else { return }
    refreshAppSignatureSummary()
    if authorizationAutomaticRelaunchInProgress {
      isAccessibilityAuthorizationPresented = false
      return
    }
    isAccessibilityAuthorizationPresented = true
    if authorizationManualRelaunchRequired {
      statusMessage = authorizationRepairResultText
    } else if authorizationAutomaticRelaunchInProgress {
      statusMessage = "正在重新打开软件；请稍候。"
    } else if allRequiredPermissionsComplete {
      if pendingAuthorizationRepairServices().isEmpty {
        authorizationRelaunchCompleted = true
      }
      statusMessage = "三项必要权限均已确认。"
    } else {
      statusMessage = authorizationSetupDetail
    }
  }

  @discardableResult
  func presentAuthorizationOnboardingIfNeeded() -> Bool {
    guard !isStopped else { return false }
    refreshAccessibilityStatus()
    if allRequiredPermissionsComplete {
      defaults.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      defaults.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
      return false
    }

    guard isInstalledInApplications, !context.isInvalid else { return false }
    let missingFingerprint =
      coreAuthorizationServices
      .filter { !$0.isGranted(in: authorizationPermissionSnapshot) }
      .map(\.rawValue)
      .joined(separator: "|")
    let lastPrompted = defaults.string(
      forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
    let wasComplete = defaults.bool(forKey: Self.authorizationWasCompleteDefaultsKey)
    guard wasComplete || lastPrompted != missingFingerprint else { return false }

    defaults.set(
      missingFingerprint,
      forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
    defaults.set(false, forKey: Self.authorizationWasCompleteDefaultsKey)
    presentAuthorizationCenter()
    AppDiagnostics.log(
      "authorization_onboarding_presented",
      ["missing": missingFingerprint])
    return true
  }

  func dismissAuthorizationCenter() {
    guard !isStopped else { return  }
    isAccessibilityAuthorizationPresented = false
    AppDiagnostics.log(
      "authorization_center_hidden",
      [
        "flowContinues": "\(!pendingAuthorizationRepairServices().isEmpty)",
        "pid": "\(context.processIdentifier)",
      ])
  }

  func performAuthorizationPrimaryAction() {
    guard !isStopped else { return  }
    if authorizationManualRelaunchRequired {
      quitAppForManualAuthorizationRelaunch()
      return
    }
    guard !authorizationAutomaticRelaunchInProgress else { return }
    if allRequiredPermissionsComplete {
      if pendingAuthorizationRepairServices().isEmpty || authorizationRelaunchCompleted {
        dismissAuthorizationCenter()
      } else {
        restartAppForAuthorization()
      }
      return
    }
    startAutomaticAuthorization()
  }

  func restartAppForAuthorization() {
    guard !isStopped else { return  }
    beginAuthorizationRelaunchOnce(reason: "userRequested")
  }

  @discardableResult
  private func beginAuthorizationRelaunchOnce(reason: String) -> Bool {
    guard !isStopped,
      authorizationRelaunchAttemptState.handle(.requestAutomaticRelaunch)
        == .beginAutomaticRelaunch else { return false }
    authorizationRelaunchCompleted = false
    authorizationAutomaticRelaunchInProgress = true
    authorizationManualRelaunchRequired = false
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
    isAccessibilityAuthorizationPresented = false
    guard armAuthorizationRelaunchRelay(allowNewAutomaticAttempt: true),
      let relayToken = authorizationRelaunchRelayToken else {
      finishAuthorizationAutomaticRelaunchFailure(reason: "relayArmFailed")
      return false
    }
    authorizationRepairResultText = "正在重新打开软件；新进程会自动续上授权进度。"
    statusMessage = authorizationRepairResultText
    guard !isStopped else { return false }
    AppDiagnostics.log("authorization_automatic_relaunch_requested",
      ["pid": "\(context.processIdentifier)", "reason": reason])
    if let token = session.issue(.relaunchWatchdog) {
      session.schedule(token, after: 5, scheduler: dependencies.schedule) { [weak self] in
        self?.finishAuthorizationAutomaticRelaunchFailure(reason: "oldProcessStillAlive")
      }
    }
    // The host must flush before it calls shutdown(intent:). A denied flush is not a handoff.
    let accepted = requestTermination?(.authorizationRelaunch(relayToken)) ?? false
    if !accepted, !isStopped {
      finishAuthorizationAutomaticRelaunchFailure(reason: "terminationDenied")
    }
    return accepted
  }

  private func finishAuthorizationAutomaticRelaunchFailure(reason: String) {
    guard !isStopped else { return  }
    guard
      authorizationRelaunchAttemptState.handle(.automaticRelaunchFailed)
        == .showManualRelaunchOnly
    else { return }

    session.invalidate(.relaunchWatchdog)
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = true
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
    disarmAuthorizationRelaunchRelay(reason: "automaticRelaunchFailed:\(reason)")
    authorizationRepairResultText =
      "自动重启没有完成，授权进度已保存。请退出软件，再从“应用程序”手动打开一次。"
    statusMessage = authorizationRepairResultText
    isAccessibilityAuthorizationPresented = true
    guard !isStopped else { return }
    presentMainWindow?()
    AppDiagnostics.log(
      "authorization_manual_relaunch_required",
      [
        "pid": "\(context.processIdentifier)",
        "reason": reason,
      ])
  }

  private func quitAppForManualAuthorizationRelaunch() {
    guard !isStopped, authorizationManualRelaunchRequired else { return }
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
    isAccessibilityAuthorizationPresented = false
    AppDiagnostics.log("authorization_manual_quit_requested", ["pid": "\(context.processIdentifier)"])
    _ = requestTermination?(.ordinary)
  }

  func prepareAuthorizationRelaunchForSystemTerminationIfNeeded() -> AuthorizationTerminationIntent {
    guard !isStopped, !authorizationManualRelaunchRequired else { return .ordinary }
    let pending = pendingAuthorizationRepairServices()
    guard !pending.isEmpty else { return .ordinary }
    let currentService = authorizationRepairOpenedSettingsService
      ?? AuthorizationRecoveryPolicy.remainingRepairServices(
        pending, snapshot: liveAuthorizationPermissionSnapshot()).first
    guard currentService?.mayRequireRelaunch == true || allRequiredPermissionsComplete,
      armAuthorizationRelaunchRelay(), let token = authorizationRelaunchRelayToken else { return .ordinary }
    AppDiagnostics.log("authorization_system_termination_checkpointed", [
      "armed": "true", "pending": pending.map(\.rawValue).joined(separator: ","),
      "pid": "\(context.processIdentifier)", "service": currentService?.rawValue ?? "complete"])
    return .systemAuthorizationRelaunch(token)
  }

  func startAutomaticAuthorization() {
    guard !isStopped else { return  }
    guard !isRepairingAuthorization else { return }
    if authorizationManualRelaunchRequired {
      presentAuthorizationCenter()
      return
    }
    guard !authorizationAutomaticRelaunchInProgress else { return }
    authorizationRelaunchCompleted = false
    refreshAuthorizationAndReloadIfNeeded()
    guard !isStopped, !authorizationAutomaticRelaunchInProgress,
      !authorizationManualRelaunchRequired
    else { return }
    if allRequiredPermissionsComplete {
      if pendingAuthorizationRepairServices().isEmpty {
        authorizationRelaunchCompleted = true
      }
      statusMessage = "三项必要权限均已确认。"
      return
    }

    let missingServices = coreAuthorizationServices.filter {
      !$0.isGranted(in: authorizationPermissionSnapshot)
    }
    guard let nextService = missingServices.first else { return }

    beginFlow()
    authorizationRelaunchAttemptState.handle(.reset)
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = false

    defaults.set(
      missingServices.map(\.rawValue),
      forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.set(true, forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.set(
      Int(context.processIdentifier),
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()

    authorizationRepairOpenedSettingsService = nextService
    authorizationRepairResultText =
      "请在系统设置中开启\(nextService.displayName)；开启后软件会自动继续下一步。"
    statusMessage = authorizationRepairResultText
    requestAuthorizationRegistration(for: nextService)
  }

  private func repairOnlyMissingAuthorizationAndRelaunch() {
    guard !isStopped else { return  }
    guard context.allowsStablePermissionRepair else {
      authorizationRepairResultText = "当前运行版本不是正式安装版，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let expectedBundleID = context.expectedBundleIdentifier
    let bundleID = appBundleIdentifier
    guard bundleID == expectedBundleID else {
      authorizationRepairResultText = "当前运行版本与正式版身份不一致，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let liveSnapshot = liveAuthorizationPermissionSnapshot()
    advancedListeningAuthorized = liveSnapshot.accessibility
    inputMonitoringAuthorized = liveSnapshot.inputMonitoring
    screenRecordingAuthorized = liveSnapshot.screenRecording
    let services = AuthorizationRecoveryPolicy.servicesEligibleForRepair(
      isInstalledInApplications: isInstalledInApplications,
      snapshot: liveSnapshot,
      explicitRecheckFailed: authorizationRecheckFailed)
    guard !services.isEmpty else {
      authorizationRecheckFailed = false
      authorizationRepairResultText = "权限已经生效，不需要其他操作。"
      statusMessage = authorizationRepairResultText
      return
    }
    guard !isRepairingAuthorization else { return }

    isRepairingAuthorization = true
    let serviceNames = services.map(\.displayName).joined(separator: "和")
    authorizationRepairResultText =
      "正在清除本 App 当前未生效的\(serviceNames)记录；已生效项和其他权限保持不变..."
    statusMessage = authorizationRepairResultText

    performPermissionReset(services: services, expectedBundleID: expectedBundleID, explicitClear: false)
  }

  func clearAuthorizationPermissionsAndRestart(userConfirmed: Bool) {
    guard !isStopped else { return  }
    guard context.allowsStablePermissionRepair else {
      authorizationRepairResultText = "当前运行版本不是正式安装版，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let expectedBundleID = context.expectedBundleIdentifier
    let services = AuthorizationRecoveryPolicy.servicesEligibleForExplicitClear(
      isInstalledInApplications: isInstalledInApplications,
      bundleIdentifier: appBundleIdentifier,
      expectedBundleIdentifier: expectedBundleID,
      userConfirmed: userConfirmed)
    guard !services.isEmpty else {
      authorizationRepairResultText =
        isInstalledInApplications
        ? "未执行：只有确认后才会清除本 App 的权限。"
        : "未执行：请先从“应用程序”文件夹打开本软件。"
      statusMessage = authorizationRepairResultText
      return
    }
    guard !isRepairingAuthorization else { return }

    disarmAuthorizationRelaunchRelay(reason: "explicitClearStarting")
    clearPendingAuthorizationFlow()
    isRepairingAuthorization = true
    authorizationRepairResultText =
      "正在清除本 App 的辅助功能、屏幕录制和输入监控；其他 App 和其他权限保持不变..."
    statusMessage = authorizationRepairResultText
    AppDiagnostics.log(
      "authorization_explicit_clear_confirmed",
      [
        "bundle": expectedBundleID,
        "services": services.map(\.rawValue).joined(separator: ","),
      ])

    performPermissionReset(services: services, expectedBundleID: expectedBundleID, explicitClear: true)
  }

  func handleAuthorizationRepairRelaunchIfNeeded() {
    guard !isStopped else { return  }
    let pending = pendingAuthorizationRepairServices()
    let didRelaunch = authorizationFlowAlreadyRelaunched
    let requiresRelaunch = defaults.bool(
      forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    let continuation = AuthorizationFlowContinuationPolicy.next(
      pendingServices: pending,
      snapshot: authorizationPermissionSnapshot,
      requiresRelaunch: requiresRelaunch,
      processAlreadyRelaunched: didRelaunch)

    switch continuation {
    case .inactive:
      return
    case .finished:
      clearPendingAuthorizationFlow()
      authorizationRelaunchAttemptState.handle(.relaunchedProcessVerified)
      authorizationRelaunchCompleted = true
      authorizationAutomaticRelaunchInProgress = false
      authorizationManualRelaunchRequired = false
      authorizationRepairResultText = "权限已开启，软件已重新打开。"
      statusMessage = authorizationRepairResultText
      AppDiagnostics.log(
        "authorization_relaunch_verified_on_launch",
        ["pid": "\(context.processIdentifier)"])
      return
    case .awaitRelaunch:
      beginAuthorizationRelaunchOnce(reason: "launchContinuationAwaitingNewPID")
      return
    case .continueWith(let nextService):
      authorizationRelaunchAttemptState.handle(.reset)
      authorizationAutomaticRelaunchInProgress = false
      authorizationManualRelaunchRequired = false
      let remaining = AuthorizationRecoveryPolicy.remainingRepairServices(
        pending,
        snapshot: authorizationPermissionSnapshot)
      markCurrentProcessAsAuthorizationFlowOwner()
      authorizationRepairResultText =
        didRelaunch
        ? "软件已重新打开，授权进度已接上。请继续开启\(nextService.displayName)。"
        : "请继续开启\(nextService.displayName)。"
      statusMessage = authorizationRepairResultText
      isAccessibilityAuthorizationPresented = true
      authorizationRepairOpenedSettingsService = nextService
      AppDiagnostics.log(
        "authorization_flow_resumed",
        [
          "pid": "\(context.processIdentifier)",
          "relaunched": "\(didRelaunch)",
          "remaining": remaining.map(\.rawValue).joined(separator: ","),
        ])
      scheduleFlow(after: 0.35) { [weak self] in
        guard let self, self.authorizationRepairOpenedSettingsService == nextService else { return }
        self.requestAuthorizationRegistration(for: nextService)
      }
    }
  }

  private func scheduleAuthorizationRepairRelaunch(
    pendingServices: [AuthorizationRepairService]
  ) {
    guard !isStopped else { return  }
    authorizationRelaunchCompleted = false
    beginFlow()
    authorizationRelaunchAttemptState.handle(.reset)
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = false
    defaults.set(
      pendingServices.map(\.rawValue),
      forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.set(true, forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.set(
      Int(context.processIdentifier),
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()

    AppDiagnostics.log(
      "authorization_repair_relaunch_scheduled",
      [
        "bundle": appBundleIdentifier,
        "services": pendingServices.map(\.rawValue).joined(separator: ","),
      ])
    beginAuthorizationRelaunchOnce(reason: "targetedPermissionRepair")
  }

  private func pendingAuthorizationRepairServices() -> [AuthorizationRepairService] {
    let rawValues =
      defaults.stringArray(
        forKey: Self.pendingAuthorizationRepairServicesDefaultsKey) ?? []
    return rawValues.compactMap(AuthorizationRepairService.init(rawValue:))
  }

  private var authorizationFlowAlreadyRelaunched: Bool {
    let rawOwnerPID = defaults.integer(
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    let ownerPID = rawOwnerPID > 0 ? Int32(exactly: rawOwnerPID) : nil
    return AuthorizationRelaunchStatePolicy.processAlreadyRelaunched(
      flowOwnerProcessIdentifier: ownerPID,
      currentProcessIdentifier: context.processIdentifier)
  }

  private func markCurrentProcessAsAuthorizationFlowOwner() {
    defaults.set(
      Int(context.processIdentifier),
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()
  }

  private func clearPendingAuthorizationFlow() {
    session.issue(.flow)
    session.invalidate(.registration)
    authorizationRegistrationRequestOwner = nil
    defaults.removeObject(forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.removeObject(forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.removeObject(forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()
    authorizationRepairOpenedSettingsService = nil
    authorizationSystemPromptRelaunchScheduled = false
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
  }

  @discardableResult
  func presentAuthorizationRelaunchResultIfNeeded() -> Bool {
    guard !isStopped else { return false }
    let rawSourcePID = defaults.integer(
      forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    let sourcePID = rawSourcePID > 0 ? Int32(exactly: rawSourcePID) : nil
    let rawRequestedAt = defaults.double(
      forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    let requestedAt = rawRequestedAt > 0 ? rawRequestedAt : nil
    let currentPID = context.processIdentifier
    let shouldPresent = AuthorizationRelaunchPresentationPolicy.shouldPresent(
      sourceProcessIdentifier: sourcePID,
      currentProcessIdentifier: currentPID,
      requestedAt: requestedAt,
      now: dependencies.now().timeIntervalSince1970)
    clearAuthorizationRelaunchPresentationRequest()
    guard shouldPresent else { return false }

    refreshAccessibilityStatus()
    authorizationRelaunchCompleted =
      allRequiredPermissionsComplete && pendingAuthorizationRepairServices().isEmpty
    authorizationRepairResultText =
      allRequiredPermissionsComplete
      ? "权限已开启，软件已重新打开。"
      : "软件已重新打开；\(authorizationSetupDetail)"
    statusMessage = authorizationRepairResultText
    if authorizationRelaunchCompleted {
      authorizationRelaunchAttemptState.handle(.relaunchedProcessVerified)
      authorizationAutomaticRelaunchInProgress = false
      authorizationManualRelaunchRequired = false
      isAccessibilityAuthorizationPresented = false
      dependencies.hideGuide()
    } else {
      isAccessibilityAuthorizationPresented = true
    }
    AppDiagnostics.log(
      "authorization_relaunch_result_presented",
      [
        "sourcePID": sourcePID.map(String.init) ?? "",
        "pid": "\(currentPID)",
        "permissionsComplete": "\(allRequiredPermissionsComplete)",
      ])
    return !authorizationRelaunchCompleted
  }

  private func recordAuthorizationRelaunchPresentationRequest() {
    defaults.set(
      Int(context.processIdentifier),
      forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    defaults.set(
      dependencies.now().timeIntervalSince1970,
      forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    defaults.synchronize()
  }

  private func clearAuthorizationRelaunchPresentationRequest() {
    defaults.removeObject(forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    defaults.removeObject(forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    defaults.synchronize()
  }

  private func requestAuthorizationRegistration(for service: AuthorizationRepairService) {
    guard !isStopped, !authorizationAutomaticRelaunchInProgress,
      !authorizationManualRelaunchRequired,
      authorizationRepairOpenedSettingsService == service,
      pendingAuthorizationRepairServices().contains(service),
      let token = session.issue(.registration) else { return }
    if service.mayRequireRelaunch {
      _ = armAuthorizationRelaunchRelay()
    } else {
      dependencies.stopPromptMonitor()
    }
    guard session.isCurrent(token) else { return }
    let opened = openAuthorizationPrivacyPane(for: service)
    guard session.isCurrent(token) else { return }
    if opened {
      let progress = authorizationGuideProgress(for: service)
      dependencies.showGuide(service, progress.step, progress.total) { [weak self] in
        guard let self, self.session.isCurrent(token) else { return }
        self.requestOfficialAuthorizationRegistration(for: service)
      }
      guard session.isCurrent(token) else { return }
      if service.mayRequireRelaunch {
        authorizationSystemPromptRelaunchScheduled = false
        dependencies.startPromptMonitor(authorizationApplicationDisplayName, service) { [weak self] in
          guard let self, self.session.isCurrent(token) else { return }
          self.handleAuthorizationSystemRelaunchPrompt(for: service)
        }
      }
      statusMessage = "已打开\(service.displayName)设置。列表里没有本 App 时，拖入或双击前台授权卡；然后打开右侧开关。"
    } else {
      dependencies.hideGuide()
      dependencies.stopPromptMonitor()
      if service.mayRequireRelaunch { disarmAuthorizationRelaunchRelay(reason: "privacyPaneOpenFailed") }
    }
    guard session.isCurrent(token) else { return }
    requestPolling?("\(service.rawValue)SettingsOpened")
  }

  private func authorizationGuideProgress(
    for service: AuthorizationRepairService
  ) -> (step: Int, total: Int) {
    let services = AuthorizationRepairService.allCases
    let index = services.firstIndex(of: service) ?? services.startIndex
    return (services.distance(from: services.startIndex, to: index) + 1, services.count)
  }

  private func requestOfficialAuthorizationRegistration(for service: AuthorizationRepairService) {
    guard !isStopped,
      context.isInstalledInApplications, !context.isInvalid,
      context.bundleIdentifier == context.expectedBundleIdentifier,
      authorizationRepairOpenedSettingsService == service,
      pendingAuthorizationRepairServices().contains(service),
      let token = session.current(.registration), session.isCurrent(token),
      authorizationRegistrationRequestOwner != token else { return }
    authorizationRegistrationRequestOwner = token
    defer {
      // An older modal permission call must never clear a newer request's ownership.
      if authorizationRegistrationRequestOwner == token {
        authorizationRegistrationRequestOwner = nil
      }
    }
    AppDiagnostics.log("authorization_official_registration_requested", [
      "pid": "\(context.processIdentifier)", "service": service.rawValue,
      "trigger": "frontGuideDoubleClick"])
    let granted = dependencies.requestOfficialPermission(service)
    // A system permission API may run a nested event loop. Revalidate after it returns.
    guard session.isCurrent(token) else { return }
    authorizationRepairResultText = granted
      ? "macOS 已确认\(service.displayName)；正在核对并继续。"
      : "已向 macOS 请求登记\(service.displayName)。请在系统提示或当前列表中确认，再打开右侧开关。"
    statusMessage = authorizationRepairResultText
    guard session.isCurrent(token) else { return }
    AppDiagnostics.log("authorization_official_registration_returned", [
      "granted": "\(granted)", "pid": "\(context.processIdentifier)", "service": service.rawValue])
    _ = refreshAuthorizationAndReloadIfNeeded()
    guard session.isCurrent(token) else { return }
    if !service.isGranted(in: liveAuthorizationPermissionSnapshot()) {
      session.schedule(token, after: 0.35, scheduler: dependencies.schedule) { [weak self] in
        guard let self, self.authorizationRepairOpenedSettingsService == service else { return }
        _ = self.openAuthorizationPrivacyPane(for: service)
      }
    }
  }

  private var authorizationApplicationDisplayName: String { context.displayName }

  private func handleAuthorizationSystemRelaunchPrompt(
    for service: AuthorizationRepairService
  ) {
    guard !isStopped else { return  }
    guard !authorizationSystemPromptRelaunchScheduled,
      authorizationRepairOpenedSettingsService == service,
      pendingAuthorizationRepairServices().contains(service)
    else { return }

    authorizationSystemPromptRelaunchScheduled = true
    dependencies.stopPromptMonitor()
    dependencies.hideGuide()
    AppDiagnostics.log(
      "authorization_system_prompt_detected",
      [
        "pid": "\(context.processIdentifier)",
        "service": service.rawValue,
      ])
    authorizationRepairResultText =
      "macOS 已要求重开；软件正在自动退出，新进程会接着下一项。"
    statusMessage = authorizationRepairResultText
    beginAuthorizationRelaunchOnce(reason: "systemPrompt:\(service.rawValue)")
  }

  @discardableResult
  private func openAuthorizationPrivacyPane(for service: AuthorizationRepairService) -> Bool {
    guard !isStopped else { return false }
    let pane: String
    switch service {
    case .accessibility:
      pane = "Privacy_Accessibility"
    case .screenRecording:
      pane = "Privacy_ScreenCapture"
    case .inputMonitoring:
      pane = "Privacy_ListenEvent"
    }
    let candidates = [
      "x-apple.systempreferences:com.apple.preference.security?\(pane)",
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
    ]
    for candidate in candidates {
      guard let url = URL(string: candidate) else { continue }
      if dependencies.openURL(url) { return true }
    }
    statusMessage = "无法自动打开系统设置的\(service.displayName)页面，请稍后重试。"
    return false
  }

  @discardableResult
  private func armAuthorizationRelaunchRelay(allowNewAutomaticAttempt: Bool = false) -> Bool {
    guard !isStopped, context.isInstalledInApplications, !context.isInvalid,
      context.bundleIdentifier == context.expectedBundleIdentifier else { return false }
    if let markerURL = authorizationRelaunchRelayMarkerURL {
      if dependencies.markerExists(markerURL), authorizationRelaunchRelayProcess?.isRunning() == true {
        return true
      }
      if authorizationRelaunchRelayProcess != nil, authorizationRelaunchRelayToken != nil {
        AppDiagnostics.log("authorization_relaunch_relay_rearm_blocked", ["reason": "awaitingOutcome"])
        return false
      }
      authorizationRelaunchRelayProcess = nil
      dependencies.removeMarker(markerURL)
      authorizationRelaunchRelayMarkerURL = nil
      clearAuthorizationRelaunchPresentationRequest()
    }
    switch authorizationRelaunchAttemptState.phase {
    case .manualRelaunchRequired, .finished:
      AppDiagnostics.log("authorization_relaunch_relay_rearm_blocked", ["reason": "terminalAttemptState"])
      return false
    case .automaticRelaunchRequested where !allowNewAutomaticAttempt:
      AppDiagnostics.log("authorization_relaunch_relay_rearm_blocked", ["reason": "automaticAttemptAlreadyRequested"])
      return false
    case .ready, .automaticRelaunchRequested: break
    }
    let markerURL = context.supportDirectory.appendingPathComponent(
      "authorization-relaunch-\(context.processIdentifier).pending")
    let relayToken = UUID()
    authorizationRelaunchRelayToken = relayToken
    authorizationRelaunchRelayMarkerURL = markerURL
    recordAuthorizationRelaunchPresentationRequest()
    do {
      let relay = try dependencies.armRelay(AuthorizationRelaunchRelayRequest(
        processIdentifier: context.processIdentifier, bundleIdentifier: appBundleIdentifier,
        markerURL: markerURL, applicationURL: context.applicationURL)
      ) { [weak self] outcome in
        self?.handleAuthorizationRelaunchRelayOutcome(outcome, token: relayToken)
      }
      guard !isStopped, authorizationRelaunchRelayToken == relayToken else {
        relay.detach()
        relay.cancel()
        dependencies.removeMarker(markerURL)
        return false
      }
      authorizationRelaunchRelayProcess = relay
      AppDiagnostics.log("authorization_relaunch_relay_armed", [
        "pid": "\(context.processIdentifier)", "timeoutSeconds": "300"])
      return true
    } catch {
      guard authorizationRelaunchRelayToken == relayToken else { return false }
      authorizationRelaunchRelayToken = nil
      authorizationRelaunchRelayProcess = nil
      authorizationRelaunchRelayMarkerURL = nil
      dependencies.removeMarker(markerURL)
      clearAuthorizationRelaunchPresentationRequest()
      AppDiagnostics.log("authorization_relaunch_relay_arm_failed", ["error": error.localizedDescription])
      return false
    }
  }

  private func handleAuthorizationRelaunchRelayOutcome(
    _ outcome: AuthorizationRelaunchRelayOutcome,
    token: UUID
  ) {
    guard !isStopped, authorizationRelaunchRelayToken == token else { return }
    let outcomeText: String
    switch outcome {
    case .reopened:
      outcomeText = "reopened"
    case .timedOut:
      outcomeText = "timedOut"
    case .cancelled:
      outcomeText = "cancelled"
    case .failed(let status):
      outcomeText = "failed:\(status)"
    }
    AppDiagnostics.log(
      "authorization_relaunch_relay_finished",
      ["outcome": outcomeText])

    switch outcome {
    case .reopened:
      return
    case .timedOut:
      finishAuthorizationAutomaticRelaunchFailure(reason: "relayTimedOut")
    case .cancelled:
      finishAuthorizationAutomaticRelaunchFailure(reason: "relayCancelled")
    case .failed(let status):
      finishAuthorizationAutomaticRelaunchFailure(reason: "relayFailed:\(status)")
    }
  }

  private func disarmAuthorizationRelaunchRelay(reason: String) {
    let markerURL = authorizationRelaunchRelayMarkerURL
    let relayProcess = authorizationRelaunchRelayProcess
    authorizationRelaunchRelayToken = nil
    authorizationRelaunchRelayProcess = nil
    authorizationRelaunchRelayMarkerURL = nil
    guard markerURL != nil || relayProcess != nil else { return }
    relayProcess?.detach()
    if let markerURL { dependencies.removeMarker(markerURL) }
    clearAuthorizationRelaunchPresentationRequest()
    relayProcess?.cancel()
    AppDiagnostics.log("authorization_relaunch_relay_disarmed", ["reason": reason])
  }

  func quitAppForAccessibilityReauthorization() {
    guard !isStopped else { return }
    _ = requestTermination?(.ordinary)
  }

  private func liveAuthorizationPermissionSnapshot() -> AuthorizationPermissionSnapshot {
    dependencies.snapshot()
  }

  func refreshAccessibilityStatus() {
    guard !isStopped else { return  }
    let snapshot = liveAuthorizationPermissionSnapshot()
    guard !isStopped else { return }
    advancedListeningAuthorized = snapshot.accessibility
    inputMonitoringAuthorized = snapshot.inputMonitoring
    screenRecordingAuthorized = snapshot.screenRecording
    if snapshot.allEventTapPermissionsGranted {
      authorizationRecheckFailed = false
      defaults.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      defaults.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
    }
  }

  @discardableResult
  func refreshAuthorizationAndReloadIfNeeded() -> Bool {
    guard !isStopped else { return false }
    let previousSnapshot = authorizationHotReloadState.permissions
    let snapshot = liveAuthorizationPermissionSnapshot()
    guard !isStopped else { return false }
    let changed = authorizationHotReloadState.observe(snapshot)
    featurePermissionsChanged?(previousSnapshot, snapshot)
    guard !isStopped else { return false }
    let eventTapChanged =
      previousSnapshot.accessibility != snapshot.accessibility
      || previousSnapshot.inputMonitoring != snapshot.inputMonitoring
    advancedListeningAuthorized = snapshot.accessibility
    inputMonitoringAuthorized = snapshot.inputMonitoring
    screenRecordingAuthorized = snapshot.screenRecording
    if snapshot.allEventTapPermissionsGranted {
      authorizationRecheckFailed = false
      defaults.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      defaults.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
      dependencies.stopPromptMonitor()
      dependencies.hideDragPrompt()
    }
    refreshCapsConflict?()
    guard !isStopped else { return false }

    if advancePendingAuthorizationRepair(snapshot: snapshot) {
      return true
    }
    guard changed else { return false }

    guard eventTapChanged else {
      statusMessage = authorizationSetupDetail
      AppDiagnostics.log(
        "authorization_changed",
        [
          "screenRecording": "\(snapshot.screenRecording)",
          "result": snapshot.allEventTapPermissionsGranted ? "complete" : "screenChanged",
        ])
      return true
    }

    let becameComplete =
      !previousSnapshot.allEventTapPermissionsGranted
      && snapshot.allEventTapPermissionsGranted

    session.invalidate(.hotReload)
    if !snapshot.allEventTapPermissionsGranted {
      authorizationRelaunchCompleted = false
      defaults.removeObject(
        forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
      reloadPermissionDependentListeners()
      statusMessage = permissionDetail
      AppDiagnostics.log(
        "authorization_changed",
        [
          "accessibility": "\(snapshot.accessibility)",
          "inputMonitoring": "\(snapshot.inputMonitoring)",
          "screenRecording": "\(snapshot.screenRecording)",
          "result": "permissionsIncomplete",
        ])
      return true
    }

    if becameComplete {
      performAuthorizationHotReload(trigger: "eventTapPermissionsGranted")
      return true
    }

    performAuthorizationHotReload(trigger: "permissionChanged")
    return true
  }

  private func advancePendingAuthorizationRepair(
    snapshot: AuthorizationPermissionSnapshot
  ) -> Bool {
    guard !isStopped else { return false }
    let pending = pendingAuthorizationRepairServices()
    guard !pending.isEmpty else { return false }

    let remaining = AuthorizationRecoveryPolicy.remainingRepairServices(
      pending,
      snapshot: snapshot)
    let requiresRelaunch = defaults.bool(
      forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    let continuation = AuthorizationFlowContinuationPolicy.next(
      pendingServices: pending,
      snapshot: snapshot,
      requiresRelaunch: requiresRelaunch,
      processAlreadyRelaunched: authorizationFlowAlreadyRelaunched)

    switch continuation {
    case .inactive:
      return false
    case .finished:
      clearPendingAuthorizationFlow()
      authorizationRelaunchAttemptState.handle(.relaunchedProcessVerified)
      authorizationRelaunchCompleted = true
      authorizationAutomaticRelaunchInProgress = false
      authorizationManualRelaunchRequired = false
      return true
    case .awaitRelaunch:
      // 保留 pending、owner PID 和 presentation marker，直到不同的新 PID
      // 真正启动并消费它们。三项全开与系统重开提示共用同一个一次性闸门。
      beginAuthorizationRelaunchOnce(reason: "allPermissionsGranted")
      return true
    case .continueWith:
      break
    }

    if remaining.map(\.rawValue) != pending.map(\.rawValue) {
      defaults.set(
        remaining.map(\.rawValue),
        forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
      defaults.synchronize()
    }

    guard remaining.count != pending.count else { return false }
    guard remaining.first != authorizationRepairOpenedSettingsService,
      let nextService = remaining.first
    else {
      return true
    }
    authorizationRepairOpenedSettingsService = nextService
    authorizationRepairResultText =
      "\(pending.filter { $0.isGranted(in: snapshot) }.map(\.displayName).joined(separator: "和"))已生效；请继续开启\(nextService.displayName)。"
    statusMessage = authorizationRepairResultText
    session.invalidate(.registration)
    scheduleFlow(after: 0.25) { [weak self] in
      guard let self, self.authorizationRepairOpenedSettingsService == nextService else { return }
      self.requestAuthorizationRegistration(for: nextService)
    }
    return true
  }

  private func reloadPermissionDependentListeners() {
    guard !isStopped else { return }
    reloadListeners?()
  }

  private func performAuthorizationHotReload(trigger: String) {
    guard !isStopped else { return  }
    reloadPermissionDependentListeners()
    guard !isStopped else { return }
    let verification = authorizationListenerVerification()
    guard !isStopped else { return }
    let decision = authorizationHotReloadState.recordReload(verification: verification)
    AppDiagnostics.log(
      "authorization_hot_reload",
      [
        "trigger": trigger,
        "required": verification.required.joined(separator: ","),
        "failed": verification.failed.joined(separator: ","),
        "decision": "\(decision)",
      ])

    switch decision {
    case .permissionsIncomplete:
      statusMessage = permissionDetail
    case .hotReloadSucceeded:
      defaults.removeObject(
        forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
      statusMessage = "授权已生效，后台监听已恢复。"
    case .retryHotReload(let attempt):
      guard let token = session.issue(.hotReload) else { return }
      session.schedule(token, after: 0.45, scheduler: dependencies.schedule) { [weak self] in
        guard let self else { return }
        let snapshot = self.liveAuthorizationPermissionSnapshot()
        guard snapshot == self.authorizationHotReloadState.permissions else {
          _ = self.refreshAuthorizationAndReloadIfNeeded()
          return
        }
        guard snapshot.allEventTapPermissionsGranted else { return }
        self.performAuthorizationHotReload(trigger: "boundedRetry\(attempt)")
      }
    case .scheduleSingleRelaunch:
      scheduleAuthorizationHotReloadRelaunch(failedListeners: verification.failed)
    case .manualRelaunchRequired:
      statusMessage = "授权已具备，但后台监听仍未恢复。请手动退出并重新打开 App。"
    }
  }

  private func authorizationListenerVerification() -> AuthorizationListenerVerification {
    listenerVerification?() ?? AuthorizationListenerVerification(required: [], failed: [])
  }

  private func scheduleAuthorizationHotReloadRelaunch(failedListeners: [String]) {
    guard !isStopped else { return  }
    defaults.set(
      true, forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
    defaults.synchronize()

    if authorizationRelaunchAttemptState.phase == .finished {
      authorizationRelaunchAttemptState.handle(.reset)
    }
    if beginAuthorizationRelaunchOnce(
      reason: "hotReload:\(failedListeners.joined(separator: ","))"
    ) {
      AppDiagnostics.log(
        "authorization_hot_reload_relaunch_scheduled",
        ["failed": failedListeners.joined(separator: ",")])
    } else {
      AppDiagnostics.log(
        "authorization_hot_reload_relaunch_failed",
        ["failed": failedListeners.joined(separator: ",")])
    }
  }

  func verifyAuthorizationHotReloadAfterRelaunchIfNeeded() {
    guard !isStopped else { return  }
    guard defaults.bool(forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey) else {
      return
    }
    let verification = authorizationListenerVerification()
    if authorizationPermissionsComplete && verification.succeeded {
      defaults.removeObject(forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
      authorizationHotReloadState = AuthorizationHotReloadStateMachine(
        permissions: AuthorizationPermissionSnapshot(
          accessibility: advancedListeningAuthorized,
          inputMonitoring: inputMonitoringAuthorized,
          screenRecording: screenRecordingAuthorized))
      AppDiagnostics.log("authorization_hot_reload_relaunch_verified", [:])
    } else {
      authorizationHotReloadState.markRelaunchAttempted()
      AppDiagnostics.log(
        "authorization_hot_reload_relaunch_unresolved",
        ["failed": verification.failed.joined(separator: ",")])
    }
  }

  func refreshAppSignatureSummary() {
    guard let token = session.issue(.signature) else { return }
    runOwnedProcess(token: token, executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=4", appBundlePath], timeout: 3, limit: 65_536
    ) { [weak self] result in
      guard let self else { return }
      self.session.complete(token)
      guard !self.isStopped else { return }
      if result.succeeded {
        self.appSignatureSummary = Self.signatureSummary(from: result.standardError)
      } else if let launchError = result.launchError {
        self.appSignatureSummary = "签名读取失败：\(launchError)"
      } else {
        self.appSignatureSummary = "签名读取失败"
      }
    }
  }

  private static func signatureSummary(from output: String) -> String {
    let wantedPrefixes = ["Signature=", "TeamIdentifier=", "CDHash="]
    let fields = output.split(separator: "\n").compactMap { line -> String? in
      let text = String(line)
      guard wantedPrefixes.contains(where: { text.hasPrefix($0) }) else { return nil }
      return text
    }
    return fields.isEmpty ? "签名摘要不可用" : fields.joined(separator: " · ")
  }

}
