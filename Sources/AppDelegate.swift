import AppKit
import Darwin
import SwiftUI

extension Notification.Name {
  static let showAixlgHotkeysWindow = AppRuntimeIdentity.current.notificationName("showWindow")
  static let showAixlgLauncherWindow = AppRuntimeIdentity.current.notificationName("showLauncher")
  static let showAixlgPluginCenterWindow = AppRuntimeIdentity.current.notificationName(
    "showPluginCenter")
  static let showAixlgSleepManagementWindow = AppRuntimeIdentity.current.notificationName(
    "showSleepManagement")
  static let toggleAixlgSleepStatus = AppRuntimeIdentity.current.notificationName(
    "toggleSleepStatus")
  static let showAixlgVolumeFeedback = AppRuntimeIdentity.current.notificationName(
    "showVolumeFeedback")
  static let sleepStatusStateChanged = AppRuntimeIdentity.current.notificationName(
    "sleepStatusStateChanged")
  static let networkSpeedPluginVisibilityChanged = AppRuntimeIdentity.current.notificationName(
    "networkSpeedPluginVisibilityChanged")
  static let sleepStatusItemChanged = AppRuntimeIdentity.current.notificationName(
    "sleepStatusItemChanged")
  static let menuBarConfigurationChanged = AppRuntimeIdentity.current.notificationName(
    "menuBarConfigurationChanged")
}

private final class LauncherPanelWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

private final class ClassicTabSwitcherPanelWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct NetworkStatusMenuItemState: Codable {
  let id: String
  let title: String
  let isEnabled: Bool
  let isHidden: Bool
  let toolTip: String?
}

private struct NetworkStatusMenuSnapshot: Codable {
  let items: [NetworkStatusMenuItemState]
}

private struct NetworkStatusHelperMessage: Codable {
  let type: String
  let snapshot: NetworkStatusMenuSnapshot?
  let volume: Double?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let model: AppModel
  private let runtimeIdentity = AppRuntimeIdentity.current
  private var window: NSWindow?
  private var mainWindowTitlebarAccessory: NSTitlebarAccessoryViewController?
  private var launcherWindow: NSWindow?
  private var processViewerWindow: NSWindow?
  private var clipboardHistoryWindow: NSWindow?
  private var clipboardHistoryReturnApplication: NSRunningApplication?
  private var codexNetworkProbeWindow: NSWindow?
  private var sleepManagementWindow: NSWindow?
  private var aiPlayerWindow: NSWindow?
  private var integratedFeatureComposition: AnyObject?
  private var classicTabSwitcherWindow: NSPanel?
  private var sleepStatusItem: NSStatusItem?
  private var permissionTimer: Timer?
  private var permissionPollsRemaining = 0
  private var statusHelperWatchdogTimer: Timer?
  private var globalInputOwnershipTimer: Timer?
  private var workspaceLaunchObserver: NSObjectProtocol?
  private var workspaceTerminateObserver: NSObjectProtocol?
  private var workspaceActiveSpaceObserver: NSObjectProtocol?
  private var showWindowObserver: NSObjectProtocol?
  private var showLauncherObserver: NSObjectProtocol?
  private var showPluginCenterObserver: NSObjectProtocol?
  private var showSleepManagementObserver: NSObjectProtocol?
  private var toggleSleepStatusObserver: NSObjectProtocol?
  private var volumeFeedbackObserver: NSObjectProtocol?
  private var networkSpeedPluginObserver: NSObjectProtocol?
  private var sleepStatusItemObserver: NSObjectProtocol?
  private var menuBarConfigurationObserver: NSObjectProtocol?
  private var sparkleUpdateController: SparkleUpdateController?
  private var closeWindowKeyMonitor: Any?
  private var networkSpeedHelperProcess: Process?
  private var networkSpeedHelperInputHandle: FileHandle?
  private var networkSpeedHelperOutputHandle: FileHandle?
  private var networkSpeedHelperReadBuffer = Data()
  private var sleepStatusHelperProcess: Process?
  private var networkSpeedHelperFailureCount = 0
  private var sleepStatusHelperFailureCount = 0
  private var networkSpeedHelperRestartNotBefore: TimeInterval = 0
  private var sleepStatusHelperRestartNotBefore: TimeInterval = 0
  private var sleepStatusHelperCapabilityToken: String?
  private var backgroundActivity: NSObjectProtocol?
  private var didPerformTerminationCleanup = false
  private var pendingFileOpenBatches: [[URL]] = []
  private var didCompleteLaunchPresentation = false
  private var didOpenAssociatedFilesDuringLaunch = false
  private let codexNetworkProbeController = CodexNetworkProbeController()
  private var didBootstrap = false
  private var didPositionLauncherWindow = false
  private var lastSleepStatusHelperStateSignature: String?
  private var suppressMainWindowForLauncherUntil: TimeInterval = 0
  private var shortcutWindowToggleState = ShortcutWindowToggleState()
  private var pendingRestorationTickets: [ShortcutWindowTarget: ShortcutWindowToggleTicket] = [:]
  private var networkSpeedHelperExecutableName: String {
    runtimeIdentity.networkSpeedHelperExecutableName
  }
  private var sleepStatusHelperExecutableName: String {
    runtimeIdentity.sleepStatusHelperExecutableName
  }
  private var appDisplayName: String { runtimeIdentity.displayName }
  private let defaultWindowSize = NSSize(width: 1120, height: 760)
  private let launcherWindowSize = NSSize(width: 720, height: 520)
  private let launcherWindowMaximumSize = NSSize(width: 840, height: 560)
  private let processViewerWindowSize = NSSize(width: 1120, height: 760)
  private let clipboardHistoryWindowSize = NSSize(width: 500, height: 680)
  private let codexNetworkProbeWindowSize = NSSize(width: 760, height: 520)
  private let sleepManagementWindowSize = NSSize(width: 560, height: 480)
  private let aiPlayerWindowSize = NSSize(width: 980, height: 620)
  private let classicTabSwitcherWindowSize = NSSize(width: 780, height: 430)

  init(model: AppModel) {
    self.model = model
    super.init()
    self.model.showWindowHandler = { [weak self] in self?.toggleMainWindow() }
    self.model.presentWindowHandler = { [weak self] in self?.presentMainWindow() }
    self.model.toggleShortcutWindowHandler = { [weak self] target in
      self?.toggleShortcutWindow(target) ?? .unavailable
    }
    self.model.showLauncherHandler = { [weak self] in
      self?.presentShortcutWindow(.launcher)
    }
    self.model.showProcessViewerHandler = { [weak self] in
      self?.presentShortcutWindow(.processViewer)
    }
    self.model.showClipboardHistoryHandler = { [weak self] in
      self?.presentShortcutWindow(.clipboardHistory)
    }
    self.model.showCodexNetworkProbeHandler = { [weak self] in
      self?.presentShortcutWindow(.networkProbe)
    }
    self.model.showSleepPanelHandler = { [weak self] in
      self?.presentShortcutWindow(.sleepManagement)
    }
    self.model.showAIPlayerHandler = { [weak self] in
      self?.presentShortcutWindow(.aiPlayer)
    }
    self.model.classicTabSwitcherHUDHandler = { [weak self] state in
      self?.syncClassicTabSwitcherHUD(state)
    }
    self.model.authorizationPollingRequestHandler = { [weak self] reason in
      self?.startPermissionPolling(reason: reason)
    }
    self.model.authorizationTerminationHandler = { [weak self] in
      self?.terminateForAuthorizationRelaunch()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if AppSelfInstaller.launchInstallIfNeeded() {
      NSApp.terminate(nil)
      return
    }
    bootstrapIfNeeded()
  }

  func bootstrapIfNeeded() {
    guard !didBootstrap else { return }
    didBootstrap = true
    _ = DockPresencePreference.apply(visible: DockPresencePreference.isVisible())
    NSApp.applicationIconImage = NSImage(named: "AppIcon")
    buildMainMenu()
    buildWindow()
    buildLauncherWindow()
    integratedFeatureComposition = installIntegratedFeaturesIfAvailable(into: model)
    if !pendingFileOpenBatches.isEmpty {
      didOpenAssociatedFilesDuringLaunch = true
      let batches = pendingFileOpenBatches
      pendingFileOpenBatches.removeAll()
      batches.forEach(openAssociatedFiles)
    }
    buildStatusMenu()
    Task { @MainActor [weak self] in
      self?.configureSparkleUpdaterIfRequired()
    }
    startCloseWindowKeyMonitor()
    startShowWindowObserver()
    startShortcutWindowRestorationObserver()
    startPluginCenterObserver()
    startSleepManagementObserver()
    startSleepStatusToggleObserver()
    startVolumeFeedbackObserver()
    startNetworkSpeedPluginObserver()
    startSleepStatusItemObserver()
    startMenuBarConfigurationObserver()
    startGlobalInputOwnershipMonitoring()
    startPermissionPolling(reason: "launch")
    startBackgroundActivity()
  }

  @MainActor
  func showWindowAfterLaunch() {
    defer { didCompleteLaunchPresentation = true }
    guard !didOpenAssociatedFilesDuringLaunch else { return }
    showWindowWithStartupRetries()
    model.handleAuthorizationRepairRelaunchIfNeeded()
    let presentedRelaunchResult = model.presentAuthorizationRelaunchResultIfNeeded()
    if presentedRelaunchResult {
      showAuthorizationRelaunchResultWithRetries()
    } else {
      // Free sharing never suppresses the normal system permission onboarding.
      _ = model.presentAuthorizationOnboardingIfNeeded()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    _ = model.refreshGlobalInputOwnership(trigger: "becameActive")
    let changed = model.refreshAuthorizationAndReloadIfNeeded()
    model.refreshLaunchAtLoginStatus()
    if changed {
      refreshStatusMenu()
    }
    startPermissionPolling(reason: "becameActive")
    if launcherWindow?.isVisible == true {
      model.activateInputMethodForLauncher()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
      model.statusMessage = "这个链接不受支持，未更改任何内容。"
      return
    }
    self.application(application, openFiles: urls.map(\.path))
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls = filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
    guard !urls.isEmpty,
      urls.allSatisfy({ FileAssociationManager.fileKind(for: $0) != nil })
    else {
      model.statusMessage = "这个文件不是披卷或听澜当前支持的格式，未更改任何内容。"
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    let batchValidation = FileAssociationManager.validateOpenBatch(urls)
    guard batchValidation == .accepted else {
      model.statusMessage = batchValidation.customerMessage ?? "这批文件暂时无法一起打开。"
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    if !didCompleteLaunchPresentation {
      didOpenAssociatedFilesDuringLaunch = true
      shortcutWindowToggleState.invalidate()
    }
    if didBootstrap {
      openAssociatedFiles(urls)
    } else {
      pendingFileOpenBatches.append(urls)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  private func openAssociatedFiles(_ urls: [URL]) {
    Task { @MainActor [weak self] in
      self?.openAssociatedFilesOnMainActor(urls)
    }
  }

  @MainActor
  private func openAssociatedFilesOnMainActor(_ urls: [URL]) {
    let batchValidation = FileAssociationManager.validateOpenBatch(urls)
    guard batchValidation == .accepted else {
      model.statusMessage = batchValidation.customerMessage ?? "这批文件暂时无法一起打开。"
      return
    }
    let manager = try? FileAssociationManager()
    let decisions =
      manager?.routingDecisions(for: urls)
      ?? urls.map { url in
        let kind = FileAssociationManager.fileKind(for: url)
        return FileOpenRouteDecision(
          originalURL: url,
          standardizedURL: url.standardizedFileURL,
          kind: kind,
          destination: kind == .pdf
            ? .pijuan
            : (kind == .audio ? .tinglanAudio : .unsupported))
      }

    var pdfURLs: [URL] = []
    var audioURLs: [URL] = []
    var unsupportedNames: [String] = []
    for decision in decisions {
      switch decision.destination {
      case .pijuan:
        pdfURLs.append(decision.standardizedURL)
      case .tinglanAudio, .keepSystemDefault:
        audioURLs.append(decision.standardizedURL)
      case .unsupported:
        unsupportedNames.append(decision.standardizedURL.lastPathComponent)
      }
    }
    if let firstPDF = pdfURLs.first {
      model.openPijuanPDFDocument(firstPDF)
    }
    if !audioURLs.isEmpty {
      model.openAudioFilesInAIPlayer(audioURLs)
    }
    if !unsupportedNames.isEmpty {
      model.statusMessage = "暂不支持打开：\(unsupportedNames.joined(separator: "、"))"
    }
  }

  func applicationDidHide(_ notification: Notification) {
    shortcutWindowToggleState.invalidate()
    pendingRestorationTickets.removeAll()
    if launcherWindow != nil {
      model.restoreInputMethodAfterLauncher()
    }
    NotificationCenter.default.post(
      name: .clipboardHistoryWindowWillHide,
      object: nil)
    NotificationCenter.default.post(
      name: .processViewerWindowVisibilityChanged,
      object: false)
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated { codexNetworkProbeController.cancelAll() }
  }

  func applicationDidUnhide(_ notification: Notification) {
    settlePendingShortcutWindowRestorations()
    let isViewerVisible =
      processViewerWindow?.isVisible == true
      && processViewerWindow?.isMiniaturized == false
      && processViewerWindow?.isOnActiveSpace == true
    NotificationCenter.default.post(
      name: .processViewerWindowVisibilityChanged,
      object: isViewerVisible)
  }

  func applicationDidResignActive(_ notification: Notification) {
    model.cancelRecordingIfNeeded()
    if launcherWindow?.isVisible == true {
      model.restoreInputMethodAfterLauncher()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if shouldSuppressMainWindowForLauncher {
      presentShortcutWindow(.launcher)
    } else {
      presentMainWindow()
    }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model.prepareAuthorizationRelaunchForSystemTerminationIfNeeded()
    AppDiagnostics.log(
      "app_should_terminate",
      ["pid": "\(ProcessInfo.processInfo.processIdentifier)", "decision": "terminateNow"])
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    performTerminationCleanup()
  }

  private func terminateForAuthorizationRelaunch() {
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    AppDiagnostics.log(
      "authorization_run_loop_stop_requested",
      ["pid": "\(processIdentifier)"])
    performTerminationCleanup()

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
      guard Darwin.kill(processIdentifier, 0) == 0 else { return }
      Darwin.kill(processIdentifier, SIGTERM)
    }

    NSApp.stop(nil)
    if let wakeEvent = NSEvent.otherEvent(
      with: .applicationDefined,
      location: .zero,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      subtype: 0,
      data1: 0,
      data2: 0)
    {
      NSApp.postEvent(wakeEvent, atStart: true)
    }
  }

  private func performTerminationCleanup() {
    guard !didPerformTerminationCleanup else { return }
    didPerformTerminationCleanup = true
    model.shutdown()
    permissionTimer?.invalidate()
    statusHelperWatchdogTimer?.invalidate()
    globalInputOwnershipTimer?.invalidate()
    if let backgroundActivity {
      ProcessInfo.processInfo.endActivity(backgroundActivity)
    }
    if let showWindowObserver {
      DistributedNotificationCenter.default().removeObserver(showWindowObserver)
    }
    DistributedNotificationCenter.default().removeObserver(
      self, name: .showAixlgLauncherWindow, object: nil)
    if let showLauncherObserver {
      NotificationCenter.default.removeObserver(showLauncherObserver)
    }
    if let showPluginCenterObserver {
      NotificationCenter.default.removeObserver(showPluginCenterObserver)
    }
    DistributedNotificationCenter.default().removeObserver(
      self, name: .showAixlgPluginCenterWindow, object: nil)
    if let showSleepManagementObserver {
      DistributedNotificationCenter.default().removeObserver(showSleepManagementObserver)
    }
    DistributedNotificationCenter.default().removeObserver(
      self, name: .showAixlgSleepManagementWindow, object: nil)
    if let toggleSleepStatusObserver {
      DistributedNotificationCenter.default().removeObserver(toggleSleepStatusObserver)
    }
    if let networkSpeedPluginObserver {
      NotificationCenter.default.removeObserver(networkSpeedPluginObserver)
    }
    if let sleepStatusItemObserver {
      NotificationCenter.default.removeObserver(sleepStatusItemObserver)
    }
    if let menuBarConfigurationObserver {
      NotificationCenter.default.removeObserver(menuBarConfigurationObserver)
    }
    if let volumeFeedbackObserver {
      NotificationCenter.default.removeObserver(volumeFeedbackObserver)
    }
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    if let workspaceLaunchObserver {
      workspaceCenter.removeObserver(workspaceLaunchObserver)
    }
    if let workspaceTerminateObserver {
      workspaceCenter.removeObserver(workspaceTerminateObserver)
    }
    if let workspaceActiveSpaceObserver {
      workspaceCenter.removeObserver(workspaceActiveSpaceObserver)
    }
    if let closeWindowKeyMonitor {
      NSEvent.removeMonitor(closeWindowKeyMonitor)
      self.closeWindowKeyMonitor = nil
    }
    classicTabSwitcherWindow?.orderOut(nil)
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated { codexNetworkProbeController.cancelAll() }
    stopNetworkSpeedHelper(killStale: false)
    stopSleepStatusHelper(killStale: false)
  }

  private func buildWindow() {
    let root = RootView().environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: defaultWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = appDisplayName
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 820, height: 600)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.delegate = self
    window.contentView = hosting
    let titlebarHosting = NSHostingView(
      rootView: MainWindowTitlebarView(title: appDisplayName).environmentObject(model))
    titlebarHosting.sizingOptions = [.intrinsicContentSize]
    titlebarHosting.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
    let titlebarAccessory = NSTitlebarAccessoryViewController()
    titlebarAccessory.layoutAttribute = .left
    titlebarAccessory.view = titlebarHosting
    window.addTitlebarAccessoryViewController(titlebarAccessory)
    mainWindowTitlebarAccessory = titlebarAccessory
    window.center()
    self.window = window
  }

  private func buildLauncherWindow() {
    let root = LauncherOverlayView(
      onClose: { [weak self] in self?.hideLauncher() },
      onOpen: { [weak self] app in
        self?.model.openLauncherApp(app)
        self?.hideLauncher()
      }
    )
    .environmentObject(model)

    let hosting = NSHostingView(rootView: root)
    hosting.wantsLayer = true
    let panel = LauncherPanelWindow(
      contentRect: NSRect(origin: .zero, size: launcherWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = "小龙哥启动器"
    panel.contentView = hosting
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.delegate = self
    panel.contentMinSize = NSSize(width: 480, height: 520)
    panel.contentMaxSize = launcherWindowMaximumSize
    panel.isOpaque = true
    panel.backgroundColor = .windowBackgroundColor
    panel.hasShadow = true
    panel.level = .normal
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    launcherWindow = panel
  }

  private func buildAIPlayerWindow() {
    let root = AIPlayerView(controller: model.aiPlayer)
    let hosting = NSHostingView(rootView: root)
    let playerWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: aiPlayerWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    playerWindow.title = "听澜播放器"
    playerWindow.minSize = NSSize(width: 720, height: 480)
    playerWindow.isReleasedWhenClosed = false
    playerWindow.isRestorable = false
    playerWindow.delegate = self
    playerWindow.contentView = hosting
    playerWindow.center()
    aiPlayerWindow = playerWindow
  }

  private func buildProcessViewerWindow() {
    let root = ProcessViewerWindowRoot()
      .environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    let viewerWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: processViewerWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    viewerWindow.title = "进程查看器"
    viewerWindow.minSize = NSSize(width: 820, height: 600)
    viewerWindow.isReleasedWhenClosed = false
    viewerWindow.isRestorable = false
    viewerWindow.delegate = self
    viewerWindow.contentView = hosting
    viewerWindow.center()
    processViewerWindow = viewerWindow
  }

  private func buildClipboardHistoryWindow() {
    let root = ClipboardHistoryWindowView(controller: model.clipboardHistory) { [weak self] entry in
      self?.handleClipboardHistoryEntryActivation(entry)
    }
    let hosting = NSHostingView(rootView: root)
    let historyWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: clipboardHistoryWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    historyWindow.title = "剪贴板历史"
    historyWindow.minSize = NSSize(width: 440, height: 500)
    historyWindow.maxSize = NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
    historyWindow.isReleasedWhenClosed = false
    historyWindow.isRestorable = false
    historyWindow.delegate = self
    historyWindow.contentView = hosting
    historyWindow.center()
    clipboardHistoryWindow = historyWindow
  }

  private func buildCodexNetworkProbeWindow() {
    let root = CodexNetworkProbeWindowRoot(controller: codexNetworkProbeController)
      .environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    let probeWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: codexNetworkProbeWindowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    probeWindow.title = "测试网速"
    probeWindow.minSize = NSSize(width: 580, height: 480)
    probeWindow.isReleasedWhenClosed = false
    probeWindow.isRestorable = false
    probeWindow.delegate = self
    probeWindow.contentView = hosting
    probeWindow.center()
    codexNetworkProbeWindow = probeWindow
  }

  private func buildSleepManagementWindow() {
    let root = KeepAwakeSheetView { [weak self] in
      self?.sleepManagementWindow?.close()
    }
    .environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    let sleepWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: sleepManagementWindowSize),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    sleepWindow.title = "保持唤醒"
    sleepWindow.isReleasedWhenClosed = false
    sleepWindow.isRestorable = false
    sleepWindow.delegate = self
    sleepWindow.contentView = hosting
    sleepWindow.center()
    sleepManagementWindow = sleepWindow
  }

  private func buildClassicTabSwitcherWindow() {
    let root = ClassicTabSwitcherHUDView()
      .environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    hosting.wantsLayer = true
    let panel = ClassicTabSwitcherPanelWindow(
      contentRect: NSRect(origin: .zero, size: classicTabSwitcherWindowSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = hosting
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    classicTabSwitcherWindow = panel
  }

  private func buildMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: appDisplayName)

    let settings = NSMenuItem(
      title: "设置…", action: #selector(showSettingsAction), keyEquivalent: ",")
    settings.keyEquivalentModifierMask = [.command]
    settings.target = self

    let update = NSMenuItem(
      title: "检查更新…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
    update.target = self

    let open = NSMenuItem(
      title: "功能快捷键", action: #selector(showShortcutGuideAction), keyEquivalent: "")
    open.keyEquivalentModifierMask = [.command]
    open.target = self

    let launcher = NSMenuItem(
      title: "打开 App 启动器", action: #selector(showLauncherAction), keyEquivalent: "")
    launcher.target = self

    let phrases = NSMenuItem(
      title: "打开快捷短语", action: #selector(showPhraseWindowAction), keyEquivalent: "")
    phrases.target = self

    let quit = NSMenuItem(
      title: "退出 \(appDisplayName)", action: #selector(quit), keyEquivalent: "q")
    quit.keyEquivalentModifierMask = [.command]
    quit.target = self

    appMenu.addItem(settings)
    appMenu.addItem(update)
    appMenu.addItem(launcher)
    appMenu.addItem(open)
    appMenu.addItem(phrases)
    appMenu.addItem(.separator())
    appMenu.addItem(quit)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let fileMenuItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    let fileMenu = NSMenu(title: "文件")
    let newShortcut = NSMenuItem(
      title: "新增快捷键", action: #selector(createShortcutAction), keyEquivalent: "n")
    newShortcut.keyEquivalentModifierMask = [.command]
    newShortcut.target = self
    let closeWindow = NSMenuItem(
      title: "关闭窗口", action: #selector(closeWindowAction), keyEquivalent: "w")
    closeWindow.keyEquivalentModifierMask = [.command]
    closeWindow.target = self
    fileMenu.addItem(newShortcut)
    fileMenu.addItem(.separator())
    fileMenu.addItem(closeWindow)
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "编辑")
    let undo = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    let cut = NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    let copy = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    let paste = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let selectAll = NSMenuItem(
      title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(undo)
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    editMenu.addItem(cut)
    editMenu.addItem(copy)
    editMenu.addItem(paste)
    editMenu.addItem(.separator())
    editMenu.addItem(selectAll)
    editMenu.addItem(.separator())
    let editShortcut = NSMenuItem(
      title: "前往功能快捷键…", action: #selector(showShortcutGuideAction), keyEquivalent: "")
    editShortcut.target = self
    editMenu.addItem(editShortcut)
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "窗口")
    let minimize = NSMenuItem(
      title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    let zoom = NSMenuItem(
      title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    let bringAll = NSMenuItem(
      title: "全部置于前面", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowMenu.addItem(minimize)
    windowMenu.addItem(zoom)
    windowMenu.addItem(.separator())
    windowMenu.addItem(bringAll)
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    NSApp.windowsMenu = windowMenu

    let helpMenuItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
    let helpMenu = NSMenu(title: "帮助")
    let feedback = NSMenuItem(
      title: "加入交流群", action: #selector(showCommunityQRCodeAction), keyEquivalent: "")
    feedback.target = self
    feedback.toolTip = "显示交流群二维码"
    feedback.setAccessibilityLabel("加入交流群，显示入群二维码")
    helpMenu.addItem(feedback)
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
  }

  private func startCloseWindowKeyMonitor() {
    guard closeWindowKeyMonitor == nil else { return }
    closeWindowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      guard self.isCommandW(event) else { return event }
      return self.closeFrontmostWindowForCommandW() ? nil : event
    }
  }

  private func isCommandW(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
      !flags.contains(.option),
      !flags.contains(.control),
      !flags.contains(.shift)
    else {
      return false
    }
    return event.charactersIgnoringModifiers?.lowercased() == "w"
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  private func startBackgroundActivity() {
    backgroundActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "Keep global hotkeys responsive while the window is hidden."
    )
  }

  private func startGlobalInputOwnershipMonitoring() {
    guard workspaceLaunchObserver == nil, workspaceTerminateObserver == nil else { return }
    let center = NSWorkspace.shared.notificationCenter
    workspaceLaunchObserver = center.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let bundleIdentifier =
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .bundleIdentifier
      guard bundleIdentifier == nil || bundleIdentifier == AppRuntimeIdentity.stableBundleIdentifier
      else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        _ = self.model.refreshGlobalInputOwnership(trigger: "workspaceLaunch")
      }
    }
    workspaceTerminateObserver = center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let bundleIdentifier =
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .bundleIdentifier
      guard bundleIdentifier == nil || bundleIdentifier == AppRuntimeIdentity.stableBundleIdentifier
      else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        _ = self.model.refreshGlobalInputOwnership(trigger: "workspaceTerminate")
      }
    }

    globalInputOwnershipTimer?.invalidate()
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        _ = self?.model.refreshGlobalInputOwnership(trigger: "watchdog")
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    globalInputOwnershipTimer = timer
    _ = model.refreshGlobalInputOwnership(trigger: "monitoringStarted")
  }

  private func isRelevantGlobalInputRuntimeChange(_ notification: Notification) -> Bool {
    guard
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      let bundleIdentifier = application.bundleIdentifier
    else {
      return true
    }
    return bundleIdentifier == AppRuntimeIdentity.stableBundleIdentifier
  }

  private func buildStatusMenu() {
    refreshStatusMenu()
    buildStatusHelpers()
    startStatusHelperWatchdog()
  }

  private func buildStatusHelpers() {
    syncSleepStatusItemVisibility()
    syncNetworkSpeedStatusItemVisibility()
  }

  private func buildSleepStatusItemIfNeeded() {
    guard sleepStatusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: 44)
    item.autosaveName = NSStatusItem.AutosaveName(
      "\(runtimeIdentity.notificationNamespace).sleepStatusItem.v3")
    if let button = item.button {
      button.image = nil
      button.imagePosition = .noImage
      button.target = self
      button.action = #selector(sleepStatusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    item.isVisible = true
    sleepStatusItem = item
    updateSleepStatusItem()
  }

  private func removeSleepStatusItem() {
    guard let sleepStatusItem else { return }
    NSStatusBar.system.removeStatusItem(sleepStatusItem)
    self.sleepStatusItem = nil
  }

  private func startNetworkSpeedHelperIfNeeded() {
    if networkSpeedHelperProcess?.isRunning == true { return }
    guard ProcessInfo.processInfo.systemUptime >= networkSpeedHelperRestartNotBefore else { return }
    stopNetworkSpeedHelper(killStale: true)

    guard let helperURL = networkSpeedHelperURL(),
      FileManager.default.isExecutableFile(atPath: helperURL.path)
    else {
      AppDiagnostics.log(
        "network_speed_helper_missing",
        ["name": networkSpeedHelperExecutableName])
      registerNetworkSpeedHelperFailure()
      return
    }

    let process = Process()
    process.executableURL = helperURL
    let parentToHelper = Pipe()
    let helperToParent = Pipe()
    process.standardInput = parentToHelper
    process.standardOutput = helperToParent
    var environment = ProcessInfo.processInfo.environment
    environment["AIXLG_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
    environment["AIXLG_PARENT_BUNDLE_ID"] =
      Bundle.main.bundleIdentifier ?? runtimeIdentity.bundleIdentifier
    environment["AIXLG_PARENT_APP_PATH"] = Bundle.main.bundleURL.path
    environment["AIXLG_PARENT_EXECUTABLE"] =
      Bundle.main.executableURL?.lastPathComponent ?? runtimeIdentity.mainExecutableName
    environment["AIXLG_HELPER_EXECUTABLE"] = networkSpeedHelperExecutableName
    environment["AIXLG_NOTIFICATION_NAMESPACE"] = runtimeIdentity.notificationNamespace
    environment["AIXLG_DEFAULTS_SUITE"] = runtimeIdentity.defaultsSuiteName
    environment["AIXLG_APP_DISPLAY_NAME"] = runtimeIdentity.displayName
    process.environment = environment
    let helperOutput = helperToParent.fileHandleForReading
    helperOutput.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      DispatchQueue.main.async {
        self?.receiveNetworkSpeedHelperOutput(data)
      }
    }
    process.terminationHandler = { [weak self, weak process] _ in
      DispatchQueue.main.async {
        if self?.networkSpeedHelperProcess === process {
          self?.networkSpeedHelperProcess = nil
          self?.resetNetworkSpeedHelperIPC()
          self?.registerNetworkSpeedHelperFailure()
        }
      }
    }

    do {
      try process.run()
      networkSpeedHelperProcess = process
      networkSpeedHelperInputHandle = parentToHelper.fileHandleForWriting
      networkSpeedHelperOutputHandle = helperOutput
      publishNetworkStatusMenuSnapshot()
      AppDiagnostics.log(
        "network_speed_helper_started",
        ["pid": "\(process.processIdentifier)", "name": networkSpeedHelperExecutableName])
      markNetworkSpeedHelperStableIfStillRunning(process)
    } catch {
      helperOutput.readabilityHandler = nil
      try? parentToHelper.fileHandleForWriting.close()
      try? helperOutput.close()
      AppDiagnostics.log(
        "network_speed_helper_failed",
        ["error": "\(error)", "path": helperURL.path])
      registerNetworkSpeedHelperFailure()
    }
  }

  private func startSleepStatusHelperIfNeeded() {
    if sleepStatusHelperProcess?.isRunning == true {
      publishSleepStatusHelperState()
      return
    }
    guard ProcessInfo.processInfo.systemUptime >= sleepStatusHelperRestartNotBefore else { return }
    stopSleepStatusHelper(killStale: true)

    guard let helperURL = sleepStatusHelperURL(),
      FileManager.default.isExecutableFile(atPath: helperURL.path)
    else {
      AppDiagnostics.log(
        "sleep_status_helper_missing",
        ["name": sleepStatusHelperExecutableName])
      registerSleepStatusHelperFailure()
      return
    }

    let process = Process()
    process.executableURL = helperURL
    let capabilityToken = UUID().uuidString
    sleepStatusHelperCapabilityToken = capabilityToken
    var environment = ProcessInfo.processInfo.environment
    environment["AIXLG_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
    environment["AIXLG_PARENT_BUNDLE_ID"] =
      Bundle.main.bundleIdentifier ?? runtimeIdentity.bundleIdentifier
    environment["AIXLG_PARENT_APP_PATH"] = Bundle.main.bundleURL.path
    environment["AIXLG_PARENT_EXECUTABLE"] =
      Bundle.main.executableURL?.lastPathComponent ?? runtimeIdentity.mainExecutableName
    environment["AIXLG_HELPER_EXECUTABLE"] = sleepStatusHelperExecutableName
    environment["AIXLG_NOTIFICATION_NAMESPACE"] = runtimeIdentity.notificationNamespace
    environment["AIXLG_DEFAULTS_SUITE"] = runtimeIdentity.defaultsSuiteName
    environment["AIXLG_APP_DISPLAY_NAME"] = runtimeIdentity.displayName
    environment["AIXLG_SLEEP_CAPABILITY_TOKEN"] = capabilityToken
    process.environment = environment
    process.terminationHandler = { [weak self, weak process] _ in
      DispatchQueue.main.async {
        if self?.sleepStatusHelperProcess === process {
          self?.sleepStatusHelperProcess = nil
          self?.lastSleepStatusHelperStateSignature = nil
          self?.sleepStatusHelperCapabilityToken = nil
          self?.registerSleepStatusHelperFailure()
        }
      }
    }

    do {
      try process.run()
      sleepStatusHelperProcess = process
      AppDiagnostics.log(
        "sleep_status_helper_started",
        ["pid": "\(process.processIdentifier)", "name": sleepStatusHelperExecutableName])
      markSleepStatusHelperStableIfStillRunning(process)
      publishSleepStatusHelperState(force: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.publishSleepStatusHelperState(force: true)
      }
    } catch {
      if sleepStatusHelperCapabilityToken == capabilityToken {
        sleepStatusHelperCapabilityToken = nil
      }
      AppDiagnostics.log(
        "sleep_status_helper_failed",
        ["error": "\(error)", "path": helperURL.path])
      registerSleepStatusHelperFailure()
    }
  }

  private func stopNetworkSpeedHelper(killStale: Bool) {
    if let process = networkSpeedHelperProcess, process.isRunning {
      process.terminate()
    }
    networkSpeedHelperProcess = nil
    resetNetworkSpeedHelperIPC()

    guard killStale else { return }
    terminateStaleHelperProcesses(named: networkSpeedHelperExecutableName)
  }

  private func resetNetworkSpeedHelperIPC() {
    networkSpeedHelperOutputHandle?.readabilityHandler = nil
    try? networkSpeedHelperInputHandle?.close()
    try? networkSpeedHelperOutputHandle?.close()
    networkSpeedHelperInputHandle = nil
    networkSpeedHelperOutputHandle = nil
    networkSpeedHelperReadBuffer.removeAll(keepingCapacity: false)
  }

  private func receiveNetworkSpeedHelperOutput(_ data: Data) {
    networkSpeedHelperReadBuffer.append(data)
    guard networkSpeedHelperReadBuffer.count <= 16_384 else {
      networkSpeedHelperReadBuffer.removeAll(keepingCapacity: false)
      AppDiagnostics.log("network_speed_helper_command_overflow")
      return
    }
    while let newline = networkSpeedHelperReadBuffer.firstIndex(of: 0x0A) {
      let lineData = networkSpeedHelperReadBuffer[..<newline]
      networkSpeedHelperReadBuffer.removeSubrange(...newline)
      guard !lineData.isEmpty,
        let command = String(data: lineData, encoding: .utf8)
      else { continue }
      handleNetworkSpeedHelperCommand(command)
    }
  }

  private func handleNetworkSpeedHelperCommand(_ command: String) {
    let youmuCommandID: String? =
      switch command {
      case "youmu.quickSnapshot": YoumuFeatureShortcutCatalog.quickSnapshot.id
      case "youmu.annotatedScreenshot": YoumuFeatureShortcutCatalog.annotatedScreenshot.id
      case "youmu.longScreenshot": YoumuFeatureShortcutCatalog.longScreenshot.id
      case "youmu.pinScreenshot": YoumuFeatureShortcutCatalog.pinScreenshot.id
      case "youmu.ocrCopy": YoumuFeatureShortcutCatalog.ocrCopy.id
      case "youmu.ocrTranslate": YoumuFeatureShortcutCatalog.ocrTranslate.id
      case "youmu.selectionReader": YoumuFeatureShortcutCatalog.selectionReader.id
      case "youmu.imageTranslate": YoumuFeatureShortcutCatalog.imageTranslate.id
      default: nil
      }
    if let youmuCommandID {
      model.executeFeatureCommand(commandID: youmuCommandID)
      return
    }

    switch command {
    case "host.requestMenuSnapshot":
      publishNetworkStatusMenuSnapshot()
    case "host.phrases":
      showPhraseWindowAction()
    case "host.inputMethod":
      showInputMethodManagementAction()
    case "host.networkProbe":
      showCodexNetworkProbeStatusAction()
    case "host.keepAwake":
      showSleepManagementAction()
    case "host.launcher":
      showLauncherAction()
    case "host.shortcuts":
      showShortcutGuideAction()
    case "host.processViewer":
      showProcessViewerStatusAction()
    case "host.pijuanPDF":
      model.showPijuanPDFFeature()
    case "host.aiPlayer":
      model.showAIPlayer()
    case "host.clipboardHistory":
      model.showClipboardHistory()
    case "host.pluginCenter":
      showPluginCenterAction()
    case "host.menuBarSettings":
      model.presentMenuBarCustomization()
    case "host.settings":
      showSettingsAction()
    case "host.checkUpdates":
      checkForUpdatesAction()
    case "host.togglePaused":
      togglePaused()
    case "host.quit":
      quit()
    default:
      AppDiagnostics.log("network_speed_helper_unknown_command", ["command": command])
    }
  }

  private func stopSleepStatusHelper(killStale: Bool) {
    if let process = sleepStatusHelperProcess, process.isRunning {
      process.terminate()
    }
    sleepStatusHelperProcess = nil
    lastSleepStatusHelperStateSignature = nil
    sleepStatusHelperCapabilityToken = nil

    guard killStale else { return }
    terminateStaleHelperProcesses(named: sleepStatusHelperExecutableName)
  }

  /// Capture old identities before the caller starts a new helper. Reap only that snapshot
  /// off the AppKit thread, even if the replacement is already running when cleanup executes.
  private func terminateStaleHelperProcesses(named executableName: String) {
    guard
      let executableURL = Bundle.main.executableURL?
        .deletingLastPathComponent().appendingPathComponent(executableName)
    else { return }
    let staleHelpers = StaleHelperProcessCleanup.snapshot(executableURL: executableURL)
    guard !staleHelpers.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
      StaleHelperProcessCleanup.terminate(staleHelpers)
    }
  }

  private func networkSpeedHelperURL() -> URL? {
    Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent(networkSpeedHelperExecutableName)
  }

  private func sleepStatusHelperURL() -> URL? {
    Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent(sleepStatusHelperExecutableName)
  }

  private func registerNetworkSpeedHelperFailure() {
    networkSpeedHelperFailureCount = min(networkSpeedHelperFailureCount + 1, 20)
    networkSpeedHelperRestartNotBefore =
      ProcessInfo.processInfo.systemUptime
      + HelperRestartBackoff.delay(afterConsecutiveFailures: networkSpeedHelperFailureCount)
  }

  private func registerSleepStatusHelperFailure() {
    sleepStatusHelperFailureCount = min(sleepStatusHelperFailureCount + 1, 20)
    sleepStatusHelperRestartNotBefore =
      ProcessInfo.processInfo.systemUptime
      + HelperRestartBackoff.delay(afterConsecutiveFailures: sleepStatusHelperFailureCount)
  }

  private func markNetworkSpeedHelperStableIfStillRunning(_ process: Process) {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + HelperRestartBackoff.stableRunDuration
    ) { [weak self, weak process] in
      guard let self, let process,
        self.networkSpeedHelperProcess === process,
        process.isRunning
      else { return }
      self.networkSpeedHelperFailureCount = 0
      self.networkSpeedHelperRestartNotBefore = 0
    }
  }

  private func markSleepStatusHelperStableIfStillRunning(_ process: Process) {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + HelperRestartBackoff.stableRunDuration
    ) { [weak self, weak process] in
      guard let self, let process,
        self.sleepStatusHelperProcess === process,
        process.isRunning
      else { return }
      self.sleepStatusHelperFailureCount = 0
      self.sleepStatusHelperRestartNotBefore = 0
    }
  }

  private func refreshStatusMenu() {
    publishNetworkStatusMenuSnapshot()
  }

  private func publishNetworkStatusMenuSnapshot() {
    guard networkSpeedHelperProcess?.isRunning == true,
      let networkSpeedHelperInputHandle
    else { return }

    let handlerAvailable = model.executeFeatureCommandHandler != nil
    let commandsAvailable = handlerAvailable && model.hasGlobalInputOwnership
    var states: [NetworkStatusMenuItemState] = []

    let visibleItemIDs = model.menuBarVisibleItemIDs
    let isVisible: (String) -> Bool = { commandID in
      MenuBarCatalog.isStatusMenuCommandVisible(
        commandID,
        visibleItemIDs: visibleItemIDs)
    }

    for command in youmuStatusMenuCommands {
      var isEnabled = commandsAvailable
      var toolTip: String?
      if !handlerAvailable {
        toolTip = "游目功能尚未就绪。"
      } else if !model.hasGlobalInputOwnership {
        toolTip = model.globalInputOwnershipBlockedMessage
      }
      if command.descriptor.id == YoumuFeatureShortcutCatalog.pinScreenshot.id,
        commandsAvailable,
        !NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
      {
        isEnabled = false
        toolTip = "剪贴板中没有可钉到桌面的图片。"
      }
      states.append(
        NetworkStatusMenuItemState(
          id: command.ipcID,
          title: youmuStatusMenuTitle(command.title, commandID: command.descriptor.id),
          isEnabled: isEnabled,
          isHidden: !isVisible(command.ipcID),
          toolTip: toolTip))
    }

    states.append(
      NetworkStatusMenuItemState(
        id: "host.phrases",
        title: "快捷短语",
        isEnabled: true,
        isHidden: !isVisible("host.phrases"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.inputMethod",
        title: "输入法管理",
        isEnabled: true,
        isHidden: !isVisible("host.inputMethod"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.networkProbe",
        title: statusMenuTitle("测试网速", shortcutAction: .showCodexNetworkProbe),
        isEnabled: true,
        isHidden: !isVisible("host.networkProbe"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.keepAwake",
        title: statusMenuTitle(
          model.keepAwakeEnabled ? "保持唤醒　醒" : "保持唤醒　眠",
          shortcutAction: .showSleepPanel),
        isEnabled: true,
        isHidden: !isVisible("host.keepAwake"),
        toolTip: model.keepAwakeStatusText))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.launcher",
        title: statusMenuTitle("启动器", shortcutAction: .showLauncher),
        isEnabled: model.launcherPluginEnabled,
        isHidden: !isVisible("host.launcher"),
        toolTip: model.launcherPluginEnabled ? nil : "启动器已关闭。"))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.shortcuts",
        title: statusMenuTitle("查看快捷键", shortcutAction: .showPanel),
        isEnabled: true,
        isHidden: !isVisible("host.shortcuts"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.processViewer",
        title: statusMenuTitle("进程查看器", shortcutAction: .showProcessViewer),
        isEnabled: true,
        isHidden: !isVisible("host.processViewer"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.pijuanPDF",
        title: "披卷",
        isEnabled: true,
        isHidden: !isVisible("host.pijuanPDF"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.aiPlayer",
        title: "听澜播放器",
        isEnabled: true,
        isHidden: !isVisible("host.aiPlayer"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.clipboardHistory",
        title: statusMenuTitle("剪贴板历史", shortcutAction: .showClipboardHistory),
        isEnabled: true,
        isHidden: !isVisible("host.clipboardHistory"),
        toolTip: nil))

    states.append(
      NetworkStatusMenuItemState(
        id: "host.togglePaused",
        title: model.isPaused ? "启用后台快捷键" : "暂停后台快捷键",
        isEnabled: true,
        isHidden: false,
        toolTip: nil))

    sendNetworkStatusHelperMessage(
      NetworkStatusHelperMessage(
        type: "snapshot",
        snapshot: NetworkStatusMenuSnapshot(items: states),
        volume: nil),
      inputHandle: networkSpeedHelperInputHandle)
  }

  private func sendNetworkStatusHelperMessage(
    _ message: NetworkStatusHelperMessage,
    inputHandle: FileHandle? = nil
  ) {
    guard let handle = inputHandle ?? networkSpeedHelperInputHandle else { return }
    do {
      var payload = try JSONEncoder().encode(message)
      payload.append(0x0A)
      try handle.write(contentsOf: payload)
    } catch {
      AppDiagnostics.log("network_speed_helper_message_failed", ["error": "\(error)"])
    }
  }

  private var youmuStatusMenuCommands:
    [(ipcID: String, title: String, descriptor: FeatureShortcutCommandDescriptor)]
  {
    [
      ("youmu.quickSnapshot", "快速截图", YoumuFeatureShortcutCatalog.quickSnapshot),
      (
        "youmu.annotatedScreenshot", "截图并标注",
        YoumuFeatureShortcutCatalog.annotatedScreenshot
      ),
      ("youmu.longScreenshot", "长截图", YoumuFeatureShortcutCatalog.longScreenshot),
      ("youmu.pinScreenshot", "钉截图", YoumuFeatureShortcutCatalog.pinScreenshot),
      ("youmu.ocrCopy", "OCR 复制", YoumuFeatureShortcutCatalog.ocrCopy),
      ("youmu.ocrTranslate", "OCR 翻译", YoumuFeatureShortcutCatalog.ocrTranslate),
      ("youmu.selectionReader", "选区朗读", YoumuFeatureShortcutCatalog.selectionReader),
      ("youmu.imageTranslate", "图片翻译", YoumuFeatureShortcutCatalog.imageTranslate),
    ]
  }

  private func youmuStatusMenuTitle(_ title: String, commandID: String) -> String {
    guard let shortcut = model.featureShortcutMenuLabel(for: commandID) else { return title }
    return "\(title)　\(shortcut)"
  }

  private func statusMenuTitle(_ title: String, shortcutAction: ShortcutAction) -> String {
    let shortcuts = model.statusMenuShortcutLabels(for: shortcutAction)
    guard !shortcuts.isEmpty else { return title }
    return "\(title)　\(shortcuts.joined(separator: " / "))"
  }

  private func startStatusHelperWatchdog() {
    updateStatusHelperWatchdog()
    statusHelperWatchdogTimer?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateStatusHelperWatchdog()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    statusHelperWatchdogTimer = timer
  }

  private func updateStatusHelperWatchdog() {
    if model.sleepStatusItemVisible, sleepStatusHelperProcess?.isRunning != true {
      startSleepStatusHelperIfNeeded()
    }
    updateSleepStatusItem()
    if networkSpeedHelperProcess?.isRunning != true {
      startNetworkSpeedHelperIfNeeded()
    }
  }

  private func syncSleepStatusItemVisibility() {
    if model.sleepStatusItemVisible {
      removeSleepStatusItem()
      startSleepStatusHelperIfNeeded()
      publishSleepStatusHelperState()
    } else {
      removeSleepStatusItem()
      stopSleepStatusHelper(killStale: true)
    }
    AppDiagnostics.log(
      "sleep_status_item_visibility",
      [
        "visible": "\(model.sleepStatusItemVisible)",
        "itemExists": "\(sleepStatusItem != nil)",
        "helperRunning": "\(sleepStatusHelperProcess?.isRunning == true)",
        "active": "\(model.keepAwakeEnabled)",
        "status": model.keepAwakeStatusText,
      ])
  }

  private func syncNetworkSpeedStatusItemVisibility() {
    startNetworkSpeedHelperIfNeeded()
    updateStatusHelperWatchdog()
    AppDiagnostics.log(
      "network_speed_status_item_visibility",
      [
        "enabled": "true",
        "helperRunning": "\(networkSpeedHelperProcess?.isRunning == true)",
        "mode": "primary_host_entry",
      ])
  }

  private func updateSleepStatusItem() {
    guard model.sleepStatusItemVisible else { return }
    publishSleepStatusHelperState()
    guard let sleepStatusItem else { return }
    sleepStatusItem.length = 44
    if let button = sleepStatusItem.button {
      button.image = nil
      button.imagePosition = .noImage
      button.title = sleepStatusGlyph(active: model.keepAwakeEnabled)
      button.font = .systemFont(ofSize: 12.5, weight: .semibold)
      button.toolTip = sleepStatusTooltip()
      button.target = self
      button.action = #selector(sleepStatusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
  }

  private func sleepStatusGlyph(active: Bool) -> String {
    active ? "醒┃" : "眠╮"
  }

  private func sleepStatusTooltip() -> String {
    if model.keepAwakeEnabled {
      return "左键切换为眠 · 右键打开保持唤醒 · \(model.keepAwakeStatusText)"
    }
    return "左键切换为醒 · 右键打开保持唤醒"
  }

  private func publishSleepStatusHelperState(force: Bool = false) {
    guard sleepStatusHelperProcess?.isRunning == true,
      let sleepStatusHelperCapabilityToken
    else { return }
    let signature = "\(model.keepAwakeEnabled)|\(model.keepAwakeStatusText)"
    guard force || signature != lastSleepStatusHelperStateSignature else { return }
    lastSleepStatusHelperStateSignature = signature
    DistributedNotificationCenter.default().postNotificationName(
      .sleepStatusStateChanged,
      object: sleepStatusHelperCapabilityToken,
      userInfo: [
        "active": model.keepAwakeEnabled ? "true" : "false",
        "status": model.keepAwakeStatusText,
      ],
      deliverImmediately: true
    )
  }

  private func sleepStatusIconImage(active: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.black.setStroke()
    let path = NSBezierPath()
    path.lineWidth = active ? 2.3 : 2.1
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    if active {
      path.move(to: NSPoint(x: 9, y: 3.2))
      path.line(to: NSPoint(x: 9, y: 14.8))
    } else {
      path.move(to: NSPoint(x: 7.1, y: 14.2))
      path.curve(
        to: NSPoint(x: 12.7, y: 4.1),
        controlPoint1: NSPoint(x: 7.1, y: 9.0),
        controlPoint2: NSPoint(x: 12.7, y: 10.0)
      )
    }
    path.stroke()
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  private func startPermissionPolling(reason: String) {
    permissionTimer?.invalidate()
    permissionTimer = nil
    guard !model.allRequiredPermissionsComplete else { return }

    permissionPollsRemaining = 240
    AppDiagnostics.log(
      "authorization_polling_started",
      ["reason": reason, "maximumPolls": "\(permissionPollsRemaining)"])
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.permissionPollsRemaining -= 1
        if self.model.refreshAuthorizationAndReloadIfNeeded() {
          self.refreshStatusMenu()
        }
        if self.model.allRequiredPermissionsComplete || self.permissionPollsRemaining <= 0 {
          self.permissionTimer?.invalidate()
          self.permissionTimer = nil
          AppDiagnostics.log(
            "authorization_polling_stopped",
            [
              "complete": "\(self.model.allRequiredPermissionsComplete)",
              "remaining": "\(self.permissionPollsRemaining)",
            ])
        }
      }
    }
  }

  private func startShowWindowObserver() {
    showWindowObserver = DistributedNotificationCenter.default().addObserver(
      forName: .showAixlgHotkeysWindow,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.presentMainWindow() }
    }
    showLauncherObserver = NotificationCenter.default.addObserver(
      forName: .showAixlgLauncherWindow,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.toggleLauncher() }
    }
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(showLauncherAction),
      name: .showAixlgLauncherWindow,
      object: nil
    )
  }

  private func startShortcutWindowRestorationObserver() {
    guard workspaceActiveSpaceObserver == nil else { return }
    workspaceActiveSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.settlePendingShortcutWindowRestorations() }
    }
  }

  private func startPluginCenterObserver() {
    guard showPluginCenterObserver == nil else { return }
    showPluginCenterObserver = DistributedNotificationCenter.default().addObserver(
      forName: .showAixlgPluginCenterWindow,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.showPluginCenterAction() }
    }
  }

  private func startSleepManagementObserver() {
    guard showSleepManagementObserver == nil else { return }
    showSleepManagementObserver = DistributedNotificationCenter.default().addObserver(
      forName: .showAixlgSleepManagementWindow,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let capabilityToken = notification.object as? String
      MainActor.assumeIsolated {
        guard let self,
          capabilityToken == self.sleepStatusHelperCapabilityToken,
          self.sleepStatusHelperProcess?.isRunning == true
        else { return }
        self.showSleepManagementAction()
      }
    }
  }

  private func startSleepStatusToggleObserver() {
    guard toggleSleepStatusObserver == nil else { return }
    toggleSleepStatusObserver = DistributedNotificationCenter.default().addObserver(
      forName: .toggleAixlgSleepStatus,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let capabilityToken = notification.object as? String
      MainActor.assumeIsolated {
        guard let self,
          capabilityToken == self.sleepStatusHelperCapabilityToken,
          self.sleepStatusHelperProcess?.isRunning == true
        else { return }
        self.toggleSleepStatus(source: "helper")
      }
    }
  }

  private func startVolumeFeedbackObserver() {
    guard volumeFeedbackObserver == nil else { return }
    volumeFeedbackObserver = NotificationCenter.default.addObserver(
      forName: .showAixlgVolumeFeedback,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let volume = notification.userInfo?["volume"] as? Double
      let source = notification.userInfo?["source"] as? String ?? "unknown"
      MainActor.assumeIsolated {
        guard let volume else { return }
        self?.handleVolumeFeedback(volume: volume, source: source)
      }
    }
  }

  private func startNetworkSpeedPluginObserver() {
    guard networkSpeedPluginObserver == nil else { return }
    networkSpeedPluginObserver = NotificationCenter.default.addObserver(
      forName: .networkSpeedPluginVisibilityChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.syncNetworkSpeedStatusItemVisibility()
        self.sendNetworkStatusHelperMessage(
          NetworkStatusHelperMessage(
            type: "healthPreferencesChanged",
            snapshot: nil,
            volume: nil))
      }
    }
  }

  private func startSleepStatusItemObserver() {
    guard sleepStatusItemObserver == nil else { return }
    sleepStatusItemObserver = NotificationCenter.default.addObserver(
      forName: .sleepStatusItemChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncSleepStatusItemVisibility() }
    }
  }

  private func startMenuBarConfigurationObserver() {
    guard menuBarConfigurationObserver == nil else { return }
    menuBarConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .menuBarConfigurationChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishNetworkStatusMenuSnapshot() }
    }
  }


  private func configureSparkleUpdaterIfRequired() {
    guard model.usesSparkleUpdater, runtimeIdentity.allowsOnlineUpdates else { return }
    let controller = SparkleUpdateController { [weak model] state in
      model?.handleSparkleUpdateState(state)
    }
    sparkleUpdateController = controller
    model.sparkleCheckForUpdatesHandler = { [weak controller] in
      Task { @MainActor in
        controller?.checkForUpdates()
      }
    }
    controller.start()
  }

  private func handleVolumeFeedback(volume: Double, source: String) {
    sendNetworkStatusHelperMessage(
      NetworkStatusHelperMessage(
        type: "volume",
        snapshot: nil,
        volume: min(100, max(0, volume))))
    AppDiagnostics.log(
      "volume_feedback_relayed_to_primary_status_item",
      [
        "source": source,
        "volume": "\(Int(volume.rounded()))%",
        "appActive": "\(NSApp.isActive)",
        "appHidden": "\(NSApp.isHidden)",
      ])
  }

  private func showWindow(ticket: ShortcutWindowToggleTicket) {
    guard !shouldSuppressMainWindowForLauncher else { return }
    guard !model.isLongScreenshotCaptureActive else {
      AppDiagnostics.log("main_window_suppressed", ["reason": "youmuLongScreenshot"])
      return
    }
    if window == nil {
      buildWindow()
    }
    NSApp.unhide(nil)
    normalizeWindowFrameIfNeeded()
    window?.orderFrontRegardless()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.shortcutWindowToggleState.accepts(ticket),
        ticket.wantsPresented,
        !self.model.isLongScreenshotCaptureActive
      else { return }
      self.window?.orderFrontRegardless()
      self.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func showAIPlayer() {
    if aiPlayerWindow == nil {
      buildAIPlayerWindow()
    }
    hideLauncherForDestinationSwitch()
    hideProcessViewerWindow()
    hideCodexNetworkProbeWindow()
    hideClipboardHistoryWindow()
    sleepManagementWindow?.orderOut(nil)
    window?.orderOut(nil)
    model.aiPlayer.start()
    NSApp.unhide(nil)
    aiPlayerWindow?.orderFrontRegardless()
    aiPlayerWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func presentMainWindow() {
    presentShortcutWindow(.main)
  }

  private func presentMainWindow(ticket: ShortcutWindowToggleTicket) {
    hideLauncherForDestinationSwitch()
    hideProcessViewerWindow()
    hideCodexNetworkProbeWindow()
    hideClipboardHistoryWindow()
    sleepManagementWindow?.orderOut(nil)
    aiPlayerWindow?.orderOut(nil)
    showWindow(ticket: ticket)
  }

  private func toggleMainWindow() {
    _ = toggleShortcutWindow(.main)
  }

  private func toggleLauncher() {
    _ = toggleShortcutWindow(.launcher)
  }

  @discardableResult
  private func presentShortcutWindow(
    _ target: ShortcutWindowTarget
  ) -> ShortcutWindowToggleOutcome {
    prepareShortcutWindowRoute(target)
    let snapshot = shortcutWindowSnapshot(for: target)
    let ticket = shortcutWindowToggleState.present(target: target)
    captureClipboardHistoryReturnApplicationIfNeeded(for: target)
    settlePendingShortcutWindowRestorations()
    if snapshot.requiresSystemRestoration {
      restoreShortcutWindow(target, ticket: ticket)
    } else {
      showShortcutWindow(target, ticket: ticket)
      shortcutWindowToggleState.finish(ticket)
    }
    return .shown
  }

  private func toggleShortcutWindow(
    _ target: ShortcutWindowTarget
  ) -> ShortcutWindowToggleOutcome {
    let snapshot = shortcutWindowSnapshot(for: target)
    let ticket = shortcutWindowToggleState.toggle(
      target: target,
      snapshot: snapshot)
    if ticket.wantsPresented {
      prepareShortcutWindowRoute(target)
      captureClipboardHistoryReturnApplicationIfNeeded(for: target)
    }
    settlePendingShortcutWindowRestorations()
    if ticket.wantsPresented {
      if snapshot.requiresSystemRestoration {
        restoreShortcutWindow(target, ticket: ticket)
      } else {
        showShortcutWindow(target, ticket: ticket)
        shortcutWindowToggleState.finish(ticket)
      }
      return .shown
    }
    hideShortcutWindow(target)
    shortcutWindowToggleState.finish(ticket)
    return .hidden
  }

  private func restoreShortcutWindow(
    _ target: ShortcutWindowTarget,
    ticket: ShortcutWindowToggleTicket
  ) {
    guard let targetWindow = shortcutWindow(for: target) else { return }
    pendingRestorationTickets[target] = ticket
    hideSiblingShortcutWindows(except: targetWindow)
    NSApp.unhide(nil)
    targetWindow.deminiaturize(nil)
    targetWindow.orderFrontRegardless()
    targetWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settlePendingShortcutWindowRestoration(for: target)
    DispatchQueue.main.async { [weak self] in
      self?.settlePendingShortcutWindowRestoration(for: target)
    }
  }

  private func completeShortcutWindowRestorationLifecycle(_ target: ShortcutWindowTarget) {
    switch target {
    case .launcher:
      model.activateInputMethodForLauncher()
      model.markLauncherInteractive()
      model.markLauncherFirstResultsIfAvailable(source: "window_restore")
    case .processViewer:
      NotificationCenter.default.post(
        name: .processViewerWindowVisibilityChanged,
        object: true)
    case .clipboardHistory:
      model.clipboardHistory.requestSearchFocus()
    case .main, .shortcutGuide, .settings, .networkProbe, .sleepManagement, .aiPlayer:
      break
    }
  }

  private func hideSiblingShortcutWindows(except targetWindow: NSWindow) {
    if let window, window !== targetWindow {
      window.orderOut(nil)
    }
    if let launcherWindow, launcherWindow !== targetWindow {
      hideLauncherForDestinationSwitch()
    }
    if let processViewerWindow, processViewerWindow !== targetWindow {
      hideProcessViewerWindow()
    }
    if let clipboardHistoryWindow, clipboardHistoryWindow !== targetWindow {
      hideClipboardHistoryWindow()
    }
    if let codexNetworkProbeWindow, codexNetworkProbeWindow !== targetWindow {
      hideCodexNetworkProbeWindow()
    }
    if let sleepManagementWindow, sleepManagementWindow !== targetWindow {
      sleepManagementWindow.orderOut(nil)
    }
    if let aiPlayerWindow, aiPlayerWindow !== targetWindow {
      aiPlayerWindow.orderOut(nil)
    }
  }

  private func settlePendingShortcutWindowRestorations() {
    for target in Array(pendingRestorationTickets.keys) {
      settlePendingShortcutWindowRestoration(for: target)
    }
  }

  private func settlePendingShortcutWindowRestoration(
    for target: ShortcutWindowTarget
  ) {
    guard let ticket = pendingRestorationTickets[target] else { return }
    if shortcutWindowToggleState.accepts(ticket), ticket.wantsPresented {
      let snapshot = shortcutWindowSnapshot(for: target)
      if !snapshot.routeMatches {
        guard snapshot.isSystemPresented else { return }
        pendingRestorationTickets[target] = nil
        shortcutWindowToggleState.finish(ticket)
        return
      }
      guard snapshot.isPresented else { return }
      pendingRestorationTickets[target] = nil
      shortcutWindowToggleState.finish(ticket)
      completeShortcutWindowRestorationLifecycle(target)
      return
    }

    if shortcutWindowToggleState.pendingTarget?.presentationSlot == target.presentationSlot,
      shortcutWindowToggleState.desiredPresented == true
    {
      pendingRestorationTickets[target] = nil
      return
    }

    suppressSupersededShortcutWindowRestoration(target)
    let targetWindow = shortcutWindow(for: target)
    if targetWindow?.isMiniaturized != true, targetWindow?.isVisible != true {
      pendingRestorationTickets[target] = nil
    }
  }

  private func suppressSupersededShortcutWindowRestoration(
    _ target: ShortcutWindowTarget
  ) {
    switch target {
    case .main, .shortcutGuide:
      window?.orderOut(nil)
    case .settings:
      window?.orderOut(nil)
    case .launcher:
      hideLauncherForDestinationSwitch()
    case .processViewer:
      hideProcessViewerWindow()
    case .clipboardHistory:
      hideClipboardHistoryWindow()
    case .networkProbe:
      hideCodexNetworkProbeWindow()
    case .sleepManagement:
      sleepManagementWindow?.orderOut(nil)
    case .aiPlayer:
      aiPlayerWindow?.orderOut(nil)
    }
  }

  private func removePendingShortcutWindowRestoration(for targetWindow: NSWindow) {
    for target in Array(pendingRestorationTickets.keys)
    where shortcutWindow(for: target) === targetWindow {
      pendingRestorationTickets[target] = nil
    }
  }

  private func shortcutWindowSnapshot(
    for target: ShortcutWindowTarget
  ) -> ShortcutWindowPresentationSnapshot {
    let targetWindow = shortcutWindow(for: target)
    return ShortcutWindowPresentationSnapshot(
      exists: targetWindow != nil,
      isVisible: targetWindow?.isVisible == true,
      isMiniaturized: targetWindow?.isMiniaturized == true,
      appIsHidden: NSApp.isHidden,
      isOnActiveSpace: targetWindow?.isOnActiveSpace ?? true,
      routeMatches: shortcutWindowRouteMatches(target))
  }

  private func shortcutWindowRouteMatches(_ target: ShortcutWindowTarget) -> Bool {
    switch target {
    case .shortcutGuide:
      return model.selectedModuleName == "功能快捷键"
    case .settings:
      return model.isSettingsPresented
    case .main, .launcher, .processViewer, .clipboardHistory, .networkProbe,
      .sleepManagement, .aiPlayer:
      return true
    }
  }

  private func prepareShortcutWindowRoute(_ target: ShortcutWindowTarget) {
    switch target {
    case .settings:
      model.showSettings()
    case .shortcutGuide:
      model.selectedModuleName = "功能快捷键"
    case .main, .launcher, .processViewer, .clipboardHistory, .networkProbe,
      .sleepManagement, .aiPlayer:
      break
    }
  }

  private func shortcutWindow(for target: ShortcutWindowTarget) -> NSWindow? {
    switch target {
    case .main, .shortcutGuide, .settings:
      return window
    case .launcher:
      return launcherWindow
    case .processViewer:
      return processViewerWindow
    case .clipboardHistory:
      return clipboardHistoryWindow
    case .networkProbe:
      return codexNetworkProbeWindow
    case .sleepManagement:
      return sleepManagementWindow
    case .aiPlayer:
      return aiPlayerWindow
    }
  }

  private func showShortcutWindow(
    _ target: ShortcutWindowTarget,
    ticket: ShortcutWindowToggleTicket
  ) {
    NSApp.unhide(nil)
    shortcutWindow(for: target)?.deminiaturize(nil)
    switch target {
    case .main, .shortcutGuide:
      presentMainWindow(ticket: ticket)
    case .settings:
      presentMainWindow(ticket: ticket)
    case .launcher:
      showLauncher(ticket: ticket)
    case .processViewer:
      showProcessViewer()
    case .clipboardHistory:
      showClipboardHistory()
    case .networkProbe:
      showCodexNetworkProbe()
    case .sleepManagement:
      showSleepManagementWindow()
    case .aiPlayer:
      showAIPlayer()
    }
  }

  private func hideShortcutWindow(_ target: ShortcutWindowTarget) {
    switch target {
    case .main, .shortcutGuide:
      window?.orderOut(nil)
    case .settings:
      window?.orderOut(nil)
    case .launcher:
      hideLauncher()
    case .processViewer:
      hideProcessViewerWindow()
    case .clipboardHistory:
      hideClipboardHistoryWindow()
    case .networkProbe:
      hideCodexNetworkProbeWindow()
    case .sleepManagement:
      sleepManagementWindow?.orderOut(nil)
    case .aiPlayer:
      // A shortcut hides the player UI; playback is stopped only by an explicit close/stop action.
      aiPlayerWindow?.orderOut(nil)
    }
  }

  private func showLauncher(ticket: ShortcutWindowToggleTicket) {
    if launcherWindow == nil {
      buildLauncherWindow()
    }
    hideProcessViewerWindow()
    hideCodexNetworkProbeWindow()
    hideClipboardHistoryWindow()
    sleepManagementWindow?.orderOut(nil)
    aiPlayerWindow?.orderOut(nil)
    model.activateInputMethodForLauncher()
    model.prepareLauncherPresentation()
    suppressMainWindowForLauncherUntil = ProcessInfo.processInfo.systemUptime + 1.4
    window?.orderOut(nil)
    positionLauncherWindowIfNeeded()
    launcherWindow?.alphaValue = 1
    launcherWindow?.orderFrontRegardless()
    launcherWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.shortcutWindowToggleState.accepts(ticket),
        ticket.wantsPresented
      else { return }
      self.model.markLauncherInteractive()
      self.model.markLauncherFirstResultsIfAvailable(source: "window")
      self.window?.orderOut(nil)
    }
  }

  private func showProcessViewer() {
    if processViewerWindow == nil {
      buildProcessViewerWindow()
    }
    hideLauncherForDestinationSwitch()
    hideCodexNetworkProbeWindow()
    hideClipboardHistoryWindow()
    sleepManagementWindow?.orderOut(nil)
    aiPlayerWindow?.orderOut(nil)
    window?.orderOut(nil)
    processViewerWindow?.center()
    processViewerWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(
      name: .processViewerWindowVisibilityChanged,
      object: true)
  }

  private func showClipboardHistory() {
    if clipboardHistoryWindow == nil {
      buildClipboardHistoryWindow()
    }
    hideLauncherForDestinationSwitch()
    hideProcessViewerWindow()
    hideCodexNetworkProbeWindow()
    sleepManagementWindow?.orderOut(nil)
    aiPlayerWindow?.orderOut(nil)
    window?.orderOut(nil)
    NSApp.unhide(nil)
    model.clipboardHistory.requestSearchFocus()
    clipboardHistoryWindow?.center()
    clipboardHistoryWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func handleClipboardHistoryEntryActivation(_ entry: ClipboardHistoryEntry) {
    model.clipboardHistory.copyToPasteboard(entry: entry) { [weak self] succeeded in
      ClipboardReplayFeedback.deliver(didCommit: succeeded)
      guard succeeded else { return }
      self?.completeClipboardHistorySelection()
    }
  }

  private func captureClipboardHistoryReturnApplicationIfNeeded(
    for target: ShortcutWindowTarget
  ) {
    guard target == .clipboardHistory else { return }
    guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
      frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      clipboardHistoryReturnApplication = nil
      return
    }
    clipboardHistoryReturnApplication = frontmostApplication
  }

  private func completeClipboardHistorySelection() {
    shortcutWindowToggleState.invalidate()
    settlePendingShortcutWindowRestorations()
    let returnApplication = clipboardHistoryReturnApplication
    clipboardHistoryReturnApplication = nil
    hideClipboardHistoryWindow()
    if let returnApplication, !returnApplication.isTerminated,
      returnApplication.activate(options: [.activateIgnoringOtherApps])
    {
      return
    }
    NSApp.hide(nil)
  }

  private func showCodexNetworkProbe() {
    if codexNetworkProbeWindow == nil {
      buildCodexNetworkProbeWindow()
    }
    hideLauncherForDestinationSwitch()
    hideProcessViewerWindow()
    hideClipboardHistoryWindow()
    sleepManagementWindow?.orderOut(nil)
    aiPlayerWindow?.orderOut(nil)
    window?.orderOut(nil)
    codexNetworkProbeWindow?.center()
    codexNetworkProbeWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated { codexNetworkProbeController.setEnabled(true) }
  }

  private func showSleepManagementWindow() {
    if sleepManagementWindow == nil {
      buildSleepManagementWindow()
    }
    hideLauncherForDestinationSwitch()
    hideProcessViewerWindow()
    hideCodexNetworkProbeWindow()
    hideClipboardHistoryWindow()
    aiPlayerWindow?.orderOut(nil)
    window?.orderOut(nil)
    sleepManagementWindow?.center()
    sleepManagementWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private var shouldSuppressMainWindowForLauncher: Bool {
    launcherWindow?.isVisible == true
      || ProcessInfo.processInfo.systemUptime < suppressMainWindowForLauncherUntil
  }

  private func hideLauncherForDestinationSwitch() {
    guard let launcherWindow else {
      suppressMainWindowForLauncherUntil = 0
      return
    }
    model.restoreInputMethodAfterLauncher()
    launcherWindow.orderOut(nil)
    launcherWindow.alphaValue = 1
    suppressMainWindowForLauncherUntil = 0
  }

  private func hideProcessViewerWindow() {
    guard let processViewerWindow else { return }
    processViewerWindow.orderOut(nil)
    NotificationCenter.default.post(
      name: .processViewerWindowVisibilityChanged,
      object: false)
  }

  private func hideCodexNetworkProbeWindow() {
    guard let codexNetworkProbeWindow else { return }
    codexNetworkProbeWindow.orderOut(nil)
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated { codexNetworkProbeController.cancelAll() }
  }

  private func hideClipboardHistoryWindow() {
    clipboardHistoryReturnApplication = nil
    guard let clipboardHistoryWindow else { return }
    NotificationCenter.default.post(
      name: .clipboardHistoryWindowWillHide,
      object: nil)
    clipboardHistoryWindow.orderOut(nil)
  }

  private func hideLauncher() {
    guard let launcherWindow else { return }
    shortcutWindowToggleState.invalidate()
    settlePendingShortcutWindowRestorations()
    let hideGeneration = shortcutWindowToggleState.generation
    model.restoreInputMethodAfterLauncher()
    suppressMainWindowForLauncherUntil = ProcessInfo.processInfo.systemUptime + 1.4
    launcherWindow.orderOut(nil)
    launcherWindow.alphaValue = 1
    window?.orderOut(nil)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.shortcutWindowToggleState.generation == hideGeneration else { return }
      self.window?.orderOut(nil)
    }
  }

  private func syncClassicTabSwitcherHUD(_ state: ClassicTabSwitcherHUDState) {
    guard state.isVisible else {
      classicTabSwitcherWindow?.orderOut(nil)
      return
    }
    if classicTabSwitcherWindow == nil {
      buildClassicTabSwitcherWindow()
    }
    positionClassicTabSwitcherWindow()
    classicTabSwitcherWindow?.alphaValue = 1
    classicTabSwitcherWindow?.orderFrontRegardless()
  }

  private func positionClassicTabSwitcherWindow() {
    guard let classicTabSwitcherWindow else { return }
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = NSRect(
      x: visible.midX - classicTabSwitcherWindowSize.width / 2,
      y: visible.midY - classicTabSwitcherWindowSize.height / 2 + 40,
      width: classicTabSwitcherWindowSize.width,
      height: classicTabSwitcherWindowSize.height
    )
    classicTabSwitcherWindow.setFrame(frame, display: true)
  }

  private func positionLauncherWindowIfNeeded() {
    guard let launcherWindow else { return }
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    if didPositionLauncherWindow, visible.intersects(launcherWindow.frame) {
      return
    }
    didPositionLauncherWindow = true
    positionLauncherWindow(in: visible)
  }

  private func positionLauncherWindow(in visible: NSRect) {
    guard let launcherWindow else { return }
    let frame = NSRect(
      x: visible.midX - launcherWindowSize.width / 2,
      y: visible.maxY - launcherWindowSize.height - 92,
      width: launcherWindowSize.width,
      height: launcherWindowSize.height
    )
    launcherWindow.setFrame(frame, display: true)
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard let launcherWindow, sender === launcherWindow else { return frameSize }
    let proposedContent = sender.contentRect(
      forFrameRect: NSRect(origin: .zero, size: frameSize)
    ).size
    let width = min(max(proposedContent.width, 480), launcherWindowMaximumSize.width)
    let minimumHeight: CGFloat = width < 600 ? 560 : 520
    let height = min(max(proposedContent.height, minimumHeight), launcherWindowMaximumSize.height)
    return sender.frameRect(
      forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height))
    ).size
  }

  private func showPhraseWindow() {
    model.showPhraseWindow()
  }

  private func showWindowWithStartupRetries() {
    let ticket = shortcutWindowToggleState.present(target: .main)
    settlePendingShortcutWindowRestorations()
    showPrimaryWindowOnStartup(ticket: ticket)
    shortcutWindowToggleState.finish(ticket)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
      guard let self, self.shortcutWindowToggleState.accepts(ticket) else { return }
      self.showPrimaryWindowOnStartup(ticket: ticket)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self] in
      guard let self, self.shortcutWindowToggleState.accepts(ticket) else { return }
      self.showPrimaryWindowOnStartup(ticket: ticket)
    }
  }

  private func showAuthorizationRelaunchResultWithRetries() {
    let ticket = shortcutWindowToggleState.present(target: .main)
    settlePendingShortcutWindowRestorations()
    for (attempt, delay) in [0.0, 0.6, 1.8].enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.shortcutWindowToggleState.accepts(ticket) else { return }
        self.showWindow(ticket: ticket)
        if attempt == 0 {
          self.shortcutWindowToggleState.finish(ticket)
        }
        AppDiagnostics.log(
          "authorization_relaunch_window_presented",
          [
            "attempt": "\(attempt + 1)",
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "appActive": "\(NSApp.isActive)",
            "windowVisible": "\(self.window?.isVisible == true)",
            "windowKey": "\(self.window?.isKeyWindow == true)",
          ])
      }
    }
  }

  private func showPrimaryWindowOnStartup(ticket: ShortcutWindowToggleTicket) {
    model.selectPlugin(id: nil)
    model.selectedModuleName = "插件中心"
    showWindow(ticket: ticket)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shortcutWindowToggleState.invalidate()
    removePendingShortcutWindowRestoration(for: sender)
    if sender === launcherWindow {
      hideLauncher()
      return false
    }
    if sender === processViewerWindow {
      NotificationCenter.default.post(
        name: .processViewerWindowVisibilityChanged,
        object: false)
    }
    if sender === codexNetworkProbeWindow {
      codexNetworkProbeController.cancelAll()
    }
    if sender === clipboardHistoryWindow {
      hideClipboardHistoryWindow()
      return false
    }
    if sender === aiPlayerWindow {
      model.stopAIPlayerIfLoaded()
    }
    sender.orderOut(nil)
    return false
  }

  func windowDidMiniaturize(_ notification: Notification) {
    shortcutWindowToggleState.invalidate()
    let minimizedWindow = notification.object as? NSWindow
    if let minimizedWindow {
      removePendingShortcutWindowRestoration(for: minimizedWindow)
    }
    if minimizedWindow === launcherWindow {
      model.restoreInputMethodAfterLauncher()
    } else if minimizedWindow === processViewerWindow {
      NotificationCenter.default.post(
        name: .processViewerWindowVisibilityChanged,
        object: false)
    } else if minimizedWindow === clipboardHistoryWindow {
      NotificationCenter.default.post(
        name: .clipboardHistoryWindowWillHide,
        object: nil)
    } else if minimizedWindow === codexNetworkProbeWindow {
      codexNetworkProbeController.cancelAll()
    }
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    guard let restoredWindow = notification.object as? NSWindow else { return }
    for target in Array(pendingRestorationTickets.keys)
    where shortcutWindow(for: target) === restoredWindow {
      settlePendingShortcutWindowRestoration(for: target)
    }
    if restoredWindow === processViewerWindow {
      NotificationCenter.default.post(
        name: .processViewerWindowVisibilityChanged,
        object: shortcutWindowSnapshot(for: .processViewer).isPresented)
    }
  }

  @discardableResult
  private func closeFrontmostWindowForCommandW() -> Bool {
    if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
      if keyWindow == launcherWindow {
        hideLauncher()
      } else {
        keyWindow.performClose(nil)
      }
      return true
    }
    if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
      mainWindow.performClose(nil)
      return true
    }
    if launcherWindow?.isVisible == true {
      hideLauncher()
      return true
    }
    if window?.isVisible == true {
      window?.performClose(nil)
      return true
    }
    return false
  }

  private func normalizeWindowFrameIfNeeded() {
    guard let window else { return }
    let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let screenFrame =
      NSScreen.screens.first { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 560 }?
      .visibleFrame ?? NSScreen.main?.visibleFrame ?? fallback
    let visible =
      screenFrame.width >= 900 && screenFrame.height >= 560 ? screenFrame : fallback
    let width = min(defaultWindowSize.width, max(window.minSize.width, visible.width * 0.82))
    let height = min(defaultWindowSize.height, max(window.minSize.height, visible.height * 0.82))
    let wanted = NSRect(
      x: visible.midX - width / 2,
      y: visible.midY - height / 2,
      width: width,
      height: height
    )
    let current = window.frame
    let tooWide = current.width > wanted.width * 1.12
    let tooTall = current.height > wanted.height * 1.16
    let tooSmall = current.width < window.minSize.width || current.height < window.minSize.height
    let offscreen = !visible.intersects(current)
    if current == .zero || tooWide || tooTall || tooSmall || offscreen {
      window.setFrame(wanted, display: true)
    }
  }

  @objc private func showWindowAction() {
    presentMainWindow()
  }

  @objc private func showPrimaryPanelAction() {
    model.selectedModuleName = "功能快捷键"
    presentMainWindow()
  }

  @objc private func showShortcutGuideAction() {
    model.showShortcutGuidePanel()
  }

  @objc private func showLauncherAction() {
    model.showLauncher()
  }

  @objc private func showPhraseWindowAction() {
    showPhraseWindow()
  }

  @objc private func showCodexNetworkProbeStatusAction() {
    presentShortcutWindow(.networkProbe)
  }

  @objc private func showProcessViewerStatusAction() {
    presentShortcutWindow(.processViewer)
  }

  @objc private func showPluginCenterAction() {
    model.selectedModuleName = "插件中心"
    presentMainWindow()
  }

  @objc private func showInputMethodManagementAction() {
    model.selectPlugin(id: AppModel.inputMethodPluginID)
    model.selectedModuleName = "插件中心"
    presentMainWindow()
    model.statusMessage = "已打开输入法管理。"
  }

  @objc private func showSleepManagementAction() {
    AppDiagnostics.log(
      "sleep_status_item_open_sleep_management",
      [
        "active": "\(model.keepAwakeEnabled)",
        "status": model.keepAwakeStatusText,
      ])
    model.showSleepPanel()
  }

  @objc private func sleepStatusItemClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showSleepManagementAction()
    } else {
      toggleSleepStatusItemAction()
    }
  }

  @objc private func toggleSleepStatusItemAction() {
    toggleSleepStatus(source: "native")
  }

  private func toggleSleepStatus(source: String) {
    let wasActive = model.keepAwakeEnabled
    switch sleepStatusToggleAction(isAwake: wasActive) {
    case .stop:
      model.stopKeepAwake()
    case .startInfinite:
      model.startKeepAwake(minutes: 0)
    }
    AppDiagnostics.log(
      "sleep_status_item_toggled",
      [
        "source": source,
        "from": wasActive ? "awake" : "sleep",
        "to": model.keepAwakeEnabled ? "awake" : "sleep",
      ])
  }

  @objc private func showSettingsAction() {
    model.showSettings()
    presentMainWindow()
  }

  @objc private func createShortcutAction() {
    presentMainWindow()
    model.requestCreateShortcut()
  }

  @objc private func showCommunityQRCodeAction() {
    model.presentCommunityQRCode()
  }

  @objc private func checkForUpdatesAction() {
    model.showSettings(section: "更新与创始会员")
    presentMainWindow()
    model.checkForUpdates()
  }

  @objc private func closeWindowAction() {
    closeFrontmostWindowForCommandW()
  }

  @objc private func togglePaused() {
    model.togglePaused()
    refreshStatusMenu()
  }

  @objc private func reloadHotkeys() {
    model.reloadHotkeys()
    refreshStatusMenu()
  }

  @objc private func openAccessibility() {
    presentMainWindow()
    model.presentAuthorizationCenter()
  }

  @objc private func openConfig() {
    model.openConfigFile()
  }

  @objc private func toggleLoginItem() {
    model.setLaunchAtLoginEnabled(!model.launchAtLoginEnabled)
    refreshStatusMenu()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

}
