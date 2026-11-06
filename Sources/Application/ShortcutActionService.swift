import AppKit
import ApplicationServices
import Carbon
import Foundation

struct ShortcutActionApplication: Equatable {
  let pid: pid_t
  let launchTime: TimeInterval?
  let bundleIdentifier: String?
  let localizedName: String?
  let isTerminated: Bool
}

@MainActor
protocol ShortcutActionCancellation: AnyObject {
  func cancel()
}

@MainActor
protocol ShortcutActionProcess: ShortcutActionCancellation {
  func start()
}

@MainActor
protocol ShortcutActionPasteboardWrite: AnyObject {
  /// Returns true only when this write still owns the clipboard and restored its snapshot.
  func restoreIfStillOwned() -> Bool
}

@MainActor
protocol ShortcutActionWindowPort: AnyObject {
  func cancel()
  func submit(
    action: WindowArrangementAction, application: WindowArrangementApplication,
    screens: [WindowArrangementScreen],
    screenProvider: @escaping WindowArrangementController.ScreenProvider,
    completion: @escaping WindowArrangementController.Completion)
}

/// Effect boundaries let lifecycle checks run without posting real keys or executing user scripts.
@MainActor
struct ShortcutActionEnvironment {
  var frontmost: () -> ShortcutActionApplication?
  var ownBundleIdentifier: () -> String?
  var accessibilityTrusted: () -> Bool
  var hardwareModifiers: () -> [String]
  var openURL: (URL) -> Void
  var pluginDirectory: () -> URL?
  var makeProcess: (
    URL, [String], TimeInterval, Int, @escaping @MainActor (BoundedProcessResult) -> Void
  ) -> any ShortcutActionProcess
  var writeText: (
    String, @escaping @MainActor () -> Bool,
    @escaping @MainActor ((any ShortcutActionPasteboardWrite)?) -> Void
  ) -> Void
  var markClipboardChange: () -> Void
  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any ShortcutActionCancellation
  var observeScreens: (@escaping @MainActor () -> Void) -> any ShortcutActionCancellation
  var screens: @MainActor @Sendable () -> [WindowArrangementScreen]
  var postEvent: (CGEventSource?, UInt32, Bool, CGEventFlags, Bool, pid_t) -> Bool
  var pause: (useconds_t) -> Void

  static func live() -> Self {
    Self(
      frontmost: {
        NSWorkspace.shared.frontmostApplication.map {
          ShortcutActionApplication(
            pid: $0.processIdentifier, launchTime: $0.launchDate?.timeIntervalSince1970,
            bundleIdentifier: $0.bundleIdentifier, localizedName: $0.localizedName,
            isTerminated: $0.isTerminated)
        }
      },
      ownBundleIdentifier: { Bundle.main.bundleIdentifier },
      accessibilityTrusted: { AXIsProcessTrusted() },
      hardwareModifiers: { modifierNames(from: CGEventSource.flagsState(.hidSystemState)) },
      openURL: { NSWorkspace.shared.open($0) },
      pluginDirectory: { Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) },
      makeProcess: { ActionProcess(executable: $0, arguments: $1, timeout: $2, limit: $3, completion: $4) },
      writeText: { text, validate, completion in
        let pasteboard = NSPasteboard.general
        TemporaryPasteboardWrite.writeString(
          text, to: pasteboard, validateBeforeWrite: validate
        ) { write in
          completion(write.map { ActionPasteboardWrite(write: $0, pasteboard: pasteboard) })
        }
      },
      markClipboardChange: { ClipboardHistorySuppression.markCurrentPasteboardChange() },
      schedule: { delay, action in
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return ActionCancellation { item.cancel() }
      },
      observeScreens: { action in
        let observer = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { action() } }
        return ActionCancellation { NotificationCenter.default.removeObserver(observer) }
      },
      screens: {
        let screens = NSScreen.screens
        let primaryTop = screens.first?.frame.maxY ?? 0
        return screens.map {
          WindowArrangementScreen(
            frame: AXWindowGeometry.convertAppKitRectToAX($0.frame, primaryTop: primaryTop),
            visibleFrame: AXWindowGeometry.convertAppKitRectToAX($0.visibleFrame, primaryTop: primaryTop))
        }
      },
      postEvent: { source, code, down, flags, modifier, pid in
        guard let event = CGEvent(
          keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        else { return false }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.postToPid(pid)
        return true
      },
      pause: { usleep($0) })
  }
}

@MainActor
private final class ActionCancellation: ShortcutActionCancellation {
  private var action: (() -> Void)?
  init(_ action: @escaping () -> Void) { self.action = action }
  func cancel() { let current = action; action = nil; current?() }
}

@MainActor
private final class ActionProcess: ShortcutActionProcess {
  private let execution: BoundedProcessExecution
  init(
    executable: URL, arguments: [String], timeout: TimeInterval, limit: Int,
    completion: @escaping @MainActor (BoundedProcessResult) -> Void
  ) {
    execution = BoundedProcessExecution(
      executableURL: executable, arguments: arguments, timeout: timeout, outputByteLimit: limit
    ) { result in MainActor.assumeIsolated { completion(result) } }
  }
  func start() { execution.start() }
  func cancel() { execution.cancel() }
}

@MainActor
private final class ActionPasteboardWrite: ShortcutActionPasteboardWrite {
  let write: TemporaryPasteboardWrite
  let pasteboard: NSPasteboard
  init(write: TemporaryPasteboardWrite, pasteboard: NSPasteboard) {
    self.write = write
    self.pasteboard = pasteboard
  }
  func restoreIfStillOwned() -> Bool { write.restoreIfStillOwned(on: pasteboard) != nil }
}

@MainActor
private final class ActionWindowController: ShortcutActionWindowPort {
  private let controller = WindowArrangementController()
  func cancel() { controller.cancel() }
  func submit(
    action: WindowArrangementAction, application: WindowArrangementApplication,
    screens: [WindowArrangementScreen],
    screenProvider: @escaping WindowArrangementController.ScreenProvider,
    completion: @escaping WindowArrangementController.Completion
  ) {
    controller.submit(
      action: action, application: application, screens: screens,
      screenProvider: screenProvider, completion: completion)
  }
}

/// Owns shortcut effects independently of AppModel and its presentation state.
@MainActor
final class ShortcutActionService {
  private let environment: ShortcutActionEnvironment
  private let windows: any ShortcutActionWindowPort
  private var onStatus: ((String) -> Void)?
  private var toggleSettings: (() -> ShortcutWindowToggleOutcome)?
  private var presentSettings: (() -> Void)?
  private var presentAuthorization: (() -> Void)?
  private var started = false
  private var stopped = false
  private var cancelling = false
  private var generation = UUID()
  private var shellGeneration = UUID()
  private var closeGeneration = UUID()
  private var textGeneration = UUID()
  private var windowGeneration = UUID()
  private var shellExecution: (any ShortcutActionProcess)?
  private var closeExecution: (any ShortcutActionProcess)?
  private var screenObserver: (any ShortcutActionCancellation)?
  private var restoreTask: (any ShortcutActionCancellation)?
  private var temporaryWrite: (any ShortcutActionPasteboardWrite)?
  private var active: Bool { started && !stopped && !cancelling }

  init(
    onStatus: @escaping (String) -> Void,
    toggleSettings: @escaping () -> ShortcutWindowToggleOutcome,
    presentSettings: @escaping () -> Void,
    presentAuthorization: @escaping () -> Void,
    environment: ShortcutActionEnvironment? = nil,
    windowController: (any ShortcutActionWindowPort)? = nil
  ) {
    self.onStatus = onStatus
    self.toggleSettings = toggleSettings
    self.presentSettings = presentSettings
    self.presentAuthorization = presentAuthorization
    self.environment = environment ?? .live()
    windows = windowController ?? ActionWindowController()
  }

  isolated deinit { shutdown() }

  func start() {
    guard !started, !stopped else { return }
    started = true
    let owner = generation
    screenObserver = environment.observeScreens { [weak self] in
      guard let self, self.owns(owner) else { return }
      self.cancelWindowArrangement()
    }
  }

  /// Cancels current work without ending this service's lifetime.
  func cancelPendingActions() {
    guard !cancelling else { return }
    cancelling = true
    generation = UUID()
    shellGeneration = UUID()
    closeGeneration = UUID()
    textGeneration = UUID()
    let shell = shellExecution
    let close = closeExecution
    let restoration = restoreTask
    let write = temporaryWrite
    let observer = screenObserver
    shellExecution = nil
    closeExecution = nil
    restoreTask = nil
    temporaryWrite = nil
    screenObserver = nil
    // Detach every old resource before cancellation can synchronously call back into this owner.
    cancelWindowArrangement()
    shell?.cancel()
    close?.cancel()
    restoration?.cancel()
    if write?.restoreIfStillOwned() == true { environment.markClipboardChange() }
    observer?.cancel()
    cancelling = false
    if started && !stopped {
      // Re-register so a queued notification from the old owner cannot affect new work.
      started = false
      start()
    }
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    cancelPendingActions()
    onStatus = nil
    toggleSettings = nil
    presentSettings = nil
    presentAuthorization = nil
  }

  private func owns(_ owner: UUID) -> Bool { active && generation == owner }
  private func status(_ message: String) { if active { onStatus?(message) } }

  func bundledPluginDirectoryURL() -> URL? { environment.pluginDirectory() }

  func openURL(_ target: String) {
    guard active else { return }
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: value),
      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    else { status("网址无效：\(target)"); return }
    environment.openURL(url)
  }

  func runShell(_ command: String) {
    guard active else { return }
    let resolvedCommand: String
    if command.hasPrefix("plugin:") {
      guard let resolved = pluginShellCommand(for: command) else { return }
      resolvedCommand = resolved
    } else {
      resolvedCommand = command
    }
    let trimmedCommand = resolvedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { status("脚本命令为空。"); return }
    shellGeneration = UUID()
    let shellOwner = shellGeneration
    let owner = generation
    let previous = shellExecution
    shellExecution = nil
    previous?.cancel()
    guard owns(owner), shellGeneration == shellOwner else { return }
    let displayName = shellDisplayName(for: command)
    let auditKind = shellAuditKind(for: command)
    status("正在运行\(displayName)...")
    guard owns(owner), shellGeneration == shellOwner else { return }
    AppDiagnostics.log("shell_start", ["kind": auditKind])
    let execution = environment.makeProcess(
      URL(fileURLWithPath: "/bin/zsh"), ["-lc", trimmedCommand], 15, 131_072
    ) { [weak self] result in
      guard let self, self.owns(owner), self.shellGeneration == shellOwner else { return }
      self.shellExecution = nil
      let message: String
      if let error = result.launchError {
        message = "\(displayName)启动失败：\(error)"
      } else if result.timedOut {
        message = "\(displayName)超过 15 秒，已取消。"
      } else if result.cancelled {
        return
      } else {
        message = Self.shellFeedbackMessage(
          displayName: displayName, exitCode: result.terminationStatus ?? -1,
          output: result.standardOutput, error: result.standardError)
      }
      AppDiagnostics.log("shell_finished", [
        "kind": auditKind, "exitCode": result.terminationStatus.map(String.init) ?? "none",
        "timedOut": "\(result.timedOut)",
        "truncated": "\(result.outputWasTruncated || result.errorWasTruncated)",
      ])
      self.status(message)
    }
    shellExecution = execution
    execution.start()
  }

  private func shellAuditKind(for target: String) -> String {
    if target.hasPrefix("plugin:") { return "bundled_plugin" }
    if target.hasPrefix("shortcuts run ") { return "apple_shortcut" }
    if target.hasPrefix("osascript ") { return "apple_script" }
    if target.hasPrefix("defaults ") { return "system_defaults" }
    return "local_command"
  }

  private func pluginShellCommand(for target: String) -> String? {
    let fileName = String(target.dropFirst("plugin:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard fileName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$"#, options: .regularExpression) != nil,
      !fileName.contains("..")
    else { status("脚本插件名称无效。"); return nil }
    guard let directory = bundledPluginDirectoryURL()?.standardizedFileURL else {
      status("没有找到脚本插件：\(fileName)"); return nil
    }
    let candidate = directory.appendingPathComponent(fileName).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directory,
      FileManager.default.fileExists(atPath: candidate.path)
    else { status("没有找到脚本插件：\(fileName)"); return nil }
    return "bash \(shellQuote(candidate.path))"
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func shellDisplayName(for command: String) -> String {
    if command == "plugin:mic-toggle.sh" { return "切换麦克风" }
    if command.hasPrefix("plugin:") { return "脚本插件" }
    return "脚本"
  }

  private static func shellFeedbackMessage(
    displayName: String, exitCode: Int32, output: String, error: String
  ) -> String {
    let detail = (output + "\n" + error).split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty }
    if exitCode == 0 { return detail.map { "\(displayName)：\($0)" } ?? "\(displayName)已运行。" }
    return detail.map { "\(displayName)失败：\($0)" } ?? "\(displayName)失败，退出码 \(exitCode)。"
  }

  @discardableResult
  func sendShortcut(_ target: String) -> Bool {
    guard active else { return false }
    let owner = generation
    guard let shortcut = parseHotkeyText(target), let code = keyCode(for: shortcut.key) else {
      status("发送按键无效：\(target)")
      AppDiagnostics.log("send_shortcut_invalid", ["target": target])
      return false
    }
    let display = displayHotkeyText(key: shortcut.key, modifiers: shortcut.modifiers)
    let destination = environment.frontmost()
    AppDiagnostics.log("send_shortcut_requested", [
      "target": target, "display": display, "key": shortcut.key,
      "modifiers": shortcut.modifiers.joined(separator: "+"),
      "frontmost": destination?.localizedName ?? destination?.bundleIdentifier ?? "",
      "frontmostBundle": destination?.bundleIdentifier ?? "",
      "frontmostPID": destination.map { "\($0.pid)" } ?? "",
    ])
    if shortcut.key == ",", Set(shortcut.modifiers) == Set(["command"]),
      let ownBundle = environment.ownBundleIdentifier(), destination?.bundleIdentifier == ownBundle
    {
      let outcome = toggleSettings?() ?? .unavailable
      guard owns(owner) else { return false }
      if outcome == .shown || outcome == .unavailable {
        if outcome == .unavailable { presentSettings?() }
        status("已打开设置，再按一次即隐藏。")
      } else { status("已隐藏设置。") }
      AppDiagnostics.log("send_shortcut_performed", [
        "target": target, "display": display, "route": "self_settings_toggle",
        "frontmostBundle": destination?.bundleIdentifier ?? "",
        "frontmostPID": destination.map { "\($0.pid)" } ?? "",
      ])
      return owns(owner)
    }
    guard environment.accessibilityTrusted() else {
      status("发送按键需要辅助功能授权。")
      AppDiagnostics.log("send_shortcut_failed", [
        "target": target, "display": display, "reason": "missing_accessibility"])
      return false
    }
    guard let destination, destination.pid > 0, !destination.isTerminated else {
      status("发送按键未执行：没有可接收的前台 App。")
      AppDiagnostics.log("send_shortcut_failed", [
        "target": target, "display": display, "reason": "missing_frontmost_application"])
      return false
    }
    let current = environment.frontmost()
    AppDiagnostics.log("send_shortcut_start", [
      "target": target, "display": display, "key": shortcut.key,
      "modifiers": shortcut.modifiers.joined(separator: "+"), "route": "process",
      "destination": destination.localizedName ?? destination.bundleIdentifier ?? "",
      "destinationBundle": destination.bundleIdentifier ?? "", "destinationPID": "\(destination.pid)",
      "currentFrontmost": current?.localizedName ?? current?.bundleIdentifier ?? "",
      "currentFrontmostBundle": current?.bundleIdentifier ?? "",
      "hardwareModifiers": environment.hardwareModifiers().joined(separator: "+"),
    ])
    guard postShortcutKeyChord(keyCode: code, modifiers: shortcut.modifiers, destinationPID: destination.pid)
    else {
      guard owns(owner) else { return false }
      status("发送按键失败：\(display)")
      AppDiagnostics.log("send_shortcut_failed", [
        "target": target, "display": display, "reason": "event_creation_failed",
        "destinationBundle": destination.bundleIdentifier ?? "", "destinationPID": "\(destination.pid)",
      ])
      return false
    }
    guard owns(owner) else { return false }
    status("已向 \(destination.localizedName ?? "前台 App") 发送 \(display)。")
    AppDiagnostics.log("send_shortcut_posted", [
      "target": target, "display": display, "route": "process",
      "destination": destination.localizedName ?? destination.bundleIdentifier ?? "",
      "destinationBundle": destination.bundleIdentifier ?? "", "destinationPID": "\(destination.pid)",
    ])
    return owns(owner)
  }

  private func postShortcutKeyChord(keyCode: UInt32, modifiers: [String], destinationPID: pid_t) -> Bool {
    let owner = generation
    let orderedModifiers = modifierOrder.filter { modifiers.contains($0) }
    let source = CGEventSource(stateID: .privateState)
    source?.localEventsSuppressionInterval = 0
    var activeFlags: CGEventFlags = []
    var pressedModifiers: [String] = []
    var keyIsDown = false
    var completed = false
    defer {
      if !completed {
        // Only release synthetic down events successfully posted by this exact chord to this PID.
        // Cleanup is allowed even after shutdown; it cannot introduce a new down event.
        if keyIsDown {
          _ = environment.postEvent(source, keyCode, false, activeFlags, false, destinationPID)
        }
        for modifier in pressedModifiers.reversed() {
          activeFlags.remove(cgModifierFlag(modifier))
          if let code = leftModifierKeyCode(for: modifier) {
            _ = environment.postEvent(source, code, false, activeFlags, true, destinationPID)
          }
        }
      }
    }
    for modifier in orderedModifiers {
      let nextFlags = activeFlags.union(cgModifierFlag(modifier))
      guard owns(owner), postShortcutModifierEvent(
        source: source, modifier: modifier, isDown: true, flags: nextFlags, destinationPID: destinationPID)
      else { return false }
      activeFlags = nextFlags
      pressedModifiers.append(modifier)
      environment.pause(6_000)
    }
    let finalFlags = cgModifiers(orderedModifiers)
    guard owns(owner), postShortcutKeyEvent(
      source: source, keyCode: keyCode, isDown: true, flags: finalFlags, destinationPID: destinationPID)
    else { return false }
    keyIsDown = true
    environment.pause(10_000)
    guard owns(owner), postShortcutKeyEvent(
      source: source, keyCode: keyCode, isDown: false, flags: finalFlags, destinationPID: destinationPID)
    else { return false }
    keyIsDown = false
    for modifier in orderedModifiers.reversed() {
      let nextFlags = activeFlags.subtracting(cgModifierFlag(modifier))
      guard owns(owner), postShortcutModifierEvent(
        source: source, modifier: modifier, isDown: false, flags: nextFlags, destinationPID: destinationPID)
      else { return false }
      activeFlags = nextFlags
      pressedModifiers.removeLast()
      environment.pause(4_000)
    }
    completed = true
    return true
  }

  private func postShortcutKeyEvent(
    source: CGEventSource?, keyCode: UInt32, isDown: Bool, flags: CGEventFlags, destinationPID: pid_t
  ) -> Bool {
    guard active else { return false }
    return environment.postEvent(source, keyCode, isDown, flags, false, destinationPID)
  }

  private func postShortcutModifierEvent(
    source: CGEventSource?, modifier: String, isDown: Bool, flags: CGEventFlags, destinationPID: pid_t
  ) -> Bool {
    guard active, let code = leftModifierKeyCode(for: modifier) else { return false }
    return environment.postEvent(source, code, isDown, flags, true, destinationPID)
  }

  private func cgModifierFlag(_ modifier: String) -> CGEventFlags {
    switch modifier {
    case "command": return .maskCommand
    case "option": return .maskAlternate
    case "control": return .maskControl
    case "shift": return .maskShift
    default: return []
    }
  }

  private func leftModifierKeyCode(for modifier: String) -> UInt32? {
    switch modifier {
    case "command": return UInt32(kVK_Command)
    case "option": return UInt32(kVK_Option)
    case "control": return UInt32(kVK_Control)
    case "shift": return UInt32(kVK_Shift)
    default: return nil
    }
  }

  func toggleNativeFullScreen() { submitWindowArrangement(.nativeFullScreen) }

  func closeWindowSmart() {
    guard active else { return }
    cancelWindowArrangement()
    closeGeneration = UUID()
    let closeOwner = closeGeneration
    let owner = generation
    let previous = closeExecution
    closeExecution = nil
    previous?.cancel()
    guard owns(owner), closeGeneration == closeOwner else { return }
    let requested = environment.frontmost()
    let browserName: String?
    switch requested?.bundleIdentifier {
    case "com.google.Chrome": browserName = "Google Chrome"
    case "com.microsoft.edgemac": browserName = "Microsoft Edge"
    default: browserName = nil
    }
    guard let browserName else {
      if sendShortcut("⌘ W") { status("已发送 ⌘ W。") }
      return
    }
    let script = """
      tell application "\(browserName)"
        if (count of windows) > 0 then close active tab of front window
      end tell
      """
    let execution = environment.makeProcess(
      URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], 2, 32_768
    ) { [weak self] result in
      guard let self, self.owns(owner), self.closeGeneration == closeOwner else { return }
      self.closeExecution = nil
      guard self.sameApplication(self.environment.frontmost(), requested) else {
        self.status("前台 App 已变化，本次关闭已取消。")
        return
      }
      if result.cancelled { return }
      if result.succeeded { self.status("已关闭当前标签页。") }
      else if self.sendShortcut("⌘ W") { self.status("已发送 ⌘ W。") }
    }
    closeExecution = execution
    execution.start()
  }

  private func sameApplication(
    _ lhs: ShortcutActionApplication?, _ rhs: ShortcutActionApplication?
  ) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.pid > 0 && lhs.pid == rhs.pid && lhs.launchTime == rhs.launchTime && !lhs.isTerminated
  }

  func insertText(_ text: String) {
    guard active else { return }
    guard !text.isEmpty else { status("短语内容为空。"); return }
    textGeneration = UUID()
    let textOwner = textGeneration
    let owner = generation
    restoreTemporaryWrite()
    guard owns(owner), textGeneration == textOwner else { return }
    let markClipboardChange = environment.markClipboardChange
    let requested = environment.frontmost()
    environment.writeText(
      text,
      { [weak self] in
        guard let self else { return false }
        return self.owns(owner) && self.textGeneration == textOwner
          && self.sameApplication(self.environment.frontmost(), requested)
      },
      { [weak self] write in
        guard let self else {
          if write?.restoreIfStillOwned() == true {
            markClipboardChange()
          }
          return
        }
        guard self.owns(owner), self.textGeneration == textOwner else {
          if write?.restoreIfStillOwned() == true { self.environment.markClipboardChange() }
          return
        }
        guard let write else { self.status("输入短语失败：未改动原剪贴板。"); return }
        self.temporaryWrite = write
        self.environment.markClipboardChange()
        guard self.owns(owner), self.textGeneration == textOwner else { return }
        guard self.sameApplication(self.environment.frontmost(), requested) else {
          self.restoreTemporaryWrite()
          self.status("前台 App 已变化，本次输入已取消。")
          return
        }
        let sent = self.sendShortcut("⌘ V")
        guard self.owns(owner), self.textGeneration == textOwner else { return }
        if sent { self.status("已输入短语。") }
        else { self.restoreTemporaryWrite(); return }
        guard self.owns(owner), self.textGeneration == textOwner else { return }
        self.restoreTask = self.environment.schedule(0.8) { [weak self] in
          guard let self, self.owns(owner), self.textGeneration == textOwner else { return }
          self.restoreTemporaryWrite()
        }
      })
  }

  private func restoreTemporaryWrite() {
    let restoration = restoreTask
    let write = temporaryWrite
    restoreTask = nil
    temporaryWrite = nil
    restoration?.cancel()
    if write?.restoreIfStillOwned() == true { environment.markClipboardChange() }
  }

  func applyWindowPreset(_ target: String) {
    guard active else { return }
    guard WindowPreset(rawValue: target) != nil, let action = WindowArrangementAction(rawValue: target)
    else { status("窗口动作无效：\(target)"); return }
    submitWindowArrangement(action)
  }

  private func cancelWindowArrangement() {
    windowGeneration = UUID()
    windows.cancel()
  }

  private func submitWindowArrangement(_ action: WindowArrangementAction) {
    guard active else { return }
    guard environment.accessibilityTrusted() else {
      cancelWindowArrangement()
      status("窗口管理需要完成系统授权。")
      if active { presentAuthorization?() }
      return
    }
    guard let app = environment.frontmost(), app.pid > 0, !app.isTerminated else {
      cancelWindowArrangement()
      status("没有找到当前前台 App。")
      return
    }
    windowGeneration = UUID()
    let windowOwner = windowGeneration
    let owner = generation
    AppDiagnostics.log("window_preset_start", ["preset": action.rawValue, "bundle": app.bundleIdentifier ?? ""])
    windows.submit(
      action: action, application: WindowArrangementApplication(pid: app.pid, launchTime: app.launchTime),
      screens: environment.screens(), screenProvider: environment.screens
    ) { [weak self] result in
      guard let self, self.owns(owner), self.windowGeneration == windowOwner else { return }
      self.status(result.message)
      AppDiagnostics.log("window_preset_finished", ["preset": action.rawValue, "result": result.status.rawValue])
    }
  }
}
