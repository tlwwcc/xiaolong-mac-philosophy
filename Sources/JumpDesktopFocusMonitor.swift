import AppKit
import ApplicationServices

/// A verified click grants one remote canvas. Focus notifications only validate
/// that grant; they never grant it again after a local menu or pointer exit.
@MainActor
final class JumpDesktopFocusMonitor {
  private struct Canvas {
    let pid: pid_t
    let window: AXUIElement
    let frame: CGRect
  }
  private enum FocusRead {
    case local
    case unavailable
    case canvas(Canvas, hit: Bool)
  }
  private struct PendingClick {
    let generation: UInt64
    let pid: pid_t
    let point: CGPoint
    let bounds: CGRect
  }

  private let onChange: (Bool) -> Void
  private var routing = JumpDesktopRoutingState()
  private var canvas: Canvas?
  private var canvasID: UInt64 = 0
  private var pendingClick: PendingClick?
  private var pointerTap: CFMachPort?
  private var pointerSource: CFRunLoopSource?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var accessibilityObserver: AXObserver?
  private var observedApplication: AXUIElement?
  private var observedPID: pid_t?
  private var pollTimer: Timer?
  private var lastPublishedValue: Bool?
  private var isRunning = false
  private var focusGeneration: UInt64 = 0
  private var readToken: UUID?
  private var observerRetryAfter = Date.distantPast
  private(set) var shouldYieldLocalHotkeys = false
  var allowsChordKeyDown: Bool {
    guard routing.allowsChordKeyDown else { return false }
    if case .remote = routing.owner {
      guard let canvas else { return false }
      return canvas.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    return true
  }

  init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
  isolated deinit { stop() }

  func setChordHeld(_ held: Bool) {
    guard isRunning else { return }
    if held, let point = CGEvent(source: nil)?.location {
      checkPointer(point)
    }
    routing.setChordHeld(held)
    publish(reason: held ? "chordOwnerLocked" : "chordReleased")
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    startPointerObserver()
    for name in [NSWorkspace.didActivateApplicationNotification,
                 NSWorkspace.didTerminateApplicationNotification] {
      workspaceObservers.append(
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: name, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh(focusMayHaveChanged: true) }
        })
    }
    refresh()
  }

  func stop() {
    isRunning = false
    focusGeneration &+= 1
    readToken = nil
    pendingClick = nil
    canvas = nil
    routing.stop()
    shouldYieldLocalHotkeys = false
    lastPublishedValue = nil
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    pollTimer?.invalidate()
    pollTimer = nil
    detachAccessibilityObserver()
    if let pointerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), pointerSource, .commonModes) }
    if let pointerTap { CFMachPortInvalidate(pointerTap) }
    pointerSource = nil
    pointerTap = nil
  }

  private static func isJump(_ app: NSRunningApplication?) -> Bool {
    app?.bundleIdentifier == "com.p5sys.jump.mac.viewer.web"
      || app?.bundleIdentifier == "com.p5sys.jump.mac.viewer"
  }

  private func startPointerObserver() {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                              .otherMouseDragged, .leftMouseDown, .rightMouseDown,
                              .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      let monitor = Unmanaged<JumpDesktopFocusMonitor>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { monitor.pointerEvent(type, event: event) }
      return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
      options: .listenOnly, eventsOfInterest: mask, callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
      AppDiagnostics.log("jump_pointer_observer_unavailable", [:])
      return
    }
    pointerTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    pointerSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func pointerEvent(_ type: CGEventType, event: CGEvent) {
    guard isRunning else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      returnToLocal(reason: "pointerObserverReset", cancelChord: true)
      if let pointerTap { CGEvent.tapEnable(tap: pointerTap, enable: true) }
      return
    }
    let point = event.location
    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
      // Check the top-level window at the actual click. A status menu/popover
      // belongs to its local process even while Jump remains frontmost.
      guard let hitWindow = Self.windowOwner(at: point),
        Self.isJump(NSRunningApplication(processIdentifier: hitWindow.pid)) else {
        returnToLocal(reason: "localClick", cancelChord: true)
        return
      }
      let generation = routing.beginClick()
      pendingClick = PendingClick(generation: generation, pid: hitWindow.pid, point: point, bounds: hitWindow.frame)
      focusGeneration &+= 1
      publish(reason: "verifyCanvasClick")
      refresh()
    } else {
      checkPointer(point)
    }
  }

  private func checkPointer(_ point: CGPoint) {
    if let pendingClick {
      if !pendingClick.bounds.contains(point) {
        returnToLocal(reason: "pointerOutsidePendingWindow", cancelChord: false)
      }
      return
    }
    if let canvas, !canvas.frame.contains(point) {
      returnToLocal(reason: "pointerOutsideCanvas", cancelChord: false)
    }
  }

  private func returnToLocal(reason: String, cancelChord: Bool) {
    pendingClick = nil
    focusGeneration &+= 1
    if cancelChord { routing.localInteraction() } else { routing.pointerLeftCanvas() }
    publish(reason: reason)
  }

  func refresh(focusMayHaveChanged: Bool = false) {
    guard isRunning else { return }
    if focusMayHaveChanged { focusGeneration &+= 1 }
    let front = NSWorkspace.shared.frontmostApplication
    let app: NSRunningApplication?
    if Self.isJump(front) {
      app = front
    } else if !focusMayHaveChanged, let pendingClick {
      app = NSRunningApplication(processIdentifier: pendingClick.pid)
    } else {
      app = nil
    }
    guard let app, Self.isJump(app) else {
      returnToLocal(reason: "localApplication", cancelChord: true)
      canvas = nil
      pollTimer?.invalidate()
      pollTimer = nil
      detachAccessibilityObserver()
      return
    }
    attachAccessibilityObserver(pid: app.processIdentifier)
    if pollTimer == nil {
      let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      RunLoop.main.add(timer, forMode: .common)
      pollTimer = timer
    }
    guard readToken == nil else { return }
    let token = UUID()
    readToken = token
    let generation = focusGeneration
    let pid = app.processIdentifier
    let bundle = app.bundleIdentifier
    let click = pendingClick
    let point = click?.point ?? CGEvent(source: nil)?.location
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = Self.readFocus(pid: pid, bundle: bundle, point: point)
      await self?.finishRead(result, token: token, generation: generation, pid: pid, click: click)
    }
  }

  private func finishRead(_ result: FocusRead, token: UUID, generation: UInt64,
                          pid: pid_t, click: PendingClick?) {
    guard isRunning, readToken == token else { return }
    readToken = nil
    guard generation == focusGeneration else { refresh(); return }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      returnToLocal(reason: "clickDidNotActivateViewer", cancelChord: true)
      return
    }
    switch result {
    case .unavailable:
      // Unknown AX does not acquire ownership. An existing grant may survive
      // a transient read failure, but explicit local input always revokes it.
      return
    case .local:
      canvas = nil
      returnToLocal(reason: "localControl", cancelChord: true)
    case .canvas(let current, let hit):
      if canvas?.pid != current.pid || canvas.map({ !CFEqual($0.window, current.window) }) != false {
        canvasID &+= 1
      }
      canvas = current
      let pointerInside = CGEvent(source: nil).map { current.frame.contains($0.location) } ?? false
      if let click {
        pendingClick = nil
        _ = routing.resolveClick(click.generation, canvas: hit && pointerInside ? canvasID : nil)
      } else {
        routing.validateCanvas(canvasID)
        if !pointerInside || !hit { routing.pointerLeftCanvas() }
      }
      publish(reason: hit && pointerInside ? "verifiedCanvas" : "outsideCanvas")
    }
  }

  private func publish(reason: String) {
    let value = routing.shouldYieldLocalHotkeys
    shouldYieldLocalHotkeys = value
    guard lastPublishedValue != value else { return }
    lastPublishedValue = value
    AppDiagnostics.log("jump_desktop_shortcut_route", ["yieldLocal": "\(value)", "reason": reason])
    onChange(value)
  }

  private nonisolated static func windowOwner(at point: CGPoint) -> (pid: pid_t, frame: CGRect)? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]] else { return nil }
    for window in windows {
      guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point),
        (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
      return (pid, frame)
    }
    return nil
  }

  private nonisolated static func readFocus(pid: pid_t, bundle: String?, point: CGPoint?) -> FocusRead {
    let application = AXUIElementCreateApplication(pid)
    guard let window = element(application, kAXFocusedWindowAttribute),
      let focused = element(application, kAXFocusedUIElementAttribute) else { return .unavailable }
    let role = attribute(focused, kAXRoleAttribute).value as? String
    let windowRole = attribute(window, kAXRoleAttribute).value as? String
    let children = attribute(focused, kAXChildrenAttribute)
    let childCount: Int?
    if children.error == .success { childCount = (children.value as? [AXUIElement])?.count }
    else if children.error == .noValue || children.error == .attributeUnsupported { childCount = 0 }
    else { childCount = nil }
    let modal = attribute(window, kAXModalAttribute).value as? Bool
    let minimized = attribute(window, kAXMinimizedAttribute).value as? Bool
    guard let role, let windowRole else { return .unavailable }
    if modal == true || minimized == true { return .local }
    if windowRole == "AXSheet" || windowRole == "AXDialog" { return .local }
    guard windowRole == "AXWindow" else { return .unavailable }
    if role != "AXScrollArea" {
      switch role {
      case "AXButton", "AXCheckBox", "AXTextField", "AXTextArea", "AXComboBox",
           "AXTable", "AXOutline", "AXPopUpButton", "AXRadioButton", "AXTabGroup",
           "AXWindow", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem":
        return .local
      default: return .unavailable
      }
    }
    guard let childCount, let modal, let minimized else { return .unavailable }
    guard JumpDesktopFocusPolicy.isRemoteCanvas(bundleIdentifier: bundle, windowRole: windowRole,
      focusedRole: role, focusedChildCount: childCount, isModal: modal, isMinimized: minimized)
      else { return .local }
    guard let position = attribute(focused, kAXPositionAttribute).value,
      let size = attribute(focused, kAXSizeAttribute).value,
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
      else { return .unavailable }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
      AXValueGetValue(size as! AXValue, .cgSize, &extent),
      origin.x.isFinite, origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
      extent.width > 0, extent.height > 0 else { return .unavailable }
    let frame = CGRect(origin: origin, size: extent)
    let canvas = Canvas(pid: pid, window: window, frame: frame)
    guard let point, frame.contains(point) else { return .canvas(canvas, hit: false) }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.05)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
      let hit else { return .unavailable }
    return .canvas(canvas, hit: CFEqual(focused, hit))
  }

  private nonisolated static func attribute(_ element: AXUIElement, _ name: String)
    -> (value: CFTypeRef?, error: AXError)
  {
    AXUIElementSetMessagingTimeout(element, 0.05)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, error)
  }

  private nonisolated static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
    let result = attribute(parent, name)
    guard result.error == .success, let value = result.value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private func attachAccessibilityObserver(pid: pid_t) {
    guard observedPID != pid
      || (accessibilityObserver == nil && Date() >= observerRetryAfter) else { return }
    detachAccessibilityObserver()
    observerRetryAfter = Date().addingTimeInterval(1)
    observedPID = pid
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.05)
    observedApplication = application
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, context in
      guard let context else { return }
      let monitor = Unmanaged<JumpDesktopFocusMonitor>.fromOpaque(context).takeUnretainedValue()
      Task { @MainActor [weak monitor] in monitor?.refresh(focusMayHaveChanged: true) }
    }
    let creationStatus = AXObserverCreate(pid, callback, &observer)
    guard creationStatus == .success, let observer else {
      AppDiagnostics.log("jump_desktop_observer_unavailable", ["status": "\(creationStatus.rawValue)"])
      return
    }
    accessibilityObserver = observer
    var hasFocusNotification = false
    for notification in [kAXFocusedWindowChangedNotification,
                         kAXFocusedUIElementChangedNotification,
                         kAXMainWindowChangedNotification,
                         kAXWindowCreatedNotification] {
      let status = AXObserverAddNotification(
        observer, application, notification as CFString,
        Unmanaged.passUnretained(self).toOpaque())
      if status == .success || status == .notificationAlreadyRegistered {
        if notification != kAXWindowCreatedNotification { hasFocusNotification = true }
      } else {
        AppDiagnostics.log("jump_desktop_notification_unavailable",
                           ["notification": notification, "status": "\(status.rawValue)"])
      }
    }
    guard hasFocusNotification else {
      accessibilityObserver = nil
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
  }

  private func detachAccessibilityObserver() {
    if observedPID != nil { focusGeneration &+= 1 }
    if let observer = accessibilityObserver {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    accessibilityObserver = nil
    observedApplication = nil
    observedPID = nil
  }
}
