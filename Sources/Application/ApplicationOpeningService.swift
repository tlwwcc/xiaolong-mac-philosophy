import AppKit
import ApplicationServices
import Foundation

enum OpenAppTriggerMode {
    case toggle
    case activateOnly
  }

private struct AppWindowLevelSnapshot {
  let targetWindowRank: Int?
  let targetWindowTitle: String
  let targetWindowCount: Int
  let topPID: pid_t?
  let topOwner: String
  let topTitle: String
  let visibleWindowCount: Int
  let axFocusedTitle: String
  let axMainTitle: String

  var targetWindowTopmost: Bool {
    targetWindowRank == 0
  }

  var payload: [String: String] {
    [
      "axFocusedTitle": axFocusedTitle,
      "axMainTitle": axMainTitle,
      "targetWindowCount": "\(targetWindowCount)",
      "targetWindowRank": targetWindowRank.map(String.init) ?? "none",
      "targetWindowTitle": targetWindowTitle,
      "targetWindowTopmost": "\(targetWindowTopmost)",
      "topOwner": topOwner,
      "topPID": topPID.map(String.init) ?? "none",
      "topTitle": topTitle,
      "visibleWindowCount": "\(visibleWindowCount)",
    ]
  }
}

/// Owns application activation and foreground-repair lifetimes independently of UI state.
@MainActor
final class ApplicationOpeningService {
  private let onStatus: (String) -> Void
  private var stopped = false
  private var statusMessage = "" {
    didSet { if !stopped { onStatus(statusMessage) } }
  }
  init(onStatus: @escaping (String) -> Void) { self.onStatus = onStatus }

  func shutdown() {
    stopped = true
    activationSession.stop()
    appForegroundPendingUntil.removeAll()
    recentlyHiddenAppBundleIDs.removeAll()
  }

  private var recentlyHiddenAppBundleIDs: [String: TimeInterval] = [:]
  private var appForegroundPendingUntil: [String: TimeInterval] = [:]
  private let activationSession = ApplicationActivationSession()
  private let appRecentlyHiddenInterval: TimeInterval = 1.2
  private let appActivationRetryDelays: [TimeInterval] = [0.03, 0.08]
  private let appActivationSystemRetryDelay: TimeInterval = 0.10
  private let appActivationAppleScriptRetryDelay: TimeInterval = 0.18
  private let appActivationRepairDelay: TimeInterval = 0.32
  private let appActivationSettleRetryDelay: TimeInterval = 0.55
  private let appForegroundPendingInterval: TimeInterval = 3.0
  private let appForegroundVerifierDelays: [TimeInterval] = [
    0.04, 0.12, 0.22, 0.36, 0.55, 0.85, 1.25, 1.75, 2.40,
  ]
  private let appColdLaunchForegroundRetryDelays: [TimeInterval] = [
    0.20, 0.55, 1.00, 1.60, 2.40,
  ]

  func openNamedApplication(
    _ name: String, completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    guard !stopped,
      let owner = issueAppActivationToken(for: "name:\(name)")
    else { return }
    runOwnedProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"),
      arguments: ["-a", name], activation: owner, timeout: 8
    ) { result in completion?(result.succeeded) }
  }

  func toggleBundleApp(
    _ bundleID: String,
    mode: OpenAppTriggerMode = .toggle,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    guard !stopped else { completion?(false); return }
    AppDiagnostics.log("app_toggle_bundle", ["bundle": bundleID])
    if bundleID == "com.apple.apps.launcher" {
      completion?(openApplicationsUI())
      return
    }
    if let app = preferredRunningApplication(bundleID: bundleID) {
      AppDiagnostics.log("app_running_found", ["bundle": bundleID])
      toggleRunningApp(app, mode: mode)
      completion?(true)
      return
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      AppDiagnostics.log("app_open_url", ["bundle": bundleID, "path": url.path])
      openApplication(at: url, completion: completion)
      return
    }
    let activation = issueAppActivationToken(for: activationKey(forBundleID: bundleID))
    runOwnedProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"),
      arguments: ["-b", bundleID], activation: activation,
      timeout: 8
    ) { [weak self] result in
      guard let self, !self.stopped else { return }
      if result.succeeded {
        self.reinforceColdLaunchForeground(bundleID: bundleID, activation: activation)
      }
      completion?(result.succeeded)
    }
  }

  func toggleApp(
    at url: URL,
    mode: OpenAppTriggerMode = .toggle,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    guard !stopped else { completion?(false); return }
    if let bundleID = Bundle(url: url)?.bundleIdentifier,
      let app = preferredRunningApplication(bundleID: bundleID)
    {
      toggleRunningApp(app, mode: mode)
      completion?(true)
      return
    }
    openApplication(at: url, completion: completion)
  }

  func preferredRunningApplication(bundleID: String) -> NSRunningApplication? {
    preferredRunningApplication {
      $0.bundleIdentifier == bundleID
    }
  }

  func preferredRunningApplication(named name: String) -> NSRunningApplication? {
    preferredRunningApplication {
      ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
    }
  }

  func preferredRunningApplication(
    where matches: (NSRunningApplication) -> Bool
  ) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications
      .filter { !$0.isTerminated && matches($0) }
      .max { appSelectionScore($0) < appSelectionScore($1) }
  }

  private func appSelectionScore(_ app: NSRunningApplication) -> Int {
    var score = 0
    if app.activationPolicy == .regular {
      score += 100
    } else if app.activationPolicy == .accessory {
      score += 20
    }
    if app.isActive {
      score += 40
    }
    if !app.isHidden {
      score += 20
    }
    if app.bundleURL != nil {
      score += 8
    }
    if app.localizedName != nil {
      score += 4
    }
    return score
  }

  private typealias AppActivationToken = ApplicationActivationSession.Token

  func activationKey(for app: NSRunningApplication) -> String? {
    if let bundleID = app.bundleIdentifier {
      return activationKey(forBundleID: bundleID)
    }
    return "pid:\(app.processIdentifier)"
  }

  func activationKey(forBundleID bundleID: String) -> String {
    "bundle:\(bundleID)"
  }

  private func issueAppActivationToken(for key: String?) -> AppActivationToken? {
    guard let key, let token = activationSession.issue(for: key) else { return nil }
    AppDiagnostics.log(
      "app_foreground_repair_owner_started",
      ["key": key, "token": "\(token.value)"])
    return token
  }

  private func invalidateAppActivation(for key: String?) {
    guard let key else { return }
    activationSession.invalidate(for: key)
  }

  func cancelAppForegroundRepair(for app: NSRunningApplication, reason: String) {
    guard let key = activationKey(for: app) else { return }
    let token = activationSession.currentToken(for: key)?.value
    activationSession.invalidate(for: key)
    if let bundleID = app.bundleIdentifier {
      clearAppForegroundActivationPending(bundleID)
    }
    AppDiagnostics.log(
      "app_foreground_repair_cancelled_user_interaction",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "key": key,
        "reason": reason,
        "token": token.map(String.init) ?? "none",
      ])
  }

  func cancelStaleAppActivations(keeping currentKey: String?) {
    let staleKeys = activationSession.activeKeys.filter { key in
      guard let currentKey else { return true }
      return key != currentKey
    }
    guard !staleKeys.isEmpty else { return }
    for key in staleKeys {
      invalidateAppActivation(for: key)
      if let bundleID = bundleID(fromActivationKey: key) {
        clearAppForegroundActivationPending(bundleID)
      }
    }
    AppDiagnostics.log(
      "app_activation_stale_cancelled",
      ["count": "\(staleKeys.count)", "keeping": currentKey ?? ""]
    )
  }

  private func bundleID(fromActivationKey key: String) -> String? {
    guard key.hasPrefix("bundle:") else { return nil }
    return String(key.dropFirst("bundle:".count))
  }

  private func isAppActivationCurrent(_ token: AppActivationToken?) -> Bool {
    activationSession.isCurrent(token)
  }

  private func logStaleAppActivationIgnored(
    event: String,
    bundleID: String?,
    activation: AppActivationToken?,
    delay: TimeInterval,
    reason: String = "stale_activation_token"
  ) {
    var payload: [String: String] = [
      "bundle": bundleID ?? "",
      "delay": String(format: "%.2f", delay),
      "reason": reason,
    ]
    if let activation {
      payload["key"] = activation.key
      payload["token"] = "\(activation.value)"
      payload["currentToken"] = activationSession.currentToken(for: activation.key).map { String($0.value) } ?? "none"
    }
    AppDiagnostics.log(event, payload)
    if event != "app_foreground_repair_stale_ignored" {
      AppDiagnostics.log("app_foreground_repair_stale_ignored", payload)
    }
  }

  private func scheduleAppActivationWorkItem(
    activation: AppActivationToken?,
    fallbackKey: String?,
    bundleID: String?,
    delay: TimeInterval,
    reason: String,
    execute: @MainActor @Sendable @escaping () -> Void
  ) {
    activationSession.schedule(
      activation: activation, fallbackKey: fallbackKey, delay: delay, execute: execute,
      onStale: { [weak self] in
        self?.logStaleAppActivationIgnored(
          event: "app_foreground_repair_stale_ignored", bundleID: bundleID,
          activation: activation, delay: delay, reason: reason)
      })
  }

  private func cancelAppActivationWorkItems(for key: String, reason: String) {
    let count = activationSession.cancelScheduled(for: key)
    guard count > 0 else { return }
    AppDiagnostics.log(
      "app_foreground_repair_owner_cancelled",
      ["count": "\(count)", "key": key, "reason": reason])
  }

  private func completeAppForegroundRepairOwner(
    for app: NSRunningApplication, activation: AppActivationToken?, reason: String
  ) {
    guard let key = activation?.key ?? activationKey(for: app),
      let token = activation ?? activationSession.currentToken(for: key),
      activationSession.isCurrent(token)
    else { return }
    activationSession.complete(token)
    AppDiagnostics.log(
      "app_foreground_repair_owner_completed",
      ["app": app.localizedName ?? "App", "bundle": app.bundleIdentifier ?? "",
       "key": key, "reason": reason, "token": "\(token.value)"])
  }

  private func markAppForegroundActivationPending(
    _ bundleID: String,
    at now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    appForegroundPendingUntil[bundleID] = now + appForegroundPendingInterval
  }

  private func clearAppForegroundActivationPending(_ bundleID: String) {
    appForegroundPendingUntil.removeValue(forKey: bundleID)
  }

  private func isAppForegroundActivationPending(
    _ bundleID: String,
    at now: TimeInterval
  ) -> Bool {
    guard let pendingUntil = appForegroundPendingUntil[bundleID] else { return false }
    if now <= pendingUntil {
      return true
    }
    appForegroundPendingUntil.removeValue(forKey: bundleID)
    return false
  }

  @discardableResult
  private func clearForegroundActivationIfSatisfied(
    _ app: NSRunningApplication,
    ensureWindow: Bool,
    activation: AppActivationToken? = nil
  ) -> Bool {
    guard isAppActivationCurrent(activation) else { return false }
    guard appActivationIsSatisfied(app, ensureWindow: ensureWindow) else { return false }
    if let bundleID = app.bundleIdentifier {
      clearAppForegroundActivationPending(bundleID)
    }
    completeAppForegroundRepairOwner(for: app, activation: activation, reason: "satisfied")
    return true
  }

  private func markAppRecentlyHidden(_ bundleID: String, at now: TimeInterval) {
    recentlyHiddenAppBundleIDs[bundleID] = now + appRecentlyHiddenInterval
  }

  private func isAppRecentlyHidden(_ bundleID: String, at now: TimeInterval) -> Bool {
    guard let hiddenUntil = recentlyHiddenAppBundleIDs[bundleID] else { return false }
    if now < hiddenUntil {
      return true
    }
    recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
    return false
  }

  private func shouldActivateRunningApp(
    _ app: NSRunningApplication,
    activation: AppActivationToken?
  ) -> Bool {
    guard isAppActivationCurrent(activation) else { return false }
    if let bundleID = app.bundleIdentifier,
      isAppRecentlyHidden(bundleID, at: ProcessInfo.processInfo.systemUptime)
    {
      return false
    }
    return true
  }

  private func appActivationIsSatisfied(
    _ app: NSRunningApplication,
    ensureWindow: Bool
  ) -> Bool {
    guard isFrontmost(app), !app.isHidden else { return false }
    guard ensureWindow else { return true }
    guard hasVisibleWindow(for: app) else {
      logWindowLevelSnapshot(for: app, event: "app_window_level_check", reason: "no_visible_window")
      return false
    }
    let snapshot = windowLevelSnapshot(for: app)
    var payload = snapshot.payload
    payload["app"] = app.localizedName ?? "App"
    payload["bundle"] = app.bundleIdentifier ?? ""
    payload["reason"] = "activation_satisfied_check"
    AppDiagnostics.log("app_window_level_check", payload)
    guard snapshot.targetWindowRank != nil else {
      return true
    }
    return snapshot.targetWindowTopmost
  }

  @discardableResult
  func toggleRunningApp(named name: String, mode: OpenAppTriggerMode = .toggle) -> Bool {
    guard !stopped else { return false }
    guard let app = preferredRunningApplication(named: name) else {
      return false
    }
    toggleRunningApp(app, mode: mode)
    return true
  }

  func toggleRunningApp(_ app: NSRunningApplication, mode: OpenAppTriggerMode = .toggle) {
    guard !stopped else { return }
    let appName = app.localizedName ?? "App"
    let bundleID = app.bundleIdentifier
    let appActivationKey = activationKey(for: app)
    let now = ProcessInfo.processInfo.systemUptime
    let wasJustHidden = bundleID.map { isAppRecentlyHidden($0, at: now) } ?? false
    let activationPending =
      bundleID.map { isAppForegroundActivationPending($0, at: now) } ?? false
    AppDiagnostics.log(
      "app_toggle_start",
      [
        "app": appName,
        "bundle": bundleID ?? "",
        "frontmost": "\(isFrontmost(app))",
        "hidden": "\(app.isHidden)",
        "mode": mode == .activateOnly ? "activateOnly" : "toggle",
        "pendingActivation": "\(activationPending)",
        "wasJustHidden": "\(wasJustHidden)",
      ])

    if mode == .activateOnly {
      if let bundleID {
        recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
      }
      if clearForegroundActivationIfSatisfied(app, ensureWindow: true) {
        AppDiagnostics.log(
          "app_toggle_branch",
          [
            "app": appName,
            "branch": "activate_only_already_front",
            "bundle": bundleID ?? "",
          ])
        AppDiagnostics.log(
          "app_activate_only_already_front",
          ["app": appName, "bundle": bundleID ?? ""]
        )
        return
      }
      AppDiagnostics.log(
        "app_toggle_branch",
        ["app": appName, "branch": "activate_only", "bundle": bundleID ?? ""])
      bringAppToFront(app, ensureWindow: true)
      return
    }

    if wasJustHidden {
      if let bundleID {
        recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
      }
      AppDiagnostics.log(
        "app_toggle_branch",
        ["app": appName, "branch": "recently_hidden_reopen", "bundle": bundleID ?? ""])
      bringAppToFront(app, ensureWindow: true)
      return
    }

    if let bundleID, activationPending {
      if clearForegroundActivationIfSatisfied(app, ensureWindow: true) {
        AppDiagnostics.log(
          "app_toggle_branch",
          [
            "app": appName,
            "branch": "activation_pending_satisfied_continue_to_hide",
            "bundle": bundleID,
          ])
        // Fall through to normal hide handling when the previous activation really reached front.
      } else {
        recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
        AppDiagnostics.log(
          "app_toggle_branch",
          ["app": appName, "branch": "activation_pending_activate", "bundle": bundleID])
        bringAppToFront(app, ensureWindow: true)
        return
      }
    }

    if isFrontmost(app), !app.isHidden {
      invalidateAppActivation(for: appActivationKey)
      AppDiagnostics.log(
        "app_toggle_branch", ["app": appName, "branch": "hide", "bundle": bundleID ?? ""])
      AppDiagnostics.log("app_hide_start", ["app": appName, "bundle": bundleID ?? ""])
      let didHide = app.hide()
      if let bundleID {
        clearAppForegroundActivationPending(bundleID)
        markAppRecentlyHidden(bundleID, at: now)
      }
      AppDiagnostics.log(
        "app_hide_finished",
        [
          "app": appName,
          "bundle": bundleID ?? "",
          "didHide": "\(didHide)",
          "frontmostAfter": "\(isFrontmost(app))",
          "hiddenAfter": "\(app.isHidden)",
        ])
      if !didHide {
        let hideOwner = issueAppActivationToken(for: appActivationKey)
        scheduleAppActivationWorkItem(
          activation: hideOwner, fallbackKey: appActivationKey, bundleID: bundleID,
          delay: 0.16, reason: "hide_feedback"
        ) { [weak self, weak app] in
          guard let self, let app else { return }
          guard self.isFrontmost(app), !app.isHidden else { return }
          if let bundleID = app.bundleIdentifier {
            self.recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
          }
          self.statusMessage = "暂时无法隐藏：\(appName)"
        }
      }
      return
    }
    if let bundleID {
      recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
    }
    AppDiagnostics.log(
      "app_toggle_branch",
      ["app": appName, "branch": "activate", "bundle": bundleID ?? ""])
    bringAppToFront(app, ensureWindow: true)
  }

  private func bringAppToFront(
    _ app: NSRunningApplication,
    ensureWindow: Bool = false,
    activation: AppActivationToken? = nil
  ) {
    let appActivationKey = activation?.key ?? activationKey(for: app)
    cancelStaleAppActivations(keeping: appActivationKey)
    let createdActivation = activation == nil
    let activation = activation ?? issueAppActivationToken(for: appActivationKey)
    if !createdActivation, let activation {
      cancelAppActivationWorkItems(for: activation.key, reason: "owner_rescheduled")
    }
    AppDiagnostics.log(
      "app_foreground_focus_token_started",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "key": appActivationKey ?? "",
        "token": activation.map { "\($0.value)" } ?? "",
      ])
    if createdActivation, let bundleID = app.bundleIdentifier {
      recentlyHiddenAppBundleIDs.removeValue(forKey: bundleID)
    }
    guard shouldActivateRunningApp(app, activation: activation) else {
      AppDiagnostics.log(
        "app_toggle_branch",
        [
          "app": app.localizedName ?? "App",
          "branch": "activation_skipped_recently_hidden_or_stale",
          "bundle": app.bundleIdentifier ?? "",
        ])
      return
    }
    if let bundleID = app.bundleIdentifier {
      markAppForegroundActivationPending(bundleID)
    }

    _ = activateRunningAppFast(
      app,
      ensureWindow: ensureWindow,
      activation: activation
    )
    if clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) {
      return
    }
    activateRunningAppThroughWorkspace(app, activation: activation)

    for delay in appActivationRetryDelays {
      scheduleAppActivationWorkItem(
        activation: activation,
        fallbackKey: appActivationKey,
        bundleID: app.bundleIdentifier,
        delay: delay,
        reason: "fast_retry"
      ) { [weak self, weak app] in
        guard let self, let app else { return }
        guard self.shouldActivateRunningApp(app, activation: activation) else { return }
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
          return
        }
        _ = self.activateRunningAppFast(app, activation: activation)
      }
    }

    scheduleAppActivationWorkItem(
      activation: activation,
      fallbackKey: appActivationKey,
      bundleID: app.bundleIdentifier,
      delay: appActivationSystemRetryDelay,
      reason: "workspace_retry"
    ) { [weak self, weak app] in
      guard let self, let app else { return }
      guard self.shouldActivateRunningApp(app, activation: activation) else { return }
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
        return
      }
      self.activateRunningAppThroughWorkspace(app, activation: activation)
    }

    scheduleAppActivationWorkItem(
      activation: activation,
      fallbackKey: appActivationKey,
      bundleID: app.bundleIdentifier,
      delay: appActivationAppleScriptRetryDelay,
      reason: "applescript_retry"
    ) { [weak self, weak app] in
      guard let self, let app else { return }
      guard self.shouldActivateRunningApp(app, activation: activation) else { return }
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
        return
      }
      self.activateRunningAppThroughAppleScript(app, activation: activation)
    }

    if let bundleID = app.bundleIdentifier {
      scheduleAppForegroundVerification(
        bundleID: bundleID,
        ensureWindow: ensureWindow,
        activation: activation
      )
    }

    guard ensureWindow else { return }
    scheduleAppActivationWorkItem(
      activation: activation,
      fallbackKey: appActivationKey,
      bundleID: app.bundleIdentifier,
      delay: appActivationRepairDelay,
      reason: "window_repair"
    ) { [weak self, weak app] in
      guard let self, let app else { return }
      guard self.shouldActivateRunningApp(app, activation: activation) else { return }
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: true, activation: activation) else { return }
      self.repairAndActivateRunningApp(app, ensureWindow: true, activation: activation)
    }

    scheduleAppActivationWorkItem(
      activation: activation,
      fallbackKey: appActivationKey,
      bundleID: app.bundleIdentifier,
      delay: appActivationSettleRetryDelay,
      reason: "settle_retry"
    ) { [weak self, weak app] in
      guard let self, let app else { return }
      guard self.shouldActivateRunningApp(app, activation: activation) else { return }
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
        return
      }
      _ = self.activateRunningAppFast(app, activation: activation)
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
        return
      }
      self.activateRunningAppThroughWorkspace(app, activation: activation)
    }
  }

  private func scheduleAppForegroundVerification(
    bundleID: String,
    ensureWindow: Bool,
    activation: AppActivationToken?
  ) {
    markAppForegroundActivationPending(bundleID)
    for delay in appForegroundVerifierDelays {
      scheduleAppActivationWorkItem(
        activation: activation,
        fallbackKey: activationKey(forBundleID: bundleID),
        bundleID: bundleID,
        delay: delay,
        reason: "foreground_verify"
      ) { [weak self] in
        guard let self else { return }
        guard let app = self.preferredRunningApplication(bundleID: bundleID) else { return }
        guard self.shouldActivateRunningApp(app, activation: activation) else { return }
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
          return
        }

        AppDiagnostics.log(
          "app_foreground_verify",
          [
            "bundle": bundleID,
            "delay": String(format: "%.2f", delay),
            "frontmost": "\(self.isFrontmost(app))",
          ])

        _ = self.activateRunningAppFast(app, ensureWindow: ensureWindow, activation: activation)
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation) else {
          return
        }

        if delay >= 0.12 {
          self.activateRunningAppThroughWorkspace(app, activation: activation)
        }
        if delay >= 0.36 {
          self.activateRunningAppThroughAppleScript(app, activation: activation)
        }
        if delay >= 0.85 {
          self.repairAndActivateRunningApp(
            app,
            ensureWindow: ensureWindow,
            activation: activation
          )
        }
        _ = self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow, activation: activation)
      }
    }
  }

  private func reinforceColdLaunchForeground(
    bundleID: String,
    activation: AppActivationToken?
  ) {
    var didReachFront = false
    for delay in appColdLaunchForegroundRetryDelays {
      scheduleAppActivationWorkItem(
        activation: activation,
        fallbackKey: activationKey(forBundleID: bundleID),
        bundleID: bundleID,
        delay: delay,
        reason: "cold_launch_reinforce"
      ) { [weak self] in
        guard let self else { return }
        guard !didReachFront else { return }
        guard let app = self.preferredRunningApplication(bundleID: bundleID) else { return }
        guard self.shouldActivateRunningApp(app, activation: activation) else { return }

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true, activation: activation) {
          didReachFront = true
          return
        }

        AppDiagnostics.log(
          "app_cold_launch_reinforce",
          ["bundle": bundleID, "delay": String(format: "%.2f", delay)])
        _ = self.activateRunningAppFast(app, ensureWindow: true, activation: activation)

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true, activation: activation) {
          didReachFront = true
          return
        }

        if delay >= 1.0 {
          self.activateRunningAppThroughAppleScript(app, activation: activation)
        } else {
          self.activateRunningAppThroughWorkspace(app, activation: activation)
        }

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true, activation: activation) {
          didReachFront = true
        }
      }
    }
  }

  private func activateRunningAppFast(
    _ app: NSRunningApplication,
    ensureWindow: Bool = true,
    activation: AppActivationToken? = nil
  ) -> Bool {
    guard shouldActivateRunningApp(app, activation: activation) else { return false }
    let appName = app.localizedName ?? "App"
    AppDiagnostics.log(
      "app_activate_fast_start", ["app": appName, "bundle": app.bundleIdentifier ?? ""])
    app.unhide()
    let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    let axFrontmost = isFrontmost(app) ? true : forceFrontmostThroughAccessibility(app)
    restoreAndRaiseWindows(for: app)
    if !isFrontmost(app) {
      _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    let satisfied = appActivationIsSatisfied(app, ensureWindow: ensureWindow)
    AppDiagnostics.log(
      "app_activate_fast_end",
      [
        "activated": "\(activated)", "app": appName, "axFrontmost": "\(axFrontmost)",
        "frontmost": "\(isFrontmost(app))",
        "satisfied": "\(satisfied)",
      ])
    return satisfied
  }

  private func activateRunningAppThroughWorkspace(
    _ app: NSRunningApplication,
    activation: AppActivationToken? = nil
  ) {
    guard shouldActivateRunningApp(app, activation: activation) else { return }
    app.unhide()
    restoreAndRaiseWindows(for: app)

    if let url = app.bundleURL {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      configuration.addsToRecentItems = false
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
        [weak self, weak app] openedApp, _ in
        DispatchQueue.main.async {
          guard let self, let app = openedApp ?? app else { return }
          guard self.shouldActivateRunningApp(app, activation: activation) else { return }
          _ = self.activateRunningAppFast(app, activation: activation)
          self.restoreAndRaiseWindows(for: app)
          guard !self.appActivationIsSatisfied(app, ensureWindow: true) else { return }
          self.activateRunningAppThroughAppleScript(app, activation: activation)
        }
      }
      return
    }

    reopenRunningApplication(app, activation: activation)
    _ = activateRunningAppFast(app, activation: activation)
    activateRunningAppThroughAppleScript(app, activation: activation)
  }

  private func activateRunningAppThroughAppleScript(
    _ app: NSRunningApplication,
    activation: AppActivationToken? = nil
  ) {
    guard shouldActivateRunningApp(app, activation: activation) else { return }
    guard let bundleID = app.bundleIdentifier else { return }
    let script = """
      tell application id "\(bundleID)" to activate
      tell application "System Events"
        repeat 4 times
          try
            set frontmost of first application process whose unix id is \(app.processIdentifier) to true
          end try
          try
            if exists (first application process whose bundle identifier is "\(bundleID)") then
              set targetProcess to first application process whose bundle identifier is "\(bundleID)"
              set frontmost of targetProcess to true
              if frontmost of targetProcess then exit repeat
            end if
          end try
          delay 0.03
        end repeat
      end tell
      """
    runOwnedProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-e", script], activation: activation, timeout: 2
    ) { [weak self, weak app] result in
      guard let self, let app else { return }
      guard self.isAppActivationCurrent(activation) else {
        self.logStaleAppActivationIgnored(
          event: "app_foreground_repair_stale_ignored",
          bundleID: bundleID,
          activation: activation,
          delay: 0,
          reason: "applescript_returned_after_owner_changed")
        return
      }
      self.restoreAndRaiseWindows(for: app)
      if !self.isFrontmost(app) {
        _ = self.forceFrontmostThroughAccessibility(app)
      }
      AppDiagnostics.log(
        "app_applescript_activate",
        [
          "app": app.localizedName ?? "App",
          "bundle": bundleID,
          "frontmost": "\(self.isFrontmost(app))",
          "ok": "\(result.succeeded)",
        ])
    }
  }

  private func repairAndActivateRunningApp(
    _ app: NSRunningApplication,
    ensureWindow: Bool,
    activation: AppActivationToken? = nil
  ) {
    guard shouldActivateRunningApp(app, activation: activation) else { return }
    let appName = app.localizedName ?? "App"
    AppDiagnostics.log("app_repair_start", ["app": appName, "bundle": app.bundleIdentifier ?? ""])
    app.unhide()
    restoreAndRaiseWindows(for: app)
    if ensureWindow, hasNoUsableWindow(for: app) {
      reopenRunningApplication(app, activation: activation)
    }
    activateRunningAppThroughWorkspace(app, activation: activation)
    restoreAndRaiseWindows(for: app)
    AppDiagnostics.log("app_repair_end", ["app": appName, "frontmost": "\(isFrontmost(app))"])
  }

  private func restoreAndRaiseWindows(for app: NSRunningApplication) {
    guard AXIsProcessTrusted() else { return }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let window =
      AccessibilityWindowQueries.focusedWindow(for: appElement) ?? AccessibilityWindowQueries.controllableWindow(for: appElement)
      ?? axWindows(for: app).first
    guard let window else { return }
    let title = AccessibilityWindowQueries.axWindowTitle(window)
    let minimizedBefore = AccessibilityWindowQueries.isWindowMinimized(window)
    let setMinimized = AXUIElementSetAttributeValue(
      window,
      kAXMinimizedAttribute as CFString,
      kCFBooleanFalse
    )
    let setMain = AXUIElementSetAttributeValue(
      window,
      kAXMainAttribute as CFString,
      kCFBooleanTrue
    )
    let setFocused = AXUIElementSetAttributeValue(
      window,
      kAXFocusedAttribute as CFString,
      kCFBooleanTrue
    )
    let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AppDiagnostics.log(
      "app_window_ax_raise",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "minimizedBefore": "\(minimizedBefore)",
        "raise": "\(raise.rawValue)",
        "setFocused": "\(setFocused.rawValue)",
        "setMain": "\(setMain.rawValue)",
        "setMinimized": "\(setMinimized.rawValue)",
        "title": title,
      ])
  }

  @discardableResult
  private func forceFrontmostThroughAccessibility(_ app: NSRunningApplication) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let result = AXUIElementSetAttributeValue(
      appElement,
      kAXFrontmostAttribute as CFString,
      kCFBooleanTrue
    )
    restoreAndRaiseWindows(for: app)
    let frontmost = isFrontmost(app)
    AppDiagnostics.log(
      "app_ax_frontmost",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "frontmost": "\(frontmost)",
        "result": "\(result.rawValue)",
      ])
    return result == .success && frontmost
  }

  private func hasNoUsableWindow(for app: NSRunningApplication) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    return axWindows(for: app).allSatisfy { window in
      var rawMinimized: CFTypeRef?
      let minimized =
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
          == .success
        ? (rawMinimized as? Bool ?? false) : false
      return minimized
    }
  }

  private func hasVisibleWindow(for app: NSRunningApplication) -> Bool {
    guard AXIsProcessTrusted() else { return true }
    let windows = axWindows(for: app)
    guard !windows.isEmpty else { return false }
    return windows.contains { window in
      var rawMinimized: CFTypeRef?
      let minimized =
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
          == .success
        ? (rawMinimized as? Bool ?? false) : false
      return !minimized
    }
  }

  private func logWindowLevelSnapshot(
    for app: NSRunningApplication,
    event: String,
    reason: String
  ) {
    let snapshot = windowLevelSnapshot(for: app)
    var payload = snapshot.payload
    payload["app"] = app.localizedName ?? "App"
    payload["bundle"] = app.bundleIdentifier ?? ""
    payload["reason"] = reason
    AppDiagnostics.log(event, payload)
  }

  private func windowLevelSnapshot(for app: NSRunningApplication) -> AppWindowLevelSnapshot {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let infos =
      CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let visibleWindows = infos.filter(isStandardVisibleWindowInfo)
    let targetPID = app.processIdentifier
    let targetIndex = visibleWindows.firstIndex { windowInfoPID($0) == targetPID }
    let targetInfo = targetIndex.map { visibleWindows[$0] }
    let targetWindows = visibleWindows.filter { windowInfoPID($0) == targetPID }
    let topInfo = visibleWindows.first
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return AppWindowLevelSnapshot(
      targetWindowRank: targetIndex,
      targetWindowTitle: targetInfo.map(windowInfoTitle) ?? "",
      targetWindowCount: targetWindows.count,
      topPID: topInfo.flatMap(windowInfoPID),
      topOwner: topInfo.map(windowInfoOwner) ?? "",
      topTitle: topInfo.map(windowInfoTitle) ?? "",
      visibleWindowCount: visibleWindows.count,
      axFocusedTitle: AccessibilityWindowQueries.focusedWindow(for: appElement).map(AccessibilityWindowQueries.axWindowTitle) ?? "",
      axMainTitle: AccessibilityWindowQueries.mainWindow(for: appElement).map(AccessibilityWindowQueries.axWindowTitle) ?? ""
    )
  }

  private func isStandardVisibleWindowInfo(_ info: [String: Any]) -> Bool {
    guard (numberValue(info[kCGWindowLayer as String])?.intValue ?? 0) == 0 else {
      return false
    }
    let alpha = numberValue(info[kCGWindowAlpha as String])?.doubleValue ?? 1
    guard alpha > 0 else { return false }
    guard let bounds = windowInfoBounds(info) else { return true }
    return bounds.width >= 80 && bounds.height >= 60
  }

  private func windowInfoPID(_ info: [String: Any]) -> pid_t? {
    guard let number = numberValue(info[kCGWindowOwnerPID as String]) else { return nil }
    return pid_t(number.intValue)
  }

  private func windowInfoOwner(_ info: [String: Any]) -> String {
    (info[kCGWindowOwnerName as String] as? String) ?? ""
  }

  private func windowInfoTitle(_ info: [String: Any]) -> String {
    (info[kCGWindowName as String] as? String) ?? ""
  }

  private func windowInfoBounds(_ info: [String: Any]) -> CGRect? {
    guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    let width = numberValue(bounds["Width"])?.doubleValue ?? 0
    let height = numberValue(bounds["Height"])?.doubleValue ?? 0
    let x = numberValue(bounds["X"])?.doubleValue ?? 0
    let y = numberValue(bounds["Y"])?.doubleValue ?? 0
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func numberValue(_ value: Any?) -> NSNumber? {
    if let number = value as? NSNumber { return number }
    if let double = value as? Double { return NSNumber(value: double) }
    if let int = value as? Int { return NSNumber(value: int) }
    return nil
  }

  private func axWindows(for app: NSRunningApplication) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var rawWindows: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        == .success,
      let windows = rawWindows as? [AXUIElement]
    else {
      return []
    }
    return windows
  }

  private func runOwnedProcess(
    executableURL: URL, arguments: [String], activation: AppActivationToken?,
    timeout: TimeInterval, completion: @escaping (BoundedProcessResult) -> Void
  ) {
    guard !stopped, activationSession.isCurrent(activation) else { return }
    var resourceID: UUID?
    let process = BoundedProcessExecution(
      executableURL: executableURL, arguments: arguments, timeout: timeout,
      outputByteLimit: 32_768
    ) { [weak self] result in
      guard let self else { return }
      if let resourceID { self.activationSession.releaseResource(resourceID) }
      guard !self.stopped else { return }
      completion(result)
    }
    resourceID = activationSession.retainResource(
      activation: activation, fallbackKey: activation?.key,
      cancel: { process.cancel() })
    guard resourceID != nil else { return }
    process.start()
  }

  private func reopenRunningApplication(
    _ app: NSRunningApplication, activation: AppActivationToken?
  ) {
    let arguments: [String]
    if let bundleID = app.bundleIdentifier {
      arguments = ["-b", bundleID]
    } else if let url = app.bundleURL {
      arguments = [url.path]
    } else { return }
    runOwnedProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"), arguments: arguments,
      activation: activation, timeout: 8, completion: { _ in })
  }

  @discardableResult
  private func openApplicationsUI() -> Bool {
    let opened = NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    guard opened else {
      statusMessage = "打开 App 软件界面失败。"
      return false
    }
    let finderKey = activationKey(forBundleID: "com.apple.finder")
    let owner = issueAppActivationToken(for: finderKey)
    scheduleAppActivationWorkItem(
      activation: owner, fallbackKey: finderKey, bundleID: "com.apple.finder",
      delay: 0.08, reason: "applications_folder"
    ) {
      NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.finder"
      })?
      .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    statusMessage = "已打开 App 软件界面。"
    return true
  }

  private func isFrontmost(_ app: NSRunningApplication) -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else {
      return app.isActive
    }
    if frontmost.processIdentifier == app.processIdentifier {
      return true
    }
    guard let frontBundleID = frontmost.bundleIdentifier, let appBundleID = app.bundleIdentifier
    else {
      return false
    }
    return frontBundleID == appBundleID
  }

  private func openApplication(
    at url: URL,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    let bundleID = Bundle(url: url)?.bundleIdentifier
    let requestKey = bundleID.map(activationKey(forBundleID:)) ?? "url:\(url.standardizedFileURL.path)"
    guard let activation = issueAppActivationToken(for: requestKey) else {
      completion?(false)
      return
    }
    if let bundleID {
      markAppForegroundActivationPending(bundleID)
      reinforceColdLaunchForeground(bundleID: bundleID, activation: activation)
      scheduleAppForegroundVerification(
        bundleID: bundleID,
        ensureWindow: true,
        activation: activation
      )
    }
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
      [weak self] app, error in
      DispatchQueue.main.async {
        guard let self, !self.stopped else { return }
        completion?(error == nil)
        guard self.isAppActivationCurrent(activation) else { return }
        if let error {
          self.statusMessage = "打开 App 失败：\(error.localizedDescription)"
          return
        }
        if let app = app ?? bundleID.flatMap({ self.preferredRunningApplication(bundleID: $0) }) {
          self.bringAppToFront(app, ensureWindow: true, activation: activation)
        }
        self.statusMessage =
          "已打开：\(app?.localizedName ?? url.deletingPathExtension().lastPathComponent)"
      }
    }
  }

}
