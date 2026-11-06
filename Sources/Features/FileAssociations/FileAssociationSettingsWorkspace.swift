import Combine
import Foundation

@MainActor
struct FileAssociationOperations {
  var status: (AssociatedFileKind) throws -> FileAssociationStatus
  var setDefault: (AssociatedFileKind) async throws -> FileAssociationChangeResult
  var restore: (AssociatedFileKind) async throws -> FileAssociationChangeResult

  static func live() throws -> Self {
    let manager = try FileAssociationManager()
    return Self(
      status: { try manager.currentStatus(for: $0) },
      setDefault: { kind in
        guard kind == .pdf else { throw FileAssociationError.noPreviousHandler(kind: kind) }
        manager.pdfRoute = .pijuanReading
        return try await manager.setAsDefault(for: kind)
      },
      restore: { try await manager.restorePreviousHandler(for: $0) })
  }
}

/// Owns association presentation and one explicit user transaction at a time.
/// The manager retains its backup-before-write and rollback guarantees.
@MainActor
final class FileAssociationSettingsWorkspace: ObservableObject {
  @Published private(set) var pdfFileAssociationCoverage: FileAssociationStatus.Coverage = .none
  @Published private(set) var audioFileAssociationCoverage: FileAssociationStatus.Coverage = .none
  @Published private(set) var pdfFileAssociationCanRestore = false
  @Published private(set) var audioFileAssociationCanRestore = false
  @Published private(set) var fileAssociationBusyKind: AssociatedFileKind?
  @Published private(set) var fileAssociationFeedbackKind: AssociatedFileKind?
  @Published private(set) var fileAssociationFeedbackText = ""
  var onStatus: ((String) -> Void)?

  private let allowed: @MainActor () -> Bool
  private let makeOperations: @MainActor () throws -> FileAssociationOperations
  private var operationsStorage: FileAssociationOperations?
  private var operationID: UUID?
  private var task: Task<Void, Never>?
  private var stopped = false

  init(
    changesAllowed: @escaping @MainActor () -> Bool,
    makeOperations: (@MainActor () throws -> FileAssociationOperations)? = nil
  ) {
    self.allowed = changesAllowed
    self.makeOperations = makeOperations ?? { try .live() }
  }

  var changesAllowed: Bool {
    guard !stopped else { return false }
    let value = allowed()
    return !stopped && value
  }
  var hasPendingTransaction: Bool { operationID != nil }

  func prepareForTermination() -> Bool {
    guard hasPendingTransaction else { return true }
    onStatus?("正在保存默认打开方式，请完成后再退出。")
    return false
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    operationID = nil
    task = nil
    fileAssociationBusyKind = nil
    // An issued macOS change cannot be revoked. Let the manager finish its atomic
    // transaction/rollback, but suppress all late UI delivery. Ordinary quit waits above.
  }

  func refreshFileAssociationStatus() {
    guard !stopped else { return }
    guard changesAllowed else {
      guard !stopped else { return }
      pdfFileAssociationCoverage = .none
      audioFileAssociationCoverage = .none
      pdfFileAssociationCanRestore = false
      audioFileAssociationCanRestore = false
      fileAssociationFeedbackText = "只有官网正式版安装到“应用程序”后才能设置；当前运行身份不会改动系统默认打开方式。"
      return
    }
    do {
      let operations = try operations()
      guard !stopped else { return }
      let pdf = try operations.status(.pdf)
      guard !stopped else { return }
      let audio = try operations.status(.audio)
      guard !stopped else { return }
      pdfFileAssociationCoverage = pdf.coverage
      audioFileAssociationCoverage = audio.coverage
      pdfFileAssociationCanRestore = pdf.canRestorePreviousHandler
      audioFileAssociationCanRestore = audio.canRestorePreviousHandler
      if fileAssociationFeedbackText.hasPrefix("安装到")
        || fileAssociationFeedbackText.hasPrefix("只有官网正式版") {
        fileAssociationFeedbackText = ""
      }
    } catch {
      guard !stopped else { return }
      fileAssociationFeedbackText = error.localizedDescription
    }
  }

  func setAsDefaultApplication(for kind: AssociatedFileKind) {
    guard kind == .pdf else { return }
    begin(kind: kind, restoring: false)
  }

  func restorePreviousDefaultApplication(for kind: AssociatedFileKind) {
    begin(kind: kind, restoring: true)
  }

  private func begin(kind: AssociatedFileKind, restoring: Bool) {
    guard !stopped, operationID == nil else { return }
    guard changesAllowed else { refreshFileAssociationStatus(); return }
    let owner = UUID()
    operationID = owner
    fileAssociationBusyKind = kind
    fileAssociationFeedbackKind = kind
    fileAssociationFeedbackText = restoring
      ? "正在恢复\(kind.displayName)原来的打开方式…"
      : "正在请求 macOS 更新\(kind.displayName)打开方式…"
    task = Task { @MainActor [weak self] in
      guard let self, self.owns(owner) else { return }
      defer {
        if self.owns(owner) {
          self.operationID = nil
          self.task = nil
          self.fileAssociationBusyKind = nil
        }
      }
      guard self.changesAllowed else { self.refreshFileAssociationStatus(); return }
      do {
        let operations = try self.operations()
        guard self.owns(owner), self.changesAllowed else { return }
        let result: FileAssociationChangeResult
        if restoring { result = try await operations.restore(kind) }
        else { result = try await operations.setDefault(kind) }
        guard self.owns(owner) else { return }
        self.fileAssociationFeedbackText = restoring
          ? "已恢复 \(kind.displayName) 原来的默认打开方式。"
          : (result.changedContentTypeIdentifiers.isEmpty
              ? "\(kind.displayName) 已经由本 App 打开。"
              : "已设为 \(kind.displayName) 默认打开方式；原应用已安全记住，可随时恢复。")
        self.refreshFileAssociationStatus()
        guard self.owns(owner) else { return }
        self.onStatus?(self.fileAssociationFeedbackText)
      } catch {
        guard self.owns(owner) else { return }
        self.fileAssociationFeedbackText = error.localizedDescription
        self.onStatus?(self.fileAssociationFeedbackText)
      }
    }
  }

  private func owns(_ owner: UUID) -> Bool { !stopped && operationID == owner }

  private func operations() throws -> FileAssociationOperations {
    if let operationsStorage { return operationsStorage }
    let operations = try makeOperations()
    operationsStorage = operations
    return operations
  }
}
