import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

enum PDFFileOpenRoute: String, CaseIterable, Codable, Sendable {
  case pijuanReading
}

enum AudioFileOpenRoute: String, CaseIterable, Codable, Sendable {
  case tinglan
  case keepSystemDefault
}

enum AssociatedFileKind: String, CaseIterable, Codable, Sendable {
  case pdf
  case audio

  var displayName: String {
    switch self {
    case .pdf: return "PDF"
    case .audio: return "音频"
    }
  }

  var contentTypes: [UTType] {
    switch self {
    case .pdf:
      return [.pdf]
    case .audio:
      return [.mp3, .mpeg4Audio, .wav]
    }
  }
}

enum FileOpenDestination: String, Codable, Sendable {
  case pijuan
  case tinglanAudio
  case keepSystemDefault
  case unsupported
}

struct FileOpenRouteDecision: Equatable, Sendable {
  let originalURL: URL
  let standardizedURL: URL
  let kind: AssociatedFileKind?
  let destination: FileOpenDestination
}

enum FileOpenBatchValidation: Equatable, Sendable {
  case accepted
  case tooManyPDFs(count: Int)

  var customerMessage: String? {
    switch self {
    case .accepted:
      return nil
    case .tooManyPDFs(let count):
      return "披卷当前一次打开一个 PDF；这次选择了 \(count) 个，请逐个打开。"
    }
  }
}

/// Runtime-only authorization for the system-wide default-handler write path.
///
/// Compile-time release flags and an `/Applications` path are necessary but insufficient: a
/// locally signed or ad-hoc build can otherwise reproduce both. The write button is enabled only
/// when the running process and every architecture of its static code satisfy the stable
/// Developer ID requirement and exact Team ID.
enum FileAssociationRuntimeAuthorization {
  static let stableRequirementText =
    "identifier \"\(AppRuntimeIdentity.stableBundleIdentifier)\""
    + " and anchor apple generic"
    + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
    + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    + " and certificate leaf[subject.OU] = \(AppRuntimeIdentity.stableDeveloperTeamIdentifier)"

  static let currentProcessIsTrustedStableRelease = validateCurrentProcess()

  private static func validateCurrentProcess() -> Bool {
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        stableRequirementText as CFString,
        SecCSFlags(rawValue: 0),
        &requirement) == errSecSuccess,
      let requirement
    else { return false }

    var dynamicCode: SecCode?
    guard
      SecCodeCopySelf(SecCSFlags(rawValue: 0), &dynamicCode) == errSecSuccess,
      let dynamicCode,
      SecCodeCheckValidityWithErrors(
        dynamicCode,
        SecCSFlags(rawValue: 0),
        requirement,
        nil) == errSecSuccess
    else { return false }

    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(
        dynamicCode,
        SecCSFlags(rawValue: kSecCSUseAllArchitectures),
        &staticCode) == errSecSuccess,
      let staticCode
    else { return false }

    let strictFlags = SecCSFlags(
      rawValue: UInt32(
        kSecCSCheckAllArchitectures
          | kSecCSCheckNestedCode
          | kSecCSStrictValidate))
    guard
      SecStaticCodeCheckValidityWithErrors(
        staticCode,
        strictFlags,
        requirement,
        nil) == errSecSuccess
    else { return false }

    var signingInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &signingInformation) == errSecSuccess,
      let signingInformation,
      (signingInformation as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String
        == AppRuntimeIdentity.stableDeveloperTeamIdentifier
    else { return false }
    return true
  }
}

struct FileAssociationApplicationIdentity: Codable, Equatable, Sendable {
  let bundleIdentifier: String?
  let bundlePath: String

  var applicationURL: URL {
    URL(fileURLWithPath: bundlePath, isDirectory: true).standardizedFileURL
  }

  func matches(_ other: Self) -> Bool {
    if let bundleIdentifier, let otherBundleIdentifier = other.bundleIdentifier {
      return bundleIdentifier == otherBundleIdentifier
    }
    return applicationURL == other.applicationURL
  }
}

struct FileAssociationHandlerState: Equatable, Sendable {
  let contentTypeIdentifier: String
  let application: FileAssociationApplicationIdentity?
  let isHostApplication: Bool
}

struct FileAssociationStatus: Equatable, Sendable {
  enum Coverage: String, Codable, Sendable {
    case none
    case partial
    case all
  }

  let kind: AssociatedFileKind
  let handlers: [FileAssociationHandlerState]
  let canRestorePreviousHandler: Bool

  var coverage: Coverage {
    let matchingCount = handlers.filter(\.isHostApplication).count
    if matchingCount == 0 { return .none }
    if matchingCount == handlers.count { return .all }
    return .partial
  }
}

struct FileAssociationChangeResult: Equatable, Sendable {
  enum Action: String, Codable, Sendable {
    case setAsDefault
    case restorePreviousHandler
  }

  let action: Action
  let kind: AssociatedFileKind
  let changedContentTypeIdentifiers: [String]
  let unchangedContentTypeIdentifiers: [String]
}

enum FileAssociationError: LocalizedError, Equatable {
  case hostIsNotApplicationBundle(String)
  case hostBundleIdentifierMissing
  case previousHandlerUnavailable(kind: AssociatedFileKind, contentType: String)
  case storedPreviousHandlersUnreadable
  case noPreviousHandler(kind: AssociatedFileKind)
  case previousApplicationUnavailable(bundleIdentifier: String?, path: String)
  case changeFailed(
    action: FileAssociationChangeResult.Action,
    kind: AssociatedFileKind,
    contentType: String,
    reason: String,
    rollbackFailures: [String]
  )

  var errorDescription: String? {
    switch self {
    case .hostIsNotApplicationBundle(let path):
      return "当前运行位置不是完整 App，无法更改文件关联：\(path)"
    case .hostBundleIdentifierMissing:
      return "当前 App 缺少 Bundle Identifier，无法更改文件关联。"
    case .previousHandlerUnavailable(let kind, let contentType):
      return "系统未返回 \(kind.displayName)（\(contentType)）的原打开方式，为了确保可恢复，未作任何更改。"
    case .storedPreviousHandlersUnreadable:
      return "之前的文件关联备份无法读取，未作任何系统更改。"
    case .noPreviousHandler(let kind):
      return "没有可恢复的 \(kind.displayName) 原打开方式。"
    case .previousApplicationUnavailable(let bundleIdentifier, let path):
      let identity = bundleIdentifier.map { "\($0)，\(path)" } ?? path
      return "原打开应用已移动或删除，暂时无法恢复：\(identity)"
    case .changeFailed(let action, let kind, let contentType, let reason, let failures):
      let verb = action == .setAsDefault ? "设为默认" : "恢复"
      let rollback =
        failures.isEmpty
        ? "已恢复变更前的状态。"
        : "回滚仍有异常：\(failures.joined(separator: "；"))"
      return "\(kind.displayName) \(verb)失败（\(contentType)）：\(reason)。\(rollback)"
    }
  }
}

@MainActor
protocol FileAssociationWorkspace: AnyObject {
  func defaultApplication(for contentType: UTType) -> FileAssociationApplicationIdentity?
  func resolveApplication(_ identity: FileAssociationApplicationIdentity) -> URL?
  func setDefaultApplication(
    at applicationURL: URL,
    for contentType: UTType,
    completionHandler: @escaping (Error?) -> Void
  )
}

@MainActor
final class SystemFileAssociationWorkspace: FileAssociationWorkspace {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace = .shared) {
    self.workspace = workspace
  }

  func defaultApplication(for contentType: UTType) -> FileAssociationApplicationIdentity? {
    guard let url = workspace.urlForApplication(toOpen: contentType) else { return nil }
    return Self.identity(for: url)
  }

  func resolveApplication(_ identity: FileAssociationApplicationIdentity) -> URL? {
    if let bundleIdentifier = identity.bundleIdentifier,
      let currentURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    {
      return currentURL.standardizedFileURL
    }

    let fallbackURL = identity.applicationURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: fallbackURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      fallbackURL.pathExtension.lowercased() == "app"
    else { return nil }
    return fallbackURL
  }

  func setDefaultApplication(
    at applicationURL: URL,
    for contentType: UTType,
    completionHandler: @escaping (Error?) -> Void
  ) {
    Task {
      do {
        try await workspace.setDefaultApplication(at: applicationURL, toOpen: contentType)
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
  }

  static func identity(for applicationURL: URL) -> FileAssociationApplicationIdentity {
    let standardizedURL = applicationURL.standardizedFileURL
    return FileAssociationApplicationIdentity(
      bundleIdentifier: Bundle(url: standardizedURL)?.bundleIdentifier,
      bundlePath: standardizedURL.path)
  }
}

@MainActor
final class FileAssociationManager {
  private let defaults: UserDefaults
  private let hostApplication: FileAssociationApplicationIdentity
  private let workspace: FileAssociationWorkspace

  private let pdfRouteKey = "file-association.pdf-route-v1"
  private let audioRouteKey = "file-association.audio-route-v1"
  private let previousHandlersKey = "file-association.previous-handlers-v1"

  convenience init(defaults: UserDefaults = .standard) throws {
    let bundleURL = Bundle.main.bundleURL.standardizedFileURL
    guard bundleURL.pathExtension.lowercased() == "app" else {
      throw FileAssociationError.hostIsNotApplicationBundle(bundleURL.path)
    }
    guard Bundle.main.bundleIdentifier != nil else {
      throw FileAssociationError.hostBundleIdentifierMissing
    }
    self.init(
      defaults: defaults,
      hostApplication: SystemFileAssociationWorkspace.identity(for: bundleURL),
      workspace: SystemFileAssociationWorkspace())
  }

  init(
    defaults: UserDefaults,
    hostApplication: FileAssociationApplicationIdentity,
    workspace: FileAssociationWorkspace
  ) {
    self.defaults = defaults
    self.hostApplication = hostApplication
    self.workspace = workspace
  }

  var pdfRoute: PDFFileOpenRoute {
    get {
      defaults.string(forKey: pdfRouteKey).flatMap(PDFFileOpenRoute.init(rawValue:))
        ?? .pijuanReading
    }
    set { defaults.set(newValue.rawValue, forKey: pdfRouteKey) }
  }

  var audioRoute: AudioFileOpenRoute {
    get {
      defaults.string(forKey: audioRouteKey).flatMap(AudioFileOpenRoute.init(rawValue:))
        ?? .keepSystemDefault
    }
    set { defaults.set(newValue.rawValue, forKey: audioRouteKey) }
  }

  func routingDecisions(for urls: [URL]) -> [FileOpenRouteDecision] {
    urls.map { originalURL in
      let standardizedURL =
        originalURL.isFileURL
        ? originalURL.standardizedFileURL
        : originalURL
      guard originalURL.isFileURL,
        let kind = Self.fileKind(for: standardizedURL)
      else {
        return FileOpenRouteDecision(
          originalURL: originalURL,
          standardizedURL: standardizedURL,
          kind: nil,
          destination: .unsupported)
      }

      let destination: FileOpenDestination
      switch kind {
      case .pdf:
        destination = .pijuan
      case .audio:
        destination = audioRoute == .tinglan ? .tinglanAudio : .keepSystemDefault
      }
      return FileOpenRouteDecision(
        originalURL: originalURL,
        standardizedURL: standardizedURL,
        kind: kind,
        destination: destination)
    }
  }

  static func validateOpenBatch(_ urls: [URL]) -> FileOpenBatchValidation {
    let pdfCount = urls.reduce(into: 0) { count, url in
      if fileKind(for: url) == .pdf { count += 1 }
    }
    return pdfCount > 1 ? .tooManyPDFs(count: pdfCount) : .accepted
  }

  func currentStatus(for kind: AssociatedFileKind) throws -> FileAssociationStatus {
    let snapshots = try loadPreviousHandlers()
    let states = kind.contentTypes.map { contentType in
      let application = workspace.defaultApplication(for: contentType)
      return FileAssociationHandlerState(
        contentTypeIdentifier: contentType.identifier,
        application: application,
        isHostApplication: application?.matches(hostApplication) == true)
    }
    let prefix = "\(kind.rawValue)|"
    return FileAssociationStatus(
      kind: kind,
      handlers: states,
      canRestorePreviousHandler: states.contains { state in
        state.isHostApplication
          && snapshots["\(prefix)\(state.contentTypeIdentifier)"] != nil
      })
  }

  func setAsDefault(for kind: AssociatedFileKind) async throws
    -> FileAssociationChangeResult
  {
    guard hostApplication.applicationURL.pathExtension.lowercased() == "app" else {
      throw FileAssociationError.hostIsNotApplicationBundle(hostApplication.bundlePath)
    }
    guard hostApplication.bundleIdentifier != nil else {
      throw FileAssociationError.hostBundleIdentifierMissing
    }

    let originalSnapshots = try loadPreviousHandlers()
    var snapshots = originalSnapshots
    let types = kind.contentTypes
    var originals: [String: FileAssociationApplicationIdentity] = [:]
    var typesToChange: [UTType] = []
    var unchanged: [String] = []

    for contentType in types {
      let identifier = contentType.identifier
      if let current = workspace.defaultApplication(for: contentType),
        current.matches(hostApplication)
      {
        unchanged.append(identifier)
        continue
      }
      guard let current = workspace.defaultApplication(for: contentType) else {
        throw FileAssociationError.previousHandlerUnavailable(
          kind: kind,
          contentType: identifier)
      }
      originals[identifier] = current
      snapshots[storageKey(for: kind, contentTypeIdentifier: identifier)] = current
      typesToChange.append(contentType)
    }

    if !typesToChange.isEmpty {
      // Persist the recovery target before the first asynchronous system mutation.
      try savePreviousHandlers(snapshots)
    }

    var changed: [UTType] = []
    do {
      for contentType in typesToChange {
        try await changeDefaultApplication(
          to: hostApplication.applicationURL,
          for: contentType)
        changed.append(contentType)
      }
    } catch {
      var failures = await rollBack(
        changed.reversed(),
        destinations: originals)
      if failures.isEmpty {
        do {
          try savePreviousHandlers(originalSnapshots)
        } catch {
          failures.append("原关联已回滚，但恢复快照清理失败：\(error.localizedDescription)")
        }
      }
      throw FileAssociationError.changeFailed(
        action: .setAsDefault,
        kind: kind,
        contentType: typesToChange.dropFirst(changed.count).first?.identifier ?? "unknown",
        reason: error.localizedDescription,
        rollbackFailures: failures)
    }

    return FileAssociationChangeResult(
      action: .setAsDefault,
      kind: kind,
      changedContentTypeIdentifiers: changed.map(\.identifier),
      unchangedContentTypeIdentifiers: unchanged)
  }

  func restorePreviousHandler(for kind: AssociatedFileKind) async throws
    -> FileAssociationChangeResult
  {
    var snapshots = try loadPreviousHandlers()
    let entries: [(UTType, FileAssociationApplicationIdentity)] = kind.contentTypes.compactMap {
      contentType in
      let key = storageKey(for: kind, contentTypeIdentifier: contentType.identifier)
      return snapshots[key].map { (contentType, $0) }
    }
    guard !entries.isEmpty else {
      throw FileAssociationError.noPreviousHandler(kind: kind)
    }

    var resolved: [String: URL] = [:]
    var typesToRestore: [UTType] = []
    var unchanged: [String] = []
    for (contentType, previous) in entries {
      let identifier = contentType.identifier
      guard workspace.defaultApplication(for: contentType)?.matches(hostApplication) == true else {
        // Respect a newer choice made in Finder or System Settings after our own change.
        unchanged.append(identifier)
        continue
      }
      guard let applicationURL = workspace.resolveApplication(previous) else {
        throw FileAssociationError.previousApplicationUnavailable(
          bundleIdentifier: previous.bundleIdentifier,
          path: previous.bundlePath)
      }
      resolved[identifier] = applicationURL
      typesToRestore.append(contentType)
    }

    var restored: [UTType] = []
    do {
      for contentType in typesToRestore {
        guard let applicationURL = resolved[contentType.identifier] else { continue }
        try await changeDefaultApplication(to: applicationURL, for: contentType)
        restored.append(contentType)
      }
    } catch {
      let destinations = Dictionary(
        uniqueKeysWithValues: restored.map { ($0.identifier, hostApplication) })
      let failures = await rollBack(restored.reversed(), destinations: destinations)
      throw FileAssociationError.changeFailed(
        action: .restorePreviousHandler,
        kind: kind,
        contentType: typesToRestore.dropFirst(restored.count).first?.identifier ?? "unknown",
        reason: error.localizedDescription,
        rollbackFailures: failures)
    }

    for (contentType, _) in entries {
      snapshots.removeValue(
        forKey: storageKey(for: kind, contentTypeIdentifier: contentType.identifier))
    }
    try savePreviousHandlers(snapshots)
    return FileAssociationChangeResult(
      action: .restorePreviousHandler,
      kind: kind,
      changedContentTypeIdentifiers: restored.map(\.identifier),
      unchangedContentTypeIdentifiers: unchanged)
  }

  static func fileKind(for url: URL) -> AssociatedFileKind? {
    guard url.isFileURL else { return nil }
    let pathExtension = url.pathExtension.lowercased()
    if pathExtension == "pdf" { return .pdf }
    if ["mp3", "m4a", "wav"].contains(pathExtension) {
      return .audio
    }
    return nil
  }

  private func storageKey(
    for kind: AssociatedFileKind,
    contentTypeIdentifier: String
  ) -> String {
    "\(kind.rawValue)|\(contentTypeIdentifier)"
  }

  private func loadPreviousHandlers() throws
    -> [String: FileAssociationApplicationIdentity]
  {
    guard let data = defaults.data(forKey: previousHandlersKey) else { return [:] }
    do {
      return try JSONDecoder().decode(
        [String: FileAssociationApplicationIdentity].self,
        from: data)
    } catch {
      throw FileAssociationError.storedPreviousHandlersUnreadable
    }
  }

  private func savePreviousHandlers(
    _ snapshots: [String: FileAssociationApplicationIdentity]
  ) throws {
    do {
      let data = try JSONEncoder().encode(snapshots)
      defaults.set(data, forKey: previousHandlersKey)
    } catch {
      throw FileAssociationError.storedPreviousHandlersUnreadable
    }
  }

  private func changeDefaultApplication(to applicationURL: URL, for contentType: UTType)
    async throws
  {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      workspace.setDefaultApplication(at: applicationURL, for: contentType) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func rollBack<S: Sequence>(
    _ contentTypes: S,
    destinations: [String: FileAssociationApplicationIdentity]
  ) async -> [String] where S.Element == UTType {
    var failures: [String] = []
    for contentType in contentTypes {
      guard let identity = destinations[contentType.identifier],
        let applicationURL = workspace.resolveApplication(identity)
      else {
        failures.append("\(contentType.identifier) 无法定位原应用")
        continue
      }
      do {
        try await changeDefaultApplication(to: applicationURL, for: contentType)
      } catch {
        failures.append("\(contentType.identifier): \(error.localizedDescription)")
      }
    }
    return failures
  }
}
