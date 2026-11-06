import AppKit
import ApplicationServices
import Foundation

enum WindowSplitPreference {
  static let key = "windowSplitLeftPercent"
  static let defaultLeftPercent = 60
  static let range = 10...90

  static var leftPercent: Int {
    let value = UserDefaults.standard.object(forKey: key) as? Int ?? defaultLeftPercent
    return range.contains(value) ? value : defaultLeftPercent
  }
}

enum WindowArrangementAction: String, Sendable {
  case leftHalf, rightHalf, topHalf, bottomHalf
  case leftProportional, rightProportional
  case topLeft, topRight, bottomLeft, bottomRight
  case maximize, center, minimize, nativeFullScreen
}

struct WindowArrangementApplication: Equatable, Sendable {
  let pid: Int32
  let launchTime: TimeInterval?
}

struct WindowArrangementScreen: Sendable {
  /// Both rectangles use Accessibility coordinates, with a downward positive Y axis.
  let frame: CGRect
  let visibleFrame: CGRect
}

struct WindowArrangementResult: Sendable {
  enum Status: String, Sendable { case applied, constrained, unsupported, failed }
  let status: Status
  let message: String
  let requestedFrame: CGRect?
  let observedFrame: CGRect?
}

struct WindowArrangementWindow: Sendable {
  let id: String
  let frame: CGRect
  let minimized: Bool
  let fullScreen: Bool?
  let movable: Bool
  let resizable: Bool
}

enum WindowArrangementSelection: Sendable {
  case window(WindowArrangementWindow)
  case unavailable(String)
  case temporarilyUnavailable(String)
}

/// Backend entry points run on the private serial queue; local AppKit work hops to main. AX keeps
/// the exact element alive; it never translates that element into a changing window-array index.
protocol WindowArrangementBackend: AnyObject, Sendable {
  func isCurrent(_ app: WindowArrangementApplication) -> Bool
  func selectWindow(_ app: WindowArrangementApplication) -> WindowArrangementSelection
  func readWindow(_ id: String) -> WindowArrangementWindow?
  func readFrame(_ id: String) -> CGRect?
  func stillOwnsWindow(_ id: String) -> Bool
  func readFullScreen(_ id: String) -> Bool?
  func setSize(_ size: CGSize, window: String) -> Bool
  func setPosition(_ point: CGPoint, window: String) -> Bool
  func setMinimized(_ value: Bool, window: String) -> Bool
  func setFullScreen(_ value: Bool, window: String) -> Bool
  /// nil means this backend needs the checked AX size/position sequence.
  func setFrameDirectly(
    _ frame: CGRect, window: String,
    isValid: @escaping @Sendable () -> Bool
  ) -> Bool?
}

extension WindowArrangementBackend {
  func readFrame(_ id: String) -> CGRect? { readWindow(id)?.frame }
  func stillOwnsWindow(_ id: String) -> Bool { true }
  func readFullScreen(_ id: String) -> Bool? { readWindow(id)?.fullScreen }
  func setFrameDirectly(
    _ frame: CGRect, window: String,
    isValid: @escaping @Sendable () -> Bool
  ) -> Bool? { nil }
}

enum WindowArrangementGeometry {
  static let tolerance: CGFloat = 2

  static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
      && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
  }

  static func workArea(for frame: CGRect, screens: [WindowArrangementScreen]) -> CGRect? {
    let valid = screens.filter { $0.visibleFrame.width > 0 && $0.visibleFrame.height > 0 }
    guard !valid.isEmpty else { return nil }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let largest = valid.max {
      intersectionArea(frame, $0.frame) < intersectionArea(frame, $1.frame)
    }
    if let largest, intersectionArea(frame, largest.frame) > 0 { return largest.visibleFrame }
    return valid.min { distance(center, $0.frame) < distance(center, $1.frame) }?.visibleFrame
  }

  static func target(
    _ action: WindowArrangementAction, current: CGRect, workArea: CGRect
  ) -> CGRect {
    let left = floor(workArea.width / 2)
    let top = floor(workArea.height / 2)
    switch action {
    case .leftHalf:
      return CGRect(x: workArea.minX, y: workArea.minY, width: left, height: workArea.height)
    case .rightHalf:
      return CGRect(
        x: workArea.minX + left, y: workArea.minY,
        width: workArea.width - left, height: workArea.height)
    case .leftProportional, .rightProportional:
      let leftWidth = floor(workArea.width * CGFloat(WindowSplitPreference.leftPercent) / 100)
      let isLeft = action == .leftProportional
      return CGRect(
        x: isLeft ? workArea.minX : workArea.minX + leftWidth, y: workArea.minY,
        width: isLeft ? leftWidth : workArea.width - leftWidth, height: workArea.height)
    case .topHalf:
      return CGRect(x: workArea.minX, y: workArea.minY, width: workArea.width, height: top)
    case .bottomHalf:
      return CGRect(
        x: workArea.minX, y: workArea.minY + top,
        width: workArea.width, height: workArea.height - top)
    case .topLeft:
      return CGRect(x: workArea.minX, y: workArea.minY, width: left, height: top)
    case .topRight:
      return CGRect(
        x: workArea.minX + left, y: workArea.minY,
        width: workArea.width - left, height: top)
    case .bottomLeft:
      return CGRect(
        x: workArea.minX, y: workArea.minY + top,
        width: left, height: workArea.height - top)
    case .bottomRight:
      return CGRect(
        x: workArea.minX + left, y: workArea.minY + top,
        width: workArea.width - left, height: workArea.height - top)
    case .center:
      return CGRect(
        x: workArea.minX + workArea.width * 0.14, y: workArea.minY + workArea.height * 0.14,
        width: workArea.width * 0.72, height: workArea.height * 0.72)
    case .maximize, .minimize, .nativeFullScreen:
      return workArea
    }
  }

  static func aligned(
    size: CGSize, action: WindowArrangementAction, desired: CGRect, workArea: CGRect
  ) -> CGRect {
    let x: CGFloat
    let y: CGFloat
    switch action {
    case .rightHalf, .rightProportional, .topRight, .bottomRight: x = max(workArea.minX, workArea.maxX - size.width)
    case .center: x = workArea.midX - size.width / 2
    default: x = desired.minX
    }
    switch action {
    case .bottomHalf, .bottomLeft, .bottomRight: y = max(workArea.minY, workArea.maxY - size.height)
    case .center: y = workArea.midY - size.height / 2
    default: y = desired.minY
    }
    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }

  private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let rect = a.intersection(b)
    return rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
  }

  private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    let dx = point.x - min(max(point.x, rect.minX), rect.maxX)
    let dy = point.y - min(max(point.y, rect.minY), rect.maxY)
    return dx * dx + dy * dy
  }
}

final class WindowArrangementController: @unchecked Sendable {
  typealias Completion = @MainActor @Sendable (WindowArrangementResult) -> Void
  typealias ScreenProvider = @MainActor @Sendable () -> [WindowArrangementScreen]

  private struct Request: Sendable {
    let generation: UInt64
    let action: WindowArrangementAction
    let application: WindowArrangementApplication
    let screens: [WindowArrangementScreen]
    let screenProvider: ScreenProvider?
    let completion: Completion
  }

  private struct Placement: Sendable {
    let request: Request
    let windowID: String
    let desired: CGRect
    let workArea: CGRect
    let deadline: TimeInterval
    let positionOnly: Bool
    let originalSize: CGSize
    let alignment: WindowArrangementAction
    let supersedesResize: Bool
    let settleUntil: TimeInterval
  }

  private let queue = DispatchQueue(label: "cn.tlww.aixlg.window-arrangement", qos: .userInitiated)
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var submission: UInt64?
  private var reportedGeneration: UInt64?
  private let backend: any WindowArrangementBackend
  // Only in-flight work is tracked; layout actions never depend on press parity or history.
  private var lastConstrainedPlacement: (key: String, desired: CGRect, observed: CGRect)?
  private var pendingPlacementKey: String?
  private var lastResize: (key: String, size: CGSize, time: TimeInterval, accepted: Bool)?
  private var lastMove: (key: String, point: CGPoint, time: TimeInterval, accepted: Bool)?
  private var fullScreenWrites: [String: (target: Bool, generation: UInt64)] = [:]

  init(backend: any WindowArrangementBackend = AXWindowArrangementBackend()) {
    self.backend = backend
  }

  func submit(
    action: WindowArrangementAction,
    application: WindowArrangementApplication,
    screens: [WindowArrangementScreen],
    screenProvider: ScreenProvider? = nil,
    completion: @escaping Completion
  ) {
    lock.lock()
    generation &+= 1
    let next = generation
    submission = next
    lock.unlock()
    let request = Request(
      generation: next, action: action, application: application, screens: screens,
      screenProvider: screenProvider, completion: completion)
    queue.async { [weak self] in self?.begin(request) }
  }

  func cancel() {
    lock.lock()
    generation &+= 1
    submission = nil
    lock.unlock()
    queue.async { [weak self] in
      self?.pendingPlacementKey = nil
      self?.lastResize = nil
      self?.lastMove = nil
    }
  }

  private func owns(_ request: Request) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == request.generation
  }

  private func valid(_ request: Request) -> Bool {
    lock.lock()
    let pending = generation == request.generation && submission == request.generation
    lock.unlock()
    guard pending else { return false }
    guard backend.isCurrent(request.application) else {
      finish(request, .failed, "当前 App 已变化，已停止调整原窗口。")
      return false
    }
    return owns(request)
  }

  private func begin(_ request: Request, selectionDeadline: TimeInterval? = nil) {
    guard owns(request) else { return }
    guard backend.isCurrent(request.application) else {
      finish(request, .failed, "原窗口所在的 App 已关闭或重新启动。")
      return
    }
    let window: WindowArrangementWindow
    switch backend.selectWindow(request.application) {
    case .window(let selected): window = selected
    case .unavailable(let message):
      finish(request, .unsupported, message)
      return
    case .temporarilyUnavailable(let message):
      let deadline = selectionDeadline ?? uptime + 2
      guard uptime < deadline else {
        finish(request, .failed, message)
        return
      }
      queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
        self?.begin(request, selectionDeadline: deadline)
      }
      return
    }
    guard valid(request) else { return }
    if request.action == .minimize {
      if window.fullScreen == true || fullScreenWrites[window.id] != nil {
        changeFullScreen(
          request, windowID: window.id, desired: false,
          deadline: uptime + 3, remainingWrites: 3, continuePlacement: true)
        return
      }
      minimize(request, windowID: window.id)
      return
    }
    if request.action == .nativeFullScreen {
      guard window.fullScreen != nil else {
        finish(request, .unsupported, "这个窗口不支持系统全屏。")
        return
      }
      changeFullScreen(
        request, windowID: window.id, desired: true,
        deadline: uptime + 3, remainingWrites: 3, continuePlacement: false)
      return
    }
    if window.fullScreen == true || fullScreenWrites[window.id] != nil {
      changeFullScreen(
        request, windowID: window.id, desired: false,
        deadline: uptime + 3, remainingWrites: 3, continuePlacement: true)
    } else {
      place(request, window: window, screens: request.screens)
    }
  }

  private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func minimize(_ request: Request, windowID: String) {
    guard valid(request) else { return }
    guard backend.stillOwnsWindow(windowID) else {
      finish(request, .failed, "当前窗口已变化，已停止调整。")
      return
    }
    // Checking exact focus can itself block in AX; a newer request may arrive while it runs.
    guard valid(request) else { return }
    guard backend.setMinimized(true, window: windowID) else {
      finish(request, .unsupported, "这个窗口不支持最小化。")
      return
    }
    observeMinimized(request, windowID: windowID, remaining: 8)
  }

  private func observeMinimized(_ request: Request, windowID: String, remaining: Int) {
    guard valid(request) else { return }
    if backend.readWindow(windowID)?.minimized == true {
      finish(request, .applied, "已最小化窗口。")
    } else if remaining > 0 {
      queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
        self?.observeMinimized(request, windowID: windowID, remaining: remaining - 1)
      }
    } else {
      finish(request, .failed, "窗口没有完成最小化，请重试。")
    }
  }

  private func changeFullScreen(
    _ request: Request, windowID: String, desired: Bool, deadline: TimeInterval,
    remainingWrites: Int, continuePlacement: Bool, stableSamples: Int = 0
  ) {
    guard valid(request) else { return }
    let observed = backend.readFullScreen(windowID)
    let pending = fullScreenWrites[windowID]
    let previousTransitionMayArrive =
      pending.map {
        $0.target != desired
      } ?? false
    if observed == desired && !previousTransitionMayArrive
      && (pending == nil || stableSamples >= 1)
    {
      fullScreenWrites.removeValue(forKey: windowID)
      if continuePlacement {
        refreshScreensAndPlace(request, windowID: windowID)
      } else {
        finish(request, .applied, desired ? "已进入全屏。" : "已退出全屏。")
      }
      return
    }
    guard uptime < deadline else {
      finish(request, .failed, "系统全屏切换尚未完成，请稍后再试。")
      return
    }
    // A temporarily absent AX value during the Space animation is not an unsupported window.
    if observed != nil && observed != desired && remainingWrites > 0
      && (pending?.target != desired || pending?.generation != request.generation)
    {
      guard valid(request) else { return }
      let exactWindow = backend.stillOwnsWindow(windowID)
      if exactWindow && owns(request)
        && backend.setFullScreen(desired, window: windowID)
      {
        fullScreenWrites[windowID] = (desired, request.generation)
      }
    }
    let samples = observed == desired && !previousTransitionMayArrive ? stableSamples + 1 : 0
    queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.changeFullScreen(
        request, windowID: windowID, desired: desired, deadline: deadline,
        remainingWrites: observed != nil && observed != desired
          ? max(0, remainingWrites - 1) : remainingWrites,
        continuePlacement: continuePlacement, stableSamples: samples)
    }
  }

  private func refreshScreensAndPlace(
    _ request: Request, windowID: String, remainingReads: Int = 12
  ) {
    // Space/Dock transitions can trail AXFullScreen. Refresh on the main thread after the exit
    // observation, then send only value snapshots back to the worker.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self, self.owns(request) else { return }
      let screens = request.screenProvider?() ?? request.screens
      self.queue.async { [weak self] in
        guard let self, self.valid(request) else { return }
        guard let window = self.backend.readWindow(windowID) else {
          if remainingReads > 0 {
            self.refreshScreensAndPlace(
              request, windowID: windowID, remainingReads: remainingReads - 1)
          } else {
            self.finish(request, .failed, "全屏已退出，但窗口位置暂时无法读取。")
          }
          return
        }
        self.place(request, window: window, screens: screens, afterFullScreen: true)
      }
    }
  }

  private func place(
    _ request: Request, window: WindowArrangementWindow, screens: [WindowArrangementScreen],
    afterFullScreen: Bool = false
  ) {
    if request.action == .minimize {
      minimize(request, windowID: window.id)
      return
    }
    guard valid(request),
      let area = WindowArrangementGeometry.workArea(for: window.frame, screens: screens)
    else {
      finish(request, .failed, "无法读取窗口所在屏幕的可用范围。")
      return
    }
    guard window.movable else {
      finish(request, .unsupported, "这个窗口不支持移动。")
      return
    }
    let restoreKey = key(request.application, window.id)
    let desired = WindowArrangementGeometry.target(
      request.action, current: window.frame, workArea: area)
    let alignment = request.action
    let placement = Placement(
      request: request, windowID: window.id, desired: desired, workArea: area,
      deadline: uptime + 3.4, positionOnly: !window.resizable,
      originalSize: window.frame.size, alignment: alignment,
      supersedesResize: pendingPlacementKey == restoreKey,
      settleUntil: uptime + (pendingPlacementKey == restoreKey ? 1.5 : (afterFullScreen ? 1 : 0)))
    pendingPlacementKey = restoreKey
    if WindowArrangementGeometry.matches(window.frame, desired)
      && !placement.supersedesResize && !afterFullScreen
    {
      completePlacement(placement, observed: window.frame, constrained: false)
      return
    }
    // Repeating a proven application size limit must not turn into a failure merely because
    // the window is already at that limit. This caches only the last observed constraint,
    // never a restore target or a toggle state.
    if !placement.supersedesResize && !afterFullScreen,
      let limited = lastConstrainedPlacement, limited.key == restoreKey,
      WindowArrangementGeometry.matches(limited.desired, desired),
      WindowArrangementGeometry.matches(limited.observed, window.frame)
    {
      completePlacement(placement, observed: window.frame, constrained: true)
      return
    }
    lastConstrainedPlacement = nil
    let actualTarget =
      window.resizable
      ? desired
      : WindowArrangementGeometry.aligned(
        size: window.frame.size, action: alignment, desired: desired, workArea: area)
    startPlacement(placement, current: window.frame, target: actualTarget)
  }

  private func hasRoom(_ frame: CGRect, for target: CGRect, in area: CGRect) -> Bool {
    frame.minX + target.width <= area.maxX + WindowArrangementGeometry.tolerance
      && frame.minY + target.height <= area.maxY + WindowArrangementGeometry.tolerance
      && frame.minX >= area.minX - WindowArrangementGeometry.tolerance
      && frame.minY >= area.minY - WindowArrangementGeometry.tolerance
  }

  private func prepareRoom(
    _ placement: Placement, current: CGRect, target: CGRect,
    completion: @escaping @Sendable (CGRect) -> Void
  ) {
    guard valid(placement.request) else { return }
    let area = placement.workArea
    // Initial placement AND late geometry correction need room before enlarging.
    // AppKit caps the requested size relative to the window's current origin.
    guard !placement.positionOnly && !hasRoom(current, for: target, in: area) else {
      completion(current)
      return
    }
    guard uptime < placement.deadline else {
      finish(
        placement.request, .failed, "窗口没有移到可调整的位置，请重试。",
        requested: placement.desired, observed: current)
      return
    }
    let origin = CGPoint(
      x: max(area.minX, min(target.minX, area.maxX - max(current.width, target.width))),
      y: max(area.minY, min(target.minY, area.maxY - max(current.height, target.height))))
    write(placement, frame: CGRect(origin: origin, size: current.size), positionOnly: true)
    guard owns(placement.request) else { return }
    guard backend.stillOwnsWindow(placement.windowID),
      owns(placement.request), let frame = backend.readFrame(placement.windowID),
      owns(placement.request)
    else {
      finish(placement.request, .failed, "当前窗口已变化，已停止调整。")
      return
    }
    // Synchronous apps can proceed immediately; only an unfinished move needs a timer.
    if hasRoom(frame, for: target, in: area) {
      completion(frame)
      return
    }
    queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in
      guard let self, self.valid(placement.request) else { return }
      guard self.backend.stillOwnsWindow(placement.windowID), self.owns(placement.request),
        let observed = self.backend.readFrame(placement.windowID), self.owns(placement.request)
      else {
        self.finish(placement.request, .failed, "当前窗口已变化，已停止调整。")
        return
      }
      self.prepareRoom(placement, current: observed, target: target, completion: completion)
    }
  }

  private func startPlacement(_ placement: Placement, current: CGRect, target: CGRect) {
    // Our own NSWindow can change both components in one non-animated main-thread transaction.
    // External apps still need the size-first path and observed geometry before moving right.
    if let accepted = backend.setFrameDirectly(
      target, window: placement.windowID,
      isValid: { [weak self] in self?.owns(placement.request) == true })
    {
      guard valid(placement.request) else { return }
      guard accepted else {
        finish(placement.request, .failed, "当前窗口已变化，已停止调整。")
        return
      }
      if let observed = backend.readFrame(placement.windowID), valid(placement.request) {
        if WindowArrangementGeometry.matches(observed, target) {
          completePlacement(placement, observed: observed, constrained: placement.positionOnly)
          return
        }
        // The direct local setter has already applied native minimum/maximum sizes.
        // Align that proven size now rather than waiting for AX constraint retries.
        let aligned = WindowArrangementGeometry.aligned(
          size: observed.size,
          action: placement.alignment, desired: target, workArea: placement.workArea)
        if backend.setFrameDirectly(
          aligned, window: placement.windowID,
          isValid: { [weak self] in self?.owns(placement.request) == true }) == true,
          let actual = backend.readFrame(placement.windowID), valid(placement.request),
          WindowArrangementGeometry.matches(actual, aligned)
        {
          completePlacement(placement, observed: actual, constrained: true)
          return
        }
      }
      observe(
        placement, previousFrame: nil, lastSizeWrite: uptime,
        sizeWrites: 1, acceptedSize: true)
      return
    }
    prepareRoom(placement, current: current, target: target) { [weak self] ready in
      guard let self, self.valid(placement.request) else { return }
      let needsSize = !placement.positionOnly && ready.size != target.size
      let acceptedSize = self.write(
        placement, frame: target, positionOnly: !needsSize,
        reusePendingSize: placement.supersedesResize)
      let sizeTime =
        self.lastResize.flatMap {
          $0.key == self.key(placement.request.application, placement.windowID)
            && $0.size == target.size
            ? $0.time : nil
        } ?? self.uptime
      self.observe(
        placement, previousFrame: nil, lastSizeWrite: sizeTime,
        sizeWrites: needsSize ? 1 : 0, acceptedSize: acceptedSize)
    }
  }

  @discardableResult
  private func write(
    _ placement: Placement, frame: CGRect, positionOnly: Bool = false,
    reusePendingSize: Bool = false
  ) -> Bool {
    let request = placement.request
    // AX success is acceptance, not geometry. Do not move a still-wide window to the right-half
    // origin: some apps clamp that move or restore their maximized size during the transition.
    guard valid(request), backend.stillOwnsWindow(placement.windowID), owns(request) else {
      return false
    }
    let resizeKey = key(request.application, placement.windowID)
    let accepted: Bool
    if positionOnly {
      accepted = true
    } else if reusePendingSize, let previous = lastResize,
      previous.key == resizeKey, previous.size == frame.size,
      previous.accepted && uptime - previous.time < 0.9
    {
      // Repeating the same intent must not restart the target application's resize animation.
      accepted = previous.accepted
    } else {
      accepted = backend.setSize(frame.size, window: placement.windowID)
      lastResize = (resizeKey, frame.size, uptime, accepted)
    }
    guard owns(request) else { return accepted }
    if !positionOnly {
      guard let observed = backend.readFrame(placement.windowID), owns(request),
        sameSize(observed.size, frame.size)
      else { return accepted }
    }
    // AX reads and exact-focus checks can block; recheck the generation after each boundary.
    guard valid(request), backend.stillOwnsWindow(placement.windowID), owns(request) else {
      return false
    }
    if let previous = lastMove, previous.key == resizeKey, previous.point == frame.origin,
      previous.accepted && uptime - previous.time < 0.9
    {
      return accepted
    }
    let moved = backend.setPosition(frame.origin, window: placement.windowID)
    lastMove = (resizeKey, frame.origin, uptime, moved)
    return accepted
  }

  private func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
    abs(a.width - b.width) <= WindowArrangementGeometry.tolerance
      && abs(a.height - b.height) <= WindowArrangementGeometry.tolerance
  }

  private func observe(
    _ placement: Placement, previousFrame: CGRect?, lastSizeWrite: TimeInterval,
    sizeWrites: Int, acceptedSize: Bool, reachedDesired: Bool = false,
    settledSizes: [CGSize] = [], reported: Bool = false, eagerRetryUsed: Bool = false,
    eagerMoveRetryUsed: Bool = false
  ) {
    // Follow unfinished geometry on the next display-frame scale, then back off once applied.
    queue.asyncAfter(deadline: .now() + (reported ? 0.06 : 0.016)) { [weak self] in
      guard let self, self.valid(placement.request) else { return }
      guard self.backend.stillOwnsWindow(placement.windowID) else {
        self.finish(placement.request, .failed, "当前窗口已变化，已停止调整。")
        return
      }
      guard self.owns(placement.request) else { return }
      guard let frame = self.backend.readFrame(placement.windowID) else {
        self.finish(placement.request, .failed, "原窗口已关闭，已停止调整。")
        return
      }
      guard self.owns(placement.request) else { return }
      let now = self.uptime
      let matchesDesired = WindowArrangementGeometry.matches(frame, placement.desired)
      let stable =
        previousFrame.map { WindowArrangementGeometry.matches($0, frame) } ?? false
      let sizeStable = previousFrame.map { self.sameSize($0.size, frame.size) } ?? false
      let sizeDiffers = !self.sameSize(frame.size, placement.desired.size)
      let sizeChanged = !self.sameSize(frame.size, placement.originalSize)
      var nextReported = reported
      if matchesDesired && stable {
        let finished = now >= placement.settleUntil
        self.completePlacement(
          placement, observed: frame, constrained: false, finalize: finished, notify: !reported)
        if finished { return }
        // Return success promptly, but retain a cancellable tail watch for late old AX writes.
        nextReported = true
      }
      // A limit is only inferred after repeated, spaced size attempts converge. An intermediate
      // animation frame or a single accepted-but-ignored request is not a minimum size.
      let constrained =
        placement.positionOnly
        || (settledSizes.count >= 2
          && settledSizes.allSatisfy {
            self.sameSize($0, frame.size)
          } && now - lastSizeWrite >= 0.9 && sizeStable && sizeChanged && acceptedSize)
      let aligned = WindowArrangementGeometry.aligned(
        size: frame.size, action: placement.alignment,
        desired: placement.desired, workArea: placement.workArea)
      if sizeDiffers && constrained
        && WindowArrangementGeometry.matches(frame, aligned) && stable
        && now >= placement.settleUntil
      {
        self.completePlacement(placement, observed: frame, constrained: true, notify: !reported)
        return
      }
      guard now < placement.deadline else {
        // A rejected resize must not leave an oversized window clipped beyond the target edge.
        if !WindowArrangementGeometry.matches(frame, aligned) {
          self.write(placement, frame: aligned, positionOnly: true)
        }
        self.finish(
          placement.request, .failed, "窗口未完成调整，可能正忙或受到应用限制。",
          requested: placement.desired, observed: frame
        )
        return
      }
      var nextEagerMoveRetryUsed = eagerMoveRetryUsed
      let eagerRetry =
        placement.supersedesResize && !eagerRetryUsed && sizeStable
        && now - lastSizeWrite >= 0.24
      if sizeDiffers && !placement.positionOnly
        && ((reachedDesired && !matchesDesired)
          || eagerRetry
          || (sizeWrites < 3 && sizeStable && now - lastSizeWrite >= 0.9))
      {
        // A late old position can accompany the old size. Apply the same room check as
        // initial placement, without resetting the deadline, callback or retry budget.
        let nextSettled =
          sizeStable && now - lastSizeWrite >= 0.9
            && self.hasRoom(frame, for: placement.desired, in: placement.workArea)
          ? settledSizes + [frame.size] : settledSizes
        let retryReported = nextReported
        self.prepareRoom(placement, current: frame, target: placement.desired) {
          [weak self] ready in
          guard let self, self.valid(placement.request) else { return }
          let accepted = self.write(placement, frame: placement.desired)
          self.observe(
            placement, previousFrame: ready, lastSizeWrite: self.uptime,
            sizeWrites: eagerRetry ? sizeWrites : sizeWrites + 1, acceptedSize: accepted,
            reachedDesired: false, settledSizes: nextSettled, reported: retryReported,
            eagerRetryUsed: eagerRetryUsed || eagerRetry, eagerMoveRetryUsed: eagerMoveRetryUsed)
        }
        return
      } else if !matchesDesired && (!sizeDiffers || constrained) {
        if placement.supersedesResize && !eagerMoveRetryUsed, let pending = self.lastMove,
          now - pending.time >= 0.24 && stable
        {
          self.lastMove = nil
          nextEagerMoveRetryUsed = true
        }
        self.write(placement, frame: sizeDiffers ? aligned : placement.desired, positionOnly: true)
      }
      self.observe(
        placement, previousFrame: frame, lastSizeWrite: lastSizeWrite,
        sizeWrites: sizeWrites, acceptedSize: acceptedSize,
        reachedDesired: reachedDesired || matchesDesired,
        settledSizes: settledSizes, reported: nextReported, eagerRetryUsed: eagerRetryUsed,
        eagerMoveRetryUsed: nextEagerMoveRetryUsed)
    }
  }

  private func completePlacement(
    _ placement: Placement, observed: CGRect, constrained: Bool,
    finalize: Bool = true, notify: Bool = true
  ) {
    // AX reads may return after a newer press; stale success must not clear its restore state.
    guard owns(placement.request) else { return }
    lastResize = nil
    lastMove = nil
    lastConstrainedPlacement =
      constrained
      ? (key(placement.request.application, placement.windowID), placement.desired, observed) : nil
    finish(
      placement.request, constrained ? .constrained : .applied,
      constrained ? "已按方向对齐；这个 App 限制了窗口大小。" : "窗口已调整。",
      requested: placement.desired, observed: observed, finalize: finalize, notify: notify)
  }

  private func key(_ app: WindowArrangementApplication, _ window: String) -> String {
    let launch = app.launchTime.map { String($0) } ?? "unknown"
    return "\(app.pid):\(launch):\(window)"
  }

  private func finish(
    _ request: Request, _ status: WindowArrangementResult.Status, _ message: String,
    requested: CGRect? = nil, observed: CGRect? = nil,
    finalize: Bool = true, notify: Bool = true
  ) {
    guard owns(request) else { return }
    if finalize {
      pendingPlacementKey = nil
      lastResize = nil
      lastMove = nil
      lock.lock()
      if submission == request.generation { submission = nil }
      lock.unlock()
    }
    guard notify, reportedGeneration != request.generation else { return }
    reportedGeneration = request.generation
    let result = WindowArrangementResult(
      status: status, message: message, requestedFrame: requested, observedFrame: observed)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.owns(request) else { return }
      request.completion(result)
    }
  }
}

/// AX calls targeting this process can synchronously enter AppKit on the calling thread.
/// Never send our own windows through the external-process AX path, including reads.
final class LocalWindowArrangementBackend: WindowArrangementBackend, @unchecked Sendable {
  private final class Observations: @unchecked Sendable {
    let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
  }
  @MainActor private final class Reference {
    weak var window: NSWindow?
    var transitioning = false
    private var observations: Observations?
    init(_ window: NSWindow) {
      self.window = window
      let changes: [(Notification.Name, Bool)] = [
        (NSWindow.willEnterFullScreenNotification, true),
        (NSWindow.willExitFullScreenNotification, true),
        (NSWindow.didEnterFullScreenNotification, false),
        (NSWindow.didExitFullScreenNotification, false),
      ]
      observations = Observations(
        changes.map { name, transitioning in
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.transitioning = transitioning }
          }
        })
    }
  }
  @MainActor private var windows: [String: Reference] = [:]

  func handles(_ id: String) -> Bool { id.hasPrefix("local:") }

  private func onMain<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { body() }
  }

  func isCurrent(_ app: WindowArrangementApplication) -> Bool {
    onMain {
      app.pid == ProcessInfo.processInfo.processIdentifier && NSApp.isActive && !NSApp.isHidden
        && (app.launchTime == nil
          || app.launchTime == NSRunningApplication.current.launchDate?.timeIntervalSince1970)
    }
  }

  @MainActor private func focusedWindow() -> NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

  @MainActor private func usable(_ window: NSWindow) -> Bool {
    NSApp.isActive && !NSApp.isHidden && window.isVisible && !window.isMiniaturized
      && !(window is NSPanel) && window.sheetParent == nil && window.attachedSheet == nil
      && NSApp.modalWindow == nil
  }

  @MainActor private func selected(_ id: String) -> NSWindow? {
    guard let reference = windows[id], !reference.transitioning,
      let window = reference.window, focusedWindow() === window, usable(window)
    else {
      return nil
    }
    return window
  }

  // AX has a top-left origin; AppKit has a bottom-left origin on the primary display.
  @MainActor private func converted(_ frame: CGRect) -> CGRect {
    CGRect(
      x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
      width: frame.width, height: frame.height)
  }

  func selectWindow(_ app: WindowArrangementApplication) -> WindowArrangementSelection {
    guard isCurrent(app) else { return .unavailable("当前 App 没有可见窗口。") }
    return onMain {
      guard let window = self.focusedWindow(), self.usable(window) else {
        return .unavailable("请先关闭当前对话框，再调整窗口。")
      }
      self.windows = self.windows.filter { $0.value.window != nil }
      let id =
        self.windows.first { $0.value.window === window }?.key
        ?? "local:\(UUID().uuidString)"
      if self.windows[id] == nil { self.windows[id] = Reference(window) }
      guard self.windows[id]?.transitioning != true else {
        return .temporarilyUnavailable("系统全屏切换中，请稍候。")
      }
      return .window(self.snapshot(window, id: id))
    }
  }

  @MainActor private func snapshot(_ window: NSWindow, id: String) -> WindowArrangementWindow {
    .init(
      id: id, frame: converted(window.frame), minimized: window.isMiniaturized,
      fullScreen: window.styleMask.contains(.fullScreen), movable: window.isMovable,
      resizable: window.styleMask.contains(.resizable))
  }

  func readWindow(_ id: String) -> WindowArrangementWindow? {
    onMain {
      guard let reference = self.windows[id], !reference.transitioning,
        let window = reference.window
      else { return nil }
      return self.snapshot(window, id: id)
    }
  }

  func readFrame(_ id: String) -> CGRect? {
    onMain { self.windows[id]?.window.map { self.converted($0.frame) } }
  }

  func stillOwnsWindow(_ id: String) -> Bool { onMain { self.selected(id) != nil } }

  func readFullScreen(_ id: String) -> Bool? {
    onMain {
      guard let reference = self.windows[id], !reference.transitioning else { return nil }
      return reference.window?.styleMask.contains(.fullScreen)
    }
  }

  @MainActor private func apply(_ frame: CGRect, to window: NSWindow) {
    let minimum = window.frameRect(
      forContentRect: CGRect(origin: .zero, size: window.contentMinSize)
    ).size
    let maximum = window.frameRect(
      forContentRect: CGRect(origin: .zero, size: window.contentMaxSize)
    ).size
    var limited = frame
    if window.styleMask.contains(.resizable) {
      limited.size.width = max(
        max(window.minSize.width, minimum.width),
        min(frame.width, min(window.maxSize.width, maximum.width)))
      limited.size.height = max(
        max(window.minSize.height, minimum.height),
        min(frame.height, min(window.maxSize.height, maximum.height)))
    } else {
      limited.size = window.frame.size
    }
    window.setFrame(converted(limited), display: true, animate: false)
  }

  func setFrameDirectly(
    _ frame: CGRect, window id: String,
    isValid: @escaping @Sendable () -> Bool
  ) -> Bool? {
    onMain {
      // Recheck after the main-queue hop: a newer key or focus change may already be queued.
      guard isValid(), let window = self.selected(id), window.isMovable else { return false }
      self.apply(frame, to: window)
      return true
    }
  }

  func setSize(_ size: CGSize, window id: String) -> Bool {
    onMain {
      guard let window = self.selected(id), window.styleMask.contains(.resizable) else {
        return false
      }
      var frame = self.converted(window.frame)
      frame.size = size
      self.apply(frame, to: window)
      return true
    }
  }

  func setPosition(_ point: CGPoint, window id: String) -> Bool {
    onMain {
      guard let window = self.selected(id), window.isMovable else { return false }
      self.apply(CGRect(origin: point, size: window.frame.size), to: window)
      return true
    }
  }

  func setMinimized(_ value: Bool, window id: String) -> Bool {
    onMain {
      guard let window = self.selected(id), window.styleMask.contains(.miniaturizable) else {
        return false
      }
      if value { window.miniaturize(nil) } else { window.deminiaturize(nil) }
      return true
    }
  }

  func setFullScreen(_ value: Bool, window id: String) -> Bool {
    onMain {
      guard let window = self.selected(id), window.styleMask.contains(.resizable),
        !window.collectionBehavior.contains(.fullScreenAuxiliary),
        !window.collectionBehavior.contains(.fullScreenNone)
      else { return false }
      if window.styleMask.contains(.fullScreen) != value { window.toggleFullScreen(nil) }
      return true
    }
  }
}

final class AXWindowArrangementBackend: WindowArrangementBackend, @unchecked Sendable {
  private let local = LocalWindowArrangementBackend()
  private struct Entry {
    let app: WindowArrangementApplication
    let element: AXUIElement
  }
  private var entries: [String: Entry] = [:]
  private var nextID: UInt64 = 0
  private let timeout: Float = 0.15

  func isCurrent(_ app: WindowArrangementApplication) -> Bool {
    guard sameProcess(app), let running = NSRunningApplication(processIdentifier: app.pid) else {
      return false
    }
    return running.isActive && !running.isHidden
  }

  private func sameProcess(_ app: WindowArrangementApplication) -> Bool {
    guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated
    else {
      return false
    }
    guard let expected = app.launchTime else { return true }
    return running.launchDate?.timeIntervalSince1970 == expected
  }

  func selectWindow(_ app: WindowArrangementApplication) -> WindowArrangementSelection {
    if app.pid == ProcessInfo.processInfo.processIdentifier { return local.selectWindow(app) }
    guard isCurrent(app), NSRunningApplication(processIdentifier: app.pid)?.isHidden != true else {
      return .unavailable("当前 App 没有可见窗口。")
    }
    let element = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(element, timeout)
    let selection = intendedWindow(element)
    if selection.temporary { return .temporarilyUnavailable("当前窗口正在变化，请稍后重试。") }
    // A focused dialog/sheet is intentional: do not silently resize its parent or another window.
    guard let chosen = selection.window else { return .unavailable("没有找到当前窗口。") }
    AXUIElementSetMessagingTimeout(chosen, timeout)
    guard
      let details = attributes(
        chosen, [kAXRoleAttribute, kAXSubroleAttribute, "AXSheets", kAXMinimizedAttribute]),
      let role = details[kAXRoleAttribute] as? String
    else {
      return .temporarilyUnavailable("当前窗口暂时没有响应，请稍后重试。")
    }
    guard role == kAXWindowRole else {
      return .unavailable("请先关闭当前对话框，再调整窗口。")
    }
    let subrole = details[kAXSubroleAttribute] as? String
    guard subrole == nil || subrole == kAXStandardWindowSubrole else {
      return .unavailable("当前对话框或工具窗口不适合分屏。")
    }
    if let sheets = details["AXSheets"] as? [AXUIElement], !sheets.isEmpty {
      return .unavailable("请先关闭当前对话框，再调整窗口。")
    }
    guard bool(details[kAXMinimizedAttribute]) != true else {
      return .unavailable("请先恢复当前窗口，再调整位置。")
    }
    let existing = entries.first { $0.value.app == app && CFEqual($0.value.element, chosen) }?.key
    let id: String
    if let existing {
      id = existing
    } else {
      nextID &+= 1
      id = "\(app.pid):\(nextID)"
      entries = entries.filter { sameProcess($0.value.app) }
      entries[id] = Entry(app: app, element: chosen)
    }
    guard let window = readWindow(id) else {
      return .temporarilyUnavailable("当前窗口暂时无法读取，请稍后重试。")
    }
    return .window(window)
  }

  func readWindow(_ id: String) -> WindowArrangementWindow? {
    if local.handles(id) { return local.readWindow(id) }
    guard let entry = entries[id], isCurrent(entry.app),
      let values = attributes(
        entry.element,
        [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen"]),
      let frame = frame(values),
      let movable = settable(entry.element, kAXPositionAttribute),
      let resizable = settable(entry.element, kAXSizeAttribute)
    else { return nil }
    return WindowArrangementWindow(
      id: id, frame: frame,
      minimized: bool(values[kAXMinimizedAttribute]) == true,
      fullScreen: bool(values["AXFullScreen"]), movable: movable, resizable: resizable)
  }

  func readFrame(_ id: String) -> CGRect? {
    if local.handles(id) { return local.readFrame(id) }
    guard let entry = entries[id], isCurrent(entry.app),
      let values = attributes(entry.element, [kAXPositionAttribute, kAXSizeAttribute])
    else { return nil }
    return frame(values)
  }

  private func frame(_ values: [String: CFTypeRef]) -> CGRect? {
    guard let positionValue = values[kAXPositionAttribute],
      let sizeValue = values[kAXSizeAttribute],
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
      origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  func stillOwnsWindow(_ id: String) -> Bool {
    if local.handles(id) { return local.stillOwnsWindow(id) }
    guard let entry = entries[id], isCurrent(entry.app) else { return false }
    let appElement = AXUIElementCreateApplication(entry.app.pid)
    AXUIElementSetMessagingTimeout(appElement, timeout)
    let selection = intendedWindow(appElement)
    guard !selection.temporary, let target = selection.window, CFEqual(target, entry.element) else {
      return false
    }
    AXUIElementSetMessagingTimeout(target, timeout)
    guard let values = attributes(target, [kAXMinimizedAttribute, "AXSheets"]),
      bool(values[kAXMinimizedAttribute]) != true
    else { return false }
    if let sheets = values["AXSheets"] as? [AXUIElement], !sheets.isEmpty {
      return false
    }
    return true
  }

  func readFullScreen(_ id: String) -> Bool? {
    if local.handles(id) { return local.readFullScreen(id) }
    guard let entry = entries[id], isCurrent(entry.app) else { return nil }
    return boolean(entry.element, "AXFullScreen")
  }

  func setSize(_ size: CGSize, window: String) -> Bool {
    if local.handles(window) { return local.setSize(size, window: window) }
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return false }
    return set(value, attribute: kAXSizeAttribute, window: window)
  }

  func setPosition(_ point: CGPoint, window: String) -> Bool {
    if local.handles(window) { return local.setPosition(point, window: window) }
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return set(value, attribute: kAXPositionAttribute, window: window)
  }

  func setMinimized(_ value: Bool, window: String) -> Bool {
    if local.handles(window) { return local.setMinimized(value, window: window) }
    return set(
      value ? kCFBooleanTrue! : kCFBooleanFalse!, attribute: kAXMinimizedAttribute, window: window)
  }

  func setFullScreen(_ value: Bool, window: String) -> Bool {
    if local.handles(window) { return local.setFullScreen(value, window: window) }
    return set(
      value ? kCFBooleanTrue! : kCFBooleanFalse!, attribute: "AXFullScreen", window: window)
  }

  func setFrameDirectly(
    _ frame: CGRect, window: String,
    isValid: @escaping @Sendable () -> Bool
  ) -> Bool? {
    guard local.handles(window) else { return nil }
    return local.setFrameDirectly(frame, window: window, isValid: isValid)
  }

  private func set(_ value: CFTypeRef, attribute name: String, window: String) -> Bool {
    guard let entry = entries[window], isCurrent(entry.app) else { return false }
    return AXUIElementSetAttributeValue(entry.element, name as CFString, value) == .success
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  // One IPC round trip, with per-attribute absence kept separate from transport failure.
  // AX does not promise an atomic geometry snapshot; the controller still observes convergence.
  private func attributes(_ element: AXUIElement, _ names: [String]) -> [String: CFTypeRef]? {
    var values: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        == .success,
      let items = values as? [CFTypeRef], items.count == names.count
    else { return nil }
    var result: [String: CFTypeRef] = [:]
    for (name, value) in zip(names, items) {
      if CFGetTypeID(value) == CFNullGetTypeID() { continue }
      if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
        var error = AXError.success
        guard AXValueGetValue(value as! AXValue, .axError, &error),
          error == .noValue || error == .attributeUnsupported
        else { return nil }
        continue
      }
      result[name] = value
    }
    return result
  }

  private func intendedWindow(_ app: AXUIElement) -> (window: AXUIElement?, temporary: Bool) {
    for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      var value: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(app, name as CFString, &value)
      if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
        return ((value as! AXUIElement), false)
      }
      // Only an explicitly absent focused attribute may fall back to the main window. A timeout
      // must not silently pick a different window while the real focus is temporarily unreadable.
      if status != .noValue && status != .attributeUnsupported { return (nil, true) }
    }
    return (nil, false)
  }

  private func boolean(_ element: AXUIElement, _ name: String) -> Bool? {
    bool(attribute(element, name))
  }

  private func bool(_ value: CFTypeRef?) -> Bool? {
    guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
      return nil
    }
    return CFBooleanGetValue((value as! CFBoolean))
  }

  private func settable(_ element: AXUIElement, _ name: String) -> Bool? {
    var value = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(element, name as CFString, &value)
    if status == .attributeUnsupported { return false }
    guard status == .success else { return nil }
    return value.boolValue
  }
}
