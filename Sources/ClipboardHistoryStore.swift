import CryptoKit
import Darwin
import Foundation
import SQLite3
import UniformTypeIdentifiers

enum ClipboardHistoryManagedPermissions {
  static func clearExtendedACL(at url: URL) throws {
    guard let emptyACL = acl_init(0) else {
      throw ClipboardHistoryStoreError.payload("无法初始化受管副本权限。")
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }

    let result = url.path.withCString { path in
      acl_set_file(path, ACL_TYPE_EXTENDED, emptyACL)
    }
    guard result == 0 || errno == ENOTSUP else {
      throw ClipboardHistoryStoreError.payload("无法清除受管副本的扩展权限。")
    }
  }
}

/// A short-lived, isolated copy of one complete file-history group. Pasteboards receive these
/// URLs instead of canonical history payloads, so cleanup can remove the history row immediately
/// without invalidating an in-flight paste operation.
struct ClipboardHistoryReplayLease: Equatable, Sendable {
  let urls: [URL]
  let containerURL: URL
  let byteCount: Int64
}

final class ClipboardHistoryStore {
  fileprivate static let maximumFileTreeNodeCount = 1_024
  fileprivate static let maximumFileTreeDepth = 64
  fileprivate static let maximumManagedFileTreeBytes: Int64 = 50_000_000_000
  fileprivate static let maximumFileTraversalDuration: TimeInterval = 4
  // Every filesystem node consumes at least one quota unit. The independent entry/node caps
  // below provide the inode bound without changing the long-standing byte-quota meaning for
  // ordinary non-empty files.
  fileprivate static let minimumFileNodeChargeBytes: Int64 = 1
  fileprivate static let maximumStoredEntryCount = 1_000
  // A byte quota alone cannot bound an all-empty-file history. Keep startup reconciliation and
  // cleanup deterministic by limiting managed payload nodes independently of entry bytes; the
  // small wrapper directories remain bounded by the separate entry and per-capture item caps.
  fileprivate static let maximumStoredFileNodeCount = 8_192
  private static let sparseFileInspectionFloor: Int64 = 64 * 1_024 * 1_024
  private static let maximumExtendedAttributeNameListBytes = 64 * 1_024
  private static let resourceForkAttributeName = "com.apple.ResourceFork"
  private static let allowedExtendedAttributes: [String: Int] = [
    "com.apple.FinderInfo": 32,
    "com.apple.lastuseddate#PS": 64,
    "com.apple.metadata:_kMDItemUserTags": 64 * 1_024,
    "com.apple.metadata:kMDItemWhereFroms": 64 * 1_024,
    "com.apple.provenance": 64,
    "com.apple.quarantine": 4 * 1_024,
  ]

  private enum FileTraversalLimitError: Error {
    case byteLimit(requiredBytes: Int64, maximumBytes: Int64)
    case deadline
    case depthLimit
    case nodeLimit
  }

  private final class FileTraversalBudget {
    let maximumBytes: Int64
    let maximumNodeCount: Int
    let deadline: TimeInterval
    private(set) var nodeCount = 0
    private(set) var declaredBytes: Int64 = 0
    private(set) var readBytes: Int64 = 0

    init(
      maximumBytes: Int64,
      duration: TimeInterval,
      maximumNodeCount: Int = ClipboardHistoryStore.maximumFileTreeNodeCount
    ) {
      self.maximumBytes = max(0, maximumBytes)
      self.maximumNodeCount = max(1, maximumNodeCount)
      deadline = ProcessInfo.processInfo.systemUptime + max(0.05, duration)
    }

    func checkTime() throws {
      guard ProcessInfo.processInfo.systemUptime <= deadline else {
        throw FileTraversalLimitError.deadline
      }
    }

    func beginNode(depth: Int) throws {
      try checkTime()
      guard depth <= ClipboardHistoryStore.maximumFileTreeDepth else {
        throw FileTraversalLimitError.depthLimit
      }
      let (next, overflow) = nodeCount.addingReportingOverflow(1)
      guard !overflow, next <= maximumNodeCount else {
        throw FileTraversalLimitError.nodeLimit
      }
      nodeCount = next
    }

    func chargeDeclaredBytes(_ count: Int64) throws {
      guard count >= 0 else {
        throw ClipboardHistoryStoreError.payload("文件大小无效，已跳过本次复制。")
      }
      let (next, overflow) = declaredBytes.addingReportingOverflow(count)
      guard !overflow else {
        throw FileTraversalLimitError.byteLimit(
          requiredBytes: Int64.max,
          maximumBytes: maximumBytes)
      }
      guard next <= maximumBytes else {
        throw FileTraversalLimitError.byteLimit(
          requiredBytes: next,
          maximumBytes: maximumBytes)
      }
      declaredBytes = next
      try checkTime()
    }

    func chargeReadBytes(_ count: Int) throws {
      guard count >= 0 else {
        throw ClipboardHistoryStoreError.payload("文件读取长度无效，已跳过本次复制。")
      }
      let (next, overflow) = readBytes.addingReportingOverflow(Int64(count))
      guard !overflow else {
        throw FileTraversalLimitError.byteLimit(
          requiredBytes: Int64.max,
          maximumBytes: maximumBytes)
      }
      guard next <= maximumBytes else {
        throw FileTraversalLimitError.byteLimit(
          requiredBytes: next,
          maximumBytes: maximumBytes)
      }
      readBytes = next
      try checkTime()
    }

    var remainingNodeCount: Int {
      max(0, maximumNodeCount - nodeCount)
    }
  }

  private struct CapturePreflight {
    let fingerprint: String
    let byteCount: Int64
    let nodeCount: Int
  }

  private struct MaterializedCapture {
    let id: String
    let stagingURL: URL
    let fingerprint: String
    let kind: ClipboardHistoryKind
    let textSummary: String
    let source: ClipboardHistorySource
    let capturedAt: Date
    let byteCount: Int64
    let nodeCount: Int
    let payloadRelativePaths: [String]
    let fileNames: [String]
    let richUTI: String?
  }

  private struct NodeDigest {
    let hexadecimal: String
    let byteCount: Int64
    let logicalByteCount: Int64
  }

  private struct NodeCost {
    let logicalByteCount: Int64
    let accountedByteCount: Int64
  }

  private struct ExtendedAttributeDigest {
    let hexadecimal: String?
    let byteCount: Int64
  }

  private struct QuarantinedPayload {
    let id: String
    let byteCount: Int64
    let originalURL: URL
    let quarantineURL: URL
  }

  private struct ReplacementIntent {
    let incomingID: String
    let evictionIDs: [String]
    let maxBytes: Int64
  }

  private let baseDirectory: URL
  private let blobsDirectory: URL
  private let stagingDirectory: URL
  private let databaseURL: URL
  private let fileManager: FileManager
  private let beforePurge: (() throws -> Void)?
  private let beforeInsert: (() throws -> Void)?
  private let afterReplacementIntentCommitted: (() throws -> Void)?
  private let beforeEvictionCommit: (() throws -> Void)?
  private let beforeFullPayloadValidation: (() throws -> Void)?
  private let beforeFileContentHash: (() throws -> Void)?
  private let lock = NSLock()
  private var database: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(
    baseDirectory: URL,
    fileManager: FileManager = .default,
    beforePurge: (() throws -> Void)? = nil,
    beforeInsert: (() throws -> Void)? = nil,
    afterReplacementIntentCommitted: (() throws -> Void)? = nil,
    beforeEvictionCommit: (() throws -> Void)? = nil,
    beforeFullPayloadValidation: (() throws -> Void)? = nil,
    beforeFileContentHash: (() throws -> Void)? = nil
  ) throws {
    self.baseDirectory = baseDirectory.standardizedFileURL
    blobsDirectory = self.baseDirectory.appendingPathComponent("blobs", isDirectory: true)
    stagingDirectory = self.baseDirectory.appendingPathComponent("staging", isDirectory: true)
    databaseURL = self.baseDirectory.appendingPathComponent("history.sqlite3")
    self.fileManager = fileManager
    self.beforePurge = beforePurge
    self.beforeInsert = beforeInsert
    self.afterReplacementIntentCommitted = afterReplacementIntentCommitted
    self.beforeEvictionCommit = beforeEvictionCommit
    self.beforeFullPayloadValidation = beforeFullPayloadValidation
    self.beforeFileContentHash = beforeFileContentHash

    try Self.preparePrivateDirectory(self.baseDirectory, fileManager: fileManager)
    try Self.preparePrivateDirectory(blobsDirectory, fileManager: fileManager)
    try Self.preparePrivateDirectory(stagingDirectory, fileManager: fileManager)

    var openedDatabase: OpaquePointer?
    let openResult = sqlite3_open_v2(
      databaseURL.path,
      &openedDatabase,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK else {
      let message =
        openedDatabase.flatMap(sqlite3_errmsg).map(String.init(cString:))
        ?? "SQLite open failed (\(openResult))"
      sqlite3_close(openedDatabase)
      throw ClipboardHistoryStoreError.database(message)
    }
    database = openedDatabase

    do {
      sqlite3_busy_timeout(database, 2_000)
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA foreign_keys=ON")
      try execute("PRAGMA synchronous=NORMAL")
      try migrate()
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
      try recoverOwnedDirectories()
    } catch {
      sqlite3_close(database)
      database = nil
      throw error
    }
  }

  deinit {
    sqlite3_close(database)
  }

  func capture(
    _ capture: ClipboardHistoryCapture,
    retentionDays: Int,
    maxBytes: Int64
  ) throws -> ClipboardHistoryCaptureResult {
    try validatePolicy(retentionDays: retentionDays, maxBytes: maxBytes)
    let preflight: CapturePreflight
    do {
      preflight = try inspect(capture, byteLimit: maxBytes)
    } catch FileTraversalLimitError.byteLimit(let requiredBytes, let maximumBytes) {
      return .rejectedQuota(requiredBytes: requiredBytes, maxBytes: maximumBytes)
    }

    return try withLock {
      if let existing = try entry(fingerprint: preflight.fingerprint) {
        try updateDuplicate(
          id: existing.id,
          copiedAt: capture.capturedAt,
          source: capture.source)
        _ = try cleanupLocked(
          retentionDays: retentionDays,
          maxBytes: maxBytes,
          now: capture.capturedAt,
          protectedIDs: [existing.id])
        guard let updated = try entry(id: existing.id) else {
          throw ClipboardHistoryStoreError.database("去重记录更新后丢失。")
        }
        return .deduplicated(updated)
      }

      _ = try cleanupLocked(
        retentionDays: retentionDays,
        maxBytes: maxBytes,
        now: capture.capturedAt)

      guard preflight.byteCount <= maxBytes else {
        return .rejectedQuota(
          requiredBytes: preflight.byteCount,
          maxBytes: maxBytes)
      }

      guard
        var evictionEntries = try quotaEvictions(
          incomingBytes: preflight.byteCount,
          incomingNodes: preflight.nodeCount,
          maxBytes: maxBytes)
      else {
        return .rejectedQuota(
          requiredBytes: preflight.byteCount,
          maxBytes: maxBytes)
      }

      try requireAvailableDiskCapacity(for: preflight.byteCount)
      let materialized: MaterializedCapture
      do {
        materialized = try materialize(capture, byteBudget: preflight.byteCount)
      } catch FileTraversalLimitError.byteLimit(let requiredBytes, _) {
        return .rejectedQuota(requiredBytes: requiredBytes, maxBytes: maxBytes)
      }
      var stagingWasMoved = false
      defer {
        if !stagingWasMoved {
          try? fileManager.removeItem(at: materialized.stagingURL)
        }
      }

      guard materialized.byteCount <= maxBytes else {
        return .rejectedQuota(
          requiredBytes: materialized.byteCount,
          maxBytes: maxBytes)
      }

      if materialized.fingerprint != preflight.fingerprint,
        let existing = try entry(fingerprint: materialized.fingerprint)
      {
        try updateDuplicate(
          id: existing.id,
          copiedAt: materialized.capturedAt,
          source: materialized.source)
        _ = try cleanupLocked(
          retentionDays: retentionDays,
          maxBytes: maxBytes,
          now: materialized.capturedAt,
          protectedIDs: [existing.id])
        guard let updated = try entry(id: existing.id) else {
          throw ClipboardHistoryStoreError.database("去重记录更新后丢失。")
        }
        return .deduplicated(updated)
      }

      guard
        let actualEvictions = try quotaEvictions(
          incomingBytes: materialized.byteCount,
          incomingNodes: materialized.nodeCount,
          maxBytes: maxBytes)
      else {
        return .rejectedQuota(
          requiredBytes: materialized.byteCount,
          maxBytes: maxBytes)
      }
      evictionEntries = actualEvictions

      let finalDirectory = blobsDirectory.appendingPathComponent(
        materialized.id,
        isDirectory: true)
      guard !fileManager.fileExists(atPath: finalDirectory.path) else {
        throw ClipboardHistoryStoreError.payload("受管目录标识冲突。")
      }

      do {
        try fileManager.moveItem(at: materialized.stagingURL, to: finalDirectory)
        stagingWasMoved = true
        try transaction {
          try beforeInsert?()
          try insert(materialized)
          if !evictionEntries.isEmpty {
            try insertReplacementIntent(
              incomingID: materialized.id,
              evictionIDs: evictionEntries.map(\.id),
              maxBytes: maxBytes)
          }
        }
      } catch {
        let insertionError = error
        if fileManager.fileExists(atPath: finalDirectory.path) {
          do {
            try fileManager.moveItem(at: finalDirectory, to: materialized.stagingURL)
            let orphan = QuarantinedPayload(
              id: materialized.id,
              byteCount: materialized.byteCount,
              originalURL: finalDirectory,
              quarantineURL: materialized.stagingURL)
            try transaction { try enqueueDeletions([orphan]) }
            drainDeletionQueueLocked()
          } catch let cleanupError {
            throw ClipboardHistoryStoreError.payload(
              "新内容写入失败且暂存清理失败：\(cleanupError.localizedDescription)")
          }
        }
        throw insertionError
      }

      guard let inserted = try entry(id: materialized.id) else {
        throw ClipboardHistoryStoreError.database("新历史记录写入后丢失。")
      }
      guard !evictionEntries.isEmpty else { return .inserted(inserted) }
      try afterReplacementIntentCommitted?()

      let quarantined: [QuarantinedPayload]
      do {
        quarantined = try quarantineManagedPayloads(for: evictionEntries)
      } catch {
        try discardEntriesLocked(
          [inserted],
          attemptsImmediatePurge: true,
          removingReplacementIntentID: inserted.id)
        throw error
      }

      do {
        try purgeQuarantinedPayloads(quarantined)
      } catch {
        do {
          try restoreQuarantinedPayloads(quarantined)
        } catch let restoreError {
          throw ClipboardHistoryStoreError.payload(
            "写入失败且历史回滚失败：\(restoreError.localizedDescription)")
        }
        let corruptedEntries = evictionEntries.filter { !managedPayloadIsComplete($0) }
        if !corruptedEntries.isEmpty {
          try discardEntriesLocked(
            evictionEntries,
            attemptsImmediatePurge: true,
            removingReplacementIntentID: inserted.id)
          return .inserted(inserted)
        }
        try discardEntriesLocked(
          [inserted],
          attemptsImmediatePurge: true,
          removingReplacementIntentID: inserted.id)
        return .rejectedQuota(
          requiredBytes: materialized.byteCount,
          maxBytes: maxBytes)
      }

      do {
        try transaction {
          try beforeEvictionCommit?()
          for entry in evictionEntries {
            try deleteRow(id: entry.id)
          }
          try deleteReplacementIntent(incomingID: inserted.id)
        }
      } catch {
        try resolveReplacementIntentLocked(incomingID: inserted.id)
      }
      return .inserted(inserted)
    }
  }

  func entries() throws -> [ClipboardHistoryEntry] {
    return try withLock {
      try queryEntries(
        """
        SELECT id, fingerprint, kind, text_summary, source_bundle_id, source_app_name,
               created_at, last_copied_at, copy_count, byte_count, is_pinned,
               payload_paths_json, file_names_json, rich_uti
        FROM entries
        ORDER BY last_copied_at DESC, created_at DESC, id DESC
        """
      ) { _ in }
    }
  }

  func statistics() throws -> ClipboardHistoryStats {
    try withLock { try statisticsLocked() }
  }

  /// Reconciles a file-capture worker that was terminated between staging and commit. Traversal
  /// remains bounded by the same node, byte, depth, and deadline gates as normal store recovery.
  func recoverAfterIsolatedCapture() throws {
    try withLock { try recoverOwnedDirectories() }
  }

  @discardableResult
  func cleanup(
    retentionDays: Int,
    maxBytes: Int64,
    now: Date = Date()
  ) throws -> ClipboardHistoryStats {
    try validatePolicy(retentionDays: retentionDays, maxBytes: maxBytes)
    return try withLock {
      try cleanupLocked(retentionDays: retentionDays, maxBytes: maxBytes, now: now)
    }
  }

  @discardableResult
  func setPinned(id: String, isPinned: Bool) throws -> ClipboardHistoryEntry? {
    try withLock {
      try withStatement("UPDATE entries SET is_pinned=? WHERE id=?") { statement in
        sqlite3_bind_int(statement, 1, isPinned ? 1 : 0)
        bind(id, at: 2, in: statement)
        try stepDone(statement)
      }
      return try entry(id: id)
    }
  }

  @discardableResult
  func delete(id: String) throws -> Bool {
    try withLock {
      guard let existing = try entry(id: id) else { return false }
      let quarantined = try quarantineManagedPayloads(for: [existing])
      do {
        try transaction {
          try deleteRow(id: id)
          try enqueueDeletions(quarantined)
        }
      } catch {
        do {
          try restoreQuarantinedPayloads(quarantined)
        } catch let restoreError {
          throw ClipboardHistoryStoreError.payload(
            "删除失败且历史回滚失败：\(restoreError.localizedDescription)")
        }
        throw error
      }
      drainDeletionQueueLocked()
      return true
    }
  }

  func clearAll() throws {
    try withLock {
      let existing = try allEntriesForMaintenance()
      try queueOrphanedBlobDirectories(referencedIDs: Set(existing.map(\.id)))
      let quarantined = try quarantineManagedPayloads(for: existing)
      do {
        try transaction {
          try execute("DELETE FROM entries")
          try enqueueDeletions(quarantined)
        }
      } catch {
        do {
          try restoreQuarantinedPayloads(quarantined)
        } catch let restoreError {
          throw ClipboardHistoryStoreError.payload(
            "清空失败且历史回滚失败：\(restoreError.localizedDescription)")
        }
        throw error
      }
      drainDeletionQueueLocked()
    }
  }

  func absolutePayloadURLs(_ entry: ClipboardHistoryEntry) -> [URL] {
    entry.payloadRelativePaths.compactMap(safePayloadURL(relativePath:))
  }

  func absolutePayloadURLs(for entry: ClipboardHistoryEntry) -> [URL] {
    absolutePayloadURLs(entry)
  }

  func absolutePayloadURL(for entry: ClipboardHistoryEntry, at index: Int) -> URL? {
    guard entry.payloadRelativePaths.indices.contains(index) else { return nil }
    return safePayloadURL(relativePath: entry.payloadRelativePaths[index])
  }

  /// Re-reads and copies the complete file group while holding the store lock. The atomic rename
  /// makes the returned lease all-or-nothing, and its external cache path remains independent from
  /// later history cleanup or deletion.
  func makeReplayLease(
    entryID: String,
    destinationRoot: URL,
    destinationBoundary: URL,
    maxCacheBytes: Int64 = 50_000_000_000
  ) throws -> ClipboardHistoryReplayLease {
    try withLock {
      guard maxCacheBytes >= 0 else {
        throw ClipboardHistoryStoreError.payload("剪贴板回放缓存上限无效。")
      }
      guard let current = try entry(id: entryID), current.kind == .files else {
        throw ClipboardHistoryStoreError.payload("这条文件历史已不存在。")
      }
      guard !current.payloadRelativePaths.isEmpty,
        current.payloadRelativePaths.count == current.fileNames.count
      else {
        throw ClipboardHistoryStoreError.payload("保存的文件组已不完整。")
      }

      let sourceURLs = current.payloadRelativePaths.compactMap(safePayloadURL(relativePath:))
      guard sourceURLs.count == current.payloadRelativePaths.count,
        sourceURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) })
      else {
        throw ClipboardHistoryStoreError.payload("保存的文件组已不完整。")
      }

      let normalizedRoot = try validateTransientDestination(
        root: destinationRoot,
        boundary: destinationBoundary)
      guard !Self.isAncestor(baseDirectory, of: normalizedRoot),
        !Self.isAncestor(normalizedRoot, of: baseDirectory)
      else {
        throw ClipboardHistoryStoreError.payload("剪贴板回放副本不能放在历史真源目录中。")
      }

      var sourceBytes: Int64 = 0
      var sourceLogicalBytes: Int64 = 0
      let sourceBudget = FileTraversalBudget(
        maximumBytes: Self.maximumManagedFileTreeBytes,
        duration: Self.maximumFileTraversalDuration)
      for sourceURL in sourceURLs {
        let cost = try nodeCost(at: sourceURL, budget: sourceBudget, depth: 0)
        sourceBytes = try Self.checkedByteCountSum(
          sourceBytes,
          cost.accountedByteCount)
        sourceLogicalBytes = try Self.checkedByteCountSum(
          sourceLogicalBytes,
          cost.logicalByteCount)
      }
      guard sourceBytes == current.byteCount || sourceLogicalBytes == current.byteCount else {
        throw ClipboardHistoryStoreError.payload("保存的文件组已发生变化，无法安全回放。")
      }
      let existingBytes = try nodeByteCount(at: normalizedRoot)
      let projectedBytes = try Self.checkedByteCountSum(existingBytes, sourceBytes)
      guard projectedBytes <= maxCacheBytes else {
        throw ClipboardHistoryStoreError.payload("剪贴板回放缓存已达 50 GB 上限。")
      }
      try requireAvailableDiskCapacity(at: normalizedRoot, for: sourceBytes)

      let token = UUID().uuidString.lowercased()
      let partialContainer = normalizedRoot.appendingPathComponent(
        "\(token).partial",
        isDirectory: true)
      let readyContainer = normalizedRoot.appendingPathComponent(
        "\(token).ready",
        isDirectory: true)
      try createPrivateTransientDirectory(partialContainer, in: normalizedRoot)

      do {
        for (index, sourceURL) in sourceURLs.enumerated() {
          let itemDirectory = partialContainer.appendingPathComponent(
            String(format: "%04d", index),
            isDirectory: true)
          try Self.preparePrivateDirectory(itemDirectory, fileManager: fileManager)
          let expectedName = current.fileNames[index]
          guard !expectedName.isEmpty, expectedName == sourceURL.lastPathComponent else {
            throw ClipboardHistoryStoreError.payload("保存的文件名与受管副本不一致。")
          }
          try copyNodeUsingCloneWhenAvailable(
            from: sourceURL,
            to: itemDirectory.appendingPathComponent(expectedName))
        }
        try fileManager.moveItem(at: partialContainer, to: readyContainer)
      } catch {
        if fileManager.fileExists(atPath: partialContainer.path) {
          try? removeTransientTree(at: partialContainer, within: normalizedRoot)
        }
        throw error
      }

      let leaseURLs = current.fileNames.indices.map { index in
        readyContainer
          .appendingPathComponent(String(format: "%04d", index), isDirectory: true)
          .appendingPathComponent(current.fileNames[index])
      }
      guard leaseURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
        try? discardReplayLeaseLocked(
          containerURL: readyContainer,
          destinationRoot: normalizedRoot)
        throw ClipboardHistoryStoreError.payload("剪贴板回放副本未能完整提交。")
      }
      return ClipboardHistoryReplayLease(
        urls: leaseURLs,
        containerURL: readyContainer,
        byteCount: sourceBytes)
    }
  }

  func discardReplayLease(
    _ lease: ClipboardHistoryReplayLease,
    destinationRoot: URL,
    destinationBoundary: URL
  ) throws {
    try withLock {
      let normalizedRoot = try validateTransientDestination(
        root: destinationRoot,
        boundary: destinationBoundary)
      guard lease.urls.allSatisfy({ Self.isStrictDescendant($0, of: lease.containerURL) }) else {
        throw ClipboardHistoryStoreError.payload("剪贴板回放副本路径无效。")
      }
      try discardReplayLeaseLocked(
        containerURL: lease.containerURL,
        destinationRoot: normalizedRoot)
    }
  }

  /// Creates one isolated, writable working copy for Quick Look, opening, or Finder reveal.
  /// The entry is re-read while holding the store lock so cleanup cannot move the canonical
  /// payload between validation and copy. The copy is committed with an atomic directory rename.
  func makeTransientCopy(
    entryID: String,
    payloadIndex: Int,
    destinationRoot: URL,
    destinationBoundary: URL,
    maxSessionBytes: Int64 = 50_000_000_000
  ) throws -> ClipboardHistoryWorkingCopy {
    try withLock {
      guard let current = try entry(id: entryID), current.kind == .files else {
        throw ClipboardHistoryStoreError.payload("这条文件历史已不存在。")
      }
      guard current.payloadRelativePaths.indices.contains(payloadIndex),
        current.fileNames.indices.contains(payloadIndex),
        let sourceURL = safePayloadURL(
          relativePath: current.payloadRelativePaths[payloadIndex])
      else {
        throw ClipboardHistoryStoreError.payload("选中的历史文件不可用。")
      }
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw ClipboardHistoryStoreError.payload("选中的历史文件已不存在。")
      }

      let normalizedRoot = try validateTransientDestination(
        root: destinationRoot,
        boundary: destinationBoundary)
      guard !Self.isAncestor(baseDirectory, of: normalizedRoot),
        !Self.isAncestor(normalizedRoot, of: baseDirectory)
      else {
        throw ClipboardHistoryStoreError.payload("工作副本不能放在历史真源目录中。")
      }

      try validateExternalAccessNode(at: sourceURL)

      let sourceBytes = try nodeByteCount(at: sourceURL)
      let existingBytes = try nodeByteCount(at: normalizedRoot)
      let projectedBytes = try Self.checkedByteCountSum(existingBytes, sourceBytes)
      guard projectedBytes <= maxSessionBytes else {
        throw ClipboardHistoryStoreError.payload("本次运行的文件工作副本已达 50 GB 上限。")
      }
      try requireAvailableDiskCapacity(at: normalizedRoot, for: sourceBytes)

      let token = UUID().uuidString.lowercased()
      let partialContainer = normalizedRoot.appendingPathComponent(
        "\(token).partial",
        isDirectory: true)
      let readyContainer = normalizedRoot.appendingPathComponent(
        "\(token).ready",
        isDirectory: true)
      try createPrivateTransientDirectory(partialContainer, in: normalizedRoot)
      let safeName = sourceURL.lastPathComponent.isEmpty ? "文件" : sourceURL.lastPathComponent
      let partialURL = partialContainer.appendingPathComponent(safeName)

      do {
        try copyNodeUsingCloneWhenAvailable(from: sourceURL, to: partialURL)
        try makeTransientTreeWritable(at: partialContainer)
        try fileManager.moveItem(at: partialContainer, to: readyContainer)
      } catch {
        try? removeTransientTree(at: partialContainer, within: normalizedRoot)
        throw error
      }

      return ClipboardHistoryWorkingCopy(
        url: readyContainer.appendingPathComponent(safeName),
        containerURL: readyContainer)
    }
  }

  private func inspect(
    _ capture: ClipboardHistoryCapture,
    byteLimit: Int64
  ) throws -> CapturePreflight {
    if !capture.files.isEmpty {
      guard capture.files.count <= 128 else {
        throw ClipboardHistoryStoreError.payload("一次复制的文件数量超过安全上限。")
      }
      let budget = FileTraversalBudget(
        maximumBytes: byteLimit,
        duration: Self.maximumFileTraversalDuration)
      var signatures: [Data] = []
      var byteCount: Int64 = 0
      for rawSourceURL in capture.files {
        let sourceURL = rawSourceURL.standardizedFileURL
        try requireLocalFileSystem(at: sourceURL)
        guard fileManager.fileExists(atPath: sourceURL.path),
          !Self.isAncestor(sourceURL, of: stagingDirectory)
        else {
          throw ClipboardHistoryStoreError.unreadableFile(sourceURL.path)
        }
        let digest = try digestNode(at: sourceURL, budget: budget, depth: 0)
        byteCount = try Self.checkedByteCountSum(byteCount, digest.byteCount)
        let originalName = sourceURL.lastPathComponent.isEmpty ? "文件" : sourceURL.lastPathComponent
        signatures.append(
          Self.framedData([
            Data(originalName.utf8),
            Data(digest.hexadecimal.utf8),
          ]))
      }
      let sortedSignatures = signatures.sorted { $0.lexicographicallyPrecedes($1) }
      return CapturePreflight(
        fingerprint: Self.fingerprint(kind: .files, components: sortedSignatures),
        byteCount: byteCount,
        nodeCount: budget.nodeCount)
    }

    if let imageData = capture.imagePNGData, !imageData.isEmpty {
      return CapturePreflight(
        fingerprint: Self.fingerprint(kind: .image, components: [imageData]),
        byteCount: Int64(imageData.count),
        nodeCount: 1)
    }

    if capture.text != nil || capture.richData?.isEmpty == false {
      let plainData = Data((capture.text ?? "").utf8)
      guard !plainData.isEmpty || capture.richData?.isEmpty == false else {
        throw ClipboardHistoryStoreError.emptyCapture
      }
      let richData = capture.richData ?? Data()
      let byteCount = try Self.checkedByteCountSum(
        capture.text == nil ? 0 : Int64(plainData.count),
        Int64(richData.count))
      let fingerprintComponents = capture.text != nil ? [plainData] : [richData]
      let kind: ClipboardHistoryKind = Self.isLikelyLink(capture.text ?? "") ? .link : .text
      return CapturePreflight(
        fingerprint: Self.fingerprint(kind: kind, components: fingerprintComponents),
        byteCount: byteCount,
        nodeCount: (capture.text == nil ? 0 : 1) + (richData.isEmpty ? 0 : 1))
    }

    throw ClipboardHistoryStoreError.emptyCapture
  }

  private func requireAvailableDiskCapacity(for incomingBytes: Int64) throws {
    guard incomingBytes > 0 else { return }
    let available = Self.availableDiskCapacity(at: baseDirectory)
    if let available, available < incomingBytes {
      throw ClipboardHistoryStoreError.payload("磁盘剩余空间不足，未保存本次复制内容。")
    }
  }

  private func requireAvailableDiskCapacity(at directory: URL, for incomingBytes: Int64) throws {
    guard incomingBytes > 0 else { return }
    let available = Self.availableDiskCapacity(at: directory)
    if let available, available < incomingBytes {
      throw ClipboardHistoryStoreError.payload("磁盘剩余空间不足，未创建文件工作副本。")
    }
  }

  /// Reads immediately available blocks from the destination volume without asking CacheDelete to
  /// calculate purgeable capacity. The latter can synchronously scan every mounted volume for tens
  /// of seconds, which would make a small Quick Look working copy appear to hang.
  private static func availableDiskCapacity(at directory: URL) -> Int64? {
    var statistics = statfs()
    let result = directory.path.withCString { path in
      statfs(path, &statistics)
    }
    guard result == 0 else { return nil }

    let blocks = UInt64(statistics.f_bavail)
    let blockSize = UInt64(statistics.f_bsize)
    let (bytes, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
    if overflow || bytes > UInt64(Int64.max) {
      return Int64.max
    }
    return Int64(bytes)
  }

  private func materialize(
    _ capture: ClipboardHistoryCapture,
    byteBudget: Int64
  ) throws -> MaterializedCapture {
    let id = UUID().uuidString.lowercased()
    let stagingURL = stagingDirectory.appendingPathComponent(id, isDirectory: true)
    try Self.preparePrivateDirectory(stagingURL, fileManager: fileManager)

    do {
      if !capture.files.isEmpty {
        return try materializeFiles(
          capture,
          id: id,
          stagingURL: stagingURL,
          byteBudget: byteBudget)
      }
      if let imageData = capture.imagePNGData, !imageData.isEmpty {
        return try materializeImage(capture, imageData: imageData, id: id, stagingURL: stagingURL)
      }
      if capture.text != nil || capture.richData?.isEmpty == false {
        return try materializeText(capture, id: id, stagingURL: stagingURL)
      }
      throw ClipboardHistoryStoreError.emptyCapture
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  private func materializeText(
    _ capture: ClipboardHistoryCapture,
    id: String,
    stagingURL: URL
  ) throws -> MaterializedCapture {
    let text = capture.text ?? ""
    let plainData = Data(text.utf8)
    guard !plainData.isEmpty || capture.richData?.isEmpty == false else {
      throw ClipboardHistoryStoreError.emptyCapture
    }

    var payloadRelativePaths: [String] = []
    var byteCount = Int64(plainData.count)
    if capture.text != nil {
      let plainURL = stagingURL.appendingPathComponent("plain.txt")
      try writePrivate(plainData, to: plainURL)
      payloadRelativePaths.append(relativePayloadPath(id: id, suffix: "plain.txt"))
    }

    let normalizedRichUTI = capture.richUTI?.isEmpty == false ? capture.richUTI : nil
    if let richData = capture.richData, !richData.isEmpty {
      let richURL = stagingURL.appendingPathComponent("rich.data")
      try writePrivate(richData, to: richURL)
      payloadRelativePaths.append(relativePayloadPath(id: id, suffix: "rich.data"))
      byteCount += Int64(richData.count)
    }

    // Pasteboards commonly expose the same human-readable text in several rich formats.
    // When plain text exists, its exact UTF-8 bytes are the canonical identity so a
    // formatting/source change does not create another history row. Pure rich captures
    // fall back to their original bytes because no plain representation exists.
    let fingerprintComponents =
      capture.text != nil
      ? [plainData]
      : [capture.richData ?? Data()]

    let kind: ClipboardHistoryKind = Self.isLikelyLink(text) ? .link : .text
    return MaterializedCapture(
      id: id,
      stagingURL: stagingURL,
      fingerprint: Self.fingerprint(kind: kind, components: fingerprintComponents),
      kind: kind,
      textSummary: Self.textSummary(text, fallback: "富文本"),
      source: capture.source,
      capturedAt: capture.capturedAt,
      byteCount: byteCount,
      nodeCount: payloadRelativePaths.count,
      payloadRelativePaths: payloadRelativePaths,
      fileNames: [],
      richUTI: normalizedRichUTI)
  }

  private func materializeImage(
    _ capture: ClipboardHistoryCapture,
    imageData: Data,
    id: String,
    stagingURL: URL
  ) throws -> MaterializedCapture {
    let imageURL = stagingURL.appendingPathComponent("image.png")
    try writePrivate(imageData, to: imageURL)
    return MaterializedCapture(
      id: id,
      stagingURL: stagingURL,
      fingerprint: Self.fingerprint(kind: .image, components: [imageData]),
      kind: .image,
      textSummary: "图片",
      source: capture.source,
      capturedAt: capture.capturedAt,
      byteCount: Int64(imageData.count),
      nodeCount: 1,
      payloadRelativePaths: [relativePayloadPath(id: id, suffix: "image.png")],
      fileNames: [],
      richUTI: nil)
  }

  private func materializeFiles(
    _ capture: ClipboardHistoryCapture,
    id: String,
    stagingURL: URL,
    byteBudget: Int64
  ) throws -> MaterializedCapture {
    let filesRoot = stagingURL.appendingPathComponent("files", isDirectory: true)
    try Self.preparePrivateDirectory(filesRoot, fileManager: fileManager)
    var payloadRelativePaths: [String] = []
    var fileNames: [String] = []
    var signatures: [Data] = []
    var byteCount: Int64 = 0
    let sourceBudget = FileTraversalBudget(
      maximumBytes: byteBudget,
      duration: Self.maximumFileTraversalDuration)
    let destinationBudget = FileTraversalBudget(
      maximumBytes: byteBudget,
      duration: Self.maximumFileTraversalDuration)

    for (index, rawSourceURL) in capture.files.enumerated() {
      let sourceURL = rawSourceURL.standardizedFileURL
      try requireLocalFileSystem(at: sourceURL)
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw ClipboardHistoryStoreError.unreadableFile(sourceURL.path)
      }
      guard !Self.isAncestor(sourceURL, of: stagingURL) else {
        throw ClipboardHistoryStoreError.unreadableFile(sourceURL.path)
      }

      let sourceDigest = try digestNode(at: sourceURL, budget: sourceBudget, depth: 0)
      let projectedByteCount = try Self.checkedByteCountSum(byteCount, sourceDigest.byteCount)
      guard projectedByteCount <= byteBudget else {
        throw ClipboardHistoryStoreError.payload("复制的文件在保存过程中发生变化，请重试。")
      }

      let itemDirectoryName = String(format: "%04d", index)
      let itemDirectory = filesRoot.appendingPathComponent(itemDirectoryName, isDirectory: true)
      try Self.preparePrivateDirectory(itemDirectory, fileManager: fileManager)
      let originalName = sourceURL.lastPathComponent.isEmpty ? "文件" : sourceURL.lastPathComponent
      let destinationURL = itemDirectory.appendingPathComponent(originalName)
      do {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
      } catch {
        throw ClipboardHistoryStoreError.unreadableFile(sourceURL.path)
      }

      let digest = try digestNode(at: destinationURL, budget: destinationBudget, depth: 0)
      byteCount = try Self.checkedByteCountSum(byteCount, digest.byteCount)
      guard byteCount <= byteBudget else {
        throw ClipboardHistoryStoreError.payload("复制的文件在保存过程中发生变化，请重试。")
      }
      fileNames.append(originalName)
      payloadRelativePaths.append(
        relativePayloadPath(
          id: id,
          suffix: "files/\(itemDirectoryName)/\(originalName)"))
      signatures.append(
        Self.framedData([
          Data(originalName.utf8),
          Data(digest.hexadecimal.utf8),
        ]))
    }

    let sortedSignatures = signatures.sorted { $0.lexicographicallyPrecedes($1) }
    let summaryNames = fileNames.prefix(3).joined(separator: "、")
    let more = fileNames.count > 3 ? " 等 \(fileNames.count) 个" : ""
    return MaterializedCapture(
      id: id,
      stagingURL: stagingURL,
      fingerprint: Self.fingerprint(kind: .files, components: sortedSignatures),
      kind: .files,
      textSummary: "\(summaryNames)\(more)",
      source: capture.source,
      capturedAt: capture.capturedAt,
      byteCount: byteCount,
      nodeCount: destinationBudget.nodeCount,
      payloadRelativePaths: payloadRelativePaths,
      fileNames: fileNames,
      richUTI: nil)
  }

  private func digestNode(at url: URL) throws -> NodeDigest {
    let budget = FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration)
    return try digestNode(at: url, budget: budget, depth: 0)
  }

  private func digestNode(
    at url: URL,
    budget: FileTraversalBudget,
    depth: Int
  ) throws -> NodeDigest {
    try budget.beginNode(depth: depth)
    var pathStatus = stat()
    guard url.path.withCString({ lstat($0, &pathStatus) }) == 0 else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    let nodeType = pathStatus.st_mode & S_IFMT
    let extendedAttributes = try digestExtendedAttributes(at: url, budget: budget)

    if nodeType == S_IFLNK {
      let destination: String
      do {
        destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
      } catch {
        throw ClipboardHistoryStoreError.unreadableFile(url.path)
      }
      var after = stat()
      guard url.path.withCString({ lstat($0, &after) }) == 0,
        Self.sameNode(pathStatus, after)
      else {
        throw ClipboardHistoryStoreError.payload(
          "复制的符号链接在读取过程中发生变化，请重试。")
      }
      let data = Data(destination.utf8)
      try budget.chargeDeclaredBytes(Int64(pathStatus.st_size))
      let logicalByteCount = Int64(pathStatus.st_size)
      let copiedByteCount = try Self.checkedByteCountSum(
        logicalByteCount,
        extendedAttributes.byteCount)
      let byteCount = max(copiedByteCount, Self.minimumFileNodeChargeBytes)
      let baseDigest = Self.fingerprint(kindTag: "symlink", components: [data])
      return NodeDigest(
        hexadecimal: Self.digestIncludingExtendedAttributes(
          baseDigest,
          extendedAttributes: extendedAttributes),
        byteCount: byteCount,
        logicalByteCount: logicalByteCount)
    }

    if nodeType == S_IFDIR {
      let children = try boundedChildren(at: url, budget: budget)
      var components: [Data] = []
      var byteCount = max(extendedAttributes.byteCount, Self.minimumFileNodeChargeBytes)
      var logicalByteCount: Int64 = 0
      for child in children {
        let childDigest = try digestNode(at: child, budget: budget, depth: depth + 1)
        byteCount = try Self.checkedByteCountSum(byteCount, childDigest.byteCount)
        logicalByteCount = try Self.checkedByteCountSum(
          logicalByteCount,
          childDigest.logicalByteCount)
        components.append(
          Self.framedData([
            Data(child.lastPathComponent.utf8),
            Data(childDigest.hexadecimal.utf8),
          ]))
      }
      var after = stat()
      guard url.path.withCString({ lstat($0, &after) }) == 0,
        Self.sameNode(pathStatus, after)
      else {
        throw ClipboardHistoryStoreError.payload(
          "复制的文件夹在读取过程中发生变化，请重试。")
      }
      let baseDigest = Self.fingerprint(kindTag: "directory", components: components)
      return NodeDigest(
        hexadecimal: Self.digestIncludingExtendedAttributes(
          baseDigest,
          extendedAttributes: extendedAttributes),
        byteCount: byteCount,
        logicalByteCount: logicalByteCount)
    }

    guard nodeType == S_IFREG else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }

    try beforeFileContentHash?()
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_size >= 0,
      Self.sameNode(pathStatus, before)
    else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    let expectedByteCount = Int64(before.st_size)
    guard !Self.isUnsafeSparseFile(before) else {
      throw ClipboardHistoryStoreError.payload(
        "大型稀疏文件无法在安全时限内完整校验，已跳过本次复制。")
    }
    try budget.chargeDeclaredBytes(expectedByteCount)

    var hasher = SHA256()
    hasher.update(data: Data("clipboard-history-file-v1".utf8))
    var actualByteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if count > 0 {
        try budget.chargeReadBytes(count)
        actualByteCount = try Self.checkedByteCountSum(actualByteCount, Int64(count))
        hasher.update(data: Data(buffer[0..<count]))
      } else if count == 0 {
        break
      } else if errno == EINTR {
        continue
      } else {
        throw ClipboardHistoryStoreError.unreadableFile(url.path)
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_mode == before.st_mode,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
      actualByteCount == expectedByteCount
    else {
      throw ClipboardHistoryStoreError.payload("复制的文件在读取过程中发生变化，请重试。")
    }
    try budget.checkTime()
    let logicalByteCount = expectedByteCount
    let copiedByteCount = try Self.checkedByteCountSum(
      logicalByteCount,
      extendedAttributes.byteCount)
    let baseDigest = Self.hexadecimal(hasher.finalize())
    return NodeDigest(
      hexadecimal: Self.digestIncludingExtendedAttributes(
        baseDigest,
        extendedAttributes: extendedAttributes),
      byteCount: max(copiedByteCount, Self.minimumFileNodeChargeBytes),
      logicalByteCount: logicalByteCount)
  }

  private func boundedChildren(
    at directory: URL,
    budget: FileTraversalBudget
  ) throws -> [URL] {
    var enumerationError: Error?
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsSubdirectoryDescendants],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw ClipboardHistoryStoreError.unreadableFile(directory.path)
    }
    var children: [URL] = []
    while let child = enumerator.nextObject() as? URL {
      try budget.checkTime()
      guard children.count < budget.remainingNodeCount else {
        throw ClipboardHistoryStoreError.payload(
          "文件树节点数量超过安全上限，已跳过本次复制。")
      }
      children.append(child)
    }
    guard enumerationError == nil else {
      throw ClipboardHistoryStoreError.unreadableFile(directory.path)
    }
    return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func digestExtendedAttributes(
    at url: URL,
    budget: FileTraversalBudget
  ) throws -> ExtendedAttributeDigest {
    let names = try extendedAttributeNames(at: url)
    let resourceForkSize = url.path.withCString { path in
      Self.resourceForkAttributeName.withCString { attributeName in
        getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
      }
    }
    if resourceForkSize > 0 {
      throw ClipboardHistoryStoreError.payload(
        "带有非空资源分支的文件无法安全计费，已跳过本次复制。")
    }
    guard resourceForkSize >= 0 || errno == ENOATTR || errno == ENOTSUP else {
      throw ClipboardHistoryStoreError.payload(
        "文件资源分支无法安全检查，已跳过本次复制。")
    }
    var components: [Data] = []
    var byteCount: Int64 = 0
    for name in names {
      let size = url.path.withCString { path in
        name.withCString { attributeName in
          getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        }
      }
      guard size >= 0 else {
        throw ClipboardHistoryStoreError.payload(
          "文件扩展属性在检查过程中发生变化，已跳过本次复制。")
      }
      if name == Self.resourceForkAttributeName {
        guard size == 0 else {
          throw ClipboardHistoryStoreError.payload(
            "带有非空资源分支的文件无法安全计费，已跳过本次复制。")
        }
        continue
      }
      guard let maximumSize = Self.allowedExtendedAttributes[name], size <= maximumSize else {
        throw ClipboardHistoryStoreError.payload(
          "文件包含未获准或过大的扩展属性，已跳过本次复制。")
      }

      try budget.chargeDeclaredBytes(Int64(size))
      var value = Data(count: size)
      let readCount = value.withUnsafeMutableBytes { rawBuffer in
        url.path.withCString { path in
          name.withCString { attributeName in
            getxattr(
              path,
              attributeName,
              rawBuffer.baseAddress,
              rawBuffer.count,
              0,
              XATTR_NOFOLLOW)
          }
        }
      }
      guard readCount == size else {
        throw ClipboardHistoryStoreError.payload(
          "文件扩展属性在读取过程中发生变化，已跳过本次复制。")
      }
      try budget.chargeReadBytes(size)
      byteCount = try Self.checkedByteCountSum(byteCount, Int64(size))
      components.append(Self.framedData([Data(name.utf8), value]))
    }

    guard names == (try extendedAttributeNames(at: url)) else {
      throw ClipboardHistoryStoreError.payload(
        "文件扩展属性集合在读取过程中发生变化，已跳过本次复制。")
    }
    return ExtendedAttributeDigest(
      hexadecimal: components.isEmpty
        ? nil : Self.fingerprint(kindTag: "xattrs-v1", components: components),
      byteCount: byteCount)
  }

  private func extendedAttributeNames(at url: URL) throws -> [String] {
    let requiredSize = url.path.withCString { path in
      listxattr(path, nil, 0, XATTR_NOFOLLOW)
    }
    if requiredSize < 0, errno == ENOTSUP { return [] }
    guard requiredSize >= 0,
      requiredSize <= Self.maximumExtendedAttributeNameListBytes
    else {
      throw ClipboardHistoryStoreError.payload(
        "文件扩展属性名称列表无法安全读取，已跳过本次复制。")
    }
    guard requiredSize > 0 else { return [] }

    var buffer = [CChar](repeating: 0, count: requiredSize)
    let actualSize = buffer.withUnsafeMutableBufferPointer { pointer in
      url.path.withCString { path in
        listxattr(path, pointer.baseAddress, pointer.count, XATTR_NOFOLLOW)
      }
    }
    guard actualSize == requiredSize else {
      throw ClipboardHistoryStoreError.payload(
        "文件扩展属性名称列表在读取过程中发生变化，已跳过本次复制。")
    }
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    guard bytes.last == 0 else {
      throw ClipboardHistoryStoreError.payload("文件扩展属性名称列表格式无效。")
    }
    var names: [String] = []
    var start = 0
    for index in bytes.indices where bytes[index] == 0 {
      guard index > start,
        let name = String(bytes: bytes[start..<index], encoding: .utf8),
        !name.isEmpty
      else {
        throw ClipboardHistoryStoreError.payload("文件扩展属性名称格式无效。")
      }
      names.append(name)
      start = index + 1
    }
    guard start == bytes.count, Set(names).count == names.count else {
      throw ClipboardHistoryStoreError.payload("文件扩展属性名称列表格式无效。")
    }
    return names.sorted()
  }

  private static func digestIncludingExtendedAttributes(
    _ baseDigest: String,
    extendedAttributes: ExtendedAttributeDigest
  ) -> String {
    guard let attributesDigest = extendedAttributes.hexadecimal else { return baseDigest }
    return fingerprint(
      kindTag: "node-with-xattrs-v1",
      components: [Data(baseDigest.utf8), Data(attributesDigest.utf8)])
  }

  private func requireLocalFileSystem(at url: URL) throws {
    var fileSystem = statfs()
    let result = url.path.withCString { path in
      statfs(path, &fileSystem)
    }
    guard result == 0 else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    guard (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0 else {
      throw ClipboardHistoryStoreError.payload(
        "网络文件无法在安全时限内完整校验，已跳过本次复制。")
    }
  }

  private static func isUnsafeSparseFile(_ status: stat) -> Bool {
    let logicalBytes = Int64(status.st_size)
    guard logicalBytes >= sparseFileInspectionFloor,
      (status.st_flags & UInt32(UF_COMPRESSED)) == 0,
      status.st_blocks >= 0
    else { return false }
    let (allocatedBytes, overflow) = Int64(status.st_blocks).multipliedReportingOverflow(by: 512)
    guard !overflow else { return false }
    return allocatedBytes < logicalBytes / 4
  }

  private static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  /// Computes the logical payload size without reading file contents. Startup recovery uses
  /// this structural check so a legitimate multi-gigabyte history does not synchronously hash
  /// the entire private store before the app can open.
  private func nodeByteCount(at url: URL) throws -> Int64 {
    let budget = FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration)
    return try nodeCost(at: url, budget: budget, depth: 0).accountedByteCount
  }

  private func nodeByteCount(
    at url: URL,
    budget: FileTraversalBudget,
    depth: Int
  ) throws -> Int64 {
    try nodeCost(at: url, budget: budget, depth: depth).accountedByteCount
  }

  private func nodeCost(
    at url: URL,
    budget: FileTraversalBudget,
    depth: Int
  ) throws -> NodeCost {
    try budget.beginNode(depth: depth)
    var pathStatus = stat()
    guard url.path.withCString({ lstat($0, &pathStatus) }) == 0 else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    let nodeType = pathStatus.st_mode & S_IFMT
    let extendedAttributes = try digestExtendedAttributes(at: url, budget: budget)

    if nodeType == S_IFLNK {
      let dataBytes = Int64(pathStatus.st_size)
      try budget.chargeDeclaredBytes(dataBytes)
      let logicalByteCount = dataBytes
      let copiedByteCount = try Self.checkedByteCountSum(
        logicalByteCount,
        extendedAttributes.byteCount)
      var after = stat()
      guard url.path.withCString({ lstat($0, &after) }) == 0,
        Self.sameNode(pathStatus, after)
      else {
        throw ClipboardHistoryStoreError.payload(
          "保存的符号链接在检查过程中发生变化。")
      }
      return NodeCost(
        logicalByteCount: logicalByteCount,
        accountedByteCount: max(copiedByteCount, Self.minimumFileNodeChargeBytes))
    }

    if nodeType == S_IFDIR {
      let children = try boundedChildren(at: url, budget: budget)
      var logicalByteCount: Int64 = 0
      var accountedByteCount = max(
        extendedAttributes.byteCount,
        Self.minimumFileNodeChargeBytes)
      for child in children {
        let childCost = try nodeCost(at: child, budget: budget, depth: depth + 1)
        logicalByteCount = try Self.checkedByteCountSum(
          logicalByteCount,
          childCost.logicalByteCount)
        accountedByteCount = try Self.checkedByteCountSum(
          accountedByteCount,
          childCost.accountedByteCount)
      }
      var after = stat()
      guard url.path.withCString({ lstat($0, &after) }) == 0,
        Self.sameNode(pathStatus, after)
      else {
        throw ClipboardHistoryStoreError.payload(
          "保存的文件夹在检查过程中发生变化。")
      }
      return NodeCost(
        logicalByteCount: logicalByteCount,
        accountedByteCount: accountedByteCount)
    }

    guard nodeType == S_IFREG else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    let dataBytes = Int64(pathStatus.st_size)
    try budget.chargeDeclaredBytes(dataBytes)
    let logicalByteCount = dataBytes
    let copiedByteCount = try Self.checkedByteCountSum(
      logicalByteCount,
      extendedAttributes.byteCount)
    var after = stat()
    guard url.path.withCString({ lstat($0, &after) }) == 0,
      Self.sameNode(pathStatus, after)
    else {
      throw ClipboardHistoryStoreError.payload(
        "保存的文件在检查过程中发生变化。")
    }
    return NodeCost(
      logicalByteCount: logicalByteCount,
      accountedByteCount: max(copiedByteCount, Self.minimumFileNodeChargeBytes))
  }

  /// Reconstructs the one-component clipboard fingerprint while streaming from disk. This is
  /// reserved for interrupted capacity replacements where content identity must be proven; it
  /// avoids `Data(contentsOf:)` memory spikes for large text or image payloads.
  private func streamingFingerprint(
    kind: ClipboardHistoryKind,
    at url: URL
  ) throws -> String {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    let expectedByteCount = Int64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
    guard expectedByteCount >= 0 else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }

    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    hasher.update(data: Data("clipboard-history-v1".utf8))
    hasher.update(data: Self.framedData([Data(kind.rawValue.utf8)]))
    var framedLength = UInt64(expectedByteCount).bigEndian
    withUnsafeBytes(of: &framedLength) { hasher.update(data: Data($0)) }

    var readByteCount: Int64 = 0
    do {
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        readByteCount = try Self.checkedByteCountSum(readByteCount, Int64(chunk.count))
        hasher.update(data: chunk)
      }
    } catch {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    guard readByteCount == expectedByteCount else {
      throw ClipboardHistoryStoreError.unreadableFile(url.path)
    }
    return Self.hexadecimal(hasher.finalize())
  }

  private func cleanupLocked(
    retentionDays: Int,
    maxBytes: Int64,
    now: Date,
    protectedIDs: Set<String> = []
  ) throws -> ClipboardHistoryStats {
    drainDeletionQueueLocked()
    let pendingDeletionBytes = try pendingDeletionByteCountLocked()
    let allEntries = try allEntriesForMaintenance()
    let storedNodeCounts = try storedNodeCountsLocked()
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
    var deletionIDs = Set(
      allEntries.filter {
        !$0.isPinned && !protectedIDs.contains($0.id) && $0.lastCopiedAt < cutoff
      }.map(\.id))

    var remainingBytes = try allEntries.reduce(pendingDeletionBytes) { partial, entry in
      deletionIDs.contains(entry.id)
        ? partial : try Self.checkedByteCountSum(partial, entry.byteCount)
    }
    var remainingEntryCount = allEntries.count - deletionIDs.count
    var remainingNodeCount = try allEntries.reduce(0) { partial, entry in
      guard !deletionIDs.contains(entry.id) else { return partial }
      return try Self.checkedNodeCountSum(partial, storedNodeCounts[entry.id] ?? 1)
    }
    if (
      remainingBytes > maxBytes
        || remainingEntryCount > Self.maximumStoredEntryCount
        || remainingNodeCount > Self.maximumStoredFileNodeCount
    ),
      pendingDeletionBytes == 0
    {
      let quotaCandidates =
        allEntries
        .filter {
          !$0.isPinned && !protectedIDs.contains($0.id) && !deletionIDs.contains($0.id)
        }
        .sorted {
          if $0.lastCopiedAt == $1.lastCopiedAt { return $0.createdAt < $1.createdAt }
          return $0.lastCopiedAt < $1.lastCopiedAt
        }
      for entry in quotaCandidates
      where remainingBytes > maxBytes
        || remainingEntryCount > Self.maximumStoredEntryCount
        || remainingNodeCount > Self.maximumStoredFileNodeCount
      {
        deletionIDs.insert(entry.id)
        remainingBytes -= entry.byteCount
        remainingEntryCount -= 1
        remainingNodeCount -= storedNodeCounts[entry.id] ?? 1
      }
    }

    let deletedEntries = allEntries.filter { deletionIDs.contains($0.id) }
    if !deletedEntries.isEmpty {
      let quarantined = try quarantineManagedPayloads(for: deletedEntries)
      do {
        try transaction {
          for entry in deletedEntries {
            try deleteRow(id: entry.id)
          }
          try enqueueDeletions(quarantined)
        }
      } catch {
        do {
          try restoreQuarantinedPayloads(quarantined)
        } catch let restoreError {
          throw ClipboardHistoryStoreError.payload(
            "清理失败且历史回滚失败：\(restoreError.localizedDescription)")
        }
        throw error
      }
      drainDeletionQueueLocked()
    }
    return try statisticsLocked()
  }

  /// Returns nil when even evicting every unpinned entry cannot fit the incoming payload.
  private func quotaEvictions(
    incomingBytes: Int64,
    incomingNodes: Int,
    maxBytes: Int64
  ) throws -> [ClipboardHistoryEntry]? {
    guard incomingNodes > 0, incomingNodes <= Self.maximumStoredFileNodeCount else {
      throw ClipboardHistoryStoreError.payload(
        "本次文件节点数量超过剪贴板历史的全局安全上限。")
    }
    drainDeletionQueueLocked()
    let pendingDeletionBytes = try pendingDeletionByteCountLocked()
    guard pendingDeletionBytes == 0 else { return nil }
    let allEntries = try allEntriesForMaintenance()
    let initialBytes = try Self.checkedByteCountSum(incomingBytes, pendingDeletionBytes)
    var projectedBytes = try allEntries.reduce(initialBytes) { partial, entry in
      try Self.checkedByteCountSum(partial, entry.byteCount)
    }
    var projectedEntryCount = allEntries.count + 1
    let storedNodeCounts = try storedNodeCountsLocked()
    var projectedNodeCount = try storedNodeCounts.values.reduce(incomingNodes) { partial, count in
      try Self.checkedNodeCountSum(partial, count)
    }
    guard projectedBytes > maxBytes
      || projectedEntryCount > Self.maximumStoredEntryCount
      || projectedNodeCount > Self.maximumStoredFileNodeCount
    else {
      return []
    }

    let candidates = allEntries.filter { !$0.isPinned }.sorted {
      if $0.lastCopiedAt == $1.lastCopiedAt { return $0.createdAt < $1.createdAt }
      return $0.lastCopiedAt < $1.lastCopiedAt
    }
    var evictions: [ClipboardHistoryEntry] = []
    for candidate in candidates
    where projectedBytes > maxBytes
      || projectedEntryCount > Self.maximumStoredEntryCount
      || projectedNodeCount > Self.maximumStoredFileNodeCount
    {
      evictions.append(candidate)
      projectedBytes -= candidate.byteCount
      projectedEntryCount -= 1
      projectedNodeCount -= storedNodeCounts[candidate.id] ?? 1
    }
    guard projectedNodeCount <= Self.maximumStoredFileNodeCount else {
      throw ClipboardHistoryStoreError.payload(
        "置顶内容占用的文件节点已达剪贴板历史安全上限。")
    }
    return projectedBytes <= maxBytes && projectedEntryCount <= Self.maximumStoredEntryCount
      ? evictions
      : nil
  }

  private func insert(_ capture: MaterializedCapture) throws {
    let payloadJSON = try Self.jsonString(capture.payloadRelativePaths)
    let fileNamesJSON = try Self.jsonString(capture.fileNames)
    try withStatement(
      """
      INSERT INTO entries(
        id, fingerprint, kind, text_summary, source_bundle_id, source_app_name,
        created_at, last_copied_at, copy_count, byte_count, is_pinned,
        payload_paths_json, file_names_json, rich_uti
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, ?, ?, ?)
      """
    ) { statement in
      bind(capture.id, at: 1, in: statement)
      bind(capture.fingerprint, at: 2, in: statement)
      bind(capture.kind.rawValue, at: 3, in: statement)
      bind(capture.textSummary, at: 4, in: statement)
      bind(capture.source.bundleIdentifier, at: 5, in: statement)
      bind(capture.source.applicationName, at: 6, in: statement)
      sqlite3_bind_double(statement, 7, capture.capturedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 8, capture.capturedAt.timeIntervalSince1970)
      sqlite3_bind_int64(statement, 9, capture.byteCount)
      bind(payloadJSON, at: 10, in: statement)
      bind(fileNamesJSON, at: 11, in: statement)
      bind(capture.richUTI, at: 12, in: statement)
      try stepDone(statement)
    }
    try withStatement(
      "INSERT INTO entry_node_counts(entry_id, node_count) VALUES(?, ?)"
    ) { statement in
      bind(capture.id, at: 1, in: statement)
      sqlite3_bind_int(statement, 2, Int32(capture.nodeCount))
      try stepDone(statement)
    }
  }

  private func updateDuplicate(
    id: String,
    copiedAt: Date,
    source: ClipboardHistorySource
  ) throws {
    try withStatement(
      """
      UPDATE entries
      SET last_copied_at=MAX(last_copied_at, ?),
          copy_count=copy_count+1,
          source_bundle_id=?,
          source_app_name=?
      WHERE id=?
      """
    ) { statement in
      sqlite3_bind_double(statement, 1, copiedAt.timeIntervalSince1970)
      bind(source.bundleIdentifier, at: 2, in: statement)
      bind(source.applicationName, at: 3, in: statement)
      bind(id, at: 4, in: statement)
      try stepDone(statement)
    }
  }

  private func entry(id: String) throws -> ClipboardHistoryEntry? {
    try singleEntry(whereClause: "id=?") { statement in
      bind(id, at: 1, in: statement)
    }
  }

  private func entry(fingerprint: String) throws -> ClipboardHistoryEntry? {
    try singleEntry(whereClause: "fingerprint=?") { statement in
      bind(fingerprint, at: 1, in: statement)
    }
  }

  private func singleEntry(
    whereClause: String,
    bindValues: (OpaquePointer?) -> Void
  ) throws -> ClipboardHistoryEntry? {
    try queryEntries(
      """
      SELECT id, fingerprint, kind, text_summary, source_bundle_id, source_app_name,
             created_at, last_copied_at, copy_count, byte_count, is_pinned,
             payload_paths_json, file_names_json, rich_uti
      FROM entries WHERE \(whereClause) LIMIT 1
      """,
      bindValues: bindValues
    ).first
  }

  private func allEntriesForMaintenance() throws -> [ClipboardHistoryEntry] {
    try queryEntries(
      """
      SELECT id, fingerprint, kind, text_summary, source_bundle_id, source_app_name,
             created_at, last_copied_at, copy_count, byte_count, is_pinned,
             payload_paths_json, file_names_json, rich_uti
      FROM entries
      ORDER BY last_copied_at ASC, created_at ASC
      """,
      bindValues: { _ in })
  }

  private func storedNodeCountsLocked() throws -> [String: Int] {
    var result: [String: Int] = [:]
    try withStatement(
      "SELECT entry_id, node_count FROM entry_node_counts ORDER BY entry_id ASC"
    ) { statement in
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          let entryID = text(statement, column: 0)
          let rawCount = sqlite3_column_int64(statement, 1)
          guard !entryID.isEmpty,
            rawCount > 0,
            rawCount <= Int64(Self.maximumFileTreeNodeCount)
          else {
            throw ClipboardHistoryStoreError.database("剪贴板历史节点计数无效。")
          }
          result[entryID] = Int(rawCount)
        case SQLITE_DONE:
          return
        default:
          throw ClipboardHistoryStoreError.database(lastError())
        }
      }
    }
    return result
  }

  private func setStoredNodeCountLocked(entryID: String, nodeCount: Int) throws {
    guard nodeCount > 0, nodeCount <= Self.maximumFileTreeNodeCount else {
      throw ClipboardHistoryStoreError.payload("剪贴板历史节点计数超过安全上限。")
    }
    try withStatement(
      """
      INSERT INTO entry_node_counts(entry_id, node_count) VALUES(?, ?)
      ON CONFLICT(entry_id) DO UPDATE SET node_count=excluded.node_count
      """
    ) { statement in
      bind(entryID, at: 1, in: statement)
      sqlite3_bind_int(statement, 2, Int32(nodeCount))
      try stepDone(statement)
    }
  }

  private func queryEntries(
    _ sql: String,
    bindValues: (OpaquePointer?) -> Void
  ) throws -> [ClipboardHistoryEntry] {
    var result: [ClipboardHistoryEntry] = []
    try withStatement(sql) { statement in
      bindValues(statement)
      while true {
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
          guard let kind = ClipboardHistoryKind(rawValue: text(statement, column: 2)) else {
            throw ClipboardHistoryStoreError.database("历史记录类型无效。")
          }
          let payloadPaths = try Self.decodeStringArray(text(statement, column: 11))
          let fileNames = try Self.decodeStringArray(text(statement, column: 12))
          result.append(
            ClipboardHistoryEntry(
              id: text(statement, column: 0),
              fingerprint: text(statement, column: 1),
              kind: kind,
              textSummary: text(statement, column: 3),
              source: ClipboardHistorySource(
                bundleIdentifier: optionalText(statement, column: 4),
                applicationName: optionalText(statement, column: 5)),
              createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
              lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
              copyCount: Int(sqlite3_column_int64(statement, 8)),
              byteCount: sqlite3_column_int64(statement, 9),
              isPinned: sqlite3_column_int(statement, 10) == 1,
              payloadRelativePaths: payloadPaths,
              fileNames: fileNames,
              richUTI: optionalText(statement, column: 13)))
        case SQLITE_DONE:
          return
        default:
          throw ClipboardHistoryStoreError.database(lastError())
        }
      }
    }
    return result
  }

  private func statisticsLocked() throws -> ClipboardHistoryStats {
    var entryCount = 0
    var pinnedCount = 0
    var activeByteCount: Int64 = 0
    var oldestCopiedAt: Date?
    var newestCopiedAt: Date?
    try withStatement(
      """
      SELECT COUNT(*), COALESCE(SUM(is_pinned), 0), COALESCE(SUM(byte_count), 0),
             MIN(last_copied_at), MAX(last_copied_at)
      FROM entries
      """
    ) { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
      entryCount = Int(sqlite3_column_int64(statement, 0))
      pinnedCount = Int(sqlite3_column_int64(statement, 1))
      activeByteCount = sqlite3_column_int64(statement, 2)
      oldestCopiedAt =
        entryCount == 0
        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
      newestCopiedAt =
        entryCount == 0
        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
    }
    let pendingByteCount = try pendingDeletionByteCountLocked()
    let totalByteCount = try Self.checkedByteCountSum(activeByteCount, pendingByteCount)
    return ClipboardHistoryStats(
      entryCount: entryCount,
      pinnedCount: pinnedCount,
      totalByteCount: totalByteCount,
      pendingDeletionByteCount: pendingByteCount,
      oldestCopiedAt: oldestCopiedAt,
      newestCopiedAt: newestCopiedAt)
  }

  private func entryCountLocked() throws -> Int {
    var count = 0
    try withStatement("SELECT COUNT(*) FROM entries") { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
      let rawCount = sqlite3_column_int64(statement, 0)
      guard rawCount >= 0, rawCount <= Int64(Int.max) else {
        throw ClipboardHistoryStoreError.database("剪贴板历史条目数量无效。")
      }
      count = Int(rawCount)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
    }
    return count
  }

  private func deleteRow(id: String) throws {
    try withStatement("DELETE FROM entries WHERE id=?") { statement in
      bind(id, at: 1, in: statement)
      try stepDone(statement)
    }
  }

  private func enqueueDeletions(_ payloads: [QuarantinedPayload]) throws {
    for payload in payloads {
      try withStatement(
        """
        INSERT INTO deletion_queue(id, byte_count, created_at)
        VALUES(?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          byte_count=excluded.byte_count,
          created_at=excluded.created_at
        """
      ) { statement in
        bind(payload.id, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, payload.byteCount)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        try stepDone(statement)
      }
    }
  }

  private func insertReplacementIntent(
    incomingID: String,
    evictionIDs: [String],
    maxBytes: Int64
  ) throws {
    let evictionIDsJSON = try Self.jsonString(evictionIDs)
    try withStatement(
      """
      INSERT INTO replacement_intents(incoming_id, eviction_ids_json, max_bytes, created_at)
      VALUES(?, ?, ?, ?)
      """
    ) { statement in
      bind(incomingID, at: 1, in: statement)
      bind(evictionIDsJSON, at: 2, in: statement)
      sqlite3_bind_int64(statement, 3, maxBytes)
      sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
      try stepDone(statement)
    }
  }

  private func replacementIntentsLocked() throws -> [ReplacementIntent] {
    var intents: [ReplacementIntent] = []
    try withStatement(
      """
      SELECT incoming_id, eviction_ids_json, max_bytes
      FROM replacement_intents
      ORDER BY created_at ASC, incoming_id ASC
      """
    ) { statement in
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          let incomingID = text(statement, column: 0)
          let evictionIDs = try Self.decodeStringArray(text(statement, column: 1))
          guard UUID(uuidString: incomingID) != nil,
            !evictionIDs.isEmpty,
            evictionIDs.allSatisfy({ UUID(uuidString: $0) != nil })
          else {
            throw ClipboardHistoryStoreError.database("容量替换恢复记录无效。")
          }
          intents.append(
            ReplacementIntent(
              incomingID: incomingID,
              evictionIDs: evictionIDs,
              maxBytes: sqlite3_column_int64(statement, 2)))
        case SQLITE_DONE:
          return
        default:
          throw ClipboardHistoryStoreError.database(lastError())
        }
      }
    }
    return intents
  }

  private func deleteReplacementIntent(incomingID: String) throws {
    try withStatement("DELETE FROM replacement_intents WHERE incoming_id=?") { statement in
      bind(incomingID, at: 1, in: statement)
      try stepDone(statement)
    }
  }

  private func resolveReplacementIntentLocked(incomingID: String) throws {
    guard
      let intent = try replacementIntentsLocked().first(where: { $0.incomingID == incomingID })
    else { return }
    guard let incoming = try entry(id: intent.incomingID) else {
      try transaction { try deleteReplacementIntent(incomingID: intent.incomingID) }
      return
    }

    let evictionEntries = try intent.evictionIDs.compactMap { try entry(id: $0) }
    let incomingMustWin =
      evictionEntries.count != intent.evictionIDs.count
      || evictionEntries.contains(where: { !managedPayloadIsComplete($0) })
    if incomingMustWin {
      try discardEntriesLocked(
        evictionEntries,
        attemptsImmediatePurge: true,
        removingReplacementIntentID: intent.incomingID)
      return
    }

    try discardEntriesLocked(
      [incoming],
      attemptsImmediatePurge: true,
      removingReplacementIntentID: intent.incomingID)
    let restoredActiveBytes = try allEntriesForMaintenance().reduce(Int64(0)) {
      try Self.checkedByteCountSum($0, $1.byteCount)
    }
    guard restoredActiveBytes <= intent.maxBytes else {
      throw ClipboardHistoryStoreError.payload("容量替换回滚后仍超过设定空间。")
    }
  }

  private func recoverReplacementIntentsLocked() throws {
    for intent in try replacementIntentsLocked() {
      try resolveReplacementIntentLocked(incomingID: intent.incomingID)
    }
  }

  private func pendingDeletionsLocked() throws -> [QuarantinedPayload] {
    var payloads: [QuarantinedPayload] = []
    try withStatement(
      "SELECT id, byte_count FROM deletion_queue ORDER BY created_at ASC, id ASC"
    ) { statement in
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
          let id = text(statement, column: 0)
          guard UUID(uuidString: id) != nil else {
            throw ClipboardHistoryStoreError.database("待清理历史标识无效。")
          }
          payloads.append(
            QuarantinedPayload(
              id: id,
              byteCount: sqlite3_column_int64(statement, 1),
              originalURL: blobsDirectory.appendingPathComponent(id, isDirectory: true),
              quarantineURL: stagingDirectory.appendingPathComponent(id, isDirectory: true)))
        case SQLITE_DONE:
          return
        default:
          throw ClipboardHistoryStoreError.database(lastError())
        }
      }
    }
    return payloads
  }

  private func pendingDeletionByteCountLocked() throws -> Int64 {
    var value: Int64 = 0
    try withStatement("SELECT COALESCE(SUM(byte_count), 0) FROM deletion_queue") { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
      value = sqlite3_column_int64(statement, 0)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw ClipboardHistoryStoreError.database(lastError())
      }
    }
    return value
  }

  private func removeDeletionQueueRow(id: String) throws {
    try withStatement("DELETE FROM deletion_queue WHERE id=?") { statement in
      bind(id, at: 1, in: statement)
      try stepDone(statement)
    }
  }

  private func drainDeletionQueueLocked() {
    guard let payloads = try? pendingDeletionsLocked() else { return }
    for payload in payloads {
      if fileManager.fileExists(atPath: payload.quarantineURL.path) {
        do {
          try purgeQuarantinedPayloads([payload])
        } catch {
          continue
        }
      }
      try? removeDeletionQueueRow(id: payload.id)
    }
  }

  private func quarantineManagedPayloads(
    for entries: [ClipboardHistoryEntry]
  ) throws -> [QuarantinedPayload] {
    var quarantined: [QuarantinedPayload] = []
    do {
      for entry in entries {
        guard UUID(uuidString: entry.id) != nil else {
          throw ClipboardHistoryStoreError.payload("历史记录标识无效，已停止删除。")
        }
        let originalURL = blobsDirectory.appendingPathComponent(entry.id, isDirectory: true)
          .standardizedFileURL
        guard Self.isStrictDescendant(originalURL, of: blobsDirectory) else {
          throw ClipboardHistoryStoreError.payload("历史副本不在受管目录中，已停止删除。")
        }
        guard fileManager.fileExists(atPath: originalURL.path) else { continue }
        let quarantineURL = stagingDirectory.appendingPathComponent(entry.id, isDirectory: true)
          .standardizedFileURL
        guard Self.isStrictDescendant(quarantineURL, of: stagingDirectory),
          !fileManager.fileExists(atPath: quarantineURL.path)
        else {
          throw ClipboardHistoryStoreError.payload("历史清理暂存目录冲突，请重试。")
        }
        try fileManager.moveItem(at: originalURL, to: quarantineURL)
        quarantined.append(
          QuarantinedPayload(
            id: entry.id,
            byteCount: entry.byteCount,
            originalURL: originalURL,
            quarantineURL: quarantineURL))
      }
      return quarantined
    } catch {
      try? restoreQuarantinedPayloads(quarantined)
      throw ClipboardHistoryStoreError.payload(error.localizedDescription)
    }
  }

  private func restoreQuarantinedPayloads(_ payloads: [QuarantinedPayload]) throws {
    for payload in payloads.reversed() {
      guard fileManager.fileExists(atPath: payload.quarantineURL.path) else { continue }
      guard !fileManager.fileExists(atPath: payload.originalURL.path) else {
        throw ClipboardHistoryStoreError.payload("历史清理回滚遇到目录冲突。")
      }
      try fileManager.moveItem(at: payload.quarantineURL, to: payload.originalURL)
    }
  }

  private func managedPayloadHasExpectedStructure(
    _ entry: ClipboardHistoryEntry,
    sharedBudget: FileTraversalBudget? = nil
  ) -> Bool {
    (try? validateManagedPayloadStructure(entry, sharedBudget: sharedBudget)) == true
  }

  private func validateManagedPayloadStructure(
    _ entry: ClipboardHistoryEntry,
    sharedBudget: FileTraversalBudget? = nil
  ) throws -> Bool {
    let expectedPrefix = "blobs/\(entry.id)/"
    guard !entry.payloadRelativePaths.isEmpty,
      Set(entry.payloadRelativePaths).count == entry.payloadRelativePaths.count,
      entry.payloadRelativePaths.allSatisfy({ $0.hasPrefix(expectedPrefix) })
    else { return false }
    let urls = entry.payloadRelativePaths.compactMap(safePayloadURL(relativePath:))
    guard urls.count == entry.payloadRelativePaths.count else { return false }

    var logicalByteCount: Int64 = 0
    var accountedByteCount: Int64 = 0
    let budget = sharedBudget ?? FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration)
    for url in urls {
      let cost = try nodeCost(at: url, budget: budget, depth: 0)
      logicalByteCount = try Self.checkedByteCountSum(
        logicalByteCount,
        cost.logicalByteCount)
      accountedByteCount = try Self.checkedByteCountSum(
        accountedByteCount,
        cost.accountedByteCount)
    }

    switch entry.kind {
    case .text, .link:
      guard logicalByteCount == entry.byteCount else { return false }
      let allowedPaths = Set([expectedPrefix + "plain.txt", expectedPrefix + "rich.data"])
      return entry.fileNames.isEmpty
        && entry.payloadRelativePaths.count <= allowedPaths.count
        && entry.payloadRelativePaths.allSatisfy(allowedPaths.contains)
        && (entry.payloadRelativePaths.contains(where: { $0.hasSuffix("/plain.txt") })
          || entry.payloadRelativePaths.contains(where: { $0.hasSuffix("/rich.data") }))
    case .image:
      guard logicalByteCount == entry.byteCount else { return false }
      return entry.fileNames.isEmpty
        && entry.payloadRelativePaths == [expectedPrefix + "image.png"]
    case .files:
      guard entry.byteCount == accountedByteCount || entry.byteCount == logicalByteCount else {
        return false
      }
      guard entry.payloadRelativePaths.count == entry.fileNames.count else { return false }
      return zip(entry.payloadRelativePaths.indices, entry.fileNames).allSatisfy { index, name in
        entry.payloadRelativePaths[index]
          == expectedPrefix + "files/\(String(format: "%04d", index))/\(name)"
      }
    }
  }

  private func managedPayloadIsComplete(_ entry: ClipboardHistoryEntry) -> Bool {
    do {
      try beforeFullPayloadValidation?()
      guard managedPayloadHasExpectedStructure(entry) else { return false }
      let urls = entry.payloadRelativePaths.compactMap(safePayloadURL(relativePath:))
      guard urls.count == entry.payloadRelativePaths.count else { return false }

      switch entry.kind {
      case .text, .link:
        let plainIndex = entry.payloadRelativePaths.firstIndex { $0.hasSuffix("/plain.txt") }
        let richIndex = entry.payloadRelativePaths.firstIndex { $0.hasSuffix("/rich.data") }
        guard let identityIndex = plainIndex ?? richIndex else { return false }
        return try streamingFingerprint(kind: entry.kind, at: urls[identityIndex])
          == entry.fingerprint
      case .image:
        guard urls.count == 1 else { return false }
        return try streamingFingerprint(kind: .image, at: urls[0]) == entry.fingerprint
      case .files:
        let budget = FileTraversalBudget(
          maximumBytes: Self.maximumManagedFileTreeBytes,
          duration: Self.maximumFileTraversalDuration)
        let digests = try urls.map { url in
          try digestNode(at: url, budget: budget, depth: 0)
        }
        let signatures = zip(entry.fileNames, digests).map { name, digest in
          Self.framedData([
            Data(name.utf8),
            Data(digest.hexadecimal.utf8),
          ])
        }
        .sorted { $0.lexicographicallyPrecedes($1) }
        return Self.fingerprint(kind: .files, components: signatures) == entry.fingerprint
      }
    } catch {
      return false
    }
  }

  private func discardEntriesLocked(
    _ entries: [ClipboardHistoryEntry],
    attemptsImmediatePurge: Bool,
    removingReplacementIntentID: String? = nil
  ) throws {
    let quarantined = try quarantineManagedPayloads(for: entries)
    do {
      try transaction {
        for entry in entries { try deleteRow(id: entry.id) }
        try enqueueDeletions(quarantined)
        if let removingReplacementIntentID {
          try deleteReplacementIntent(incomingID: removingReplacementIntentID)
        }
      }
    } catch {
      try? restoreQuarantinedPayloads(quarantined)
      throw error
    }

    if attemptsImmediatePurge {
      for payload in quarantined {
        do {
          try purgeQuarantinedPayloads([payload])
          try removeDeletionQueueRow(id: payload.id)
        } catch {
          continue
        }
      }
    }
    drainDeletionQueueLocked()
  }

  private func purgeQuarantinedPayloads(_ payloads: [QuarantinedPayload]) throws {
    for payload in payloads {
      guard fileManager.fileExists(atPath: payload.quarantineURL.path) else { continue }
      do {
        try beforePurge?()
        try makeOwnedTreeWritable(at: payload.quarantineURL)
        try fileManager.removeItem(at: payload.quarantineURL)
      } catch {
        throw ClipboardHistoryStoreError.payload("历史副本删除失败：\(error.localizedDescription)")
      }
    }
  }

  private func validateExternalAccessNode(at url: URL) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw ClipboardHistoryStoreError.payload("无法检查选中的历史文件。")
    }
    let type = attributes[.type] as? FileAttributeType
    if type == .typeSymbolicLink {
      throw ClipboardHistoryStoreError.payload("为了避免跳回历史目录外，暂不打开符号链接。")
    }

    let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    if isAlias {
      throw ClipboardHistoryStoreError.payload("为了避免跳回历史目录外，暂不打开访达别名。")
    }

    let unsafeExtensions: Set<String> = [
      "app", "action", "command", "dmg", "kext", "mobileconfig", "mpkg", "pkg", "prefpane",
      "saver", "terminal", "workflow",
    ]
    if unsafeExtensions.contains(url.pathExtension.lowercased()) {
      throw ClipboardHistoryStoreError.payload("为了避免运行程序或安装包，这类历史项暂不提供打开。")
    }

    if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
      contentType.conforms(to: .application)
        || contentType.conforms(to: .executable)
        || contentType.conforms(to: .unixExecutable)
        || contentType.conforms(to: .applicationBundle)
        || contentType.conforms(to: .pluginBundle)
        || contentType.conforms(to: .diskImage)
    {
      throw ClipboardHistoryStoreError.payload("为了避免运行程序或安装包，这类历史项暂不提供打开。")
    }

    if type == .typeRegular {
      if fileManager.isExecutableFile(atPath: url.path) {
        throw ClipboardHistoryStoreError.payload("为了避免执行历史内容，可执行文件暂不提供打开。")
      }
      return
    }

    guard type == .typeDirectory else {
      throw ClipboardHistoryStoreError.payload("这类历史文件暂不支持打开。")
    }
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [])
    } catch {
      throw ClipboardHistoryStoreError.payload("无法安全检查选中的历史文件夹。")
    }
    for child in children {
      try validateExternalAccessNode(at: child)
    }
  }

  private func copyNodeUsingCloneWhenAvailable(from source: URL, to destination: URL) throws {
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        copyfile(sourcePath, destinationPath, nil, flags)
      }
    }
    guard result != 0 else { return }

    let cloneError = errno
    try? fileManager.removeItem(at: destination)
    do {
      try fileManager.copyItem(at: source, to: destination)
    } catch {
      let cloneMessage = String(cString: strerror(cloneError))
      throw ClipboardHistoryStoreError.payload(
        "无法创建文件工作副本：\(error.localizedDescription)（\(cloneMessage)）")
    }
  }

  private func makeTransientTreeWritable(at root: URL) throws {
    _ = root.path.withCString { lchflags($0, 0) }
    try ClipboardHistoryManagedPermissions.clearExtendedACL(at: root)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [],
      errorHandler: { _, _ in false })
    while let child = enumerator?.nextObject() as? URL {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      _ = child.path.withCString { lchflags($0, 0) }
      if values.isSymbolicLink == true { continue }
      try ClipboardHistoryManagedPermissions.clearExtendedACL(at: child)
      try fileManager.setAttributes(
        [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
        ofItemAtPath: child.path)
    }
  }

  private func validateTransientDestination(root: URL, boundary: URL) throws -> URL {
    let normalizedBoundary = boundary.standardizedFileURL
    let normalizedRoot = root.standardizedFileURL
    guard Self.hasUUIDSuffix(normalizedRoot.lastPathComponent, suffix: ".session"),
      Self.isRealDirectory(normalizedBoundary),
      Self.isRealDirectory(normalizedRoot),
      normalizedRoot.deletingLastPathComponent() == normalizedBoundary,
      normalizedBoundary.resolvingSymlinksInPath().standardizedFileURL == normalizedBoundary,
      normalizedRoot.resolvingSymlinksInPath().standardizedFileURL == normalizedRoot,
      Self.isStrictDescendant(normalizedRoot, of: normalizedBoundary)
    else {
      throw ClipboardHistoryStoreError.payload("工作副本目录边界无效或包含符号链接。")
    }
    return normalizedRoot
  }

  private func createPrivateTransientDirectory(_ url: URL, in parent: URL) throws {
    guard Self.hasUUIDSuffix(url.lastPathComponent, suffix: ".partial"),
      url.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL,
      Self.isRealDirectory(parent)
    else {
      throw ClipboardHistoryStoreError.payload("工作副本暂存路径无效。")
    }
    let result = url.path.withCString { mkdir($0, 0o700) }
    guard result == 0, Self.isRealDirectory(url),
      url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
    else {
      throw ClipboardHistoryStoreError.payload("无法安全创建工作副本暂存目录。")
    }
  }

  private func removeTransientTree(at url: URL, within parent: URL) throws {
    guard Self.hasUUIDSuffix(url.lastPathComponent, suffix: ".partial"),
      url.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL,
      Self.isRealDirectory(parent),
      Self.isRealDirectory(url),
      url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
    else {
      throw ClipboardHistoryStoreError.payload("拒绝清理工作副本边界外的路径。")
    }
    try makeTransientTreeWritable(at: url)
    try fileManager.removeItem(at: url)
  }

  private func discardReplayLeaseLocked(containerURL: URL, destinationRoot: URL) throws {
    let normalizedContainer = containerURL.standardizedFileURL
    guard Self.hasUUIDSuffix(normalizedContainer.lastPathComponent, suffix: ".ready"),
      normalizedContainer.deletingLastPathComponent() == destinationRoot.standardizedFileURL,
      Self.isRealDirectory(destinationRoot),
      destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        == destinationRoot.standardizedFileURL
    else {
      throw ClipboardHistoryStoreError.payload("拒绝清理回放缓存边界外的路径。")
    }
    guard fileManager.fileExists(atPath: normalizedContainer.path) else { return }
    guard Self.isRealDirectory(normalizedContainer),
      normalizedContainer.resolvingSymlinksInPath().standardizedFileURL == normalizedContainer
    else {
      throw ClipboardHistoryStoreError.payload("剪贴板回放缓存目录无效。")
    }
    try makeTransientTreeWritable(at: normalizedContainer)
    try fileManager.removeItem(at: normalizedContainer)
  }

  private func makeOwnedTreeWritable(at root: URL) throws {
    let normalizedRoot = root.standardizedFileURL
    guard Self.isStrictDescendant(normalizedRoot, of: stagingDirectory),
      Self.isRealDirectory(normalizedRoot),
      normalizedRoot.resolvingSymlinksInPath().standardizedFileURL == normalizedRoot
    else {
      throw ClipboardHistoryStoreError.payload("拒绝修改受管目录之外的文件权限。")
    }
    _ = normalizedRoot.path.withCString { lchflags($0, 0) }
    try ClipboardHistoryManagedPermissions.clearExtendedACL(at: normalizedRoot)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: normalizedRoot.path)
    let enumerator = fileManager.enumerator(
      at: normalizedRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [],
      errorHandler: { _, _ in false })
    while let child = enumerator?.nextObject() as? URL {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      _ = child.path.withCString { lchflags($0, 0) }
      if values.isSymbolicLink == true { continue }
      try ClipboardHistoryManagedPermissions.clearExtendedACL(at: child)
      try fileManager.setAttributes(
        [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
        ofItemAtPath: child.path)
    }
  }

  private func safePayloadURL(relativePath: String) -> URL? {
    guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
      return nil
    }
    let url = baseDirectory.appendingPathComponent(relativePath).standardizedFileURL
    guard Self.isStrictDescendant(url, of: blobsDirectory) else { return nil }
    return url
  }

  private func relativePayloadPath(id: String, suffix: String) -> String {
    "blobs/\(id)/\(suffix)"
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw ClipboardHistoryStoreError.payload(error.localizedDescription)
    }
  }

  private func validatePolicy(retentionDays: Int, maxBytes: Int64) throws {
    guard retentionDays >= 0 else {
      throw ClipboardHistoryStoreError.invalidPolicy("保留天数不能小于 0。")
    }
    guard maxBytes >= 0, maxBytes <= Self.maximumManagedFileTreeBytes else {
      throw ClipboardHistoryStoreError.invalidPolicy("存储空间必须在 0 到 50 GB 之间。")
    }
  }

  private func migrate() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS entries(
        id TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        text_summary TEXT NOT NULL,
        source_bundle_id TEXT,
        source_app_name TEXT,
        created_at REAL NOT NULL,
        last_copied_at REAL NOT NULL,
        copy_count INTEGER NOT NULL DEFAULT 1 CHECK(copy_count >= 1),
        byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
        is_pinned INTEGER NOT NULL DEFAULT 0 CHECK(is_pinned IN (0, 1)),
        payload_paths_json TEXT NOT NULL,
        file_names_json TEXT NOT NULL,
        rich_uti TEXT
      )
      """)
    try execute(
      "CREATE INDEX IF NOT EXISTS entries_last_copied_idx ON entries(last_copied_at DESC)")
    try execute(
      "CREATE INDEX IF NOT EXISTS entries_cleanup_idx ON entries(is_pinned, last_copied_at ASC)")
    try execute(
      """
      CREATE TABLE IF NOT EXISTS entry_node_counts(
        entry_id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
        node_count INTEGER NOT NULL CHECK(node_count > 0 AND node_count <= 1024)
      )
      """)
    try execute(
      """
      INSERT OR IGNORE INTO entry_node_counts(entry_id, node_count)
      SELECT id, 1 FROM entries
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS deletion_queue(
        id TEXT PRIMARY KEY,
        byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
        created_at REAL NOT NULL
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS replacement_intents(
        incoming_id TEXT PRIMARY KEY,
        eviction_ids_json TEXT NOT NULL,
        max_bytes INTEGER NOT NULL CHECK(max_bytes >= 0),
        created_at REAL NOT NULL
      )
      """)
    try execute("PRAGMA user_version=4")
  }

  private func recoverOwnedDirectories() throws {
    guard try entryCountLocked() <= Self.maximumStoredEntryCount else {
      throw ClipboardHistoryStoreError.payload(
        "剪贴板历史条目超过全局安全上限，已停止自动恢复。")
    }
    let referencedIDs = Set(try allEntriesForMaintenance().map(\.id))
    let queuedIDs = Set(try pendingDeletionsLocked().map(\.id))
    let stagingBudget = FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration)
    let stagingChildren = try boundedChildren(at: stagingDirectory, budget: stagingBudget)
    for child in stagingChildren where UUID(uuidString: child.lastPathComponent) != nil {
      let id = child.lastPathComponent
      let originalURL = blobsDirectory.appendingPathComponent(id, isDirectory: true)
      if referencedIDs.contains(id) {
        guard !fileManager.fileExists(atPath: originalURL.path) else {
          throw ClipboardHistoryStoreError.payload("历史恢复遇到重复的受管目录。")
        }
        try fileManager.moveItem(at: child, to: originalURL)
      } else if queuedIDs.contains(id) {
        continue
      } else {
        let payload = QuarantinedPayload(
          id: id,
          byteCount: try nodeByteCount(at: child, budget: stagingBudget, depth: 0),
          originalURL: originalURL,
          quarantineURL: child)
        try transaction { try enqueueDeletions([payload]) }
      }
    }
    try recoverReplacementIntentsLocked()
    let managedBudget = FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration,
      maximumNodeCount: Self.maximumStoredFileNodeCount)
    var corruptedReferencedEntries: [ClipboardHistoryEntry] = []
    for entry in try allEntriesForMaintenance() {
      do {
        let nodeCountBefore = managedBudget.nodeCount
        if try !validateManagedPayloadStructure(entry, sharedBudget: managedBudget) {
          corruptedReferencedEntries.append(entry)
        } else {
          try setStoredNodeCountLocked(
            entryID: entry.id,
            nodeCount: managedBudget.nodeCount - nodeCountBefore)
        }
      } catch let limit as FileTraversalLimitError {
        // A shared safety budget is an App-level recovery boundary. Never reinterpret an
        // exhausted budget as corruption and continue deleting rows one by one.
        throw limit
      } catch {
        // Missing payloads and unsafe filesystem metadata are corrupt rows. Quarantine their
        // owned directory through the normal durable deletion path rather than opening them.
        corruptedReferencedEntries.append(entry)
      }
    }
    if !corruptedReferencedEntries.isEmpty {
      try discardEntriesLocked(
        corruptedReferencedEntries,
        attemptsImmediatePurge: false)
    }
    let survivingReferencedIDs = Set(try allEntriesForMaintenance().map(\.id))
    try queueOrphanedBlobDirectories(referencedIDs: survivingReferencedIDs)
    drainDeletionQueueLocked()
  }

  private func queueOrphanedBlobDirectories(referencedIDs: Set<String>) throws {
    let queuedIDs = Set(try pendingDeletionsLocked().map(\.id))
    let blobsBudget = FileTraversalBudget(
      maximumBytes: Self.maximumManagedFileTreeBytes,
      duration: Self.maximumFileTraversalDuration)
    let children = try boundedChildren(at: blobsDirectory, budget: blobsBudget)
    for child in children {
      let id = child.lastPathComponent
      guard UUID(uuidString: id) != nil, !referencedIDs.contains(id) else { continue }
      let quarantineURL = stagingDirectory.appendingPathComponent(id, isDirectory: true)
      guard !fileManager.fileExists(atPath: quarantineURL.path) else {
        throw ClipboardHistoryStoreError.payload("历史恢复暂存目录冲突。")
      }
      let byteCount = try nodeByteCount(at: child, budget: blobsBudget, depth: 0)
      try fileManager.moveItem(at: child, to: quarantineURL)
      if queuedIDs.contains(id) { continue }
      let payload = QuarantinedPayload(
        id: id,
        byteCount: byteCount,
        originalURL: child,
        quarantineURL: quarantineURL)
      do {
        try transaction { try enqueueDeletions([payload]) }
      } catch {
        try? fileManager.moveItem(at: quarantineURL, to: child)
        throw error
      }
    }
  }

  private func execute(_ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
      let message = errorPointer.map { String(cString: $0) } ?? lastError()
      sqlite3_free(errorPointer)
      throw ClipboardHistoryStoreError.database(message)
    }
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func withStatement(
    _ sql: String,
    body: (OpaquePointer?) throws -> Void
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw ClipboardHistoryStoreError.database(lastError())
    }
    defer { sqlite3_finalize(statement) }
    try body(statement)
  }

  private func stepDone(_ statement: OpaquePointer?) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw ClipboardHistoryStoreError.database(lastError())
    }
  }

  private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_text(statement, index, value, -1, transient)
  }

  private func text(_ statement: OpaquePointer?, column: Int32) -> String {
    optionalText(statement, column: column) ?? ""
  }

  private func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, column)
    else {
      return nil
    }
    return String(cString: pointer)
  }

  private func lastError() -> String {
    database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "SQLite error"
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private static func preparePrivateDirectory(
    _ url: URL,
    fileManager: FileManager
  ) throws {
    do {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    } catch {
      throw ClipboardHistoryStoreError.payload(error.localizedDescription)
    }
  }

  private static func jsonString(_ values: [String]) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ClipboardHistoryStoreError.database("无法编码历史路径。")
    }
    return string
  }

  private static func decodeStringArray(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else {
      throw ClipboardHistoryStoreError.database("无法解码历史路径。")
    }
    do {
      return try JSONDecoder().decode([String].self, from: data)
    } catch {
      throw ClipboardHistoryStoreError.database(error.localizedDescription)
    }
  }

  private static func textSummary(_ text: String, fallback: String) -> String {
    let collapsed =
      text
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let value = collapsed.isEmpty ? fallback : collapsed
    return String(value.prefix(240))
  }

  private static func isLikelyLink(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains(where: \Character.isWhitespace),
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased()
    else {
      return false
    }
    return ["http", "https", "ftp", "mailto"].contains(scheme)
  }

  private static func fingerprint(
    kind: ClipboardHistoryKind,
    components: [Data]
  ) -> String {
    fingerprint(kindTag: kind.rawValue, components: components)
  }

  private static func fingerprint(kindTag: String, components: [Data]) -> String {
    var hasher = SHA256()
    hasher.update(data: Data("clipboard-history-v1".utf8))
    hasher.update(data: framedData([Data(kindTag.utf8)]))
    for component in components {
      hasher.update(data: framedData([component]))
    }
    return hexadecimal(hasher.finalize())
  }

  private static func framedData(_ components: [Data]) -> Data {
    var result = Data()
    for component in components {
      var length = UInt64(component.count).bigEndian
      withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
      result.append(component)
    }
    return result
  }

  private static func checkedByteCountSum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow, sum >= 0 else {
      throw ClipboardHistoryStoreError.payload("复制内容过大，无法安全计算存储空间。")
    }
    return sum
  }

  private static func checkedNodeCountSum(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow, sum >= 0 else {
      throw ClipboardHistoryStoreError.payload("文件节点过多，无法安全计算存储上限。")
    }
    return sum
  }

  private static func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func isAncestor(_ ancestor: URL, of descendant: URL) -> Bool {
    let ancestorPath = ancestor.standardizedFileURL.path
    let descendantPath = descendant.standardizedFileURL.path
    return descendantPath == ancestorPath || descendantPath.hasPrefix(ancestorPath + "/")
  }

  private static func isStrictDescendant(_ descendant: URL, of ancestor: URL) -> Bool {
    let ancestorPath = ancestor.standardizedFileURL.path
    let descendantPath = descendant.standardizedFileURL.path
    return descendantPath.hasPrefix(ancestorPath + "/")
  }

  private static func hasUUIDSuffix(_ name: String, suffix: String) -> Bool {
    guard name.hasSuffix(suffix) else { return false }
    let token = String(name.dropLast(suffix.count))
    return token == token.lowercased() && UUID(uuidString: token) != nil
  }

  private static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFDIR
  }
}
