import CryptoKit
import Foundation
import MacAutomationCore
import MacFeatureCatalog

/// Application use-case adapter. The transport has no access to files, AppModel or permissions.
/// Every write uses the same create/update/delete methods as the native interface.
@MainActor
final class AutomationService {
  private let model: AppModel
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()
  private static let editableFields: Set<String> = [
    "name", "hotkey", "enabled", "note", "scope", "action", "target",
  ]
  private static let creatableActions: Set<ShortcutAction> = [
    .openApp, .openURL, .insertText, .showPanel, .showLauncher,
    .showProcessViewer, .showClipboardHistory, .showCodexNetworkProbe, .showSleepPanel,
    .windowPreset, .nativeFullScreen, .closeWindowSmart, .sendShortcut,
  ]

  init(model: AppModel) {
    self.model = model
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
  }

  func handle(_ input: Data) -> Data {
    var requestID: String?
    let response: AutomationResponse
    do {
      guard input.count <= 262_144 else {
        throw failure("request_too_large", "请求超过 256 KB。")
      }
      let request = try decoder.decode(AutomationRequest.self, from: input)
      requestID = request.requestID
      if let id = request.requestID, id.isEmpty || id.utf8.count > 128 {
        throw failure("invalid_request", "请求编号必须为 1–128 字节。")
      }
      if let id = request.targetID, id.isEmpty || id.utf8.count > 256 {
        throw failure("invalid_request", "目标 ID 无效。")
      }
      response = try execute(request)
    } catch {
      response = AutomationResponse(
        ok: false, requestID: requestID, revision: model.shortcutConfiguration.revision,
        runtimeStatus: model.automationRuntimeStatus,
        error: error as? AutomationError
          ?? failure("invalid_request", error.localizedDescription))
    }
    return (try? encoder.encode(response))
      ?? Data(#"{"schemaVersion":1,"ok":false,"error":{"code":"encoding_failed","message":"无法编码结果"}}"#.utf8)
  }

  private func execute(_ request: AutomationRequest) throws -> AutomationResponse {
    switch request.operation {
    case "status":
      try requireEmptyPayload(request)
      return success(request, data: .object([
        "product": .string("小龙哥 Mac 哲学"),
        "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
        "configurationLoaded": .bool(model.shortcutConfiguration.committedItems != nil),
        "diskRevision": .string(try model.shortcutConfiguration.diskRevision()),
        "configurationPendingEdit": .bool(
          model.hasActiveShortcutEditors || model.shortcutConfiguration.committedItems != model.items),
        "accessibilityAuthorized": .bool(model.advancedListeningAuthorized),
        "inputMonitoringAuthorized": .bool(model.inputMonitoringAuthorized),
        "shortcutCount": .integer(Int64(model.items.count)),
      ]))
    case "shortcuts.list":
      try requireEmptyPayload(request)
      return success(request, data: .array(try model.items.map(shortcutValue)))
    case "shortcuts.get":
      try requireEmptyPayload(request)
      return success(request, data: try shortcutValue(findItem(request.targetID)))
    case "features.list":
      try requireEmptyPayload(request)
      guard request.targetID == nil else {
        throw failure("invalid_request", "功能目录不接受 targetId；查看具体功能请用 help。")
      }
      return success(request, data: .array(try ProductFeatureCatalog.all.map(featureValue)))
    case "help":
      try requireEmptyPayload(request)
      return success(request, data: try help(request.targetID))
    case "requests.get":
      try requireEmptyPayload(request)
      guard let id = request.targetID,
        let receipt = try model.shortcutConfiguration.receipt(requestID: id)
      else { throw failure("request_not_found", "找不到该请求的提交记录；不要据此重复执行。") }
      return success(request, data: try value(receipt))
    case "shortcuts.add", "shortcuts.update", "shortcuts.delete":
      return try mutate(request)
    default:
      throw failure("unknown_operation", "不支持的操作。请先运行 xlg schema --json。")
    }
  }

  private func mutate(_ request: AutomationRequest) throws -> AutomationResponse {
    let requestData = try encoder.encode(request)
    if !request.dryRun, let id = request.requestID,
      let receipt = try model.shortcutConfiguration.receipt(requestID: id, requestData: requestData)
    {
      return AutomationResponse(
        ok: true, requestID: id, revision: receipt.afterRevision,
        changed: receipt.beforeRevision != receipt.afterRevision, persisted: true,
        runtimeStatus: model.automationRuntimeStatus,
        data: try value(receipt), warnings: ["这是原请求的提交回执，没有重复修改；当前状态请重新查询。"])
    }

    guard let revision = model.shortcutConfiguration.revision,
      let committed = model.shortcutConfiguration.committedItems
    else { throw failure("configuration_unavailable", "请先在软件内恢复快捷键配置。") }
    guard !model.hasActiveShortcutEditors, committed == model.items else {
      throw failure("configuration_busy", "界面里有尚未保存的修改，请完成或取消后再试。")
    }
    guard !model.isChangingShortcutConfiguration else {
      throw failure("configuration_busy", "正在更新配置，请完成后再试。")
    }
    guard try model.shortcutConfiguration.diskRevision() == revision else {
      throw failure("revision_conflict", "配置已在外部修改，请重新打开软件后读取最新配置。")
    }
    if let expected = request.expectedRevision, expected != revision {
      throw failure("revision_conflict", "配置已变化，请重新读取并预览。")
    }
    if !request.dryRun {
      guard request.requestID != nil, request.expectedRevision != nil else {
        throw failure("write_context_required", "保存须携带 requestId 和最新 expectedRevision。")
      }
    }
    guard model.recordingItemID == nil, !model.isDraftShortcutRecording,
      !model.isCapturingShortcutAction
    else { throw failure("recording_in_progress", "正在录制快捷键，结束录制后再修改。") }

    let previous: ShortcutItem?
    var candidate: ShortcutItem?
    switch request.operation {
    case "shortcuts.add":
      guard request.targetID == nil else {
        throw failure("invalid_request", "新增快捷键不接受 targetId，ID 由软件分配。")
      }
      previous = nil
      let seed = request.requestID ?? "preview"
      let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
      let initial = ShortcutItem(
        id: "ai-\(digest)", isBuiltIn: false, name: "", scope: "全部应用",
        key: "", modifiers: [], action: .openApp, target: "", enabled: true, note: "")
      candidate = try applyPayload(request.payload, to: initial, creating: true)
    case "shortcuts.update":
      let current = try findItem(request.targetID)
      previous = current
      candidate = try applyPayload(request.payload, to: current, creating: false)
    default:
      try requireEmptyPayload(request)
      let current = try findItem(request.targetID)
      guard current.isBuiltIn == false, model.canDeleteShortcut(id: current.id) else {
        throw failure("protected_shortcut", "CLI 只删除用户自建快捷键；内置功能请改键或停用。")
      }
      previous = current
      candidate = nil
    }
    candidate = candidate.map { model.normalizedShortcutDraft($0, id: $0.id) }
    if let candidate {
      guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw failure("invalid_name", "功能名称不能为空。")
      }
      _ = try ShortcutConfigurationCodec.decode(ShortcutConfigurationService.encode([candidate]))
      if let issue = model.shortcutIssue(for: candidate), issue.kind.isBlocking {
        throw AutomationError(
          code: "shortcut_conflict", message: "\(issue.kind.label)：\(issue.suggestion)",
          details: ["kind": .string(issue.kind.rawValue), "object": .string(issue.object)])
      }
    }
    let preview: AutomationValue = .object([
      "operation": .string(request.operation),
      "before": try previous.map(value) ?? .null,
      "after": try candidate.map(value) ?? .null,
    ])
    if request.dryRun {
      return success(request, data: preview, warnings: ["预览通过，尚未保存或注册快捷键。"])
    }

    guard let requestID = request.requestID, let expectedRevision = request.expectedRevision else {
      throw failure("write_context_required", "缺少提交上下文。")
    }
    model.shortcutConfiguration.mutationContext = .init(
      requestID: requestID, requestData: requestData, expectedRevision: expectedRevision)
    defer { model.shortcutConfiguration.mutationContext = nil }
    let saved: Bool
    if request.operation == "shortcuts.add", let candidate {
      saved = model.createShortcut(from: candidate)
    } else if request.operation == "shortcuts.update", let candidate {
      saved = model.updateShortcut(id: candidate.id, draft: candidate)
    } else if let previous {
      model.deleteShortcut(id: previous.id)
      saved = !model.items.contains { $0.id == previous.id }
    } else {
      saved = false
    }
    guard saved else {
      if let failure = model.shortcutConfiguration.lastFailure { throw failure }
      throw failure("mutation_rejected", model.statusMessage)
    }
    guard let receipt = try model.shortcutConfiguration.receipt(
      requestID: requestID, requestData: requestData)
    else {
      throw failure("result_unknown", "修改结果暂时无法核实，请用原 requestId 查询，不要重复提交。")
    }
    return AutomationResponse(
      ok: true, requestID: requestID, revision: model.shortcutConfiguration.revision,
      changed: receipt.beforeRevision != receipt.afterRevision, persisted: true,
      runtimeStatus: model.automationRuntimeStatus,
      data: .object(["change": preview, "receipt": try value(receipt)]),
      warnings: model.automationRuntimeStatus == "registered"
        ? [] : ["配置已保存；请按 runtimeStatus 核对后台快捷键当前状态。"])
  }

  private func applyPayload(
    _ payload: [String: AutomationValue], to original: ShortcutItem, creating: Bool
  ) throws -> ShortcutItem {
    guard !payload.isEmpty, Set(payload.keys).isSubset(of: Self.editableFields) else {
      throw failure("invalid_payload", "修改字段为空或包含不支持的字段。")
    }
    // Managed rows retain semantic ownership. AI may change their chord and enabled state.
    if !creating, original.isBuiltIn != false || original.commandID != nil {
      guard Set(payload.keys).isSubset(of: ["hotkey", "enabled"]) else {
        throw failure("protected_shortcut", "内置快捷键只能改键或启停。")
      }
    }
    var result = original
    func string(_ key: String) throws -> String? {
      guard let supplied = payload[key] else { return nil }
      guard case .string(let text) = supplied else {
        throw failure("invalid_payload", "\(key) 必须是文字。")
      }
      return text
    }
    if let text = try string("name") { result.name = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let text = try string("scope") { result.scope = text }
    if let text = try string("note") { result.note = text }
    if let text = try string("target") { result.target = text }
    if let raw = try string("action") {
      guard let action = ShortcutAction(rawValue: raw), Self.creatableActions.contains(action) else {
        throw failure("unsupported_action", "该动作尚未开放给 CLI。请查询 features list。")
      }
      result.action = action
    }
    if let enabled = payload["enabled"] {
      guard case .bool(let flag) = enabled else {
        throw failure("invalid_payload", "enabled 必须是 true 或 false。")
      }
      result.enabled = flag
    }
    if let text = try string("hotkey") {
      let chord = try HotkeyChord.parse(text)
      guard keyCode(for: chord.key) != nil else {
        throw failure("unsupported_key", "当前 Mac 不支持该按键。")
      }
      guard !chord.modifiers.isEmpty || !requiresModifier(chord.key) else {
        throw failure("modifier_required", "普通按键需要搭配 Caps、Command、Option 或 Control。")
      }
      result.key = chord.key
      result.modifiers = chord.modifiers
      result.trigger = nil
    } else if creating {
      throw failure("hotkey_required", "新增快捷键须提供 hotkey，例如 Caps+K。")
    }
    if creating || payload["action"] != nil || payload["target"] != nil {
      guard Self.creatableActions.contains(result.action) else {
        throw failure("unsupported_action", "CLI 不创建或改写 Shell 命令。")
      }
      if result.action == .openURL {
        guard let url = URL(string: result.target),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host?.isEmpty == false
        else { throw failure("invalid_target", "网址须是完整的 http 或 https 地址。") }
      }
      if result.action == .sendShortcut {
        let chord = try HotkeyChord.parse(result.target)
        guard keyCode(for: chord.key) != nil else {
          throw failure("invalid_target", "要发送的快捷键不受支持。")
        }
        guard !chord.modifiers.isEmpty || canUseBareSendShortcut(chord.key) else {
          throw failure("invalid_target", "要发送的普通按键须搭配修饰键。")
        }
        result.target = chord.canonical
      }
      if result.action == .windowPreset {
        guard WindowArrangementAction(rawValue: result.target) != nil else {
          throw failure("invalid_target", "窗口动作无效。")
        }
      }
    }
    return result
  }

  private func findItem(_ id: String?) throws -> ShortcutItem {
    guard let id, let item = model.items.first(where: { $0.id == id }) else {
      throw failure("shortcut_not_found", "未找到快捷键，请先读取列表并使用其中的 ID。")
    }
    return item
  }

  private func shortcutValue(_ item: ShortcutItem) throws -> AutomationValue {
    guard case .object(var fields) = try value(item) else { return .null }
    let managed = item.isBuiltIn != false || item.commandID != nil
    fields["hotkey"] = .string(item.displayHotkey)
    fields["canDelete"] = .bool(!managed && model.canDeleteShortcut(id: item.id))
    fields["editableFields"] = .array(
      (managed ? ["hotkey", "enabled"] : Self.editableFields.sorted()).map(AutomationValue.string))
    fields["runtimeStatus"] = .string(model.automationRuntimeStatus(for: item))
    return .object(fields)
  }

  private func help(_ id: String?) throws -> AutomationValue {
    if let id, let feature = ProductFeatureCatalog.feature(id: id) {
      return try featureValue(feature)
    }
    if let id, let item = model.items.first(where: { $0.id == id || $0.commandID == id }) {
      return .object([
        "shortcut": try shortcutValue(item),
        "usage": .string(item.note.isEmpty ? "按已设置的快捷键使用。窗口类功能再按一次收起。" : item.note),
      ])
    }
    if let id, id != "shortcuts" {
      throw failure("feature_not_found", "没有这个功能 ID，请先读取 features list。")
    }
    return .object([
      "features": .array(try ProductFeatureCatalog.all.map(featureValue)),
      "shortcuts": .array(try model.items.map(shortcutValue)),
      "creatableActions": .array(Self.creatableActions.map(\.rawValue).sorted().map(AutomationValue.string)),
      "editableFields": .array(Self.editableFields.sorted().map(AutomationValue.string)),
      "payloadSchema": .object([
        "name": .string("string; required for add"),
        "hotkey": .string("string; required for add; e.g. Caps+K or command+shift+K"),
        "action": .string("creatableActions value; default openApp"),
        "target": .string("application bundle:ID or path, http(s) URL, text, chord, or window action"),
        "enabled": .string("boolean; default true"),
        "scope": .string("string; display category"),
        "note": .string("string; optional description"),
      ]),
      "example": .object([
        "name": .string("打开 Safari"), "hotkey": .string("Caps+J"),
        "action": .string("openApp"), "target": .string("bundle:com.apple.Safari"),
      ]),
      "workflow": .array([
        .string("读取 shortcuts list，按唯一 ID 选择现有项；有重名时不要猜。"),
        .string("用 --dry-run 验证配置和冲突。"),
        .string("携带列表的 revision 和唯一 requestId 提交，再回读。"),
        .string("结果未知时查询 requests get；不要换请求编号重复写入。"),
      ]),
    ])
  }

  private func featureValue(_ feature: ProductFeatureDescriptor) throws -> AutomationValue {
    guard case .object(var fields) = try value(feature) else { return .null }
    let shortcuts = model.items.filter {
      feature.matchesShortcut(action: $0.action.rawValue, commandID: $0.commandID)
    }
    fields["categoryTitle"] = .string(feature.category.title)
    fields["modeTitle"] = .string(feature.mode.title)
    fields["shortcuts"] = .array(try shortcuts.map(shortcutValue))
    fields["cliCapabilities"] = .object([
      "help": .bool(true),
      "editLinkedShortcuts": .bool(!shortcuts.isEmpty),
      "configureFeature": .bool(false),
      "invokeFeature": .bool(false),
    ])
    return .object(fields)
  }

  private func requireEmptyPayload(_ request: AutomationRequest) throws {
    guard request.payload.isEmpty else {
      throw failure("invalid_payload", "该操作不接受 payload 字段。")
    }
  }

  private func success(
    _ request: AutomationRequest, data: AutomationValue, warnings: [String] = []
  ) -> AutomationResponse {
    AutomationResponse(
      ok: true, requestID: request.requestID, revision: model.shortcutConfiguration.revision,
      runtimeStatus: model.automationRuntimeStatus, data: data, warnings: warnings)
  }

  private func value<T: Encodable>(_ value: T) throws -> AutomationValue {
    try decoder.decode(AutomationValue.self, from: encoder.encode(value))
  }

  private func failure(_ code: String, _ message: String) -> AutomationError {
    AutomationError(code: code, message: message)
  }
}
