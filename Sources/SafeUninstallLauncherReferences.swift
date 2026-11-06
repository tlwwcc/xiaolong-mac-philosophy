import CryptoKit
import Foundation
import MacAutomationCore

private struct SafeUninstallReferenceFileSnapshot: Codable {
  let label: String
  let path: String
  let originalData: Data?
  var committedDigest: String?
}

private struct SafeUninstallReferenceSnapshot: Codable {
  let id: String
  let targetBundleIdentifier: String
  let targetPath: String
  let createdAt: Date
  var files: [SafeUninstallReferenceFileSnapshot]
}

enum SafeUninstallReferenceStoreError: Error, LocalizedError {
  case missingPreparedSnapshot
  case snapshotTargetMismatch
  case referenceChangedAfterUninstall(String)
  case unsupportedReferenceFormat(String)
  case transactionAlreadyAttempted
  case transactionFailed(original: String, compensationFailures: [String])

  var errorDescription: String? {
    switch self {
    case .missingPreparedSnapshot: return "启动器引用备份不存在。"
    case .snapshotTargetMismatch: return "启动器引用备份与当前 App 不匹配。"
    case .referenceChangedAfterUninstall(let label):
      return "\(label) 在卸载后已被修改，未覆盖新设置。"
    case .unsupportedReferenceFormat(let label): return "\(label) 数据格式无法安全识别。"
    case .transactionAlreadyAttempted: return "本次引用更新已执行，请重新读取后再试。"
    case .transactionFailed(let original, let failures):
      return failures.isEmpty
        ? "引用更新失败，已还原本次已写内容：\(original)"
        : "引用更新失败，部分内容发生变化而未覆盖；请保留引用备份：\(failures.joined(separator: "；"))"
    }
  }
}

/// Removes only this App's launcher shortcut, learned history and pinned card. Every file is
/// snapshotted first; restoration refuses to overwrite settings changed after uninstall.
@MainActor
final class SafeUninstallLauncherReferenceStore: SafeUninstallReferenceCommitting {
  private let shortcutTransaction: XLGConfigShortcutTransaction
  private let shortcutsURL: URL
  private let historyURL: URL
  private let pinnedURL: URL
  private let snapshotDirectory: URL
  private let fileManager: FileManager
  private var preparedSnapshotIDByTarget: [String: String] = [:]
  private var hasAttemptedTransaction = false

  init(
    shortcutsURL: URL,
    shortcutTransaction: XLGConfigShortcutTransaction,
    historyURL: URL,
    pinnedURL: URL,
    snapshotDirectory: URL,
    fileManager: FileManager = .default
  ) throws {
    guard shortcutTransaction.fileURL.standardizedFileURL == shortcutsURL.standardizedFileURL else {
      throw SafeUninstallReferenceStoreError.snapshotTargetMismatch
    }
    self.shortcutTransaction = shortcutTransaction
    self.shortcutsURL = shortcutsURL
    self.historyURL = historyURL
    self.pinnedURL = pinnedURL
    self.snapshotDirectory = snapshotDirectory
    self.fileManager = fileManager
    try fileManager.createDirectory(
      at: snapshotDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: snapshotDirectory.path)
  }

  func snapshotDigest(for target: SafeUninstallTargetSnapshot) throws -> String {
    let id = UUID().uuidString.lowercased()
    let snapshot = SafeUninstallReferenceSnapshot(
      id: id,
      targetBundleIdentifier: target.bundleIdentifier,
      targetPath: target.path,
      createdAt: Date(),
      files: [
        SafeUninstallReferenceFileSnapshot(
          label: "快捷键", path: shortcutsURL.path,
          originalData: shortcutTransaction.originalData, committedDigest: nil),
        try fileSnapshot(label: "启动历史", url: historyURL),
        try fileSnapshot(label: "固定项", url: pinnedURL),
      ])
    try save(snapshot)
    preparedSnapshotIDByTarget[targetKey(target)] = id
    return id
  }

  func commitRemoval(for target: SafeUninstallTargetSnapshot) throws {
    guard let id = preparedSnapshotIDByTarget[targetKey(target)] else {
      throw SafeUninstallReferenceStoreError.missingPreparedSnapshot
    }
    var snapshot = try load(id)
    try validate(snapshot, target: target)
    let transformed = try snapshot.files.map { file in
      try transformedData(for: file, target: target)
    }
    try apply(
      snapshot: snapshot, expected: snapshot.files.map(\.originalData), replacements: transformed
    ) {
      for index in snapshot.files.indices {
        snapshot.files[index].committedDigest = self.digest(transformed[index])
      }
      try self.save(snapshot)
    }
  }

  func restoreRemoval(
    for target: SafeUninstallTargetSnapshot,
    expectedSnapshotDigest: String
  ) throws {
    let snapshot = try load(expectedSnapshotDigest)
    try validate(snapshot, target: target)
    var current: [Data?] = []
    for (index, file) in snapshot.files.enumerated() {
      guard let committedDigest = file.committedDigest else {
        throw SafeUninstallReferenceStoreError.missingPreparedSnapshot
      }
      let data = try currentData(at: index, file: file)
      guard digest(data) == committedDigest else {
        throw SafeUninstallReferenceStoreError.referenceChangedAfterUninstall(file.label)
      }
      current.append(data)
    }
    try apply(
      snapshot: snapshot, expected: current, replacements: snapshot.files.map(\.originalData)
    ) {}
  }

  /// Each participant has its own durable CAS receipt. A partial failure compensates only
  /// attempted writes, against their observed after-revision; unrelated later edits survive.
  private func apply(
    snapshot: SafeUninstallReferenceSnapshot, expected: [Data?], replacements: [Data?],
    finish: () throws -> Void
  ) throws {
    guard !hasAttemptedTransaction else {
      throw SafeUninstallReferenceStoreError.transactionAlreadyAttempted
    }
    for (index, file) in snapshot.files.enumerated() {
      guard digest(try currentData(at: index, file: file)) == digest(expected[index]) else {
        throw SafeUninstallReferenceStoreError.referenceChangedAfterUninstall(file.label)
      }
    }
    let operation = UUID().uuidString
    var attempted: [Int] = []
    var receipts: [Int: ConfigurationCommitReceipt] = [:]
    func requestID(_ index: Int) -> String { "uninstall-reference-\(operation)-\(index)" }
    // The shortcut participant belongs to one attempt. A later invocation must never
    // enter compensation for a receipt produced by an earlier successful invocation.
    hasAttemptedTransaction = true
    do {
      for (index, file) in snapshot.files.enumerated() {
        attempted.append(index)
        if index == 0 {
          try shortcutTransaction.commit(replacements[index])
        } else {
          let store = ConfigurationTransactionStore(fileURL: URL(fileURLWithPath: file.path))
          receipts[index] = try store.commit(
            requestID: requestID(index),
            requestData: Data("\(snapshot.id):\(index):\(digest(replacements[index]))".utf8),
            expectedRevision: digest(expected[index]), replacement: replacements[index])
        }
      }
      try finish()
    } catch {
      let original = error
      var failures: [String] = []
      for index in attempted.reversed() {
        do {
          if index == 0 {
            try shortcutTransaction.rollback()
            continue
          }
          let file = snapshot.files[index]
          let store = ConfigurationTransactionStore(fileURL: URL(fileURLWithPath: file.path))
          try store.recover()
          if receipts[index] == nil, try store.read().revision == digest(expected[index]) {
            continue
          }
          guard
            let receipt = try receipts[index] ?? store.lookupReceipt(requestID: requestID(index)),
            receipt.changed
          else { continue }
          _ = try store.commit(
            requestID: "undo-\(requestID(index))", requestData: Data(snapshot.id.utf8),
            expectedRevision: receipt.afterRevision, replacement: expected[index])
        } catch { failures.append("\(snapshot.files[index].label)：\(error.localizedDescription)") }
      }
      throw SafeUninstallReferenceStoreError.transactionFailed(
        original: original.localizedDescription, compensationFailures: failures)
    }
  }

  private func currentData(at index: Int, file: SafeUninstallReferenceFileSnapshot) throws -> Data?
  {
    if index == 0 { return shortcutTransaction.originalData }
    let current = try ConfigurationTransactionStore(fileURL: URL(fileURLWithPath: file.path)).read()
    return current.exists ? current.data : nil
  }

  private func transformedData(
    for file: SafeUninstallReferenceFileSnapshot,
    target: SafeUninstallTargetSnapshot
  ) throws -> Data? {
    guard let data = file.originalData else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch file.label {
    case "快捷键":
      guard var items = try? JSONDecoder().decode([ShortcutItem].self, from: data) else {
        throw SafeUninstallReferenceStoreError.unsupportedReferenceFormat(file.label)
      }
      items.removeAll {
        $0.action == .openApp && targetMatches($0.target, target: target)
      }
      return try encoder.encode(items)
    case "启动历史":
      guard var history = try? JSONDecoder().decode(LauncherUsageHistory.self, from: data) else {
        throw SafeUninstallReferenceStoreError.unsupportedReferenceFormat(file.label)
      }
      history.records.removeAll {
        bundleOrPathMatches(bundle: $0.bundleIdentifier, path: $0.path, target: target)
      }
      return try encoder.encode(history)
    case "固定项":
      guard var pinned = try? JSONDecoder().decode(LauncherPinnedCollection.self, from: data) else {
        throw SafeUninstallReferenceStoreError.unsupportedReferenceFormat(file.label)
      }
      pinned.items.removeAll {
        bundleOrPathMatches(bundle: $0.bundleIdentifier, path: $0.path, target: target)
      }
      return try encoder.encode(pinned)
    default:
      throw SafeUninstallReferenceStoreError.unsupportedReferenceFormat(file.label)
    }
  }

  private func targetMatches(_ value: String, target: SafeUninstallTargetSnapshot) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased() == "bundle:\(target.bundleIdentifier.lowercased())" {
      return true
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
      == URL(fileURLWithPath: target.path).standardizedFileURL.path
  }

  private func bundleOrPathMatches(
    bundle: String,
    path: String,
    target: SafeUninstallTargetSnapshot
  ) -> Bool {
    (!bundle.isEmpty && bundle.caseInsensitiveCompare(target.bundleIdentifier) == .orderedSame)
      || URL(fileURLWithPath: path).standardizedFileURL.path
        == URL(fileURLWithPath: target.path).standardizedFileURL.path
  }

  private func fileSnapshot(label: String, url: URL) throws -> SafeUninstallReferenceFileSnapshot {
    let snapshot = try ConfigurationTransactionStore(fileURL: url).read()
    return SafeUninstallReferenceFileSnapshot(
      label: label, path: url.path,
      originalData: snapshot.exists ? snapshot.data : nil, committedDigest: nil)
  }

  private func validate(
    _ snapshot: SafeUninstallReferenceSnapshot,
    target: SafeUninstallTargetSnapshot
  ) throws {
    guard snapshot.files.map(\.label) == ["快捷键", "启动历史", "固定项"],
      snapshot.files.map({ URL(fileURLWithPath: $0.path).standardizedFileURL })
        == [shortcutsURL, historyURL, pinnedURL].map(\.standardizedFileURL),
      snapshot.targetBundleIdentifier == target.bundleIdentifier,
      URL(fileURLWithPath: snapshot.targetPath).standardizedFileURL.path
        == URL(fileURLWithPath: target.path).standardizedFileURL.path
    else { throw SafeUninstallReferenceStoreError.snapshotTargetMismatch }
  }

  private func targetKey(_ target: SafeUninstallTargetSnapshot) -> String {
    "\(target.bundleIdentifier.lowercased())|\(target.path.lowercased())"
  }

  private func snapshotURL(_ id: String) -> URL {
    snapshotDirectory.appendingPathComponent("\(id).json")
  }

  private func save(_ snapshot: SafeUninstallReferenceSnapshot) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = snapshotURL(snapshot.id)
    try encoder.encode(snapshot).write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func load(_ id: String) throws -> SafeUninstallReferenceSnapshot {
    guard UUID(uuidString: id) != nil else {
      throw SafeUninstallReferenceStoreError.missingPreparedSnapshot
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      SafeUninstallReferenceSnapshot.self,
      from: Data(contentsOf: snapshotURL(id)))
  }

  private func digest(_ data: Data?) -> String {
    guard let data else { return "missing" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
