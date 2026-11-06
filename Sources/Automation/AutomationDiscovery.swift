import Foundation

/// The public automation contract is deliberately independent of AppModel and user data.
/// Help and schema must work without starting the application or reading its configuration.
enum AutomationDiscovery {
  static let schemaVersion = 1
  static let installedApplicationPath = "/Applications/小龙哥Mac哲学.app"
  static let installedExecutablePath =
    installedApplicationPath + "/Contents/MacOS/aixlg-hotkeys"
  static let bundleIdentifier = "cn.tlww.aixlg.hotkeys"
  static let teamIdentifier = "TG5Z23NAC2"
  static let maximumRequestBytes = 262_144
  static let maximumResponseBytes = 8_388_608
  static let shortcutActions = [
    "openApp", "openURL", "insertText", "showPanel", "showLauncher", "showProcessViewer",
    "showClipboardHistory", "showCodexNetworkProbe", "showSleepPanel", "windowPreset",
    "nativeFullScreen", "closeWindowSmart", "sendShortcut",
  ]
  static let aiSetupPrompt = """
    请通过我已安装的小龙哥 Mac 哲学管理快捷键。先运行：
    '/Applications/小龙哥Mac哲学.app/Contents/MacOS/aixlg-hotkeys' --cli schema --json
    后续命令沿用同一程序与 --cli 前缀。先查询现状，按返回的稳定 ID 操作；修改先 dry-run，
    再带最新 revision 和唯一 request-id 保存，并回读结果。若超时，查询原 request-id，
    不重复新增；固定功能只改按键或停用。若 App 没运行，先打开已安装 App。
    我的需求：
    """

  static let operations = [
    "status", "features.list", "help", "shortcuts.list", "shortcuts.get",
    "shortcuts.add", "shortcuts.update", "shortcuts.delete", "requests.get",
  ]

  static let helpText = """
    小龙哥 Mac 哲学 · CLI

    告诉你的 AI：「用 xlg 帮我添加或修改快捷键。」
    AI 可先运行 xlg schema --json，按返回的协议操作。

    xlg --help
    xlg schema --json
    xlg status --json
    xlg features list --json
    xlg help <快捷键 ID、命令 ID 或 shortcuts> --json
    xlg shortcuts list --json
    xlg shortcuts get <快捷键 ID> --json
    xlg shortcuts add --input - --dry-run --json
    xlg shortcuts update <快捷键 ID> --input - --if-revision <版本> --request-id <唯一编号> --json
    xlg shortcuts delete <快捷键 ID> --if-revision <版本> --request-id <唯一编号> --json
    xlg requests get <请求编号> --json

    --input - 从标准输入读取 JSON 对象；--input <文件> 读取本地 JSON 文件。
    写入前先预览；正式写入携带最新 revision 和唯一 request-id。
    请求超时后，用原 request-id 查询结果，不要换编号重复提交。
    内置功能仅可改按键或停用，不能删除或转换功能；只有自建快捷键可以删除。
    “已保存”与“当前已生效”分别返回；系统授权仍需在 macOS 中完成。
    除帮助和协议外，需要先打开已安装的小龙哥 Mac 哲学：
    open -g '/Applications/小龙哥Mac哲学.app'
    """

  static var schema: [String: Any] {
    [
      "schemaVersion": schemaVersion,
      "product": "小龙哥 Mac 哲学",
      "cli": "xlg",
      "installedInvocation": [
        "executable": installedExecutablePath,
        "prefixArguments": ["--cli"],
        "pathSetupRequired": false,
      ],
      "aiSetupPrompt": aiSetupPrompt,
      "transport": "local-user-unix-socket",
      "maximumRequestBytes": maximumRequestBytes,
      "operations": operations,
      "request": [
        "required": ["schemaVersion", "requestId", "operation", "payload", "dryRun"],
        "properties": [
          "schemaVersion": ["type": "integer", "const": schemaVersion],
          "requestId": ["type": "string", "maxLength": 128],
          "operation": ["type": "string", "enum": operations],
          "targetId": ["type": "string", "maxLength": 256],
          "payload": ["type": "object"],
          "expectedRevision": ["type": "string", "maxLength": 128],
          "dryRun": ["type": "boolean"],
        ],
        "additionalProperties": false,
      ],
      "response": [
        "fields": [
          "schemaVersion", "ok", "requestId", "revision", "changed", "persisted",
          "runtimeStatus", "data", "error", "warnings",
        ],
        "successRequires": "Read ok; for writes inspect persisted and runtimeStatus separately.",
      ],
      "rules": [
        "Use IDs returned by list, never infer an ID from a display name.",
        "Read the current revision before writing; stale revisions are rejected.",
        "Reuse the same requestId and exact request after an unknown result.",
        "dryRun validates and previews without changing configuration.",
        "Fixed feature shortcuts cannot be deleted or converted to another action.",
        "This interface does not grant macOS permissions or execute arbitrary shell commands.",
      ],
      "payload": [
        "shortcuts.add": [
          "required": ["name", "hotkey"],
          "properties": shortcutPayloadProperties,
          "additionalProperties": false,
          "defaults": ["action": "openApp", "enabled": true, "scope": "全部应用"],
        ],
        "shortcuts.update": [
          "properties": shortcutPayloadProperties,
          "additionalProperties": false,
          "managedShortcutAllowedFields": ["hotkey", "enabled"],
        ],
        "shortcuts.delete": ["properties": [:], "additionalProperties": false],
        "readOperations": ["properties": [:], "additionalProperties": false],
      ],
      "targetId": [
        "shortcuts.get": "ID returned by shortcuts list",
        "shortcuts.update": "ID returned by shortcuts list",
        "shortcuts.delete": "User-created shortcut ID returned by shortcuts list",
        "requests.get": "The original requestId",
        "help": "A shortcut ID, command ID, or shortcuts",
      ],
      "examples": [
        [
          "command": "xlg shortcuts add --input - --dry-run --json",
          "stdin": [
            "name": "打开计算器", "hotkey": "Caps+Shift+C",
            "action": "openApp", "target": "bundle:com.apple.calculator",
          ],
        ],
        [
          "command": "xlg shortcuts update SHORTCUT_ID --input - --if-revision REVISION --request-id REQUEST_ID --json",
          "stdin": ["hotkey": "Caps+Shift+P"],
        ],
        [
          "command": "xlg requests get REQUEST_ID --json",
          "purpose": "Check the original outcome after a timeout; do not invent another request ID.",
        ],
      ],
    ]
  }

  private static var shortcutPayloadProperties: [String: Any] {
    [
      "name": ["type": "string", "description": "用户可见功能名称"],
      "hotkey": ["type": "string", "examples": ["Caps+Shift+C", "Command+Shift+P"]],
      "enabled": ["type": "boolean"],
      "note": ["type": "string"],
      "scope": ["type": "string"],
      "action": ["type": "string", "enum": shortcutActions],
      "target": [
        "type": "string",
        "description": "动作目标；openApp 使用 bundle:应用标识或存在的本机绝对路径，openURL 使用 http(s) 网址。",
      ],
    ]
  }

  static func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func failure(
    code: String,
    message: String,
    requestId: String? = nil,
    details: [String: Any] = [:]
  ) -> Data {
    var error: [String: Any] = ["code": code, "message": message]
    if !details.isEmpty { error["details"] = details }
    let result: [String: Any] = [
      "schemaVersion": schemaVersion,
      "ok": false,
      "requestId": requestId as Any? ?? NSNull(),
      "changed": false,
      "persisted": false,
      "runtimeStatus": "unknown",
      "data": NSNull(),
      "error": error,
      "warnings": [],
    ]
    return (try? jsonData(result)) ?? Data("{\"ok\":false}".utf8)
  }
}
