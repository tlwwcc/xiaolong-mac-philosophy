import Darwin
import Foundation

/// A failed decode may put defaults in memory, but must never turn a later edit into silent
/// destruction of the user's original file. Each configuration owns its own recovery state.
struct LocalConfigurationRecovery {
  private(set) var requiresBackup = false
  private(set) var message: String?
  private(set) var backupURL: URL?
  let name: String
  private var externalChangeDetected = false
  var beforeRecoveryReplacement: (() throws -> Void)?

  init(name: String, beforeRecoveryReplacement: (() throws -> Void)? = nil) {
    self.name = name
    self.beforeRecoveryReplacement = beforeRecoveryReplacement
  }

  mutating func recordReadFailure() {
    requiresBackup = true
    message = "\(name)读取失败，当前使用默认值。原文件已保护，保存前会先备份。"
  }

  mutating func recordReadSuccess() {
    requiresBackup = false
    message = nil
    backupURL = nil
    externalChangeDetected = false
  }

  mutating func write(_ data: Data, to url: URL) throws {
    guard !externalChangeDetected else { throw CocoaError(.fileWriteFileExists) }
    if requiresBackup {
      do {
        backupURL = try Self.preserveOriginal(at: url)
      } catch {
        message = "\(name)原文件暂时无法备份，已暂停保存，避免覆盖。请检查配置文件夹。"
        throw error
      }
      try beforeRecoveryReplacement?()
      guard let backupURL,
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
          == .typeRegular,
        try LocalConfigurationFileCodec.readData(from: url)
          == LocalConfigurationFileCodec.readData(from: backupURL)
      else {
        externalChangeDetected = true
        message = "检测到\(name)已在外部修改，已暂停保存。请重新打开软件后再试。"
        throw CocoaError(.fileWriteFileExists)
      }
    }
    try data.write(to: url, options: [.atomic])
    if requiresBackup {
      requiresBackup = false
      message = "原\(name)已备份，可从配置文件夹的 backups 中找回。"
    }
  }

  private static func preserveOriginal(at url: URL) throws -> URL {
    let manager = FileManager.default
    // A symlink, directory, unreadable file, or oversized input is not a safe recovery source.
    // Leave it in place and refuse the save instead of following or allocating it without limit.
    let attributes = try manager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let original = try LocalConfigurationFileCodec.readData(from: url)
    let directory = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    if manager.fileExists(atPath: directory.path) {
      let type = try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
      guard type == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
    } else {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let backup = directory.appendingPathComponent(
      "\(url.deletingPathExtension().lastPathComponent)-unreadable-\(UUID().uuidString).json")
    let descriptor = open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: original)
    try handle.synchronize()
    try handle.close()
    guard try LocalConfigurationFileCodec.readData(from: backup) == original else {
      throw CocoaError(.fileWriteUnknown)
    }
    return backup
  }
}
