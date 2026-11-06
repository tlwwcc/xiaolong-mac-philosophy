import Darwin
import Foundation

enum AutomationCLI {
  struct Invocation {
    let request: [String: Any]?
    let offlineOutput: Data?
    let json: Bool
  }

  /// Must run before the GUI's single-instance activation branch.
  static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
    guard arguments.dropFirst().first == "--cli" else { return nil }
    var requestId: String?
    do {
      let invocation = try parse(Array(arguments.dropFirst(2))) { path in
        if path == "-" { return try boundedRead(FileHandle.standardInput) }
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try boundedRead(handle)
      }
      if let output = invocation.offlineOutput {
        writeOutput(output)
        return 0
      }
      guard let request = invocation.request else {
        throw AutomationSocketError(code: "invalidArguments", message: "缺少 CLI 命令。")
      }
      requestId = request["requestId"] as? String
      let response = try AutomationSocketClient().send(AutomationDiscovery.jsonData(request))
      guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
        let ok = object["ok"] as? Bool,
        object["schemaVersion"] as? Int == AutomationDiscovery.schemaVersion
      else {
        throw AutomationSocketError(code: "invalidResponse", message: "CLI 服务返回了不兼容的响应。")
      }
      writeOutput(response)
      return ok ? 0 : 1
    } catch {
      let failure = error as? AutomationSocketError
        ?? AutomationSocketError(code: "invalidInput", message: error.localizedDescription)
      var details: [String: Any] = [:]
      if ["timeout", "connectionClosed", "invalidResponse"].contains(failure.code) {
        details["operationOutcome"] = "unknown"
        details["nextStep"] = "Use requests get with the original requestId before retrying."
      }
      writeOutput(AutomationDiscovery.failure(
        code: failure.code, message: failure.message, requestId: requestId, details: details))
      switch failure.code {
      case "invalidArguments", "invalidInput", "invalidJSON", "inputTooLarge": return 64
      case "appNotRunning", "transportUnavailable": return 69
      case "timeout", "connectionClosed": return 75
      default: return 1
      }
    }
  }

  static func parse(_ arguments: [String], readInput: (String) throws -> Data) throws -> Invocation {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []
    let valueOptions: Set<String> = ["--input", "--if-revision", "--request-id"]
    let flagOptions: Set<String> = ["--json", "--dry-run", "--help"]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if valueOptions.contains(argument) {
        guard options[argument] == nil, index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--")
        else { throw invalid("选项 \(argument) 缺少值或重复出现。") }
        options[argument] = arguments[index + 1]
        index += 2
      } else if flagOptions.contains(argument) {
        guard switches.insert(argument).inserted else { throw invalid("选项 \(argument) 重复出现。") }
        index += 1
      } else if argument.hasPrefix("-") {
        throw invalid("不支持的选项：\(argument)")
      } else {
        positional.append(argument)
        index += 1
      }
    }
    let json = switches.contains("--json")
    let isRootHelp = positional.isEmpty || positional == ["help"] || switches.contains("--help")
    if isRootHelp {
      guard options.isEmpty, !switches.contains("--dry-run") else {
        throw invalid("帮助命令不接受写入选项。")
      }
      let output = json
        ? try AutomationDiscovery.jsonData([
          "schemaVersion": AutomationDiscovery.schemaVersion,
          "ok": true,
          "data": ["help": AutomationDiscovery.helpText, "schema": AutomationDiscovery.schema],
        ])
        : Data(AutomationDiscovery.helpText.utf8)
      return Invocation(request: nil, offlineOutput: output, json: json)
    }
    if positional == ["schema"] {
      guard options.isEmpty, !switches.contains("--dry-run") else {
        throw invalid("schema 命令不接受写入选项。")
      }
      return Invocation(
        request: nil, offlineOutput: try AutomationDiscovery.jsonData(AutomationDiscovery.schema),
        json: true)
    }

    let operation: String
    let targetId: String?
    switch positional {
    case ["status"]: operation = "status"; targetId = nil
    case ["features", "list"]: operation = "features.list"; targetId = nil
    case ["shortcuts", "list"]: operation = "shortcuts.list"; targetId = nil
    case ["shortcuts", "add"]: operation = "shortcuts.add"; targetId = nil
    default:
      if positional.count == 2, positional[0] == "help" {
        operation = "help"; targetId = positional[1]
      } else if positional.count == 3, positional[0] == "shortcuts",
        ["get", "update", "delete"].contains(positional[1])
      {
        operation = "shortcuts." + positional[1]; targetId = positional[2]
      } else if positional.count == 3, positional[0] == "requests", positional[1] == "get" {
        operation = "requests.get"; targetId = positional[2]
      } else {
        throw invalid("无法识别命令。运行 xlg --help 查看用法。")
      }
    }
    let isWrite = ["shortcuts.add", "shortcuts.update", "shortcuts.delete"].contains(operation)
    let needsInput = operation == "shortcuts.add" || operation == "shortcuts.update"
    let dryRun = switches.contains("--dry-run")
    guard isWrite || (!dryRun && options["--if-revision"] == nil) else {
      throw invalid("只读命令不接受 --dry-run 或 --if-revision。")
    }
    guard needsInput == (options["--input"] != nil) else {
      throw invalid(needsInput ? "此命令需要 --input <文件或 ->。" : "此命令不接受 --input。")
    }
    if isWrite && !dryRun {
      guard options["--if-revision"] != nil, options["--request-id"] != nil else {
        throw invalid("正式写入需要 --if-revision 与 --request-id；可先用 --dry-run 预览。")
      }
    }
    let requestId = options["--request-id"] ?? UUID().uuidString
    guard validToken(requestId, maximum: 128),
      targetId.map({ validToken($0, maximum: 256) }) ?? true,
      options["--if-revision"].map({ validToken($0, maximum: 128) }) ?? true
    else { throw invalid("请求编号、对象 ID 或 revision 无效。") }
    var payload: [String: Any] = [:]
    if let input = options["--input"] {
      let data = try readInput(input)
      guard data.count <= AutomationDiscovery.maximumRequestBytes else {
        throw AutomationSocketError(code: "inputTooLarge", message: "输入 JSON 超过 256 KB。")
      }
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AutomationSocketError(code: "invalidJSON", message: "输入必须是 JSON 对象。")
      }
      payload = object
    }
    var request: [String: Any] = [
      "schemaVersion": AutomationDiscovery.schemaVersion,
      "requestId": requestId, "operation": operation,
      "payload": payload, "dryRun": dryRun,
    ]
    if let targetId { request["targetId"] = targetId }
    if let revision = options["--if-revision"] { request["expectedRevision"] = revision }
    return Invocation(request: request, offlineOutput: nil, json: json)
  }

  private static func boundedRead(_ handle: FileHandle) throws -> Data {
    var data = Data()
    while data.count <= AutomationDiscovery.maximumRequestBytes {
      let chunk = try handle.read(
        upToCount: min(65_536, AutomationDiscovery.maximumRequestBytes + 1 - data.count)) ?? Data()
      if chunk.isEmpty { return data }
      data.append(chunk)
    }
    throw AutomationSocketError(code: "inputTooLarge", message: "输入 JSON 超过 256 KB。")
  }

  private static func validToken(_ text: String, maximum: Int) -> Bool {
    !text.isEmpty && text.utf8.count <= maximum
      && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func invalid(_ message: String) -> AutomationSocketError {
    AutomationSocketError(code: "invalidArguments", message: message)
  }

  private static func writeOutput(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}
