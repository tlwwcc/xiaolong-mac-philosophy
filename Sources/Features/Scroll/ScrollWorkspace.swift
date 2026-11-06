import AppKit
import Combine
import Foundation

struct ScrollWorkspacePermissions: Equatable {
  let accessibility: Bool
  let inputMonitoring: Bool
}

@MainActor protocol ScrollWorkspaceEngine: AnyObject {
  var isRunning: Bool { get }
  func update(settings: ScrollEngineSettings) -> Bool
  func stop()
}
extension ScrollEngine: ScrollWorkspaceEngine {}

@MainActor protocol ScrollWorkspaceCancellation: AnyObject { func cancel() }

@MainActor struct ScrollWorkspaceEnvironment {
  var makeEngine: (@escaping @MainActor (String) -> Void) -> any ScrollWorkspaceEngine
  var loadLegacyProfile: () -> LegacyScrollProfile
  var isLegacyRunning: () -> Bool
  var revealLegacyConfig: () -> Bool
  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any ScrollWorkspaceCancellation
  var log: (String, [String: String]) -> Void

  static func live() -> Self {
    Self(
      makeEngine: { notice in
        ScrollEngine { message in Task { @MainActor in notice(message) } }
      },
      loadLegacyProfile: { LegacyScrollProfile.load() },
      isLegacyRunning: {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == LegacyScrollProfile.legacyBundleID }
      },
      revealLegacyConfig: {
        guard FileManager.default.fileExists(atPath: LegacyScrollProfile.legacyPlistURL.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([LegacyScrollProfile.legacyPlistURL])
        return true
      },
      schedule: { delay, callback in
        let work = DispatchWorkItem { MainActor.assumeIsolated { callback() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return ScrollWorkspaceWorkItem(work)
      },
      log: { AppDiagnostics.log($0, $1) })
  }
}

@MainActor private final class ScrollWorkspaceWorkItem: ScrollWorkspaceCancellation {
  private var work: DispatchWorkItem?
  init(_ work: DispatchWorkItem) { self.work = work }
  func cancel() { let previous = work; work = nil; previous?.cancel() }
}

/// Settings and runtime ownership for the existing mouse wheel and volume engine.
/// Global input arbitration and permission acquisition remain with the host.
@MainActor final class ScrollWorkspace: @MainActor ObservableObject {
  let objectWillChange = ObservableObjectPublisher()
  private(set) var legacyProfile = LegacyScrollProfile.empty
  private(set) var settings = ScrollEngineSettings.defaults
  private(set) var isRunning = false
  private(set) var isLongScreenshotCaptureActive = false
  var onStatus: ((String) -> Void)?

  private let defaults: UserDefaults
  private let hasGlobalInputOwnership: () -> Bool
  private let ownershipBlockedMessage: () -> String
  private let permissions: () -> ScrollWorkspacePermissions
  private let requestLegacyQuit: () -> Void
  private let environment: ScrollWorkspaceEnvironment
  private var engine: (any ScrollWorkspaceEngine)?
  private var engineSettings: ScrollEngineSettings?
  private var engineOwner = UUID()
  private var reloadOwner = UUID()
  private var commandOwner = UUID()
  private var legacyRefreshOwner = UUID()
  private var legacyRefresh: (any ScrollWorkspaceCancellation)?
  private var started = false
  private var isShutdown = false

  private static let mouseVolumePluginUserSetDefaultsKey = "mouseVolumePluginUserSetV1"
  private static let scrollEngineUserSetEnabledDefaultsKey = "scrollEngineUserSetEnabledV1"

  init(
    defaults: UserDefaults = .standard,
    hasGlobalInputOwnership: @escaping () -> Bool,
    ownershipBlockedMessage: @escaping () -> String,
    permissions: @escaping () -> ScrollWorkspacePermissions,
    requestLegacyQuit: @escaping () -> Void,
    environment: ScrollWorkspaceEnvironment? = nil
  ) {
    self.defaults = defaults
    self.hasGlobalInputOwnership = hasGlobalInputOwnership
    self.ownershipBlockedMessage = ownershipBlockedMessage
    self.permissions = permissions
    self.requestLegacyQuit = requestLegacyQuit
    self.environment = environment ?? .live()
  }

  isolated deinit { shutdown() }

  var mouseVolumePluginEnabled: Bool { settings.volumeHotCornerEnabled }
  var listenerIsRunning: Bool { !isShutdown && engine?.isRunning == true }
  var mouseScrollPreset: MouseScrollPreset {
    if settings.step >= 40 || settings.speed >= 3.2 { return .fast }
    return settings.smooth ? .natural : .stable
  }
  var statusText: String {
    if settings.enabled { return isRunning ? "滚动运行中" : "滚动未运行" }
    if settings.volumeHotCornerEnabled { return "状态栏音量已启用" }
    return "未运行"
  }

  func loadSettings() {
    guard let owner = beginCommand() else { return }
    let profile = environment.loadLegacyProfile()
    guard ownsCommand(owner) else { return }
    legacyProfile = profile
    let loaded = loadScrollSettings()
    guard ownsCommand(owner) else { return }
    settings = loaded
    saveScrollSettings()
    objectWillChange.send()
  }

  func start() {
    guard !isShutdown, !started else { return }
    started = true
    let owner = commandOwner
    if settings.enabled { quitLegacyScrollAppIfRunning() }
    guard ownsCommand(owner) else { return }
    reload()
  }

  func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true
    started = false
    commandOwner = UUID()
    reloadOwner = UUID()
    legacyRefreshOwner = UUID()
    let previousRefresh = legacyRefresh
    legacyRefresh = nil
    detachEngine()
    previousRefresh?.cancel()
    onStatus = nil
  }

  func refreshLegacyScrollProfile() {
    guard !isShutdown else { return }
    let owner = commandOwner
    let profile = environment.loadLegacyProfile()
    guard ownsCommand(owner) else { return }
    legacyProfile = profile
    objectWillChange.send()
  }

  func revealLegacyScrollConfig() {
    guard let owner = beginCommand() else { return }
    if !environment.revealLegacyConfig() { emit("没有找到旧滚动配置文件。", owner: owner) }
  }

  func importLegacyScrollProfile() {
    guard let owner = beginCommand() else { return }
    let profile = environment.loadLegacyProfile()
    guard ownsCommand(owner) else { return }
    legacyProfile = profile
    var next = ScrollEngineSettings.fromLegacyProfile(profile)
    next.enabled = settings.enabled
    next.enforceMouseWheelOnlyWindowsHabit()
    commit(next, owner: owner, quitLegacy: false,
      message: profile.profileFound ? "已导入旧滚动参数。" : "没有旧滚动参数，已使用默认滚动手感。")
  }

  func applyRecommendedScrollSettings(reverse: Bool? = nil) {
    guard let owner = beginCommand() else { return }
    var next = ScrollEngineSettings.mosPreset
    next.enabled = true
    next.volumeHotCornerEnabled = settings.volumeHotCornerEnabled
    next.volumeStep = settings.volumeStep
    next.enforceMouseWheelOnlyWindowsHabit()
    defaults.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    commit(next, owner: owner, quitLegacy: true,
      message: "已恢复 Mos-like 丝滑滚动手感：只接管鼠标滚轮，触控板保持系统原样。")
  }

  func applyMosScrollPreset() {
    guard let owner = beginCommand() else { return }
    var next = ScrollEngineSettings.mosPreset
    next.volumeHotCornerEnabled = settings.volumeHotCornerEnabled
    next.volumeStep = settings.volumeStep
    next.enforceMouseWheelOnlyWindowsHabit()
    defaults.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    commit(next, owner: owner, quitLegacy: true,
      message: "已恢复 Mos-like 丝滑滚动手感：方向校准和平滑滚动已开启。")
  }

  func applyMouseScrollPreset(_ preset: MouseScrollPreset) {
    guard let owner = beginCommand() else { return }
    var next = settings
    next.enforceMouseWheelOnlyWindowsHabit()
    switch preset {
    case .natural: next.smooth = true; next.step = 28; next.speed = 2.1; next.duration = 4
    case .stable: next.smooth = false; next.step = 33.6; next.speed = 2.7; next.duration = 4.35
    case .fast: next.smooth = true; next.step = 42; next.speed = 3.4; next.duration = 3
    }
    commit(next, owner: owner, quitLegacy: next.enabled,
      message: "鼠标滚动已切换为「\(preset.title)」预设。")
  }

  func updateScrollSettings(_ mutate: (inout ScrollEngineSettings) -> Void) {
    guard let owner = beginCommand() else { return }
    var next = settings
    mutate(&next)
    guard ownsCommand(owner) else { return }
    next.enforceMouseWheelOnlyWindowsHabit()
    commit(next, owner: owner, quitLegacy: next.enabled)
  }

  func setScrollEngineEnabled(_ enabled: Bool) {
    guard let owner = beginCommand() else { return }
    var next = settings
    next.enabled = enabled
    next.enforceMouseWheelOnlyWindowsHabit()
    defaults.set(true, forKey: Self.scrollEngineUserSetEnabledDefaultsKey)
    commit(next, owner: owner, quitLegacy: enabled, message: enabled
      ? "鼠标滚动插件已启用：只接管鼠标滚轮，触控板保持系统原样。" : "鼠标滚动插件已关闭。")
  }

  func setMouseVolumePluginEnabled(_ enabled: Bool) {
    guard let owner = beginCommand() else { return }
    var next = settings
    next.volumeHotCornerEnabled = enabled
    defaults.set(true, forKey: Self.mouseVolumePluginUserSetDefaultsKey)
    commit(next, owner: owner, quitLegacy: false, message: enabled
      ? "鼠标音量插件已启用：鼠标移到屏幕右上角热区，滚轮可调音量。" : "鼠标音量插件已关闭。")
  }

  func updateMouseVolumePluginSettings(_ mutate: (inout ScrollEngineSettings) -> Void) {
    guard let owner = beginCommand() else { return }
    var next = settings
    mutate(&next)
    guard ownsCommand(owner) else { return }
    defaults.set(true, forKey: Self.mouseVolumePluginUserSetDefaultsKey)
    commit(next, owner: owner, quitLegacy: false)
  }

  func setLongScreenshotCaptureActive(_ isActive: Bool) {
    guard !isShutdown, isLongScreenshotCaptureActive != isActive else { return }
    isLongScreenshotCaptureActive = isActive
    objectWillChange.send()
    guard !isShutdown, isLongScreenshotCaptureActive == isActive else { return }
    reload(reportStatus: false)
    guard !isShutdown, isLongScreenshotCaptureActive == isActive else { return }
    var fields = ["reason": "youmuLongScreenshot", "running": "\(isRunning)"]
    if isActive { fields["mode"] = "eventTapStopped" }
    environment.log(isActive ? "scroll_engine_suspended" : "scroll_engine_resumed", fields)
  }

  func reload(reportStatus: Bool = true) {
    guard started, !isShutdown else { return }
    let reload = UUID()
    reloadOwner = reload
    if isLongScreenshotCaptureActive {
      detachEngine()
      return
    }
    guard hasGlobalInputOwnership() else {
      detachEngine()
      if ownsReload(reload) { onStatus?(ownershipBlockedMessage()) }
      return
    }
    guard settings.needsEventTap else { detachEngine(); return }
    let snapshot = permissions()
    guard snapshot.accessibility, snapshot.inputMonitoring else {
      detachEngine()
      if ownsReload(reload) {
        onStatus?(snapshot.accessibility
          ? "鼠标音量需要完成系统授权，请在 App 中点“立即授权”。"
          : "鼠标滚动或鼠标音量需要完成系统授权，请在 App 中点“立即授权”。")
      }
      return
    }
    if let engine, engineSettings == settings, engine.isRunning {
      isRunning = true
      objectWillChange.send()
      if ownsReload(reload), reportStatus, settings.enabled { onStatus?("内置滚动引擎已启用。") }
      return
    }
    detachEngine()
    guard ownsReload(reload) else { return }
    let owner = UUID()
    engineOwner = owner
    let created = environment.makeEngine { [weak self] message in
      guard let self, !self.isShutdown, self.engineOwner == owner,
        !self.isLongScreenshotCaptureActive, self.hasGlobalInputOwnership() else { return }
      self.onStatus?(message)
    }
    guard ownsReload(reload), engineOwner == owner else { created.stop(); return }
    engine = created
    let snapshotSettings = settings
    engineSettings = snapshotSettings
    let didStart = created.update(settings: snapshotSettings)
    guard ownsReload(reload), engineOwner == owner else { created.stop(); return }
    isRunning = didStart && created.isRunning
    objectWillChange.send()
    if ownsReload(reload), reportStatus, isRunning, settings.enabled { onStatus?("内置滚动引擎已启用。") }
  }

  private func detachEngine() {
    engineOwner = UUID()
    let previous = engine
    engine = nil
    engineSettings = nil
    let wasRunning = isRunning
    isRunning = false
    previous?.stop()
    if wasRunning { objectWillChange.send() }
  }

  private func ownsReload(_ owner: UUID) -> Bool { !isShutdown && started && reloadOwner == owner }
  private func beginCommand() -> UUID? {
    guard !isShutdown else { return nil }
    commandOwner = UUID()
    return commandOwner
  }
  private func ownsCommand(_ owner: UUID) -> Bool { !isShutdown && commandOwner == owner }
  private func emit(_ message: String, owner: UUID) {
    guard ownsCommand(owner) else { return }
    onStatus?(message)
  }
  private func commit(_ next: ScrollEngineSettings, owner: UUID, quitLegacy: Bool, message: String? = nil) {
    guard ownsCommand(owner) else { return }
    settings = next
    saveScrollSettings()
    objectWillChange.send()
    guard ownsCommand(owner) else { return }
    if quitLegacy { quitLegacyScrollAppIfRunning() }
    guard ownsCommand(owner) else { return }
    reload()
    if let message { emit(message, owner: owner) }
  }

  private func quitLegacyScrollAppIfRunning() {
    guard !isShutdown, environment.isLegacyRunning() else { return }
    let owner = UUID()
    legacyRefreshOwner = owner
    let previous = legacyRefresh
    legacyRefresh = nil
    previous?.cancel()
    guard !isShutdown, legacyRefreshOwner == owner else { return }
    requestLegacyQuit()
    guard !isShutdown, legacyRefreshOwner == owner else { return }
    let scheduled = environment.schedule(1) { [weak self] in
      guard let self, !self.isShutdown, self.legacyRefreshOwner == owner else { return }
      self.legacyRefresh = nil
      self.refreshLegacyScrollProfile()
    }
    guard !isShutdown, legacyRefreshOwner == owner else { scheduled.cancel(); return }
    legacyRefresh = scheduled
  }

  private func saveScrollSettings() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: "scrollEngineSettings")
  }

  private func loadScrollSettings() -> ScrollEngineSettings {
    guard let data = defaults.data(forKey: "scrollEngineSettings"),
      var settings = try? JSONDecoder().decode(ScrollEngineSettings.self, from: data)
    else {
      return ScrollEngineSettings.fromLegacyProfile(environment.loadLegacyProfile())
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
