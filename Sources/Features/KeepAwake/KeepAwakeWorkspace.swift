import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
protocol KeepAwakePowerPort: AnyObject {
  func beginActivity(preventDisplaySleep: Bool) -> NSObjectProtocol
  func endActivity(_ activity: NSObjectProtocol)
  func declareUserActivity(existingID: IOPMAssertionID?) -> IOPMAssertionID?
  func releaseUserActivity(_ id: IOPMAssertionID)
}

@MainActor
protocol KeepAwakeTimerToken: AnyObject {
  func cancel()
}

@MainActor
protocol KeepAwakeTimerScheduling: AnyObject {
  func schedule(
    every interval: TimeInterval, action: @escaping @MainActor () -> Void
  ) -> any KeepAwakeTimerToken
}

/// Owns only this feature's process activity, display assertion and scheduled callbacks.
/// The host forwards published state; tests inject ports without changing system power settings.
@MainActor
final class KeepAwakeWorkspace: ObservableObject {
  @Published private(set) var enabled = false
  @Published private(set) var preventDisplaySleep = false
  @Published private(set) var statusText = "未开启"
  @Published private(set) var customHours = 3

  var onStatus: ((String) -> Void)?
  var onStateChanged: (() -> Void)?

  private let defaults: UserDefaults
  private let now: @MainActor () -> Date
  private let power: any KeepAwakePowerPort
  private let scheduler: any KeepAwakeTimerScheduling
  private var activity: NSObjectProtocol?
  private var countdownTimer: (any KeepAwakeTimerToken)?
  private var userActivityTimer: (any KeepAwakeTimerToken)?
  private var userActivityID: IOPMAssertionID?
  private var endDate: Date?
  private var generation: UInt64 = 0
  private var isShutdown = false

  private static let preventDisplaySleepKey = "keepAwakePreventDisplaySleep"
  private static let customHoursKey = "keepAwakeCustomHours"

  init(
    defaults: UserDefaults = .standard,
    now: @escaping @MainActor () -> Date = { Date() },
    power: (any KeepAwakePowerPort)? = nil,
    scheduler: (any KeepAwakeTimerScheduling)? = nil
  ) {
    self.defaults = defaults
    self.now = now
    self.power = power ?? SystemKeepAwakePower()
    self.scheduler = scheduler ?? MainRunLoopKeepAwakeScheduler()
  }

  func loadSettings() {
    guard !isShutdown else { return }
    let previous = preventDisplaySleep
    if defaults.object(forKey: Self.preventDisplaySleepKey) != nil {
      preventDisplaySleep = defaults.bool(forKey: Self.preventDisplaySleepKey)
    }
    let savedHours = defaults.integer(forKey: Self.customHoursKey)
    customHours = savedHours == 0 ? 3 : min(max(savedHours, 1), 12)
    if enabled, previous != preventDisplaySleep {
      rebuildActivity()
      startTimers()
      refreshStatus()
      onStateChanged?()
    }
  }

  func start(minutes: Int) {
    guard !isShutdown else { return }
    // Convert before multiplication so a caller cannot overflow Int with a duration.
    endDate = minutes > 0 ? now().addingTimeInterval(TimeInterval(minutes) * 60) : nil
    enabled = true
    rebuildActivity()
    startTimers()
    refreshStatus()
    onStateChanged?()
    onStatus?(endDate == nil ? "保持唤醒已开启：无限期。" : "保持唤醒已开启：\(statusText)。")
  }

  func startCustomHours() {
    start(minutes: customHours * 60)
  }

  func toggleInfinite() {
    guard !isShutdown else { return }
    if enabled && endDate == nil { stop() }
    else { start(minutes: 0) }
  }

  func stop(resetStatus: Bool = true) {
    invalidateTimers()
    releaseUserActivity()
    endDate = nil
    if let activity {
      power.endActivity(activity)
      self.activity = nil
    }
    enabled = false
    statusText = "未开启"
    onStateChanged?()
    if resetStatus { onStatus?("保持唤醒已关闭。") }
  }

  func setPreventDisplaySleep(_ value: Bool) {
    guard !isShutdown else { return }
    preventDisplaySleep = value
    defaults.set(value, forKey: Self.preventDisplaySleepKey)
    if enabled {
      rebuildActivity()
      startTimers()
      refreshStatus()
      onStateChanged?()
      onStatus?(value ? "保持唤醒时也会保持屏幕亮起。" : "保持唤醒时只阻止系统睡眠。")
    }
  }

  func setCustomHours(_ hours: Int) {
    guard !isShutdown else { return }
    customHours = min(max(hours, 1), 12)
    defaults.set(customHours, forKey: Self.customHoursKey)
  }

  /// Terminal lifecycle boundary. Unlike stop(), it cannot be restarted by a late owner.
  func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true
    stop(resetStatus: false)
    onStatus = nil
    onStateChanged = nil
  }

  private func rebuildActivity() {
    if let activity {
      power.endActivity(activity)
      self.activity = nil
    }
    activity = power.beginActivity(preventDisplaySleep: preventDisplaySleep)
  }

  private func invalidateTimers() {
    generation &+= 1
    countdownTimer?.cancel()
    countdownTimer = nil
    userActivityTimer?.cancel()
    userActivityTimer = nil
  }

  private func startTimers() {
    invalidateTimers()
    let owner = generation
    if endDate != nil {
      countdownTimer = scheduler.schedule(every: 1) { [weak self] in
        guard let self, self.isCurrent(owner) else { return }
        self.tick()
      }
    }
    guard enabled, preventDisplaySleep else {
      releaseUserActivity()
      return
    }
    declareUserActivity()
    userActivityTimer = scheduler.schedule(every: 30) { [weak self] in
      guard let self, self.isCurrent(owner) else { return }
      self.declareUserActivity()
    }
  }

  private func isCurrent(_ owner: UInt64) -> Bool {
    !isShutdown && enabled && generation == owner
  }

  private func declareUserActivity() {
    guard enabled, preventDisplaySleep, !isShutdown else { return }
    if let id = power.declareUserActivity(existingID: userActivityID) {
      userActivityID = id
    }
  }

  private func releaseUserActivity() {
    if let userActivityID {
      power.releaseUserActivity(userActivityID)
      self.userActivityID = nil
    }
  }

  private func tick() {
    if let endDate, now() >= endDate {
      stop()
      onStatus?("保持唤醒已到时，已恢复系统睡眠。")
      return
    }
    refreshStatus()
    onStateChanged?()
  }

  private func refreshStatus() {
    guard enabled else { statusText = "未开启"; return }
    guard let endDate else { statusText = "无限期"; return }
    let remainingSeconds = max(0, ceil(endDate.timeIntervalSince(now())))
    // Protect diagnostics from an arbitrary oversized programmatic duration.
    let remaining = remainingSeconds >= Double(Int.max) ? Int.max : Int(remainingSeconds)
    let hours = remaining / 3600
    let minutes = (remaining % 3600) / 60
    let seconds = remaining % 60
    if hours > 0 { statusText = "剩余 \(hours) 小时 \(minutes) 分" }
    else if minutes > 0 { statusText = "剩余 \(minutes) 分 \(seconds) 秒" }
    else { statusText = "剩余 \(seconds) 秒" }
  }
}

@MainActor
private final class SystemKeepAwakePower: KeepAwakePowerPort {
  func beginActivity(preventDisplaySleep: Bool) -> NSObjectProtocol {
    var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
    if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
    return ProcessInfo.processInfo.beginActivity(
      options: options,
      reason: preventDisplaySleep
        ? "小龙哥Mac哲学：保持唤醒并保持屏幕亮起。"
        : "小龙哥Mac哲学：正在保持唤醒。")
  }

  func endActivity(_ activity: NSObjectProtocol) {
    ProcessInfo.processInfo.endActivity(activity)
  }

  func declareUserActivity(existingID: IOPMAssertionID?) -> IOPMAssertionID? {
    var id = existingID ?? IOPMAssertionID(0)
    let result = IOPMAssertionDeclareUserActivity(
      "小龙哥Mac哲学：不锁屏 / 不进屏保。" as CFString, kIOPMUserActiveLocal, &id)
    return result == kIOReturnSuccess ? id : nil
  }

  func releaseUserActivity(_ id: IOPMAssertionID) {
    IOPMAssertionRelease(id)
  }
}

@MainActor
private final class MainRunLoopKeepAwakeScheduler: KeepAwakeTimerScheduling {
  func schedule(
    every interval: TimeInterval, action: @escaping @MainActor () -> Void
  ) -> any KeepAwakeTimerToken {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { action() }
    }
    RunLoop.main.add(timer, forMode: .common)
    return MainRunLoopKeepAwakeTimer(timer: timer)
  }
}

@MainActor
private final class MainRunLoopKeepAwakeTimer: KeepAwakeTimerToken {
  private let timer: Timer
  init(timer: Timer) { self.timer = timer }
  func cancel() { timer.invalidate() }
}
