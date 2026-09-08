import AppKit
import ApplicationServices
import QuartzCore

private final class AuthorizationGuidePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

enum AuthorizationDragGuideLayout {
  static let edgeInset: CGFloat = 16
  static let horizontalInset: CGFloat = 16
  static let bottomInset: CGFloat = 44
  static let preferredSize = NSSize(width: 480, height: 116)

  static func approximateContentFrame(in systemSettingsFrame: NSRect) -> NSRect {
    let sidebarWidth = max(220, systemSettingsFrame.width * 0.30)
    return NSRect(
      x: systemSettingsFrame.minX + sidebarWidth,
      y: systemSettingsFrame.minY,
      width: max(0, systemSettingsFrame.width - sidebarWidth),
      height: max(0, systemSettingsFrame.height - 52))
  }

  static func guideFrame(
    visibleFrame: NSRect,
    systemSettingsFrame: NSRect,
    contentFrame: NSRect?
  ) -> NSRect {
    let target = contentFrame ?? approximateContentFrame(in: systemSettingsFrame)
    let availableWidth = max(280, target.width - horizontalInset * 2)
    let width = min(preferredSize.width, availableWidth)
    let height = preferredSize.height
    let preferredX = target.midX - width / 2
    let preferredY = target.minY + bottomInset
    let x = min(
      max(preferredX, visibleFrame.minX + edgeInset),
      visibleFrame.maxX - width - edgeInset)
    let y = min(
      max(preferredY, visibleFrame.minY + edgeInset),
      visibleFrame.maxY - height - edgeInset)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  static func completionGuideFrame(visibleFrame: NSRect) -> NSRect {
    let availableWidth = max(280, visibleFrame.width - edgeInset * 2)
    let width = min(preferredSize.width, availableWidth)
    let height = preferredSize.height
    let x = min(
      max(visibleFrame.midX - width / 2, visibleFrame.minX + edgeInset),
      visibleFrame.maxX - width - edgeInset)
    let y = min(
      max(visibleFrame.minY + bottomInset, visibleFrame.minY + edgeInset),
      visibleFrame.maxY - height - edgeInset)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  /// AX 与 CGWindow 使用主屏左上原点；AppKit 使用主屏左下原点。
  static func appKitFrame(
    fromTopLeftFrame frame: NSRect,
    primaryScreenMaxY: CGFloat
  ) -> NSRect {
    NSRect(
      x: frame.minX,
      y: primaryScreenMaxY - frame.maxY,
      width: frame.width,
      height: frame.height)
  }
}

/// “小白授权”第二窗口：从拖入列表到最终重启，始终在同一张卡上引导。
/// 它不激活系统设置、不点击系统开关，也不声称系统行本身会抖动。
@MainActor
final class AuthorizationDragGuideController {
  static let shared = AuthorizationDragGuideController()

  static let expectedInstallPath = AppRuntimeIdentity.current.installURL.path
  static let expectedBundleIdentifier = AppRuntimeIdentity.current.bundleIdentifier

  private struct SystemSettingsGeometry {
    let windowFrame: NSRect
    let contentFrame: NSRect?
  }

  private var guideWindow: NSPanel?
  private var guideView: AuthorizationInstalledAppDragCardView?
  private var currentPhase: AuthorizationGuidePhase?
  private var registrationHandler: (() -> Void)?
  private var restartHandler: (() -> Void)?
  private var isDragging = false
  private var workspaceActivationObserver: NSObjectProtocol?
  private var activeSpaceObserver: NSObjectProtocol?
  private var screenChangeObserver: NSObjectProtocol?

  private init() {}

  func show(
    for service: AuthorizationRepairService,
    step: Int,
    total: Int,
    onRegister: @escaping () -> Void
  ) {
    runOnMain { [weak self] in
      guard let self else { return }
      guard expectedInstalledAppIsAvailable else {
        AppDiagnostics.log(
          "authorization_front_guide_identity_mismatch",
          [
            "path": Self.expectedInstallPath,
            "bundle": Bundle(url: URL(fileURLWithPath: Self.expectedInstallPath))?
              .bundleIdentifier ?? "missing",
          ])
        return
      }
      currentPhase = .guidedDrag(
        serviceDisplayName: service.displayName,
        step: step,
        total: total)
      registrationHandler = onRegister
      restartHandler = nil
      installVisibilityObserversIfNeeded()
      scheduleReposition(forceAttention: true)
    }
  }

  func showSystemRelaunch(
    for service: AuthorizationRepairService,
    step: Int,
    total: Int,
    onFallbackRestart: @escaping () -> Void
  ) {
    runOnMain { [weak self] in
      guard let self else { return }
      currentPhase = .systemRelaunch(
        serviceDisplayName: service.displayName,
        step: step,
        total: total)
      registrationHandler = nil
      restartHandler = onFallbackRestart
      isDragging = false
      installVisibilityObserversIfNeeded()
      scheduleReposition(forceAttention: true)
    }
  }

  func showRestartReady(onRestart: @escaping () -> Void) {
    runOnMain { [weak self] in
      guard let self else { return }
      currentPhase = .restartReady
      registrationHandler = nil
      restartHandler = onRestart
      isDragging = false
      installVisibilityObserversIfNeeded()
      scheduleReposition(forceAttention: true)
    }
  }

  func hide() {
    runOnMain { [weak self] in
      self?.guideWindow?.orderOut(nil)
      self?.currentPhase = nil
      self?.registrationHandler = nil
      self?.restartHandler = nil
      self?.isDragging = false
      self?.guideView?.layer?.removeAllAnimations()
      self?.removeVisibilityObservers()
    }
  }

  func hideDragPromptIfNeeded() {
    runOnMain { [weak self] in
      guard let self, currentPhase?.isDragPhase == true else { return }
      guideWindow?.orderOut(nil)
      currentPhase = nil
      registrationHandler = nil
      restartHandler = nil
      isDragging = false
      guideView?.layer?.removeAllAnimations()
      removeVisibilityObservers()
    }
  }

  private func runOnMain(_ operation: @MainActor () -> Void) {
    operation()
  }

  private var expectedInstalledAppIsAvailable: Bool {
    let appURL = URL(fileURLWithPath: Self.expectedInstallPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return Bundle(url: appURL)?.bundleIdentifier == Self.expectedBundleIdentifier
  }

  private func installVisibilityObserversIfNeeded() {
    if workspaceActivationObserver == nil {
      workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          let application =
            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
          guard
            application?.bundleIdentifier == "com.apple.systempreferences"
              || application?.bundleIdentifier == "com.apple.SystemSettings"
          else { return }
          self?.scheduleReposition(forceAttention: false)
        }
      }
    }
    if activeSpaceObserver == nil {
      activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleReposition(forceAttention: false) }
      }
    }
    if screenChangeObserver == nil {
      screenChangeObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleReposition(forceAttention: false) }
      }
    }
  }

  private func removeVisibilityObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    if let workspaceActivationObserver {
      workspaceCenter.removeObserver(workspaceActivationObserver)
      self.workspaceActivationObserver = nil
    }
    if let activeSpaceObserver {
      workspaceCenter.removeObserver(activeSpaceObserver)
      self.activeSpaceObserver = nil
    }
    if let screenChangeObserver {
      NotificationCenter.default.removeObserver(screenChangeObserver)
      self.screenChangeObserver = nil
    }
  }

  private func scheduleReposition(forceAttention: Bool) {
    // System Settings 冷启动和 SwiftUI 子页切换期间几何会短暂变化。
    // 只做四次有界重定位，不持续跟踪或操控系统设置。
    for (index, delay) in [0.25, 0.9, 1.8, 3.0].enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.reposition(forceAttention: forceAttention && index == 0)
      }
    }
  }

  private func reposition(forceAttention: Bool) {
    guard !isDragging else { return }
    guard let phase = currentPhase else { return }

    let geometry = systemSettingsGeometry()
    let targetScreen = geometry.flatMap { self.screen(containing: $0.windowFrame) } ?? NSScreen.main
    guard let targetScreen else {
      guideWindow?.orderOut(nil)
      return
    }

    let frame: NSRect
    if let geometry {
      frame = AuthorizationDragGuideLayout.guideFrame(
        visibleFrame: targetScreen.visibleFrame,
        systemSettingsFrame: geometry.windowFrame,
        contentFrame: geometry.contentFrame)
    } else if phase.keepsVisibleWithoutSystemSettings {
      frame = AuthorizationDragGuideLayout.completionGuideFrame(
        visibleFrame: targetScreen.visibleFrame)
    } else {
      // 系统设置冷启动、切换 Space 或 Stage Manager 时，窗口几何可能短暂不可读。
      // 授权精灵是 App 自己的前台 UI，不能因此退到“后台不可见”。
      frame = AuthorizationDragGuideLayout.completionGuideFrame(
        visibleFrame: targetScreen.visibleFrame)
    }
    let shouldAnimate =
      forceAttention || guideWindow?.isVisible != true || guideView?.phase != phase

    if let guideWindow, let guideView {
      guideView.phase = phase
      guideWindow.setFrame(frame, display: true)
      guideWindow.orderFrontRegardless()
    } else {
      let appURL = URL(fileURLWithPath: Self.expectedInstallPath, isDirectory: true)
      let view = AuthorizationInstalledAppDragCardView(
        appURL: appURL,
        phase: phase,
        onDragStateChanged: { [weak self] isDragging in
          guard let self else { return }
          self.isDragging = isDragging
          if isDragging {
            self.guideView?.layer?.removeAllAnimations()
          } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
              self?.reposition(forceAttention: false)
            }
          }
        },
        onRegistration: { [weak self] in
          self?.registrationHandler?()
        },
        onSystemRelaunch: { [weak self] in
          self?.beginSystemRelaunchFallback()
        },
        onRestart: { [weak self] in
          self?.beginRestart()
        })
      view.frame = NSRect(origin: .zero, size: frame.size)
      view.autoresizingMask = [.width, .height]
      view.wantsLayer = true

      let window = AuthorizationGuidePanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)
      window.contentView = view
      window.backgroundColor = .clear
      window.isOpaque = false
      window.hasShadow = true
      window.level = .statusBar
      window.hidesOnDeactivate = false
      window.becomesKeyOnlyIfNeeded = true
      window.worksWhenModal = true
      window.preventsApplicationTerminationWhenModal = false
      window.isMovable = false
      window.isReleasedWhenClosed = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      window.orderFrontRegardless()
      guideWindow = window
      guideView = view
    }

    if shouldAnimate {
      animateAttention()
    }
  }

  private func beginRestart() {
    guard currentPhase == .restartReady, let restartHandler else { return }
    self.restartHandler = nil
    currentPhase = .restarting
    guideView?.phase = .restarting
    guideView?.layer?.removeAllAnimations()
    restartHandler()
  }

  private func beginSystemRelaunchFallback() {
    guard case .systemRelaunch = currentPhase, let restartHandler else { return }
    self.restartHandler = nil
    currentPhase = .restarting
    guideView?.phase = .restarting
    guideView?.layer?.removeAllAnimations()
    restartHandler()
  }

  private func animateAttention() {
    guard let layer = guideView?.layer else { return }
    layer.removeAnimation(forKey: "authorizationGuideNudge")
    layer.removeAnimation(forKey: "authorizationGuidePulse")

    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
      shake.values = [0, -8, 8, -8, 8, 0]
      shake.keyTimes = [0, 0.18, 0.36, 0.54, 0.72, 1]
      shake.duration = 0.46
      shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(shake, forKey: "authorizationGuideNudge")
    }

    let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
    pulse.values = [1.0, 1.018, 1.0]
    pulse.keyTimes = [0, 0.5, 1]
    pulse.duration = 0.42
    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(pulse, forKey: "authorizationGuidePulse")
  }

  private func screen(containing frame: NSRect) -> NSScreen? {
    let candidates: [(screen: NSScreen, area: CGFloat)] = NSScreen.screens.map { screen in
      let intersection = screen.frame.intersection(frame)
      return (screen, intersection.width * intersection.height)
    }
    return
      candidates
      .filter { $0.area > 0 }
      .max { $0.area < $1.area }?
      .screen
  }

  private func systemSettingsGeometry() -> SystemSettingsGeometry? {
    let bundleIDs = ["com.apple.systempreferences", "com.apple.SystemSettings"]
    let applications = bundleIDs.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }
    let processIDs = Set(applications.map(\.processIdentifier))
    guard !processIDs.isEmpty,
      let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY
    else { return nil }

    // 有辅助功能权限时，AX 能精确读取右侧列表的滚动区。
    let accessibilityCandidates = applications.flatMap {
      application -> [SystemSettingsGeometry] in
      let appElement = AXUIElementCreateApplication(application.processIdentifier)
      var rawWindows: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          appElement,
          kAXWindowsAttribute as CFString,
          &rawWindows) == .success,
        let windows = rawWindows as? [AXUIElement]
      else { return [] }

      return windows.compactMap { window -> SystemSettingsGeometry? in
        guard let position = axPoint(window, attribute: kAXPositionAttribute),
          let size = axSize(window, attribute: kAXSizeAttribute),
          size.width > 300,
          size.height > 300
        else { return nil }
        let windowFrame = AuthorizationDragGuideLayout.appKitFrame(
          fromTopLeftFrame: NSRect(origin: position, size: size),
          primaryScreenMaxY: primaryScreenMaxY)
        let contentTopLeftFrame = axScrollAreaFrames(
          in: window,
          remainingDepth: 6
        ).filter {
          $0.width > max(300, size.width * 0.50)
            && $0.height > size.height * 0.55
            && $0.minX > position.x + size.width * 0.20
        }.max {
          $0.width * $0.height < $1.width * $1.height
        }
        let contentFrame = contentTopLeftFrame.map {
          AuthorizationDragGuideLayout.appKitFrame(
            fromTopLeftFrame: $0,
            primaryScreenMaxY: primaryScreenMaxY)
        }
        return SystemSettingsGeometry(
          windowFrame: windowFrame,
          contentFrame: contentFrame)
      }
    }
    if let geometry = accessibilityCandidates.max(by: {
      $0.windowFrame.width * $0.windowFrame.height
        < $1.windowFrame.width * $1.windowFrame.height
    }) {
      return geometry
    }

    // 授权尚未获得时 AX 会被拒绝；退回只读 WindowServer 几何。
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let candidates = windows.compactMap { window -> SystemSettingsGeometry? in
      guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
        processIDs.contains(ownerPID),
        let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
        let x = bounds["X"]?.doubleValue,
        let y = bounds["Y"]?.doubleValue,
        let width = bounds["Width"]?.doubleValue,
        let height = bounds["Height"]?.doubleValue,
        width > 300,
        height > 300
      else { return nil }
      let windowFrame = AuthorizationDragGuideLayout.appKitFrame(
        fromTopLeftFrame: NSRect(x: x, y: y, width: width, height: height),
        primaryScreenMaxY: primaryScreenMaxY)
      return SystemSettingsGeometry(
        windowFrame: windowFrame,
        contentFrame: AuthorizationDragGuideLayout.approximateContentFrame(
          in: windowFrame))
    }
    return candidates.max {
      $0.windowFrame.width * $0.windowFrame.height
        < $1.windowFrame.width * $1.windowFrame.height
    }
  }

  private func axScrollAreaFrames(
    in element: AXUIElement,
    remainingDepth: Int
  ) -> [NSRect] {
    guard remainingDepth >= 0 else { return [] }
    if axString(element, attribute: kAXRoleAttribute) == kAXScrollAreaRole,
      let position = axPoint(element, attribute: kAXPositionAttribute),
      let size = axSize(element, attribute: kAXSizeAttribute)
    {
      return [NSRect(origin: position, size: size)]
    }
    guard remainingDepth > 0 else { return [] }
    var rawChildren: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &rawChildren) == .success,
      let children = rawChildren as? [AXUIElement]
    else { return [] }
    return children.flatMap {
      axScrollAreaFrames(in: $0, remainingDepth: remainingDepth - 1)
    }
  }

  private func axString(_ element: AXUIElement, attribute: String) -> String? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue) == .success
    else { return nil }
    return rawValue as? String
  }

  private func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) else { return nil }
    return point
  }

  private func axSize(_ element: AXUIElement, attribute: String) -> CGSize? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgSize, &size) else { return nil }
    return size
  }
}

extension AuthorizationGuidePhase {
  fileprivate var isDragPhase: Bool {
    switch self {
    case .drag, .guidedDrag: return true
    case .systemRelaunch, .restartReady, .restarting: return false
    }
  }

  fileprivate var keepsVisibleWithoutSystemSettings: Bool {
    switch self {
    case .systemRelaunch, .restartReady, .restarting: return true
    case .drag, .guidedDrag: return false
    }
  }
}

private final class AuthorizationInstalledAppDragCardView: NSView, NSDraggingSource {
  var appURL: URL {
    didSet {
      icon = NSWorkspace.shared.icon(forFile: appURL.path)
      needsDisplay = true
    }
  }

  var phase: AuthorizationGuidePhase {
    didSet {
      updateAccessibility()
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
    }
  }

  private var icon: NSImage
  private var mouseDownEvent: NSEvent?
  private var mouseDownLocation: NSPoint?
  private let onDragStateChanged: (Bool) -> Void
  private let onRegistration: () -> Void
  private let onSystemRelaunch: () -> Void
  private let onRestart: () -> Void

  init(
    appURL: URL,
    phase: AuthorizationGuidePhase,
    onDragStateChanged: @escaping (Bool) -> Void,
    onRegistration: @escaping () -> Void,
    onSystemRelaunch: @escaping () -> Void,
    onRestart: @escaping () -> Void
  ) {
    self.appURL = appURL
    self.phase = phase
    self.onDragStateChanged = onDragStateChanged
    self.onRegistration = onRegistration
    self.onSystemRelaunch = onSystemRelaunch
    self.onRestart = onRestart
    icon = NSWorkspace.shared.icon(forFile: appURL.path)
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    updateAccessibility()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    AuthorizationDragGuideLayout.preferredSize
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let presentation = AuthorizationGuidePresentation.make(for: phase)
    let accentColor: NSColor
    switch phase {
    case .restartReady:
      accentColor = .systemGreen
    case .restarting:
      accentColor = .secondaryLabelColor
    case .systemRelaunch:
      accentColor = .systemOrange
    case .drag, .guidedDrag:
      accentColor = .controlAccentColor
    }
    let card = bounds.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: card, xRadius: 15, yRadius: 15)
    NSGradient(colors: [
      NSColor.windowBackgroundColor.withAlphaComponent(0.98),
      accentColor.withAlphaComponent(0.19),
    ])?.draw(in: path, angle: 0)
    accentColor.withAlphaComponent(0.62).setStroke()
    path.lineWidth = 1.5
    path.stroke()

    let arrowRect = NSRect(x: 18, y: bounds.midY - 18, width: 36, height: 36)
    let arrow = NSImage(
      systemSymbolName: presentation.symbolName,
      accessibilityDescription: presentation.title
    )?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 34, weight: .bold))
    arrow?.draw(in: arrowRect)

    let iconRect = NSRect(x: 68, y: bounds.midY - 24, width: 48, height: 48)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: iconRect)

    if let stepText = presentation.stepText {
      let stepRect = NSRect(
        x: 132,
        y: bounds.midY + 25,
        width: max(0, bounds.width - 148),
        height: 18)
      stepText.draw(
        in: stepRect,
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
          .foregroundColor: accentColor,
        ])
    }

    let titleRect = NSRect(
      x: 132,
      y: bounds.midY + (presentation.stepText == nil ? 5 : 1),
      width: max(0, bounds.width - 148),
      height: 24)
    presentation.title.draw(
      in: titleRect,
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ])

    let subtitleRect = NSRect(
      x: 132,
      y: bounds.midY - 27,
      width: max(0, bounds.width - 148),
      height: 20)
    presentation.subtitle.draw(
      in: subtitleRect,
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
  }

  override func resetCursorRects() {
    let presentation = AuthorizationGuidePresentation.make(for: phase)
    if presentation.isDraggable {
      addCursorRect(bounds, cursor: .openHand)
    } else if presentation.isRestartAction || presentation.isSystemRelaunchAction {
      addCursorRect(bounds, cursor: .pointingHand)
    } else {
      addCursorRect(bounds, cursor: .arrow)
    }
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownEvent = event
    mouseDownLocation = convert(event.locationInWindow, from: nil)
  }

  override func mouseDragged(with event: NSEvent) {
    guard AuthorizationGuidePresentation.make(for: phase).isDraggable,
      mouseDownEvent != nil
    else { return }
    mouseDownEvent = nil
    mouseDownLocation = nil
    layer?.removeAllAnimations()
    onDragStateChanged(true)
    let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
    item.setDraggingFrame(bounds, contents: dragPreviewImage())
    beginDraggingSession(with: [item], event: event, source: self)
  }

  override func mouseUp(with event: NSEvent) {
    let presentation = AuthorizationGuidePresentation.make(for: phase)
    let mouseUpLocation = convert(event.locationInWindow, from: nil)
    let isClick =
      mouseDownLocation.map {
        hypot(mouseUpLocation.x - $0.x, mouseUpLocation.y - $0.y) <= 6
      } ?? false
    mouseDownEvent = nil
    mouseDownLocation = nil
    if presentation.isRegistrationAction, isClick, event.clickCount >= 2 {
      onRegistration()
      return
    }
    if presentation.isSystemRelaunchAction, isClick, event.clickCount >= 2 {
      onSystemRelaunch()
      return
    }
    if presentation.isRestartAction, isClick {
      onRestart()
    }
  }

  override func accessibilityPerformPress() -> Bool {
    let presentation = AuthorizationGuidePresentation.make(for: phase)
    if presentation.isRegistrationAction {
      onRegistration()
      return true
    }
    if presentation.isSystemRelaunchAction {
      onSystemRelaunch()
      return true
    }
    if presentation.isRestartAction {
      onRestart()
      return true
    }
    return false
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    onDragStateChanged(false)
  }

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
    true
  }

  private func dragPreviewImage() -> NSImage {
    let image = NSImage(size: bounds.size)
    image.lockFocus()
    draw(bounds)
    image.unlockFocus()
    return image
  }

  private func updateAccessibility() {
    let presentation = AuthorizationGuidePresentation.make(for: phase)
    setAccessibilityLabel(presentation.title)
    setAccessibilityHelp(presentation.accessibilityHelp)
  }
}
