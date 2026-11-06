import Foundation

/// The versioned JSON vocabulary shared by the app, CLI and AI clients.
public enum AutomationValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([AutomationValue])
  case object([String: AutomationValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(Double.self), value.isFinite {
      self = .number(value)
    } else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([AutomationValue].self) { self = .array(value) }
    else if let value = try? container.decode([String: AutomationValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: AutomationValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
}

public struct AutomationError: Error, Codable, Equatable, Sendable, LocalizedError {
  public let code: String
  public let message: String
  public let details: [String: AutomationValue]
  public let retryable: Bool

  public init(
    code: String, message: String,
    details: [String: AutomationValue] = [:], retryable: Bool = false
  ) {
    self.code = code
    self.message = message
    self.details = details
    self.retryable = retryable
  }

  public var errorDescription: String? { message }
}

public struct AutomationRequest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String?
  public let operation: String
  public let targetID: String?
  public let payload: [String: AutomationValue]
  public let expectedRevision: String?
  public let dryRun: Bool

  public init(
    schemaVersion: Int = 1, requestID: String? = nil, operation: String,
    targetID: String? = nil, payload: [String: AutomationValue] = [:],
    expectedRevision: String? = nil, dryRun: Bool = false
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.operation = operation
    self.targetID = targetID
    self.payload = payload
    self.expectedRevision = expectedRevision
    self.dryRun = dryRun
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, requestID = "requestId", operation, targetID = "targetId"
    case payload, expectedRevision, dryRun
  }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: AutomationCodingKey.self)
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    guard fields.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
      throw AutomationError(code: "invalid_request", message: "请求包含未知字段。")
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == 1 else {
      throw AutomationError(code: "unsupported_schema", message: "不支持这个自动化协议版本。")
    }
    requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    operation = try container.decode(String.self, forKey: .operation)
    targetID = try container.decodeIfPresent(String.self, forKey: .targetID)
    payload = try container.decodeIfPresent([String: AutomationValue].self, forKey: .payload) ?? [:]
    expectedRevision = try container.decodeIfPresent(String.self, forKey: .expectedRevision)
    dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
  }
}

public struct AutomationResponse: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let ok: Bool
  public let requestID: String?
  public let revision: String?
  public let changed: Bool
  public let persisted: Bool
  public let runtimeStatus: String?
  public let data: AutomationValue?
  public let error: AutomationError?
  public let warnings: [String]

  public init(
    schemaVersion: Int = 1, ok: Bool, requestID: String? = nil, revision: String? = nil,
    changed: Bool = false, persisted: Bool = false, runtimeStatus: String? = nil,
    data: AutomationValue? = nil, error: AutomationError? = nil, warnings: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.ok = ok
    self.requestID = requestID
    self.revision = revision
    self.changed = changed
    self.persisted = persisted
    self.runtimeStatus = runtimeStatus
    self.data = data
    self.error = error
    self.warnings = warnings
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, ok, requestID = "requestId", revision, changed, persisted
    case runtimeStatus, data, error, warnings
  }
}

private struct AutomationCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
  init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
