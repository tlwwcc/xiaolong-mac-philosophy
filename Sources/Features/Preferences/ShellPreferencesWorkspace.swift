import Combine
import Foundation

/// Owns shell preferences as one coherent published snapshot; operating-system effects are ports.
@MainActor
final class ShellPreferencesWorkspace: ObservableObject {
  struct State: Equatable {
    var sleepStatusItemVisible = true
    var dockIconVisible = true
    var menuBarVisibleItemIDs = MenuBarCatalog.defaultVisibleItemIDs
    var networkSpeedPluginEnabled = true
    var networkSpeedShowMemory = true
    var networkSpeedShowCPU = false
    var networkSpeedShowGPU = false
    var codexNetworkProbeDefaultDirection: NetworkProbeDirection = .codex
  }

  enum Change: Equatable { case sleepStatus, menuBar, networkSpeed }

  struct Dependencies {
    var applyDockVisibility: () -> Bool
    var notify: (Change) -> Void
  }

  @Published private(set) var state = State()
  private(set) var lastStatusMessage = ""
  private let defaults: UserDefaults
  private let dependencies: Dependencies
  private var stopped = false
  private var isChanging = false
  var onStatus: ((String) -> Void)?
  var allowsOrdinaryWrites: (() -> Bool)?

  init(defaults: UserDefaults = .standard, dependencies: Dependencies) {
    self.defaults = defaults
    self.dependencies = dependencies
  }

  var sleepStatusItemVisible: Bool { state.sleepStatusItemVisible }
  var dockIconVisible: Bool { state.dockIconVisible }
  var menuBarVisibleItemIDs: Set<MenuBarCatalogItemID> { state.menuBarVisibleItemIDs }
  var networkSpeedPluginEnabled: Bool { state.networkSpeedPluginEnabled }
  var networkSpeedShowMemory: Bool { state.networkSpeedShowMemory }
  var networkSpeedShowCPU: Bool { state.networkSpeedShowCPU }
  var networkSpeedShowGPU: Bool { state.networkSpeedShowGPU }
  var codexNetworkProbeDefaultDirection: NetworkProbeDirection {
    state.codexNetworkProbeDefaultDirection
  }

  private static let sleepKey = "sleepStatusItemVisibleV1"
  private static let networkKey = "networkSpeedPluginEnabledV1"
  private static let memoryKey = "networkSpeedShowMemoryV1"
  private static let cpuKey = "networkSpeedShowCPUV1"
  private static let gpuKey = "networkSpeedShowGPUV1"
  private static let metricsVersionKey = "networkSpeedDisplayOptionsVersionV1"
  private static let probeKey = "codexNetworkProbeDefaultDirectionV1"
  private static let probeMigrationKey = "codexNetworkProbeCodexDefaultMigratedV2"

  func shutdown() { stopped = true }

  /// Startup keeps the existing one-time migrations; it does not apply Dock policy twice.
  func loadSettings() {
    change {
      if defaults.object(forKey: Self.metricsVersionKey) == nil {
        defaults.set(true, forKey: Self.memoryKey)
        defaults.set(false, forKey: Self.cpuKey)
        defaults.set(false, forKey: Self.gpuKey)
        defaults.set(1, forKey: Self.metricsVersionKey)
      }
      loadSnapshot(restored: false)
    }
  }

  /// The importer has finished writing while its host transition gate still rejects GUI changes.
  func reloadAfterConfigurationRestore() {
    change(ordinary: false) {
      loadSnapshot(restored: true)
    }
  }

  private func loadSnapshot(restored: Bool) {
    var next = State()
    next.sleepStatusItemVisible = boolDefaultingTrue(Self.sleepKey)
    next.menuBarVisibleItemIDs = MenuBarCatalog.loadVisibleItemIDs(from: defaults)
    next.networkSpeedShowMemory = boolDefaultingTrue(Self.memoryKey)
    next.networkSpeedShowCPU = defaults.bool(forKey: Self.cpuKey)
    next.networkSpeedShowGPU = defaults.bool(forKey: Self.gpuKey)
    let storedDirection = NetworkProbeDirection(rawValue: defaults.string(forKey: Self.probeKey) ?? "")
    next.codexNetworkProbeDefaultDirection =
      restored || defaults.bool(forKey: Self.probeMigrationKey)
      ? NetworkProbeDirection.customerFacing(storedDirection) : .codex
    if restored {
      _ = dependencies.applyDockVisibility()
      guard !stopped else { return }
      DockPresencePreference.save(true, in: defaults)
    }
    guard !stopped else { return }
    defaults.set(true, forKey: Self.networkKey)
    defaults.set(true, forKey: Self.probeMigrationKey)
    defaults.set(next.codexNetworkProbeDefaultDirection.rawValue, forKey: Self.probeKey)
    publish(next, notifying: restored ? [.sleepStatus, .menuBar, .networkSpeed] : [])
  }

  func setSleepStatusItemVisible(_ visible: Bool) {
    change {
      var next = state
      next.sleepStatusItemVisible = visible
      defaults.set(visible, forKey: Self.sleepKey)
      publish(next, notifying: [.sleepStatus],
              status: visible ? "睡眠状态栏图标已显示。" : "睡眠状态栏图标已隐藏。")
    }
  }

  func setDockIconVisible(_ visible: Bool) {
    _ = visible
    change {
      let applied = dependencies.applyDockVisibility()
      guard !stopped else { return }
      guard applied else {
        report("暂时无法在程序坞显示图标。")
        return
      }
      var next = state
      next.dockIconVisible = true
      DockPresencePreference.save(true, in: defaults)
      publish(next, status: "应用会一直显示在程序坞中。")
    }
  }

  func isMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID) -> Bool {
    state.menuBarVisibleItemIDs.contains(itemID)
  }

  func setMenuBarCatalogItemVisible(_ itemID: MenuBarCatalogItemID, _ visible: Bool) {
    change {
      var next = state
      if visible { next.menuBarVisibleItemIDs.insert(itemID) }
      else { next.menuBarVisibleItemIDs.remove(itemID) }
      guard next != state else { return }
      MenuBarCatalog.saveVisibleItemIDs(next.menuBarVisibleItemIDs, to: defaults)
      let title = MenuBarCatalog.items.first(where: { $0.id == itemID })?.title ?? itemID.rawValue
      publish(next, notifying: [.menuBar],
              status: visible ? "已在快捷菜单显示「\(title)」。" : "已从快捷菜单隐藏「\(title)」。")
    }
  }

  func resetMenuBarCatalogVisibility() {
    change {
      var next = state
      next.menuBarVisibleItemIDs = MenuBarCatalog.defaultVisibleItemIDs
      next.sleepStatusItemVisible = true
      next.dockIconVisible = true
      next.networkSpeedShowMemory = true
      next.networkSpeedShowCPU = false
      next.networkSpeedShowGPU = false
      guard next != state else { return }
      _ = dependencies.applyDockVisibility()
      guard !stopped else { return }
      MenuBarCatalog.saveVisibleItemIDs(next.menuBarVisibleItemIDs, to: defaults)
      defaults.set(true, forKey: Self.sleepKey)
      DockPresencePreference.save(true, in: defaults)
      defaults.set(true, forKey: Self.memoryKey)
      defaults.set(false, forKey: Self.cpuKey)
      defaults.set(false, forKey: Self.gpuKey)
      publish(next, notifying: [.menuBar, .networkSpeed, .sleepStatus],
              status: "菜单栏图标、状态内容和快捷入口已恢复默认。")
    }
  }

  func setNetworkSpeedPluginEnabled(_ enabled: Bool) {
    _ = enabled
    change {
      var next = state
      next.networkSpeedPluginEnabled = true
      defaults.set(true, forKey: Self.networkKey)
      publish(next, notifying: [.networkSpeed],
              status: "网速显示是 Mac 哲学的菜单栏主入口，默认保持显示。")
    }
  }

  func setNetworkSpeedShowMemory(_ enabled: Bool) {
    setMetric(\.networkSpeedShowMemory, key: Self.memoryKey, enabled: enabled)
  }

  func setNetworkSpeedShowCPU(_ enabled: Bool) {
    setMetric(\.networkSpeedShowCPU, key: Self.cpuKey, enabled: enabled)
  }

  func setNetworkSpeedShowGPU(_ enabled: Bool) {
    setMetric(\.networkSpeedShowGPU, key: Self.gpuKey, enabled: enabled)
  }

  private func setMetric(_ field: WritableKeyPath<State, Bool>, key: String, enabled: Bool) {
    change {
      var next = state
      next[keyPath: field] = enabled
      defaults.set(enabled, forKey: key)
      publish(next, notifying: [.networkSpeed], status: "网速显示选项已更新。")
    }
  }

  func setCodexNetworkProbeDefaultDirection(_ direction: NetworkProbeDirection) {
    change {
      var next = state
      let direction = NetworkProbeDirection.customerFacing(direction)
      next.codexNetworkProbeDefaultDirection = direction
      defaults.set(direction.rawValue, forKey: Self.probeKey)
      publish(next, status: "测试网速默认方向已改为\(direction.title)。")
    }
  }

  private func boolDefaultingTrue(_ key: String) -> Bool {
    defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
  }

  /// The guard remains held during synchronous Combine, notification and status callbacks.
  private func change(ordinary: Bool = true, _ operation: () -> Void) {
    guard !stopped, !isChanging else { return }
    isChanging = true
    defer { isChanging = false }
    if ordinary {
      let allowed = allowsOrdinaryWrites?() ?? true
      guard !stopped else { return }
      guard allowed else {
        report("正在恢复配置，请完成后再修改设置。")
        return
      }
    }
    operation()
  }

  private func publish(_ next: State, notifying changes: [Change] = [], status: String? = nil) {
    guard !stopped else { return }
    if state != next { state = next }
    for notification in changes {
      guard !stopped else { return }
      dependencies.notify(notification)
    }
    if let status { report(status) }
  }

  private func report(_ message: String) {
    guard !stopped else { return }
    lastStatusMessage = message
    onStatus?(message)
  }
}
