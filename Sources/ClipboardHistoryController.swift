import AppKit
import Darwin
import Foundation
import ImageIO

enum ClipboardPasteboardIsolationResult<Value> {
  case success(Value)
  case noPayload
  case stale
  case rejected
  case timedOut
  case failed
}

/// Reads provider-backed pasteboard bytes in a disposable copy of this executable. AppKit may
/// synchronously ask another process to materialize a promised value; doing that in the main App
/// process would let a slow or oversized provider stall the UI or exhaust its address space before
/// a post-read `Data.count` check can run.
enum ClipboardPasteboardIsolation {
  static let workerArgument = "--aixlg-clipboard-isolated-worker-v1"
  static let defaultTimeout: TimeInterval = 0.8

  private static let protocolVersion = 1
  private static let maximumEncodedResponseBytes = 72 * 1_024 * 1_024
  private static let workerAddressSpaceHeadroomBytes: UInt64 = 512 * 1_024 * 1_024
  private static let maximumTypeNameBytes = 1_024
  private static let maximumFilePathBytes = 4 * 1_024
  private static let maximumTotalFilePathBytes = 1 * 1_024 * 1_024
  private static let maximumStoreRequestBytes = 2 * 1_024 * 1_024
  private static let fileStoreTimeout: TimeInterval = 4.5
  private static let queue = DispatchQueue(
    label: "cn.tlww.aixlg.clipboard-pasteboard-isolation",
    qos: .utility)

  struct CaptureWire: Codable {
    let kind: String
    let filePaths: [String]?
    let data: Data?
    let text: String?
    let richData: Data?
    let richUTI: String?
  }

  struct SnapshotValueWire: Codable {
    let type: String
    let data: Data
  }

  struct SnapshotWire: Codable {
    let changeCount: Int
    let items: [[SnapshotValueWire]]
  }

  struct FileStoreWire: Codable {
    let outcome: String
    let entry: ClipboardHistoryEntry?
    let requiredBytes: Int64?
    let maxBytes: Int64?
    var skipMessage: String? = nil
  }

  private struct FileStoreRequest: Codable {
    let version: Int
    let requestNonce: String
    let baseDirectoryPath: String
    let filePaths: [String]
    let source: ClipboardHistorySource
    let capturedAt: Date
    let retentionDays: Int
    let maxBytes: Int64
  }

  private struct Response: Codable {
    let version: Int
    let outcome: String
    let capture: CaptureWire?
    let snapshot: SnapshotWire?
    let fileStore: FileStoreWire?
    let requestNonce: String?
    let operation: String?
    let pasteboardName: String?
    let expectedChangeCount: Int?

    init(
      version: Int,
      outcome: String,
      capture: CaptureWire?,
      snapshot: SnapshotWire?,
      fileStore: FileStoreWire? = nil,
      requestNonce: String? = nil,
      operation: String? = nil,
      pasteboardName: String? = nil,
      expectedChangeCount: Int? = nil
    ) {
      self.version = version
      self.outcome = outcome
      self.capture = capture
      self.snapshot = snapshot
      self.fileStore = fileStore
      self.requestNonce = requestNonce
      self.operation = operation
      self.pasteboardName = pasteboardName
      self.expectedChangeCount = expectedChangeCount
    }

    func bound(
      to requestNonce: String,
      operation: String,
      pasteboardName: String,
      expectedChangeCount: Int
    ) -> Response {
      Response(
        version: version,
        outcome: outcome,
        capture: capture,
        snapshot: snapshot,
        fileStore: fileStore,
        requestNonce: requestNonce,
        operation: operation,
        pasteboardName: pasteboardName,
        expectedChangeCount: expectedChangeCount)
    }
  }

  static func capture(
    pasteboardName: String,
    expectedChangeCount: Int,
    timeout: TimeInterval = defaultTimeout,
    completion: @escaping (ClipboardPasteboardIsolationResult<CaptureWire>) -> Void
  ) {
    queue.async {
      let result: ClipboardPasteboardIsolationResult<CaptureWire> = run(
        operation: "capture",
        pasteboardName: pasteboardName,
        expectedChangeCount: expectedChangeCount,
        byteLimit: ClipboardHistoryController.maximumCapturedImageBytes,
        timeout: timeout)
      DispatchQueue.main.async { completion(result) }
    }
  }

  static func snapshot(
    pasteboardName: String,
    expectedChangeCount: Int,
    byteLimit: Int,
    timeout: TimeInterval = defaultTimeout,
    completion: @escaping (ClipboardPasteboardIsolationResult<ClipboardPasteboardSnapshot>) -> Void
  ) {
    queue.async {
      let result: ClipboardPasteboardIsolationResult<SnapshotWire> = run(
        operation: "snapshot",
        pasteboardName: pasteboardName,
        expectedChangeCount: expectedChangeCount,
        byteLimit: byteLimit,
        timeout: timeout)
      let mapped: ClipboardPasteboardIsolationResult<ClipboardPasteboardSnapshot>
      switch result {
      case .success(let wire):
        let items = wire.items.map { values in
          values.map {
            ClipboardPasteboardSnapshot.Value(
              type: NSPasteboard.PasteboardType($0.type),
              data: $0.data)
          }
        }
        mapped = .success(
          ClipboardPasteboardSnapshot(changeCount: wire.changeCount, items: items))
      case .noPayload: mapped = .noPayload
      case .stale: mapped = .stale
      case .rejected: mapped = .rejected
      case .timedOut: mapped = .timedOut
      case .failed: mapped = .failed
      }
      DispatchQueue.main.async { completion(mapped) }
    }
  }

  static func storeFiles(
    _ capture: ClipboardHistoryCapture,
    baseDirectory: URL,
    retentionDays: Int,
    maxBytes: Int64,
    timeout: TimeInterval = fileStoreTimeout
  ) -> ClipboardPasteboardIsolationResult<FileStoreWire> {
    guard !Thread.isMainThread else { return .failed }
    guard !capture.files.isEmpty,
      capture.files.count <= ClipboardHistoryController.maximumCapturedFileCount,
      maxBytes >= 0,
      maxBytes <= Int64(Int.max)
    else { return .rejected }
    let requestNonce = UUID().uuidString.lowercased()
    let request = FileStoreRequest(
      version: protocolVersion,
      requestNonce: requestNonce,
      baseDirectoryPath: baseDirectory.standardizedFileURL.path,
      filePaths: capture.files.map { $0.standardizedFileURL.path },
      source: capture.source,
      capturedAt: capture.capturedAt,
      retentionDays: retentionDays,
      maxBytes: maxBytes)
    guard let requestData = try? PropertyListEncoder().encode(request),
      requestData.count <= maximumStoreRequestBytes
    else { return .rejected }
    return run(
      operation: "store-files",
      pasteboardName: "file-store",
      expectedChangeCount: 0,
      byteLimit: Int(maxBytes),
      timeout: timeout,
      requestData: requestData,
      requestNonce: requestNonce)
  }

  /// Called before normal App startup. A return value means this process was launched only to
  /// service one bounded pasteboard read and must exit with the returned status immediately.
  static func runWorkerIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
    guard let markerIndex = arguments.firstIndex(of: workerArgument) else { return nil }
    let values = Array(arguments.dropFirst(markerIndex + 1))
    guard values.count == 6 || values.count == 7,
      let expectedChangeCount = Int(values[2]),
      let byteLimit = Int(values[3]),
      byteLimit >= 0,
      UUID(uuidString: values[4]) != nil
    else { return 64 }

    let operation = values[0]
    guard
      (operation == "store-files" && values.count == 7)
        || (operation != "store-files" && values.count == 6)
    else { return 64 }
    let createdFileLimit =
      operation == "store-files"
      ? max(Int64(maximumEncodedResponseBytes), Int64(byteLimit))
      : Int64(maximumEncodedResponseBytes)
    guard applyWorkerResourceLimits(maximumCreatedFileBytes: createdFileLimit) else { return 77 }
    let pasteboardName = values[1]
    let requestNonce = values[4]
    let outputPath = values[5]
    let response: Response
    if operation == "store-files" {
      response = storeFilesResponse(
        requestPath: values[6],
        requestNonce: requestNonce,
        byteLimit: Int64(byteLimit))
    } else {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
      if pasteboard.changeCount != expectedChangeCount {
        response = Response(
          version: protocolVersion,
          outcome: "stale",
          capture: nil,
          snapshot: nil)
      } else if operation == "capture" {
        response = captureResponse(
          from: pasteboard,
          expectedChangeCount: expectedChangeCount)
      } else if operation == "snapshot" {
        response = snapshotResponse(
          from: pasteboard,
          expectedChangeCount: expectedChangeCount,
          byteLimit: byteLimit)
      } else {
        return 64
      }
    }

    let boundResponse = response.bound(
      to: requestNonce,
      operation: operation,
      pasteboardName: pasteboardName,
      expectedChangeCount: expectedChangeCount)
    guard let encoded = try? PropertyListEncoder().encode(boundResponse),
      encoded.count <= maximumEncodedResponseBytes,
      writeResponse(encoded, to: outputPath)
    else { return 74 }
    return 0
  }

  private static func run<Value>(
    operation: String,
    pasteboardName: String,
    expectedChangeCount: Int,
    byteLimit: Int,
    timeout: TimeInterval,
    requestData: Data? = nil,
    requestNonce explicitRequestNonce: String? = nil
  ) -> ClipboardPasteboardIsolationResult<Value> {
    guard byteLimit >= 0,
      let executableURL = Bundle.main.executableURL,
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else { return .failed }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aixlg-clipboard-isolation-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    let outputURL = directory.appendingPathComponent("response.plist", isDirectory: false)
    let requestURL = directory.appendingPathComponent("request.plist", isDirectory: false)
    let requestNonce = explicitRequestNonce ?? UUID().uuidString.lowercased()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch {
      return .failed
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    if let requestData {
      guard requestData.count <= maximumStoreRequestBytes,
        writeResponse(requestData, to: requestURL.path)
      else { return .failed }
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      workerArgument,
      operation,
      pasteboardName,
      String(expectedChangeCount),
      String(byteLimit),
      requestNonce,
      outputURL.path,
    ]
    if requestData != nil {
      process.arguments?.append(requestURL.path)
    }
    let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardOutput = nullOutput
    process.standardError = nullOutput
    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    do {
      try process.run()
    } catch {
      try? nullOutput?.close()
      return .failed
    }

    let deadline = DispatchTime.now() + max(0.05, timeout)
    if terminated.wait(timeout: deadline) == .timedOut {
      let reaped = terminateAndReap(process, terminated: terminated)
      try? nullOutput?.close()
      return reaped ? .timedOut : .failed
    }
    try? nullOutput?.close()
    guard process.terminationStatus == 0,
      let encoded = readBoundedResponse(at: outputURL.path),
      let response = try? PropertyListDecoder().decode(Response.self, from: encoded),
      response.version == protocolVersion,
      response.requestNonce == requestNonce,
      response.operation == operation,
      response.pasteboardName == pasteboardName,
      response.expectedChangeCount == expectedChangeCount
    else { return .failed }

    switch response.outcome {
    case "ok":
      if Value.self == CaptureWire.self, let value = response.capture as? Value {
        return .success(value)
      }
      if Value.self == SnapshotWire.self, let value = response.snapshot as? Value {
        return .success(value)
      }
      if Value.self == FileStoreWire.self, let value = response.fileStore as? Value {
        return .success(value)
      }
      return .failed
    case "none": return .noPayload
    case "stale": return .stale
    case "rejected": return .rejected
    default: return .failed
    }
  }

  private static func terminateAndReap(
    _ process: Process,
    terminated: DispatchSemaphore
  ) -> Bool {
    process.terminate()
    if terminated.wait(timeout: .now() + 0.1) == .success { return true }
    // Pasteboard IPC is interruptible. Keep reaping on this isolation queue until our exact child
    // exits instead of returning while a wedged worker and its resource budget remain alive.
    while process.isRunning {
      let result = Darwin.kill(process.processIdentifier, SIGKILL)
      guard result == 0 || errno == ESRCH else { return false }
      if terminated.wait(timeout: .now() + 0.1) == .success { return true }
    }
    return true
  }

  private static func readBoundedResponse(
    at path: String,
    maximumBytes: Int = maximumEncodedResponseBytes
  ) -> Data? {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_nlink == 1,
      before.st_uid == geteuid(),
      before.st_size >= 0,
      before.st_size <= off_t(maximumBytes)
    else { return nil }

    let expectedSize = Int(before.st_size)
    var encoded = Data(count: expectedSize)
    let completelyRead = encoded.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let base = rawBuffer.baseAddress else { return expectedSize == 0 }
      var offset = 0
      while offset < expectedSize {
        let count = Darwin.read(
          descriptor,
          base.advanced(by: offset),
          min(64 * 1_024, expectedSize - offset))
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      var extra: UInt8 = 0
      return Darwin.read(descriptor, &extra, 1) == 0
    }
    guard completelyRead else { return nil }

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else { return nil }
    return encoded
  }

  private static func storeFilesResponse(
    requestPath: String,
    requestNonce: String,
    byteLimit: Int64
  ) -> Response {
    guard
      let encoded = readBoundedResponse(
        at: requestPath,
        maximumBytes: maximumStoreRequestBytes),
      let request = try? PropertyListDecoder().decode(FileStoreRequest.self, from: encoded),
      request.version == protocolVersion,
      request.requestNonce == requestNonce,
      request.maxBytes == byteLimit,
      (1...3_650).contains(request.retentionDays),
      (100_000_000...50_000_000_000).contains(request.maxBytes),
      request.capturedAt.timeIntervalSince1970.isFinite,
      request.filePaths.count > 0,
      request.filePaths.count <= ClipboardHistoryController.maximumCapturedFileCount,
      (request.source.bundleIdentifier?.utf8.count ?? 0) <= maximumTypeNameBytes,
      (request.source.applicationName?.utf8.count ?? 0) <= maximumTypeNameBytes
    else {
      return Response(
        version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }

    let baseDirectory = URL(
      fileURLWithPath: request.baseDirectoryPath,
      isDirectory: true
    ).standardizedFileURL
    var baseStatus = stat()
    guard request.baseDirectoryPath.hasPrefix("/"),
      request.baseDirectoryPath.utf8.count <= maximumFilePathBytes,
      baseDirectory.path == request.baseDirectoryPath,
      baseDirectory.path.withCString({ lstat($0, &baseStatus) }) == 0,
      (baseStatus.st_mode & S_IFMT) == S_IFDIR,
      baseStatus.st_uid == geteuid()
    else {
      return Response(
        version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }

    var totalPathBytes = 0
    var files: [URL] = []
    files.reserveCapacity(request.filePaths.count)
    for path in request.filePaths {
      let (nextTotal, overflow) = totalPathBytes.addingReportingOverflow(path.utf8.count)
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard !overflow,
        nextTotal <= maximumTotalFilePathBytes,
        path.hasPrefix("/"),
        path.utf8.count <= maximumFilePathBytes,
        url.path == path
      else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      totalPathBytes = nextTotal
      files.append(url)
    }

    do {
      let store = try ClipboardHistoryStore(baseDirectory: baseDirectory)
      let result = try store.capture(
        ClipboardHistoryCapture(
          files: files,
          source: request.source,
          capturedAt: request.capturedAt),
        retentionDays: request.retentionDays,
        maxBytes: request.maxBytes)
      #if AIXLG_TESTING
        if let rawDelay = ProcessInfo.processInfo.environment[
          "AIXLG_CLIPBOARD_QA_POST_COMMIT_DELAY_MS"
        ], let delayMilliseconds = UInt32(rawDelay), delayMilliseconds > 0 {
          usleep(delayMilliseconds * 1_000)
        }
      #endif
      let wire: FileStoreWire
      switch result {
      case .inserted(let entry):
        wire = FileStoreWire(
          outcome: "inserted", entry: entry, requiredBytes: nil, maxBytes: nil)
      case .deduplicated(let entry):
        wire = FileStoreWire(
          outcome: "deduplicated", entry: entry, requiredBytes: nil, maxBytes: nil)
      case .rejectedQuota(let requiredBytes, let maxBytes):
        wire = FileStoreWire(
          outcome: "rejected-quota",
          entry: nil,
          requiredBytes: requiredBytes,
          maxBytes: maxBytes)
      }
      return Response(
        version: protocolVersion,
        outcome: "ok",
        capture: nil,
        snapshot: nil,
        fileStore: wire)
    } catch let error as ClipboardHistoryStoreError {
      let message: String
      switch error {
      case .database, .invalidPolicy:
        return Response(
          version: protocolVersion, outcome: "failed", capture: nil, snapshot: nil)
      case .unreadableFile:
        message = "文件暂时无法读取；请确认文件仍存在、已下载到本机且允许访问后，重新复制。"
      case .emptyCapture:
        message = "没有可保存的文件，请重新复制。"
      case .payload(let detail):
        message = detail
      }
      // A known per-file refusal is distinct from a store failure or an unknown commit.
      return Response(
        version: protocolVersion, outcome: "ok", capture: nil, snapshot: nil,
        fileStore: FileStoreWire(
          outcome: "skipped", entry: nil, requiredBytes: nil, maxBytes: nil,
          skipMessage: String(message.prefix(512))))
    } catch {
      return Response(
        version: protocolVersion, outcome: "failed", capture: nil, snapshot: nil)
    }
  }

  private static func captureResponse(
    from pasteboard: NSPasteboard,
    expectedChangeCount: Int
  ) -> Response {
    let types = pasteboard.types ?? []
    guard !containsSensitiveType(types) else {
      return Response(version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }

    if let objects = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]),
      !objects.isEmpty
    {
      let paths = objects.compactMap { object -> String? in
        guard let url = object as? NSURL, url.isFileURL else { return nil }
        return (url as URL).path
      }
      let totalPathBytes = paths.reduce(0) { partial, path in
        partial + path.utf8.count
      }
      guard !paths.isEmpty,
        paths.count <= ClipboardHistoryController.maximumCapturedFileCount,
        paths.allSatisfy({ $0.utf8.count <= maximumFilePathBytes }),
        totalPathBytes <= maximumTotalFilePathBytes
      else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      guard pasteboard.changeCount == expectedChangeCount else {
        return Response(version: protocolVersion, outcome: "stale", capture: nil, snapshot: nil)
      }
      return Response(
        version: protocolVersion,
        outcome: "ok",
        capture: CaptureWire(
          kind: "files", filePaths: paths, data: nil, text: nil, richData: nil, richUTI: nil),
        snapshot: nil)
    }

    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      guard png.count <= ClipboardHistoryController.maximumCapturedImageBytes else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      guard pasteboard.changeCount == expectedChangeCount else {
        return Response(version: protocolVersion, outcome: "stale", capture: nil, snapshot: nil)
      }
      return Response(
        version: protocolVersion,
        outcome: "ok",
        capture: CaptureWire(
          kind: "png", filePaths: nil, data: png, text: nil, richData: nil, richUTI: nil),
        snapshot: nil)
    }
    if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
      guard tiff.count <= ClipboardHistoryController.maximumCapturedImageBytes else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      guard pasteboard.changeCount == expectedChangeCount else {
        return Response(version: protocolVersion, outcome: "stale", capture: nil, snapshot: nil)
      }
      return Response(
        version: protocolVersion,
        outcome: "ok",
        capture: CaptureWire(
          kind: "tiff", filePaths: nil, data: tiff, text: nil, richData: nil, richUTI: nil),
        snapshot: nil)
    }

    let text = pasteboard.string(forType: .string)
    guard (text?.utf8.count ?? 0) <= ClipboardHistoryController.maximumCapturedPlainTextBytes else {
      return Response(version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }
    var richData: Data?
    var richUTI: String?
    if let rtf = pasteboard.data(forType: .rtf), !rtf.isEmpty {
      richData = rtf
      richUTI = NSPasteboard.PasteboardType.rtf.rawValue
    } else if let html = pasteboard.data(forType: .html), !html.isEmpty {
      richData = html
      richUTI = NSPasteboard.PasteboardType.html.rawValue
    }
    guard (richData?.count ?? 0) <= ClipboardHistoryController.maximumCapturedRichTextBytes else {
      return Response(version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }
    guard text != nil || richData != nil else {
      return Response(version: protocolVersion, outcome: "none", capture: nil, snapshot: nil)
    }
    guard pasteboard.changeCount == expectedChangeCount else {
      return Response(version: protocolVersion, outcome: "stale", capture: nil, snapshot: nil)
    }
    return Response(
      version: protocolVersion,
      outcome: "ok",
      capture: CaptureWire(
        kind: "text",
        filePaths: nil,
        data: nil,
        text: text,
        richData: richData,
        richUTI: richUTI),
      snapshot: nil)
  }

  private static func snapshotResponse(
    from pasteboard: NSPasteboard,
    expectedChangeCount: Int,
    byteLimit: Int
  ) -> Response {
    guard byteLimit >= 0 else {
      return Response(version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }
    let sourceItems = pasteboard.pasteboardItems ?? []
    guard sourceItems.count <= ClipboardPasteboardSnapshot.maximumItemCount else {
      return Response(version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
    }
    var items: [[SnapshotValueWire]] = []
    var totalBytes = 0
    var totalTypes = 0
    items.reserveCapacity(sourceItems.count)
    for item in sourceItems {
      let types = item.types
      guard types.count <= ClipboardPasteboardSnapshot.maximumTypeCount - totalTypes else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      totalTypes += types.count
      var values: [SnapshotValueWire] = []
      values.reserveCapacity(types.count)
      for type in types {
        guard type.rawValue.utf8.count <= maximumTypeNameBytes,
          let data = item.data(forType: type),
          data.count <= byteLimit - totalBytes
        else {
          return Response(
            version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
        }
        totalBytes += data.count
        values.append(SnapshotValueWire(type: type.rawValue, data: data))
      }
      guard !values.isEmpty else {
        return Response(
          version: protocolVersion, outcome: "rejected", capture: nil, snapshot: nil)
      }
      items.append(values)
    }
    guard pasteboard.changeCount == expectedChangeCount else {
      return Response(version: protocolVersion, outcome: "stale", capture: nil, snapshot: nil)
    }
    return Response(
      version: protocolVersion,
      outcome: "ok",
      capture: nil,
      snapshot: SnapshotWire(changeCount: expectedChangeCount, items: items))
  }

  private static func containsSensitiveType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    let denied = [
      "org.nspasteboard.TransientType",
      "org.nspasteboard.ConcealedType",
      "org.nspasteboard.AutoGeneratedType",
    ]
    return types.contains { type in
      denied.contains { type.rawValue.caseInsensitiveCompare($0) == .orderedSame }
    }
  }

  private static func applyWorkerResourceLimits(maximumCreatedFileBytes: Int64) -> Bool {
    guard maximumCreatedFileBytes >= Int64(maximumEncodedResponseBytes) else { return false }
    var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &noCore) == 0 else { return false }
    guard let currentVirtualSize = currentVirtualSize(),
      currentVirtualSize <= UInt64.max - workerAddressSpaceHeadroomBytes
    else { return false }
    let addressSpaceLimit = rlim_t(currentVirtualSize + workerAddressSpaceHeadroomBytes)
    var address = rlimit(rlim_cur: addressSpaceLimit, rlim_max: addressSpaceLimit)
    guard setrlimit(RLIMIT_AS, &address) == 0 else { return false }
    var cpu = rlimit(rlim_cur: 6, rlim_max: 6)
    guard setrlimit(RLIMIT_CPU, &cpu) == 0 else { return false }
    var output = rlimit(
      rlim_cur: rlim_t(maximumCreatedFileBytes),
      rlim_max: rlim_t(maximumCreatedFileBytes))
    return setrlimit(RLIMIT_FSIZE, &output) == 0
  }

  private static func currentVirtualSize() -> UInt64? {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          rebound,
          &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    return info.virtual_size
  }

  private static func writeResponse(_ data: Data, to path: String) -> Bool {
    let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return data.isEmpty }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
  }
}

/// Coordinates intentional, short-lived pasteboard writes made by this app so they are not
/// mistaken for a user copy. User-facing copy actions should not use this suppression.
enum ClipboardHistorySuppression {
  private static let lock = NSLock()
  private static var ignoredChangeCounts: [Int: TimeInterval] = [:]

  static func markCurrentPasteboardChange(ttl: TimeInterval = 5) {
    lock.lock()
    let now = ProcessInfo.processInfo.systemUptime
    ignoredChangeCounts = ignoredChangeCounts.filter { $0.value > now }
    ignoredChangeCounts[NSPasteboard.general.changeCount] = now + max(0.5, ttl)
    lock.unlock()
  }

  static func consume(changeCount: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    ignoredChangeCounts = ignoredChangeCounts.filter { $0.value > now }
    return ignoredChangeCounts.removeValue(forKey: changeCount) != nil
  }
}

/// Narrow pasteboard surface used by replay transactions. Keeping this injectable lets QA force
/// failures after `clearContents()` and prove the caller's previous clipboard is restored.
protocol ClipboardHistoryPasteboard: AnyObject {
  var changeCount: Int { get }
  var pasteboardItems: [NSPasteboardItem]? { get }

  @discardableResult func clearContents() -> Int
  func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
  func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
  func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: ClipboardHistoryPasteboard {}

struct ClipboardPasteboardSnapshot {
  static let defaultByteLimit = 64 * 1_024 * 1_024
  static let maximumItemCount = 128
  static let maximumTypeCount = 256

  struct Value {
    let type: NSPasteboard.PasteboardType
    let data: Data
  }

  let changeCount: Int
  let items: [[Value]]

  static func capture(
    from pasteboard: any ClipboardHistoryPasteboard,
    byteLimit: Int = defaultByteLimit
  ) -> ClipboardPasteboardSnapshot? {
    guard byteLimit >= 0 else { return nil }
    let changeCount = pasteboard.changeCount
    let sourceItems = pasteboard.pasteboardItems ?? []
    guard sourceItems.count <= maximumItemCount else { return nil }
    var items: [[Value]] = []
    var totalBytes = 0
    var totalTypes = 0
    items.reserveCapacity(sourceItems.count)
    for item in sourceItems {
      var values: [Value] = []
      guard item.types.count <= maximumTypeCount - totalTypes else { return nil }
      totalTypes += item.types.count
      values.reserveCapacity(item.types.count)
      for type in item.types {
        guard let data = item.data(forType: type) else { return nil }
        guard data.count <= byteLimit - totalBytes else { return nil }
        totalBytes += data.count
        values.append(Value(type: type, data: data))
      }
      guard !values.isEmpty else { return nil }
      items.append(values)
    }
    guard pasteboard.changeCount == changeCount else { return nil }
    return ClipboardPasteboardSnapshot(changeCount: changeCount, items: items)
  }

  func restore(
    to pasteboard: any ClipboardHistoryPasteboard,
    expectedChangeCount: Int
  ) -> Int? {
    var objects: [NSPasteboardWriting] = []
    objects.reserveCapacity(items.count)
    for values in items {
      let item = NSPasteboardItem()
      for value in values {
        guard item.setData(value.data, forType: value.type) else { return nil }
      }
      objects.append(item)
    }
    // Ownership is a compare-and-swap on changeCount. Comparing just the visible string would
    // overwrite a later copy that happens to contain identical text and would discard rich/file
    // representations that do not have a string value.
    guard pasteboard.changeCount == expectedChangeCount else { return nil }
    let restoredChangeCount = pasteboard.clearContents()
    guard pasteboard.changeCount == restoredChangeCount else { return nil }
    let restored = objects.isEmpty || pasteboard.writeObjects(objects)
    guard restored, pasteboard.changeCount == restoredChangeCount else { return nil }
    return restoredChangeCount
  }
}

struct TemporaryPasteboardWrite {
  let snapshot: ClipboardPasteboardSnapshot
  let ownedChangeCount: Int

  static func writeString(
    _ string: String,
    to pasteboard: any ClipboardHistoryPasteboard,
    snapshotByteLimit: Int = ClipboardPasteboardSnapshot.defaultByteLimit
  ) -> TemporaryPasteboardWrite? {
    // Production NSPasteboard reads must use the asynchronous overload below. This synchronous
    // seam remains only for bounded in-memory QA adapters, where no external data provider can be
    // invoked and exact rollback failure paths can be exercised deterministically.
    guard !(pasteboard is NSPasteboard) else { return nil }
    guard
      let snapshot = ClipboardPasteboardSnapshot.capture(
        from: pasteboard,
        byteLimit: snapshotByteLimit)
    else { return nil }
    let ownedChangeCount = pasteboard.clearContents()
    guard pasteboard.changeCount == ownedChangeCount,
      pasteboard.setString(string, forType: .string),
      pasteboard.changeCount == ownedChangeCount
    else {
      _ = snapshot.restore(to: pasteboard, expectedChangeCount: ownedChangeCount)
      return nil
    }
    return TemporaryPasteboardWrite(snapshot: snapshot, ownedChangeCount: ownedChangeCount)
  }

  static func writeString(
    _ string: String,
    to pasteboard: NSPasteboard,
    snapshotByteLimit: Int = ClipboardPasteboardSnapshot.defaultByteLimit,
    validateBeforeWrite: @escaping () -> Bool = { true },
    completion: @escaping (TemporaryPasteboardWrite?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let expectedChangeCount = pasteboard.changeCount
    ClipboardPasteboardIsolation.snapshot(
      pasteboardName: pasteboard.name.rawValue,
      expectedChangeCount: expectedChangeCount,
      byteLimit: snapshotByteLimit
    ) { result in
      dispatchPrecondition(condition: .onQueue(.main))
      guard case .success(let snapshot) = result,
        snapshot.changeCount == expectedChangeCount,
        pasteboard.changeCount == expectedChangeCount,
        validateBeforeWrite()
      else {
        completion(nil)
        return
      }
      let ownedChangeCount = pasteboard.clearContents()
      guard pasteboard.changeCount == ownedChangeCount,
        pasteboard.setString(string, forType: .string),
        pasteboard.changeCount == ownedChangeCount
      else {
        _ = snapshot.restore(to: pasteboard, expectedChangeCount: ownedChangeCount)
        completion(nil)
        return
      }
      completion(
        TemporaryPasteboardWrite(snapshot: snapshot, ownedChangeCount: ownedChangeCount))
    }
  }

  @discardableResult
  func restoreIfStillOwned(
    on pasteboard: any ClipboardHistoryPasteboard
  ) -> Int? {
    snapshot.restore(to: pasteboard, expectedChangeCount: ownedChangeCount)
  }
}

final class ClipboardHistoryController: ObservableObject {
  var successfulUse: (@MainActor () -> Void)?
  @Published private(set) var entries: [ClipboardHistoryEntry] = []
  @Published var selectedEntryID: String?
  @Published private(set) var isEnabled: Bool
  @Published private(set) var isBusy = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var usedBytes: Int64 = 0
  @Published private(set) var pendingDeletionBytes: Int64 = 0
  @Published private(set) var maxBytes: Int64
  @Published private(set) var retentionDays: Int
  @Published private(set) var quotaBlocked = false
  @Published private(set) var searchFocusRequest = 0
  @Published private(set) var excludedApplications: [ClipboardHistoryExcludedApplication]

  private enum DefaultsKey {
    static let enabled = "clipboardHistory.enabledV1"
    static let retentionDays = "clipboardHistory.retentionDaysV1"
    static let maxBytes = "clipboardHistory.maxBytesV1"
    static let excludedApplications = "clipboardHistory.excludedApplicationsV1"
  }

  private let store: ClipboardHistoryStore?
  private let storeBaseDirectory: URL
  private let worker = DispatchQueue(label: "cn.tlww.aixlg.clipboard-history.store", qos: .utility)
  private let workingCopyChannelDirectory: URL
  private let workingCopyRoot: URL
  private let workingCopySessionDirectory: URL
  private let replayLeaseRoot: URL
  private let replayLeaseSessionDirectory: URL
  private let replayLeaseCacheLimit: Int64
  private let beforeReplayMarkerWrite: (() throws -> Void)?
  private let afterReplayLeasePrepared: (() -> Void)?
  private let systemPasteboard: NSPasteboard
  private var timer: Timer?
  private var maintenanceTimer: Timer?
  private var replayLeaseTimer: Timer?
  private var frontmostApplicationObserver: NSObjectProtocol?
  private var lastChangeCount = NSPasteboard.general.changeCount
  /// Accessed only from `worker`, which keeps observation fingerprints ordered even when image
  /// normalization takes longer than the 0.4-second pasteboard polling interval.
  private var workerLastObservedPasteboardFingerprint: String?
  private var observedExcludedTransientChange = false
  private var sourceCandidatesSinceLastPasteboardChange: [ClipboardHistorySource] = []
  private var pasteboardCaptureGeneration: UInt64 = 0
  private var pasteboardCaptureInFlight = false
  private var deferredPasteboardRead: PendingClipboardReadRequest?
  private var uncommittedPasteboardChangeDelta = 0
  private var runtimeAllowed = false
  private let defaults: UserDefaults
  private let textPreviewCache = NSCache<NSString, NSString>()
  private var activeReplayLease: ActiveReplayLease?
  private var pendingReplayLeaseCleanup: [ManagedReplayLease] = []
  private var replayGeneration: UInt64 = 0

  private static let workingCopyLifetime: TimeInterval = 24 * 60 * 60
  private static let workingCopyCacheLimit: Int64 = 50_000_000_000
  private static let defaultReplayLeaseCacheLimit: Int64 = 50_000_000_000
  fileprivate static let maximumCapturedImageBytes = 64 * 1_024 * 1_024
  private static let maximumCapturedImageDimension = 16_384
  private static let maximumCapturedImagePixels = 40_000_000
  fileprivate static let maximumCapturedPlainTextBytes = 16 * 1_024 * 1_024
  fileprivate static let maximumCapturedRichTextBytes = 16 * 1_024 * 1_024
  fileprivate static let maximumCapturedFileCount = 128

  private enum PendingClipboardCapture: Sendable {
    case ready(ClipboardHistoryCapture)
    case tiff(Data, source: ClipboardHistorySource, capturedAt: Date)
  }

  private struct PendingClipboardObservation: Sendable {
    let capture: PendingClipboardCapture
    let changeCountDelta: Int
    let observedTransientChange: Bool
    let typelessExcluded: Bool
    let typelessRunning: Bool
  }

  private struct PendingClipboardReadRequest: Sendable {
    let generation: UInt64
    let pasteboardName: String
    let expectedChangeCount: Int
    let source: ClipboardHistorySource
    let capturedAt: Date
    let changeCountDelta: Int
    let observedTransientChange: Bool
    let typelessExcluded: Bool
    let typelessRunning: Bool
  }

  private enum PreparedReplayPayload {
    case files(ManagedReplayLease)
    case image(Data)
    case text(plain: String?, richType: NSPasteboard.PasteboardType?, richData: Data?)
  }

  private struct ActiveReplayLease {
    let managed: ManagedReplayLease
    let pasteboard: any ClipboardHistoryPasteboard
    let changeCount: Int
  }

  private struct ManagedReplayLease {
    let lease: ClipboardHistoryReplayLease
    let destinationRoot: URL
  }

  private struct ReplayLeaseMarkerCandidate: Codable {
    let containerPath: String
    let urlPaths: [String]
    let byteCount: Int64
  }

  private struct ReplayLeaseMarker: Codable {
    let candidates: [ReplayLeaseMarkerCandidate]
  }

  init(
    baseDirectory: URL,
    defaults: UserDefaults = .standard,
    replayLeaseCacheLimit: Int64 = ClipboardHistoryController.defaultReplayLeaseCacheLimit,
    beforeReplayMarkerWrite: (() throws -> Void)? = nil,
    afterReplayLeasePrepared: (() -> Void)? = nil,
    systemPasteboard: NSPasteboard = .general
  ) {
    let normalizedBaseDirectory = baseDirectory.standardizedFileURL
    storeBaseDirectory = normalizedBaseDirectory
    let channelName = normalizedBaseDirectory.deletingLastPathComponent().lastPathComponent
    let cachesDirectory = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    )[0].resolvingSymlinksInPath().standardizedFileURL
    let workingCopyChannelDirectory = cachesDirectory.appendingPathComponent(
      channelName,
      isDirectory: true)
    let workingCopyRoot =
      workingCopyChannelDirectory
      .appendingPathComponent("clipboard-open", isDirectory: true)
    let replayLeaseRoot =
      workingCopyChannelDirectory
      .appendingPathComponent("clipboard-replay", isDirectory: true)
    self.workingCopyChannelDirectory = workingCopyChannelDirectory
    self.workingCopyRoot = workingCopyRoot
    workingCopySessionDirectory = workingCopyRoot.appendingPathComponent(
      "\(UUID().uuidString.lowercased()).session",
      isDirectory: true)
    self.replayLeaseRoot = replayLeaseRoot
    replayLeaseSessionDirectory = replayLeaseRoot.appendingPathComponent(
      "\(UUID().uuidString.lowercased()).session",
      isDirectory: true)
    self.replayLeaseCacheLimit = max(0, replayLeaseCacheLimit)
    self.beforeReplayMarkerWrite = beforeReplayMarkerWrite
    self.afterReplayLeasePrepared = afterReplayLeasePrepared
    self.systemPasteboard = systemPasteboard
    self.defaults = defaults
    isEnabled =
      defaults.object(forKey: DefaultsKey.enabled) == nil
      ? true : defaults.bool(forKey: DefaultsKey.enabled)
    let savedRetention = defaults.integer(forKey: DefaultsKey.retentionDays)
    retentionDays = Self.clampedRetentionDays(savedRetention == 0 ? 30 : savedRetention)
    let savedMaxBytes = defaults.object(forKey: DefaultsKey.maxBytes) as? NSNumber
    maxBytes = Self.clampedMaxBytes(savedMaxBytes?.int64Value ?? 1_000_000_000)
    excludedApplications = Self.loadExcludedApplications(defaults: defaults)

    do {
      store = try ClipboardHistoryStore(baseDirectory: normalizedBaseDirectory)
    } catch {
      store = nil
      statusMessage = "保存失败：\(error.localizedDescription)"
    }
    sourceCandidatesSinceLastPasteboardChange = [
      Self.source(for: NSWorkspace.shared.frontmostApplication)
    ]
    frontmostApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else { return }
      self?.recordSourceCandidate(Self.source(for: application))
    }
    textPreviewCache.totalCostLimit = 64 * 1_024 * 1_024
    try? recoverActiveReplayLeaseFromGeneralPasteboard()
    let protectedReplayContainer = activeReplayLease?.managed.lease.containerURL
    worker.async { [weak self] in
      guard let self else { return }
      _ = try? self.cleanupWorkingCopyCache()
      _ = try? self.cleanupStaleReplayLeaseCache(
        protecting: protectedReplayContainer)
    }
    refresh()
  }

  deinit {
    if let frontmostApplicationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(frontmostApplicationObserver)
    }
    timer?.invalidate()
    maintenanceTimer?.invalidate()
    replayLeaseTimer?.invalidate()
  }

  func setRuntimeAllowed(_ allowed: Bool) {
    runtimeAllowed = allowed
    if !allowed { invalidatePasteboardReads() }
    syncMonitoring()
  }

  func requestSearchFocus() {
    searchFocusRequest &+= 1
  }

  func reloadManagedPreferences() {
    isEnabled = defaults.object(forKey: DefaultsKey.enabled) == nil
      ? true : defaults.bool(forKey: DefaultsKey.enabled)
    let savedRetention = defaults.integer(forKey: DefaultsKey.retentionDays)
    retentionDays = Self.clampedRetentionDays(savedRetention == 0 ? 30 : savedRetention)
    let savedMaxBytes = defaults.object(forKey: DefaultsKey.maxBytes) as? NSNumber
    maxBytes = Self.clampedMaxBytes(savedMaxBytes?.int64Value ?? 1_000_000_000)
    excludedApplications = Self.loadExcludedApplications(defaults: defaults)
    invalidatePasteboardReads()
    syncMonitoring(performInitialMaintenance: false)
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if !enabled { invalidatePasteboardReads() }
    defaults.set(enabled, forKey: DefaultsKey.enabled)
    statusMessage = enabled ? "已开始保存新的复制内容" : "已暂停记录，现有历史保留"
    syncMonitoring()
  }

  func setRetentionDays(_ days: Int) {
    let value = Self.clampedRetentionDays(days)
    guard retentionDays != value else { return }
    retentionDays = value
    defaults.set(value, forKey: DefaultsKey.retentionDays)
    cleanNow(announces: false)
  }

  func setMaxBytes(_ bytes: Int64) {
    let value = Self.clampedMaxBytes(bytes)
    guard maxBytes != value else { return }
    maxBytes = value
    defaults.set(value, forKey: DefaultsKey.maxBytes)
    cleanNow(announces: false)
  }

  @discardableResult
  func addExcludedApplication(at applicationURL: URL) -> Bool {
    let url = applicationURL.standardizedFileURL
    guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      let bundle = Bundle(url: url),
      let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !bundleIdentifier.isEmpty
    else {
      statusMessage = "无法排除：请选择一个有效的 App"
      return false
    }

    let displayName =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    let application = ClipboardHistoryExcludedApplication(
      bundleIdentifier: bundleIdentifier,
      applicationName: displayName,
      applicationPath: url.path)
    let remaining = excludedApplications.filter {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) != .orderedSame
    }
    excludedApplications = ClipboardHistoryExclusionPolicy.normalizedApplications(
      remaining + [application])
    persistExcludedApplications()
    statusMessage = "已排除 \(displayName)，它位于前台时观察到的新复制不再记录"
    return true
  }

  func removeExcludedApplication(_ application: ClipboardHistoryExcludedApplication) {
    let remaining = excludedApplications.filter {
      $0.bundleIdentifier.caseInsensitiveCompare(application.bundleIdentifier) != .orderedSame
    }
    guard remaining.count != excludedApplications.count else { return }
    excludedApplications = remaining
    persistExcludedApplications()
    statusMessage = "已取消排除 \(application.applicationName)"
  }

  func stop() {
    replayGeneration &+= 1
    invalidatePasteboardReads()
    setBusy(false)
    timer?.invalidate()
    timer = nil
    maintenanceTimer?.invalidate()
    maintenanceTimer = nil
    replayLeaseTimer?.invalidate()
    replayLeaseTimer = nil
    retryPendingReplayLeaseCleanup()
  }

  func refresh() {
    guard let store else { return }
    worker.async { [weak self] in
      guard let self else { return }
      do {
        let entries = try store.entries()
        let stats = try store.statistics()
        DispatchQueue.main.async {
          self.apply(entries: entries, stats: stats)
        }
      } catch {
        self.publishFailure(error)
      }
    }
  }

  func cleanNow() {
    cleanNow(announces: true)
  }

  func setPinned(_ entry: ClipboardHistoryEntry, pinned: Bool) {
    guard let store else { return }
    setBusy(true)
    worker.async { [weak self] in
      guard let self else { return }
      do {
        _ = try store.setPinned(id: entry.id, isPinned: pinned)
        let entries = try store.entries()
        let stats = try store.statistics()
        DispatchQueue.main.async {
          self.apply(entries: entries, stats: stats)
          self.isBusy = false
          self.statusMessage = pinned ? "已固定，自动清理会跳过这条" : "已取消固定"
        }
      } catch {
        self.publishFailure(error, clearsBusy: true)
      }
    }
  }

  func delete(_ entry: ClipboardHistoryEntry) {
    guard let store else { return }
    setBusy(true)
    worker.async { [weak self] in
      guard let self else { return }
      do {
        _ = try store.delete(id: entry.id)
        let entries = try store.entries()
        let stats = try store.statistics()
        DispatchQueue.main.async {
          self.apply(entries: entries, stats: stats)
          self.isBusy = false
          self.statusMessage =
            stats.pendingDeletionByteCount > 0
            ? "历史已删除；部分磁盘空间将在后台继续清理"
            : "已删除这条历史及本应用保存的副本"
        }
      } catch {
        self.publishFailure(error, clearsBusy: true)
      }
    }
  }

  func clearAll() {
    guard let store else { return }
    setBusy(true)
    worker.async { [weak self] in
      guard let self else { return }
      do {
        try store.clearAll()
        let stats = try store.statistics()
        DispatchQueue.main.async {
          self.apply(entries: [], stats: stats)
          self.isBusy = false
          self.statusMessage =
            stats.pendingDeletionByteCount > 0
            ? "历史已清空；部分磁盘空间将在后台继续清理，Finder 原文件未删除"
            : "历史已清空，Finder 中的原文件没有被删除"
        }
      } catch {
        self.publishFailure(error, clearsBusy: true)
      }
    }
  }

  func payloadURLs(for entry: ClipboardHistoryEntry) -> [URL] {
    store?.absolutePayloadURLs(for: entry) ?? []
  }

  func payloadURL(for entry: ClipboardHistoryEntry, at index: Int) -> URL? {
    store?.absolutePayloadURL(for: entry, at: index)
  }

  func prepareWorkingCopy(
    for entry: ClipboardHistoryEntry,
    at index: Int,
    actionDescription: String,
    completion: @escaping (Result<ClipboardHistoryWorkingCopy, Error>) -> Void
  ) {
    guard let store, entry.kind == .files else {
      let error = ClipboardHistoryStoreError.payload("选中的记录不是文件。")
      statusMessage = "无法\(actionDescription)：\(error.localizedDescription)"
      completion(.failure(error))
      return
    }

    setBusy(true)
    statusMessage = "正在准备\(actionDescription)副本…"
    worker.async { [weak self] in
      guard let self else { return }
      do {
        let cacheUsage = try self.cleanupWorkingCopyCache()
        let bytesOutsideCurrentSession = max(
          0,
          cacheUsage.totalBytes - cacheUsage.currentSessionBytes)
        let currentSessionAllowance = max(
          0,
          Self.workingCopyCacheLimit - bytesOutsideCurrentSession)
        let workingCopy = try store.makeTransientCopy(
          entryID: entry.id,
          payloadIndex: index,
          destinationRoot: self.workingCopySessionDirectory,
          destinationBoundary: self.workingCopyRoot,
          maxSessionBytes: currentSessionAllowance)
        DispatchQueue.main.async {
          self.isBusy = false
          self.statusMessage = nil
          completion(.success(workingCopy))
        }
      } catch {
        DispatchQueue.main.async {
          self.isBusy = false
          self.statusMessage = "无法\(actionDescription)：\(error.localizedDescription)"
          completion(.failure(error))
        }
      }
    }
  }

  func openWorkingCopy(for entry: ClipboardHistoryEntry, at index: Int) {
    prepareWorkingCopy(for: entry, at: index, actionDescription: "打开") { [weak self] result in
      guard let self, case .success(let workingCopy) = result else { return }
      if NSWorkspace.shared.open(workingCopy.url) {
        self.statusMessage = "已打开副本，修改不会影响历史"
      } else {
        self.discardWorkingCopy(workingCopy)
        self.statusMessage = "无法打开副本：没有可用的默认 App"
      }
    }
  }

  func revealWorkingCopy(for entry: ClipboardHistoryEntry, at index: Int) {
    prepareWorkingCopy(for: entry, at: index, actionDescription: "在访达中显示") {
      [weak self] result in
      guard let self, case .success(let workingCopy) = result else { return }
      NSWorkspace.shared.activateFileViewerSelecting([workingCopy.url])
      self.statusMessage = "已在访达中显示副本"
    }
  }

  func discardWorkingCopy(_ workingCopy: ClipboardHistoryWorkingCopy) {
    let container = workingCopy.containerURL.standardizedFileURL
    guard Self.isStrictDescendant(container, of: workingCopySessionDirectory) else { return }
    worker.async { [weak self] in
      guard let self else { return }
      _ = try? self.removeWorkingCopyContainerIfValid(container)
    }
  }

  func plainText(for entry: ClipboardHistoryEntry) -> String {
    if let cached = textPreviewCache.object(forKey: entry.id as NSString) {
      return cached as String
    }
    guard entry.kind == .text || entry.kind == .link,
      let url = payloadURLs(for: entry).first(where: { $0.lastPathComponent == "plain.txt" }),
      let handle = try? FileHandle(forReadingFrom: url)
    else { return entry.textSummary }
    defer { try? handle.close() }
    let previewLimit = 2 * 1_024 * 1_024
    guard let data = try? handle.read(upToCount: previewLimit + 1) else {
      return entry.textSummary
    }
    let wasTrimmed = data.count > previewLimit
    let preview = wasTrimmed ? data.prefix(previewLimit) : data[...]
    let text = String(decoding: preview, as: UTF8.self)
    let value = wasTrimmed ? "\(text)\n\n…（内容过长，预览仅显示前 2 MB）" : text
    textPreviewCache.setObject(value as NSString, forKey: entry.id as NSString, cost: data.count)
    return value
  }

  @discardableResult
  func copyToPasteboard(
    entry: ClipboardHistoryEntry,
    plainText: Bool = false,
    pasteboard: NSPasteboard = .general
  ) -> Bool {
    copyToPasteboard(
      entry: entry,
      plainText: plainText,
      pasteboardAdapter: pasteboard,
      tracksGeneralPasteboard: pasteboard === NSPasteboard.general)
  }

  /// Production activation path. Disk reads, replay-lease cloning, and the old clipboard snapshot
  /// all run away from the App process's main thread; only the bounded CAS write is committed on it.
  func copyToPasteboard(
    entry: ClipboardHistoryEntry,
    plainText: Bool = false,
    pasteboard: NSPasteboard = .general,
    completion: @escaping (Bool) -> Void
  ) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.copyToPasteboard(
          entry: entry,
          plainText: plainText,
          pasteboard: pasteboard,
          completion: completion)
      }
      return
    }
    guard store != nil else {
      setBusy(false)
      completion(false)
      return
    }

    replayGeneration &+= 1
    let generation = replayGeneration
    let snapshotChangeCount = pasteboard.changeCount
    let pasteboardName = pasteboard.name.rawValue
    setBusy(true)
    pollReplayLeaseIfPasteboardChanged()
    worker.async { [weak self] in
      guard let self else { return }
      let currentBeforePrepare = DispatchQueue.main.sync {
        generation == self.replayGeneration
      }
      guard currentBeforePrepare else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let result = Result { try self.prepareReplayPayload(entry: entry, plainText: plainText) }
      if case .success(let prepared) = result {
        let currentAfterPrepare = DispatchQueue.main.sync {
          generation == self.replayGeneration
        }
        guard currentAfterPrepare else {
          self.discardPreparedReplayPayloadOnWorker(prepared)
          DispatchQueue.main.async { completion(false) }
          return
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch result {
        case .failure(let error):
          guard generation == self.replayGeneration else {
            completion(false)
            return
          }
          self.isBusy = false
          self.statusMessage = "恢复到系统剪贴板失败：\(error.localizedDescription)"
          completion(false)
        case .success(let prepared):
          guard generation == self.replayGeneration,
            pasteboard.changeCount == snapshotChangeCount
          else {
            self.discardPreparedReplayPayload(prepared)
            self.isBusy = false
            completion(false)
            return
          }
          ClipboardPasteboardIsolation.snapshot(
            pasteboardName: pasteboardName,
            expectedChangeCount: snapshotChangeCount,
            byteLimit: ClipboardPasteboardSnapshot.defaultByteLimit
          ) { [weak self] snapshotResult in
            guard let self else { return }
            guard generation == self.replayGeneration,
              pasteboard.changeCount == snapshotChangeCount,
              case .success(let snapshot) = snapshotResult,
              snapshot.changeCount == snapshotChangeCount
            else {
              self.discardPreparedReplayPayload(prepared)
              self.isBusy = false
              switch snapshotResult {
              case .timedOut:
                self.statusMessage = "剪贴板提供方响应过慢，未改动原剪贴板"
              case .rejected:
                self.statusMessage = "剪贴板内容超过安全备份上限，未改动原剪贴板"
              case .stale:
                self.statusMessage = "剪贴板刚刚被其他内容更新，请重试"
              case .noPayload, .failed, .success:
                self.statusMessage = "剪贴板无法在隔离环境中安全备份，未改动原剪贴板"
              }
              completion(false)
              return
            }
            let didCommit = self.commitReplayPayload(
              prepared,
              entry: entry,
              pasteboard: pasteboard,
              snapshot: snapshot,
              tracksGeneralPasteboard: pasteboard === NSPasteboard.general)
            self.isBusy = false
            if didCommit { self.successfulUse?() }
            completion(didCommit)
          }
        }
      }
    }
  }

  /// Injectable synchronous seam used by interaction fixtures to force post-clear failures.
  @discardableResult
  func copyToPasteboard(
    entry: ClipboardHistoryEntry,
    plainText: Bool = false,
    pasteboardAdapter: any ClipboardHistoryPasteboard,
    tracksGeneralPasteboard: Bool = false
  ) -> Bool {
    do {
      guard !(pasteboardAdapter is NSPasteboard),
        let snapshot = snapshotPasteboard(pasteboardAdapter)
      else {
        statusMessage = "恢复到系统剪贴板失败：生产剪贴板必须走异步隔离读取。"
        return false
      }
      let prepared = try prepareReplayPayload(entry: entry, plainText: plainText)
      return commitReplayPayload(
        prepared,
        entry: entry,
        pasteboard: pasteboardAdapter,
        snapshot: snapshot,
        tracksGeneralPasteboard: tracksGeneralPasteboard)
    } catch {
      statusMessage = "恢复到系统剪贴板失败：\(error.localizedDescription)"
      return false
    }
  }

  private func prepareReplayPayload(
    entry: ClipboardHistoryEntry,
    plainText: Bool
  ) throws -> PreparedReplayPayload {
    guard let store else {
      throw ClipboardHistoryStoreError.payload("剪贴板历史存储不可用。")
    }
    let urls = store.absolutePayloadURLs(for: entry)
    guard urls.count == entry.payloadRelativePaths.count, !urls.isEmpty else {
      throw ClipboardHistoryStoreError.payload("保存的内容已不存在。")
    }

    switch entry.kind {
    case .files:
      try ensureReplayLeaseDirectories()
      let totalReplayBytes = Self.logicalByteCount(
        at: replayLeaseRoot,
        fileManager: .default)
      let currentSessionBytes = Self.logicalByteCount(
        at: replayLeaseSessionDirectory,
        fileManager: .default)
      let bytesOutsideCurrentSession = max(0, totalReplayBytes - currentSessionBytes)
      let currentSessionAllowance = max(
        0,
        replayLeaseCacheLimit - min(replayLeaseCacheLimit, bytesOutsideCurrentSession))
      let lease = try store.makeReplayLease(
        entryID: entry.id,
        destinationRoot: replayLeaseSessionDirectory,
        destinationBoundary: replayLeaseRoot,
        maxCacheBytes: currentSessionAllowance)
      afterReplayLeasePrepared?()
      return .files(
        ManagedReplayLease(lease: lease, destinationRoot: replayLeaseSessionDirectory))

    case .image:
      guard let url = urls.first,
        FileManager.default.fileExists(atPath: url.path),
        let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        !data.isEmpty
      else {
        throw ClipboardHistoryStoreError.payload("保存的图片已不存在。")
      }
      return .image(data)

    case .text, .link:
      let plainURL = urls.first { $0.lastPathComponent == "plain.txt" }
      let richURL = urls.first { $0.lastPathComponent == "rich.data" }
      let plain = plainURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
      let richData =
        plainText ? nil : richURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
      let richType =
        plainText ? nil : entry.richUTI.map { NSPasteboard.PasteboardType($0) }
      guard plain != nil || (richType != nil && richData?.isEmpty == false) else {
        throw ClipboardHistoryStoreError.payload("保存的文字已不存在。")
      }
      return .text(plain: plain, richType: richType, richData: richData)
    }
  }

  private func commitReplayPayload(
    _ prepared: PreparedReplayPayload,
    entry: ClipboardHistoryEntry,
    pasteboard: any ClipboardHistoryPasteboard,
    snapshot: ClipboardPasteboardSnapshot,
    tracksGeneralPasteboard: Bool
  ) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let objects = pasteboardObjects(for: prepared), !objects.isEmpty else {
      discardPreparedReplayPayload(prepared)
      statusMessage = "恢复到系统剪贴板失败"
      return false
    }
    guard pasteboard.changeCount == snapshot.changeCount else {
      discardPreparedReplayPayload(prepared)
      statusMessage = "剪贴板刚刚被其他内容更新，请重试"
      return false
    }

    let ownedChangeCount = pasteboard.clearContents()
    guard pasteboard.changeCount == ownedChangeCount else {
      discardPreparedReplayPayload(prepared)
      statusMessage = "剪贴板已被其他内容更新，本次恢复已取消"
      return false
    }
    if tracksGeneralPasteboard, case .files(let incomingLease) = prepared {
      let candidates = [incomingLease] + (activeReplayLease.map { [$0.managed] } ?? [])
      do {
        try persistReplayLeaseMarker(candidates: candidates)
      } catch {
        let restoredChangeCount = restorePasteboard(
          snapshot,
          to: pasteboard,
          expectedChangeCount: ownedChangeCount)
        if let restoredChangeCount {
          lastChangeCount = restoredChangeCount
          rebindActiveReplayLeaseAfterRollback(
            pasteboard: pasteboard,
            snapshotChangeCount: snapshot.changeCount,
            restoredChangeCount: restoredChangeCount)
        }
        discardPreparedReplayPayload(prepared)
        if tracksGeneralPasteboard, activeReplayLease == nil {
          removeActiveReplayLeaseMarker()
        }
        statusMessage =
          restoredChangeCount == nil
          ? "无法保护文件回放状态；剪贴板已被其他内容更新"
          : "无法保护文件回放状态，原剪贴板内容已恢复"
        return false
      }
    }
    guard pasteboard.changeCount == ownedChangeCount else {
      discardPreparedReplayPayload(prepared)
      releaseActiveReplayLease()
      if tracksGeneralPasteboard { removeActiveReplayLeaseMarker() }
      statusMessage = "文件回放写入前剪贴板已被其他内容更新"
      return false
    }
    let didWrite = pasteboard.writeObjects(objects)
    let resultingChangeCount = pasteboard.changeCount
    guard didWrite, resultingChangeCount == ownedChangeCount else {
      let restoredChangeCount =
        resultingChangeCount == ownedChangeCount
        ? restorePasteboard(
          snapshot,
          to: pasteboard,
          expectedChangeCount: resultingChangeCount)
        : nil
      if let restoredChangeCount {
        if tracksGeneralPasteboard { lastChangeCount = restoredChangeCount }
        rebindActiveReplayLeaseAfterRollback(
          pasteboard: pasteboard,
          snapshotChangeCount: snapshot.changeCount,
          restoredChangeCount: restoredChangeCount)
      }
      discardPreparedReplayPayload(prepared)
      if tracksGeneralPasteboard, activeReplayLease == nil {
        removeActiveReplayLeaseMarker()
      }
      statusMessage =
        restoredChangeCount != nil
        ? "恢复到系统剪贴板失败，原剪贴板内容已恢复"
        : "恢复到系统剪贴板失败；剪贴板已被其他内容更新"
      return false
    }

    if tracksGeneralPasteboard, case .files(let committedLease) = prepared {
      do {
        try persistReplayLeaseMarker(candidates: [committedLease])
      } catch {
        let restoredChangeCount = restorePasteboard(
          snapshot,
          to: pasteboard,
          expectedChangeCount: ownedChangeCount)
        if let restoredChangeCount {
          lastChangeCount = restoredChangeCount
          rebindActiveReplayLeaseAfterRollback(
            pasteboard: pasteboard,
            snapshotChangeCount: snapshot.changeCount,
            restoredChangeCount: restoredChangeCount)
        }
        discardPreparedReplayPayload(prepared)
        if activeReplayLease == nil { removeActiveReplayLeaseMarker() }
        statusMessage =
          restoredChangeCount == nil
          ? "文件回放已写入但保护标记提交失败；剪贴板已被其他内容更新"
          : "文件回放保护标记提交失败，原剪贴板内容已恢复"
        return false
      }
      guard pasteboard.changeCount == ownedChangeCount else {
        discardPreparedReplayPayload(prepared)
        releaseActiveReplayLease()
        removeActiveReplayLeaseMarker()
        statusMessage = "文件回放提交期间剪贴板已被其他内容更新"
        return false
      }
    }

    if tracksGeneralPasteboard {
      lastChangeCount = ownedChangeCount
    }
    switch prepared {
    case .files(let managed):
      replaceActiveReplayLease(
        with: managed,
        pasteboard: pasteboard,
        changeCount: ownedChangeCount,
        persistsAcrossControllerLifetime: tracksGeneralPasteboard)
      statusMessage = "已将 \(entry.fileNames.count) 个文件作为一组放回系统剪贴板"
    case .image, .text:
      releaseActiveReplayLease()
      statusMessage = "已放回系统剪贴板，按 ⌘V 即可粘贴"
    }
    return true
  }

  private func pasteboardObjects(
    for prepared: PreparedReplayPayload
  ) -> [NSPasteboardWriting]? {
    switch prepared {
    case .files(let managed):
      return managed.lease.urls.map { $0 as NSURL }
    case .image(let data):
      let item = NSPasteboardItem()
      guard item.setData(data, forType: .png) else { return nil }
      return [item]
    case .text(let plain, let richType, let richData):
      let item = NSPasteboardItem()
      var wroteValue = false
      if let richType, let richData, !richData.isEmpty {
        guard item.setData(richData, forType: richType) else { return nil }
        wroteValue = true
      }
      if let plain {
        guard item.setString(plain, forType: .string) else { return nil }
        wroteValue = true
      }
      return wroteValue ? [item] : nil
    }
  }

  private func snapshotPasteboard(
    _ pasteboard: any ClipboardHistoryPasteboard
  ) -> ClipboardPasteboardSnapshot? {
    ClipboardPasteboardSnapshot.capture(from: pasteboard)
  }

  private func restorePasteboard(
    _ snapshot: ClipboardPasteboardSnapshot,
    to pasteboard: any ClipboardHistoryPasteboard,
    expectedChangeCount: Int
  ) -> Int? {
    snapshot.restore(to: pasteboard, expectedChangeCount: expectedChangeCount)
  }

  private func rebindActiveReplayLeaseAfterRollback(
    pasteboard: any ClipboardHistoryPasteboard,
    snapshotChangeCount: Int,
    restoredChangeCount: Int
  ) {
    guard let activeReplayLease,
      activeReplayLease.pasteboard === pasteboard,
      activeReplayLease.changeCount == snapshotChangeCount
    else { return }
    self.activeReplayLease = ActiveReplayLease(
      managed: activeReplayLease.managed,
      pasteboard: pasteboard,
      changeCount: restoredChangeCount)
  }

  private func discardPreparedReplayPayload(_ prepared: PreparedReplayPayload) {
    guard case .files(let managed) = prepared else { return }
    scheduleReplayLeaseDiscard(managed)
  }

  private func discardPreparedReplayPayloadOnWorker(_ prepared: PreparedReplayPayload) {
    guard case .files(let managed) = prepared, let store else { return }
    do {
      try store.discardReplayLease(
        managed.lease,
        destinationRoot: managed.destinationRoot,
        destinationBoundary: replayLeaseRoot)
    } catch {
      DispatchQueue.main.async { [weak self] in
        guard let self,
          !self.pendingReplayLeaseCleanup.contains(where: {
            $0.lease.containerURL == managed.lease.containerURL
          })
        else { return }
        self.pendingReplayLeaseCleanup.append(managed)
        self.ensureReplayLeaseTimer()
      }
    }
  }

  private func replaceActiveReplayLease(
    with managed: ManagedReplayLease,
    pasteboard: any ClipboardHistoryPasteboard,
    changeCount: Int,
    persistsAcrossControllerLifetime: Bool
  ) {
    let previous = activeReplayLease?.managed
    activeReplayLease = ActiveReplayLease(
      managed: managed,
      pasteboard: pasteboard,
      changeCount: changeCount)
    if !persistsAcrossControllerLifetime {
      removeActiveReplayLeaseMarker()
    }
    ensureReplayLeaseTimer()
    if let previous { scheduleReplayLeaseDiscard(previous) }
  }

  private func ensureReplayLeaseTimer() {
    guard replayLeaseTimer == nil else { return }
    let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
      self?.pollReplayLeaseIfPasteboardChanged()
    }
    RunLoop.main.add(timer, forMode: .common)
    replayLeaseTimer = timer
  }

  /// Internal so the interaction fixture can deterministically advance the lease lifecycle.
  func pollReplayLeaseIfPasteboardChanged() {
    retryPendingReplayLeaseCleanup()
    guard let activeReplayLease else {
      if pendingReplayLeaseCleanup.isEmpty {
        replayLeaseTimer?.invalidate()
        replayLeaseTimer = nil
      }
      return
    }
    guard activeReplayLease.pasteboard.changeCount != activeReplayLease.changeCount else { return }
    self.activeReplayLease = nil
    removeActiveReplayLeaseMarker()
    scheduleReplayLeaseDiscard(activeReplayLease.managed)
  }

  private func releaseActiveReplayLease() {
    guard let activeReplayLease else { return }
    self.activeReplayLease = nil
    removeActiveReplayLeaseMarker()
    scheduleReplayLeaseDiscard(activeReplayLease.managed)
  }

  private func scheduleReplayLeaseDiscard(_ managed: ManagedReplayLease) {
    guard let store else { return }
    let destinationBoundary = replayLeaseRoot
    worker.async { [weak self, store] in
      do {
        try store.discardReplayLease(
          managed.lease,
          destinationRoot: managed.destinationRoot,
          destinationBoundary: destinationBoundary)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self,
            !self.pendingReplayLeaseCleanup.contains(where: {
              $0.lease.containerURL == managed.lease.containerURL
            })
          else { return }
          self.pendingReplayLeaseCleanup.append(managed)
          self.ensureReplayLeaseTimer()
        }
      }
    }
  }

  private func retryPendingReplayLeaseCleanup() {
    guard !pendingReplayLeaseCleanup.isEmpty else { return }
    let pending = pendingReplayLeaseCleanup
    pendingReplayLeaseCleanup.removeAll()
    for managed in pending { scheduleReplayLeaseDiscard(managed) }
  }

  private func syncMonitoring(performInitialMaintenance: Bool = true) {
    if activeReplayLease != nil { ensureReplayLeaseTimer() }
    guard store != nil else {
      stop()
      return
    }
    if maintenanceTimer == nil {
      if performInitialMaintenance { cleanNow(announces: false) }
      let maintenance = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
        self?.cleanNow(announces: false)
      }
      RunLoop.main.add(maintenance, forMode: .common)
      maintenanceTimer = maintenance
    }
    guard runtimeAllowed else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard isEnabled else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard timer == nil else { return }
    lastChangeCount = NSPasteboard.general.changeCount
    sourceCandidatesSinceLastPasteboardChange = [
      Self.source(for: NSWorkspace.shared.frontmostApplication)
    ]
    worker.async { [weak self] in
      self?.workerLastObservedPasteboardFingerprint = nil
    }
    observedExcludedTransientChange = false
    let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
      self?.pollPasteboard()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func pollPasteboard() {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    let currentSource = Self.source(for: NSWorkspace.shared.frontmostApplication)
    recordSourceCandidate(currentSource)
    let possibleSources = sourceCandidatesSinceLastPasteboardChange
    // Keep only the current foreground owner after every poll. Activation history is therefore
    // a narrow attribution window, not a stale list that could suppress an unrelated copy later.
    sourceCandidatesSinceLastPasteboardChange = [currentSource]
    guard changeCount != lastChangeCount else { return }
    let previousChangeCount = lastChangeCount
    lastChangeCount = changeCount
    let changeCountDelta = Self.changeCountDelta(
      from: previousChangeCount,
      to: changeCount)

    guard !ClipboardHistorySuppression.consume(changeCount: changeCount) else {
      uncommittedPasteboardChangeDelta = 0
      return
    }
    let pasteboardTypes = pasteboard.types ?? []
    if containsTransientType(pasteboardTypes) {
      uncommittedPasteboardChangeDelta = Self.saturatedChangeCountSum(
        uncommittedPasteboardChangeDelta,
        changeCountDelta)
      observedExcludedTransientChange = typelessExclusionIsActive
      statusMessage =
        observedExcludedTransientChange
        ? "已跳过 Typeless 产生的临时剪贴板"
        : "已跳过密码或临时剪贴板内容"
      return
    }
    guard !containsSensitiveOrTransientType(pasteboardTypes) else {
      uncommittedPasteboardChangeDelta = 0
      observedExcludedTransientChange = false
      resetObservationFingerprint()
      statusMessage = "已跳过密码或临时剪贴板内容"
      return
    }
    if let excludedSource = possibleSources.first(where: {
      ClipboardHistoryExclusionPolicy.isSourceExcluded(
        $0,
        applications: excludedApplications)
    }) {
      uncommittedPasteboardChangeDelta = 0
      observedExcludedTransientChange = false
      resetObservationFingerprint()
      statusMessage = "已跳过可能来自 \(excludedSource.applicationName ?? "排除软件") 的复制内容"
      return
    }
    uncommittedPasteboardChangeDelta = Self.saturatedChangeCountSum(
      uncommittedPasteboardChangeDelta,
      changeCountDelta)
    pasteboardCaptureGeneration &+= 1
    let request = PendingClipboardReadRequest(
      generation: pasteboardCaptureGeneration,
      pasteboardName: pasteboard.name.rawValue,
      expectedChangeCount: changeCount,
      source: currentSource,
      capturedAt: Date(),
      changeCountDelta: uncommittedPasteboardChangeDelta,
      observedTransientChange: observedExcludedTransientChange,
      typelessExcluded: ClipboardHistoryExclusionPolicy.containsTypeless(
        excludedApplications),
      typelessRunning: !NSRunningApplication.runningApplications(
        withBundleIdentifier: ClipboardHistoryExclusionPolicy.typelessBundleIdentifier
      ).isEmpty)
    observedExcludedTransientChange = false
    enqueuePasteboardRead(request)
  }

  private func enqueuePasteboardRead(_ request: PendingClipboardReadRequest) {
    dispatchPrecondition(condition: .onQueue(.main))
    if pasteboardCaptureInFlight {
      // Coalesce bursts instead of creating an attacker-controlled queue of slow providers.
      deferredPasteboardRead = request
      return
    }
    startPasteboardRead(request)
  }

  private func startPasteboardRead(_ request: PendingClipboardReadRequest) {
    dispatchPrecondition(condition: .onQueue(.main))
    pasteboardCaptureInFlight = true
    ClipboardPasteboardIsolation.capture(
      pasteboardName: request.pasteboardName,
      expectedChangeCount: request.expectedChangeCount
    ) { [weak self] result in
      guard let self else { return }
      self.pasteboardCaptureInFlight = false
      defer { self.startDeferredPasteboardReadIfNeeded() }
      guard request.generation == self.pasteboardCaptureGeneration,
        self.runtimeAllowed,
        self.isEnabled,
        NSPasteboard.general.name.rawValue == request.pasteboardName,
        NSPasteboard.general.changeCount == request.expectedChangeCount
      else { return }

      guard case .success(let wire) = result,
        let capture = self.pendingCapture(
          from: wire,
          source: request.source,
          capturedAt: request.capturedAt)
      else {
        self.uncommittedPasteboardChangeDelta = 0
        self.resetObservationFingerprint()
        switch result {
        case .rejected:
          self.statusMessage = "已跳过：剪贴板内容超过安全上限或无法安全读取"
        case .timedOut:
          self.statusMessage = "已跳过：剪贴板提供方响应过慢"
        case .failed:
          self.statusMessage = "已跳过：剪贴板内容无法在隔离环境中安全读取"
        case .noPayload, .stale, .success:
          break
        }
        return
      }
      self.uncommittedPasteboardChangeDelta = 0
      self.save(
        PendingClipboardObservation(
          capture: capture,
          changeCountDelta: request.changeCountDelta,
          observedTransientChange: request.observedTransientChange,
          typelessExcluded: request.typelessExcluded,
          typelessRunning: request.typelessRunning))
    }
  }

  private func startDeferredPasteboardReadIfNeeded() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let deferred = deferredPasteboardRead else { return }
    deferredPasteboardRead = nil
    guard deferred.generation == pasteboardCaptureGeneration,
      runtimeAllowed,
      isEnabled,
      NSPasteboard.general.name.rawValue == deferred.pasteboardName,
      NSPasteboard.general.changeCount == deferred.expectedChangeCount
    else { return }
    startPasteboardRead(deferred)
  }

  private func invalidatePasteboardReads() {
    dispatchPrecondition(condition: .onQueue(.main))
    pasteboardCaptureGeneration &+= 1
    deferredPasteboardRead = nil
    uncommittedPasteboardChangeDelta = 0
  }

  private func pendingCapture(
    from wire: ClipboardPasteboardIsolation.CaptureWire,
    source: ClipboardHistorySource,
    capturedAt: Date
  ) -> PendingClipboardCapture? {
    switch wire.kind {
    case "files":
      guard let paths = wire.filePaths,
        !paths.isEmpty,
        paths.count <= Self.maximumCapturedFileCount
      else { return nil }
      let urls = paths.map { URL(fileURLWithPath: $0) }
      return .ready(
        ClipboardHistoryCapture(files: urls, source: source, capturedAt: capturedAt))
    case "png":
      guard let data = wire.data, !data.isEmpty,
        data.count <= Self.maximumCapturedImageBytes
      else { return nil }
      return .ready(
        ClipboardHistoryCapture(imagePNGData: data, source: source, capturedAt: capturedAt))
    case "tiff":
      guard let data = wire.data, !data.isEmpty,
        data.count <= Self.maximumCapturedImageBytes
      else { return nil }
      return .tiff(data, source: source, capturedAt: capturedAt)
    case "text":
      guard (wire.text?.utf8.count ?? 0) <= Self.maximumCapturedPlainTextBytes,
        (wire.richData?.count ?? 0) <= Self.maximumCapturedRichTextBytes,
        wire.text != nil || wire.richData != nil
      else { return nil }
      return .ready(
        ClipboardHistoryCapture(
          text: wire.text,
          richData: wire.richData,
          richUTI: wire.richUTI,
          source: source,
          capturedAt: capturedAt))
    default:
      return nil
    }
  }

  private func save(_ observation: PendingClipboardObservation) {
    guard let store else { return }
    let retentionDays = retentionDays
    let maxBytes = maxBytes
    setBusy(true)
    worker.async { [weak self] in
      guard let self else { return }
      do {
        let capture = try Self.prepareCaptureForStorage(observation.capture)
        let fingerprint = ClipboardHistoryExclusionPolicy.observationFingerprint(for: capture)
        let shouldSkipTypelessRoundTrip =
          ClipboardHistoryExclusionPolicy.shouldSkipTypelessRoundTrip(
            previousFingerprint: self.workerLastObservedPasteboardFingerprint,
            currentFingerprint: fingerprint,
            changeCountDelta: observation.changeCountDelta,
            observedTransientChange: observation.observedTransientChange,
            typelessExcluded: observation.typelessExcluded,
            typelessRunning: observation.typelessRunning)
        self.workerLastObservedPasteboardFingerprint = fingerprint
        if shouldSkipTypelessRoundTrip {
          DispatchQueue.main.async {
            self.isBusy = false
            self.statusMessage = "已跳过 Typeless 产生的临时剪贴板"
          }
          return
        }
        let result: ClipboardHistoryCaptureResult
        if capture.files.isEmpty {
          result = try store.capture(
            capture,
            retentionDays: retentionDays,
            maxBytes: maxBytes)
        } else {
          let isolated = ClipboardPasteboardIsolation.storeFiles(
            capture,
            baseDirectory: self.storeBaseDirectory,
            retentionDays: retentionDays,
            maxBytes: maxBytes)
          switch isolated {
          case .success(let wire):
            switch wire.outcome {
            case "inserted":
              guard let entry = wire.entry, entry.kind == .files else {
                throw ClipboardHistoryStoreError.payload("隔离文件保存结果无效。")
              }
              result = .inserted(entry)
            case "deduplicated":
              guard let entry = wire.entry, entry.kind == .files else {
                throw ClipboardHistoryStoreError.payload("隔离文件去重结果无效。")
              }
              result = .deduplicated(entry)
            case "skipped":
              guard let message = wire.skipMessage, !message.isEmpty,
                message.utf8.count <= 2_048, wire.entry == nil
              else {
                throw ClipboardHistoryStoreError.payload("文件保存返回了无效的跳过原因。")
              }
              try store.recoverAfterIsolatedCapture()
              let entries = try store.entries()
              let stats = try store.statistics()
              DispatchQueue.main.async {
                self.apply(entries: entries, stats: stats)
                self.isBusy = false
                self.statusMessage = "本次文件未保存：\(message)"
              }
              return
            case "rejected-quota":
              guard let requiredBytes = wire.requiredBytes,
                let returnedMaxBytes = wire.maxBytes,
                requiredBytes >= 0,
                returnedMaxBytes == maxBytes
              else {
                throw ClipboardHistoryStoreError.payload("隔离文件配额结果无效。")
              }
              result = .rejectedQuota(
                requiredBytes: requiredBytes,
                maxBytes: returnedMaxBytes)
            default:
              throw ClipboardHistoryStoreError.payload("隔离文件保存结果无效。")
            }
          case .timedOut, .failed:
            // A child can commit SQLite/files and then lose its response. In that interval a
            // timeout is an unknown acknowledgement, not proof of rollback. Reconcile the
            // canonical store and show its authoritative state instead of reporting a false
            // failure or hiding an entry that already replaced older history.
            try store.recoverAfterIsolatedCapture()
            let entries = try store.entries()
            let stats = try store.statistics()
            DispatchQueue.main.async {
              self.apply(entries: entries, stats: stats)
              self.isBusy = false
              self.statusMessage =
                "文件保存确认中断；已重新核对历史，结果以当前列表为准。"
            }
            return
          case .rejected, .noPayload, .stale:
            try store.recoverAfterIsolatedCapture()
            let entries = try store.entries()
            let stats = try store.statistics()
            DispatchQueue.main.async {
              self.apply(entries: entries, stats: stats)
              self.isBusy = false
              self.statusMessage = "本次文件未保存：文件读取请求无效，请重新复制；已有历史仍可使用。"
            }
            return
          }
        }
        let entries = try store.entries()
        let stats = try store.statistics()
        DispatchQueue.main.async {
          self.apply(entries: entries, stats: stats)
          self.isBusy = false
          switch result {
          case .inserted(let entry):
            self.statusMessage =
              entry.kind == .files
              ? "已保存 \(entry.fileNames.count) 个文件，合并为一条历史"
              : "已保存到剪贴板历史"
          case .deduplicated(let entry):
            self.statusMessage = "已合并重复内容 · \(entry.copyCount) 次"
          case .rejectedQuota(let requiredBytes, let maxBytes):
            self.statusMessage =
              "保存失败：本次需要 \(Self.byteText(requiredBytes))，空间上限为 \(Self.byteText(maxBytes))"
          }
        }
      } catch {
        self.publishFailure(error, clearsBusy: true)
      }
    }
  }

  private func cleanNow(announces: Bool) {
    guard let store else { return }
    let retentionDays = retentionDays
    let maxBytes = maxBytes
    setBusy(true)
    worker.async { [weak self] in
      guard let self else { return }
      do {
        _ = try? self.cleanupWorkingCopyCache()
        let stats = try store.cleanup(retentionDays: retentionDays, maxBytes: maxBytes)
        let entries = try store.entries()
        DispatchQueue.main.async {
          self.apply(entries: entries, stats: stats)
          self.isBusy = false
          if announces {
            self.statusMessage =
              stats.pendingDeletionByteCount > 0
              ? "历史规则已执行；部分磁盘空间将在后台继续清理"
              : "已按 \(retentionDays) 天和 \(Self.byteText(maxBytes)) 上限清理"
          }
        }
      } catch {
        self.publishFailure(error, clearsBusy: true)
      }
    }
  }

  private func apply(entries: [ClipboardHistoryEntry], stats: ClipboardHistoryStats) {
    let entryIDs = Set(entries.map(\.id))
    if self.entries.contains(where: { !entryIDs.contains($0.id) }) {
      textPreviewCache.removeAllObjects()
    }
    self.entries = entries
    usedBytes = stats.totalByteCount
    pendingDeletionBytes = stats.pendingDeletionByteCount
    if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
      self.selectedEntryID = entries.first?.id
    } else if self.selectedEntryID == nil {
      self.selectedEntryID = entries.first?.id
    }
    let pinnedBytes = entries.lazy.filter(\.isPinned).reduce(Int64(0)) { partial, entry in
      let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
      return overflow ? Int64.max : sum
    }
    quotaBlocked = pinnedBytes >= maxBytes
  }

  private func setBusy(_ busy: Bool) {
    if Thread.isMainThread {
      isBusy = busy
    } else {
      DispatchQueue.main.async { [weak self] in self?.isBusy = busy }
    }
  }

  private func publishFailure(_ error: Error, clearsBusy: Bool = false) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if clearsBusy { self.isBusy = false }
      self.statusMessage = "保存失败：\(error.localizedDescription)"
    }
  }

  private struct WorkingCopyCacheUsage {
    let totalBytes: Int64
    let currentSessionBytes: Int64
  }

  private struct WorkingCopyCacheItem {
    let url: URL
    let sessionURL: URL
    let modifiedAt: Date
    let byteCount: Int64
  }

  private func ensureReplayLeaseDirectories() throws {
    let cachesDirectory = workingCopyChannelDirectory.deletingLastPathComponent()
    guard Self.isRealDirectory(cachesDirectory) else {
      throw ClipboardHistoryStoreError.payload("系统缓存目录不可用。")
    }
    try Self.ensurePrivateDirectChild(workingCopyChannelDirectory, of: cachesDirectory)
    try Self.ensurePrivateDirectChild(replayLeaseRoot, of: workingCopyChannelDirectory)
    try Self.ensurePrivateDirectChild(replayLeaseSessionDirectory, of: replayLeaseRoot)
  }

  private var activeReplayLeaseMarkerURL: URL {
    replayLeaseRoot.appendingPathComponent("active-lease.json")
  }

  private func persistReplayLeaseMarker(candidates: [ManagedReplayLease]) throws {
    try ensureReplayLeaseDirectories()
    try beforeReplayMarkerWrite?()
    var seenContainers: Set<String> = []
    let markerCandidates = candidates.compactMap { managed -> ReplayLeaseMarkerCandidate? in
      let containerPath = managed.lease.containerURL.standardizedFileURL.path
      guard seenContainers.insert(containerPath).inserted else { return nil }
      return ReplayLeaseMarkerCandidate(
        containerPath: containerPath,
        urlPaths: managed.lease.urls.map { $0.standardizedFileURL.path },
        byteCount: managed.lease.byteCount)
    }
    guard !markerCandidates.isEmpty else {
      throw ClipboardHistoryStoreError.payload("文件回放保护标记没有可用候选。")
    }
    let marker = ReplayLeaseMarker(candidates: markerCandidates)
    let markerData = try JSONEncoder().encode(marker)
    let temporaryURL = replayLeaseRoot.appendingPathComponent(
      "\(UUID().uuidString.lowercased()).marker-partial")
    guard
      FileManager.default.createFile(
        atPath: temporaryURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600])
    else {
      throw ClipboardHistoryStoreError.payload("无法创建文件回放保护标记。")
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    do {
      let handle = try FileHandle(forWritingTo: temporaryURL)
      defer { try? handle.close() }
      try handle.write(contentsOf: markerData)
      try handle.synchronize()
    } catch {
      throw ClipboardHistoryStoreError.payload("无法写入文件回放保护标记。")
    }
    let renameResult = temporaryURL.path.withCString { sourcePath in
      activeReplayLeaseMarkerURL.path.withCString { destinationPath in
        rename(sourcePath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw ClipboardHistoryStoreError.payload("无法提交文件回放保护标记。")
    }
    // Nothing throwable may follow the atomic rename: callers can now treat the marker as durable.
  }

  private func removeActiveReplayLeaseMarker() {
    try? FileManager.default.removeItem(at: activeReplayLeaseMarkerURL)
  }

  private func recoverActiveReplayLeaseFromGeneralPasteboard() throws {
    try ensureReplayLeaseDirectories()
    guard let data = try? Data(contentsOf: activeReplayLeaseMarkerURL),
      let marker = try? JSONDecoder().decode(ReplayLeaseMarker.self, from: data),
      !marker.candidates.isEmpty
    else { return }

    let pasteboardURLs =
      (systemPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) ?? [])
      .compactMap { ($0 as? NSURL).map { ($0 as URL).standardizedFileURL } }
    let pasteboardPaths = Set(pasteboardURLs.map(\.path))
    guard
      let selected = marker.candidates.first(where: { candidate in
        candidate.byteCount >= 0 && candidate.byteCount <= replayLeaseCacheLimit
          && Set(candidate.urlPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            == pasteboardPaths
      })
    else { return }

    let container = URL(fileURLWithPath: selected.containerPath, isDirectory: true)
      .standardizedFileURL
    let session = container.deletingLastPathComponent()
    guard Self.hasUUIDSuffix(container.lastPathComponent, suffix: ".ready"),
      Self.hasUUIDSuffix(session.lastPathComponent, suffix: ".session"),
      Self.isRealDirectory(replayLeaseRoot),
      Self.isRealDirectory(session),
      Self.isRealDirectory(container),
      Self.isResolvedDirectChild(session, of: replayLeaseRoot),
      Self.isResolvedDirectChild(container, of: session),
      pasteboardURLs.allSatisfy({
        Self.isStrictDescendant($0, of: container)
          && Self.pathExistsWithoutFollowingLink($0)
      })
    else { return }

    let managed = ManagedReplayLease(
      lease: ClipboardHistoryReplayLease(
        urls: pasteboardURLs,
        containerURL: container,
        byteCount: selected.byteCount),
      destinationRoot: session)
    activeReplayLease = ActiveReplayLease(
      managed: managed,
      pasteboard: systemPasteboard,
      changeCount: systemPasteboard.changeCount)
    ensureReplayLeaseTimer()
  }

  private func cleanupStaleReplayLeaseCache(protecting protectedContainer: URL?) throws {
    try ensureReplayLeaseDirectories()
    let normalizedProtectedContainer = protectedContainer?.standardizedFileURL
    let protectedSession = normalizedProtectedContainer?.deletingLastPathComponent()
    let sessions = try FileManager.default.contentsOfDirectory(
      at: replayLeaseRoot,
      includingPropertiesForKeys: nil,
      options: [])
    for session in sessions {
      guard Self.hasUUIDSuffix(session.lastPathComponent, suffix: ".session"),
        Self.isRealDirectory(session),
        Self.isResolvedDirectChild(session, of: replayLeaseRoot)
      else { continue }
      if session.standardizedFileURL == replayLeaseSessionDirectory.standardizedFileURL {
        continue
      }
      if session.standardizedFileURL == protectedSession {
        let siblings = try FileManager.default.contentsOfDirectory(
          at: session,
          includingPropertiesForKeys: nil,
          options: [])
        for sibling in siblings
        where sibling.standardizedFileURL != normalizedProtectedContainer
          && (Self.hasUUIDSuffix(sibling.lastPathComponent, suffix: ".ready")
            || Self.hasUUIDSuffix(sibling.lastPathComponent, suffix: ".partial"))
          && Self.isRealDirectory(sibling)
          && Self.isResolvedDirectChild(sibling, of: session)
        {
          try Self.makeWorkingTreeRemovable(at: sibling)
          try FileManager.default.removeItem(at: sibling)
        }
        continue
      }
      try Self.makeWorkingTreeRemovable(at: session)
      try FileManager.default.removeItem(at: session)
    }
  }

  private func cleanupWorkingCopyCache(now: Date = Date()) throws -> WorkingCopyCacheUsage {
    try ensureWorkingCopyDirectories()
    let fileManager = FileManager.default
    let expiration = now.addingTimeInterval(-Self.workingCopyLifetime)
    let rootChildren = try fileManager.contentsOfDirectory(
      at: workingCopyRoot,
      includingPropertiesForKeys: nil,
      options: [])
    let sessions = rootChildren.filter { session in
      Self.hasUUIDSuffix(session.lastPathComponent, suffix: ".session")
        && Self.isRealDirectory(session)
        && Self.isResolvedDirectChild(session, of: workingCopyRoot)
    }

    var retained: [WorkingCopyCacheItem] = []
    for session in sessions {
      let children = try fileManager.contentsOfDirectory(
        at: session,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [])
      for child in children {
        let isPartial = Self.hasUUIDSuffix(child.lastPathComponent, suffix: ".partial")
        let isReady = Self.hasUUIDSuffix(child.lastPathComponent, suffix: ".ready")
        guard isPartial || isReady, Self.isRealDirectory(child),
          Self.isResolvedDirectChild(child, of: session)
        else { continue }
        let modified =
          (try? child.resourceValues(
            forKeys: [.contentModificationDateKey]
          ).contentModificationDate) ?? .distantPast

        if isPartial || modified < expiration {
          if (try? removeWorkingCopyContainerIfValid(child)) == true { continue }
        }
        retained.append(
          WorkingCopyCacheItem(
            url: child,
            sessionURL: session,
            modifiedAt: modified,
            byteCount: Self.logicalByteCount(at: child, fileManager: fileManager)))
      }
    }

    retained.sort { $0.modifiedAt < $1.modifiedAt }
    var totalBytes = retained.reduce(Int64(0)) { partial, item in
      let (sum, overflow) = partial.addingReportingOverflow(item.byteCount)
      return overflow ? Int64.max : sum
    }
    for item in retained
    where totalBytes > Self.workingCopyCacheLimit
      && item.sessionURL.standardizedFileURL != workingCopySessionDirectory.standardizedFileURL
    {
      if (try? removeWorkingCopyContainerIfValid(item.url)) == true {
        totalBytes = max(0, totalBytes - item.byteCount)
      }
    }

    let currentSessionBytes =
      retained
      .filter {
        $0.sessionURL.standardizedFileURL == workingCopySessionDirectory.standardizedFileURL
          && Self.pathExistsWithoutFollowingLink($0.url)
      }
      .reduce(Int64(0)) { partial, item in
        let (sum, overflow) = partial.addingReportingOverflow(item.byteCount)
        return overflow ? Int64.max : sum
      }
    let verifiedTotal =
      retained
      .filter { Self.pathExistsWithoutFollowingLink($0.url) }
      .reduce(Int64(0)) { partial, item in
        let (sum, overflow) = partial.addingReportingOverflow(item.byteCount)
        return overflow ? Int64.max : sum
      }
    return WorkingCopyCacheUsage(
      totalBytes: verifiedTotal,
      currentSessionBytes: currentSessionBytes)
  }

  private func ensureWorkingCopyDirectories() throws {
    let cachesDirectory = workingCopyChannelDirectory.deletingLastPathComponent()
    guard Self.isRealDirectory(cachesDirectory) else {
      throw ClipboardHistoryStoreError.payload("系统缓存目录不可用。")
    }
    try Self.ensurePrivateDirectChild(workingCopyChannelDirectory, of: cachesDirectory)
    try Self.ensurePrivateDirectChild(workingCopyRoot, of: workingCopyChannelDirectory)
    try Self.ensurePrivateDirectChild(workingCopySessionDirectory, of: workingCopyRoot)
  }

  @discardableResult
  private func removeWorkingCopyContainerIfValid(_ rawURL: URL) throws -> Bool {
    try ensureWorkingCopyDirectories()
    let url = rawURL.standardizedFileURL
    let session = url.deletingLastPathComponent()
    guard Self.hasUUIDSuffix(session.lastPathComponent, suffix: ".session"),
      Self.hasUUIDSuffix(url.lastPathComponent, suffix: ".ready")
        || Self.hasUUIDSuffix(url.lastPathComponent, suffix: ".partial"),
      Self.isRealDirectory(session),
      Self.isRealDirectory(url),
      Self.isResolvedDirectChild(session, of: workingCopyRoot),
      Self.isResolvedDirectChild(url, of: session)
    else {
      throw ClipboardHistoryStoreError.payload("拒绝清理工作副本边界外的路径。")
    }
    try Self.makeWorkingTreeRemovable(at: url)
    try FileManager.default.removeItem(at: url)
    return !Self.pathExistsWithoutFollowingLink(url)
  }

  private static func ensurePrivateDirectChild(_ child: URL, of parent: URL) throws {
    guard isRealDirectory(parent),
      child.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
    else {
      throw ClipboardHistoryStoreError.payload("工作副本目录边界无效。")
    }
    if !pathExistsWithoutFollowingLink(child) {
      let result = child.path.withCString { mkdir($0, 0o700) }
      guard result == 0 || errno == EEXIST else {
        throw ClipboardHistoryStoreError.payload("无法创建工作副本目录。")
      }
    }
    guard isRealDirectory(child), isResolvedDirectChild(child, of: parent) else {
      throw ClipboardHistoryStoreError.payload("工作副本目录不能是符号链接。")
    }
    let chmodResult = child.path.withCString { chmod($0, 0o700) }
    guard chmodResult == 0 else {
      throw ClipboardHistoryStoreError.payload("无法保护工作副本目录权限。")
    }
  }

  private static func makeWorkingTreeRemovable(at root: URL) throws {
    guard isRealDirectory(root) else {
      throw ClipboardHistoryStoreError.payload("工作副本清理目标无效。")
    }
    _ = root.path.withCString { lchflags($0, 0) }
    try ClipboardHistoryManagedPermissions.clearExtendedACL(at: root)
    _ = root.path.withCString { chmod($0, 0o700) }
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [],
      errorHandler: { _, _ in false })
    while let child = enumerator?.nextObject() as? URL {
      _ = child.path.withCString { lchflags($0, 0) }
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { continue }
      try ClipboardHistoryManagedPermissions.clearExtendedACL(at: child)
      _ = child.path.withCString { chmod($0, values.isDirectory == true ? 0o700 : 0o600) }
    }
  }

  private static func logicalByteCount(at url: URL, fileManager: FileManager) -> Int64 {
    var info = stat()
    guard url.path.withCString({ lstat($0, &info) }) == 0 else { return 0 }
    let type = info.st_mode & S_IFMT
    if type == S_IFLNK { return 0 }
    if type == S_IFREG { return max(0, Int64(info.st_size)) }
    guard type == S_IFDIR,
      let children = try? fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [])
    else { return 0 }
    return children.reduce(Int64(0)) { partial, child in
      let childBytes = logicalByteCount(at: child, fileManager: fileManager)
      let (sum, overflow) = partial.addingReportingOverflow(childBytes)
      return overflow ? Int64.max : sum
    }
  }

  private static func hasUUIDSuffix(_ name: String, suffix: String) -> Bool {
    guard name.hasSuffix(suffix) else { return false }
    let token = String(name.dropLast(suffix.count))
    return token == token.lowercased() && UUID(uuidString: token) != nil
  }

  private static func pathExistsWithoutFollowingLink(_ url: URL) -> Bool {
    var info = stat()
    return url.path.withCString { lstat($0, &info) } == 0
  }

  private static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFDIR
  }

  private static func isResolvedDirectChild(_ child: URL, of parent: URL) -> Bool {
    guard isRealDirectory(parent), isRealDirectory(child) else { return false }
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
    let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
    return resolvedChild.deletingLastPathComponent() == resolvedParent
      && resolvedChild.path.hasPrefix(resolvedParent.path + "/")
  }

  private static func isStrictDescendant(_ descendant: URL, of ancestor: URL) -> Bool {
    descendant.standardizedFileURL.path.hasPrefix(ancestor.standardizedFileURL.path + "/")
  }

  private func containsSensitiveOrTransientType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    let ignored = [
      "org.nspasteboard.TransientType",
      "org.nspasteboard.ConcealedType",
      "org.nspasteboard.AutoGeneratedType",
      "com.agilebits.onepassword",
      "com.typeit4me.clipping",
      "de.petermaurer.TransientPasteboardType",
      "net.antelle.keeweb",
    ]
    return types.contains { type in
      ignored.contains { ignoredType in
        type.rawValue.caseInsensitiveCompare(ignoredType) == .orderedSame
          || type.rawValue.localizedCaseInsensitiveContains(ignoredType)
      }
    }
  }

  private func containsTransientType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    types.contains {
      $0.rawValue.caseInsensitiveCompare("org.nspasteboard.TransientType") == .orderedSame
        || $0.rawValue.caseInsensitiveCompare("de.petermaurer.TransientPasteboardType")
          == .orderedSame
    }
  }

  private var typelessExclusionIsActive: Bool {
    ClipboardHistoryExclusionPolicy.containsTypeless(excludedApplications)
      && !NSRunningApplication.runningApplications(
        withBundleIdentifier: ClipboardHistoryExclusionPolicy.typelessBundleIdentifier
      ).isEmpty
  }

  private static func source(for application: NSRunningApplication?) -> ClipboardHistorySource {
    ClipboardHistorySource(
      bundleIdentifier: application?.bundleIdentifier,
      applicationName: application?.localizedName)
  }

  private func recordSourceCandidate(_ source: ClipboardHistorySource) {
    guard source != sourceCandidatesSinceLastPasteboardChange.last else { return }
    sourceCandidatesSinceLastPasteboardChange.append(source)
    if sourceCandidatesSinceLastPasteboardChange.count > 32 {
      sourceCandidatesSinceLastPasteboardChange.removeFirst(
        sourceCandidatesSinceLastPasteboardChange.count - 32)
    }
  }

  private func resetObservationFingerprint() {
    worker.async { [weak self] in
      self?.workerLastObservedPasteboardFingerprint = nil
    }
  }

  private func persistExcludedApplications() {
    do {
      defaults.set(
        try JSONEncoder().encode(excludedApplications), forKey: DefaultsKey.excludedApplications)
    } catch {
      statusMessage = "排除软件保存失败：\(error.localizedDescription)"
    }
  }

  private static func loadExcludedApplications(
    defaults: UserDefaults
  ) -> [ClipboardHistoryExcludedApplication] {
    guard defaults.object(forKey: DefaultsKey.excludedApplications) != nil else {
      return ClipboardHistoryExclusionPolicy.defaultApplications
    }
    guard let data = defaults.data(forKey: DefaultsKey.excludedApplications),
      let applications = try? JSONDecoder().decode(
        [ClipboardHistoryExcludedApplication].self,
        from: data)
    else { return ClipboardHistoryExclusionPolicy.defaultApplications }
    return ClipboardHistoryExclusionPolicy.normalizedApplications(applications)
  }

  private static func changeCountDelta(from previous: Int, to current: Int) -> Int {
    guard current > previous else { return 1 }
    return current - previous
  }

  private static func saturatedChangeCountSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return overflow ? Int.max : sum
  }

  private static func prepareCaptureForStorage(
    _ pending: PendingClipboardCapture
  ) throws -> ClipboardHistoryCapture {
    switch pending {
    case .ready(let capture):
      try validateCaptureBudget(capture)
      return capture
    case .tiff(let data, let source, let capturedAt):
      try validateImageData(data, expectedType: "public.tiff")
      guard
        let imageSource = CGImageSourceCreateWithData(
          data as CFData,
          [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(
          imageSource,
          0,
          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      else {
        throw ClipboardHistoryStoreError.payload("剪贴板图片无法安全解码。")
      }
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output,
          "public.png" as CFString,
          1,
          nil)
      else {
        throw ClipboardHistoryStoreError.payload("剪贴板图片无法转换为 PNG。")
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw ClipboardHistoryStoreError.payload("剪贴板图片无法转换为 PNG。")
      }
      let png = output as Data
      guard png.count <= maximumCapturedImageBytes else {
        throw ClipboardHistoryStoreError.payload("转换后的剪贴板图片超过单次安全上限。")
      }
      try validateImageData(png, expectedType: "public.png")
      return ClipboardHistoryCapture(
        imagePNGData: png,
        source: source,
        capturedAt: capturedAt)
    }
  }

  private static func validateCaptureBudget(_ capture: ClipboardHistoryCapture) throws {
    guard capture.files.count <= maximumCapturedFileCount else {
      throw ClipboardHistoryStoreError.payload("一次复制的文件数量超过安全上限。")
    }
    if let image = capture.imagePNGData {
      try validateImageData(image, expectedType: "public.png")
    }
    let plainTextBytes = capture.text?.utf8.count ?? 0
    guard plainTextBytes <= maximumCapturedPlainTextBytes else {
      throw ClipboardHistoryStoreError.payload("剪贴板纯文本超过单次安全上限。")
    }
    guard (capture.richData?.count ?? 0) <= maximumCapturedRichTextBytes else {
      throw ClipboardHistoryStoreError.payload("剪贴板富文本超过单次安全上限。")
    }
  }

  private static func validateImageData(_ data: Data, expectedType: String) throws {
    guard !data.isEmpty, data.count <= maximumCapturedImageBytes,
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let actualType = CGImageSourceGetType(source),
      (actualType as String) == expectedType,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0,
      width <= maximumCapturedImageDimension,
      height <= maximumCapturedImageDimension
    else {
      throw ClipboardHistoryStoreError.payload("剪贴板图片格式或尺寸不安全。")
    }
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, pixels <= maximumCapturedImagePixels else {
      throw ClipboardHistoryStoreError.payload("剪贴板图片像素总量超过安全上限。")
    }
  }

  private static func clampedRetentionDays(_ value: Int) -> Int {
    min(3_650, max(1, value))
  }

  private static func clampedMaxBytes(_ value: Int64) -> Int64 {
    min(50_000_000_000, max(100_000_000, value))
  }

  private static func byteText(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}
