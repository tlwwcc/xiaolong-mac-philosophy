import AppKit
import ApplicationServices
import Foundation

struct AuthorizationSystemRelaunchPromptSnapshot: Equatable {
  let texts: [String]
  let buttonTitles: [String]
}

enum AuthorizationSystemRelaunchPromptPolicy {
  private static let inputMonitoringMessageTokens = [
    "无法监控键盘输入",
    "无法监听键盘输入",
    "unable to monitor keyboard input",
    "will not be able to monitor keyboard input",
  ]
  private static let screenRecordingMessageTokens = [
    "屏幕录制",
    "屏幕与系统音频录制",
    "无法录制屏幕内容",
    "录制屏幕内容",
    "record the contents of your screen",
    "screen recording",
    "screen & system audio recording",
  ]
  private static let relaunchButtonTokens = [
    "退出并重新打开",
    "quit and reopen",
    "quit & reopen",
  ]

  static func shouldAutomaticallyRelaunch(
    snapshot: AuthorizationSystemRelaunchPromptSnapshot,
    applicationDisplayName: String,
    service: AuthorizationRepairService = .inputMonitoring
  ) -> Bool {
    let normalizedApplicationName = normalize(applicationDisplayName)
    guard !normalizedApplicationName.isEmpty else { return false }

    let normalizedText = normalize(snapshot.texts.joined(separator: " "))
    let normalizedButtons = normalize(snapshot.buttonTitles.joined(separator: " "))
    guard normalizedText.contains(normalizedApplicationName) else { return false }

    let messageTokens =
      service == .screenRecording
      ? screenRecordingMessageTokens : inputMonitoringMessageTokens
    let containsPermissionMessage = messageTokens.contains {
      normalizedText.contains(normalize($0))
    }
    let containsRelaunchButton = relaunchButtonTokens.contains {
      normalizedButtons.contains(normalize($0))
    }
    return containsPermissionMessage && containsRelaunchButton
  }

  private static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    var normalized = ""
    for scalar in folded.lowercased().unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
      {
        continue
      }
      normalized.unicodeScalars.append(scalar)
    }
    return normalized
  }
}

enum AuthorizationSystemRelaunchPromptProbe {
  private static let systemSettingsBundleIdentifiers = [
    "com.apple.systempreferences",
    "com.apple.SystemSettings",
  ]
  private static let maximumElementCount = 320
  private static let maximumDepth = 10
  private static let sheetsAttribute = "AXSheets"

  static func isVisible(
    applicationDisplayName: String,
    service: AuthorizationRepairService = .inputMonitoring
  ) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let applications = systemSettingsBundleIdentifiers.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }

    for application in applications where !application.isTerminated {
      let appElement = AXUIElementCreateApplication(application.processIdentifier)
      for root in candidateRoots(for: appElement) {
        var texts: [String] = []
        var buttonTitles: [String] = []
        var remainingElements = maximumElementCount
        collectSnapshot(
          from: root,
          remainingDepth: maximumDepth,
          remainingElements: &remainingElements,
          texts: &texts,
          buttonTitles: &buttonTitles)
        let snapshot = AuthorizationSystemRelaunchPromptSnapshot(
          texts: texts,
          buttonTitles: buttonTitles)
        if AuthorizationSystemRelaunchPromptPolicy.shouldAutomaticallyRelaunch(
          snapshot: snapshot,
          applicationDisplayName: applicationDisplayName,
          service: service)
        {
          return true
        }
      }
    }
    return false
  }

  private static func candidateRoots(for appElement: AXUIElement) -> [AXUIElement] {
    var roots: [AXUIElement] = []

    if let focusedWindow = axElement(appElement, attribute: kAXFocusedWindowAttribute) {
      roots.append(contentsOf: axElements(focusedWindow, attribute: sheetsAttribute))
      roots.append(focusedWindow)
    }
    if let mainWindow = axElement(appElement, attribute: kAXMainWindowAttribute) {
      roots.append(contentsOf: axElements(mainWindow, attribute: sheetsAttribute))
      roots.append(mainWindow)
    }
    for window in axElements(appElement, attribute: kAXWindowsAttribute) {
      roots.append(contentsOf: axElements(window, attribute: sheetsAttribute))
      roots.append(window)
    }

    // macOS 26 can expose the Input Monitoring relaunch alert as an app-level
    // focused form instead of a regular window. Keep the app tree as a bounded,
    // read-only fallback so that variant still reaches the matching policy.
    roots.append(contentsOf: axElements(appElement, attribute: kAXChildrenAttribute))
    roots.append(appElement)
    return roots
  }

  private static func collectSnapshot(
    from element: AXUIElement,
    remainingDepth: Int,
    remainingElements: inout Int,
    texts: inout [String],
    buttonTitles: inout [String]
  ) {
    guard remainingDepth >= 0, remainingElements > 0 else { return }
    remainingElements -= 1

    let role = axString(element, attribute: kAXRoleAttribute)
    let strings = [
      axString(element, attribute: kAXTitleAttribute),
      axString(element, attribute: kAXDescriptionAttribute),
      axString(element, attribute: kAXHelpAttribute),
      axString(element, attribute: kAXValueAttribute),
    ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    texts.append(contentsOf: strings)
    if role == kAXButtonRole {
      buttonTitles.append(contentsOf: strings)
    }

    guard remainingDepth > 0 else { return }
    for child in axElements(element, attribute: kAXChildrenAttribute) {
      collectSnapshot(
        from: child,
        remainingDepth: remainingDepth - 1,
        remainingElements: &remainingElements,
        texts: &texts,
        buttonTitles: &buttonTitles)
      guard remainingElements > 0 else { return }
    }
  }

  private static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
      let elements = rawValue as? [AXUIElement]
    else { return [] }
    return elements
  }

  private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
      let value = rawValue,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func axString(_ element: AXUIElement, attribute: String) -> String? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success
    else { return nil }
    return rawValue as? String
  }
}

final class AuthorizationSystemRelaunchPromptMonitor: @unchecked Sendable {
  static let shared = AuthorizationSystemRelaunchPromptMonitor()

  private static let queueLabel =
    "\(AppRuntimeIdentity.current.notificationNamespace).authorization-system-relaunch-prompt"
  private let queue = DispatchQueue(
    label: AuthorizationSystemRelaunchPromptMonitor.queueLabel,
    qos: .utility)
  private var timer: DispatchSourceTimer?
  private var pollsRemaining = 0
  private var applicationDisplayName = ""
  private var service: AuthorizationRepairService = .inputMonitoring
  private var detectionHandler: (@Sendable () -> Void)?

  private init() {}

  func start(
    applicationDisplayName: String,
    service: AuthorizationRepairService = .inputMonitoring,
    timeout: TimeInterval = 300,
    pollInterval: TimeInterval = 0.5,
    onDetected: @escaping @Sendable () -> Void
  ) {
    guard !applicationDisplayName.isEmpty, timeout > 0, pollInterval > 0 else { return }
    queue.async { [weak self] in
      guard let self else { return }
      stopLocked()
      self.applicationDisplayName = applicationDisplayName
      self.service = service
      detectionHandler = onDetected
      pollsRemaining = max(1, Int(ceil(timeout / pollInterval)))

      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(
        deadline: .now() + 0.15,
        repeating: pollInterval,
        leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in
        self?.poll()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopLocked()
    }
  }

  private func poll() {
    guard pollsRemaining > 0 else {
      stopLocked()
      return
    }
    pollsRemaining -= 1
    guard
      AuthorizationSystemRelaunchPromptProbe.isVisible(
        applicationDisplayName: applicationDisplayName,
        service: service)
    else { return }

    let handler = detectionHandler
    stopLocked()
    DispatchQueue.main.async {
      handler?()
    }
  }

  private func stopLocked() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    pollsRemaining = 0
    applicationDisplayName = ""
    service = .inputMonitoring
    detectionHandler = nil
  }
}
