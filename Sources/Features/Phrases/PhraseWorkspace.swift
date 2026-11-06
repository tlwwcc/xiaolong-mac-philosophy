import Combine
import Foundation
import MacAutomationCore
import SwiftUI

/// Owns phrase editing and persistence. Global input monitoring remains with the application.
@MainActor
final class PhraseWorkspace: ObservableObject {
  @Published var phrases: [PhraseItem] = [] {
    didSet {
      if !isLoading, phrases != oldValue { hasUnsavedChanges = true }
    }
  }
  @Published var selectedPhraseID: String?
  @Published private(set) var hasUnsavedChanges = false
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var backupURL: URL?
  private(set) var committedPhrases: [PhraseItem] = []
  private(set) var lastFailure: Error?

  var onReload: (() -> Void)?
  var onStatus: ((String) -> Void)?
  var onRecoveryChanged: (() -> Void)?

  private let store: ConfigurationTransactionStore
  private let saveDelayNanoseconds: UInt64
  private var snapshot: ConfigurationSnapshot?
  private var recoverySnapshot: ConfigurationSnapshot?
  private var saveTask: Task<Void, Never>?
  private var saveGeneration: UInt64 = 0
  private var saveNeedsReload = false
  private var isLoading = false

  init(fileURL: URL, saveDelayNanoseconds: UInt64 = 350_000_000) {
    store = ConfigurationTransactionStore(fileURL: fileURL)
    self.saveDelayNanoseconds = saveDelayNanoseconds
  }

  var revision: String? { snapshot?.revision }

  /// The visible recovery action also refreshes input, only after a successful validated load.
  @discardableResult
  func reloadFromDisk(discardPendingChanges: Bool = false) -> Bool {
    guard load(discardPendingChanges: discardPendingChanges) else { return false }
    onReload?()
    return true
  }

  /// A normal reload first preserves edits. Explicit restore may discard the old in-memory draft.
  @discardableResult
  func load(discardPendingChanges: Bool = false) -> Bool {
    if !discardPendingChanges, hasUnsavedChanges, !flushPendingSave() { return false }
    cancelScheduledSave()
    saveNeedsReload = false
    snapshot = nil
    recoverySnapshot = nil
    backupURL = nil
    lastFailure = nil
    do {
      try store.recover()
      let loaded = try store.read()
      if loaded.exists {
        let values: [PhraseItem]
        do {
          values = try Self.decode(loaded.data)
        } catch {
          // Only bounded regular-file bytes become a recoverable baseline.
          recoverySnapshot = loaded
          throw error
        }
        snapshot = loaded
        replaceLoadedPhrases(values)
        setRecoveryMessage(nil)
      } else {
        snapshot = loaded
        replaceLoadedPhrases(defaultPhrases())
        setRecoveryMessage(nil)
        // Preserve the established first-run empty-file behavior through the shared writer.
        hasUnsavedChanges = true
        return saveOnly()
      }
      return true
    } catch {
      replaceLoadedPhrases(defaultPhrases())
      lastFailure = error
      setRecoveryMessage(
        recoverySnapshot == nil
          ? "快捷短语暂时无法读取，已暂停保存。原文件保持不变，请检查配置文件夹。"
          : "快捷短语读取失败，当前使用默认值。原文件已保护，保存前会先备份。")
      onStatus?("快捷短语读取失败，原文件已保护：\(error.localizedDescription)")
      return false
    }
  }

  func bindingForPhrase(id: String) -> Binding<PhraseItem>? {
    guard phrases.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { [weak self] in
        self?.phrases.first(where: { $0.id == id })
          ?? PhraseItem(id: id, trigger: "", output: "", enabled: false, note: "")
      },
      set: { [weak self] value in
        guard let self, value.id == id,
          let index = self.phrases.firstIndex(where: { $0.id == id })
        else { return }
        self.phrases[index] = value
      })
  }

  @discardableResult
  func saveOnly() -> Bool {
    guard let baseline = snapshot ?? recoverySnapshot else {
      return reportSaveFailure(AutomationError(
        code: "configuration_unavailable", message: "快捷短语尚未成功读取，已暂停保存。"))
    }
    do {
      let data = try Self.encode(phrases)
      let receipt = try store.commit(
        requestID: "phrases-gui-\(UUID().uuidString)",
        requestData: Data(ConfigurationTransactionStore.revision(for: data).utf8),
        expectedRevision: baseline.revision,
        replacement: data)
      do {
        let current = try store.read()
        guard current.revision == receipt.afterRevision else {
          throw AutomationError(code: "revision_conflict", message: "保存后快捷短语又发生了变化。")
        }
        let verified = try Self.decode(current.data)
        snapshot = current
        committedPhrases = verified
      } catch {
        snapshot = nil
        recoverySnapshot = nil
        throw AutomationError(
          code: "transaction_unknown",
          message: "快捷短语已提交，但无法核实当前内容。已暂停保存，请重新读取配置。",
          details: ["requestId": .string(receipt.requestID)])
      }
      if recoverySnapshot != nil {
        backupURL = receipt.backupURL
        setRecoveryMessage("原快捷短语已备份，可从配置文件夹的事务备份中找回。")
      } else if lastFailure != nil {
        setRecoveryMessage(nil)
      }
      recoverySnapshot = nil
      hasUnsavedChanges = false
      lastFailure = nil
      return true
    } catch {
      return reportSaveFailure(error)
    }
  }

  @discardableResult
  func saveAndReload() -> Bool {
    cancelScheduledSave()
    saveNeedsReload = true
    return persistPendingSave(reload: true)
  }

  func scheduleSave(reload: Bool) {
    saveNeedsReload = saveNeedsReload || reload
    cancelScheduledSave()
    let generation = saveGeneration
    let delay = saveDelayNanoseconds
    saveTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, self.saveGeneration == generation, !Task.isCancelled else { return }
      self.saveTask = nil
      _ = self.persistPendingSave(reload: self.saveNeedsReload)
    }
  }

  /// Synchronous on the main actor so termination cannot outrun the final keystroke.
  /// Failed writes remain dirty and can be retried; a failure never updates the expander.
  @discardableResult
  func flushPendingSave(reload: Bool = false) -> Bool {
    let hadPendingSave = saveTask != nil
    cancelScheduledSave()
    guard hasUnsavedChanges || hadPendingSave else { return true }
    return persistPendingSave(reload: reload && saveNeedsReload)
  }

  @discardableResult
  func shutdown() -> Bool {
    flushPendingSave(reload: false)
  }

  func addPhrase() {
    let item = PhraseItem(
      id: UUID().uuidString, trigger: "ppdz", output: "通讯地址", enabled: true, note: "")
    phrases.append(item)
    selectedPhraseID = item.id
    _ = saveAndReload()
  }

  func deleteSelectedPhrase() {
    guard let selectedPhraseID,
      let index = phrases.firstIndex(where: { $0.id == selectedPhraseID })
    else { return }
    let nextID: String?
    if phrases.indices.contains(index + 1) {
      nextID = phrases[index + 1].id
    } else if phrases.indices.contains(index - 1) {
      nextID = phrases[index - 1].id
    } else {
      nextID = nil
    }
    // SwiftUI may retain a row's binding until the update finishes. Clear selection first.
    self.selectedPhraseID = nil
    phrases.remove(at: index)
    self.selectedPhraseID = nextID ?? phrases.first?.id
    _ = saveAndReload()
  }

  private func replaceLoadedPhrases(_ values: [PhraseItem]) {
    isLoading = true
    phrases = values
    isLoading = false
    committedPhrases = values
    selectedPhraseID = values.first?.id
    hasUnsavedChanges = false
  }

  private func cancelScheduledSave() {
    saveGeneration &+= 1
    saveTask?.cancel()
    saveTask = nil
  }

  private func persistPendingSave(reload: Bool) -> Bool {
    guard saveOnly() else { return false }
    saveNeedsReload = false
    if reload { onReload?() }
    return true
  }

  private func reportSaveFailure(_ error: Error) -> Bool {
    lastFailure = error
    if let failure = error as? AutomationError, failure.code == "revision_conflict" {
      setRecoveryMessage("快捷短语已在外部修改，已暂停保存。当前编辑仍保留，请先重新读取后再决定。")
    } else if let failure = error as? AutomationError, failure.code == "transaction_unknown" {
      setRecoveryMessage("快捷短语已提交，但当前内容尚未核实，已暂停保存。请重新读取配置。")
    } else if recoverySnapshot != nil {
      setRecoveryMessage("原快捷短语暂时无法安全备份，已暂停保存，避免覆盖。请检查配置文件夹。")
    } else {
      setRecoveryMessage("快捷短语尚未保存，当前编辑仍保留。可先复制当前短语，再重新读取配置。")
    }
    onStatus?("快捷短语保存失败：\(error.localizedDescription)")
    return false
  }

  private func setRecoveryMessage(_ message: String?) {
    recoveryMessage = message
    onRecoveryChanged?()
  }

  private static func encode(_ values: [PhraseItem]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(values)
    _ = try decode(data)
    return data
  }

  private static func decode(_ data: Data) throws -> [PhraseItem] {
    try LocalConfigurationFileCodec.decodeArray(
      PhraseItem.self, from: data, allowedKeys: ["id", "trigger", "output", "enabled", "note"]
    ) { phrases in
      var seen = Set<String>()
      for phrase in phrases {
        guard !phrase.id.isEmpty, seen.insert(phrase.id).inserted,
          phrase.id.utf8.count <= 256,
          phrase.trigger.utf8.count <= 256,
          phrase.output.utf8.count <= LocalConfigurationFileCodec.maximumStringBytes,
          phrase.note.utf8.count <= 32_768
        else { throw LocalConfigurationReadError.invalidRecord }
      }
    }
  }
}
