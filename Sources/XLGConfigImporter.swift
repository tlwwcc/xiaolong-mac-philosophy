import CryptoKit
import Darwin
import Foundation

struct XLGConfigProcessResult {
  let terminationStatus: Int32?
  let standardOutput: String
  let standardError: String
  let outputWasTruncated: Bool
  let errorWasTruncated: Bool
  let timedOut: Bool
  let launchError: String?

  var succeeded: Bool {
    launchError == nil && !timedOut && terminationStatus == 0
  }
}

private final class XLGConfigProcessOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let byteLimit: Int
  private var data = Data()
  private var truncated = false

  init(byteLimit: Int) {
    self.byteLimit = max(0, byteLimit)
  }

  func append(_ incoming: Data) {
    guard !incoming.isEmpty else { return }
    lock.lock()
    let remaining = max(0, byteLimit - data.count)
    if remaining > 0 { data.append(incoming.prefix(remaining)) }
    if incoming.count > remaining { truncated = true }
    lock.unlock()
  }

  func value() -> (String, Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (String(decoding: data, as: UTF8.self), truncated)
  }
}

enum XLGConfigProcessRunner {
  static func run(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval = 2,
    outputByteLimit: Int = 65_536
  ) -> XLGConfigProcessResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let output = XLGConfigProcessOutputBuffer(byteLimit: outputByteLimit)
    let error = XLGConfigProcessOutputBuffer(byteLimit: outputByteLimit)
    let terminated = DispatchSemaphore(value: 0)
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    outputPipe.fileHandleForReading.readabilityHandler = { handle in
      output.append(handle.availableData)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      error.append(handle.availableData)
    }
    process.terminationHandler = { _ in terminated.signal() }

    let launchError: String?
    do {
      try process.run()
      launchError = nil
    } catch {
      launchError = error.localizedDescription
    }

    var didTimeOut = false
    var didTerminate = launchError != nil
    if launchError == nil {
      didTerminate = terminated.wait(timeout: .now() + max(0.05, timeout)) == .success
      if !didTerminate {
        didTimeOut = true
        if process.isRunning { process.terminate() }
        didTerminate = terminated.wait(timeout: .now() + 0.3) == .success
        if !didTerminate, process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          didTerminate = terminated.wait(timeout: .now() + 0.5) == .success
        }
      }
      // Let the continuously draining handlers consume bytes already queued by the kernel. Never
      // wait for EOF: a descendant may still own an inherited write descriptor.
      usleep(50_000)
    }

    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    try? outputPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForReading.close()
    let (standardOutput, outputWasTruncated) = output.value()
    let (standardError, errorWasTruncated) = error.value()
    let status =
      launchError == nil && didTerminate && !process.isRunning
      ? process.terminationStatus : nil
    return XLGConfigProcessResult(
      terminationStatus: status,
      standardOutput: standardOutput,
      standardError: standardError,
      outputWasTruncated: outputWasTruncated,
      errorWasTruncated: errorWasTruncated,
      timedOut: didTimeOut,
      launchError: launchError)
  }
}

enum XLGConfigImportError: LocalizedError {
  case invalidManifestURL
  case untrustedConfigURL(URL)
  case unsupportedSchema(Int)
  case checksumMismatch(expected: String, actual: String)
  case invalidUserDefaultsValue(String)
  case invalidPayload(String)
  case unsafeShortcut(String)
  case missingKarabinerElements
  case unreadableKarabinerConfig(backupURL: URL?)
  case rollbackFailed(original: Error, rollback: Error)

  var errorDescription: String? {
    switch self {
    case .invalidManifestURL:
      return "小龙哥配置下载地址无效。"
    case .untrustedConfigURL(let url):
      return "配置下载地址不受信任：\(url.absoluteString)"
    case .unsupportedSchema(let schema):
      return "小龙哥配置格式版本不支持：\(schema)"
    case .checksumMismatch(let expected, let actual):
      return "配置校验失败：期望 \(expected)，实际 \(actual)。"
    case .invalidUserDefaultsValue(let key):
      return "配置项格式不支持：\(key)"
    case .invalidPayload(let reason):
      return "配置内容不符合安全格式：\(reason)"
    case .unsafeShortcut(let name):
      return "未受信任的配置不能加入 Shell 动作：\(name)"
    case .missingKarabinerElements:
      return "还没安装 Karabiner-Elements。请先安装并打开一次 Karabiner，再回来导入 Caps 入口键。"
    case .unreadableKarabinerConfig(let backupURL):
      if let backupURL {
        return "Karabiner 配置文件读不出来。已保留原文件备份：\(backupURL.path)。请重新打开 Karabiner 后再导入；如果仍失败，把错误反馈给小龙哥。"
      }
      return "Karabiner 配置文件读不出来。请重新打开 Karabiner 后再导入；如果仍失败，把错误反馈给小龙哥。"
    case .rollbackFailed(let original, let rollback):
      return "导入失败且回滚未完全成功：\(original.localizedDescription)；回滚错误：\(rollback.localizedDescription)"
    }
  }
}

struct XLGConfigImportRequest {
  var applicationSupportURL: URL
  var shortcutsURL: URL
  var phrasesURL: URL
  var inputMethodRulesURL: URL
  var launcherPinnedURL: URL
  var youmuSettingsURL: URL
  var defaults: UserDefaults
  var pdfDefaults: UserDefaults
  var allowNetworkDownload: Bool
  var includeKarabiner: Bool
  var manifestURL: URL
  var karabinerAppURL: URL
  var karabinerConfigURL: URL
  var karabinerCLIURL: URL

  init(
    applicationSupportURL: URL,
    shortcutsURL: URL,
    phrasesURL: URL,
    defaults: UserDefaults,
    allowNetworkDownload: Bool,
    includeKarabiner: Bool,
    manifestURL: URL,
    karabinerAppURL: URL,
    karabinerConfigURL: URL,
    karabinerCLIURL: URL,
    inputMethodRulesURL: URL? = nil,
    launcherPinnedURL: URL? = nil,
    youmuSettingsURL: URL? = nil,
    pdfDefaults: UserDefaults? = nil
  ) {
    self.applicationSupportURL = applicationSupportURL
    self.shortcutsURL = shortcutsURL
    self.phrasesURL = phrasesURL
    self.inputMethodRulesURL =
      inputMethodRulesURL
      ?? applicationSupportURL.appendingPathComponent("input-method-rules.json")
    self.launcherPinnedURL =
      launcherPinnedURL
      ?? applicationSupportURL.appendingPathComponent("launcher-pinned.json")
    self.youmuSettingsURL =
      youmuSettingsURL
      ?? applicationSupportURL.appendingPathComponent("Features/Youmu/settings.json")
    self.defaults = defaults
    self.pdfDefaults = pdfDefaults ?? defaults
    self.allowNetworkDownload = allowNetworkDownload
    self.includeKarabiner = includeKarabiner
    self.manifestURL = manifestURL
    self.karabinerAppURL = karabinerAppURL
    self.karabinerConfigURL = karabinerConfigURL
    self.karabinerCLIURL = karabinerCLIURL
  }

  static func appDefault(
    applicationSupportURL: URL,
    shortcutsURL: URL,
    phrasesURL: URL,
    allowNetworkDownload: Bool = false
  ) -> XLGConfigImportRequest {
    XLGConfigImportRequest(
      applicationSupportURL: applicationSupportURL,
      shortcutsURL: shortcutsURL,
      phrasesURL: phrasesURL,
      defaults: .standard,
      allowNetworkDownload: allowNetworkDownload,
      // “最佳配置”只管理本 App；Karabiner 仍由独立入口显式导入。
      includeKarabiner: false,
      manifestURL: URL(string: "https://aixlg.com/configs/xlg-config-latest.json")!,
      karabinerAppURL: URL(
        fileURLWithPath: "/Applications/Karabiner-Elements.app",
        isDirectory: true),
      karabinerConfigURL: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/karabiner/karabiner.json"),
      karabinerCLIURL: URL(
        fileURLWithPath:
          "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"),
      pdfDefaults: UserDefaults(
        suiteName: "cn.tlww.aixlg.hotkeys.feature.pijuan-pdf"))
  }
}

struct XLGCapsEntryKeyImportResult {
  var message: String
  var backupURL: URL?
}

struct XLGConfigImportResult {
  var sourceDescription: String
  var backupURL: URL
  var shortcutsCount: Int
  var phrasesCount: Int
  var appliedUserDefaultsCount: Int
  var karabinerMessage: String
  var warnings: [String]

  var summary: String {
    var parts = ["已恢复小龙哥最佳配置，原配置已备份。"]
    if !karabinerMessage.isEmpty {
      parts.append(karabinerMessage)
    }
    if !warnings.isEmpty {
      parts.append(warnings.joined(separator: " "))
    }
    return parts.joined(separator: " ")
  }
}

enum XLGConfigSourceTrust {
  case bundled
  case untrusted
}

struct XLGConfigManifest: Codable {
  var schema: Int
  var name: String
  var version: String
  var url: URL
  var sha256: String
  var minimumAppBuild: Int?
}

struct XLGConfigPayload: Codable {
  var schema: Int
  var app: XLGConfigAppPayload
  var karabiner: XLGKarabinerPayload?
  var configurationDate: String? = nil
}

struct XLGConfigAppPayload: Codable {
  var shortcuts: [ShortcutItem]
  var phrases: [PhraseItem]
  var userDefaults: [String: XLGConfigJSONValue]
  var launcherPinned: XLGConfigJSONValue? = nil
  var youmuSettings: XLGConfigJSONValue? = nil
  var pdfShortcuts: XLGConfigJSONValue? = nil
}

struct XLGKarabinerPayload: Codable {
  var importCapsEntryKeyRule: Bool
}

enum XLGConfigJSONValue: Codable, Equatable {
  case string(String)
  case bool(Bool)
  case int(Int)
  case double(Double)
  case array([XLGConfigJSONValue])
  case object([String: XLGConfigJSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([XLGConfigJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: XLGConfigJSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }

  var propertyListValue: Any? {
    switch self {
    case .string(let value):
      return value
    case .bool(let value):
      return value
    case .int(let value):
      return value
    case .double(let value):
      return value
    case .array(let values):
      return values.compactMap(\.propertyListValue)
    case .object:
      return nil
    case .null:
      return nil
    }
  }

  var jsonObject: Any {
    switch self {
    case .string(let value):
      return value
    case .bool(let value):
      return value
    case .int(let value):
      return value
    case .double(let value):
      return value
    case .array(let values):
      return values.map(\.jsonObject)
    case .object(let object):
      return object.mapValues(\.jsonObject)
    case .null:
      return NSNull()
    }
  }
}

enum XLGConfigImporter {
  private static let payloadSchema = 1
  private static let maximumPayloadBytes = 1_048_576
  private static let maximumRecordCount = 500
  private static let userDefaultsBackupName = "selected-user-defaults.plist"
  private static let backupManifestName = "backup-manifest.json"

  static let allowlistedUserDefaultsKeys: Set<String> = [
    "capsCorePluginEnabledV1",
    "inputMethodPluginEnabledV1",
    "inputMethodLauncherRuleSeededV1",
    "deletedShortcutNamesV1",
    "deletedShortcutRecoveryIDsV1",
    "shortcutSemanticCapsSpaceChoiceFingerprintV1",
    "shortcutSemanticCommandSpaceChoiceFingerprintV1",
    "shortcutSemanticMigrationUndoFingerprintV1",
    "shortcutDefaultBaselineVersionV1",
    "selectedOptimizationIDs",
    "selectedOptimizationIDsVersion",
    "sleepStatusItemVisibleV1",
    "networkSpeedPluginEnabledV1",
    "systemHealthMonitorEnabledV1",
    "networkSpeedShowMemoryV1",
    "networkSpeedShowCPUV1",
    "networkSpeedShowGPUV1",
    "networkSpeedDisplayOptionsVersionV1",
    "mouseVolumePluginUserSetV1",
    "scrollEngineUserSetEnabledV1",
    "scrollEngineSettings",
    "keepAwakePreventDisplaySleep",
    "keepAwakeCustomHours",
    "launcherDisplayModeV1",
    "launcherShowsPinnedNamesV1",
    "launcherSearchEngineV1",
    "launcherPluginEnabledV1",
    "showDockIconV1",
    "menuBarVisibleCatalogItemIDsV1",
    "menuBarCatalogConfigurationVersionV1",
    "processViewerPluginEnabledV1",
    "processViewerShowSystemProcessesV1",
    "codexNetworkProbePluginEnabledV1",
    "codexNetworkProbeDefaultDirectionV1",
    "classicTabSwitcherEnabledV1",
    "classicTabSwitcherCommandTabTakeoverConfirmedV1",
    "classicTabSwitcherDemotionV1",
    "classicTabSwitcherBuiltInRouteV1",
    "classicTabSwitcherRetiredV1",
    "commandWProtectionBundleIDs",
    "diagnosticsEnabled",
    "clipboardHistory.excludedApplicationsV1",
    "clipboardHistory.enabledV1",
    "clipboardHistory.retentionDaysV1",
    "clipboardHistory.maxBytesV1",
    "youmu.editor.arrow-style",
    "cn.tlww.aixlg.hotkeys.feature.youmu.defaults.selection-reader.font-scale",
  ]

  private static let acceptedUserDefaultsKeys =
    allowlistedUserDefaultsKeys.union(RetiredShiftInputSourcePreferences.keys)

  private static let karabinerRuleDescription = "小龙哥入口键：Caps Lock → Control+Option"
  private static let oldKarabinerRuleDescriptions: Set<String> = [
    karabinerRuleDescription,
    "Caps Lock → Control+Option",
    "Caps Lock -> Control+Option",
    "小龙哥入口键：Caps Lock -> Control+Option",
  ]

  private enum MissingKarabinerBehavior {
    case skip
    case fail
  }

  private struct KarabinerImportResult {
    var message: String
    var backupURL: URL?
  }

  static func importRecommendedConfig(
    request: XLGConfigImportRequest
  ) async throws -> XLGConfigImportResult {
    try importBundledConfiguration(request: request)
  }

  /// Detect an entirely new configuration. Missing shortcuts alone never means a new user:
  /// any existing managed file (even malformed/a broken symlink) or preference preserves the profile.
  static func installBundledConfigurationIfNeeded(
    request: XLGConfigImportRequest
  ) throws -> XLGConfigImportResult? {
    let files = [
      request.shortcutsURL, request.phrasesURL, request.inputMethodRulesURL,
      request.launcherPinnedURL, request.youmuSettingsURL,
    ]
    for file in files {
      var info = stat()
      if lstat(file.path, &info) == 0 { return nil }
      if errno != ENOENT { return nil }
    }
    if allowlistedUserDefaultsKeys.contains(where: { request.defaults.object(forKey: $0) != nil })
      || request.pdfDefaults.object(forKey: pdfShortcutsKey) != nil
    {
      return nil
    }
    return try importBundledConfiguration(request: request)
  }

  /// A synchronous transaction for the first launch after the caller has verified no existing
  /// user configuration is present. Ordinary upgrades must not invoke this automatically.
  static func importBundledConfiguration(
    request: XLGConfigImportRequest
  ) throws -> XLGConfigImportResult {
    try importConfigData(
      builtInConfigData(),
      sourceDescription: "小龙哥配置 · \(bundledConfigurationDate)",
      warnings: [], sourceTrust: .bundled, request: request, replaceManagedConfiguration: true)
  }

  static func importConfigData(
    _ data: Data,
    sourceDescription: String,
    warnings: [String] = [],
    sourceTrust: XLGConfigSourceTrust = .untrusted,
    request: XLGConfigImportRequest
  ) throws -> XLGConfigImportResult {
    try importConfigData(
      data,
      sourceDescription: sourceDescription,
      warnings: warnings,
      sourceTrust: sourceTrust,
      request: request,
      replaceManagedConfiguration: false)
  }

  static func importConfigData(
    _ data: Data,
    sourceDescription: String,
    warnings: [String],
    sourceTrust: XLGConfigSourceTrust,
    request: XLGConfigImportRequest,
    replaceManagedConfiguration: Bool
  ) throws -> XLGConfigImportResult {
    try validatePayloadShape(data, sourceTrust: sourceTrust)
    let decoder = JSONDecoder()
    let payload = try decoder.decode(XLGConfigPayload.self, from: data)
    guard payload.schema == payloadSchema else {
      throw XLGConfigImportError.unsupportedSchema(payload.schema)
    }
    if sourceTrust == .untrusted,
      let unsafe = payload.app.shortcuts.first(where: { $0.action == .runShell })
    {
      throw XLGConfigImportError.unsafeShortcut(unsafe.name)
    }

    var importedShortcuts = payload.app.shortcuts
    if sourceTrust == .untrusted {
      for index in importedShortcuts.indices {
        importedShortcuts[index].id = UUID().uuidString
        importedShortcuts[index].commandID = nil
        importedShortcuts[index].recoveryID = nil
        importedShortcuts[index].isBuiltIn = false
      }
    }

    let backup = try makeBackup(request: request)
    do {
      try write(importedShortcuts, to: request.shortcutsURL)
      try write(payload.app.phrases, to: request.phrasesURL)
      if replaceManagedConfiguration {
        try writeJSONObject(["version": 1, "rules": []], to: request.inputMethodRulesURL)
        try writeJSONObject(
          payload.app.launcherPinned?.jsonObject ?? ["version": 1, "items": []],
          to: request.launcherPinnedURL)
        try writeJSONObject(
          payload.app.youmuSettings?.jsonObject ?? [:], to: request.youmuSettingsURL)
        clearManagedUserDefaults(request.defaults)
        try applyPDFShortcuts(payload.app.pdfShortcuts, defaults: request.pdfDefaults)
      }
      let appliedDefaults = try applyUserDefaults(
        payload.app.userDefaults,
        defaults: request.defaults)
      let karabinerMessage: String
      if request.includeKarabiner, payload.karabiner?.importCapsEntryKeyRule == true {
        karabinerMessage = try importKarabinerRule(
          request: request,
          backupURL: backup.directoryURL,
          missingKarabinerBehavior: .skip
        ).message
      } else {
        karabinerMessage = ""
      }
      return XLGConfigImportResult(
        sourceDescription: sourceDescription,
        backupURL: backup.directoryURL,
        shortcutsCount: importedShortcuts.count,
        phrasesCount: payload.app.phrases.count,
        appliedUserDefaultsCount: appliedDefaults,
        karabinerMessage: karabinerMessage,
        warnings: warnings)
    } catch {
      do {
        try rollback(backup: backup, request: request)
      } catch let rollbackError {
        throw XLGConfigImportError.rollbackFailed(original: error, rollback: rollbackError)
      }
      throw error
    }
  }

  /// The signed App must contain the exact frozen snapshot. Command-line fixtures may read the
  /// source-adjacent resource; an installed App never falls back to the working directory.
  static func builtInConfigData() throws -> Data {
    #if AIXLG_FORMAL_RELEASE
      // Fixture source paths must never become string literals in a signed App.
      let resourceURL = Bundle.main.url(
        forResource: "XLGDefaultConfiguration", withExtension: "json")
    #else
      let resourceURL: URL?
      if let bundledURL = Bundle.main.url(
        forResource: "XLGDefaultConfiguration", withExtension: "json")
      {
        resourceURL = bundledURL
      } else if Bundle.main.bundleURL.pathExtension != "app" {
        resourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent().appendingPathComponent(
            "Resources/XLGDefaultConfiguration.json")
      } else {
        resourceURL = nil
      }
    #endif
    guard let resourceURL else {
      throw XLGConfigImportError.invalidPayload("安装包缺少日期配置，请重新安装最新版本")
    }
    let data = try LocalConfigurationFileCodec.readData(
      from: resourceURL, maximumBytes: maximumPayloadBytes)
    try validatePayloadShape(data, sourceTrust: .bundled)
    return data
  }

  static var bundledConfigurationDate: String {
    guard let data = try? builtInConfigData(),
      let payload = try? JSONDecoder().decode(XLGConfigPayload.self, from: data),
      let date = payload.configurationDate
    else { return "配置不可用" }
    return date
  }

  static let pdfShortcutsKey = "feature.pijuan-pdf.shortcut-configuration-v1"

  private static func applyPDFShortcuts(_ value: XLGConfigJSONValue?, defaults: UserDefaults) throws
  {
    if let value, value != .null {
      let data = try JSONSerialization.data(
        withJSONObject: value.jsonObject, options: [.sortedKeys])
      defaults.set(data, forKey: pdfShortcutsKey)
    } else {
      defaults.removeObject(forKey: pdfShortcutsKey)
    }
    defaults.synchronize()
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func importCapsEntryKeyRule(
    request: XLGConfigImportRequest
  ) throws -> XLGCapsEntryKeyImportResult {
    let backupURL = request.applicationSupportURL
      .appendingPathComponent("backups", isDirectory: true)
      .appendingPathComponent("karabiner-caps-entry-key-\(timestamp())", isDirectory: true)
    let result = try importKarabinerRule(
      request: request,
      backupURL: backupURL,
      missingKarabinerBehavior: .fail)
    return XLGCapsEntryKeyImportResult(message: result.message, backupURL: result.backupURL)
  }

  private static func validatePayloadShape(
    _ data: Data,
    sourceTrust: XLGConfigSourceTrust
  ) throws {
    guard data.count <= maximumPayloadBytes else {
      throw XLGConfigImportError.invalidPayload("文件超过 1 MB")
    }
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys).isSubset(of: ["schema", "app", "karabiner", "configurationDate"]),
      root["schema"] is NSNumber,
      let app = root["app"] as? [String: Any],
      Set(["shortcuts", "phrases", "userDefaults"]).isSubset(of: Set(app.keys)),
      Set(app.keys).isSubset(of: [
        "shortcuts", "phrases", "userDefaults", "launcherPinned", "youmuSettings", "pdfShortcuts",
      ]),
      let shortcuts = app["shortcuts"] as? [[String: Any]],
      let phrases = app["phrases"] as? [[String: Any]],
      let userDefaults = app["userDefaults"] as? [String: Any]
    else {
      throw XLGConfigImportError.invalidPayload("顶层字段不完整或含未知字段")
    }
    if sourceTrust == .untrusted,
      root["configurationDate"] != nil || app["launcherPinned"] != nil
        || app["youmuSettings"] != nil || app["pdfShortcuts"] != nil
    {
      throw XLGConfigImportError.invalidPayload("外部配置不能声明打包配置或写入内置功能设置")
    }
    if let date = root["configurationDate"] {
      guard let date = date as? String,
        date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
        phrases.isEmpty,
        app["launcherPinned"] is [String: Any],
        app["youmuSettings"] is [String: Any]
      else { throw XLGConfigImportError.invalidPayload("日期配置不完整或含个人短语") }
    }
    guard shortcuts.count <= maximumRecordCount, phrases.count <= maximumRecordCount else {
      throw XLGConfigImportError.invalidPayload("记录数量超过 500 条")
    }
    let requiredShortcutKeys: Set<String> = [
      "id", "name", "scope", "key", "modifiers", "action", "target", "enabled", "note",
    ]
    let optionalUserShortcutKeys: Set<String> = ["trigger"]
    let managedShortcutKeys: Set<String> = ["commandID", "recoveryID", "isBuiltIn"]
    let phraseKeys: Set<String> = ["id", "trigger", "output", "enabled", "note"]
    let allowsManagedShortcutKeys: Bool
    switch sourceTrust {
    case .bundled:
      allowsManagedShortcutKeys = true
    case .untrusted:
      allowsManagedShortcutKeys = false
    }
    guard
      shortcuts.allSatisfy({
        let keys = Set($0.keys)
        guard requiredShortcutKeys.isSubset(of: keys) else { return false }
        if allowsManagedShortcutKeys {
          return keys.isSubset(
            of: requiredShortcutKeys.union(optionalUserShortcutKeys).union(managedShortcutKeys))
        }
        return keys.isSubset(of: requiredShortcutKeys.union(optionalUserShortcutKeys))
      })
    else {
      throw XLGConfigImportError.invalidPayload("快捷键字段不符合固定结构")
    }
    guard phrases.allSatisfy({ Set($0.keys) == phraseKeys }) else {
      throw XLGConfigImportError.invalidPayload("快捷短语字段不符合固定结构")
    }
    guard Set(userDefaults.keys).isSubset(of: acceptedUserDefaultsKeys) else {
      throw XLGConfigImportError.invalidPayload("包含未允许的设置项")
    }
    if let karabiner = root["karabiner"] as? [String: Any],
      Set(karabiner.keys) != ["importCapsEntryKeyRule"]
    {
      throw XLGConfigImportError.invalidPayload("Karabiner 字段不符合固定结构")
    }
    for shortcut in shortcuts {
      try validateString(shortcut["name"], field: "快捷键名称", maximumLength: 200)
      try validateString(shortcut["target"], field: "快捷键目标", maximumLength: 8192)
      try validateString(shortcut["note"], field: "快捷键说明", maximumLength: 4096)
      if let rawTrigger = shortcut["trigger"] {
        guard
          let trigger = rawTrigger as? [String: Any],
          Set(trigger.keys) == ["kind", "modifier"],
          trigger["kind"] as? String == ShortcutTrigger.Kind.modifierDoubleTap.rawValue,
          let modifier = trigger["modifier"] as? String,
          PhysicalModifierKey(rawValue: modifier) != nil
        else {
          throw XLGConfigImportError.invalidPayload("快捷键触发方式不受支持")
        }
      }
    }
    for phrase in phrases {
      try validateString(phrase["trigger"], field: "短语触发词", maximumLength: 256)
      try validateString(phrase["output"], field: "短语内容", maximumLength: 65_536)
      try validateString(phrase["note"], field: "短语说明", maximumLength: 4096)
    }
  }

  private static func validateString(_ value: Any?, field: String, maximumLength: Int) throws {
    guard let value = value as? String, value.count <= maximumLength else {
      throw XLGConfigImportError.invalidPayload("\(field)格式或长度无效")
    }
  }

  private struct BackupRecord: Codable {
    var directoryPath: String
    var shortcutsExisted: Bool
    var phrasesExisted: Bool
    var inputMethodRulesExisted: Bool
    var launcherPinnedExisted: Bool
    var youmuSettingsExisted: Bool
    var karabinerExisted: Bool
  }

  private struct BackupState {
    var directoryURL: URL
    var shortcutsExisted: Bool
    var phrasesExisted: Bool
    var inputMethodRulesExisted: Bool
    var launcherPinnedExisted: Bool
    var youmuSettingsExisted: Bool
    var karabinerExisted: Bool
  }

  private static func makeBackup(request: XLGConfigImportRequest) throws -> BackupState {
    let backupURL = request.applicationSupportURL
      .appendingPathComponent("backups", isDirectory: true)
      .appendingPathComponent("xlg-config-import-\(timestamp())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: backupURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    let shortcutsExisted = FileManager.default.fileExists(atPath: request.shortcutsURL.path)
    if shortcutsExisted {
      try FileManager.default.copyItem(
        at: request.shortcutsURL,
        to: backupURL.appendingPathComponent("shortcuts.json"))
    }

    let phrasesExisted = FileManager.default.fileExists(atPath: request.phrasesURL.path)
    if phrasesExisted {
      try FileManager.default.copyItem(
        at: request.phrasesURL,
        to: backupURL.appendingPathComponent("phrases.json"))
    }

    let inputMethodRulesExisted = try backupFileIfPresent(
      request.inputMethodRulesURL,
      to: backupURL.appendingPathComponent("input-method-rules.json"))
    let launcherPinnedExisted = try backupFileIfPresent(
      request.launcherPinnedURL,
      to: backupURL.appendingPathComponent("launcher-pinned.json"))
    let youmuSettingsExisted = try backupFileIfPresent(
      request.youmuSettingsURL,
      to: backupURL.appendingPathComponent("youmu-settings.json"))

    try backupUserDefaults(
      request.defaults, to: backupURL.appendingPathComponent(userDefaultsBackupName))

    try backupUserDefaults(
      request.pdfDefaults, to: backupURL.appendingPathComponent("pdf-shortcuts.plist"),
      keys: [pdfShortcutsKey])

    let karabinerExisted = FileManager.default.fileExists(atPath: request.karabinerConfigURL.path)
    if request.includeKarabiner, karabinerExisted {
      try FileManager.default.copyItem(
        at: request.karabinerConfigURL,
        to: backupURL.appendingPathComponent("karabiner.json"))
    }

    let record = BackupRecord(
      directoryPath: backupURL.path,
      shortcutsExisted: shortcutsExisted,
      phrasesExisted: phrasesExisted,
      inputMethodRulesExisted: inputMethodRulesExisted,
      launcherPinnedExisted: launcherPinnedExisted,
      youmuSettingsExisted: youmuSettingsExisted,
      karabinerExisted: karabinerExisted)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(
      to: backupURL.appendingPathComponent(backupManifestName), options: [.atomic])
    return BackupState(
      directoryURL: backupURL,
      shortcutsExisted: shortcutsExisted,
      phrasesExisted: phrasesExisted,
      inputMethodRulesExisted: inputMethodRulesExisted,
      launcherPinnedExisted: launcherPinnedExisted,
      youmuSettingsExisted: youmuSettingsExisted,
      karabinerExisted: karabinerExisted)
  }

  private static func rollback(backup: BackupState, request: XLGConfigImportRequest) throws {
    try restoreFile(
      original: request.shortcutsURL,
      backup: backup.directoryURL.appendingPathComponent("shortcuts.json"),
      existed: backup.shortcutsExisted)
    try restoreFile(
      original: request.phrasesURL,
      backup: backup.directoryURL.appendingPathComponent("phrases.json"),
      existed: backup.phrasesExisted)
    try restoreFile(
      original: request.inputMethodRulesURL,
      backup: backup.directoryURL.appendingPathComponent("input-method-rules.json"),
      existed: backup.inputMethodRulesExisted)
    try restoreFile(
      original: request.launcherPinnedURL,
      backup: backup.directoryURL.appendingPathComponent("launcher-pinned.json"),
      existed: backup.launcherPinnedExisted)
    try restoreFile(
      original: request.youmuSettingsURL,
      backup: backup.directoryURL.appendingPathComponent("youmu-settings.json"),
      existed: backup.youmuSettingsExisted)
    try restoreUserDefaults(
      request.defaults,
      from: backup.directoryURL.appendingPathComponent(userDefaultsBackupName))
    try restoreUserDefaults(
      request.pdfDefaults, from: backup.directoryURL.appendingPathComponent("pdf-shortcuts.plist"),
      keys: [pdfShortcutsKey])
    if request.includeKarabiner {
      try restoreFile(
        original: request.karabinerConfigURL,
        backup: backup.directoryURL.appendingPathComponent("karabiner.json"),
        existed: backup.karabinerExisted)
    }
  }

  private static func restoreFile(original: URL, backup: URL, existed: Bool) throws {
    try? FileManager.default.removeItem(at: original)
    if existed {
      try FileManager.default.createDirectory(
        at: original.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: backup, to: original)
    }
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }

  private static func writeJSONObject(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
  }

  private static func backupFileIfPresent(_ source: URL, to destination: URL) throws -> Bool {
    let existed = FileManager.default.fileExists(atPath: source.path)
    if existed {
      try FileManager.default.copyItem(at: source, to: destination)
    }
    return existed
  }

  private static func backupUserDefaults(
    _ defaults: UserDefaults, to url: URL, keys: Set<String> = allowlistedUserDefaultsKeys
  ) throws {
    var snapshot: [String: Any] = [:]
    var presentKeys: [String] = []
    for key in keys.sorted() {
      guard let object = defaults.object(forKey: key) else { continue }
      presentKeys.append(key)
      snapshot[key] = object
    }
    snapshot["_presentKeys"] = presentKeys
    let data = try PropertyListSerialization.data(
      fromPropertyList: snapshot,
      format: .xml,
      options: 0)
    try data.write(to: url, options: [.atomic])
  }

  private static func restoreUserDefaults(
    _ defaults: UserDefaults, from url: URL, keys: Set<String> = allowlistedUserDefaultsKeys
  ) throws {
    let data = try LocalConfigurationFileCodec.readData(from: url)
    guard
      let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let presentKeys = snapshot["_presentKeys"] as? [String]
    else { return }

    for key in keys {
      if presentKeys.contains(key), let value = snapshot[key] {
        defaults.set(value, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    defaults.synchronize()
  }

  @discardableResult
  private static func applyUserDefaults(
    _ values: [String: XLGConfigJSONValue],
    defaults: UserDefaults
  ) throws -> Int {
    var applied = 0
    for (key, value) in values {
      guard allowlistedUserDefaultsKeys.contains(key) else { continue }
      switch (key, value) {
      case ("scrollEngineSettings", .object), ("clipboardHistory.excludedApplicationsV1", .array):
        // These consumers read JSON Data, not plist dictionaries/arrays. In particular an array
        // of exclusion objects must not pass through propertyListValue's compactMap.
        let data = try JSONSerialization.data(
          withJSONObject: value.jsonObject,
          options: [.sortedKeys])
        defaults.set(data, forKey: key)
      case (_, .null):
        defaults.removeObject(forKey: key)
      case ("scrollEngineSettings", _), ("clipboardHistory.excludedApplicationsV1", _):
        throw XLGConfigImportError.invalidUserDefaultsValue(key)
      default:
        guard let propertyListValue = value.propertyListValue else {
          throw XLGConfigImportError.invalidUserDefaultsValue(key)
        }
        defaults.set(propertyListValue, forKey: key)
      }
      applied += 1
    }
    defaults.synchronize()
    return applied
  }

  private static func clearManagedUserDefaults(_ defaults: UserDefaults) {
    for key in allowlistedUserDefaultsKeys {
      defaults.removeObject(forKey: key)
    }
    defaults.synchronize()
  }

  private static func importKarabinerRule(
    request: XLGConfigImportRequest,
    backupURL: URL,
    missingKarabinerBehavior: MissingKarabinerBehavior
  ) throws -> KarabinerImportResult {
    guard FileManager.default.fileExists(atPath: request.karabinerAppURL.path) else {
      switch missingKarabinerBehavior {
      case .skip:
        return KarabinerImportResult(message: "未检测到 Karabiner-Elements，已跳过入口键规则导入。", backupURL: nil)
      case .fail:
        throw XLGConfigImportError.missingKarabinerElements
      }
    }

    try FileManager.default.createDirectory(
      at: request.karabinerConfigURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let karabinerBackupURL = try backupKarabinerConfigIfNeeded(
      from: request.karabinerConfigURL,
      to: backupURL)
    let root: [String: Any]
    do {
      root = try loadKarabinerRoot(from: request.karabinerConfigURL)
    } catch {
      throw XLGConfigImportError.unreadableKarabinerConfig(backupURL: karabinerBackupURL)
    }

    var updatedRoot = root
    var profiles = root["profiles"] as? [[String: Any]] ?? []
    if profiles.isEmpty {
      profiles = [defaultKarabinerProfile()]
    }

    let selectedIndex =
      profiles.firstIndex {
        ($0["selected"] as? Bool) == true
      } ?? 0

    var profile = profiles[selectedIndex]
    var complex = profile["complex_modifications"] as? [String: Any] ?? [:]
    var rules = complex["rules"] as? [[String: Any]] ?? []
    rules.removeAll { rule in
      guard let description = rule["description"] as? String else { return false }
      return oldKarabinerRuleDescriptions.contains(description)
    }
    rules.insert(capsLockEntryKeyRule(), at: 0)
    complex["rules"] = rules
    profile["complex_modifications"] = complex
    profiles[selectedIndex] = profile
    updatedRoot["profiles"] = profiles

    let data = try JSONSerialization.data(
      withJSONObject: updatedRoot,
      options: [.prettyPrinted, .sortedKeys])
    try data.write(to: request.karabinerConfigURL, options: [.atomic])
    refreshKarabinerProfileIfPossible(cliURL: request.karabinerCLIURL)
    return KarabinerImportResult(
      message: "已导入 Caps 入口键：Caps Lock 会变成 Control + Option。",
      backupURL: karabinerBackupURL)
  }

  private static func backupKarabinerConfigIfNeeded(
    from configURL: URL,
    to backupDirectoryURL: URL
  ) throws -> URL? {
    guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
    try FileManager.default.createDirectory(
      at: backupDirectoryURL,
      withIntermediateDirectories: true)
    let backupURL = backupDirectoryURL.appendingPathComponent("karabiner.json")
    if !FileManager.default.fileExists(atPath: backupURL.path) {
      try FileManager.default.copyItem(at: configURL, to: backupURL)
    }
    return backupURL
  }

  private static func loadKarabinerRoot(from url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return [
        "global": ["show_in_menu_bar": false],
        "profiles": [defaultKarabinerProfile()],
      ]
    }
    let data = try LocalConfigurationFileCodec.readData(from: url)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any] else {
      throw XLGConfigImportError.invalidUserDefaultsValue("karabiner.json")
    }
    return root
  }

  private static func refreshKarabinerProfileIfPossible(cliURL: URL) {
    guard FileManager.default.isExecutableFile(atPath: cliURL.path) else { return }
    guard let currentProfile = runKarabinerCLI(cliURL, arguments: ["--show-current-profile-name"]),
      !currentProfile.isEmpty
    else { return }
    _ = runKarabinerCLI(cliURL, arguments: ["--select-profile", currentProfile])
  }

  private static func runKarabinerCLI(_ cliURL: URL, arguments: [String]) -> String? {
    let result = XLGConfigProcessRunner.run(
      executableURL: cliURL,
      arguments: arguments,
      timeout: 2,
      outputByteLimit: 65_536)
    guard result.succeeded else { return nil }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func defaultKarabinerProfile() -> [String: Any] {
    [
      "name": "Default profile",
      "selected": true,
      "complex_modifications": ["rules": []],
      "virtual_hid_keyboard": ["keyboard_type_v2": "ansi"],
    ]
  }

  private static func capsLockEntryKeyRule() -> [String: Any] {
    [
      "description": karabinerRuleDescription,
      "manipulators": [
        [
          "from": [
            "key_code": "caps_lock",
            "modifiers": ["optional": ["any"]],
          ],
          "to": [
            [
              "key_code": "left_control",
              "modifiers": ["left_option"],
            ]
          ],
          "type": "basic",
        ]
      ],
    ]
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.string(from: Date()) + "-" + UUID().uuidString.lowercased()
  }
}
