import AppKit
import Combine
import Foundation
import MacAutomationCore

/// The only mutable shortcut document. GUI, recording and automation share its use cases and writer.
@MainActor
final class ShortcutWorkspace: ObservableObject {
  struct Dependencies {
    var normalizedOpenAppTarget: (String) -> String?
    var openAppTargetExists: (String) -> Bool
    var preferredBrowserShortcutTarget: () -> (name: String, target: String)?
    var now: () -> Date = Date.init
    var build: () -> String = { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
  }

  @Published private(set) var items: [ShortcutItem] = []
  @Published var selectedID: String?
  @Published var shortcutRecordingConflictNotice: ShortcutRecordingConflictNotice?
  @Published private(set) var shortcutSemanticMigrationMessage = ""
  @Published private(set) var lastShortcutSemanticBackupURL: URL?
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var lastStatusMessage = ""
  let shortcutConfiguration: ShortcutConfigurationService
  private let fileURL: URL
  private let defaults: UserDefaults
  private let dependencies: Dependencies
  private let recordingPorts: ShortcutRecordingPorts?
  private var stopped = false
  private var generation = UUID()
  private var shortcutEditorOwners: Set<UUID> = []
  private var shortcutEditorRevisions: [UUID: String] = [:]
  private var shortcutEditorItems: [UUID: [ShortcutItem]] = [:]
  private var actionPresetUndoSnapshots: [String: ShortcutItem] = [:]
  private var enableAfterRecordingItemIDs = Set<String>()
  private var shortcutRecovery = LocalConfigurationRecovery(name: "快捷键配置")
  private var shortcutDefaultBaselineVersionCommitPending = false
  private var hotkeyReloadWorkItem: DispatchWorkItem?
  private var recorderSubscription: AnyCancellable?

  var onStatus: ((String) -> Void)?
  var onRecoveryChanged: (() -> Void)?
  var onCommittedChange: (() -> Void)?
  var requestHotkeyReload: (() -> Void)?
  var suspendHotkeys: (() -> Void)?
  var hasGlobalInputOwnership: (() -> Bool)?
  var ownershipBlockedMessage: (() -> String)?
  var currentHotkeyFailures: (() -> [String])?
  var isLauncherEnabled: (() -> Bool)?
  var allowsConfigurationMutation: (() -> Bool)?
  var selectShortcutModule: (() -> Void)?
  var focusShortcutList: ((_ category: String, _ search: String) -> Void)?
  var presentWindow: (() -> Void)?

  init(fileURL: URL, configuration: ShortcutConfigurationService,
       defaults: UserDefaults = .standard, dependencies: Dependencies,
       recordingPorts: ShortcutRecordingPorts? = nil) {
    self.fileURL = fileURL
    self.shortcutConfiguration = configuration
    self.defaults = defaults
    self.dependencies = dependencies
    self.recordingPorts = recordingPorts
  }

  var isStopped: Bool { stopped }
  var hasActiveShortcutEditors: Bool { !shortcutEditorOwners.isEmpty }
  var recordingItemID: String? { shortcutRecorder.recordingItemID }
  var isDraftShortcutRecording: Bool { shortcutRecorder.isDraftShortcutRecording }
  var shortcutActionCaptureItemID: String? { shortcutRecorder.actionCaptureItemID }
  var shortcutActionCaptureDraft: String { shortcutRecorder.actionCaptureDraft }
  var shortcutRecordingSessionID: UUID? { shortcutRecordingSession?.id }
  var shortcutActionCaptureSessionID: UUID? {
    shortcutRecorder.isCapturingAction ? shortcutRecorder.sessionID : nil
  }
  var isRecording: Bool { shortcutRecordingSession != nil }
  var isCapturingShortcutAction: Bool { shortcutActionCaptureItemID != nil }
  private var shortcutRecordingSession: ShortcutRecordingSession? {
    shortcutRecorder.isRecording ? shortcutRecorder.session : nil
  }
  private var hotkeyFailures: [String] { currentHotkeyFailures?() ?? [] }
  private var launcherPluginEnabled: Bool { isLauncherEnabled?() ?? false }
  private var statusMessage: String {
    get { lastStatusMessage }
    set { guard !stopped else { return }; lastStatusMessage = newValue; onStatus?(newValue) }
  }
  private var mutationsAllowed: Bool {
    guard !stopped else { return false }
    let hostAllowsMutation = allowsConfigurationMutation?() ?? true
    guard !stopped else { return false }
    guard hostAllowsMutation, !shortcutConfiguration.isRestoring else {
      statusMessage = "正在恢复配置，请完成后再修改快捷键。"
      return false
    }
    return true
  }
  lazy var shortcutRecorder: ShortcutRecordingCoordinator = {
    let recorder = ShortcutRecordingCoordinator(
      onStatus: { [weak self] in self?.statusMessage = $0 },
      hasGlobalInputOwnership: { [weak self] in
        guard let self, !self.stopped, !self.shortcutConfiguration.isRestoring,
          self.allowsConfigurationMutation?() ?? true else { return false }
        return self.hasGlobalInputOwnership?() ?? false
      },
      ownershipBlockedMessage: { [weak self] in self?.ownershipBlockedMessage?() ?? "全局输入独占权尚未取得" },
      suspendHotkeys: { [weak self] in self?.suspendHotkeys?() },
      resumeHotkeys: { [weak self] in self?.reloadHotkeys() },
      onItemCaptured: { [weak self] session, value in self?.commitRecordedShortcut(session: session, value: value) },
      onCancelledItem: { [weak self] in self?.enableAfterRecordingItemIDs.remove($0) },
      ports: recordingPorts)
    recorderSubscription = recorder.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return recorder
  }()

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    generation = UUID()
    hotkeyReloadWorkItem?.cancel()
    hotkeyReloadWorkItem = nil
    shortcutEditorOwners.removeAll()
    shortcutEditorRevisions.removeAll()
    shortcutEditorItems.removeAll()
    shortcutRecorder.shutdown()
  }

  private func updateConfigurationRecoveryMessage() {
    guard !stopped else { return }
    recoveryMessage = shortcutRecovery.message
    onRecoveryChanged?()
  }
  private func reloadHotkeys() {
    guard !stopped else { return }
    requestHotkeyReload?()
  }
  private func normalizedOpenAppTarget(_ target: String) -> String? {
    dependencies.normalizedOpenAppTarget(target)
  }
  private func openAppTargetExists(_ target: String) -> Bool {
    dependencies.openAppTargetExists(target)
  }
  private func preferredBrowserShortcutTarget() -> (name: String, target: String)? {
    dependencies.preferredBrowserShortcutTarget()
  }

  private let deletedShortcutNamesDefaultsKey = "deletedShortcutNamesV1"
  private let deletedShortcutRecoveryIDsDefaultsKey = "deletedShortcutRecoveryIDsV1"
  private static let shortcutSemanticCapsChoiceDefaultsKey = "shortcutSemanticCapsSpaceChoiceFingerprintV1"
  private static let shortcutSemanticCommandChoiceDefaultsKey = "shortcutSemanticCommandSpaceChoiceFingerprintV1"
  private static let shortcutSemanticUndoDefaultsKey = "shortcutSemanticMigrationUndoFingerprintV1"
  private static let builtInLauncherHotkey = ShortcutItem(
    id: "builtin-launcher-caps-space", name: "小龙哥启动器", scope: "内置", key: "Space",
    modifiers: ["control", "option"], action: .showLauncher, target: "", enabled: true,
    note: "Caps + Space：打开小龙哥启动器。")

  var selectedIndex: Int? {
    items.firstIndex { $0.id == selectedID }
  }

  var selectedItem: ShortcutItem? {
    guard let selectedIndex else { return nil }
    return items[selectedIndex]
  }

  var activeCount: Int {
    items.filter { $0.enabled && keyCode(for: $0.key) != nil }.count
  }

  var launcherHotkeySummary: String {
    guard launcherPluginEnabled else { return "已关闭" }
    let externallyBlocked = hotkeyFailures.contains {
      $0.contains("小龙哥启动器") && $0.contains("未抢占")
    }
    return shortcutSemanticAnalysis.capsSpaceConflicts.isEmpty && !externallyBlocked
      ? "Caps + Space" : "统一启动键未启用"
  }

  var shortcutSemanticAnalysis: ShortcutSemanticAnalysis {
    ShortcutSemanticMigration.analyze(items)
  }

  var shortcutSemanticCapsDecisionPending: Bool {
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    guard !conflicts.isEmpty else { return false }
    return defaults.string(forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
      != ShortcutSemanticMigration.conflictFingerprint(conflicts)
  }

  var shortcutSemanticCommandDecisionPending: Bool {
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    guard !conflicts.isEmpty else { return false }
    return defaults.string(forKey: Self.shortcutSemanticCommandChoiceDefaultsKey)
      != ShortcutSemanticMigration.conflictFingerprint(conflicts)
  }

  var shortcutSemanticNeedsAttention: Bool {
    shortcutSemanticCapsDecisionPending || shortcutSemanticCommandDecisionPending
  }

  var sleepHotkeySummary: String {
    guard let item = sleepHotkeyItem, item.enabled else { return "未设置" }
    return item.displayHotkey
  }

  var sleepHotkeyConfigured: Bool {
    sleepHotkeyItem?.enabled == true
  }

  var codexNetworkProbeHotkeySummary: String {
    guard
      let item = items.first(where: { $0.action == .showCodexNetworkProbe }),
      item.enabled
    else {
      return "未设置"
    }
    return item.displayHotkey
  }

  var isRecordingSleepHotkey: Bool {
    guard let sleepHotkeyItemID else { return false }
    return isRecording(sleepHotkeyItemID)
  }

  var sleepHotkeyItem: ShortcutItem? {
    items.first(where: { $0.action == .showSleepPanel })
  }

  var sleepHotkeyItemID: String? {
    sleepHotkeyItem?.id
  }

  var launcherShortcutCount: Int {
    launcherOpenAppShortcutMap.count
  }

  var launcherOpenAppShortcutMap: [String: LauncherAppShortcut] {
    var result: [String: LauncherAppShortcut] = [:]
    for item in items where item.enabled && item.action == .openApp {
      guard let targetKey = normalizedOpenAppTarget(item.target) else { continue }
      if result[targetKey] == nil {
        result[targetKey] = LauncherAppShortcut(
          itemID: item.id,
          name: item.name,
          hotkey: item.displayHotkey)
      }
    }
    return result
  }

  var deletedDefaultShortcutCount: Int {
    deletedDefaultShortcutTemplates().count
  }

  func beginShortcutEditing(owner: UUID) {
    guard mutationsAllowed else { return }
    guard shortcutEditorOwners.insert(owner).inserted else { return }
    shortcutEditorRevisions[owner] = shortcutConfiguration.revision ?? "unavailable"
    shortcutEditorItems[owner] = items
  }

  func endShortcutEditing(owner: UUID) {
    shortcutEditorOwners.remove(owner)
    shortcutEditorRevisions.removeValue(forKey: owner)
    shortcutEditorItems.removeValue(forKey: owner)
  }

  @discardableResult
  func validateShortcutEditor(owner: UUID?) -> Bool {
    guard mutationsAllowed else { return false }
    guard let owner else { return true }
    guard shortcutEditorOwners.contains(owner),
      shortcutEditorRevisions[owner] == (shortcutConfiguration.revision ?? "unavailable"),
      shortcutEditorItems[owner] == items
    else {
      statusMessage = "快捷键已在其他位置更改。本次草稿还在，请重新打开编辑窗口后再保存。"
      return false
    }
    return true
  }

  func statusMenuShortcutLabels(for action: ShortcutAction) -> [String] {
    var labels = enabledShortcutMenuLabels(for: action, in: items)
    if action == .showLauncher, launcherHotkeySummary == "Caps + Space" {
      labels.insert("Caps + Space", at: 0)
    }
    var seen: Set<String> = []
    return labels.filter { seen.insert($0).inserted }
  }

  @discardableResult
  func canRestorePluginShortcut(id: String) -> Bool {
    guard let item = items.first(where: { $0.id == id }) else { return false }
    return defaultPluginShortcut(matching: item) != nil
  }

  func restorePluginShortcut(id: String) {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.id == id }),
      var restored = defaultPluginShortcut(matching: items[index])
    else {
      statusMessage = "这个插件没有内置默认设置。"
      return
    }
    restored.id = items[index].id
    items[index] = restored
    selectedID = restored.id
    saveAndReload()
    statusMessage = "已恢复“\(restored.name)”的默认设置。"
  }

  func defaultPluginShortcut(matching item: ShortcutItem) -> ShortcutItem? {
    defaultShortcuts().first {
      isPluginShortcut($0)
        && ($0.name == item.name
          || (!$0.target.isEmpty && $0.action == item.action && $0.target == item.target))
    }
  }

  func existingSoftwareShortcut(for target: String) -> ShortcutItem? {
    let normalized = normalizedOpenAppTarget(target) ?? target
    guard let index = launcherShortcutItemIndex(forNormalizedTarget: normalized) else { return nil }
    return items[index]
  }

  func adoptCapsSpaceForLauncher() {
    guard mutationsAllowed else { return }
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    applyShortcutSemanticResolution(
      itemIDs: conflicts.map(\.id),
      reason: "user-adopt-caps-space-launcher",
      successMessage: "已停用并保留冲突项；Caps + Space 现在打开小龙哥启动器。")
  }

  func keepCurrentCapsSpaceBehavior() {
    guard mutationsAllowed else { return }
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    guard !conflicts.isEmpty else { return }
    defaults.set(
      ShortcutSemanticMigration.conflictFingerprint(conflicts),
      forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
    shortcutSemanticMigrationMessage =
      "已保留现状。Caps + Space 仍由「\(conflicts.map(\.name).joined(separator: "、"))」使用，统一启动键未启用。"
  }

  func returnCommandSpaceToSystem() {
    guard mutationsAllowed else { return }
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    applyShortcutSemanticResolution(
      itemIDs: conflicts.map(\.id),
      reason: "user-return-command-space-to-system",
      successMessage: "本 App 已停止占用 Command + Space；没有修改 macOS 系统设置。")
  }

  func keepCurrentCommandSpaceBehavior() {
    guard mutationsAllowed else { return }
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    guard !conflicts.isEmpty else { return }
    defaults.set(
      ShortcutSemanticMigration.conflictFingerprint(conflicts),
      forKey: Self.shortcutSemanticCommandChoiceDefaultsKey)
    shortcutSemanticMigrationMessage =
      "已保留 Command + Space 的个人例外；默认说明仍以 macOS 系统搜索为准。"
  }

  func openShortcutSemanticBackup() {
    guard let backupURL = lastShortcutSemanticBackupURL,
      FileManager.default.fileExists(atPath: backupURL.path)
    else {
      shortcutSemanticMigrationMessage = "找不到本次迁移备份。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([backupURL])
  }

  func undoLatestShortcutSemanticMigration() {
    guard mutationsAllowed else { return }
    do {
      let backupURL = try ShortcutSemanticMigration.restoreLatestMigration(
        at: fileURL, writeConfiguration: shortcutConfiguration.replace)
      let restoredItems = try ShortcutConfigurationCodec.load(from: fileURL)
      let officialFingerprint = ShortcutSemanticMigration.conflictFingerprint(
        ShortcutSemanticMigration.analyze(restoredItems).officialLegacyItems)
      defaults.set(officialFingerprint, forKey: Self.shortcutSemanticUndoDefaultsKey)
      load()
      reloadHotkeys()
      lastShortcutSemanticBackupURL = backupURL
      shortcutSemanticMigrationMessage = "已从备份恢复本 App 快捷键；没有修改 macOS 系统设置。"
    } catch {
      shortcutSemanticMigrationMessage = "未恢复：\(error.localizedDescription)"
    }
  }

  func applyShortcutSemanticResolution(
    itemIDs: [String],
    reason: String,
    successMessage: String
  ) {
    guard mutationsAllowed else { return }
    guard !itemIDs.isEmpty else { return }
    do {
      let result = try ShortcutSemanticMigration.disableItems(
        at: fileURL,
        itemIDs: Set(itemIDs),
        reason: reason,
        build: dependencies.build(),
        writeConfiguration: shortcutConfiguration.replace)
      defaults.removeObject(forKey: Self.shortcutSemanticUndoDefaultsKey)
      defaults.removeObject(forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
      defaults.removeObject(forKey: Self.shortcutSemanticCommandChoiceDefaultsKey)
      load()
      try? ShortcutSemanticMigration.refreshLatestRecordMigratedSHA(at: fileURL)
      reloadHotkeys()
      lastShortcutSemanticBackupURL = result.backupURL
      shortcutSemanticMigrationMessage = successMessage
    } catch {
      shortcutSemanticMigrationMessage = "迁移未完成，已停止继续修改：\(error.localizedDescription)"
    }
  }

  func startSleepHotkeyRecording() {
    guard mutationsAllowed else { return }
    let itemID = ensureSleepHotkeyItem()
    selectShortcutModule?()
    selectedID = itemID
    enableAfterRecordingItemIDs.insert(itemID)
    presentWindow?()
    startRecording(itemID: itemID)
    statusMessage = "正在设置睡眠快捷键：请直接按组合键。"
  }

  func openShortcutManager(action: ShortcutAction) {
    guard mutationsAllowed else { return }
    let itemID: String?
    switch action {
    case .showLauncher:
      itemID = ensureShortcutItemForManagement(action: .showLauncher)
    case .showClipboardHistory:
      itemID = ensureShortcutItemForManagement(action: .showClipboardHistory)
    case .showCodexNetworkProbe:
      itemID = ensureCodexNetworkProbeHotkeyItem(enabledWhenCreated: true)
    case .showSleepPanel:
      itemID = ensureSleepHotkeyItem(enabledWhenCreated: true)
    default:
      itemID = items.first(where: { $0.action == action })?.id
    }
    guard let itemID else {
      statusMessage = "未找到可管理的快捷键。"
      return
    }
    selectShortcutModule?()
    selectedID = itemID
    focusShortcutList?("全部", "")
    presentWindow?()
    statusMessage = "已切到功能快捷键，可在首页管理这条规则。"
  }

  func featureShortcutItemIDs(for commandID: String) -> [String] {
    items.filter { $0.commandID == commandID }.map(\.id)
  }

  @discardableResult
  func featureShortcutMenuLabel(for commandID: String) -> String? {
    let matchingItems = items.filter { $0.commandID == commandID }
    return matchingItems.first(where: \.enabled)?.displayHotkey
      ?? matchingItems.first?.displayHotkey
  }

  @discardableResult
  func ensureFeatureShortcutItem(commandID: String) -> String? {
    guard mutationsAllowed else { return nil }
    if let existing = items.first(where: { $0.commandID == commandID }) {
      return existing.id
    }
    guard let descriptor = YoumuFeatureShortcutCatalog.descriptor(for: commandID) else {
      statusMessage = "未知的截图命令，未新增快捷键。"
      return nil
    }
    var item = descriptor.makeShortcutItem()
    item.isBuiltIn = true
    let signature = shortcutTriggerSignature(for: item)
    let conflicts = items.contains {
      itemConsumesHotkey($0)
        && shortcutTriggerSignature(for: $0) == signature
    }
    if conflicts {
      item.enabled = false
      item.note += " 默认组合键与现有规则冲突，已保留但未自动启用。"
    }
    items.append(item)
    selectedID = item.id
    saveAndReload()
    statusMessage =
      conflicts
      ? "已加入 \(descriptor.displayName)，因快捷键冲突暂未启用。"
      : "已加入 \(descriptor.displayName) 快捷键。"
    return item.id
  }

  func openFeatureShortcutManager(commandID: String) {
    guard mutationsAllowed else { return }
    guard let itemID = ensureFeatureShortcutItem(commandID: commandID) else { return }
    selectShortcutModule?()
    selectedID = itemID
    focusShortcutList?("截图类", "")
    presentWindow?()
    statusMessage = "已切到功能快捷键；这里和截图详情使用同一条规则。"
  }

  func openPijuanPDFShortcutManager() {
    guard mutationsAllowed else { return }
    selectShortcutModule?()
    selectedID = nil
    focusShortcutList?("PDF类", "")
    presentWindow?()
    statusMessage = "已切到功能快捷键；PDF 浏览器快捷键统一在这里管理。"
  }

  func clearSleepHotkey() {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.action == .showSleepPanel }) else {
      statusMessage = "睡眠快捷键尚未设置。"
      return
    }
    if recordingItemID == items[index].id {
      enableAfterRecordingItemIDs.remove(items[index].id)
      stopRecording()
    }
    items[index].enabled = false
    selectedID = items[index].id
    saveAndReload()
    statusMessage = "已清除睡眠快捷键。"
  }

  func ensureSleepHotkeyItem(enabledWhenCreated: Bool = false) -> String {
    if let index = items.firstIndex(where: {
      $0.isBuiltIn != false && $0.action == .showSleepPanel
    }) {
      let wantedNote = "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
      var changed = false
      if items[index].name != "切换无限期保持唤醒"
        || items[index].scope != "常用脚本"
        || items[index].target != "sleep-infinite-toggle"
        || items[index].note != wantedNote
      {
        items[index].name = "切换无限期保持唤醒"
        items[index].scope = "常用脚本"
        items[index].target = "sleep-infinite-toggle"
        items[index].note = wantedNote
        changed = true
      }
      if items[index].isBuiltIn != false {
        if items[index].isBuiltIn != true {
          items[index].isBuiltIn = true
          changed = true
        }
        if items[index].recoveryID != ShortcutRecoveryIdentity.sleepManagement {
          items[index].recoveryID = ShortcutRecoveryIdentity.sleepManagement
          changed = true
        }
      }
      clearShortcutDeletionMarkers(for: items[index])
      if changed { saveOnly() }
      return items[index].id
    }
    if let userItem = items.first(where: { $0.action == .showSleepPanel }) {
      return userItem.id
    }
    let item = ShortcutItem(
      id: UUID().uuidString,
      recoveryID: ShortcutRecoveryIdentity.sleepManagement,
      isBuiltIn: true,
      name: "切换无限期保持唤醒",
      scope: "常用脚本",
      key: "X",
      modifiers: ["control", "option", "command"],
      action: .showSleepPanel,
      target: "sleep-infinite-toggle",
      enabled: enabledWhenCreated,
      note: "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
    )
    clearShortcutDeletionMarkers(for: item)
    items.append(item)
    selectedID = item.id
    saveOnly()
    return item.id
  }

  func ensureCodexNetworkProbeHotkeyItem(enabledWhenCreated: Bool = false) -> String {
    if let index = items.firstIndex(where: {
      $0.isBuiltIn != false && $0.action == .showCodexNetworkProbe
    }) {
      let wantedNote = "一个球测下载和上传，一个球测 Codex 四轮连通与响应。"
      var changed = false
      if items[index].name != "打开测试网速"
        || items[index].scope != "常用脚本"
        || items[index].target != "codex-network-probe"
        || items[index].note != wantedNote
      {
        items[index].name = "打开测试网速"
        items[index].scope = "常用脚本"
        items[index].target = "codex-network-probe"
        items[index].note = wantedNote
        changed = true
      }
      if items[index].isBuiltIn != false {
        if items[index].isBuiltIn != true {
          items[index].isBuiltIn = true
          changed = true
        }
        if items[index].recoveryID != ShortcutRecoveryIdentity.networkProbe {
          items[index].recoveryID = ShortcutRecoveryIdentity.networkProbe
          changed = true
        }
      }
      clearShortcutDeletionMarkers(for: items[index])
      if changed { saveOnly() }
      return items[index].id
    }
    if let userItem = items.first(where: { $0.action == .showCodexNetworkProbe }) {
      return userItem.id
    }
    let item = ShortcutItem(
      id: UUID().uuidString,
      recoveryID: ShortcutRecoveryIdentity.networkProbe,
      isBuiltIn: true,
      name: "打开测试网速",
      scope: "常用脚本",
      key: "T",
      modifiers: ["control", "option"],
      action: .showCodexNetworkProbe,
      target: "codex-network-probe",
      enabled: enabledWhenCreated,
      note: "一个球测下载和上传，一个球测 Codex 四轮连通与响应。"
    )
    clearShortcutDeletionMarkers(for: item)
    items.append(item)
    selectedID = item.id
    saveOnly()
    return item.id
  }

  @discardableResult
  func ensureCoreHotkeyItem(action: ShortcutAction) -> String? {
    if let index = items.firstIndex(where: { $0.action == action }) {
      if isAppManagedShortcut(items[index]) {
        clearShortcutDeletionMarkers(for: items[index])
      }
      if !items[index].enabled {
        items[index].enabled = true
        saveAndReload()
      }
      return items[index].id
    }
    guard var item = defaultShortcuts().first(where: { $0.action == action }) else {
      return nil
    }
    item.enabled = true
    clearShortcutDeletionMarkers(for: item)
    items.append(item)
    selectShortcutModule?()
    selectedID = item.id
    saveAndReload()
    return item.id
  }

  @discardableResult
  func ensureShortcutItemForManagement(action: ShortcutAction) -> String? {
    if let item = items.first(where: { $0.action == action }) {
      if isAppManagedShortcut(item) {
        clearShortcutDeletionMarkers(for: item)
      }
      return item.id
    }
    guard var item = defaultShortcuts().first(where: { $0.action == action }) else {
      return nil
    }
    item.enabled = true
    clearShortcutDeletionMarkers(for: item)
    items.append(item)
    saveAndReload()
    return item.id
  }

  func launcherTarget(for app: LauncherApp) -> String {
    app.bundleIdentifier.isEmpty ? app.path : "bundle:\(app.bundleIdentifier)"
  }

  func launcherShortcut(for app: LauncherApp) -> LauncherAppShortcut? {
    launcherOpenAppShortcutMap[launcherTargetKey(for: app)]
  }

  @discardableResult
  func isRecordingLauncherShortcut(for app: LauncherApp) -> Bool {
    guard let recordingItemID,
      let item = items.first(where: { $0.id == recordingItemID && $0.action == .openApp })
    else {
      return false
    }
    let targetKey = normalizedOpenAppTarget(item.target) ?? item.target
    return targetKey == launcherTargetKey(for: app)
  }

  func prioritizedLauncherApps(_ apps: [LauncherApp]) -> [LauncherApp] {
    let shortcutMap = launcherOpenAppShortcutMap
    guard !shortcutMap.isEmpty else { return apps }
    return apps.enumerated()
      .sorted { lhs, rhs in
        let lhsHasShortcut = shortcutMap[launcherTargetKey(for: lhs.element)] != nil
        let rhsHasShortcut = shortcutMap[launcherTargetKey(for: rhs.element)] != nil
        if lhsHasShortcut != rhsHasShortcut {
          return lhsHasShortcut
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  func launcherShortcutItemIndex(forNormalizedTarget normalizedTarget: String) -> Int? {
    if let enabledIndex = items.indices.first(where: { index in
      items[index].enabled && items[index].action == .openApp
        && (normalizedOpenAppTarget(items[index].target) ?? items[index].target) == normalizedTarget
    }) {
      return enabledIndex
    }
    return items.indices.first { index in
      items[index].action == .openApp
        && (normalizedOpenAppTarget(items[index].target) ?? items[index].target) == normalizedTarget
    }
  }

  func launcherTargetKey(for app: LauncherApp) -> String {
    if !app.bundleIdentifier.isEmpty {
      return "bundle:\(app.bundleIdentifier)"
    }
    return normalizedOpenAppTarget(app.path) ?? app.path
  }

  func load() {
    guard mutationsAllowed else { return }
    loadConfiguration(commit: { self.saveOnly() })
  }

  /// The coordinator has released the service lease, while still excluding external writers.
  /// Only this load receives the private commit capability; reentrant GUI calls stay blocked.
  func reloadAfterConfigurationRestore() {
    guard !stopped, !shortcutConfiguration.isRestoring else { return }
    loadConfiguration(commit: { self.saveConfiguration() })
  }

  /// An explicit external reference transaction has finished; adopt only a safe service read.
  /// The host keeps its completion gate closed while this controlled refresh publishes.
  /// This is not a second writer and does not run default repair over the external result.
  @discardableResult
  func reloadAfterExternalReferenceChange() -> Bool {
    guard !stopped, !shortcutConfiguration.isRestoring else { return false }
    do {
      guard let decoded = try shortcutConfiguration.reload() else { return false }
      items = decoded
      if let selectedID, !decoded.contains(where: { $0.id == selectedID }) {
        self.selectedID = decoded.first?.id
      }
      shortcutRecovery.recordReadSuccess()
      updateConfigurationRecoveryMessage()
      onCommittedChange?()
      reloadHotkeys()
      return true
    } catch {
      statusMessage = "快捷键配置重新读取失败：\(error.localizedDescription)"
      return false
    }
  }

  private func loadConfiguration(commit: () -> Bool) {
    guard !stopped, !shortcutConfiguration.isRestoring else { return }
    var semanticMigrationFailed = false
    var semanticMigrationChanged = false
    do {
      if let originalItems = try shortcutConfiguration.reload() {
        let officialFingerprint = ShortcutSemanticMigration.conflictFingerprint(
          ShortcutSemanticMigration.analyze(originalItems).officialLegacyItems)
        let userUndidSameMigration =
          !officialFingerprint.isEmpty
          && defaults.string(forKey: Self.shortcutSemanticUndoDefaultsKey)
            == officialFingerprint
        if !userUndidSameMigration {
          do {
            let result = try ShortcutSemanticMigration.applyAutomaticMigrationIfNeeded(
              at: fileURL,
              build: dependencies.build(),
              writeConfiguration: shortcutConfiguration.replace)
            if result.changed {
              semanticMigrationChanged = true
              lastShortcutSemanticBackupURL = result.backupURL
              shortcutSemanticMigrationMessage =
                "已停用可精确识别的官方旧默认；本 App 不再占用 Command + Space。"
              defaults.removeObject(forKey: Self.shortcutSemanticUndoDefaultsKey)
            }
          } catch {
            semanticMigrationFailed = true
            shortcutSemanticMigrationMessage = "迁移未完成，已停止继续修改。"
            statusMessage = "快捷键迁移未完成：\(error.localizedDescription)"
          }
        }
        items = try shortcutConfiguration.reload() ?? []
        shortcutRecovery.recordReadSuccess()
        updateConfigurationRecoveryMessage()
      } else {
        _ = try shortcutConfiguration.reload()
        shortcutRecovery.recordReadSuccess()
        updateConfigurationRecoveryMessage()
        items = defaultShortcuts()
        markShortcutDefaultBaselineCurrent()
        _ = commit()
      }
      let needsCodexNetworkProbeShortcut = !items.contains {
        $0.action == .showCodexNetworkProbe
      }
      let needsClipboardHistoryShortcut = !items.contains {
        $0.action == .showClipboardHistory
      }
      let needsFeatureShortcutMerge = !missingDefaultFeatureShortcuts().isEmpty
      let needsRecoveryOwnershipRepair = hasLegacyRecoveryOwnershipRepair()
      let needsFeatureNameMigration =
        YoumuFeatureShortcutCatalog.updatingLegacyDisplayNames(in: items) != items
      let needsDuplicateShortcutIDRepair = hasDuplicateShortcutIDs()
      let needsDuplicateManagedIdentityRepair = hasDuplicateManagedShortcutIdentities()
      let needsBuiltInOwnershipMigration = items.contains { $0.isBuiltIn == nil }
      let needsShortcutDefaultBaselineMigration =
        defaults.integer(forKey: ShortcutDefaultBaseline.versionDefaultsKey)
        < ShortcutDefaultBaseline.currentVersion
      let itemsBeforeCoreRepair = items
      let deletedNamesBeforeCoreRepair = deletedShortcutNames()
      let deletedRecoveryIDsBeforeCoreRepair = deletedShortcutRecoveryIDs()
      if !semanticMigrationFailed, repairCoreDefaultsAndMergeCommonRules() {
        let backupSucceeded: Bool
        if needsDuplicateShortcutIDRepair || needsDuplicateManagedIdentityRepair {
          backupSucceeded = backupShortcutConfigBeforeDuplicateIDRepair()
        } else if needsRecoveryOwnershipRepair || needsBuiltInOwnershipMigration {
          backupSucceeded = backupShortcutConfigBeforeRecoveryOwnershipRepair()
        } else if needsFeatureNameMigration {
          backupSucceeded = backupShortcutConfigBeforeFeatureNameMigration()
        } else if needsShortcutDefaultBaselineMigration {
          backupSucceeded = backupShortcutConfigBeforeDefaultBaselineMigration()
        } else if needsFeatureShortcutMerge {
          backupSucceeded = backupShortcutConfigBeforeFeatureShortcutMerge()
        } else if needsClipboardHistoryShortcut {
          backupSucceeded = backupShortcutConfigBeforeClipboardHistoryAddition()
        } else if needsCodexNetworkProbeShortcut {
          backupSucceeded = backupShortcutConfigBeforeCodexNetworkProbeAddition()
        } else {
          backupSucceeded = true
        }
        if backupSucceeded {
          if !commit() {
            items = itemsBeforeCoreRepair
            setDeletedShortcutNames(deletedNamesBeforeCoreRepair)
            setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBeforeCoreRepair)
            cancelShortcutDefaultBaselineVersionCommit()
          } else {
            commitShortcutDefaultBaselineVersionIfNeeded()
          }
        } else {
          items = itemsBeforeCoreRepair
          setDeletedShortcutNames(deletedNamesBeforeCoreRepair)
          setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBeforeCoreRepair)
          cancelShortcutDefaultBaselineVersionCommit()
        }
      }
      if semanticMigrationChanged {
        try? ShortcutSemanticMigration.refreshLatestRecordMigratedSHA(at: fileURL)
      }
      if lastShortcutSemanticBackupURL == nil,
        let record = ShortcutSemanticMigration.latestRecord(for: fileURL)
      {
        lastShortcutSemanticBackupURL = ShortcutSemanticMigration.backupURL(
          for: fileURL, record: record)
      }
      selectedID = items.first?.id
    } catch {
      items = defaultShortcuts()
      selectedID = items.first?.id
      shortcutRecovery.recordReadFailure()
      updateConfigurationRecoveryMessage()
      statusMessage = "配置读取失败，原文件已保护：\(error.localizedDescription)"
    }
  }

  @discardableResult
  func repairCoreDefaultsAndMergeCommonRules() -> Bool {
    var changed = false
    if repairDuplicateShortcutIDs() {
      changed = true
    }
    if repairLegacyRecoveryOwnership() {
      changed = true
    }
    if migrateBuiltInShortcutOwnership() {
      changed = true
    }
    if repairDuplicateManagedShortcutIdentities() {
      changed = true
    }
    let renamedFeatureShortcuts = YoumuFeatureShortcutCatalog.updatingLegacyDisplayNames(in: items)
    if renamedFeatureShortcuts != items {
      items = renamedFeatureShortcuts
      changed = true
    }
    if migrateShortcutDefaultBaselineIfNeeded() {
      changed = true
    }
    let removedLegacyRemoteRules = [
      "打开 Mos", "重启 Mos", "备份 Mos 配置", "微信输入法", "快捷词", "打开 App 软件界面", "打开应用程序文件夹",
      "打开系统设置", "全景模式",
    ]
    let beforeCount = items.count
    items.removeAll {
      $0.isBuiltIn != false && removedLegacyRemoteRules.contains($0.name)
    }
    if items.count != beforeCount {
      changed = true
    }
    let beforeDisplaySleepCount = items.count
    items.removeAll {
      $0.isBuiltIn != false && isLegacyDisplaySleepShortcut($0)
    }
    if items.count != beforeDisplaySleepCount {
      changed = true
    }
    for index in items.indices where items[index].isBuiltIn != false {
      switch items[index].name {
      case "Emoji", "打开 Emoji 与符号":
        let wantedNote = "打开系统 Emoji 与符号面板。"
        if items[index].name != "打开 Emoji 与符号"
          || items[index].scope != "常用脚本"
          || items[index].action != .sendShortcut
          || items[index].target != "⌃ ⌘ Space"
          || items[index].note != wantedNote
        {
          items[index].name = "打开 Emoji 与符号"
          items[index].scope = "常用脚本"
          items[index].action = .sendShortcut
          items[index].target = "⌃ ⌘ Space"
          items[index].note = wantedNote
          changed = true
        }
      case "打开任务页":
        if items[index].scope != "系统辅助" || items[index].action != .openURL {
          items[index].scope = "系统辅助"
          items[index].action = .openURL
          items[index].note = "系统级打开本地任务页。"
          changed = true
        }
      case "番茄闹钟":
        let wantedNote = "通过系统快捷指令运行，可在功能快捷键中调整。"
        if items[index].scope != "系统辅助"
          || items[index].target != "shortcuts run '番茄闹钟'"
          || items[index].note != wantedNote
        {
          items[index].scope = "系统辅助"
          items[index].action = .runShell
          items[index].target = "shortcuts run '番茄闹钟'"
          items[index].note = wantedNote
          changed = true
        }
      case "麦克风", "切换麦克风":
        let wantedNote = "Studio Display / DJI 麦克风切换。"
        if items[index].name != "切换麦克风"
          || items[index].scope != "常用脚本"
          || items[index].target != "plugin:mic-toggle.sh"
          || items[index].note != wantedNote
        {
          items[index].name = "切换麦克风"
          items[index].scope = "常用脚本"
          items[index].action = .runShell
          items[index].target = "plugin:mic-toggle.sh"
          items[index].note = wantedNote
          changed = true
        }
      case "休眠":
        let wantedNote = "让 Mac 进入睡眠。"
        if items[index].scope != "常用脚本" || items[index].note != wantedNote {
          items[index].scope = "常用脚本"
          items[index].note = wantedNote
          changed = true
        }
      case "打开睡眠面板", "睡眠面板", "保持唤醒", "切换无限保持唤醒", "切换无限期保持唤醒":
        guard items[index].action == .showSleepPanel else { break }
        let wantedNote = "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
        if items[index].name != "切换无限期保持唤醒"
          || items[index].scope != "常用脚本"
          || items[index].target != "sleep-infinite-toggle"
          || items[index].note != wantedNote
        {
          items[index].name = "切换无限期保持唤醒"
          items[index].scope = "常用脚本"
          items[index].target = "sleep-infinite-toggle"
          items[index].note = wantedNote
          changed = true
        }
      case "打开 X-DRAGON":
        let wantedNote = "打开 X-DRAGON 文件夹。"
        let wantedTarget =
          FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("X-DRAGON", isDirectory: true)
          .path
        if items[index].scope != "常用脚本" || items[index].action != .openApp
          || items[index].target != wantedTarget
          || items[index].note != wantedNote
        {
          items[index].scope = "常用脚本"
          items[index].action = .openApp
          items[index].target = wantedTarget
          items[index].note = wantedNote
          changed = true
        }
      case "系统设置":
        let wantedTarget = "bundle:com.apple.systempreferences"
        let wantedNote = "打开系统设置。"
        if items[index].scope != "常用脚本"
          || items[index].action != .openApp
          || items[index].target != wantedTarget
          || items[index].note != wantedNote
        {
          items[index].scope = "常用脚本"
          items[index].action = .openApp
          items[index].target = wantedTarget
          items[index].note = wantedNote
          changed = true
        }
      case "打开 TickTick", "打开TickTick", "滴答清单软件":
        let wantedModifiers = ["control", "option"]
        let wantedTarget = "bundle:com.TickTick.task.mac"
        if items[index].name != "滴答清单软件"
          || items[index].scope != "App"
          || items[index].key != "T"
          || items[index].modifiers != wantedModifiers
          || items[index].action != .openApp
          || items[index].target != wantedTarget
          || !items[index].enabled
        {
          items[index].name = "滴答清单软件"
          items[index].scope = "App"
          items[index].key = "T"
          items[index].modifiers = wantedModifiers
          items[index].action = .openApp
          items[index].target = wantedTarget
          items[index].enabled = true
          if items[index].note.isEmpty || items[index].note.contains("小锤子") {
            items[index].note = "任务清单入口，App 打开 / 置前 / 再按隐藏。"
          }
          changed = true
        }
      case "偏好设置":
        let wantedModifiers = ["control", "option"]
        let wantedNote = "给前台 App 发送 ⌘ 逗号。"
        if items[index].scope != "系统辅助"
          || items[index].key != "`"
          || items[index].modifiers != wantedModifiers
          || items[index].action != .sendShortcut
          || items[index].target != "⌘ ,"
          || !items[index].enabled
          || items[index].note != wantedNote
        {
          items[index].scope = "系统辅助"
          items[index].key = "`"
          items[index].modifiers = wantedModifiers
          items[index].action = .sendShortcut
          items[index].target = "⌘ ,"
          items[index].enabled = true
          items[index].note = wantedNote
          changed = true
        }
      default:
        break
      }
    }
    if repairMissingDefaultBrowserShortcut() {
      changed = true
    }
    for index in items.indices
    where
      items[index].isBuiltIn != false && items[index].action == .showSleepPanel
    {
      let wantedNote = "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
      if items[index].name != "切换无限期保持唤醒"
        || items[index].scope != "常用脚本"
        || items[index].target != "sleep-infinite-toggle"
        || items[index].note != wantedNote
      {
        items[index].name = "切换无限期保持唤醒"
        items[index].scope = "常用脚本"
        items[index].target = "sleep-infinite-toggle"
        items[index].note = wantedNote
        changed = true
      }
    }
    let sleepDeletionNames = ShortcutRecoveryIdentity.deletionNameAliases(
      recoveryID: ShortcutRecoveryIdentity.sleepManagement,
      primaryName: "切换无限期保持唤醒")
    if !isShortcutRecoveryDeleted(ShortcutRecoveryIdentity.sleepManagement),
      deletedShortcutNames().isDisjoint(with: sleepDeletionNames),
      !items.contains(where: { $0.action == .showSleepPanel })
    {
      let item = ShortcutItem(
        id: UUID().uuidString,
        recoveryID: ShortcutRecoveryIdentity.sleepManagement,
        isBuiltIn: true,
        name: "切换无限期保持唤醒",
        scope: "常用脚本",
        key: "X",
        modifiers: ["control", "option", "command"],
        action: .showSleepPanel,
        target: "sleep-infinite-toggle",
        enabled: true,
        note: "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
      )
      items.insert(item, at: min(1, items.count))
      changed = true
    }
    if !isShortcutRecoveryDeleted(ShortcutRecoveryIdentity.networkProbe),
      !isShortcutNameDeleted("打开测试网速"),
      !items.contains(where: { $0.action == .showCodexNetworkProbe })
    {
      let item = ShortcutItem(
        id: UUID().uuidString,
        recoveryID: ShortcutRecoveryIdentity.networkProbe,
        isBuiltIn: true,
        name: "打开测试网速",
        scope: "常用脚本",
        key: "T",
        modifiers: ["control", "option"],
        action: .showCodexNetworkProbe,
        target: "codex-network-probe",
        enabled: true,
        note: "一个球测下载和上传，一个球测 Codex 四轮连通与响应。"
      )
      items.append(item)
      changed = true
    }
    if !isShortcutRecoveryDeleted(ShortcutRecoveryIdentity.clipboardHistory),
      !isShortcutNameDeleted("打开剪贴板历史"),
      !items.contains(where: { $0.action == .showClipboardHistory })
    {
      var item = ShortcutItem(
        id: UUID().uuidString,
        recoveryID: ShortcutRecoveryIdentity.clipboardHistory,
        isBuiltIn: true,
        name: "打开剪贴板历史",
        scope: "常用脚本",
        key: ShortcutDefaultBaseline.clipboardKey,
        modifiers: ShortcutDefaultBaseline.proportionalModifiers,
        action: .showClipboardHistory,
        target: "clipboard-history",
        enabled: true,
        note: ShortcutDefaultBaseline.clipboardNote
      )
      let signature = shortcutTriggerSignature(for: item)
      let hasConflict = items.contains {
        itemConsumesHotkey($0)
          && shortcutTriggerSignature(for: $0) == signature
      }
      if hasConflict {
        item.enabled = false
        item.note += " 快捷键与现有规则冲突，已保留但未自动启用。"
      }
      items.append(item)
      changed = true
    }
    if !isShortcutRecoveryDeleted(
      ShortcutRecoveryIdentity.make(
        commandID: nil, actionID: ShortcutAction.insertText.rawValue, target: "#")),
      !isShortcutNameDeleted("输入井号 #"),
      !items.contains(where: {
        $0.name == "输入井号 #"
          || ($0.action == .insertText && $0.target == "#")
      })
    {
      let item = ShortcutItem(
        id: UUID().uuidString,
        recoveryID: ShortcutRecoveryIdentity.make(
          commandID: nil, actionID: ShortcutAction.insertText.rawValue, target: "#"),
        isBuiltIn: true,
        name: "输入井号 #",
        scope: "常用脚本",
        key: "3",
        modifiers: ["control", "option"],
        action: .insertText,
        target: "#",
        enabled: false,
        note: "在当前光标处输入 #。"
      )
      items.append(item)
      changed = true
    }
    if !isShortcutRecoveryDeleted(
      ShortcutRecoveryIdentity.make(
        commandID: nil,
        actionID: ShortcutAction.windowPreset.rawValue,
        target: WindowPreset.maximize.rawValue)),
      !isShortcutNameDeleted("窗口最大化"),
      !isShortcutNameDeleted("窗口化全屏"),
      !items.contains(where: {
        $0.action == .windowPreset && $0.target == WindowPreset.maximize.rawValue
      })
    {
      let item = ShortcutItem(
        id: UUID().uuidString,
        recoveryID: ShortcutRecoveryIdentity.make(
          commandID: nil,
          actionID: ShortcutAction.windowPreset.rawValue,
          target: WindowPreset.maximize.rawValue),
        isBuiltIn: true,
        name: "窗口化全屏",
        scope: "窗口",
        key: "F",
        modifiers: ["control", "option"],
        action: .windowPreset,
        target: WindowPreset.maximize.rawValue,
        enabled: true,
        note: "Caps + F：窗口化全屏，保留 Dock 和顶部菜单栏/状态栏，始终铺满可用区域；重复按保持铺满。"
      )
      items.append(item)
      changed = true
    }
    let maximizeHotkey = Set(["control", "option"])
    for index in items.indices {
      let usesCapsF =
        items[index].usesChordTrigger && items[index].key == "F"
        && Set(items[index].modifiers) == maximizeHotkey
      let isMaximize =
        items[index].action == .windowPreset
        && items[index].target == WindowPreset.maximize.rawValue
      guard usesCapsF && !isMaximize else { continue }
      if ["系统全屏", "系统全景", "全景", "全景模式", "全屏"].contains(items[index].name) {
        items[index].name = "全屏"
        items[index].modifiers = ["control", "option", "command"]
        items[index].action = .nativeFullScreen
        items[index].target = "entireScreen"
        items[index].note = "Caps + ⌘ + F：始终进入系统全屏；Caps + ⌘ + ↑ 回到居中小窗口。"
      } else {
        items[index].enabled = false
        if !items[index].note.contains("已避让 Caps + F")
          && !items[index].note.contains("已避让 CL + F")
        {
          items[index].note += " 已避让 Caps + F，避免覆盖窗口化全屏。"
        }
      }
      changed = true
    }
    for index in items.indices where items[index].action == .openApp {
      if let normalizedTarget = normalizedOpenAppTarget(items[index].target),
        items[index].target != normalizedTarget
      {
        items[index].target = normalizedTarget
        changed = true
      }
    }
    if !disableMissingOpenAppShortcuts().isEmpty {
      changed = true
    }
    if repairMissingDefaultFeatureShortcuts() {
      changed = true
    }
    // Apply after startup repairs, including users already on baseline 11.
    if ShortcutDefaultBaseline.migrateWindowActionNotes(in: &items) {
      changed = true
    }
    return changed
  }

  func missingDefaultFeatureShortcuts() -> [FeatureShortcutCommandDescriptor] {
    guard YoumuFeatureShortcutCatalog.runtimeAvailable else { return [] }
    return YoumuFeatureShortcutCatalog.missingDefaultDescriptors(
      in: items,
      deletedNames: deletedShortcutNames(),
      deletedRecoveryIDs: deletedShortcutRecoveryIDs())
  }

  @discardableResult
  func hasDuplicateShortcutIDs() -> Bool {
    var seen: Set<String> = []
    return items.contains { !seen.insert($0.id).inserted }
  }

  @discardableResult
  func repairDuplicateShortcutIDs() -> Bool {
    let groups = Dictionary(grouping: items.indices, by: { items[$0].id })
    var changed = false
    for indices in groups.values where indices.count > 1 {
      let keeper =
        indices.first(where: { isFixedFeatureShortcut(items[$0]) }) ?? indices[0]
      for index in indices where index != keeper {
        items[index].id = UUID().uuidString
        changed = true
      }
    }
    return changed
  }

  @discardableResult
  func managedShortcutIdentityKey(_ item: ShortcutItem) -> String? {
    if let commandID = item.commandID,
      YoumuFeatureShortcutCatalog.descriptor(for: commandID) != nil
    {
      return "command:\(commandID)"
    }
    guard item.isBuiltIn != false,
      let recoveryID = item.recoveryID,
      defaultShortcuts().contains(where: { $0.recoveryID == recoveryID })
    else {
      return nil
    }
    return "recovery:\(recoveryID)"
  }

  @discardableResult
  func hasDuplicateManagedShortcutIdentities() -> Bool {
    var seen: Set<String> = []
    return items.contains { item in
      guard let identity = managedShortcutIdentityKey(item) else { return false }
      return !seen.insert(identity).inserted
    }
  }

  @discardableResult
  func repairDuplicateManagedShortcutIdentities() -> Bool {
    let groups = Dictionary(grouping: items.indices) { managedShortcutIdentityKey(items[$0]) }
    var removedIndices: Set<Int> = []
    var changed = false
    for (identity, indices) in groups {
      guard let identity, indices.count > 1 else { continue }
      let keeper = indices[0]
      for index in indices.dropFirst() {
        let hasSameSemanticActionAndHotkey =
          items[index].action == items[keeper].action
          && items[index].target == items[keeper].target
          && shortcutTriggerSignature(for: items[index])
            == shortcutTriggerSignature(for: items[keeper])
        let decision = ShortcutDuplicateManagedIdentityPolicy.decision(
          isFixedFeature: identity.hasPrefix("command:"),
          hasSameSemanticActionAndHotkey: hasSameSemanticActionAndHotkey)
        if decision == .removeDuplicate {
          removedIndices.insert(index)
        } else {
          items[index].commandID = nil
          items[index].recoveryID = nil
          items[index].isBuiltIn = false
        }
        changed = true
      }
    }
    if !removedIndices.isEmpty {
      items = items.enumerated().compactMap { index, item in
        removedIndices.contains(index) ? nil : item
      }
    }
    return changed
  }

  func legacyRecoveryTemplate(
    for item: ShortcutItem,
    templates: [ShortcutItem]
  ) -> ShortcutItem? {
    if let commandID = item.commandID,
      let template = templates.first(where: { $0.commandID == commandID })
    {
      return template
    }
    if let recoveryID = item.recoveryID,
      let template = templates.first(where: { $0.recoveryID == recoveryID })
    {
      if template.commandID != nil || item.isBuiltIn != false {
        return template
      }
    }
    guard item.isBuiltIn != false,
      let descriptor = YoumuFeatureShortcutCatalog.all.first(where: { $0.target == item.target })
    else {
      return nil
    }
    return templates.first(where: { $0.commandID == descriptor.id })
  }

  @discardableResult
  func hasLegacyRecoveryOwnershipRepair() -> Bool {
    let templates = defaultShortcuts()
    return items.contains { item in
      guard let template = legacyRecoveryTemplate(for: item, templates: templates)
      else {
        return false
      }
      let matchesCanonicalAction = !shortcutSemanticActionChanged(
        item,
        action: template.action,
        target: template.target)
      if template.commandID != nil {
        return item.commandID != template.commandID
          || item.recoveryID != template.recoveryID
          || item.isBuiltIn != true
          || !matchesCanonicalAction
      }
      return !matchesCanonicalAction
    }
  }

  @discardableResult
  func repairLegacyRecoveryOwnership() -> Bool {
    var changed = false
    let templates = defaultShortcuts()
    for index in items.indices {
      guard let template = legacyRecoveryTemplate(for: items[index], templates: templates)
      else {
        continue
      }

      let matchesCanonicalAction = !shortcutSemanticActionChanged(
        items[index],
        action: template.action,
        target: template.target)
      let decision = ShortcutLegacyRecoveryRepairPolicy.decision(
        isFixedFeature: template.commandID != nil,
        matchesCanonicalAction: matchesCanonicalAction)

      switch decision {
      case .keepManagedDefault:
        if items[index].isBuiltIn != true {
          items[index].isBuiltIn = true
          changed = true
        }
      case .restoreFixedFeatureOwnership:
        guard let commandID = template.commandID,
          let descriptor = YoumuFeatureShortcutCatalog.descriptor(for: commandID)
        else {
          continue
        }
        guard
          items[index].commandID != commandID
            || items[index].recoveryID != template.recoveryID
            || items[index].isBuiltIn != true
        else {
          continue
        }
        items[index].commandID = commandID
        items[index].recoveryID = template.recoveryID
        items[index].isBuiltIn = true
        items[index].name = descriptor.displayName
        items[index].scope = descriptor.scope
        items[index].note = descriptor.note
        changed = true
      case .convertToUserRule(let markDefaultDeleted):
        if markDefaultDeleted {
          markShortcutDeleted(template, recoveryID: template.recoveryID)
        } else {
          // Fixed features are merged back below. Give the preserved custom action a fresh ID so
          // it cannot collide with the stable feature command row.
          items[index].id = UUID().uuidString
        }
        items[index].commandID = nil
        items[index].recoveryID = nil
        items[index].isBuiltIn = false
        changed = true
      }
    }
    return changed
  }

  @discardableResult
  func repairMissingDefaultFeatureShortcuts() -> Bool {
    let missing = missingDefaultFeatureShortcuts()
    guard !missing.isEmpty else { return false }

    for descriptor in missing {
      var item = descriptor.makeShortcutItem()
      item.isBuiltIn = true
      let signature = shortcutTriggerSignature(for: item)
      let hasConflict = items.contains {
        itemConsumesHotkey($0)
          && shortcutTriggerSignature(for: $0) == signature
      }
      if hasConflict {
        item.enabled = false
        item.note += " 默认组合键与现有规则冲突，已保留但未自动启用。"
      }
      items.append(item)
    }
    statusMessage = "已补回截图默认快捷键；现有自定义规则保持不变。"
    return true
  }

  @discardableResult
  func isLegacyDisplaySleepShortcut(_ item: ShortcutItem) -> Bool {
    let legacyNames = Set(["息屏", "息屏不睡机"])
    return item.usesChordTrigger
      && legacyNames.contains(item.name)
      && item.action == .runShell
      && item.target == "pmset displaysleepnow"
      && item.key == "Escape"
      && Set(item.modifiers) == Set(["control", "option", "command"])
  }

  @discardableResult
  func backupShortcutConfigBeforeCodexNetworkProbeAddition() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "codex-network-probe",
      failureMessage: "快捷键备份失败，未写入测试网速快捷键。")
  }

  @discardableResult
  func backupShortcutConfigBeforeClipboardHistoryAddition() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "clipboard-history",
      failureMessage: "快捷键备份失败，未写入剪贴板历史快捷键。")
  }

  @discardableResult
  func backupShortcutConfigBeforeFeatureShortcutMerge() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "feature-shortcuts",
      failureMessage: "快捷键备份失败，未补回截图默认快捷键。")
  }

  @discardableResult
  func backupShortcutConfigBeforeFeatureNameMigration() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "feature-display-names",
      failureMessage: "快捷键备份失败，未更改功能名称。")
  }

  @discardableResult
  func backupShortcutConfigBeforeRecoveryOwnershipRepair() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-recovery-ownership",
      failureMessage: "快捷键备份失败，未迁移旧版恢复身份。")
  }

  @discardableResult
  func backupShortcutConfigBeforeDuplicateIDRepair() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-duplicate-identities",
      failureMessage: "快捷键备份失败，未修复重复身份。")
  }

  @discardableResult
  func backupShortcutConfigBeforeDefaultBaselineMigration() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-default-baseline-v\(ShortcutDefaultBaseline.currentVersion)",
      failureMessage: "快捷键备份失败，未升级默认快捷键触发方式。")
  }

  @discardableResult
  func backupShortcutConfigBeforeDefaultMerge(
    reason: String,
    failureMessage: String
  ) -> Bool {
    guard let data = try? LocalConfigurationFileCodec.readData(from: fileURL) else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let build = dependencies.build()
    let directory = fileURL.deletingLastPathComponent()
      .appendingPathComponent("backups", isDirectory: true)
    let backup = directory.appendingPathComponent(
      "shortcuts-before-\(reason)-build\(build)-\(formatter.string(from: dependencies.now())).json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: backup, options: [.atomic])
      return true
    } catch {
      statusMessage = "\(failureMessage)：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func migrateShortcutDefaultBaselineIfNeeded() -> Bool {
    let defaults = self.defaults
    guard
      defaults.integer(forKey: ShortcutDefaultBaseline.versionDefaultsKey)
        < ShortcutDefaultBaseline.currentVersion
    else { return false }

    let clipboardDeletionNames = ShortcutRecoveryIdentity.deletionNameAliases(
      recoveryID: ShortcutRecoveryIdentity.clipboardHistory,
      primaryName: "打开剪贴板历史")
    let allowClipboardHistoryTriggerMigration =
      !isShortcutRecoveryDeleted(ShortcutRecoveryIdentity.clipboardHistory)
      && deletedShortcutNames().isDisjoint(with: clipboardDeletionNames)
    var changed = ShortcutDefaultBaseline.migrateLegacyDefaults(
      in: &items,
      allowClipboardHistoryTriggerMigration: false)
    if allowClipboardHistoryTriggerMigration,
      ShortcutDefaultBaseline.migrateClipboardHistoryChord(in: &items)
    {
      changed = true
    }
    let ratioTargets = [WindowPreset.leftProportional.rawValue, WindowPreset.rightProportional.rawValue]
    for var item in defaultShortcuts() where item.action == .windowPreset && ratioTargets.contains(item.target) {
      guard !isShortcutRecoveryDeleted(item.recoveryID ?? ""),
        !isShortcutNameDeleted(item.name),
        !items.contains(where: { $0.action == item.action && $0.target == item.target })
      else { continue }
      let signature = shortcutTriggerSignature(for: item)
      if items.contains(where: { itemConsumesHotkey($0) && shortcutTriggerSignature(for: $0) == signature }) {
        item.enabled = false
        item.note += " 快捷键与现有规则冲突，已保留但未自动启用。"
      }
      items.append(item)
      changed = true
    }
    if changed {
      shortcutDefaultBaselineVersionCommitPending = true
      statusMessage = "检测到旧版快捷键方案，已升级为当前小龙哥默认方案。你的自定义快捷键不会被覆盖。"
    } else {
      markShortcutDefaultBaselineCurrent()
    }
    return changed
  }

  func commitShortcutDefaultBaselineVersionIfNeeded() {
    guard shortcutDefaultBaselineVersionCommitPending else { return }
    markShortcutDefaultBaselineCurrent()
    shortcutDefaultBaselineVersionCommitPending = false
  }

  func cancelShortcutDefaultBaselineVersionCommit() {
    shortcutDefaultBaselineVersionCommitPending = false
  }

  func markShortcutDefaultBaselineCurrent() {
    defaults.set(
      ShortcutDefaultBaseline.currentVersion,
      forKey: ShortcutDefaultBaseline.versionDefaultsKey)
    defaults.synchronize()
  }

  @discardableResult
  func saveOnly() -> Bool {
    guard mutationsAllowed else { return false }
    return saveConfiguration()
  }

  private func saveConfiguration() -> Bool {
    guard !stopped, !shortcutConfiguration.isRestoring else { return false }
    do {
      try shortcutConfiguration.save(items)
      if let committed = shortcutConfiguration.committedItems {
        items = committed
      }
      shortcutRecovery.recordReadSuccess()
      updateConfigurationRecoveryMessage()
      return true
    } catch {
      if let committed = shortcutConfiguration.committedItems {
        items = committed
      }
      updateConfigurationRecoveryMessage()
      statusMessage = "保存失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func saveAndReload() -> Bool {
    guard mutationsAllowed else { return false }
    guard saveOnly() else { return false }
    onCommittedChange?()
    reloadHotkeys()
    return true
  }

  func saveAndScheduleHotkeyReload(delay: TimeInterval = 0.45) {
    guard mutationsAllowed, saveOnly() else { return }
    hotkeyReloadWorkItem?.cancel()
    let owner = UUID()
    generation = owner
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped, self.generation == owner else { return }
      self.hotkeyReloadWorkItem = nil
      self.reloadHotkeys()
    }
    hotkeyReloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func hotkeyRegistrationItems() -> [ShortcutItem] {
    guard launcherPluginEnabled else {
      AppDiagnostics.log("built_in_launcher_skipped", ["reason": "plugin_disabled"])
      return items
    }
    let builtInSignature = shortcutTriggerSignature(for: Self.builtInLauncherHotkey)
    let userOverridesBuiltIn = items.contains { item in
      item.enabled && shortcutTriggerSignature(for: item) == builtInSignature
    }
    guard userOverridesBuiltIn else {
      return [Self.builtInLauncherHotkey] + items
    }
    AppDiagnostics.log(
      "built_in_launcher_skipped",
      [
        "reason": "user_override",
        "key": Self.builtInLauncherHotkey.displayHotkey,
      ])
    return items
  }

  func makeShortcutDraft(module: String = "功能快捷键") -> ShortcutItem {
    if module == "快捷短语" || module == "短语类" {
      return ShortcutItem(
        id: UUID().uuidString,
        name: "新快捷键",
        scope: "全部应用",
        key: "N",
        modifiers: ["control", "option"],
        action: .openURL,
        target: "https://aixlg.com/",
        enabled: false,
        note: "点快捷键框后直接按键。"
      )
    }
    switch module {
    case "自定义脚本类", "内置插件", "内部插件", "脚本插件":
      return ShortcutItem(
        id: UUID().uuidString,
        name: "新插件",
        scope: "插件",
        key: "N",
        modifiers: ["control", "option"],
        action: .runShell,
        target: "",
        enabled: false,
        note: "脚本插件。"
      )
    default:
      return ShortcutItem(
        id: UUID().uuidString,
        name: "新快捷键",
        scope: "全部应用",
        key: "N",
        modifiers: ["control", "option"],
        action: .openURL,
        target: "https://aixlg.com/",
        enabled: false,
        note: "点快捷键框后直接按键。"
      )
    }
  }

  @discardableResult
  func createShortcut(from draft: ShortcutItem, editorOwner: UUID? = nil) -> Bool {
    guard mutationsAllowed else { return false }
    guard validateShortcutEditor(owner: editorOwner) else { return false }
    let originalItems = items
    let originalSelectedID = selectedID
    var item = normalizedShortcutDraft(draft, id: draft.id)
    item.commandID = nil
    item.recoveryID = nil
    item.isBuiltIn = false
    if items.contains(where: { $0.id == item.id }) {
      item.id = UUID().uuidString
    }
    guard validateShortcutDraft(item) else { return false }
    items.insert(item, at: 0)
    selectedID = item.id
    guard saveAndReload() else {
      items = originalItems
      selectedID = originalSelectedID
      return false
    }
    statusMessage = "已新增快捷键：\(item.name)。"
    return true
  }

  @discardableResult
  func updateShortcut(id: String, draft: ShortcutItem, editorOwner: UUID? = nil) -> Bool {
    guard mutationsAllowed else { return false }
    guard validateShortcutEditor(owner: editorOwner) else { return false }
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      statusMessage = "这条快捷键已不存在。"
      return false
    }
    let current = items[index]
    let originalSelectedID = selectedID
    let deletedNamesBefore = deletedShortcutNames()
    let deletedRecoveryIDsBefore = deletedShortcutRecoveryIDs()
    let undoSnapshotBefore = actionPresetUndoSnapshots[id]
    var item = normalizedShortcutDraft(draft, id: id)
    let changesSemanticAction = shortcutSemanticActionChanged(
      current,
      action: item.action,
      target: item.target)
    let mutationDecision = ShortcutActionMutationPolicy.decision(
      isFixedFeature: isFixedFeatureShortcut(current),
      isAppManaged: isAppManagedShortcut(current),
      changesSemanticAction: changesSemanticAction)
    switch mutationDecision {
    case .blockedFixedFeature:
      if changesSemanticAction {
        statusMessage = "这是固定功能快捷键；可改键或停用，不能转换功能。"
        return false
      }
      item.commandID = current.commandID
      item.recoveryID = current.recoveryID
      item.isBuiltIn = current.isBuiltIn
    case .convertManagedDefaultToUserRule:
      guard shortcutDeletionDecision(for: current).canDelete else {
        statusMessage = "这条默认快捷键缺少恢复身份，不能转换功能。"
        return false
      }
      item.commandID = nil
      item.recoveryID = nil
      item.isBuiltIn = false
    case .preserveOwnership:
      if isAppManagedShortcut(current) {
        item.commandID = current.commandID
        item.recoveryID = current.recoveryID
        item.isBuiltIn = current.isBuiltIn
      } else {
        item.commandID = nil
        item.recoveryID = nil
        item.isBuiltIn = false
      }
    }
    guard validateShortcutDraft(item) else { return false }
    replaceShortcutForActionMutation(at: index, with: item)
    selectedID = id
    guard saveAndReload() else {
      items[index] = current
      selectedID = originalSelectedID
      actionPresetUndoSnapshots[id] = undoSnapshotBefore
      setDeletedShortcutNames(deletedNamesBefore)
      setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBefore)
      return false
    }
    statusMessage = "已更新快捷键：\(item.name)。"
    return true
  }

  func normalizedShortcutDraft(_ draft: ShortcutItem, id: String) -> ShortcutItem {
    ShortcutItem(
      id: id,
      commandID: draft.commandID,
      recoveryID: draft.recoveryID,
      isBuiltIn: draft.isBuiltIn,
      name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
      scope: draft.scope.trimmingCharacters(in: .whitespacesAndNewlines),
      key: draft.key.trimmingCharacters(in: .whitespacesAndNewlines),
      modifiers: Array(Set(draft.modifiers)).sorted(),
      trigger: draft.trigger,
      action: draft.action,
      target: draft.target.trimmingCharacters(in: .whitespacesAndNewlines),
      enabled: draft.enabled,
      note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  @discardableResult
  func validateShortcutDraft(_ draft: ShortcutItem) -> Bool {
    guard !draft.name.isEmpty else {
      statusMessage = "请填写功能名称。"
      return false
    }
    if let issue = shortcutIssue(for: draft), issue.kind.isBlocking {
      statusMessage = "未保存：\(issue.kind.label)，\(issue.suggestion)"
      return false
    }
    return true
  }

  func deleteShortcut(id: String) {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let item = items[index]
    let deletionDecision = shortcutDeletionDecision(for: item)
    guard deletionDecision.canDelete else {
      statusMessage = deletionDecision.disabledMessage ?? "这条快捷键不能删除。"
      return
    }
    let originalItems = items
    let originalSelectedID = selectedID
    let deletedNamesBefore = deletedShortcutNames()
    let deletedRecoveryIDsBefore = deletedShortcutRecoveryIDs()
    let undoSnapshotBefore = actionPresetUndoSnapshots[id]
    if recordingItemID == id {
      enableAfterRecordingItemIDs.remove(id)
      stopRecording()
    }
    if shortcutActionCaptureItemID == id {
      shortcutRecorder.cancelAction(ownerID: shortcutActionCaptureSessionID)
    }
    actionPresetUndoSnapshots.removeValue(forKey: id)
    if isAppManagedShortcut(item) {
      markShortcutDeleted(item, recoveryID: deletionDecision.recoveryID)
    }
    let nextID: String?
    if items.indices.contains(index + 1) {
      nextID = items[index + 1].id
    } else if items.indices.contains(index - 1) {
      nextID = items[index - 1].id
    } else {
      nextID = nil
    }
    let deletedSelectedItem = selectedID == id
    items.remove(at: index)
    if deletedSelectedItem {
      selectedID = nextID ?? items.first?.id
    }
    guard saveOnly() else {
      items = originalItems
      selectedID = originalSelectedID
      actionPresetUndoSnapshots[id] = undoSnapshotBefore
      setDeletedShortcutNames(deletedNamesBefore)
      setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBefore)
      return
    }
    onCommittedChange?()
    reloadHotkeys()
    statusMessage =
      deletionDecision.recoveryID == nil
      ? "已删除快捷键：\(item.name)。"
      : "已删除快捷键：\(item.name)。需要时可重新新增或恢复小龙哥最佳配置。"
  }

  func deleteSelected() {
    guard mutationsAllowed else { return }
    guard let selectedID else { return }
    deleteShortcut(id: selectedID)
  }

  @discardableResult
  func canDeleteShortcut(id: String) -> Bool {
    guard let item = items.first(where: { $0.id == id }) else { return false }
    return shortcutDeletionDecision(for: item).canDelete
  }

  func shortcutDeletionHelp(id: String) -> String {
    guard let item = items.first(where: { $0.id == id }) else {
      return "这条快捷键已不存在。"
    }
    let decision = shortcutDeletionDecision(for: item)
    if let disabledMessage = decision.disabledMessage { return disabledMessage }
    return decision.recoveryID == nil
      ? "只会移除这条按键绑定，不会删除对应功能。"
      : "只会移除这条按键绑定；之后可重新新增或从小龙哥最佳配置恢复。"
  }

  func restoreDeletedDefaultShortcuts() {
    guard mutationsAllowed else { return }
    let templates = deletedDefaultShortcutTemplates()
    guard !templates.isEmpty else {
      statusMessage = "没有需要恢复的默认快捷键。"
      return
    }

    let originalItems = items
    let originalSelectedID = selectedID
    var firstRestoredID: String?
    var disabledForConflict = 0
    for template in templates {
      var restored = template
      let signature = shortcutTriggerSignature(for: restored)
      let conflicts =
        restored.enabled && itemConsumesHotkey(restored)
        && items.contains {
          itemConsumesHotkey($0)
            && shortcutTriggerSignature(for: $0) == signature
        }
      if conflicts {
        restored.enabled = false
        restored.note += " 默认组合键与现有规则冲突，已恢复但未自动启用。"
        disabledForConflict += 1
      }
      items.append(restored)
      firstRestoredID = firstRestoredID ?? restored.id
    }

    selectedID = firstRestoredID
    guard saveOnly() else {
      items = originalItems
      selectedID = originalSelectedID
      return
    }
    for template in templates {
      clearShortcutDeletionMarkers(for: template)
    }
    onCommittedChange?()
    reloadHotkeys()
    statusMessage =
      disabledForConflict == 0
      ? "已恢复 \(templates.count) 条默认快捷键。"
      : "已恢复 \(templates.count) 条默认快捷键；\(disabledForConflict) 条因组合键冲突暂未启用。"
  }

  func shortcutDeletionDecision(for item: ShortcutItem) -> ShortcutDeletionDecision {
    let recoveryID = defaultShortcutTemplate(matching: item)?.recoveryID
    return ShortcutDeletionPolicy.decision(
      isAppManaged: isAppManagedShortcut(item),
      isUserDefined: item.isBuiltIn == false,
      isFixedFeature: isFixedFeatureShortcut(item),
      recoveryID: recoveryID)
  }

  @discardableResult
  func isFixedFeatureShortcut(_ item: ShortcutItem) -> Bool {
    item.commandID != nil
      || ShortcutRecoveryIdentity.featureCommandID(from: item.recoveryID) != nil
      || (item.isBuiltIn != false && item.target.hasPrefix("feature-command:"))
  }

  @discardableResult
  func isAppManagedShortcut(_ item: ShortcutItem) -> Bool {
    if item.isBuiltIn == true || item.commandID != nil { return true }
    if item.isBuiltIn == false { return false }
    return defaultShortcuts().contains { template in
      guard template.action == item.action else { return false }
      if item.action == .openApp {
        return (normalizedOpenAppTarget(template.target) ?? template.target)
          == (normalizedOpenAppTarget(item.target) ?? item.target)
      }
      return template.target == item.target
    }
  }

  func defaultShortcutTemplate(matching item: ShortcutItem) -> ShortcutItem? {
    let templates = defaultShortcuts()
    if let recoveryID = item.recoveryID,
      let template = templates.first(where: { $0.recoveryID == recoveryID })
    {
      return template
    }
    if let commandID = item.commandID,
      let template = templates.first(where: { $0.commandID == commandID })
    {
      return template
    }
    return templates.first { shortcut(item, matchesDefaultTemplate: $0) }
  }

  @discardableResult
  func shortcut(_ item: ShortcutItem, matchesDefaultTemplate template: ShortcutItem)
    -> Bool
  {
    if let recoveryID = item.recoveryID, recoveryID == template.recoveryID { return true }
    if let commandID = item.commandID, commandID == template.commandID { return true }
    guard template.action == item.action else { return false }
    if item.action == .openApp {
      return (normalizedOpenAppTarget(template.target) ?? template.target)
        == (normalizedOpenAppTarget(item.target) ?? item.target)
    }
    return template.target == item.target
  }

  func deletedDefaultShortcutTemplates() -> [ShortcutItem] {
    let recoveryIDs = deletedShortcutRecoveryIDs()
    let deletedNames = deletedShortcutNames()
    var seenRecoveryIDs: Set<String> = []
    return defaultShortcuts().filter { template in
      guard let recoveryID = template.recoveryID,
        seenRecoveryIDs.insert(recoveryID).inserted,
        !items.contains(where: { shortcut($0, matchesDefaultTemplate: template) })
      else {
        return false
      }
      return recoveryIDs.contains(recoveryID)
        || !deletedNames.isDisjoint(with: shortcutDeletionNameAliases(for: template))
    }
  }

  @discardableResult
  func migrateBuiltInShortcutOwnership() -> Bool {
    var changed = false
    for index in items.indices {
      if items[index].isBuiltIn == nil {
        items[index].isBuiltIn = isAppManagedShortcut(items[index])
        changed = true
      }
      if items[index].isBuiltIn == true, items[index].recoveryID == nil,
        let recoveryID = defaultShortcutTemplate(matching: items[index])?.recoveryID
      {
        items[index].recoveryID = recoveryID
        changed = true
      }
    }
    return changed
  }

  func resetDefaults() {
    guard mutationsAllowed else { return }
    clearDeletedShortcutNames()
    clearDeletedShortcutRecoveryIDs()
    items = defaultShortcuts()
    markShortcutDefaultBaselineCurrent()
    selectedID = items.first?.id
    saveAndReload()
  }

  func markShortcutDeleted(_ item: ShortcutItem, recoveryID: String?) {
    if let template = defaultShortcutTemplate(matching: item) {
      for name in shortcutDeletionNameAliases(for: template) {
        markShortcutNameDeleted(name)
      }
    }
    if let recoveryID {
      var recoveryIDs = deletedShortcutRecoveryIDs()
      recoveryIDs.insert(recoveryID)
      defaults.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  func markShortcutNameDeleted(_ name: String) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else { return }
    var names = Set(deletedShortcutNames())
    names.insert(normalizedName)
    defaults.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
  }

  @discardableResult
  func isShortcutNameDeleted(_ name: String) -> Bool {
    deletedShortcutNames().contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func clearDeletedShortcutNames() {
    defaults.removeObject(forKey: deletedShortcutNamesDefaultsKey)
  }

  func setDeletedShortcutNames(_ names: Set<String>) {
    if names.isEmpty {
      clearDeletedShortcutNames()
    } else {
      defaults.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
    }
  }

  func deletedShortcutNames() -> Set<String> {
    Set(defaults.stringArray(forKey: deletedShortcutNamesDefaultsKey) ?? [])
  }

  @discardableResult
  func isShortcutRecoveryDeleted(_ recoveryID: String) -> Bool {
    deletedShortcutRecoveryIDs().contains(recoveryID)
  }

  func restoreShortcutRecoveryID(_ recoveryID: String) {
    var recoveryIDs = deletedShortcutRecoveryIDs()
    guard recoveryIDs.remove(recoveryID) != nil else { return }
    if recoveryIDs.isEmpty {
      defaults.removeObject(forKey: deletedShortcutRecoveryIDsDefaultsKey)
    } else {
      defaults.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  func restoreShortcutNames(_ namesToRestore: Set<String>) {
    var names = deletedShortcutNames()
    let originalCount = names.count
    names.subtract(namesToRestore)
    guard names.count != originalCount else { return }
    if names.isEmpty {
      defaults.removeObject(forKey: deletedShortcutNamesDefaultsKey)
    } else {
      defaults.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
    }
  }

  func clearShortcutDeletionMarkers(for item: ShortcutItem) {
    guard let template = defaultShortcutTemplate(matching: item),
      let recoveryID = template.recoveryID
    else {
      return
    }
    restoreShortcutRecoveryID(recoveryID)
    restoreShortcutNames(shortcutDeletionNameAliases(for: template))
  }

  func shortcutDeletionNameAliases(for template: ShortcutItem) -> Set<String> {
    ShortcutRecoveryIdentity.deletionNameAliases(
      recoveryID: template.recoveryID,
      primaryName: template.name)
  }

  func clearDeletedShortcutRecoveryIDs() {
    defaults.removeObject(forKey: deletedShortcutRecoveryIDsDefaultsKey)
  }

  func setDeletedShortcutRecoveryIDs(_ recoveryIDs: Set<String>) {
    if recoveryIDs.isEmpty {
      clearDeletedShortcutRecoveryIDs()
    } else {
      defaults.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  func deletedShortcutRecoveryIDs() -> Set<String> {
    Set(
      defaults.stringArray(forKey: deletedShortcutRecoveryIDsDefaultsKey) ?? [])
  }

  func updateEnabled(_ itemID: String, _ enabled: Bool) {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
    if enabled, let issue = shortcutIssue(for: items[index], assumingEnabled: true),
      issue.kind.isBlocking
    {
      selectedID = itemID
      statusMessage = "未启用：\(issue.kind.label)，\(issue.suggestion)"
      return
    }
    items[index].enabled = enabled
    saveAndReload()
  }

  func shortcutIssue(for item: ShortcutItem, assumingEnabled: Bool? = nil) -> ShortcutIssue? {
    let enabled = assumingEnabled ?? item.enabled
    if let issue = shortcutCompletionIssue(for: item) {
      return issue
    }

    var candidate = item
    candidate.enabled = enabled
    if enabled, itemConsumesHotkey(candidate),
      let conflict = conflictingExecutableItem(for: candidate)
    {
      return ShortcutIssue(
        kind: .shortcutDuplicate,
        hotkey: candidate.displayHotkey,
        object: conflict.name,
        impact: "两项功能使用同一快捷键，按下时无法确定要执行哪一项。",
        suggestion: "请修改本项快捷键，或先停用「\(conflict.name)」。")
    }

    if enabled, let failure = hotkeyFailureText(for: candidate) {
      let kind: ShortcutIssueKind =
        failure.localizedCaseInsensitiveContains("karabiner")
          || failure.contains("外部")
          || failure.contains("接管")
        ? .externalManaged
        : .systemOccupied
      return ShortcutIssue(
        kind: kind,
        hotkey: candidate.displayHotkey,
        object: failure,
        impact: kind == .externalManaged
          ? "这组快捷键正在由其他输入工具处理，本软件无法可靠使用。" : "这组快捷键已被系统占用，当前功能无法启用。",
        suggestion: kind == .externalManaged ? "检查其他输入工具的设置后再启用。" : "请换一组未被系统占用的快捷键。")
    }

    if let conflict = disabledExecutableCollision(for: candidate) {
      return ShortcutIssue(
        kind: .possibleCollision,
        hotkey: candidate.displayHotkey,
        object: conflict.name,
        impact: "停用项里也记录了这组快捷键，不会阻止当前保存。",
        suggestion: "如不再使用，可删除或改掉停用项。")
    }

    return nil
  }

  @discardableResult
  func canUndoActionPreset(itemID: String) -> Bool {
    actionPresetUndoSnapshots[itemID] != nil
  }

  func undoActionPreset(itemID: String) {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      let snapshot = actionPresetUndoSnapshots[itemID]
    else { return }
    let current = items[index]
    let originalSelectedID = selectedID
    let deletedNamesBefore = deletedShortcutNames()
    let deletedRecoveryIDsBefore = deletedShortcutRecoveryIDs()
    actionPresetUndoSnapshots[itemID] = current
    replaceShortcutForActionMutation(at: index, with: snapshot)
    selectedID = itemID
    guard saveAndReload() else {
      items[index] = current
      selectedID = originalSelectedID
      actionPresetUndoSnapshots[itemID] = snapshot
      setDeletedShortcutNames(deletedNamesBefore)
      setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBefore)
      return
    }
  }

  @discardableResult
  func applyActionPreset(
    itemID: String,
    action: ShortcutAction,
    target: String,
    name: String? = nil,
    scope: String? = nil,
    note: String? = nil
  ) -> Bool {
    guard mutationsAllowed else { return false }
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
    let current = items[index]
    let originalSelectedID = selectedID
    let previousUndoSnapshot = actionPresetUndoSnapshots[itemID]
    let deletedNamesBefore = deletedShortcutNames()
    let deletedRecoveryIDsBefore = deletedShortcutRecoveryIDs()
    let normalizedTarget = action == .openApp ? (normalizedOpenAppTarget(target) ?? target) : target
    let changesSemanticAction = shortcutSemanticActionChanged(
      current,
      action: action,
      target: normalizedTarget)
    let mutationDecision = ShortcutActionMutationPolicy.decision(
      isFixedFeature: isFixedFeatureShortcut(current),
      isAppManaged: isAppManagedShortcut(current),
      changesSemanticAction: changesSemanticAction)
    guard mutationDecision != .blockedFixedFeature else {
      statusMessage = "这是固定功能快捷键；可改键或停用，不能转换功能。"
      return false
    }

    var replacement = current
    if mutationDecision == .convertManagedDefaultToUserRule {
      guard shortcutDeletionDecision(for: current).canDelete else {
        statusMessage = "这条默认快捷键缺少恢复身份，不能转换功能。"
        return false
      }
      replacement.commandID = nil
      replacement.recoveryID = nil
      replacement.isBuiltIn = false
    }
    replacement.action = action
    replacement.target = normalizedTarget
    if let name { replacement.name = name }
    if let scope { replacement.scope = scope }
    if let note { replacement.note = note }

    actionPresetUndoSnapshots[itemID] = current
    replaceShortcutForActionMutation(at: index, with: replacement)
    selectedID = itemID
    guard saveAndReload() else {
      items[index] = current
      selectedID = originalSelectedID
      actionPresetUndoSnapshots[itemID] = previousUndoSnapshot
      setDeletedShortcutNames(deletedNamesBefore)
      setDeletedShortcutRecoveryIDs(deletedRecoveryIDsBefore)
      return false
    }
    return true
  }

  @discardableResult
  func canChangeShortcutAction(id: String) -> Bool {
    guard let item = items.first(where: { $0.id == id }) else { return false }
    return !isFixedFeatureShortcut(item)
  }

  func shortcutActionChangeHelp(id: String) -> String {
    canChangeShortcutAction(id: id)
      ? "把这条快捷键改成其他动作。"
      : "这是固定功能快捷键；可改键或停用，不能转换功能。"
  }

  @discardableResult
  func shortcutSemanticActionChanged(
    _ item: ShortcutItem,
    action: ShortcutAction,
    target: String
  ) -> Bool {
    guard item.action == action else { return true }
    if action == .openApp {
      return (normalizedOpenAppTarget(item.target) ?? item.target)
        != (normalizedOpenAppTarget(target) ?? target)
    }
    return item.target != target
  }

  func replaceShortcutForActionMutation(
    at index: Int,
    with replacement: ShortcutItem
  ) {
    let current = items[index]
    let currentIsManaged = isAppManagedShortcut(current)
    let replacementIsManaged = isAppManagedShortcut(replacement)
    if currentIsManaged && !replacementIsManaged {
      let decision = shortcutDeletionDecision(for: current)
      if decision.canDelete {
        markShortcutDeleted(current, recoveryID: decision.recoveryID)
      }
    } else if !currentIsManaged && replacementIsManaged {
      clearShortcutDeletionMarkers(for: replacement)
    }
    items[index] = replacement
  }

  func setOpenTarget(itemID: String, choice: AppChoice) {
    guard mutationsAllowed else { return }
    applyActionPreset(
      itemID: itemID,
      action: .openApp,
      target: choice.target,
      name: "打开 \(choice.name)",
      scope: "App",
      note: "\(choice.source) App：打开 / 置前 / 再按隐藏。"
    )
  }

  @discardableResult
  func isRecording(_ itemID: String) -> Bool { recordingItemID == itemID }

  func startRecording(itemID: String) {
    guard mutationsAllowed else { return }
    hotkeyReloadWorkItem?.cancel()
    hotkeyReloadWorkItem = nil
    shortcutRecordingConflictNotice = nil
    shortcutRecorder.beginItem(itemID: itemID)
  }

  func toggleDraftShortcutRecording(onCaptured: @escaping (ShortcutTriggerRecordingValue) -> Void) {
    guard mutationsAllowed else { return }
    hotkeyReloadWorkItem?.cancel()
    hotkeyReloadWorkItem = nil
    shortcutRecordingConflictNotice = nil
    shortcutRecorder.toggleDraft(onCaptured: onCaptured)
  }

  func cancelDraftShortcutRecording(ownerID: UUID? = nil) { shortcutRecorder.cancelDraft(ownerID: ownerID) }

  func stopRecording() { shortcutRecorder.stopCurrent() }

  func stopShortcutTriggerRecording(reloadHotkeys: Bool) {
    shortcutRecorder.stopCurrent(reloadHotkeys: reloadHotkeys)
  }

  func cancelRecordingIfNeeded() {
    guard isRecording else { return }
    shortcutRecorder.stopCurrent()
    statusMessage = "已取消快捷键录入。"
  }

  func beginShortcutActionCapture(itemID: String) {
    guard mutationsAllowed else { return }
    guard canChangeShortcutAction(id: itemID) else {
      statusMessage = shortcutActionChangeHelp(id: itemID)
      return
    }
    selectedID = itemID
    let item = items.first { $0.id == itemID }
    shortcutRecorder.beginAction(itemID: itemID, initialDraft: item?.action == .sendShortcut ? item?.target ?? "" : "")
  }

  func cancelShortcutActionCapture(ownerID: UUID? = nil) { shortcutRecorder.cancelAction(ownerID: ownerID) }

  func commitRecordedShortcut(session: ShortcutRecordingSession, value: ShortcutTriggerRecordingValue) {
    guard mutationsAllowed else { return }
    guard shortcutRecorder.owns(session.id) else { return }
    if let trigger = value.trigger { commitRecordedPhysicalTrigger(session: session, trigger: trigger) }
    else { commitRecordedChord(session: session, value: value) }
  }

  func setPhysicalRightOptionDoubleTapTrigger(itemID: String) {
    guard mutationsAllowed else { return }
    guard let index = items.firstIndex(where: { $0.id == itemID }) else {
      statusMessage = "未找到要调整的快捷键。"
      return
    }
    let trigger = ShortcutTrigger.rightOptionDoubleTap
    let signature = trigger.signature
    if let conflict = items.first(where: {
      $0.id != itemID && itemConsumesHotkey($0)
        && shortcutTriggerSignature(for: $0) == signature
    }) {
      selectedID = conflict.id
      focusShortcutList?("全部", "")
      statusMessage = "\(trigger.displayText) 已被「\(conflict.name)」占用。"
      return
    }
    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    let originalRevision = shortcutConfiguration.revision
    var candidateItems = originalItems
    var candidateEnableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
    candidateItems[index].trigger = trigger
    if candidateEnableAfterRecordingItemIDs.remove(itemID) != nil {
      candidateItems[index].enabled = true
    }
    if recordingItemID == itemID, let owner = shortcutRecordingSessionID {
      guard shortcutRecorder.finish(ownerID: owner, reloadHotkeys: false) else { return }
    }
    guard items == originalItems, selectedID == originalSelectedID,
      enableAfterRecordingItemIDs == originalEnableAfterRecordingItemIDs,
      shortcutConfiguration.revision == originalRevision else {
      reloadHotkeys()
      return
    }
    items = candidateItems
    enableAfterRecordingItemIDs = candidateEnableAfterRecordingItemIDs
    selectedID = itemID
    guard saveAndReload() else {
      items = originalItems
      selectedID = originalSelectedID
      enableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
      reloadHotkeys()
      return
    }
    statusMessage = "已识别并生效：\(trigger.displayText)。"
  }

  func confirmShortcutActionCapture(ownerID: UUID? = nil) {
    guard mutationsAllowed else { return }
    guard ownerID == nil || ownerID == shortcutActionCaptureSessionID else { return }
    guard let owner = shortcutActionCaptureSessionID,
      let itemID = shortcutActionCaptureItemID,
      let index = items.firstIndex(where: { $0.id == itemID })
    else {
      cancelShortcutActionCapture()
      return
    }
    let target = shortcutActionCaptureDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      statusMessage = "请先按下要发送的快捷键。"
      return
    }
    let currentName = items[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextName =
      currentName.isEmpty || items[index].action != .sendShortcut ? "发送 \(target)" : nil
    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    let originalRevision = shortcutConfiguration.revision
    guard shortcutRecorder.finish(ownerID: owner, reloadHotkeys: false) else { return }
    guard items == originalItems, selectedID == originalSelectedID,
      enableAfterRecordingItemIDs == originalEnableAfterRecordingItemIDs,
      shortcutConfiguration.revision == originalRevision else {
      reloadHotkeys()
      return
    }
    let saved = applyActionPreset(
      itemID: itemID,
      action: .sendShortcut,
      target: target,
      name: nextName,
      scope: "常用按键",
      note: "发送按键"
    )
    if saved {
      statusMessage = "已设置发送按键：\(target)。"
    }
  }

  func commitRecordedChord(session: ShortcutRecordingSession, value: ShortcutTriggerRecordingValue) {
    guard mutationsAllowed else { return }
    guard shortcutRecorder.owns(session.id) else { return }
    let sessionID = session.id
    let key = value.key
    let modifiers = value.modifiers
    guard case .item(let itemID) = session.target,
      let index = items.firstIndex(where: { $0.id == itemID })
    else {
      guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: true) else { return }
      if case .item(let cancelledID) = session.target { enableAfterRecordingItemIDs.remove(cancelledID) }
      statusMessage = "未找到正在编辑的快捷键。"
      return
    }
    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    let originalRevision = shortcutConfiguration.revision
    var candidateItems = originalItems
    var candidateEnableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
    let signature = chordTriggerSignature(key: key, modifiers: modifiers)
    var disabledMissingNames: [String] = []
    for candidateIndex in candidateItems.indices {
      let candidate = candidateItems[candidateIndex]
      guard candidate.enabled, candidate.id != itemID, candidate.action == .openApp,
        shortcutTriggerSignature(for: candidate) == signature,
        !openAppTargetExists(candidate.target) else { continue }
      candidateItems[candidateIndex].enabled = false
      if !candidateItems[candidateIndex].note.contains("目标 App 不存在") {
        candidateItems[candidateIndex].note += candidate.note.isEmpty
          ? "目标 App 不存在，已自动停用。" : " 目标 App 不存在，已自动停用。"
      }
      disabledMissingNames.append(shortcutAppName(candidate))
    }
    let conflicts = candidateItems.filter {
      itemConsumesHotkey($0) && $0.id != itemID && shortcutTriggerSignature(for: $0) == signature
    }
    if let conflict = conflicts.first,
      !canTransferLauncherHotkeyConflicts(currentItem: items[index], conflicts: conflicts)
    {
      guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: true) else { return }
      if case .item(let cancelledID) = session.target { enableAfterRecordingItemIDs.remove(cancelledID) }
      let displayHotkey = displayHotkeyText(key: key, modifiers: modifiers)
      let targetShortcut = parseHotkeyText(conflict.target)
      let opensPreferences =
        conflict.action == .sendShortcut
        && targetShortcut?.key == ","
        && Set(targetShortcut?.modifiers ?? []) == Set(["command"])
      shortcutRecordingConflictNotice = ShortcutRecordingConflictNotice(
        existingItemID: conflict.id,
        hotkey: displayHotkey,
        existingName: conflict.name,
        opensPreferences: opensPreferences
      )
      selectedID = conflict.id
      focusShortcutList?("全部", "")
      statusMessage = shortcutRecordingConflictNotice?.message ?? "\(displayHotkey) 已被占用。"
      return
    }
    var transferredNames = disabledMissingNames
    let conflictIDs = Set(conflicts.map(\.id))
    for candidateIndex in candidateItems.indices where conflictIDs.contains(candidateItems[candidateIndex].id) {
      guard candidateItems[candidateIndex].enabled else { continue }
      candidateItems[candidateIndex].enabled = false
      transferredNames.append(shortcutAppName(candidateItems[candidateIndex]))
    }
    candidateItems[index].key = key
    candidateItems[index].modifiers = modifiers
    candidateItems[index].trigger = nil
    if candidateEnableAfterRecordingItemIDs.remove(itemID) != nil {
      candidateItems[index].enabled = true
    }
    if candidateItems[index].action == .openApp {
      let target = normalizedOpenAppTarget(candidateItems[index].target) ?? candidateItems[index].target
      for candidateIndex in candidateItems.indices where candidateItems[candidateIndex].id != itemID
        && candidateItems[candidateIndex].action == .openApp {
        let otherTarget = normalizedOpenAppTarget(candidateItems[candidateIndex].target)
          ?? candidateItems[candidateIndex].target
        if target == otherTarget { candidateItems[candidateIndex].enabled = false }
      }
    }
    let displayHotkey = candidateItems[index].displayHotkey
    // Ending capture may synchronously publish a new owner or a configuration change.
    // Keep the candidate local until both the recording owner and baseline are accepted.
    guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: false) else { return }
    guard items == originalItems, selectedID == originalSelectedID,
      enableAfterRecordingItemIDs == originalEnableAfterRecordingItemIDs,
      shortcutConfiguration.revision == originalRevision else {
      reloadHotkeys()
      return
    }
    items = candidateItems
    enableAfterRecordingItemIDs = candidateEnableAfterRecordingItemIDs
    guard saveAndReload() else {
      items = originalItems
      selectedID = originalSelectedID
      enableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
      reloadHotkeys()
      return
    }
    if transferredNames.isEmpty {
      statusMessage = "已识别并生效：\(displayHotkey)。"
    } else {
      let transferredText = transferredNames.joined(separator: "、")
      statusMessage = "已识别并生效：\(displayHotkey)，已取消「\(transferredText)」的旧快捷键。"
    }
  }

  func commitRecordedPhysicalTrigger(session: ShortcutRecordingSession, trigger: ShortcutTrigger) {
    guard mutationsAllowed else { return }
    guard shortcutRecorder.owns(session.id) else { return }
    let sessionID = session.id
    guard case .item(let itemID) = session.target,
      let index = items.firstIndex(where: { $0.id == itemID })
    else {
      guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: true) else { return }
      if case .item(let cancelledID) = session.target { enableAfterRecordingItemIDs.remove(cancelledID) }
      statusMessage = "未找到正在编辑的快捷键。"
      return
    }
    let signature = trigger.signature
    if let conflict = items.first(where: {
      $0.id != itemID && itemConsumesHotkey($0)
        && shortcutTriggerSignature(for: $0) == signature
    }) {
      guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: true) else { return }
      if case .item(let cancelledID) = session.target { enableAfterRecordingItemIDs.remove(cancelledID) }
      selectedID = conflict.id
      focusShortcutList?("全部", "")
      statusMessage = "\(trigger.displayText) 已被「\(conflict.name)」占用。"
      return
    }

    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    let originalRevision = shortcutConfiguration.revision
    var candidateItems = originalItems
    var candidateEnableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
    candidateItems[index].trigger = trigger
    if candidateEnableAfterRecordingItemIDs.remove(itemID) != nil {
      candidateItems[index].enabled = true
    }
    guard shortcutRecorder.finish(ownerID: sessionID, reloadHotkeys: false) else { return }
    guard items == originalItems, selectedID == originalSelectedID,
      enableAfterRecordingItemIDs == originalEnableAfterRecordingItemIDs,
      shortcutConfiguration.revision == originalRevision else {
      reloadHotkeys()
      return
    }
    items = candidateItems
    enableAfterRecordingItemIDs = candidateEnableAfterRecordingItemIDs
    selectedID = itemID
    guard saveAndReload() else {
      items = originalItems
      selectedID = originalSelectedID
      enableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
      reloadHotkeys()
      return
    }
    statusMessage = "已识别并生效：\(trigger.displayText)。"
  }

  func disableDuplicateLauncherShortcuts(keeping itemID: String) {
    guard let item = items.first(where: { $0.id == itemID && $0.action == .openApp }) else {
      return
    }
    let targetKey = normalizedOpenAppTarget(item.target) ?? item.target
    for index in items.indices where items[index].id != itemID && items[index].action == .openApp {
      let candidateKey = normalizedOpenAppTarget(items[index].target) ?? items[index].target
      if candidateKey == targetKey {
        items[index].enabled = false
      }
    }
  }

  func conflictingHotkeyItems(
    excluding itemID: String,
    key: String,
    modifiers: [String]
  ) -> [ShortcutItem] {
    let signature = chordTriggerSignature(key: key, modifiers: modifiers)
    return items.filter { item in
      itemConsumesHotkey(item) && item.id != itemID
        && shortcutTriggerSignature(for: item) == signature
    }
  }

  @discardableResult
  func itemConsumesHotkey(_ item: ShortcutItem) -> Bool {
    guard item.enabled else { return false }
    if item.action == .openApp {
      return openAppTargetExists(item.target)
    }
    return true
  }

  func shortcutCompletionIssue(for item: ShortcutItem) -> ShortcutIssue? {
    let hotkey = item.displayHotkey
    let trimmedTarget = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
    if item.trigger == nil && item.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ShortcutIssue(
        kind: .needsCompletion,
        hotkey: hotkey,
        object: "快捷键",
        impact: "这条规则还没有可注册的快捷键。",
        suggestion: "请先录入一组快捷键。")
    }
    switch item.action {
    case .openApp:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "目标 App / 文件 / 文件夹",
          impact: "没有目标时，快捷键不知道要打开什么。",
          suggestion: "请先选择 App、文件或文件夹。")
      }
      if !openAppTargetExists(item.target) {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: item.target,
          impact: "目标 App 或路径当前不可用，启用后也无法稳定执行。",
          suggestion: "请重新选择一个存在的 App、文件或文件夹。")
      }
    case .openURL:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "网址",
          impact: "没有网址时，快捷键无法打开页面。",
          suggestion: "请先填写网址。")
      }
    case .runShell:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "脚本内容",
          impact: "没有脚本时，快捷键不会执行任何动作。",
          suggestion: "请先选择常用脚本或填写脚本。")
      }
    case .sendShortcut:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "要发送的快捷键",
          impact: "没有目标快捷键时，桥接动作无法发送。",
          suggestion: "请先录入要发送给当前 App 的快捷键。")
      }
    case .windowPreset:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "窗口动作",
          impact: "缺少窗口动作时，快捷键无法执行。",
          suggestion: "请先选择一个窗口管理动作。")
      }
    case .insertText:
      if trimmedTarget.isEmpty {
        return ShortcutIssue(
          kind: .needsCompletion,
          hotkey: hotkey,
          object: "输入内容",
          impact: "没有输入内容时，快捷键不会打出任何字符。",
          suggestion: "请先填写要输入的文本。")
      }
    case .showPanel, .showLauncher, .showProcessViewer, .showClipboardHistory,
      .showCodexNetworkProbe, .showSleepPanel, .nativeFullScreen, .closeWindowSmart:
      break
    }
    return nil
  }

  func conflictingExecutableItem(for item: ShortcutItem) -> ShortcutItem? {
    let signature = shortcutTriggerSignature(for: item)
    return items.first { candidate in
      candidate.id != item.id && itemConsumesHotkey(candidate)
        && shortcutTriggerSignature(for: candidate) == signature
    }
  }

  func disabledExecutableCollision(for item: ShortcutItem) -> ShortcutItem? {
    let signature = shortcutTriggerSignature(for: item)
    return items.first { candidate in
      candidate.id != item.id && !candidate.enabled
        && shortcutTriggerSignature(for: candidate) == signature
    }
  }

  @discardableResult
  func hotkeyFailureText(for item: ShortcutItem) -> String? {
    hotkeyFailures.first { failure in
      failure.contains(item.name) || failure.contains(item.displayHotkey)
    }
  }

  @discardableResult
  func canTransferLauncherHotkeyConflicts(
    currentItem: ShortcutItem,
    conflicts: [ShortcutItem]
  ) -> Bool {
    guard isLauncherOpenAppShortcut(currentItem), !conflicts.isEmpty else { return false }
    return conflicts.allSatisfy(isLauncherOpenAppShortcut)
  }

  func disableLauncherHotkeyConflicts(_ conflicts: [ShortcutItem]) -> [String] {
    var disabledNames: [String] = []
    let conflictIDs = Set(conflicts.map(\.id))
    for index in items.indices where conflictIDs.contains(items[index].id) {
      guard items[index].enabled else { continue }
      items[index].enabled = false
      disabledNames.append(shortcutAppName(items[index]))
    }
    return disabledNames
  }

  @discardableResult
  func isLauncherOpenAppShortcut(_ item: ShortcutItem) -> Bool {
    guard item.action == .openApp,
      let target = normalizedOpenAppTarget(item.target),
      target.hasPrefix("bundle:")
    else {
      return false
    }
    let scope = item.scope.trimmingCharacters(in: .whitespacesAndNewlines)
    if scope.contains("系统") || scope == "窗口" || scope == "插件"
      || scope == "脚本" || scope == "短语"
    {
      return false
    }
    return true
  }

  func shortcutAppName(_ item: ShortcutItem) -> String {
    var name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("打开 ") {
      name.removeFirst(3)
    } else if name.hasPrefix("打开") {
      name.removeFirst(2)
    }
    return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.name : name
  }

  @discardableResult
  func repairMissingDefaultBrowserShortcut() -> Bool {
    var changed = false
    for index in items.indices
    where
      items[index].isBuiltIn != false && isDefaultChromeBrowserShortcut(items[index])
    {
      guard !openAppTargetExists(items[index].target),
        let browser = preferredBrowserShortcutTarget()
      else {
        continue
      }
      items[index].name = "打开 \(browser.name)"
      items[index].target = browser.target
      items[index].note = "浏览器快捷键：Chrome 不存在时自动指向本机默认或已安装浏览器。"
      changed = true
    }
    return changed
  }

  @discardableResult
  func isDefaultChromeBrowserShortcut(_ item: ShortcutItem) -> Bool {
    item.action == .openApp
      && item.name == "打开 Chrome"
      && item.key == "E"
      && Set(item.modifiers) == Set(["control", "option"])
      && (normalizedOpenAppTarget(item.target) ?? item.target) == "bundle:com.google.Chrome"
  }

  func disableMissingOpenAppShortcuts(
    excluding itemID: String? = nil,
    matchingSignature signature: String? = nil
  ) -> [String] {
    var disabledNames: [String] = []
    for index in items.indices
    where items[index].enabled && items[index].id != itemID && items[index].action == .openApp {
      if let signature,
        shortcutTriggerSignature(for: items[index]) != signature
      {
        continue
      }
      guard !openAppTargetExists(items[index].target) else { continue }
      items[index].enabled = false
      if !items[index].note.contains("目标 App 不存在") {
        items[index].note += items[index].note.isEmpty ? "目标 App 不存在，已自动停用。" : " 目标 App 不存在，已自动停用。"
      }
      disabledNames.append(shortcutAppName(items[index]))
    }
    return disabledNames
  }

}
