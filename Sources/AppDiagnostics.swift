import Foundation

enum AppDiagnostics {
  private final class EnabledState: @unchecked Sendable {
    private let lock = NSLock()
    private let environmentForcesEnabled: Bool
    private var value: Bool

    init() {
      environmentForcesEnabled =
        ProcessInfo.processInfo.environment["AIXLG_DIAGNOSTICS"] == "1"
      value =
        environmentForcesEnabled
        || UserDefaults.standard.bool(forKey: AppDiagnostics.enabledDefaultsKey)
    }

    func read() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func update(userEnabled: Bool) {
      lock.lock()
      value = environmentForcesEnabled || userEnabled
      lock.unlock()
    }
  }

  private static let queue = DispatchQueue(
    label: "\(AppRuntimeIdentity.current.notificationNamespace).diagnostics")
  private static let maxBytes = 512 * 1024
  private static let enabledDefaultsKey = "diagnosticsEnabled"
  private static let enabledState = EnabledState()

  static var isEnabled: Bool {
    enabledState.read()
  }

  static var logURL: URL {
    AppRuntimeIdentity.current.logDirectoryURL.appendingPathComponent("events.log")
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    enabledState.update(userEnabled: enabled)
  }

  static func log(_ event: String) {
    log(event, [:])
  }

  static func log(_ event: String, _ fields: @autoclosure () -> [String: String]) {
    guard isEnabled else { return }
    let fields = fields()
    let timestamp = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    let payload =
      fields
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
      .joined(separator: " ")
    let line = payload.isEmpty ? "\(timestamp) \(event)\n" : "\(timestamp) \(event) \(payload)\n"
    queue.async {
      append(line)
    }
  }

  private static func append(_ line: String) {
    let url = logURL
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    rotateIfNeeded(url)
    let data = Data(line.utf8)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: data)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  }

  private static func rotateIfNeeded(_ url: URL) {
    guard
      let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
      size.intValue > maxBytes
    else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
