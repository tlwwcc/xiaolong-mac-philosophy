import Foundation
import MacAutomationCore

/// GUI use cases and CLI requests commit against the application's loaded snapshot.
/// Reading the current disk revision immediately before writing stale memory is forbidden.
@MainActor
final class ShortcutConfigurationService {
  struct MutationContext {
    let requestID: String
    let requestData: Data
    let expectedRevision: String
  }

  private let store: ConfigurationTransactionStore
  private(set) var snapshot: ConfigurationSnapshot?
  private(set) var committedItems: [ShortcutItem]?
  private(set) var lastFailure: Error?
  private var recoverySnapshot: ConfigurationSnapshot?
  private final class RestoreSession {
    let ownerID: UUID
    let original: ConfigurationSnapshot
    let requestID: String
    var attempted = false
    var receipt: ConfigurationCommitReceipt?
    init(ownerID: UUID, original: ConfigurationSnapshot) {
      self.ownerID = ownerID
      self.original = original
      requestID = "restore-\(ownerID.uuidString)"
    }
  }
  private var restoreSession: RestoreSession?
  var isRestoring: Bool { restoreSession != nil }
  var mutationContext: MutationContext?

  init(fileURL: URL) {
    store = ConfigurationTransactionStore(fileURL: fileURL)
  }

  /// Recovery belongs to explicit application loads, never to queries or dry-run.
  func reload() throws -> [ShortcutItem]? {
    try requireOrdinaryWriter()
    snapshot = nil
    committedItems = nil
    recoverySnapshot = nil
    try store.recover()
    let loaded = try store.read()
    lastFailure = nil
    if !loaded.exists {
      snapshot = loaded
      return nil
    }
    let decoded: [ShortcutItem]
    do {
      decoded = try ShortcutConfigurationCodec.decode(loaded.data)
    } catch {
      // A safe, bounded read of malformed JSON is recoverable through an explicit GUI save.
      // The store will preserve these exact bytes and require their original revision.
      recoverySnapshot = loaded
      lastFailure = error
      throw error
    }
    snapshot = loaded
    committedItems = decoded
    return decoded
  }

  var revision: String? { snapshot?.revision }

  func diskRevision() throws -> String {
    try store.read().revision
  }

  func receipt(requestID: String, requestData: Data? = nil) throws
    -> ConfigurationCommitReceipt?
  {
    try store.lookupReceipt(requestID: requestID, requestData: requestData)
  }

  @discardableResult
  func save(_ items: [ShortcutItem]) throws -> ConfigurationCommitReceipt {
    try commit(Self.encode(items))
  }

  private func commit(_ data: Data) throws -> ConfigurationCommitReceipt {
    try requireOrdinaryWriter()
    let context = mutationContext
    mutationContext = nil
    guard let baseline = snapshot ?? (context == nil ? recoverySnapshot : nil) else {
      let error = AutomationError(
        code: "configuration_unavailable",
        message: "配置尚未成功读取，请先恢复配置后再修改。")
      lastFailure = error
      throw error
    }
    do {
      _ = try ShortcutConfigurationCodec.decode(data)
      let result = try store.commit(
        requestID: context?.requestID ?? "gui-\(UUID().uuidString)",
        requestData: context?.requestData ?? Data(ConfigurationTransactionStore.revision(for: data).utf8),
        expectedRevision: context?.expectedRevision ?? baseline.revision,
        replacement: data)
      do {
        let current = try store.read()
        guard current.revision == result.afterRevision || result.replayed else {
          throw AutomationError(code: "revision_conflict", message: "保存后配置又发生了变化。")
        }
        let decoded = current.exists ? try ShortcutConfigurationCodec.decode(current.data) : nil
        self.snapshot = current
        committedItems = decoded
        recoverySnapshot = nil
      } catch {
        self.snapshot = nil
        committedItems = nil
        recoverySnapshot = nil
        throw AutomationError(
          code: "transaction_unknown",
          message: "配置已提交，但无法核实当前内容。已暂停保存，请查原请求回执并重新打开软件。",
          details: ["requestId": .string(result.requestID)])
      }
      lastFailure = nil
      return result
    } catch {
      lastFailure = error
      throw error
    }
  }

  /// The one writer owns restore exclusion as well as ordinary GUI/CLI commits.
  /// The first-launch path may establish a missing baseline; existing unreadable data must
  /// have been explicitly loaded so the original bytes are known before restoration.
  func beginRestoreTransaction(ownerID: UUID) throws -> XLGConfigShortcutTransaction {
    try requireOrdinaryWriter()
    guard mutationContext == nil else {
      throw AutomationError(code: "configuration_busy", message: "已有配置保存正在处理，请稍后恢复。")
    }
    let original: ConfigurationSnapshot
    if let loaded = snapshot ?? recoverySnapshot {
      original = loaded
    } else {
      let absent = try store.read()
      guard !absent.exists else {
        throw AutomationError(code: "configuration_unavailable", message: "请先重新读取当前配置，再恢复默认设置。")
      }
      original = absent
    }
    guard try store.read().revision == original.revision else {
      throw AutomationError(code: "revision_conflict", message: "配置已在外部修改，请重新读取后再恢复。")
    }
    let session = RestoreSession(ownerID: ownerID, original: original)
    restoreSession = session
    return XLGConfigShortcutTransaction(
      fileURL: store.fileURL, originalData: original.exists ? original.data : nil,
      commit: { [weak self] data in
        guard let self else { throw AutomationError(code: "configuration_unavailable", message: "配置服务已关闭。") }
        try self.commitRestore(data, session: session)
      },
      rollback: { [weak self] in
        guard let self else { throw AutomationError(code: "configuration_unavailable", message: "配置服务已关闭。") }
        try self.rollbackRestore(session: session)
      })
  }

  func endRestoreTransaction(ownerID: UUID) {
    guard restoreSession?.ownerID == ownerID else { return }
    restoreSession = nil
  }

  private func requireOrdinaryWriter() throws {
    guard restoreSession == nil else {
      throw AutomationError(code: "configuration_busy", message: "配置正在更新，请完成后再修改。")
    }
  }

  private func requireRestoreOwner(_ session: RestoreSession) throws {
    guard restoreSession === session else {
      throw AutomationError(code: "restore_owner_expired", message: "本次配置操作已结束，未修改配置。")
    }
  }

  private func commitRestore(_ data: Data?, session: RestoreSession) throws {
    try requireRestoreOwner(session)
    guard !session.attempted else {
      throw AutomationError(code: "restore_already_attempted", message: "本次配置操作已提交，未重复执行。")
    }
    if let data { _ = try ShortcutConfigurationCodec.decode(data) }
    session.attempted = true
    do {
      let receipt = try store.commit(
        requestID: session.requestID, requestData: Data("restore:\(data.map(ConfigurationTransactionStore.revision) ?? ConfigurationTransactionStore.missingRevision)".utf8),
        expectedRevision: session.original.revision, replacement: data)
      session.receipt = receipt
      let current = try store.read()
      guard current.revision == receipt.afterRevision else {
        throw AutomationError(code: "revision_conflict", message: "更新后配置又在外部变化，未覆盖新内容。")
      }
      acceptRestoreSnapshot(current)
      lastFailure = nil
    } catch {
      lastFailure = error
      throw error
    }
  }

  private func rollbackRestore(session: RestoreSession) throws {
    try requireRestoreOwner(session)
    guard session.attempted else { return }
    // A failure after replacement can leave a prepared receipt. Resolve evidence first;
    // never guess whether old bytes may be written over a newer configuration.
    try store.recover()
    if session.receipt == nil, try store.read().revision == session.original.revision {
      acceptRestoreSnapshot(session.original)
      return
    }
    let forward = try session.receipt ?? store.lookupReceipt(requestID: session.requestID)
    guard let forward, forward.changed else { return }
    let compensation = try store.commit(
      requestID: "compensate-\(session.ownerID.uuidString)",
      requestData: Data("restore-compensation:\(forward.requestID):\(session.original.revision)".utf8),
      expectedRevision: forward.afterRevision,
      replacement: session.original.exists ? session.original.data : nil)
    let current = try store.read()
    guard current.revision == compensation.afterRevision else {
      throw AutomationError(code: "transaction_unknown", message: "还原后配置再次变化，请保留备份并重新读取。")
    }
    acceptRestoreSnapshot(current)
  }

  private func acceptRestoreSnapshot(_ current: ConfigurationSnapshot) {
    if !current.exists {
      snapshot = current
      committedItems = nil
      recoverySnapshot = nil
    } else if let decoded = try? ShortcutConfigurationCodec.decode(current.data) {
      snapshot = current
      committedItems = decoded
      recoverySnapshot = nil
    } else {
      // Compensation alone can restore malformed preimages. They remain recoverable,
      // never exposed as valid user configuration or accepted by ordinary saves.
      snapshot = nil
      committedItems = nil
      recoverySnapshot = current
    }
  }

  /// Legacy migrations retain their exact-match and undo evidence, but use the shared writer.
  func replace(original: Data, replacement: Data) throws {
    guard snapshot?.revision == ConfigurationTransactionStore.revision(for: original) else {
      throw AutomationError(code: "revision_conflict", message: "迁移前配置已变化，未覆盖。")
    }
    _ = try commit(replacement)
  }

  static func encode(_ items: [ShortcutItem]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(items)
  }
}
