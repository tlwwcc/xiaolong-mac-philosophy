import AppKit
import ApplicationServices
import Carbon
import IOKit.pwr_mgt
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

enum MouseScrollPreset: String, CaseIterable, Identifiable {
  case natural
  case stable
  case fast

  var id: String { rawValue }

  var title: String {
    switch self {
    case .natural: return "自然"
    case .stable: return "稳定"
    case .fast: return "快速"
    }
  }

  var detail: String {
    switch self {
    case .natural: return "顺滑均衡"
    case .stable: return "方向精准"
    case .fast: return "长页更快"
    }
  }
}

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

struct ShortcutTriggerRecordingValue: Equatable {
  let key: String
  let modifiers: [String]
  let trigger: ShortcutTrigger?

  var displayText: String {
    trigger?.displayText ?? displayHotkeyText(key: key, modifiers: modifiers)
  }
}

private final class ShortcutRecordingTapContext {
  weak var model: AppModel?
  let sessionID: UUID

  init(model: AppModel, sessionID: UUID) {
    self.model = model
    self.sessionID = sessionID
  }
}

@MainActor
final class AppModel: ObservableObject {
  nonisolated static let launcherPluginID = "launcher"
  nonisolated static let phrasesPluginID = "phrases"
  let runtimeIdentity = AppRuntimeIdentity.current
  var sparkleCheckForUpdatesHandler: (() -> Void)?
  private let globalInputLease = GlobalInputLease()
  private(set) var hasGlobalInputOwnership = false
  private var globalInputOwnershipBlockReason = "全局输入独占权尚未取得"

  private enum OpenAppTriggerMode {
    case toggle
    case activateOnly
  }

  private enum ShortcutRecordingTarget {
    case item(String)
    case draft
  }

  private struct ShortcutRecordingSession {
    let id: UUID
    let target: ShortcutRecordingTarget
  }

  private static let builtInLauncherHotkey = ShortcutItem(
    id: "builtin-launcher-caps-space",
    name: "小龙哥启动器",
    scope: "内置",
    key: "Space",
    modifiers: ["control", "option"],
    action: .showLauncher,
    target: "",
    enabled: true,
    note: "Caps + Space：打开小龙哥启动器。"
  )

  @Published var items: [ShortcutItem] = []
  @Published var selectedID: String?
  @Published var statusMessage = "正在启动..."
  @Published var isPaused = false
  @Published var recordingItemID: String?
  @Published private(set) var isDraftShortcutRecording = false
  @Published var shortcutRecordingConflictNotice: ShortcutRecordingConflictNotice?
  @Published var shortcutActionCaptureItemID: String?
  @Published var shortcutActionCaptureDraft = ""
  @Published var hotkeyFailures: [String] = []
  @Published var advancedListeningAuthorized = AXIsProcessTrusted()
  @Published var inputMonitoringAuthorized = CGPreflightListenEventAccess()
  @Published var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
  @Published var capsCorePluginEnabled = false
  @Published var capsCoreEngineRunning = false
  @Published var capsCorePluginStatus: CapsCorePluginStatus = .stopped
  @Published var inputMethodPluginEnabled = false
  @Published var inputMethodSources: [InputMethodSourceDescriptor] = []
  @Published var inputMethodRules: [InputMethodAppRule] = []
  @Published var inputMethodRuleDiagnostics: [InputMethodRuleDiagnostic] = []
  @Published var inputMethodPluginStatus: InputMethodPluginStatus = .stopped
  @Published var legacyScrollProfile = LegacyScrollProfile.empty
  @Published var scrollSettings = ScrollEngineSettings.defaults
  @Published var scrollEngineRunning = false
  @Published var launchAtLoginEnabled = false
  @Published var phrases: [PhraseItem] = []
  @Published var selectedPhraseID: String?
  @Published var launcherApps: [LauncherApp] = []
  @Published var launcherQuery = ""
  @Published var launcherSearchEngine: LauncherSearchEngine = .baidu
  @Published private(set) var launcherPinnedRecords: [LauncherPinnedRecord] = []
  @Published var launcherPinnedStatusText = ""
  @Published var isLauncherScanning = false
  @Published var launcherDisplayMode: LauncherDisplayMode = .icons
  @Published var launcherShowsPinnedNames = false
  @Published var launcherPluginEnabled = true
  @Published var launcherSelectedResultID: String?
  @Published var launcherFocusRequestID = 0
  private var launcherOpenLearning = LauncherOpenLearningCoordinator()
  @Published var selectedPluginID: String?
  @Published var pluginCenterScrollAnchorID: String?
  @Published var selectedModuleName = "插件中心" {
    didSet {
      if Self.isLegacyLauncherModule(selectedModuleName) {
        selectedPluginID = Self.launcherPluginID
        pluginCenterScrollAnchorID = Self.launcherPluginID
        selectedModuleName = "插件中心"
      }
    }
  }
  @Published var selectedAboutSection = "通用"
  @Published var diagnosticsEnabled = AppDiagnostics.isEnabled
  @Published var keepAwakeEnabled = false
  @Published var keepAwakePreventDisplaySleep = false
  @Published var keepAwakeStatusText = "未开启"
  @Published var keepAwakeCustomHours = 3
  @Published var sleepStatusItemVisible = true
  @Published var dockIconVisible = DockPresencePreference.isVisible()
  @Published var menuBarVisibleItemIDs = MenuBarCatalog.defaultVisibleItemIDs
  @Published var isMenuBarCustomizationPresented = false
  @Published var isCommunityQRCodePresented = false
  @Published var systemMonitorSnapshot = SystemMonitorSnapshot.empty
  @Published var networkSpeedPluginEnabled = true
  @Published var networkSpeedShowMemory = true
  @Published var networkSpeedShowCPU = false
  @Published var networkSpeedShowGPU = false
  @Published private(set) var pdfFileAssociationCoverage: FileAssociationStatus.Coverage = .none
  @Published private(set) var audioFileAssociationCoverage: FileAssociationStatus.Coverage = .none
  @Published private(set) var pdfFileAssociationCanRestore = false
  @Published private(set) var audioFileAssociationCanRestore = false
  @Published private(set) var fileAssociationBusyKind: AssociatedFileKind?
  @Published private(set) var fileAssociationFeedbackKind: AssociatedFileKind?
  @Published private(set) var fileAssociationFeedbackText = ""
  @Published var codexNetworkProbeDefaultDirection: NetworkProbeDirection = .domestic
  @Published var latestUpdate: AppUpdateManifest?
  @Published var updateServerVersionText = "未检查"
  @Published var updateStatusText = "未检查"
  @Published var updateReleaseDetailText = ""
  @Published var updateDownloadProgress: Double?
  @Published private(set) var updateFailureMessage: String?
  @Published var isUpdateBusy = false
  @Published var pendingReleaseNote: ReleaseNoteEntry?
  @Published var isReleaseNotePresented = false
  @Published var shortcutGuideFocusRequest = 0
  @Published var shortcutGuideRequestedCategory = "全部"
  @Published var shortcutGuideRequestedSearchText = ""
  @Published var shortcutCreateRequestID = 0
  @Published var shortcutEditRequestID = 0
  @Published var shortcutSemanticMigrationMessage = ""
  @Published private(set) var lastShortcutSemanticBackupURL: URL?
  @Published var pijuanPDFShortcutCount = 0
  @Published var isAccessibilityAuthorizationPresented = false
  @Published var isTranslationModelSetupPresented = false
  private let translationModelSetupOnboarding = TranslationModelSetupOnboarding()
  var translationModelNeedsDownloadHandler: (() async -> Bool)?
  var makeTranslationModelSetupViewHandler: ((@escaping () -> Void) -> AnyView?)?

  @Published private(set) var authorizationRelaunchCompleted = false
  @Published private(set) var authorizationAutomaticRelaunchInProgress = false
  @Published private(set) var authorizationManualRelaunchRequired = false
  @Published var appSignatureSummary = "未检测"
  @Published var isRepairingAuthorization = false
  @Published var authorizationRepairResultText = ""
  @Published private(set) var authorizationRecheckFailed = false
  @Published var sleepPanelRequestID = 0
  @Published var isImportingXLGConfig = false
  @Published var lastXLGConfigImportBackupURL: URL?
  @Published var classicTabSwitcherEnabled = false
  @Published var classicTabSwitcherCommandTabTakeoverConfirmed = false
  @Published var classicTabSwitcherRunning = false
  @Published var classicTabSwitcherStatusText = "未监听"
  @Published var classicTabSwitcherHUDState = ClassicTabSwitcherHUDState.hidden

  let fileURL: URL
  let phraseURL: URL
  let launcherIndexURL: URL
  let launcherHistoryURL: URL
  let launcherPinnedURL: URL
  let inputMethodRulesURL: URL
  let clipboardHistory: ClipboardHistoryController
  private var fileAssociationManagerStorage: FileAssociationManager?
  private var aiPlayerStorage: AIPlayerController?
  var aiPlayer: AIPlayerController {
    if let aiPlayerStorage {
      return aiPlayerStorage
    }
    let controller = AIPlayerController()
    aiPlayerStorage = controller
    return controller
  }
  var aiPlayerExtendedMediaAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/mpv")
  }
  var aiPlayerCanUndoTrash: Bool {
    aiPlayerStorage?.canUndoTrash ?? false
  }
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
  var showAIPlayerHandler: (() -> Void)?
  var showYoumuFeatureHandler: (() -> Void)?
  var openYoumuControlCenterHandler: (() -> Void)?
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
  var authorizationTerminationHandler: (() -> Void)?

  private var hotkeyManager: HotkeyManager?
  private var phraseExpander: PhraseExpander?
  private var scrollEngine: ScrollEngine?
  private var isScrollEngineSuspendedForLongScreenshot = false

  var isLongScreenshotCaptureActive: Bool {
    isScrollEngineSuspendedForLongScreenshot
  }
  private var capsCoreEngine: CapsCoreEngine?
  var inputMethodPluginEngine: InputMethodPluginEngine?
  var inputMethodStructuralDiagnostics: [InputMethodRuleDiagnostic] = []
  var inputMethodManualSelection: InputMethodSourceSelectionOperation?
  var launcherInputMethodSelection: InputMethodSourceSelectionOperation?
  var launcherInputMethodOverrideActive = false
  var launcherInputMethodPreviousSelectionID: String?
  var launcherInputMethodTargetSelectionID: String?
  private var classicTabSwitcher: ClassicTabSwitcher?
  private var authorizationReloadWorkItem: DispatchWorkItem?
  private var authorizationRepairOpenedSettingsService: AuthorizationRepairService?
  private var authorizationRelaunchRelayMarkerURL: URL?
  private var authorizationRelaunchRelayProcess: Process?
  private var authorizationRelaunchRelayToken: UUID?
  private var authorizationRelaunchFailureWorkItem: DispatchWorkItem?
  private var authorizationSystemPromptRelaunchScheduled = false
  private var authorizationRegistrationRequestInFlight = false
  private var authorizationRelaunchAttemptState = AuthorizationRelaunchAttemptStateMachine()
  private var authorizationHotReloadState = AuthorizationHotReloadStateMachine(
    permissions: AuthorizationPermissionSnapshot(
      accessibility: AXIsProcessTrusted(),
      inputMonitoring: CGPreflightListenEventAccess(),
      screenRecording: CGPreflightScreenCaptureAccess()),
    relaunchAttemptedForCurrentGrant: UserDefaults.standard.bool(
      forKey: "authorizationHotReloadRelaunchAttemptedV1"))
  private var detectedCapsCoreConflict: CapsCoreConflict?
  private var lastCapsCoreConflictCheckAt: TimeInterval = 0
  private var recordingTimeout: DispatchWorkItem?
  private var recordingTap: CFMachPort?
  private var recordingTapSource: CFRunLoopSource?
  private var recordingTapContext: ShortcutRecordingTapContext?
  private var recordingModifierListener: PhysicalModifierDoubleTapHIDListener?
  private var shortcutRecordingSession: ShortcutRecordingSession?
  private var draftShortcutRecordingHandler: ((ShortcutTriggerRecordingValue) -> Void)?
  private var hotkeysSuspendedForRecording = false
  private var hotkeyReloadWorkItem: DispatchWorkItem?
  private var phraseSaveWorkItem: DispatchWorkItem?
  private var phraseSaveNeedsReload = false
  private var shortcutDefaultBaselineVersionCommitPending = false
  private var maximizeRestoreFrames: [String: CGRect] = [:]
  private var pendingMaximizeRestoreKeys = Set<String>()
  private var windowOperationSequence: UInt64 = 0
  private var windowOperationTokens: [String: UInt64] = [:]
  private var fullScreenToggleGeneration: UInt64 = 0
  private var recentlyHiddenAppBundleIDs: [String: TimeInterval] = [:]
  private var appForegroundPendingUntil: [String: TimeInterval] = [:]
  private var appActivationSequence: UInt64 = 0
  private var appActivationTokens: [String: UInt64] = [:]
  private var appActivationWorkItems: [String: [DispatchWorkItem]] = [:]
  private var shellExecution: BoundedProcessExecution?
  private var shellExecutionGeneration: UInt64 = 0
  private var enableAfterRecordingItemIDs = Set<String>()
  private var launcherIndex: LauncherAppIndex?
  private var launcherUsageHistory = LauncherUsageHistory.empty
  private var launcherScanInProgress = false
  private var launcherOpenToken: LauncherPerformance.OpenToken?
  private var launcherOpenDidMarkFirstResults = false
  private var launcherUninstallRequestID: String?
  private var keepAwakeActivity: NSObjectProtocol?
  private var keepAwakeTimer: Timer?
  private var keepAwakeUserActivityTimer: Timer?
  private var keepAwakeUserActivityID: IOPMAssertionID?
  private var keepAwakeEndDate: Date?
  private var systemMonitor = SystemMonitor()
  private var systemMonitorTimer: Timer?
  private var stagedUpdate: StagedAppUpdate?
  private var lastAutomaticUpdateCheckAt: Date?
  private var needsUpdateAuthorizationRecheck = false

  private var launchAgentID: String { runtimeIdentity.launchAgentIdentifier }
  private let maximizeRestoreDefaultsKey = "windowMaximizeRestoreFramesV2"
  private let deletedShortcutNamesDefaultsKey = "deletedShortcutNamesV1"
  private let deletedShortcutRecoveryIDsDefaultsKey = "deletedShortcutRecoveryIDsV1"
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
  private let automaticUpdateCheckInterval: TimeInterval = 6 * 60 * 60
  private static let mouseVolumePluginUserSetDefaultsKey = "mouseVolumePluginUserSetV1"
  private static let keepAwakePreventDisplaySleepDefaultsKey = "keepAwakePreventDisplaySleep"
  private static let keepAwakeCustomHoursDefaultsKey = "keepAwakeCustomHours"
  private static let sleepStatusItemVisibleDefaultsKey = "sleepStatusItemVisibleV1"
  private static let capsCorePluginEnabledDefaultsKey = "capsCorePluginEnabledV1"
  private static let scrollEngineUserSetEnabledDefaultsKey = "scrollEngineUserSetEnabledV1"
  private static let networkSpeedPluginEnabledDefaultsKey = "networkSpeedPluginEnabledV1"
  private static let networkSpeedShowMemoryDefaultsKey = "networkSpeedShowMemoryV1"
  private static let networkSpeedShowCPUDefaultsKey = "networkSpeedShowCPUV1"
  private static let networkSpeedShowGPUDefaultsKey = "networkSpeedShowGPUV1"
  private static let networkSpeedDisplayOptionsVersionDefaultsKey =
    "networkSpeedDisplayOptionsVersionV1"
  private static let codexNetworkProbeDefaultDirectionDefaultsKey =
    "codexNetworkProbeDefaultDirectionV1"
  private static let classicTabSwitcherEnabledDefaultsKey = "classicTabSwitcherEnabledV1"
  private static let classicTabSwitcherDemotionDefaultsKey = "classicTabSwitcherDemotionV1"
  private static let classicTabSwitcherBuiltInRouteDefaultsKey = "classicTabSwitcherBuiltInRouteV1"
  private static let classicTabSwitcherRetiredDefaultsKey = "classicTabSwitcherRetiredV1"
  private static let classicTabSwitcherCommandTabTakeoverDefaultsKey =
    "classicTabSwitcherCommandTabTakeoverConfirmedV1"
  private static let classicTabSwitcherRetired = true
  private static let launcherSearchEngineDefaultsKey = "launcherSearchEngineV1"
  private static let launcherDisplayModeDefaultsKey = "launcherDisplayModeV1"
  private static let launcherShowsPinnedNamesDefaultsKey = "launcherShowsPinnedNamesV1"
  private static let launcherPluginEnabledDefaultsKey = "launcherPluginEnabledV1"
  private static let autoUpdateCheckKey = "lastAutomaticUpdateCheckAtV1"
  private static let lastSeenReleaseNotesBuildDefaultsKey = "lastSeenReleaseNotesBuildV1"
  private static let pendingAuthorizationRepairServicesDefaultsKey =
    "pendingAuthorizationRepairServicesV2"
  private static let restartAfterAuthorizationRepairGrantDefaultsKey =
    "restartAfterAuthorizationRepairGrantV2"
  private static let authorizationFlowOwnerPIDDefaultsKey =
    "authorizationFlowOwnerPIDV1"
  private static let authorizationHotReloadRelaunchAttemptedDefaultsKey =
    "authorizationHotReloadRelaunchAttemptedV1"
  private static let authorizationRelaunchPresentationSourcePIDDefaultsKey =
    "authorizationRelaunchPresentationSourcePIDV1"
  private static let authorizationRelaunchPresentationRequestedAtDefaultsKey =
    "authorizationRelaunchPresentationRequestedAtV1"
  private static let authorizationLastPromptedMissingFingerprintDefaultsKey =
    "authorizationLastPromptedMissingFingerprintV1"
  private static let authorizationWasCompleteDefaultsKey =
    "authorizationWasCompleteV1"
  private static let shortcutSemanticCapsChoiceDefaultsKey =
    "shortcutSemanticCapsSpaceChoiceFingerprintV1"
  private static let shortcutSemanticCommandChoiceDefaultsKey =
    "shortcutSemanticCommandSpaceChoiceFingerprintV1"
  private static let shortcutSemanticUndoDefaultsKey =
    "shortcutSemanticMigrationUndoFingerprintV1"
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
    phraseURL = base.appendingPathComponent("phrases.json")
    launcherIndexURL = base.appendingPathComponent("launcher-index.json")
    launcherHistoryURL = base.appendingPathComponent("launcher-history.json")
    launcherPinnedURL = base.appendingPathComponent("launcher-pinned.json")
    inputMethodRulesURL = base.appendingPathComponent("input-method-rules.json")
    var initialConfigurationError: String?
    do {
      _ = try XLGConfigImporter.installBundledConfigurationIfNeeded(
        request: .appDefault(
          applicationSupportURL: base,
          shortcutsURL: base.appendingPathComponent("shortcuts.json"),
          phrasesURL: base.appendingPathComponent("phrases.json")))
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
    sleepStatusItemVisible = Self.boolDefaultingTrue(
      forKey: Self.sleepStatusItemVisibleDefaultsKey)
    menuBarVisibleItemIDs = MenuBarCatalog.loadVisibleItemIDs()
    capsCorePluginEnabled = UserDefaults.standard.bool(
      forKey: Self.capsCorePluginEnabledDefaultsKey)
    inputMethodPluginEnabled = UserDefaults.standard.bool(
      forKey: Self.inputMethodPluginEnabledDefaultsKey)
    loadInputMethodRules()
    Self.ensureNetworkSpeedPrimaryEntryEnabled()
    networkSpeedPluginEnabled = true
    Self.migrateNetworkSpeedDisplayOptionsIfNeeded()
    networkSpeedShowMemory = Self.boolDefaultingTrue(
      forKey: Self.networkSpeedShowMemoryDefaultsKey)
    networkSpeedShowCPU = UserDefaults.standard.bool(forKey: Self.networkSpeedShowCPUDefaultsKey)
    networkSpeedShowGPU = UserDefaults.standard.bool(forKey: Self.networkSpeedShowGPUDefaultsKey)
    let storedNetworkProbeDirection = NetworkProbeDirection(
      rawValue: UserDefaults.standard.string(
        forKey: Self.codexNetworkProbeDefaultDirectionDefaultsKey) ?? ""
    )
    codexNetworkProbeDefaultDirection = NetworkProbeDirection.customerFacing(
      storedNetworkProbeDirection)
    UserDefaults.standard.set(
      codexNetworkProbeDefaultDirection.rawValue,
      forKey: Self.codexNetworkProbeDefaultDirectionDefaultsKey)
    Self.retireClassicTabSwitcherIfNeeded()
    launcherSearchEngine = Self.loadLauncherSearchEngine()
    launcherDisplayMode = Self.loadLauncherDisplayMode()
    launcherShowsPinnedNames = Self.loadLauncherShowsPinnedNames()
    launcherPluginEnabled = Self.boolDefaultingTrue(
      forKey: Self.launcherPluginEnabledDefaultsKey)
    classicTabSwitcherEnabled = UserDefaults.standard.bool(
      forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    classicTabSwitcherCommandTabTakeoverConfirmed = UserDefaults.standard.bool(
      forKey: Self.classicTabSwitcherCommandTabTakeoverDefaultsKey)
    load()
    loadPhrases()
    refreshAccessibilityStatus()
    authorizationRelaunchCompleted = allRequiredPermissionsComplete
    refreshAppSignatureSummary()
    refreshLaunchAtLoginStatus()
    repairLaunchAgentIfNeeded()
    refreshLegacyScrollProfile()
    scrollSettings = loadScrollSettings()
    saveScrollSettings()
    hotkeyManager = HotkeyManager(
      onTrigger: { [weak self] item, context in
        Task { @MainActor [weak self] in
          guard let self else { return }
          guard
            !item.usesChordTrigger
              || self.capsCoreEngine?.shouldAllowHotkeyTrigger(modifiers: item.modifiers) ?? true
          else {
            AppDiagnostics.log(
              "hotkey_trigger_blocked",
              [
                "item": item.name,
                "key": item.displayHotkey,
                "reason": "caps_hardware_reconcile",
              ])
            self.statusMessage = "Caps 已自动解粘，本次快捷键已安全拦截，请重新按一次。"
            return
          }
          self.perform(item, context: context)
        }
      },
      onNotice: { [weak self] message in
        Task { @MainActor [weak self] in
          self?.handleHotkeyManagerNotice(message)
        }
      })
    phraseExpander = PhraseExpander { [weak self] message in
      Task { @MainActor [weak self] in self?.statusMessage = message }
    }
    scrollEngine = ScrollEngine { [weak self] message in
      Task { @MainActor [weak self] in self?.statusMessage = message }
    }
    capsCoreEngine = CapsCoreEngine(
      allowsSystemMappingProtection: !runtimeIdentity.isInvalid
    ) { [weak self] status in
      Task { @MainActor [weak self] in
        self?.handleCapsCoreEngineStatus(status)
      }
    }
    classicTabSwitcher = ClassicTabSwitcher(
      onStateChange: { [weak self] state in
        Task { @MainActor [weak self] in
          self?.updateClassicTabSwitcherHUDState(state)
        }
      },
      onNotice: { [weak self] message in
        Task { @MainActor [weak self] in self?.statusMessage = message }
      },
      cancelAppForegroundRepair: { [weak self] app, reason in
        if Thread.isMainThread {
          MainActor.assumeIsolated {
            self?.cancelAppForegroundRepair(for: app, reason: reason)
          }
        } else {
          Task { @MainActor [weak self] in
            self?.cancelAppForegroundRepair(for: app, reason: reason)
          }
        }
      },
      revealSelfApp: { [weak self] in
        guard let self else { return false }
        let reveal = {
          if let presentWindowHandler = self.presentWindowHandler {
            presentWindowHandler()
            return true
          }
          if let showWindowHandler = self.showWindowHandler {
            showWindowHandler()
            return true
          }
          DistributedNotificationCenter.default().postNotificationName(
            .showAixlgHotkeysWindow,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
          return true
        }
        if Thread.isMainThread {
          return MainActor.assumeIsolated { reveal() }
        }
        Task { @MainActor in
          _ = reveal()
        }
        return true
      })
    if scrollSettings.enabled {
      quitLegacyScrollAppIfRunning()
    }
    reloadHotkeys()
    reloadPhraseExpander()
    reloadCapsCorePlugin(requestPermission: false)
    seedLauncherInputMethodRuleIfNeeded()
    reloadInputMethodPlugin()
    reloadScrollEngine()
    reloadClassicTabSwitcher()
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

  func shutdown() {
    phraseSaveWorkItem?.cancel()
    shellExecutionGeneration &+= 1
    shellExecution?.cancel()
    shellExecution = nil
    authorizationReloadWorkItem?.cancel()
    hasGlobalInputOwnership = false
    globalInputOwnershipWillYieldHandler?()
    hotkeyManager?.suspendAll()
    phraseExpander?.stop()
    capsCoreEngine?.stop(reason: "appShutdown")
    restoreInputMethodAfterLauncher()
    inputMethodManualSelection?.cancel()
    inputMethodManualSelection = nil
    launcherInputMethodSelection?.cancel()
    launcherInputMethodSelection = nil
    inputMethodPluginEngine?.stop()
    scrollEngine?.stop()
    stopSystemMonitor()
    stopKeepAwake(resetStatus: false)
    classicTabSwitcher?.stop()
    stopShortcutTriggerRecording(reloadHotkeys: false)
    aiPlayerStorage?.stop()
    clipboardHistory.stop()
    globalInputLease.release()
  }

  private func initializeGlobalInputOwnership() {
    guard runtimeIdentity.mayRequestGlobalInputLease(runningProcesses: []) else {
      globalInputOwnershipBlockReason = "运行身份无效"
      return
    }
    hasGlobalInputOwnership = globalInputLease.acquire()
    if !hasGlobalInputOwnership {
      globalInputOwnershipBlockReason =
        globalInputLease.lastFailure == "busy" ? "另一版本正在接管全局输入" : "全局输入独占权建立失败"
    }
    AppDiagnostics.log(
      "global_input_ownership_initialized",
      [
        "channel": runtimeIdentity.buildChannelName,
        "owned": "\(hasGlobalInputOwnership)",
        "reason": hasGlobalInputOwnership ? "acquired" : globalInputOwnershipBlockReason,
      ])
  }

  @discardableResult
  func refreshGlobalInputOwnership(trigger: String) -> Bool {
    let eligible = runtimeIdentity.mayRequestGlobalInputLease(runningProcesses: [])

    if !eligible {
      globalInputOwnershipBlockReason = "运行身份无效"
      guard hasGlobalInputOwnership else { return false }

      // Stop every host-owned listener before releasing the kernel lease.
      hasGlobalInputOwnership = false
      globalInputOwnershipWillYieldHandler?()
      stopRecording()
      reloadPermissionDependentListeners()
      globalInputLease.release()
      statusMessage = "运行身份无效，已停止 Caps 和全局快捷键。"
      AppDiagnostics.log(
        "global_input_ownership_released",
        [
          "channel": runtimeIdentity.buildChannelName,
          "trigger": trigger,
          "reason": "invalidIdentity",
        ])
      return true
    }

    if hasGlobalInputOwnership, globalInputLease.isOwned { return false }
    guard globalInputLease.acquire() else {
      globalInputOwnershipBlockReason =
        globalInputLease.lastFailure == "busy" ? "另一版本正在接管全局输入" : "全局输入独占权建立失败"
      return false
    }

    hasGlobalInputOwnership = true
    reloadPermissionDependentListeners()
    statusMessage = "Caps 和全局快捷键已恢复。"
    AppDiagnostics.log(
      "global_input_ownership_acquired",
      ["channel": runtimeIdentity.buildChannelName, "trigger": trigger])
    return true
  }

  var globalInputOwnershipBlockedMessage: String {
    "\(globalInputOwnershipBlockReason)：已暂停全局监听。"
  }

  var selectedIndex: Int? {
    items.firstIndex { $0.id == selectedID }
  }

  var selectedItem: ShortcutItem? {
    guard let selectedIndex else { return nil }
    return items[selectedIndex]
  }

  func bindingForItem(id: String) -> Binding<ShortcutItem>? {
    guard items.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { [weak self] in
        self?.items.first(where: { $0.id == id }) ?? Self.deletedShortcutPlaceholder(id: id)
      },
      set: { [weak self] value in
        guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
        self.items[index] = value
      }
    )
  }

  func bindingForPhrase(id: String) -> Binding<PhraseItem>? {
    guard phrases.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { [weak self] in
        self?.phrases.first(where: { $0.id == id }) ?? Self.deletedPhrasePlaceholder(id: id)
      },
      set: { [weak self] value in
        guard let self, let index = self.phrases.firstIndex(where: { $0.id == id }) else { return }
        self.phrases[index] = value
      }
    )
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

  var activeCount: Int {
    items.filter { $0.enabled && keyCode(for: $0.key) != nil }.count
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

  var updatePrimaryActionTitle: String {
    if isUpdateBusy {
      return "处理中"
    }
    guard let latestUpdate else { return "检查更新" }
    return "更新到 \(latestUpdate.displayVersion)"
  }

  var updatePrimaryActionIcon: String {
    latestUpdate == nil ? "arrow.clockwise" : "square.and.arrow.down"
  }

  private var currentBuildNumber: Int {
    let info = Bundle.main.infoDictionary ?? [:]
    let build = info["CFBundleVersion"] as? String ?? "0"
    return Int(build) ?? 0
  }

  var usesSparkleUpdater: Bool {
    currentBuildNumber >= 182
  }

  private static func boolDefaultingTrue(forKey key: String) -> Bool {
    guard UserDefaults.standard.object(forKey: key) != nil else { return true }
    return UserDefaults.standard.bool(forKey: key)
  }

  private static func migrateNetworkSpeedDisplayOptionsIfNeeded() {
    guard UserDefaults.standard.object(forKey: networkSpeedDisplayOptionsVersionDefaultsKey) == nil
    else { return }
    UserDefaults.standard.set(true, forKey: networkSpeedShowMemoryDefaultsKey)
    UserDefaults.standard.set(false, forKey: networkSpeedShowCPUDefaultsKey)
    UserDefaults.standard.set(false, forKey: networkSpeedShowGPUDefaultsKey)
    UserDefaults.standard.set(1, forKey: networkSpeedDisplayOptionsVersionDefaultsKey)
  }

  private static func ensureNetworkSpeedPrimaryEntryEnabled() {
    UserDefaults.standard.set(true, forKey: networkSpeedPluginEnabledDefaultsKey)
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

  private static func loadLauncherSearchEngine() -> LauncherSearchEngine {
    let rawValue = UserDefaults.standard.string(forKey: launcherSearchEngineDefaultsKey) ?? ""
    return LauncherSearchEngine(rawValue: rawValue) ?? .baidu
  }

  private static func loadLauncherDisplayMode() -> LauncherDisplayMode {
    let rawValue =
      UserDefaults.standard.string(forKey: launcherDisplayModeDefaultsKey)
      ?? LauncherDefaultConfiguration.displayModeRawValue
    return LauncherDisplayMode(rawValue: rawValue) ?? .icons
  }

  private static func loadLauncherShowsPinnedNames() -> Bool {
    guard UserDefaults.standard.object(forKey: launcherShowsPinnedNamesDefaultsKey) != nil else {
      return LauncherDefaultConfiguration.showsPinnedNames
    }
    return UserDefaults.standard.bool(forKey: launcherShowsPinnedNamesDefaultsKey)
  }

  func setLauncherSearchEngine(_ engine: LauncherSearchEngine) {
    launcherSearchEngine = engine
    UserDefaults.standard.set(engine.rawValue, forKey: Self.launcherSearchEngineDefaultsKey)
    statusMessage = "启动器网页搜索已切换为 \(engine.title)。"
  }

  private func loadKeepAwakeSettings() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.keepAwakePreventDisplaySleepDefaultsKey) != nil {
      keepAwakePreventDisplaySleep = defaults.bool(
        forKey: Self.keepAwakePreventDisplaySleepDefaultsKey)
    }
    let savedHours = defaults.integer(forKey: Self.keepAwakeCustomHoursDefaultsKey)
    keepAwakeCustomHours = savedHours == 0 ? 3 : min(max(savedHours, 1), 12)
  }

  private func applyKeepAwakeActivity() {
    if let keepAwakeActivity {
      ProcessInfo.processInfo.endActivity(keepAwakeActivity)
      self.keepAwakeActivity = nil
    }
    var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
    if keepAwakePreventDisplaySleep {
      options.insert(.idleDisplaySleepDisabled)
    }
    keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
      options: options,
      reason: keepAwakePreventDisplaySleep
        ? "小龙哥Mac哲学：保持唤醒并保持屏幕亮起。"
        : "小龙哥Mac哲学：正在保持唤醒。"
    )
  }

  private func startKeepAwakeTimers() {
    keepAwakeTimer?.invalidate()
    keepAwakeTimer = nil
    if keepAwakeEndDate != nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tickKeepAwake() }
      }
      keepAwakeTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    startKeepAwakeUserActivityTimer()
  }

  private func startKeepAwakeUserActivityTimer() {
    keepAwakeUserActivityTimer?.invalidate()
    keepAwakeUserActivityTimer = nil
    guard keepAwakeEnabled, keepAwakePreventDisplaySleep else {
      releaseKeepAwakeUserActivity()
      return
    }

    declareKeepAwakeUserActivity()
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.declareKeepAwakeUserActivity() }
    }
    keepAwakeUserActivityTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func declareKeepAwakeUserActivity() {
    guard keepAwakeEnabled, keepAwakePreventDisplaySleep else { return }
    var assertionID = keepAwakeUserActivityID ?? IOPMAssertionID(0)
    let result = IOPMAssertionDeclareUserActivity(
      "小龙哥Mac哲学：不锁屏 / 不进屏保。" as CFString,
      kIOPMUserActiveLocal,
      &assertionID
    )
    if result == kIOReturnSuccess {
      keepAwakeUserActivityID = assertionID
    }
  }

  private func releaseKeepAwakeUserActivity() {
    if let keepAwakeUserActivityID {
      IOPMAssertionRelease(keepAwakeUserActivityID)
      self.keepAwakeUserActivityID = nil
    }
  }

  private func tickKeepAwake() {
    if let keepAwakeEndDate, Date() >= keepAwakeEndDate {
      stopKeepAwake()
      statusMessage = "保持唤醒已到时，已恢复系统睡眠。"
      return
    }
    refreshKeepAwakeStatusText()
    notifySleepStatusItemChanged()
  }

  private func refreshKeepAwakeStatusText() {
    guard keepAwakeEnabled else {
      keepAwakeStatusText = "未开启"
      return
    }
    guard let keepAwakeEndDate else {
      keepAwakeStatusText = "无限期"
      return
    }
    let remaining = max(0, Int(ceil(keepAwakeEndDate.timeIntervalSinceNow)))
    let hours = remaining / 3600
    let minutes = (remaining % 3600) / 60
    let seconds = remaining % 60
    if hours > 0 {
      keepAwakeStatusText = "剩余 \(hours) 小时 \(minutes) 分"
    } else if minutes > 0 {
      keepAwakeStatusText = "剩余 \(minutes) 分 \(seconds) 秒"
    } else {
      keepAwakeStatusText = "剩余 \(seconds) 秒"
    }
  }

  var panelHotkeySummary: String {
    "无键盘绑定"
  }

  var panelHotkeyItemID: String? {
    nil
  }

  var launcherHotkeySummary: String {
    guard launcherPluginEnabled else { return "已关闭" }
    let externallyBlocked = hotkeyFailures.contains {
      $0.contains("小龙哥启动器") && $0.contains("未抢占")
    }
    return shortcutSemanticAnalysis.capsSpaceConflicts.isEmpty && !externallyBlocked
      ? "Caps + Space" : "统一启动键未启用"
  }

  var launcherHotkeyItemID: String? {
    nil
  }

  func statusMenuShortcutLabels(for action: ShortcutAction) -> [String] {
    var labels = enabledShortcutMenuLabels(for: action, in: items)
    if action == .showLauncher, launcherHotkeySummary == "Caps + Space" {
      labels.insert("Caps + Space", at: 0)
    }
    var seen: Set<String> = []
    return labels.filter { seen.insert($0).inserted }
  }

  var shortcutSemanticAnalysis: ShortcutSemanticAnalysis {
    ShortcutSemanticMigration.analyze(items)
  }

  var shortcutSemanticCapsDecisionPending: Bool {
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    guard !conflicts.isEmpty else { return false }
    return UserDefaults.standard.string(forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
      != ShortcutSemanticMigration.conflictFingerprint(conflicts)
  }

  var shortcutSemanticCommandDecisionPending: Bool {
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    guard !conflicts.isEmpty else { return false }
    return UserDefaults.standard.string(forKey: Self.shortcutSemanticCommandChoiceDefaultsKey)
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

  private var sleepHotkeyItem: ShortcutItem? {
    items.first(where: { $0.action == .showSleepPanel })
  }

  private var sleepHotkeyItemID: String? {
    sleepHotkeyItem?.id
  }

  private var launcherFilterCacheKey = ""
  private var launcherFilterCacheResult: [LauncherApp] = []
  private var launcherDataRevision = 0

  var filteredLauncherApps: [LauncherApp] {
    let key = "\(launcherDataRevision)#\(launcherQuery)"
    if key == launcherFilterCacheKey { return launcherFilterCacheResult }
    let apps = AppLauncherScanner.filter(
      launcherApps,
      query: launcherQuery,
      history: launcherUsageHistory)
    let result =
      AppLauncherScanner.normalize(launcherQuery).isEmpty
      ? prioritizedLauncherApps(apps) : apps
    launcherFilterCacheKey = key
    launcherFilterCacheResult = result
    return result
  }

  var launcherResultApps: [LauncherApp] {
    guard AppLauncherScanner.normalize(launcherQuery).isEmpty else {
      return filteredLauncherApps
    }
    return LauncherPinnedResolver.excludingPinnedApps(
      filteredLauncherApps,
      records: launcherPinnedRecords)
  }

  var launcherPinnedItems: [ResolvedLauncherPinnedItem] {
    launcherPinnedRecords.map { record in
      ResolvedLauncherPinnedItem(record: record, app: resolvePinnedLauncherApp(record))
    }
  }

  var launcherHasEmptyQuery: Bool {
    AppLauncherScanner.normalize(launcherQuery).isEmpty
  }

  var launcherShortcutCount: Int {
    launcherOpenAppShortcutMap.count
  }

  var launcherCalculatorItem: LauncherUtilityItem? {
    LauncherCalculator.evaluate(launcherQuery)
  }

  var launcherUtilityItem: LauncherUtilityItem? {
    if let calculator = launcherCalculatorItem {
      return calculator
    }
    if filteredLauncherApps.isEmpty {
      return LauncherWebResolver.destination(for: launcherQuery, searchEngine: launcherSearchEngine)
    }
    return nil
  }

  var pluginItems: [ShortcutItem] {
    items.filter(isPluginShortcut)
  }

  var pluginCenterItemCount: Int {
    9
  }

  var mouseVolumePluginEnabled: Bool {
    scrollSettings.volumeHotCornerEnabled
  }

  var mouseScrollPreset: MouseScrollPreset {
    if scrollSettings.step >= 40 || scrollSettings.speed >= 3.2 {
      return .fast
    }
    if scrollSettings.smooth {
      return .natural
    }
    return .stable
  }

  var systemPreferredItems: [ShortcutItem] {
    items.filter(isPluginShortcut)
  }

  func canRestorePluginShortcut(id: String) -> Bool {
    guard let item = items.first(where: { $0.id == id }) else { return false }
    return defaultPluginShortcut(matching: item) != nil
  }

  func restorePluginShortcut(id: String) {
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

  private func defaultPluginShortcut(matching item: ShortcutItem) -> ShortcutItem? {
    defaultShortcuts().first {
      isPluginShortcut($0)
        && ($0.name == item.name
          || (!$0.target.isEmpty && $0.action == item.action && $0.target == item.target))
    }
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

  var dockIdentityText: String {
    dockIconVisible ? "程序坞已显示" : "仅菜单栏"
  }

  var scrollEngineText: String {
    if scrollSettings.enabled {
      return scrollEngineRunning ? "滚动运行中" : "滚动未运行"
    }
    if scrollSettings.volumeHotCornerEnabled {
      return "状态栏音量已启用"
    }
    return "未运行"
  }

  var diagnosticsLogPath: String {
    AppDiagnostics.logURL.path
  }

  func setDiagnosticsEnabled(_ enabled: Bool) {
    diagnosticsEnabled = enabled
    AppDiagnostics.setEnabled(enabled)
    statusMessage = enabled ? "诊断日志已开启。" : "诊断日志已关闭。"
  }

  func startSystemMonitor() {
    refreshSystemMonitorSnapshot()
    guard systemMonitorTimer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshSystemMonitorSnapshot() }
    }
    RunLoop.main.add(timer, forMode: .common)
    systemMonitorTimer = timer
  }

  func stopSystemMonitor() {
    systemMonitorTimer?.invalidate()
    systemMonitorTimer = nil
  }

  func refreshSystemMonitorSnapshot() {
    systemMonitorSnapshot = systemMonitor.sample()
  }

  func startKeepAwake(minutes: Int) {
    keepAwakeEndDate = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
    keepAwakeEnabled = true
    applyKeepAwakeActivity()
    startKeepAwakeTimers()
    refreshKeepAwakeStatusText()
    notifySleepStatusItemChanged()
    statusMessage = keepAwakeEndDate == nil ? "保持唤醒已开启：无限期。" : "保持唤醒已开启：\(keepAwakeStatusText)。"
  }

  func startKeepAwakeCustomHours() {
    startKeepAwake(minutes: keepAwakeCustomHours * 60)
  }

  func toggleInfiniteKeepAwake() {
    if keepAwakeEnabled && keepAwakeEndDate == nil {
      stopKeepAwake()
    } else {
      startKeepAwake(minutes: 0)
    }
  }

  func stopKeepAwake(resetStatus: Bool = true) {
    keepAwakeTimer?.invalidate()
    keepAwakeTimer = nil
    keepAwakeUserActivityTimer?.invalidate()
    keepAwakeUserActivityTimer = nil
    releaseKeepAwakeUserActivity()
    keepAwakeEndDate = nil
    if let keepAwakeActivity {
      ProcessInfo.processInfo.endActivity(keepAwakeActivity)
      self.keepAwakeActivity = nil
    }
    keepAwakeEnabled = false
    keepAwakeStatusText = "未开启"
    notifySleepStatusItemChanged()
    if resetStatus {
      statusMessage = "保持唤醒已关闭。"
    }
  }

  func setKeepAwakePreventDisplaySleep(_ enabled: Bool) {
    keepAwakePreventDisplaySleep = enabled
    UserDefaults.standard.set(enabled, forKey: Self.keepAwakePreventDisplaySleepDefaultsKey)
    if keepAwakeEnabled {
      applyKeepAwakeActivity()
      startKeepAwakeTimers()
      refreshKeepAwakeStatusText()
      notifySleepStatusItemChanged()
      statusMessage = enabled ? "保持唤醒时也会保持屏幕亮起。" : "保持唤醒时只阻止系统睡眠。"
    }
  }

  func setKeepAwakeCustomHours(_ hours: Int) {
    keepAwakeCustomHours = min(max(hours, 1), 12)
    UserDefaults.standard.set(keepAwakeCustomHours, forKey: Self.keepAwakeCustomHoursDefaultsKey)
  }

  func setSleepStatusItemVisible(_ visible: Bool) {
    sleepStatusItemVisible = visible
    UserDefaults.standard.set(visible, forKey: Self.sleepStatusItemVisibleDefaultsKey)
    notifySleepStatusItemChanged()
    statusMessage = visible ? "睡眠状态栏图标已显示。" : "睡眠状态栏图标已隐藏。"
  }

  func setDockIconVisible(_ visible: Bool) {
    guard visible != dockIconVisible else { return }
    guard DockPresencePreference.apply(visible: visible) else {
      statusMessage = visible ? "暂时无法在程序坞显示图标。" : "暂时无法从程序坞隐藏图标。"
      return
    }
    DockPresencePreference.save(visible)
    dockIconVisible = visible
    statusMessage =
      visible
      ? "已在程序坞显示图标；顶部菜单栏仍可使用。"
      : "已从程序坞隐藏图标；可从顶部菜单栏打开或完全退出。"
  }

  func isMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID) -> Bool {
    menuBarVisibleItemIDs.contains(itemID)
  }

  func setMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID, _ visible: Bool) {
    var next = menuBarVisibleItemIDs
    if visible {
      next.insert(itemID)
    } else {
      next.remove(itemID)
    }
    guard next != menuBarVisibleItemIDs else { return }
    menuBarVisibleItemIDs = next
    MenuBarCatalog.saveVisibleItemIDs(next)
    NotificationCenter.default.post(name: .menuBarConfigurationChanged, object: nil)
    statusMessage =
      visible
      ? "已在快捷菜单显示「\(menuBarCatalogTitle(itemID))」。" : "已从快捷菜单隐藏「\(menuBarCatalogTitle(itemID))」。"
  }

  func resetMenuBarCatalogVisibility() {
    let needsCatalogReset = menuBarVisibleItemIDs != MenuBarCatalog.defaultVisibleItemIDs
    let needsSleepItemReset = !sleepStatusItemVisible
    let needsDockReset = dockIconVisible
    let needsStatusContentReset =
      !networkSpeedShowMemory
      || networkSpeedShowCPU
      || networkSpeedShowGPU
    guard needsCatalogReset || needsSleepItemReset || needsDockReset || needsStatusContentReset
    else {
      return
    }
    menuBarVisibleItemIDs = MenuBarCatalog.defaultVisibleItemIDs
    MenuBarCatalog.saveVisibleItemIDs(menuBarVisibleItemIDs)
    sleepStatusItemVisible = true
    UserDefaults.standard.set(true, forKey: Self.sleepStatusItemVisibleDefaultsKey)
    if needsDockReset, DockPresencePreference.apply(visible: false) {
      DockPresencePreference.save(false)
      dockIconVisible = false
    }
    networkSpeedShowMemory = true
    networkSpeedShowCPU = false
    networkSpeedShowGPU = false
    UserDefaults.standard.set(true, forKey: Self.networkSpeedShowMemoryDefaultsKey)
    UserDefaults.standard.set(false, forKey: Self.networkSpeedShowCPUDefaultsKey)
    UserDefaults.standard.set(false, forKey: Self.networkSpeedShowGPUDefaultsKey)
    NotificationCenter.default.post(name: .menuBarConfigurationChanged, object: nil)
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    notifySleepStatusItemChanged()
    statusMessage = "菜单栏图标、状态内容和快捷入口已恢复默认。"
  }

  func presentMenuBarCustomization() {
    isMenuBarCustomizationPresented = true
    presentWindowHandler?()
  }

  private func menuBarCatalogTitle(_ itemID: MenuBarCatalogItemID) -> String {
    MenuBarCatalog.items.first(where: { $0.id == itemID })?.title ?? itemID.rawValue
  }

  private func notifySleepStatusItemChanged() {
    NotificationCenter.default.post(name: .sleepStatusItemChanged, object: nil)
  }

  var isSettingsPresented: Bool {
    selectedModuleName == "关于"
  }

  func showSettings(section: String? = nil) {
    selectedAboutSection = SettingsNavigationPolicy.normalized(section ?? selectedAboutSection)
    selectedModuleName = "关于"
  }

  func requestCreateShortcut() {
    selectedModuleName = "功能快捷键"
    shortcutCreateRequestID &+= 1
  }

  func runPrimaryUpdateAction() {
    if latestUpdate == nil {
      checkForUpdates()
    } else {
      installLatestUpdate()
    }
  }

  func checkForUpdatesIfNeeded() {
    guard runtimeIdentity.allowsOnlineUpdates else {
      updateServerVersionText = "不可用"
      updateStatusText = "运行身份无效，更新已停用。"
      return
    }
    // Sparkle owns both scheduled discovery and installation from Build 182 onward.
    guard !usesSparkleUpdater else { return }
    guard !isUpdateBusy else { return }
    guard updateFailureMessage == nil else { return }
    let now = Date()
    let savedLastCheckInterval = UserDefaults.standard.double(forKey: Self.autoUpdateCheckKey)
    var savedLastCheck: Date?
    if savedLastCheckInterval > 0 {
      savedLastCheck = Date(timeIntervalSince1970: savedLastCheckInterval)
    }
    let lastCheck = lastAutomaticUpdateCheckAt ?? savedLastCheck
    if let lastCheck, now.timeIntervalSince(lastCheck) < automaticUpdateCheckInterval {
      return
    }
    lastAutomaticUpdateCheckAt = now
    UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.autoUpdateCheckKey)
    checkForUpdates(announcesResult: false)
  }

  func showReleaseNoteIfNeeded() {
    guard pendingReleaseNote == nil, !isReleaseNotePresented else { return }
    guard let note = ReleaseNotes.entry(forBuild: currentBuildNumber) else { return }
    let lastSeenBuild = UserDefaults.standard.integer(
      forKey: Self.lastSeenReleaseNotesBuildDefaultsKey)
    guard lastSeenBuild < note.build else { return }
    pendingReleaseNote = note
    isReleaseNotePresented = true
  }

  func markReleaseNoteSeen() {
    if let pendingReleaseNote {
      UserDefaults.standard.set(
        pendingReleaseNote.build,
        forKey: Self.lastSeenReleaseNotesBuildDefaultsKey
      )
    }
    pendingReleaseNote = nil
    isReleaseNotePresented = false
  }

  func openReleaseNotesChangelog() {
    let url = pendingReleaseNote?.changelogURL ?? ReleaseNotes.fallbackChangelogURL
    NSWorkspace.shared.open(url)
  }

  func checkForUpdates() {
    checkForUpdates(announcesResult: true)
  }

  private func checkForUpdates(announcesResult: Bool) {
    guard runtimeIdentity.allowsOnlineUpdates else {
      latestUpdate = nil
      needsUpdateAuthorizationRecheck = false
      updateServerVersionText = "不可用"
      updateStatusText = "运行身份无效，更新已停用。"
      updateReleaseDetailText = ""
      updateDownloadProgress = nil
      if announcesResult { statusMessage = updateStatusText }
      return
    }
    if usesSparkleUpdater {
      latestUpdate = nil
      updateFailureMessage = nil
      updateServerVersionText = "检查中"
      updateStatusText = "正在检查更新..."
      guard let sparkleCheckForUpdatesHandler else {
        handleSparkleUpdateState(.failed(message: "更新组件尚未就绪，请稍后再试。"))
        return
      }
      sparkleCheckForUpdatesHandler()
      return
    }
    guard !isUpdateBusy else { return }
    if announcesResult {
      updateFailureMessage = nil
    }
    isUpdateBusy = true
    stagedUpdate = nil
    updateServerVersionText = "检查中"
    updateStatusText = "正在检查更新..."
    updateDownloadProgress = nil
    AppUpdater.shared.checkForUpdate(bypassingCache: announcesResult) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isUpdateBusy = false
        switch result {
        case .success(let manifest):
          self.updateFailureMessage = nil
          self.updateServerVersionText = manifest.displayVersion
          let currentVersion = self.appVersionText
          self.updateReleaseDetailText = self.updateReleaseDetailText(for: manifest)
          if AppUpdater.shared.isNewer(manifest, thanCurrentBuild: self.currentBuildNumber) {
            let authorization = UpdateReleasePolicy.decision(
              publishedAt: manifest.publishedAt)
            if let denial = authorization.denialMessage {
              self.latestUpdate = nil
              self.needsUpdateAuthorizationRecheck = true
              self.updateStatusText =
                "发现新版 \(manifest.displayVersion)，但当前更新权不包含这个版本。"
              self.statusMessage = denial
            } else {
              self.latestUpdate = manifest
              self.needsUpdateAuthorizationRecheck = false
              self.updateStatusText = "发现新版：当前 \(currentVersion)，线上 \(manifest.displayVersion)。"
              self.statusMessage = "发现新版 \(manifest.displayVersion)，可下载并校验更新包。"
            }
          } else {
            self.latestUpdate = nil
            self.needsUpdateAuthorizationRecheck = false
            self.updateStatusText = "已是最新版：当前 \(currentVersion)，线上 \(manifest.displayVersion)。"
            if announcesResult {
              self.statusMessage = "当前已是最新版。"
            }
          }
        case .failure(let error):
          AppDiagnostics.log(
            "update_check_failed",
            [
              "source": announcesResult ? "manual" : "automatic",
              "error": error.localizedDescription,
            ])
          if let latestUpdate = self.latestUpdate {
            self.updateServerVersionText = latestUpdate.displayVersion
            self.updateStatusText =
              "暂时无法重新检查，仍保留已发现的 \(latestUpdate.displayVersion)。"
          } else {
            self.updateServerVersionText = announcesResult ? "暂不可用" : "未检查"
            self.updateStatusText = announcesResult ? "暂时无法检查更新。" : "未检查"
            self.updateReleaseDetailText = ""
          }
          self.updateDownloadProgress = nil
          if announcesResult {
            let detail = AppUpdaterError.customerDescription(
              for: error,
              fallback: "暂时无法连接或读取更新信息，请稍后重试。")
            self.statusMessage = "检查更新失败：\(detail)"
          }
        }
      }
    }
  }

  private func updateReleaseDetailText(for manifest: AppUpdateManifest) -> String {
    var lines = ["通道：\(manifest.channel)"]
    if !manifest.publishedAt.isEmpty {
      lines.append("发布时间：\(manifest.publishedAt)")
    }
    if !manifest.notes.isEmpty {
      lines.append("更新说明：\(manifest.notes)")
    }
    return lines.joined(separator: "\n")
  }

  func installLatestUpdate() {
    guard runtimeIdentity.allowsOnlineUpdates else {
      updateStatusText = "运行身份无效，更新与安装已停用。"
      statusMessage = updateStatusText
      return
    }
    if usesSparkleUpdater {
      checkForUpdates()
      return
    }
    guard !isUpdateBusy else { return }
    guard let latestUpdate else {
      checkForUpdates()
      return
    }
    guard reconcileDetectedUpdateAuthorization() else { return }
    beginInstallingUpdate(latestUpdate)
  }

  @discardableResult
  private func reconcileDetectedUpdateAuthorization() -> Bool {
    guard let latestUpdate else { return true }
    let authorization = UpdateReleasePolicy.decision(
      publishedAt: latestUpdate.publishedAt)
    guard let denial = authorization.denialMessage else { return true }
    self.latestUpdate = nil
    needsUpdateAuthorizationRecheck = true
    updateStatusText =
      "发现新版 \(latestUpdate.displayVersion)，但当前更新权不包含这个版本。"
    statusMessage = denial
    return false
  }

  private func beginInstallingUpdate(_ latestUpdate: AppUpdateManifest) {
    isUpdateBusy = true
    updateFailureMessage = nil
    updateDownloadProgress = nil
    updateStatusText = "正在下载 \(latestUpdate.displayVersion)..."
    statusMessage = "正在下载更新包..."
    AppUpdater.shared.downloadAndStage(
      manifest: latestUpdate,
      eligibilityCheck: { publishedAt in
        UpdateReleasePolicy.decision(publishedAt: publishedAt).isAllowed
      },
      eventHandler: { [weak self] event in
        DispatchQueue.main.async {
          guard let self, self.isUpdateBusy else { return }
          switch event {
          case .downloading(let progress):
            self.updateDownloadProgress = progress.fractionCompleted
            self.updateStatusText = self.downloadStatusText(
              progress,
              version: latestUpdate.displayVersion)
          case .verifying:
            self.updateDownloadProgress = nil
            self.updateStatusText = "正在校验 \(latestUpdate.displayVersion)..."
            self.statusMessage = "正在核对更新包完整性和 macOS 安全认证。"
          }
        }
      },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          guard let self else { return }
          switch result {
          case .success(let staged):
            self.stagedUpdate = staged
            self.updateDownloadProgress = nil
            self.updateStatusText = "正在安装 \(staged.manifest.displayVersion)..."
            self.statusMessage = "更新包已验证，正在准备安全替换。"
            AppUpdater.shared.installStagedUpdate(
              staged,
              eligibilityCheck: { verifiedPublishedAt in
                UpdateReleasePolicy.decision(
                  publishedAt: verifiedPublishedAt
                ).isAllowed
              },
              eventHandler: { [weak self] event in
                DispatchQueue.main.async {
                  guard let self, self.isUpdateBusy else { return }
                  switch event {
                  case .requestingAuthorization:
                    self.updateStatusText = "等待确认替换“应用程序”中的旧版本..."
                    self.statusMessage = "请在 macOS 提示中确认本次软件更新。"
                  case .replacing:
                    self.updateStatusText = "正在安全替换 \(staged.manifest.displayVersion)..."
                    self.statusMessage = "正在替换并复验 App；完成前不会退出当前版本。"
                  }
                }
              },
              completion: { [weak self] installResult in
                DispatchQueue.main.async {
                  guard let self else { return }
                  switch installResult {
                  case .success(let installed):
                    do {
                      try AppUpdater.shared.launchRelaunchAfterInstall(installed)
                      self.updateStatusText = "更新已安装，即将重启..."
                      self.statusMessage = "新版本已通过安装后校验，即将重启。"
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.terminate(nil)
                      }
                    } catch {
                      AppDiagnostics.log(
                        "update_relaunch_failed",
                        ["error": error.localizedDescription])
                      self.isUpdateBusy = false
                      self.latestUpdate = nil
                      self.stagedUpdate = nil
                      self.updateFailureMessage =
                        "新版本已安装，但自动重启失败。请退出 App，再从“应用程序”重新打开。"
                      self.updateStatusText = self.updateFailureMessage ?? "新版本已安装。"
                      self.statusMessage = self.updateStatusText
                    }
                  case .failure(let error):
                    self.finishUpdateFailure(error)
                  }
                }
              })
          case .failure(let error):
            self.finishUpdateFailure(error)
          }
        }
      })
  }

  func handleSparkleUpdateState(_ state: SparkleUpdateState) {
    guard usesSparkleUpdater else { return }
    latestUpdate = nil
    updateDownloadProgress = nil
    isUpdateBusy = false
    switch state {
    case .ready:
      if updateStatusText == "未检查" {
        updateStatusText = "自动检查已开启。"
      }
    case .checking:
      isUpdateBusy = true
      updateFailureMessage = nil
      updateServerVersionText = "检查中"
      updateStatusText = "正在检查更新..."
    case .found(let displayVersion):
      updateFailureMessage = nil
      updateServerVersionText = displayVersion
      updateStatusText = "发现新版 \(displayVersion)，请在更新窗口中确认。"
      statusMessage = "发现新版 \(displayVersion)。"
    case .aheadOfRelease(let displayVersion):
      updateFailureMessage = nil
      updateServerVersionText = displayVersion ?? "暂未确认"
      updateStatusText = "当前版本高于已发布版本，无需降级。"
      statusMessage = updateStatusText
    case .current:
      updateFailureMessage = nil
      updateServerVersionText = appVersionText
      updateStatusText = "已是最新版：当前 \(appVersionText)。"
      statusMessage = "当前已是最新版。"
    case .failed(let message):
      updateServerVersionText = "暂不可用"
      updateFailureMessage = message
      updateStatusText = message
      statusMessage = message
    }
  }

  private func finishUpdateFailure(_ error: Error) {
    isUpdateBusy = false
    updateDownloadProgress = nil
    stagedUpdate = nil
    latestUpdate = nil
    needsUpdateAuthorizationRecheck = false
    AppDiagnostics.log(
      "update_install_failed",
      [
        "type": String(reflecting: type(of: error)),
        "error": error.localizedDescription,
      ])
    let detail = AppUpdaterError.customerDescription(
      for: error,
      fallback:
        "更新包处理失败，已停止本次更新。当前版本保持不变；如仍失败，请从官网下载正式版覆盖一次。")
    let suffix = detail.contains("当前版本") ? "" : " 当前版本未被替换。"
    let message = "更新失败：\(detail)\(suffix) 请确认后手动重试。"
    updateFailureMessage = message
    updateStatusText = message
    statusMessage = message
  }

  private func downloadStatusText(
    _ progress: AppUpdateDownloadProgress,
    version: String
  ) -> String {
    let written = ByteCountFormatter.string(
      fromByteCount: progress.bytesWritten,
      countStyle: .file)
    guard let expectedBytes = progress.expectedBytes,
      let fraction = progress.fractionCompleted
    else {
      return "正在下载 \(version)：\(written)"
    }
    let expected = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    let percent = Int((fraction * 100).rounded(.down))
    return "正在下载 \(version)：\(percent)%（\(written) / \(expected)）"
  }

  func showPhraseWindow() {
    selectPlugin(id: Self.phrasesPluginID)
    selectedModuleName = "插件中心"
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

  func prepareLauncherPresentation() {
    launcherQuery = ""
    launcherSelectedResultID = nil
    launcherOpenDidMarkFirstResults = false
    launcherOpenToken = LauncherPerformance.beginOpen(
      isWarm: !launcherApps.isEmpty,
      cachedCount: launcherApps.count)
    launcherFocusRequestID &+= 1
    ensureLauncherAppsReady()
  }

  func selectPlugin(id: String?) {
    selectedPluginID = id
    if let id {
      pluginCenterScrollAnchorID = id
    }
  }

  func showLauncherPluginDetails() {
    selectPlugin(id: Self.launcherPluginID)
    selectedModuleName = "插件中心"
    presentWindowHandler?()
  }

  func setLauncherPluginEnabled(_ enabled: Bool) {
    launcherPluginEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.launcherPluginEnabledDefaultsKey)
    reloadHotkeys()
    statusMessage =
      enabled
      ? "启动器插件已开启；固定项目、显示偏好和索引保持不变。"
      : "启动器插件已关闭；Caps + Space 已停用，固定项目和设置仍保留。"
  }

  func setLauncherDisplayMode(_ mode: LauncherDisplayMode) {
    guard launcherDisplayMode != mode else { return }
    launcherDisplayMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: Self.launcherDisplayModeDefaultsKey)
    LauncherPerformance.markPresentationChange(
      kind: "displayMode",
      value: mode.rawValue,
      resultCount: launcherResultApps.count)
  }

  func setLauncherShowsPinnedNames(_ showsNames: Bool) {
    guard launcherShowsPinnedNames != showsNames else { return }
    launcherShowsPinnedNames = showsNames
    UserDefaults.standard.set(showsNames, forKey: Self.launcherShowsPinnedNamesDefaultsKey)
    LauncherPerformance.markPresentationChange(
      kind: "pinnedNames",
      value: showsNames ? "shown" : "hidden",
      resultCount: launcherResultApps.count)
  }

  func markLauncherInteractive() {
    guard let launcherOpenToken else { return }
    LauncherPerformance.markInteractive(launcherOpenToken)
  }

  func markLauncherFirstResultsIfAvailable(source: String) {
    guard !launcherOpenDidMarkFirstResults, let launcherOpenToken else { return }
    let count = launcherResultApps.count + (launcherUtilityItem == nil ? 0 : 1)
    guard count > 0 || !launcherScanInProgress else { return }
    launcherOpenDidMarkFirstResults = true
    LauncherPerformance.endOpen(launcherOpenToken, resultCount: count, source: source)
    self.launcherOpenToken = nil
  }

  func showAIPlayer() {
    aiPlayer.start()
    showAIPlayerHandler?()
  }

  func undoAIPlayerTrash() {
    aiPlayerStorage?.undoTrash()
  }

  func stopAIPlayerIfLoaded() {
    aiPlayerStorage?.stop()
  }

  func showYoumuFeature() {
    guard hasGlobalInputOwnership else {
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    guard let showYoumuFeatureHandler else {
      statusMessage = "游目原生模块尚未载入当前构建。"
      return
    }
    showYoumuFeatureHandler()
  }

  func openYoumuControlCenter() {
    guard let openYoumuControlCenterHandler else {
      statusMessage = "游目控制窗口尚未载入当前构建。"
      return
    }
    openYoumuControlCenterHandler()
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
      statusMessage = "披卷原生模块尚未载入当前构建。"
      return
    }
    showPijuanPDFFeatureHandler()
  }

  func openPijuanPDFDocument(_ url: URL) {
    guard let openPijuanPDFDocumentHandler else {
      statusMessage = "披卷原生模块尚未载入当前构建，未打开文件。"
      return
    }
    openPijuanPDFDocumentHandler(url.standardizedFileURL)
  }

  func openAudioFilesInAIPlayer(_ urls: [URL]) {
    let files = urls.map(\.standardizedFileURL)
    guard !files.isEmpty else { return }
    aiPlayer.start()
    aiPlayer.addFiles(files, playFirst: true)
    showAIPlayerHandler?()
  }

  @MainActor
  func refreshFileAssociationStatus() {
    guard fileAssociationChangesAllowed else {
      pdfFileAssociationCoverage = .none
      audioFileAssociationCoverage = .none
      pdfFileAssociationCanRestore = false
      audioFileAssociationCanRestore = false
      fileAssociationFeedbackText = "只有官网正式版安装到“应用程序”后才能设置；当前运行身份不会改动系统默认打开方式。"
      return
    }

    do {
      let manager = try fileAssociationManager()
      let pdf = try manager.currentStatus(for: .pdf)
      let audio = try manager.currentStatus(for: .audio)
      pdfFileAssociationCoverage = pdf.coverage
      audioFileAssociationCoverage = audio.coverage
      pdfFileAssociationCanRestore = pdf.canRestorePreviousHandler
      audioFileAssociationCanRestore = audio.canRestorePreviousHandler
      if fileAssociationFeedbackText.hasPrefix("安装到") {
        fileAssociationFeedbackText = ""
      }
    } catch {
      fileAssociationFeedbackText = error.localizedDescription
    }
  }

  @MainActor
  func setAsDefaultApplication(for kind: AssociatedFileKind) {
    guard fileAssociationBusyKind == nil else { return }
    guard fileAssociationChangesAllowed else {
      refreshFileAssociationStatus()
      return
    }

    fileAssociationBusyKind = kind
    fileAssociationFeedbackKind = kind
    fileAssociationFeedbackText = "正在请求 macOS 更新\(kind.displayName)打开方式…"
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.fileAssociationBusyKind = nil }
      do {
        let manager = try self.fileAssociationManager()
        switch kind {
        case .pdf:
          manager.pdfRoute = .pijuanReading
        case .audio:
          manager.audioRoute = .tinglan
        }
        let result = try await manager.setAsDefault(for: kind)
        self.fileAssociationFeedbackText =
          result.changedContentTypeIdentifiers.isEmpty
          ? "\(kind.displayName) 已经由本 App 打开。"
          : "已设为 \(kind.displayName) 默认打开方式；原应用已安全记住，可随时恢复。"
        self.refreshFileAssociationStatus()
        self.statusMessage = self.fileAssociationFeedbackText
      } catch {
        self.fileAssociationFeedbackText = error.localizedDescription
        self.statusMessage = self.fileAssociationFeedbackText
      }
    }
  }

  @MainActor
  func restorePreviousDefaultApplication(for kind: AssociatedFileKind) {
    guard fileAssociationBusyKind == nil else { return }
    guard fileAssociationChangesAllowed else {
      refreshFileAssociationStatus()
      return
    }

    fileAssociationBusyKind = kind
    fileAssociationFeedbackKind = kind
    fileAssociationFeedbackText = "正在恢复\(kind.displayName)原来的打开方式…"
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.fileAssociationBusyKind = nil }
      do {
        let manager = try self.fileAssociationManager()
        _ = try await manager.restorePreviousHandler(for: kind)
        self.fileAssociationFeedbackText = "已恢复 \(kind.displayName) 原来的默认打开方式。"
        self.refreshFileAssociationStatus()
        self.statusMessage = self.fileAssociationFeedbackText
      } catch {
        self.fileAssociationFeedbackText = error.localizedDescription
        self.statusMessage = self.fileAssociationFeedbackText
      }
    }
  }

  @MainActor
  private func fileAssociationManager() throws -> FileAssociationManager {
    if let fileAssociationManagerStorage {
      return fileAssociationManagerStorage
    }
    let manager = try FileAssociationManager()
    fileAssociationManagerStorage = manager
    return manager
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

  func ensureLauncherAppsReady() {
    if launcherApps.isEmpty {
      loadLauncherIndexIfAvailable()
    }
    if launcherApps.isEmpty || AppLauncherScanner.shouldRefreshIndex(launcherIndex) {
      refreshLauncherApps(force: false)
    }
  }

  func refreshLauncherApps() {
    refreshLauncherApps(force: true)
  }

  private func refreshLauncherApps(force: Bool) {
    guard !launcherScanInProgress else { return }
    if !force, !AppLauncherScanner.shouldRefreshIndex(launcherIndex) {
      return
    }
    launcherScanInProgress = true
    isLauncherScanning = true
    let cachedApps = launcherApps
    let scanToken = LauncherPerformance.beginScan(cachedCount: cachedApps.count, forced: force)
    let hadCachedApps = !launcherApps.isEmpty
    if hadCachedApps {
      isLauncherScanning = false
      statusMessage = force ? "正在后台重建启动器索引..." : "正在后台更新启动器索引..."
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let apps = AppLauncherScanner.scan(cachedApps: cachedApps)
      AppLauncherScanner.saveIndex(apps, to: self.launcherIndexURL)
      let index = AppLauncherScanner.loadIndex(from: self.launcherIndexURL)
      LauncherPerformance.endScan(scanToken, resultCount: apps.count)
      DispatchQueue.main.async {
        self.launcherIndex = index
        self.launcherApps = apps
        self.launcherDataRevision += 1
        self.pruneLauncherUsageHistoryIfNeeded()
        self.isLauncherScanning = false
        self.launcherScanInProgress = false
        self.statusMessage = "启动器结果已更新。"
        self.markLauncherFirstResultsIfAvailable(source: "refresh")
      }
    }
  }

  private func loadLauncherIndexIfAvailable() {
    guard let index = AppLauncherScanner.loadIndex(from: launcherIndexURL) else { return }
    let apps = AppLauncherScanner.cachedApps(from: index)
    launcherIndex = index
    guard !apps.isEmpty else { return }
    launcherApps = apps
    launcherDataRevision += 1
    pruneLauncherUsageHistoryIfNeeded()
    statusMessage = "启动器已载入固定索引 \(apps.count) 个 App。"
  }

  private func loadLauncherUsageHistory() {
    launcherUsageHistory = LauncherUsageHistory.load(from: launcherHistoryURL)
    launcherDataRevision += 1
  }

  private func saveLauncherUsageHistory() {
    launcherUsageHistory.save(to: launcherHistoryURL)
  }

  private func loadLauncherPinnedItems() {
    let collection = LauncherPinnedCollection.load(from: launcherPinnedURL)
    var seenIDs = Set<String>()
    launcherPinnedRecords = collection.items.filter { record in
      !record.id.isEmpty && seenIDs.insert(record.id).inserted
    }
  }

  private func saveLauncherPinnedItems() {
    LauncherPinnedCollection(
      version: LauncherPinnedCollection.currentVersion,
      items: launcherPinnedRecords
    ).save(to: launcherPinnedURL)
  }

  func isLauncherAppPinned(_ app: LauncherApp) -> Bool {
    let id = LauncherPinnedRecord.stableAppID(for: app)
    return launcherPinnedRecords.contains(where: { $0.id == id })
  }

  var isAIPlayerPinnedInLauncher: Bool {
    launcherPinnedRecords.contains(where: { $0.id == LauncherPinnedRecord.aiPlayerBuiltInID })
  }

  @discardableResult
  func pinAIPlayerInLauncher() -> Bool {
    var collection = launcherPinnedCollection
    switch collection.insert(.aiPlayer) {
    case .alreadyPresent:
      announceLauncherPinnedStatus("听澜播放器已在快捷栏。")
      return true
    case .maximumReached:
      announceLauncherPinnedStatus("最多固定 8 项，请先取消一个。")
      return false
    case .inserted(let position):
      launcherPinnedRecords = collection.items
      saveLauncherPinnedItems()
      announceLauncherPinnedStatus("已添加听澜播放器，第 \(position) 项。")
      return true
    }
  }

  func setAIPlayerPinnedInLauncher(_ pinned: Bool) {
    if pinned {
      _ = pinAIPlayerInLauncher()
    } else {
      unpinLauncherItem(id: LauncherPinnedRecord.aiPlayerBuiltInID)
    }
  }

  @discardableResult
  func pinLauncherApp(_ app: LauncherApp) -> Bool {
    let record = LauncherPinnedRecord.app(app)
    var collection = launcherPinnedCollection
    switch collection.insert(record) {
    case .alreadyPresent:
      announceLauncherPinnedStatus("\(app.name) 已固定。")
      return true
    case .maximumReached:
      announceLauncherPinnedStatus("最多固定 8 项，请先取消一个。")
      return false
    case .inserted(let position):
      launcherPinnedRecords = collection.items
      saveLauncherPinnedItems()
      announceLauncherPinnedStatus("已固定 \(app.name)，第 \(position) 项。")
      return true
    }
  }

  func unpinLauncherApp(_ app: LauncherApp) {
    unpinLauncherItem(id: LauncherPinnedRecord.stableAppID(for: app))
  }

  func unpinLauncherItem(id: String) {
    var collection = launcherPinnedCollection
    guard let removed = collection.remove(id: id) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已取消固定 \(removed.displayName)。")
  }

  func reportUnavailableLauncherPinnedItem(_ item: ResolvedLauncherPinnedItem) {
    announceLauncherPinnedStatus("\(item.name) 已不可用，可移除固定。")
  }

  func canMoveLauncherPinnedItem(id: String, offset: Int) -> Bool {
    guard let index = launcherPinnedRecords.firstIndex(where: { $0.id == id }) else {
      return false
    }
    return launcherPinnedRecords.indices.contains(index + offset)
  }

  func moveLauncherPinnedItem(id: String, offset: Int) {
    var collection = launcherPinnedCollection
    guard let destination = collection.move(id: id, offset: offset) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已移动到第 \(destination + 1) 项。")
  }

  func moveLauncherPinnedItem(id: String, before targetID: String) {
    var collection = launcherPinnedCollection
    guard let target = collection.move(id: id, before: targetID) else { return }
    launcherPinnedRecords = collection.items
    saveLauncherPinnedItems()
    announceLauncherPinnedStatus("已移动到第 \(target + 1) 项。")
  }

  private func announceLauncherPinnedStatus(_ message: String) {
    launcherPinnedStatusText = message
    statusMessage = message
  }

  private func resolvePinnedLauncherApp(_ record: LauncherPinnedRecord) -> LauncherApp? {
    LauncherPinnedResolver.resolve(record, apps: launcherApps)
  }

  private var launcherPinnedCollection: LauncherPinnedCollection {
    LauncherPinnedCollection(
      version: LauncherPinnedCollection.currentVersion,
      items: launcherPinnedRecords
    )
  }

  private func pruneLauncherUsageHistoryIfNeeded() {
    if launcherUsageHistory.pruneUnavailableApps(launcherApps) {
      launcherDataRevision += 1
      saveLauncherUsageHistory()
    }
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
    let learningToken = launcherOpenLearning.beginOpen()
    openAppOrFolder(launcherTarget(for: app)) { [weak self] succeeded in
      guard let self,
        self.launcherOpenLearning.shouldRecord(token: learningToken, succeeded: true)
      else { return }
      guard succeeded else {
        self.statusMessage = "无法打开 \(app.name)，未记入使用排序。"
        return
      }
      self.recordLauncherOpen(app, query: matchedQuery)
      self.statusMessage = "已切换 \(app.name)。"
    }
  }

  private func recordLauncherOpen(_ app: LauncherApp, query: String) {
    launcherUsageHistory.recordOpen(app: app, query: query)
    launcherDataRevision += 1
    saveLauncherUsageHistory()
  }

  func openLauncherShortcutManager(for app: LauncherApp) {
    let target = launcherTarget(for: app)
    let normalizedTarget = normalizedOpenAppTarget(target) ?? target
    let requestedSearchText: String
    if let index = launcherShortcutItemIndex(forNormalizedTarget: normalizedTarget) {
      selectedID = items[index].id
      requestedSearchText = items[index].name
    } else {
      selectedID = nil
      requestedSearchText = app.name
    }
    selectedModuleName = "功能快捷键"
    shortcutGuideRequestedCategory = "软件类"
    shortcutGuideRequestedSearchText = requestedSearchText
    shortcutGuideFocusRequest &+= 1
    presentWindowHandler?()
    statusMessage =
      selectedID == nil
      ? "已打开功能快捷键；点“新增快捷键”为 \(app.name) 添加规则。"
      : "已在功能快捷键中找到 \(app.name) 的规则。"
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
    statusMessage = "正在彻底卸载 \(app.name)…"
    do {
      let engine = try makePermanentUninstallEngine()
      Task { @MainActor [weak self] in
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
        guard let self, self.launcherUninstallRequestID == requestID else { return }
        self.launcherUninstallRequestID = nil
        if outcome.didDeleteTargetApplication {
          self.reloadLauncherReferencesAfterPermanentUninstall(
            targetPath: review.target.path)
        }
        self.statusMessage = outcome.message
        if outcome.state == .blocked || outcome.state == .partialFailure {
          self.presentPermanentUninstallFailure(app: app, message: outcome.message)
        }
      }
    } catch {
      finishPermanentLauncherUninstallFailure(
        app: app,
        message: "无法启动彻底卸载：\(error.localizedDescription)")
    }
  }

  private func makePermanentUninstallEngine() throws -> SafeUninstallPermanentEngine {
    let base = fileURL.deletingLastPathComponent()
      .appendingPathComponent("safe-uninstall", isDirectory: true)
    return SafeUninstallPermanentEngine(
      files: SafeUninstallPermanentFileExecutor(),
      processes: SafeUninstallLiveProcessController(),
      references: try SafeUninstallLauncherReferenceStore(
        shortcutsURL: fileURL,
        historyURL: launcherHistoryURL,
        pinnedURL: launcherPinnedURL,
        snapshotDirectory: base.appendingPathComponent(
          "permanent-reference-snapshots", isDirectory: true)))
  }

  private func reloadLauncherReferencesAfterPermanentUninstall(targetPath: String) {
    if let decoded = try? ShortcutConfigurationCodec.load(from: fileURL) {
      items = decoded
      if let selectedID, !decoded.contains(where: { $0.id == selectedID }) {
        self.selectedID = decoded.first?.id
      }
      reloadHotkeys()
    }
    launcherUsageHistory = LauncherUsageHistory.load(from: launcherHistoryURL)
    loadLauncherPinnedItems()
    launcherDataRevision += 1
    let standardized = URL(fileURLWithPath: targetPath).standardizedFileURL.path
    launcherApps.removeAll { $0.url.standardizedFileURL.path == standardized }
    AppLauncherScanner.saveIndex(launcherApps, to: launcherIndexURL)
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

    // App 级 runModal 会阻断游目的跨窗口选区。异步 sheet 只约束当前窗口，
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
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    applyShortcutSemanticResolution(
      itemIDs: conflicts.map(\.id),
      reason: "user-adopt-caps-space-launcher",
      successMessage: "已停用并保留冲突项；Caps + Space 现在打开小龙哥启动器。")
  }

  func keepCurrentCapsSpaceBehavior() {
    let conflicts = shortcutSemanticAnalysis.capsSpaceConflicts
    guard !conflicts.isEmpty else { return }
    UserDefaults.standard.set(
      ShortcutSemanticMigration.conflictFingerprint(conflicts),
      forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
    shortcutSemanticMigrationMessage =
      "已保留现状。Caps + Space 仍由「\(conflicts.map(\.name).joined(separator: "、"))」使用，统一启动键未启用。"
  }

  func returnCommandSpaceToSystem() {
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    applyShortcutSemanticResolution(
      itemIDs: conflicts.map(\.id),
      reason: "user-return-command-space-to-system",
      successMessage: "本 App 已停止占用 Command + Space；没有修改 macOS 系统设置。")
  }

  func keepCurrentCommandSpaceBehavior() {
    let conflicts = shortcutSemanticAnalysis.commandSpaceConflicts
    guard !conflicts.isEmpty else { return }
    UserDefaults.standard.set(
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
    do {
      let backupURL = try ShortcutSemanticMigration.restoreLatestMigration(at: fileURL)
      let restoredItems = try ShortcutConfigurationCodec.load(from: fileURL)
      let officialFingerprint = ShortcutSemanticMigration.conflictFingerprint(
        ShortcutSemanticMigration.analyze(restoredItems).officialLegacyItems)
      UserDefaults.standard.set(officialFingerprint, forKey: Self.shortcutSemanticUndoDefaultsKey)
      load()
      reloadHotkeys()
      lastShortcutSemanticBackupURL = backupURL
      shortcutSemanticMigrationMessage = "已从备份恢复本 App 快捷键；没有修改 macOS 系统设置。"
    } catch {
      shortcutSemanticMigrationMessage = "未恢复：\(error.localizedDescription)"
    }
  }

  private func applyShortcutSemanticResolution(
    itemIDs: [String],
    reason: String,
    successMessage: String
  ) {
    guard !itemIDs.isEmpty else { return }
    do {
      let result = try ShortcutSemanticMigration.disableItems(
        at: fileURL,
        itemIDs: Set(itemIDs),
        reason: reason,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
      UserDefaults.standard.removeObject(forKey: Self.shortcutSemanticUndoDefaultsKey)
      UserDefaults.standard.removeObject(forKey: Self.shortcutSemanticCapsChoiceDefaultsKey)
      UserDefaults.standard.removeObject(forKey: Self.shortcutSemanticCommandChoiceDefaultsKey)
      load()
      try? ShortcutSemanticMigration.refreshLatestRecordMigratedSHA(at: fileURL)
      reloadHotkeys()
      lastShortcutSemanticBackupURL = result.backupURL
      shortcutSemanticMigrationMessage = successMessage
    } catch {
      shortcutSemanticMigrationMessage = "无法创建备份，未更改任何快捷键：\(error.localizedDescription)"
    }
  }

  func startSleepHotkeyRecording() {
    let itemID = ensureSleepHotkeyItem()
    selectedModuleName = "功能快捷键"
    selectedID = itemID
    enableAfterRecordingItemIDs.insert(itemID)
    presentWindowHandler?()
    startRecording(itemID: itemID)
    statusMessage = "正在设置睡眠快捷键：请直接按组合键。"
  }

  func openShortcutManager(action: ShortcutAction) {
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
    selectedModuleName = "功能快捷键"
    selectedID = itemID
    shortcutGuideRequestedCategory = "全部"
    shortcutGuideRequestedSearchText = ""
    shortcutGuideFocusRequest += 1
    presentWindowHandler?()
    statusMessage = "已切到功能快捷键，可在首页管理这条规则。"
  }

  func featureShortcutItemIDs(for commandID: String) -> [String] {
    items.filter { $0.commandID == commandID }.map(\.id)
  }

  func featureShortcutMenuLabel(for commandID: String) -> String? {
    let matchingItems = items.filter { $0.commandID == commandID }
    return matchingItems.first(where: \.enabled)?.displayHotkey
      ?? matchingItems.first?.displayHotkey
  }

  @discardableResult
  func ensureFeatureShortcutItem(commandID: String) -> String? {
    if let existing = items.first(where: { $0.commandID == commandID }) {
      return existing.id
    }
    guard let descriptor = YoumuFeatureShortcutCatalog.descriptor(for: commandID) else {
      statusMessage = "未知的游目命令，未新增快捷键。"
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
    guard let itemID = ensureFeatureShortcutItem(commandID: commandID) else { return }
    selectedModuleName = "功能快捷键"
    selectedID = itemID
    shortcutGuideRequestedCategory = "截图类"
    shortcutGuideRequestedSearchText = ""
    shortcutGuideFocusRequest &+= 1
    presentWindowHandler?()
    statusMessage = "已切到功能快捷键；这里和游目详情使用同一条规则。"
  }

  func openPijuanPDFShortcutManager() {
    selectedModuleName = "功能快捷键"
    selectedID = nil
    shortcutGuideRequestedCategory = "PDF类"
    shortcutGuideRequestedSearchText = ""
    shortcutGuideFocusRequest &+= 1
    presentWindowHandler?()
    statusMessage = "已切到功能快捷键；披卷快捷键统一在这里管理。"
  }

  func clearSleepHotkey() {
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

  private func ensureSleepHotkeyItem(enabledWhenCreated: Bool = false) -> String {
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

  private func ensureCodexNetworkProbeHotkeyItem(enabledWhenCreated: Bool = false) -> String {
    if let index = items.firstIndex(where: {
      $0.isBuiltIn != false && $0.action == .showCodexNetworkProbe
    }) {
      let wantedNote = "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
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
      note: "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
    )
    clearShortcutDeletionMarkers(for: item)
    items.append(item)
    selectedID = item.id
    saveOnly()
    return item.id
  }

  private func ensureCoreHotkeyItem(action: ShortcutAction) -> String? {
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
    selectedModuleName = "功能快捷键"
    selectedID = item.id
    saveAndReload()
    return item.id
  }

  private func ensureShortcutItemForManagement(action: ShortcutAction) -> String? {
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

  private func launcherTarget(for app: LauncherApp) -> String {
    app.bundleIdentifier.isEmpty ? app.path : "bundle:\(app.bundleIdentifier)"
  }

  func launcherShortcut(for app: LauncherApp) -> LauncherAppShortcut? {
    launcherOpenAppShortcutMap[launcherTargetKey(for: app)]
  }

  func isRecordingLauncherShortcut(for app: LauncherApp) -> Bool {
    guard let recordingItemID,
      let item = items.first(where: { $0.id == recordingItemID && $0.action == .openApp })
    else {
      return false
    }
    let targetKey = normalizedOpenAppTarget(item.target) ?? item.target
    return targetKey == launcherTargetKey(for: app)
  }

  private var launcherOpenAppShortcutMap: [String: LauncherAppShortcut] {
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

  private func prioritizedLauncherApps(_ apps: [LauncherApp]) -> [LauncherApp] {
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

  private func launcherShortcutItemIndex(forNormalizedTarget normalizedTarget: String) -> Int? {
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

  private func launcherTargetKey(for app: LauncherApp) -> String {
    if !app.bundleIdentifier.isEmpty {
      return "bundle:\(app.bundleIdentifier)"
    }
    return normalizedOpenAppTarget(app.path) ?? app.path
  }

  func load() {
    var semanticMigrationFailed = false
    var semanticMigrationChanged = false
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        let originalItems = try ShortcutConfigurationCodec.load(from: fileURL)
        let officialFingerprint = ShortcutSemanticMigration.conflictFingerprint(
          ShortcutSemanticMigration.analyze(originalItems).officialLegacyItems)
        let userUndidSameMigration =
          !officialFingerprint.isEmpty
          && UserDefaults.standard.string(forKey: Self.shortcutSemanticUndoDefaultsKey)
            == officialFingerprint
        if !userUndidSameMigration {
          do {
            let result = try ShortcutSemanticMigration.applyAutomaticMigrationIfNeeded(
              at: fileURL,
              build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown")
            if result.changed {
              semanticMigrationChanged = true
              lastShortcutSemanticBackupURL = result.backupURL
              shortcutSemanticMigrationMessage =
                "已停用可精确识别的官方旧默认；本 App 不再占用 Command + Space。"
              UserDefaults.standard.removeObject(forKey: Self.shortcutSemanticUndoDefaultsKey)
            }
          } catch {
            semanticMigrationFailed = true
            shortcutSemanticMigrationMessage = "无法创建备份，未更改任何快捷键。"
            statusMessage = "快捷键迁移未完成：\(error.localizedDescription)"
          }
        }
        items = try ShortcutConfigurationCodec.load(from: fileURL)
      } else {
        items = defaultShortcuts()
        markShortcutDefaultBaselineCurrent()
        saveOnly()
      }
      let needsCodexNetworkProbeShortcut = !items.contains {
        $0.action == .showCodexNetworkProbe
      }
      let needsClipboardHistoryShortcut = !items.contains {
        $0.action == .showClipboardHistory
      }
      let needsFeatureShortcutMerge = !missingDefaultFeatureShortcuts().isEmpty
      let needsRecoveryOwnershipRepair = hasLegacyRecoveryOwnershipRepair()
      let needsDuplicateShortcutIDRepair = hasDuplicateShortcutIDs()
      let needsDuplicateManagedIdentityRepair = hasDuplicateManagedShortcutIdentities()
      let needsBuiltInOwnershipMigration = items.contains { $0.isBuiltIn == nil }
      let needsShortcutDefaultBaselineMigration =
        UserDefaults.standard.integer(forKey: ShortcutDefaultBaseline.versionDefaultsKey)
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
          if !saveOnly() {
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
      statusMessage = "配置读取失败，已载入默认值：\(error.localizedDescription)"
    }
  }

  func loadPhrases() {
    do {
      try FileManager.default.createDirectory(
        at: phraseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: phraseURL.path) {
        phrases = try LocalConfigurationFileCodec.decodeArray(
          PhraseItem.self,
          from: phraseURL,
          allowedKeys: ["id", "trigger", "output", "enabled", "note"]
        ) { phrases in
          for phrase in phrases {
            guard phrase.id.utf8.count <= 256,
              phrase.trigger.utf8.count <= 256,
              phrase.output.utf8.count <= LocalConfigurationFileCodec.maximumStringBytes,
              phrase.note.utf8.count <= 32_768
            else { throw LocalConfigurationReadError.invalidRecord }
          }
        }
      } else {
        phrases = defaultPhrases()
        savePhrasesOnly()
      }
      selectedPhraseID = phrases.first?.id
    } catch {
      phrases = defaultPhrases()
      selectedPhraseID = phrases.first?.id
      statusMessage = "快捷短语读取失败，已载入默认值：\(error.localizedDescription)"
    }
  }

  private func repairCoreDefaultsAndMergeCommonRules() -> Bool {
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
      case "窗口最大化", "窗口化全屏":
        let wantedModifiers = ["control", "option"]
        let wantedNote = "Caps + F：窗口化全屏，保留 Dock 和顶部菜单栏/状态栏，左右上下 100% 铺满可用区域，再按一次恢复。"
        if items[index].name != "窗口化全屏"
          || items[index].scope != "窗口"
          || items[index].key != "F"
          || items[index].modifiers != wantedModifiers
          || items[index].action != .windowPreset
          || items[index].target != WindowPreset.maximize.rawValue
          || !items[index].enabled
          || items[index].note != wantedNote
        {
          items[index].name = "窗口化全屏"
          items[index].scope = "窗口"
          items[index].key = "F"
          items[index].modifiers = wantedModifiers
          items[index].action = .windowPreset
          items[index].target = WindowPreset.maximize.rawValue
          items[index].enabled = true
          items[index].note = wantedNote
          changed = true
        }
      case "系统全屏", "系统全景", "全景", "全景模式", "全屏":
        let wantedModifiers = ["control", "option", "command"]
        let wantedNote = "Caps + ⌘ + F：按一下进入全屏，再按一下退出。"
        if items[index].name != "全屏"
          || items[index].scope != "窗口"
          || items[index].key != "F"
          || items[index].modifiers != wantedModifiers
          || items[index].action != .nativeFullScreen
          || items[index].target != "entireScreen"
          || !items[index].enabled
          || items[index].note != wantedNote
        {
          items[index].name = "全屏"
          items[index].scope = "窗口"
          items[index].key = "F"
          items[index].modifiers = wantedModifiers
          items[index].action = .nativeFullScreen
          items[index].target = "entireScreen"
          items[index].enabled = true
          items[index].note = wantedNote
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
        note: "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
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
        key: "V",
        modifiers: ["control", "option"],
        trigger: .rightOptionDoubleTap,
        action: .showClipboardHistory,
        target: "clipboard-history",
        enabled: true,
        note: "连按物理右 Option 两次：打开剪贴板历史并开始搜索；再连按两次收起。"
      )
      let signature = shortcutTriggerSignature(for: item)
      let hasConflict = items.contains {
        itemConsumesHotkey($0)
          && shortcutTriggerSignature(for: $0) == signature
      }
      if hasConflict {
        item.enabled = false
        item.note += " 连按右 Option 两次与现有规则冲突，已保留但未自动启用。"
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
        note: "Caps + F：窗口化全屏，保留 Dock 和顶部菜单栏/状态栏，左右上下 100% 铺满可用区域，再按一次恢复。"
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
        items[index].note = "Caps + ⌘ + F：按一下进入全屏，再按一下退出。"
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
    return changed
  }

  private func missingDefaultFeatureShortcuts() -> [FeatureShortcutCommandDescriptor] {
    guard YoumuFeatureShortcutCatalog.runtimeAvailable else { return [] }
    return YoumuFeatureShortcutCatalog.missingDefaultDescriptors(
      in: items,
      deletedNames: deletedShortcutNames(),
      deletedRecoveryIDs: deletedShortcutRecoveryIDs())
  }

  private func hasDuplicateShortcutIDs() -> Bool {
    var seen: Set<String> = []
    return items.contains { !seen.insert($0.id).inserted }
  }

  private func repairDuplicateShortcutIDs() -> Bool {
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

  private func managedShortcutIdentityKey(_ item: ShortcutItem) -> String? {
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

  private func hasDuplicateManagedShortcutIdentities() -> Bool {
    var seen: Set<String> = []
    return items.contains { item in
      guard let identity = managedShortcutIdentityKey(item) else { return false }
      return !seen.insert(identity).inserted
    }
  }

  private func repairDuplicateManagedShortcutIdentities() -> Bool {
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

  private func legacyRecoveryTemplate(
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

  private func hasLegacyRecoveryOwnershipRepair() -> Bool {
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

  private func repairLegacyRecoveryOwnership() -> Bool {
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

  private func repairMissingDefaultFeatureShortcuts() -> Bool {
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
    statusMessage = "已补回游目默认快捷键；现有自定义规则保持不变。"
    return true
  }

  private func isLegacyDisplaySleepShortcut(_ item: ShortcutItem) -> Bool {
    let legacyNames = Set(["息屏", "息屏不睡机"])
    return item.usesChordTrigger
      && legacyNames.contains(item.name)
      && item.action == .runShell
      && item.target == "pmset displaysleepnow"
      && item.key == "Escape"
      && Set(item.modifiers) == Set(["control", "option", "command"])
  }

  private func backupShortcutConfigBeforeCodexNetworkProbeAddition() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "codex-network-probe",
      failureMessage: "快捷键备份失败，未写入测试网速快捷键。")
  }

  private func backupShortcutConfigBeforeClipboardHistoryAddition() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "clipboard-history",
      failureMessage: "快捷键备份失败，未写入剪贴板历史快捷键。")
  }

  private func backupShortcutConfigBeforeFeatureShortcutMerge() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "feature-shortcuts",
      failureMessage: "快捷键备份失败，未补回游目默认快捷键。")
  }

  private func backupShortcutConfigBeforeRecoveryOwnershipRepair() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-recovery-ownership",
      failureMessage: "快捷键备份失败，未迁移旧版恢复身份。")
  }

  private func backupShortcutConfigBeforeDuplicateIDRepair() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-duplicate-identities",
      failureMessage: "快捷键备份失败，未修复重复身份。")
  }

  private func backupShortcutConfigBeforeDefaultBaselineMigration() -> Bool {
    backupShortcutConfigBeforeDefaultMerge(
      reason: "shortcut-default-baseline-v\(ShortcutDefaultBaseline.currentVersion)",
      failureMessage: "快捷键备份失败，未升级默认快捷键触发方式。")
  }

  private func backupShortcutConfigBeforeDefaultMerge(
    reason: String,
    failureMessage: String
  ) -> Bool {
    guard let data = try? LocalConfigurationFileCodec.readData(from: fileURL) else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let directory = fileURL.deletingLastPathComponent()
      .appendingPathComponent("backups", isDirectory: true)
    let backup = directory.appendingPathComponent(
      "shortcuts-before-\(reason)-build\(build)-\(formatter.string(from: Date())).json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: backup, options: [.atomic])
      return true
    } catch {
      statusMessage = "\(failureMessage)：\(error.localizedDescription)"
      return false
    }
  }

  private func migrateShortcutDefaultBaselineIfNeeded() -> Bool {
    let defaults = UserDefaults.standard
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
    let changed = ShortcutDefaultBaseline.migrateLegacyDefaults(
      in: &items,
      allowClipboardHistoryTriggerMigration: allowClipboardHistoryTriggerMigration)
    if changed {
      shortcutDefaultBaselineVersionCommitPending = true
      statusMessage = "检测到旧版快捷键方案，已升级为当前小龙哥默认方案。你的自定义快捷键不会被覆盖。"
    } else {
      markShortcutDefaultBaselineCurrent()
    }
    return changed
  }

  private func commitShortcutDefaultBaselineVersionIfNeeded() {
    guard shortcutDefaultBaselineVersionCommitPending else { return }
    markShortcutDefaultBaselineCurrent()
    shortcutDefaultBaselineVersionCommitPending = false
  }

  private func cancelShortcutDefaultBaselineVersionCommit() {
    shortcutDefaultBaselineVersionCommitPending = false
  }

  private func markShortcutDefaultBaselineCurrent() {
    UserDefaults.standard.set(
      ShortcutDefaultBaseline.currentVersion,
      forKey: ShortcutDefaultBaseline.versionDefaultsKey)
    UserDefaults.standard.synchronize()
  }

  @discardableResult
  func saveOnly() -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(items)
      try data.write(to: fileURL, options: [.atomic])
      return true
    } catch {
      statusMessage = "保存失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func saveAndReload() -> Bool {
    guard saveOnly() else { return false }
    launcherDataRevision += 1
    reloadHotkeys()
    return true
  }

  func saveAndScheduleHotkeyReload(delay: TimeInterval = 0.45) {
    guard saveOnly() else { return }
    hotkeyReloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.hotkeyReloadWorkItem = nil
      self.reloadHotkeys()
    }
    hotkeyReloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func savePhrasesOnly() {
    do {
      try FileManager.default.createDirectory(
        at: phraseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(phrases)
      try data.write(to: phraseURL, options: [.atomic])
    } catch {
      statusMessage = "快捷短语保存失败：\(error.localizedDescription)"
    }
  }

  func savePhrasesAndReload() {
    phraseSaveWorkItem?.cancel()
    phraseSaveWorkItem = nil
    phraseSaveNeedsReload = false
    savePhrasesOnly()
    reloadPhraseExpander()
  }

  func schedulePhrasesSave(reload: Bool) {
    phraseSaveNeedsReload = phraseSaveNeedsReload || reload
    phraseSaveWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let shouldReload = self.phraseSaveNeedsReload
      self.phraseSaveWorkItem = nil
      self.phraseSaveNeedsReload = false
      self.savePhrasesOnly()
      if shouldReload {
        self.reloadPhraseExpander()
      }
    }
    phraseSaveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
  }

  func reloadPhraseExpander() {
    refreshAccessibilityStatus()
    guard hasGlobalInputOwnership else {
      phraseExpander?.stop()
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    guard !isPaused else {
      phraseExpander?.stop()
      return
    }
    phraseExpander?.reload(phrases)
  }

  var commandWProtectionStatus: String {
    if isPaused || shortcutRecordingSession != nil { return "保护已暂停。" }
    if !hasGlobalInputOwnership {
      return "保护未生效，请先恢复后台快捷键。"
    }
    if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
      return "保护未生效，请在权限设置中完成系统授权。"
    }
    guard hotkeyManager?.commandWProtectionRunning == true else {
      return "保护未生效，请恢复后台快捷键或检查系统权限。"
    }
    return "保护已启用。"
  }

  func reloadHotkeys() {
    refreshAccessibilityStatus()
    if !disableMissingOpenAppShortcuts().isEmpty {
      saveOnly()
    }
    guard hasGlobalInputOwnership else {
      hotkeyManager?.suspendAll()
      hotkeyFailures = []
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    guard !isPaused else {
      hotkeyManager?.suspendAll()
      hotkeyFailures = []
      statusMessage = "后台快捷键已暂停。"
      return
    }
    guard shortcutRecordingSession == nil else {
      hotkeyManager?.suspendAll()
      hotkeyFailures = []
      hotkeysSuspendedForRecording = true
      return
    }
    hotkeyManager?.register(hotkeyRegistrationItems())
    let failures = hotkeyManager?.failures ?? []
    hotkeyFailures = failures
    statusMessage = failures.isEmpty ? "后台快捷键已启用。" : failures.joined(separator: "\n")
  }

  private func handleHotkeyManagerNotice(_ message: String) {
    let failures = hotkeyManager?.failures ?? []
    hotkeyFailures = failures
    statusMessage = failures.isEmpty ? message : failures.joined(separator: "\n")
  }

  private func hotkeyRegistrationItems() -> [ShortcutItem] {
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

  private static func isLegacyLauncherModule(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized == "启动器" || normalized == "App 启动器"
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
  func createShortcut(from draft: ShortcutItem) -> Bool {
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
  func updateShortcut(id: String, draft: ShortcutItem) -> Bool {
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

  func addShortcut(module: String = "功能快捷键") {
    if module == "快捷短语" || module == "短语类" {
      addPhrase()
      return
    }
    _ = createShortcut(from: makeShortcutDraft(module: module))
  }

  private func normalizedShortcutDraft(_ draft: ShortcutItem, id: String) -> ShortcutItem {
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

  private func validateShortcutDraft(_ draft: ShortcutItem) -> Bool {
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

  func addPhrase() {
    let item = PhraseItem(
      id: UUID().uuidString,
      trigger: "ppdz",
      output: "通讯地址",
      enabled: true,
      note: ""
    )
    phrases.append(item)
    selectedPhraseID = item.id
    savePhrasesAndReload()
  }

  func deleteSelectedPhrase() {
    guard let selectedPhraseID,
      let index = phrases.firstIndex(where: { $0.id == selectedPhraseID })
    else {
      return
    }
    let nextID: String?
    if phrases.indices.contains(index + 1) {
      nextID = phrases[index + 1].id
    } else if phrases.indices.contains(index - 1) {
      nextID = phrases[index - 1].id
    } else {
      nextID = nil
    }
    self.selectedPhraseID = nil
    phrases.remove(at: index)
    self.selectedPhraseID = nextID ?? phrases.first?.id
    savePhrasesAndReload()
  }

  func deleteShortcut(id: String) {
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
      shortcutActionCaptureItemID = nil
      shortcutActionCaptureDraft = ""
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
    launcherDataRevision += 1
    reloadHotkeys()
    statusMessage =
      deletionDecision.recoveryID == nil
      ? "已删除快捷键：\(item.name)。"
      : "已删除快捷键：\(item.name)。需要时可重新新增或恢复小龙哥最佳配置。"
  }

  func deleteSelected() {
    guard let selectedID else { return }
    deleteShortcut(id: selectedID)
  }

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

  var deletedDefaultShortcutCount: Int {
    deletedDefaultShortcutTemplates().count
  }

  func restoreDeletedDefaultShortcuts() {
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
    launcherDataRevision += 1
    reloadHotkeys()
    statusMessage =
      disabledForConflict == 0
      ? "已恢复 \(templates.count) 条默认快捷键。"
      : "已恢复 \(templates.count) 条默认快捷键；\(disabledForConflict) 条因组合键冲突暂未启用。"
  }

  private func shortcutDeletionDecision(for item: ShortcutItem) -> ShortcutDeletionDecision {
    let recoveryID = defaultShortcutTemplate(matching: item)?.recoveryID
    return ShortcutDeletionPolicy.decision(
      isAppManaged: isAppManagedShortcut(item),
      isUserDefined: item.isBuiltIn == false,
      isFixedFeature: isFixedFeatureShortcut(item),
      recoveryID: recoveryID)
  }

  private func isFixedFeatureShortcut(_ item: ShortcutItem) -> Bool {
    item.commandID != nil
      || ShortcutRecoveryIdentity.featureCommandID(from: item.recoveryID) != nil
      || (item.isBuiltIn != false && item.target.hasPrefix("feature-command:"))
  }

  private func isAppManagedShortcut(_ item: ShortcutItem) -> Bool {
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

  private func defaultShortcutTemplate(matching item: ShortcutItem) -> ShortcutItem? {
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

  private func shortcut(_ item: ShortcutItem, matchesDefaultTemplate template: ShortcutItem)
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

  private func deletedDefaultShortcutTemplates() -> [ShortcutItem] {
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

  private func migrateBuiltInShortcutOwnership() -> Bool {
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
    clearDeletedShortcutNames()
    clearDeletedShortcutRecoveryIDs()
    items = defaultShortcuts()
    markShortcutDefaultBaselineCurrent()
    selectedID = items.first?.id
    saveAndReload()
  }

  private func markShortcutDeleted(_ item: ShortcutItem, recoveryID: String?) {
    if let template = defaultShortcutTemplate(matching: item) {
      for name in shortcutDeletionNameAliases(for: template) {
        markShortcutNameDeleted(name)
      }
    }
    if let recoveryID {
      var recoveryIDs = deletedShortcutRecoveryIDs()
      recoveryIDs.insert(recoveryID)
      UserDefaults.standard.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  private func markShortcutNameDeleted(_ name: String) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else { return }
    var names = Set(deletedShortcutNames())
    names.insert(normalizedName)
    UserDefaults.standard.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
  }

  private func isShortcutNameDeleted(_ name: String) -> Bool {
    deletedShortcutNames().contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func clearDeletedShortcutNames() {
    UserDefaults.standard.removeObject(forKey: deletedShortcutNamesDefaultsKey)
  }

  private func setDeletedShortcutNames(_ names: Set<String>) {
    if names.isEmpty {
      clearDeletedShortcutNames()
    } else {
      UserDefaults.standard.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
    }
  }

  private func deletedShortcutNames() -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: deletedShortcutNamesDefaultsKey) ?? [])
  }

  private func isShortcutRecoveryDeleted(_ recoveryID: String) -> Bool {
    deletedShortcutRecoveryIDs().contains(recoveryID)
  }

  private func restoreShortcutRecoveryID(_ recoveryID: String) {
    var recoveryIDs = deletedShortcutRecoveryIDs()
    guard recoveryIDs.remove(recoveryID) != nil else { return }
    if recoveryIDs.isEmpty {
      UserDefaults.standard.removeObject(forKey: deletedShortcutRecoveryIDsDefaultsKey)
    } else {
      UserDefaults.standard.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  private func restoreShortcutNames(_ namesToRestore: Set<String>) {
    var names = deletedShortcutNames()
    let originalCount = names.count
    names.subtract(namesToRestore)
    guard names.count != originalCount else { return }
    if names.isEmpty {
      UserDefaults.standard.removeObject(forKey: deletedShortcutNamesDefaultsKey)
    } else {
      UserDefaults.standard.set(Array(names).sorted(), forKey: deletedShortcutNamesDefaultsKey)
    }
  }

  private func clearShortcutDeletionMarkers(for item: ShortcutItem) {
    guard let template = defaultShortcutTemplate(matching: item),
      let recoveryID = template.recoveryID
    else {
      return
    }
    restoreShortcutRecoveryID(recoveryID)
    restoreShortcutNames(shortcutDeletionNameAliases(for: template))
  }

  private func shortcutDeletionNameAliases(for template: ShortcutItem) -> Set<String> {
    ShortcutRecoveryIdentity.deletionNameAliases(
      recoveryID: template.recoveryID,
      primaryName: template.name)
  }

  private func clearDeletedShortcutRecoveryIDs() {
    UserDefaults.standard.removeObject(forKey: deletedShortcutRecoveryIDsDefaultsKey)
  }

  private func setDeletedShortcutRecoveryIDs(_ recoveryIDs: Set<String>) {
    if recoveryIDs.isEmpty {
      clearDeletedShortcutRecoveryIDs()
    } else {
      UserDefaults.standard.set(
        Array(recoveryIDs).sorted(),
        forKey: deletedShortcutRecoveryIDsDefaultsKey)
    }
  }

  private func deletedShortcutRecoveryIDs() -> Set<String> {
    Set(
      UserDefaults.standard.stringArray(forKey: deletedShortcutRecoveryIDsDefaultsKey) ?? [])
  }

  func updateEnabled(_ itemID: String, _ enabled: Bool) {
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
    if launcherApps.isEmpty, !isLauncherScanning {
      ensureLauncherAppsReady()
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let apps =
      trimmedQuery.isEmpty
      ? launcherApps
      : AppLauncherScanner.filter(
        launcherApps,
        query: trimmedQuery,
        history: launcherUsageHistory)
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

  private var actionPresetUndoSnapshots: [String: ShortcutItem] = [:]

  func canUndoActionPreset(itemID: String) -> Bool {
    actionPresetUndoSnapshots[itemID] != nil
  }

  func undoActionPreset(itemID: String) {
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

  func canChangeShortcutAction(id: String) -> Bool {
    guard let item = items.first(where: { $0.id == id }) else { return false }
    return !isFixedFeatureShortcut(item)
  }

  func shortcutActionChangeHelp(id: String) -> String {
    canChangeShortcutAction(id: id)
      ? "把这条快捷键改成其他动作。"
      : "这是固定功能快捷键；可改键或停用，不能转换功能。"
  }

  private func shortcutSemanticActionChanged(
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

  private func replaceShortcutForActionMutation(
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
    applyActionPreset(
      itemID: itemID,
      action: .openApp,
      target: choice.target,
      name: "打开 \(choice.name)",
      scope: "App",
      note: "\(choice.source) App：打开 / 置前 / 再按隐藏。"
    )
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

  func togglePaused() {
    isPaused.toggle()
    reloadHotkeys()
    reloadPhraseExpander()
    reloadCapsCorePlugin(requestPermission: false)
    reloadClassicTabSwitcher()
  }

  func openConfigFile() {
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  func openDiagnosticsLog() {
    let url = AppDiagnostics.logURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
      statusMessage = "诊断日志还没有生成。"
    }
  }

  func copyDiagnosticsLog() {
    let url = AppDiagnostics.logURL
    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
      statusMessage = "诊断日志为空。"
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    statusMessage = "已复制诊断日志。"
  }

  func openPhraseConfigFile() {
    NSWorkspace.shared.activateFileViewerSelecting([phraseURL])
  }

  func openProductWebsite() {
    guard let url = URL(string: "https://aixlg.com/") else { return }
    NSWorkspace.shared.open(url)
  }

  func presentCommunityQRCode() {
    presentWindowHandler?()
    isCommunityQRCodePresented = true
  }

  func openPrivacyWebsite() {
    guard let url = URL(string: "https://aixlg.com/privacy.html") else { return }
    NSWorkspace.shared.open(url)
  }

  func openApplicationsFolder() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
  }

  func restoreBestConfigurationAfterUserConfirmation() {
    guard !isImportingXLGConfig else { return }
    isImportingXLGConfig = true
    statusMessage = "正在恢复小龙哥最佳配置..."

    let request = XLGConfigImportRequest.appDefault(
      applicationSupportURL: fileURL.deletingLastPathComponent(),
      shortcutsURL: fileURL,
      phrasesURL: phraseURL,
      allowNetworkDownload: false)

    Task {
      do {
        let result = try await XLGConfigImporter.importRecommendedConfig(request: request)
        await MainActor.run {
          self.finishXLGConfigImport(result)
        }
      } catch {
        await MainActor.run {
          self.isImportingXLGConfig = false
          self.statusMessage = "最佳配置恢复失败：\(error.localizedDescription)"
        }
      }
    }
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
    lastXLGConfigImportBackupURL = result.backupURL
    clipboardHistory.reloadManagedPreferences()
    setDiagnosticsEnabled(UserDefaults.standard.bool(forKey: "diagnosticsEnabled"))
    load()
    loadPhrases()
    loadInputMethodRules()
    loadLauncherPinnedItems()
    loadKeepAwakeSettings()
    capsCorePluginEnabled = UserDefaults.standard.bool(
      forKey: Self.capsCorePluginEnabledDefaultsKey)
    inputMethodPluginEnabled = UserDefaults.standard.bool(
      forKey: Self.inputMethodPluginEnabledDefaultsKey)
    sleepStatusItemVisible = Self.boolDefaultingTrue(
      forKey: Self.sleepStatusItemVisibleDefaultsKey)
    menuBarVisibleItemIDs = MenuBarCatalog.loadVisibleItemIDs()
    Self.ensureNetworkSpeedPrimaryEntryEnabled()
    networkSpeedPluginEnabled = true
    networkSpeedShowMemory = Self.boolDefaultingTrue(
      forKey: Self.networkSpeedShowMemoryDefaultsKey)
    networkSpeedShowCPU = UserDefaults.standard.bool(forKey: Self.networkSpeedShowCPUDefaultsKey)
    networkSpeedShowGPU = UserDefaults.standard.bool(forKey: Self.networkSpeedShowGPUDefaultsKey)
    launcherDisplayMode = Self.loadLauncherDisplayMode()
    launcherShowsPinnedNames = Self.loadLauncherShowsPinnedNames()
    launcherSearchEngine = Self.loadLauncherSearchEngine()
    launcherPluginEnabled = Self.boolDefaultingTrue(
      forKey: Self.launcherPluginEnabledDefaultsKey)
    let restoredDockVisibility = DockPresencePreference.isVisible()
    if restoredDockVisibility != dockIconVisible,
      DockPresencePreference.apply(visible: restoredDockVisibility)
    {
      dockIconVisible = restoredDockVisibility
    }
    scrollSettings = loadScrollSettings()
    saveScrollSettings()
    reloadHotkeys()
    reloadPhraseExpander()
    reloadScrollEngine()
    reloadInputMethodPlugin()
    notifySleepStatusItemChanged()
    NotificationCenter.default.post(name: .menuBarConfigurationChanged, object: nil)
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    NotificationCenter.default.post(
      name: Notification.Name("AIXLGManagedConfigurationDidRestore"), object: nil)
    isImportingXLGConfig = false
    statusMessage = "\(result.summary) 来源：\(result.sourceDescription)。"
  }

  func refreshLaunchAtLoginStatus() {
    guard runtimeIdentity.allowsLaunchAtLogin else {
      launchAtLoginEnabled = false
      return
    }
    launchAtLoginEnabled = launchAgentPlistMatchesCurrentApp()
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    guard runtimeIdentity.allowsLaunchAtLogin else {
      launchAtLoginEnabled = false
      statusMessage = "运行身份无效，不能更改开机启动。"
      return
    }
    do {
      try setLaunchAtLogin(enabled)
      refreshLaunchAtLoginStatus()
      statusMessage = enabled ? "已开启开机自动启动。" : "已关闭开机自动启动。"
    } catch {
      refreshLaunchAtLoginStatus()
      statusMessage = "开机启动设置失败：\(error.localizedDescription)"
    }
  }

  private func launchAgentURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("\(launchAgentID).plist")
  }

  private func repairLaunchAgentIfNeeded() {
    guard runtimeIdentity.allowsLaunchAtLogin else { return }
    let url = launchAgentURL()
    guard FileManager.default.fileExists(atPath: url.path), !launchAtLoginEnabled else { return }
    try? setLaunchAtLogin(true)
    refreshLaunchAtLoginStatus()
  }

  private func launchAgentPlistMatchesCurrentApp() -> Bool {
    guard runtimeIdentity.allowsLaunchAtLogin else { return false }
    let url = launchAgentURL()
    guard
      FileManager.default.fileExists(atPath: url.path),
      let data = try? LocalConfigurationFileCodec.readData(from: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let arguments = plist["ProgramArguments"] as? [String]
    else {
      return false
    }
    return arguments.contains(Bundle.main.bundlePath)
  }

  private func setLaunchAtLogin(_ enabled: Bool) throws {
    guard runtimeIdentity.allowsLaunchAtLogin else { return }
    let url = launchAgentURL()
    if enabled {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let plist: [String: Any] = [
        "Label": launchAgentID,
        "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
        "RunAtLoad": true,
      ]
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0)
      try data.write(to: url, options: [.atomic])
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  func refreshLegacyScrollProfile() {
    legacyScrollProfile = LegacyScrollProfile.load()
  }

  func revealLegacyScrollConfig() {
    guard FileManager.default.fileExists(atPath: LegacyScrollProfile.legacyPlistURL.path) else {
      statusMessage = "没有找到旧滚动配置文件。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([LegacyScrollProfile.legacyPlistURL])
  }

  func importLegacyScrollProfile() {
    refreshLegacyScrollProfile()
    var imported = ScrollEngineSettings.fromLegacyProfile(legacyScrollProfile)
    imported.enabled = scrollSettings.enabled
    imported.enforceMouseWheelOnlyWindowsHabit()
    scrollSettings = imported
    saveScrollSettings()
    reloadScrollEngine()
    statusMessage =
      legacyScrollProfile.profileFound ? "已导入旧滚动参数。" : "没有旧滚动参数，已使用默认滚动手感。"
  }

  func applyRecommendedScrollSettings(reverse: Bool? = nil) {
    let mouseVolumeEnabled = scrollSettings.volumeHotCornerEnabled
    let volumeStep = scrollSettings.volumeStep
    var recommended = ScrollEngineSettings.mosPreset
    recommended.enabled = true
    recommended.reverseVertical = true
    recommended.reverseHorizontal = true
    recommended.volumeHotCornerEnabled = mouseVolumeEnabled
    recommended.volumeStep = volumeStep
    recommended.enforceMouseWheelOnlyWindowsHabit()
    scrollSettings = recommended
    UserDefaults.standard.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    saveScrollSettings()
    quitLegacyScrollAppIfRunning()
    reloadScrollEngine()
    statusMessage = "已恢复 Mos-like 丝滑滚动手感：只接管鼠标滚轮，触控板保持系统原样。"
  }

  func applyMosScrollPreset() {
    let mouseVolumeEnabled = scrollSettings.volumeHotCornerEnabled
    let volumeStep = scrollSettings.volumeStep
    var preset = ScrollEngineSettings.mosPreset
    preset.volumeHotCornerEnabled = mouseVolumeEnabled
    preset.volumeStep = volumeStep
    preset.enforceMouseWheelOnlyWindowsHabit()
    scrollSettings = preset
    UserDefaults.standard.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    saveScrollSettings()
    quitLegacyScrollAppIfRunning()
    reloadScrollEngine()
    statusMessage = "已恢复 Mos-like 丝滑滚动手感：方向校准和平滑滚动已开启。"
  }

  func applyMouseScrollPreset(_ preset: MouseScrollPreset) {
    let wasEnabled = scrollSettings.enabled
    let mouseVolumeEnabled = scrollSettings.volumeHotCornerEnabled
    let volumeWidthRatio = scrollSettings.volumeHotCornerWidthRatio
    let volumeHeightRatio = scrollSettings.volumeHotCornerHeightRatio
    let volumeStep = scrollSettings.volumeStep
    var next = scrollSettings

    next.enabled = wasEnabled
    next.enforceMouseWheelOnlyWindowsHabit()
    next.volumeHotCornerEnabled = mouseVolumeEnabled
    next.volumeHotCornerWidthRatio = volumeWidthRatio
    next.volumeHotCornerHeightRatio = volumeHeightRatio
    next.volumeStep = volumeStep

    switch preset {
    case .natural:
      next.smooth = true
      next.step = 28.0
      next.speed = 2.1
      next.duration = 4.0
    case .stable:
      next.smooth = false
      next.step = 33.6
      next.speed = 2.7
      next.duration = 4.35
    case .fast:
      next.smooth = true
      next.step = 42.0
      next.speed = 3.4
      next.duration = 3.0
    }

    scrollSettings = next
    saveScrollSettings()
    if scrollSettings.enabled {
      quitLegacyScrollAppIfRunning()
    }
    reloadScrollEngine()
    statusMessage = "鼠标滚动已切换为「\(preset.title)」预设。"
  }

  func updateScrollSettings(_ mutate: (inout ScrollEngineSettings) -> Void) {
    mutate(&scrollSettings)
    scrollSettings.enforceMouseWheelOnlyWindowsHabit()
    saveScrollSettings()
    if scrollSettings.enabled {
      quitLegacyScrollAppIfRunning()
    }
    reloadScrollEngine()
  }

  func setScrollEngineEnabled(_ enabled: Bool) {
    scrollSettings.enabled = enabled
    scrollSettings.enforceMouseWheelOnlyWindowsHabit()
    UserDefaults.standard.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    saveScrollSettings()
    if enabled {
      quitLegacyScrollAppIfRunning()
    }
    reloadScrollEngine()
    statusMessage =
      enabled
      ? "鼠标滚动插件已启用：只接管鼠标滚轮，触控板保持系统原样。"
      : "鼠标滚动插件已关闭。"
  }

  func setCapsCorePluginEnabled(_ enabled: Bool) {
    capsCorePluginEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.capsCorePluginEnabledDefaultsKey)
    reloadCapsCorePlugin(requestPermission: enabled)
    statusMessage = enabled ? capsCorePluginStatus.detailText : "Caps 核心键已关闭。"
  }

  func reloadCapsCorePlugin(requestPermission: Bool = false) {
    guard let capsCoreEngine else { return }
    guard hasGlobalInputOwnership else {
      capsCoreEngine.stop(reason: "globalInputLeaseUnavailable")
      capsCoreEngineRunning = false
      capsCorePluginStatus = .paused
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    let conflict = capsCorePluginEnabled ? Self.currentCapsCoreConflict() : nil
    detectedCapsCoreConflict = conflict
    lastCapsCoreConflictCheckAt = ProcessInfo.processInfo.systemUptime

    guard capsCorePluginEnabled else {
      capsCoreEngine.stop(reason: "pluginDisabled")
      capsCoreEngineRunning = false
      capsCorePluginStatus = .stopped
      return
    }
    guard !isPaused else {
      capsCoreEngine.stop(reason: "appPaused")
      capsCoreEngineRunning = false
      capsCorePluginStatus = .paused
      return
    }
    if let conflict {
      capsCoreEngine.stop(reason: "conflict")
      capsCoreEngineRunning = false
      capsCorePluginStatus = .conflict(conflict)
      AppDiagnostics.log(
        "caps_core_conflict",
        ["conflict": conflict.displayText, "action": "stopSelfEngine"])
      return
    }

    let started = capsCoreEngine.start(requestPermission: requestPermission)
    capsCoreEngineRunning = started && capsCoreEngine.isRunning
  }

  private func handleCapsCoreEngineStatus(_ status: CapsCoreEngineStatus) {
    switch status {
    case .stopped:
      capsCoreEngineRunning = false
      if !capsCorePluginEnabled {
        capsCorePluginStatus = .stopped
      }
    case .running:
      capsCoreEngineRunning = true
      capsCorePluginStatus = .running
    case .waitingForPermission(let message):
      capsCoreEngineRunning = false
      capsCorePluginStatus = .waitingForPermission(message)
    case .failed(let message):
      capsCoreEngineRunning = false
      capsCorePluginStatus = .failed(message)
    }
  }

  private func refreshCapsCoreConflictIfNeeded() {
    guard capsCorePluginEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastCapsCoreConflictCheckAt >= 3 else { return }
    lastCapsCoreConflictCheckAt = now
    let conflict = Self.currentCapsCoreConflict()
    guard conflict != detectedCapsCoreConflict else { return }
    detectedCapsCoreConflict = conflict

    guard let capsCoreEngine else { return }
    if let conflict {
      capsCoreEngine.stop(reason: "conflictDetected")
      capsCoreEngineRunning = false
      capsCorePluginStatus = .conflict(conflict)
      AppDiagnostics.log(
        "caps_core_conflict",
        ["conflict": conflict.displayText, "action": "stopSelfEngine"])
    } else {
      reloadCapsCorePlugin(requestPermission: false)
    }
  }

  private static func currentCapsCoreConflict() -> CapsCoreConflict? {
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

  @MainActor private static var karabinerCapsRuleCache: (mtime: TimeInterval, hasRule: Bool)?

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

  func setMouseVolumePluginEnabled(_ enabled: Bool) {
    scrollSettings.volumeHotCornerEnabled = enabled
    UserDefaults.standard.set(true, forKey: Self.mouseVolumePluginUserSetDefaultsKey)
    saveScrollSettings()
    reloadScrollEngine()
    statusMessage =
      enabled
      ? "鼠标音量插件已启用：鼠标移到屏幕右上角热区，滚轮可调音量。"
      : "鼠标音量插件已关闭。"
  }

  func setNetworkSpeedPluginEnabled(_ _: Bool) {
    Self.ensureNetworkSpeedPrimaryEntryEnabled()
    networkSpeedPluginEnabled = true
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    statusMessage = "网速显示是 Mac 哲学的菜单栏主入口，默认保持显示。"
  }

  func setNetworkSpeedShowMemory(_ enabled: Bool) {
    networkSpeedShowMemory = enabled
    UserDefaults.standard.set(enabled, forKey: Self.networkSpeedShowMemoryDefaultsKey)
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    statusMessage = "网速显示选项已更新。"
  }

  func setNetworkSpeedShowCPU(_ enabled: Bool) {
    networkSpeedShowCPU = enabled
    UserDefaults.standard.set(enabled, forKey: Self.networkSpeedShowCPUDefaultsKey)
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    statusMessage = "网速显示选项已更新。"
  }

  func setNetworkSpeedShowGPU(_ enabled: Bool) {
    networkSpeedShowGPU = enabled
    UserDefaults.standard.set(enabled, forKey: Self.networkSpeedShowGPUDefaultsKey)
    NotificationCenter.default.post(name: .networkSpeedPluginVisibilityChanged, object: nil)
    statusMessage = "网速显示选项已更新。"
  }

  func setCodexNetworkProbeDefaultDirection(_ direction: NetworkProbeDirection) {
    let direction = NetworkProbeDirection.customerFacing(direction)
    codexNetworkProbeDefaultDirection = direction
    UserDefaults.standard.set(
      direction.rawValue,
      forKey: Self.codexNetworkProbeDefaultDirectionDefaultsKey)
    statusMessage = "测试网速默认方向已改为\(direction.title)。"
  }

  func setClassicTabSwitcherEnabled(_ enabled: Bool) {
    if Self.classicTabSwitcherRetired {
      disableClassicTabSwitcherForRetirement(
        status: "窗口切换已下线，Command + Tab 保持系统默认。")
      return
    }
    if enabled, !classicTabSwitcherEnabled,
      !classicTabSwitcherCommandTabTakeoverConfirmed,
      !confirmCommandTabTakeover()
    {
      statusMessage = "窗口切换未开启，Command + Tab 保持系统默认。"
      return
    }
    classicTabSwitcherEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    if !enabled {
      setClassicTabSwitcherCommandTabTakeoverConfirmed(false)
    }
    reloadClassicTabSwitcher()
    if enabled, classicTabSwitcherRunning {
      statusMessage =
        classicTabSwitcherCommandTabTakeoverConfirmed
        ? "窗口切换已接管 Command + Tab，Option + Tab 仍可回退。"
        : "内置窗口切换已开启，使用 Option + Tab 呼出。"
    } else if enabled {
      statusMessage = "内置窗口切换需要完成权限后才能监听全局快捷键。"
    } else if !enabled {
      statusMessage = "内置窗口切换已关闭，Command + Tab 已恢复系统默认。"
    }
  }

  func confirmClassicTabSwitcherCommandTabTakeover() {
    if Self.classicTabSwitcherRetired {
      disableClassicTabSwitcherForRetirement(
        status: "窗口切换已下线，不再接管 Command + Tab。")
      return
    }
    guard confirmCommandTabTakeover() else {
      statusMessage = "Command + Tab 保持系统默认，可继续用 Option + Tab。"
      return
    }
    setClassicTabSwitcherCommandTabTakeoverConfirmed(true)
    if !classicTabSwitcherEnabled {
      classicTabSwitcherEnabled = true
      UserDefaults.standard.set(true, forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    }
    reloadClassicTabSwitcher()
    if classicTabSwitcherRunning {
      statusMessage = "已接管 Command + Tab；关闭窗口切换或点恢复即可还给系统。"
    } else {
      statusMessage = "已确认接管，但还需要补齐权限后才能监听 Command + Tab。"
    }
  }

  func restoreSystemCommandTabForClassicTabSwitcher() {
    if Self.classicTabSwitcherRetired {
      disableClassicTabSwitcherForRetirement(status: "Command + Tab 已保持系统默认。")
      return
    }
    setClassicTabSwitcherCommandTabTakeoverConfirmed(false)
    reloadClassicTabSwitcher()
    if classicTabSwitcherEnabled {
      statusMessage = "已恢复系统 Command + Tab；窗口切换暂用 Option + Tab。"
    } else {
      statusMessage = "Command + Tab 已保持系统默认。"
    }
  }

  private func setClassicTabSwitcherCommandTabTakeoverConfirmed(_ confirmed: Bool) {
    classicTabSwitcherCommandTabTakeoverConfirmed = confirmed
    UserDefaults.standard.set(
      confirmed,
      forKey: Self.classicTabSwitcherCommandTabTakeoverDefaultsKey)
  }

  private func confirmCommandTabTakeover() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "接管 Command + Tab？"
    alert.informativeText = [
      "开启后，小龙哥窗口切换会替代 macOS 原版 Command + Tab。",
      "按住 Command、连按 Tab 选择窗口，松开 Command 切过去。",
      "关闭窗口切换或点“恢复系统 Command + Tab”后会还给系统。",
      "Option + Tab 会保留为回退入口。",
    ].joined(separator: "\n")
    let confirmButton = alert.addButton(withTitle: "接管 Command + Tab")
    alert.addButton(withTitle: "取消")
    confirmButton.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }

  func previewClassicTabSwitcherHUD() {
    if Self.classicTabSwitcherRetired {
      disableClassicTabSwitcherForRetirement(
        status: "窗口切换已下线，暂不再展示半成品 HUD。")
      return
    }
    classicTabSwitcher?.previewHUD()
    statusMessage = "正在预览内置窗口切换 HUD。"
  }

  private func disableClassicTabSwitcherForRetirement(status: String? = nil) {
    classicTabSwitcherEnabled = false
    classicTabSwitcherCommandTabTakeoverConfirmed = false
    UserDefaults.standard.set(false, forKey: Self.classicTabSwitcherEnabledDefaultsKey)
    UserDefaults.standard.set(false, forKey: Self.classicTabSwitcherCommandTabTakeoverDefaultsKey)
    UserDefaults.standard.set(true, forKey: Self.classicTabSwitcherRetiredDefaultsKey)
    classicTabSwitcher?.stop()
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

  func updateMouseVolumePluginSettings(_ mutate: (inout ScrollEngineSettings) -> Void) {
    mutate(&scrollSettings)
    UserDefaults.standard.set(true, forKey: Self.mouseVolumePluginUserSetDefaultsKey)
    saveScrollSettings()
    reloadScrollEngine()
  }

  /// 长截图期间完全停止宿主滚轮引擎。物理滚轮只由目标 App 的原生事件链处理；
  /// ScreenCaptureKit 负责观察像素变化，宿主不再依赖 passthrough 特例。
  func setLongScreenshotCaptureActive(_ isActive: Bool) {
    guard isScrollEngineSuspendedForLongScreenshot != isActive else { return }
    isScrollEngineSuspendedForLongScreenshot = isActive
    if isActive {
      scrollEngine?.stop()
      scrollEngineRunning = false
      AppDiagnostics.log(
        "scroll_engine_suspended",
        [
          "mode": "eventTapStopped",
          "reason": "youmuLongScreenshot",
          "running": "\(scrollEngineRunning)",
        ])
    } else {
      reloadScrollEngine(reportStatus: false)
      AppDiagnostics.log(
        "scroll_engine_resumed",
        [
          "reason": "youmuLongScreenshot",
          "running": "\(scrollEngineRunning)",
        ])
    }
  }

  func reloadScrollEngine(reportStatus: Bool = true) {
    guard let scrollEngine else { return }
    guard !isScrollEngineSuspendedForLongScreenshot else {
      scrollEngine.stop()
      scrollEngineRunning = false
      return
    }
    guard hasGlobalInputOwnership else {
      scrollEngine.stop()
      scrollEngineRunning = false
      statusMessage = globalInputOwnershipBlockedMessage
      return
    }
    if scrollSettings.needsEventTap {
      let started = scrollEngine.update(settings: scrollSettings)
      scrollEngineRunning = started && scrollEngine.isRunning
      if reportStatus, scrollEngineRunning, scrollSettings.enabled {
        statusMessage = "内置滚动引擎已启用。"
      }
    } else {
      scrollEngine.stop()
      scrollEngineRunning = false
    }
  }

  func reloadClassicTabSwitcher() {
    refreshAccessibilityStatus()
    guard let classicTabSwitcher else { return }
    guard hasGlobalInputOwnership else {
      classicTabSwitcher.stop()
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "全局监听已让位"
      updateClassicTabSwitcherHUDState(.hidden)
      return
    }
    if Self.classicTabSwitcherRetired {
      disableClassicTabSwitcherForRetirement()
      return
    }
    guard !isPaused else {
      classicTabSwitcher.stop()
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "已暂停"
      updateClassicTabSwitcherHUDState(.hidden)
      return
    }
    guard classicTabSwitcherEnabled else {
      classicTabSwitcher.stop()
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "未监听"
      updateClassicTabSwitcherHUDState(.hidden)
      return
    }

    switch classicTabSwitcher.start(
      capturesCommandTab: classicTabSwitcherCommandTabTakeoverConfirmed)
    {
    case .running:
      classicTabSwitcherRunning = true
      classicTabSwitcherStatusText =
        classicTabSwitcherCommandTabTakeoverConfirmed ? "Command+Tab 监听中" : "回退监听中"
    case .missingAccessibility:
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "需要辅助功能权限"
      statusMessage = "内置窗口切换需要辅助功能权限才能读取和激活窗口。"
    case .missingInputMonitoring:
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "需要输入监控权限"
      statusMessage =
        classicTabSwitcherCommandTabTakeoverConfirmed
        ? "未能接管 Command + Tab：需要输入监控权限，系统默认仍可用，可先用 Option + Tab。"
        : "内置窗口切换需要输入监控权限才能监听 Option + Tab。"
    case .failed(let message):
      classicTabSwitcherRunning = false
      classicTabSwitcherStatusText = "启动失败"
      statusMessage = message
    }
  }

  private func updateClassicTabSwitcherHUDState(_ state: ClassicTabSwitcherHUDState) {
    classicTabSwitcherHUDState = state
    classicTabSwitcherHUDHandler?(state)
  }

  private func quitLegacyScrollAppIfRunning() {
    guard
      NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleIdentifier == LegacyScrollProfile.legacyBundleID
      })
    else { return }
    runShell("osascript -e 'tell application \"Mos\" to quit'")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.refreshLegacyScrollProfile()
    }
  }

  private func loadScrollSettings() -> ScrollEngineSettings {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: "scrollEngineSettings"),
      var settings = try? JSONDecoder().decode(ScrollEngineSettings.self, from: data)
    else {
      return ScrollEngineSettings.fromLegacyProfile(LegacyScrollProfile.load())
    }
    var didMigrate = false
    if !defaults.bool(forKey: "scrollDirectionMigrationV1") {
      settings.reverseVertical = false
      settings.reverseHorizontal = false
      defaults.set(true, forKey: "scrollDirectionMigrationV1")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineStableModeV2") {
      settings.smooth = false
      settings.speed = ScrollEngineSettings.defaults.speed
      settings.step = ScrollEngineSettings.defaults.step
      settings.duration = ScrollEngineSettings.defaults.duration
      defaults.set(true, forKey: "scrollEngineStableModeV2")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineStableModeV3") {
      settings.smooth = false
      settings.speed = ScrollEngineSettings.defaults.speed
      settings.step = ScrollEngineSettings.defaults.step
      settings.duration = ScrollEngineSettings.defaults.duration
      settings.affectTrackpad = false
      defaults.set(true, forKey: "scrollEngineStableModeV3")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineStableModeV4") {
      settings.smooth = false
      settings.speed = ScrollEngineSettings.defaults.speed
      settings.step = ScrollEngineSettings.defaults.step
      settings.duration = ScrollEngineSettings.defaults.duration
      settings.affectTrackpad = false
      defaults.set(true, forKey: "scrollEngineStableModeV4")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineMosPresetV5") {
      let wasEnabled = settings.enabled
      settings = ScrollEngineSettings.mosPreset
      settings.enabled = wasEnabled
      defaults.set(true, forKey: "scrollEngineMosPresetV5")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineStableDirectionV6") {
      settings.reverseVertical = true
      settings.reverseHorizontal = true
      settings.smooth = false
      settings.affectTrackpad = false
      defaults.set(true, forKey: "scrollEngineStableDirectionV6")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineDirectCaptureV7") {
      settings.reverseVertical = true
      settings.reverseHorizontal = true
      settings.smooth = false
      settings.affectTrackpad = false
      defaults.set(true, forKey: "scrollEngineDirectCaptureV7")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollVolumeHotCornerStableV8") {
      settings.volumeHotCornerEnabled = true
      settings.volumeHotCornerWidthRatio = ScrollEngineSettings.defaults.volumeHotCornerWidthRatio
      settings.volumeHotCornerHeightRatio = ScrollEngineSettings.defaults.volumeHotCornerHeightRatio
      settings.volumeStep = ScrollEngineSettings.defaults.volumeStep
      defaults.set(true, forKey: "scrollVolumeHotCornerStableV8")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollMouseOnlyModeV9") {
      settings.affectTrackpad = false
      settings.smooth = false
      defaults.set(true, forKey: "scrollMouseOnlyModeV9")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollVolumeCornerTightV10") {
      settings.volumeHotCornerEnabled = true
      settings.volumeHotCornerWidthRatio = ScrollEngineSettings.defaults.volumeHotCornerWidthRatio
      settings.volumeHotCornerHeightRatio = ScrollEngineSettings.defaults.volumeHotCornerHeightRatio
      defaults.set(true, forKey: "scrollVolumeCornerTightV10")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollTrackpadBypassV11") {
      settings.affectTrackpad = false
      defaults.set(true, forKey: "scrollTrackpadBypassV11")
      didMigrate = true
    }
    if !defaults.bool(forKey: "scrollEngineDefaultOffV12") {
      if !defaults.bool(forKey: Self.scrollEngineUserSetEnabledDefaultsKey) {
        settings.enabled = false
        settings.volumeHotCornerEnabled = false
        settings.affectTrackpad = false
        didMigrate = true
      }
      defaults.set(true, forKey: "scrollEngineDefaultOffV12")
    }
    if !defaults.bool(forKey: "mouseVolumePluginCenterV13") {
      if !defaults.bool(forKey: Self.mouseVolumePluginUserSetDefaultsKey) {
        settings.volumeHotCornerEnabled = false
        didMigrate = true
      }
      defaults.set(true, forKey: "mouseVolumePluginCenterV13")
    }
    if !defaults.bool(forKey: "mouseScrollPluginCenterV14") {
      if !defaults.bool(forKey: Self.scrollEngineUserSetEnabledDefaultsKey) {
        settings.enabled = false
        settings.affectTrackpad = false
        didMigrate = true
      }
      defaults.set(true, forKey: "mouseScrollPluginCenterV14")
    }
    if !defaults.bool(forKey: "mouseScrollTrackpadBypassV15") {
      settings.affectTrackpad = false
      defaults.set(true, forKey: "mouseScrollTrackpadBypassV15")
      didMigrate = true
    }
    if !defaults.bool(forKey: "mouseScrollMosLikeSmoothingV16") {
      settings.smooth = true
      settings.speed = ScrollEngineSettings.mosPreset.speed
      settings.step = ScrollEngineSettings.mosPreset.step
      settings.duration = ScrollEngineSettings.mosPreset.duration
      settings.affectTrackpad = false
      defaults.set(true, forKey: "mouseScrollMosLikeSmoothingV16")
      didMigrate = true
    }
    let beforeWindowsHabit = settings
    settings.enforceMouseWheelOnlyWindowsHabit()
    if settings != beforeWindowsHabit {
      didMigrate = true
    }
    if didMigrate, let migratedData = try? JSONEncoder().encode(settings) {
      defaults.set(migratedData, forKey: "scrollEngineSettings")
    }
    return settings
  }

  private func saveScrollSettings() {
    guard let data = try? JSONEncoder().encode(scrollSettings) else { return }
    UserDefaults.standard.set(data, forKey: "scrollEngineSettings")
  }

  func presentAuthorizationCenter() {
    if let presentWindowHandler {
      presentWindowHandler()
    } else {
      showWindowHandler?()
    }
    _ = refreshAuthorizationAndReloadIfNeeded()
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
    refreshAccessibilityStatus()
    let defaults = UserDefaults.standard
    if allRequiredPermissionsComplete {
      defaults.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      defaults.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
      return false
    }

    guard isInstalledInApplications, !runtimeIdentity.isInvalid else { return false }
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

  /// Defer model preparation until the permission sheet and its restart flow have settled.
  func offerTranslationModelSetupIfNeeded() {
    guard isInstalledInApplications, !runtimeIdentity.isInvalid,
      let needsDownload = translationModelNeedsDownloadHandler,
      makeTranslationModelSetupViewHandler != nil
    else { return }
    translationModelSetupOnboarding.offerIfNeeded(
      needsDownload: needsDownload,
      canPresent: { [weak self] in self?.canPresentTranslationModelSetup == true },
      present: { [weak self] in self?.isTranslationModelSetupPresented = true })
  }

  private var canPresentTranslationModelSetup: Bool {
    !isAccessibilityAuthorizationPresented && !isTranslationModelSetupPresented
      && !authorizationAutomaticRelaunchInProgress && !authorizationManualRelaunchRequired
      && pendingAuthorizationRepairServices().isEmpty
  }

  func dismissAuthorizationCenter() {
    isAccessibilityAuthorizationPresented = false
    AppDiagnostics.log(
      "authorization_center_hidden",
      [
        "flowContinues": "\(!pendingAuthorizationRepairServices().isEmpty)",
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
      ])
  }

  func performAuthorizationPrimaryAction() {
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
    beginAuthorizationRelaunchOnce(reason: "userRequested")
  }

  @discardableResult
  private func beginAuthorizationRelaunchOnce(reason: String) -> Bool {
    guard
      authorizationRelaunchAttemptState.handle(.requestAutomaticRelaunch)
        == .beginAutomaticRelaunch
    else { return false }

    authorizationRelaunchCompleted = false
    authorizationAutomaticRelaunchInProgress = true
    authorizationManualRelaunchRequired = false
    AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    AuthorizationDragGuideController.shared.hide()
    isAccessibilityAuthorizationPresented = false
    guard armAuthorizationRelaunchRelay(allowNewAutomaticAttempt: true) else {
      finishAuthorizationAutomaticRelaunchFailure(reason: "relayArmFailed")
      return false
    }

    authorizationRepairResultText = "正在重新打开软件；新进程会自动续上授权进度。"
    statusMessage = authorizationRepairResultText
    AppDiagnostics.log(
      "authorization_automatic_relaunch_requested",
      [
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "reason": reason,
      ])

    authorizationRelaunchFailureWorkItem?.cancel()
    let failureWorkItem = DispatchWorkItem { [weak self] in
      self?.finishAuthorizationAutomaticRelaunchFailure(reason: "oldProcessStillAlive")
    }
    authorizationRelaunchFailureWorkItem = failureWorkItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: failureWorkItem)

    if let authorizationTerminationHandler {
      authorizationTerminationHandler()
    } else {
      NSApp.terminate(nil)
    }
    return true
  }

  private func finishAuthorizationAutomaticRelaunchFailure(reason: String) {
    guard
      authorizationRelaunchAttemptState.handle(.automaticRelaunchFailed)
        == .showManualRelaunchOnly
    else { return }

    authorizationRelaunchFailureWorkItem?.cancel()
    authorizationRelaunchFailureWorkItem = nil
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = true
    AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    AuthorizationDragGuideController.shared.hide()
    disarmAuthorizationRelaunchRelay(reason: "automaticRelaunchFailed:\(reason)")
    authorizationRepairResultText =
      "自动重启没有完成，授权进度已保存。请退出软件，再从“应用程序”手动打开一次。"
    statusMessage = authorizationRepairResultText
    isAccessibilityAuthorizationPresented = true
    if let presentWindowHandler {
      presentWindowHandler()
    } else {
      showWindowHandler?()
    }
    AppDiagnostics.log(
      "authorization_manual_relaunch_required",
      [
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "reason": reason,
      ])
  }

  private func quitAppForManualAuthorizationRelaunch() {
    guard authorizationManualRelaunchRequired else { return }
    AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    AuthorizationDragGuideController.shared.hide()
    isAccessibilityAuthorizationPresented = false
    AppDiagnostics.log(
      "authorization_manual_quit_requested",
      ["pid": "\(ProcessInfo.processInfo.processIdentifier)"])
    if let authorizationTerminationHandler {
      authorizationTerminationHandler()
    } else {
      NSApp.terminate(nil)
    }
  }

  func prepareAuthorizationRelaunchForSystemTerminationIfNeeded() {
    guard !authorizationManualRelaunchRequired else { return }
    let pending = pendingAuthorizationRepairServices()
    guard !pending.isEmpty else { return }
    let currentService =
      authorizationRepairOpenedSettingsService
      ?? AuthorizationRecoveryPolicy.remainingRepairServices(
        pending,
        snapshot: liveAuthorizationPermissionSnapshot()
      ).first
    guard currentService?.mayRequireRelaunch == true || allRequiredPermissionsComplete else {
      return
    }

    let armed = armAuthorizationRelaunchRelay()
    AppDiagnostics.log(
      "authorization_system_termination_checkpointed",
      [
        "armed": "\(armed)",
        "pending": pending.map(\.rawValue).joined(separator: ","),
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "service": currentService?.rawValue ?? "complete",
      ])
  }

  func startAutomaticAuthorization() {
    if authorizationManualRelaunchRequired {
      presentAuthorizationCenter()
      return
    }
    guard !authorizationAutomaticRelaunchInProgress else { return }
    authorizationRelaunchCompleted = false
    refreshAuthorizationAndReloadIfNeeded()
    guard !authorizationAutomaticRelaunchInProgress,
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

    authorizationRelaunchAttemptState.handle(.reset)
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = false

    let defaults = UserDefaults.standard
    defaults.set(
      missingServices.map(\.rawValue),
      forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.set(true, forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.set(
      Int(ProcessInfo.processInfo.processIdentifier),
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()

    authorizationRepairOpenedSettingsService = nextService
    authorizationRepairResultText =
      "请在系统设置中开启\(nextService.displayName)；开启后软件会自动继续下一步。"
    statusMessage = authorizationRepairResultText
    requestAuthorizationRegistration(for: nextService)
  }

  private func repairOnlyMissingAuthorizationAndRelaunch() {
    guard runtimeIdentity.allowsStablePermissionRepair else {
      authorizationRepairResultText = "当前运行版本不是正式安装版，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let expectedBundleID = runtimeIdentity.bundleIdentifier
    let bundleID = appBundleIdentifier
    guard bundleID == expectedBundleID else {
      authorizationRepairResultText = "当前运行版本与正式版身份不一致，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let liveSnapshot = AuthorizationPermissionSnapshot(
      accessibility: AXIsProcessTrusted(),
      inputMonitoring: CGPreflightListenEventAccess(),
      screenRecording: CGPreflightScreenCaptureAccess())
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

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var succeeded: [AuthorizationRepairService] = []
      var failures: [String] = []
      for service in services {
        AppDiagnostics.log(
          "authorization_tcc_reset_start",
          ["bundle": expectedBundleID, "service": service.rawValue])
        let result = BoundedProcessExecution.runSynchronously(
          executableURL: URL(fileURLWithPath: "/usr/bin/tccutil"),
          arguments: AuthorizationRecoveryPolicy.targetedResetArguments(
            service: service,
            bundleIdentifier: expectedBundleID),
          timeout: 5,
          outputByteLimit: 32_768)
        let detail = [result.standardOutput, result.standardError]
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        if result.succeeded {
          succeeded.append(service)
        } else {
          failures.append("\(service.displayName)未能修复")
        }
        AppDiagnostics.log(
          "authorization_tcc_reset_result",
          [
            "bundle": expectedBundleID,
            "service": service.rawValue,
            "exitCode": result.terminationStatus.map(String.init) ?? "unavailable",
            "timedOut": "\(result.timedOut)",
            "truncated": "\(result.outputWasTruncated || result.errorWasTruncated)",
            "launchError": result.launchError ?? "",
            "detail": detail,
          ])
      }

      DispatchQueue.main.async {
        guard let self else { return }
        self.isRepairingAuthorization = false
        self.refreshAuthorizationAndReloadIfNeeded()
        if !succeeded.isEmpty {
          let succeededNames = succeeded.map(\.displayName).joined(separator: "和")
          let failureText = failures.isEmpty ? "" : "；未清除：\(failures.joined(separator: "；"))"
          self.authorizationRepairResultText =
            "只清除了本 App 当前未生效的\(succeededNames)记录\(failureText)。即将自动重启软件，并按顺序直接打开对应系统设置。"
          self.isAccessibilityAuthorizationPresented = false
          self.scheduleAuthorizationRepairRelaunch(pendingServices: succeeded)
        } else {
          self.authorizationRepairResultText =
            "定向修复失败，未清除任何权限。\(failures.joined(separator: "；"))"
        }
        self.statusMessage = self.authorizationRepairResultText
      }
    }
  }

  func clearAuthorizationPermissionsAndRestart(userConfirmed: Bool) {
    guard runtimeIdentity.allowsStablePermissionRepair else {
      authorizationRepairResultText = "当前运行版本不是正式安装版，未重置权限。"
      statusMessage = authorizationRepairResultText
      return
    }
    let expectedBundleID = runtimeIdentity.bundleIdentifier
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

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var succeeded: [AuthorizationRepairService] = []
      var failures: [String] = []
      for service in services {
        AppDiagnostics.log(
          "authorization_explicit_clear_start",
          ["bundle": expectedBundleID, "service": service.rawValue])
        let result = BoundedProcessExecution.runSynchronously(
          executableURL: URL(fileURLWithPath: "/usr/bin/tccutil"),
          arguments: AuthorizationRecoveryPolicy.targetedResetArguments(
            service: service,
            bundleIdentifier: expectedBundleID),
          timeout: 5,
          outputByteLimit: 32_768)
        let detail = [result.standardOutput, result.standardError]
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        if result.succeeded {
          succeeded.append(service)
        } else {
          failures.append("\(service.displayName)未能重置")
        }
        AppDiagnostics.log(
          "authorization_explicit_clear_result",
          [
            "bundle": expectedBundleID,
            "service": service.rawValue,
            "exitCode": result.terminationStatus.map(String.init) ?? "unavailable",
            "timedOut": "\(result.timedOut)",
            "truncated": "\(result.outputWasTruncated || result.errorWasTruncated)",
            "launchError": result.launchError ?? "",
            "detail": detail,
          ])
      }

      DispatchQueue.main.async {
        guard let self else { return }
        self.isRepairingAuthorization = false
        if !succeeded.isEmpty {
          let succeededNames = succeeded.map(\.displayName).joined(separator: "和")
          let failureText = failures.isEmpty ? "" : "；未清除：\(failures.joined(separator: "；"))"
          self.authorizationRepairResultText =
            "已清除本 App 的\(succeededNames)\(failureText)。正在重启并重新进入授权引导。"
          self.statusMessage = self.authorizationRepairResultText
          self.isAccessibilityAuthorizationPresented = false
          self.scheduleAuthorizationRepairRelaunch(pendingServices: succeeded)
        } else {
          self.authorizationRepairResultText =
            "清除失败，现有权限没有被改变。\(failures.joined(separator: "；"))"
          self.statusMessage = self.authorizationRepairResultText
        }
      }
    }
  }

  func handleAuthorizationRepairRelaunchIfNeeded() {
    let pending = pendingAuthorizationRepairServices()
    let didRelaunch = authorizationFlowAlreadyRelaunched
    let requiresRelaunch = UserDefaults.standard.bool(
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
        ["pid": "\(ProcessInfo.processInfo.processIdentifier)"])
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
          "pid": "\(ProcessInfo.processInfo.processIdentifier)",
          "relaunched": "\(didRelaunch)",
          "remaining": remaining.map(\.rawValue).joined(separator: ","),
        ])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        self?.requestAuthorizationRegistration(for: nextService)
      }
    }
  }

  private func scheduleAuthorizationRepairRelaunch(
    pendingServices: [AuthorizationRepairService]
  ) {
    authorizationRelaunchCompleted = false
    authorizationRelaunchAttemptState.handle(.reset)
    authorizationAutomaticRelaunchInProgress = false
    authorizationManualRelaunchRequired = false
    let defaults = UserDefaults.standard
    defaults.set(
      pendingServices.map(\.rawValue),
      forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.set(true, forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.set(
      Int(ProcessInfo.processInfo.processIdentifier),
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
      UserDefaults.standard.stringArray(
        forKey: Self.pendingAuthorizationRepairServicesDefaultsKey) ?? []
    return rawValues.compactMap(AuthorizationRepairService.init(rawValue:))
  }

  private var authorizationFlowAlreadyRelaunched: Bool {
    let rawOwnerPID = UserDefaults.standard.integer(
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    let ownerPID = rawOwnerPID > 0 ? Int32(rawOwnerPID) : nil
    return AuthorizationRelaunchStatePolicy.processAlreadyRelaunched(
      flowOwnerProcessIdentifier: ownerPID,
      currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier)
  }

  private func markCurrentProcessAsAuthorizationFlowOwner() {
    UserDefaults.standard.set(
      Int(ProcessInfo.processInfo.processIdentifier),
      forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    UserDefaults.standard.synchronize()
  }

  private func clearPendingAuthorizationFlow() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: Self.pendingAuthorizationRepairServicesDefaultsKey)
    defaults.removeObject(forKey: Self.restartAfterAuthorizationRepairGrantDefaultsKey)
    defaults.removeObject(forKey: Self.authorizationFlowOwnerPIDDefaultsKey)
    defaults.synchronize()
    authorizationRepairOpenedSettingsService = nil
    authorizationSystemPromptRelaunchScheduled = false
    AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    AuthorizationDragGuideController.shared.hide()
  }

  @discardableResult
  func presentAuthorizationRelaunchResultIfNeeded() -> Bool {
    let defaults = UserDefaults.standard
    let rawSourcePID = defaults.integer(
      forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    let sourcePID = rawSourcePID > 0 ? Int32(rawSourcePID) : nil
    let rawRequestedAt = defaults.double(
      forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    let requestedAt = rawRequestedAt > 0 ? rawRequestedAt : nil
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let shouldPresent = AuthorizationRelaunchPresentationPolicy.shouldPresent(
      sourceProcessIdentifier: sourcePID,
      currentProcessIdentifier: currentPID,
      requestedAt: requestedAt,
      now: Date().timeIntervalSince1970)
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
      AuthorizationDragGuideController.shared.hide()
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
    let defaults = UserDefaults.standard
    defaults.set(
      Int(ProcessInfo.processInfo.processIdentifier),
      forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    defaults.set(
      Date().timeIntervalSince1970,
      forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    defaults.synchronize()
  }

  private func clearAuthorizationRelaunchPresentationRequest() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: Self.authorizationRelaunchPresentationSourcePIDDefaultsKey)
    defaults.removeObject(forKey: Self.authorizationRelaunchPresentationRequestedAtDefaultsKey)
    defaults.synchronize()
  }

  private func requestAuthorizationRegistration(for service: AuthorizationRepairService) {
    guard !authorizationAutomaticRelaunchInProgress,
      !authorizationManualRelaunchRequired
    else { return }
    if service.mayRequireRelaunch {
      armAuthorizationRelaunchRelay()
    } else {
      AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    }
    let opened = openAuthorizationPrivacyPane(for: service)
    if opened {
      let progress = authorizationGuideProgress(for: service)
      AuthorizationDragGuideController.shared.show(
        for: service,
        step: progress.step,
        total: progress.total
      ) { [weak self] in
        self?.requestOfficialAuthorizationRegistration(for: service)
      }
      if service.mayRequireRelaunch {
        authorizationSystemPromptRelaunchScheduled = false
        AuthorizationSystemRelaunchPromptMonitor.shared.start(
          applicationDisplayName: authorizationApplicationDisplayName,
          service: service
        ) { [weak self] in
          Task { @MainActor [weak self] in
            self?.handleAuthorizationSystemRelaunchPrompt(for: service)
          }
        }
      }
      statusMessage =
        "已打开\(service.displayName)设置。列表里没有本 App 时，拖入或双击前台授权卡；然后打开右侧开关。"
    } else {
      AuthorizationDragGuideController.shared.hide()
      AuthorizationSystemRelaunchPromptMonitor.shared.stop()
      if service.mayRequireRelaunch {
        disarmAuthorizationRelaunchRelay(reason: "privacyPaneOpenFailed")
      }
    }
    authorizationPollingRequestHandler?("\(service.rawValue)SettingsOpened")
  }

  private func authorizationGuideProgress(
    for service: AuthorizationRepairService
  ) -> (step: Int, total: Int) {
    let services = AuthorizationRepairService.allCases
    let index = services.firstIndex(of: service) ?? services.startIndex
    return (services.distance(from: services.startIndex, to: index) + 1, services.count)
  }

  private func requestOfficialAuthorizationRegistration(
    for service: AuthorizationRepairService
  ) {
    guard !authorizationRegistrationRequestInFlight,
      authorizationRepairOpenedSettingsService == service,
      pendingAuthorizationRepairServices().contains(service)
    else { return }

    authorizationRegistrationRequestInFlight = true
    AppDiagnostics.log(
      "authorization_official_registration_requested",
      [
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "service": service.rawValue,
        "trigger": "frontGuideDoubleClick",
      ])

    let granted: Bool
    switch service {
    case .accessibility:
      let options = ["AXTrustedCheckOptionPrompt": true]
      granted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    case .screenRecording:
      granted = CGRequestScreenCaptureAccess()
    case .inputMonitoring:
      granted = CGRequestListenEventAccess()
    }

    authorizationRegistrationRequestInFlight = false
    authorizationRepairResultText =
      granted
      ? "macOS 已确认\(service.displayName)；正在核对并继续。"
      : "已向 macOS 请求登记\(service.displayName)。请在系统提示或当前列表中确认，再打开右侧开关。"
    statusMessage = authorizationRepairResultText
    AppDiagnostics.log(
      "authorization_official_registration_returned",
      [
        "granted": "\(granted)",
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "service": service.rawValue,
      ])
    _ = refreshAuthorizationAndReloadIfNeeded()
    if !service.isGranted(in: liveAuthorizationPermissionSnapshot()) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        _ = self?.openAuthorizationPrivacyPane(for: service)
      }
    }
  }

  private var authorizationApplicationDisplayName: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? URL(fileURLWithPath: appBundlePath).deletingPathExtension().lastPathComponent
  }

  private func handleAuthorizationSystemRelaunchPrompt(
    for service: AuthorizationRepairService
  ) {
    guard !authorizationSystemPromptRelaunchScheduled,
      authorizationRepairOpenedSettingsService == service,
      pendingAuthorizationRepairServices().contains(service)
    else { return }

    authorizationSystemPromptRelaunchScheduled = true
    AuthorizationSystemRelaunchPromptMonitor.shared.stop()
    AuthorizationDragGuideController.shared.hide()
    AppDiagnostics.log(
      "authorization_system_prompt_detected",
      [
        "pid": "\(ProcessInfo.processInfo.processIdentifier)",
        "service": service.rawValue,
      ])
    authorizationRepairResultText =
      "macOS 已要求重开；软件正在自动退出，新进程会接着下一项。"
    statusMessage = authorizationRepairResultText
    beginAuthorizationRelaunchOnce(reason: "systemPrompt:\(service.rawValue)")
  }

  @discardableResult
  private func openAuthorizationPrivacyPane(for service: AuthorizationRepairService) -> Bool {
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
      if NSWorkspace.shared.open(url) { return true }
    }
    statusMessage = "无法自动打开系统设置的\(service.displayName)页面，请稍后重试。"
    return false
  }

  @discardableResult
  private func armAuthorizationRelaunchRelay(
    allowNewAutomaticAttempt: Bool = false
  ) -> Bool {
    if let markerURL = authorizationRelaunchRelayMarkerURL {
      if FileManager.default.fileExists(atPath: markerURL.path),
        authorizationRelaunchRelayProcess?.isRunning == true
      {
        return true
      }
      if authorizationRelaunchRelayProcess != nil,
        authorizationRelaunchRelayToken != nil
      {
        AppDiagnostics.log(
          "authorization_relaunch_relay_rearm_blocked",
          ["reason": "awaitingOutcome"])
        return false
      }
      authorizationRelaunchRelayProcess = nil
      try? FileManager.default.removeItem(at: markerURL)
      authorizationRelaunchRelayMarkerURL = nil
      clearAuthorizationRelaunchPresentationRequest()
    }
    switch authorizationRelaunchAttemptState.phase {
    case .manualRelaunchRequired, .finished:
      AppDiagnostics.log(
        "authorization_relaunch_relay_rearm_blocked",
        ["reason": "terminalAttemptState"])
      return false
    case .automaticRelaunchRequested where !allowNewAutomaticAttempt:
      AppDiagnostics.log(
        "authorization_relaunch_relay_rearm_blocked",
        ["reason": "automaticAttemptAlreadyRequested"])
      return false
    case .ready, .automaticRelaunchRequested:
      break
    }
    let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent(
      runtimeIdentity.applicationSupportDirectoryName,
      isDirectory: true)
    let markerURL = supportDirectory.appendingPathComponent(
      "authorization-relaunch-\(ProcessInfo.processInfo.processIdentifier).pending")

    do {
      let relayToken = UUID()
      authorizationRelaunchRelayToken = relayToken
      recordAuthorizationRelaunchPresentationRequest()
      let relay = try AuthorizationRelaunchRelay.arm(
        AuthorizationRelaunchRelayRequest(
          processIdentifier: ProcessInfo.processInfo.processIdentifier,
          bundleIdentifier: appBundleIdentifier,
          markerURL: markerURL,
          applicationURL: URL(fileURLWithPath: appBundlePath))
      ) { [weak self] outcome in
        DispatchQueue.main.async {
          self?.handleAuthorizationRelaunchRelayOutcome(
            outcome,
            token: relayToken)
        }
      }
      authorizationRelaunchRelayProcess = relay
      authorizationRelaunchRelayMarkerURL = markerURL
      AppDiagnostics.log(
        "authorization_relaunch_relay_armed",
        [
          "pid": "\(ProcessInfo.processInfo.processIdentifier)",
          "timeoutSeconds": "300",
        ])
      return true
    } catch {
      try? FileManager.default.removeItem(at: markerURL)
      authorizationRelaunchRelayProcess = nil
      authorizationRelaunchRelayToken = nil
      authorizationRelaunchRelayMarkerURL = nil
      clearAuthorizationRelaunchPresentationRequest()
      AppDiagnostics.log(
        "authorization_relaunch_relay_arm_failed",
        ["error": error.localizedDescription])
      return false
    }
  }

  private func handleAuthorizationRelaunchRelayOutcome(
    _ outcome: AuthorizationRelaunchRelayOutcome,
    token: UUID
  ) {
    guard authorizationRelaunchRelayToken == token else { return }
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
    guard markerURL != nil || relayProcess != nil else { return }
    authorizationRelaunchRelayToken = nil
    if relayProcess?.isRunning == true {
      relayProcess?.terminate()
    }
    authorizationRelaunchRelayProcess = nil
    if let markerURL {
      try? FileManager.default.removeItem(at: markerURL)
    }
    authorizationRelaunchRelayMarkerURL = nil
    clearAuthorizationRelaunchPresentationRequest()
    AppDiagnostics.log("authorization_relaunch_relay_disarmed", ["reason": reason])
  }

  func quitAppForAccessibilityReauthorization() {
    NSApp.terminate(nil)
  }

  private func liveAuthorizationPermissionSnapshot() -> AuthorizationPermissionSnapshot {
    AuthorizationPermissionSnapshot(
      accessibility: AXIsProcessTrusted(),
      inputMonitoring: CGPreflightListenEventAccess(),
      screenRecording: CGPreflightScreenCaptureAccess())
  }

  func refreshAccessibilityStatus() {
    let snapshot = liveAuthorizationPermissionSnapshot()
    advancedListeningAuthorized = snapshot.accessibility
    inputMonitoringAuthorized = snapshot.inputMonitoring
    screenRecordingAuthorized = snapshot.screenRecording
    if snapshot.allEventTapPermissionsGranted {
      authorizationRecheckFailed = false
      UserDefaults.standard.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      UserDefaults.standard.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
    }
  }

  @discardableResult
  func refreshAuthorizationAndReloadIfNeeded() -> Bool {
    let previousSnapshot = authorizationHotReloadState.permissions
    let snapshot = liveAuthorizationPermissionSnapshot()
    let changed = authorizationHotReloadState.observe(snapshot)
    integratedFeaturePermissionsDidChangeHandler?(previousSnapshot, snapshot)
    let eventTapChanged =
      previousSnapshot.accessibility != snapshot.accessibility
      || previousSnapshot.inputMonitoring != snapshot.inputMonitoring
    advancedListeningAuthorized = snapshot.accessibility
    inputMonitoringAuthorized = snapshot.inputMonitoring
    screenRecordingAuthorized = snapshot.screenRecording
    if snapshot.allEventTapPermissionsGranted {
      authorizationRecheckFailed = false
      UserDefaults.standard.set(true, forKey: Self.authorizationWasCompleteDefaultsKey)
      UserDefaults.standard.removeObject(
        forKey: Self.authorizationLastPromptedMissingFingerprintDefaultsKey)
      AuthorizationSystemRelaunchPromptMonitor.shared.stop()
      AuthorizationDragGuideController.shared.hideDragPromptIfNeeded()
    }
    refreshCapsCoreConflictIfNeeded()

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

    authorizationReloadWorkItem?.cancel()
    authorizationReloadWorkItem = nil
    if !snapshot.allEventTapPermissionsGranted {
      authorizationRelaunchCompleted = false
      UserDefaults.standard.removeObject(
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
    let defaults = UserDefaults.standard
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.requestAuthorizationRegistration(for: nextService)
    }
    return true
  }

  private func reloadPermissionDependentListeners() {
    reloadHotkeys()
    reloadPhraseExpander()
    reloadCapsCorePlugin(requestPermission: false)
    reloadInputMethodPlugin()
    reloadScrollEngine()
    reloadClassicTabSwitcher()
  }

  private func performAuthorizationHotReload(trigger: String) {
    reloadPermissionDependentListeners()
    let verification = authorizationListenerVerification()
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
      UserDefaults.standard.removeObject(
        forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
      statusMessage = "授权已生效，后台监听已恢复。"
    case .retryHotReload(let attempt):
      let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.authorizationReloadWorkItem = nil
        let snapshot = AuthorizationPermissionSnapshot(
          accessibility: AXIsProcessTrusted(),
          inputMonitoring: CGPreflightListenEventAccess(),
          screenRecording: CGPreflightScreenCaptureAccess())
        guard snapshot == self.authorizationHotReloadState.permissions else {
          _ = self.refreshAuthorizationAndReloadIfNeeded()
          return
        }
        guard snapshot.allEventTapPermissionsGranted else { return }
        self.performAuthorizationHotReload(trigger: "boundedRetry\(attempt)")
      }
      authorizationReloadWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    case .scheduleSingleRelaunch:
      scheduleAuthorizationHotReloadRelaunch(failedListeners: verification.failed)
    case .manualRelaunchRequired:
      statusMessage = "授权已具备，但后台监听仍未恢复。请手动退出并重新打开 App。"
    }
  }

  private func authorizationListenerVerification() -> AuthorizationListenerVerification {
    guard hasGlobalInputOwnership else {
      return AuthorizationListenerVerification(required: [], failed: [])
    }
    var required: [String] = []
    var failed: [String] = []

    if let health = hotkeyManager?.listenerHealth, health.advancedListenerRequired {
      required.append("hotkeys")
      if !health.advancedListenerRunning { failed.append("hotkeys") }
    }
    if let phraseExpander, phraseExpander.requiresListening {
      required.append("phrases")
      if !phraseExpander.isListening { failed.append("phrases") }
    }
    if capsCorePluginEnabled && detectedCapsCoreConflict == nil && !isPaused {
      required.append("capsCore")
      if capsCoreEngine?.isRunning != true { failed.append("capsCore") }
    }
    if scrollSettings.needsEventTap {
      required.append("scroll")
      if scrollEngine?.isRunning != true { failed.append("scroll") }
    }
    if !Self.classicTabSwitcherRetired && classicTabSwitcherEnabled && !isPaused {
      required.append("classicTab")
      if classicTabSwitcher?.isRunning != true { failed.append("classicTab") }
    }

    return AuthorizationListenerVerification(required: required, failed: failed)
  }

  private func scheduleAuthorizationHotReloadRelaunch(failedListeners: [String]) {
    UserDefaults.standard.set(
      true, forKey: Self.authorizationHotReloadRelaunchAttemptedDefaultsKey)
    UserDefaults.standard.synchronize()

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

  private func verifyAuthorizationHotReloadAfterRelaunchIfNeeded() {
    let defaults = UserDefaults.standard
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
    let bundlePath = appBundlePath
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=4", bundlePath],
      timeout: 3,
      outputByteLimit: 65_536
    ) { [weak self] result in
      guard let self else { return }
      if result.succeeded {
        self.appSignatureSummary = Self.signatureSummary(from: result.standardError)
      } else if let launchError = result.launchError {
        self.appSignatureSummary = "签名读取失败：\(launchError)"
      } else {
        self.appSignatureSummary = "签名读取失败"
      }
    }.start()
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

  func isRecording(_ itemID: String) -> Bool {
    recordingItemID == itemID
  }

  func startRecording(itemID: String) {
    if recordingItemID == itemID, shortcutRecordingSession != nil {
      enableAfterRecordingItemIDs.remove(itemID)
      stopRecording()
      statusMessage = "已取消快捷键录入。"
      return
    }
    shortcutRecordingConflictNotice = nil
    beginShortcutTriggerRecording(target: .item(itemID), draftHandler: nil)
  }

  func toggleDraftShortcutRecording(
    onCaptured: @escaping (ShortcutTriggerRecordingValue) -> Void
  ) {
    if isDraftShortcutRecording, shortcutRecordingSession != nil {
      stopRecording()
      statusMessage = "已取消快捷键录入。"
      return
    }
    shortcutRecordingConflictNotice = nil
    beginShortcutTriggerRecording(target: .draft, draftHandler: onCaptured)
  }

  func cancelDraftShortcutRecording() {
    guard isDraftShortcutRecording else { return }
    stopRecording()
    statusMessage = "已取消快捷键录入。"
  }

  private func beginShortcutTriggerRecording(
    target: ShortcutRecordingTarget,
    draftHandler: ((ShortcutTriggerRecordingValue) -> Void)?
  ) {
    hotkeyReloadWorkItem?.cancel()
    hotkeyReloadWorkItem = nil
    stopShortcutTriggerRecording(reloadHotkeys: true)
    if shortcutActionCaptureItemID != nil {
      shortcutActionCaptureItemID = nil
      shortcutActionCaptureDraft = ""
    }

    let session = ShortcutRecordingSession(id: UUID(), target: target)
    shortcutRecordingSession = session
    draftShortcutRecordingHandler = draftHandler
    switch target {
    case .item(let itemID):
      recordingItemID = itemID
      isDraftShortcutRecording = false
    case .draft:
      recordingItemID = nil
      isDraftShortcutRecording = true
    }

    let tapStarted = startRecordingTapIfPossible(sessionID: session.id)
    let modifierStarted = startRecordingModifierListener(sessionID: session.id)
    if !hotkeysSuspendedForRecording {
      if hasGlobalInputOwnership {
        hotkeyManager?.suspendAll()
      }
      // A recording session may begin while the runtime is waiting for the global-input lease.
      // If ownership arrives before this session ends, reloadHotkeys()
      // deliberately keeps registrations suspended until the recorder releases them here.
      hotkeysSuspendedForRecording = true
    }

    if !hasGlobalInputOwnership {
      statusMessage = globalInputOwnershipBlockedMessage
    } else if tapStarted, modifierStarted {
      statusMessage = "录制中：按普通组合键，或连按同一个实体修饰键两次。再点一下取消。"
    } else if modifierStarted {
      statusMessage = "录制中：可连按实体修饰键两次；系统保留组合键需辅助功能授权。"
    } else if tapStarted {
      statusMessage = "录制中：可录入普通组合键；实体修饰键需输入监控权限和物理键盘。"
    } else {
      statusMessage = "录制未开始：请开启辅助功能和输入监控权限后重试。"
    }

    let owner = session.id
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.shortcutRecordingSession?.id == owner else { return }
      self.stopRecording()
      self.statusMessage = "已取消快捷键录入。"
    }
    recordingTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  func setPhysicalRightOptionDoubleTapTrigger(itemID: String) {
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
      shortcutGuideRequestedCategory = "全部"
      shortcutGuideRequestedSearchText = ""
      shortcutGuideFocusRequest += 1
      statusMessage = "\(trigger.displayText) 已被「\(conflict.name)」占用。"
      return
    }
    let originalItem = items[index]
    let originalSelectedID = selectedID
    let shouldEnableAfterRecording = enableAfterRecordingItemIDs.contains(itemID)
    if recordingItemID == itemID {
      stopRecording()
    }
    items[index].trigger = trigger
    if enableAfterRecordingItemIDs.remove(itemID) != nil {
      items[index].enabled = true
    }
    selectedID = itemID
    guard saveAndReload() else {
      items[index] = originalItem
      selectedID = originalSelectedID
      if shouldEnableAfterRecording {
        enableAfterRecordingItemIDs.insert(itemID)
      }
      return
    }
    statusMessage = "已识别并生效：\(trigger.displayText)。"
  }

  func stopRecording() {
    stopShortcutTriggerRecording(reloadHotkeys: true)
  }

  private func stopShortcutTriggerRecording(reloadHotkeys shouldReloadHotkeys: Bool) {
    recordingTimeout?.cancel()
    recordingTimeout = nil
    shortcutRecordingSession = nil
    recordingItemID = nil
    isDraftShortcutRecording = false
    draftShortcutRecordingHandler = nil
    stopRecordingTap()
    recordingModifierListener?.stop()
    recordingModifierListener = nil
    if hotkeysSuspendedForRecording {
      hotkeysSuspendedForRecording = false
      if shouldReloadHotkeys {
        reloadHotkeys()
      }
    }
  }

  @discardableResult
  private func startRecordingTapIfPossible(sessionID: UUID) -> Bool {
    stopRecordingTap()
    guard hasGlobalInputOwnership else {
      statusMessage = globalInputOwnershipBlockedMessage
      return false
    }
    guard AXIsProcessTrusted() else { return false }
    let mask = 1 << CGEventType.keyDown.rawValue
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let context = Unmanaged<ShortcutRecordingTapContext>.fromOpaque(userInfo)
        .takeUnretainedValue()
      guard let model = context.model else {
        return Unmanaged.passUnretained(event)
      }
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        model.reenableRecordingTap(sessionID: context.sessionID)
        return Unmanaged.passUnretained(event)
      }
      guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
      }
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      let flags = event.flags
      let sessionID = context.sessionID
      DispatchQueue.main.async {
        model.applyRecorded(keyCode: keyCode, flags: flags, sessionID: sessionID)
      }
      return nil
    }
    let context = ShortcutRecordingTapContext(model: self, sessionID: sessionID)
    recordingTapContext = context
    recordingTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: Unmanaged.passUnretained(context).toOpaque()
    )
    guard let recordingTap else {
      recordingTapContext = nil
      statusMessage = "高级录入启动失败：请重新授权辅助功能后重试。"
      return false
    }
    recordingTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, recordingTap, 0)
    if let recordingTapSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), recordingTapSource, .commonModes)
    }
    CGEvent.tapEnable(tap: recordingTap, enable: true)
    return true
  }

  private func stopRecordingTap() {
    if let recordingTap {
      CGEvent.tapEnable(tap: recordingTap, enable: false)
    }
    if let recordingTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), recordingTapSource, .commonModes)
    }
    recordingTapSource = nil
    recordingTap = nil
    recordingTapContext = nil
  }

  private func reenableRecordingTap(sessionID: UUID) {
    guard shortcutRecordingSession?.id == sessionID, let recordingTap else { return }
    CGEvent.tapEnable(tap: recordingTap, enable: true)
  }

  @discardableResult
  private func startRecordingModifierListener(sessionID: UUID) -> Bool {
    recordingModifierListener?.stop()
    recordingModifierListener = nil
    guard hasGlobalInputOwnership, CGPreflightListenEventAccess() else { return false }

    let listener = PhysicalModifierDoubleTapHIDListener(
      modifiers: Set(PhysicalModifierKey.allCases),
      onTrigger: { [weak self] modifier in
        self?.applyRecorded(
          trigger: ShortcutTrigger(kind: .modifierDoubleTap, modifier: modifier),
          sessionID: sessionID)
      },
      onNotice: { [weak self] notice in
        guard let self, self.shortcutRecordingSession?.id == sessionID else { return }
        switch notice {
        case .permissionLost:
          self.statusMessage = "实体修饰键录入已停止：请重新开启输入监控权限。"
        case .physicalKeyboardUnavailable:
          self.statusMessage = "未检测到可用物理键盘；仍可录入普通组合键。"
        default:
          break
        }
      })
    guard listener.start() else { return false }
    recordingModifierListener = listener
    return listener.hasAcceptedPhysicalKeyboard
  }

  func cancelRecordingIfNeeded() {
    guard isRecording else { return }
    if let recordingItemID {
      enableAfterRecordingItemIDs.remove(recordingItemID)
    }
    stopRecording()
    statusMessage = "已取消快捷键录入。"
  }

  func beginShortcutActionCapture(itemID: String) {
    guard canChangeShortcutAction(id: itemID) else {
      statusMessage = shortcutActionChangeHelp(id: itemID)
      return
    }
    cancelRecordingIfNeeded()
    selectedID = itemID
    shortcutActionCaptureItemID = itemID
    if let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].action == .sendShortcut
    {
      shortcutActionCaptureDraft = items[index].target
    } else {
      shortcutActionCaptureDraft = ""
    }
    statusMessage = "正在录入要发送的按键。"
  }

  func cancelShortcutActionCapture() {
    shortcutActionCaptureItemID = nil
    shortcutActionCaptureDraft = ""
    statusMessage = "已取消发送按键设置。"
  }

  func applyShortcutActionCaptured(_ event: NSEvent) {
    guard let key = keyName(for: UInt32(event.keyCode)) else {
      statusMessage = "这个按键暂不支持，请换一个常规按键。"
      return
    }
    let modifiers = modifierNames(from: event.modifierFlags)
    if modifiers.isEmpty && !canUseBareSendShortcut(key) {
      statusMessage = "未保存：\(ShortcutItem.prettyKey(key)) 会劫持普通输入，请至少加 ⌃ / ⌥ / ⇧ / ⌘。"
      return
    }
    shortcutActionCaptureDraft = displayHotkeyText(key: key, modifiers: modifiers)
    statusMessage = "已录入：\(shortcutActionCaptureDraft)。"
  }

  func confirmShortcutActionCapture() {
    guard let itemID = shortcutActionCaptureItemID,
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
    shortcutActionCaptureItemID = nil
    shortcutActionCaptureDraft = ""
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

  func applyRecorded(_ event: NSEvent) {
    guard let sessionID = shortcutRecordingSession?.id else { return }
    applyRecorded(
      keyCode: UInt32(event.keyCode),
      modifiers: modifierNames(from: event.modifierFlags),
      sessionID: sessionID)
  }

  func applyRecorded(keyCode: UInt32, flags: CGEventFlags) {
    guard let sessionID = shortcutRecordingSession?.id else { return }
    applyRecorded(
      keyCode: keyCode,
      modifiers: modifierNames(from: flags),
      sessionID: sessionID)
  }

  private func applyRecorded(keyCode: UInt32, flags: CGEventFlags, sessionID: UUID) {
    applyRecorded(keyCode: keyCode, modifiers: modifierNames(from: flags), sessionID: sessionID)
  }

  private func applyRecorded(keyCode: UInt32, modifiers: [String], sessionID: UUID) {
    guard let session = shortcutRecordingSession, session.id == sessionID else { return }
    if keyCode == 53 {
      if let recordingItemID {
        enableAfterRecordingItemIDs.remove(recordingItemID)
      }
      stopRecording()
      statusMessage = "已取消录制。"
      return
    }
    guard let key = keyName(for: keyCode) else {
      stopRecording()
      statusMessage = "这个按键暂不支持，请换一个常规按键。"
      return
    }
    if modifiers.isEmpty && requiresModifier(key) {
      stopRecording()
      statusMessage = "未保存：\(ShortcutItem.prettyKey(key)) 会劫持普通输入，请至少加 ⌃ / ⌥ / ⇧ / ⌘。"
      return
    }

    if case .draft = session.target {
      let handler = draftShortcutRecordingHandler
      let value = ShortcutTriggerRecordingValue(key: key, modifiers: modifiers, trigger: nil)
      stopRecording()
      handler?(value)
      statusMessage = "已识别：\(value.displayText)。"
      return
    }

    guard case .item(let itemID) = session.target,
      let index = items.firstIndex(where: { $0.id == itemID })
    else {
      stopRecording()
      statusMessage = "未找到正在编辑的快捷键。"
      return
    }
    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    let signature = chordTriggerSignature(key: key, modifiers: modifiers)
    let disabledMissingNames = disableMissingOpenAppShortcuts(
      excluding: itemID,
      matchingSignature: signature
    )
    let conflicts = conflictingHotkeyItems(
      excluding: itemID,
      key: key,
      modifiers: modifiers
    )
    if let conflict = conflicts.first,
      !canTransferLauncherHotkeyConflicts(currentItem: items[index], conflicts: conflicts)
    {
      items = originalItems
      enableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
      stopRecording()
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
      shortcutGuideRequestedCategory = "全部"
      shortcutGuideRequestedSearchText = ""
      shortcutGuideFocusRequest += 1
      statusMessage = shortcutRecordingConflictNotice?.message ?? "\(displayHotkey) 已被占用。"
      return
    }
    let transferredNames = disabledMissingNames + disableLauncherHotkeyConflicts(conflicts)
    items[index].key = key
    items[index].modifiers = modifiers
    items[index].trigger = nil
    if enableAfterRecordingItemIDs.remove(itemID) != nil {
      items[index].enabled = true
    }
    disableDuplicateLauncherShortcuts(keeping: itemID)
    let displayHotkey = items[index].displayHotkey
    stopShortcutTriggerRecording(reloadHotkeys: false)
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

  private func applyRecorded(trigger: ShortcutTrigger, sessionID: UUID) {
    guard let session = shortcutRecordingSession, session.id == sessionID else { return }
    if case .draft = session.target {
      let handler = draftShortcutRecordingHandler
      let value = ShortcutTriggerRecordingValue(key: "", modifiers: [], trigger: trigger)
      stopRecording()
      handler?(value)
      statusMessage = "已识别：\(trigger.displayText)。"
      return
    }
    guard case .item(let itemID) = session.target,
      let index = items.firstIndex(where: { $0.id == itemID })
    else {
      stopRecording()
      statusMessage = "未找到正在编辑的快捷键。"
      return
    }
    let signature = trigger.signature
    if let conflict = items.first(where: {
      $0.id != itemID && itemConsumesHotkey($0)
        && shortcutTriggerSignature(for: $0) == signature
    }) {
      stopRecording()
      selectedID = conflict.id
      shortcutGuideRequestedCategory = "全部"
      shortcutGuideRequestedSearchText = ""
      shortcutGuideFocusRequest += 1
      statusMessage = "\(trigger.displayText) 已被「\(conflict.name)」占用。"
      return
    }

    let originalItems = items
    let originalSelectedID = selectedID
    let originalEnableAfterRecordingItemIDs = enableAfterRecordingItemIDs
    items[index].trigger = trigger
    if enableAfterRecordingItemIDs.remove(itemID) != nil {
      items[index].enabled = true
    }
    selectedID = itemID
    stopShortcutTriggerRecording(reloadHotkeys: false)
    guard saveAndReload() else {
      items = originalItems
      selectedID = originalSelectedID
      enableAfterRecordingItemIDs = originalEnableAfterRecordingItemIDs
      reloadHotkeys()
      return
    }
    statusMessage = "已识别并生效：\(trigger.displayText)。"
  }

  private func disableDuplicateLauncherShortcuts(keeping itemID: String) {
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

  private func conflictingHotkeyItems(
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

  private func itemConsumesHotkey(_ item: ShortcutItem) -> Bool {
    guard item.enabled else { return false }
    if item.action == .openApp {
      return openAppTargetExists(item.target)
    }
    return true
  }

  private func shortcutCompletionIssue(for item: ShortcutItem) -> ShortcutIssue? {
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

  private func conflictingExecutableItem(for item: ShortcutItem) -> ShortcutItem? {
    let signature = shortcutTriggerSignature(for: item)
    return items.first { candidate in
      candidate.id != item.id && itemConsumesHotkey(candidate)
        && shortcutTriggerSignature(for: candidate) == signature
    }
  }

  private func disabledExecutableCollision(for item: ShortcutItem) -> ShortcutItem? {
    let signature = shortcutTriggerSignature(for: item)
    return items.first { candidate in
      candidate.id != item.id && !candidate.enabled
        && shortcutTriggerSignature(for: candidate) == signature
    }
  }

  private func hotkeyFailureText(for item: ShortcutItem) -> String? {
    hotkeyFailures.first { failure in
      failure.contains(item.name) || failure.contains(item.displayHotkey)
    }
  }

  private func canTransferLauncherHotkeyConflicts(
    currentItem: ShortcutItem,
    conflicts: [ShortcutItem]
  ) -> Bool {
    guard isLauncherOpenAppShortcut(currentItem), !conflicts.isEmpty else { return false }
    return conflicts.allSatisfy(isLauncherOpenAppShortcut)
  }

  private func disableLauncherHotkeyConflicts(_ conflicts: [ShortcutItem]) -> [String] {
    var disabledNames: [String] = []
    let conflictIDs = Set(conflicts.map(\.id))
    for index in items.indices where conflictIDs.contains(items[index].id) {
      guard items[index].enabled else { continue }
      items[index].enabled = false
      disabledNames.append(shortcutAppName(items[index]))
    }
    return disabledNames
  }

  private func isLauncherOpenAppShortcut(_ item: ShortcutItem) -> Bool {
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

  private func shortcutAppName(_ item: ShortcutItem) -> String {
    var name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("打开 ") {
      name.removeFirst(3)
    } else if name.hasPrefix("打开") {
      name.removeFirst(2)
    }
    return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.name : name
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
    cancelStaleAppActivations(keeping: appActivationKeyForOpenAppTarget(trimmed))
    if let normalizedTarget = normalizedOpenAppTarget(trimmed),
      normalizedTarget.hasPrefix("bundle:")
    {
      let bundleID = String(normalizedTarget.dropFirst("bundle:".count))
      toggleBundleApp(bundleID, mode: mode, completion: completion)
      return
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      toggleBundleApp(bundleID, mode: mode, completion: completion)
      return
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      let url = URL(fileURLWithPath: expanded)
      if url.pathExtension == "app" {
        toggleApp(at: url, mode: mode, completion: completion)
      } else {
        completion?(NSWorkspace.shared.open(url))
      }
      return
    }
    if toggleRunningApp(named: trimmed, mode: mode) {
      completion?(true)
      return
    }
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"),
      arguments: ["-a", trimmed],
      timeout: 8
    ) { result in
      completion?(result.succeeded)
    }.start()
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
      return activationKey(forBundleID: bundleID)
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      return activationKey(forBundleID: bundleID)
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      let url = URL(fileURLWithPath: expanded)
      if url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier {
        return activationKey(forBundleID: bundleID)
      }
    }
    if let app = preferredRunningApplication(named: trimmed) {
      return activationKey(for: app)
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
        || preferredRunningApplication(bundleID: bundleID) != nil
    }
    if trimmed.hasPrefix("bundle:") {
      let bundleID = String(trimmed.dropFirst("bundle:".count))
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        || preferredRunningApplication(bundleID: bundleID) != nil
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return FileManager.default.fileExists(atPath: expanded)
    }
    return installedApplicationURL(named: trimmed) != nil
      || preferredRunningApplication(named: trimmed) != nil
  }

  private func repairMissingDefaultBrowserShortcut() -> Bool {
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

  private func isDefaultChromeBrowserShortcut(_ item: ShortcutItem) -> Bool {
    item.action == .openApp
      && item.name == "打开 Chrome"
      && item.key == "E"
      && Set(item.modifiers) == Set(["control", "option"])
      && (normalizedOpenAppTarget(item.target) ?? item.target) == "bundle:com.google.Chrome"
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

  private func toggleBundleApp(
    _ bundleID: String,
    mode: OpenAppTriggerMode = .toggle,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
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
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"),
      arguments: ["-b", bundleID],
      timeout: 8
    ) { [weak self] result in
      guard let self else { return }
      if result.succeeded {
        self.reinforceColdLaunchForeground(bundleID: bundleID, activation: activation)
      }
      completion?(result.succeeded)
    }.start()
  }

  private func toggleApp(
    at url: URL,
    mode: OpenAppTriggerMode = .toggle,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    if let bundleID = Bundle(url: url)?.bundleIdentifier,
      let app = preferredRunningApplication(bundleID: bundleID)
    {
      toggleRunningApp(app, mode: mode)
      completion?(true)
      return
    }
    openApplication(at: url, completion: completion)
  }

  private func preferredRunningApplication(bundleID: String) -> NSRunningApplication? {
    preferredRunningApplication {
      $0.bundleIdentifier == bundleID
    }
  }

  private func preferredRunningApplication(named name: String) -> NSRunningApplication? {
    preferredRunningApplication {
      ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
    }
  }

  private func preferredRunningApplication(
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

  private struct AppActivationToken {
    let key: String
    let value: UInt64
  }

  private func activationKey(for app: NSRunningApplication) -> String? {
    if let bundleID = app.bundleIdentifier {
      return activationKey(forBundleID: bundleID)
    }
    return "pid:\(app.processIdentifier)"
  }

  private func activationKey(forBundleID bundleID: String) -> String {
    "bundle:\(bundleID)"
  }

  private func issueAppActivationToken(for key: String?) -> AppActivationToken? {
    guard let key else { return nil }
    cancelAppActivationWorkItems(for: key, reason: "new_owner_same_key")
    appActivationSequence &+= 1
    appActivationTokens[key] = appActivationSequence
    AppDiagnostics.log(
      "app_foreground_repair_owner_started",
      ["key": key, "token": "\(appActivationSequence)"])
    return AppActivationToken(key: key, value: appActivationSequence)
  }

  private func invalidateAppActivation(for key: String?) {
    guard let key else { return }
    cancelAppActivationWorkItems(for: key, reason: "activation_invalidated")
    appActivationTokens.removeValue(forKey: key)
  }

  private func cancelAppForegroundRepair(for app: NSRunningApplication, reason: String) {
    guard let key = activationKey(for: app) else { return }
    let token = appActivationTokens[key]
    cancelAppActivationWorkItems(for: key, reason: reason)
    appActivationTokens.removeValue(forKey: key)
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

  private func cancelStaleAppActivations(keeping currentKey: String?) {
    let staleKeys = appActivationTokens.keys.filter { key in
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
    guard let token else { return true }
    return appActivationTokens[token.key] == token.value
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
      payload["currentToken"] = appActivationTokens[activation.key].map(String.init) ?? "none"
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
    let key = activation?.key ?? fallbackKey
    guard let key else {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
      return
    }

    var workItem: DispatchWorkItem?
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if let workItem {
        self.removeAppActivationWorkItem(workItem, forKey: key)
        guard !workItem.isCancelled else { return }
      }
      guard self.isAppActivationCurrent(activation) else {
        self.logStaleAppActivationIgnored(
          event: "app_foreground_repair_stale_ignored",
          bundleID: bundleID,
          activation: activation,
          delay: delay,
          reason: reason)
        return
      }
      execute()
    }
    workItem = item
    appActivationWorkItems[key, default: []].append(item)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func cancelAppActivationWorkItems(for key: String, reason: String) {
    guard let items = appActivationWorkItems.removeValue(forKey: key), !items.isEmpty else {
      return
    }
    for item in items {
      item.cancel()
    }
    AppDiagnostics.log(
      "app_foreground_repair_owner_cancelled",
      ["count": "\(items.count)", "key": key, "reason": reason])
  }

  private func removeAppActivationWorkItem(_ workItem: DispatchWorkItem, forKey key: String) {
    guard var items = appActivationWorkItems[key] else { return }
    items.removeAll { $0 === workItem }
    if items.isEmpty {
      appActivationWorkItems.removeValue(forKey: key)
    } else {
      appActivationWorkItems[key] = items
    }
  }

  private func completeAppForegroundRepairOwner(for app: NSRunningApplication, reason: String) {
    guard let key = activationKey(for: app), let token = appActivationTokens[key] else { return }
    cancelAppActivationWorkItems(for: key, reason: "owner_completed")
    appActivationTokens.removeValue(forKey: key)
    AppDiagnostics.log(
      "app_foreground_repair_owner_completed",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "key": key,
        "reason": reason,
        "token": "\(token)",
      ])
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
    ensureWindow: Bool
  ) -> Bool {
    guard appActivationIsSatisfied(app, ensureWindow: ensureWindow) else { return false }
    if let bundleID = app.bundleIdentifier {
      clearAppForegroundActivationPending(bundleID)
    }
    completeAppForegroundRepairOwner(for: app, reason: "satisfied")
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
  private func toggleRunningApp(named name: String, mode: OpenAppTriggerMode = .toggle) -> Bool {
    guard let app = preferredRunningApplication(named: name) else {
      return false
    }
    toggleRunningApp(app, mode: mode)
    return true
  }

  private func toggleRunningApp(_ app: NSRunningApplication, mode: OpenAppTriggerMode = .toggle) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak app] in
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
    let appActivationKey = activationKey(for: app)
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
    if clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) {
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
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: true) else { return }
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
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
        return
      }
      _ = self.activateRunningAppFast(app, activation: activation)
      guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
        guard !self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow) else {
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
        _ = self.clearForegroundActivationIfSatisfied(app, ensureWindow: ensureWindow)
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

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true) {
          didReachFront = true
          return
        }

        AppDiagnostics.log(
          "app_cold_launch_reinforce",
          ["bundle": bundleID, "delay": String(format: "%.2f", delay)])
        _ = self.activateRunningAppFast(app, ensureWindow: true, activation: activation)

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true) {
          didReachFront = true
          return
        }

        if delay >= 1.0 {
          self.activateRunningAppThroughAppleScript(app, activation: activation)
        } else {
          self.activateRunningAppThroughWorkspace(app, activation: activation)
        }

        if self.clearForegroundActivationIfSatisfied(app, ensureWindow: true) {
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

    reopenRunningApplication(app)
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
    runAppleScript(script, timeout: 2) { [weak self, weak app] ok in
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
          "ok": "\(ok)",
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
      reopenRunningApplication(app)
    }
    activateRunningAppThroughWorkspace(app, activation: activation)
    restoreAndRaiseWindows(for: app)
    AppDiagnostics.log("app_repair_end", ["app": appName, "frontmost": "\(isFrontmost(app))"])
  }

  private func restoreAndRaiseWindows(for app: NSRunningApplication) {
    guard AXIsProcessTrusted() else { return }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let window =
      focusedWindow(for: appElement) ?? controllableWindow(for: appElement)
      ?? axWindows(for: app).first
    guard let window else { return }
    let title = axWindowTitle(window)
    let minimizedBefore = isWindowMinimized(window)
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
      axFocusedTitle: focusedWindow(for: appElement).map(axWindowTitle) ?? "",
      axMainTitle: mainWindow(for: appElement).map(axWindowTitle) ?? ""
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

  private func reopenRunningApplication(_ app: NSRunningApplication) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let bundleID = app.bundleIdentifier {
      process.arguments = ["-b", bundleID]
    } else if let url = app.bundleURL {
      process.arguments = [url.path]
    } else {
      return
    }
    try? process.run()
  }

  @discardableResult
  private func openApplicationsUI() -> Bool {
    let opened = NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    guard opened else {
      statusMessage = "打开 App 软件界面失败。"
      return false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
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
    let activation: AppActivationToken?
    if let bundleID {
      activation = issueAppActivationToken(for: activationKey(forBundleID: bundleID))
    } else {
      activation = nil
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
        guard let self else { return }
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

  private func openURL(_ target: String) {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: value),
      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    else {
      statusMessage = "网址无效：\(target)"
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func runShell(_ command: String) {
    let resolvedCommand = pluginShellCommand(for: command) ?? command
    let trimmedCommand = resolvedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else {
      statusMessage = "脚本命令为空。"
      return
    }
    let displayName = shellDisplayName(for: command)
    let auditKind = shellAuditKind(for: command)
    statusMessage = "正在运行\(displayName)..."
    AppDiagnostics.log("shell_start", ["kind": auditKind])

    shellExecutionGeneration &+= 1
    let generation = shellExecutionGeneration
    shellExecution?.cancel()
    let execution = BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-lc", trimmedCommand],
      timeout: 15,
      outputByteLimit: 131_072
    ) { [weak self] result in
      guard let self, self.shellExecutionGeneration == generation else { return }
      self.shellExecution = nil
      let message: String
      if let launchError = result.launchError {
        message = "\(displayName)启动失败：\(launchError)"
      } else if result.timedOut {
        message = "\(displayName)超过 15 秒，已取消。"
      } else if result.cancelled {
        return
      } else {
        message = Self.shellFeedbackMessage(
          displayName: displayName,
          exitCode: result.terminationStatus ?? -1,
          output: result.standardOutput,
          error: result.standardError
        )
      }
      AppDiagnostics.log(
        "shell_finished",
        [
          "kind": auditKind,
          "exitCode": result.terminationStatus.map(String.init) ?? "none",
          "timedOut": "\(result.timedOut)",
          "truncated": "\(result.outputWasTruncated || result.errorWasTruncated)",
        ]
      )
      self.statusMessage = message
    }
    shellExecution = execution.start()
  }

  private func shellAuditKind(for target: String) -> String {
    if target.hasPrefix("plugin:") { return "bundled_plugin" }
    if target.hasPrefix("shortcuts run ") { return "apple_shortcut" }
    if target.hasPrefix("osascript ") { return "apple_script" }
    if target.hasPrefix("defaults ") { return "system_defaults" }
    return "local_command"
  }

  private func pluginShellCommand(for target: String) -> String? {
    guard target.hasPrefix("plugin:") else { return nil }
    let fileName = String(target.dropFirst("plugin:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      fileName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$"#, options: .regularExpression)
        != nil,
      !fileName.contains("..")
    else {
      statusMessage = "脚本插件名称无效。"
      return nil
    }
    let directories = [bundledPluginDirectoryURL()].compactMap { $0 }
    let candidates = directories.compactMap { directory -> URL? in
      let standardizedDirectory = directory.standardizedFileURL
      let candidate = standardizedDirectory.appendingPathComponent(fileName).standardizedFileURL
      guard candidate.deletingLastPathComponent() == standardizedDirectory else { return nil }
      return candidate
    }
    guard
      let scriptURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      statusMessage = "没有找到脚本插件：\(fileName)"
      return nil
    }
    return "bash \(shellQuote(scriptURL.path))"
  }

  private func bundledPluginDirectoryURL() -> URL? {
    Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true)
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func shellDisplayName(for command: String) -> String {
    if command == "plugin:mic-toggle.sh" {
      return "切换麦克风"
    }
    if command.hasPrefix("plugin:") {
      return "脚本插件"
    }
    return "脚本"
  }

  private static func shellFeedbackMessage(
    displayName: String,
    exitCode: Int32,
    output: String,
    error: String
  ) -> String {
    let detail =
      (output + "\n" + error)
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }

    if exitCode == 0 {
      return detail.map { "\(displayName)：\($0)" } ?? "\(displayName)已运行。"
    }
    return detail.map { "\(displayName)失败：\($0)" } ?? "\(displayName)失败，退出码 \(exitCode)。"
  }

  private func sendShortcut(_ target: String) {
    guard let shortcut = parseHotkeyText(target), let code = keyCode(for: shortcut.key) else {
      statusMessage = "发送按键无效：\(target)"
      AppDiagnostics.log("send_shortcut_invalid", ["target": target])
      return
    }
    let display = displayHotkeyText(key: shortcut.key, modifiers: shortcut.modifiers)
    let requestFrontmost = NSWorkspace.shared.frontmostApplication
    AppDiagnostics.log(
      "send_shortcut_requested",
      [
        "target": target,
        "display": display,
        "key": shortcut.key,
        "modifiers": shortcut.modifiers.joined(separator: "+"),
        "frontmost": requestFrontmost?.localizedName ?? requestFrontmost?.bundleIdentifier ?? "",
        "frontmostBundle": requestFrontmost?.bundleIdentifier ?? "",
        "frontmostPID": requestFrontmost.map { "\($0.processIdentifier)" } ?? "",
      ])

    if shortcut.key == ",",
      Set(shortcut.modifiers) == Set(["command"]),
      requestFrontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
    {
      let outcome = toggleShortcutWindow(.settings)
      if outcome == .shown || outcome == .unavailable {
        if outcome == .unavailable {
          showSettings()
          presentWindowHandler?()
        }
        statusMessage = "已打开设置，再按一次即隐藏。"
      } else {
        statusMessage = "已隐藏设置。"
      }
      AppDiagnostics.log(
        "send_shortcut_performed",
        [
          "target": target,
          "display": display,
          "route": "self_settings_toggle",
          "frontmostBundle": requestFrontmost?.bundleIdentifier ?? "",
          "frontmostPID": requestFrontmost.map { "\($0.processIdentifier)" } ?? "",
        ])
      return
    }

    guard AXIsProcessTrusted() else {
      statusMessage = "发送按键需要辅助功能授权。"
      AppDiagnostics.log(
        "send_shortcut_failed",
        ["target": target, "display": display, "reason": "missing_accessibility"])
      return
    }

    guard let requestFrontmost, requestFrontmost.processIdentifier > 0,
      !requestFrontmost.isTerminated
    else {
      statusMessage = "发送按键未执行：没有可接收的前台 App。"
      AppDiagnostics.log(
        "send_shortcut_failed",
        [
          "target": target,
          "display": display,
          "reason": "missing_frontmost_application",
        ])
      return
    }

    finishSendShortcut(
      target: target,
      display: display,
      key: shortcut.key,
      modifiers: shortcut.modifiers,
      keyCode: code,
      destination: requestFrontmost
    )
  }

  private func finishSendShortcut(
    target: String,
    display: String,
    key: String,
    modifiers: [String],
    keyCode: UInt32,
    destination: NSRunningApplication
  ) {
    let currentFrontmost = NSWorkspace.shared.frontmostApplication
    let hardwareModifiers = activeHardwareModifierNames()
    AppDiagnostics.log(
      "send_shortcut_start",
      [
        "target": target,
        "display": display,
        "key": key,
        "modifiers": modifiers.joined(separator: "+"),
        "route": "process",
        "destination": destination.localizedName ?? destination.bundleIdentifier ?? "",
        "destinationBundle": destination.bundleIdentifier ?? "",
        "destinationPID": "\(destination.processIdentifier)",
        "currentFrontmost":
          currentFrontmost?.localizedName ?? currentFrontmost?.bundleIdentifier ?? "",
        "currentFrontmostBundle": currentFrontmost?.bundleIdentifier ?? "",
        "hardwareModifiers": hardwareModifiers.joined(separator: "+"),
      ])
    guard
      postShortcutKeyChord(
        keyCode: keyCode,
        modifiers: modifiers,
        destinationPID: destination.processIdentifier)
    else {
      statusMessage = "发送按键失败：\(display)"
      AppDiagnostics.log(
        "send_shortcut_failed",
        [
          "target": target,
          "display": display,
          "reason": "event_creation_failed",
          "destinationBundle": destination.bundleIdentifier ?? "",
          "destinationPID": "\(destination.processIdentifier)",
        ])
      return
    }
    statusMessage = "已向 \(destination.localizedName ?? "前台 App") 发送 \(display)。"
    AppDiagnostics.log(
      "send_shortcut_posted",
      [
        "target": target,
        "display": display,
        "route": "process",
        "destination": destination.localizedName ?? destination.bundleIdentifier ?? "",
        "destinationBundle": destination.bundleIdentifier ?? "",
        "destinationPID": "\(destination.processIdentifier)",
      ])
  }

  private func activeHardwareModifierNames() -> [String] {
    modifierNames(from: CGEventSource.flagsState(.hidSystemState))
  }

  private func postShortcutKeyChord(
    keyCode: UInt32,
    modifiers: [String],
    destinationPID: pid_t
  ) -> Bool {
    let orderedModifiers = modifierOrder.filter { modifiers.contains($0) }
    let source = CGEventSource(stateID: .privateState)
    source?.localEventsSuppressionInterval = 0
    var activeFlags: CGEventFlags = []

    for modifier in orderedModifiers {
      activeFlags.insert(cgModifierFlag(modifier))
      guard
        postShortcutModifierEvent(
          source: source,
          modifier: modifier,
          isDown: true,
          flags: activeFlags,
          destinationPID: destinationPID
        )
      else {
        return false
      }
      usleep(6_000)
    }

    let finalFlags = cgModifiers(orderedModifiers)
    guard
      postShortcutKeyEvent(
        source: source,
        keyCode: keyCode,
        isDown: true,
        flags: finalFlags,
        destinationPID: destinationPID)
    else {
      return false
    }
    usleep(10_000)
    guard
      postShortcutKeyEvent(
        source: source,
        keyCode: keyCode,
        isDown: false,
        flags: finalFlags,
        destinationPID: destinationPID)
    else {
      return false
    }

    for modifier in orderedModifiers.reversed() {
      activeFlags.remove(cgModifierFlag(modifier))
      guard
        postShortcutModifierEvent(
          source: source,
          modifier: modifier,
          isDown: false,
          flags: activeFlags,
          destinationPID: destinationPID
        )
      else {
        return false
      }
      usleep(4_000)
    }
    return true
  }

  private func postShortcutKeyEvent(
    source: CGEventSource?,
    keyCode: UInt32,
    isDown: Bool,
    flags: CGEventFlags,
    destinationPID: pid_t
  ) -> Bool {
    guard
      let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: isDown
      )
    else {
      return false
    }
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    event.postToPid(destinationPID)
    return true
  }

  private func postShortcutModifierEvent(
    source: CGEventSource?,
    modifier: String,
    isDown: Bool,
    flags: CGEventFlags,
    destinationPID: pid_t
  ) -> Bool {
    guard let keyCode = leftModifierKeyCode(for: modifier) else { return false }
    guard
      let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: isDown
      )
    else {
      return false
    }
    event.type = .flagsChanged
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    event.postToPid(destinationPID)
    return true
  }

  private func cgModifierFlag(_ modifier: String) -> CGEventFlags {
    switch modifier {
    case "command": return .maskCommand
    case "option": return .maskAlternate
    case "control": return .maskControl
    case "shift": return .maskShift
    default: return []
    }
  }

  private func leftModifierKeyCode(for modifier: String) -> UInt32? {
    switch modifier {
    case "command": return UInt32(kVK_Command)
    case "option": return UInt32(kVK_Option)
    case "control": return UInt32(kVK_Control)
    case "shift": return UInt32(kVK_Shift)
    default: return nil
    }
  }

  private func toggleNativeFullScreen() {
    fullScreenToggleGeneration &+= 1
    let generation = fullScreenToggleGeneration
    guard AXIsProcessTrusted() else {
      statusMessage = "进入或退出全屏需要完成系统授权。"
      presentAuthorizationCenter()
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication else {
      statusMessage = "没有找到当前前台 App。"
      return
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard
      let window = focusedWindow(for: appElement)
        ?? mainWindow(for: appElement)
        ?? controllableWindow(for: appElement)
    else {
      statusMessage = "没有找到可全屏的窗口。"
      return
    }

    let appName = app.localizedName ?? app.bundleIdentifier ?? ""
    let isFullScreen = axBool(window, attribute: "AXFullScreen" as CFString) ?? false
    let nextValue: CFBoolean = isFullScreen ? kCFBooleanFalse! : kCFBooleanTrue!
    let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, nextValue)
    AppDiagnostics.log(
      "native_fullscreen_toggle",
      [
        "app": appName,
        "from": "\(isFullScreen)",
        "result": "\(result.rawValue)",
      ])

    let expected = !isFullScreen
    let finish: (Bool) -> Void = { [weak self] succeeded in
      guard let self, self.fullScreenToggleGeneration == generation else { return }
      self.statusMessage =
        succeeded
        ? (isFullScreen ? "已退出全屏。" : "已进入全屏。")
        : "全屏动作未观察到窗口状态变化，请检查该窗口是否支持 AXFullScreen。"
    }
    let tryKeyboardFallback: () -> Void = { [weak self] in
      guard let self, self.fullScreenToggleGeneration == generation else { return }
      self.sendShortcut("⌃ ⌘ F")
      self.pollFullScreenState(
        window,
        expected: expected,
        generation: generation,
        deadline: ProcessInfo.processInfo.systemUptime + 0.45,
        completion: finish)
    }

    guard result == .success else {
      tryKeyboardFallback()
      return
    }
    pollFullScreenState(
      window,
      expected: expected,
      generation: generation,
      deadline: ProcessInfo.processInfo.systemUptime + 0.45
    ) { [weak self] succeeded in
      guard let self, self.fullScreenToggleGeneration == generation else { return }
      if succeeded {
        finish(true)
      } else {
        AppDiagnostics.log(
          "native_fullscreen_toggle_wait_miss",
          ["app": appName, "from": "\(isFullScreen)", "to": "\(expected)"])
        tryKeyboardFallback()
      }
    }
  }

  private func pollFullScreenState(
    _ window: AXUIElement,
    expected: Bool,
    generation: UInt64,
    deadline: TimeInterval,
    completion: @escaping (Bool) -> Void
  ) {
    guard fullScreenToggleGeneration == generation else { return }
    if axBool(window, attribute: "AXFullScreen" as CFString) == expected {
      completion(true)
      return
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      completion(false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      self?.pollFullScreenState(
        window,
        expected: expected,
        generation: generation,
        deadline: deadline,
        completion: completion)
    }
  }

  private func closeWindowSmart() {
    let requestedApplication = NSWorkspace.shared.frontmostApplication
    let bundleID = requestedApplication?.bundleIdentifier ?? ""
    let browserName: String?
    switch bundleID {
    case "com.google.Chrome":
      browserName = "Google Chrome"
    case "com.microsoft.edgemac":
      browserName = "Microsoft Edge"
    default:
      browserName = nil
    }

    if let browserName {
      let script = """
        tell application "\(browserName)"
          if (count of windows) > 0 then close active tab of front window
        end tell
        """
      runAppleScript(script, timeout: 2) { [weak self] succeeded in
        guard let self else { return }
        guard
          NSWorkspace.shared.frontmostApplication?.processIdentifier
            == requestedApplication?.processIdentifier
        else {
          self.statusMessage = "前台 App 已变化，本次关闭已取消。"
          return
        }
        if succeeded {
          self.statusMessage = "已关闭当前标签页。"
        } else {
          self.sendShortcut("⌘ W")
          self.statusMessage = "已发送 ⌘ W。"
        }
      }
      return
    }

    sendShortcut("⌘ W")
    statusMessage = "已发送 ⌘ W。"
  }

  private func insertText(_ text: String) {
    guard !text.isEmpty else {
      statusMessage = "短语内容为空。"
      return
    }
    let pasteboard = NSPasteboard.general
    let requestedProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
    TemporaryPasteboardWrite.writeString(
      text,
      to: pasteboard,
      validateBeforeWrite: {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == requestedProcessIdentifier
      },
      completion: { [weak self] temporaryWrite in
        guard let self else { return }
        guard let temporaryWrite else {
          self.statusMessage = "输入短语失败：未改动原剪贴板。"
          return
        }
        ClipboardHistorySuppression.markCurrentPasteboardChange()
        self.sendShortcut("⌘ V")
        self.statusMessage = "已输入短语。"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          if temporaryWrite.restoreIfStillOwned(on: pasteboard) != nil {
            ClipboardHistorySuppression.markCurrentPasteboardChange()
          }
        }
      }
    )
  }

  @discardableResult
  private func runAppleScript(
    _ source: String,
    timeout: TimeInterval,
    completion: @escaping (Bool) -> Void
  ) -> BoundedProcessExecution {
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-e", source],
      timeout: timeout,
      outputByteLimit: 32_768
    ) { result in
      completion(result.succeeded)
    }.start()
  }

  private func applyWindowPreset(_ target: String) {
    guard let preset = WindowPreset(rawValue: target) else {
      statusMessage = "窗口动作无效：\(target)"
      return
    }
    guard AXIsProcessTrusted() else {
      statusMessage = "窗口管理需要完成系统授权。"
      presentAuthorizationCenter()
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication else {
      statusMessage = "没有找到当前前台 App。"
      return
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = controllableWindow(for: appElement) else {
      statusMessage = "没有找到可控制的窗口。"
      return
    }
    if preset == .minimize {
      let result = AXUIElementSetAttributeValue(
        window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
      statusMessage = result == .success ? "已最小化窗口。" : "窗口最小化失败。"
      return
    }
    if preset == .maximize {
      toggleWindowMaximize(window, app: app)
      return
    }
    guard let frame = targetFrame(for: preset, window: window) else {
      statusMessage = "无法计算窗口位置。"
      return
    }
    let restoreKey = maximizeRestoreKey(for: window, app: app)
    pendingMaximizeRestoreKeys.remove(restoreKey)
    removeMaximizeRestoreFrame(for: restoreKey)
    setWindow(window, frame: frame, app: app) { [weak self] succeeded in
      if !succeeded { self?.statusMessage = "窗口位置调整失败。" }
    }
  }

  private func toggleWindowMaximize(_ window: AXUIElement, app: NSRunningApplication) {
    guard let current = windowFrame(window) else {
      statusMessage = "无法读取当前窗口位置。"
      return
    }
    let screen = screen(containing: current) ?? NSScreen.main
    guard let screen, let visible = visibleAXFrame(for: screen) else {
      statusMessage = "无法读取当前屏幕范围。"
      return
    }
    let restoreKey = maximizeRestoreKey(for: window, app: app)

    if pendingMaximizeRestoreKeys.remove(restoreKey) != nil,
      let previous = maximizeRestoreFrame(for: restoreKey)
    {
      let restored = clampedRestoreFrame(previous)
      setWindow(window, frame: restored, app: app) { [weak self] succeeded in
        guard let self else { return }
        if succeeded {
          self.removeMaximizeRestoreFrame(for: restoreKey)
          self.statusMessage = "已恢复窗口。"
        } else {
          self.statusMessage = "窗口恢复失败，已保留原恢复位置。"
        }
      }
      return
    }

    if current.isVisuallyMaximized(in: visible) {
      if let previous = maximizeRestoreFrame(for: restoreKey) {
        pendingMaximizeRestoreKeys.remove(restoreKey)
        let restored = clampedRestoreFrame(previous)
        guard !restored.isVisuallyMaximized(in: visible) || restored != visible else {
          removeMaximizeRestoreFrame(for: restoreKey)
          statusMessage = "窗口已是窗口化全屏。"
          return
        }
        setWindow(window, frame: restored, app: app) { [weak self] succeeded in
          guard let self else { return }
          if succeeded {
            self.removeMaximizeRestoreFrame(for: restoreKey)
            self.statusMessage = "已恢复窗口。"
          } else {
            self.statusMessage = "窗口恢复失败，已保留原恢复位置。"
          }
        }
        return
      }
      if current.overfillsWorkArea(in: visible) {
        setWindow(window, frame: visible, app: app, visualMaximizeFrame: visible) {
          [weak self] succeeded in
          self?.statusMessage = succeeded ? "已调整为窗口化全屏。" : "窗口调整失败。"
        }
        return
      }
      statusMessage = "窗口已是窗口化全屏。"
      return
    }

    storeMaximizeRestoreFrame(current, for: restoreKey)
    pendingMaximizeRestoreKeys.insert(restoreKey)
    setWindow(window, frame: visible, app: app, visualMaximizeFrame: visible) {
      [weak self] succeeded in
      guard let self else { return }
      self.pendingMaximizeRestoreKeys.remove(restoreKey)
      if succeeded {
        self.statusMessage = "已窗口化全屏。"
      } else {
        if self.maximizeRestoreFrame(for: restoreKey) == current {
          self.removeMaximizeRestoreFrame(for: restoreKey)
        }
        self.statusMessage = "窗口化全屏失败，未记入错误的恢复位置。"
      }
    }
  }

  private func targetFrame(for preset: WindowPreset, window: AXUIElement) -> CGRect? {
    let current = windowFrame(window) ?? .zero
    let screen = screen(containing: current) ?? NSScreen.main
    guard let screen, let visible = visibleAXFrame(for: screen) else { return nil }
    let halfWidth = visible.width / 2
    let halfHeight = visible.height / 2
    switch preset {
    case .leftHalf:
      return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
    case .rightHalf:
      return CGRect(x: visible.midX, y: visible.minY, width: halfWidth, height: visible.height)
    case .topHalf:
      return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfHeight)
    case .bottomHalf:
      return CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: halfHeight)
    case .topLeft:
      return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: halfHeight)
    case .topRight:
      return CGRect(x: visible.midX, y: visible.minY, width: halfWidth, height: halfHeight)
    case .bottomLeft:
      return CGRect(x: visible.minX, y: visible.midY, width: halfWidth, height: halfHeight)
    case .bottomRight:
      return CGRect(x: visible.midX, y: visible.midY, width: halfWidth, height: halfHeight)
    case .maximize:
      return visible
    case .center:
      let width = min(current.width, visible.width)
      let height = min(current.height, visible.height)
      return CGRect(
        x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    case .minimize:
      return nil
    }
  }

  private func windowFrame(_ window: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition)
        == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
      rawPosition != nil,
      rawSize != nil
    else {
      return nil
    }
    guard CFGetTypeID(rawPosition!) == AXValueGetTypeID(),
      CFGetTypeID(rawSize!) == AXValueGetTypeID()
    else {
      return nil
    }
    let positionValue = rawPosition as! AXValue
    let sizeValue = rawSize as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue, .cgPoint, &position)
    AXValueGetValue(sizeValue, .cgSize, &size)
    return CGRect(origin: position, size: size)
  }

  private func screen(containing frame: CGRect) -> NSScreen? {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return nil }
    guard frame != .zero else { return NSScreen.main ?? screens.first }
    let geometries = screens.map {
      WindowScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    guard
      let index = AXWindowGeometry.screenIndex(
        containingAXFrame: frame,
        screens: geometries,
        primaryTop: primaryScreenTop(for: screens))
    else { return NSScreen.main ?? screens.first }
    return screens[index]
  }

  private func visibleAXFrame(for screen: NSScreen) -> CGRect? {
    let visible = screen.visibleFrame
    guard visible.width > 0, visible.height > 0 else { return nil }
    return AXWindowGeometry.visibleAXFrame(
      for: WindowScreenGeometry(frame: screen.frame, visibleFrame: visible),
      primaryTop: primaryScreenTop(for: NSScreen.screens))
  }

  private func primaryScreenTop(for screens: [NSScreen]) -> CGFloat {
    screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
  }

  private func clampedRestoreFrame(_ frame: CGRect) -> CGRect {
    guard let restoreScreen = screen(containing: frame),
      let visible = visibleAXFrame(for: restoreScreen)
    else { return frame }
    return AXWindowGeometry.clamped(frame, to: visible)
  }

  private func setWindow(
    _ window: AXUIElement,
    frame: CGRect,
    app: NSRunningApplication,
    visualMaximizeFrame: CGRect? = nil,
    completion: @escaping (Bool) -> Void
  ) {
    let operationKey = windowOperationKey(for: window, app: app)
    windowOperationSequence &+= 1
    let operationToken = windowOperationSequence
    windowOperationTokens[operationKey] = operationToken
    setWindowWithAccessibility(window, frame: frame)
    scheduleWindowVerification(
      window,
      requestedFrame: frame,
      visualMaximizeFrame: visualMaximizeFrame,
      app: app,
      operationKey: operationKey,
      operationToken: operationToken,
      attempt: 0,
      delay: 0.05,
      completion: completion)
  }

  private func scheduleWindowVerification(
    _ window: AXUIElement,
    requestedFrame: CGRect,
    visualMaximizeFrame: CGRect?,
    app: NSRunningApplication,
    operationKey: String,
    operationToken: UInt64,
    attempt: Int,
    delay: TimeInterval,
    completion: @escaping (Bool) -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak app] in
      guard let self, let app,
        self.windowOperationTokens[operationKey] == operationToken
      else { return }
      let fallbackFrame = visualMaximizeFrame ?? requestedFrame
      if self.windowFrame(window).matchesRequestedFrame(
        attempt == 0 ? requestedFrame : fallbackFrame,
        visualMaximizeFrame: visualMaximizeFrame)
      {
        self.finishWindowOperation(
          key: operationKey, token: operationToken, succeeded: true, completion: completion)
        return
      }

      switch attempt {
      case 0:
        self.setWindowWithAccessibility(window, frame: fallbackFrame)
        self.scheduleWindowVerification(
          window,
          requestedFrame: requestedFrame,
          visualMaximizeFrame: visualMaximizeFrame,
          app: app,
          operationKey: operationKey,
          operationToken: operationToken,
          attempt: 1,
          delay: 0.05,
          completion: completion)
      case 1:
        guard let index = self.systemEventsWindowIndex(for: window, pid: app.processIdentifier)
        else {
          self.setWindowWithAccessibility(window, frame: fallbackFrame)
          self.scheduleWindowVerification(
            window,
            requestedFrame: requestedFrame,
            visualMaximizeFrame: visualMaximizeFrame,
            app: app,
            operationKey: operationKey,
            operationToken: operationToken,
            attempt: 3,
            delay: 0.08,
            completion: completion)
          return
        }
        self.setWindowWithSystemEvents(
          pid: app.processIdentifier,
          windowIndex: index,
          frame: fallbackFrame
        ) { [weak self, weak app] _ in
          guard let self, let app,
            self.windowOperationTokens[operationKey] == operationToken
          else { return }
          self.scheduleWindowVerification(
            window,
            requestedFrame: requestedFrame,
            visualMaximizeFrame: visualMaximizeFrame,
            app: app,
            operationKey: operationKey,
            operationToken: operationToken,
            attempt: 2,
            delay: 0.08,
            completion: completion)
        }
      case 2:
        self.setWindowWithAccessibility(window, frame: fallbackFrame)
        self.scheduleWindowVerification(
          window,
          requestedFrame: requestedFrame,
          visualMaximizeFrame: visualMaximizeFrame,
          app: app,
          operationKey: operationKey,
          operationToken: operationToken,
          attempt: 3,
          delay: 0.08,
          completion: completion)
      default:
        self.finishWindowOperation(
          key: operationKey, token: operationToken, succeeded: false, completion: completion)
      }
    }
  }

  private func finishWindowOperation(
    key: String,
    token: UInt64,
    succeeded: Bool,
    completion: (Bool) -> Void
  ) {
    guard windowOperationTokens[key] == token else { return }
    windowOperationTokens.removeValue(forKey: key)
    completion(succeeded)
  }

  private func windowOperationKey(
    for window: AXUIElement,
    app: NSRunningApplication
  ) -> String {
    let base = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    let identity =
      intAttribute("AXWindowNumber", from: window).map(String.init)
      ?? "element:\(CFHash(window))"
    return "\(base)#\(identity)"
  }

  private func setWindowWithAccessibility(_ window: AXUIElement, frame: CGRect) {
    var origin = frame.origin
    var size = frame.size
    guard let position = AXValueCreate(.cgPoint, &origin),
      let windowSize = AXValueCreate(.cgSize, &size)
    else {
      return
    }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize)
  }

  private func systemEventsWindowIndex(for window: AXUIElement, pid: pid_t) -> Int? {
    let appElement = AXUIElementCreateApplication(pid)
    return axWindows(for: appElement).firstIndex(where: { CFEqual($0, window) }).map { $0 + 1 }
  }

  private func setWindowWithSystemEvents(
    pid: pid_t,
    windowIndex: Int,
    frame: CGRect,
    completion: @escaping (Bool) -> Void
  ) {
    let script = """
      tell application "System Events"
        set matches to application processes whose unix id is \(pid)
        if (count of matches) is 0 then error "process not found"
        set targetProcess to item 1 of matches
        if (count of windows of targetProcess) < \(windowIndex) then error "window not found"
        set targetWindow to window \(windowIndex) of targetProcess
        set size of targetWindow to {\(Int(frame.width)), \(Int(frame.height))}
        set position of targetWindow to {\(Int(frame.minX)), \(Int(frame.minY))}
      end tell
      """
    runAppleScript(script, timeout: 2, completion: completion)
  }

  private func controllableWindow(for appElement: AXUIElement) -> AXUIElement? {
    let windows = axWindows(for: appElement)
    let focused = focusedWindow(for: appElement)
    if let focused, isControllableWindow(focused) {
      return focused
    }
    return
      windows
      .filter(isControllableWindow)
      .max { windowScore($0) < windowScore($1) }
      ?? focused
      ?? windows.first
  }

  private func focusedWindow(for appElement: AXUIElement) -> AXUIElement? {
    var rawWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
      let rawWindow,
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (rawWindow as! AXUIElement)
  }

  private func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
    var rawWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXMainWindowAttribute as CFString, &rawWindow) == .success,
      let rawWindow,
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (rawWindow as! AXUIElement)
  }

  private func axWindowTitle(_ window: AXUIElement) -> String {
    var rawTitle: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle)
        == .success,
      let title = rawTitle as? String
    else {
      return ""
    }
    return title
  }

  private func axWindows(for appElement: AXUIElement) -> [AXUIElement] {
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

  private func isControllableWindow(_ window: AXUIElement) -> Bool {
    guard !isWindowMinimized(window), let frame = windowFrame(window) else { return false }
    return frame.width >= 320 && frame.height >= 180
  }

  private func isWindowMinimized(_ window: AXUIElement) -> Bool {
    var rawMinimized: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
        == .success,
      let rawMinimized
    else {
      return false
    }
    return boolValue(from: rawMinimized)
  }

  private func axBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
      let rawValue
    else {
      return nil
    }
    return boolValue(from: rawValue)
  }

  private func boolValue(from value: CFTypeRef) -> Bool {
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    let boolValue = value as! CFBoolean
    return CFBooleanGetValue(boolValue)
  }

  private func windowScore(_ window: AXUIElement) -> CGFloat {
    guard let frame = windowFrame(window) else { return 0 }
    return frame.width * frame.height
  }

  private func maximizeRestoreKey(for window: AXUIElement, app: NSRunningApplication) -> String {
    let appKey = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    if let windowNumber = intAttribute("AXWindowNumber", from: window) {
      return "\(appKey)#window:\(windowNumber)"
    }
    // AXWindowNumber is not universal. The element hash is safe for this process lifetime but is
    // deliberately not persisted because it has no identity meaning after relaunch.
    return "\(appKey)#volatile:\(CFHash(window))"
  }

  private func storeMaximizeRestoreFrame(_ frame: CGRect, for key: String) {
    maximizeRestoreFrames[key] = frame
    guard !key.contains("#volatile:") else { return }
    var stored = storedMaximizeRestoreFrames()
    stored[key] = encodeFrame(frame)
    UserDefaults.standard.set(stored, forKey: maximizeRestoreDefaultsKey)
  }

  private func maximizeRestoreFrame(for key: String) -> CGRect? {
    if let frame = maximizeRestoreFrames[key] { return frame }
    guard let rawFrame = storedMaximizeRestoreFrames()[key] else { return nil }
    return decodeFrame(rawFrame)
  }

  private func removeMaximizeRestoreFrame(for key: String) {
    maximizeRestoreFrames.removeValue(forKey: key)
    guard !key.contains("#volatile:") else { return }
    removeStoredMaximizeRestoreFrame(for: key)
  }

  private func removeStoredMaximizeRestoreFrame(for key: String) {
    var stored = storedMaximizeRestoreFrames()
    stored.removeValue(forKey: key)
    UserDefaults.standard.set(stored, forKey: maximizeRestoreDefaultsKey)
  }

  private func storedMaximizeRestoreFrames() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: maximizeRestoreDefaultsKey) as? [String: String] ?? [:]
  }

  private func encodeFrame(_ frame: CGRect) -> String {
    [frame.minX, frame.minY, frame.width, frame.height]
      .map { String(format: "%.3f", Double($0)) }
      .joined(separator: ",")
  }

  private func decodeFrame(_ value: String) -> CGRect? {
    let parts = value.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  }

  private func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
      let rawValue
    else {
      return nil
    }
    if CFGetTypeID(rawValue) == CFNumberGetTypeID() {
      return rawValue as? Int
    }
    return rawValue as? Int
  }

  private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
      let rawValue
    else {
      return nil
    }
    return rawValue as? String
  }
}

extension CGRect {
  fileprivate func isNearlyEqual(to other: CGRect, tolerance: CGFloat = 6) -> Bool {
    abs(origin.x - other.origin.x) <= tolerance
      && abs(origin.y - other.origin.y) <= tolerance
      && abs(size.width - other.size.width) <= tolerance
      && abs(size.height - other.size.height) <= tolerance
  }

  fileprivate func isVisuallyMaximized(in visible: CGRect) -> Bool {
    let widthOK = width >= visible.width - 24
    let heightOK = height >= visible.height - 36
    let xOK = abs(minX - visible.minX) <= 24
    let bottomOK = abs(minY - visible.minY) <= 36
    let topOK = abs(maxY - visible.maxY) <= 36
    return widthOK && heightOK && xOK && (bottomOK || topOK)
  }

  fileprivate func overfillsWorkArea(in visible: CGRect) -> Bool {
    height > visible.height + 24 || maxY > visible.maxY + 24
  }
}

extension Optional where Wrapped == CGRect {
  fileprivate func matchesRequestedFrame(
    _ frame: CGRect,
    visualMaximizeFrame: CGRect?,
    tolerance: CGFloat = 18
  ) -> Bool {
    guard let current = self else { return false }
    if let visualMaximizeFrame {
      return current.isVisuallyMaximized(in: visualMaximizeFrame)
        && !current.overfillsWorkArea(in: visualMaximizeFrame)
    }
    return current.isNearlyEqual(to: frame, tolerance: tolerance)
  }
}
