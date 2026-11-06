import Combine
import Foundation

/// Owns the existing login preference. It never loads a job or creates a new App identity.
@MainActor
final class StartupPreferenceWorkspace: ObservableObject {
  @Published private(set) var enabled = false
  private let identity: AppRuntimeIdentity
  private let agentURL: URL
  private let bundlePath: String
  private let files: FileManager
  private var onStatus: ((String) -> Void)?
  private var stopped = false
  private var isChanging = false

  init(
    identity: AppRuntimeIdentity,
    agentURL: URL? = nil,
    bundlePath: String = Bundle.main.bundlePath,
    files: FileManager = .default,
    onStatus: @escaping (String) -> Void
  ) {
    self.identity = identity
    self.agentURL = agentURL ?? files.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("\(identity.launchAgentIdentifier).plist")
    self.bundlePath = bundlePath
    self.files = files
    self.onStatus = onStatus
  }

  func refresh() {
    guard !stopped, !isChanging else { return }
    isChanging = true
    defer { isChanging = false }
    publishCurrentPreference()
  }

  func setEnabled(_ value: Bool) {
    guard !stopped, !isChanging else { return }
    isChanging = true
    defer { isChanging = false }
    guard identity.allowsLaunchAtLogin else {
      enabled = false
      onStatus?("运行身份无效，不能更改开机启动。")
      return
    }
    do {
      try write(value)
      publishCurrentPreference()
      onStatus?(value ? "已开启开机自动启动。" : "已关闭开机自动启动。")
    } catch {
      publishCurrentPreference()
      onStatus?("开机启动设置失败：\(error.localizedDescription)")
    }
  }

  /// Preserve the existing user's enabled preference when the installed App path changes.
  /// An absent preference is never turned on by startup or refresh.
  func repairExistingPreference() {
    guard !stopped, !isChanging, let arguments = enabledManagedArguments(),
      arguments[1] != bundlePath else { return }
    isChanging = true
    defer { isChanging = false }
    do { try write(true) }
    catch { onStatus?("开机启动设置修复失败：\(error.localizedDescription)") }
    publishCurrentPreference()
  }

  func shutdown() {
    stopped = true
    onStatus = nil
  }

  private func publishCurrentPreference() {
    guard !stopped else { return }
    enabled = enabledManagedArguments()?[1] == bundlePath
  }

  /// Only our recognized, explicitly enabled job may be repaired automatically.
  /// Unknown/malformed jobs and explicit disabled preferences retain their exact bytes.
  private func enabledManagedArguments() -> [String]? {
    guard identity.allowsLaunchAtLogin,
      files.fileExists(atPath: agentURL.path),
      let data = try? LocalConfigurationFileCodec.readData(from: agentURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      plist["Label"] as? String == identity.launchAgentIdentifier,
      plist["RunAtLoad"] as? Bool == true,
      plist["Disabled"] as? Bool != true,
      plist["Program"] == nil,
      let arguments = plist["ProgramArguments"] as? [String],
      arguments.count == 2, arguments[0] == "/usr/bin/open",
      arguments[1].hasPrefix("/"),
      URL(fileURLWithPath: arguments[1]).pathExtension.lowercased() == "app"
    else { return nil }
    return arguments
  }

  private func write(_ value: Bool) throws {
    if value {
      try files.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let plist: [String: Any] = [
        "Label": identity.launchAgentIdentifier,
        "ProgramArguments": ["/usr/bin/open", bundlePath],
        "RunAtLoad": true,
      ]
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: agentURL, options: [.atomic])
    } else if files.fileExists(atPath: agentURL.path) {
      // Report a failed removal instead of telling the user the preference was disabled.
      try files.removeItem(at: agentURL)
    }
  }
}
