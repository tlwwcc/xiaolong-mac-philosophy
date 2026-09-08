import Foundation

enum InputMethodBuiltInTarget {
  static var launcherIdentifier: String {
    "\(AppRuntimeIdentity.current.bundleIdentifier).launcher"
  }
  static let abcSelectionID = "com.apple.keylayout.ABC"
}

struct InputMethodAppCandidate: Identifiable, Hashable {
  let name: String
  let bundleIdentifier: String
  let path: String

  var id: String { bundleIdentifier }
}

enum InputMethodAppCandidateResolver {
  static func normalized(
    _ candidates: [InputMethodAppCandidate],
    ownBundleIdentifier: String?
  ) -> [InputMethodAppCandidate] {
    var seen = Set<String>()
    return
      candidates
      .filter { candidate in
        let bundleID = candidate.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.name.isEmpty, !bundleID.isEmpty, !candidate.path.isEmpty else {
          return false
        }
        return seen.insert(bundleID.lowercased()).inserted
      }
      .sorted { lhs, rhs in
        let lhsIsOwn = lhs.bundleIdentifier == ownBundleIdentifier
        let rhsIsOwn = rhs.bundleIdentifier == ownBundleIdentifier
        if lhsIsOwn != rhsIsOwn { return lhsIsOwn }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }
}

enum InputMethodScopedOverridePolicy {
  static func restorationSelectionID(
    previousSelectionID: String?,
    currentSelectionID: String?,
    overrideSelectionID: String?
  ) -> String? {
    guard let previousSelectionID, !previousSelectionID.isEmpty,
      let overrideSelectionID, currentSelectionID == overrideSelectionID,
      previousSelectionID != overrideSelectionID
    else { return nil }
    return previousSelectionID
  }
}

struct InputMethodSourceDescriptor: Codable, Hashable, Identifiable {
  let sourceID: String
  let inputModeID: String?
  let name: String
  let languages: [String]

  init(
    sourceID: String,
    inputModeID: String?,
    name: String,
    languages: [String] = []
  ) {
    self.sourceID = sourceID
    self.inputModeID = inputModeID
    self.name = name
    self.languages = languages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceID = try container.decode(String.self, forKey: .sourceID)
    inputModeID = try container.decodeIfPresent(String.self, forKey: .inputModeID)
    name = try container.decode(String.self, forKey: .name)
    languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
  }

  var id: String { selectionID }
  var selectionID: String { inputModeID ?? sourceID }
}

struct InputMethodAppRule: Codable, Hashable, Identifiable {
  var id: String
  var appName: String
  var bundleIdentifier: String
  var appPath: String
  var sourceSelectionID: String
  var enabled: Bool
}

struct InputMethodRulesDocument: Codable, Equatable {
  static let currentVersion = 1

  var version: Int
  var rules: [InputMethodAppRule]

  init(version: Int = Self.currentVersion, rules: [InputMethodAppRule]) {
    self.version = version
    self.rules = rules
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    guard version == Self.currentVersion else {
      throw InputMethodRulesFormatError.unsupportedRulesVersion(version)
    }
    rules = try container.decode([InputMethodAppRule].self, forKey: .rules)
  }
}

enum InputMethodSwitchDecision: Equatable {
  case pluginDisabled
  case invalidApplication
  case noRule
  case ruleDisabled
  case alreadySelected
  case switchTo(String)
}

enum InputMethodRuleResolver {
  static func decision(
    pluginEnabled: Bool,
    bundleIdentifier: String?,
    currentSelectionID: String?,
    rules: [InputMethodAppRule]
  ) -> InputMethodSwitchDecision {
    guard pluginEnabled else { return .pluginDisabled }
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return .invalidApplication }
    guard
      let rule = rules.first(where: {
        $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
      })
    else { return .noRule }
    guard rule.enabled else { return .ruleDisabled }
    guard !rule.sourceSelectionID.isEmpty else { return .noRule }
    guard rule.sourceSelectionID != currentSelectionID else { return .alreadySelected }
    return .switchTo(rule.sourceSelectionID)
  }

  static func normalized(_ rules: [InputMethodAppRule]) -> [InputMethodAppRule] {
    InputMethodRuleAnalyzer.analyze(rules, availableSelectionIDs: nil).rules
  }
}

enum InputMethodRuleDiagnosticKind: String, Codable {
  case emptyRule
  case duplicateApplication
  case unavailableInputSource
}

struct InputMethodRuleDiagnostic: Identifiable, Equatable {
  let id: String
  let kind: InputMethodRuleDiagnosticKind
  let appName: String
  let detailText: String

  var isRepairable: Bool {
    kind == .emptyRule || kind == .duplicateApplication
  }
}

struct InputMethodRuleAnalysis: Equatable {
  let rules: [InputMethodAppRule]
  let diagnostics: [InputMethodRuleDiagnostic]

  var repairableCount: Int {
    diagnostics.filter(\.isRepairable).count
  }

  var unavailableSourceCount: Int {
    diagnostics.filter { $0.kind == .unavailableInputSource }.count
  }
}

enum InputMethodRuleAnalyzer {
  static func analyze(
    _ rules: [InputMethodAppRule],
    availableSelectionIDs: Set<String>?
  ) -> InputMethodRuleAnalysis {
    var normalizedRules: [InputMethodAppRule] = []
    var diagnostics: [InputMethodRuleDiagnostic] = []
    var seenBundleIDs = Set<String>()

    for (index, originalRule) in rules.enumerated() {
      var rule = originalRule
      rule.appName = rule.appName.trimmingCharacters(in: .whitespacesAndNewlines)
      rule.bundleIdentifier = rule.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
      rule.appPath = rule.appPath.trimmingCharacters(in: .whitespacesAndNewlines)
      rule.sourceSelectionID = rule.sourceSelectionID.trimmingCharacters(
        in: .whitespacesAndNewlines)

      let displayName = rule.appName.isEmpty ? "第 \(index + 1) 条规则" : rule.appName
      guard !rule.bundleIdentifier.isEmpty, !rule.sourceSelectionID.isEmpty else {
        diagnostics.append(
          InputMethodRuleDiagnostic(
            id: "empty-\(index)-\(rule.id)",
            kind: .emptyRule,
            appName: displayName,
            detailText: "Bundle ID 或输入法标识为空，已忽略这条规则。"))
        continue
      }

      let normalizedBundleID = rule.bundleIdentifier.lowercased()
      guard seenBundleIDs.insert(normalizedBundleID).inserted else {
        diagnostics.append(
          InputMethodRuleDiagnostic(
            id: "duplicate-\(index)-\(rule.id)",
            kind: .duplicateApplication,
            appName: displayName,
            detailText: "同一个 App 只能保留一条规则，已采用列表中较早的一条。"))
        continue
      }

      normalizedRules.append(rule)
      if let availableSelectionIDs,
        !availableSelectionIDs.contains(rule.sourceSelectionID)
      {
        diagnostics.append(
          InputMethodRuleDiagnostic(
            id: "unavailable-\(index)-\(rule.id)",
            kind: .unavailableInputSource,
            appName: displayName,
            detailText: "目标输入法当前未启用；规则已保留，触发时会报告明确失败。"))
      }
    }

    return InputMethodRuleAnalysis(rules: normalizedRules, diagnostics: diagnostics)
  }
}

enum InputMethodRulesFormatError: LocalizedError, Equatable {
  case invalidJSON
  case invalidBackupKind
  case unsupportedRulesVersion(Int)
  case unsupportedBackupVersion(Int)
  case noUsableRules
  case fileTooLarge(maximumBytes: Int)
  case tooManyRules(maximumCount: Int)
  case fieldTooLong(field: String, maximumBytes: Int)

  var errorDescription: String? {
    switch self {
    case .invalidJSON:
      return "文件不是有效的输入法规则 JSON。"
    case .invalidBackupKind:
      return "这不是“小龙哥 Mac 哲学”的输入法规则备份。"
    case .unsupportedRulesVersion(let version):
      return "规则文件版本 \(version) 暂不支持，请用较新的 App 导出兼容备份。"
    case .unsupportedBackupVersion(let version):
      return "备份格式版本 \(version) 暂不支持，请用较新的 App 处理。"
    case .noUsableRules:
      return "文件中没有可用规则；当前规则未被修改。"
    case .fileTooLarge(let maximumBytes):
      return "规则文件超过 \(maximumBytes / 1_048_576) MiB 安全上限；当前规则未被修改。"
    case .tooManyRules(let maximumCount):
      return "规则数量超过 \(maximumCount) 条安全上限；当前规则未被修改。"
    case .fieldTooLong(let field, let maximumBytes):
      return "规则中的“\(field)”超过 \(maximumBytes) 字节安全上限；当前规则未被修改。"
    }
  }
}

struct InputMethodRulesBackupDocument: Codable, Equatable {
  static let kind = "aixlg-input-method-rules"
  static let currentSchemaVersion = 1

  let kind: String
  let schemaVersion: Int
  let appVersion: String
  let appBuild: String
  let exportedAt: Date
  let rules: [InputMethodAppRule]
}

struct InputMethodRuleImportResult: Equatable {
  let sourceDescription: String
  let rawRuleCount: Int
  let analysis: InputMethodRuleAnalysis
}

enum InputMethodRulesCodec {
  static let maximumFileBytes = 1_048_576
  static let maximumRuleCount = 512
  static let maximumRuleIDBytes = 128
  static let maximumAppNameBytes = 256
  static let maximumBundleIdentifierBytes = 512
  static let maximumAppPathBytes = 4_096
  static let maximumSourceSelectionIDBytes = 512
  static let maximumVersionLabelBytes = 128

  static func loadBoundedData(from url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw InputMethodRulesFormatError.invalidJSON
    }
    try validateFileByteCount(fileSize)
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try validateFileByteCount(data.count)
    return data
  }

  static func encodePersistedRules(_ rules: [InputMethodAppRule]) throws -> Data {
    try validateRules(rules)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(InputMethodRulesDocument(rules: rules))
    try validateFileByteCount(data.count)
    return data
  }

  static func encodeBackup(
    rules: [InputMethodAppRule],
    appVersion: String,
    appBuild: String,
    exportedAt: Date = Date()
  ) throws -> Data {
    try validateRules(rules)
    try validateString(appVersion, field: "App 版本", maximumBytes: maximumVersionLabelBytes)
    try validateString(appBuild, field: "构建号", maximumBytes: maximumVersionLabelBytes)
    let document = InputMethodRulesBackupDocument(
      kind: InputMethodRulesBackupDocument.kind,
      schemaVersion: InputMethodRulesBackupDocument.currentSchemaVersion,
      appVersion: appVersion,
      appBuild: appBuild,
      exportedAt: exportedAt,
      rules: rules)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    try validateFileByteCount(data.count)
    return data
  }

  static func decodePersistedRules(from data: Data) throws -> InputMethodRulesDocument {
    _ = try preflightRoot(from: data)
    return try decodePersistedRulesAfterPreflight(from: data)
  }

  private static func decodePersistedRulesAfterPreflight(
    from data: Data
  ) throws -> InputMethodRulesDocument {
    do {
      let document = try JSONDecoder().decode(InputMethodRulesDocument.self, from: data)
      try validateRules(document.rules)
      return document
    } catch let error as InputMethodRulesFormatError {
      throw error
    } catch {
      throw InputMethodRulesFormatError.invalidJSON
    }
  }

  static func decodeImport(
    from data: Data,
    availableSelectionIDs: Set<String>
  ) throws -> InputMethodRuleImportResult {
    let root = try preflightRoot(from: data)

    let rules: [InputMethodAppRule]
    let sourceDescription: String
    if root["kind"] != nil || root["schemaVersion"] != nil {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let backup: InputMethodRulesBackupDocument
      do {
        backup = try decoder.decode(InputMethodRulesBackupDocument.self, from: data)
      } catch {
        throw InputMethodRulesFormatError.invalidJSON
      }
      guard backup.kind == InputMethodRulesBackupDocument.kind else {
        throw InputMethodRulesFormatError.invalidBackupKind
      }
      guard backup.schemaVersion == InputMethodRulesBackupDocument.currentSchemaVersion else {
        throw InputMethodRulesFormatError.unsupportedBackupVersion(backup.schemaVersion)
      }
      try validateString(
        backup.appVersion,
        field: "App 版本",
        maximumBytes: maximumVersionLabelBytes)
      try validateString(
        backup.appBuild,
        field: "构建号",
        maximumBytes: maximumVersionLabelBytes)
      try validateRules(backup.rules)
      rules = backup.rules
      sourceDescription =
        "备份 \(CustomerVersionFormatter.backupVersion(version: backup.appVersion, build: backup.appBuild))"
    } else {
      let document = try decodePersistedRulesAfterPreflight(from: data)
      rules = document.rules
      sourceDescription = "旧版规则文件"
    }

    let analysis = InputMethodRuleAnalyzer.analyze(
      rules,
      availableSelectionIDs: availableSelectionIDs)
    if !rules.isEmpty, analysis.rules.isEmpty {
      throw InputMethodRulesFormatError.noUsableRules
    }
    return InputMethodRuleImportResult(
      sourceDescription: sourceDescription,
      rawRuleCount: rules.count,
      analysis: analysis)
  }

  private static func preflightRoot(from data: Data) throws -> [String: Any] {
    try validateFileByteCount(data.count)
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any],
      let rawRules = root["rules"] as? [Any]
    else {
      throw InputMethodRulesFormatError.invalidJSON
    }
    guard rawRules.count <= maximumRuleCount else {
      throw InputMethodRulesFormatError.tooManyRules(maximumCount: maximumRuleCount)
    }
    return root
  }

  private static func validateFileByteCount(_ byteCount: Int) throws {
    guard byteCount <= maximumFileBytes else {
      throw InputMethodRulesFormatError.fileTooLarge(maximumBytes: maximumFileBytes)
    }
  }

  private static func validateRules(_ rules: [InputMethodAppRule]) throws {
    guard rules.count <= maximumRuleCount else {
      throw InputMethodRulesFormatError.tooManyRules(maximumCount: maximumRuleCount)
    }
    for rule in rules {
      try validateString(rule.id, field: "规则 ID", maximumBytes: maximumRuleIDBytes)
      try validateString(rule.appName, field: "App 名称", maximumBytes: maximumAppNameBytes)
      try validateString(
        rule.bundleIdentifier,
        field: "Bundle ID",
        maximumBytes: maximumBundleIdentifierBytes)
      try validateString(rule.appPath, field: "App 路径", maximumBytes: maximumAppPathBytes)
      try validateString(
        rule.sourceSelectionID,
        field: "输入法标识",
        maximumBytes: maximumSourceSelectionIDBytes)
    }
  }

  private static func validateString(
    _ value: String,
    field: String,
    maximumBytes: Int
  ) throws {
    guard value.utf8.count <= maximumBytes else {
      throw InputMethodRulesFormatError.fieldTooLong(
        field: field,
        maximumBytes: maximumBytes)
    }
  }
}

enum InputMethodBoundedSelectionAction: Equatable {
  case confirmed
  case retry
  case stopUnconfirmed
}

enum InputMethodBoundedSelectionPolicy {
  static let maximumRequests = 2

  static func nextAction(
    currentSelectionID: String?,
    targetSelectionID: String,
    requestsMade: Int
  ) -> InputMethodBoundedSelectionAction {
    if currentSelectionID == targetSelectionID { return .confirmed }
    if requestsMade < maximumRequests { return .retry }
    return .stopUnconfirmed
  }
}

enum InputMethodConflictMatcher {
  static func isCompetingTool(name: String) -> Bool {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("自动切换输入法") { return true }
    return [
      "autoswitchinput", "autoswitchinput pro", "input source pro", "inputswitcher", "switchkey",
    ].contains(normalized)
  }
}

enum InputMethodPluginStatus: Equatable {
  case stopped
  case ready(Int)
  case noRules
  case conflict([String])
  case switched(appName: String, sourceName: String, requestsMade: Int)
  case failed(String)

  var displayText: String {
    switch self {
    case .stopped: return "已关闭"
    case .ready: return "监听中"
    case .noRules: return "未设置规则"
    case .conflict: return "冲突，已让位"
    case .switched: return "已切换"
    case .failed: return "切换失败"
    }
  }

  var detailText: String {
    switch self {
    case .stopped:
      return "关闭时不会监听 App 切换，也不会改变输入法。"
    case .ready(let count):
      return "正在监听前台 App，已启用 \(count) 条规则。"
    case .noRules:
      return "插件已开启；添加 App 规则后才会切换输入法。"
    case .conflict(let names):
      return
        "检测到同类工具正在运行：\(names.joined(separator: "、"))。"
        + "两个工具会争抢同一输入法，本插件已停止执行；关闭其中一个即可，现有规则不会丢失。"
    case .switched(let appName, let sourceName, let requestsMade):
      if requestsMade > 1 {
        return "已为 \(appName) 切换到 \(sourceName)；首次结果未确认，单次重试后成功。"
      }
      return "已为 \(appName) 切换到 \(sourceName)。"
    case .failed(let message):
      return message
    }
  }
}

enum InputMethodConflictRecoveryPolicy {
  static func shouldReapplyCurrentRule(
    wasBlockedByConflict: Bool,
    pluginEnabled: Bool,
    conflictsAreClear: Bool,
    hasFrontmostApplication: Bool
  ) -> Bool {
    wasBlockedByConflict && pluginEnabled && conflictsAreClear && hasFrontmostApplication
  }
}
