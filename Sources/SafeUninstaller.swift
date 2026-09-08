import AppKit
import Carbon
import Darwin
import Foundation

enum SafeUninstallSourceKind: String, Codable, CaseIterable {
  case ordinaryApplication
  case appStore
  case packageReceipt
  case homebrewCask
  case officialUninstaller
  case helperOrExtension
  case systemApplication
  case externalOrReadOnlyVolume
  case unknown

  var displayName: String {
    switch self {
    case .ordinaryApplication: return "普通 App"
    case .appStore: return "Mac App Store"
    case .packageReceipt: return "安装器安装"
    case .homebrewCask: return "Homebrew"
    case .officialUninstaller: return "带官方卸载器"
    case .helperOrExtension: return "带辅助组件或系统扩展"
    case .systemApplication: return "系统 App"
    case .externalOrReadOnlyVolume: return "外接或只读位置"
    case .unknown: return "来源未确认"
    }
  }

  var supportsPhaseOneRemoval: Bool {
    self == .ordinaryApplication || self == .appStore
  }
}

enum SafeUninstallOwnershipConfidence: String, Codable {
  case confirmed
  case high
  case low
  case sharedOrUnknown

  var displayName: String {
    switch self {
    case .confirmed: return "已确认"
    case .high: return "较高"
    case .low: return "较低"
    case .sharedOrUnknown: return "未知或共享"
    }
  }
}

enum SafeUninstallRiskLevel: String, Codable {
  case low
  case medium
  case high
  case protected

  var displayName: String {
    switch self {
    case .low: return "低风险"
    case .medium: return "需确认"
    case .high: return "高风险"
    case .protected: return "受保护"
    }
  }
}

enum SafeUninstallPermissionState: String, Codable {
  case readable
  case systemAuthorization
  case unreadable
  case unknown
}

enum SafeUninstallSymlinkState: String, Codable {
  case regular
  case symbolicLink
  case alias
  case unknown
}

enum SafeUninstallCandidateType: String, Codable {
  case application
  case cache
  case log
  case savedState
  case preference
  case applicationSupport
  case webData
  case httpStorage
  case cookie
  case crashReport
  case launchAgent
  case container
  case groupContainer
  case helper
  case systemExtension
  case networkExtension
  case userDocument
  case unknown

  var displayName: String {
    switch self {
    case .application: return "主 App"
    case .cache: return "缓存"
    case .log: return "日志"
    case .savedState: return "窗口状态"
    case .preference: return "设置"
    case .applicationSupport: return "应用数据"
    case .webData: return "网页数据"
    case .httpStorage: return "网络缓存"
    case .cookie: return "Cookie"
    case .crashReport: return "崩溃记录"
    case .launchAgent: return "登录项"
    case .container: return "容器"
    case .groupContainer: return "共享容器"
    case .helper: return "辅助组件"
    case .systemExtension: return "系统扩展"
    case .networkExtension: return "网络扩展"
    case .userDocument: return "用户文档"
    case .unknown: return "未分类"
    }
  }
}

enum SafeUninstallRemovalMethod: String, Codable {
  case moveToTrash
  case preserve
  case officialUninstaller
  case homebrew
  case unsupported
}

enum SafeUninstallScanRootState: Codable, Hashable {
  case scanned
  case unreadable(String)

  private enum CodingKeys: String, CodingKey {
    case state
    case message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    if state == "scanned" {
      self = .scanned
    } else {
      self = .unreadable(try container.decode(String.self, forKey: .message))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .scanned:
      try container.encode("scanned", forKey: .state)
    case .unreadable(let message):
      try container.encode("unreadable", forKey: .state)
      try container.encode(message, forKey: .message)
    }
  }
}

struct SafeUninstallFileIdentity: Codable, Hashable {
  let standardizedPath: String
  let fileResourceIdentifier: String
  let volumeIdentifier: String
  let parentFileIdentity: String
  let fileType: String
  let isSymbolicLink: Bool
  let isAliasFile: Bool
  let isLocalVolume: Bool
  let isReadOnlyVolume: Bool
  let isWritable: Bool
  let bundleIdentifier: String
  let teamIdentifier: String
  let designatedRequirementDigest: String

  static func capture(
    at url: URL,
    bundleIdentifier: String = "",
    teamIdentifier: String = "",
    designatedRequirementDigest: String = ""
  ) throws -> SafeUninstallFileIdentity {
    let standardized = url.standardizedFileURL
    let keys: Set<URLResourceKey> = [
      .fileResourceIdentifierKey,
      .volumeIdentifierKey,
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .isAliasFileKey,
      .volumeIsLocalKey,
      .volumeIsReadOnlyKey,
      .isWritableKey,
    ]
    let values = try standardized.resourceValues(forKeys: keys)
    let parentValues = try standardized.deletingLastPathComponent().resourceValues(
      forKeys: [.fileResourceIdentifierKey])
    let type: String
    if values.isSymbolicLink == true {
      type = "symbolic-link"
    } else if values.isDirectory == true {
      type = "directory"
    } else if values.isRegularFile == true {
      type = "regular-file"
    } else {
      type = "other"
    }
    return SafeUninstallFileIdentity(
      standardizedPath: standardized.path,
      fileResourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        ?? "unknown",
      volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) } ?? "unknown",
      parentFileIdentity: parentValues.fileResourceIdentifier.map { String(describing: $0) }
        ?? "unknown",
      fileType: type,
      isSymbolicLink: values.isSymbolicLink ?? false,
      isAliasFile: values.isAliasFile ?? false,
      isLocalVolume: values.volumeIsLocal ?? false,
      isReadOnlyVolume: values.volumeIsReadOnly ?? false,
      isWritable: values.isWritable ?? false,
      bundleIdentifier: bundleIdentifier,
      teamIdentifier: teamIdentifier,
      designatedRequirementDigest: designatedRequirementDigest)
  }
}

struct SafeUninstallTargetSnapshot: Codable, Hashable {
  let name: String
  let bundleIdentifier: String
  let path: String
  let identity: SafeUninstallFileIdentity
  let sourceKind: SafeUninstallSourceKind
  let ownerUID: UInt32
}

struct SafeUninstallCandidate: Codable, Identifiable, Hashable {
  let id: String
  let operationID: String
  let originalURL: String
  let standardizedURL: String
  let expectedIdentity: SafeUninstallFileIdentity
  let type: SafeUninstallCandidateType
  let size: Int64?
  let ownershipConfidence: SafeUninstallOwnershipConfidence
  let ownershipEvidence: String
  let riskLevel: SafeUninstallRiskLevel
  let defaultSelected: Bool
  let selectionReason: String
  let sourceKind: SafeUninstallSourceKind
  let permissionState: SafeUninstallPermissionState
  let symlinkState: SafeUninstallSymlinkState
  let supportedRemovalMethod: SafeUninstallRemovalMethod

  var isExecutable: Bool {
    supportedRemovalMethod == .moveToTrash
      && riskLevel != .protected
      && symlinkState == .regular
      && (permissionState == .readable || permissionState == .systemAuthorization)
  }

  var displayPath: String {
    originalURL.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  var displaySize: String {
    guard let size else { return "大小未知" }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }
}

struct SafeUninstallScanRoot: Codable, Hashable {
  let name: String
  let path: String
  let state: SafeUninstallScanRootState
}

struct SafeUninstallReview: Codable, Hashable {
  let operationID: String
  let target: SafeUninstallTargetSnapshot
  let candidates: [SafeUninstallCandidate]
  let scanRoots: [SafeUninstallScanRoot]
  let reviewRevision: String

  var selectedCandidateIDs: [String] {
    candidates.filter(\.defaultSelected).map(\.id)
  }

  var hasIncompleteScan: Bool {
    scanRoots.contains {
      if case .unreadable = $0.state { return true }
      return false
    }
  }

  var permanentDeletionCandidateIDs: [String] {
    candidates.filter { candidate in
      guard candidate.isExecutable else { return false }
      if candidate.type == .application { return true }
      if candidate.ownershipConfidence == .confirmed
        || candidate.ownershipConfidence == .high
      {
        return true
      }
      return candidate.ownershipConfidence == .low
        && candidate.riskLevel == .low
        && [.cache, .log, .savedState, .crashReport].contains(candidate.type)
    }.map(\.id)
  }
}

enum SafeUninstallTransactionState: String, Codable {
  case prepared
  case executing
  case completed
  case partialFailure
  case manualRecoveryRequired
  case restoreAvailable
  case restored
  case restoreFailed
  case blocked
  case cancelled
}

enum SafeUninstallTransactionItemState: String, Codable {
  case pending
  case moved
  case failed
  case restored
  case restoreFailed
}

struct SafeUninstallTransactionItem: Codable, Hashable {
  let candidateID: String
  let originalURL: String
  let expectedIdentity: SafeUninstallFileIdentity
  var actualTrashURL: String?
  var state: SafeUninstallTransactionItemState
  var errorCode: String?
}

struct SafeUninstallReferenceCompensation: Codable, Hashable {
  let kind: String
  let snapshotDigest: String
  var committed: Bool
  var restored: Bool
}

struct SafeUninstallTransaction: Codable, Hashable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let operationID: String
  let createdAt: Date
  var state: SafeUninstallTransactionState
  let targetSnapshot: SafeUninstallTargetSnapshot
  let selectedCandidateIDs: [String]
  var items: [SafeUninstallTransactionItem]
  var referenceCompensations: [SafeUninstallReferenceCompensation]
  var lastDurableUpdateAt: Date
}

struct SafeUninstallRunningProcess: Codable, Hashable {
  let pid: Int32
  let bundleIdentifier: String
  let bundlePath: String
  let launchTimestamp: TimeInterval
  let ownerUID: UInt32
}

enum SafeUninstallExecutionState: String {
  case completed
  case completedWithWarnings
  case waitingForForceQuitConfirmation
  case partialFailure
  case blocked
  case manualRecoveryRequired
  case restored
  case restoreFailed
  case cancelled
}

struct SafeUninstallExecutionOutcome {
  let state: SafeUninstallExecutionState
  let message: String
  let errorCode: String?
  let movedCount: Int
  let transaction: SafeUninstallTransaction?

  var didMoveTargetApplication: Bool {
    guard let transaction else { return false }
    let targetPath = URL(fileURLWithPath: transaction.targetSnapshot.path).standardizedFileURL.path
    return transaction.items.contains {
      URL(fileURLWithPath: $0.originalURL).standardizedFileURL.path == targetPath
        && $0.state == .moved
    }
  }
}

enum SafeUninstallExecutionProgress {
  case movingToTrash
  case applicationMoved
}

protocol SafeUninstallFileExecuting {
  func currentIdentity(for candidate: SafeUninstallCandidate) async throws
    -> SafeUninstallFileIdentity
  func moveToTrash(_ candidate: SafeUninstallCandidate) async throws -> String
  func originalPathExists(_ path: String) async -> Bool
  func restore(
    trashURL: String,
    originalURL: String,
    expectedIdentity: SafeUninstallFileIdentity
  ) async throws
}

protocol SafeUninstallProcessControlling {
  func runningProcesses(for target: SafeUninstallTargetSnapshot) async
    -> [SafeUninstallRunningProcess]
  func requestTermination(_ process: SafeUninstallRunningProcess) async -> Bool
  func requestForceTermination(_ process: SafeUninstallRunningProcess) async -> Bool
  func waitForExit(_ process: SafeUninstallRunningProcess, timeout: TimeInterval) async -> Bool
}

protocol SafeUninstallTransactionPersisting {
  func save(_ transaction: SafeUninstallTransaction) throws
  func load(operationID: String) throws -> SafeUninstallTransaction?
}

protocol SafeUninstallReferenceCommitting {
  func snapshotDigest(for target: SafeUninstallTargetSnapshot) throws -> String
  func commitRemoval(for target: SafeUninstallTargetSnapshot) throws
  func restoreRemoval(
    for target: SafeUninstallTargetSnapshot,
    expectedSnapshotDigest: String
  ) throws
}

struct SafeUninstallPermanentDeleteFailure: Hashable {
  let candidateID: String
  let message: String
}

struct SafeUninstallPermanentDeleteResult: Hashable {
  let deletedCandidateIDs: Set<String>
  let failures: [SafeUninstallPermanentDeleteFailure]
}

protocol SafeUninstallPermanentFileDeleting {
  func currentIdentity(for candidate: SafeUninstallCandidate) async throws
    -> SafeUninstallFileIdentity
  func deletePermanently(_ candidates: [SafeUninstallCandidate]) async
    -> SafeUninstallPermanentDeleteResult
}

enum SafeUninstallPermanentExecutionState: String {
  case completed
  case completedWithWarnings
  case blocked
  case partialFailure
}

struct SafeUninstallPermanentExecutionOutcome {
  let state: SafeUninstallPermanentExecutionState
  let message: String
  let errorCode: String?
  let deletedCount: Int
  let didDeleteTargetApplication: Bool
}

enum SafeUninstallSharedInfrastructurePolicy {
  static let blockedErrorCode = "PROTECTED_SHARED_AUTOMATION_INFRASTRUCTURE"

  private static let protectedBundleIdentifiers: Set<String> = [
    "com.trycua.driver"
  ]

  static func blockReason(for target: SafeUninstallTargetSnapshot) -> String? {
    let bundleIdentifier = target.bundleIdentifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard protectedBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    return
      "「\(target.name)」属于本机共享自动化基础设施，可能被其他工作流依赖，不能从小龙哥 Mac 哲学中卸载。若你明确不再需要它，请使用该工具的官方卸载方式，或在 Finder 中手动处理。"
  }
}

enum SafeUninstallPermanentExecutionProgress {
  case terminatingApplication
  case deletingPermanently
  case applicationDeleted
}

final class SafeUninstallPermanentEngine {
  private let files: SafeUninstallPermanentFileDeleting
  private let processes: SafeUninstallProcessControlling
  private let references: SafeUninstallReferenceCommitting

  init(
    files: SafeUninstallPermanentFileDeleting,
    processes: SafeUninstallProcessControlling,
    references: SafeUninstallReferenceCommitting
  ) {
    self.files = files
    self.processes = processes
    self.references = references
  }

  func execute(
    review: SafeUninstallReview,
    selectedCandidateIDs: [String],
    expectedReviewRevision: String,
    progress: (@MainActor (SafeUninstallPermanentExecutionProgress) -> Void)? = nil
  ) async -> SafeUninstallPermanentExecutionOutcome {
    if let reason = SafeUninstallSharedInfrastructurePolicy.blockReason(for: review.target) {
      return blocked(
        reason,
        code: SafeUninstallSharedInfrastructurePolicy.blockedErrorCode)
    }
    guard review.reviewRevision == expectedReviewRevision else {
      return blocked("卸载清单已经变化，请重新发起一键卸载。", code: "STALE_REVIEW")
    }
    let selectedSet = Set(selectedCandidateIDs)
    let selected = review.candidates
      .filter { selectedSet.contains($0.id) }
      .sorted { lhs, rhs in
        if lhs.type == .application, rhs.type != .application { return false }
        if rhs.type == .application, lhs.type != .application { return true }
        return lhs.standardizedURL < rhs.standardizedURL
      }
    guard !selected.isEmpty,
      let application = selected.first(where: { $0.type == .application })
    else {
      return blocked("没有可彻底卸载的主 App。", code: "MISSING_APPLICATION")
    }

    do {
      try await revalidate(selected)
      _ = try references.snapshotDigest(for: review.target)
      let running = await processes.runningProcesses(for: review.target)
      for process in running {
        try validate(process: process, target: review.target)
      }
      if !running.isEmpty {
        await progress?(.terminatingApplication)
      }
      for process in running {
        guard await processes.requestForceTermination(process) else {
          throw SafeUninstallEngineError.forceTerminationRequestRejected
        }
      }
      for process in running {
        var exited = await processes.waitForExit(process, timeout: 6.0)
        if !exited {
          exited = await processes.waitForExit(process, timeout: 0.75)
        }
        guard exited else {
          throw SafeUninstallEngineError.forceTerminationFailed
        }
      }
      try await revalidate(selected)
    } catch {
      return blocked(
        "卸载前安全校验未通过：\(error.localizedDescription)",
        code: "PREFLIGHT_FAILED")
    }

    await progress?(.deletingPermanently)
    let deletion = await files.deletePermanently(selected)
    let deletedApp = deletion.deletedCandidateIDs.contains(application.id)
    var failureMessages = deletion.failures.map(\.message)

    if deletedApp {
      do {
        try references.commitRemoval(for: review.target)
      } catch {
        failureMessages.append("启动器引用未能完整清理：\(error.localizedDescription)")
      }
      await progress?(.applicationDeleted)
    }

    let deletedCount = deletion.deletedCandidateIDs.count
    if deletedApp, failureMessages.isEmpty {
      return SafeUninstallPermanentExecutionOutcome(
        state: .completed,
        message:
          "已彻底卸载 \(review.target.name)：主程序及 \(max(0, deletedCount - 1)) 项专属数据已永久删除。",
        errorCode: nil,
        deletedCount: deletedCount,
        didDeleteTargetApplication: true)
    }
    if deletedApp {
      return SafeUninstallPermanentExecutionOutcome(
        state: .completedWithWarnings,
        message:
          "已彻底卸载 \(review.target.name)；\(failureMessages.count) 项受系统保护或删除失败，已保留。",
        errorCode: "RESIDUALS_RETAINED",
        deletedCount: deletedCount,
        didDeleteTargetApplication: true)
    }
    if deletedCount > 0 {
      return SafeUninstallPermanentExecutionOutcome(
        state: .partialFailure,
        message:
          "未能删除 \(review.target.name) 主程序；已有 \(deletedCount) 项专属数据永久删除，主程序仍保留。",
        errorCode: "APPLICATION_DELETE_FAILED",
        deletedCount: deletedCount,
        didDeleteTargetApplication: false)
    }
    return blocked(
      failureMessages.first ?? "系统未能永久删除所选 App。",
      code: "PERMANENT_DELETE_FAILED")
  }

  private func revalidate(_ candidates: [SafeUninstallCandidate]) async throws {
    for candidate in candidates {
      guard candidate.isExecutable else {
        throw SafeUninstallEngineError.unsafeCandidate(candidate.standardizedURL)
      }
      let identity = try await files.currentIdentity(for: candidate)
      guard identity == candidate.expectedIdentity else {
        throw SafeUninstallEngineError.identityChanged(candidate.standardizedURL)
      }
    }
  }

  private func validate(
    process: SafeUninstallRunningProcess,
    target: SafeUninstallTargetSnapshot
  ) throws {
    let processPath = URL(fileURLWithPath: process.bundlePath).standardizedFileURL.path
    let targetPath = URL(fileURLWithPath: target.path).standardizedFileURL.path
    let identifierMatches =
      process.bundleIdentifier == target.bundleIdentifier
      || process.bundleIdentifier.hasPrefix(target.bundleIdentifier + ".")
    let pathMatches =
      processPath == targetPath || processPath.hasPrefix(targetPath + "/Contents/")
    guard process.ownerUID == target.ownerUID,
      identifierMatches,
      pathMatches,
      process.launchTimestamp > 0
    else {
      throw SafeUninstallEngineError.processIdentityMismatch
    }
  }

  private func blocked(
    _ message: String,
    code: String
  ) -> SafeUninstallPermanentExecutionOutcome {
    SafeUninstallPermanentExecutionOutcome(
      state: .blocked,
      message: message,
      errorCode: code,
      deletedCount: 0,
      didDeleteTargetApplication: false)
  }
}

enum SafeUninstallEngineError: Error, LocalizedError {
  case staleReview
  case identityChanged(String)
  case unsafeCandidate(String)
  case processIdentityMismatch
  case multipleRunningCopies
  case transactionHeaderFailed
  case forceTerminationRequestRejected
  case forceTerminationFailed
  case restoreConflict(String)

  var errorDescription: String? {
    switch self {
    case .staleReview:
      return "卸载清单已经变化，请重新检查。"
    case .identityChanged(let path):
      return "检查后对象发生变化，已停止：\(path)"
    case .unsafeCandidate(let path):
      return "该项目不满足安全移动条件，已保留：\(path)"
    case .processIdentityMismatch:
      return "运行中的 App 身份与检查结果不一致，已停止。"
    case .multipleRunningCopies:
      return "检测到多个同名 App 正在运行，已停止，避免结束错误进程。"
    case .transactionHeaderFailed:
      return "无法保存恢复记录，未移动任何项目。"
    case .forceTerminationRequestRejected:
      return "进程身份在强制退出前发生变化，未发送终止信号。"
    case .forceTerminationFailed:
      return "已发送强制退出，但 App 未在约 7 秒内结束，未删除任何项目。"
    case .restoreConflict(let path):
      return "原位置已有同名对象，未覆盖：\(path)"
    }
  }
}

final class SafeUninstallPhaseOneEngine {
  private let files: SafeUninstallFileExecuting
  private let processes: SafeUninstallProcessControlling
  private let transactions: SafeUninstallTransactionPersisting
  private let references: SafeUninstallReferenceCommitting

  init(
    files: SafeUninstallFileExecuting,
    processes: SafeUninstallProcessControlling,
    transactions: SafeUninstallTransactionPersisting,
    references: SafeUninstallReferenceCommitting
  ) {
    self.files = files
    self.processes = processes
    self.transactions = transactions
    self.references = references
  }

  func execute(
    review: SafeUninstallReview,
    selectedCandidateIDs: [String],
    expectedReviewRevision: String,
    forceQuitApproved: Bool,
    progress: (@MainActor (SafeUninstallExecutionProgress) -> Void)? = nil
  ) async -> SafeUninstallExecutionOutcome {
    if let reason = SafeUninstallSharedInfrastructurePolicy.blockReason(for: review.target) {
      return blockedMessage(
        reason,
        code: SafeUninstallSharedInfrastructurePolicy.blockedErrorCode)
    }
    guard review.reviewRevision == expectedReviewRevision else {
      return blocked(.staleReview)
    }
    let selectedSet = Set(selectedCandidateIDs)
    let selected = review.candidates
      .filter { selectedSet.contains($0.id) }
      .sorted { lhs, rhs in
        if lhs.type == .application, rhs.type != .application { return true }
        if rhs.type == .application, lhs.type != .application { return false }
        return lhs.standardizedURL < rhs.standardizedURL
      }
    guard !selected.isEmpty else {
      return blocked(.unsafeCandidate("没有可执行项目"))
    }
    guard selected.contains(where: { $0.type == .application }) else {
      return blocked(.unsafeCandidate("必须保留主 App 才能执行卸载"))
    }

    do {
      try await revalidate(selected)
      let running = await processes.runningProcesses(for: review.target)
      for process in running {
        try validate(process: process, target: review.target)
      }
      if forceQuitApproved {
        for process in running {
          guard await processes.requestForceTermination(process) else {
            throw SafeUninstallEngineError.forceTerminationRequestRejected
          }
        }
        for process in running {
          var exited = await processes.waitForExit(process, timeout: 6.0)
          if !exited {
            // One bounded recheck only; never loop indefinitely around a stubborn process.
            exited = await processes.waitForExit(process, timeout: 0.75)
          }
          if !exited {
            throw SafeUninstallEngineError.forceTerminationFailed
          }
        }
      } else {
        for process in running {
          _ = await processes.requestTermination(process)
        }
        var stubbornProcesses: [SafeUninstallRunningProcess] = []
        for process in running {
          if !(await processes.waitForExit(process, timeout: 2.5)) {
            stubbornProcesses.append(process)
          }
        }
        if !stubbornProcesses.isEmpty {
          return SafeUninstallExecutionOutcome(
            state: .waitingForForceQuitConfirmation,
            message: "App 未在限定时间内退出。只有再次确认后才会强制结束已验证的同一 App 进程。",
            errorCode: "FORCE_QUIT_CONFIRMATION_REQUIRED",
            movedCount: 0,
            transaction: nil)
        }
      }
      try await revalidate(selected)
    } catch let error as SafeUninstallEngineError {
      return blocked(error)
    } catch {
      return blockedMessage(
        "执行前校验失败，未移动任何项目。请重新检查后重试。",
        code: "PREFLIGHT_FAILED")
    }

    await progress?(.movingToTrash)

    var transaction = SafeUninstallTransaction(
      schemaVersion: SafeUninstallTransaction.schemaVersion,
      operationID: review.operationID,
      createdAt: Date(),
      state: .executing,
      targetSnapshot: review.target,
      selectedCandidateIDs: selected.map(\.id),
      items: selected.map {
        SafeUninstallTransactionItem(
          candidateID: $0.id,
          originalURL: $0.standardizedURL,
          expectedIdentity: $0.expectedIdentity,
          actualTrashURL: nil,
          state: .pending,
          errorCode: nil)
      },
      referenceCompensations: [],
      lastDurableUpdateAt: Date())
    do {
      try transactions.save(transaction)
    } catch {
      return blocked(.transactionHeaderFailed)
    }

    let referenceSnapshotDigest: String
    do {
      referenceSnapshotDigest = try references.snapshotDigest(for: review.target)
    } catch {
      transaction.state = .blocked
      transaction.lastDurableUpdateAt = Date()
      try? transactions.save(transaction)
      return blockedMessage(
        "无法为启动器引用创建可恢复备份，未移动任何项目。",
        code: "REFERENCE_SNAPSHOT_FAILED")
    }

    var movedCount = 0
    var referenceCommitted = false
    var residualFailureReasons: [String] = []
    for index in selected.indices {
      let candidate = selected[index]
      do {
        let current = try await files.currentIdentity(for: candidate)
        guard current == candidate.expectedIdentity else {
          throw SafeUninstallEngineError.identityChanged(candidate.standardizedURL)
        }
        let trashURL = try await files.moveToTrash(candidate)
        movedCount += 1
        transaction.items[index].actualTrashURL = trashURL
        transaction.items[index].state = .moved
        transaction.lastDurableUpdateAt = Date()
      } catch {
        let failureReason = error.localizedDescription
        transaction.items[index].state = .failed
        transaction.items[index].errorCode = "MOVE_FAILED"
        transaction.state = movedCount == 0 ? .blocked : .partialFailure
        transaction.lastDurableUpdateAt = Date()
        if candidate.type != .application,
          transaction.items.contains(where: {
            URL(fileURLWithPath: $0.originalURL).standardizedFileURL.path
              == URL(fileURLWithPath: review.target.path).standardizedFileURL.path
              && $0.state == .moved
          })
        {
          residualFailureReasons.append(failureReason)
          do {
            try transactions.save(transaction)
          } catch {
            transaction.state = .manualRecoveryRequired
            return SafeUninstallExecutionOutcome(
              state: .manualRecoveryRequired,
              message: "App 已移入废纸篓，但残留处理记录未能完整保存。请在废纸篓中核对。",
              errorCode: "TRANSACTION_DURABILITY_FAILED",
              movedCount: movedCount,
              transaction: transaction)
          }
          continue
        }
        try? transactions.save(transaction)
        return SafeUninstallExecutionOutcome(
          state: movedCount == 0 ? .blocked : .partialFailure,
          message: movedCount == 0
            ? "未完成卸载：\(failureReason) 未移动任何项目，原有启动器、固定项和快捷键保持不变。"
            : "部分项目已移到废纸篓，后续操作因“\(failureReason)”停止。可以查看本次清单并恢复已移动项目。",
          errorCode: "MOVE_FAILED",
          movedCount: movedCount,
          transaction: transaction)
      }

      do {
        try transactions.save(transaction)
      } catch {
        transaction.state = .manualRecoveryRequired
        return SafeUninstallExecutionOutcome(
          state: .manualRecoveryRequired,
          message: "项目已移动，但恢复记录未能完整保存。已停止后续操作，请在废纸篓中核对。",
          errorCode: "TRANSACTION_DURABILITY_FAILED",
          movedCount: movedCount,
          transaction: transaction)
      }

      if candidate.type == .application, !referenceCommitted {
        do {
          try references.commitRemoval(for: review.target)
          transaction.referenceCompensations.append(
            SafeUninstallReferenceCompensation(
              kind: "launcher-references",
              snapshotDigest: referenceSnapshotDigest,
              committed: true,
              restored: false))
          referenceCommitted = true
          try transactions.save(transaction)
          await progress?(.applicationMoved)
        } catch {
          transaction.state = .manualRecoveryRequired
          try? transactions.save(transaction)
          return SafeUninstallExecutionOutcome(
            state: .manualRecoveryRequired,
            message: "App 已移入废纸篓，但本机引用事务未完整提交。已停止后续操作，请查看恢复清单。",
            errorCode: "REFERENCE_COMMIT_FAILED",
            movedCount: movedCount,
            transaction: transaction)
        }
      }
    }

    transaction.state = residualFailureReasons.isEmpty ? .completed : .partialFailure
    transaction.lastDurableUpdateAt = Date()
    try? transactions.save(transaction)
    if !residualFailureReasons.isEmpty {
      return SafeUninstallExecutionOutcome(
        state: .completedWithWarnings,
        message: "App 已移到废纸篓；\(residualFailureReasons.count) 项残留受系统保护或权限限制，已保留在原位。启动器已同步更新。",
        errorCode: "RESIDUALS_RETAINED",
        movedCount: movedCount,
        transaction: transaction)
    }
    return SafeUninstallExecutionOutcome(
      state: .completed,
      message: "已移到废纸篓。恢复记录保存在本机，废纸篓未被清空。",
      errorCode: nil,
      movedCount: movedCount,
      transaction: transaction)
  }

  func restore(_ transaction: SafeUninstallTransaction) async -> SafeUninstallExecutionOutcome {
    var transaction = transaction
    var restoredCount = 0
    for index in transaction.items.indices.reversed()
    where transaction.items[index].state == .moved {
      let item = transaction.items[index]
      guard let trashURL = item.actualTrashURL else {
        transaction.items[index].state = .restoreFailed
        transaction.items[index].errorCode = "MISSING_TRASH_URL"
        continue
      }
      if await files.originalPathExists(item.originalURL) {
        transaction.items[index].state = .restoreFailed
        transaction.items[index].errorCode = "ORIGINAL_PATH_CONFLICT"
        transaction.state = .restoreFailed
        try? transactions.save(transaction)
        return SafeUninstallExecutionOutcome(
          state: .restoreFailed,
          message: SafeUninstallEngineError.restoreConflict(item.originalURL)
            .localizedDescription,
          errorCode: "ORIGINAL_PATH_CONFLICT",
          movedCount: restoredCount,
          transaction: transaction)
      }
      do {
        try await files.restore(
          trashURL: trashURL,
          originalURL: item.originalURL,
          expectedIdentity: item.expectedIdentity)
        restoredCount += 1
        transaction.items[index].state = .restored
        transaction.lastDurableUpdateAt = Date()
        try transactions.save(transaction)
      } catch {
        transaction.items[index].state = .restoreFailed
        transaction.items[index].errorCode = "RESTORE_FAILED"
        transaction.state = .restoreFailed
        try? transactions.save(transaction)
        return SafeUninstallExecutionOutcome(
          state: .restoreFailed,
          message: "恢复未完成，已保留事务清单。请确认废纸篓对象和原目录权限。",
          errorCode: "RESTORE_FAILED",
          movedCount: restoredCount,
          transaction: transaction)
      }
    }

    if let compensation = transaction.referenceCompensations.first(where: \.committed) {
      do {
        try references.restoreRemoval(
          for: transaction.targetSnapshot,
          expectedSnapshotDigest: compensation.snapshotDigest)
        if let index = transaction.referenceCompensations.firstIndex(of: compensation) {
          transaction.referenceCompensations[index].restored = true
        }
      } catch {
        transaction.state = .restoreFailed
        try? transactions.save(transaction)
        return SafeUninstallExecutionOutcome(
          state: .restoreFailed,
          message: "App 已恢复，但本机引用与之后的新配置冲突，未覆盖新配置。",
          errorCode: "REFERENCE_RESTORE_CONFLICT",
          movedCount: restoredCount,
          transaction: transaction)
      }
    }

    transaction.state = .restored
    transaction.lastDurableUpdateAt = Date()
    try? transactions.save(transaction)
    return SafeUninstallExecutionOutcome(
      state: .restored,
      message: "已按逆序恢复本次移动的项目。",
      errorCode: nil,
      movedCount: restoredCount,
      transaction: transaction)
  }

  private func revalidate(_ candidates: [SafeUninstallCandidate]) async throws {
    for candidate in candidates {
      guard candidate.isExecutable else {
        throw SafeUninstallEngineError.unsafeCandidate(candidate.standardizedURL)
      }
      let identity = try await files.currentIdentity(for: candidate)
      guard identity == candidate.expectedIdentity else {
        throw SafeUninstallEngineError.identityChanged(candidate.standardizedURL)
      }
    }
  }

  private func validate(
    process: SafeUninstallRunningProcess,
    target: SafeUninstallTargetSnapshot
  ) throws {
    let processPath = URL(fileURLWithPath: process.bundlePath).standardizedFileURL.path
    let targetPath = URL(fileURLWithPath: target.path).standardizedFileURL.path
    let exactBundle = process.bundleIdentifier == target.bundleIdentifier
    let embeddedHelperBundle =
      !target.bundleIdentifier.isEmpty
      && process.bundleIdentifier.hasPrefix(target.bundleIdentifier + ".")
    let belongsToTargetBundle =
      processPath == targetPath || processPath.hasPrefix(targetPath + "/Contents/")
    guard process.ownerUID == target.ownerUID,
      exactBundle || embeddedHelperBundle,
      belongsToTargetBundle,
      process.launchTimestamp > 0
    else {
      throw SafeUninstallEngineError.processIdentityMismatch
    }
  }

  private func blocked(_ error: SafeUninstallEngineError) -> SafeUninstallExecutionOutcome {
    blockedMessage(error.localizedDescription, code: String(describing: error))
  }

  private func blockedMessage(_ message: String, code: String) -> SafeUninstallExecutionOutcome {
    SafeUninstallExecutionOutcome(
      state: .blocked,
      message: message,
      errorCode: code,
      movedCount: 0,
      transaction: nil)
  }
}

struct SafeUninstallJSONTransactionStore: SafeUninstallTransactionPersisting {
  let directory: URL

  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path)
  }

  func save(_ transaction: SafeUninstallTransaction) throws {
    let data = try JSONEncoder.safeUninstaller.encode(transaction)
    let url = directory.appendingPathComponent("\(transaction.operationID).json")
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }

  func load(operationID: String) throws -> SafeUninstallTransaction? {
    let url = directory.appendingPathComponent("\(operationID).json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder.safeUninstaller.decode(
      SafeUninstallTransaction.self,
      from: Data(contentsOf: url))
  }
}

enum SafeUninstallLiveExecutionError: Error, LocalizedError {
  case missingItem(String)
  case finderAuthorizationCancelled
  case finderAutomationDenied
  case finderRecycleFailed(String)
  case trashDidNotReturnURL
  case trashMoveIncomplete(String)
  case restoreIdentityMismatch
  case restoreParentUnavailable(String)
  case restoreDestinationExists(String)

  var errorDescription: String? {
    switch self {
    case .missingItem(let path): return "对象已不在原位置：\(path)"
    case .finderAuthorizationCancelled:
      return "你取消了系统授权，未移动任何项目。"
    case .finderAutomationDenied:
      return "访达自动化权限未开启。请到“系统设置 → 隐私与安全性 → 自动化”，允许“小龙哥Mac哲学”控制“访达”后重试。"
    case .finderRecycleFailed(let message):
      return "访达未能将对象移入废纸篓：\(message)"
    case .trashDidNotReturnURL: return "系统未返回废纸篓中的实际位置。"
    case .trashMoveIncomplete(let path): return "对象移动后仍出现在原位置：\(path)"
    case .restoreIdentityMismatch: return "废纸篓中的对象与恢复记录不一致。"
    case .restoreParentUnavailable(let path): return "原目录不存在或不可写：\(path)"
    case .restoreDestinationExists(let path): return "原位置已有同名对象，未覆盖：\(path)"
    }
  }
}

/// Production uses NSWorkspace for ordinary items and Finder-owned authorization for protected
/// items. Tests may inject an isolated trash directory so no unrelated Trash content is touched.
final class SafeUninstallLiveFileExecutor: SafeUninstallFileExecuting {
  typealias RecycleCompletion = @Sendable ([URL: URL], Error?) -> Void
  typealias RecycleOperation = @Sendable (
    _ urls: [URL],
    _ completion: @escaping RecycleCompletion
  ) -> Void
  typealias FinderRecycleOperation = @MainActor (_ url: URL) throws -> URL

  private let fileManager: FileManager
  private let isolatedTrashDirectory: URL?
  private let recycleOperation: RecycleOperation
  private let finderRecycleOperation: FinderRecycleOperation

  init(
    fileManager: FileManager = .default,
    isolatedTrashDirectory: URL? = nil,
    recycleOperation: RecycleOperation? = nil,
    finderRecycleOperation: FinderRecycleOperation? = nil
  ) {
    self.fileManager = fileManager
    self.isolatedTrashDirectory = isolatedTrashDirectory
    self.recycleOperation =
      recycleOperation ?? { urls, completion in
        NSWorkspace.shared.recycle(urls, completionHandler: completion)
      }
    self.finderRecycleOperation =
      finderRecycleOperation ?? SafeUninstallLiveFileExecutor.recycleThroughFinder
  }

  func currentIdentity(for candidate: SafeUninstallCandidate) async throws
    -> SafeUninstallFileIdentity
  {
    try SafeUninstallFileIdentity.capture(
      at: URL(fileURLWithPath: candidate.standardizedURL),
      bundleIdentifier: candidate.expectedIdentity.bundleIdentifier,
      teamIdentifier: candidate.expectedIdentity.teamIdentifier,
      designatedRequirementDigest: candidate.expectedIdentity.designatedRequirementDigest)
  }

  func moveToTrash(_ candidate: SafeUninstallCandidate) async throws -> String {
    let source = URL(fileURLWithPath: candidate.standardizedURL).standardizedFileURL
    guard fileManager.fileExists(atPath: source.path) else {
      throw SafeUninstallLiveExecutionError.missingItem(source.path)
    }
    let resultingURL: URL
    if let isolatedTrashDirectory {
      try fileManager.createDirectory(
        at: isolatedTrashDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var destination = isolatedTrashDirectory.appendingPathComponent(source.lastPathComponent)
      if fileManager.fileExists(atPath: destination.path) {
        destination = isolatedTrashDirectory.appendingPathComponent(
          "\(UUID().uuidString)-\(source.lastPathComponent)")
      }
      try fileManager.moveItem(at: source, to: destination)
      resultingURL = destination
    } else if candidate.permissionState == .systemAuthorization {
      // Finder owns the Automation and administrator confirmation. This process never receives,
      // stores, or bypasses the user's administrator credential.
      resultingURL = try await finderRecycleOperation(source)
    } else {
      resultingURL = try await recycleWithWorkspace(source)
    }
    guard !fileManager.fileExists(atPath: source.path),
      fileManager.fileExists(atPath: resultingURL.path)
    else {
      throw SafeUninstallLiveExecutionError.trashMoveIncomplete(source.path)
    }
    return resultingURL.standardizedFileURL.path
  }

  private func recycleWithWorkspace(_ source: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      recycleOperation([source]) { newURLs, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let standardizedSource = source.standardizedFileURL.path
        guard
          let result = newURLs.first(where: {
            $0.key.standardizedFileURL.path == standardizedSource
          })?.value
        else {
          continuation.resume(
            throwing: SafeUninstallLiveExecutionError.trashDidNotReturnURL)
          return
        }
        continuation.resume(returning: result)
      }
    }
  }

  @MainActor
  private static func recycleThroughFinder(_ source: URL) throws -> URL {
    let sourceCode = """
      on trashPath(targetPath)
        set targetAlias to POSIX file targetPath as alias
        tell application "Finder"
          set trashedItem to delete targetAlias
          return POSIX path of (trashedItem as alias)
        end tell
      end trashPath
      """
    guard let script = NSAppleScript(source: sourceCode) else {
      throw SafeUninstallLiveExecutionError.finderRecycleFailed("无法创建访达指令。")
    }
    var compileError: NSDictionary?
    guard script.compileAndReturnError(&compileError) else {
      throw finderExecutionError(compileError)
    }

    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(
      NSAppleEventDescriptor(string: "trashPath"),
      forKeyword: AEKeyword(keyASSubroutineName))
    let arguments = NSAppleEventDescriptor.list()
    arguments.insert(NSAppleEventDescriptor(string: source.path), at: 1)
    event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

    var executionError: NSDictionary?
    let result = script.executeAppleEvent(event, error: &executionError)
    if executionError != nil {
      throw finderExecutionError(executionError)
    }
    guard let path = result.stringValue, !path.isEmpty else {
      throw SafeUninstallLiveExecutionError.trashDidNotReturnURL
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  private static func finderExecutionError(_ details: NSDictionary?)
    -> SafeUninstallLiveExecutionError
  {
    let number = (details?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    switch number {
    case -128:
      return .finderAuthorizationCancelled
    case -1743:
      return .finderAutomationDenied
    default:
      let message =
        (details?[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
      if let message, !message.isEmpty {
        return .finderRecycleFailed(message)
      }
      if let number {
        return .finderRecycleFailed("系统错误 \(number)。")
      }
      return .finderRecycleFailed("未知错误。")
    }
  }

  func originalPathExists(_ path: String) async -> Bool {
    fileManager.fileExists(atPath: URL(fileURLWithPath: path).standardizedFileURL.path)
  }

  func restore(
    trashURL: String,
    originalURL: String,
    expectedIdentity: SafeUninstallFileIdentity
  ) async throws {
    let source = URL(fileURLWithPath: trashURL).standardizedFileURL
    let destination = URL(fileURLWithPath: originalURL).standardizedFileURL
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SafeUninstallLiveExecutionError.restoreDestinationExists(destination.path)
    }
    let parent = destination.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      fileManager.isWritableFile(atPath: parent.path)
    else {
      throw SafeUninstallLiveExecutionError.restoreParentUnavailable(parent.path)
    }
    let current = try SafeUninstallFileIdentity.capture(
      at: source,
      bundleIdentifier: expectedIdentity.bundleIdentifier,
      teamIdentifier: expectedIdentity.teamIdentifier,
      designatedRequirementDigest: expectedIdentity.designatedRequirementDigest)
    guard Self.sameMovedObject(current, expectedIdentity) else {
      throw SafeUninstallLiveExecutionError.restoreIdentityMismatch
    }
    try fileManager.moveItem(at: source, to: destination)
  }

  static func sameMovedObject(
    _ current: SafeUninstallFileIdentity,
    _ expected: SafeUninstallFileIdentity
  ) -> Bool {
    current.fileResourceIdentifier == expected.fileResourceIdentifier
      && current.volumeIdentifier == expected.volumeIdentifier
      && current.fileType == expected.fileType
      && current.isSymbolicLink == expected.isSymbolicLink
      && current.isAliasFile == expected.isAliasFile
      && current.bundleIdentifier == expected.bundleIdentifier
      && current.teamIdentifier == expected.teamIdentifier
      && current.designatedRequirementDigest == expected.designatedRequirementDigest
  }
}

enum SafeUninstallPermanentDeleteError: Error, LocalizedError {
  case unsafePath(String)
  case identityUnavailable(String)
  case authorizationCancelled
  case authorizationFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsafePath(let path):
      return "永久删除路径未通过边界校验：\(path)"
    case .identityUnavailable(let path):
      return "无法在删除前复核对象身份：\(path)"
    case .authorizationCancelled:
      return "已取消 macOS 管理员认证。"
    case .authorizationFailed(let message):
      return "macOS 管理员认证未完成：\(message)"
    }
  }
}

/// The current uninstall route uses this executor only after the user accepts one irreversible
/// warning. Ordinary files are removed directly. Protected paths are passed to one macOS
/// administrator-authentication request, with a device/inode check immediately before `rm`.
final class SafeUninstallPermanentFileExecutor: SafeUninstallPermanentFileDeleting {
  typealias PrivilegedRemovalOperation = @MainActor (_ urls: [URL]) throws -> Void

  private let fileManager: FileManager
  private let homeDirectory: URL
  private let privilegedRemovalOperation: PrivilegedRemovalOperation

  init(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    privilegedRemovalOperation: PrivilegedRemovalOperation? = nil
  ) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.privilegedRemovalOperation =
      privilegedRemovalOperation ?? SafeUninstallPermanentFileExecutor.removeWithAuthorization
  }

  func currentIdentity(for candidate: SafeUninstallCandidate) async throws
    -> SafeUninstallFileIdentity
  {
    try SafeUninstallFileIdentity.capture(
      at: URL(fileURLWithPath: candidate.standardizedURL),
      bundleIdentifier: candidate.expectedIdentity.bundleIdentifier,
      teamIdentifier: candidate.expectedIdentity.teamIdentifier,
      designatedRequirementDigest: candidate.expectedIdentity.designatedRequirementDigest)
  }

  func deletePermanently(_ candidates: [SafeUninstallCandidate]) async
    -> SafeUninstallPermanentDeleteResult
  {
    var deleted = Set<String>()
    var failureByCandidateID: [String: String] = [:]
    var ordinaryCandidates: [SafeUninstallCandidate] = []
    var privilegedCandidates: [SafeUninstallCandidate] = []

    // Finish every reversible boundary check before deleting anything. In particular, an
    // authorization sheet must be resolved before ordinary files are removed; otherwise a user
    // who cancels the sheet can lose the unprivileged half of a mixed selection.
    for candidate in candidates {
      do {
        try validateDeletionBoundary(candidate)
      } catch {
        failureByCandidateID[candidate.id] = error.localizedDescription
        continue
      }

      if candidate.permissionState == .systemAuthorization {
        privilegedCandidates.append(candidate)
      } else {
        ordinaryCandidates.append(candidate)
      }
    }

    if !privilegedCandidates.isEmpty {
      let urls = privilegedCandidates.map {
        URL(fileURLWithPath: $0.standardizedURL).standardizedFileURL
      }
      var authorizationFailure: String?
      do {
        try await privilegedRemovalOperation(urls)
      } catch {
        authorizationFailure = error.localizedDescription
      }
      var everyPrivilegedCandidateWasRemoved = true
      for candidate in privilegedCandidates {
        if pathExists(candidate.standardizedURL) {
          everyPrivilegedCandidateWasRemoved = false
          failureByCandidateID[candidate.id] =
            authorizationFailure ?? "系统返回后对象仍在原位置。"
        } else {
          deleted.insert(candidate.id)
          failureByCandidateID.removeValue(forKey: candidate.id)
        }
      }
      guard everyPrivilegedCandidateWasRemoved else {
        return SafeUninstallPermanentDeleteResult(
          deletedCandidateIDs: deleted,
          failures: failureByCandidateID.sorted { $0.key < $1.key }.map {
            SafeUninstallPermanentDeleteFailure(candidateID: $0.key, message: $0.value)
          })
      }
    }

    for candidate in ordinaryCandidates {
      let url = URL(fileURLWithPath: candidate.standardizedURL).standardizedFileURL
      do {
        try fileManager.removeItem(at: url)
        if pathExists(url.path) {
          failureByCandidateID[candidate.id] = "系统返回后对象仍在原位置。"
        } else {
          deleted.insert(candidate.id)
        }
      } catch {
        if pathExists(url.path) {
          // Never open a second, late authorization sheet after another selected object has
          // already been irreversibly deleted. Report the exact failure and let the user retry.
          failureByCandidateID[candidate.id] = error.localizedDescription
        } else {
          deleted.insert(candidate.id)
        }
      }
    }

    return SafeUninstallPermanentDeleteResult(
      deletedCandidateIDs: deleted,
      failures: failureByCandidateID.sorted { $0.key < $1.key }.map {
        SafeUninstallPermanentDeleteFailure(candidateID: $0.key, message: $0.value)
      })
  }

  private func validateDeletionBoundary(_ candidate: SafeUninstallCandidate) throws {
    let url = URL(fileURLWithPath: candidate.standardizedURL).standardizedFileURL
    guard url.path == candidate.expectedIdentity.standardizedPath,
      url.path != "/",
      url.path != homeDirectory.path,
      !candidate.expectedIdentity.isSymbolicLink,
      !candidate.expectedIdentity.isAliasFile
    else {
      throw SafeUninstallPermanentDeleteError.unsafePath(url.path)
    }
    if candidate.type == .application {
      let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        homeDirectory.appendingPathComponent("Applications", isDirectory: true),
      ]
      guard url.pathExtension.lowercased() == "app",
        roots.contains(where: { SafeUninstallPathPolicy.isDirectChild(url, of: $0) })
      else {
        throw SafeUninstallPermanentDeleteError.unsafePath(url.path)
      }
      return
    }

    let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
    let allowedRoots = [
      library.appendingPathComponent("Application Support", isDirectory: true),
      library.appendingPathComponent("Preferences", isDirectory: true),
      library.appendingPathComponent("Caches", isDirectory: true),
      library.appendingPathComponent("Logs", isDirectory: true),
      library.appendingPathComponent("Saved Application State", isDirectory: true),
      library.appendingPathComponent("LaunchAgents", isDirectory: true),
      library.appendingPathComponent("WebKit", isDirectory: true),
      library.appendingPathComponent("HTTPStorages", isDirectory: true),
      library.appendingPathComponent("Cookies", isDirectory: true),
      library.appendingPathComponent("Application Support/CrashReporter", isDirectory: true),
      library.appendingPathComponent("Containers", isDirectory: true),
      library.appendingPathComponent("Group Containers", isDirectory: true),
    ]
    guard allowedRoots.contains(where: { SafeUninstallPathPolicy.isDirectChild(url, of: $0) })
    else {
      throw SafeUninstallPermanentDeleteError.unsafePath(url.path)
    }
  }

  private func pathExists(_ path: String) -> Bool {
    var info = stat()
    if lstat(path, &info) == 0 { return true }
    return errno != ENOENT
  }

  @MainActor
  static func removeWithAuthorization(_ urls: [URL]) throws {
    let sourceCode = """
      on deletePaths(entries)
        set commandsList to {"set -e"}
        repeat with entryData in entries
          set targetPath to item 1 of entryData as text
          set expectedIdentity to item 2 of entryData as text
          set verifyCommand to "current_id=$(/usr/bin/stat -f '%d:%i' " & quoted form of targetPath & ")"
          set removeCommand to "test \\\"$current_id\\\" = " & quoted form of expectedIdentity & " && /bin/rm -rf -- " & quoted form of targetPath
          set end of commandsList to verifyCommand
          set end of commandsList to removeCommand
        end repeat
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to "; "
        set commandText to commandsList as text
        set AppleScript's text item delimiters to previousDelimiters
        do shell script commandText with administrator privileges
      end deletePaths
      """
    guard let script = NSAppleScript(source: sourceCode) else {
      throw SafeUninstallPermanentDeleteError.authorizationFailed("无法创建系统认证指令。")
    }
    var compileError: NSDictionary?
    guard script.compileAndReturnError(&compileError) else {
      throw authorizationError(compileError)
    }

    let entries = NSAppleEventDescriptor.list()
    for (index, url) in urls.enumerated() {
      var info = stat()
      guard lstat(url.path, &info) == 0 else {
        throw SafeUninstallPermanentDeleteError.identityUnavailable(url.path)
      }
      let entry = NSAppleEventDescriptor.list()
      entry.insert(NSAppleEventDescriptor(string: url.path), at: 1)
      entry.insert(
        NSAppleEventDescriptor(string: "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"),
        at: 2)
      entries.insert(entry, at: index + 1)
    }

    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(
      NSAppleEventDescriptor(string: "deletePaths"),
      forKeyword: AEKeyword(keyASSubroutineName))
    let arguments = NSAppleEventDescriptor.list()
    arguments.insert(entries, at: 1)
    event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

    var executionError: NSDictionary?
    _ = script.executeAppleEvent(event, error: &executionError)
    if executionError != nil {
      throw authorizationError(executionError)
    }
  }

  private static func authorizationError(_ details: NSDictionary?)
    -> SafeUninstallPermanentDeleteError
  {
    let number = (details?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    if number == -128 { return .authorizationCancelled }
    let message =
      (details?[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
    if let message, !message.isEmpty {
      return .authorizationFailed(message)
    }
    if let number {
      return .authorizationFailed("系统错误 \(number)。")
    }
    return .authorizationFailed("未知错误。")
  }
}

final class SafeUninstallLiveProcessController: SafeUninstallProcessControlling, @unchecked Sendable {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace = .shared) {
    self.workspace = workspace
  }

  func runningProcesses(for target: SafeUninstallTargetSnapshot) async
    -> [SafeUninstallRunningProcess]
  {
    await MainActor.run {
      workspace.runningApplications.compactMap { application in
        snapshot(application, ifBelongsTo: target)
      }
    }
  }

  func requestTermination(_ process: SafeUninstallRunningProcess) async -> Bool {
    await MainActor.run {
      guard let application = verifiedApplication(for: process) else { return false }
      return application.isTerminated || application.terminate()
    }
  }

  func requestForceTermination(_ process: SafeUninstallRunningProcess) async -> Bool {
    await MainActor.run {
      // Verify the kernel owner and executable path immediately before any force signal.
      guard kernelIdentityMatches(process) else { return !processExists(process.pid) }
      if let application = verifiedApplication(for: process) {
        if application.isTerminated { return true }
        _ = application.forceTerminate()
      }
      // NSRunningApplication can acknowledge before a stubborn process exits. The kernel identity
      // check above and this signal are adjacent, avoiding a second LaunchServices metadata race.
      if kill(process.pid, SIGKILL) == 0 { return true }
      return errno == ESRCH
    }
  }

  func waitForExit(_ process: SafeUninstallRunningProcess, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    repeat {
      let state = await MainActor.run { () -> Int in
        if !processExists(process.pid) { return 1 }
        guard
          let application = workspace.runningApplications.first(where: {
            $0.processIdentifier == process.pid
          })
        else {
          let expectedBundlePath = URL(fileURLWithPath: process.bundlePath)
            .standardizedFileURL.path
          let isSameKernelProcess =
            processOwnerUID(process.pid) == process.ownerUID
            && processExecutablePath(process.pid)?.hasPrefix(
              expectedBundlePath + "/Contents/") == true
          return isSameKernelProcess ? 0 : 1
        }
        if application.isTerminated { return 1 }
        if verifiedApplication(for: process) != nil { return 0 }
        let expectedBundlePath = URL(fileURLWithPath: process.bundlePath).standardizedFileURL.path
        let isSameKernelProcess =
          processOwnerUID(process.pid) == process.ownerUID
          && processExecutablePath(process.pid)?.hasPrefix(
            expectedBundlePath + "/Contents/") == true
        return isSameKernelProcess ? 0 : -1
      }
      if state == 1 { return true }
      if state == -1 { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return await MainActor.run {
      !processExists(process.pid)
        || !workspace.runningApplications.contains(where: {
          $0.processIdentifier == process.pid && !$0.isTerminated
        })
    }
  }

  private func snapshot(
    _ application: NSRunningApplication,
    ifBelongsTo target: SafeUninstallTargetSnapshot
  ) -> SafeUninstallRunningProcess? {
    guard !application.isTerminated,
      let bundleIdentifier = application.bundleIdentifier,
      let bundleURL = application.bundleURL,
      let executableURL = application.executableURL,
      let launchDate = application.launchDate,
      processOwnerUID(application.processIdentifier) == target.ownerUID
    else { return nil }
    let targetPath = URL(fileURLWithPath: target.path).standardizedFileURL.path
    let bundlePath = bundleURL.standardizedFileURL.path
    let executablePath = executableURL.standardizedFileURL.path
    let identifierMatches =
      bundleIdentifier == target.bundleIdentifier
      || bundleIdentifier.hasPrefix(target.bundleIdentifier + ".")
    let bundleMatches = bundlePath == targetPath || bundlePath.hasPrefix(targetPath + "/Contents/")
    let executableMatches = executablePath.hasPrefix(targetPath + "/Contents/")
    guard identifierMatches, bundleMatches, executableMatches else { return nil }
    return SafeUninstallRunningProcess(
      pid: application.processIdentifier,
      bundleIdentifier: bundleIdentifier,
      bundlePath: bundlePath,
      launchTimestamp: launchDate.timeIntervalSince1970,
      ownerUID: target.ownerUID)
  }

  private func verifiedApplication(
    for process: SafeUninstallRunningProcess
  ) -> NSRunningApplication? {
    guard
      let application = workspace.runningApplications.first(where: {
        $0.processIdentifier == process.pid
      }),
      !application.isTerminated,
      application.bundleIdentifier == process.bundleIdentifier,
      application.bundleURL?.standardizedFileURL.path
        == URL(fileURLWithPath: process.bundlePath).standardizedFileURL.path,
      processOwnerUID(process.pid) == process.ownerUID
    else { return nil }
    return application
  }

  private func processOwnerUID(_ pid: pid_t) -> UInt32? {
    var info = proc_bsdinfo()
    let result = proc_pidinfo(
      pid,
      PROC_PIDTBSDINFO,
      0,
      &info,
      Int32(MemoryLayout<proc_bsdinfo>.size))
    guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
    return info.pbi_uid
  }

  private func processExists(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let result = proc_pidinfo(
      pid,
      PROC_PIDTBSDINFO,
      0,
      &info,
      Int32(MemoryLayout<proc_bsdinfo>.size))
    guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
    // Darwin's SZOMB process status is 5. A zombie cannot execute or hold the App bundle open.
    return info.pbi_status != 5
  }

  private func kernelIdentityMatches(_ process: SafeUninstallRunningProcess) -> Bool {
    let expectedBundlePath = URL(fileURLWithPath: process.bundlePath).standardizedFileURL.path
    return processOwnerUID(process.pid) == process.ownerUID
      && processExecutablePath(process.pid)?.hasPrefix(expectedBundlePath + "/Contents/") == true
  }

  private func processExecutablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let validBytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: validBytes, as: UTF8.self))
      .standardizedFileURL.path
  }
}

extension JSONEncoder {
  fileprivate static var safeUninstaller: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var safeUninstaller: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

enum SafeUninstallPathPolicy {
  static func isDirectChild(_ url: URL, of root: URL) -> Bool {
    url.standardizedFileURL.deletingLastPathComponent().path
      == root.standardizedFileURL.path
  }

  static func isValidBundleIdentifier(_ value: String) -> Bool {
    guard value.count >= 3, value.count <= 255,
      value.contains("."),
      !value.hasPrefix("."),
      !value.hasSuffix("."),
      !value.contains("..")
    else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  static func appBlockReason(
    url: URL,
    identity: SafeUninstallFileIdentity,
    homeDirectory: URL,
    currentApplicationURL: URL
  ) -> String? {
    let standardized = url.standardizedFileURL
    guard standardized.pathExtension.lowercased() == "app" else {
      return "不是标准 App，已阻止卸载。"
    }
    guard identity.standardizedPath != currentApplicationURL.standardizedFileURL.path else {
      return "不能在本软件里卸载当前正在运行的 App。"
    }
    guard !identity.isSymbolicLink, !identity.isAliasFile else {
      return "App 是符号链接或别名，无法确认真实边界，已阻止。"
    }
    guard identity.isLocalVolume, !identity.isReadOnlyVolume else {
      return "App 位于外接、网络或只读位置，已阻止。"
    }
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      homeDirectory.appendingPathComponent("Applications", isDirectory: true),
    ]
    guard roots.contains(where: { isDirectChild(standardized, of: $0) }) else {
      return "App 不在本机标准应用目录，已阻止卸载。"
    }
    guard !standardized.path.hasPrefix("/System/") else {
      return "系统 App 受保护，已阻止卸载。"
    }
    return nil
  }

  static func classifyOwnership(
    candidateName: String,
    bundleIdentifier: String,
    appName: String,
    candidateType: SafeUninstallCandidateType,
    launchAgentReferencesTarget: Bool = false
  ) -> (
    confidence: SafeUninstallOwnershipConfidence,
    risk: SafeUninstallRiskLevel,
    selected: Bool,
    reason: String
  ) {
    let lower = candidateName.lowercased()
    let bundle = bundleIdentifier.lowercased()
    let exactStem: String
    if lower.hasSuffix(".plist") {
      exactStem = String(lower.dropLast(".plist".count))
    } else if lower.hasSuffix(".savedstate") {
      exactStem = String(lower.dropLast(".savedstate".count))
    } else {
      exactStem = lower
    }
    if candidateType == .container, !bundle.isEmpty, exactStem == bundle {
      return (
        .confirmed,
        .high,
        false,
        "精确 Bundle ID 的专属沙盒容器；包含账号与本地数据，且 macOS 可能单独询问访问权限，默认保留。"
      )
    }
    if [
      .container, .groupContainer, .userDocument, .helper, .systemExtension,
      .networkExtension,
    ].contains(candidateType) {
      return (.sharedOrUnknown, .protected, false, "共享或高风险对象默认保留。")
    }
    if candidateType == .launchAgent, !launchAgentReferencesTarget {
      return (.sharedOrUnknown, .protected, false, "启动项未能证明唯一归属。")
    }
    if !bundle.isEmpty, exactStem == bundle {
      let lowRisk = [.cache, .log, .savedState, .crashReport].contains(candidateType)
      let precisePrivateData = [
        .preference, .applicationSupport, .webData, .httpStorage, .cookie,
      ].contains(candidateType)
      return (
        .high,
        lowRisk ? .low : .medium,
        lowRisk || precisePrivateData,
        lowRisk
          ? "精确 Bundle ID 的低风险本机数据。"
          : (precisePrivateData
            ? "精确 Bundle ID 的专属数据；可能包含账号与设置，可取消选择以保留。"
            : "可能包含设置或本地数据，默认保留。")
      )
    }
    if candidateType == .crashReport {
      let crashName = candidateName.lowercased()
      let appPrefix = appName.lowercased()
      if !appPrefix.isEmpty,
        crashName.hasPrefix(appPrefix + "_") || crashName.hasPrefix(appPrefix + "-")
      {
        return (.low, .low, false, "按 App 名称匹配的崩溃记录，由你决定是否清理。")
      }
    }
    let normalizedCandidate = normalize(candidateName)
    let normalizedApp = normalize(appName)
    if !normalizedApp.isEmpty,
      normalizedCandidate == normalizedApp
        || (!bundle.isEmpty && lower.hasPrefix(bundle))
    {
      return (.low, .medium, false, "只由名称或共享前缀匹配，默认保留。")
    }
    return (.sharedOrUnknown, .protected, false, "无法证明唯一归属。")
  }

  static func isRelatedCandidate(
    candidateName: String,
    bundleIdentifier: String,
    appName: String,
    candidateType: SafeUninstallCandidateType,
    launchAgentReferencesTarget: Bool = false
  ) -> Bool {
    guard isValidBundleIdentifier(bundleIdentifier) else { return false }
    if candidateType == .launchAgent, launchAgentReferencesTarget {
      return true
    }
    let lower = candidateName.lowercased()
    let bundle = bundleIdentifier.lowercased()
    let stem = NSString(string: lower).deletingPathExtension
    if !bundle.isEmpty,
      stem == bundle
        || lower == bundle
        || lower == "\(bundle).savedstate"
        || lower.hasPrefix(bundle + ".")
        || lower.hasPrefix(bundle + "-")
    {
      return true
    }
    if candidateType == .crashReport {
      let crashName = candidateName.lowercased()
      let appPrefix = appName.lowercased()
      return !appPrefix.isEmpty
        && (crashName.hasPrefix(appPrefix + "_") || crashName.hasPrefix(appPrefix + "-"))
    }
    let normalizedCandidate = normalize(candidateName)
    let normalizedApp = normalize(appName)
    return !normalizedApp.isEmpty && normalizedCandidate == normalizedApp
  }

  static func stableRevision(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
      .lowercased()
  }
}

struct SafeUninstallLiveScanner {
  private let fileManager = FileManager.default

  func scan(
    appName: String,
    bundleIdentifier: String,
    appURL: URL,
    currentApplicationURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> SafeUninstallReview {
    let operationID = UUID().uuidString
    let bundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SafeUninstallPathPolicy.isValidBundleIdentifier(bundleID) else {
      throw SafeUninstallScanError.blocked("App 的 Bundle ID 缺失或格式异常，为避免扩大匹配已停止。")
    }
    let identity = try SafeUninstallFileIdentity.capture(
      at: appURL,
      bundleIdentifier: bundleID)
    let source = sourceKind(for: appURL, identity: identity)
    if let reason = SafeUninstallPathPolicy.appBlockReason(
      url: appURL,
      identity: identity,
      homeDirectory: homeDirectory,
      currentApplicationURL: currentApplicationURL)
    {
      let standardRoots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        homeDirectory.appendingPathComponent("Applications", isDirectory: true),
      ]
      let canShowHomebrewRoute =
        source == .homebrewCask
        && identity.standardizedPath != currentApplicationURL.standardizedFileURL.path
        && standardRoots.contains {
          SafeUninstallPathPolicy.isDirectChild(appURL.standardizedFileURL, of: $0)
        }
      if !canShowHomebrewRoute {
        throw SafeUninstallScanError.blocked(reason)
      }
    }
    let target = SafeUninstallTargetSnapshot(
      name: appName,
      bundleIdentifier: bundleID,
      path: appURL.standardizedFileURL.path,
      identity: identity,
      sourceKind: source,
      ownerUID: getuid())

    let appRemovalSupported = source.supportsPhaseOneRemoval
    let appPermissionState: SafeUninstallPermissionState =
      identity.isWritable ? .readable : .systemAuthorization
    let appExecutable = appRemovalSupported
    var candidates = [
      SafeUninstallCandidate(
        id: "app:\(identity.fileResourceIdentifier)",
        operationID: operationID,
        originalURL: appURL.path,
        standardizedURL: appURL.standardizedFileURL.path,
        expectedIdentity: identity,
        type: .application,
        size: allocatedSize(for: appURL),
        ownershipConfidence: .confirmed,
        ownershipEvidence: "所选 App 主包与 Bundle ID。",
        riskLevel: appExecutable ? .medium : .protected,
        defaultSelected: appExecutable,
        selectionReason: appExecutable
          ? (appPermissionState == .systemAuthorization
            ? "主 App 可卸载；移动时 macOS 会显示管理员确认。"
            : "主 App 可在确认后移到废纸篓。")
          : (appRemovalSupported
            ? "当前账户无法直接移动该 App，未尝试绕过系统权限。"
            : "该安装来源需要官方或受支持的卸载路径。"),
        sourceKind: source,
        permissionState: appPermissionState,
        symlinkState: identity.isSymbolicLink
          ? .symbolicLink : (identity.isAliasFile ? .alias : .regular),
        supportedRemovalMethod: removalMethod(for: source))
    ]

    let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
    let roots: [(String, URL, SafeUninstallCandidateType)] = [
      (
        "Application Support", library.appendingPathComponent("Application Support"),
        .applicationSupport
      ),
      ("Preferences", library.appendingPathComponent("Preferences"), .preference),
      ("Caches", library.appendingPathComponent("Caches"), .cache),
      ("Logs", library.appendingPathComponent("Logs"), .log),
      (
        "Saved Application State", library.appendingPathComponent("Saved Application State"),
        .savedState
      ),
      ("LaunchAgents", library.appendingPathComponent("LaunchAgents"), .launchAgent),
      ("WebKit", library.appendingPathComponent("WebKit"), .webData),
      ("HTTPStorages", library.appendingPathComponent("HTTPStorages"), .httpStorage),
      ("Cookies", library.appendingPathComponent("Cookies"), .cookie),
      (
        "CrashReporter", library.appendingPathComponent("Application Support/CrashReporter"),
        .crashReport
      ),
      ("Containers", library.appendingPathComponent("Containers"), .container),
      ("Group Containers", library.appendingPathComponent("Group Containers"), .groupContainer),
    ]
    var scanRoots: [SafeUninstallScanRoot] = []
    var seen = Set<String>()
    for (rootName, root, type) in roots {
      do {
        let children = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
          ],
          options: [.skipsHiddenFiles])
        scanRoots.append(
          SafeUninstallScanRoot(name: rootName, path: root.path, state: .scanned))
        for child in children {
          let launchAgentMatches =
            type == .launchAgent
            ? launchAgent(child, references: bundleID) : false
          guard
            SafeUninstallPathPolicy.isRelatedCandidate(
              candidateName: child.lastPathComponent,
              bundleIdentifier: bundleID,
              appName: appName,
              candidateType: type,
              launchAgentReferencesTarget: launchAgentMatches)
          else { continue }
          let classification = SafeUninstallPathPolicy.classifyOwnership(
            candidateName: child.lastPathComponent,
            bundleIdentifier: bundleID,
            appName: appName,
            candidateType: type,
            launchAgentReferencesTarget: launchAgentMatches)
          let standardized = child.standardizedFileURL.path
          guard seen.insert(standardized).inserted else { continue }
          guard let candidateIdentity = try? SafeUninstallFileIdentity.capture(at: child) else {
            continue
          }
          let symlink: SafeUninstallSymlinkState =
            candidateIdentity.isSymbolicLink
            ? .symbolicLink : (candidateIdentity.isAliasFile ? .alias : .regular)
          let protectedByLink = symlink != .regular
          let permissionState: SafeUninstallPermissionState
          if type == .container,
            classification.confidence == .confirmed,
            candidateIdentity.standardizedPath.lowercased().hasSuffix(
              "/containers/\(bundleID.lowercased())")
          {
            permissionState = .systemAuthorization
          } else if candidateIdentity.isWritable {
            permissionState = .readable
          } else {
            permissionState = .unreadable
          }
          candidates.append(
            SafeUninstallCandidate(
              id: "residual:\(candidateIdentity.fileResourceIdentifier)",
              operationID: operationID,
              originalURL: child.path,
              standardizedURL: standardized,
              expectedIdentity: candidateIdentity,
              type: type,
              size: allocatedSize(for: child),
              ownershipConfidence: protectedByLink ? .sharedOrUnknown : classification.confidence,
              ownershipEvidence: protectedByLink
                ? "候选是符号链接或别名，不跟随处理。"
                : classification.reason,
              riskLevel: protectedByLink ? .protected : classification.risk,
              defaultSelected: protectedByLink || !source.supportsPhaseOneRemoval
                || permissionState == .unreadable || permissionState == .unknown
                ? false : classification.selected,
              selectionReason: protectedByLink
                ? "链接对象锁定保留。"
                : classification.reason,
              sourceKind: source,
              permissionState: permissionState,
              symlinkState: symlink,
              supportedRemovalMethod: protectedByLink || !source.supportsPhaseOneRemoval
                ? .preserve : .moveToTrash))
        }
      } catch {
        scanRoots.append(
          SafeUninstallScanRoot(
            name: rootName,
            path: root.path,
            state: .unreadable("该范围未扫描：权限不足或目录不可读。")))
      }
    }

    let revisionMaterial = ([identity.fileResourceIdentifier] + candidates.map(\.id)).joined(
      separator: "|")
    return SafeUninstallReview(
      operationID: operationID,
      target: target,
      candidates: candidates,
      scanRoots: scanRoots,
      reviewRevision: SafeUninstallPathPolicy.stableRevision(revisionMaterial))
  }

  private func sourceKind(
    for appURL: URL,
    identity: SafeUninstallFileIdentity
  ) -> SafeUninstallSourceKind {
    if appURL.path.hasPrefix("/System/") { return .systemApplication }
    if !identity.isLocalVolume || identity.isReadOnlyVolume {
      return .externalOrReadOnlyVolume
    }
    let resolvedPath = appURL.resolvingSymlinksInPath().path
    if appURL.path.contains("/Caskroom/")
      || (identity.isSymbolicLink && resolvedPath.contains("/Caskroom/"))
    {
      return .homebrewCask
    }
    if identity.isSymbolicLink || identity.isAliasFile { return .unknown }
    if fileManager.fileExists(
      atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    {
      return .appStore
    }
    if containsOfficialUninstaller(appURL) { return .officialUninstaller }
    if containsProtectedExtension(appURL) { return .helperOrExtension }
    return .ordinaryApplication
  }

  private func removalMethod(for source: SafeUninstallSourceKind) -> SafeUninstallRemovalMethod {
    switch source {
    case .ordinaryApplication, .appStore: return .moveToTrash
    case .homebrewCask: return .homebrew
    case .packageReceipt, .officialUninstaller: return .officialUninstaller
    default: return .unsupported
    }
  }

  private func containsOfficialUninstaller(_ appURL: URL) -> Bool {
    let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    guard let names = try? fileManager.contentsOfDirectory(atPath: resources.path) else {
      return false
    }
    return names.contains { $0.lowercased().contains("uninstall") }
  }

  private func containsProtectedExtension(_ appURL: URL) -> Bool {
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    return ["Library/SystemExtensions", "Library/LoginItems", "Library/LaunchServices"].contains {
      fileManager.fileExists(atPath: contents.appendingPathComponent($0).path)
    }
  }

  private func launchAgent(_ url: URL, references bundleIdentifier: String) -> Bool {
    guard !bundleIdentifier.isEmpty,
      let data = fileManager.contents(atPath: url.path),
      let text = String(data: data, encoding: .utf8)
    else { return false }
    return text.contains(bundleIdentifier)
  }

  private func allocatedSize(for url: URL) -> Int64? {
    guard
      let values = try? url.resourceValues(
        forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
    else { return nil }
    return [values.totalFileAllocatedSize, values.fileAllocatedSize, values.fileSize]
      .compactMap { $0 }
      .map(Int64.init)
      .first
  }
}

enum SafeUninstallScanError: Error, LocalizedError {
  case blocked(String)

  var errorDescription: String? {
    switch self {
    case .blocked(let reason): return reason
    }
  }
}

enum SafeUninstallRuntimeGate {
  // build 75: enabled only for confirmed ordinary/MAS apps after two identity checks.
  static let realFileExecutionEnabled = true
}

enum LauncherUninstallFlowStage: String, Codable {
  case checking
  case review
  case exitingApplication
  case waitingForForceQuitConfirmation
  case movingToTrash
  case restoring
  case completed
  case failed
  case cancelled

  var statusText: String {
    switch self {
    case .checking: return "正在检查"
    case .review: return "检查完成"
    case .exitingApplication: return "正在退出 App"
    case .waitingForForceQuitConfirmation: return "App 仍在运行"
    case .movingToTrash: return "正在移到废纸篓"
    case .restoring: return "正在恢复"
    case .completed: return "已完成"
    case .failed: return "失败，可重试"
    case .cancelled: return "已取消"
    }
  }

  var isBusy: Bool {
    [.checking, .exitingApplication, .movingToTrash, .restoring].contains(self)
  }
}

struct LauncherUninstallPresentation: Identifiable {
  let id: String
  let app: LauncherApp
  var stage: LauncherUninstallFlowStage
  var message: String
  var review: SafeUninstallReview?
  var selectedCandidateIDs: Set<String>
  var movedCount: Int
  var errorCode: String?
  var transaction: SafeUninstallTransaction?

  var canRestore: Bool {
    transaction?.items.contains(where: { $0.state == .moved }) == true
  }

  static func checking(app: LauncherApp) -> LauncherUninstallPresentation {
    LauncherUninstallPresentation(
      id: UUID().uuidString,
      app: app,
      stage: .checking,
      message: "正在识别安装来源并检查可安全处理的项目。",
      review: nil,
      selectedCandidateIDs: [],
      movedCount: 0,
      errorCode: nil,
      transaction: nil)
  }
}
