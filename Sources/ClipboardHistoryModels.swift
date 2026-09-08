import Foundation

enum ClipboardHistoryKind: String, Codable, CaseIterable, Sendable {
  case text
  case link
  case image
  case files
}

struct ClipboardHistorySource: Codable, Equatable, Sendable {
  var bundleIdentifier: String?
  var applicationName: String?

  init(
    bundleIdentifier: String? = nil,
    applicationName: String? = nil
  ) {
    self.bundleIdentifier = Self.normalized(bundleIdentifier)
    self.applicationName = Self.normalized(applicationName)
  }

  static let unknown = ClipboardHistorySource()

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}

struct ClipboardHistoryExcludedApplication: Codable, Equatable, Identifiable, Sendable {
  let bundleIdentifier: String
  let applicationName: String
  let applicationPath: String?

  var id: String { bundleIdentifier.lowercased() }
}

/// A single pasteboard change. Multiple file URLs intentionally stay in one capture so Finder's
/// multi-file copy is represented by one history row and can be written back in one operation.
struct ClipboardHistoryCapture: Equatable, Sendable {
  var text: String?
  var richData: Data?
  var richUTI: String?
  var imagePNGData: Data?
  var files: [URL]
  var source: ClipboardHistorySource
  var capturedAt: Date

  init(
    text: String? = nil,
    richData: Data? = nil,
    richUTI: String? = nil,
    imagePNGData: Data? = nil,
    files: [URL] = [],
    source: ClipboardHistorySource = .unknown,
    capturedAt: Date = Date()
  ) {
    self.text = text
    self.richData = richData
    self.richUTI = richUTI?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.imagePNGData = imagePNGData
    self.files = files
    self.source = source
    self.capturedAt = capturedAt
  }
}

struct ClipboardHistoryEntry: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let fingerprint: String
  let kind: ClipboardHistoryKind
  let textSummary: String
  let source: ClipboardHistorySource
  let createdAt: Date
  let lastCopiedAt: Date
  let copyCount: Int
  let byteCount: Int64
  let isPinned: Bool
  let payloadRelativePaths: [String]
  let fileNames: [String]
  let richUTI: String?
}

/// A disposable file copy that can safely leave the history store. External apps and Quick Look
/// receive this URL instead of the canonical managed payload, so edits cannot corrupt history.
struct ClipboardHistoryWorkingCopy: Equatable, Sendable {
  let url: URL
  let containerURL: URL
}

struct ClipboardHistoryStats: Codable, Equatable, Sendable {
  let entryCount: Int
  let pinnedCount: Int
  let totalByteCount: Int64
  let pendingDeletionByteCount: Int64
  let oldestCopiedAt: Date?
  let newestCopiedAt: Date?

  static let empty = ClipboardHistoryStats(
    entryCount: 0,
    pinnedCount: 0,
    totalByteCount: 0,
    pendingDeletionByteCount: 0,
    oldestCopiedAt: nil,
    newestCopiedAt: nil
  )
}

enum ClipboardHistoryCaptureResult: Equatable, Sendable {
  case inserted(ClipboardHistoryEntry)
  case deduplicated(ClipboardHistoryEntry)
  case rejectedQuota(requiredBytes: Int64, maxBytes: Int64)

  var entry: ClipboardHistoryEntry? {
    switch self {
    case .inserted(let entry), .deduplicated(let entry):
      return entry
    case .rejectedQuota:
      return nil
    }
  }
}

enum ClipboardHistoryStoreError: LocalizedError, Equatable {
  case invalidPolicy(String)
  case emptyCapture
  case unreadableFile(String)
  case database(String)
  case payload(String)

  var errorDescription: String? {
    switch self {
    case .invalidPolicy(let message):
      return message
    case .emptyCapture:
      return "剪贴板中没有可保存的文字、图片或文件。"
    case .unreadableFile(let path):
      return "无法读取已复制文件：\(path)"
    case .database(let message):
      return "剪贴板历史数据库错误：\(message)"
    case .payload(let message):
      return "剪贴板历史文件错误：\(message)"
    }
  }
}
