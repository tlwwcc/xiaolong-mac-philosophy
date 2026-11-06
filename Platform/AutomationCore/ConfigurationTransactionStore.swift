import CryptoKit
import Darwin
import Foundation

public struct ConfigurationSnapshot: Equatable, Sendable {
  public let data: Data
  public let revision: String
  public let exists: Bool
}

public struct ConfigurationCommitReceipt: Codable, Equatable, Sendable {
  public let requestID: String
  public let beforeRevision: String
  public let afterRevision: String
  public let backupURL: URL?
  public let changed: Bool
  public let replayed: Bool

  fileprivate func replay() -> Self {
    Self(
      requestID: requestID, beforeRevision: beforeRevision, afterRevision: afterRevision,
      backupURL: backupURL, changed: changed, replayed: true)
  }
}

/// Stores opaque configuration bytes. All writers must pass the revision they actually edited.
/// This is a file transaction, never an arbitrary-action retry facility.
public struct ConfigurationTransactionStore: Sendable {
  public static let missingRevision = "missing"
  public let fileURL: URL
  public let maximumBytes: Int
  public var stateDirectoryURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent(stateDirectoryName, isDirectory: true)
  }

  private var stateDirectoryName: String { ".automation-\(Self.digest(Data(fileURL.lastPathComponent.utf8)).prefix(20))" }
  private static let metadataLimit = 65_536

  public init(fileURL: URL, maximumBytes: Int = 8 * 1_024 * 1_024) {
    self.fileURL = fileURL
    self.maximumBytes = maximumBytes
  }

  /// Strictly read-only: no locks, directories, receipts or recovery writes.
  public func read() throws -> ConfigurationSnapshot {
    try validateLocation()
    guard let parent = try Self.openDirectory(fileURL.deletingLastPathComponent(), create: false) else {
      return Self.snapshot(nil)
    }
    defer { close(parent) }
    return try readSnapshot(parent)
  }

  /// Read-only receipt lookup. Pending receipts require explicit recovery, never implicit replay.
  public func lookupReceipt(
    requestID: String, requestData: Data? = nil
  ) throws -> ConfigurationCommitReceipt? {
    try validateRequestID(requestID)
    try validateLocation()
    guard let state = try Self.openDirectory(stateDirectoryURL, create: false) else { return nil }
    defer { close(state) }
    try Self.validatePrivateDirectory(state)
    guard let record = try loadRecord(requestID: requestID, state: state) else { return nil }
    try checkBinding(record, requestID: requestID, requestData: requestData)
    return try completedReceipt(record, replayed: true)
  }

  /// Resolves a previous crash by inspecting the before/after hashes; never reapplies old bytes.
  public func recover() throws {
    try withTransactionLock { parent, state in
      try recoverActive(parent: parent, state: state)
    }
  }

  /// Request bytes bind an idempotency key to its original intent. The host validates business rules.
  /// Repeating an acknowledged request returns its historical receipt, even if later edits exist.
  /// A nil replacement restores an absent file; it is never equivalent to empty bytes.
  public func commit(
    requestID: String, requestData: Data, expectedRevision: String, replacement: Data?
  ) throws -> ConfigurationCommitReceipt {
    try validateRequestID(requestID)
    guard requestData.count <= 1_048_576 else {
      throw failure("request_too_large", "请求超过 1 MB 上限。")
    }
    guard (replacement?.count ?? 0) <= maximumBytes else {
      throw failure("configuration_too_large", "配置超过允许大小。")
    }
    return try withTransactionLock { parent, state in
      try recoverActive(parent: parent, state: state)
      if let previous = try loadRecord(requestID: requestID, state: state) {
        try checkBinding(previous, requestID: requestID, requestData: requestData)
        // Idempotency is checked before CAS. Never overwrite newer data on a retry.
        return try completedReceipt(previous, replayed: true)
      }
      let before = try readSnapshot(parent)
      guard before.revision == expectedRevision else {
        throw failure(
          "revision_conflict", "配置已被修改，请重新读取后再决定。",
          details: ["expectedRevision": .string(expectedRevision), "actualRevision": .string(before.revision)])
      }
      let afterRevision = replacement.map(Self.digest) ?? Self.missingRevision
      let receiptName = receiptName(requestID)
      let backupName = "backup-\(Self.digest(Data(requestID.utf8))).data"
      let changed = before.revision != afterRevision
      let receipt = ConfigurationCommitReceipt(
        requestID: requestID, beforeRevision: before.revision, afterRevision: afterRevision,
        backupURL: before.exists && changed ? stateDirectoryURL.appendingPathComponent(backupName) : nil,
        changed: changed, replayed: false)

      if before.exists && changed {
        // A request gets exactly one immutable preimage; never overwrite an existing backup.
        if let orphan = try Self.readFile(backupName, directory: state, limit: maximumBytes) {
          guard orphan == before.data else {
            throw failure("backup_failed", "已存在的配置备份不匹配，未替换配置。")
          }
        } else {
          try Self.writeNew(before.data, name: backupName, directory: state)
        }
        guard try Self.readFile(backupName, directory: state, limit: maximumBytes) == before.data else {
          throw failure("backup_failed", "配置备份校验失败，未替换配置。")
        }
      }
      var record = Record(
        schemaVersion: 1, requestID: requestID, requestDigest: Self.digest(requestData),
        status: .prepared, receipt: receipt)
      try saveRecord(record, name: receiptName, state: state)
      try Self.atomicWrite(
        try encode(ActiveJournal(schemaVersion: 1, receiptName: receiptName)),
        name: "active.json", directory: state)

      do {
        if changed {
          // Stage inside our private transaction directory. Recovery can remove this exact file
          // after a crash without guessing which temporary files in the user's folder are ours.
          let stagedName = stagingName(requestID)
          if let replacement {
            try Self.writeNew(replacement, name: stagedName, directory: state)
          }
          // Recheck after staging, immediately before replacing, to catch noncooperating writers.
          guard try readSnapshot(parent).revision == before.revision else {
            throw failure("revision_conflict", "保存前配置发生变化，未覆盖。")
          }
          if replacement != nil {
            guard renameat(state, stagedName, parent, fileURL.lastPathComponent) == 0 else {
              throw Self.ioError("原子替换配置")
            }
          } else {
            // An explicit compensation may restore the original absence. It uses the same
            // CAS, immutable preimage, durable journal and receipt as replacement writes.
            try Self.remove(fileURL.lastPathComponent, directory: parent)
          }
          guard fsync(parent) == 0, fsync(state) == 0 else {
            throw Self.ioError("同步配置目录")
          }
        }
        guard try readSnapshot(parent).revision == afterRevision else {
          throw failure("transaction_unknown", "配置回读与写入结果不同，请查询请求回执。")
        }
        record.status = .committed
        try saveRecord(record, name: receiptName, state: state)
        try Self.remove("active.json", directory: state)
        return receipt
      } catch {
        // Recovery writes only the receipt. Never roll back over a later writer's data.
        do { try recoverActive(parent: parent, state: state) } catch {}
        if let finished = try? loadRecord(requestID: requestID, state: state),
          finished.status == .committed {
          return finished.receipt
        }
        throw error
      }
    }
  }

  public static func revision(for data: Data) -> String { digest(data) }

  private enum Status: String, Codable { case prepared, committed, interrupted, unknown }
  private struct Record: Codable {
    let schemaVersion: Int
    let requestID: String
    let requestDigest: String
    var status: Status
    let receipt: ConfigurationCommitReceipt
  }
  private struct ActiveJournal: Codable {
    let schemaVersion: Int
    let receiptName: String
  }

  private func readSnapshot(_ parent: Int32) throws -> ConfigurationSnapshot {
    Self.snapshot(try Self.readFile(fileURL.lastPathComponent, directory: parent, limit: maximumBytes))
  }

  private static func snapshot(_ data: Data?) -> ConfigurationSnapshot {
    ConfigurationSnapshot(data: data ?? Data(), revision: data.map(digest) ?? missingRevision, exists: data != nil)
  }

  private func receiptName(_ requestID: String) -> String {
    "receipt-\(Self.digest(Data(requestID.utf8))).json"
  }

  private func stagingName(_ requestID: String) -> String {
    "replacement-\(Self.digest(Data(requestID.utf8))).data"
  }

  private func loadRecord(requestID: String, state: Int32) throws -> Record? {
    guard let bytes = try Self.readFile(receiptName(requestID), directory: state, limit: Self.metadataLimit) else {
      return nil
    }
    let record: Record = try decode(bytes)
    try validateRecord(record)
    guard record.requestID == requestID else {
      throw failure("receipt_corrupt", "请求回执身份不匹配，已停止写入。")
    }
    return record
  }

  private func saveRecord(_ record: Record, name: String, state: Int32) throws {
    try Self.atomicWrite(try encode(record), name: name, directory: state)
  }

  private func validateRecord(_ record: Record) throws {
    let receipt = record.receipt
    let expectedBackup = stateDirectoryURL.appendingPathComponent(
      "backup-\(Self.digest(Data(record.requestID.utf8))).data")
    guard record.schemaVersion == 1,
      receipt.requestID == record.requestID,
      Self.isDigest(record.requestDigest),
      receipt.afterRevision == Self.missingRevision || Self.isDigest(receipt.afterRevision),
      receipt.beforeRevision == Self.missingRevision || Self.isDigest(receipt.beforeRevision),
      receipt.changed == (receipt.beforeRevision != receipt.afterRevision),
      receipt.backupURL == (
        receipt.changed && receipt.beforeRevision != Self.missingRevision ? expectedBackup : nil)
    else {
      throw failure("receipt_corrupt", "请求回执内容不完整或不一致，已停止写入。")
    }
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private func checkBinding(_ record: Record, requestID: String, requestData: Data?) throws {
    guard record.requestID == requestID,
      requestData.map({ Self.digest($0) == record.requestDigest }) ?? true else {
      throw failure("request_id_conflict", "这个请求编号已用于不同内容，未重复执行。")
    }
  }

  private func completedReceipt(_ record: Record, replayed: Bool) throws -> ConfigurationCommitReceipt {
    switch record.status {
    case .committed: return replayed ? record.receipt.replay() : record.receipt
    case .interrupted:
      throw failure("transaction_interrupted", "上次请求在保存前中断，未自动重试。请重新读取并使用新请求编号。")
    case .prepared, .unknown:
      throw failure("transaction_unknown", "上次请求的结果尚未确认，未重复执行。请恢复并查询同一请求编号。")
    }
  }

  private func recoverActive(parent: Int32, state: Int32) throws {
    guard let journalBytes = try Self.readFile("active.json", directory: state, limit: Self.metadataLimit) else {
      return
    }
    let journal: ActiveJournal = try decode(journalBytes)
    guard journal.schemaVersion == 1,
      journal.receiptName.hasPrefix("receipt-"), journal.receiptName.hasSuffix(".json"),
      journal.receiptName.count == 77,
      journal.receiptName.dropFirst(8).dropLast(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      let recordBytes = try Self.readFile(journal.receiptName, directory: state, limit: Self.metadataLimit)
    else { throw failure("receipt_corrupt", "恢复日志无效，已停止写入。") }
    var record: Record = try decode(recordBytes)
    try validateRecord(record)
    guard receiptName(record.requestID) == journal.receiptName else {
      throw failure("receipt_corrupt", "恢复回执身份不匹配，已停止写入。")
    }
    if record.status == .prepared {
      let current = try readSnapshot(parent).revision
      if current == record.receipt.afterRevision {
        record.status = .committed
      } else if current == record.receipt.beforeRevision {
        record.status = .interrupted
      } else {
        record.status = .unknown
      }
      try saveRecord(record, name: journal.receiptName, state: state)
    }
    try Self.remove(stagingName(record.requestID), directory: state)
    try Self.remove("active.json", directory: state)
  }

  private func withTransactionLock<T>(_ body: (Int32, Int32) throws -> T) throws -> T {
    try validateLocation()
    guard let parent = try Self.openDirectory(fileURL.deletingLastPathComponent(), create: true) else {
      throw failure("storage_unavailable", "配置目录不可用。")
    }
    defer { close(parent) }
    let stateName = stateDirectoryName
    if mkdirat(parent, stateName, mode_t(0o700)) != 0, errno != EEXIST {
      throw Self.ioError("创建事务目录")
    }
    let state = openat(parent, stateName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard state >= 0 else { throw Self.ioError("打开事务目录") }
    defer { close(state) }
    try Self.validatePrivateDirectory(state)
    // Lock the stable directory inode itself. There is no first-writer lock-file creation race,
    // and atomically replacing configuration/receipt files cannot replace the lock's inode.
    while flock(state, LOCK_EX) != 0 {
      if errno != EINTR { throw Self.ioError("锁定配置") }
    }
    defer { _ = flock(state, LOCK_UN) }
    return try body(parent, state)
  }

  private func validateLocation() throws {
    guard fileURL.isFileURL, fileURL.path.hasPrefix("/"),
      !fileURL.path.utf8.contains(0), fileURL.lastPathComponent != ".",
      fileURL.lastPathComponent != "..", !fileURL.lastPathComponent.isEmpty,
      maximumBytes > 0, maximumBytes <= 64 * 1_024 * 1_024 else {
      throw failure("invalid_storage", "配置路径或读取上限无效。")
    }
  }

  private func validateRequestID(_ id: String) throws {
    guard !id.isEmpty, id.utf8.count <= 256,
      id == id.trimmingCharacters(in: .whitespacesAndNewlines),
      !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw failure("invalid_request_id", "请求编号必须为 1–256 字节，且不能含控制字符或首尾空白。")
    }
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func decode<T: Decodable>(_ data: Data) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw failure("receipt_corrupt", "事务日志无法读取，已停止写入。") }
  }

  private func failure(
    _ code: String, _ message: String, details: [String: AutomationValue] = [:]
  ) -> AutomationError {
    AutomationError(code: code, message: message, details: details)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Walk every path component using directory descriptors, rejecting symlink parents too.
  private static func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
    let components = url.pathComponents.filter { $0 != "/" }
    var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw ioError("打开目录根") }
    for component in components {
      guard component != "..", component != ".", !component.utf8.contains(0) else {
        close(directory)
        throw AutomationError(code: "unsafe_path", message: "配置目录包含不安全路径。")
      }
      if create, mkdirat(directory, component, mode_t(0o700)) != 0, errno != EEXIST {
        let error = ioError("创建配置目录")
        close(directory)
        throw error
      }
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if next < 0 {
        let savedError = errno
        close(directory)
        if !create, savedError == ENOENT { return nil }
        throw ioError("打开配置目录", errorNumber: savedError)
      }
      close(directory)
      directory = next
    }
    return directory
  }

  private static func validatePrivateDirectory(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw ioError("检查事务目录") }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0 else {
      throw AutomationError(code: "unsafe_path", message: "事务目录必须属于当前用户且仅本人可访问。")
    }
  }

  private static func validateRegularFile(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw ioError("检查配置文件") }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
      throw AutomationError(code: "unsafe_file", message: "配置必须是当前用户拥有的普通文件，不能是链接或设备。")
    }
  }

  private static func readFile(_ name: String, directory: Int32, limit: Int) throws -> Data? {
    let descriptor = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw ioError("读取配置")
    }
    defer { close(descriptor) }
    try validateRegularFile(descriptor)
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw ioError("检查配置大小") }
    guard info.st_size <= limit else {
      throw AutomationError(code: "configuration_too_large", message: "文件超过允许读取大小。")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, min($0.count, limit + 1 - result.count))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw ioError("读取配置内容")
      }
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else {
        throw AutomationError(code: "configuration_too_large", message: "文件超过允许读取大小。")
      }
    }
  }

  private static func writeNew(_ data: Data, name: String, directory: Int32) throws {
    let descriptor = openat(
      directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw ioError("建立事务文件") }
    defer { close(descriptor) }
    do {
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if count < 0 {
            if errno == EINTR { continue }
            throw ioError("写入事务文件")
          }
          guard count > 0 else { throw ioError("写入事务文件", errorNumber: EIO) }
          offset += count
        }
      }
      guard fsync(descriptor) == 0 else { throw ioError("同步事务文件") }
      guard fsync(directory) == 0 else { throw ioError("同步事务目录") }
    } catch {
      _ = unlinkat(directory, name, 0)
      throw error
    }
  }

  private static func atomicWrite(_ data: Data, name: String, directory: Int32) throws {
    // Check any existing destination without following links, including special files.
    let existing = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if existing >= 0 {
      defer { close(existing) }
      try validateRegularFile(existing)
    } else if errno != ENOENT {
      throw ioError("检查写入目标")
    }
    let temporary = ".transaction-\(UUID().uuidString).tmp"
    try writeNew(data, name: temporary, directory: directory)
    defer { _ = unlinkat(directory, temporary, 0) }
    guard renameat(directory, temporary, directory, name) == 0 else { throw ioError("原子替换配置") }
    guard fsync(directory) == 0 else { throw ioError("同步配置目录") }
  }

  private static func remove(_ name: String, directory: Int32) throws {
    guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw ioError("清理事务日志") }
    guard fsync(directory) == 0 else { throw ioError("同步事务日志目录") }
  }

  private static func ioError(_ action: String, errorNumber: Int32 = errno) -> AutomationError {
    AutomationError(
      code: errorNumber == ELOOP || errorNumber == ENOTDIR ? "unsafe_path" : "storage_io",
      message: "\(action)失败，未绕过文件保护。",
      details: ["errno": .integer(Int64(errorNumber))])
  }
}
