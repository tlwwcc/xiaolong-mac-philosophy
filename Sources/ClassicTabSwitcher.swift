import AppKit
import ApplicationServices
import Carbon

struct ClassicTabSwitcherAppSnapshot: Identifiable, Equatable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let path: String?
  let icon: NSImage?
  let windowTitle: String
  let isMinimized: Bool
  let isHidden: Bool
  let isFullscreen: Bool
  let isCurrentWindow: Bool

  static func == (lhs: ClassicTabSwitcherAppSnapshot, rhs: ClassicTabSwitcherAppSnapshot) -> Bool {
    lhs.id == rhs.id
      && lhs.name == rhs.name
      && lhs.bundleIdentifier == rhs.bundleIdentifier
      && lhs.path == rhs.path
      && lhs.windowTitle == rhs.windowTitle
      && lhs.isMinimized == rhs.isMinimized
      && lhs.isHidden == rhs.isHidden
      && lhs.isFullscreen == rhs.isFullscreen
      && lhs.isCurrentWindow == rhs.isCurrentWindow
  }
}

struct ClassicTabSwitcherHUDState: Equatable {
  var isVisible: Bool
  var apps: [ClassicTabSwitcherAppSnapshot]
  var selectedIndex: Int
  var message: String?

  static let hidden = ClassicTabSwitcherHUDState(
    isVisible: false,
    apps: [],
    selectedIndex: 0,
    message: nil)
}

enum ClassicTabSwitcherStartResult: Equatable {
  case running
  case missingAccessibility
  case missingInputMonitoring
  case failed(String)
}

final class ClassicTabSwitcher {
  private enum TabDirection: String {
    case forward
    case backward

    var step: Int {
      switch self {
      case .forward: return 1
      case .backward: return -1
      }
    }
  }

  private enum TriggerModifier: String {
    case command
    case option

    var displayName: String {
      switch self {
      case .command: return "Command+Tab"
      case .option: return "Alt/Option+Tab"
      }
    }

    var suppressedLogName: String {
      switch self {
      case .command: return "classic_tab_switcher_command_tab_suppressed"
      case .option: return "classic_tab_switcher_alt_tab_suppressed"
      }
    }

    var releaseLogName: String {
      switch self {
      case .command: return "classic_tab_switcher_session_release_command"
      case .option: return "classic_tab_switcher_session_release_option"
      }
    }
  }

  private struct CandidateRefreshSnapshot {
    let candidates: [ClassicTabSwitcherWindowCandidate]
    let appCount: Int
    let windowCount: Int
    let visibleWindowCount: Int
    let slowAppCount: Int
    let slowApps: [String]
    let budgetExceeded: Bool
    let inventory: CandidateInventory
  }

  private struct CandidateInventory {
    var rawRunningAppCount = 0
    var regularAppCount = 0
    var rawWindowCount = 0
    var includedWindowCount = 0
    var fallbackAppCandidateCount = 0
    var filteredAppCount = 0
    var filteredWindowCount = 0
    var includedMinimizedCount = 0
    var includedHiddenCount = 0
    var includedFullscreenCount = 0
    var filteredReasons: [String: Int] = [:]
    var filteredSamples: [String: [String]] = [:]

    mutating func recordFiltered(reason: String, app: NSRunningApplication, title: String = "") {
      filteredReasons[reason, default: 0] += 1
      let name = app.localizedName ?? app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
      let sample =
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? name
        : "\(name):\(title)"
      if filteredSamples[reason, default: []].count < 4 {
        filteredSamples[reason, default: []].append(sample)
      }
    }

    func payload(reason: String, visibleWindowCount: Int, resultCount: Int) -> [String: String] {
      [
        "fallbackAppCandidateCount": "\(fallbackAppCandidateCount)",
        "filteredAppCount": "\(filteredAppCount)",
        "filteredReasonSummary": reasonSummary(),
        "filteredSamples": sampleSummary(),
        "filteredWindowCount": "\(filteredWindowCount)",
        "includedFullscreenCount": "\(includedFullscreenCount)",
        "includedHiddenCount": "\(includedHiddenCount)",
        "includedMinimizedCount": "\(includedMinimizedCount)",
        "includedWindowCount": "\(includedWindowCount)",
        "rawRunningAppCount": "\(rawRunningAppCount)",
        "rawWindowCount": "\(rawWindowCount)",
        "reason": reason,
        "regularAppCount": "\(regularAppCount)",
        "resultCount": "\(resultCount)",
        "visibleWindowCount": "\(visibleWindowCount)",
      ]
    }

    private func reasonSummary() -> String {
      filteredReasons
        .sorted { lhs, rhs in
          if lhs.value != rhs.value { return lhs.value > rhs.value }
          return lhs.key < rhs.key
        }
        .map { "\($0.key):\($0.value)" }
        .joined(separator: ",")
    }

    private func sampleSummary() -> String {
      filteredSamples
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.joined(separator: "|"))" }
        .joined(separator: ";")
    }
  }

  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var eventTapRunLoop: CFRunLoop?
  private var eventTapThread: Thread?
  private var workspaceObserver: NSObjectProtocol?
  private var candidates: [ClassicTabSwitcherWindowCandidate] = []
  private var selectedIndex = 0
  private var lastActivatedBundleIDs: [String] = []
  private var hideMessageWorkItem: DispatchWorkItem?
  private var hudPublishWorkItem: DispatchWorkItem?
  private var lastHUDPublishAt: TimeInterval = 0
  private var lastCommandFlagDown = false
  private var lastOptionFlagDown = false
  private var pendingSessionStart = false
  private var pendingSessionStartedAt: TimeInterval = 0
  private var pendingSessionTrigger: TriggerModifier?
  private var pendingSessionDirection: TabDirection?
  private var activeSessionTrigger: TriggerModifier?
  private var activeSessionStartedAt: TimeInterval = 0
  private var pendingTabPressCount = 0
  private var pendingSelectionDelta = 0
  private var capturesCommandTab = false
  private var commitInProgress = false
  private var candidateCache: [ClassicTabSwitcherWindowCandidate] = []
  private var candidateCacheUpdatedAt: TimeInterval = 0
  private var candidateRefreshInFlight = false
  private var candidateRefreshCompletions: [([ClassicTabSwitcherWindowCandidate]) -> Void] = []
  private var candidateRefreshGeneration = 0
  private var candidateRefreshActiveReason: String?
  private var candidateRefreshCoalescedReasons: [String] = []
  private var candidateRefreshLastFinishedAt: TimeInterval = 0
  private var focusTokenSequence: UInt64 = 0
  private var currentFocusToken: UInt64 = 0
  private var currentFocusCandidate: ClassicTabSwitcherWindowCandidate?
  private var currentFocusStartedAt: TimeInterval = 0
  private var focusRetryWorkItems: [DispatchWorkItem] = []
  private var completedFocusTokens = Set<UInt64>()
  private let appIconCacheLock = NSLock()
  private var appIconCache: [String: NSImage] = [:]
  private let inputEventLock = NSLock()
  private var inputEventCounter: UInt64 = 0
  private var latestCommandReleaseEventID: UInt64 = 0
  private var latestOptionReleaseEventID: UInt64 = 0
  private let candidateRefreshQueue = DispatchQueue(
    label: "\(AppRuntimeIdentity.current.notificationNamespace).classic-tab.candidates",
    qos: .userInitiated)
  private let candidateCacheFreshAge: TimeInterval = 1.5
  private let candidateRefreshMinimumInterval: TimeInterval = 1.0
  private let candidateRefreshBudget: TimeInterval = 0.65
  private let candidateSlowAppBudget: TimeInterval = 0.12
  private let iconSlowLoadBudget: TimeInterval = 0.012
  private let axSnapshotTimeout: TimeInterval = 0.055
  private let axFocusTimeout: TimeInterval = 0.12
  private let postCommitUserInterventionGrace: TimeInterval = 0.12
  private let stageManagerRevealRetryDelays: [TimeInterval] = [0.06, 0.14, 0.30, 0.60]
  private let onStateChange: (ClassicTabSwitcherHUDState) -> Void
  private let onNotice: (String) -> Void
  private let cancelAppForegroundRepair: (NSRunningApplication, String) -> Void
  private let revealSelfApp: () -> Bool

  private(set) var isRunning = false
  private(set) var isSessionActive = false

  init(
    onStateChange: @escaping (ClassicTabSwitcherHUDState) -> Void,
    onNotice: @escaping (String) -> Void,
    cancelAppForegroundRepair: @escaping (NSRunningApplication, String) -> Void,
    revealSelfApp: @escaping () -> Bool
  ) {
    self.onStateChange = onStateChange
    self.onNotice = onNotice
    self.cancelAppForegroundRepair = cancelAppForegroundRepair
    self.revealSelfApp = revealSelfApp
  }

  deinit {
    stop()
  }

  func start(capturesCommandTab: Bool) -> ClassicTabSwitcherStartResult {
    stop()
    self.capturesCommandTab = capturesCommandTab
    let accessibilityTrusted = AXIsProcessTrusted()
    AppDiagnostics.log(
      "classic_tab_switcher_accessibility_preflight",
      [
        "capturesCommandTab": "\(capturesCommandTab)",
        "granted": "\(accessibilityTrusted)",
      ])
    guard accessibilityTrusted else {
      return .missingAccessibility
    }
    guard requestListenEventAccessIfNeeded() else {
      return .missingInputMonitoring
    }
    AppDiagnostics.log(
      "classic_tab_switcher_secure_input_state",
      ["enabled": "\(secureInputEnabled())"])

    let mask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let switcher = Unmanaged<ClassicTabSwitcher>.fromOpaque(userInfo).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        AppDiagnostics.log(
          "classic_tab_switcher_eventtap_disabled",
          [
            "reason": type == .tapDisabledByTimeout ? "timeout" : "userInput",
            "secureInput": "\(switcher.secureInputEnabled())",
          ])
        switcher.reenableEventTap(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
        return Unmanaged.passUnretained(event)
      }
      if switcher.handle(event: event, type: type) {
        return nil
      }
      return Unmanaged.passUnretained(event)
    }

    eventTap =
      makeEventTap(tap: .cghidEventTap, mask: mask, callback: callback)
      ?? makeEventTap(tap: .cgSessionEventTap, mask: mask, callback: callback)

    guard let eventTap else {
      return .failed("窗口切换监听启动失败：请点“立即授权”，软件会自动处理。")
    }

    resetInputEventWatermark()
    candidateRefreshGeneration += 1
    startWorkspaceObserver()
    seedFrontmostApplication()
    refreshCandidateCache(reason: "start")
    startEventTapThread(tapPort: eventTap)
    isRunning = true
    AppDiagnostics.log(
      "classic_tab_switcher_started",
      ["capturesCommandTab": "\(capturesCommandTab)"])
    return .running
  }

  func stop() {
    hideMessageWorkItem?.cancel()
    hideMessageWorkItem = nil
    hudPublishWorkItem?.cancel()
    hudPublishWorkItem = nil
    isRunning = false
    isSessionActive = false
    pendingSessionStart = false
    pendingSessionStartedAt = 0
    pendingSessionTrigger = nil
    pendingSessionDirection = nil
    activeSessionTrigger = nil
    activeSessionStartedAt = 0
    pendingTabPressCount = 0
    pendingSelectionDelta = 0
    commitInProgress = false
    invalidateFocusToken(reason: "stop")
    cancelFocusRetryWorkItems(reason: "stop")
    candidates.removeAll()
    candidateCache.removeAll()
    appIconCacheLock.lock()
    appIconCache.removeAll()
    appIconCacheLock.unlock()
    candidateCacheUpdatedAt = 0
    candidateRefreshInFlight = false
    candidateRefreshCompletions.removeAll()
    candidateRefreshActiveReason = nil
    candidateRefreshCoalescedReasons.removeAll()
    candidateRefreshLastFinishedAt = 0
    candidateRefreshGeneration += 1
    resetInputEventWatermark()
    selectedIndex = 0
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let eventTapRunLoop {
      CFRunLoopStop(eventTapRunLoop)
    }
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
      self.workspaceObserver = nil
    }
    eventTapSource = nil
    eventTapRunLoop = nil
    eventTapThread = nil
    eventTap = nil
    DispatchQueue.main.async {
      self.onStateChange(.hidden)
    }
  }

  func previewHUD() {
    hideMessageWorkItem?.cancel()
    hideMessageWorkItem = nil
    guard AXIsProcessTrusted() else {
      AppDiagnostics.log(
        "classic_tab_switcher_preview_blocked",
        ["reason": "missing_accessibility"])
      showTransientMessage("需要完成系统授权才能读取窗口")
      return
    }

    refreshCandidateCache(reason: "manual_preview") { [weak self] refreshed in
      guard let self else { return }
      self.candidates = refreshed
      guard refreshed.count >= 2 else {
        self.showTransientMessage("没有可切换的窗口")
        AppDiagnostics.log(
          "classic_tab_switcher_preview_empty",
          ["count": "\(refreshed.count)"])
        return
      }
      self.selectedIndex = self.initialSelectionIndex(in: refreshed)
      self.publishSessionState(throttled: false)
      AppDiagnostics.log(
        "classic_tab_switcher_preview_shown",
        [
          "count": "\(refreshed.count)",
          "selected": self.selectedWindowName,
        ])
      let workItem = DispatchWorkItem { [weak self] in
        guard let self, !self.isSessionActive else { return }
        self.publishHidden()
        self.hideMessageWorkItem = nil
      }
      self.hideMessageWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
  }

  private func makeEventTap(
    tap: CGEventTapLocation,
    mask: Int,
    callback: @escaping CGEventTapCallBack
  ) -> CFMachPort? {
    CGEvent.tapCreate(
      tap: tap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    )
  }

  private func startEventTapThread(tapPort: CFMachPort) {
    let thread = Thread { [weak self] in
      guard let self else { return }
      let runLoop = CFRunLoopGetCurrent()
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
      self.eventTapRunLoop = runLoop
      self.eventTapSource = source
      if let source {
        CFRunLoopAddSource(runLoop, source, .commonModes)
      }
      CGEvent.tapEnable(tap: tapPort, enable: true)
      AppDiagnostics.log("classic_tab_switcher_eventtap_started", [:])
      CFRunLoopRun()
    }
    thread.name = "aixlg-classic-tab-switcher"
    thread.qualityOfService = .userInteractive
    eventTapThread = thread
    thread.start()
  }

  private func handle(event: CGEvent, type: CGEventType) -> Bool {
    switch type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return false
    }
  }

  private func handleKeyDown(_ event: CGEvent) -> Bool {
    let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    if isSessionActive, code == keyCode(for: "Escape") {
      DispatchQueue.main.async { self.cancelSession() }
      return true
    }
    if code == keyCode(for: "Tab") {
      let eventID = nextInputEventID()
      let trigger = tabTrigger(for: flags)
      let direction = tabDirection(for: flags)
      AppDiagnostics.log(
        "classic_tab_switcher_tab_keydown",
        keyDiagnosticPayload(
          flags: flags,
          autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat),
          eventID: eventID,
          matched: trigger != nil,
          trigger: trigger,
          direction: direction
        ))
      guard let trigger else {
        return false
      }
      if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
        AppDiagnostics.log(
          "classic_tab_switcher_autorepeat_ignored",
          ["eventID": "\(eventID)", "trigger": trigger.rawValue])
        return true
      }
      AppDiagnostics.log(
        trigger.suppressedLogName,
        [
          "direction": direction.rawValue,
          "eventID": "\(eventID)",
          "trigger": trigger.rawValue,
        ])
      DispatchQueue.main.async {
        self.handleTriggerTabPress(eventID: eventID, trigger: trigger, direction: direction)
      }
      return true
    }
    return false
  }

  private func handleFlagsChanged(_ event: CGEvent) -> Bool {
    let eventID = nextInputEventID()
    let flags = event.flags
    let commandDown = flags.contains(.maskCommand)
    let optionDown = flags.contains(.maskAlternate)
    if commandDown != lastCommandFlagDown {
      lastCommandFlagDown = commandDown
      if !commandDown {
        markTriggerReleased(.command, eventID: eventID)
      }
      AppDiagnostics.log(
        "classic_tab_switcher_command_flags_changed",
        [
          "down": "\(commandDown)",
          "eventID": "\(eventID)",
          "keyCode": "\(event.getIntegerValueField(.keyboardEventKeycode))",
          "option": "\(optionDown)",
          "session": "\(isSessionActive)",
          "secureInput": "\(secureInputEnabled())",
        ])
      if !commandDown {
        DispatchQueue.main.async {
          self.handleTriggerReleased(.command, eventID: eventID)
        }
      }
    }
    if optionDown != lastOptionFlagDown {
      lastOptionFlagDown = optionDown
      if !optionDown {
        markTriggerReleased(.option, eventID: eventID)
      }
      AppDiagnostics.log(
        "classic_tab_switcher_option_flags_changed",
        [
          "command": "\(commandDown)",
          "down": "\(optionDown)",
          "eventID": "\(eventID)",
          "keyCode": "\(event.getIntegerValueField(.keyboardEventKeycode))",
          "session": "\(isSessionActive)",
          "secureInput": "\(secureInputEnabled())",
        ])
      if !optionDown {
        DispatchQueue.main.async {
          self.handleTriggerReleased(.option, eventID: eventID)
        }
      }
    }
    return false
  }

  private func tabTrigger(for flags: CGEventFlags) -> TriggerModifier? {
    let command = flags.contains(.maskCommand)
    let option = flags.contains(.maskAlternate)
    guard !flags.contains(.maskControl) else { return nil }
    if capturesCommandTab, command, !option {
      return .command
    }
    if option, !command {
      return .option
    }
    return nil
  }

  private func tabDirection(for flags: CGEventFlags) -> TabDirection {
    flags.contains(.maskShift) ? .backward : .forward
  }

  private func nextInputEventID() -> UInt64 {
    inputEventLock.lock()
    defer { inputEventLock.unlock() }
    inputEventCounter += 1
    return inputEventCounter
  }

  private func resetInputEventWatermark() {
    inputEventLock.lock()
    inputEventCounter = 0
    latestCommandReleaseEventID = 0
    latestOptionReleaseEventID = 0
    inputEventLock.unlock()
    lastCommandFlagDown = false
    lastOptionFlagDown = false
  }

  private func markTriggerReleased(_ trigger: TriggerModifier, eventID: UInt64) {
    inputEventLock.lock()
    switch trigger {
    case .command:
      latestCommandReleaseEventID = max(latestCommandReleaseEventID, eventID)
    case .option:
      latestOptionReleaseEventID = max(latestOptionReleaseEventID, eventID)
    }
    inputEventLock.unlock()
  }

  private func isInputEventStale(_ eventID: UInt64, trigger: TriggerModifier) -> Bool {
    inputEventLock.lock()
    let releaseEventID: UInt64
    switch trigger {
    case .command:
      releaseEventID = latestCommandReleaseEventID
    case .option:
      releaseEventID = latestOptionReleaseEventID
    }
    inputEventLock.unlock()
    return eventID <= releaseEventID
  }

  private func handleTriggerTabPress(
    eventID: UInt64,
    trigger: TriggerModifier,
    direction: TabDirection
  ) {
    guard isRunning else { return }
    guard !isInputEventStale(eventID, trigger: trigger) else {
      AppDiagnostics.log(
        "classic_tab_switcher_stale_tab_ignored",
        ["eventID": "\(eventID)", "reason": "released_before_main", "trigger": trigger.rawValue])
      return
    }
    guard !commitInProgress else {
      AppDiagnostics.log(
        "classic_tab_switcher_tab_ignored",
        ["eventID": "\(eventID)", "reason": "commit_in_progress", "trigger": trigger.rawValue])
      return
    }
    hideMessageWorkItem?.cancel()
    hideMessageWorkItem = nil
    if isSessionActive {
      guard activeSessionTrigger == trigger else {
        AppDiagnostics.log(
          "classic_tab_switcher_tab_ignored",
          [
            "activeTrigger": activeSessionTrigger?.rawValue ?? "none",
            "eventID": "\(eventID)",
            "reason": "different_trigger_active",
            "trigger": trigger.rawValue,
          ])
        return
      }
      guard !candidates.isEmpty else { return }
      let stepStartedAt = ProcessInfo.processInfo.systemUptime
      moveSelection(direction)
      publishSessionState(throttled: true)
      let stepDuration = ProcessInfo.processInfo.systemUptime - stepStartedAt
      AppDiagnostics.log(
        "classic_tab_switcher_session_update",
        [
          "count": "\(candidates.count)",
          "direction": direction.rawValue,
          "duration": String(format: "%.4f", stepDuration),
          "eventID": "\(eventID)",
          "selected": selectedWindowName,
          "trigger": trigger.rawValue,
        ])
      AppDiagnostics.log(
        "classic_tab_switcher_tab_step",
        [
          "count": "\(candidates.count)",
          "direction": direction.rawValue,
          "duration": String(format: "%.4f", stepDuration),
          "eventID": "\(eventID)",
          "selectedIndex": "\(selectedIndex)",
          "trigger": trigger.rawValue,
        ])
      return
    }

    if pendingSessionStart {
      guard pendingSessionTrigger == trigger else {
        AppDiagnostics.log(
          "classic_tab_switcher_tab_ignored",
          [
            "eventID": "\(eventID)",
            "pendingTrigger": pendingSessionTrigger?.rawValue ?? "none",
            "reason": "different_trigger_pending",
            "trigger": trigger.rawValue,
          ])
        return
      }
      recordPendingTabPress(direction: direction)
      AppDiagnostics.log(
        "classic_tab_switcher_session_start_queued_tab",
        [
          "direction": direction.rawValue,
          "eventID": "\(eventID)",
          "pendingDelta": "\(pendingSelectionDelta)",
          "pendingTabs": "\(pendingTabPressCount)",
          "trigger": trigger.rawValue,
        ])
      return
    }

    pendingSessionStart = true
    pendingSessionStartedAt = ProcessInfo.processInfo.systemUptime
    pendingSessionTrigger = trigger
    pendingSessionDirection = direction
    recordPendingTabPress(direction: direction)
    let startEventID = eventID
    let cachedCandidates = candidateCache
    if cachedCandidates.count >= 2 {
      let fresh = candidateCacheIsFresh()
      logCandidateCacheUsed(
        reason: "session_start",
        source: fresh ? "cache_fresh" : "cache_stale",
        eventID: startEventID,
        cacheCount: cachedCandidates.count)
      beginSession(
        with: cachedCandidates,
        eventID: startEventID,
        source: fresh ? "cache_fresh" : "cache_stale",
        trigger: trigger)
      return
    }

    AppDiagnostics.log(
      "classic_tab_switcher_session_start_pending",
      [
        "direction": direction.rawValue,
        "eventID": "\(startEventID)",
        "reason": "cache_empty",
        "trigger": trigger.rawValue,
      ])
    showTransientMessage("正在准备窗口")
    refreshCandidateCache(reason: "session_start") { [weak self] refreshed in
      self?.completePendingSessionStart(
        eventID: startEventID,
        candidates: refreshed,
        source: "refresh",
        trigger: trigger)
    }
  }

  private func handleTriggerReleased(_ trigger: TriggerModifier, eventID: UInt64) {
    if pendingSessionStart {
      guard pendingSessionTrigger == trigger else { return }
      pendingSessionStart = false
      pendingSessionTrigger = nil
      pendingSessionDirection = nil
      pendingSessionStartedAt = 0
      pendingTabPressCount = 0
      pendingSelectionDelta = 0
      publishHidden()
      AppDiagnostics.log(
        "classic_tab_switcher_session_start_canceled",
        [
          "eventID": "\(eventID)",
          "reason": "\(trigger.rawValue)_released_before_candidates",
          "trigger": trigger.rawValue,
        ])
      return
    }
    guard isSessionActive else { return }
    guard activeSessionTrigger == trigger else { return }
    guard !commitInProgress else {
      AppDiagnostics.log(
        "classic_tab_switcher_session_release_ignored",
        ["eventID": "\(eventID)", "reason": "commit_in_progress", "trigger": trigger.rawValue])
      return
    }
    AppDiagnostics.log(
      trigger.releaseLogName,
      [
        "count": "\(candidates.count)",
        "eventID": "\(eventID)",
        "selected": selectedWindowName,
        "trigger": trigger.rawValue,
      ])
    finishSession(releaseEventID: eventID)
  }

  private func completePendingSessionStart(
    eventID: UInt64,
    candidates refreshed: [ClassicTabSwitcherWindowCandidate],
    source: String,
    trigger: TriggerModifier
  ) {
    guard pendingSessionStart else { return }
    guard pendingSessionTrigger == trigger else { return }
    guard !isInputEventStale(eventID, trigger: trigger) else {
      pendingSessionStart = false
      pendingSessionTrigger = nil
      pendingSessionDirection = nil
      pendingSessionStartedAt = 0
      pendingTabPressCount = 0
      pendingSelectionDelta = 0
      publishHidden()
      AppDiagnostics.log(
        "classic_tab_switcher_session_start_canceled",
        [
          "eventID": "\(eventID)",
          "reason": "released_before_refresh",
          "trigger": trigger.rawValue,
        ])
      return
    }
    beginSession(with: refreshed, eventID: eventID, source: source, trigger: trigger)
  }

  private func beginSession(
    with refreshed: [ClassicTabSwitcherWindowCandidate],
    eventID: UInt64,
    source: String,
    trigger: TriggerModifier
  ) {
    hideMessageWorkItem?.cancel()
    hideMessageWorkItem = nil
    invalidateFocusToken(reason: "session_start")
    pendingSessionStart = false
    pendingSessionTrigger = nil
    let direction = pendingSessionDirection ?? .forward
    pendingSessionDirection = nil
    let sessionRequestedAt = pendingSessionStartedAt
    pendingSessionStartedAt = 0
    let tabPressCount = max(1, pendingTabPressCount)
    let selectionDelta = pendingSelectionDelta
    pendingTabPressCount = 0
    pendingSelectionDelta = 0
    candidates = refreshed
    guard candidates.count >= 2 else {
      activeSessionTrigger = nil
      activeSessionStartedAt = 0
      showTransientMessage("没有可切换的窗口")
      AppDiagnostics.log(
        "classic_tab_switcher_no_candidates",
        [
          "count": "\(candidates.count)",
          "eventID": "\(eventID)",
          "source": source,
          "trigger": trigger.rawValue,
        ])
      return
    }
    selectedIndex = initialSelectionIndex(in: candidates, direction: direction)
    if selectionDelta != 0 {
      selectedIndex = wrappedIndex(selectedIndex + selectionDelta, count: candidates.count)
    }
    isSessionActive = true
    activeSessionTrigger = trigger
    activeSessionStartedAt =
      sessionRequestedAt > 0 ? sessionRequestedAt : ProcessInfo.processInfo.systemUptime
    let publishStartedAt = ProcessInfo.processInfo.systemUptime
    publishSessionState(throttled: false)
    let publishDuration = ProcessInfo.processInfo.systemUptime - publishStartedAt
    let firstFrameDuration = ProcessInfo.processInfo.systemUptime - activeSessionStartedAt
    AppDiagnostics.log(
      "classic_tab_switcher_hud_first_frame",
      [
        "cacheAge": String(format: "%.3f", candidateCacheAge()),
        "count": "\(candidates.count)",
        "duration": String(format: "%.4f", firstFrameDuration),
        "eventID": "\(eventID)",
        "publishDuration": String(format: "%.4f", publishDuration),
        "selected": selectedWindowName,
        "source": source,
        "trigger": trigger.rawValue,
      ])
    AppDiagnostics.log(
      "classic_tab_switcher_session_start",
      [
        "cacheAge": String(format: "%.3f", candidateCacheAge()),
        "count": "\(candidates.count)",
        "direction": direction.rawValue,
        "eventID": "\(eventID)",
        "pendingDelta": "\(selectionDelta)",
        "pendingTabs": "\(tabPressCount)",
        "selected": selectedWindowName,
        "source": source,
        "trigger": trigger.rawValue,
      ])
  }

  private func finishSession(releaseEventID: UInt64) {
    guard isSessionActive else { return }
    guard !commitInProgress else {
      AppDiagnostics.log(
        "classic_tab_switcher_session_commit_ignored",
        ["eventID": "\(releaseEventID)", "reason": "commit_in_progress"])
      return
    }
    commitInProgress = true
    isSessionActive = false
    guard candidates.indices.contains(selectedIndex) else {
      publishHidden()
      commitInProgress = false
      activeSessionTrigger = nil
      return
    }
    let candidate = candidates[selectedIndex]
    let commitStartedAt = ProcessInfo.processInfo.systemUptime
    let focusToken = startFocusToken(for: candidate, eventID: releaseEventID)
    publishHidden()
    AppDiagnostics.log(
      "classic_tab_switcher_window_reveal_requested",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "eventID": "\(releaseEventID)",
        "minimized": "\(candidate.isMinimized)",
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])
    revealWindowToFront(candidate, focusToken: focusToken)
    let commitDuration = ProcessInfo.processInfo.systemUptime - commitStartedAt
    AppDiagnostics.log(
      "classic_tab_switcher_commit_latency",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "duration": String(format: "%.4f", commitDuration),
        "eventID": "\(releaseEventID)",
        "frontmost": "\(isFrontmost(candidate.app))",
        "targetWindowRank": windowRank(for: candidate).map(String.init) ?? "none",
        "targetWindowTopmost": "\(windowRank(for: candidate) == 0)",
        "title": candidate.displayTitle,
      ])
    AppDiagnostics.log(
      "classic_tab_switcher_session_commit",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "eventID": "\(releaseEventID)",
        "frontmost": "\(isFrontmost(candidate.app))",
        "title": candidate.displayTitle,
        "windowTopmost": "\(windowRank(for: candidate) == 0)",
      ])
    candidates.removeAll()
    selectedIndex = 0
    activeSessionTrigger = nil
    activeSessionStartedAt = 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
      guard let self else { return }
      self.commitInProgress = false
      self.refreshCandidateCache(reason: "post_commit")
    }
  }

  private func cancelSession() {
    guard isSessionActive else { return }
    isSessionActive = false
    candidates.removeAll()
    selectedIndex = 0
    activeSessionTrigger = nil
    activeSessionStartedAt = 0
    pendingSessionTrigger = nil
    pendingSessionDirection = nil
    pendingSessionStartedAt = 0
    pendingSelectionDelta = 0
    invalidateFocusToken(reason: "session_cancel")
    publishHidden()
    AppDiagnostics.log("classic_tab_switcher_session_cancel", [:])
  }

  private func publishSessionState(throttled: Bool) {
    hudPublishWorkItem?.cancel()
    hudPublishWorkItem = nil
    let now = ProcessInfo.processInfo.systemUptime
    if throttled, now - lastHUDPublishAt < 0.028 {
      let workItem = DispatchWorkItem { [weak self] in
        self?.publishSessionState(throttled: false)
      }
      hudPublishWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.028, execute: workItem)
      return
    }
    lastHUDPublishAt = now
    let snapshots = candidates.map(snapshot)
    let state = ClassicTabSwitcherHUDState(
      isVisible: true,
      apps: snapshots,
      selectedIndex: min(selectedIndex, max(0, snapshots.count - 1)),
      message: nil)
    onStateChange(state)
  }

  private func publishHidden() {
    hudPublishWorkItem?.cancel()
    hudPublishWorkItem = nil
    onStateChange(.hidden)
  }

  private func showTransientMessage(_ message: String) {
    onStateChange(
      ClassicTabSwitcherHUDState(
        isVisible: true,
        apps: [],
        selectedIndex: 0,
        message: message))
    let workItem = DispatchWorkItem { [weak self] in
      self?.onStateChange(.hidden)
      self?.hideMessageWorkItem = nil
    }
    hideMessageWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
  }

  private func refreshCandidateCache(
    reason: String,
    completion: (([ClassicTabSwitcherWindowCandidate]) -> Void)? = nil
  ) {
    if let completion, candidateCache.count >= 2, candidateCacheIsFresh() {
      logCandidateCacheUsed(
        reason: reason,
        source: "fresh_cache_for_completion",
        eventID: nil,
        cacheCount: candidateCache.count)
      completion(candidateCache)
      return
    }

    if shouldDeferCandidateRefresh(reason: reason, hasCompletion: completion != nil) {
      logCandidateRefreshSkipped(reason: reason, skippedBy: "active_session")
      return
    }

    if shouldUseExistingCacheForRefresh(reason: reason, hasCompletion: completion != nil) {
      logCandidateCacheUsed(
        reason: reason,
        source: "refresh_budget_min_interval",
        eventID: nil,
        cacheCount: candidateCache.count)
      return
    }

    if let completion {
      candidateRefreshCompletions.append(completion)
    }

    guard !candidateRefreshInFlight else {
      candidateRefreshCoalescedReasons.append(reason)
      let payload = [
        "activeReason": candidateRefreshActiveReason ?? "unknown",
        "cacheAge": candidateCacheAgeLabel(),
        "cacheCount": "\(candidateCache.count)",
        "coalescedCount": "\(candidateRefreshCoalescedReasons.count)",
        "reason": reason,
      ]
      AppDiagnostics.log("classic_tab_candidate_refresh_coalesced", payload)
      AppDiagnostics.log("classic_tab_switcher_candidate_refresh_joined", payload)
      return
    }

    candidateRefreshInFlight = true
    candidateRefreshActiveReason = reason
    candidateRefreshCoalescedReasons.removeAll()
    let generation = candidateRefreshGeneration
    let activationOrder = lastActivatedBundleIDs
    let startedAt = ProcessInfo.processInfo.systemUptime
    let fallbackCandidates = candidateCache
    let fallbackUpdatedAt = candidateCacheUpdatedAt
    AppDiagnostics.log(
      "classic_tab_candidate_refresh_started",
      [
        "cacheAge": candidateCacheAgeLabel(),
        "cacheCount": "\(candidateCache.count)",
        "cacheResult": candidateCache.isEmpty ? "miss" : "available",
        "cacheStatus": candidateCacheStatus(),
        "reason": reason,
      ])
    AppDiagnostics.log(
      "classic_tab_switcher_candidate_refresh_started",
      ["reason": reason])

    candidateRefreshQueue.async { [weak self] in
      guard let self else { return }
      let snapshot = self.eligibleWindowCandidateSnapshot(
        activationOrder: activationOrder,
        startedAt: startedAt)
      let usedFallback = snapshot.budgetExceeded && fallbackCandidates.count >= 2
      let refreshed = usedFallback ? fallbackCandidates : snapshot.candidates
      DispatchQueue.main.async {
        guard generation == self.candidateRefreshGeneration else { return }
        self.candidateRefreshInFlight = false
        self.candidateRefreshActiveReason = nil
        let finishedAt = ProcessInfo.processInfo.systemUptime
        self.candidateRefreshLastFinishedAt = finishedAt
        self.candidateCache = refreshed
        self.candidateCacheUpdatedAt = usedFallback ? fallbackUpdatedAt : finishedAt
        let completions = self.candidateRefreshCompletions
        self.candidateRefreshCompletions.removeAll()
        let coalescedReasons = self.candidateRefreshCoalescedReasons
        self.candidateRefreshCoalescedReasons.removeAll()
        let duration = finishedAt - startedAt
        let payload = [
          "appCount": "\(snapshot.appCount)",
          "budgetExceeded": "\(snapshot.budgetExceeded)",
          "cacheAge": self.candidateCacheAgeLabel(),
          "cacheResult": usedFallback ? "fallback_hit" : "refreshed",
          "cacheStatus": self.candidateCacheStatus(),
          "coalesced": "\(coalescedReasons.isEmpty ? false : true)",
          "coalescedCount": "\(coalescedReasons.count)",
          "coalescedReasons": coalescedReasons.joined(separator: ","),
          "count": "\(refreshed.count)",
          "duration": String(format: "%.3f", duration),
          "reason": reason,
          "slowAppCount": "\(snapshot.slowAppCount)",
          "slowApps": snapshot.slowApps.prefix(4).joined(separator: ","),
          "usedFallback": "\(usedFallback)",
          "visibleWindowCount": "\(snapshot.visibleWindowCount)",
          "windowCount": "\(snapshot.windowCount)",
        ]
        AppDiagnostics.log("classic_tab_candidate_refresh_finished", payload)
        let inventoryPayload = snapshot.inventory.payload(
          reason: reason,
          visibleWindowCount: snapshot.visibleWindowCount,
          resultCount: refreshed.count)
        AppDiagnostics.log("classic_tab_candidate_inventory", inventoryPayload)
        AppDiagnostics.log("classic_tab_candidate_inventory_filtered", inventoryPayload)
        AppDiagnostics.log(
          "classic_tab_switcher_candidate_refresh_finished",
          payload)
        for completion in completions {
          completion(refreshed)
        }
      }
    }
  }

  private func candidateCacheIsFresh(maxAge: TimeInterval? = nil) -> Bool {
    let maxAge = maxAge ?? candidateCacheFreshAge
    return candidateCacheAge() <= maxAge
  }

  private func candidateCacheAge() -> TimeInterval {
    guard candidateCacheUpdatedAt > 0 else { return .infinity }
    return ProcessInfo.processInfo.systemUptime - candidateCacheUpdatedAt
  }

  private func candidateCacheAgeLabel() -> String {
    let age = candidateCacheAge()
    guard age.isFinite else { return "none" }
    return String(format: "%.3f", age)
  }

  private func candidateCacheStatus(maxAge: TimeInterval? = nil) -> String {
    if candidateCache.isEmpty { return "empty" }
    return candidateCacheIsFresh(maxAge: maxAge) ? "fresh" : "stale"
  }

  private func shouldDeferCandidateRefresh(reason: String, hasCompletion: Bool) -> Bool {
    guard !hasCompletion else { return false }
    if pendingSessionStart || isSessionActive || commitInProgress {
      return reason != "start"
    }
    return false
  }

  private func shouldUseExistingCacheForRefresh(reason: String, hasCompletion: Bool) -> Bool {
    guard !hasCompletion, candidateCache.count >= 2 else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    if candidateCacheIsFresh(), reason != "start" {
      return true
    }
    guard candidateRefreshLastFinishedAt > 0 else { return false }
    let elapsed = now - candidateRefreshLastFinishedAt
    guard elapsed < candidateRefreshMinimumInterval else { return false }
    return reason == "activation" || reason == "post_commit" || reason == "session_cache_stale"
  }

  private func logCandidateCacheUsed(
    reason: String,
    source: String,
    eventID: UInt64?,
    cacheCount: Int
  ) {
    var payload = [
      "cacheAge": candidateCacheAgeLabel(),
      "cacheCount": "\(cacheCount)",
      "cacheStatus": candidateCacheStatus(),
      "reason": reason,
      "source": source,
    ]
    if let eventID {
      payload["eventID"] = "\(eventID)"
    }
    AppDiagnostics.log("classic_tab_candidate_cache_used", payload)
  }

  private func logCandidateRefreshSkipped(reason: String, skippedBy: String) {
    AppDiagnostics.log(
      "classic_tab_candidate_refresh_skipped",
      [
        "cacheAge": candidateCacheAgeLabel(),
        "cacheCount": "\(candidateCache.count)",
        "cacheStatus": candidateCacheStatus(),
        "reason": reason,
        "skippedBy": skippedBy,
      ])
  }

  private func eligibleWindowCandidateSnapshot(
    activationOrder: [String],
    startedAt: TimeInterval
  ) -> CandidateRefreshSnapshot {
    let visibleInfos = standardVisibleWindowInfos()
    var usedVisibleInfoIndexes = Set<Int>()
    var results: [ClassicTabSwitcherWindowCandidate] = []
    var inventory = CandidateInventory()
    let rawRunning = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
    inventory.rawRunningAppCount = rawRunning.count
    let running = rawRunning.compactMap { app -> NSRunningApplication? in
      guard app.activationPolicy == .regular else {
        inventory.filteredAppCount += 1
        inventory.recordFiltered(reason: "app_non_regular", app: app)
        return nil
      }
      guard app.localizedName?.isEmpty == false else {
        inventory.filteredAppCount += 1
        inventory.recordFiltered(reason: "app_no_name", app: app)
        return nil
      }
      return app
    }
    inventory.regularAppCount = running.count
    var windowCount = 0
    var slowApps: [String] = []
    var budgetExceeded = false

    for app in running {
      let appStartedAt = ProcessInfo.processInfo.systemUptime
      var appIcon: NSImage?
      func candidateIcon() -> NSImage? {
        if let appIcon {
          return appIcon
        }
        appIcon = cachedIcon(for: app)
        return appIcon
      }
      let windows = axWindows(for: app)
      windowCount += windows.count
      inventory.rawWindowCount += windows.count
      var appIncludedCount = 0
      if windows.isEmpty {
        inventory.recordFiltered(reason: "app_no_ax_windows", app: app)
      }
      for (windowIndex, window) in windows.enumerated() {
        guard isWindowRole(window) else {
          inventory.filteredWindowCount += 1
          inventory.recordFiltered(reason: "window_non_window_role", app: app)
          continue
        }
        let title = axString(window, attribute: kAXTitleAttribute as CFString)
        let minimized = axBool(window, attribute: kAXMinimizedAttribute as CFString)
        let fullscreen = axBool(window, attribute: "AXFullScreen" as CFString)
        let windowNumber = axWindowNumber(window)
        let visibleRank = visibleWindowRank(
          for: app,
          windowNumber: windowNumber,
          title: title,
          visibleInfos: visibleInfos,
          usedIndexes: &usedVisibleInfoIndexes
        )
        guard
          isSwitchableWindow(title: title, minimized: minimized, visibleRank: visibleRank)
        else {
          inventory.filteredWindowCount += 1
          inventory.recordFiltered(
            reason: filteredWindowReason(
              title: title,
              minimized: minimized,
              visibleRank: visibleRank),
            app: app,
            title: title)
          continue
        }
        let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        let fallbackWindowID = "ax\(windowIndex)"
        let candidateID = [
          bundleID,
          "\(app.processIdentifier)",
          windowNumber.map(String.init) ?? fallbackWindowID,
        ].joined(separator: "-")
        results.append(
          ClassicTabSwitcherWindowCandidate(
            id: candidateID,
            app: app,
            icon: candidateIcon(),
            window: window,
            windowTitle: title,
            windowNumber: windowNumber,
            visibleRank: visibleRank,
            isMinimized: minimized,
            isHidden: app.isHidden,
            isFullscreen: fullscreen
          ))
        appIncludedCount += 1
        inventory.includedWindowCount += 1
        if minimized { inventory.includedMinimizedCount += 1 }
        if app.isHidden { inventory.includedHiddenCount += 1 }
        if fullscreen { inventory.includedFullscreenCount += 1 }
      }
      if appIncludedCount == 0, shouldIncludeAppFallbackCandidate(for: app) {
        let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        results.append(
          ClassicTabSwitcherWindowCandidate(
            id: "\(bundleID)-\(app.processIdentifier)-appFallback",
            app: app,
            icon: candidateIcon(),
            window: nil,
            windowTitle: app.localizedName ?? "App",
            windowNumber: nil,
            visibleRank: nil,
            isMinimized: false,
            isHidden: app.isHidden,
            isFullscreen: false
          ))
        inventory.fallbackAppCandidateCount += 1
        inventory.includedWindowCount += 1
        if app.isHidden { inventory.includedHiddenCount += 1 }
      }
      let appDuration = ProcessInfo.processInfo.systemUptime - appStartedAt
      if appDuration >= candidateSlowAppBudget {
        let appName = app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)"
        slowApps.append("\(appName):\(String(format: "%.3f", appDuration))")
      }
      if ProcessInfo.processInfo.systemUptime - startedAt >= candidateRefreshBudget,
        results.count >= 2
      {
        budgetExceeded = true
        break
      }
    }

    let sortedResults = results.sorted { lhs, rhs in
      let leftRank = lhs.visibleRank ?? Int.max
      let rightRank = rhs.visibleRank ?? Int.max
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      if lhs.isMinimized != rhs.isMinimized {
        return !lhs.isMinimized
      }
      let leftAppRank = rank(for: lhs.app, activationOrder: activationOrder)
      let rightAppRank = rank(for: rhs.app, activationOrder: activationOrder)
      if leftAppRank != rightAppRank {
        return leftAppRank < rightAppRank
      }
      let appCompare = (lhs.app.localizedName ?? "").localizedCaseInsensitiveCompare(
        rhs.app.localizedName ?? "")
      if appCompare != .orderedSame {
        return appCompare == .orderedAscending
      }
      return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
    }
    return CandidateRefreshSnapshot(
      candidates: sortedResults,
      appCount: running.count,
      windowCount: windowCount,
      visibleWindowCount: visibleInfos.count,
      slowAppCount: slowApps.count,
      slowApps: slowApps,
      budgetExceeded: budgetExceeded,
      inventory: inventory)
  }

  private func recordPendingTabPress(direction: TabDirection) {
    if pendingTabPressCount > 0 {
      pendingSelectionDelta += direction.step
    }
    pendingTabPressCount += 1
  }

  private func moveSelection(_ direction: TabDirection) {
    guard !candidates.isEmpty else { return }
    selectedIndex = wrappedIndex(selectedIndex + direction.step, count: candidates.count)
  }

  private func wrappedIndex(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return (index % count + count) % count
  }

  private func initialSelectionIndex(
    in windows: [ClassicTabSwitcherWindowCandidate],
    direction: TabDirection = .forward
  ) -> Int {
    if windows.count > 1, windows.first?.visibleRank == 0 {
      return direction == .forward ? 1 : windows.count - 1
    }
    if direction == .backward, windows.count > 1 {
      return windows.count - 1
    }
    return 0
  }

  private func rank(for app: NSRunningApplication, activationOrder: [String]) -> Int {
    guard let bundleID = app.bundleIdentifier,
      let index = activationOrder.firstIndex(of: bundleID)
    else {
      return Int.max
    }
    return index
  }

  private func standardVisibleWindowInfos() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let infos =
      CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return infos.filter(isStandardVisibleWindowInfo)
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

  private func visibleWindowRank(
    for app: NSRunningApplication,
    windowNumber: Int?,
    title: String,
    visibleInfos: [[String: Any]],
    usedIndexes: inout Set<Int>
  ) -> Int? {
    if let windowNumber,
      let index = visibleInfos.firstIndex(where: { info in
        !usedIndexes.contains(indexForWindowInfo(info, in: visibleInfos))
          && numberValue(info[kCGWindowNumber as String])?.intValue == windowNumber
      })
    {
      usedIndexes.insert(index)
      return index
    }

    let normalizedTitle = normalizedWindowTitle(title)
    if !normalizedTitle.isEmpty,
      let index = visibleInfos.firstIndex(where: { info in
        windowInfoPID(info) == app.processIdentifier
          && normalizedWindowTitle(windowInfoTitle(info)) == normalizedTitle
          && !usedIndexes.contains(indexForWindowInfo(info, in: visibleInfos))
      })
    {
      usedIndexes.insert(index)
      return index
    }

    if let index = visibleInfos.firstIndex(where: { info in
      windowInfoPID(info) == app.processIdentifier
        && !usedIndexes.contains(indexForWindowInfo(info, in: visibleInfos))
    }) {
      usedIndexes.insert(index)
      return index
    }

    return nil
  }

  private func indexForWindowInfo(_ target: [String: Any], in infos: [[String: Any]]) -> Int {
    let targetNumber = numberValue(target[kCGWindowNumber as String])?.intValue
    return infos.firstIndex { info in
      numberValue(info[kCGWindowNumber as String])?.intValue == targetNumber
    } ?? -1
  }

  private func isSwitchableWindow(
    title: String,
    minimized: Bool,
    visibleRank: Int?
  ) -> Bool {
    let hasTitle = !normalizedWindowTitle(title).isEmpty
    if minimized {
      return hasTitle
    }
    return hasTitle || visibleRank != nil
  }

  private func filteredWindowReason(
    title: String,
    minimized: Bool,
    visibleRank: Int?
  ) -> String {
    let hasTitle = !normalizedWindowTitle(title).isEmpty
    if minimized, !hasTitle {
      return "window_minimized_no_title"
    }
    if !hasTitle, visibleRank == nil {
      return "window_no_title_no_visible_match"
    }
    return "window_not_switchable"
  }

  private func shouldIncludeAppFallbackCandidate(for app: NSRunningApplication) -> Bool {
    guard app.activationPolicy == .regular, !app.isTerminated else { return false }
    guard app.localizedName?.isEmpty == false else { return false }
    return true
  }

  private func cachedIcon(for app: NSRunningApplication) -> NSImage? {
    guard let key = iconCacheKey(for: app), let path = app.bundleURL?.path else { return nil }
    appIconCacheLock.lock()
    if let cached = appIconCache[key] {
      appIconCacheLock.unlock()
      return cached
    }
    appIconCacheLock.unlock()

    let startedAt = ProcessInfo.processInfo.systemUptime
    let icon = NSWorkspace.shared.icon(forFile: path)
    let duration = ProcessInfo.processInfo.systemUptime - startedAt
    appIconCacheLock.lock()
    appIconCache[key] = icon
    appIconCacheLock.unlock()
    AppDiagnostics.log(
      "classic_tab_switcher_icon_load",
      [
        "app": app.localizedName ?? "App",
        "bundle": app.bundleIdentifier ?? "",
        "duration": String(format: "%.4f", duration),
        "path": path,
        "slow": "\(duration >= iconSlowLoadBudget)",
      ])
    return icon
  }

  private func iconCacheKey(for app: NSRunningApplication) -> String? {
    if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
      return "bundle:\(bundleID)"
    }
    if let path = app.bundleURL?.path, !path.isEmpty {
      return "path:\(path)"
    }
    return "pid:\(app.processIdentifier)"
  }

  private func axApplicationElement(
    for app: NSRunningApplication,
    timeout: TimeInterval
  ) -> AXUIElement {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    _ = AXUIElementSetMessagingTimeout(appElement, Float(timeout))
    return appElement
  }

  private func axWindows(for app: NSRunningApplication) -> [AXUIElement] {
    let appElement = axApplicationElement(for: app, timeout: axSnapshotTimeout)
    var rawWindows: AnyObject?
    guard
      AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        == .success,
      let windows = rawWindows as? [AXUIElement]
    else {
      return []
    }
    return windows
  }

  private func fallbackWindow(
    for app: NSRunningApplication,
    appElement: AXUIElement
  ) -> AXUIElement? {
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      var rawWindow: AnyObject?
      if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &rawWindow) == .success,
        let window = rawWindow,
        CFGetTypeID(window) == AXUIElementGetTypeID()
      {
        return (window as! AXUIElement)
      }
    }

    return axWindows(for: app).first { window in
      isWindowRole(window)
        && !axBool(window, attribute: kAXMinimizedAttribute as CFString)
    } ?? axWindows(for: app).first(where: isWindowRole)
  }

  private func isWindowRole(_ window: AXUIElement) -> Bool {
    axString(window, attribute: kAXRoleAttribute as CFString) == kAXWindowRole
  }

  private func axString(_ element: AXUIElement, attribute: CFString) -> String {
    var rawValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
      return ""
    }
    return rawValue as? String ?? ""
  }

  private func axBool(_ element: AXUIElement, attribute: CFString) -> Bool {
    var rawValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
      return false
    }
    return rawValue as? Bool ?? false
  }

  private func axWindowNumber(_ window: AXUIElement) -> Int? {
    var rawValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &rawValue)
        == .success
    else {
      return nil
    }
    return numberValue(rawValue)?.intValue
  }

  private func numberValue(_ raw: Any?) -> NSNumber? {
    if let number = raw as? NSNumber {
      return number
    }
    if let int = raw as? Int {
      return NSNumber(value: int)
    }
    if let int32 = raw as? Int32 {
      return NSNumber(value: int32)
    }
    if let double = raw as? Double {
      return NSNumber(value: double)
    }
    return nil
  }

  private func windowInfoPID(_ info: [String: Any]) -> pid_t? {
    guard let number = numberValue(info[kCGWindowOwnerPID as String]) else { return nil }
    return pid_t(number.intValue)
  }

  private func windowInfoTitle(_ info: [String: Any]) -> String {
    info[kCGWindowName as String] as? String ?? ""
  }

  private func windowInfoOwner(_ info: [String: Any]) -> String {
    info[kCGWindowOwnerName as String] as? String ?? ""
  }

  private func windowInfoBounds(_ info: [String: Any]) -> CGRect? {
    guard let rawBounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    let x = numberValue(rawBounds["X"])?.doubleValue ?? 0
    let y = numberValue(rawBounds["Y"])?.doubleValue ?? 0
    let width = numberValue(rawBounds["Width"])?.doubleValue ?? 0
    let height = numberValue(rawBounds["Height"])?.doubleValue ?? 0
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func normalizedWindowTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func snapshot(for candidate: ClassicTabSwitcherWindowCandidate)
    -> ClassicTabSwitcherAppSnapshot
  {
    let app = candidate.app
    let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    return ClassicTabSwitcherAppSnapshot(
      id: candidate.id,
      name: app.localizedName ?? "App",
      bundleIdentifier: bundleID,
      path: app.bundleURL?.path,
      icon: candidate.icon ?? cachedIcon(for: app),
      windowTitle: candidate.displayTitle,
      isMinimized: candidate.isMinimized,
      isHidden: candidate.isHidden,
      isFullscreen: candidate.isFullscreen,
      isCurrentWindow: candidate.visibleRank == 0 && isFrontmost(app))
  }

  private var selectedWindowName: String {
    guard candidates.indices.contains(selectedIndex) else { return "" }
    let candidate = candidates[selectedIndex]
    return "\(candidate.app.localizedName ?? "App") · \(candidate.displayTitle)"
  }

  private func isFrontmost(_ app: NSRunningApplication) -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else {
      return app.isActive
    }
    if frontmost.processIdentifier == app.processIdentifier {
      return true
    }
    guard
      let frontBundleID = frontmost.bundleIdentifier,
      let appBundleID = app.bundleIdentifier
    else {
      return false
    }
    return frontBundleID == appBundleID
  }

  private func isSelfApplication(_ app: NSRunningApplication) -> Bool {
    if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
      return true
    }
    guard let bundleID = app.bundleIdentifier,
      let mainBundleID = Bundle.main.bundleIdentifier
    else {
      return false
    }
    return bundleID == mainBundleID
  }

  private func revealWindowToFront(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    focusToken: UInt64
  ) {
    guard isCurrentFocusToken(focusToken, candidate: candidate, reason: "immediate") else {
      return
    }
    if isSelfApplication(candidate.app) {
      revealSelfAppToFront(candidate, focusToken: focusToken)
      return
    }
    logStageManagerCurrentPageRevealStarted(candidate, focusToken: focusToken)
    let immediateTopmost = revealStageManagerCurrentPage(
      candidate,
      reason: "immediate",
      focusToken: focusToken,
      attempt: 0,
      useAXFrontmost: false,
      isFinalAttempt: false)
    if !immediateTopmost {
      AppDiagnostics.log(
        "classic_tab_switcher_no_reopen_app_fallback_suppressed",
        [
          "app": candidate.app.localizedName ?? "App",
          "bundle": candidate.app.bundleIdentifier ?? "",
          "focusToken": "\(focusToken)",
          "reason": "running_window_switch",
          "title": candidate.displayTitle,
          "windowOnly": "true",
          "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
        ])
      _ = recoverFrontmostWithoutReopen(
        candidate,
        reason: "immediate_recovery",
        focusToken: focusToken)
      _ = revealStageManagerCurrentPage(
        candidate,
        reason: "immediate_recovery_current_page",
        focusToken: focusToken,
        attempt: 0,
        useAXFrontmost: true,
        isFinalAttempt: false)
    }
    for (retryIndex, delay) in stageManagerRevealRetryDelays.enumerated() {
      var workItem: DispatchWorkItem?
      let item = DispatchWorkItem { [weak self, candidate] in
        guard let self else { return }
        if let workItem {
          self.removeFocusRetryWorkItem(workItem)
          guard !workItem.isCancelled else { return }
        }
        let reason = "retry_\(String(format: "%.2f", delay))"
        guard self.isCurrentFocusToken(focusToken, candidate: candidate, reason: reason) else {
          return
        }
        guard self.windowRank(for: candidate) != 0 else { return }
        let isFinalAttempt = retryIndex == self.stageManagerRevealRetryDelays.count - 1
        let currentPageTopmost = self.revealStageManagerCurrentPage(
          candidate,
          reason: reason,
          focusToken: focusToken,
          attempt: retryIndex + 1,
          useAXFrontmost: true,
          isFinalAttempt: isFinalAttempt)
        guard !currentPageTopmost else { return }
        _ = self.recoverFrontmostWithoutReopen(
          candidate,
          reason: reason,
          focusToken: focusToken)
        _ = self.revealStageManagerCurrentPage(
          candidate,
          reason: "\(reason)_post_recovery_current_page",
          focusToken: focusToken,
          attempt: retryIndex + 1,
          useAXFrontmost: true,
          isFinalAttempt: isFinalAttempt)
      }
      workItem = item
      focusRetryWorkItems.append(item)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  private func logStageManagerCurrentPageRevealStarted(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    focusToken: UInt64
  ) {
    var payload = [
      "app": candidate.app.localizedName ?? "App",
      "bundle": candidate.app.bundleIdentifier ?? "",
      "focusToken": "\(focusToken)",
      "frontmost": "\(isFrontmost(candidate.app))",
      "targetWindowRank": windowRank(for: candidate).map(String.init) ?? "none",
      "targetWindowTopmost": "\(windowRank(for: candidate) == 0)",
      "title": candidate.displayTitle,
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
    ]
    mergeTopWindowPayload(into: &payload, suffix: "")
    AppDiagnostics.log("classic_tab_stage_manager_reveal_started", payload)
  }

  @discardableResult
  private func revealStageManagerCurrentPage(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    reason: String,
    focusToken: UInt64,
    attempt: Int,
    useAXFrontmost: Bool,
    isFinalAttempt: Bool
  ) -> Bool {
    guard isCurrentFocusToken(focusToken, candidate: candidate, reason: reason) else {
      return false
    }

    let app = candidate.app
    let appElement = axApplicationElement(for: app, timeout: axFocusTimeout)
    let targetWindow = candidate.window ?? fallbackWindow(for: app, appElement: appElement)
    let rankBefore = windowRank(for: candidate)
    let hiddenBefore = app.isHidden
    let minimizedBefore: String
    if let targetWindow {
      minimizedBefore = "\(axBool(targetWindow, attribute: kAXMinimizedAttribute as CFString))"
    } else {
      minimizedBefore = "none"
    }
    var attemptPayload: [String: String] = [
      "app": app.localizedName ?? "App",
      "attempt": "\(attempt)",
      "bundle": app.bundleIdentifier ?? "",
      "focusToken": "\(focusToken)",
      "frontmostBefore": "\(isFrontmost(app))",
      "hiddenBefore": "\(hiddenBefore)",
      "minimizedBefore": minimizedBefore,
      "reason": reason,
      "targetWindowAvailable": "\(targetWindow != nil)",
      "targetWindowRankBefore": rankBefore.map(String.init) ?? "none",
      "targetWindowTopmostBefore": "\(rankBefore == 0)",
      "title": candidate.displayTitle,
      "useAXFrontmost": "\(useAXFrontmost)",
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
    ]
    mergeTopWindowPayload(into: &attemptPayload, suffix: "Before")
    AppDiagnostics.log("classic_tab_stage_manager_reveal_attempt", attemptPayload)

    let topmost = focusCandidateWindow(
      candidate,
      reason: reason,
      focusToken: focusToken,
      useAXFrontmost: useAXFrontmost)

    let rankAfter = windowRank(for: candidate)
    let hiddenAfter = app.isHidden
    let minimizedAfter: String
    if let targetWindow {
      minimizedAfter = "\(axBool(targetWindow, attribute: kAXMinimizedAttribute as CFString))"
    } else {
      minimizedAfter = "none"
    }
    let frontmostAfter = isFrontmost(app)
    let platformLimited = !topmost && (isFinalAttempt || (frontmostAfter && rankAfter != 0))
    var resultPayload: [String: String] = [
      "app": app.localizedName ?? "App",
      "attempt": "\(attempt)",
      "bundle": app.bundleIdentifier ?? "",
      "focusToken": "\(focusToken)",
      "frontmostAfter": "\(frontmostAfter)",
      "hiddenAfter": "\(hiddenAfter)",
      "minimizedAfter": minimizedAfter,
      "platform_limited": "\(platformLimited)",
      "reason": reason,
      "targetWindowRank": rankAfter.map(String.init) ?? "none",
      "targetWindowRankBefore": rankBefore.map(String.init) ?? "none",
      "targetWindowTopmost": "\(rankAfter == 0)",
      "targetWindowTopmostBefore": "\(rankBefore == 0)",
      "title": candidate.displayTitle,
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
    ]
    mergeTopWindowPayload(into: &resultPayload, suffix: "After")
    AppDiagnostics.log("classic_tab_stage_manager_reveal_result", resultPayload)
    if platformLimited {
      var limitedPayload = resultPayload
      limitedPayload["diagnosis"] = "platform_limited"
      limitedPayload["limit"] = "stage_manager_or_space_public_api_limit"
      limitedPayload["noColdStart"] = "true"
      AppDiagnostics.log("classic_tab_stage_manager_reveal_limited", limitedPayload)
      if isFinalAttempt {
        onNotice("这个窗口可能在另一个桌面或受系统窗口管理限制，已尽力切换。")
      }
    }
    return topmost
  }

  private func revealSelfAppToFront(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    focusToken: UInt64
  ) {
    guard isCurrentFocusToken(focusToken, candidate: candidate, reason: "self_app_reveal") else {
      return
    }
    AppDiagnostics.log(
      "classic_tab_switcher_self_app_reveal_started",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "focusToken": "\(focusToken)",
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])

    let requested = revealSelfApp()
    _ = focusCandidateWindow(
      candidate,
      reason: "self_app_reveal_immediate",
      focusToken: focusToken,
      useAXFrontmost: true)
    logSelfAppRevealResult(
      candidate,
      focusToken: focusToken,
      reason: "immediate",
      requested: requested)

    for delay in [0.08, 0.22, 0.50, 0.85] {
      var workItem: DispatchWorkItem?
      let item = DispatchWorkItem { [weak self, candidate] in
        guard let self else { return }
        if let workItem {
          self.removeFocusRetryWorkItem(workItem)
          guard !workItem.isCancelled else { return }
        }
        let reason = "self_retry_\(String(format: "%.2f", delay))"
        guard self.isCurrentFocusToken(focusToken, candidate: candidate, reason: reason) else {
          return
        }
        guard self.windowRank(for: candidate) != 0 else { return }
        let retryRequested = self.revealSelfApp()
        _ = self.focusCandidateWindow(
          candidate,
          reason: reason,
          focusToken: focusToken,
          useAXFrontmost: true)
        self.logSelfAppRevealResult(
          candidate,
          focusToken: focusToken,
          reason: reason,
          requested: retryRequested)
      }
      workItem = item
      focusRetryWorkItems.append(item)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  private func logSelfAppRevealResult(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    focusToken: UInt64,
    reason: String,
    requested: Bool
  ) {
    let rank = windowRank(for: candidate)
    var payload: [String: String] = [
      "app": candidate.app.localizedName ?? "App",
      "bundle": candidate.app.bundleIdentifier ?? "",
      "focusToken": "\(focusToken)",
      "frontmost": "\(isFrontmost(candidate.app))",
      "reason": reason,
      "requested": "\(requested)",
      "targetWindowRank": rank.map(String.init) ?? "none",
      "targetWindowTopmost": "\(rank == 0)",
      "title": candidate.displayTitle,
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
    ]
    for item in topWindowPayload() {
      payload[item.key] = item.value
    }
    AppDiagnostics.log("classic_tab_switcher_self_app_reveal_result", payload)
    if rank == 0 {
      AppDiagnostics.log(
        "classic_tab_switcher_self_app_reveal_topmost",
        payload)
      markFocusOwnerCompleted(candidate: candidate, focusToken: focusToken, reason: reason)
    } else {
      AppDiagnostics.log(
        "classic_tab_switcher_self_app_reveal_limited",
        payload)
    }
  }

  @discardableResult
  private func focusCandidateWindow(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    reason: String,
    focusToken: UInt64,
    useAXFrontmost: Bool = false
  ) -> Bool {
    guard isCurrentFocusToken(focusToken, candidate: candidate, reason: reason) else {
      return false
    }
    let app = candidate.app
    app.unhide()
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let targetWindow = candidate.window ?? fallbackWindow(for: app, appElement: appElement)
    var minimizedBefore = "none"
    var setMinimized = "none"
    var setMain = "none"
    var setFocused = "none"
    var raise = "none"
    var axFrontmostBefore = "skipped"
    var axFrontmostAfter = "skipped"
    var hostHiddenForTarget = "false"
    let usedFallbackWindow = candidate.window == nil && targetWindow != nil

    if useAXFrontmost {
      axFrontmostBefore =
        "\(setAXBool(appElement, attribute: kAXFrontmostAttribute as CFString, value: true))"
    }

    if let window = targetWindow {
      minimizedBefore = "\(axBool(window, attribute: kAXMinimizedAttribute as CFString))"
      setMinimized =
        "\(setAXBool(window, attribute: kAXMinimizedAttribute as CFString, value: false))"
      setMain = "\(setAXBool(window, attribute: kAXMainAttribute as CFString, value: true))"
      setFocused = "\(setAXBool(window, attribute: kAXFocusedAttribute as CFString, value: true))"
      raise = "\(AXUIElementPerformAction(window, kAXRaiseAction as CFString).rawValue)"
    }

    let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    if useAXFrontmost {
      axFrontmostAfter =
        "\(setAXBool(appElement, attribute: kAXFrontmostAttribute as CFString, value: true))"
    }
    if let window = targetWindow {
      _ = setAXBool(window, attribute: kAXMinimizedAttribute as CFString, value: false)
      _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      _ = setAXBool(window, attribute: kAXMainAttribute as CFString, value: true)
      _ = setAXBool(window, attribute: kAXFocusedAttribute as CFString, value: true)
    }
    let windowlessActivationFallback = activateWindowlessFallbackIfNeeded(
      candidate,
      targetWindow: targetWindow,
      reason: reason,
      focusToken: focusToken)
    if useAXFrontmost,
      hideSwitcherHostIfBlockingTarget(candidate, reason: reason, focusToken: focusToken)
    {
      hostHiddenForTarget = "true"
      _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
      _ = setAXBool(appElement, attribute: kAXFrontmostAttribute as CFString, value: true)
      if let window = targetWindow {
        _ = setAXBool(window, attribute: kAXMinimizedAttribute as CFString, value: false)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = setAXBool(window, attribute: kAXMainAttribute as CFString, value: true)
        _ = setAXBool(window, attribute: kAXFocusedAttribute as CFString, value: true)
      }
    }

    let rank = windowRank(for: candidate)
    let topPayload = topWindowPayload()
    var payload: [String: String] = [
      "activated": "\(activated)",
      "app": app.localizedName ?? "App",
      "axFrontmostAfter": axFrontmostAfter,
      "axFrontmostBefore": axFrontmostBefore,
      "bundle": app.bundleIdentifier ?? "",
      "fullscreen": "\(candidate.isFullscreen)",
      "focusToken": "\(focusToken)",
      "hiddenBefore": "\(candidate.isHidden)",
      "hostHiddenForTarget": hostHiddenForTarget,
      "minimizedBefore": minimizedBefore,
      "reason": reason,
      "setFocused": setFocused,
      "setMain": setMain,
      "setMinimized": setMinimized,
      "raise": raise,
      "title": candidate.displayTitle,
      "targetWindowRank": rank.map(String.init) ?? "none",
      "targetWindowTopmost": "\(rank == 0)",
      "windowlessActivationFallback": windowlessActivationFallback,
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      "usedFallbackWindow": "\(usedFallbackWindow)",
    ]
    for item in topPayload {
      payload[item.key] = item.value
    }
    AppDiagnostics.log("classic_tab_switcher_window_focus", payload)

    if rank == 0 {
      AppDiagnostics.log(
        "classic_tab_switcher_target_window_topmost",
        [
          "app": app.localizedName ?? "App",
          "bundle": app.bundleIdentifier ?? "",
          "focusToken": "\(focusToken)",
          "reason": reason,
          "title": candidate.displayTitle,
          "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
        ])
      markFocusOwnerCompleted(candidate: candidate, focusToken: focusToken, reason: reason)
    }

    if rank != 0 {
      AppDiagnostics.log(
        "classic_tab_switcher_window_focus_limited",
        [
          "app": app.localizedName ?? "App",
          "bundle": app.bundleIdentifier ?? "",
          "fullscreen": "\(candidate.isFullscreen)",
          "reason": reason,
          "targetWindowRank": rank.map(String.init) ?? "none",
          "title": candidate.displayTitle,
        ])
    }

    return rank == 0
  }

  private func activateWindowlessFallbackIfNeeded(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    targetWindow: AXUIElement?,
    reason: String,
    focusToken: UInt64
  ) -> String {
    guard
      isCurrentFocusToken(focusToken, candidate: candidate, reason: "\(reason)_windowless")
    else {
      return "stale"
    }
    let app = candidate.app
    let rankBefore = windowRank(for: candidate)
    guard rankBefore != 0 else {
      return "already_topmost"
    }
    let fallbackReason: String
    if targetWindow == nil {
      fallbackReason = "missing_ax_window"
    } else if candidate.windowNumber == nil {
      fallbackReason = "missing_window_number"
    } else if rankBefore == nil {
      fallbackReason = "missing_visible_rank"
    } else {
      return "not_needed"
    }
    let frontmostBefore = isFrontmost(app)
    let bundleID = app.bundleIdentifier ?? ""
    AppDiagnostics.log(
      "classic_tab_switcher_windowless_activation_started",
      [
        "app": app.localizedName ?? "App",
        "bundle": bundleID,
        "focusToken": "\(focusToken)",
        "frontmostBefore": "\(frontmostBefore)",
        "fallbackReason": fallbackReason,
        "reason": reason,
        "targetWindowRankBefore": rankBefore.map(String.init) ?? "none",
        "targetWindowAvailable": "\(targetWindow != nil)",
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])

    app.unhide()
    let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    let axFrontmost = setAXBool(
      axApplicationElement(for: app, timeout: axFocusTimeout),
      attribute: kAXFrontmostAttribute as CFString,
      value: true)
    let appleScriptScheduled = activateRunningAppThroughAppleScript(app) {
      [weak self, weak app] appleScriptOK in
      guard let self, let app,
        self.isCurrentFocusToken(
          focusToken, candidate: candidate, reason: "\(reason)_applescript_completion")
      else { return }
      let rankAfterAppleScript = self.windowRank(for: candidate)
      AppDiagnostics.log(
        "classic_tab_switcher_windowless_applescript_result",
        [
          "app": app.localizedName ?? "App",
          "appleScriptOK": "\(appleScriptOK)",
          "bundle": bundleID,
          "focusToken": "\(focusToken)",
          "reason": reason,
          "targetWindowRankAfter": rankAfterAppleScript.map(String.init) ?? "none",
        ])
      if rankAfterAppleScript == 0 {
        self.markFocusOwnerCompleted(candidate: candidate, focusToken: focusToken, reason: reason)
      }
    }
    let rankAfter = windowRank(for: candidate)
    let frontmostAfter = isFrontmost(app)
    AppDiagnostics.log(
      "classic_tab_switcher_windowless_activation_result",
      [
        "activated": "\(activated)",
        "app": app.localizedName ?? "App",
        "appleScriptScheduled": "\(appleScriptScheduled)",
        "axFrontmost": "\(axFrontmost)",
        "bundle": bundleID,
        "focusToken": "\(focusToken)",
        "frontmostAfter": "\(frontmostAfter)",
        "frontmostBefore": "\(frontmostBefore)",
        "fallbackReason": fallbackReason,
        "reason": reason,
        "targetWindowRankAfter": rankAfter.map(String.init) ?? "none",
        "targetWindowRankBefore": rankBefore.map(String.init) ?? "none",
        "targetWindowTopmost": "\(rankAfter == 0)",
        "targetWindowAvailable": "\(targetWindow != nil)",
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])
    if rankAfter == 0 {
      markFocusOwnerCompleted(candidate: candidate, focusToken: focusToken, reason: reason)
    }
    if rankAfter == 0 {
      return "topmost"
    }
    if frontmostAfter {
      return "frontmost_only"
    }
    return "limited"
  }

  @discardableResult
  private func recoverFrontmostWithoutReopen(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    reason: String,
    focusToken: UInt64
  ) -> Bool {
    guard isCurrentFocusToken(focusToken, candidate: candidate, reason: reason) else {
      return false
    }
    AppDiagnostics.log(
      "classic_tab_switcher_no_reopen_frontmost_recovery_started",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "focusToken": "\(focusToken)",
        "reason": reason,
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])
    let recovered = focusCandidateWindow(
      candidate,
      reason: reason,
      focusToken: focusToken,
      useAXFrontmost: true)
    let rank = windowRank(for: candidate)
    var payload: [String: String] = [
      "app": candidate.app.localizedName ?? "App",
      "bundle": candidate.app.bundleIdentifier ?? "",
      "focusToken": "\(focusToken)",
      "frontmost": "\(isFrontmost(candidate.app))",
      "reason": reason,
      "recovered": "\(recovered)",
      "targetWindowRank": rank.map(String.init) ?? "none",
      "targetWindowTopmost": "\(rank == 0)",
      "title": candidate.displayTitle,
      "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
    ]
    for item in topWindowPayload() {
      payload[item.key] = item.value
    }
    AppDiagnostics.log("classic_tab_switcher_no_reopen_frontmost_recovery_result", payload)
    if !recovered {
      AppDiagnostics.log(
        "classic_tab_switcher_no_reopen_frontmost_recovery_limited",
        payload)
    }
    return recovered
  }

  private func hideSwitcherHostIfBlockingTarget(
    _ candidate: ClassicTabSwitcherWindowCandidate,
    reason: String,
    focusToken: UInt64
  ) -> Bool {
    guard candidate.app.bundleIdentifier != Bundle.main.bundleIdentifier else {
      return false
    }
    guard let top = standardVisibleWindowInfos().first,
      windowInfoPID(top) == ProcessInfo.processInfo.processIdentifier
    else {
      return false
    }
    NSApp.hide(nil)
    AppDiagnostics.log(
      "classic_tab_switcher_no_reopen_host_hidden_for_target",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "focusToken": "\(focusToken)",
        "reason": reason,
        "title": candidate.displayTitle,
        "topOwner": windowInfoOwner(top),
        "topPID": windowInfoPID(top).map(String.init) ?? "none",
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])
    return true
  }

  private func startFocusToken(
    for candidate: ClassicTabSwitcherWindowCandidate,
    eventID: UInt64
  ) -> UInt64 {
    cancelFocusRetryWorkItems(reason: "new_focus_owner")
    if currentFocusToken != 0 {
      AppDiagnostics.log(
        "classic_tab_foreground_repair_previous_owner_cancelled",
        [
          "app": candidate.app.localizedName ?? "App",
          "bundle": candidate.app.bundleIdentifier ?? "",
          "previousFocusToken": "\(currentFocusToken)",
          "reason": "new_focus_owner",
          "title": candidate.displayTitle,
        ])
    }
    focusTokenSequence &+= 1
    currentFocusToken = focusTokenSequence
    currentFocusCandidate = candidate
    currentFocusStartedAt = ProcessInfo.processInfo.systemUptime
    completedFocusTokens.removeAll()
    AppDiagnostics.log(
      "classic_tab_switcher_focus_token_started",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "eventID": "\(eventID)",
        "focusToken": "\(currentFocusToken)",
        "title": candidate.displayTitle,
      ])
    AppDiagnostics.log(
      "classic_tab_switcher_window_only_focus_owner_started",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "eventID": "\(eventID)",
        "focusToken": "\(currentFocusToken)",
        "mode": "no_reopen",
        "title": candidate.displayTitle,
        "windowNumber": candidate.windowNumber.map(String.init) ?? "none",
      ])
    AppDiagnostics.log(
      "classic_tab_foreground_repair_owner_started",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "eventID": "\(eventID)",
        "focusToken": "\(currentFocusToken)",
        "title": candidate.displayTitle,
      ])
    return currentFocusToken
  }

  private func invalidateFocusToken(reason: String) {
    guard currentFocusToken != 0 else { return }
    let staleToken = currentFocusToken
    currentFocusToken = 0
    currentFocusCandidate = nil
    currentFocusStartedAt = 0
    cancelFocusRetryWorkItems(reason: reason)
    AppDiagnostics.log(
      "classic_tab_switcher_focus_token_invalidated",
      ["focusToken": "\(staleToken)", "reason": reason])
  }

  private func isCurrentFocusToken(
    _ focusToken: UInt64,
    candidate: ClassicTabSwitcherWindowCandidate,
    reason: String
  ) -> Bool {
    guard currentFocusToken == focusToken else {
      AppDiagnostics.log(
        "classic_tab_switcher_stale_focus_retry_ignored",
        [
          "app": candidate.app.localizedName ?? "App",
          "bundle": candidate.app.bundleIdentifier ?? "",
          "currentFocusToken": "\(currentFocusToken)",
          "focusToken": "\(focusToken)",
          "reason": reason,
          "title": candidate.displayTitle,
        ])
      AppDiagnostics.log(
        "classic_tab_foreground_repair_stale_ignored",
        [
          "app": candidate.app.localizedName ?? "App",
          "bundle": candidate.app.bundleIdentifier ?? "",
          "currentFocusToken": "\(currentFocusToken)",
          "focusToken": "\(focusToken)",
          "reason": reason,
          "title": candidate.displayTitle,
        ])
      return false
    }
    return true
  }

  private func cancelFocusRetryWorkItems(reason: String) {
    let count = focusRetryWorkItems.count
    guard count > 0 else { return }
    for item in focusRetryWorkItems {
      item.cancel()
    }
    focusRetryWorkItems.removeAll()
    AppDiagnostics.log(
      "classic_tab_foreground_repair_pending_cancelled",
      ["count": "\(count)", "focusToken": "\(currentFocusToken)", "reason": reason])
  }

  private func removeFocusRetryWorkItem(_ workItem: DispatchWorkItem) {
    focusRetryWorkItems.removeAll { $0 === workItem }
  }

  private func markFocusOwnerCompleted(
    candidate: ClassicTabSwitcherWindowCandidate,
    focusToken: UInt64,
    reason: String
  ) {
    guard currentFocusToken == focusToken, !completedFocusTokens.contains(focusToken) else {
      return
    }
    completedFocusTokens.insert(focusToken)
    AppDiagnostics.log(
      "classic_tab_foreground_repair_owner_completed",
      [
        "app": candidate.app.localizedName ?? "App",
        "bundle": candidate.app.bundleIdentifier ?? "",
        "focusToken": "\(focusToken)",
        "reason": reason,
        "title": candidate.displayTitle,
      ])
  }

  private func cancelFocusAfterPostCommitActivationChange(_ activatedApp: NSRunningApplication) {
    guard currentFocusToken != 0, let candidate = currentFocusCandidate else { return }
    guard !sameApplication(activatedApp, candidate.app) else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - currentFocusStartedAt
    guard elapsed >= postCommitUserInterventionGrace else {
      let focusToken = currentFocusToken
      AppDiagnostics.log(
        "classic_tab_post_commit_user_interaction_deferred",
        [
          "activeApp": activatedApp.localizedName ?? "App",
          "activeBundle": activatedApp.bundleIdentifier ?? "",
          "elapsed": String(format: "%.3f", elapsed),
          "focusToken": "\(focusToken)",
          "grace": String(format: "%.3f", postCommitUserInterventionGrace),
          "targetApp": candidate.app.localizedName ?? "App",
          "targetBundle": candidate.app.bundleIdentifier ?? "",
          "title": candidate.displayTitle,
        ])
      DispatchQueue.main.asyncAfter(
        deadline: .now() + max(0.02, postCommitUserInterventionGrace - elapsed)
      ) { [weak self, weak activatedApp] in
        guard let self, let activatedApp else { return }
        guard self.currentFocusToken == focusToken else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
          self.sameApplication(frontmost, activatedApp)
        else {
          return
        }
        self.cancelFocusAfterPostCommitActivationChange(activatedApp)
      }
      return
    }
    AppDiagnostics.log(
      "classic_tab_post_commit_user_interaction_cancelled",
      [
        "activeApp": activatedApp.localizedName ?? "App",
        "activeBundle": activatedApp.bundleIdentifier ?? "",
        "activePID": "\(activatedApp.processIdentifier)",
        "elapsed": String(format: "%.3f", elapsed),
        "focusToken": "\(currentFocusToken)",
        "grace": String(format: "%.3f", postCommitUserInterventionGrace),
        "targetApp": candidate.app.localizedName ?? "App",
        "targetBundle": candidate.app.bundleIdentifier ?? "",
        "targetPID": "\(candidate.app.processIdentifier)",
        "title": candidate.displayTitle,
      ])
    cancelAppForegroundRepair(candidate.app, "post_commit_user_interaction")
    invalidateFocusToken(reason: "post_commit_user_interaction")
  }

  private func sameApplication(
    _ lhs: NSRunningApplication,
    _ rhs: NSRunningApplication
  ) -> Bool {
    if lhs.processIdentifier == rhs.processIdentifier {
      return true
    }
    guard let leftBundle = lhs.bundleIdentifier, let rightBundle = rhs.bundleIdentifier else {
      return false
    }
    return leftBundle == rightBundle
  }

  private func setAXBool(_ element: AXUIElement, attribute: CFString, value: Bool) -> Int32 {
    let rawValue = (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
    return AXUIElementSetAttributeValue(element, attribute, rawValue).rawValue
  }

  @discardableResult
  private func activateRunningAppThroughAppleScript(
    _ app: NSRunningApplication,
    completion: @escaping (Bool) -> Void
  ) -> Bool {
    guard let bundleID = app.bundleIdentifier else {
      completion(false)
      return false
    }
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
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-e", script],
      timeout: 2,
      outputByteLimit: 32_768
    ) { result in
      completion(result.succeeded)
    }.start()
    return true
  }

  private func windowRank(for candidate: ClassicTabSwitcherWindowCandidate) -> Int? {
    let visibleInfos = standardVisibleWindowInfos()
    if let windowNumber = candidate.windowNumber,
      let index = visibleInfos.firstIndex(where: {
        numberValue($0[kCGWindowNumber as String])?.intValue == windowNumber
      })
    {
      return index
    }
    let normalizedTitle = normalizedWindowTitle(candidate.displayTitle)
    if !normalizedTitle.isEmpty,
      let index = visibleInfos.firstIndex(where: {
        windowInfoPID($0) == candidate.app.processIdentifier
          && normalizedWindowTitle(windowInfoTitle($0)) == normalizedTitle
      })
    {
      return index
    }
    return visibleInfos.firstIndex { windowInfoPID($0) == candidate.app.processIdentifier }
  }

  private func topWindowPayload() -> [String: String] {
    let visibleInfos = standardVisibleWindowInfos()
    guard let top = visibleInfos.first else {
      return ["topOwner": "", "topPID": "none", "topTitle": ""]
    }
    return [
      "topOwner": windowInfoOwner(top),
      "topPID": windowInfoPID(top).map(String.init) ?? "none",
      "topTitle": windowInfoTitle(top),
    ]
  }

  private func mergeTopWindowPayload(into payload: inout [String: String], suffix: String) {
    let topPayload = topWindowPayload()
    payload["topOwner\(suffix)"] = topPayload["topOwner"] ?? ""
    payload["topPID\(suffix)"] = topPayload["topPID"] ?? "none"
    payload["topTitle\(suffix)"] = topPayload["topTitle"] ?? ""
  }

  private func keyDiagnosticPayload(
    flags: CGEventFlags,
    autorepeat: Int64,
    eventID: UInt64,
    matched: Bool,
    trigger: TriggerModifier?,
    direction: TabDirection
  ) -> [String: String] {
    [
      "autorepeat": "\(autorepeat)",
      "commandMatched": "\(trigger == .command)",
      "command": "\(flags.contains(.maskCommand))",
      "commandTakeover": "\(capturesCommandTab)",
      "control": "\(flags.contains(.maskControl))",
      "direction": direction.rawValue,
      "eventID": "\(eventID)",
      "matched": "\(matched)",
      "optionMatched": "\(trigger == .option)",
      "option": "\(flags.contains(.maskAlternate))",
      "secureInput": "\(secureInputEnabled())",
      "session": "\(isSessionActive)",
      "shift": "\(flags.contains(.maskShift))",
      "trigger": trigger?.rawValue ?? "none",
    ]
  }

  private func secureInputEnabled() -> Bool {
    IsSecureEventInputEnabled()
  }

  private func startWorkspaceObserver() {
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else {
        return
      }
      self?.recordActivation(app)
    }
  }

  private func seedFrontmostApplication() {
    if let app = NSWorkspace.shared.frontmostApplication {
      recordActivation(app)
    }
  }

  private func recordActivation(_ app: NSRunningApplication) {
    cancelFocusAfterPostCommitActivationChange(app)
    guard let bundleID = app.bundleIdentifier else { return }
    lastActivatedBundleIDs.removeAll { $0 == bundleID }
    lastActivatedBundleIDs.insert(bundleID, at: 0)
    if lastActivatedBundleIDs.count > 16 {
      lastActivatedBundleIDs.removeLast(lastActivatedBundleIDs.count - 16)
    }
    if isRunning, !isSessionActive, !pendingSessionStart, !commitInProgress,
      !candidateRefreshInFlight, !candidateCacheIsFresh(maxAge: 0.6)
    {
      refreshCandidateCache(reason: "activation")
    }
  }

  private func reenableEventTap(reason: String) {
    guard let eventTap else { return }
    CGEvent.tapEnable(tap: eventTap, enable: true)
    AppDiagnostics.log("classic_tab_switcher_eventtap_reenabled", ["reason": reason])
    DispatchQueue.main.async {
      self.onNotice("内置窗口切换监听已自动恢复。")
    }
  }

  private func requestListenEventAccessIfNeeded() -> Bool {
    guard #available(macOS 10.15, *) else { return true }
    let preflight = CGPreflightListenEventAccess()
    AppDiagnostics.log(
      "classic_tab_switcher_input_monitoring_preflight",
      ["granted": "\(preflight)"])
    return preflight
  }
}

private final class ClassicTabSwitcherWindowCandidate {
  let id: String
  let app: NSRunningApplication
  let icon: NSImage?
  let window: AXUIElement?
  let windowTitle: String
  let windowNumber: Int?
  let visibleRank: Int?
  let isMinimized: Bool
  let isHidden: Bool
  let isFullscreen: Bool

  init(
    id: String,
    app: NSRunningApplication,
    icon: NSImage?,
    window: AXUIElement?,
    windowTitle: String,
    windowNumber: Int?,
    visibleRank: Int?,
    isMinimized: Bool,
    isHidden: Bool,
    isFullscreen: Bool
  ) {
    self.id = id
    self.app = app
    self.icon = icon
    self.window = window
    self.windowTitle = windowTitle
    self.windowNumber = windowNumber
    self.visibleRank = visibleRank
    self.isMinimized = isMinimized
    self.isHidden = isHidden
    self.isFullscreen = isFullscreen
  }

  var displayTitle: String {
    let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? (app.localizedName ?? "窗口") : trimmed
  }
}
