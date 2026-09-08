import Darwin
import Foundation

struct AIPlayerMPVStartupGeneration: Equatable {
  private(set) var value: UInt64 = 0

  mutating func begin() -> UInt64 {
    value &+= 1
    return value
  }

  func owns(_ generation: UInt64) -> Bool {
    value == generation
  }
}

enum AIPlayerProcessTermination {
  static func terminateAndWait(_ process: Process, timeout: TimeInterval) {
    if process.isRunning { process.terminate() }
    var deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return }
    Darwin.kill(process.processIdentifier, SIGKILL)
    deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
}

enum AIPlayerUnixSocket {
  static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
        bytes.withUnsafeBufferPointer { source in
          if let baseAddress = source.baseAddress {
            memcpy(destination, baseAddress, bytes.count)
          }
        }
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        body(socketAddress, length)
      }
    }
  }

  static func connect(path: String, timeoutSeconds: Double = 1.5) -> Int32? {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var timeout = timeval(
      tv_sec: Int(timeoutSeconds),
      tv_usec: Int32((timeoutSeconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
    )
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    let connected = withAddress(path: path) { address, length in
      Darwin.connect(descriptor, address, length)
    } ?? -1
    guard connected == 0 else {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  static func sendJSON(
    _ object: Any,
    to path: String,
    expectedRequestID: String? = nil
  ) throws -> [String: Any] {
    guard let descriptor = connect(path: path) else {
      throw AIPlayerError.operationFailed("播放器 IPC 连接失败。")
    }
    defer { Darwin.close(descriptor) }
    var payload = try JSONSerialization.data(withJSONObject: object)
    payload.append(0x0A)
    try payload.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: sent), bytes.count - sent)
        guard count > 0 else { throw AIPlayerError.operationFailed("播放器 IPC 写入失败。") }
        sent += count
      }
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while response.count < 1_048_576 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count > 0 else { break }
      response.append(contentsOf: buffer.prefix(count))
      while let newline = response.firstIndex(of: 0x0A) {
        let line = response.prefix(upTo: newline)
        response.removeSubrange(...newline)
        guard let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
          continue
        }
        if let expectedRequestID {
          if result["request_id"] as? String == expectedRequestID { return result }
        } else {
          return result
        }
      }
    }
    throw AIPlayerError.operationFailed("播放器 IPC 未返回匹配响应。")
  }
}

final class AIPlayerMPV: AIPlayerPlaybackEngine, @unchecked Sendable {
  private let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
  private let socketURL: URL
  private let lock = NSLock()
  private var process: Process?
  private var startupGeneration = AIPlayerMPVStartupGeneration()

  init(baseDirectory: URL) {
    socketURL = baseDirectory.appendingPathComponent("mpv.sock")
  }

  var dependencyAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: executableURL.path)
  }

  var isAvailable: Bool { dependencyAvailable }
  var capabilities: AIPlayerPlaybackCapabilities {
    AIPlayerPlaybackCapabilities(commonAudio: false, extendedMedia: dependencyAvailable)
  }
  var requiresMainThreadAccess: Bool { false }

  func stop() {
    lock.lock()
    let runningProcess = process
    process = nil
    _ = startupGeneration.begin()
    if let runningProcess {
      AIPlayerProcessTermination.terminateAndWait(runningProcess, timeout: 0.5)
    }
    try? FileManager.default.removeItem(at: socketURL)
    lock.unlock()
  }

  func load(_ url: URL, resumeAt: Double = 0) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIPlayerError.missingFile(url.path)
    }
    guard AIPlayerFormatting.mediaKind(for: url) != nil else {
      throw AIPlayerError.unsupportedFormat(url.pathExtension)
    }
    try ensureRunning()
    _ = try command(["loadfile", url.standardizedFileURL.path, "replace"])
    if resumeAt > 0 {
      _ = try setProperty("time-pos", value: resumeAt)
    }
    _ = try setProperty("pause", value: false)
  }

  func pause() throws { _ = try setProperty("pause", value: true) }

  func resume() throws { _ = try setProperty("pause", value: false) }

  func toggle() throws {
    try ensureRunning()
    _ = try command(["cycle", "pause"])
  }

  func seek(seconds: Double) throws {
    try ensureRunning()
    _ = try command(["seek", seconds, "relative", "exact"])
  }

  func setVolume(_ volume: Double) throws {
    _ = try setProperty("volume", value: min(max(volume, 0), 100))
  }

  func snapshot() throws -> AIPlayerPlaybackSnapshot {
    try ensureRunning()
    let pathValue = try property("path")
    guard let pathValue else {
      return AIPlayerPlaybackSnapshot()
    }
    guard let path = pathValue as? String, !path.isEmpty else {
      throw AIPlayerError.operationFailed("mpv 返回了无效的媒体路径。")
    }
    guard let pause = try property("pause") as? Bool else {
      throw AIPlayerError.operationFailed("mpv 未返回有效的播放状态。")
    }
    let position = number(try property("time-pos"))
    let duration = number(try property("duration"))
    let volume = number(try property("volume"), fallback: 70)
    return AIPlayerPlaybackSnapshot(
      playback: pause ? "paused" : "playing",
      path: path,
      positionSeconds: position,
      durationSeconds: duration,
      volume: volume
    )
  }

  private func ensureRunning() throws {
    guard dependencyAvailable else { throw AIPlayerError.dependencyMissing }
    lock.lock()
    defer { lock.unlock() }
    if process?.isRunning == true, FileManager.default.fileExists(atPath: socketURL.path) {
      return
    }
    if let staleProcess = process {
      process = nil
      AIPlayerProcessTermination.terminateAndWait(staleProcess, timeout: 0.5)
    }
    process = nil
    try? FileManager.default.removeItem(at: socketURL)
    let generation = startupGeneration.begin()
    let newProcess = Process()
    newProcess.executableURL = executableURL
    newProcess.arguments = [
      "--idle=yes",
      "--no-terminal",
      "--no-config",
      "--input-ipc-server=\(socketURL.path)",
      "--keep-open=yes",
      "--force-window=no",
      "--audio-display=no",
      "--save-position-on-quit=no",
    ]
    newProcess.standardOutput = FileHandle.nullDevice
    newProcess.standardError = FileHandle.nullDevice
    do {
      try newProcess.run()
      process = newProcess
    } catch {
      throw AIPlayerError.operationFailed("mpv 启动失败：\(error.localizedDescription)")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
      if startupGeneration.owns(generation), process === newProcess,
        newProcess.isRunning,
        FileManager.default.fileExists(atPath: socketURL.path)
      {
        return
      }
      if !newProcess.isRunning { break }
      Thread.sleep(forTimeInterval: 0.04)
    }
    if startupGeneration.owns(generation), process === newProcess {
      process = nil
    }
    AIPlayerProcessTermination.terminateAndWait(newProcess, timeout: 0.5)
    try? FileManager.default.removeItem(at: socketURL)
    throw AIPlayerError.operationFailed("mpv 已启动，但 IPC 未就绪。")
  }

  private func command(_ values: [Any]) throws -> [String: Any] {
    let response = try rawCommand(values)
    if let error = response["error"] as? String, error != "success" {
      throw AIPlayerError.operationFailed("mpv：\(error)")
    }
    return response
  }

  private func rawCommand(_ values: [Any]) throws -> [String: Any] {
    let requestID = UUID().uuidString
    return try AIPlayerUnixSocket.sendJSON(
      ["command": values, "request_id": requestID],
      to: socketURL.path,
      expectedRequestID: requestID)
  }

  private func property(_ name: String) throws -> Any? {
    let response = try rawCommand(["get_property", name])
    if let error = response["error"] as? String, error != "success" {
      if error == "property unavailable" { return nil }
      throw AIPlayerError.operationFailed("mpv：\(error)")
    }
    guard let data = response["data"], !(data is NSNull) else { return nil }
    return data
  }

  private func setProperty(_ name: String, value: Any) throws -> [String: Any] {
    try ensureRunning()
    return try command(["set_property", name, value])
  }

  private func number(_ value: Any?, fallback: Double = 0) -> Double {
    if let double = value as? Double { return double }
    if let integer = value as? Int { return Double(integer) }
    if let number = value as? NSNumber { return number.doubleValue }
    return fallback
  }

}
