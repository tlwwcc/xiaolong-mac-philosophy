import Combine
import Foundation

@MainActor
final class PDFViewerShortcutStore: ObservableObject {
  @Published private(set) var configuration: PDFViewerShortcutConfiguration

  private let defaults: UserDefaults
  private let storageKey: String
  private var configurationRestoreObserver: AnyCancellable?

  init(
    defaults: UserDefaults,
    storageKey: String = "pdfViewerShortcutConfigurationV1"
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.configuration = PDFViewerShortcutConfiguration()
    reload()
    configurationRestoreObserver = NotificationCenter.default.publisher(
      for: Notification.Name("AIXLGManagedConfigurationDidRestore")
    ).receive(on: RunLoop.main).sink { [weak self] _ in
      self?.reload()
    }
  }

  func reload() {
    if let data = defaults.data(forKey: storageKey) {
      if let decoded = try? JSONDecoder().decode(
        PDFViewerShortcutConfiguration.self,
        from: data)
      {
        if !decoded.deletedActionIDs.isEmpty,
          defaults.data(forKey: "\(storageKey).beforeBuiltInProtectionV2") == nil
        {
          defaults.set(data, forKey: "\(storageKey).beforeBuiltInProtectionV2")
        }
        let sanitized = decoded.sanitized()
        self.configuration = sanitized
        if sanitized != decoded {
          if sanitized.overrides.isEmpty && sanitized.deletedActionIDs.isEmpty {
            defaults.removeObject(forKey: storageKey)
          } else if let sanitizedData = try? JSONEncoder().encode(sanitized) {
            defaults.set(sanitizedData, forKey: storageKey)
          }
        }
      } else {
        self.configuration = PDFViewerShortcutConfiguration()
        defaults.removeObject(forKey: storageKey)
      }
    } else {
      self.configuration = PDFViewerShortcutConfiguration()
    }
  }

  func shortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcut {
    configuration.shortcut(for: action)
  }

  func activeShortcut(for action: PDFViewerShortcutAction) -> PDFViewerShortcut? {
    configuration.activeShortcut(for: action)
  }

  func isDeleted(_ action: PDFViewerShortcutAction) -> Bool {
    configuration.isDeleted(action)
  }

  @discardableResult
  func update(
    _ shortcut: PDFViewerShortcut,
    for action: PDFViewerShortcutAction
  ) -> PDFViewerShortcutValidationError? {
    do {
      configuration = try configuration.setting(shortcut, for: action)
      persist()
      return nil
    } catch let error as PDFViewerShortcutValidationError {
      return error
    } catch {
      return .unsupportedKey
    }
  }

  @discardableResult
  func reset(_ action: PDFViewerShortcutAction) -> PDFViewerShortcutValidationError? {
    do {
      configuration = try configuration.resetting(action)
      persist()
      return nil
    } catch let error as PDFViewerShortcutValidationError {
      return error
    } catch {
      return .unsupportedKey
    }
  }

  func delete(_ action: PDFViewerShortcutAction) {
    configuration = configuration.deleting(action)
    persist()
  }

  func restoreDeleted(_ action: PDFViewerShortcutAction) {
    configuration = configuration.restoringDeleted(action)
    persist()
  }

  func restoreAllDeleted() {
    configuration = configuration.restoringAllDeleted()
    persist()
  }

  func resetAll() {
    configuration = PDFViewerShortcutConfiguration()
    defaults.removeObject(forKey: storageKey)
  }

  var hasCustomShortcuts: Bool {
    !configuration.overrides.isEmpty
  }

  var hasChanges: Bool {
    hasCustomShortcuts || !configuration.deletedActionIDs.isEmpty
  }

  var activeShortcutCount: Int {
    PDFViewerShortcutAction.allCases.count - configuration.deletedActionIDs.count
  }

  var deletedShortcutCount: Int {
    configuration.deletedActionIDs.count
  }

  private func persist() {
    guard !configuration.overrides.isEmpty || !configuration.deletedActionIDs.isEmpty else {
      defaults.removeObject(forKey: storageKey)
      return
    }
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    defaults.set(data, forKey: storageKey)
  }
}
