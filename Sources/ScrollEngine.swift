import AppKit
import ApplicationServices
import CoreAudio
import Darwin
import Foundation
import IOKit.hid

private let hotCornerBoundaryTolerance: CGFloat = 4
private let scrollWheelEventIsContinuousField = CGEventField(rawValue: 88)!

private func screenContainingPoint(
  _ point: NSPoint,
  tolerance: CGFloat = hotCornerBoundaryTolerance
) -> NSScreen? {
  let screens = NSScreen.screens
  let boundaryMatches = screens.filter {
    pointIsInside(point, rect: $0.frame, tolerance: tolerance)
  }
  if let screen = boundaryMatches.min(by: {
    distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame)
  }) {
    return screen
  }

  return screens.min(by: {
    distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame)
  }) ?? NSScreen.main
}

private func pointIsInside(_ point: NSPoint, rect: NSRect, tolerance: CGFloat) -> Bool {
  point.x >= rect.minX - tolerance
    && point.x <= rect.maxX + tolerance
    && point.y >= rect.minY - tolerance
    && point.y <= rect.maxY + tolerance
}

private func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
  let dx: CGFloat
  if point.x < rect.minX {
    dx = rect.minX - point.x
  } else if point.x > rect.maxX {
    dx = point.x - rect.maxX
  } else {
    dx = 0
  }

  let dy: CGFloat
  if point.y < rect.minY {
    dy = rect.minY - point.y
  } else if point.y > rect.maxY {
    dy = point.y - rect.maxY
  } else {
    dy = 0
  }

  return dx * dx + dy * dy
}

private func pointIsInTopRightBand(
  _ point: NSPoint,
  screenFrame: NSRect,
  width: CGFloat,
  height: CGFloat,
  tolerance: CGFloat = hotCornerBoundaryTolerance
) -> Bool {
  point.x >= screenFrame.maxX - width - tolerance
    && point.x <= screenFrame.maxX + tolerance
    && point.y >= screenFrame.maxY - height - tolerance
    && point.y <= screenFrame.maxY + tolerance
}

private func pointIsInQuartzTopRightBand(
  _ point: CGPoint,
  displayBounds: CGRect,
  width: CGFloat,
  height: CGFloat,
  tolerance: CGFloat = hotCornerBoundaryTolerance
) -> Bool {
  point.x >= displayBounds.maxX - width - tolerance
    && point.x <= displayBounds.maxX + tolerance
    && point.y >= displayBounds.minY - tolerance
    && point.y <= displayBounds.minY + height + tolerance
}

private func quartzDisplayBounds(for screen: NSScreen) -> CGRect? {
  guard
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  else {
    return nil
  }
  return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
}

struct ScrollEngineSettings: Codable, Equatable {
  var enabled: Bool
  var reverseVertical: Bool
  var reverseHorizontal: Bool
  var smooth: Bool
  var affectTrackpad: Bool
  var speed: Double
  var step: Double
  var duration: Double
  var volumeHotCornerEnabled: Bool
  var volumeHotCornerWidthRatio: Double
  var volumeHotCornerHeightRatio: Double
  var volumeStep: Double

  enum CodingKeys: String, CodingKey {
    case enabled
    case reverseVertical
    case reverseHorizontal
    case smooth
    case affectTrackpad
    case speed
    case step
    case duration
    case volumeHotCornerEnabled
    case volumeHotCornerWidthRatio
    case volumeHotCornerHeightRatio
    case volumeStep
  }

  init(
    enabled: Bool,
    reverseVertical: Bool,
    reverseHorizontal: Bool,
    smooth: Bool,
    affectTrackpad: Bool,
    speed: Double,
    step: Double,
    duration: Double,
    volumeHotCornerEnabled: Bool = false,
    volumeHotCornerWidthRatio: Double = 0.14,
    volumeHotCornerHeightRatio: Double = 0.16,
    volumeStep: Double = 2.0
  ) {
    self.enabled = enabled
    self.reverseVertical = reverseVertical
    self.reverseHorizontal = reverseHorizontal
    self.smooth = smooth
    self.affectTrackpad = affectTrackpad
    self.speed = speed
    self.step = step
    self.duration = duration
    self.volumeHotCornerEnabled = volumeHotCornerEnabled
    self.volumeHotCornerWidthRatio = Self.clamped(volumeHotCornerWidthRatio, 0.12...0.50)
    self.volumeHotCornerHeightRatio = Self.clamped(volumeHotCornerHeightRatio, 0.08...0.42)
    self.volumeStep = Self.clamped(volumeStep, 0.5...8.0)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
      reverseVertical: try container.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? true,
      reverseHorizontal: try container.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? true,
      smooth: try container.decodeIfPresent(Bool.self, forKey: .smooth) ?? false,
      affectTrackpad: try container.decodeIfPresent(Bool.self, forKey: .affectTrackpad) ?? false,
      speed: try container.decodeIfPresent(Double.self, forKey: .speed) ?? 2.7,
      step: try container.decodeIfPresent(Double.self, forKey: .step) ?? 33.6,
      duration: try container.decodeIfPresent(Double.self, forKey: .duration) ?? 4.35,
      volumeHotCornerEnabled: try container.decodeIfPresent(
        Bool.self, forKey: .volumeHotCornerEnabled) ?? false,
      volumeHotCornerWidthRatio: try container.decodeIfPresent(
        Double.self, forKey: .volumeHotCornerWidthRatio) ?? 0.14,
      volumeHotCornerHeightRatio: try container.decodeIfPresent(
        Double.self, forKey: .volumeHotCornerHeightRatio) ?? 0.16,
      volumeStep: try container.decodeIfPresent(Double.self, forKey: .volumeStep) ?? 2.0)
  }

  private static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  static let defaults = ScrollEngineSettings(
    enabled: false,
    reverseVertical: true,
    reverseHorizontal: true,
    smooth: true,
    affectTrackpad: false,
    speed: 2.7,
    step: 33.6,
    duration: 4.35,
    volumeHotCornerEnabled: false,
    volumeHotCornerWidthRatio: 0.14,
    volumeHotCornerHeightRatio: 0.16,
    volumeStep: 2.0)

  static let mosPreset = ScrollEngineSettings(
    enabled: true,
    reverseVertical: true,
    reverseHorizontal: true,
    smooth: true,
    affectTrackpad: false,
    speed: 2.7,
    step: 33.6,
    duration: 4.35,
    volumeHotCornerEnabled: false,
    volumeHotCornerWidthRatio: 0.14,
    volumeHotCornerHeightRatio: 0.16,
    volumeStep: 2.0)

  var needsEventTap: Bool {
    enabled || volumeHotCornerEnabled
  }

  mutating func enforceMouseWheelOnlyWindowsHabit() {
    reverseVertical = true
    reverseHorizontal = true
    affectTrackpad = false
  }

  static func fromLegacyProfile(_ profile: LegacyScrollProfile) -> ScrollEngineSettings {
    guard profile.profileFound else {
      var settings = defaults
      settings.enforceMouseWheelOnlyWindowsHabit()
      return settings
    }
    var settings = ScrollEngineSettings(
      enabled: defaults.enabled,
      reverseVertical: profile.reverse,
      reverseHorizontal: profile.reverse,
      smooth: profile.smooth,
      affectTrackpad: false,
      speed: profile.speed ?? defaults.speed,
      step: profile.step ?? defaults.step,
      duration: profile.duration ?? defaults.duration,
      volumeHotCornerEnabled: defaults.volumeHotCornerEnabled,
      volumeHotCornerWidthRatio: defaults.volumeHotCornerWidthRatio,
      volumeHotCornerHeightRatio: defaults.volumeHotCornerHeightRatio,
      volumeStep: defaults.volumeStep)
    settings.enforceMouseWheelOnlyWindowsHabit()
    return settings
  }
}

private struct ScrollEventTraits {
  let instantMouser: Bool
  let isContinuous: Bool
  let phase: Int64
  let momentumPhase: Int64
  let lineVertical: Int64
  let lineHorizontal: Int64
  let pointVertical: Int64
  let pointHorizontal: Int64
  let fixedVertical: Double
  let fixedHorizontal: Double

  init(event: CGEvent) {
    instantMouser = event.getIntegerValueField(.scrollWheelEventInstantMouser) != 0
    isContinuous = event.getIntegerValueField(scrollWheelEventIsContinuousField) != 0
    phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    lineVertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    lineHorizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    pointVertical = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    pointHorizontal = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    fixedVertical = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    fixedHorizontal = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
  }

  var hasLineDelta: Bool {
    lineVertical != 0 || lineHorizontal != 0
  }

  var hasPointDelta: Bool {
    pointVertical != 0 || pointHorizontal != 0
  }

  var hasFixedDelta: Bool {
    fixedVertical != 0 || fixedHorizontal != 0
  }

  var hasPixelDelta: Bool {
    hasPointDelta || hasFixedDelta
  }

  var hasScrollPhase: Bool {
    phase != 0
  }

  var hasMomentumPhase: Bool {
    momentumPhase != 0
  }
}

/// All cross-thread event-tap lifecycle fields live behind one lock. Callbacks and the watchdog
/// receive an immutable settings snapshot tied to the exact generation that owns the port.
final class ScrollEngineEventTapState: @unchecked Sendable {
  struct Snapshot {
    let generation: UInt64
    let settings: ScrollEngineSettings
    let tap: CFMachPort
    let tapLocation: CGEventTapLocation
    let isRunning: Bool
  }

  struct StopResources {
    let tap: CFMachPort?
    let source: CFRunLoopSource?
    let runLoop: CFRunLoop?
    let wasRunning: Bool
  }

  private let lock = NSRecursiveLock()
  private var generation: UInt64 = 0
  private var activeGeneration: UInt64?
  private var settings = ScrollEngineSettings.defaults
  private var tap: CFMachPort?
  private var tapLocation: CGEventTapLocation = .cghidEventTap
  private var source: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var thread: Thread?
  private var running = false
  private var lastTapCallbackAt: TimeInterval = 0
  private var lastOverlayCallbackAt: TimeInterval = 0

  func beginStart(settings: ScrollEngineSettings) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    activeGeneration = generation
    self.settings = settings
    tap = nil
    source = nil
    runLoop = nil
    thread = nil
    running = false
    return generation
  }

  func installTap(
    _ tap: CFMachPort,
    location: CGEventTapLocation,
    generation expected: UInt64
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == expected else { return false }
    self.tap = tap
    tapLocation = location
    return true
  }

  func attach(
    source: CFRunLoopSource?,
    runLoop: CFRunLoop,
    thread: Thread,
    generation expected: UInt64
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == expected, tap != nil else { return false }
    self.source = source
    self.runLoop = runLoop
    self.thread = thread
    return true
  }

  func markRunning(generation expected: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == expected, tap != nil else { return false }
    running = true
    return true
  }

  func snapshot(for expected: UInt64) -> Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == expected, running, let tap else { return nil }
    return Snapshot(
      generation: expected,
      settings: settings,
      tap: tap,
      tapLocation: tapLocation,
      isRunning: true)
  }

  func currentSnapshot() -> Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard let activeGeneration, running, let tap else { return nil }
    return Snapshot(
      generation: activeGeneration,
      settings: settings,
      tap: tap,
      tapLocation: tapLocation,
      isRunning: true)
  }

  func withSnapshot<T>(
    for expected: UInt64,
    _ operation: (Snapshot) -> T
  ) -> T? {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == expected, running, let tap else { return nil }
    return operation(Snapshot(
      generation: expected,
      settings: settings,
      tap: tap,
      tapLocation: tapLocation,
      isRunning: true))
  }

  func withCurrentSnapshot<T>(_ operation: (Snapshot) -> T) -> T? {
    lock.lock()
    defer { lock.unlock() }
    guard let activeGeneration, running, let tap else { return nil }
    return operation(Snapshot(
      generation: activeGeneration,
      settings: settings,
      tap: tap,
      tapLocation: tapLocation,
      isRunning: true))
  }

  func beginStop() -> StopResources {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    activeGeneration = nil
    let resources = StopResources(
      tap: tap,
      source: source,
      runLoop: runLoop,
      wasRunning: running)
    tap = nil
    source = nil
    runLoop = nil
    thread = nil
    running = false
    return resources
  }

  func recordTapCallback(at time: TimeInterval) {
    lock.lock()
    lastTapCallbackAt = time
    lock.unlock()
  }

  func recordOverlayCallback(at time: TimeInterval) {
    lock.lock()
    lastOverlayCallbackAt = time
    lock.unlock()
  }

  func callbackTimes() -> (tap: TimeInterval, overlay: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    return (lastTapCallbackAt, lastOverlayCallbackAt)
  }
}

private final class ScrollEngineEventTapContext: @unchecked Sendable {
  weak var engine: ScrollEngine?
  let generation: UInt64
  let settings: ScrollEngineSettings

  init(engine: ScrollEngine, generation: UInt64, settings: ScrollEngineSettings) {
    self.engine = engine
    self.generation = generation
    self.settings = settings
  }
}

final class ScrollEngine {
  private let eventTapState = ScrollEngineEventTapState()
  private var eventTapWatchdogTimer: DispatchSourceTimer?
  private var eventTapWatchdogGeneration: UInt64?
  private var volumeGlobalScrollMonitor: Any?
  private var volumeHIDWheelManagers: [IOHIDManager] = []
  private var volumeHotCornerOverlay: VolumeHotCornerOverlay?
  private let eventTapWatchdogQueue = DispatchQueue(
    label: "\(AppRuntimeIdentity.current.notificationNamespace).scroll-eventtap-watchdog")
  private var settings = ScrollEngineSettings.defaults
  private let syntheticPostingLock = NSLock()
  private var syntheticPostingDepth = 0
  private let syntheticEventMarker: Int64 = 0x584C_4753_6372_6F6C
  private let volumeController = SystemVolumeController()
  private let volumeAlert = SystemVolumeSettingsAlert()
  private let volumeHUD = VolumeOverlayHUD()
  private let onNotice: (String) -> Void
  private var pendingVolumeDelta = 0.0
  private var volumeFlushScheduled = false
  private var lastScrollFailureNoticeAt: TimeInterval = 0
  private var lastScrollDecisionLogAt: TimeInterval = 0
  private var lastHotCornerMissLogAt: TimeInterval = 0
  private var lastHotCornerHitLogAt: TimeInterval = 0
  private var lastEventTapCallbackLogAt: TimeInterval = 0
  private var lastGlobalMonitorLogAt: TimeInterval = 0
  private var lastGlobalMonitorCallbackAt: TimeInterval = 0
  private var lastHIDWheelHandledAt: TimeInterval = 0
  private var lastOverlayLogAt: TimeInterval = 0
  private var lastHIDValueCallbackLogAt: TimeInterval = 0
  private var hidDeviceLogCount = 0
  private let smoothScrollQueue = DispatchQueue(
    label: "\(AppRuntimeIdentity.current.notificationNamespace).smooth-scroll",
    qos: .userInteractive)
  private let smoothScrollQueueKey = DispatchSpecificKey<UInt8>()
  private var smoothScrollTimer: DispatchSourceTimer?
  private var smoothScrollSource: CGEventSource?
  private var smoothScrollTapLocation: CGEventTapLocation = .cghidEventTap
  private var smoothScrollCurrent = (x: 0.0, y: 0.0)
  private var smoothScrollBuffer = (x: 0.0, y: 0.0)
  private var smoothScrollDelta = (x: 0.0, y: 0.0)
  private var smoothScrollRemainder = (x: 0.0, y: 0.0)
  private var smoothScrollTransition = 0.09
  private var smoothScrollDeadZone = 0.8
  private var smoothScrollQueuedInputs = 0
  private var smoothScrollCoalescedInputs = 0
  private var smoothScrollGeneratedEvents = 0
  private var smoothScrollDroppedFrames = 0
  private var smoothScrollFrameCount = 0
  private var smoothScrollSlowFrames = 0
  private var smoothScrollZeroOutputFrames = 0
  private var smoothScrollFrameIntervalTotal: TimeInterval = 0
  private var smoothScrollMaxFrameInterval: TimeInterval = 0
  private var smoothScrollLastFrameAt: TimeInterval?
  private var smoothScrollLastStatsLogAt: TimeInterval = 0
  private var smoothScrollLastInputLogAt: TimeInterval = 0
  private var smoothScrollLastPostLogAt: TimeInterval = 0

  var isRunning: Bool { eventTapState.currentSnapshot()?.isRunning == true }

  init(onNotice: @escaping (String) -> Void) {
    self.onNotice = onNotice
    smoothScrollQueue.setSpecific(key: smoothScrollQueueKey, value: 1)
  }

  deinit {
    stop()
  }

  func start(settings: ScrollEngineSettings) -> Bool {
    self.settings = settings
    if !settings.smooth {
      cancelSmoothScroll()
    }
    logLifecycle("scroll_start_request", settings: settings)
    stopVolumeHotCornerOverlay()
    stopVolumeGlobalScrollMonitor()
    stopVolumeHIDWheelMonitor()
    guard settings.needsEventTap else {
      logLifecycle("scroll_start_no_eventtap_needed", settings: settings)
      stop()
      return true
    }
    guard AXIsProcessTrusted() else {
      logLifecycle("scroll_start_denied_ax", settings: settings)
      stop()
      onNotice("鼠标滚动或鼠标音量需要完成系统授权，请在 App 中点“立即授权”。")
      return false
    }
    guard requestListenEventAccessIfNeeded(settings: settings) else {
      logLifecycle("scroll_start_denied_input_monitoring", settings: settings)
      stop()
      onNotice("鼠标音量需要完成系统授权，请在 App 中点“立即授权”。")
      return false
    }
    if let active = eventTapState.currentSnapshot(), active.settings == settings {
      logLifecycle("scroll_start_already_running", settings: settings)
      startEventTapWatchdog(generation: active.generation)
      reenableEventTap(reason: "startAlreadyRunning", generation: active.generation)
      return true
    }
    if isRunning {
      // A callback must use one immutable settings snapshot for its whole decision. Updating a
      // live port therefore creates a new generation instead of racing the old callback.
      stop()
      self.settings = settings
    }

    let generation = eventTapState.beginStart(settings: settings)
    let context = ScrollEngineEventTapContext(
      engine: self,
      generation: generation,
      settings: settings)
    let contextPointer = Unmanaged.passUnretained(context).toOpaque()
    let mask = 1 << CGEventType.scrollWheel.rawValue
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let context = Unmanaged<ScrollEngineEventTapContext>
        .fromOpaque(userInfo).takeUnretainedValue()
      guard let engine = context.engine else {
        return Unmanaged.passUnretained(event)
      }
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        engine.logEventTapDisabled(type, generation: context.generation)
        engine.reenableEventTap(
          reason: engine.eventTapDisabledReason(type),
          generation: context.generation)
        return Unmanaged.passUnretained(event)
      }
      guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
      }
      if let result = engine.eventTapState.withSnapshot(for: context.generation, { snapshot in
        engine.logEventTapCallback(event, settings: context.settings)
        return engine.handle(event: event, snapshot: snapshot)
      }) {
        return result
      }
      return Unmanaged.passUnretained(event)
    }

    var createdTap: CFMachPort?
    var createdTapLocation: CGEventTapLocation = .cghidEventTap
    for tapLocation in preferredEventTapLocations(settings: settings) {
      AppDiagnostics.log(
        "scroll_eventtap_create_attempt",
        lifecycleFields(settings: settings, extra: ["tap": tapLocationName(tapLocation)]))
      if let tap = makeEventTap(
        tap: tapLocation,
        mask: mask,
        callback: callback,
        userInfo: contextPointer)
      {
        createdTap = tap
        createdTapLocation = tapLocation
        AppDiagnostics.log(
          "scroll_eventtap_create_succeeded",
          lifecycleFields(settings: settings, extra: ["tap": tapLocationName(tapLocation)]))
        break
      }
      AppDiagnostics.log(
        "scroll_eventtap_create_failed_location",
        lifecycleFields(settings: settings, extra: ["tap": tapLocationName(tapLocation)]))
    }

    guard let eventTap = createdTap,
          eventTapState.installTap(
            eventTap,
            location: createdTapLocation,
            generation: generation) else {
      _ = eventTapState.beginStop()
      logLifecycle("scroll_eventtap_create_failed", settings: settings)
      onNotice("内置滚动启动失败：请点“立即授权”，软件会自动处理。")
      return false
    }

    let tapPort = eventTap
    let tapLocation = createdTapLocation
    let thread: Thread = Thread { [weak self, context] in
      defer { withExtendedLifetime(context) {} }
      guard let self else { return }
      guard let runLoop = CFRunLoopGetCurrent() else { return }
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
      guard self.eventTapState.attach(
        source: source,
        runLoop: runLoop,
        thread: Thread.current,
        generation: generation) else { return }
      guard self.eventTapState.withSnapshot(for: generation, { _ in
        if let source {
          CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: tapPort, enable: true)
        AppDiagnostics.log(
          "scroll_eventtap_started",
          self.lifecycleFields(
            settings: settings,
            extra: [
              "tap": self.tapLocationName(tapLocation),
              "thread": Thread.current.name ?? "",
            ]))
        return ()
      }) != nil else { return }
      CFRunLoopRun()
      if let source {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
      }
    }
    thread.name = "aixlg-scroll-eventtap"
    thread.qualityOfService = QualityOfService.userInteractive
    guard eventTapState.markRunning(generation: generation) else {
      CFMachPortInvalidate(tapPort)
      return false
    }
    thread.start()
    startEventTapWatchdog(generation: generation)
    return true
  }

  func update(settings: ScrollEngineSettings) -> Bool {
    self.settings = settings
    logLifecycle("scroll_update", settings: settings)
    if settings.needsEventTap {
      return start(settings: settings)
    }
    stop()
    return true
  }

  func stop() {
    let resources = eventTapState.beginStop()
    let wasRunning = resources.wasRunning
    logLifecycle("scroll_stop", settings: settings, extra: ["wasRunning": "\(wasRunning)"])
    stopEventTapWatchdog()
    let tap = resources.tap
    let source = resources.source
    let runLoop = resources.runLoop
    if let source, let runLoop {
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let runLoop {
      CFRunLoopStop(runLoop)
      CFRunLoopWakeUp(runLoop)
    }
    stopVolumeHotCornerOverlay()
    stopVolumeGlobalScrollMonitor()
    stopVolumeHIDWheelMonitor()
    cancelSmoothScroll()
    logLifecycle("scroll_stopped", settings: settings, extra: ["wasRunning": "\(wasRunning)"])
  }

  private func handle(
    event: CGEvent,
    snapshot: ScrollEngineEventTapState.Snapshot
  ) -> Unmanaged<CGEvent>? {
    let settings = snapshot.settings
    guard !isPostingSyntheticEventActive() else {
      return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
      return Unmanaged.passUnretained(event)
    }

    let rawVertical = wheelDelta(
      event,
      lineField: .scrollWheelEventDeltaAxis1,
      pointField: .scrollWheelEventPointDeltaAxis1,
      fixedField: .scrollWheelEventFixedPtDeltaAxis1)
    let rawHorizontal = wheelDelta(
      event,
      lineField: .scrollWheelEventDeltaAxis2,
      pointField: .scrollWheelEventPointDeltaAxis2,
      fixedField: .scrollWheelEventFixedPtDeltaAxis2)
    guard rawVertical != 0 || rawHorizontal != 0 else {
      return Unmanaged.passUnretained(event)
    }

    let traits = ScrollEventTraits(event: event)
    let isTrackpad = isLikelyTrackpad(traits)
    if settings.volumeHotCornerEnabled
      && ProcessInfo.processInfo.systemUptime - eventTapState.callbackTimes().overlay < 0.35
    {
      return Unmanaged.passUnretained(event)
    }
    if shouldHandleVolumeHotCorner(
      event: event,
      traits: traits,
      verticalDelta: rawVertical,
      horizontalDelta: rawHorizontal,
      settings: settings)
    {
      logScrollDecision(
        "volume_hotcorner",
        traits: traits,
        settings: settings,
        extra: scrollEventFields(event: event, verticalDelta: rawVertical, horizontalDelta: rawHorizontal))
      handleVolumeHotCorner(
        event: event,
        traits: traits,
        verticalDelta: rawVertical,
        settings: settings)
      return nil
    }

    if isTrackpad {
      logScrollDecision(
        "trackpad_passthrough",
        traits: traits,
        settings: settings,
        extra: scrollEventFields(event: event, verticalDelta: rawVertical, horizontalDelta: rawHorizontal))
      return Unmanaged.passUnretained(event)
    }

    guard settings.enabled else {
      logScrollDecision(
        "mouse_passthrough_disabled",
        traits: traits,
        settings: settings,
        extra: scrollEventFields(event: event, verticalDelta: rawVertical, horizontalDelta: rawHorizontal))
      return Unmanaged.passUnretained(event)
    }

    if event.flags.contains(.maskCommand) {
      return Unmanaged.passUnretained(event)
    }

    let accelerated = event.flags.contains(.maskAlternate)
    let mouseNeedsDirectionCorrection = !isTrackpad
      && (settings.reverseVertical || settings.reverseHorizontal)
    let useNativeWheelEvent = !settings.smooth && !mouseNeedsDirectionCorrection
    if event.flags.contains(.maskShift), rawHorizontal == 0, rawVertical != 0 {
      if useNativeWheelEvent {
        redirectVerticalScrollToHorizontal(
          event,
          reversed: settings.reverseHorizontal,
          accelerated: accelerated,
          settings: settings)
        return Unmanaged.passUnretained(event)
      }
      let targetX = outputDelta(
        rawVertical,
        reversed: settings.reverseHorizontal,
        accelerated: accelerated,
        settings: settings)
      postSyntheticScroll(
        from: event,
        x: targetX,
        y: 0,
        smooth: settings.smooth,
        settings: settings,
        tapLocation: snapshot.tapLocation)
      logScrollDecision(
        "mouse_horizontal_synthetic",
        traits: traits,
        settings: settings,
        extra: scrollEventFields(event: event, verticalDelta: rawVertical, horizontalDelta: rawHorizontal))
      return nil
    }

    guard settings.smooth || settings.reverseVertical || settings.reverseHorizontal else {
      return Unmanaged.passUnretained(event)
    }

    if useNativeWheelEvent {
      transformNativeScrollEvent(
        event,
        verticalMultiplier: nativeScrollMultiplier(
          reversed: settings.reverseVertical,
          accelerated: accelerated,
          settings: settings),
        horizontalMultiplier: nativeScrollMultiplier(
          reversed: settings.reverseHorizontal,
          accelerated: accelerated,
          settings: settings))
      return Unmanaged.passUnretained(event)
    }

    let targetY = outputDelta(
      rawVertical, reversed: settings.reverseVertical, accelerated: accelerated, settings: settings)
    let targetX = outputDelta(
      rawHorizontal, reversed: settings.reverseHorizontal, accelerated: accelerated, settings: settings)
    postSyntheticScroll(
      from: event,
      x: targetX,
      y: targetY,
      smooth: settings.smooth,
      settings: settings,
      tapLocation: snapshot.tapLocation)
    logScrollDecision(
      "mouse_synthetic",
      traits: traits,
      settings: settings,
      extra: scrollEventFields(event: event, verticalDelta: rawVertical, horizontalDelta: rawHorizontal))
    return nil
  }

  private func wheelDelta(
    _ event: CGEvent,
    lineField: CGEventField,
    pointField: CGEventField,
    fixedField: CGEventField
  ) -> Double {
    let lineDelta = event.getIntegerValueField(lineField)
    if lineDelta != 0 {
      return Double(lineDelta)
    }

    let pointDelta = event.getIntegerValueField(pointField)
    if pointDelta != 0 {
      return pointDelta > 0 ? 1 : -1
    }

    let fixedDelta = event.getDoubleValueField(fixedField)
    if fixedDelta != 0 {
      return fixedDelta > 0 ? 1 : -1
    }

    return 0
  }

  private func isLikelyTrackpad(_ traits: ScrollEventTraits) -> Bool {
    if traits.hasMomentumPhase {
      return true
    }

    if traits.hasScrollPhase, traits.isContinuous || traits.hasPixelDelta {
      return true
    }

    return false
  }

  private func shouldHandleVolumeHotCorner(
    event: CGEvent,
    traits: ScrollEventTraits,
    verticalDelta: Double,
    horizontalDelta: Double,
    settings: ScrollEngineSettings
  ) -> Bool {
    guard settings.volumeHotCornerEnabled else { return false }
    guard verticalDelta != 0 else {
      logHotCornerMiss(
        reason: "vertical_zero",
        event: event,
        traits: traits,
        verticalDelta: verticalDelta,
        horizontalDelta: horizontalDelta,
        settings: settings)
      return false
    }
    guard abs(verticalDelta) >= abs(horizontalDelta) else {
      logHotCornerMiss(
        reason: "horizontal_dominant",
        event: event,
        traits: traits,
        verticalDelta: verticalDelta,
        horizontalDelta: horizontalDelta,
        settings: settings)
      return false
    }
    if traits.hasMomentumPhase {
      logHotCornerMiss(
        reason: "momentum",
        event: event,
        traits: traits,
        verticalDelta: verticalDelta,
        horizontalDelta: horizontalDelta,
        settings: settings)
      return false
    }
    let point = event.location
    var diagnosticScreen: NSScreen?
    var diagnosticDisplayBounds: CGRect?
    var diagnosticHotWidth: CGFloat?
    var diagnosticHotHeight: CGFloat?
    for screen in NSScreen.screens {
      let hotWidth = min(max(screen.frame.width * settings.volumeHotCornerWidthRatio, 56), 180)
      let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
      let hotHeight = min(max(menuBarHeight + 4, 24), 44)
      let displayBounds = quartzDisplayBounds(for: screen)
      if diagnosticScreen == nil
        || displayBounds.map({ pointIsInside(point, rect: $0, tolerance: hotCornerBoundaryTolerance) })
          == true
      {
        diagnosticScreen = screen
        diagnosticDisplayBounds = displayBounds
        diagnosticHotWidth = hotWidth
        diagnosticHotHeight = hotHeight
      }
      // Use the scroll event location instead of NSEvent.mouseLocation. The latter can be stale when
      // the app is hidden or not frontmost, while the event location is delivered by the global tap.
      if let displayBounds,
        pointIsInQuartzTopRightBand(
          point,
          displayBounds: displayBounds,
          width: hotWidth,
          height: hotHeight)
      {
        logHotCornerHit(
          event: event,
          traits: traits,
          verticalDelta: verticalDelta,
          horizontalDelta: horizontalDelta,
          screen: screen,
          displayBounds: displayBounds,
          hotWidth: hotWidth,
          hotHeight: hotHeight,
          settings: settings)
        return true
      }
      if displayBounds == nil,
        pointIsInTopRightBand(
          NSPoint(x: point.x, y: point.y),
          screenFrame: screen.frame,
          width: hotWidth,
          height: hotHeight)
      {
        logHotCornerHit(
          event: event,
          traits: traits,
          verticalDelta: verticalDelta,
          horizontalDelta: horizontalDelta,
          screen: screen,
          displayBounds: nil,
          hotWidth: hotWidth,
          hotHeight: hotHeight,
          settings: settings)
        return true
      }
    }
    logHotCornerMiss(
      reason: "outside_hotcorner",
      event: event,
      traits: traits,
      verticalDelta: verticalDelta,
      horizontalDelta: horizontalDelta,
      screen: diagnosticScreen,
      displayBounds: diagnosticDisplayBounds,
      hotWidth: diagnosticHotWidth,
      hotHeight: diagnosticHotHeight,
      settings: settings)
    return false
  }

  private func handleVolumeHotCorner(
    event: CGEvent,
    traits: ScrollEventTraits,
    verticalDelta: Double,
    settings: ScrollEngineSettings
  ) {
    let continuous = isLikelyTrackpad(traits)
    let fineMultiplier = event.flags.contains(.maskShift) ? 0.5 : 1.0
    let fastMultiplier = event.flags.contains(.maskAlternate) ? 2.0 : 1.0
    let deviceMultiplier = continuous ? 0.38 : 1.0
    let delta =
      -verticalDelta * settings.volumeStep * fineMultiplier * fastMultiplier * deviceMultiplier

    let delay = continuous ? 0.026 : 0.010
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingVolumeDelta += delta
      self.scheduleVolumeFlush(delay: delay)
    }
  }

  private func logScrollDecision(
    _ decision: String,
    traits: ScrollEventTraits,
    settings: ScrollEngineSettings,
    extra: [String: String] = [:]
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastScrollDecisionLogAt >= 1.0 else { return }
    lastScrollDecisionLogAt = now
    var fields = baseScrollFields(traits: traits, settings: settings)
    fields["decision"] = decision
    fields.merge(extra) { _, new in new }
    AppDiagnostics.log("scroll_event", fields)
  }

  private func logHotCornerMiss(
    reason: String,
    event: CGEvent,
    traits: ScrollEventTraits,
    verticalDelta: Double,
    horizontalDelta: Double,
    screen: NSScreen? = nil,
    displayBounds: CGRect? = nil,
    hotWidth: CGFloat? = nil,
    hotHeight: CGFloat? = nil,
    settings: ScrollEngineSettings
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastHotCornerMissLogAt >= 1.0 else { return }
    lastHotCornerMissLogAt = now
    AppDiagnostics.log(
      "scroll_hotcorner_miss",
      hotCornerFields(
        reason: reason,
        event: event,
        traits: traits,
        verticalDelta: verticalDelta,
        horizontalDelta: horizontalDelta,
        screen: screen,
        displayBounds: displayBounds,
        hotWidth: hotWidth,
        hotHeight: hotHeight,
        settings: settings))
  }

  private func logHotCornerHit(
    event: CGEvent,
    traits: ScrollEventTraits,
    verticalDelta: Double,
    horizontalDelta: Double,
    screen: NSScreen,
    displayBounds: CGRect?,
    hotWidth: CGFloat,
    hotHeight: CGFloat,
    settings: ScrollEngineSettings
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastHotCornerHitLogAt >= 1.0 else { return }
    lastHotCornerHitLogAt = now
    AppDiagnostics.log(
      "scroll_hotcorner_hit",
      hotCornerFields(
        reason: "hit",
        event: event,
        traits: traits,
        verticalDelta: verticalDelta,
        horizontalDelta: horizontalDelta,
        screen: screen,
        displayBounds: displayBounds,
        hotWidth: hotWidth,
        hotHeight: hotHeight,
        settings: settings))
  }

  private func hotCornerFields(
    reason: String,
    event: CGEvent,
    traits: ScrollEventTraits,
    verticalDelta: Double,
    horizontalDelta: Double,
    screen: NSScreen?,
    displayBounds: CGRect?,
    hotWidth: CGFloat?,
    hotHeight: CGFloat?,
    settings: ScrollEngineSettings
  ) -> [String: String] {
    var fields = baseScrollFields(traits: traits, settings: settings)
    fields.merge(
      scrollEventFields(event: event, verticalDelta: verticalDelta, horizontalDelta: horizontalDelta)
    ) { _, new in new }
    fields["reason"] = reason
    fields["screenFrame"] = screen.map { formatRect($0.frame) } ?? "none"
    fields["visibleFrame"] = screen.map { formatRect($0.visibleFrame) } ?? "none"
    fields["displayBounds"] = displayBounds.map { formatRect($0) } ?? "none"
    fields["hotWidth"] = hotWidth.map { formatNumber(Double($0)) } ?? "none"
    fields["hotHeight"] = hotHeight.map { formatNumber(Double($0)) } ?? "none"
    return fields
  }

  private func baseScrollFields(
    traits: ScrollEventTraits,
    settings: ScrollEngineSettings
  ) -> [String: String] {
    let lifecycle = eventTapState.currentSnapshot()
    return [
      "mouseScroll": "\(settings.enabled)",
      "mouseVolume": "\(settings.volumeHotCornerEnabled)",
      "needsEventTap": "\(settings.needsEventTap)",
      "isRunning": "\(lifecycle?.isRunning == true)",
      "tap": tapLocationName(lifecycle?.tapLocation ?? .cghidEventTap),
      "instant": "\(traits.instantMouser)",
      "continuous": "\(traits.isContinuous)",
      "phase": "\(traits.phase)",
      "momentum": "\(traits.momentumPhase)",
      "line": "\(traits.lineVertical),\(traits.lineHorizontal)",
      "point": "\(traits.pointVertical),\(traits.pointHorizontal)",
      "fixed": "\(formatNumber(traits.fixedVertical)),\(formatNumber(traits.fixedHorizontal))",
    ]
  }

  private func scrollEventFields(
    event: CGEvent,
    verticalDelta: Double,
    horizontalDelta: Double
  ) -> [String: String] {
    [
      "eventPoint": formatPoint(event.location),
      "rawVertical": formatNumber(verticalDelta),
      "rawHorizontal": formatNumber(horizontalDelta),
    ]
  }

  private func logLifecycle(
    _ event: String,
    settings: ScrollEngineSettings,
    extra: [String: String] = [:]
  ) {
    guard AppDiagnostics.isEnabled else { return }
    AppDiagnostics.log(event, lifecycleFields(settings: settings, extra: extra))
  }

  private func logEventTapCallback(_ event: CGEvent, settings: ScrollEngineSettings) {
    let now = ProcessInfo.processInfo.systemUptime
    eventTapState.recordTapCallback(at: now)
    guard AppDiagnostics.isEnabled else { return }
    guard now - lastEventTapCallbackLogAt >= 1.0 else { return }
    lastEventTapCallbackLogAt = now
    AppDiagnostics.log(
      "scroll_eventtap_callback",
      lifecycleFields(settings: settings, extra: ["eventPoint": formatPoint(event.location)]))
  }

  private func updateVolumeHotCornerOverlay() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updateVolumeHotCornerOverlay()
      }
      return
    }

    guard settings.volumeHotCornerEnabled else {
      stopVolumeHotCornerOverlay()
      return
    }

    if volumeHotCornerOverlay == nil {
      volumeHotCornerOverlay = VolumeHotCornerOverlay { [weak self] event in
        self?.handleVolumeOverlayScroll(event)
      }
    }
    volumeHotCornerOverlay?.update(settings: settings)
  }

  private func stopVolumeHotCornerOverlay() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.stopVolumeHotCornerOverlay()
      }
      return
    }

    guard let overlay = volumeHotCornerOverlay else { return }
    overlay.stop()
    volumeHotCornerOverlay = nil
  }

  private func handleVolumeOverlayScroll(_ event: NSEvent) {
    guard settings.volumeHotCornerEnabled else { return }
    let rawVertical = normalizedGlobalScrollDelta(event.scrollingDeltaY)
    let rawHorizontal = normalizedGlobalScrollDelta(event.scrollingDeltaX)
    guard rawVertical != 0 || rawHorizontal != 0 else { return }
    guard rawVertical != 0, abs(rawVertical) >= abs(rawHorizontal) else {
      logOverlayEvent(reason: "non_vertical", event: event, verticalDelta: rawVertical)
      return
    }
    guard event.momentumPhase == [] else {
      logOverlayEvent(reason: "momentum", event: event, verticalDelta: rawVertical)
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    guard now - eventTapState.callbackTimes().tap > 0.35 else { return }
    guard now - lastHIDWheelHandledAt > 0.08 else { return }
    eventTapState.recordOverlayCallback(at: now)
    logOverlayEvent(reason: "volume_hotcorner", event: event, verticalDelta: rawVertical)
    handleVolumeGlobalScroll(event: event, verticalDelta: rawVertical)
  }

  private func updateVolumeGlobalScrollMonitor() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updateVolumeGlobalScrollMonitor()
      }
      return
    }

    guard settings.volumeHotCornerEnabled else {
      stopVolumeGlobalScrollMonitor()
      return
    }
    guard volumeGlobalScrollMonitor == nil else { return }

    volumeGlobalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      self?.handleVolumeGlobalScrollMonitor(event)
    }
    AppDiagnostics.log("scroll_global_monitor_started", lifecycleFields(settings: settings))
  }

  private func stopVolumeGlobalScrollMonitor() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.stopVolumeGlobalScrollMonitor()
      }
      return
    }

    guard let monitor = volumeGlobalScrollMonitor else { return }
    NSEvent.removeMonitor(monitor)
    volumeGlobalScrollMonitor = nil
    AppDiagnostics.log("scroll_global_monitor_stopped", lifecycleFields(settings: settings))
  }

  private func handleVolumeGlobalScrollMonitor(_ event: NSEvent) {
    guard settings.volumeHotCornerEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    lastGlobalMonitorCallbackAt = now
    guard now - eventTapState.callbackTimes().tap > 0.35 else { return }
    guard now - lastHIDWheelHandledAt > 0.08 else { return }

    let rawVertical = normalizedGlobalScrollDelta(event.scrollingDeltaY)
    let rawHorizontal = normalizedGlobalScrollDelta(event.scrollingDeltaX)
    guard rawVertical != 0 || rawHorizontal != 0 else { return }
    guard rawVertical != 0, abs(rawVertical) >= abs(rawHorizontal) else {
      logGlobalMonitorEvent(reason: "non_vertical", event: event, verticalDelta: rawVertical)
      return
    }
    guard event.momentumPhase == [] else {
      logGlobalMonitorEvent(reason: "momentum", event: event, verticalDelta: rawVertical)
      return
    }
    guard pointIsInAnyTopRightBandAtCurrentPointer() else {
      logGlobalMonitorEvent(reason: "outside_hotcorner", event: event, verticalDelta: rawVertical)
      return
    }

    logGlobalMonitorEvent(reason: "volume_hotcorner", event: event, verticalDelta: rawVertical)
    handleVolumeGlobalScroll(event: event, verticalDelta: rawVertical)
  }

  private func updateVolumeHIDWheelMonitor() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updateVolumeHIDWheelMonitor()
      }
      return
    }

    guard settings.volumeHotCornerEnabled else {
      stopVolumeHIDWheelMonitor()
      return
    }
    guard volumeHIDWheelManagers.isEmpty else { return }

    hidDeviceLogCount = 0
    var managers: [IOHIDManager] = []
    if let pointerManager = startVolumeHIDWheelManager(
      matchName: "mouse,pointer",
      matching: [
        [
          kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ],
        [
          kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer,
        ],
      ])
    {
      managers.append(pointerManager)
    }
    if let receiverManager = startVolumeHIDWheelManager(
      matchName: "keyboard,keypad-receiver",
      matching: [
        [
          kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ],
        [
          kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keypad,
        ],
      ])
    {
      managers.append(receiverManager)
    }
    volumeHIDWheelManagers = managers
  }

  private func startVolumeHIDWheelManager(
    matchName: String,
    matching: [[String: Any]]
  ) -> IOHIDManager? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue()
        engine.logHIDDevice(event: "scroll_hid_device_matched", device: device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue()
        engine.logHIDDevice(event: "scroll_hid_device_removed", device: device)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerRegisterInputValueCallback(
      manager,
      { context, _, _, value in
        guard let context else { return }
        let engine = Unmanaged<ScrollEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleHIDInputValue(value)
      },
      Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerScheduleWithRunLoop(
      manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else {
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      AppDiagnostics.log(
        "scroll_hid_wheel_open_failed",
        lifecycleFields(settings: settings, extra: ["match": matchName, "result": "\(result)"]))
      return nil
    }

    let deviceCount = IOHIDManagerCopyDevices(manager).map { CFSetGetCount($0) } ?? 0
    AppDiagnostics.log(
      "scroll_hid_wheel_started",
      lifecycleFields(
        settings: settings,
        extra: ["deviceCount": "\(deviceCount)", "match": matchName]))
    return manager
  }

  private func stopVolumeHIDWheelMonitor() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.stopVolumeHIDWheelMonitor()
      }
      return
    }

    guard !volumeHIDWheelManagers.isEmpty else { return }
    for manager in volumeHIDWheelManagers {
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    volumeHIDWheelManagers.removeAll()
    AppDiagnostics.log("scroll_hid_wheel_stopped", lifecycleFields(settings: settings))
  }

  private func handleHIDInputValue(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let rawValue = IOHIDValueGetIntegerValue(value)
    logHIDValueCallback(usagePage: usagePage, usage: usage, rawValue: rawValue)
    guard usagePage == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_Wheel else {
      return
    }

    guard rawValue != 0 else { return }
    DispatchQueue.main.async { [weak self] in
      self?.handleVolumeHIDWheel(rawValue)
    }
  }

  private func handleVolumeHIDWheel(_ rawValue: Int) {
    guard settings.volumeHotCornerEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - eventTapState.callbackTimes().tap > 0.35 else { return }
    guard now - lastGlobalMonitorCallbackAt > 0.35 else { return }

    let rawVertical = rawValue > 0 ? 1.0 : -1.0
    guard pointIsInAnyTopRightBandAtCurrentPointer() else {
      logHIDWheelEvent(reason: "outside_hotcorner", verticalDelta: rawVertical)
      return
    }

    lastHIDWheelHandledAt = now
    logHIDWheelEvent(reason: "volume_hotcorner", verticalDelta: rawVertical)
    handleVolumeHIDWheelDelta(rawVertical)
  }

  private func handleVolumeHIDWheelDelta(_ verticalDelta: Double) {
    let delta = -verticalDelta * settings.volumeStep
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingVolumeDelta += delta
      self.scheduleVolumeFlush(delay: 0.010)
    }
  }

  private func handleVolumeGlobalScroll(event: NSEvent, verticalDelta: Double) {
    let continuous = event.hasPreciseScrollingDeltas || event.phase != []
    let fineMultiplier = event.modifierFlags.contains(.shift) ? 0.5 : 1.0
    let fastMultiplier = event.modifierFlags.contains(.option) ? 2.0 : 1.0
    let deviceMultiplier = continuous ? 0.38 : 1.0
    let delta =
      -verticalDelta * settings.volumeStep * fineMultiplier * fastMultiplier * deviceMultiplier
    let delay = continuous ? 0.026 : 0.010
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingVolumeDelta += delta
      self.scheduleVolumeFlush(delay: delay)
    }
  }

  private func normalizedGlobalScrollDelta(_ value: CGFloat) -> Double {
    guard value != 0 else { return 0 }
    return value > 0 ? 1 : -1
  }

  private func pointIsInAnyAppKitTopRightBand(_ point: NSPoint) -> Bool {
    for screen in NSScreen.screens {
      let hotWidth = min(max(screen.frame.width * settings.volumeHotCornerWidthRatio, 56), 180)
      let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
      let hotHeight = min(max(menuBarHeight + 4, 24), 44)
      if pointIsInTopRightBand(point, screenFrame: screen.frame, width: hotWidth, height: hotHeight)
      {
        return true
      }
    }
    return false
  }

  private func pointIsInAnyTopRightBandAtCurrentPointer() -> Bool {
    if pointIsInAnyAppKitTopRightBand(NSEvent.mouseLocation) {
      return true
    }
    guard let quartzPoint = CGEvent(source: nil)?.location else {
      return false
    }
    for screen in NSScreen.screens {
      let hotWidth = min(max(screen.frame.width * settings.volumeHotCornerWidthRatio, 56), 180)
      let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
      let hotHeight = min(max(menuBarHeight + 4, 24), 44)
      guard let displayBounds = quartzDisplayBounds(for: screen) else { continue }
      if pointIsInQuartzTopRightBand(
        quartzPoint,
        displayBounds: displayBounds,
        width: hotWidth,
        height: hotHeight)
      {
        return true
      }
    }
    return false
  }

  private func logGlobalMonitorEvent(
    reason: String,
    event: NSEvent,
    verticalDelta: Double
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastGlobalMonitorLogAt >= 1.0 else { return }
    lastGlobalMonitorLogAt = now
    var fields = lifecycleFields(settings: settings)
    fields["reason"] = reason
    fields["eventPoint"] = formatPoint(NSEvent.mouseLocation)
    fields["rawVertical"] = formatNumber(verticalDelta)
    fields["precise"] = "\(event.hasPreciseScrollingDeltas)"
    fields["phase"] = "\(event.phase.rawValue)"
    fields["momentum"] = "\(event.momentumPhase.rawValue)"
    AppDiagnostics.log("scroll_global_monitor_event", fields)
  }

  private func logOverlayEvent(reason: String, event: NSEvent, verticalDelta: Double) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard reason == "volume_hotcorner" || now - lastOverlayLogAt >= 1.0 else { return }
    lastOverlayLogAt = now
    var fields = lifecycleFields(settings: settings)
    fields["reason"] = reason
    fields["eventPoint"] = formatPoint(NSEvent.mouseLocation)
    fields["rawVertical"] = formatNumber(verticalDelta)
    fields["precise"] = "\(event.hasPreciseScrollingDeltas)"
    fields["phase"] = "\(event.phase.rawValue)"
    fields["momentum"] = "\(event.momentumPhase.rawValue)"
    AppDiagnostics.log("scroll_overlay_event", fields)
  }

  private func logHIDWheelEvent(reason: String, verticalDelta: Double) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastGlobalMonitorLogAt >= 1.0 else { return }
    lastGlobalMonitorLogAt = now
    var fields = lifecycleFields(settings: settings)
    fields["reason"] = reason
    fields["eventPoint"] = formatPoint(NSEvent.mouseLocation)
    fields["rawVertical"] = formatNumber(verticalDelta)
    if let quartzPoint = CGEvent(source: nil)?.location {
      fields["quartzPoint"] = formatPoint(quartzPoint)
    }
    AppDiagnostics.log("scroll_hid_wheel_event", fields)
  }

  private func logHIDValueCallback(usagePage: UInt32, usage: UInt32, rawValue: Int) {
    guard AppDiagnostics.isEnabled else { return }
    guard rawValue != 0 else { return }
    let isWheel = usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Wheel
    let isPointerAxis =
      usagePage == kHIDPage_GenericDesktop
      && (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y)
    let now = ProcessInfo.processInfo.systemUptime
    guard isWheel || (!isPointerAxis && now - lastHIDValueCallbackLogAt >= 1.0) else { return }
    lastHIDValueCallbackLogAt = now
    var fields = lifecycleFields(settings: settings)
    fields["usagePage"] = "\(usagePage)"
    fields["usage"] = "\(usage)"
    fields["rawValue"] = "\(rawValue)"
    fields["wheelCandidate"] = "\(isWheel)"
    AppDiagnostics.log("scroll_hid_value_callback", fields)
  }

  private func logHIDDevice(event: String, device: IOHIDDevice) {
    guard AppDiagnostics.isEnabled else { return }
    if event == "scroll_hid_device_matched" {
      guard hidDeviceLogCount < 16 else { return }
      hidDeviceLogCount += 1
    }
    var fields = lifecycleFields(settings: settings)
    fields["product"] = hidDeviceProperty(device, key: kIOHIDProductKey)
    fields["manufacturer"] = hidDeviceProperty(device, key: kIOHIDManufacturerKey)
    fields["transport"] = hidDeviceProperty(device, key: kIOHIDTransportKey)
    fields["vendorID"] = hidDeviceProperty(device, key: kIOHIDVendorIDKey)
    fields["productID"] = hidDeviceProperty(device, key: kIOHIDProductIDKey)
    fields["primaryUsagePage"] = hidDeviceProperty(device, key: kIOHIDPrimaryUsagePageKey)
    fields["primaryUsage"] = hidDeviceProperty(device, key: kIOHIDPrimaryUsageKey)
    AppDiagnostics.log(event, fields)
  }

  private func hidDeviceProperty(_ device: IOHIDDevice, key: String) -> String {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return "" }
    return String(describing: value)
  }

  private func lifecycleFields(
    settings: ScrollEngineSettings,
    extra: [String: String] = [:]
  ) -> [String: String] {
    let lifecycle = eventTapState.currentSnapshot()
    var fields = [
      "mouseScroll": "\(settings.enabled)",
      "mouseVolume": "\(settings.volumeHotCornerEnabled)",
      "needsEventTap": "\(settings.needsEventTap)",
      "isRunning": "\(lifecycle?.isRunning == true)",
      "tap": tapLocationName(lifecycle?.tapLocation ?? .cghidEventTap),
    ]
    fields.merge(extra) { _, new in new }
    return fields
  }

  private func requestListenEventAccessIfNeeded(settings: ScrollEngineSettings) -> Bool {
    guard #available(macOS 10.15, *) else { return true }
    let preflight = CGPreflightListenEventAccess()
    AppDiagnostics.log(
      "scroll_input_monitoring_preflight",
      lifecycleFields(settings: settings, extra: ["granted": "\(preflight)"]))
    return preflight
  }

  private func scheduleVolumeFlush(delay: Double) {
    guard !volumeFlushScheduled else { return }
    volumeFlushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.volumeFlushScheduled = false
      let delta = self.pendingVolumeDelta
      self.pendingVolumeDelta = 0
      guard abs(delta) >= 0.15 else { return }
      self.applyVolumeDelta(delta)
    }
  }

  private func applyVolumeDelta(_ delta: Double) {
    guard let volume = volumeController.changeVolume(by: delta) else {
      onNotice("没有找到可调节的系统输出音量。")
      return
    }
    VolumeFeedbackPresenter.show(
      volume: volume,
      alert: volumeAlert,
      hud: volumeHUD,
      source: "hotcorner")
  }

  private func logEventTapDisabled(_ type: CGEventType, generation: UInt64) {
    guard let snapshot = eventTapState.snapshot(for: generation) else { return }
    AppDiagnostics.log(
      "scroll_eventtap_disabled",
      lifecycleFields(
        settings: snapshot.settings,
        extra: ["reason": eventTapDisabledReason(type)]))
  }

  private func eventTapDisabledReason(_ type: CGEventType) -> String {
    if type == .tapDisabledByTimeout {
      return "tapDisabledByTimeout"
    }
    if type == .tapDisabledByUserInput {
      return "tapDisabledByUserInput"
    }
    return "unknown"
  }

  private func reenableEventTap(reason: String, generation: UInt64) {
    guard eventTapState.withSnapshot(for: generation, { snapshot in
      AppDiagnostics.log(
        "scroll_eventtap_reenable_request",
        lifecycleFields(settings: snapshot.settings, extra: ["reason": reason]))
      CGEvent.tapEnable(tap: snapshot.tap, enable: true)
      AppDiagnostics.log(
        "scroll_eventtap_reenabled",
        lifecycleFields(settings: snapshot.settings, extra: ["reason": reason]))
      return ()
    }) != nil else {
      AppDiagnostics.log(
        "scroll_eventtap_reenable_skipped",
        lifecycleFields(settings: settings, extra: ["reason": reason]))
      return
    }
    DispatchQueue.main.async {
      self.onNotice("内置滚动引擎已自动恢复。")
    }
  }

  private func startEventTapWatchdog(generation: UInt64) {
    guard eventTapWatchdogGeneration != generation else { return }
    stopEventTapWatchdog()
    let timer = DispatchSource.makeTimerSource(queue: eventTapWatchdogQueue)
    timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
    timer.setEventHandler { [weak self] in
      self?.verifyEventTapIsEnabled(generation: generation)
    }
    eventTapWatchdogTimer = timer
    eventTapWatchdogGeneration = generation
    timer.resume()
    AppDiagnostics.log(
      "scroll_eventtap_watchdog_started",
      lifecycleFields(settings: settings))
  }

  private func stopEventTapWatchdog() {
    eventTapWatchdogTimer?.cancel()
    eventTapWatchdogTimer = nil
    eventTapWatchdogGeneration = nil
  }

  private func verifyEventTapIsEnabled(generation: UInt64) {
    eventTapState.withSnapshot(for: generation) { snapshot in
      guard snapshot.settings.needsEventTap,
            !CGEvent.tapIsEnabled(tap: snapshot.tap) else { return }
      AppDiagnostics.log(
        "scroll_eventtap_watchdog_disabled",
        lifecycleFields(settings: snapshot.settings))
      CGEvent.tapEnable(tap: snapshot.tap, enable: true)
      AppDiagnostics.log(
        "scroll_eventtap_watchdog_reenabled",
        lifecycleFields(settings: snapshot.settings))
    }
  }

  private func makeEventTap(
    tap: CGEventTapLocation,
    mask: Int,
    callback: @escaping CGEventTapCallBack,
    userInfo: UnsafeMutableRawPointer
  ) -> CFMachPort? {
    CGEvent.tapCreate(
      tap: tap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: userInfo
    )
  }

  private func preferredEventTapLocations(settings: ScrollEngineSettings) -> [CGEventTapLocation] {
    if settings.volumeHotCornerEnabled {
      return [.cghidEventTap, .cgSessionEventTap]
    }
    return [.cgSessionEventTap, .cghidEventTap]
  }

  private func tapLocationName(_ tap: CGEventTapLocation) -> String {
    switch tap {
    case .cghidEventTap:
      return "hid"
    case .cgSessionEventTap:
      return "session"
    case .cgAnnotatedSessionEventTap:
      return "annotatedSession"
    @unknown default:
      return "\(tap)"
    }
  }

  private func formatPoint(_ point: CGPoint) -> String {
    "\(formatNumber(Double(point.x))),\(formatNumber(Double(point.y)))"
  }

  private func formatRect(_ rect: CGRect) -> String {
    "\(formatNumber(Double(rect.minX))),\(formatNumber(Double(rect.minY))),\(formatNumber(Double(rect.width))),\(formatNumber(Double(rect.height)))"
  }

  private func formatNumber(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private func outputDelta(
    _ value: Double,
    reversed: Bool,
    accelerated: Bool,
    settings: ScrollEngineSettings
  ) -> Double {
    settings.smooth
      ? smoothedDelta(value, reversed: reversed, accelerated: accelerated, settings: settings)
      : directDelta(value, reversed: reversed, accelerated: accelerated, settings: settings)
  }

  private func directDelta(
    _ value: Double,
    reversed: Bool,
    accelerated: Bool,
    settings: ScrollEngineSettings
  ) -> Double {
    let sign = reversed ? -1.0 : 1.0
    let acceleration = accelerated ? settings.speed : 1.0
    return value * settings.step * acceleration * sign
  }

  private func smoothedDelta(
    _ value: Double,
    reversed: Bool,
    accelerated: Bool,
    settings: ScrollEngineSettings
  ) -> Double {
    let sign = reversed ? -1.0 : 1.0
    let acceleration = accelerated ? 1.8 : 1.0
    return value * settings.step * settings.speed * acceleration * sign
  }

  private func nativeScrollMultiplier(
    reversed: Bool,
    accelerated: Bool,
    settings: ScrollEngineSettings
  ) -> Double {
    let sign = reversed ? -1.0 : 1.0
    let acceleration = accelerated ? max(settings.speed, 1.0) : 1.0
    return sign * acceleration
  }

  private func transformNativeScrollEvent(
    _ event: CGEvent,
    verticalMultiplier: Double,
    horizontalMultiplier: Double
  ) {
    applyScrollAxis(
      event,
      deltaField: .scrollWheelEventDeltaAxis1,
      pointField: .scrollWheelEventPointDeltaAxis1,
      fixedField: .scrollWheelEventFixedPtDeltaAxis1,
      acceleratedField: .scrollWheelEventAcceleratedDeltaAxis1,
      rawField: .scrollWheelEventRawDeltaAxis1,
      multiplier: verticalMultiplier)
    applyScrollAxis(
      event,
      deltaField: .scrollWheelEventDeltaAxis2,
      pointField: .scrollWheelEventPointDeltaAxis2,
      fixedField: .scrollWheelEventFixedPtDeltaAxis2,
      acceleratedField: .scrollWheelEventAcceleratedDeltaAxis2,
      rawField: .scrollWheelEventRawDeltaAxis2,
      multiplier: horizontalMultiplier)
  }

  private func redirectVerticalScrollToHorizontal(
    _ event: CGEvent,
    reversed: Bool,
    accelerated: Bool,
    settings: ScrollEngineSettings
  ) {
    let multiplier = nativeScrollMultiplier(
      reversed: reversed,
      accelerated: accelerated,
      settings: settings)
    copyScrollAxis(
      event,
      fromDeltaField: .scrollWheelEventDeltaAxis1,
      fromPointField: .scrollWheelEventPointDeltaAxis1,
      fromFixedField: .scrollWheelEventFixedPtDeltaAxis1,
      fromAcceleratedField: .scrollWheelEventAcceleratedDeltaAxis1,
      fromRawField: .scrollWheelEventRawDeltaAxis1,
      toDeltaField: .scrollWheelEventDeltaAxis2,
      toPointField: .scrollWheelEventPointDeltaAxis2,
      toFixedField: .scrollWheelEventFixedPtDeltaAxis2,
      toAcceleratedField: .scrollWheelEventAcceleratedDeltaAxis2,
      toRawField: .scrollWheelEventRawDeltaAxis2,
      multiplier: multiplier)
    applyScrollAxis(
      event,
      deltaField: .scrollWheelEventDeltaAxis1,
      pointField: .scrollWheelEventPointDeltaAxis1,
      fixedField: .scrollWheelEventFixedPtDeltaAxis1,
      acceleratedField: .scrollWheelEventAcceleratedDeltaAxis1,
      rawField: .scrollWheelEventRawDeltaAxis1,
      multiplier: 0)
  }

  private func applyScrollAxis(
    _ event: CGEvent,
    deltaField: CGEventField,
    pointField: CGEventField,
    fixedField: CGEventField,
    acceleratedField: CGEventField,
    rawField: CGEventField,
    multiplier: Double
  ) {
    scaleIntegerField(event, deltaField, multiplier: multiplier)
    scaleIntegerField(event, pointField, multiplier: multiplier)
    scaleDoubleField(event, fixedField, multiplier: multiplier)
    scaleIntegerField(event, acceleratedField, multiplier: multiplier)
    scaleIntegerField(event, rawField, multiplier: multiplier)
  }

  private func copyScrollAxis(
    _ event: CGEvent,
    fromDeltaField: CGEventField,
    fromPointField: CGEventField,
    fromFixedField: CGEventField,
    fromAcceleratedField: CGEventField,
    fromRawField: CGEventField,
    toDeltaField: CGEventField,
    toPointField: CGEventField,
    toFixedField: CGEventField,
    toAcceleratedField: CGEventField,
    toRawField: CGEventField,
    multiplier: Double
  ) {
    copyIntegerField(event, fromDeltaField, toDeltaField, multiplier: multiplier)
    copyIntegerField(event, fromPointField, toPointField, multiplier: multiplier)
    copyDoubleField(event, fromFixedField, toFixedField, multiplier: multiplier)
    copyIntegerField(event, fromAcceleratedField, toAcceleratedField, multiplier: multiplier)
    copyIntegerField(event, fromRawField, toRawField, multiplier: multiplier)
  }

  private func scaleIntegerField(_ event: CGEvent, _ field: CGEventField, multiplier: Double) {
    let value = event.getIntegerValueField(field)
    guard value != 0 || multiplier == 0 else { return }
    event.setIntegerValueField(field, value: scaledInteger(value, multiplier: multiplier))
  }

  private func copyIntegerField(
    _ event: CGEvent,
    _ fromField: CGEventField,
    _ toField: CGEventField,
    multiplier: Double
  ) {
    let value = event.getIntegerValueField(fromField)
    event.setIntegerValueField(toField, value: scaledInteger(value, multiplier: multiplier))
  }

  private func scaleDoubleField(_ event: CGEvent, _ field: CGEventField, multiplier: Double) {
    let value = event.getDoubleValueField(field)
    guard value != 0 || multiplier == 0 else { return }
    event.setDoubleValueField(field, value: value * multiplier)
  }

  private func copyDoubleField(
    _ event: CGEvent,
    _ fromField: CGEventField,
    _ toField: CGEventField,
    multiplier: Double
  ) {
    let value = event.getDoubleValueField(fromField)
    event.setDoubleValueField(toField, value: value * multiplier)
  }

  private func scaledInteger(_ value: Int64, multiplier: Double) -> Int64 {
    guard multiplier != 0 else { return 0 }
    let scaled = (Double(value) * multiplier).rounded()
    if scaled == 0, value != 0 {
      return (value > 0) == (multiplier > 0) ? 1 : -1
    }
    return Int64(max(min(scaled, Double(Int64.max)), Double(Int64.min)))
  }

  private func postSyntheticScroll(
    from originalEvent: CGEvent,
    x: Double,
    y: Double,
    smooth: Bool,
    settings: ScrollEngineSettings,
    tapLocation: CGEventTapLocation
  ) {
    let source = CGEventSource(event: originalEvent) ?? CGEventSource(stateID: .hidSystemState)
    if smooth {
      enqueueSmoothScroll(
        source: source,
        tapLocation: tapLocation,
        x: x,
        y: y,
        duration: settings.duration)
      return
    }

    let dx = Int32(x.rounded())
    let dy = Int32(y.rounded())
    guard dx != 0 || dy != 0 else {
      notifyScrollFailure("内置滚动未产生有效滚轮事件：请关闭平滑滚动或调高步长。")
      return
    }
    postSyntheticScrollFrame(
      source: source,
      tapLocation: tapLocation,
      x: dx,
      y: dy,
      mode: "direct")
  }

  private func notifyScrollFailure(_ message: String) {
    let now = Date().timeIntervalSinceReferenceDate
    guard now - lastScrollFailureNoticeAt > 2 else { return }
    lastScrollFailureNoticeAt = now
    DispatchQueue.main.async { [onNotice] in
      onNotice(message)
    }
  }

  private func enqueueSmoothScroll(
    source: CGEventSource?,
    tapLocation: CGEventTapLocation,
    x: Double,
    y: Double,
    duration: Double
  ) {
    let transition = smoothScrollTransition(forDuration: duration)
    smoothScrollQueue.async { [weak self] in
      guard let self else { return }
      var inputWasCoalesced = self.smoothScrollTimer != nil
      self.smoothScrollQueuedInputs += 1
      self.smoothScrollSource = source
      self.smoothScrollTapLocation = tapLocation
      self.smoothScrollTransition = transition

      if x * self.smoothScrollDelta.x > 0 {
        self.smoothScrollBuffer.x += x
        inputWasCoalesced = true
      } else {
        self.smoothScrollBuffer.x = x
        self.smoothScrollCurrent.x = 0
        self.smoothScrollRemainder.x = 0
      }
      if y * self.smoothScrollDelta.y > 0 {
        self.smoothScrollBuffer.y += y
        inputWasCoalesced = true
      } else {
        self.smoothScrollBuffer.y = y
        self.smoothScrollCurrent.y = 0
        self.smoothScrollRemainder.y = 0
      }

      if inputWasCoalesced {
        self.smoothScrollCoalescedInputs += 1
      }
      self.smoothScrollDelta = (x: x, y: y)
      self.logSmoothScrollInputEnqueued(x: x, y: y)
      self.startSmoothScrollTimerIfNeeded()
    }
  }

  private func startSmoothScrollTimerIfNeeded() {
    guard smoothScrollTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: smoothScrollQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      self?.processSmoothScrollFrame()
    }
    smoothScrollTimer = timer
    timer.resume()
  }

  private func processSmoothScrollFrame() {
    let now = ProcessInfo.processInfo.systemUptime
    let frameInterval = smoothScrollLastFrameAt.map { now - $0 } ?? 0
    smoothScrollLastFrameAt = now
    smoothScrollFrameCount += 1
    if frameInterval > 0 {
      smoothScrollFrameIntervalTotal += frameInterval
      smoothScrollMaxFrameInterval = max(smoothScrollMaxFrameInterval, frameInterval)
    }
    if frameInterval > 0.018 {
      smoothScrollSlowFrames += 1
      smoothScrollDroppedFrames += max(1, Int((frameInterval / 0.008).rounded()) - 1)
    }

    let frameX = (smoothScrollBuffer.x - smoothScrollCurrent.x) * smoothScrollTransition
    let frameY = (smoothScrollBuffer.y - smoothScrollCurrent.y) * smoothScrollTransition
    smoothScrollCurrent.x += frameX
    smoothScrollCurrent.y += frameY

    let outputX = frameX + smoothScrollRemainder.x
    let outputY = frameY + smoothScrollRemainder.y
    let dx = Int32(outputX.rounded())
    let dy = Int32(outputY.rounded())
    smoothScrollRemainder.x = outputX - Double(dx)
    smoothScrollRemainder.y = outputY - Double(dy)

    if dx != 0 || dy != 0 {
      smoothScrollGeneratedEvents += 1
      postSyntheticScrollFrame(
        source: smoothScrollSource,
        tapLocation: smoothScrollTapLocation,
        x: dx,
        y: dy,
        mode: "smooth")
    } else {
      smoothScrollZeroOutputFrames += 1
      smoothScrollDroppedFrames += 1
    }

    logSmoothScrollFrameStats(
      reason: "frame",
      frameInterval: frameInterval,
      outputX: outputX,
      outputY: outputY)

    let residual = max(
      abs(smoothScrollBuffer.x - smoothScrollCurrent.x),
      abs(smoothScrollBuffer.y - smoothScrollCurrent.y))
    let output = max(abs(outputX), abs(outputY))
    if residual <= smoothScrollDeadZone && output <= smoothScrollDeadZone {
      stopSmoothScrollTimer(reset: true)
    }
  }

  private func smoothScrollTransition(forDuration duration: Double) -> Double {
    let upperLimit = 5.2
    let clampedDuration = min(max(duration, 1.0), 5.0)
    let value = 1.0 - sqrt(clampedDuration / upperLimit)
    return min(max(value, 0.045), 0.22)
  }

  private func stopSmoothScrollTimer(reset: Bool) {
    smoothScrollTimer?.cancel()
    smoothScrollTimer = nil
    logSmoothScrollFrameStats(reason: "stop", frameInterval: 0, outputX: 0, outputY: 0, force: true)
    guard reset else { return }
    smoothScrollCurrent = (x: 0, y: 0)
    smoothScrollBuffer = (x: 0, y: 0)
    smoothScrollDelta = (x: 0, y: 0)
    smoothScrollRemainder = (x: 0, y: 0)
    smoothScrollSource = nil
    smoothScrollQueuedInputs = 0
    smoothScrollCoalescedInputs = 0
    smoothScrollGeneratedEvents = 0
    smoothScrollDroppedFrames = 0
    smoothScrollFrameCount = 0
    smoothScrollSlowFrames = 0
    smoothScrollZeroOutputFrames = 0
    smoothScrollFrameIntervalTotal = 0
    smoothScrollMaxFrameInterval = 0
    smoothScrollLastFrameAt = nil
  }

  private func cancelSmoothScroll() {
    if DispatchQueue.getSpecific(key: smoothScrollQueueKey) != nil {
      stopSmoothScrollTimer(reset: true)
    } else {
      smoothScrollQueue.sync { [weak self] in
        self?.stopSmoothScrollTimer(reset: true)
      }
    }
  }

  private func postSyntheticScrollFrame(
    source: CGEventSource?,
    tapLocation: CGEventTapLocation,
    x: Int32,
    y: Int32,
    mode: String
  ) {
    withSyntheticPosting {
      let started = ProcessInfo.processInfo.systemUptime
      guard
        let event = CGEvent(
          scrollWheelEvent2Source: source,
          units: .pixel,
          wheelCount: 2,
          wheel1: y,
          wheel2: x,
          wheel3: 0)
      else {
        notifyScrollFailure("内置滚动无法创建合成滚轮事件：请点“立即授权”，软件会自动处理。")
        return
      }
      event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
      event.post(tap: tapLocation)
      logSyntheticScrollPost(
        mode: mode,
        tapLocation: tapLocation,
        x: x,
        y: y,
        duration: ProcessInfo.processInfo.systemUptime - started)
    }
  }

  private func isPostingSyntheticEventActive() -> Bool {
    syntheticPostingLock.lock()
    defer { syntheticPostingLock.unlock() }
    return syntheticPostingDepth > 0
  }

  private func withSyntheticPosting(_ work: () -> Void) {
    syntheticPostingLock.lock()
    syntheticPostingDepth += 1
    syntheticPostingLock.unlock()
    defer {
      syntheticPostingLock.lock()
      syntheticPostingDepth = max(0, syntheticPostingDepth - 1)
      syntheticPostingLock.unlock()
    }
    work()
  }

  private func logSmoothScrollInputEnqueued(x: Double, y: Double) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - smoothScrollLastInputLogAt >= 1.0 else { return }
    smoothScrollLastInputLogAt = now
    AppDiagnostics.log(
      "scroll_smooth_input_enqueued",
      smoothScrollDiagnosticFields(
        reason: "input",
        frameInterval: 0,
        outputX: x,
        outputY: y,
        extra: [
          "coalesced": "\(smoothScrollTimer != nil)",
          "thread": Thread.current.name ?? "smooth-scroll",
        ]))
  }

  private func logSmoothScrollFrameStats(
    reason: String,
    frameInterval: TimeInterval,
    outputX: Double,
    outputY: Double,
    force: Bool = false
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - smoothScrollLastStatsLogAt >= 1.0 else { return }
    smoothScrollLastStatsLogAt = now
    AppDiagnostics.log(
      "scroll_smooth_frame_stats",
      smoothScrollDiagnosticFields(
        reason: reason,
        frameInterval: frameInterval,
        outputX: outputX,
        outputY: outputY,
        extra: ["thread": Thread.current.name ?? "smooth-scroll"]))
  }

  private func smoothScrollDiagnosticFields(
    reason: String,
    frameInterval: TimeInterval,
    outputX: Double,
    outputY: Double,
    extra: [String: String] = [:]
  ) -> [String: String] {
    let pendingDistance = max(
      abs(smoothScrollBuffer.x - smoothScrollCurrent.x),
      abs(smoothScrollBuffer.y - smoothScrollCurrent.y))
    let avgFrameInterval =
      smoothScrollFrameCount > 0
      ? smoothScrollFrameIntervalTotal / Double(smoothScrollFrameCount)
      : 0
    var fields = lifecycleFields(
      settings: settings,
      extra: [
        "reason": reason,
        "device": "mouse",
        "mode": settings.smooth ? "smooth" : "direct",
        "computeThread": "smooth-scroll-queue",
        "postThread": "smooth-scroll-queue",
        "postingPath": "CGEvent.post",
        "queueLength": formatNumber(pendingDistance),
        "queuedInputs": "\(smoothScrollQueuedInputs)",
        "coalescedInputs": "\(smoothScrollCoalescedInputs)",
        "frameCount": "\(smoothScrollFrameCount)",
        "generatedEvents": "\(smoothScrollGeneratedEvents)",
        "droppedFrames": "\(smoothScrollDroppedFrames)",
        "slowFrames": "\(smoothScrollSlowFrames)",
        "zeroOutputFrames": "\(smoothScrollZeroOutputFrames)",
        "frameIntervalMs": formatNumber(frameInterval * 1000),
        "avgFrameIntervalMs": formatNumber(avgFrameInterval * 1000),
        "maxFrameIntervalMs": formatNumber(smoothScrollMaxFrameInterval * 1000),
        "buffer": "\(formatNumber(smoothScrollBuffer.x)),\(formatNumber(smoothScrollBuffer.y))",
        "current": "\(formatNumber(smoothScrollCurrent.x)),\(formatNumber(smoothScrollCurrent.y))",
        "output": "\(formatNumber(outputX)),\(formatNumber(outputY))",
      ])
    fields.merge(extra) { _, new in new }
    return fields
  }

  private func logSyntheticScrollPost(
    mode: String,
    tapLocation: CGEventTapLocation,
    x: Int32,
    y: Int32,
    duration: TimeInterval
  ) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - smoothScrollLastPostLogAt >= 1.0 else { return }
    smoothScrollLastPostLogAt = now
    AppDiagnostics.log(
      "scroll_smooth_synthetic_post_off_main",
      lifecycleFields(
        settings: settings,
        extra: [
          "mode": mode,
          "tap": tapLocationName(tapLocation),
          "x": "\(x)",
          "y": "\(y)",
          "durationMs": formatNumber(duration * 1000),
          "mainThread": "\(Thread.isMainThread)",
          "thread": Thread.current.name ?? "",
        ]))
  }
}

private final class VolumeHotCornerOverlay {
  private let onScroll: (NSEvent) -> Void
  private var panels: [VolumeHotCornerOverlayPanel] = []
  private var frontRefreshTimer: Timer?
  private var activeAppObserver: Any?
  private var lastFrontRefreshLogAt: TimeInterval = 0

  init(onScroll: @escaping (NSEvent) -> Void) {
    self.onScroll = onScroll
  }

  deinit {
    stop()
  }

  func update(settings: ScrollEngineSettings) {
    let frames = overlayFrames(settings: settings)
    if frames.map(\.integral) == panels.map({ $0.frame.integral }) {
      startFrontRefreshWatchdog()
      refreshPanelOrdering(reason: "update")
      return
    }
    stop()
    panels = frames.map { frame in
      let panel = VolumeHotCornerOverlayPanel(contentRect: frame)
      let view = VolumeHotCornerOverlayView(
        frame: NSRect(origin: .zero, size: frame.size),
        onScroll: onScroll,
        onMouseEvent: { [weak panel] event in
          guard let panel else { return }
          panel.passMouseEventThrough(event)
        })
      panel.contentView = view
      panel.orderFrontRegardless()
      return panel
    }
    startFrontRefreshWatchdog()
    AppDiagnostics.log(
      "scroll_overlay_started",
      [
        "screenCount": "\(frames.count)",
        "frames": frames.map(Self.formatRect).joined(separator: ";"),
        "level": "\(VolumeHotCornerOverlayPanel.overlayLevel.rawValue)",
        "visible": panels.map { "\($0.isVisible)" }.joined(separator: ","),
      ])
  }

  func stop() {
    stopFrontRefreshWatchdog()
    guard !panels.isEmpty else { return }
    for panel in panels {
      panel.orderOut(nil)
      panel.close()
    }
    panels.removeAll()
    AppDiagnostics.log("scroll_overlay_stopped")
  }

  private func startFrontRefreshWatchdog() {
    if activeAppObserver == nil {
      activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshPanelOrdering(reason: "active_app_changed")
      }
    }

    guard frontRefreshTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.refreshPanelOrdering(reason: "timer")
    }
    frontRefreshTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    AppDiagnostics.log("scroll_overlay_front_watchdog_started", ["interval": "1.0"])
  }

  private func stopFrontRefreshWatchdog() {
    frontRefreshTimer?.invalidate()
    frontRefreshTimer = nil

    if let activeAppObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
      self.activeAppObserver = nil
    }
  }

  private func refreshPanelOrdering(reason: String) {
    guard !panels.isEmpty else { return }
    for panel in panels {
      panel.level = VolumeHotCornerOverlayPanel.overlayLevel
      panel.orderFrontRegardless()
    }

    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard reason == "active_app_changed" || now - lastFrontRefreshLogAt >= 5 else { return }
    lastFrontRefreshLogAt = now
    AppDiagnostics.log(
      "scroll_overlay_front_refresh",
      [
        "reason": reason,
        "frames": panels.map { Self.formatRect($0.frame) }.joined(separator: ";"),
        "level": panels.map { "\($0.level.rawValue)" }.joined(separator: ","),
        "visible": panels.map { "\($0.isVisible)" }.joined(separator: ","),
      ])
  }

  private func overlayFrames(settings: ScrollEngineSettings) -> [NSRect] {
    NSScreen.screens.map { screen in
      let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
      let width = min(max(screen.frame.width * min(settings.volumeHotCornerWidthRatio, 0.04), 52), 88)
      let height = min(max(menuBarHeight + 4, 24), 38)
      return NSRect(
        x: screen.frame.maxX - width,
        y: screen.frame.maxY - height,
        width: width,
        height: height)
    }
  }

  private static func formatRect(_ rect: NSRect) -> String {
    let values = [rect.minX, rect.minY, rect.width, rect.height].map {
      String(format: "%.0f", Double($0))
    }
    return values.joined(separator: ",")
  }
}

private final class VolumeHotCornerOverlayPanel: NSPanel {
  static let overlayLevel = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    level = Self.overlayLevel
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    canHide = false
    isReleasedWhenClosed = false
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func passMouseEventThrough(_ event: NSEvent) {
    ignoresMouseEvents = true
    AppDiagnostics.log(
      "scroll_overlay_click_passthrough",
      [
        "level": "\(level.rawValue)",
        "point": VolumeHotCornerOverlayView.formatPoint(event.locationInWindow),
      ])
    if let cgEvent = event.cgEvent?.copy() {
      cgEvent.post(tap: .cghidEventTap)
    } else {
      AppDiagnostics.log("scroll_overlay_click_passthrough_failed")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.ignoresMouseEvents = false
    }
  }
}

private final class VolumeHotCornerOverlayView: NSView {
  private let onScroll: (NSEvent) -> Void
  private let onMouseEvent: (NSEvent) -> Void
  private var trackingAreaRef: NSTrackingArea?
  private var lastPointerLogAt: TimeInterval = 0

  init(
    frame frameRect: NSRect,
    onScroll: @escaping (NSEvent) -> Void,
    onMouseEvent: @escaping (NSEvent) -> Void
  ) {
    self.onScroll = onScroll
    self.onMouseEvent = onMouseEvent
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: self,
      userInfo: nil)
    trackingAreaRef = area
    addTrackingArea(area)
    super.updateTrackingAreas()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let result = super.hitTest(point)
    if result != nil {
      logPointerEvent("hit_test", point: point)
    }
    return result
  }

  override func scrollWheel(with event: NSEvent) {
    logPointerEvent("scroll_received", point: event.locationInWindow)
    onScroll(event)
  }

  override func mouseEntered(with event: NSEvent) {
    logPointerEvent("mouse_entered", point: event.locationInWindow)
  }

  override func mouseExited(with event: NSEvent) {
    logPointerEvent("mouse_exited", point: event.locationInWindow)
  }

  override func mouseMoved(with event: NSEvent) {
    logPointerEvent("mouse_moved", point: event.locationInWindow)
  }

  override func mouseDown(with event: NSEvent) {
    onMouseEvent(event)
  }

  override func mouseUp(with event: NSEvent) {
    onMouseEvent(event)
  }

  override func rightMouseDown(with event: NSEvent) {
    onMouseEvent(event)
  }

  override func rightMouseUp(with event: NSEvent) {
    onMouseEvent(event)
  }

  override func otherMouseDown(with event: NSEvent) {
    onMouseEvent(event)
  }

  override func otherMouseUp(with event: NSEvent) {
    onMouseEvent(event)
  }

  private func logPointerEvent(_ reason: String, point: NSPoint) {
    guard AppDiagnostics.isEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard reason == "scroll_received" || now - lastPointerLogAt >= 1.0 else { return }
    lastPointerLogAt = now
    AppDiagnostics.log(
      "scroll_overlay_probe",
      [
        "reason": reason,
        "point": Self.formatPoint(point),
        "windowFrame": window.map { Self.formatRect($0.frame) } ?? "",
        "level": window.map { "\($0.level.rawValue)" } ?? "",
        "visible": window.map { "\($0.isVisible)" } ?? "",
      ])
  }

  fileprivate static func formatPoint(_ point: NSPoint) -> String {
    "\(String(format: "%.0f", Double(point.x))),\(String(format: "%.0f", Double(point.y)))"
  }

  private static func formatRect(_ rect: NSRect) -> String {
    let values = [rect.minX, rect.minY, rect.width, rect.height].map {
      String(format: "%.0f", Double($0))
    }
    return values.joined(separator: ",")
  }
}

final class SystemVolumeController {
  func changeVolume(by delta: Double) -> Double? {
    SystemVolumeRouteGuard.changeVolume(
      by: delta,
      defaultDevice: { [weak self] in self?.defaultOutputDevice() },
      currentVolume: { [weak self] device in self?.currentVolume(device: device) },
      setVolume: { [weak self] device, percent in
        self?.setVolume(percent, device: device) == true
      },
      onRouteChanged: { oldDevice, newDevice in
        AppDiagnostics.log(
          "mouse_volume_output_route_refreshed",
          ["oldDevice": "\(oldDevice)", "newDevice": "\(newDevice)"])
      })
  }

  private func currentVolume(device: AudioDeviceID) -> Double? {
    if let scalar = getVolumeScalar(device: device, element: kAudioObjectPropertyElementMain) {
      return scalar * 100
    }

    let channels = [UInt32(1), UInt32(2)].compactMap { element in
      getVolumeScalar(device: device, element: element)
    }
    guard !channels.isEmpty else { return nil }
    return (channels.reduce(0, +) / Double(channels.count)) * 100
  }

  private func setVolume(_ percent: Double, device: AudioDeviceID) -> Bool {
    let scalar = Float32(min(max(percent / 100, 0), 1))
    if setVolumeScalar(device: device, element: kAudioObjectPropertyElementMain, scalar: scalar) {
      return true
    }
    let left = setVolumeScalar(device: device, element: 1, scalar: scalar)
    let right = setVolumeScalar(device: device, element: 2, scalar: scalar)
    return left || right
  }

  private func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let result = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device)
    guard result == noErr, device != kAudioObjectUnknown else { return nil }
    return device
  }

  private func getVolumeScalar(device: AudioDeviceID, element: AudioObjectPropertyElement)
    -> Double?
  {
    var address = volumeAddress(element: element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var scalar = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar)
    guard result == noErr else { return nil }
    return Double(scalar)
  }

  private func setVolumeScalar(
    device: AudioDeviceID,
    element: AudioObjectPropertyElement,
    scalar: Float32
  ) -> Bool {
    var address = volumeAddress(element: element)
    guard AudioObjectHasProperty(device, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
    else {
      return false
    }
    var value = scalar
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
  }

  private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: element)
  }
}

final class SystemVolumeSettingsAlert {
  private typealias ShowFunction = @convention(c) () -> Void
  private let showFunction: ShowFunction?

  init() {
    let frameworkPath = "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL),
      let symbol = dlsym(handle, "MPVolumeSettingsAlertShow")
    else {
      showFunction = nil
      return
    }
    showFunction = unsafeBitCast(symbol, to: ShowFunction.self)
  }

  func show() -> Bool {
    guard let showFunction else { return false }
    showFunction()
    return true
  }
}

enum VolumeFeedbackPresenter {
  static func show(
    volume: Double,
    alert: SystemVolumeSettingsAlert,
    hud: VolumeOverlayHUD,
    source: String
  ) {
    let systemUIRequested = alert.show()
    let shouldShowHUD = !systemUIRequested || !NSApp.isActive || NSApp.isHidden
    if shouldShowHUD {
      hud.show(volume: volume)
    }
    NotificationCenter.default.post(
      name: .showAixlgVolumeFeedback,
      object: nil,
      userInfo: ["volume": volume, "source": source])
    AppDiagnostics.log(
      "volume_feedback_presented",
      [
        "source": source,
        "systemUI": systemUIRequested ? "requested" : "unavailable",
        "hud": "\(shouldShowHUD)",
        "statusItem": "requested",
        "appActive": "\(NSApp.isActive)",
        "appHidden": "\(NSApp.isHidden)",
        "volume": String(format: "%.0f", volume),
      ])
  }
}

final class VolumeOverlayHUD {
  private var panel: NSPanel?
  private weak var contentView: VolumeHUDView?
  private var hideWorkItem: DispatchWorkItem?

  func show(volume: Double) {
    DispatchQueue.main.async {
      let panel = self.panel ?? self.makePanel()
      let view = self.contentView
      view?.volume = volume
      view?.needsDisplay = true
      self.position(panel: panel)
      panel.alphaValue = 1
      panel.orderFrontRegardless()

      self.hideWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self, weak panel] in
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.16
          panel.animator().alphaValue = 0
        } completionHandler: {
          panel.orderOut(nil)
          self?.hideWorkItem = nil
        }
      }
      self.hideWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.46, execute: workItem)
    }
  }

  private func makePanel() -> NSPanel {
    let view = VolumeHUDView(frame: NSRect(x: 0, y: 0, width: 220, height: 76))
    let panel = VolumeHUDPanel(
      contentRect: view.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.contentView = view
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.canHide = false
    panel.isReleasedWhenClosed = false
    panel.worksWhenModal = true
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .stationary,
      .ignoresCycle,
    ]
    self.panel = panel
    self.contentView = view
    return panel
  }

  private func position(panel: NSPanel) {
    let point = NSEvent.mouseLocation
    let screen = screenContainingPoint(point)
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    let origin = NSPoint(
      x: frame.midX - size.width / 2,
      y: frame.midY - size.height / 2)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }
}

private final class VolumeHUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class VolumeHUDView: NSView {
  var volume: Double = 50

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bounds = bounds
    let background = NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22)
    NSColor.black.withAlphaComponent(0.76).setFill()
    background.fill()

    let icon = volume <= 0 ? "🔇" : "🔊"
    let percent = "\(Int(volume.rounded()))%"
    let text = "\(icon)  \(percent)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 24, weight: .bold),
      .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(x: (bounds.width - textSize.width) / 2, y: 14),
      withAttributes: attributes)

    let barRect = NSRect(x: 24, y: 52, width: bounds.width - 48, height: 8)
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()

    let fillWidth = barRect.width * min(max(volume / 100, 0), 1)
    guard fillWidth > 0 else { return }
    let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
    NSColor.systemTeal.setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
  }
}
