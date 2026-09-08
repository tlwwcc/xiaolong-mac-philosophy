import CryptoKit
import Foundation

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

  var errorDescription: String? {
    switch self {
    case .missingPreparedSnapshot: return "启动器引用备份不存在。"
    case .snapshotTargetMismatch: return "启动器引用备份与当前 App 不匹配。"
    case .referenceChangedAfterUninstall(let label):
      return "\(label) 在卸载后已被修改，未覆盖新设置。"
    case .unsupportedReferenceFormat(let label): return "\(label) 数据格式无法安全识别。"
    }
  }
}

/// Removes only this App's launcher shortcut, learned history and pinned card. Every file is
/// snapshotted first; restoration refuses to overwrite settings changed after uninstall.
final class SafeUninstallLauncherReferenceStore: SafeUninstallReferenceCommitting {
  private let shortcutsURL: URL
  private let historyURL: URL
  private let pinnedURL: URL
  private let snapshotDirectory: URL
  private let fileManager: FileManager
  private var preparedSnapshotIDByTarget: [String: String] = [:]

  init(
    shortcutsURL: URL,
    historyURL: URL,
    pinnedURL: URL,
    snapshotDirectory: URL,
    fileManager: FileManager = .default
  ) throws {
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
        fileSnapshot(label: "快捷键", url: shortcutsURL),
        fileSnapshot(label: "启动历史", url: historyURL),
        fileSnapshot(label: "固定项", url: pinnedURL),
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
    do {
      for (index, file) in snapshot.files.enumerated() {
        try write(transformed[index], to: URL(fileURLWithPath: file.path))
        snapshot.files[index].committedDigest = digest(transformed[index])
      }
      try save(snapshot)
    } catch {
      for file in snapshot.files {
        try? write(file.originalData, to: URL(fileURLWithPath: file.path))
      }
      throw error
    }
  }

  func restoreRemoval(
    for target: SafeUninstallTargetSnapshot,
    expectedSnapshotDigest: String
  ) throws {
    let snapshot = try load(expectedSnapshotDigest)
    try validate(snapshot, target: target)
    for file in snapshot.files {
      guard let committedDigest = file.committedDigest else {
        throw SafeUninstallReferenceStoreError.missingPreparedSnapshot
      }
      let url = URL(fileURLWithPath: file.path)
      let currentData = fileManager.contents(atPath: url.path)
      guard digest(currentData) == committedDigest else {
        throw SafeUninstallReferenceStoreError.referenceChangedAfterUninstall(file.label)
      }
    }
    for file in snapshot.files {
      try write(file.originalData, to: URL(fileURLWithPath: file.path))
    }
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

  private func fileSnapshot(label: String, url: URL) -> SafeUninstallReferenceFileSnapshot {
    SafeUninstallReferenceFileSnapshot(
      label: label,
      path: url.standardizedFileURL.path,
      originalData: fileManager.contents(atPath: url.path),
      committedDigest: nil)
  }

  private func validate(
    _ snapshot: SafeUninstallReferenceSnapshot,
    target: SafeUninstallTargetSnapshot
  ) throws {
    guard snapshot.targetBundleIdentifier == target.bundleIdentifier,
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
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      SafeUninstallReferenceSnapshot.self,
      from: Data(contentsOf: snapshotURL(id)))
  }

  private func write(_ data: Data?, to url: URL) throws {
    if let data {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    } else if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  private func digest(_ data: Data?) -> String {
    guard let data else { return "missing" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
