import Combine
import Foundation

/// A restore is a coordinated, backed-up multi-file operation. Once applying starts,
/// it must finish or compensate before the app may exit; cancellation is not rollback.
@MainActor
final class ConfigRestoreCoordinator: ObservableObject {
  enum Phase: Equatable { case idle, queued, applying }
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var failureMessage: String?
  @Published private(set) var lastBackupURL: URL?
  private(set) var isStopped = false
  var isRestoring: Bool { ownerID != nil || isTransitioning }
  var acceptsOrdinaryWrites: Bool { !isStopped && !isRestoring }

  private let makeRequest: @MainActor (UUID) throws -> XLGConfigImportRequest
  private let release: @MainActor (UUID) -> Void
  private let performImport: @MainActor (XLGConfigImportRequest) async throws -> XLGConfigImportResult
  private let onSuccess: @MainActor (XLGConfigImportResult) -> Void
  private let onFailure: @MainActor (String) -> Void
  private var isTransitioning = false
  private var ownerID: UUID?
  private var task: Task<Void, Never>?

  init(
    makeRequest: @escaping @MainActor (UUID) throws -> XLGConfigImportRequest,
    release: @escaping @MainActor (UUID) -> Void,
    performImport: @escaping @MainActor (XLGConfigImportRequest) async throws -> XLGConfigImportResult = {
      try await XLGConfigImporter.importRecommendedConfig(request: $0)
    },
    onSuccess: @escaping @MainActor (XLGConfigImportResult) -> Void = { _ in },
    onFailure: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.makeRequest = makeRequest
    self.release = release
    self.performImport = performImport
    self.onSuccess = onSuccess
    self.onFailure = onFailure
  }

  func beginRestore() {
    guard !isStopped, ownerID == nil, !isTransitioning else { return }
    isTransitioning = true
    let owner = UUID()
    ownerID = owner
    failureMessage = nil
    phase = .queued
    isTransitioning = false
    task = Task { @MainActor [weak self] in
      guard let self, !self.isStopped, self.ownerID == owner, !Task.isCancelled else { return }
      self.isTransitioning = true
      self.phase = .applying
      self.isTransitioning = false
      do {
        let request = try self.makeRequest(owner)
        let result = try await self.performImport(request)
        self.complete(owner: owner, result: .success(result))
      } catch {
        self.complete(owner: owner, result: .failure(error))
      }
    }
  }

  /// The host cancels termination while applying, including while compensation runs.
  func prepareForTermination() -> Bool {
    guard !isTransitioning, phase != .applying else { return false }
    cancelQueuedRestore()
    return true
  }

  @discardableResult
  func shutdown() -> Bool {
    guard prepareForTermination() else { return false }
    isStopped = true
    return true
  }

  private func cancelQueuedRestore() {
    guard phase == .queued, let owner = ownerID else { return }
    isTransitioning = true
    ownerID = nil
    task?.cancel()
    task = nil
    release(owner)
    phase = .idle
    isTransitioning = false
  }

  private func complete(owner: UUID, result: Result<XLGConfigImportResult, Error>) {
    guard ownerID == owner, !isStopped else { return }
    isTransitioning = true
    task = nil
    switch result {
    case .success(let imported):
      lastBackupURL = imported.backupURL
      failureMessage = nil
    case .failure(let error):
      if case XLGConfigImportError.failedWithBackup(_, let backupURL) = error {
        lastBackupURL = backupURL
      }
      failureMessage = error.localizedDescription
    }
    release(owner)
    // The service lease is released for the host's synchronous projection reload, while
    // this coordinator still rejects ordinary UI writes, another restore, and termination.
    // Published callbacks cannot start a new owner before the old completion has finished.
    switch result {
    case .success(let imported): onSuccess(imported)
    case .failure(let error): onFailure(error.localizedDescription)
    }
    ownerID = nil
    phase = .idle
    isTransitioning = false
  }
}
