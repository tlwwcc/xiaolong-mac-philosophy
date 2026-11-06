import AppKit
import ApplicationServices
import Carbon
import Combine
import IOKit.pwr_mgt
import MacAutomationCore
import SwiftUI
import UniformTypeIdentifiers

struct AppChoice: Identifiable, Hashable {
  let id: String
  let name: String
  let target: String
  let source: String
}

struct KeepAwakeDurationOption: Identifiable, Hashable {
  let minutes: Int
  let title: String

  var id: Int { minutes }
}

struct LauncherAppShortcut: Hashable {
  let itemID: String
  let name: String
  let hotkey: String
}







struct ShortcutRecordingConflictNotice: Equatable {
  let existingItemID: String
  let hotkey: String
  let existingName: String
  let opensPreferences: Bool

  var message: String {
    if opensPreferences {
      return "\(hotkey) 已设置：向当前 App 发送 ⌘ + ,。"
    }
    return "\(hotkey) 已被「\(existingName)」使用。"
  }
}

@MainActor
final class AppModel: ObservableObject {
  nonisolated static let launcherPluginID = "launcher"
  nonisolated static let phrasesPluginID = "phrases"
  let runtimeIdentity = AppRuntimeIdentity.current
  var sparkleCheckForUpdatesHandler: (() -> Void)? {
    get { updateWorkspace.sparkleCheckForUpdatesHandler }
    set { updateWorkspace.sparkleCheckForUpdatesHandler = newValue }
  }
  private var launcherWorkspaceSubscription: AnyCancellable?
  lazy var launcherWorkspace: LauncherWorkspace = {
    let workspace = LauncherWorkspace(
      indexURL: launcherIndexURL, historyURL: launcherHistoryURL, pinnedURL: launcherPinnedURL)
    workspace.onStatus = { [weak self] in self?.statusMessage = $0 }
    workspace.onHotkeysChanged = { [weak self] in self?.reloadHotkeys() }
    workspace.onPrioritizeApps = { [weak self] in self?.prioritizedLauncherApps($0) ?? $0 }
    launcherWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  private var keepAwakeWorkspaceSubscription: AnyCancellable?
  lazy var keepAwakeWorkspace: KeepAwakeWorkspace = {
    let workspace = KeepAwakeWorkspace()
    workspace.onStatus = { [weak self] in self?.statusMessage = $0 }
    workspace.onStateChanged = { [weak self] in self?.notifySleepStatusItemChanged() }
    keepAwakeWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  private var updateWorkspaceSubscription: AnyCancellable?
  lazy var updateWorkspace: UpdateWorkspace = {
    let workspace = UpdateWorkspace(
      allowsOnlineUpdates: runtimeIdentity.allowsOnlineUpdates,
      currentBuildNumber: currentBuildNumber, appVersionText: appVersionText,
      onStatus: { [weak self] in self?.statusMessage = $0 })
    updateWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  private lazy var shortcutActions = ShortcutActionService(
    onStatus: { [weak self] in self?.statusMessage = $0 },
    toggleSettings: { [weak self] in self?.toggleShortcutWindow(.settings) ?? .unavailable },
    presentSettings: { [weak self] in
      self?.showSettings()
      self?.presentWindowHandler?()
    },
    presentAuthorization: { [weak self] in self?.presentAuthorizationCenter() })
  private lazy var applicationOpening = ApplicationOpeningService { [weak self] message in
    self?.statusMessage = message
  }
  private var shutdownStarted = false
  private var globalInputSubscription: AnyCancellable?
  lazy var globalInputWorkspace: GlobalInputWorkspace = {
    let workspace = GlobalInputWorkspace(
      environment: .live(identity: runtimeIdentity),
      features: .init(
        refreshPermissions: { [weak self] in
          guard let self else {
            return GlobalInputPermissions(accessibility: false, inputMonitoring: false)
          }
          self.refreshAccessibilityStatus()
          let snapshot = self.authorizationPermissionSnapshot
          return GlobalInputPermissions(
            accessibility: snapshot.accessibility, inputMonitoring: snapshot.inputMonitoring)
        },
        registrationItems: { [weak self] in self?.hotkeyRegistrationItems() ?? [] },
        committedItems: { [weak self] in self?.items ?? [] },
        committedPhrases: { [weak self] in self?.phraseWorkspace.committedPhrases ?? [] },
        recordingOwner: { [weak self] in self?.shortcutRecorder.sessionID },
        repairMissingApps: { [weak self] in
          guard let self else { return }
          if !self.disableMissingOpenAppShortcuts().isEmpty { _ = self.saveOnly() }
        },
        perform: { [weak self] item, context in self?.perform(item, context: context) },
        cancelRecording: { [weak self] in self?.stopRecording() },
        willYieldOwnership: { [weak self] in self?.globalInputOwnershipWillYieldHandler?() },
        reloadScroll: { [weak self] in self?.reloadScrollEngine() },
        shutdownScroll: { [weak self] in self?.scrollWorkspace.shutdown() },
        scrollHealth: { [weak self] in
          guard let self else { return (required: false, running: false) }
          return (required: self.scrollSettings.needsEventTap,
            running: self.scrollWorkspace.listenerIsRunning)
        },
        synchronizeRetiredClassic: { [weak self] in self?.reloadClassicTabSwitcher() }),
      onStatus: { [weak self] in self?.statusMessage = $0 })
    globalInputSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var hasGlobalInputOwnership: Bool { globalInputWorkspace.hasOwnership }


  var items: [ShortcutItem] { shortcutWorkspace.items }
  var selectedID: String? {
    get { shortcutWorkspace.selectedID }
    set { shortcutWorkspace.selectedID = newValue }
  }
  @Published var statusMessage = "正在启动..."
  var isPaused: Bool { globalInputWorkspace.isPaused }
  var recordingItemID: String? { shortcutRecorder.recordingItemID }
  var isDraftShortcutRecording: Bool { shortcutRecorder.isDraftShortcutRecording }
  var hasActiveShortcutEditors: Bool { shortcutWorkspace.hasActiveShortcutEditors }

  func beginShortcutEditing(owner: UUID) {
    return shortcutWorkspace.beginShortcutEditing(owner: owner)
  }

  func endShortcutEditing(owner: UUID) {
    return shortcutWorkspace.endShortcutEditing(owner: owner)
  }

  func validateShortcutEditor(owner: UUID?) -> Bool {
    return shortcutWorkspace.validateShortcutEditor(owner: owner)
  }
  var shortcutRecordingConflictNotice: ShortcutRecordingConflictNotice? {
    get { shortcutWorkspace.shortcutRecordingConflictNotice }
    set { shortcutWorkspace.shortcutRecordingConflictNotice = newValue }
  }
  var shortcutActionCaptureItemID: String? { shortcutRecorder.actionCaptureItemID }
  var shortcutActionCaptureDraft: String { shortcutRecorder.actionCaptureDraft }
  var hotkeyFailures: [String] { globalInputWorkspace.hotkeyFailures }
  var advancedListeningAuthorized: Bool { authorizationWorkspace.advancedListeningAuthorized }
  var inputMonitoringAuthorized: Bool { authorizationWorkspace.inputMonitoringAuthorized }
  var screenRecordingAuthorized: Bool { authorizationWorkspace.screenRecordingAuthorized }
  var capsCorePluginEnabled: Bool { globalInputWorkspace.capsEnabled }
  var capsCoreEngineRunning: Bool { globalInputWorkspace.capsRunning }
  var capsCorePluginStatus: CapsCorePluginStatus { globalInputWorkspace.capsStatus }
  var legacyScrollProfile: LegacyScrollProfile { scrollWorkspace.legacyProfile }
  var scrollSettings: ScrollEngineSettings { scrollWorkspace.settings }
  var scrollEngineRunning: Bool { scrollWorkspace.isRunning }
  private var scrollWorkspaceSubscription: AnyCancellable?
  lazy var scrollWorkspace: ScrollWorkspace = {
    let workspace = ScrollWorkspace(
      hasGlobalInputOwnership: { [weak self] in self?.hasGlobalInputOwnership ?? false },
      ownershipBlockedMessage: { [weak self] in self?.globalInputOwnershipBlockedMessage ?? "全局输入独占权尚未取得" },
      permissions: { [weak self] in
        let snapshot = self?.authorizationPermissionSnapshot
        return ScrollWorkspacePermissions(accessibility: snapshot?.accessibility ?? false,
          inputMonitoring: snapshot?.inputMonitoring ?? false)
      },
      requestLegacyQuit: { [weak self] in
        self?.shortcutActions.runShell("osascript -e 'tell application \"Mos\" to quit'")
      })
    workspace.onStatus = { [weak self] in self?.statusMessage = $0 }
    scrollWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var launchAtLoginEnabled: Bool { startupWorkspace.enabled }
  private var startupWorkspaceSubscription: AnyCancellable?
  lazy var startupWorkspace: StartupPreferenceWorkspace = {
    let workspace = StartupPreferenceWorkspace(identity: runtimeIdentity,
      onStatus: { [weak self] in self?.statusMessage = $0 })
    startupWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var phrases: [PhraseItem] {
    get { phraseWorkspace.phrases }
    set { phraseWorkspace.phrases = newValue }
  }
  var selectedPhraseID: String? {
    get { phraseWorkspace.selectedPhraseID }
    set { phraseWorkspace.selectedPhraseID = newValue }
  }
  var launcherApps: [LauncherApp] {
    get { launcherWorkspace.launcherApps }
  }
  var launcherQuery: String {
    get { launcherWorkspace.launcherQuery }
    set { launcherWorkspace.launcherQuery = newValue }
  }
  var launcherSearchEngine: LauncherSearchEngine {
    get { launcherWorkspace.launcherSearchEngine }
  }
  var launcherPinnedRecords: [LauncherPinnedRecord] {
    get { launcherWorkspace.launcherPinnedRecords }
  }
  var launcherPinnedStatusText: String {
    get { launcherWorkspace.launcherPinnedStatusText }
  }
  var isLauncherScanning: Bool {
    get { launcherWorkspace.isLauncherScanning }
  }
  var launcherDisplayMode: LauncherDisplayMode {
    get { launcherWorkspace.launcherDisplayMode }
  }
  var launcherShowsPinnedNames: Bool {
    get { launcherWorkspace.launcherShowsPinnedNames }
  }
  var launcherPluginEnabled: Bool {
    get { launcherWorkspace.launcherPluginEnabled }
  }
  var launcherSelectedResultID: String? {
    get { launcherWorkspace.launcherSelectedResultID }
    set { launcherWorkspace.launcherSelectedResultID = newValue }
  }
  var launcherFocusRequestID: Int {
    get { launcherWorkspace.launcherFocusRequestID }
  }
  private var mainWorkspaceSubscription: AnyCancellable?
  lazy var mainWorkspace: MainWorkspace = {
    let workspace = MainWorkspace()
    mainWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var selectedPluginID: String? {
    get { mainWorkspace.selectedPluginID }
    set { mainWorkspace.selectedPluginID = newValue }
  }
  var pluginCenterScrollAnchorID: String? {
    get { mainWorkspace.pluginCenterScrollAnchorID }
    set { mainWorkspace.pluginCenterScrollAnchorID = newValue }
  }
  var selectedModuleName: String {
    get { mainWorkspace.selectedModuleName }
    set { mainWorkspace.selectedModuleName = newValue }
  }
  var selectedAboutSection: String {
    get { mainWorkspace.selectedAboutSection }
    set { mainWorkspace.selectedAboutSection = newValue }
  }
  var shortcutGuideFocusRequest: Int {
    get { mainWorkspace.shortcutGuideFocusRequest }
    set { mainWorkspace.shortcutGuideFocusRequest = newValue }
  }
  var shortcutGuideRequestedCategory: String {
    get { mainWorkspace.shortcutGuideRequestedCategory }
    set { mainWorkspace.shortcutGuideRequestedCategory = newValue }
  }
  var shortcutGuideRequestedSearchText: String {
    get { mainWorkspace.shortcutGuideRequestedSearchText }
    set { mainWorkspace.shortcutGuideRequestedSearchText = newValue }
  }
  var softwareShortcutRequest: SoftwareShortcutRequest? {
    get { mainWorkspace.softwareShortcutRequest }
    set { mainWorkspace.softwareShortcutRequest = newValue }
  }
  var shortcutCreateRequestID: Int {
    get { mainWorkspace.shortcutCreateRequestID }
    set { mainWorkspace.shortcutCreateRequestID = newValue }
  }
  var shortcutEditRequestID: Int {
    get { mainWorkspace.shortcutEditRequestID }
    set { mainWorkspace.shortcutEditRequestID = newValue }
  }
  var sleepPanelRequestID: Int {
    get { mainWorkspace.sleepPanelRequestID }
    set { mainWorkspace.sleepPanelRequestID = newValue }
  }
  var isMenuBarCustomizationPresented: Bool {
    get { mainWorkspace.isMenuBarCustomizationPresented }
    set { mainWorkspace.isMenuBarCustomizationPresented = newValue }
  }
  var isCommunityQRCodePresented: Bool {
    get { mainWorkspace.isCommunityQRCodePresented }
    set { mainWorkspace.isCommunityQRCodePresented = newValue }
  }
  @Published var diagnosticsEnabled = AppDiagnostics.isEnabled
  var keepAwakeEnabled: Bool { keepAwakeWorkspace.enabled }
  var keepAwakePreventDisplaySleep: Bool { keepAwakeWorkspace.preventDisplaySleep }
  var keepAwakeStatusText: String { keepAwakeWorkspace.statusText }
  var keepAwakeCustomHours: Int { keepAwakeWorkspace.customHours }
  private var shellPreferencesSubscription: AnyCancellable?
  lazy var shellPreferences: ShellPreferencesWorkspace = {
    let workspace = ShellPreferencesWorkspace(dependencies: .init(
      applyDockVisibility: { DockPresencePreference.apply(visible: true) },
      notify: { change in
        switch change {
        case .sleepStatus:
          NotificationCenter.default.post(name: .sleepStatusItemChanged, object: nil)
        case .menuBar:
          NotificationCenter.default.post(name: .menuBarConfigurationChanged, object: nil)
        case .networkSpeed:
          NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
        }
      }))
    workspace.onStatus = { [weak self] in self?.statusMessage = $0 }
    workspace.allowsOrdinaryWrites = { [weak self] in
      guard let self else { return false }
      return self.configRestore.acceptsOrdinaryWrites && !self.hasActiveUninstallTransaction
    }
    shellPreferencesSubscription = workspace.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var sleepStatusItemVisible: Bool { shellPreferences.sleepStatusItemVisible }
  var dockIconVisible: Bool { shellPreferences.dockIconVisible }
  var menuBarVisibleItemIDs: Set<MenuBarCatalogItemID> { shellPreferences.menuBarVisibleItemIDs }
  var systemMonitorSnapshot: SystemMonitorSnapshot { systemMonitorWorkspace.snapshot }
  var networkSpeedPluginEnabled: Bool { shellPreferences.networkSpeedPluginEnabled }
  var networkSpeedShowMemory: Bool { shellPreferences.networkSpeedShowMemory }
  var networkSpeedShowCPU: Bool { shellPreferences.networkSpeedShowCPU }
  var networkSpeedShowGPU: Bool { shellPreferences.networkSpeedShowGPU }
  var pdfFileAssociationCoverage: FileAssociationStatus.Coverage { fileAssociationWorkspace.pdfFileAssociationCoverage }
  var audioFileAssociationCoverage: FileAssociationStatus.Coverage { fileAssociationWorkspace.audioFileAssociationCoverage }
  var pdfFileAssociationCanRestore: Bool { fileAssociationWorkspace.pdfFileAssociationCanRestore }
  var audioFileAssociationCanRestore: Bool { fileAssociationWorkspace.audioFileAssociationCanRestore }
  var fileAssociationBusyKind: AssociatedFileKind? { fileAssociationWorkspace.fileAssociationBusyKind }
  var fileAssociationFeedbackKind: AssociatedFileKind? { fileAssociationWorkspace.fileAssociationFeedbackKind }
  var fileAssociationFeedbackText: String { fileAssociationWorkspace.fileAssociationFeedbackText }
  var codexNetworkProbeDefaultDirection: NetworkProbeDirection { shellPreferences.codexNetworkProbeDefaultDirection }
  var sparkleUpdateReminder: SparkleUpdateReminder {
    get { updateWorkspace.sparkleUpdateReminder }
  }
  var latestUpdate: AppUpdateManifest? {
    get { updateWorkspace.latestUpdate }
    set { updateWorkspace.latestUpdate = newValue }
  }
  var updateServerVersionText: String {
    get { updateWorkspace.updateServerVersionText }
    set { updateWorkspace.updateServerVersionText = newValue }
  }
  var updateStatusText: String {
    get { updateWorkspace.updateStatusText }
    set { updateWorkspace.updateStatusText = newValue }
  }
  var updateReleaseDetailText: String {
    get { updateWorkspace.updateReleaseDetailText }
    set { updateWorkspace.updateReleaseDetailText = newValue }
  }
  var updateDownloadProgress: Double? {
    get { updateWorkspace.updateDownloadProgress }
    set { updateWorkspace.updateDownloadProgress = newValue }
  }
  var updateFailureMessage: String? {
    get { updateWorkspace.updateFailureMessage }
    set { updateWorkspace.updateFailureMessage = newValue }
  }
  var isUpdateBusy: Bool {
    get { updateWorkspace.isUpdateBusy }
    set { updateWorkspace.isUpdateBusy = newValue }
  }
  var pendingReleaseNote: ReleaseNoteEntry? {
    get { updateWorkspace.pendingReleaseNote }
    set { updateWorkspace.pendingReleaseNote = newValue }
  }
  var isReleaseNotePresented: Bool {
    get { updateWorkspace.isReleaseNotePresented }
    set { updateWorkspace.isReleaseNotePresented = newValue }
  }
  var shortcutSemanticMigrationMessage: String { shortcutWorkspace.shortcutSemanticMigrationMessage }
  var lastShortcutSemanticBackupURL: URL? { shortcutWorkspace.lastShortcutSemanticBackupURL }
  @Published var pijuanPDFShortcutCount = 0
  var isAccessibilityAuthorizationPresented: Bool {
    get { authorizationWorkspace.isAccessibilityAuthorizationPresented }
    set { authorizationWorkspace.isAccessibilityAuthorizationPresented = newValue }
  }


  var authorizationRelaunchCompleted: Bool { authorizationWorkspace.authorizationRelaunchCompleted }
  var authorizationAutomaticRelaunchInProgress: Bool { authorizationWorkspace.authorizationAutomaticRelaunchInProgress }
  var authorizationManualRelaunchRequired: Bool { authorizationWorkspace.authorizationManualRelaunchRequired }
  var appSignatureSummary: String { authorizationWorkspace.appSignatureSummary }
  var isRepairingAuthorization: Bool { authorizationWorkspace.isRepairingAuthorization }
  var authorizationRepairResultText: String { authorizationWorkspace.authorizationRepairResultText }
  var authorizationRecheckFailed: Bool { authorizationWorkspace.authorizationRecheckFailed }
  var isImportingXLGConfig: Bool { configRestore.isRestoring }
  var isChangingShortcutConfiguration: Bool {
    configRestore.isRestoring || launcherReferenceOwnerID != nil
  }
  var hasActiveUninstallTransaction: Bool { launcherReferenceOwnerID != nil }
  var lastXLGConfigImportBackupURL: URL? { configRestore.lastBackupURL }
  private var configRestoreSubscription: AnyCancellable?
  lazy var configRestore: ConfigRestoreCoordinator = {
    let coordinator = ConfigRestoreCoordinator(
      makeRequest: { [weak self] owner in
        guard let self else { throw CocoaError(.userCancelled) }
        guard self.launcherReferenceOwnerID == nil,
          !self.hasActiveShortcutEditors, !self.isRecording, !self.isCapturingShortcutAction else {
          throw AutomationError(code: "configuration_busy", message: "请先保存或取消正在编辑的快捷键，再恢复配置。")
        }
        guard self.phraseWorkspace.flushPendingSave(reload: false) else {
          throw AutomationError(code: "unsaved_phrases", message: "快捷短语尚未保存，请先处理保存提示再恢复。")
        }
        var request = XLGConfigImportRequest.appDefault(
          applicationSupportURL: self.fileURL.deletingLastPathComponent(),
          shortcutsURL: self.fileURL, phrasesURL: self.phraseURL, allowNetworkDownload: false)
        request.shortcutTransaction = try self.shortcutConfiguration.beginRestoreTransaction(ownerID: owner)
        return request
      },
      release: { [weak self] owner in self?.shortcutConfiguration.endRestoreTransaction(ownerID: owner) },
      onSuccess: { [weak self] in self?.finishXLGConfigImport($0) },
      onFailure: { [weak self] in self?.statusMessage = "最佳配置恢复失败：\($0)" })
    configRestoreSubscription = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    return coordinator
  }()
  @Published var classicTabSwitcherEnabled = false
  @Published var classicTabSwitcherCommandTabTakeoverConfirmed = false
  @Published var classicTabSwitcherRunning = false
  @Published var classicTabSwitcherStatusText = "未监听"
  @Published var classicTabSwitcherHUDState = ClassicTabSwitcherHUDState.hidden

  let fileURL: URL
  private var shortcutWorkspaceSubscription: AnyCancellable?
  lazy var shortcutWorkspace: ShortcutWorkspace = {
    let workspace = ShortcutWorkspace(
      fileURL: fileURL, configuration: shortcutConfiguration,
      dependencies: .init(
        normalizedOpenAppTarget: { [weak self] in self?.normalizedOpenAppTarget($0) },
        openAppTargetExists: { [weak self] in self?.openAppTargetExists($0) ?? false },
        preferredBrowserShortcutTarget: { [weak self] in self?.preferredBrowserShortcutTarget() }))
    workspace.onStatus = { [weak self] in self?.statusMessage = $0 }
    workspace.onRecoveryChanged = { [weak self] in self?.updateConfigurationRecoveryMessage() }
    workspace.onCommittedChange = { [weak self] in self?.launcherWorkspace.invalidateSearchCache() }
    workspace.requestHotkeyReload = { [weak self] in self?.reloadHotkeys() }
    workspace.suspendHotkeys = { [weak self] in self?.globalInputWorkspace.suspendForRecording() }
    workspace.hasGlobalInputOwnership = { [weak self] in self?.hasGlobalInputOwnership ?? false }
    workspace.ownershipBlockedMessage = { [weak self] in self?.globalInputOwnershipBlockedMessage ?? "全局输入独占权尚未取得" }
    workspace.currentHotkeyFailures = { [weak self] in self?.hotkeyFailures ?? [] }
    workspace.isLauncherEnabled = { [weak self] in self?.launcherPluginEnabled ?? false }
    workspace.allowsConfigurationMutation = { [weak self] in
      guard let self else { return false }
      return self.configRestore.acceptsOrdinaryWrites && self.launcherReferenceOwnerID == nil
    }
    workspace.selectShortcutModule = { [weak self] in self?.selectedModuleName = "功能快捷键" }
    workspace.focusShortcutList = { [weak self] category, search in
      guard let self else { return }
      self.shortcutGuideRequestedCategory = category
      self.shortcutGuideRequestedSearchText = search
      self.shortcutGuideFocusRequest &+= 1
    }
    workspace.presentWindow = { [weak self] in self?.presentWindowHandler?() }
    shortcutWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    return workspace
  }()
  let shortcutConfiguration: ShortcutConfigurationService
  private var phraseWorkspaceSubscription: AnyCancellable?
  lazy var phraseWorkspace: PhraseWorkspace = {
    let workspace = PhraseWorkspace(fileURL: phraseURL)
    workspace.onReload = { [weak self] in self?.reloadPhraseExpander() }
    workspace.onStatus = { [weak self] message in self?.statusMessage = message }
    workspace.onRecoveryChanged = { [weak self] in self?.updateConfigurationRecoveryMessage() }
    phraseWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  private var authorizationWorkspaceSubscription: AnyCancellable?
  lazy var authorizationWorkspace: AuthorizationWorkspace = {
    let workspace = AuthorizationWorkspace(runtimeIdentity: runtimeIdentity)
    workspace.onStatus = { [weak self] message in self?.statusMessage = message }
    workspace.presentMainWindow = { [weak self] in
      guard let self else { return }
      if let present = self.presentWindowHandler { present() }
      else { self.showWindowHandler?() }
    }
    workspace.requestPolling = { [weak self] reason in self?.authorizationPollingRequestHandler?(reason) }
    workspace.requestTermination = { [weak self] intent in
      self?.authorizationTerminationHandler?(intent) ?? false
    }
    workspace.featurePermissionsChanged = { [weak self] previous, current in
      self?.integratedFeaturePermissionsDidChangeHandler?(previous, current)
    }
    workspace.refreshCapsConflict = { [weak self] in self?.refreshCapsCoreConflictIfNeeded() }
    workspace.reloadListeners = { [weak self] in self?.reloadPermissionDependentListeners() }
    workspace.listenerVerification = { [weak self] in
      self?.authorizationListenerVerification()
        ?? AuthorizationListenerVerification(required: [], failed: [])
    }
    authorizationWorkspaceSubscription = workspace.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  let phraseURL: URL
  let launcherIndexURL: URL
  let launcherHistoryURL: URL
  let launcherPinnedURL: URL
  let clipboardHistory: ClipboardHistoryController
  private var fileAssociationSubscription: AnyCancellable?
  lazy var fileAssociationWorkspace: FileAssociationSettingsWorkspace = {
    let workspace = FileAssociationSettingsWorkspace(changesAllowed: { [weak self] in
      self?.fileAssociationChangesAllowed ?? false
    })
    workspace.onStatus = { [weak self] message in self?.statusMessage = message }
    fileAssociationSubscription = workspace.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    return workspace
  }()
  var fileAssociationChangesAllowed: Bool {
    guard ProductReleaseIdentity.isFormalRelease, !runtimeIdentity.isInvalid else {
      return false
    }
    guard
      Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        == runtimeIdentity.installURL.resolvingSymlinksInPath().standardizedFileURL
    else { return false }
    return FileAssociationRuntimeAuthorization.currentProcessIsTrustedStableRelease
  }
  var showWindowHandler: (() -> Void)?
  var presentWindowHandler: (() -> Void)?
  var toggleShortcutWindowHandler: ((ShortcutWindowTarget) -> ShortcutWindowToggleOutcome)?
  var showLauncherHandler: (() -> Void)?
  var showProcessViewerHandler: (() -> Void)?
  var showClipboardHistoryHandler: (() -> Void)?
  var showCodexNetworkProbeHandler: (() -> Void)?
  var showYoumuFeatureHandler: (() -> Void)?
  var makeYoumuSettingsViewHandler: (() -> AnyView?)?
  var showPijuanPDFFeatureHandler: (() -> Void)?
  var openPijuanPDFDocumentHandler: ((URL) -> Void)?
  var showSleepPanelHandler: (() -> Void)?
  var makePijuanPDFShortcutSettingsViewHandler: (() -> AnyView?)?
  var executeFeatureCommandHandler: ((String) -> Void)?
  var globalInputOwnershipWillYieldHandler: (() -> Void)?
  var integratedFeaturePermissionsDidChangeHandler:
    ((AuthorizationPermissionSnapshot, AuthorizationPermissionSnapshot) -> Void)?
  var classicTabSwitcherHUDHandler: ((ClassicTabSwitcherHUDState) -> Void)?
  var authorizationPollingRequestHandler: ((String) -> Void)?
  var authorizationTerminationHandler: ((AuthorizationTerminationIntent) -> Bool)?


  var isLongScreenshotCaptureActive: Bool { scrollWorkspace.isLongScreenshotCaptureActive }
  private var shortcutRecordingSession: ShortcutRecordingSession? {
    shortcutRecorder.isRecording ? shortcutRecorder.session : nil
  }
  private var shortcutRecorder: ShortcutRecordingCoordinator { shortcutWorkspace.shortcutRecorder }
  @Published private(set) var configurationRecoveryMessage: String?
  private var launcherUninstallRequestID: String?
  private var launcherReferenceOwnerID: UUID?
  private var systemMonitorSubscription: AnyCancellable?
  lazy var systemMonitorWorkspace: SystemMonitorWorkspace = {
    let workspace = SystemMonitorWorkspace()
    systemMonitorSubscription = workspace.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    return workspace
  }()

  private static let classicTabSwitcherEnabledDefaultsKey = "classicTabSwitcherEnabledV1"
  private static let classicTabSwitcherDemotionDefaultsKey = "classicTabSwitcherDemotionV1"
  private static let classicTabSwitcherBuiltInRouteDefaultsKey = "classicTabSwitcherBuiltInRouteV1"
  private static let classicTabSwitcherRetiredDefaultsKey = "classicTabSwitcherRetiredV1"
  private static let classicTabSwitcherCommandTabTakeoverDefaultsKey =
    "classicTabSwitcherCommandTabTakeoverConfirmedV1"
  private static let classicTabSwitcherRetired = true
  static let keepAwakeDurationOptions: [KeepAwakeDurationOption] = [
    KeepAwakeDurationOption(minutes: 0, title: "无限期"),
    KeepAwakeDurationOption(minutes: 30, title: "30 分钟"),
    KeepAwakeDurationOption(minutes: 60, title: "1 小时"),
    KeepAwakeDurationOption(minutes: 120, title: "2 小时"),
    KeepAwakeDurationOption(minutes: 240, title: "4 小时"),
    KeepAwakeDurationOption(minutes: 480, title: "8 小时"),
  ]
  private let knownAppBundleIDs: [String: String] = [
    "apps": "com.apple.apps.launcher",
    "app": "com.apple.apps.launcher",
    "system settings": "com.apple.systempreferences",
    "系统设置": "com.apple.systempreferences",
    "google chrome": "com.google.Chrome",
    "chrome": "com.google.Chrome",
    "microsoft edge": "com.microsoft.edgemac",
    "edge": "com.microsoft.edgemac",
    "lark": "com.bytedance.macos.feishu",
    "feishu": "com.bytedance.macos.feishu",
    "飞书": "com.bytedance.macos.feishu",
    "wechat": "com.tencent.xinWeChat",
    "微信": "com.tencent.xinWeChat",
    "obsidian": "md.obsidian",
    "ticktick": "com.TickTick.task.mac",
    "滴答清单": "com.TickTick.task.mac",
    "codex": "com.openai.codex",
    "dingtalk": "com.alibaba.DingTalkMac",
    "钉钉": "com.alibaba.DingTalkMac",
    "汽水音乐": "com.soda.music",
    "doubao": "com.bot.neotix.doubao",
    "豆包": "com.bot.neotix.doubao",
    "clash verge": "io.github.clash-verge-rev.clash-verge-rev",
    "marvis": "com.tencent.mac.marvis",
    "alttab": "com.lwouis.alt-tab-macos",
    "bob": "com.hezongyidev.Bob",
    "cleanshot x": "pl.maketheweb.cleanshotx",
    "typeless": "now.typeless.desktop",
    "stats": "eu.exelban.Stats",
    "向日葵": "com.oray.sunlogin.macclient",
    "awesun": "com.oray.sunlogin.macclient",
  ]

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        AppRuntimeIdentity.current.applicationSupportDirectoryName,
        isDirectory: true)
    fileURL = base.appendingPathComponent("shortcuts.json")
    let initialShortcutConfiguration = ShortcutConfigurationService(fileURL: fileURL)
    shortcutConfiguration = initialShortcutConfiguration
    phraseURL = base.appendingPathComponent("phrases.json")
    launcherIndexURL = base.appendingPathComponent("launcher-index.json")
    launcherHistoryURL = base.appendingPathComponent("launcher-history.json")
    launcherPinnedURL = base.appendingPathComponent("launcher-pinned.json")
    var initialConfigurationError: String?
    do {
      var request = XLGConfigImportRequest.appDefault(
        applicationSupportURL: base, shortcutsURL: fileURL, phrasesURL: phraseURL)
      if XLGConfigImporter.shouldInstallBundledConfiguration(request: request) {
        let owner = UUID()
        request.shortcutTransaction = try initialShortcutConfiguration.beginRestoreTransaction(ownerID: owner)
        defer { initialShortcutConfiguration.endRestoreTransaction(ownerID: owner) }
        _ = try XLGConfigImporter.installBundledConfigurationIfNeeded(request: request)
      }
    } catch {
      AppDiagnostics.log(
        "default_configuration_install_failed", ["error": error.localizedDescription])
      initialConfigurationError = error.localizedDescription
    }
    clipboardHistory = ClipboardHistoryController(
      baseDirectory: base.appendingPathComponent("clipboard-history", isDirectory: true))
    if let initialConfigurationError {
      statusMessage = "初始配置未能应用，请在设置中重试恢复：\(initialConfigurationError)"
      return
    }
    setDiagnosticsEnabled(UserDefaults.standard.bool(forKey: "diagnosticsEnabled"))
    clipboardHistory.setRuntimeAllowed(true)
    initializeGlobalInputOwnership()
    loadKeepAwakeSettings()
    globalInputWorkspace.loadPreferences()
    shellPreferences.loadSettings()
    Self.retireClassicTabSwitcherIfNeeded()
    launcherWorkspace.loadSettings()
    classicTabSwitcherEnabled = UserDefaults.standard.bool(
      forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    classicTabSwitcherCommandTabTakeoverConfirmed = UserDefaults.standard.bool(
      forKey: Self.classicTabSwitcherCommandTabTakeoverDefaultsKey)
    load()
    loadPhrases()
    authorizationWorkspace.initializePermissions()
    refreshAppSignatureSummary()
    refreshLaunchAtLoginStatus()
    repairLaunchAgentIfNeeded()
    scrollWorkspace.loadSettings()
    shortcutActions.start()
    scrollWorkspace.start()
    globalInputWorkspace.start()
    verifyAuthorizationHotReloadAfterRelaunchIfNeeded()
    loadLauncherUsageHistory()
    loadLauncherPinnedItems()
    loadLauncherIndexIfAvailable()
    ensureLauncherAppsReady()
    if let updateResult = AppUpdater.shared.consumeInstallerResult() {
      updateStatusText = updateResult
      statusMessage = updateResult
      if !updateResult.hasPrefix("更新已安装") {
        updateFailureMessage = updateResult
      }
    }
  }

  isolated deinit {
    shutdown()
  }

  func shutdown(authorizationIntent: AuthorizationTerminationIntent = .ordinary) {
    guard !shutdownStarted else { return }
    guard launcherReferenceOwnerID == nil else { return }
    // Keep the first accepted termination intent across synchronous workspace notifications.
    shutdownStarted = true
    guard configRestore.shutdown() else {
      shutdownStarted = false
      return
    }
    globalInputWorkspace.shutdown()
    launcherUninstallRequestID = nil
    shortcutActions.shutdown()

    applicationOpening.shutdown()
    launcherWorkspace.shutdown()
    updateWorkspace.shutdown()
    phraseWorkspace.shutdown()
    authorizationWorkspace.shutdown(intent: authorizationIntent)
    fileAssociationWorkspace.shutdown()
    systemMonitorWorkspace.shutdown()
    startupWorkspace.shutdown()
    keepAwakeWorkspace.shutdown()
    shortcutWorkspace.shutdown()
    shellPreferences.shutdown()
    clipboardHistory.stop()
  }

  private func initializeGlobalInputOwnership() { globalInputWorkspace.initializeOwnership() }

  @discardableResult
  func refreshGlobalInputOwnership(trigger: String) -> Bool { globalInputWorkspace.refreshOwnership(trigger: trigger) }

  var globalInputOwnershipBlockedMessage: String { globalInputWorkspace.ownershipBlockedMessage }

  var selectedIndex: Int? { shortcutWorkspace.selectedIndex }

  var selectedItem: ShortcutItem? { shortcutWorkspace.selectedItem }



  func bindingForPhrase(id: String) -> Binding<PhraseItem>? {
    phraseWorkspace.bindingForPhrase(id: id)
  }

  var enabledCount: Int {
    items.filter(\.enabled).count + phrases.filter(\.enabled).count
  }

  var isRecording: Bool {
    shortcutRecordingSession != nil
  }

  var isCapturingShortcutAction: Bool {
    shortcutActionCaptureItemID != nil
  }

  var activeCount: Int { shortcutWorkspace.activeCount }

  var permissionTitle: String { authorizationWorkspace.permissionTitle }
  var permissionDetail: String { authorizationWorkspace.permissionDetail }
  var authorizationPermissionsComplete: Bool { authorizationWorkspace.authorizationPermissionsComplete }
  var allRequiredPermissionsComplete: Bool { authorizationWorkspace.allRequiredPermissionsComplete }
  var authorizationSetupDetail: String { authorizationWorkspace.authorizationSetupDetail }

  var classicTabSwitcherPrimaryStatusText: String {
    if Self.classicTabSwitcherRetired {
      return "已下线"
    }
    return classicTabSwitcherEnabled ? "已开启" : "未开启"
  }

  var classicTabSwitcherSecondaryStatusText: String {
    if Self.classicTabSwitcherRetired {
      return "系统默认"
    }
    if !classicTabSwitcherEnabled {
      return "未监听"
    }
    if classicTabSwitcherRunning, classicTabSwitcherCommandTabTakeoverConfirmed {
      return "已接管 Command+Tab"
    }
    if classicTabSwitcherRunning {
      return "Option+Tab 回退"
    }
    return classicTabSwitcherStatusText
  }

  var classicTabSwitcherNeedsPermission: Bool {
    if Self.classicTabSwitcherRetired {
      return false
    }
    return classicTabSwitcherEnabled && !classicTabSwitcherRunning
      && classicTabSwitcherStatusText.contains("权限")
  }

  var classicTabSwitcherShortcutText: String {
    if Self.classicTabSwitcherRetired {
      return "Command + Tab"
    }
    return classicTabSwitcherCommandTabTakeoverConfirmed
      ? "Command + Tab / Option + Tab"
      : "Option + Tab"
  }

  var classicTabSwitcherTakeoverSummaryText: String {
    if Self.classicTabSwitcherRetired {
      return "窗口切换已从主功能下线，Command + Tab 保持 macOS 系统默认。"
    }
    if classicTabSwitcherCommandTabTakeoverConfirmed {
      return "Command + Tab 已交给小龙哥窗口切换；Option + Tab 仍保留为回退入口。"
    }
    return "当前只监听 Option + Tab；确认后才会接管系统 Command + Tab。"
  }

  var appVersionText: String {
    Self.formattedAppVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
  }

  var appVersionAccessibilityText: String {
    Self.formattedAppVersionAccessibilityText(infoDictionary: Bundle.main.infoDictionary ?? [:])
  }

  static func formattedAppVersion(infoDictionary: [String: Any]) -> String {
    let version = infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = infoDictionary["CFBundleVersion"] as? String ?? "0"
    return CustomerVersionFormatter.appVersion(version: version, build: build)
  }

  static func formattedAppVersionAccessibilityText(infoDictionary: [String: Any]) -> String {
    let version = infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = infoDictionary["CFBundleVersion"] as? String ?? "0"
    return CustomerVersionFormatter.accessibilityVersion(version: version, build: build)
  }

  var updateLatestVersionText: String {
    updateServerVersionText
  }

  var availableUpdateVersion: String? {
    updateWorkspace.availableUpdateVersion
  }

  var hasAvailableUpdate: Bool { availableUpdateVersion != nil }

  func showAvailableUpdate() {
    showSettings(section: SettingsNavigationPolicy.updates)
    presentWindowHandler?()
  }

  var updatePrimaryActionTitle: String {
    if isUpdateBusy {
      return "处理中"
    }
    guard let version = availableUpdateVersion else { return "检查更新" }
    return "更新到 \(version)"
  }

  var updatePrimaryActionIcon: String {
    hasAvailableUpdate ? "square.and.arrow.down" : "arrow.clockwise"
  }

  private var currentBuildNumber: Int {
    let info = Bundle.main.infoDictionary ?? [:]
    let build = info["CFBundleVersion"] as? String ?? "0"
    return Int(build) ?? 0
  }

  var usesSparkleUpdater: Bool {
    currentBuildNumber >= 182
  }







  private static func retireClassicTabSwitcherIfNeeded() {
    let defaults = UserDefaults.standard
    let wasEnabled = defaults.bool(forKey: classicTabSwitcherEnabledDefaultsKey)
    let wasTakeoverConfirmed = defaults.bool(
      forKey: classicTabSwitcherCommandTabTakeoverDefaultsKey)
    guard
      !defaults.bool(forKey: classicTabSwitcherRetiredDefaultsKey)
        || wasEnabled
        || wasTakeoverConfirmed
    else { return }
    defaults.set(false, forKey: classicTabSwitcherEnabledDefaultsKey)
    defaults.set(false, forKey: classicTabSwitcherCommandTabTakeoverDefaultsKey)
    defaults.set(true, forKey: classicTabSwitcherDemotionDefaultsKey)
    defaults.set(true, forKey: classicTabSwitcherBuiltInRouteDefaultsKey)
    defaults.set(true, forKey: classicTabSwitcherRetiredDefaultsKey)
    AppDiagnostics.log(
      "classic_tab_switcher_retired_migration",
      [
        "reason": "last_chance_gate_failed",
        "wasEnabled": wasEnabled ? "true" : "false",
        "wasCommandTabTakeoverConfirmed": wasTakeoverConfirmed ? "true" : "false",
      ])
  }







  func setLauncherSearchEngine(_ engine: LauncherSearchEngine) { launcherWorkspace.setLauncherSearchEngine(engine) }

  private func loadKeepAwakeSettings() { keepAwakeWorkspace.loadSettings() }

  var panelHotkeySummary: String {
    "无键盘绑定"
  }

  var panelHotkeyItemID: String? {
    nil
  }

  var launcherHotkeySummary: String { shortcutWorkspace.launcherHotkeySummary }

  var launcherHotkeyItemID: String? {
    nil
  }

  func statusMenuShortcutLabels(for action: ShortcutAction) -> [String] {
    return shortcutWorkspace.statusMenuShortcutLabels(for: action)
  }

  var shortcutSemanticAnalysis: ShortcutSemanticAnalysis { shortcutWorkspace.shortcutSemanticAnalysis }

  var shortcutSemanticCapsDecisionPending: Bool { shortcutWorkspace.shortcutSemanticCapsDecisionPending }

  var shortcutSemanticCommandDecisionPending: Bool { shortcutWorkspace.shortcutSemanticCommandDecisionPending }

  var shortcutSemanticNeedsAttention: Bool { shortcutWorkspace.shortcutSemanticNeedsAttention }

  var sleepHotkeySummary: String { shortcutWorkspace.sleepHotkeySummary }

  var sleepHotkeyConfigured: Bool { shortcutWorkspace.sleepHotkeyConfigured }

  var codexNetworkProbeHotkeySummary: String { shortcutWorkspace.codexNetworkProbeHotkeySummary }

  var isRecordingSleepHotkey: Bool { shortcutWorkspace.isRecordingSleepHotkey }

  private var sleepHotkeyItem: ShortcutItem? { shortcutWorkspace.sleepHotkeyItem }

  private var sleepHotkeyItemID: String? { shortcutWorkspace.sleepHotkeyItemID }


  var filteredLauncherApps: [LauncherApp] { launcherWorkspace.filteredLauncherApps }

  var launcherResultApps: [LauncherApp] { launcherWorkspace.launcherResultApps }

  var launcherPinnedItems: [ResolvedLauncherPinnedItem] { launcherWorkspace.launcherPinnedItems }

  var launcherHasEmptyQuery: Bool { launcherWorkspace.launcherHasEmptyQuery }

  var launcherShortcutCount: Int { shortcutWorkspace.launcherShortcutCount }

  var launcherCalculatorItem: LauncherUtilityItem? { launcherWorkspace.launcherCalculatorItem }

  var launcherUtilityItem: LauncherUtilityItem? { launcherWorkspace.launcherUtilityItem }

  var pluginItems: [ShortcutItem] {
    items.filter(isPluginShortcut)
  }

  var pluginCenterItemCount: Int {
    9
  }

  var mouseVolumePluginEnabled: Bool { scrollWorkspace.mouseVolumePluginEnabled }

  var mouseScrollPreset: MouseScrollPreset { scrollWorkspace.mouseScrollPreset }

  var systemPreferredItems: [ShortcutItem] {
    items.filter(isPluginShortcut)
  }

  func canRestorePluginShortcut(id: String) -> Bool {
    return shortcutWorkspace.canRestorePluginShortcut(id: id)
  }

  func restorePluginShortcut(id: String) {
    return shortcutWorkspace.restorePluginShortcut(id: id)
  }

  private func defaultPluginShortcut(matching item: ShortcutItem) -> ShortcutItem? {
    return shortcutWorkspace.defaultPluginShortcut(matching: item)
  }

  private static func deletedShortcutPlaceholder(id: String) -> ShortcutItem {
    ShortcutItem(
      id: id,
      name: "已删除",
      scope: "全部应用",
      key: "Space",
      modifiers: ["command"],
      action: .openURL,
      target: "",
      enabled: false,
      note: ""
    )
  }

  private static func deletedPhrasePlaceholder(id: String) -> PhraseItem {
    PhraseItem(
      id: id,
      trigger: "",
      output: "",
      enabled: false,
      note: ""
    )
  }

  var isRecordingPanelHotkey: Bool {
    guard let panelHotkeyItemID else { return false }
    return isRecording(panelHotkeyItemID)
  }

  var isRecordingLauncherHotkey: Bool {
    guard let launcherHotkeyItemID else { return false }
    return isRecording(launcherHotkeyItemID)
  }

  var appBundlePath: String {
    Bundle.main.bundlePath
  }

  var appBundleIdentifier: String {
    Bundle.main.bundleIdentifier ?? runtimeIdentity.bundleIdentifier
  }

  var isInstalledInApplications: Bool {
    URL(fileURLWithPath: appBundlePath).standardizedFileURL.path
      == runtimeIdentity.installURL.standardizedFileURL.path
  }

  var authorizationPermissionSnapshot: AuthorizationPermissionSnapshot { authorizationWorkspace.authorizationPermissionSnapshot }
  var authorizationRepairServices: [AuthorizationRepairService] { authorizationWorkspace.authorizationRepairServices }
  var authorizationNeedsTargetedRepair: Bool { authorizationWorkspace.authorizationNeedsTargetedRepair }
  var authorizationRepairServiceNames: String { authorizationWorkspace.authorizationRepairServiceNames }
  var authorizationPrimaryButtonTitle: String { authorizationWorkspace.authorizationPrimaryButtonTitle }
  var authorizationEntryButtonTitle: String { authorizationWorkspace.authorizationEntryButtonTitle }
  var authorizationPrimarySafetyText: String { authorizationWorkspace.authorizationPrimarySafetyText }
  var authorizationPrimaryButtonDisabled: Bool { authorizationWorkspace.authorizationPrimaryButtonDisabled }
  var authorizationOverallStatusText: String { authorizationWorkspace.authorizationOverallStatusText }
  var accessibilityAuthorizationStatusText: String { authorizationWorkspace.accessibilityAuthorizationStatusText }
  var accessibilityAuthorizationGuidanceText: String { authorizationWorkspace.accessibilityAuthorizationGuidanceText }

  var dockIdentityText: String {
    "程序坞已显示"
  }

  var scrollEngineText: String { scrollWorkspace.statusText }

  func setDiagnosticsEnabled(_ enabled: Bool) {
    diagnosticsEnabled = enabled
    AppDiagnostics.setEnabled(enabled)
    statusMessage = enabled ? "诊断日志已开启。" : "诊断日志已关闭。"
  }

  func startSystemMonitor() { systemMonitorWorkspace.start() }
  func stopSystemMonitor() { systemMonitorWorkspace.stop() }
  func refreshSystemMonitorSnapshot() { systemMonitorWorkspace.refresh() }

  func startKeepAwake(minutes: Int) { keepAwakeWorkspace.start(minutes: minutes) }
  func startKeepAwakeCustomHours() { keepAwakeWorkspace.startCustomHours() }
  func toggleInfiniteKeepAwake() { keepAwakeWorkspace.toggleInfinite() }
  func stopKeepAwake(resetStatus: Bool = true) { keepAwakeWorkspace.stop(resetStatus: resetStatus) }
  func setKeepAwakePreventDisplaySleep(_ enabled: Bool) {
    keepAwakeWorkspace.setPreventDisplaySleep(enabled)
  }
  func setKeepAwakeCustomHours(_ hours: Int) { keepAwakeWorkspace.setCustomHours(hours) }

  func setSleepStatusItemVisible(_ visible: Bool) { shellPreferences.setSleepStatusItemVisible(visible) }

  func setDockIconVisible(_ visible: Bool) { shellPreferences.setDockIconVisible(visible) }

  func isMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID) -> Bool { shellPreferences.isMenuBarCatalogItemVisible(itemID) }

  func setMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID, _ visible: Bool) { shellPreferences.setMenuBarCatalogItemVisible(itemID, visible) }

  func resetMenuBarCatalogVisibility() { shellPreferences.resetMenuBarCatalogVisibility() }

  func presentMenuBarCustomization() {
    showSettings(section: SettingsNavigationPolicy.general)
    isMenuBarCustomizationPresented = true
    presentWindowHandler?()
  }



  private func notifySleepStatusItemChanged() {
    NotificationCenter.default.post(name: .sleepStatusItemChanged, object: nil)
  }

  var isSettingsPresented: Bool {
    selectedModuleName == "关于"
  }

  func showSettings(section: String? = nil) { mainWorkspace.showSettings(section: section) }
  func requestCreateShortcut() { mainWorkspace.requestCreateShortcut() }

  func runPrimaryUpdateAction() { updateWorkspace.runPrimaryUpdateAction() }
  func checkForUpdatesIfNeeded() { updateWorkspace.checkForUpdatesIfNeeded() }
  func showReleaseNoteIfNeeded() { updateWorkspace.showReleaseNoteIfNeeded() }
  func markReleaseNoteSeen() { updateWorkspace.markReleaseNoteSeen() }
  func openReleaseNotesChangelog() { updateWorkspace.openReleaseNotesChangelog() }
  func checkForUpdates() { updateWorkspace.checkForUpdates() }
  func installLatestUpdate() { updateWorkspace.installLatestUpdate() }
  func handleSparkleUpdateState(_ state: SparkleUpdateState) { updateWorkspace.handleSparkleUpdateState(state) }

  func showPhraseWindow() {
    selectPlugin(id: Self.phrasesPluginID)
    selectedModuleName = "快捷短语"
    presentWindowHandler?()
  }

  func showLauncher() {
    if let showLauncherHandler {
      showLauncherHandler()
    } else {
      NotificationCenter.default.post(name: .showAixlgLauncherWindow, object: nil)
    }
  }

  func showProcessViewer() {
    showProcessViewerHandler?()
  }

  func showClipboardHistory() {
    showClipboardHistoryHandler?()
  }

  func showCodexNetworkProbe() {
    showCodexNetworkProbeHandler?()
  }

  func prepareLauncherPresentation() { launcherWorkspace.prepareLauncherPresentation() }

  func selectPlugin(id: String?) { mainWorkspace.selectPlugin(id: id) }

  func showLauncherPluginDetails() {
    selectPlugin(id: Self.launcherPluginID)
    selectedModuleName = "插件中心"
    presentWindowHandler?()
  }

  func setLauncherPluginEnabled(_ enabled: Bool) { launcherWorkspace.setLauncherPluginEnabled(enabled) }

  func setLauncherDisplayMode(_ mode: LauncherDisplayMode) { launcherWorkspace.setLauncherDisplayMode(mode) }

  func setLauncherShowsPinnedNames(_ showsNames: Bool) { launcherWorkspace.setLauncherShowsPinnedNames(showsNames) }

  func markLauncherInteractive() { launcherWorkspace.markLauncherInteractive() }

  func markLauncherFirstResultsIfAvailable(source: String) { launcherWorkspace.markLauncherFirstResultsIfAvailable(source: source) }

  func showYoumuFeature() {
    guard hasGlobalInputOwnership else {
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    guard let showYoumuFeatureHandler else {
      statusMessage = "截图原生模块尚未载入当前构建。"
      return
    }
    showYoumuFeatureHandler()
  }

  func openYoumuControlCenter() {
    guard makeYoumuSettingsViewHandler != nil else {
      statusMessage = "截图设置尚未载入当前构建。"
      return
    }
    selectPlugin(id: "youmu")
    selectedModuleName = "插件中心"
    presentWindowHandler?()
  }

  func executeFeatureCommand(commandID: String) {
    guard hasGlobalInputOwnership else {
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    guard let executeFeatureCommandHandler else {
      statusMessage = "原生功能尚未载入，未执行该动作。"
      return
    }
    executeFeatureCommandHandler(commandID)
  }

  func showPijuanPDFFeature() {
    guard let showPijuanPDFFeatureHandler else {
      statusMessage = "PDF 浏览器原生模块尚未载入当前构建。"
      return
    }
    showPijuanPDFFeatureHandler()
  }

  func openPijuanPDFDocument(_ url: URL) {
    guard let openPijuanPDFDocumentHandler else {
      statusMessage = "PDF 浏览器原生模块尚未载入当前构建，未打开文件。"
      return
    }
    openPijuanPDFDocumentHandler(url.standardizedFileURL)
  }

  func refreshFileAssociationStatus() { fileAssociationWorkspace.refreshFileAssociationStatus() }
  func setAsDefaultApplication(for kind: AssociatedFileKind) {
    fileAssociationWorkspace.setAsDefaultApplication(for: kind)
  }
  func restorePreviousDefaultApplication(for kind: AssociatedFileKind) {
    fileAssociationWorkspace.restorePreviousDefaultApplication(for: kind)
  }

  func showSleepPanel() {
    if let showSleepPanelHandler {
      showSleepPanelHandler()
    } else {
      selectedModuleName = "插件中心"
      presentWindowHandler?()
      sleepPanelRequestID += 1
    }
    statusMessage = "已打开保持唤醒。"
  }

  func makePijuanPDFShortcutSettingsView() -> AnyView? {
    makePijuanPDFShortcutSettingsViewHandler?()
  }

  func ensureLauncherAppsReady() { launcherWorkspace.ensureLauncherAppsReady() }
  func refreshLauncherApps() { launcherWorkspace.refreshLauncherApps() }
  private func loadLauncherIndexIfAvailable() { launcherWorkspace.loadLauncherIndexIfAvailable() }
  private func loadLauncherUsageHistory() { launcherWorkspace.loadLauncherUsageHistory() }
  private func loadLauncherPinnedItems() { launcherWorkspace.loadLauncherPinnedItems() }
  func isLauncherAppPinned(_ app: LauncherApp) -> Bool { launcherWorkspace.isLauncherAppPinned(app) }
  @discardableResult
  func pinLauncherApp(_ app: LauncherApp) -> Bool { launcherWorkspace.pinLauncherApp(app) }
  func unpinLauncherApp(_ app: LauncherApp) { launcherWorkspace.unpinLauncherApp(app) }
  func unpinLauncherItem(id: String) { launcherWorkspace.unpinLauncherItem(id: id) }
  func reportUnavailableLauncherPinnedItem(_ item: ResolvedLauncherPinnedItem) {
    launcherWorkspace.reportUnavailableLauncherPinnedItem(item)
  }
  func canMoveLauncherPinnedItem(id: String, offset: Int) -> Bool {
    launcherWorkspace.canMoveLauncherPinnedItem(id: id, offset: offset)
  }
  func moveLauncherPinnedItem(id: String, offset: Int) {
    launcherWorkspace.moveLauncherPinnedItem(id: id, offset: offset)
  }
  func moveLauncherPinnedItem(id: String, before targetID: String) {
    launcherWorkspace.moveLauncherPinnedItem(id: id, before: targetID)
  }

  @discardableResult
  func runLauncherUtilityIfAvailable() -> Bool {
    if let calculator = launcherCalculatorItem {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(calculator.value, forType: .string)
      statusMessage = "已复制计算结果：\(calculator.value)"
      return true
    }

    guard filteredLauncherApps.isEmpty,
      let destination = LauncherWebResolver.destination(
        for: launcherQuery,
        searchEngine: launcherSearchEngine),
      let url = destination.url
    else {
      return false
    }
    NSWorkspace.shared.open(url)
    statusMessage =
      destination.title == "打开网址" ? "已打开网址：\(destination.value)" : "已搜索：\(destination.value)"
    return true
  }

  func openLauncherApp(_ app: LauncherApp) {
    let matchedQuery = launcherQuery
    guard let owner = launcherWorkspace.beginLauncherOpen() else { return }
    openAppOrFolder(launcherTarget(for: app)) { [weak self] succeeded in
      self?.launcherWorkspace.completeLauncherOpen(
        owner: owner, app: app, query: matchedQuery, succeeded: succeeded)
    }
  }

  func existingSoftwareShortcut(for target: String) -> ShortcutItem? {
    return shortcutWorkspace.existingSoftwareShortcut(for: target)
  }

  func openLauncherShortcutManager(for app: LauncherApp) {
    let target = launcherTarget(for: app)
    let normalizedTarget = normalizedOpenAppTarget(target) ?? target
    if let index = launcherShortcutItemIndex(forNormalizedTarget: normalizedTarget) {
      presentSoftwareShortcutEditor(item: items[index])
    } else {
      presentSoftwareShortcutEditor(
        choice: AppChoice(
          id: target, name: app.name, target: target, source: "应用程序"))
    }
  }

  func presentSoftwareShortcutEditor(item: ShortcutItem? = nil, choice: AppChoice? = nil) {
    cancelRecordingIfNeeded()
    let draft =
      item
      ?? ShortcutItem(
        id: UUID().uuidString,
        name: choice.map { "打开 \($0.name)" } ?? "",
        scope: "App", key: "", modifiers: [], action: .openApp,
        target: choice?.target ?? "", enabled: true,
        note: "按一下打开或置前，再按一下隐藏。")
    if let item { selectedID = item.id }
    mainWorkspace.presentSoftwareShortcut(itemID: item?.id, draft: draft)
    presentWindowHandler?()
  }

  func chooseAppForPermanentUninstall() {
    guard launcherUninstallRequestID == nil else {
      statusMessage = "已有彻底卸载任务正在进行。"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择要彻底卸载的 App"
    panel.prompt = "选择"
    panel.message = "选中后会先显示不可撤销警告，请核对目标文件。"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.applicationBundle]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let standardizedURL = url.standardizedFileURL
    guard standardizedURL.pathExtension.lowercased() == "app" else {
      statusMessage = "请选择一个 App。"
      return
    }
    let bundle = Bundle(url: standardizedURL)
    let fallbackName = standardizedURL.deletingPathExtension().lastPathComponent
    let name =
      (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? fallbackName
    let bundleIdentifier = bundle?.bundleIdentifier ?? ""
    let normalizedName = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "zh_Hans_CN")
    ).lowercased()
    let app = LauncherApp(
      id: bundleIdentifier.isEmpty ? standardizedURL.path : bundleIdentifier,
      name: name,
      bundleIdentifier: bundleIdentifier,
      path: standardizedURL.path,
      normalizedName: normalizedName,
      searchTokens: "\(normalizedName) \(bundleIdentifier.lowercased())",
      initials: "",
      useCount: 0,
      lastUsedDate: nil)
    requestUninstallLauncherApp(app)
  }

  func requestUninstallLauncherApp(_ app: LauncherApp) {
    guard launcherUninstallRequestID == nil else { return }
    let requestID = UUID().uuidString
    launcherUninstallRequestID = requestID
    statusMessage = "正在扫描 \(app.name) 可安全识别的卸载范围…"
    let currentApplicationURL = Bundle.main.bundleURL
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let review = try SafeUninstallLiveScanner().scan(
          appName: app.name,
          bundleIdentifier: app.bundleIdentifier,
          appURL: app.url,
          currentApplicationURL: currentApplicationURL)
        DispatchQueue.main.async {
          guard let self, self.launcherUninstallRequestID == requestID else { return }
          guard self.hasExecutableApplicationCandidate(in: review) else {
            self.finishPermanentLauncherUninstallFailure(
              app: app,
              message: self.permanentUninstallUnsupportedMessage(review))
            return
          }
          guard self.confirmPermanentLauncherUninstall(app, review: review) else {
            self.launcherUninstallRequestID = nil
            self.statusMessage = "已取消卸载 \(app.name)，未删除任何内容。"
            return
          }
          self.executePermanentLauncherUninstall(
            requestID: requestID,
            app: app,
            review: review)
        }
      } catch {
        DispatchQueue.main.async {
          guard self?.launcherUninstallRequestID == requestID else { return }
          self?.finishPermanentLauncherUninstallFailure(
            app: app,
            message: "无法确认可彻底删除的范围：\(error.localizedDescription)")
        }
      }
    }
  }

  private func executePermanentLauncherUninstall(
    requestID: String,
    app: LauncherApp,
    review: SafeUninstallReview
  ) {
    guard launcherUninstallRequestID == requestID else { return }
    let selectedCandidateIDs = review.permanentDeletionCandidateIDs
    guard hasExecutableApplicationCandidate(in: review) else {
      finishPermanentLauncherUninstallFailure(
        app: app,
        message: permanentUninstallUnsupportedMessage(review))
      return
    }
    guard !isChangingShortcutConfiguration, !hasActiveShortcutEditors,
      !isRecording, !isCapturingShortcutAction else {
      finishPermanentLauncherUninstallFailure(
        app: app, message: "请先完成快捷键编辑或配置恢复，再卸载 App。")
      return
    }
    let owner = UUID()
    do {
      let participant = try shortcutConfiguration.beginRestoreTransaction(ownerID: owner)
      launcherReferenceOwnerID = owner
      objectWillChange.send()
      guard launcherWorkspace.beginReferenceTransaction(ownerID: owner) else {
        throw AutomationError(code: "configuration_busy", message: "启动器正在更新引用，请稍后再试。")
      }
      let engine = try makePermanentUninstallEngine(shortcutTransaction: participant)
      statusMessage = "正在彻底卸载 \(app.name)…"
      // Keep the owner alive until the destructive operation and its reference commit finish.
      Task { @MainActor [self] in
        let outcome = await engine.execute(
          review: review,
          selectedCandidateIDs: selectedCandidateIDs,
          expectedReviewRevision: review.reviewRevision,
          progress: { [weak self] progress in
            guard let self, self.launcherUninstallRequestID == requestID else { return }
            switch progress {
            case .terminatingApplication:
              self.statusMessage = "正在直接结束 \(app.name) 的运行进程…"
            case .deletingPermanently:
              self.statusMessage = "正在永久删除 \(app.name) 及已确认的专属数据…"
            case .applicationDeleted:
              self.statusMessage = "\(app.name) 主程序已删除，正在清理启动器记录…"
            }
          })
        finishLauncherReferenceTransaction(ownerID: owner) {
          guard self.launcherUninstallRequestID == requestID else { return }
          _ = self.shortcutWorkspace.reloadAfterExternalReferenceChange()
          if outcome.didDeleteTargetApplication {
            self.reloadLauncherReferencesAfterPermanentUninstall(
              targetPath: review.target.path)
          }
          self.statusMessage = outcome.message
          if outcome.state == .blocked || outcome.state == .partialFailure {
            self.presentPermanentUninstallFailure(app: app, message: outcome.message)
          }
          self.launcherUninstallRequestID = nil
        }
      }
    } catch {
      let fail = {
        self.finishPermanentLauncherUninstallFailure(
          app: app, message: "无法启动彻底卸载：\(error.localizedDescription)")
      }
      if launcherReferenceOwnerID == owner {
        finishLauncherReferenceTransaction(ownerID: owner, completion: fail)
      } else {
        fail()
      }
    }
  }

  private func finishLauncherReferenceTransaction(ownerID: UUID, completion: () -> Void) {
    guard launcherReferenceOwnerID == ownerID else { return }
    shortcutConfiguration.endRestoreTransaction(ownerID: ownerID)
    if !launcherWorkspace.endReferenceTransaction(ownerID: ownerID, completion: completion) {
      completion()
    }
    launcherReferenceOwnerID = nil
    objectWillChange.send()
  }

  private func makePermanentUninstallEngine(
    shortcutTransaction: XLGConfigShortcutTransaction
  ) throws -> SafeUninstallPermanentEngine {
    let base = fileURL.deletingLastPathComponent()
      .appendingPathComponent("safe-uninstall", isDirectory: true)
    return SafeUninstallPermanentEngine(
      files: SafeUninstallPermanentFileExecutor(),
      processes: SafeUninstallLiveProcessController(),
      references: try SafeUninstallLauncherReferenceStore(
        shortcutsURL: fileURL,
        shortcutTransaction: shortcutTransaction,
        historyURL: launcherHistoryURL,
        pinnedURL: launcherPinnedURL,
        snapshotDirectory: base.appendingPathComponent(
          "permanent-reference-snapshots", isDirectory: true)))
  }

  private func reloadLauncherReferencesAfterPermanentUninstall(targetPath: String) {
    launcherWorkspace.reloadReferencesAfterUninstall(targetPath: targetPath)
  }

  private func finishPermanentLauncherUninstallFailure(
    app: LauncherApp,
    message: String
  ) {
    launcherUninstallRequestID = nil
    statusMessage = message
    presentPermanentUninstallFailure(app: app, message: message)
  }

  private func hasExecutableApplicationCandidate(in review: SafeUninstallReview) -> Bool {
    let selectedCandidateIDs = Set(review.permanentDeletionCandidateIDs)
    return review.candidates.contains {
      selectedCandidateIDs.contains($0.id) && $0.type == .application
    }
  }

  private func confirmPermanentLauncherUninstall(
    _ app: LauncherApp,
    review: SafeUninstallReview
  ) -> Bool {
    let selectedCandidateIDs = Set(review.permanentDeletionCandidateIDs)
    let selectedCandidates = review.candidates.filter { selectedCandidateIDs.contains($0.id) }
    let relatedCandidates = selectedCandidates.filter { $0.type != .application }
    let relatedSummary = Dictionary(grouping: relatedCandidates, by: { $0.type.displayName })
      .map { type, candidates in "\(type) \(candidates.count) 项" }
      .sorted()
      .joined(separator: "、")
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "确认彻底卸载「\(app.name)」？"
    alert.informativeText =
      "已完成扫描：将永久删除主程序"
      + (relatedCandidates.isEmpty ? "。" : "和 \(relatedCandidates.count) 项专属数据（\(relatedSummary)）。")
      + "\n\n如果 App 正在运行，会先结束进程。以上内容不会移到废纸篓，删除后无法恢复。"
    let pathList =
      selectedCandidates
      .map { "\($0.type.displayName)　\($0.displayPath)" }
      .joined(separator: "\n")
    let pathListHeight = min(max(CGFloat(selectedCandidates.count) * 20 + 20, 120), 260)
    let pathListView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: pathListHeight))
    pathListView.string = pathList
    pathListView.isEditable = false
    pathListView.isSelectable = true
    pathListView.drawsBackground = false
    pathListView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    pathListView.textContainerInset = NSSize(width: 8, height: 8)
    pathListView.isVerticallyResizable = true
    pathListView.textContainer?.widthTracksTextView = true
    let pathListScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 520, height: pathListHeight))
    pathListScrollView.documentView = pathListView
    pathListScrollView.hasVerticalScroller = true
    pathListScrollView.borderType = .bezelBorder
    alert.accessoryView = pathListScrollView
    let confirmButton = alert.addButton(withTitle: "彻底卸载")
    confirmButton.hasDestructiveAction = true
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func presentPermanentUninstallFailure(app: LauncherApp, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "未能彻底卸载「\(app.name)」"
    let revealURL = LauncherUninstallRecoveryRoute.revealableApplicationURL(app.url)
    alert.informativeText =
      revealURL == nil
      ? message
      : "\(message)\n\n\(LauncherUninstallRecoveryRoute.finderGuidance)"
    if revealURL != nil {
      alert.addButton(withTitle: "在“应用程序”中显示")
    }
    alert.addButton(withTitle: "知道了")

    guard
      let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        ?? NSApp.windows.first(where: { $0.isVisible })
    else {
      statusMessage = message
      return
    }

    // App 级 runModal 会阻断截图的跨窗口选区。异步 sheet 只约束当前窗口，
    // 失败提示仍留在画面里，同时允许截图选区层正常接收键盘和鼠标。
    alert.beginSheetModal(for: parentWindow) { [weak self] response in
      guard response == .alertFirstButtonReturn, let revealURL else { return }
      NSWorkspace.shared.activateFileViewerSelecting([revealURL])
      self?.statusMessage =
        "已在“应用程序”中定位 \(app.name)；点右键后选择“移到废纸篓”。"
    }
  }

  private func permanentUninstallUnsupportedMessage(_ review: SafeUninstallReview) -> String {
    switch review.target.sourceKind {
    case .homebrewCask:
      return "这是 Homebrew Cask 安装的 App，请使用 Homebrew 的卸载路径。"
    case .officialUninstaller, .packageReceipt:
      return "该 App 带官方卸载器或安装器收据，请使用它自带的卸载路径。"
    case .helperOrExtension:
      return "该 App 带登录项、辅助组件或系统扩展，不能只靠永久删文件安全卸载。"
    case .systemApplication:
      return "macOS 系统 App 受系统保护，不能彻底卸载。"
    default:
      return "该 App 的安装来源或文件身份无法安全确认，未删除任何项目。"
    }
  }

  func startPanelHotkeyRecording() {
    statusMessage = "功能快捷键只保留可点击入口，不占用键盘组合。"
  }

  func showShortcutGuidePanel() {
    selectedModuleName = "功能快捷键"
    shortcutGuideRequestedCategory = "全部"
    shortcutGuideRequestedSearchText = ""
    if let presentWindowHandler {
      presentWindowHandler()
    } else {
      showWindowHandler?()
    }
    shortcutGuideFocusRequest += 1
    statusMessage = "已打开功能快捷键，可搜索和管理当前快捷键。"
  }

  private func toggleShortcutGuidePanelFromShortcut() {
    let outcome = toggleShortcutWindow(.shortcutGuide)
    switch outcome {
    case .shown:
      selectedModuleName = "功能快捷键"
      shortcutGuideRequestedCategory = "全部"
      shortcutGuideRequestedSearchText = ""
      shortcutGuideFocusRequest += 1
      statusMessage = "已打开功能快捷键，再按一次即隐藏。"
    case .hidden:
      statusMessage = "已隐藏功能快捷键。"
    case .unavailable:
      showShortcutGuidePanel()
    }
  }

  @discardableResult
  private func toggleShortcutWindow(
    _ target: ShortcutWindowTarget
  ) -> ShortcutWindowToggleOutcome {
    toggleShortcutWindowHandler?(target) ?? .unavailable
  }

  func startLauncherHotkeyRecording() {
    statusMessage =
      shortcutSemanticAnalysis.capsSpaceConflicts.isEmpty
      ? "小龙哥启动器统一使用 Caps + Space。"
      : "Caps + Space 当前有受保护的占用，请先在功能快捷键页确认。"
  }

  func adoptCapsSpaceForLauncher() {
    return shortcutWorkspace.adoptCapsSpaceForLauncher()
  }

  func keepCurrentCapsSpaceBehavior() {
    return shortcutWorkspace.keepCurrentCapsSpaceBehavior()
  }

  func returnCommandSpaceToSystem() {
    return shortcutWorkspace.returnCommandSpaceToSystem()
  }

  func keepCurrentCommandSpaceBehavior() {
    return shortcutWorkspace.keepCurrentCommandSpaceBehavior()
  }

  func openShortcutSemanticBackup() {
    return shortcutWorkspace.openShortcutSemanticBackup()
  }

  func undoLatestShortcutSemanticMigration() {
    return shortcutWorkspace.undoLatestShortcutSemanticMigration()
  }

  private func applyShortcutSemanticResolution(
    itemIDs: [String],
    reason: String,
    successMessage: String
  ) {
    return shortcutWorkspace.applyShortcutSemanticResolution(itemIDs: itemIDs, reason: reason, successMessage: successMessage)
  }

  func startSleepHotkeyRecording() {
    return shortcutWorkspace.startSleepHotkeyRecording()
  }

  func openShortcutManager(action: ShortcutAction) {
    return shortcutWorkspace.openShortcutManager(action: action)
  }

  func featureShortcutItemIDs(for commandID: String) -> [String] {
    return shortcutWorkspace.featureShortcutItemIDs(for: commandID)
  }

  func featureShortcutMenuLabel(for commandID: String) -> String? {
    return shortcutWorkspace.featureShortcutMenuLabel(for: commandID)
  }

  @discardableResult
  func ensureFeatureShortcutItem(commandID: String) -> String? {
    return shortcutWorkspace.ensureFeatureShortcutItem(commandID: commandID)
  }

  func openFeatureShortcutManager(commandID: String) {
    return shortcutWorkspace.openFeatureShortcutManager(commandID: commandID)
  }

  func openPijuanPDFShortcutManager() {
    return shortcutWorkspace.openPijuanPDFShortcutManager()
  }

  func clearSleepHotkey() {
    return shortcutWorkspace.clearSleepHotkey()
  }

  private func ensureSleepHotkeyItem(enabledWhenCreated: Bool = false) -> String {
    return shortcutWorkspace.ensureSleepHotkeyItem(enabledWhenCreated: enabledWhenCreated)
  }

  private func ensureCodexNetworkProbeHotkeyItem(enabledWhenCreated: Bool = false) -> String {
    return shortcutWorkspace.ensureCodexNetworkProbeHotkeyItem(enabledWhenCreated: enabledWhenCreated)
  }

  private func ensureCoreHotkeyItem(action: ShortcutAction) -> String? {
    return shortcutWorkspace.ensureCoreHotkeyItem(action: action)
  }

  private func ensureShortcutItemForManagement(action: ShortcutAction) -> String? {
    return shortcutWorkspace.ensureShortcutItemForManagement(action: action)
  }

  private func launcherTarget(for app: LauncherApp) -> String {
    return shortcutWorkspace.launcherTarget(for: app)
  }

  func launcherShortcut(for app: LauncherApp) -> LauncherAppShortcut? {
    return shortcutWorkspace.launcherShortcut(for: app)
  }

  func isRecordingLauncherShortcut(for app: LauncherApp) -> Bool {
    return shortcutWorkspace.isRecordingLauncherShortcut(for: app)
  }

  private var launcherOpenAppShortcutMap: [String: LauncherAppShortcut] { shortcutWorkspace.launcherOpenAppShortcutMap }

  private func prioritizedLauncherApps(_ apps: [LauncherApp]) -> [LauncherApp] {
    return shortcutWorkspace.prioritizedLauncherApps(apps)
  }

  private func launcherShortcutItemIndex(forNormalizedTarget normalizedTarget: String) -> Int? {
    return shortcutWorkspace.launcherShortcutItemIndex(forNormalizedTarget: normalizedTarget)
  }

  private func launcherTargetKey(for app: LauncherApp) -> String {
    return shortcutWorkspace.launcherTargetKey(for: app)
  }

  func load() {
    return shortcutWorkspace.load()
  }

  func loadPhrases() {
    phraseWorkspace.load()
  }

  private func repairCoreDefaultsAndMergeCommonRules() -> Bool {
    return shortcutWorkspace.repairCoreDefaultsAndMergeCommonRules()
  }

  private func missingDefaultFeatureShortcuts() -> [FeatureShortcutCommandDescriptor] {
    return shortcutWorkspace.missingDefaultFeatureShortcuts()
  }

  private func hasDuplicateShortcutIDs() -> Bool {
    return shortcutWorkspace.hasDuplicateShortcutIDs()
  }

  private func repairDuplicateShortcutIDs() -> Bool {
    return shortcutWorkspace.repairDuplicateShortcutIDs()
  }

  private func managedShortcutIdentityKey(_ item: ShortcutItem) -> String? {
    return shortcutWorkspace.managedShortcutIdentityKey(item)
  }

  private func hasDuplicateManagedShortcutIdentities() -> Bool {
    return shortcutWorkspace.hasDuplicateManagedShortcutIdentities()
  }

  private func repairDuplicateManagedShortcutIdentities() -> Bool {
    return shortcutWorkspace.repairDuplicateManagedShortcutIdentities()
  }

  private func legacyRecoveryTemplate(
    for item: ShortcutItem,
    templates: [ShortcutItem]
  ) -> ShortcutItem? {
    return shortcutWorkspace.legacyRecoveryTemplate(for: item, templates: templates)
  }

  private func hasLegacyRecoveryOwnershipRepair() -> Bool {
    return shortcutWorkspace.hasLegacyRecoveryOwnershipRepair()
  }

  private func repairLegacyRecoveryOwnership() -> Bool {
    return shortcutWorkspace.repairLegacyRecoveryOwnership()
  }

  private func repairMissingDefaultFeatureShortcuts() -> Bool {
    return shortcutWorkspace.repairMissingDefaultFeatureShortcuts()
  }

  private func isLegacyDisplaySleepShortcut(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.isLegacyDisplaySleepShortcut(item)
  }

  private func backupShortcutConfigBeforeCodexNetworkProbeAddition() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeCodexNetworkProbeAddition()
  }

  private func backupShortcutConfigBeforeClipboardHistoryAddition() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeClipboardHistoryAddition()
  }

  private func backupShortcutConfigBeforeFeatureShortcutMerge() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeFeatureShortcutMerge()
  }

  private func backupShortcutConfigBeforeFeatureNameMigration() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeFeatureNameMigration()
  }

  private func backupShortcutConfigBeforeRecoveryOwnershipRepair() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeRecoveryOwnershipRepair()
  }

  private func backupShortcutConfigBeforeDuplicateIDRepair() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeDuplicateIDRepair()
  }

  private func backupShortcutConfigBeforeDefaultBaselineMigration() -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeDefaultBaselineMigration()
  }

  private func backupShortcutConfigBeforeDefaultMerge(
    reason: String,
    failureMessage: String
  ) -> Bool {
    return shortcutWorkspace.backupShortcutConfigBeforeDefaultMerge(reason: reason, failureMessage: failureMessage)
  }

  private func migrateShortcutDefaultBaselineIfNeeded() -> Bool {
    return shortcutWorkspace.migrateShortcutDefaultBaselineIfNeeded()
  }

  private func commitShortcutDefaultBaselineVersionIfNeeded() {
    return shortcutWorkspace.commitShortcutDefaultBaselineVersionIfNeeded()
  }

  private func cancelShortcutDefaultBaselineVersionCommit() {
    return shortcutWorkspace.cancelShortcutDefaultBaselineVersionCommit()
  }

  private func markShortcutDefaultBaselineCurrent() {
    return shortcutWorkspace.markShortcutDefaultBaselineCurrent()
  }

  private func updateConfigurationRecoveryMessage() {
    let messages = [shortcutWorkspace.recoveryMessage, phraseWorkspace.recoveryMessage].compactMap { $0 }
    configurationRecoveryMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
  }

  @discardableResult
  func saveOnly() -> Bool {
    return shortcutWorkspace.saveOnly()
  }

  @discardableResult
  func saveAndReload() -> Bool {
    return shortcutWorkspace.saveAndReload()
  }

  func saveAndScheduleHotkeyReload(delay: TimeInterval = 0.45) {
    return shortcutWorkspace.saveAndScheduleHotkeyReload(delay: delay)
  }

  @discardableResult
  func savePhrasesOnly() -> Bool { phraseWorkspace.saveOnly() }

  func savePhrasesAndReload() { phraseWorkspace.saveAndReload() }

  func flushScheduledPhraseSave() { phraseWorkspace.flushPendingSave(reload: false) }

  func schedulePhrasesSave(reload: Bool) { phraseWorkspace.scheduleSave(reload: reload) }

  func reloadPhraseExpander() { globalInputWorkspace.reloadPhrases() }

  var commandWProtectionStatus: String { globalInputWorkspace.commandWProtectionStatus }

  func reloadHotkeys() { globalInputWorkspace.reloadHotkeys() }

  var automationRuntimeStatus: String { globalInputWorkspace.automationRuntimeStatus }

  func automationRuntimeStatus(for item: ShortcutItem) -> String { globalInputWorkspace.automationRuntimeStatus(for: item) }



  private func hotkeyRegistrationItems() -> [ShortcutItem] {
    return shortcutWorkspace.hotkeyRegistrationItems()
  }

  func makeShortcutDraft(module: String = "功能快捷键") -> ShortcutItem {
    return shortcutWorkspace.makeShortcutDraft(module: module)
  }

  @discardableResult
  func createShortcut(from draft: ShortcutItem, editorOwner: UUID? = nil) -> Bool {
    return shortcutWorkspace.createShortcut(from: draft, editorOwner: editorOwner)
  }

  @discardableResult
  func updateShortcut(id: String, draft: ShortcutItem, editorOwner: UUID? = nil) -> Bool {
    return shortcutWorkspace.updateShortcut(id: id, draft: draft, editorOwner: editorOwner)
  }

  func addShortcut(module: String = "功能快捷键") {
    if module == "快捷短语" || module == "短语类" {
      addPhrase()
      return
    }
    _ = createShortcut(from: makeShortcutDraft(module: module))
  }

  func normalizedShortcutDraft(_ draft: ShortcutItem, id: String) -> ShortcutItem {
    return shortcutWorkspace.normalizedShortcutDraft(draft, id: id)
  }

  private func validateShortcutDraft(_ draft: ShortcutItem) -> Bool {
    return shortcutWorkspace.validateShortcutDraft(draft)
  }

  func addPhrase() { phraseWorkspace.addPhrase() }

  func deleteSelectedPhrase() { phraseWorkspace.deleteSelectedPhrase() }

  func deleteShortcut(id: String) {
    return shortcutWorkspace.deleteShortcut(id: id)
  }

  func deleteSelected() {
    return shortcutWorkspace.deleteSelected()
  }

  func canDeleteShortcut(id: String) -> Bool {
    return shortcutWorkspace.canDeleteShortcut(id: id)
  }

  func shortcutDeletionHelp(id: String) -> String {
    return shortcutWorkspace.shortcutDeletionHelp(id: id)
  }

  var deletedDefaultShortcutCount: Int { shortcutWorkspace.deletedDefaultShortcutCount }

  func restoreDeletedDefaultShortcuts() {
    return shortcutWorkspace.restoreDeletedDefaultShortcuts()
  }

  private func shortcutDeletionDecision(for item: ShortcutItem) -> ShortcutDeletionDecision {
    return shortcutWorkspace.shortcutDeletionDecision(for: item)
  }

  private func isFixedFeatureShortcut(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.isFixedFeatureShortcut(item)
  }

  private func isAppManagedShortcut(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.isAppManagedShortcut(item)
  }

  private func defaultShortcutTemplate(matching item: ShortcutItem) -> ShortcutItem? {
    return shortcutWorkspace.defaultShortcutTemplate(matching: item)
  }

  private func shortcut(_ item: ShortcutItem, matchesDefaultTemplate template: ShortcutItem)
    -> Bool
  {
    return shortcutWorkspace.shortcut(item, matchesDefaultTemplate: template)
  }

  private func deletedDefaultShortcutTemplates() -> [ShortcutItem] {
    return shortcutWorkspace.deletedDefaultShortcutTemplates()
  }

  private func migrateBuiltInShortcutOwnership() -> Bool {
    return shortcutWorkspace.migrateBuiltInShortcutOwnership()
  }

  func resetDefaults() {
    return shortcutWorkspace.resetDefaults()
  }

  private func markShortcutDeleted(_ item: ShortcutItem, recoveryID: String?) {
    return shortcutWorkspace.markShortcutDeleted(item, recoveryID: recoveryID)
  }

  private func markShortcutNameDeleted(_ name: String) {
    return shortcutWorkspace.markShortcutNameDeleted(name)
  }

  private func isShortcutNameDeleted(_ name: String) -> Bool {
    return shortcutWorkspace.isShortcutNameDeleted(name)
  }

  private func clearDeletedShortcutNames() {
    return shortcutWorkspace.clearDeletedShortcutNames()
  }

  private func setDeletedShortcutNames(_ names: Set<String>) {
    return shortcutWorkspace.setDeletedShortcutNames(names)
  }

  private func deletedShortcutNames() -> Set<String> {
    return shortcutWorkspace.deletedShortcutNames()
  }

  private func isShortcutRecoveryDeleted(_ recoveryID: String) -> Bool {
    return shortcutWorkspace.isShortcutRecoveryDeleted(recoveryID)
  }

  private func restoreShortcutRecoveryID(_ recoveryID: String) {
    return shortcutWorkspace.restoreShortcutRecoveryID(recoveryID)
  }

  private func restoreShortcutNames(_ namesToRestore: Set<String>) {
    return shortcutWorkspace.restoreShortcutNames(namesToRestore)
  }

  private func clearShortcutDeletionMarkers(for item: ShortcutItem) {
    return shortcutWorkspace.clearShortcutDeletionMarkers(for: item)
  }

  private func shortcutDeletionNameAliases(for template: ShortcutItem) -> Set<String> {
    return shortcutWorkspace.shortcutDeletionNameAliases(for: template)
  }

  private func clearDeletedShortcutRecoveryIDs() {
    return shortcutWorkspace.clearDeletedShortcutRecoveryIDs()
  }

  private func setDeletedShortcutRecoveryIDs(_ recoveryIDs: Set<String>) {
    return shortcutWorkspace.setDeletedShortcutRecoveryIDs(recoveryIDs)
  }

  private func deletedShortcutRecoveryIDs() -> Set<String> {
    return shortcutWorkspace.deletedShortcutRecoveryIDs()
  }

  func updateEnabled(_ itemID: String, _ enabled: Bool) {
    return shortcutWorkspace.updateEnabled(itemID, enabled)
  }

  func shortcutIssue(for item: ShortcutItem, assumingEnabled: Bool? = nil) -> ShortcutIssue? {
    return shortcutWorkspace.shortcutIssue(for: item, assumingEnabled: assumingEnabled)
  }

  func runningAppChoices() -> [AppChoice] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app in
        guard let name = app.localizedName, !name.isEmpty else { return nil }
        let target = app.bundleIdentifier.map { "bundle:\($0)" } ?? app.bundleURL?.path ?? name
        return AppChoice(id: target, name: name, target: target, source: "运行中")
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func installedAppChoices(limit: Int = 20) -> [AppChoice] {
    if launcherApps.isEmpty, !isLauncherScanning {
      ensureLauncherAppsReady()
    }
    return launcherApps.prefix(limit).map { app in
      let target = app.bundleIdentifier.isEmpty ? app.path : "bundle:\(app.bundleIdentifier)"
      return AppChoice(
        id: target,
        name: app.name,
        target: target,
        source: "应用程序"
      )
    }
  }

  func installedAppChoices(matching query: String, limit: Int = 20) -> [AppChoice] {
    let apps = launcherWorkspace.matchingLauncherApps(query: query, limit: limit)
    return apps.prefix(limit).map { app in
      let target = app.bundleIdentifier.isEmpty ? app.path : "bundle:\(app.bundleIdentifier)"
      return AppChoice(
        id: target,
        name: app.name,
        target: target,
        source: "应用程序"
      )
    }
  }


  func canUndoActionPreset(itemID: String) -> Bool {
    return shortcutWorkspace.canUndoActionPreset(itemID: itemID)
  }

  func undoActionPreset(itemID: String) {
    return shortcutWorkspace.undoActionPreset(itemID: itemID)
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
    return shortcutWorkspace.applyActionPreset(itemID: itemID, action: action, target: target, name: name, scope: scope, note: note)
  }

  func canChangeShortcutAction(id: String) -> Bool {
    return shortcutWorkspace.canChangeShortcutAction(id: id)
  }

  func shortcutActionChangeHelp(id: String) -> String {
    return shortcutWorkspace.shortcutActionChangeHelp(id: id)
  }

  private func shortcutSemanticActionChanged(
    _ item: ShortcutItem,
    action: ShortcutAction,
    target: String
  ) -> Bool {
    return shortcutWorkspace.shortcutSemanticActionChanged(item, action: action, target: target)
  }

  private func replaceShortcutForActionMutation(
    at index: Int,
    with replacement: ShortcutItem
  ) {
    return shortcutWorkspace.replaceShortcutForActionMutation(at: index, with: replacement)
  }

  func setOpenTarget(itemID: String, choice: AppChoice) {
    return shortcutWorkspace.setOpenTarget(itemID: itemID, choice: choice)
  }

  func browseOpenTarget(itemID: String) {
    guard canChangeShortcutAction(id: itemID) else {
      statusMessage = shortcutActionChangeHelp(id: itemID)
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择 App、文件或文件夹"
    panel.prompt = "选择"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      let name = url.deletingPathExtension().lastPathComponent
      self?.applyActionPreset(
        itemID: itemID,
        action: .openApp,
        target: url.path,
        name: "打开 \(name)",
        scope: url.pathExtension == "app" ? "App" : "文件 / 文件夹",
        note: url.pathExtension == "app" ? "应用程序：打开 / 置前 / 再按隐藏。" : "文件或文件夹"
      )
    }
  }

  func togglePaused() { globalInputWorkspace.togglePaused() }

  func openConfigFile() {
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  func presentCommunityQRCode() {
    presentWindowHandler?()
    isCommunityQRCodePresented = true
  }

  func openApplicationsFolder() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
  }

  func restoreBestConfigurationAfterUserConfirmation() {
    statusMessage = "正在恢复小龙哥最佳配置..."
    configRestore.beginRestore()
  }

  func openLastBestConfigurationBackup() {
    guard let lastXLGConfigImportBackupURL else {
      statusMessage = "还没有最佳配置备份。"
      return
    }
    NSWorkspace.shared.open(lastXLGConfigImportBackupURL)
    statusMessage = "已打开恢复前备份。"
  }

  private func finishXLGConfigImport(_ result: XLGConfigImportResult) {
    clipboardHistory.reloadManagedPreferences()
    setDiagnosticsEnabled(UserDefaults.standard.bool(forKey: "diagnosticsEnabled"))
    shortcutWorkspace.reloadAfterConfigurationRestore()
    phraseWorkspace.load(discardPendingChanges: true)
    loadLauncherPinnedItems()
    loadKeepAwakeSettings()
    globalInputWorkspace.loadPreferences()
    launcherWorkspace.loadSettings()
    scrollWorkspace.loadSettings()
    reloadPermissionDependentListeners()
    shellPreferences.reloadAfterConfigurationRestore()
    NotificationCenter.default.post(
      name: Notification.Name("AIXLGManagedConfigurationDidRestore"), object: nil)
    statusMessage = "\(result.summary) 来源：\(result.sourceDescription)。"
  }

  func refreshLaunchAtLoginStatus() { startupWorkspace.refresh() }
  func setLaunchAtLoginEnabled(_ enabled: Bool) { startupWorkspace.setEnabled(enabled) }
  private func repairLaunchAgentIfNeeded() { startupWorkspace.repairExistingPreference() }

  func refreshLegacyScrollProfile() { scrollWorkspace.refreshLegacyScrollProfile() }

  func revealLegacyScrollConfig() { scrollWorkspace.revealLegacyScrollConfig() }

  func importLegacyScrollProfile() { scrollWorkspace.importLegacyScrollProfile() }

  func applyRecommendedScrollSettings(reverse: Bool? = nil) { scrollWorkspace.applyRecommendedScrollSettings(reverse: reverse) }

  func applyMosScrollPreset() { scrollWorkspace.applyMosScrollPreset() }

  func applyMouseScrollPreset(_ preset: MouseScrollPreset) { scrollWorkspace.applyMouseScrollPreset(preset) }

  func updateScrollSettings(_ mutate: (inout ScrollEngineSettings) -> Void) { scrollWorkspace.updateScrollSettings(mutate) }

  func setScrollEngineEnabled(_ enabled: Bool) { scrollWorkspace.setScrollEngineEnabled(enabled) }

  func setCapsCorePluginEnabled(_ enabled: Bool) { globalInputWorkspace.setCapsEnabled(enabled) }

  func reloadCapsCorePlugin(requestPermission: Bool = false) { globalInputWorkspace.reloadCaps(requestPermission: requestPermission) }



  private func refreshCapsCoreConflictIfNeeded() { globalInputWorkspace.refreshCapsConflictIfNeeded() }








  func setMouseVolumePluginEnabled(_ enabled: Bool) { scrollWorkspace.setMouseVolumePluginEnabled(enabled) }

  func setNetworkSpeedPluginEnabled(_ _: Bool) { shellPreferences.setNetworkSpeedPluginEnabled(true) }

  func setNetworkSpeedShowMemory(_ enabled: Bool) { shellPreferences.setNetworkSpeedShowMemory(enabled) }

  func setNetworkSpeedShowCPU(_ enabled: Bool) { shellPreferences.setNetworkSpeedShowCPU(enabled) }

  func setNetworkSpeedShowGPU(_ enabled: Bool) { shellPreferences.setNetworkSpeedShowGPU(enabled) }

  func setCodexNetworkProbeDefaultDirection(_ direction: NetworkProbeDirection) { shellPreferences.setCodexNetworkProbeDefaultDirection(direction) }

  func setClassicTabSwitcherEnabled(_ enabled: Bool) {
    guard !globalInputWorkspace.isStopped else { return }
    disableClassicTabSwitcherForRetirement(status: "窗口切换已下线，Command + Tab 保持系统默认。")
  }

  func confirmClassicTabSwitcherCommandTabTakeover() {
    guard !globalInputWorkspace.isStopped else { return }
    disableClassicTabSwitcherForRetirement(status: "窗口切换已下线，不再接管 Command + Tab。")
  }

  func restoreSystemCommandTabForClassicTabSwitcher() {
    guard !globalInputWorkspace.isStopped else { return }
    disableClassicTabSwitcherForRetirement(status: "Command + Tab 已保持系统默认。")
  }





  func previewClassicTabSwitcherHUD() {
    guard !globalInputWorkspace.isStopped else { return }
    disableClassicTabSwitcherForRetirement(status: "窗口切换已下线，暂不再展示半成品 HUD。")
  }

  private func disableClassicTabSwitcherForRetirement(status: String? = nil) {
    classicTabSwitcherEnabled = false
    classicTabSwitcherCommandTabTakeoverConfirmed = false
    UserDefaults.standard.set(false, forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    UserDefaults.standard.set(false, forKey: Self.classicTabSwitcherCommandTabTakeoverDefaultsKey)
    UserDefaults.standard.set(true, forKey: Self.classicTabSwitcherRetiredDefaultsKey)
    classicTabSwitcherRunning = false
    classicTabSwitcherStatusText = "已下线"
    updateClassicTabSwitcherHUDState(.hidden)
    AppDiagnostics.log(
      "classic_tab_switcher_retired_runtime",
      ["reason": "last_chance_gate_failed"])
    if let status {
      statusMessage = status
    }
  }

  func updateMouseVolumePluginSettings(_ mutate: (inout ScrollEngineSettings) -> Void) { scrollWorkspace.updateMouseVolumePluginSettings(mutate) }

  /// 长截图期间完全停止宿主滚轮引擎。物理滚轮只由目标 App 的原生事件链处理；
  /// ScreenCaptureKit 负责观察像素变化，宿主不再依赖 passthrough 特例。
  func setLongScreenshotCaptureActive(_ isActive: Bool) { scrollWorkspace.setLongScreenshotCaptureActive(isActive) }

  func reloadScrollEngine(reportStatus: Bool = true) { scrollWorkspace.reload(reportStatus: reportStatus) }

  func reloadClassicTabSwitcher() {
    guard !globalInputWorkspace.isStopped else { return }
    disableClassicTabSwitcherForRetirement()
  }

  private func updateClassicTabSwitcherHUDState(_ state: ClassicTabSwitcherHUDState) {
    classicTabSwitcherHUDState = state
    classicTabSwitcherHUDHandler?(state)
  }







  func presentAuthorizationCenter() { authorizationWorkspace.presentAuthorizationCenter() }
  func presentAuthorizationOnboardingIfNeeded() -> Bool { authorizationWorkspace.presentAuthorizationOnboardingIfNeeded() }
  func dismissAuthorizationCenter() { authorizationWorkspace.dismissAuthorizationCenter() }
  func performAuthorizationPrimaryAction() { authorizationWorkspace.performAuthorizationPrimaryAction() }
  func restartAppForAuthorization() { authorizationWorkspace.restartAppForAuthorization() }
  func prepareAuthorizationRelaunchForSystemTerminationIfNeeded() -> AuthorizationTerminationIntent { authorizationWorkspace.prepareAuthorizationRelaunchForSystemTerminationIfNeeded() }
  func startAutomaticAuthorization() { authorizationWorkspace.startAutomaticAuthorization() }
  func clearAuthorizationPermissionsAndRestart(userConfirmed: Bool) { authorizationWorkspace.clearAuthorizationPermissionsAndRestart(userConfirmed: userConfirmed) }
  func handleAuthorizationRepairRelaunchIfNeeded() { authorizationWorkspace.handleAuthorizationRepairRelaunchIfNeeded() }
  func presentAuthorizationRelaunchResultIfNeeded() -> Bool { authorizationWorkspace.presentAuthorizationRelaunchResultIfNeeded() }
  func quitAppForAccessibilityReauthorization() { authorizationWorkspace.quitAppForAccessibilityReauthorization() }
  func refreshAccessibilityStatus() { authorizationWorkspace.refreshAccessibilityStatus() }
  func refreshAuthorizationAndReloadIfNeeded() -> Bool { authorizationWorkspace.refreshAuthorizationAndReloadIfNeeded() }
  func verifyAuthorizationHotReloadAfterRelaunchIfNeeded() { authorizationWorkspace.verifyAuthorizationHotReloadAfterRelaunchIfNeeded() }
  func refreshAppSignatureSummary() { authorizationWorkspace.refreshAppSignatureSummary() }

  private func reloadPermissionDependentListeners() { globalInputWorkspace.reloadAll() }

  private func authorizationListenerVerification() -> AuthorizationListenerVerification { globalInputWorkspace.listenerVerification() }

  func isRecording(_ itemID: String) -> Bool {
    return shortcutWorkspace.isRecording(itemID)
  }
  var shortcutRecordingSessionID: UUID? { shortcutRecordingSession?.id }
  var shortcutActionCaptureSessionID: UUID? {
    shortcutRecorder.isCapturingAction ? shortcutRecorder.sessionID : nil
  }

  func startRecording(itemID: String) {
    return shortcutWorkspace.startRecording(itemID: itemID)
  }

  func toggleDraftShortcutRecording(onCaptured: @escaping (ShortcutTriggerRecordingValue) -> Void) {
    return shortcutWorkspace.toggleDraftShortcutRecording(onCaptured: onCaptured)
  }

  func cancelDraftShortcutRecording(ownerID: UUID? = nil) {
    return shortcutWorkspace.cancelDraftShortcutRecording(ownerID: ownerID)
  }
  func stopRecording() {
    return shortcutWorkspace.stopRecording()
  }
  private func stopShortcutTriggerRecording(reloadHotkeys: Bool) {
    return shortcutWorkspace.stopShortcutTriggerRecording(reloadHotkeys: reloadHotkeys)
  }
  func cancelRecordingIfNeeded() {
    return shortcutWorkspace.cancelRecordingIfNeeded()
  }

  func beginShortcutActionCapture(itemID: String) {
    return shortcutWorkspace.beginShortcutActionCapture(itemID: itemID)
  }
  func cancelShortcutActionCapture(ownerID: UUID? = nil) {
    return shortcutWorkspace.cancelShortcutActionCapture(ownerID: ownerID)
  }
  func applyShortcutActionCaptured(_ event: NSEvent, ownerID: UUID) {
    shortcutRecorder.receiveLocal(keyCode: UInt32(event.keyCode),
      modifiers: modifierNames(from: event.modifierFlags), ownerID: ownerID)
  }
  func applyRecorded(_ event: NSEvent, ownerID: UUID) {
    shortcutRecorder.receiveLocal(keyCode: UInt32(event.keyCode),
      modifiers: modifierNames(from: event.modifierFlags), ownerID: ownerID)
  }
  func applyRecorded(keyCode: UInt32, flags: CGEventFlags) {
    guard let ownerID = shortcutRecordingSessionID else { return }
    shortcutRecorder.receiveGlobal(keyCode: keyCode, flags: flags, ownerID: ownerID)
  }

  private func commitRecordedShortcut(session: ShortcutRecordingSession, value: ShortcutTriggerRecordingValue) {
    return shortcutWorkspace.commitRecordedShortcut(session: session, value: value)
  }

  func setPhysicalRightOptionDoubleTapTrigger(itemID: String) {
    return shortcutWorkspace.setPhysicalRightOptionDoubleTapTrigger(itemID: itemID)
  }

  func confirmShortcutActionCapture(ownerID: UUID? = nil) {
    return shortcutWorkspace.confirmShortcutActionCapture(ownerID: ownerID)
  }

  private func commitRecordedChord(session: ShortcutRecordingSession, value: ShortcutTriggerRecordingValue) {
    return shortcutWorkspace.commitRecordedChord(session: session, value: value)
  }

  private func commitRecordedPhysicalTrigger(session: ShortcutRecordingSession, trigger: ShortcutTrigger) {
    return shortcutWorkspace.commitRecordedPhysicalTrigger(session: session, trigger: trigger)
  }

  private func disableDuplicateLauncherShortcuts(keeping itemID: String) {
    return shortcutWorkspace.disableDuplicateLauncherShortcuts(keeping: itemID)
  }

  private func conflictingHotkeyItems(
    excluding itemID: String,
    key: String,
    modifiers: [String]
  ) -> [ShortcutItem] {
    return shortcutWorkspace.conflictingHotkeyItems(excluding: itemID, key: key, modifiers: modifiers)
  }

  private func itemConsumesHotkey(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.itemConsumesHotkey(item)
  }

  private func shortcutCompletionIssue(for item: ShortcutItem) -> ShortcutIssue? {
    return shortcutWorkspace.shortcutCompletionIssue(for: item)
  }

  private func conflictingExecutableItem(for item: ShortcutItem) -> ShortcutItem? {
    return shortcutWorkspace.conflictingExecutableItem(for: item)
  }

  private func disabledExecutableCollision(for item: ShortcutItem) -> ShortcutItem? {
    return shortcutWorkspace.disabledExecutableCollision(for: item)
  }

  private func hotkeyFailureText(for item: ShortcutItem) -> String? {
    return shortcutWorkspace.hotkeyFailureText(for: item)
  }

  private func canTransferLauncherHotkeyConflicts(
    currentItem: ShortcutItem,
    conflicts: [ShortcutItem]
  ) -> Bool {
    return shortcutWorkspace.canTransferLauncherHotkeyConflicts(currentItem: currentItem, conflicts: conflicts)
  }

  private func disableLauncherHotkeyConflicts(_ conflicts: [ShortcutItem]) -> [String] {
    return shortcutWorkspace.disableLauncherHotkeyConflicts(conflicts)
  }

  private func isLauncherOpenAppShortcut(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.isLauncherOpenAppShortcut(item)
  }

  private func shortcutAppName(_ item: ShortcutItem) -> String {
    return shortcutWorkspace.shortcutAppName(item)
  }

  func performSelectedForTest() {
    guard let selectedItem else { return }
    perform(selectedItem)
  }

  func runItem(_ itemID: String) {
    guard let item = items.first(where: { $0.id == itemID }) else { return }
    selectedID = itemID
    perform(item)
  }

  func revealBundledPlugins() {
    if let url = bundledPluginDirectoryURL(), FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      statusMessage = "当前运行环境没有找到脚本插件目录。"
    }
  }

  private func perform(_ item: ShortcutItem, context: HotkeyTriggerContext = .standard) {
    if let commandID = item.commandID {
      guard hasGlobalInputOwnership else {
        statusMessage = globalInputOwnershipBlockedMessage
        return
      }
      guard let executeFeatureCommandHandler else {
        statusMessage = "原生功能尚未载入，未执行 \(item.name)。"
        return
      }
      executeFeatureCommandHandler(commandID)
      return
    }
    AppDiagnostics.log(
      "perform_start",
      ["action": item.action.rawValue, "item": item.name])
    defer {
      AppDiagnostics.log("perform_end", ["action": item.action.rawValue, "item": item.name])
    }
    if let target = item.action.windowToggleTarget {
      if target == .shortcutGuide {
        toggleShortcutGuidePanelFromShortcut()
      } else {
        _ = toggleShortcutWindow(target)
      }
      return
    }
    switch item.action {
    case .openApp:
      openAppOrFolder(item.target, mode: context.openAppActivateOnly ? .activateOnly : .toggle)
    case .openURL:
      openURL(item.target)
    case .runShell:
      runShell(item.target)
    case .showPanel, .showLauncher, .showProcessViewer, .showClipboardHistory,
      .showCodexNetworkProbe:
      assertionFailure("Persistent shortcut windows must use windowToggleTarget.")
    case .showSleepPanel:
      toggleInfiniteKeepAwake()
    case .windowPreset:
      applyWindowPreset(item.target)
    case .nativeFullScreen:
      toggleNativeFullScreen()
    case .sendShortcut:
      sendShortcut(item.target)
    case .closeWindowSmart:
      closeWindowSmart()
    case .insertText:
      insertText(item.target)
    }
  }

  private func openAppOrFolder(
    _ target: String,
    mode: OpenAppTriggerMode = .toggle,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      showWindowHandler?()
      completion?(false)
      return
    }
    applicationOpening.cancelStaleAppActivations(keeping: appActivationKeyForOpenAppTarget(trimmed))
    if let normalizedTarget = normalizedOpenAppTarget(trimmed),
      normalizedTarget.hasPrefix("bundle:")
    {
      let bundleID = String(normalizedTarget.dropFirst("bundle:".count))
      applicationOpening.toggleBundleApp(bundleID, mode: mode, completion: completion)
      return
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      applicationOpening.toggleBundleApp(bundleID, mode: mode, completion: completion)
      return
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      let url = URL(fileURLWithPath: expanded)
      if url.pathExtension == "app" {
        applicationOpening.toggleApp(at: url, mode: mode, completion: completion)
      } else {
        completion?(NSWorkspace.shared.open(url))
      }
      return
    }
    if applicationOpening.toggleRunningApp(named: trimmed, mode: mode) {
      completion?(true)
      return
    }
    applicationOpening.openNamedApplication(trimmed, completion: completion)
  }

  private func normalizedOpenAppTarget(_ target: String) -> String? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return bundleID.isEmpty ? nil : "bundle:\(bundleID)"
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      let url = URL(fileURLWithPath: expanded)
      if url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier {
        return "bundle:\(bundleID)"
      }
      return nil
    }
    if let url = installedApplicationURL(named: trimmed),
      let bundleID = Bundle(url: url)?.bundleIdentifier
    {
      return "bundle:\(bundleID)"
    }
    if let bundleID = knownAppBundleIDs[appAliasKey(trimmed)] {
      return "bundle:\(bundleID)"
    }
    return nil
  }

  private func appActivationKeyForOpenAppTarget(_ target: String) -> String? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let normalizedTarget = normalizedOpenAppTarget(trimmed),
      normalizedTarget.hasPrefix("bundle:")
    {
      let bundleID = String(normalizedTarget.dropFirst("bundle:".count))
      return applicationOpening.activationKey(forBundleID: bundleID)
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      return applicationOpening.activationKey(forBundleID: bundleID)
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      let url = URL(fileURLWithPath: expanded)
      if url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier {
        return applicationOpening.activationKey(forBundleID: bundleID)
      }
    }
    if let app = applicationOpening.preferredRunningApplication(named: trimmed) {
      return applicationOpening.activationKey(for: app)
    }
    return nil
  }

  private func appAliasKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
      .lowercased()
  }

  private func installedApplicationURL(named name: String) -> URL? {
    let wanted = appAliasKey(name)
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
    ]
    for root in roots {
      guard
        let urls = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      else { continue }
      for url in urls where url.pathExtension == "app" {
        if appAliasKey(url.deletingPathExtension().lastPathComponent) == wanted {
          return url
        }
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        if [displayName, bundleName].compactMap({ $0 }).contains(where: {
          appAliasKey($0) == wanted
        }) {
          return url
        }
      }
    }
    return nil
  }

  private func openAppTargetExists(_ target: String) -> Bool {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if let normalizedTarget = normalizedOpenAppTarget(trimmed),
      normalizedTarget.hasPrefix("bundle:")
    {
      let bundleID = String(normalizedTarget.dropFirst("bundle:".count))
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        || applicationOpening.preferredRunningApplication(bundleID: bundleID) != nil
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        || applicationOpening.preferredRunningApplication(bundleID: bundleID) != nil
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return FileManager.default.fileExists(atPath: expanded)
    }
    return installedApplicationURL(named: trimmed) != nil
      || applicationOpening.preferredRunningApplication(named: trimmed) != nil
  }

  private func repairMissingDefaultBrowserShortcut() -> Bool {
    return shortcutWorkspace.repairMissingDefaultBrowserShortcut()
  }

  private func isDefaultChromeBrowserShortcut(_ item: ShortcutItem) -> Bool {
    return shortcutWorkspace.isDefaultChromeBrowserShortcut(item)
  }

  private func preferredBrowserShortcutTarget() -> (name: String, target: String)? {
    let webURL = URL(string: "https://www.apple.com")!
    if let url = NSWorkspace.shared.urlForApplication(toOpen: webURL),
      let target = openAppTarget(forApplicationURL: url)
    {
      return (applicationDisplayName(at: url), target)
    }
    for url in installedBrowserApplicationURLs() {
      if let target = openAppTarget(forApplicationURL: url) {
        return (applicationDisplayName(at: url), target)
      }
    }
    return nil
  }

  private func openAppTarget(forApplicationURL url: URL) -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    if let bundleID = Bundle(url: url)?.bundleIdentifier {
      return "bundle:\(bundleID)"
    }
    return url.path
  }

  private func applicationDisplayName(at url: URL) -> String {
    let info = Bundle(url: url)?.infoDictionary ?? [:]
    let displayName = info["CFBundleDisplayName"] as? String
    let bundleName = info["CFBundleName"] as? String
    return [displayName, bundleName, url.deletingPathExtension().lastPathComponent]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? url.deletingPathExtension().lastPathComponent
  }

  private func installedBrowserApplicationURLs() -> [URL] {
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
    ]
    var urls: [URL] = []
    for root in roots {
      guard
        let appURLs = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      else { continue }
      urls.append(contentsOf: appURLs.filter(isBrowserApplicationURL))
    }
    return urls.sorted { applicationDisplayName(at: $0) < applicationDisplayName(at: $1) }
  }

  private func isBrowserApplicationURL(_ url: URL) -> Bool {
    guard url.pathExtension == "app" else { return false }
    let name = applicationDisplayName(at: url).lowercased()
    let bundleID = Bundle(url: url)?.bundleIdentifier?.lowercased() ?? ""
    let keywords = [
      "browser", "浏览器", "safari", "firefox", "edge", "brave", "arc", "opera", "vivaldi",
      "360",
    ]
    return keywords.contains { name.contains($0) || bundleID.contains($0) }
  }

  @discardableResult
  private func disableMissingOpenAppShortcuts(
    excluding itemID: String? = nil,
    matchingSignature signature: String? = nil
  ) -> [String] {
    return shortcutWorkspace.disableMissingOpenAppShortcuts(excluding: itemID, matchingSignature: signature)
  }

  private func openURL(_ target: String) { shortcutActions.openURL(target) }
  private func runShell(_ command: String) { shortcutActions.runShell(command) }
  private func sendShortcut(_ target: String) { shortcutActions.sendShortcut(target) }
  private func closeWindowSmart() { shortcutActions.closeWindowSmart() }
  private func insertText(_ text: String) { shortcutActions.insertText(text) }
  private func applyWindowPreset(_ target: String) { shortcutActions.applyWindowPreset(target) }
  private func toggleNativeFullScreen() { shortcutActions.toggleNativeFullScreen() }
  private func bundledPluginDirectoryURL() -> URL? { shortcutActions.bundledPluginDirectoryURL() }

}
