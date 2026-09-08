import AppKit
import Darwin
import Foundation

private let helperEnvironment = ProcessInfo.processInfo.environment
private let notificationNamespace =
  helperEnvironment["AIXLG_NOTIFICATION_NAMESPACE"] ?? "invalid.aixlg.helper.notification"
private let sleepStateNotificationName = Notification.Name(
  "\(notificationNamespace).sleepStatusStateChanged")
private let toggleSleepStatusNotificationName = Notification.Name(
  "\(notificationNamespace).toggleSleepStatus")
private let showSleepManagementNotificationName = Notification.Name(
  "\(notificationNamespace).showSleepManagement")

private struct SleepState {
  let active: Bool
  let status: String
}

private enum SleepHelperProcessRunner {
  private static let maximumCapturedOutputBytes = 1_048_576

  static func run(
    executableURL: URL,
    arguments: [String]
  ) -> (status: Int32, output: Data)? {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      try? pipe.fileHandleForWriting.close()

      // Drain while the child is still allowed to run so a full pipe can never block its exit.
      var captured = Data()
      while true {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1_024)
        guard !chunk.isEmpty else { break }
        let remaining = maximumCapturedOutputBytes - captured.count
        if remaining > 0 { captured.append(chunk.prefix(remaining)) }
      }
      process.waitUntilExit()
      return (process.terminationStatus, captured)
    } catch {
      try? pipe.fileHandleForWriting.close()
      try? pipe.fileHandleForReading.close()
      return nil
    }
  }
}

#if AIXLG_HELPER_PROCESS_PIPE_FIXTURE
  func runSleepHelperLargeOutputProcess(
    executableURL: URL,
    arguments: [String]
  ) -> (status: Int32, outputByteCount: Int)? {
    guard let result = SleepHelperProcessRunner.run(
      executableURL: executableURL,
      arguments: arguments)
    else { return nil }
    return (result.status, result.output.count)
  }
#endif

@MainActor
private final class SleepStatusItemApp: NSObject, NSApplicationDelegate {
  private let parentPID: pid_t
  private let parentBundleID: String?
  private let parentAppPath: String?
  private let parentExecutableName: String?
  private let helperExecutableName: String?
  private let capabilityToken: String?
  private var statusItem: NSStatusItem?
  private var parentTimer: Timer?
  private var state = SleepState(active: false, status: "未开启")
  private lazy var launchCodeIdentityIsValid: Bool = {
    guard let parentAppPath, let helperExecutableName else { return false }
    let helperPath = URL(fileURLWithPath: parentAppPath, isDirectory: true)
      .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
      .standardizedFileURL.path
    return Self.codeSignatureChainIsValid(
      parentAppPath: parentAppPath,
      helperPath: helperPath)
  }()

  override init() {
    let environment = ProcessInfo.processInfo.environment
    if let rawPID = environment["AIXLG_PARENT_PID"],
      let parsedPID = Int32(rawPID)
    {
      parentPID = parsedPID
    } else {
      parentPID = 0
    }
    parentBundleID = Self.nonEmpty(environment["AIXLG_PARENT_BUNDLE_ID"])
    parentAppPath = Self.nonEmpty(environment["AIXLG_PARENT_APP_PATH"])
    parentExecutableName = Self.nonEmpty(environment["AIXLG_PARENT_EXECUTABLE"])
    helperExecutableName = Self.nonEmpty(environment["AIXLG_HELPER_EXECUTABLE"])
    capabilityToken = Self.nonEmpty(environment["AIXLG_SLEEP_CAPABILITY_TOKEN"])
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard parentIdentityIsValid() else {
      NSApp.terminate(nil)
      return
    }
    NSApp.setActivationPolicy(.accessory)
    buildStatusItem()
    startObservers()
    startParentWatchdog()
  }

  func applicationWillTerminate(_ notification: Notification) {
    parentTimer?.invalidate()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  private func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = nil
    item.button?.imagePosition = .noImage
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.button?.font = .systemFont(ofSize: 12.5, weight: .semibold)
    item.isVisible = true
    statusItem = item
    refreshStatusItem()
  }

  private func startObservers() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleSleepStateNotification(_:)),
      name: sleepStateNotificationName,
      object: capabilityToken
    )
  }

  private func startParentWatchdog() {
    parentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.exitIfParentIsGone() }
    }
  }

  @objc private func handleSleepStateNotification(_ notification: Notification) {
    guard notification.object as? String == capabilityToken else { return }
    let info = notification.userInfo ?? [:]
    let active = (info["active"] as? String) == "true"
    let status = info["status"] as? String ?? (active ? "保持唤醒" : "未开启")
    state = SleepState(active: active, status: status)
    refreshStatusItem()
  }

  private func refreshStatusItem() {
    guard let button = statusItem?.button else { return }
    button.title = state.active ? "醒┃" : "眠╮"
    button.font = .systemFont(ofSize: 12.5, weight: .semibold)
    button.toolTip =
      state.active
      ? "左键切换为眠 · 右键打开保持唤醒 · \(state.status)"
      : "左键切换为醒 · 右键打开保持唤醒"
    statusItem?.length = NSStatusItem.variableLength
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let notificationName =
      NSApp.currentEvent?.type == .rightMouseUp
      ? showSleepManagementNotificationName : toggleSleepStatusNotificationName
    DistributedNotificationCenter.default().postNotificationName(
      notificationName, object: capabilityToken, deliverImmediately: true)
  }

  private func exitIfParentIsGone() {
    guard parentIdentityIsValid() else {
      NSApp.terminate(nil)
      return
    }
  }

  private func parentIdentityIsValid() -> Bool {
    guard parentPID > 1,
      getppid() == parentPID,
      let parentBundleID,
      let parentExecutableName,
      let helperExecutableName,
      let capabilityToken,
      capabilityToken.utf8.count >= 32,
      notificationNamespace == parentBundleID,
      let parentAppPath,
      let app = NSRunningApplication(processIdentifier: parentPID),
      !app.isTerminated,
      app.bundleIdentifier == parentBundleID,
      let parentExecutablePath = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL
        .path,
      let helperExecutablePath = Self.currentExecutablePath(),
      app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
        == URL(fileURLWithPath: parentAppPath).resolvingSymlinksInPath().standardizedFileURL.path,
      parentExecutablePath
        == URL(fileURLWithPath: parentAppPath, isDirectory: true)
        .appendingPathComponent("Contents/MacOS/\(parentExecutableName)")
        .resolvingSymlinksInPath().standardizedFileURL.path,
      helperExecutablePath
        == URL(fileURLWithPath: parentAppPath, isDirectory: true)
        .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        .resolvingSymlinksInPath().standardizedFileURL.path,
      launchCodeIdentityIsValid,
      parentProcessIsAlive()
    else {
      return false
    }
    return true
  }

  private func parentProcessIsAlive() -> Bool {
    guard parentPID > 0 else { return false }
    return kill(parentPID, 0) == 0
  }

  private func runningParentApplication() -> NSRunningApplication? {
    if parentPID > 0 {
      if let app = NSRunningApplication(processIdentifier: parentPID) {
        return app
      }
    }
    guard let parentBundleID else { return nil }
    return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == parentBundleID }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  private static func currentExecutablePath() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
      .resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func codeSignatureChainIsValid(
    parentAppPath: String,
    helperPath: String
  ) -> Bool {
    guard runCodeSign(["--verify", "--deep", "--strict", parentAppPath])?.status == 0,
      runCodeSign(["--verify", "--strict", helperPath])?.status == 0
    else {
      return false
    }

    let infoPath = URL(fileURLWithPath: parentAppPath, isDirectory: true)
      .appendingPathComponent("Contents/Info.plist").path
    let isFormalRelease =
      (NSDictionary(contentsOfFile: infoPath)?["AIXLGFormalReleaseCompiled"] as? Bool) == true
    guard isFormalRelease else { return true }
    guard
      let parentTeam = codeSigningValue(
        "TeamIdentifier",
        output: runCodeSign(["-dv", "--verbose=4", parentAppPath])?.output),
      parentTeam != "not set",
      let helperTeam = codeSigningValue(
        "TeamIdentifier",
        output: runCodeSign(["-dv", "--verbose=4", helperPath])?.output),
      helperTeam == parentTeam
    else {
      return false
    }
    return true
  }

  private static func runCodeSign(_ arguments: [String]) -> (status: Int32, output: String)? {
    guard
      let result = SleepHelperProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: arguments)
    else { return nil }
    return (result.status, String(data: result.output, encoding: .utf8) ?? "")
  }

  private static func codeSigningValue(_ key: String, output: String?) -> String? {
    guard let output else { return nil }
    let prefix = "\(key)="
    return output.split(separator: "\n").compactMap { line -> String? in
      let text = String(line)
      guard text.hasPrefix(prefix) else { return nil }
      let value = String(text.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }.first
  }
}

#if !AIXLG_HELPER_PROCESS_PIPE_FIXTURE
  @main
  private enum SleepStatusHelperMain {
    @MainActor
    static func main() {
      let delegate = SleepStatusItemApp()
      let app = NSApplication.shared
      app.delegate = delegate
      app.run()
    }
  }
#endif
