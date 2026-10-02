import AppKit
import ApplicationServices
import Foundation

enum WindowArrangementAction: String, Sendable {
  case leftHalf, rightHalf, topHalf, bottomHalf
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

/// All backend methods run on the controller's private serial queue. The AX implementation keeps
/// the exact element alive; it never translates that element into a changing window-array index.
protocol WindowArrangementBackend: AnyObject, Sendable {
  func isCurrent(_ app: WindowArrangementApplication) -> Bool
  func selectWindow(_ app: WindowArrangementApplication) -> WindowArrangementSelection
  func readWindow(_ id: String) -> WindowArrangementWindow?
  func stillOwnsWindow(_ id: String) -> Bool
  func readFullScreen(_ id: String) -> Bool?
  func setSize(_ size: CGSize, window: String) -> Bool
  func setPosition(_ point: CGPoint, window: String) -> Bool
  func setMinimized(_ value: Bool, window: String) -> Bool
  func setFullScreen(_ value: Bool, window: String) -> Bool
}

extension WindowArrangementBackend {
  func stillOwnsWindow(_ id: String) -> Bool { true }
  func readFullScreen(_ id: String) -> Bool? { readWindow(id)?.fullScreen }
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
        x: workArea.midX - current.width / 2, y: workArea.midY - current.height / 2,
        width: current.width, height: current.height)
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
    case .rightHalf, .topRight, .bottomRight: x = max(workArea.minX, workArea.maxX - size.width)
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

  static func restored(_ saved: CGRect?, in area: CGRect) -> CGRect {
    let source =
      saved
      ?? CGRect(
        x: area.midX - area.width * 0.36, y: area.midY - area.height * 0.36,
        width: area.width * 0.72, height: area.height * 0.72)
    let width = min(max(1, source.width), area.width)
    let height = min(max(1, source.height), area.height)
    return CGRect(
      x: min(max(source.minX, area.minX), area.maxX - width),
      y: min(max(source.minY, area.minY), area.maxY - height), width: width, height: height)
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

  private struct Submission {
    let generation: UInt64
    let chain: UInt64
    let count: Int
    let action: WindowArrangementAction
    let application: WindowArrangementApplication
  }

  private struct Request: Sendable {
    let generation: UInt64
    let chain: UInt64
    let count: Int
    let action: WindowArrangementAction
    let application: WindowArrangementApplication
    let screens: [WindowArrangementScreen]
    let screenProvider: ScreenProvider?
    let completion: Completion
  }

  private struct ToggleBaseline {
    let chain: UInt64
    let windowID: String
    let maximized: Bool
    let fullScreen: Bool
    let originalFrame: CGRect
    let initialCount: Int
  }

  private struct Placement: Sendable {
    let request: Request
    let windowID: String
    let desired: CGRect
    let workArea: CGRect
    let clearRestore: Bool
    let deadline: TimeInterval
    let positionOnly: Bool
  }

  private let queue = DispatchQueue(label: "cn.tlww.aixlg.window-arrangement", qos: .userInitiated)
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var submission: Submission?
  private let backend: any WindowArrangementBackend
  // The following state belongs exclusively to queue. Restore frames never outlive their exact
  // process launch and AX element, and are not persisted under recyclable window numbers.
  private var restoreFrames: [String: CGRect] = [:]
  private var toggleBaseline: ToggleBaseline?
  private var maximizedFrames: [String: CGRect] = [:]
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
    let sameToggle =
      submission.map {
        $0.action == action && $0.application == application
          && (action == .maximize || action == .nativeFullScreen)
      } ?? false
    let next = Submission(
      generation: generation, chain: sameToggle ? submission!.chain : generation,
      count: sameToggle ? submission!.count + 1 : 1, action: action, application: application)
    submission = next
    lock.unlock()
    let request = Request(
      generation: next.generation, chain: next.chain, count: next.count,
      action: action, application: application, screens: screens,
      screenProvider: screenProvider, completion: completion)
    queue.async { [weak self] in self?.begin(request) }
  }

  func cancel() {
    lock.lock()
    generation &+= 1
    submission = nil
    lock.unlock()
  }

  private func owns(_ request: Request) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == request.generation
  }

  private func valid(_ request: Request) -> Bool {
    guard owns(request) else { return false }
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
    let workArea = WindowArrangementGeometry.workArea(for: window.frame, screens: request.screens)
    if request.action == .maximize || request.action == .nativeFullScreen {
      if toggleBaseline?.chain != request.chain || toggleBaseline?.windowID != window.id {
        let changedWindow =
          toggleBaseline?.chain == request.chain
          && toggleBaseline?.windowID != window.id
        let completedMaximize =
          maximizedFrames[key(request.application, window.id)]
          .map { WindowArrangementGeometry.matches(window.frame, $0) } ?? false
        toggleBaseline = ToggleBaseline(
          chain: request.chain, windowID: window.id,
          maximized: completedMaximize
            || (workArea.map { WindowArrangementGeometry.matches(window.frame, $0) } ?? false),
          fullScreen: window.fullScreen ?? false, originalFrame: window.frame,
          initialCount: changedWindow ? request.count : 1)
      }
    }
    if request.action == .minimize {
      if window.fullScreen == true || fullScreenWrites[window.id] != nil {
        changeFullScreen(
          request, windowID: window.id, desired: false,
          deadline: uptime + 3, remainingWrites: 3, continuePlacement: true)
        return
      }
      guard backend.setMinimized(true, window: window.id) else {
        finish(request, .unsupported, "这个窗口不支持最小化。")
        return
      }
      observeMinimized(request, windowID: window.id, remaining: 8)
      return
    }
    if request.action == .nativeFullScreen {
      guard window.fullScreen != nil, let baseline = toggleBaseline else {
        finish(request, .unsupported, "这个窗口不支持系统全屏。")
        return
      }
      let count = request.count - baseline.initialCount + 1
      let desired = count.isMultiple(of: 2) ? baseline.fullScreen : !baseline.fullScreen
      changeFullScreen(
        request, windowID: window.id, desired: desired,
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
        self.place(request, window: window, screens: screens)
      }
    }
  }

  private func place(
    _ request: Request, window: WindowArrangementWindow, screens: [WindowArrangementScreen]
  ) {
    if request.action == .minimize {
      guard valid(request), backend.stillOwnsWindow(window.id), owns(request) else { return }
      if backend.setMinimized(true, window: window.id) {
        observeMinimized(request, windowID: window.id, remaining: 8)
      } else {
        finish(request, .unsupported, "这个窗口不支持最小化。")
      }
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
    let desired: CGRect
    var clearRestore = request.action != .maximize
    if request.action == .maximize, let baseline = toggleBaseline {
      let count = request.count - baseline.initialCount + 1
      let wantsMaximize = count.isMultiple(of: 2) ? baseline.maximized : !baseline.maximized
      if wantsMaximize {
        if !baseline.maximized { restoreFrames[restoreKey] = baseline.originalFrame }
        desired = area
      } else {
        let saved = baseline.maximized ? restoreFrames[restoreKey] : baseline.originalFrame
        desired = WindowArrangementGeometry.restored(saved, in: area)
        clearRestore = true
      }
    } else if request.action == .center,
      WindowArrangementGeometry.matches(window.frame, area)
    {
      let restored = WindowArrangementGeometry.restored(restoreFrames[restoreKey], in: area)
      desired = WindowArrangementGeometry.target(.center, current: restored, workArea: area)
    } else {
      desired = WindowArrangementGeometry.target(
        request.action, current: window.frame, workArea: area)
    }
    let placement = Placement(
      request: request, windowID: window.id, desired: desired, workArea: area,
      clearRestore: clearRestore, deadline: uptime + 1.5, positionOnly: !window.resizable)
    if WindowArrangementGeometry.matches(window.frame, desired) {
      completePlacement(placement, observed: window.frame, constrained: false)
      return
    }
    let actualTarget =
      window.resizable
      ? desired
      : WindowArrangementGeometry.aligned(
        size: window.frame.size, action: request.action, desired: desired, workArea: area)
    let acceptedSize = write(placement, frame: actualTarget, positionOnly: !window.resizable)
    observe(
      placement, attempt: 0, previousSize: nil,
      constrainedTarget: window.resizable ? nil : actualTarget, acceptedSize: acceptedSize)
  }

  @discardableResult
  private func write(_ placement: Placement, frame: CGRect, positionOnly: Bool = false) -> Bool {
    let request = placement.request
    // Each OS call has a bounded AX messaging timeout. A submission can invalidate this request
    // from the main thread during a slow call; all subsequent writes then stop.
    var acceptedSize = positionOnly
    for _ in 0..<2 {
      guard valid(request), backend.stillOwnsWindow(placement.windowID), owns(request) else {
        return false
      }
      if !positionOnly {
        acceptedSize = backend.setSize(frame.size, window: placement.windowID) || acceptedSize
      }
      guard valid(request), backend.stillOwnsWindow(placement.windowID), owns(request) else {
        return false
      }
      _ = backend.setPosition(frame.origin, window: placement.windowID)
    }
    return acceptedSize
  }

  private func observe(
    _ placement: Placement, attempt: Int, previousSize: CGSize?, constrainedTarget: CGRect?,
    acceptedSize: Bool
  ) {
    queue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.1)) { [weak self] in
      guard let self, self.valid(placement.request) else { return }
      guard self.backend.stillOwnsWindow(placement.windowID) else {
        self.finish(placement.request, .failed, "当前窗口已变化，已停止调整。")
        return
      }
      guard let window = self.backend.readWindow(placement.windowID) else {
        self.finish(placement.request, .failed, "原窗口已关闭，已停止调整。")
        return
      }
      if WindowArrangementGeometry.matches(window.frame, placement.desired) {
        self.completePlacement(placement, observed: window.frame, constrained: false)
        return
      }
      if let constrainedTarget, WindowArrangementGeometry.matches(window.frame, constrainedTarget) {
        self.completePlacement(placement, observed: window.frame, constrained: true)
        return
      }
      guard attempt < 4, self.uptime < placement.deadline else {
        self.finish(
          placement.request, .failed, "窗口未完成调整，可能正忙或受到应用限制。",
          requested: placement.desired, observed: window.frame)
        return
      }
      let sizeIsStable =
        previousSize.map {
          abs($0.width - window.frame.width) <= 2 && abs($0.height - window.frame.height) <= 2
        } ?? false
      let sizeDiffers =
        abs(window.frame.width - placement.desired.width) > 2
        || abs(window.frame.height - placement.desired.height) > 2
      if sizeIsStable && sizeDiffers && attempt >= 1 && acceptedSize {
        let aligned = WindowArrangementGeometry.aligned(
          size: window.frame.size, action: placement.request.action,
          desired: placement.desired, workArea: placement.workArea)
        self.write(placement, frame: aligned, positionOnly: true)
        self.observe(
          placement, attempt: attempt + 1, previousSize: window.frame.size,
          constrainedTarget: aligned, acceptedSize: acceptedSize)
      } else {
        let retryTarget =
          placement.positionOnly
          ? WindowArrangementGeometry.aligned(
            size: window.frame.size, action: placement.request.action,
            desired: placement.desired, workArea: placement.workArea)
          : placement.desired
        let nextAcceptedSize = self.write(
          placement, frame: retryTarget, positionOnly: placement.positionOnly)
        self.observe(
          placement, attempt: attempt + 1, previousSize: window.frame.size,
          constrainedTarget: placement.positionOnly ? retryTarget : nil,
          acceptedSize: nextAcceptedSize)
      }
    }
  }

  private func completePlacement(_ placement: Placement, observed: CGRect, constrained: Bool) {
    if placement.clearRestore {
      let restoreKey = key(placement.request.application, placement.windowID)
      restoreFrames.removeValue(forKey: restoreKey)
      maximizedFrames.removeValue(forKey: restoreKey)
    } else if placement.request.action == .maximize {
      maximizedFrames[key(placement.request.application, placement.windowID)] = observed
    }
    if restoreFrames.count > 128 {
      restoreFrames.removeAll()
      maximizedFrames.removeAll()
    }
    finish(
      placement.request, constrained ? .constrained : .applied,
      constrained ? "已按方向对齐；这个 App 限制了窗口大小。" : "窗口已调整。",
      requested: placement.desired, observed: observed)
  }

  private func key(_ app: WindowArrangementApplication, _ window: String) -> String {
    let launch = app.launchTime.map { String($0) } ?? "unknown"
    return "\(app.pid):\(launch):\(window)"
  }

  private func finish(
    _ request: Request, _ status: WindowArrangementResult.Status, _ message: String,
    requested: CGRect? = nil, observed: CGRect? = nil
  ) {
    guard owns(request) else { return }
    lock.lock()
    if submission?.generation == request.generation { submission = nil }
    lock.unlock()
    let result = WindowArrangementResult(
      status: status, message: message, requestedFrame: requested, observedFrame: observed)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.owns(request) else { return }
      request.completion(result)
    }
  }
}

final class AXWindowArrangementBackend: WindowArrangementBackend, @unchecked Sendable {
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
    guard let role = string(chosen, kAXRoleAttribute) else {
      return .temporarilyUnavailable("当前窗口暂时没有响应，请稍后重试。")
    }
    guard role == kAXWindowRole else {
      return .unavailable("请先关闭当前对话框，再调整窗口。")
    }
    let subrole = string(chosen, kAXSubroleAttribute)
    guard subrole == nil || subrole == kAXStandardWindowSubrole else {
      return .unavailable("当前对话框或工具窗口不适合分屏。")
    }
    if let sheets = attribute(chosen, "AXSheets") as? [AXUIElement], !sheets.isEmpty {
      return .unavailable("请先关闭当前对话框，再调整窗口。")
    }
    guard boolean(chosen, kAXMinimizedAttribute) != true else {
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
    guard let entry = entries[id], isCurrent(entry.app),
      let positionValue = attribute(entry.element, kAXPositionAttribute),
      let sizeValue = attribute(entry.element, kAXSizeAttribute),
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
    guard let movable = settable(entry.element, kAXPositionAttribute),
      let resizable = settable(entry.element, kAXSizeAttribute)
    else { return nil }
    return WindowArrangementWindow(
      id: id, frame: CGRect(origin: origin, size: size),
      minimized: boolean(entry.element, kAXMinimizedAttribute) == true,
      fullScreen: boolean(entry.element, "AXFullScreen"),
      movable: movable, resizable: resizable)
  }

  func stillOwnsWindow(_ id: String) -> Bool {
    guard let entry = entries[id], isCurrent(entry.app) else { return false }
    let appElement = AXUIElementCreateApplication(entry.app.pid)
    AXUIElementSetMessagingTimeout(appElement, timeout)
    let selection = intendedWindow(appElement)
    guard !selection.temporary, let target = selection.window, CFEqual(target, entry.element) else {
      return false
    }
    AXUIElementSetMessagingTimeout(target, timeout)
    guard boolean(target, kAXMinimizedAttribute) != true else { return false }
    if let sheets = attribute(target, "AXSheets") as? [AXUIElement], !sheets.isEmpty {
      return false
    }
    return true
  }

  func readFullScreen(_ id: String) -> Bool? {
    guard let entry = entries[id], isCurrent(entry.app) else { return nil }
    return boolean(entry.element, "AXFullScreen")
  }

  func setSize(_ size: CGSize, window: String) -> Bool {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return false }
    return set(value, attribute: kAXSizeAttribute, window: window)
  }

  func setPosition(_ point: CGPoint, window: String) -> Bool {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return set(value, attribute: kAXPositionAttribute, window: window)
  }

  func setMinimized(_ value: Bool, window: String) -> Bool {
    set(
      value ? kCFBooleanTrue! : kCFBooleanFalse!, attribute: kAXMinimizedAttribute, window: window)
  }

  func setFullScreen(_ value: Bool, window: String) -> Bool {
    set(value ? kCFBooleanTrue! : kCFBooleanFalse!, attribute: "AXFullScreen", window: window)
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

  private func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
  }

  private func boolean(_ element: AXUIElement, _ name: String) -> Bool? {
    guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else {
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
