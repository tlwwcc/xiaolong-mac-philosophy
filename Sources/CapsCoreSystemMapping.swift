import Foundation
import IOKit.hid

struct CapsCoreKeyMappingEntry: Codable, Hashable {
  let source: UInt64
  let destination: UInt64
}

enum CapsCoreSystemMappingActivation: Equatable {
  case applied
  case alreadyProtected
  case conflict(String)
  case failed(String)

  var isProtectionActive: Bool {
    self == .applied || self == .alreadyProtected
  }
}

enum CapsCoreSystemMappingRestorePlan: Equatable {
  case noChange
  case write([CapsCoreKeyMappingEntry])
  case conflict(String)
}

enum CapsCoreSystemMappingPlanner {
  static let capsLockSource = UInt64(0x7_0000_0039)
  static let disabledDestination = UInt64(0x7_0000_0000)
  static let disabledCapsLock = CapsCoreKeyMappingEntry(
    source: capsLockSource,
    destination: disabledDestination)

  static func activationPlan(
    existing: [CapsCoreKeyMappingEntry]
  ) -> Result<[CapsCoreKeyMappingEntry]?, CapsCoreSystemMappingPlanError> {
    let capsMappings = existing.filter { $0.source == capsLockSource }
    if capsMappings == [disabledCapsLock] {
      return .success(nil)
    }
    guard capsMappings.isEmpty else {
      return .failure(.existingCapsMapping)
    }
    return .success(normalized(existing + [disabledCapsLock]))
  }

  static func restorePlan(
    previous: [CapsCoreKeyMappingEntry],
    applied: [CapsCoreKeyMappingEntry],
    current: [CapsCoreKeyMappingEntry]
  ) -> CapsCoreSystemMappingRestorePlan {
    let previousCaps = previous.filter { $0.source == capsLockSource }
    let appliedCaps = applied.filter { $0.source == capsLockSource }
    let currentCaps = current.filter { $0.source == capsLockSource }

    guard previousCaps.isEmpty, appliedCaps == [disabledCapsLock] else {
      return .conflict("恢复记录中的 Caps 映射不符合本版本安全边界。")
    }
    if currentCaps.isEmpty {
      return .noChange
    }
    guard currentCaps == [disabledCapsLock] else {
      return .conflict("Caps 映射已被其他工具修改，未覆盖新设置。")
    }

    // Preserve unrelated mappings created while the app was running, removing only the exact
    // Caps -> No Action entry owned by this transaction.
    return .write(normalized(current.filter { $0.source != capsLockSource }))
  }

  static func normalized(_ mappings: [CapsCoreKeyMappingEntry]) -> [CapsCoreKeyMappingEntry] {
    Array(Set(mappings)).sorted {
      if $0.source == $1.source { return $0.destination < $1.destination }
      return $0.source < $1.source
    }
  }
}

enum CapsCoreSystemMappingPlanError: Error, Equatable {
  case existingCapsMapping
}

protocol CapsCoreSystemMappingBackend {
  func readMappings() throws -> [CapsCoreKeyMappingEntry]
  func writeMappings(_ mappings: [CapsCoreKeyMappingEntry]) throws
}

enum CapsCoreSystemMappingBackendError: Error, LocalizedError {
  case writeRejected
  case verificationFailed
  case malformedProperty

  var errorDescription: String? {
    switch self {
    case .writeRejected:
      return "macOS 拒绝更新 Caps 系统映射。"
    case .verificationFailed:
      return "Caps 系统映射写入后未通过确认。"
    case .malformedProperty:
      return "系统返回了无法识别的键盘映射。"
    }
  }
}

final class CapsCoreLiveSystemMappingBackend: CapsCoreSystemMappingBackend {
  private let client: IOHIDEventSystemClient
  private let propertyKey = kIOHIDUserKeyUsageMapKey as CFString

  init() {
    client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
  }

  func readMappings() throws -> [CapsCoreKeyMappingEntry] {
    guard let property = IOHIDEventSystemClientCopyProperty(client, propertyKey) else {
      return []
    }
    guard let rawMappings = property as? [[String: Any]] else {
      throw CapsCoreSystemMappingBackendError.malformedProperty
    }
    return try rawMappings.map { raw in
      guard
        let source = Self.uint64(raw[kIOHIDKeyboardModifierMappingSrcKey]),
        let destination = Self.uint64(raw[kIOHIDKeyboardModifierMappingDstKey])
      else {
        throw CapsCoreSystemMappingBackendError.malformedProperty
      }
      return CapsCoreKeyMappingEntry(source: source, destination: destination)
    }
  }

  func writeMappings(_ mappings: [CapsCoreKeyMappingEntry]) throws {
    let property =
      mappings.map { mapping in
        [
          kIOHIDKeyboardModifierMappingSrcKey: NSNumber(value: mapping.source),
          kIOHIDKeyboardModifierMappingDstKey: NSNumber(value: mapping.destination),
        ]
      } as NSArray
    guard IOHIDEventSystemClientSetProperty(client, propertyKey, property) else {
      throw CapsCoreSystemMappingBackendError.writeRejected
    }
    guard
      CapsCoreSystemMappingPlanner.normalized(try readMappings())
        == CapsCoreSystemMappingPlanner.normalized(mappings)
    else {
      throw CapsCoreSystemMappingBackendError.verificationFailed
    }
  }

  private static func uint64(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? UInt64 { return value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    return nil
  }
}

private struct CapsCoreSystemMappingJournal: Codable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let createdAt: Date
  let previous: [CapsCoreKeyMappingEntry]
  let applied: [CapsCoreKeyMappingEntry]
}

final class CapsCoreSystemMappingController {
  typealias EventLogger = (_ event: String, _ fields: [String: String]) -> Void

  private let backend: CapsCoreSystemMappingBackend
  private let journalURL: URL
  private let fileManager: FileManager
  private let log: EventLogger
  private var ownsMapping = false

  init(
    backend: CapsCoreSystemMappingBackend = CapsCoreLiveSystemMappingBackend(),
    journalURL: URL? = nil,
    fileManager: FileManager = .default,
    log: @escaping EventLogger = { _, _ in }
  ) {
    self.backend = backend
    self.fileManager = fileManager
    self.log = log
    if let journalURL {
      self.journalURL = journalURL
    } else {
      self.journalURL = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0]
        .appendingPathComponent(
          AppRuntimeIdentity.current.applicationSupportDirectoryName,
          isDirectory: true
        )
        .appendingPathComponent("caps-core", isDirectory: true)
        .appendingPathComponent("system-mapping-journal.json")
    }
  }

  func activate() -> CapsCoreSystemMappingActivation {
    do {
      try recoverPendingJournal()
      let existing = CapsCoreSystemMappingPlanner.normalized(try backend.readMappings())
      switch CapsCoreSystemMappingPlanner.activationPlan(existing: existing) {
      case .failure:
        log("caps_core_system_mapping_conflict", ["action": "preserveExisting"])
        return .conflict("系统已有其他 Caps 映射，本次未覆盖。")
      case .success(nil):
        ownsMapping = false
        log("caps_core_system_mapping_existing", ["action": "useExisting"])
        return .alreadyProtected
      case .success(let applied?):
        let journal = CapsCoreSystemMappingJournal(
          schemaVersion: CapsCoreSystemMappingJournal.schemaVersion,
          createdAt: Date(),
          previous: existing,
          applied: applied)
        try save(journal)
        do {
          try backend.writeMappings(applied)
        } catch {
          try? backend.writeMappings(existing)
          try? removeJournal()
          throw error
        }
        ownsMapping = true
        log(
          "caps_core_system_mapping_applied",
          ["previousCount": "\(existing.count)", "appliedCount": "\(applied.count)"])
        return .applied
      }
    } catch {
      ownsMapping = false
      log("caps_core_system_mapping_failed", ["error": error.localizedDescription])
      return .failed(error.localizedDescription)
    }
  }

  func deactivate() {
    guard ownsMapping || fileManager.fileExists(atPath: journalURL.path) else { return }
    do {
      try recoverPendingJournal()
      ownsMapping = false
    } catch {
      log("caps_core_system_mapping_restore_failed", ["error": error.localizedDescription])
    }
  }

  private func recoverPendingJournal() throws {
    guard fileManager.fileExists(atPath: journalURL.path) else { return }
    let journal = try loadJournal()
    guard journal.schemaVersion == CapsCoreSystemMappingJournal.schemaVersion else {
      log("caps_core_system_mapping_journal_unsupported", ["action": "preserveCurrent"])
      try removeJournal()
      return
    }

    let current = CapsCoreSystemMappingPlanner.normalized(try backend.readMappings())
    switch CapsCoreSystemMappingPlanner.restorePlan(
      previous: journal.previous,
      applied: journal.applied,
      current: current)
    {
    case .noChange:
      try removeJournal()
      log("caps_core_system_mapping_recovered", ["action": "alreadyRestored"])
    case .write(let restored):
      try backend.writeMappings(restored)
      try removeJournal()
      log(
        "caps_core_system_mapping_recovered",
        ["action": "restored", "mappingCount": "\(restored.count)"])
    case .conflict(let reason):
      try removeJournal()
      log(
        "caps_core_system_mapping_restore_conflict",
        ["action": "preserveCurrent", "reason": reason])
    }
  }

  private func save(_ journal: CapsCoreSystemMappingJournal) throws {
    let directory = journalURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(journal).write(to: journalURL, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
  }

  private func loadJournal() throws -> CapsCoreSystemMappingJournal {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      CapsCoreSystemMappingJournal.self,
      from: Data(contentsOf: journalURL))
  }

  private func removeJournal() throws {
    guard fileManager.fileExists(atPath: journalURL.path) else { return }
    try fileManager.removeItem(at: journalURL)
  }
}
