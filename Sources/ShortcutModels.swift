import AppKit
import Carbon
import CryptoKit

enum LocalConfigurationReadError: LocalizedError, Equatable {
  case fileTooLarge(maximumBytes: Int)
  case invalidTopLevel
  case tooManyRecords(maximum: Int)
  case collectionTooLarge
  case nestingTooDeep
  case stringTooLong
  case unknownFields
  case invalidRecord

  var errorDescription: String? {
    switch self {
    case .fileTooLarge(let maximumBytes):
      return "配置文件超过 \(maximumBytes / 1_048_576) MB 安全上限。"
    case .invalidTopLevel: return "配置文件顶层格式无效。"
    case .tooManyRecords(let maximum): return "配置记录超过 \(maximum) 条。"
    case .collectionTooLarge: return "配置中的集合过大。"
    case .nestingTooDeep: return "配置嵌套层级过深。"
    case .stringTooLong: return "配置中存在过长文本。"
    case .unknownFields: return "配置中存在未识别字段。"
    case .invalidRecord: return "配置记录不符合安全格式。"
    }
  }
}

/// One bounded reader for every local JSON/plist configuration entry point. It never allocates
/// more than `maximumFileBytes + 1` while deciding whether a file is acceptable.
enum LocalConfigurationFileCodec {
  static let maximumFileBytes = 8 * 1_024 * 1_024
  static let maximumRecordCount = 2_048
  static let maximumStringBytes = 256 * 1_024
  static let maximumCollectionEntries = 4_096
  static let maximumNestingDepth = 16

  static func readData(
    from url: URL,
    maximumBytes: Int = maximumFileBytes
  ) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
      throw LocalConfigurationReadError.fileTooLarge(maximumBytes: max(0, maximumBytes))
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 65_536))
    while data.count <= maximumBytes {
      let remainingWithSentinel = maximumBytes + 1 - data.count
      guard remainingWithSentinel > 0 else { break }
      let chunk = try handle.read(upToCount: min(65_536, remainingWithSentinel)) ?? Data()
      guard !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= maximumBytes else {
      throw LocalConfigurationReadError.fileTooLarge(maximumBytes: maximumBytes)
    }
    return data
  }

  static func decodeArray<Element: Decodable>(
    _ type: Element.Type,
    from url: URL,
    allowedKeys: Set<String>? = nil,
    maximumRecords: Int = maximumRecordCount,
    validate: ([Element]) throws -> Void = { _ in }
  ) throws -> [Element] {
    let data = try readData(from: url)
    return try decodeArray(
      type,
      from: data,
      allowedKeys: allowedKeys,
      maximumRecords: maximumRecords,
      validate: validate)
  }

  static func decodeArray<Element: Decodable>(
    _ type: Element.Type,
    from data: Data,
    allowedKeys: Set<String>? = nil,
    maximumRecords: Int = maximumRecordCount,
    validate: ([Element]) throws -> Void = { _ in }
  ) throws -> [Element] {
    guard data.count <= maximumFileBytes else {
      throw LocalConfigurationReadError.fileTooLarge(maximumBytes: maximumFileBytes)
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let records = object as? [Any] else {
      throw LocalConfigurationReadError.invalidTopLevel
    }
    guard records.count <= maximumRecords else {
      throw LocalConfigurationReadError.tooManyRecords(maximum: maximumRecords)
    }
    try validateJSONValue(records, depth: 0)
    if let allowedKeys {
      for record in records {
        guard let dictionary = record as? [String: Any],
          Set(dictionary.keys).isSubset(of: allowedKeys)
        else { throw LocalConfigurationReadError.unknownFields }
      }
    }
    let decoded = try JSONDecoder().decode([Element].self, from: data)
    try validate(decoded)
    return decoded
  }

  private static func validateJSONValue(_ value: Any, depth: Int) throws {
    guard depth <= maximumNestingDepth else {
      throw LocalConfigurationReadError.nestingTooDeep
    }
    switch value {
    case let string as String:
      guard string.utf8.count <= maximumStringBytes else {
        throw LocalConfigurationReadError.stringTooLong
      }
    case let array as [Any]:
      guard array.count <= maximumCollectionEntries else {
        throw LocalConfigurationReadError.collectionTooLarge
      }
      for child in array { try validateJSONValue(child, depth: depth + 1) }
    case let dictionary as [String: Any]:
      guard dictionary.count <= maximumCollectionEntries else {
        throw LocalConfigurationReadError.collectionTooLarge
      }
      for (key, child) in dictionary {
        guard key.utf8.count <= maximumStringBytes else {
          throw LocalConfigurationReadError.stringTooLong
        }
        try validateJSONValue(child, depth: depth + 1)
      }
    case is NSNumber, is NSNull:
      break
    default:
      throw LocalConfigurationReadError.invalidRecord
    }
  }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
  case openApp
  case openURL
  case runShell
  case showPanel
  case showLauncher
  case showProcessViewer
  case showClipboardHistory
  case showCodexNetworkProbe
  case showSleepPanel
  case windowPreset
  case nativeFullScreen
  case sendShortcut
  case closeWindowSmart
  case insertText

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openApp: return "打开 App、文件或文件夹"
    case .openURL: return "打开网址"
    case .runShell: return "运行命令"
    case .showPanel: return "功能快捷键"
    case .showLauncher: return "打开启动器"
    case .showProcessViewer: return "打开进程查看器"
    case .showClipboardHistory: return "打开剪贴板历史"
    case .showCodexNetworkProbe: return "打开测试网速"
    case .showSleepPanel: return "保持唤醒"
    case .windowPreset: return "窗口管理"
    case .nativeFullScreen: return "进入 / 退出全屏"
    case .sendShortcut: return "发送按键"
    case .closeWindowSmart: return "关闭当前标签页或窗口"
    case .insertText: return "输入文字"
    }
  }

  var shortTitle: String {
    switch self {
    case .openApp: return "打开 App"
    case .openURL: return "打开网址"
    case .runShell: return "Shell"
    case .showPanel: return "功能快捷键"
    case .showLauncher: return "启动器"
    case .showProcessViewer: return "进程查看器"
    case .showClipboardHistory: return "剪贴板历史"
    case .showCodexNetworkProbe: return "测试网速"
    case .showSleepPanel: return "保持唤醒"
    case .windowPreset: return "窗口"
    case .nativeFullScreen: return "进入 / 退出全屏"
    case .sendShortcut: return "发送按键"
    case .closeWindowSmart: return "智能关闭"
    case .insertText: return "输入文本"
    }
  }
}

enum WindowPreset: String, CaseIterable, Identifiable {
  case leftHalf
  case rightHalf
  case topHalf
  case bottomHalf
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight
  case maximize
  case center
  case minimize

  var id: String { rawValue }

  var title: String {
    switch self {
    case .leftHalf: return "1/2 左分屏"
    case .rightHalf: return "1/2 右分屏"
    case .topHalf: return "1/2 上分屏"
    case .bottomHalf: return "1/2 下分屏"
    case .topLeft: return "1/4 左上分屏"
    case .topRight: return "1/4 右上分屏"
    case .bottomLeft: return "1/4 左下分屏"
    case .bottomRight: return "1/4 右下分屏"
    case .maximize: return "窗口化全屏"
    case .center: return "窗口居中"
    case .minimize: return "窗口最小化"
    }
  }
}

enum PhysicalModifierKey: String, Codable, CaseIterable, Identifiable {
  case leftControl
  case leftShift
  case leftOption
  case leftCommand
  case rightControl
  case rightShift
  case rightOption
  case rightCommand

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .leftControl: return "物理左 Control"
    case .leftShift: return "物理左 Shift"
    case .leftOption: return "物理左 Option"
    case .leftCommand: return "物理左 Command"
    case .rightControl: return "物理右 Control"
    case .rightShift: return "物理右 Shift"
    case .rightOption: return "物理右 Option"
    case .rightCommand: return "物理右 Command"
    }
  }

  var doubleTapDisplayText: String {
    switch self {
    case .leftControl: return "连按左 ⌃ 两次"
    case .leftShift: return "连按左 ⇧ 两次"
    case .leftOption: return "连按左 ⌥ 两次"
    case .leftCommand: return "连按左 ⌘ 两次"
    case .rightControl: return "连按右 ⌃ 两次"
    case .rightShift: return "连按右 ⇧ 两次"
    case .rightOption: return "连按右 ⌥ 两次"
    case .rightCommand: return "连按右 ⌘ 两次"
    }
  }

  var hidUsage: UInt32 {
    switch self {
    case .leftControl: return 0xE0
    case .leftShift: return 0xE1
    case .leftOption: return 0xE2
    case .leftCommand: return 0xE3
    case .rightControl: return 0xE4
    case .rightShift: return 0xE5
    case .rightOption: return 0xE6
    case .rightCommand: return 0xE7
    }
  }

  init?(hidUsage: UInt32) {
    switch hidUsage {
    case 0xE0: self = .leftControl
    case 0xE1: self = .leftShift
    case 0xE2: self = .leftOption
    case 0xE3: self = .leftCommand
    case 0xE4: self = .rightControl
    case 0xE5: self = .rightShift
    case 0xE6: self = .rightOption
    case 0xE7: self = .rightCommand
    default: return nil
    }
  }
}

struct ShortcutTrigger: Codable, Equatable {
  enum Kind: String, Codable {
    case modifierDoubleTap
  }

  var kind: Kind
  var modifier: PhysicalModifierKey

  static let rightOptionDoubleTap = ShortcutTrigger(
    kind: .modifierDoubleTap,
    modifier: .rightOption)

  var displayText: String {
    switch kind {
    case .modifierDoubleTap: return modifier.doubleTapDisplayText
    }
  }

  var signature: String {
    switch kind {
    case .modifierDoubleTap: return "modifierDoubleTap:\(modifier.rawValue)"
    }
  }
}

struct ShortcutItem: Codable, Equatable, Identifiable {
  var id: String
  /// Stable platform command identity. Legacy records omit this field and keep using action/target.
  var commandID: String? = nil
  /// Stable identity for restoring an App-owned default after the user removes it.
  /// Legacy records omit this field and are migrated from their semantic action/target identity.
  var recoveryID: String? = nil
  /// App-owned defaults stay visible so they can always be adjusted or re-enabled.
  /// `nil` is retained for legacy JSON and migrated by AppModel on first load.
  var isBuiltIn: Bool? = nil
  var name: String
  var scope: String
  var key: String
  var modifiers: [String]
  /// `nil` keeps the original key + modifiers chord contract. Gesture triggers bypass Carbon.
  var trigger: ShortcutTrigger? = nil
  var action: ShortcutAction
  var target: String
  var enabled: Bool
  var note: String

  var displayHotkey: String {
    trigger?.displayText ?? displayHotkeyText(key: key, modifiers: modifiers)
  }

  var usesChordTrigger: Bool { trigger == nil }

  static func prettyKey(_ value: String) -> String {
    switch value {
    case "Escape": return "Esc"
    case "Left": return "◀"
    case "Right": return "▶"
    case "Up": return "▲"
    case "Down": return "▼"
    default: return value
    }
  }
}

enum ShortcutConfigurationCodec {
  private static let allowedKeys: Set<String> = [
    "id", "commandID", "recoveryID", "isBuiltIn", "name", "scope", "key", "modifiers",
    "trigger", "action", "target", "enabled", "note",
  ]
  private static let triggerKeys: Set<String> = ["kind", "modifier"]

  static func load(from url: URL) throws -> [ShortcutItem] {
    try decode(LocalConfigurationFileCodec.readData(from: url))
  }

  static func decode(_ data: Data) throws -> [ShortcutItem] {
    guard data.count <= LocalConfigurationFileCodec.maximumFileBytes else {
      throw LocalConfigurationReadError.fileTooLarge(
        maximumBytes: LocalConfigurationFileCodec.maximumFileBytes)
    }
    guard let rawRecords = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw LocalConfigurationReadError.invalidTopLevel
    }
    for rawRecord in rawRecords {
      guard Set(rawRecord.keys).isSubset(of: allowedKeys) else {
        throw LocalConfigurationReadError.unknownFields
      }
      if let trigger = rawRecord["trigger"], !(trigger is NSNull) {
        guard let triggerDictionary = trigger as? [String: Any],
          Set(triggerDictionary.keys).isSubset(of: triggerKeys)
        else { throw LocalConfigurationReadError.unknownFields }
      }
    }
    return try LocalConfigurationFileCodec.decodeArray(
      ShortcutItem.self,
      from: data,
      allowedKeys: allowedKeys
    ) { items in
      for item in items {
        guard isBounded(item.id, 256),
          item.commandID.map({ isBounded($0, 256) }) ?? true,
          item.recoveryID.map({ isBounded($0, 256) }) ?? true,
          isBounded(item.name, 512),
          isBounded(item.scope, 256),
          isBounded(item.key, 64),
          item.modifiers.count <= 16,
          item.modifiers.allSatisfy({ isBounded($0, 32) }),
          isBounded(item.target, LocalConfigurationFileCodec.maximumStringBytes),
          isBounded(item.note, 32_768)
        else { throw LocalConfigurationReadError.invalidRecord }
      }
    }
  }

  private static func isBounded(_ string: String, _ maximumBytes: Int) -> Bool {
    string.utf8.count <= maximumBytes
  }
}

enum ShortcutIssueKind: String, Equatable {
  case shortcutDuplicate
  case systemOccupied
  case externalManaged
  case possibleCollision
  case needsCompletion

  var label: String {
    switch self {
    case .shortcutDuplicate: return "快捷键重复"
    case .systemOccupied: return "系统占用"
    case .externalManaged: return "其他工具占用"
    case .possibleCollision: return "可能冲突"
    case .needsCompletion: return "信息不完整"
    }
  }

  var isBlocking: Bool {
    switch self {
    case .shortcutDuplicate, .systemOccupied, .externalManaged, .needsCompletion:
      return true
    case .possibleCollision:
      return false
    }
  }
}

struct ShortcutIssue: Identifiable, Equatable {
  let kind: ShortcutIssueKind
  let hotkey: String
  let object: String
  let impact: String
  let suggestion: String

  var id: String {
    [kind.rawValue, hotkey, object, impact, suggestion].joined(separator: "|")
  }
}

struct ShortcutSemanticAnalysis: Equatable {
  let officialLegacyItems: [ShortcutItem]
  let capsSpaceConflicts: [ShortcutItem]
  let commandSpaceConflicts: [ShortcutItem]

  var needsUserDecision: Bool {
    !capsSpaceConflicts.isEmpty || !commandSpaceConflicts.isEmpty
  }
}

struct ShortcutSemanticMigrationResult: Equatable {
  let changed: Bool
  let backupURL: URL?
  let affectedItemIDs: [String]
  let originalSHA256: String
  let migratedSHA256: String
}

struct ShortcutSemanticMigrationRecord: Codable, Equatable {
  let version: Int
  let createdAt: String
  let build: String
  let reason: String
  let originalSHA256: String
  let migratedSHA256: String
  let backupFileName: String
  let affectedFingerprints: [String]
}

enum ShortcutSemanticMigrationError: LocalizedError {
  case unreadableConfiguration
  case backupVerificationFailed
  case migratedWriteVerificationFailed
  case configurationChangedAfterMigration
  case missingBackup

  var errorDescription: String? {
    switch self {
    case .unreadableConfiguration:
      return "快捷键配置无法读取。"
    case .backupVerificationFailed:
      return "无法创建可验证备份。"
    case .migratedWriteVerificationFailed:
      return "迁移后的快捷键配置校验失败。"
    case .configurationChangedAfterMigration:
      return "迁移后配置已有新修改，未自动覆盖。"
    case .missingBackup:
      return "找不到本次迁移备份。"
    }
  }
}

enum ShortcutSemanticMigration {
  static let version = 1
  static let recordFileName = "shortcut-semantic-migration-issue-075.json"
  static let capsSpaceSignature = hotkeySignature(
    key: "Space", modifiers: ["control", "option"])
  static let commandSpaceSignature = hotkeySignature(
    key: "Space", modifiers: ["command"])

  static func analyze(_ items: [ShortcutItem]) -> ShortcutSemanticAnalysis {
    let enabledItems = items.filter(\.enabled)
    let officialLegacyItems = enabledItems.filter {
      isExactOfficialCommandLauncherDefault($0) || isExactOfficialShortcutGuideDefault($0)
    }
    let officialIDs = Set(officialLegacyItems.map(\.id))
    return ShortcutSemanticAnalysis(
      officialLegacyItems: officialLegacyItems,
      capsSpaceConflicts: enabledItems.filter {
        !officialIDs.contains($0.id)
          && $0.usesChordTrigger
          && hotkeySignature(key: $0.key, modifiers: $0.modifiers) == capsSpaceSignature
      },
      commandSpaceConflicts: enabledItems.filter {
        !officialIDs.contains($0.id)
          && $0.usesChordTrigger
          && hotkeySignature(key: $0.key, modifiers: $0.modifiers) == commandSpaceSignature
      })
  }

  static func isExactOfficialCommandLauncherDefault(_ item: ShortcutItem) -> Bool {
    item.usesChordTrigger
      && item.name == "打开 App 启动器"
      && item.scope == "常用脚本"
      && item.key == "Space"
      && Set(item.modifiers) == Set(["command"])
      && item.action == .showLauncher
      && item.target.isEmpty
      && item.enabled
      && item.note == "⌘ Space：打开小龙哥启动器。"
  }

  static func isExactOfficialShortcutGuideDefault(_ item: ShortcutItem) -> Bool {
    item.usesChordTrigger && ShortcutDefaultBaseline.isShortcutGuideConfigDefault(item)
  }

  static func conflictFingerprint(_ items: [ShortcutItem]) -> String {
    items.map(itemFingerprint).sorted().joined(separator: "\n")
  }

  static func applyAutomaticMigrationIfNeeded(
    at sourceURL: URL,
    build: String,
    backupDirectoryURL: URL? = nil
  ) throws -> ShortcutSemanticMigrationResult {
    let sourceData = try LocalConfigurationFileCodec.readData(from: sourceURL)
    guard let items = try? ShortcutConfigurationCodec.decode(sourceData) else {
      throw ShortcutSemanticMigrationError.unreadableConfiguration
    }
    let officialItems = analyze(items).officialLegacyItems
    guard !officialItems.isEmpty else {
      let sha = sha256(sourceData)
      return ShortcutSemanticMigrationResult(
        changed: false,
        backupURL: nil,
        affectedItemIDs: [],
        originalSHA256: sha,
        migratedSHA256: sha)
    }
    return try disableItems(
      at: sourceURL,
      itemIDs: Set(officialItems.map(\.id)),
      reason: "automatic-official-legacy",
      build: build,
      backupDirectoryURL: backupDirectoryURL)
  }

  static func disableItems(
    at sourceURL: URL,
    itemIDs: Set<String>,
    reason: String,
    build: String,
    backupDirectoryURL: URL? = nil
  ) throws -> ShortcutSemanticMigrationResult {
    let originalData = try LocalConfigurationFileCodec.readData(from: sourceURL)
    guard var items = try? ShortcutConfigurationCodec.decode(originalData) else {
      throw ShortcutSemanticMigrationError.unreadableConfiguration
    }
    let affectedItems = items.filter { itemIDs.contains($0.id) && $0.enabled }
    guard !affectedItems.isEmpty else {
      let sha = sha256(originalData)
      return ShortcutSemanticMigrationResult(
        changed: false,
        backupURL: nil,
        affectedItemIDs: [],
        originalSHA256: sha,
        migratedSHA256: sha)
    }

    let backupDirectory = backupDirectoryURL ?? sourceURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: backupDirectory, withIntermediateDirectories: true)
    let timestamp = backupTimestamp()
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let backupURL = backupDirectory.appendingPathComponent(
      "shortcuts.backup-pre-issue-075-\(timestamp)-\(suffix).json")
    try originalData.write(to: backupURL, options: [.atomic])
    guard (try? LocalConfigurationFileCodec.readData(from: backupURL)) == originalData else {
      try? FileManager.default.removeItem(at: backupURL)
      throw ShortcutSemanticMigrationError.backupVerificationFailed
    }

    for index in items.indices where itemIDs.contains(items[index].id) && items[index].enabled {
      items[index].enabled = false
      let migrationNote = "ISSUE-075 已停用并保留，可从迁移备份恢复。"
      if !items[index].note.contains(migrationNote) {
        items[index].note =
          items[index].note.isEmpty
          ? migrationNote : "\(items[index].note) \(migrationNote)"
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let migratedData = try encoder.encode(items)
    let originalSHA = sha256(originalData)
    let migratedSHA = sha256(migratedData)
    let record = ShortcutSemanticMigrationRecord(
      version: version,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      build: build,
      reason: reason,
      originalSHA256: originalSHA,
      migratedSHA256: migratedSHA,
      backupFileName: backupURL.lastPathComponent,
      affectedFingerprints: affectedItems.map(itemFingerprint).sorted())
    let recordURL = sourceURL.deletingLastPathComponent().appendingPathComponent(recordFileName)

    do {
      try migratedData.write(to: sourceURL, options: [.atomic])
      guard (try? LocalConfigurationFileCodec.readData(from: sourceURL)) == migratedData else {
        throw ShortcutSemanticMigrationError.migratedWriteVerificationFailed
      }
      let recordData = try encoder.encode(record)
      try recordData.write(to: recordURL, options: [.atomic])
    } catch {
      try? originalData.write(to: sourceURL, options: [.atomic])
      throw error
    }

    return ShortcutSemanticMigrationResult(
      changed: true,
      backupURL: backupURL,
      affectedItemIDs: affectedItems.map(\.id),
      originalSHA256: originalSHA,
      migratedSHA256: migratedSHA)
  }

  static func latestRecord(for sourceURL: URL) -> ShortcutSemanticMigrationRecord? {
    let recordURL = sourceURL.deletingLastPathComponent().appendingPathComponent(recordFileName)
    guard let data = try? LocalConfigurationFileCodec.readData(from: recordURL) else { return nil }
    return try? JSONDecoder().decode(ShortcutSemanticMigrationRecord.self, from: data)
  }

  static func refreshLatestRecordMigratedSHA(at sourceURL: URL) throws {
    guard let record = latestRecord(for: sourceURL) else { return }
    let currentData = try LocalConfigurationFileCodec.readData(from: sourceURL)
    let refreshed = ShortcutSemanticMigrationRecord(
      version: record.version,
      createdAt: record.createdAt,
      build: record.build,
      reason: record.reason,
      originalSHA256: record.originalSHA256,
      migratedSHA256: sha256(currentData),
      backupFileName: record.backupFileName,
      affectedFingerprints: record.affectedFingerprints)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let recordURL = sourceURL.deletingLastPathComponent().appendingPathComponent(recordFileName)
    try encoder.encode(refreshed).write(to: recordURL, options: [.atomic])
  }

  static func backupURL(for sourceURL: URL, record: ShortcutSemanticMigrationRecord) -> URL {
    sourceURL.deletingLastPathComponent().appendingPathComponent(record.backupFileName)
  }

  static func restoreLatestMigration(at sourceURL: URL) throws -> URL {
    guard let record = latestRecord(for: sourceURL) else {
      throw ShortcutSemanticMigrationError.missingBackup
    }
    let currentData = try LocalConfigurationFileCodec.readData(from: sourceURL)
    guard sha256(currentData) == record.migratedSHA256 else {
      throw ShortcutSemanticMigrationError.configurationChangedAfterMigration
    }
    let backupURL = backupURL(for: sourceURL, record: record)
    guard let backupData = try? LocalConfigurationFileCodec.readData(from: backupURL),
      sha256(backupData) == record.originalSHA256
    else {
      throw ShortcutSemanticMigrationError.missingBackup
    }
    try backupData.write(to: sourceURL, options: [.atomic])
    guard (try? LocalConfigurationFileCodec.readData(from: sourceURL)) == backupData else {
      throw ShortcutSemanticMigrationError.migratedWriteVerificationFailed
    }
    return backupURL
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func itemFingerprint(_ item: ShortcutItem) -> String {
    var fields = [item.name, item.scope]
    if let trigger = item.trigger {
      fields.append(trigger.signature)
    } else {
      // Preserve the original chord fingerprint so an earlier user undo remains valid.
      fields.append(item.key)
      fields.append(item.modifiers.sorted().joined(separator: "+"))
    }
    fields.append(contentsOf: [
      item.commandID ?? "legacy",
      item.action.rawValue,
      item.target,
      item.enabled ? "enabled" : "disabled",
      item.note,
    ])
    return fields.joined(separator: "|")
  }

  private static func backupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
    return formatter.string(from: Date())
  }
}

enum ShortcutDefaultBaseline {
  static let versionDefaultsKey = "shortcutDefaultBaselineVersionV1"
  static let currentVersion = 10

  static func migrateLegacyDefaults(
    in items: inout [ShortcutItem],
    allowClipboardHistoryTriggerMigration: Bool = true
  ) -> Bool {
    var changed = false
    let beforeCount = items.count
    items.removeAll {
      $0.isBuiltIn != false && $0.usesChordTrigger && isLegacyAixlgArmoryDefault($0)
    }
    if items.count != beforeCount {
      changed = true
    }
    let beforeExpiredCount = items.count
    items.removeAll {
      $0.isBuiltIn != false && $0.usesChordTrigger && isExpiredBuiltInShortcut($0)
    }
    if items.count != beforeExpiredCount {
      changed = true
    }
    let beforeShortcutGuideCount = items.count
    items.removeAll {
      $0.isBuiltIn != false && $0.usesChordTrigger && isShortcutGuideConfigDefault($0)
    }
    if items.count != beforeShortcutGuideCount {
      changed = true
    }
    if allowClipboardHistoryTriggerMigration,
      migrateClipboardHistoryDoubleTapTrigger(in: &items)
    {
      changed = true
    }

    return changed
  }

  private static func migrateClipboardHistoryDoubleTapTrigger(
    in items: inout [ShortcutItem]
  ) -> Bool {
    guard let index = legacyClipboardHistoryTriggerIndex(in: items) else {
      return false
    }
    let replacement = ShortcutTrigger.rightOptionDoubleTap
    guard
      !items.indices.contains(where: { candidateIndex in
        candidateIndex != index && items[candidateIndex].enabled
          && items[candidateIndex].trigger == replacement
      })
    else {
      return false
    }
    items[index].trigger = replacement
    if items[index].note == "Caps + V：打开剪贴板历史并开始搜索。" {
      items[index].note =
        "连按物理右 Option 两次：打开剪贴板历史并开始搜索；再连按两次收起。"
    }
    return true
  }

  private static func legacyClipboardHistoryTriggerIndex(
    in items: [ShortcutItem]
  ) -> Int? {
    items.indices.first(where: { index in
      let item = items[index]
      return item.isBuiltIn != false
        && item.action == .showClipboardHistory
        && item.target == "clipboard-history"
        && item.trigger == nil
        && item.key == "V"
        && sameModifiers(item.modifiers, ["control", "option"])
    })
  }

  static func isLegacyAixlgArmoryDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开 aixlg 军火库"
      && item.scope == "全部应用"
      && item.key == "J"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .openURL
      && item.target == "https://tlww.cn/setup/"
      && item.enabled
  }

  static func isLegacyShortcutPanelDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键面板"
      && item.scope == "全部应用"
      && item.key == "K"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
  }

  static func isExpiredBuiltInShortcut(_ item: ShortcutItem) -> Bool {
    isExpiredQuitAppShortcut(item)
      || isExpiredPhraseExampleShortcut(item)
      || isRedundantCodexBackupShortcut(item)
  }

  private static func isExpiredQuitAppShortcut(_ item: ShortcutItem) -> Bool {
    item.name == "退出当前 App"
      && item.scope == "常用按键"
      && item.key == "Q"
      && sameModifiers(item.modifiers, ["control", "option"])
      && item.action == .sendShortcut
      && item.target == "⌘ Q"
      && item.enabled == false
      && item.note == "给前台 App 发送 ⌘ Q。"
  }

  private static func isExpiredPhraseExampleShortcut(_ item: ShortcutItem) -> Bool {
    item.name == "短语示例"
      && item.scope == "短语"
      && item.key == "P"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .insertText
      && item.target == "小龙哥Mac哲学"
      && item.enabled == false
      && item.note == "新能力：把目标文本粘贴到前台输入框。"
  }

  private static func isRedundantCodexBackupShortcut(_ item: ShortcutItem) -> Bool {
    item.name == "打开 Codex 备用"
      && item.scope == "App"
      && item.key == "D"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .openApp
      && item.target == "bundle:com.openai.codex"
      && item.enabled
      && item.note == "来自小锤子备用入口。"
  }

  private static func isShortcutGuideDefaultWithLegacyName(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键面板"
      && item.scope == "全部应用"
      && item.key == "E"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
  }

  private static func isShortcutGuidePreviousDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键说明"
      && item.scope == "全部应用"
      && item.key == "E"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
      && item.note == "打开快捷键说明，快速查询当前配置。"
  }

  private static func isShortcutGuideCapsQConfigDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键说明"
      && item.scope == "常用脚本"
      && item.key == "Q"
      && sameModifiers(item.modifiers, ["control", "option"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
      && item.note == "Caps + Q：打开快捷键说明，快速查询当前配置。"
  }

  private static func isShortcutGuideCapsSpaceConfigDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键说明"
      && item.scope == "常用脚本"
      && item.key == "Space"
      && sameModifiers(item.modifiers, ["control", "option"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
      && item.note == "Caps + Space：打开快捷键说明，快速查询当前配置。"
  }

  private static func isShortcutGuideCommonScriptFallbackDefault(_ item: ShortcutItem) -> Bool {
    item.name == "打开快捷键说明"
      && item.scope == "常用脚本"
      && item.key == "E"
      && sameModifiers(item.modifiers, ["control", "option", "command"])
      && item.action == .showPanel
      && item.target.isEmpty
      && item.enabled
      && item.note == "打开快捷键说明，快速查询当前配置。"
  }

  static func isShortcutGuideConfigDefault(_ item: ShortcutItem) -> Bool {
    isLegacyShortcutPanelDefault(item)
      || isShortcutGuideDefaultWithLegacyName(item)
      || isShortcutGuidePreviousDefault(item)
      || isShortcutGuideCapsQConfigDefault(item)
      || isShortcutGuideCapsSpaceConfigDefault(item)
      || isShortcutGuideCommonScriptFallbackDefault(item)
  }

  private static func sameModifiers(_ lhs: [String], _ rhs: [String]) -> Bool {
    Set(lhs) == Set(rhs)
  }
}

func displayHotkeyText(key: String, modifiers: [String]) -> String {
  var parts: [String] = []
  let usesCapsPrefix = modifiers.contains("control") && modifiers.contains("option")
  if usesCapsPrefix {
    parts.append("Caps")
  } else {
    if modifiers.contains("control") { parts.append("⌃") }
    if modifiers.contains("option") { parts.append("⌥") }
  }
  if modifiers.contains("shift") { parts.append("⇧") }
  if modifiers.contains("command") { parts.append("⌘") }
  parts.append(ShortcutItem.prettyKey(key))
  return parts.joined(separator: " + ")
}

func enabledShortcutMenuLabels(
  for action: ShortcutAction,
  in items: [ShortcutItem]
) -> [String] {
  var seen: Set<String> = []
  var labels: [String] = []
  for item in items where item.enabled && item.action == action {
    guard item.trigger != nil || !item.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { continue }
    let label = item.displayHotkey
    guard seen.insert(label).inserted else { continue }
    labels.append(label)
  }
  return labels
}

func hotkeySignature(key: String, modifiers: [String]) -> String {
  "\(modifiers.sorted().joined(separator: "+"))+\(key)"
}

func shortcutTriggerSignature(for item: ShortcutItem) -> String {
  if let trigger = item.trigger {
    return trigger.signature
  }
  return chordTriggerSignature(key: item.key, modifiers: item.modifiers)
}

func chordTriggerSignature(key: String, modifiers: [String]) -> String {
  "chord:\(hotkeySignature(key: key, modifiers: modifiers))"
}

func canUseBareSendShortcut(_ key: String) -> Bool {
  if !requiresModifier(key) { return true }
  return ["Escape", "Return", "Tab", "Left", "Right", "Up", "Down"].contains(key)
}

let modifierOrder = ["control", "option", "shift", "command"]

let keyChoices: [String] =
  (65...90).compactMap { UnicodeScalar($0).map(String.init) } + (0...9).map(String.init) + [
    "Space", "Return", "Tab", "Escape", ",", ".", "/", ";", "'", "[", "]", "-", "=", "`",
  ] + ["Left", "Right", "Up", "Down"] + (1...12).map { "F\($0)" }

let carbonKeyCodes: [String: UInt32] = [
  "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
  "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
  "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
  "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33,
  "I": 34, "P": 35, "Return": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
  "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "Tab": 48, "Space": 49,
  "`": 50, "Escape": 53, "Left": 123, "Right": 124, "Down": 125, "Up": 126,
  "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
  "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
]

let keyNamesByCode: [UInt32: String] = Dictionary(
  uniqueKeysWithValues: carbonKeyCodes.map { ($0.value, $0.key) })

func keyCode(for key: String) -> UInt32? {
  carbonKeyCodes[key]
}

func keyName(for keyCode: UInt32) -> String? {
  keyNamesByCode[keyCode]
}

func requiresModifier(_ key: String) -> Bool {
  if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...12).contains(number) {
    return false
  }
  return true
}

func isPluginShortcut(_ item: ShortcutItem) -> Bool {
  // ShortcutItem 表达的是一次性动作，不拥有独立能力面板；完整插件由插件中心单独建模。
  false
}

func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
  let clean = flags.intersection(.deviceIndependentFlagsMask)
  return modifierOrder.filter { name in
    switch name {
    case "control": return clean.contains(.control)
    case "option": return clean.contains(.option)
    case "shift": return clean.contains(.shift)
    case "command": return clean.contains(.command)
    default: return false
    }
  }
}

func modifierNames(from flags: CGEventFlags) -> [String] {
  modifierOrder.filter { name in
    switch name {
    case "control": return flags.contains(.maskControl)
    case "option": return flags.contains(.maskAlternate)
    case "shift": return flags.contains(.maskShift)
    case "command": return flags.contains(.maskCommand)
    default: return false
    }
  }
}

func eventFlagsMatch(_ flags: CGEventFlags, modifiers: [String]) -> Bool {
  let wanted = Set(modifiers)
  var found = Set<String>()
  if flags.contains(.maskControl) { found.insert("control") }
  if flags.contains(.maskAlternate) { found.insert("option") }
  if flags.contains(.maskShift) { found.insert("shift") }
  if flags.contains(.maskCommand) { found.insert("command") }
  return found == wanted
}

func cgModifiers(_ modifiers: [String]) -> CGEventFlags {
  var flags: CGEventFlags = []
  if modifiers.contains("command") { flags.insert(.maskCommand) }
  if modifiers.contains("option") { flags.insert(.maskAlternate) }
  if modifiers.contains("control") { flags.insert(.maskControl) }
  if modifiers.contains("shift") { flags.insert(.maskShift) }
  return flags
}

func parseHotkeyText(_ text: String) -> (key: String, modifiers: [String])? {
  let normalized =
    text
    .replacingOccurrences(of: "+", with: " ")
    .replacingOccurrences(of: "Caps", with: " control option ", options: [.caseInsensitive])
    .replacingOccurrences(of: "CL", with: " control option ", options: [.caseInsensitive])
    .replacingOccurrences(of: "左", with: " left ")
    .replacingOccurrences(of: "右", with: " right ")
    .replacingOccurrences(of: "⌃", with: " control ")
    .replacingOccurrences(of: "⌥", with: " option ")
    .replacingOccurrences(of: "⇧", with: " shift ")
    .replacingOccurrences(of: "⌘", with: " command ")
  let parts =
    normalized
    .split(whereSeparator: { $0.isWhitespace })
    .map { String($0) }
  guard let rawKey = parts.last else { return nil }
  let modifiers = Array(
    Set(
      parts.dropLast().compactMap { part -> String? in
        switch part.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "control", "ctrl", "^", "left_control", "right_control", "leftcontrol",
          "rightcontrol", "lcontrol", "rcontrol":
          return "control"
        case "option", "opt", "alt", "left_option", "right_option", "leftoption",
          "rightoption", "loption", "roption", "left_alt", "right_alt", "leftalt",
          "rightalt", "lalt", "ralt":
          return "option"
        case "shift", "left_shift", "right_shift", "leftshift", "rightshift", "lshift",
          "rshift":
          return "shift"
        case "command", "cmd", "left_command", "right_command", "leftcommand",
          "rightcommand", "lcommand", "rcommand", "left_cmd", "right_cmd", "leftcmd",
          "rightcmd":
          return "command"
        default: return nil
        }
      })
  ).sorted { lhs, rhs in
    (modifierOrder.firstIndex(of: lhs) ?? Int.max) < (modifierOrder.firstIndex(of: rhs) ?? Int.max)
  }
  let key = normalizedKeyName(rawKey)
  guard keyCode(for: key) != nil else { return nil }
  return (key, modifiers)
}

private func normalizedKeyName(_ rawKey: String) -> String {
  let lowered = rawKey.lowercased()
  switch lowered {
  case "space", "空格": return "Space"
  case "return", "enter", "回车": return "Return"
  case "esc", "escape": return "Escape"
  case "tab": return "Tab"
  case "slash", "forwardslash", "forward_slash", "斜杠": return "/"
  case "comma", "逗号": return ","
  case "period", "dot", "句号", "点": return "."
  case "semicolon", "分号": return ";"
  case "quote", "apostrophe", "引号": return "'"
  case "minus", "hyphen", "减号": return "-"
  case "equal", "equals", "等号": return "="
  case "backtick", "grave", "反引号": return "`"
  case "left", "arrowleft", "leftarrow", "左箭头": return "Left"
  case "right", "arrowright", "rightarrow", "右箭头": return "Right"
  case "up", "arrowup", "uparrow", "上箭头": return "Up"
  case "down", "arrowdown", "downarrow", "下箭头": return "Down"
  default:
    return rawKey.count == 1 ? rawKey.uppercased() : rawKey
  }
}

func carbonModifiers(_ modifiers: [String]) -> UInt32 {
  var flags: UInt32 = 0
  if modifiers.contains("command") { flags |= UInt32(cmdKey) }
  if modifiers.contains("option") { flags |= UInt32(optionKey) }
  if modifiers.contains("control") { flags |= UInt32(controlKey) }
  if modifiers.contains("shift") { flags |= UInt32(shiftKey) }
  return flags
}

func fourCharCode(_ string: String) -> FourCharCode {
  var result: FourCharCode = 0
  for scalar in string.unicodeScalars.prefix(4) {
    result = (result << 8) + FourCharCode(scalar.value)
  }
  return result
}

func defaultShortcuts() -> [ShortcutItem] {
  var shortcuts = commonShortcutTemplates()
  if YoumuFeatureShortcutCatalog.runtimeAvailable {
    shortcuts.append(contentsOf: YoumuFeatureShortcutCatalog.all.map { $0.makeShortcutItem() })
  }
  for index in shortcuts.indices {
    shortcuts[index].isBuiltIn = true
    shortcuts[index].recoveryID = ShortcutRecoveryIdentity.make(
      commandID: shortcuts[index].commandID,
      actionID: shortcuts[index].action.rawValue,
      target: shortcuts[index].target)
  }
  return shortcuts
}

func commonShortcutTemplates() -> [ShortcutItem] {
  [
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 \(AppRuntimeIdentity.current.displayName)",
      scope: "App",
      key: "E",
      modifiers: ["control", "option", "command"],
      action: .openApp,
      target: "bundle:\(AppRuntimeIdentity.current.bundleIdentifier)",
      enabled: true,
      note: "打开、置前或收起\(AppRuntimeIdentity.current.displayName)。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 Chrome",
      scope: "App",
      key: "E",
      modifiers: ["control", "option"],
      action: .openApp,
      target: "bundle:com.google.Chrome",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开飞书",
      scope: "App",
      key: "S",
      modifiers: ["control", "option"],
      action: .openApp,
      target: "bundle:com.bytedance.macos.feishu",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 滴答清单",
      scope: "App",
      key: "D",
      modifiers: ["control", "option"],
      action: .openApp,
      target: "bundle:com.TickTick.task.mac",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 Obsidian",
      scope: "App",
      key: "D",
      modifiers: ["control", "option", "command"],
      action: .openApp,
      target: "bundle:md.obsidian",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开微信",
      scope: "App",
      key: "X",
      modifiers: ["control", "option"],
      action: .openApp,
      target: "bundle:com.tencent.xinWeChat",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 Codex",
      scope: "App",
      key: "C",
      modifiers: ["control", "option"],
      action: .openApp,
      target: "bundle:com.openai.codex",
      enabled: true,
      note: "App 打开 / 置前 / 再按隐藏。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "1/2 左分屏",
      scope: "窗口",
      key: "Left",
      modifiers: ["control", "option"],
      action: .windowPreset,
      target: WindowPreset.leftHalf.rawValue,
      enabled: true,
      note: "把当前窗口放到屏幕左半边。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "1/2 右分屏",
      scope: "窗口",
      key: "Right",
      modifiers: ["control", "option"],
      action: .windowPreset,
      target: WindowPreset.rightHalf.rawValue,
      enabled: true,
      note: "把当前窗口放到屏幕右半边。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "窗口化全屏",
      scope: "窗口",
      key: "F",
      modifiers: ["control", "option"],
      action: .windowPreset,
      target: WindowPreset.maximize.rawValue,
      enabled: true,
      note: "Caps + F：窗口化全屏，保留 Dock 和顶部菜单栏/状态栏，左右上下 100% 铺满可用区域，再按一次恢复。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "窗口居中",
      scope: "窗口",
      key: "Up",
      modifiers: ["control", "option", "command"],
      action: .windowPreset,
      target: WindowPreset.center.rawValue,
      enabled: true,
      note: "保持原大小居中。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "全屏",
      scope: "窗口",
      key: "F",
      modifiers: ["control", "option", "command"],
      action: .nativeFullScreen,
      target: "entireScreen",
      enabled: true,
      note: "Caps + ⌘ + F：按一下进入全屏，再按一下退出。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开 Emoji 与符号",
      scope: "常用脚本",
      key: "B",
      modifiers: ["control", "option"],
      action: .sendShortcut,
      target: "⌃ ⌘ Space",
      enabled: true,
      note: "打开系统 Emoji 与符号面板。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "输入井号 #",
      scope: "常用脚本",
      key: "3",
      modifiers: ["control", "option"],
      action: .insertText,
      target: "#",
      enabled: true,
      note: "在当前光标处输入 #。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "偏好设置",
      scope: "系统辅助",
      key: "`",
      modifiers: ["control", "option"],
      action: .sendShortcut,
      target: "⌘ ,",
      enabled: true,
      note: "给触发时的前台 App 发送 ⌘ 逗号；在本 App 内直接打开设置。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "系统设置",
      scope: "常用脚本",
      key: "`",
      modifiers: ["control", "option", "command"],
      action: .openApp,
      target: "bundle:com.apple.systempreferences",
      enabled: true,
      note: "打开系统设置。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "番茄闹钟",
      scope: "系统辅助",
      key: "G",
      modifiers: ["control", "option"],
      action: .runShell,
      target: "shortcuts run '番茄闹钟'",
      enabled: true,
      note: "通过系统快捷指令运行，可在功能快捷键中调整。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "息屏",
      scope: "常用脚本",
      key: "Escape",
      modifiers: ["control", "option"],
      action: .runShell,
      target: "pmset displaysleepnow",
      enabled: true,
      note: "关闭显示器，Mac 本身保持运行。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "切换无限期保持唤醒",
      scope: "常用脚本",
      key: "X",
      modifiers: ["control", "option", "command"],
      action: .showSleepPanel,
      target: "sleep-infinite-toggle",
      enabled: true,
      note: "按一次无限期保持唤醒，再按一次恢复系统默认睡眠。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开进程查看器",
      scope: "常用脚本",
      key: "J",
      modifiers: ["control", "option"],
      action: .showProcessViewer,
      target: "process-viewer",
      enabled: true,
      note: "打开独立的进程查看器窗口。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开剪贴板历史",
      scope: "常用脚本",
      key: "V",
      modifiers: ["control", "option"],
      trigger: .rightOptionDoubleTap,
      action: .showClipboardHistory,
      target: "clipboard-history",
      enabled: true,
      note: "连按物理右 Option 两次：打开剪贴板历史并开始搜索；再连按两次收起。"
    ),
    ShortcutItem(
      id: UUID().uuidString,
      name: "打开测试网速",
      scope: "常用脚本",
      key: "T",
      modifiers: ["control", "option"],
      action: .showCodexNetworkProbe,
      target: "codex-network-probe",
      enabled: true,
      note: "一个球测下载、上传、延迟和抖动，一个球测 Codex 四轮连通与响应。"
    ),
  ]
}
