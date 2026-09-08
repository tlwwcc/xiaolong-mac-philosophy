import AppKit
import Carbon
import Foundation
import UniformTypeIdentifiers

enum InputMethodSourceSelectionOutcome {
  case success(sourceName: String, requestsMade: Int)
  case failure(String)
}

final class InputMethodSourceSelectionOperation {
  fileprivate var workItem: DispatchWorkItem?
  fileprivate var isFinished = false
  private(set) var isCancelled = false

  func cancel() {
    isCancelled = true
    workItem?.cancel()
    workItem = nil
  }

  fileprivate func finish(
    _ outcome: InputMethodSourceSelectionOutcome,
    completion: @escaping (InputMethodSourceSelectionOutcome) -> Void
  ) {
    guard !isCancelled, !isFinished else { return }
    isFinished = true
    workItem = nil
    completion(outcome)
  }
}

enum InputMethodSourceController {
  private enum SelectionRequestResult {
    case unchanged(String)
    case requested(String)
    case unavailable
    case failed(OSStatus)
  }

  private static let confirmationDelay: TimeInterval = 0.12

  static func availableSources() -> [InputMethodSourceDescriptor] {
    assertMainQueue()
    let sources =
      TISCreateInputSourceList(nil, false).takeRetainedValue() as? [TISInputSource] ?? []
    var seen = Set<String>()
    return
      sources
      .compactMap { source -> InputMethodSourceDescriptor? in
        guard property(source, kTISPropertyInputSourceIsEnabled) as Bool? == true,
          property(source, kTISPropertyInputSourceIsSelectCapable) as Bool? == true
        else { return nil }
        let sourceID: String = property(source, kTISPropertyInputSourceID) ?? ""
        let inputModeID: String? = property(source, kTISPropertyInputModeID)
        let name: String = property(source, kTISPropertyLocalizedName) ?? sourceID
        let languages: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
        let selectionID = inputModeID ?? sourceID
        guard !selectionID.isEmpty,
          sourceID != "com.apple.CharacterPaletteIM",
          seen.insert(selectionID).inserted
        else { return nil }
        return InputMethodSourceDescriptor(
          sourceID: sourceID,
          inputModeID: inputModeID,
          name: name,
          languages: languages)
      }
      .sorted { lhs, rhs in
        if lhs.sourceID == "com.apple.keylayout.ABC" { return true }
        if rhs.sourceID == "com.apple.keylayout.ABC" { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  static func currentSelectionID() -> String? {
    assertMainQueue()
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let modeID: String? = property(source, kTISPropertyInputModeID)
    let sourceID: String? = property(source, kTISPropertyInputSourceID)
    return modeID ?? sourceID
  }

  static func currentSourceName() -> String {
    assertMainQueue()
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return property(source, kTISPropertyLocalizedName) ?? "当前输入法"
  }

  @discardableResult
  static func select(
    selectionID: String,
    shouldContinue: @escaping () -> Bool = { true },
    completion: @escaping (InputMethodSourceSelectionOutcome) -> Void
  ) -> InputMethodSourceSelectionOperation {
    assertMainQueue()
    let operation = InputMethodSourceSelectionOperation()
    requestSelection(
      selectionID: selectionID,
      requestsMade: 1,
      operation: operation,
      shouldContinue: shouldContinue,
      completion: completion)
    return operation
  }

  private static func requestSelection(
    selectionID: String,
    requestsMade: Int,
    operation: InputMethodSourceSelectionOperation,
    shouldContinue: @escaping () -> Bool,
    completion: @escaping (InputMethodSourceSelectionOutcome) -> Void
  ) {
    guard !operation.isCancelled, shouldContinue() else {
      operation.cancel()
      return
    }

    switch requestSelectionOnce(selectionID: selectionID) {
    case .unchanged(let name):
      operation.finish(
        .success(sourceName: name, requestsMade: max(0, requestsMade - 1)),
        completion: completion)
    case .requested(let name):
      scheduleConfirmation(
        selectionID: selectionID,
        sourceName: name,
        requestsMade: requestsMade,
        operation: operation,
        shouldContinue: shouldContinue,
        completion: completion)
    case .unavailable:
      operation.finish(
        .failure("目标输入法当前未启用或已从系统移除；规则已保留，请刷新输入法后重新选择。"),
        completion: completion)
    case .failed(let status):
      operation.finish(
        .failure("macOS 拒绝了第 \(requestsMade) 次切换请求（TIS 状态码 \(status)）；未继续重试。"),
        completion: completion)
    }
  }

  private static func scheduleConfirmation(
    selectionID: String,
    sourceName: String,
    requestsMade: Int,
    operation: InputMethodSourceSelectionOperation,
    shouldContinue: @escaping () -> Bool,
    completion: @escaping (InputMethodSourceSelectionOutcome) -> Void
  ) {
    let workItem = DispatchWorkItem {
      guard !operation.isCancelled, shouldContinue() else {
        operation.cancel()
        return
      }

      switch InputMethodBoundedSelectionPolicy.nextAction(
        currentSelectionID: currentSelectionID(),
        targetSelectionID: selectionID,
        requestsMade: requestsMade)
      {
      case .confirmed:
        operation.finish(
          .success(sourceName: sourceName, requestsMade: requestsMade),
          completion: completion)
      case .retry:
        requestSelection(
          selectionID: selectionID,
          requestsMade: requestsMade + 1,
          operation: operation,
          shouldContinue: shouldContinue,
          completion: completion)
      case .stopUnconfirmed:
        operation.finish(
          .failure(
            "macOS 已接受两次切换请求，但 240 毫秒内都未确认生效。已停止重试；请检查目标输入法，或先结束中文组词再试。"
          ),
          completion: completion)
      }
    }
    operation.workItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + confirmationDelay, execute: workItem)
  }

  private static func requestSelectionOnce(selectionID: String) -> SelectionRequestResult {
    let sources =
      TISCreateInputSourceList(nil, false).takeRetainedValue() as? [TISInputSource] ?? []
    guard
      let target = sources.first(where: { source in
        guard property(source, kTISPropertyInputSourceIsEnabled) as Bool? == true,
          property(source, kTISPropertyInputSourceIsSelectCapable) as Bool? == true
        else { return false }
        let modeID: String? = property(source, kTISPropertyInputModeID)
        let sourceID: String? = property(source, kTISPropertyInputSourceID)
        return modeID == selectionID || sourceID == selectionID
      })
    else { return .unavailable }

    let name: String = property(target, kTISPropertyLocalizedName) ?? selectionID
    if currentSelectionID() == selectionID {
      return .unchanged(name)
    }
    let status = TISSelectInputSource(target)
    guard status == noErr else { return .failed(status) }
    return .requested(name)
  }

  private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
  }

  private static func assertMainQueue() {
    dispatchPrecondition(condition: .onQueue(.main))
  }
}

@MainActor
final class InputMethodPluginEngine {
  typealias Configuration = (
    enabled: Bool, rules: [InputMethodAppRule], suppressApplicationRules: Bool
  )

  private let configuration: () -> Configuration
  private let onStatus: (InputMethodPluginStatus) -> Void
  private var observers: [NSObjectProtocol] = []
  private var pendingSwitch: DispatchWorkItem?
  private var pendingSelection: InputMethodSourceSelectionOperation?
  private var wasBlockedByConflict = false

  init(
    configuration: @escaping () -> Configuration,
    onStatus: @escaping (InputMethodPluginStatus) -> Void
  ) {
    self.configuration = configuration
    self.onStatus = onStatus
  }

  func start() {
    removeObservers()
    pendingSwitch?.cancel()
    pendingSwitch = nil
    pendingSelection?.cancel()
    pendingSelection = nil
    wasBlockedByConflict = false

    let config = configuration()
    guard config.enabled else {
      onStatus(.stopped)
      return
    }

    let center = NSWorkspace.shared.notificationCenter
    observers = [
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
              as? NSRunningApplication
          else { return }
          self?.handleActivation(app)
        }
      },
      center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshSafetyState() }
      },
      center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshSafetyState() }
      },
    ]
    refreshSafetyState()
  }

  func stop() {
    pendingSwitch?.cancel()
    pendingSwitch = nil
    pendingSelection?.cancel()
    pendingSelection = nil
    wasBlockedByConflict = false
    removeObservers()
    onStatus(.stopped)
  }

  private func refreshSafetyState() {
    let config = configuration()
    guard config.enabled else {
      wasBlockedByConflict = false
      onStatus(.stopped)
      return
    }
    let conflicts = Self.runningConflictNames()
    guard conflicts.isEmpty else {
      wasBlockedByConflict = true
      pendingSwitch?.cancel()
      pendingSwitch = nil
      pendingSelection?.cancel()
      pendingSelection = nil
      onStatus(.conflict(conflicts))
      return
    }
    let shouldReapplyCurrentRule = InputMethodConflictRecoveryPolicy.shouldReapplyCurrentRule(
      wasBlockedByConflict: wasBlockedByConflict,
      pluginEnabled: config.enabled,
      conflictsAreClear: true,
      hasFrontmostApplication: NSWorkspace.shared.frontmostApplication != nil)
    wasBlockedByConflict = false
    let enabledCount = config.rules.filter(\.enabled).count
    onStatus(enabledCount == 0 ? .noRules : .ready(enabledCount))
    if shouldReapplyCurrentRule, let app = NSWorkspace.shared.frontmostApplication {
      handleActivation(app)
    }
  }

  private func handleActivation(_ app: NSRunningApplication) {
    pendingSwitch?.cancel()
    pendingSwitch = nil
    pendingSelection?.cancel()
    pendingSelection = nil

    let config = configuration()
    guard config.enabled else { return }
    guard !config.suppressApplicationRules else { return }
    let conflicts = Self.runningConflictNames()
    guard conflicts.isEmpty else {
      wasBlockedByConflict = true
      onStatus(.conflict(conflicts))
      return
    }

    let decision = InputMethodRuleResolver.decision(
      pluginEnabled: config.enabled,
      bundleIdentifier: app.bundleIdentifier,
      currentSelectionID: InputMethodSourceController.currentSelectionID(),
      rules: config.rules)
    guard case .switchTo(let selectionID) = decision else {
      if decision == .alreadySelected {
        onStatus(.ready(config.rules.filter(\.enabled).count))
      }
      return
    }

    let appPID = app.processIdentifier
    let appName = app.localizedName ?? app.bundleIdentifier ?? "当前 App"
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingSwitch = nil
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == appPID else { return }

      let latest = self.configuration()
      guard !latest.suppressApplicationRules else { return }
      let latestDecision = InputMethodRuleResolver.decision(
        pluginEnabled: latest.enabled,
        bundleIdentifier: app.bundleIdentifier,
        currentSelectionID: InputMethodSourceController.currentSelectionID(),
        rules: latest.rules)
      guard case .switchTo(let latestSelectionID) = latestDecision,
        latestSelectionID == selectionID,
        Self.runningConflictNames().isEmpty
      else { return }

      self.pendingSelection = InputMethodSourceController.select(
        selectionID: selectionID,
        shouldContinue: { [weak self] in
          guard let self,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == appPID
          else { return false }
          let latest = self.configuration()
          guard latest.enabled, !latest.suppressApplicationRules,
            Self.runningConflictNames().isEmpty
          else { return false }
          return InputMethodRuleResolver.decision(
            pluginEnabled: latest.enabled,
            bundleIdentifier: app.bundleIdentifier,
            currentSelectionID: nil,
            rules: latest.rules) == .switchTo(selectionID)
        },
        completion: { [weak self] outcome in
          guard let self else { return }
          self.pendingSelection = nil
          switch outcome {
          case .success(let sourceName, let requestsMade):
            self.onStatus(
              .switched(
                appName: appName,
                sourceName: sourceName,
                requestsMade: requestsMade))
          case .failure(let message):
            self.onStatus(.failed("为 \(appName) 切换失败：\(message)"))
          }
        })
    }
    pendingSwitch = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
  }

  private func removeObservers() {
    let center = NSWorkspace.shared.notificationCenter
    observers.forEach(center.removeObserver)
    observers.removeAll()
  }

  static func runningConflictNames() -> [String] {
    let ownBundleID = Bundle.main.bundleIdentifier
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return Array(
      Set(
        NSWorkspace.shared.runningApplications.compactMap { app -> String? in
          guard !app.isTerminated,
            app.processIdentifier != ownPID,
            app.bundleIdentifier != ownBundleID,
            let name = app.localizedName,
            InputMethodConflictMatcher.isCompetingTool(name: name)
          else { return nil }
          return name
        })
    )
    .sorted()
  }
}

extension AppModel {
  static let inputMethodPluginID = "input-method-manager"
  static let inputMethodPluginEnabledDefaultsKey = "inputMethodPluginEnabledV1"
  static let inputMethodLauncherRuleSeededDefaultsKey = "inputMethodLauncherRuleSeededV1"

  var inputMethodCandidateApps: [InputMethodAppCandidate] {
    var candidates = NSWorkspace.shared.runningApplications
      .compactMap { app -> InputMethodAppCandidate? in
        guard !app.isTerminated,
          app.activationPolicy == .regular,
          let bundleID = app.bundleIdentifier,
          let path = app.bundleURL?.path
        else { return nil }
        return InputMethodAppCandidate(
          name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? bundleID,
          bundleIdentifier: bundleID,
          path: path)
      }

    if let ownBundleID = Bundle.main.bundleIdentifier {
      let ownURL = Bundle.main.bundleURL
      let ownName =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? ownURL.deletingPathExtension().lastPathComponent
      candidates.append(
        InputMethodAppCandidate(
          name: ownName,
          bundleIdentifier: ownBundleID,
          path: ownURL.path))
      candidates.append(
        InputMethodAppCandidate(
          name: "小龙哥启动器",
          bundleIdentifier: InputMethodBuiltInTarget.launcherIdentifier,
          path: ownURL.path))
    }

    return InputMethodAppCandidateResolver.normalized(
      candidates,
      ownBundleIdentifier: Bundle.main.bundleIdentifier)
  }

  func reloadInputMethodPlugin() {
    refreshInputMethodSources()
    guard hasGlobalInputOwnership else {
      inputMethodPluginEngine?.stop()
      inputMethodPluginStatus = .stopped
      return
    }
    if inputMethodPluginEngine == nil {
      inputMethodPluginEngine = InputMethodPluginEngine(
        configuration: { [weak self] in
          guard let self else { return (false, [], false) }
          return (
            self.inputMethodPluginEnabled,
            self.inputMethodRules,
            self.launcherInputMethodOverrideActive
          )
        },
        onStatus: { [weak self] status in
          DispatchQueue.main.async {
            self?.inputMethodPluginStatus = status
          }
        })
    }
    inputMethodPluginEngine?.start()
  }

  func setInputMethodPluginEnabled(_ enabled: Bool) {
    inputMethodPluginEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.inputMethodPluginEnabledDefaultsKey)
    if enabled {
      reloadInputMethodPlugin()
    } else {
      inputMethodPluginEngine?.stop()
    }
    statusMessage =
      enabled
      ? "输入法管家已开启；只在切换前台 App 时按规则执行。"
      : "输入法管家已关闭。"
  }

  func refreshInputMethodSources() {
    inputMethodSources = InputMethodSourceController.availableSources()
    refreshInputMethodRuleDiagnostics()
  }

  func addInputMethodRule(_ candidate: InputMethodAppCandidate) {
    refreshInputMethodSources()
    guard
      let selectionID = InputMethodSourceController.currentSelectionID()
        ?? inputMethodSources.first?.selectionID
    else {
      inputMethodPluginStatus = .failed("系统没有可用的键盘输入法。")
      return
    }

    if let index = inputMethodRules.firstIndex(where: {
      $0.bundleIdentifier.caseInsensitiveCompare(candidate.bundleIdentifier) == .orderedSame
    }) {
      inputMethodRules[index].appName = candidate.name
      inputMethodRules[index].appPath = candidate.path
      inputMethodRules[index].enabled = true
    } else {
      inputMethodRules.append(
        InputMethodAppRule(
          id: UUID().uuidString,
          appName: candidate.name,
          bundleIdentifier: candidate.bundleIdentifier,
          appPath: candidate.path,
          sourceSelectionID: selectionID,
          enabled: true))
    }
    saveInputMethodRulesAndReload(message: "已添加 \(candidate.name)；默认使用当前输入法。")
  }

  func chooseInputMethodRuleApp() {
    let panel = NSOpenPanel()
    panel.title = "选择要设置输入法的 App"
    panel.prompt = "添加"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url,
        let bundle = Bundle(url: url),
        let bundleID = bundle.bundleIdentifier
      else { return }
      let name =
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
      self?.addInputMethodRule(
        InputMethodAppCandidate(name: name, bundleIdentifier: bundleID, path: url.path))
    }
  }

  func setInputMethodRuleEnabled(id: String, enabled: Bool) {
    guard let index = inputMethodRules.firstIndex(where: { $0.id == id }) else { return }
    inputMethodRules[index].enabled = enabled
    saveInputMethodRulesAndReload(message: "输入法规则已更新。")
  }

  func setInputMethodRuleSource(id: String, selectionID: String) {
    guard inputMethodSources.contains(where: { $0.selectionID == selectionID }),
      let index = inputMethodRules.firstIndex(where: { $0.id == id })
    else { return }
    inputMethodRules[index].sourceSelectionID = selectionID
    saveInputMethodRulesAndReload(message: "输入法规则已更新。")
  }

  func removeInputMethodRule(id: String) {
    guard let rule = inputMethodRules.first(where: { $0.id == id }) else { return }
    inputMethodRules.removeAll(where: { $0.id == id })
    saveInputMethodRulesAndReload(message: "已移除 \(rule.appName) 的输入法规则。")
  }

  func testInputMethodSource(selectionID: String) {
    inputMethodManualSelection?.cancel()
    statusMessage = "正在确认输入法切换结果…"
    inputMethodManualSelection = InputMethodSourceController.select(
      selectionID: selectionID,
      shouldContinue: { true },
      completion: { [weak self] outcome in
        guard let self else { return }
        self.inputMethodManualSelection = nil
        switch outcome {
        case .success(let sourceName, let requestsMade):
          self.inputMethodPluginStatus = .switched(
            appName: "手动测试",
            sourceName: sourceName,
            requestsMade: requestsMade)
          self.statusMessage = self.inputMethodPluginStatus.detailText
        case .failure(let message):
          self.inputMethodPluginStatus = .failed(message)
          self.statusMessage = message
        }
      })
  }

  func inputMethodSourceName(selectionID: String) -> String {
    inputMethodSources.first(where: { $0.selectionID == selectionID })?.name ?? "输入法不可用"
  }

  func inputMethodAppIcon(rule: InputMethodAppRule) -> NSImage {
    if rule.bundleIdentifier == InputMethodBuiltInTarget.launcherIdentifier {
      return NSImage(
        systemSymbolName: "magnifyingglass",
        accessibilityDescription: "小龙哥启动器")
        ?? NSImage()
    }
    guard !rule.appPath.isEmpty else {
      return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
    return NSWorkspace.shared.icon(forFile: rule.appPath)
  }

  func loadInputMethodRules() {
    guard FileManager.default.fileExists(atPath: inputMethodRulesURL.path) else {
      inputMethodRules = []
      inputMethodStructuralDiagnostics = []
      refreshInputMethodRuleDiagnostics()
      return
    }
    do {
      let data = try InputMethodRulesCodec.loadBoundedData(from: inputMethodRulesURL)
      let document = try InputMethodRulesCodec.decodePersistedRules(from: data)
      let analysis = InputMethodRuleAnalyzer.analyze(
        document.rules,
        availableSelectionIDs: nil)
      inputMethodRules = analysis.rules
      inputMethodStructuralDiagnostics = analysis.diagnostics
      refreshInputMethodRuleDiagnostics()
    } catch {
      inputMethodPluginStatus = .failed("读取输入法规则失败：\(error.localizedDescription)")
    }
  }

  func seedLauncherInputMethodRuleIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.inputMethodLauncherRuleSeededDefaultsKey) else { return }
    if inputMethodRules.contains(where: {
      $0.bundleIdentifier == InputMethodBuiltInTarget.launcherIdentifier
    }) {
      defaults.set(true, forKey: Self.inputMethodLauncherRuleSeededDefaultsKey)
      return
    }

    inputMethodRules.append(
      InputMethodAppRule(
        id: UUID().uuidString,
        appName: "小龙哥启动器",
        bundleIdentifier: InputMethodBuiltInTarget.launcherIdentifier,
        appPath: Bundle.main.bundleURL.path,
        sourceSelectionID: InputMethodBuiltInTarget.abcSelectionID,
        enabled: true))
    inputMethodRules = InputMethodRuleResolver.normalized(inputMethodRules)
    do {
      try persistInputMethodRules()
      inputMethodStructuralDiagnostics = []
      refreshInputMethodRuleDiagnostics()
      defaults.set(true, forKey: Self.inputMethodLauncherRuleSeededDefaultsKey)
    } catch {
      inputMethodPluginStatus = .failed("保存启动器输入法规则失败：\(error.localizedDescription)")
    }
  }

  func activateInputMethodForLauncher() {
    guard !launcherInputMethodOverrideActive,
      inputMethodPluginEnabled,
      InputMethodPluginEngine.runningConflictNames().isEmpty,
      let rule = inputMethodRules.first(where: {
        $0.bundleIdentifier == InputMethodBuiltInTarget.launcherIdentifier && $0.enabled
      })
    else { return }

    let currentSelectionID = InputMethodSourceController.currentSelectionID()
    launcherInputMethodOverrideActive = true
    launcherInputMethodPreviousSelectionID = currentSelectionID
    launcherInputMethodTargetSelectionID = rule.sourceSelectionID
    guard currentSelectionID != rule.sourceSelectionID else { return }

    launcherInputMethodSelection?.cancel()
    launcherInputMethodSelection = InputMethodSourceController.select(
      selectionID: rule.sourceSelectionID,
      shouldContinue: { [weak self] in
        guard let self else { return false }
        return self.launcherInputMethodOverrideActive
          && self.launcherInputMethodTargetSelectionID == rule.sourceSelectionID
          && InputMethodPluginEngine.runningConflictNames().isEmpty
      },
      completion: { [weak self] outcome in
        guard let self else { return }
        self.launcherInputMethodSelection = nil
        switch outcome {
        case .success(let sourceName, let requestsMade):
          self.inputMethodPluginStatus = .switched(
            appName: "小龙哥启动器",
            sourceName: sourceName,
            requestsMade: requestsMade)
        case .failure(let message):
          self.launcherInputMethodOverrideActive = false
          self.launcherInputMethodPreviousSelectionID = nil
          self.launcherInputMethodTargetSelectionID = nil
          self.inputMethodPluginStatus = .failed("启动器切换失败：\(message)")
        }
      })
  }

  func restoreInputMethodAfterLauncher() {
    guard launcherInputMethodOverrideActive else { return }
    launcherInputMethodSelection?.cancel()
    launcherInputMethodSelection = nil
    let restorationSelectionID = InputMethodScopedOverridePolicy.restorationSelectionID(
      previousSelectionID: launcherInputMethodPreviousSelectionID,
      currentSelectionID: InputMethodSourceController.currentSelectionID(),
      overrideSelectionID: launcherInputMethodTargetSelectionID)

    launcherInputMethodOverrideActive = false
    launcherInputMethodPreviousSelectionID = nil
    launcherInputMethodTargetSelectionID = nil
    guard let restorationSelectionID else { return }
    launcherInputMethodSelection = InputMethodSourceController.select(
      selectionID: restorationSelectionID,
      shouldContinue: { [weak self] in self?.launcherInputMethodOverrideActive == false },
      completion: { [weak self] outcome in
        guard let self else { return }
        self.launcherInputMethodSelection = nil
        switch outcome {
        case .success:
          self.inputMethodPluginStatus = .ready(self.inputMethodRules.filter(\.enabled).count)
        case .failure(let message):
          self.inputMethodPluginStatus = .failed("恢复启动器之前的输入法失败：\(message)")
        }
      })
  }

  private func saveInputMethodRulesAndReload(message: String) {
    inputMethodRules = InputMethodRuleResolver.normalized(inputMethodRules)
    do {
      try persistInputMethodRules()
      inputMethodStructuralDiagnostics = []
      refreshInputMethodRuleDiagnostics()
      reloadInputMethodPlugin()
      statusMessage = message
    } catch {
      inputMethodPluginStatus = .failed("保存输入法规则失败：\(error.localizedDescription)")
      statusMessage = inputMethodPluginStatus.detailText
    }
  }

  private func persistInputMethodRules() throws {
    try FileManager.default.createDirectory(
      at: inputMethodRulesURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let data = try InputMethodRulesCodec.encodePersistedRules(inputMethodRules)
    try data.write(to: inputMethodRulesURL, options: .atomic)
  }

  func repairInputMethodRules() {
    let analysis = InputMethodRuleAnalyzer.analyze(
      inputMethodRules,
      availableSelectionIDs: Set(inputMethodSources.map(\.selectionID)))
    inputMethodRules = analysis.rules
    do {
      try persistInputMethodRules()
      inputMethodStructuralDiagnostics = []
      refreshInputMethodRuleDiagnostics()
      reloadInputMethodPlugin()
      statusMessage = "已清理重复或空规则；失效输入法规则仍保留，便于重新启用后恢复。"
    } catch {
      inputMethodPluginStatus = .failed("修复输入法规则失败：\(error.localizedDescription)")
      statusMessage = inputMethodPluginStatus.detailText
    }
  }

  func exportInputMethodRules() {
    let panel = NSSavePanel()
    panel.title = "导出输入法规则"
    panel.prompt = "导出"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "小龙哥Mac哲学-输入法规则-\(inputMethodBackupTimestamp()).json"
    panel.begin { [weak self] response in
      guard let self, response == .OK, var url = panel.url else { return }
      if url.pathExtension.isEmpty {
        url.appendPathExtension("json")
      }
      do {
        try self.makeInputMethodRulesBackupData().write(to: url, options: .atomic)
        self.statusMessage = "已导出 \(self.inputMethodRules.count) 条输入法规则。"
      } catch {
        self.inputMethodPluginStatus = .failed("导出输入法规则失败：\(error.localizedDescription)")
        self.statusMessage = self.inputMethodPluginStatus.detailText
      }
    }
  }

  func importInputMethodRules() {
    refreshInputMethodSources()
    let panel = NSOpenPanel()
    panel.title = "选择输入法规则备份"
    panel.prompt = "读取"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.begin { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      do {
        let data = try InputMethodRulesCodec.loadBoundedData(from: url)
        let result = try InputMethodRulesCodec.decodeImport(
          from: data,
          availableSelectionIDs: Set(self.inputMethodSources.map(\.selectionID)))
        guard self.confirmInputMethodRulesImport(result) else { return }

        let recoveryURL = try self.writeInputMethodRecoveryBackup()
        let previousRules = self.inputMethodRules
        self.inputMethodRules = result.analysis.rules
        do {
          try self.persistInputMethodRules()
        } catch {
          self.inputMethodRules = previousRules
          throw error
        }

        self.inputMethodStructuralDiagnostics = []
        self.refreshInputMethodRuleDiagnostics()
        self.reloadInputMethodPlugin()
        let cleaned = result.analysis.repairableCount
        let unavailable = result.analysis.unavailableSourceCount
        self.statusMessage =
          "已从\(result.sourceDescription)导入 \(result.analysis.rules.count) 条规则；"
          + "清理 \(cleaned) 条，失效输入法 \(unavailable) 条。导入前备份：\(recoveryURL.lastPathComponent)"
      } catch {
        self.inputMethodPluginStatus = .failed("导入输入法规则失败：\(error.localizedDescription)")
        self.statusMessage = self.inputMethodPluginStatus.detailText
      }
    }
  }

  func openInputMethodRulesBackupFolder() {
    do {
      try FileManager.default.createDirectory(
        at: inputMethodRulesBackupDirectoryURL,
        withIntermediateDirectories: true)
      NSWorkspace.shared.open(inputMethodRulesBackupDirectoryURL)
    } catch {
      inputMethodPluginStatus = .failed("打开规则备份文件夹失败：\(error.localizedDescription)")
      statusMessage = inputMethodPluginStatus.detailText
    }
  }

  private var inputMethodRulesBackupDirectoryURL: URL {
    inputMethodRulesURL
      .deletingLastPathComponent()
      .appendingPathComponent("backups", isDirectory: true)
  }

  private func makeInputMethodRulesBackupData() throws -> Data {
    try InputMethodRulesCodec.encodeBackup(
      rules: inputMethodRules,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "unknown",
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
  }

  private func writeInputMethodRecoveryBackup() throws -> URL {
    try FileManager.default.createDirectory(
      at: inputMethodRulesBackupDirectoryURL,
      withIntermediateDirectories: true)
    let url =
      inputMethodRulesBackupDirectoryURL
      .appendingPathComponent(
        "input-method-rules-pre-import-\(inputMethodBackupTimestamp()).json")
    let currentData: Data
    if let persistedData = try? InputMethodRulesCodec.loadBoundedData(from: inputMethodRulesURL) {
      currentData = persistedData
    } else {
      currentData = try makeInputMethodRulesBackupData()
    }
    try currentData.write(to: url, options: .atomic)
    return url
  }

  private func inputMethodBackupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private func confirmInputMethodRulesImport(_ result: InputMethodRuleImportResult) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "替换当前输入法规则？"
    alert.informativeText =
      "将用 \(result.analysis.rules.count) 条可用规则替换当前 \(inputMethodRules.count) 条规则。"
      + "重复/空规则 \(result.analysis.repairableCount) 条会被清理，"
      + "失效输入法 \(result.analysis.unavailableSourceCount) 条会保留并明确标记。"
      + "替换前会自动创建可恢复备份。"
    alert.addButton(withTitle: "备份并导入")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func refreshInputMethodRuleDiagnostics() {
    let unavailableDiagnostics = InputMethodRuleAnalyzer.analyze(
      inputMethodRules,
      availableSelectionIDs: Set(inputMethodSources.map(\.selectionID))
    )
    .diagnostics
    .filter { $0.kind == .unavailableInputSource }
    inputMethodRuleDiagnostics = inputMethodStructuralDiagnostics + unavailableDiagnostics
  }
}
