import CryptoKit
import Darwin
import Foundation
import SQLite3

enum AIPlayerIPCRequestPolicy {
  static let maximumEncodedRequestBytes = 64 * 1_024
  static let maximumRequestIDBytes = 128
  static let maximumCommandBytes = 64
  static let maximumArgumentKeyBytes = 64
  static let maximumPathBytes = 4_096
  static let maximumNameBytes = 512
  static let maximumIdentifierBytes = 128
  static let maximumGenericStringBytes = 1_024
  static let maximumArgumentCount = 16
  static let maximumArrayCount = 64
  static let maximumNestingDepth = 3
  static let maximumCachedResponses = 32
  static let maximumCachedResponseBytes = 64 * 1_024
  static let maximumPersistentRequests = 100_000
  static let maximumReadDuration: TimeInterval = 3
  static let maximumWriteDuration: TimeInterval = 2
  static let readIdleTimeout: TimeInterval = 1
  static let writeIdleTimeout: TimeInterval = 1

  static func requestLine(in data: Data) throws -> Data.SubSequence {
    guard data.count <= maximumEncodedRequestBytes,
      let newline = data.firstIndex(of: 0x0A)
    else {
      throw AIPlayerError.invalidRequest("请求过大或缺少换行结束符。")
    }
    return data.prefix(upTo: newline)
  }

  static func validate(_ request: [String: Any]) throws -> String? {
    let requestID: String?
    if let rawRequestID = request["request_id"] {
      guard let value = rawRequestID as? String,
        !value.isEmpty,
        value.utf8.count <= maximumRequestIDBytes,
        value.unicodeScalars.allSatisfy({ scalar in
          scalar.isASCII
            && (CharacterSet.alphanumerics.contains(scalar)
              || "-_.:".unicodeScalars.contains(scalar))
        })
      else { throw AIPlayerError.invalidRequest("request_id 无效或过长。") }
      requestID = value
    } else {
      requestID = nil
    }

    guard let command = request["command"] as? String,
      !command.isEmpty,
      command.utf8.count <= maximumCommandBytes
    else { throw AIPlayerError.invalidRequest("command 无效或过长。") }

    if let rawArguments = request["args"] {
      guard let arguments = rawArguments as? [String: Any],
        arguments.count <= maximumArgumentCount
      else { throw AIPlayerError.invalidRequest("args 无效或字段过多。") }
      try validateDictionary(arguments, depth: 1)
    }
    return requestID
  }

  static func shouldCache(response: [String: Any]) -> Bool {
    guard JSONSerialization.isValidJSONObject(response),
      let data = try? JSONSerialization.data(withJSONObject: response)
    else { return false }
    return data.count <= maximumCachedResponseBytes
  }

  static func isMutating(command: String) -> Bool {
    switch command {
    case "play", "pause", "stop", "undo-trash", "resume", "toggle", "seek", "volume",
      "library.create", "library.rename", "library.add", "reveal", "trash":
      return true
    default:
      return false
    }
  }

  static func canonicalDigest(for request: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(request) else {
      throw AIPlayerError.invalidRequest("请求无法规范化。")
    }
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validateDictionary(_ value: [String: Any], depth: Int) throws {
    guard depth <= maximumNestingDepth, value.count <= maximumArgumentCount else {
      throw AIPlayerError.invalidRequest("args 嵌套过深或字段过多。")
    }
    for (key, child) in value {
      guard !key.isEmpty, key.utf8.count <= maximumArgumentKeyBytes else {
        throw AIPlayerError.invalidRequest("args 字段名无效或过长。")
      }
      try validateValue(child, key: key, depth: depth)
    }
  }

  private static func validateValue(_ value: Any, key: String, depth: Int) throws {
    if let string = value as? String {
      let maximumBytes =
        switch key {
        case "path", "paths": maximumPathBytes
        case "name": maximumNameBytes
        case "id": maximumIdentifierBytes
        default: maximumGenericStringBytes
        }
      guard string.utf8.count <= maximumBytes else {
        throw AIPlayerError.invalidRequest("args.\(key) 过长。")
      }
      return
    }
    if value is NSNumber || value is NSNull { return }
    if let array = value as? [Any] {
      guard depth < maximumNestingDepth, array.count <= maximumArrayCount else {
        throw AIPlayerError.invalidRequest("args.\(key) 数量过多或嵌套过深。")
      }
      for child in array { try validateValue(child, key: key, depth: depth + 1) }
      return
    }
    if let dictionary = value as? [String: Any] {
      try validateDictionary(dictionary, depth: depth + 1)
      return
    }
    throw AIPlayerError.invalidRequest("args.\(key) 类型无效。")
  }
}

/// A durable at-most-once fence for commands that can change player, library, Finder,
/// or filesystem state. The `started` row is committed with FULL durability before the
/// handler runs. A crash between the side effect and response commit therefore becomes
/// an explicit indeterminate result on replay; it never silently executes a second time.
private final class AIPlayerIPCDurableRequestLedger: @unchecked Sendable {
  typealias Response = [String: Any]

  enum BeginResult {
    case execute
    case replay(Response)
    case reject(String)
  }

  private struct LedgerError: LocalizedError {
    let detail: String

    var errorDescription: String? {
      "播放器命令幂等账本不可用：\(detail)"
    }
  }

  private let databaseURL: URL
  private var database: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(baseDirectory: URL) throws {
    let directory = baseDirectory.standardizedFileURL
    databaseURL = directory.appendingPathComponent("ipc-idempotency-v1.sqlite3")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path)

    var openedDatabase: OpaquePointer?
    let openResult = sqlite3_open_v2(
      databaseURL.path,
      &openedDatabase,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil)
    guard openResult == SQLITE_OK else {
      let detail =
        openedDatabase.flatMap(sqlite3_errmsg).map(String.init(cString:))
        ?? "SQLite open failed (\(openResult))"
      sqlite3_close(openedDatabase)
      throw LedgerError(detail: detail)
    }
    database = openedDatabase

    do {
      sqlite3_extended_result_codes(database, 1)
      sqlite3_busy_timeout(database, 2_000)
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA foreign_keys=ON")
      try execute(
        """
        CREATE TABLE IF NOT EXISTS ipc_mutating_requests(
          request_id TEXT PRIMARY KEY NOT NULL,
          request_digest TEXT NOT NULL,
          command TEXT NOT NULL,
          phase TEXT NOT NULL CHECK(phase IN ('started', 'completed')),
          response_json BLOB,
          created_at REAL NOT NULL,
          completed_at REAL,
          CHECK(
            (phase = 'started' AND response_json IS NULL AND completed_at IS NULL)
            OR
            (phase = 'completed' AND response_json IS NOT NULL AND completed_at IS NOT NULL)
          )
        ) WITHOUT ROWID
        """)
      try verifyIntegrity()
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: databaseURL.path)
    } catch {
      sqlite3_close(database)
      database = nil
      throw error
    }
  }

  deinit {
    sqlite3_close(database)
  }

  func begin(
    requestID: String,
    requestDigest: String,
    command: String
  ) throws -> BeginResult {
    try execute("BEGIN IMMEDIATE")
    var committed = false
    defer {
      if !committed { try? execute("ROLLBACK") }
    }

    var storedDigest: String?
    var storedPhase: String?
    var storedResponse: Data?
    try withStatement(
      """
      SELECT request_digest, phase, response_json
      FROM ipc_mutating_requests WHERE request_id=? LIMIT 1
      """
    ) { statement in
      bind(requestID, at: 1, in: statement)
      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_ROW {
        storedDigest = text(statement, column: 0)
        storedPhase = text(statement, column: 1)
        if sqlite3_column_type(statement, 2) != SQLITE_NULL {
          storedResponse = data(statement, column: 2)
        }
      } else if stepResult != SQLITE_DONE {
        throw sqliteError("读取幂等记录失败")
      }
    }

    if let storedDigest, let storedPhase {
      let result: BeginResult
      if storedDigest != requestDigest {
        result = .reject("request_id 已绑定另一份命令内容；本次请求已拒绝。")
      } else if storedPhase == "completed", let storedResponse {
        guard
          let object = try? JSONSerialization.jsonObject(with: storedResponse),
          let response = object as? Response
        else {
          result = .reject("该 request_id 的既有结果损坏；为避免重复执行，本次请求已拒绝。")
          try execute("COMMIT")
          committed = true
          return result
        }
        result = .replay(response)
      } else {
        result = .reject(
          "该 request_id 曾开始执行但未留下最终结果；为避免重复副作用，本次不会重跑。")
      }
      try execute("COMMIT")
      committed = true
      return result
    }

    let count = try requestCount()
    guard count < AIPlayerIPCRequestPolicy.maximumPersistentRequests else {
      try execute("COMMIT")
      committed = true
      return .reject("播放器命令幂等账本已满；为避免无法追踪的重复操作，本次请求未执行。")
    }

    try withStatement(
      """
      INSERT INTO ipc_mutating_requests(
        request_id, request_digest, command, phase, response_json, created_at, completed_at
      ) VALUES(?, ?, ?, 'started', NULL, ?, NULL)
      """
    ) { statement in
      bind(requestID, at: 1, in: statement)
      bind(requestDigest, at: 2, in: statement)
      bind(command, at: 3, in: statement)
      sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
      try stepDone(statement, context: "登记幂等请求失败")
    }
    try execute("COMMIT")
    committed = true
    return .execute
  }

  func complete(
    requestID: String,
    requestDigest: String,
    response: Response
  ) throws {
    guard AIPlayerIPCRequestPolicy.shouldCache(response: response) else {
      throw LedgerError(detail: "最终响应超过持久化上限")
    }
    let responseData = try JSONSerialization.data(
      withJSONObject: response,
      options: [.sortedKeys])

    try execute("BEGIN IMMEDIATE")
    var committed = false
    defer {
      if !committed { try? execute("ROLLBACK") }
    }
    try withStatement(
      """
      UPDATE ipc_mutating_requests
      SET phase='completed', response_json=?, completed_at=?
      WHERE request_id=? AND request_digest=? AND phase='started'
      """
    ) { statement in
      bind(responseData, at: 1, in: statement)
      sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
      bind(requestID, at: 3, in: statement)
      bind(requestDigest, at: 4, in: statement)
      try stepDone(statement, context: "提交幂等结果失败")
    }
    guard sqlite3_changes(database) == 1 else {
      throw LedgerError(detail: "幂等请求所有权已丢失")
    }
    try execute("COMMIT")
    committed = true
  }

  private func requestCount() throws -> Int {
    var count = 0
    try withStatement("SELECT COUNT(*) FROM ipc_mutating_requests") { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw sqliteError("统计幂等记录失败")
      }
      count = Int(sqlite3_column_int64(statement, 0))
    }
    return count
  }

  private func verifyIntegrity() throws {
    try withStatement("PRAGMA quick_check") { statement in
      guard sqlite3_step(statement) == SQLITE_ROW,
        text(statement, column: 0) == "ok",
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw LedgerError(detail: "数据库完整性检查失败")
      }
    }
  }

  private func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    defer { sqlite3_free(errorMessage) }
    guard result == SQLITE_OK else {
      let detail = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
      throw LedgerError(detail: detail)
    }
  }

  private func withStatement<T>(
    _ sql: String,
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw sqliteError("准备幂等账本语句失败") }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }

  private func stepDone(_ statement: OpaquePointer, context: String) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(context) }
  }

  private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, value, -1, transient)
  }

  private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer) {
    value.withUnsafeBytes { bytes in
      _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
    }
  }

  private func text(_ statement: OpaquePointer, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: value)
  }

  private func data(_ statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  private func sqliteError(_ context: String) -> LedgerError {
    let detail = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "未知错误"
    return LedgerError(detail: "\(context)：\(detail)")
  }
}

/// Owns the hand-off from the IPC worker to AppKit's main queue.
///
/// A pending ticket receives one ownership transition: either the main queue claims it before
/// the monotonic deadline, or the waiting IPC worker cancels it at the deadline. Both transitions
/// happen under the same lock, so an operation runs at most once and a closure that wakes up late
/// cannot enter its body. A newer pending request with the same request ID also replaces the old
/// owner before either body can run.
final class AIPlayerIPCMainQueueExecutor: @unchecked Sendable {
  typealias Response = [String: Any]

  static let productionTimeout: TimeInterval = 8

  private enum CancellationReason {
    case timedOut
    case replaced
    case duplicateInFlight
  }

  private enum Phase {
    case pending
    case executing
    case completed(Response)
    case cancelled(CancellationReason)
  }

  private struct Record {
    let requestKey: String
    let deadline: DispatchTime
    let signal: DispatchSemaphore
    var phase: Phase
  }

  private struct Ticket: Sendable {
    let owner: UUID
    let requestKey: String
    let deadline: DispatchTime
    let signal: DispatchSemaphore
  }

  private final class MainOperation: @unchecked Sendable {
    let body: @MainActor () -> Response

    init(_ body: @escaping @MainActor () -> Response) {
      self.body = body
    }
  }

  private enum DeadlineResolution {
    case cancelled(CancellationReason)
    case executing
    case completed(Response)
  }

  private let timeout: TimeInterval
  private let lock = NSLock()
  private var records: [UUID: Record] = [:]
  private var ownerByRequestKey: [String: UUID] = [:]

  init(timeout: TimeInterval = AIPlayerIPCMainQueueExecutor.productionTimeout) {
    self.timeout = min(Self.productionTimeout, max(0.001, timeout))
  }

  func execute(
    requestID: String?,
    operation: @escaping @MainActor () -> Response
  ) -> Response {
    let ticket = begin(requestID: requestID)
    let boxedOperation = MainOperation(operation)
    DispatchQueue.main.async { [self, ticket, boxedOperation] in
      guard claim(ticket) else { return }
      MainActor.assumeIsolated {
        complete(ticket, response: boxedOperation.body())
      }
    }

    if ticket.signal.wait(timeout: ticket.deadline) == .success {
      return finish(ticket)
    }

    switch resolveDeadline(ticket) {
    case .cancelled(let reason):
      return finish(ticket, knownCancellation: reason)
    case .completed(let response):
      cleanup(ticket)
      return response
    case .executing:
      // Once admitted, the operation may already have changed player state. Waiting
      // for its definitive response is safer than returning a false timeout followed
      // by a late side effect.
      ticket.signal.wait()
      return finish(ticket)
    }
  }

  private func begin(requestID: String?) -> Ticket {
    let owner = UUID()
    let requestKey = requestID.map { "request-id:\($0)" } ?? "anonymous:\(owner.uuidString)"
    let deadline = DispatchTime.now() + timeout
    let signal = DispatchSemaphore(value: 0)
    let ticket = Ticket(
      owner: owner,
      requestKey: requestKey,
      deadline: deadline,
      signal: signal)
    var signalReplaced: DispatchSemaphore?

    lock.lock()
    if let previousOwner = ownerByRequestKey[requestKey],
      var previous = records[previousOwner]
    {
      switch previous.phase {
      case .pending:
        previous.phase = .cancelled(.replaced)
        records[previousOwner] = previous
        signalReplaced = previous.signal
      case .executing:
        records[owner] = Record(
          requestKey: requestKey,
          deadline: deadline,
          signal: signal,
          phase: .cancelled(.duplicateInFlight))
        lock.unlock()
        signal.signal()
        return ticket
      case .completed, .cancelled:
        break
      }
    }
    records[owner] = Record(
      requestKey: requestKey,
      deadline: deadline,
      signal: signal,
      phase: .pending)
    ownerByRequestKey[requestKey] = owner
    lock.unlock()
    signalReplaced?.signal()
    return ticket
  }

  /// Lock-backed compare-and-swap: only the current pending owner can become executing.
  private func claim(_ ticket: Ticket) -> Bool {
    var shouldSignal = false
    lock.lock()
    guard var record = records[ticket.owner],
      ownerByRequestKey[ticket.requestKey] == ticket.owner,
      case .pending = record.phase
    else {
      lock.unlock()
      return false
    }
    if DispatchTime.now() >= record.deadline {
      record.phase = .cancelled(.timedOut)
      records[ticket.owner] = record
      ownerByRequestKey.removeValue(forKey: ticket.requestKey)
      shouldSignal = true
    } else {
      record.phase = .executing
      records[ticket.owner] = record
    }
    lock.unlock()
    if shouldSignal { ticket.signal.signal() }
    return !shouldSignal
  }

  private func complete(_ ticket: Ticket, response: Response) {
    lock.lock()
    guard var record = records[ticket.owner], case .executing = record.phase else {
      lock.unlock()
      return
    }
    record.phase = .completed(response)
    records[ticket.owner] = record
    if ownerByRequestKey[ticket.requestKey] == ticket.owner {
      ownerByRequestKey.removeValue(forKey: ticket.requestKey)
    }
    lock.unlock()
    ticket.signal.signal()
  }

  /// Competes with `claim` under one lock. Exactly one transition can win.
  private func resolveDeadline(_ ticket: Ticket) -> DeadlineResolution {
    lock.lock()
    guard var record = records[ticket.owner] else {
      lock.unlock()
      return .cancelled(.timedOut)
    }
    let resolution: DeadlineResolution
    switch record.phase {
    case .pending:
      record.phase = .cancelled(.timedOut)
      records[ticket.owner] = record
      if ownerByRequestKey[ticket.requestKey] == ticket.owner {
        ownerByRequestKey.removeValue(forKey: ticket.requestKey)
      }
      resolution = .cancelled(.timedOut)
    case .executing:
      resolution = .executing
    case .completed(let response):
      resolution = .completed(response)
    case .cancelled(let reason):
      resolution = .cancelled(reason)
    }
    lock.unlock()
    return resolution
  }

  private func finish(
    _ ticket: Ticket,
    knownCancellation: CancellationReason? = nil
  ) -> Response {
    lock.lock()
    let phase = records[ticket.owner]?.phase
    records.removeValue(forKey: ticket.owner)
    if ownerByRequestKey[ticket.requestKey] == ticket.owner {
      ownerByRequestKey.removeValue(forKey: ticket.requestKey)
    }
    lock.unlock()

    switch phase {
    case .completed(let response):
      return response
    case .cancelled(let reason):
      return cancellationResponse(requestKey: ticket.requestKey, reason: reason)
    default:
      return cancellationResponse(
        requestKey: ticket.requestKey,
        reason: knownCancellation ?? .timedOut)
    }
  }

  private func cleanup(_ ticket: Ticket) {
    lock.lock()
    records.removeValue(forKey: ticket.owner)
    if ownerByRequestKey[ticket.requestKey] == ticket.owner {
      ownerByRequestKey.removeValue(forKey: ticket.requestKey)
    }
    lock.unlock()
  }

  private func cancellationResponse(
    requestKey: String,
    reason: CancellationReason
  ) -> Response {
    let requestID =
      requestKey.hasPrefix("request-id:")
      ? String(requestKey.dropFirst("request-id:".count))
      : nil
    let message =
      switch reason {
      case .timedOut: "播放器命令超时。"
      case .replaced: "播放器命令已被后续同编号请求替换。"
      case .duplicateInFlight: "同编号播放器命令仍在执行。"
      }
    return AIPlayerIPCServer.failureResponse(requestID: requestID, message: message)
  }
}

final class AIPlayerIPCServer: @unchecked Sendable {
  typealias Handler = ([String: Any]) -> [String: Any]

  private struct CachedResponse {
    let requestDigest: String
    let response: [String: Any]
  }

  private let baseDirectory: URL
  private let socketURL: URL
  private let queue = DispatchQueue(label: "cn.tlww.aixlg.player.ipc", qos: .userInitiated)
  private let stateLock = NSLock()
  private var descriptor: Int32 = -1
  private var isRunning = false
  private var handler: Handler?
  private var durableLedger: AIPlayerIPCDurableRequestLedger?
  private var responseCache: [String: CachedResponse] = [:]
  private var responseOrder: [String] = []

  init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory.standardizedFileURL
    socketURL = self.baseDirectory.appendingPathComponent("player.sock")
  }

  func start(handler: @escaping Handler) throws {
    stateLock.lock()
    guard !isRunning else {
      stateLock.unlock()
      return
    }
    if durableLedger == nil {
      do {
        durableLedger = try AIPlayerIPCDurableRequestLedger(baseDirectory: baseDirectory)
      } catch {
        stateLock.unlock()
        throw error
      }
    }
    self.handler = handler
    try? FileManager.default.removeItem(at: socketURL)
    let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else {
      self.handler = nil
      stateLock.unlock()
      throw AIPlayerError.operationFailed("播放器本机服务无法创建。")
    }
    let bindResult =
      AIPlayerUnixSocket.withAddress(path: socketURL.path) { address, length in
        Darwin.bind(server, address, length)
      } ?? -1
    guard bindResult == 0, Darwin.listen(server, 8) == 0 else {
      Darwin.close(server)
      self.handler = nil
      stateLock.unlock()
      throw AIPlayerError.operationFailed("播放器本机服务无法监听。")
    }
    chmod(socketURL.path, S_IRUSR | S_IWUSR)
    descriptor = server
    isRunning = true
    stateLock.unlock()
    queue.async { [weak self] in self?.acceptLoop(server: server) }
  }

  func stop() {
    stateLock.lock()
    isRunning = false
    let server = descriptor
    descriptor = -1
    handler = nil
    stateLock.unlock()
    if server >= 0 {
      Darwin.shutdown(server, SHUT_RDWR)
      Darwin.close(server)
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  private func acceptLoop(server: Int32) {
    while running {
      let client = Darwin.accept(server, nil, nil)
      guard client >= 0 else {
        if !running { break }
        continue
      }
      handle(client: client)
      Darwin.close(client)
    }
  }

  private var running: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isRunning
  }

  private func handle(client: Int32) {
    var noSigPipe: Int32 = 1
    guard
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
        socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0
    else { return }
    var requestData = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    let readDeadline =
      ProcessInfo.processInfo.systemUptime
      + AIPlayerIPCRequestPolicy.maximumReadDuration
    while requestData.count < AIPlayerIPCRequestPolicy.maximumEncodedRequestBytes {
      let remainingDuration = readDeadline - ProcessInfo.processInfo.systemUptime
      guard remainingDuration > 0 else { break }
      guard
        setSocketTimeout(
          client,
          option: SO_RCVTIMEO,
          seconds: min(AIPlayerIPCRequestPolicy.readIdleTimeout, remainingDuration))
      else { return }
      let remaining = AIPlayerIPCRequestPolicy.maximumEncodedRequestBytes - requestData.count
      let count = Darwin.read(client, &buffer, min(buffer.count, remaining))
      guard count > 0 else { break }
      requestData.append(contentsOf: buffer.prefix(count))
      if requestData.contains(0x0A) { break }
    }
    let response: [String: Any]
    do {
      let line = try AIPlayerIPCRequestPolicy.requestLine(in: requestData)
      guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw AIPlayerError.invalidRequest("请求 JSON 无效。")
      }
      let requestID = try AIPlayerIPCRequestPolicy.validate(request)
      response = buildResponse(for: request, requestID: requestID)
    } catch {
      response = Self.failureResponse(requestID: nil, message: error.localizedDescription)
    }
    guard var payload = try? JSONSerialization.data(withJSONObject: response) else { return }
    payload.append(0x0A)
    let writeDeadline =
      ProcessInfo.processInfo.systemUptime
      + AIPlayerIPCRequestPolicy.maximumWriteDuration
    payload.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var sent = 0
      while sent < bytes.count {
        let remainingDuration = writeDeadline - ProcessInfo.processInfo.systemUptime
        guard remainingDuration > 0 else { return }
        guard
          setSocketTimeout(
            client,
            option: SO_SNDTIMEO,
            seconds: min(AIPlayerIPCRequestPolicy.writeIdleTimeout, remainingDuration))
        else { return }
        let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
        guard count > 0 else { return }
        sent += count
      }
    }
  }

  private func setSocketTimeout(
    _ descriptor: Int32,
    option: Int32,
    seconds: TimeInterval
  ) -> Bool {
    let bounded = max(0.001, seconds)
    let wholeSeconds = Int(bounded.rounded(.down))
    var timeout = timeval(
      tv_sec: wholeSeconds,
      tv_usec: Int32((bounded - Double(wholeSeconds)) * 1_000_000))
    return setsockopt(
      descriptor, SOL_SOCKET, option, &timeout,
      socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
  }

  private func buildResponse(
    for request: [String: Any],
    requestID: String?
  ) -> [String: Any] {
    guard (request["protocol"] as? Int) == 1 else {
      return Self.failureResponse(requestID: requestID, message: "不支持的协议版本。")
    }
    guard let command = request["command"] as? String else {
      return Self.failureResponse(requestID: requestID, message: "command 无效或过长。")
    }
    let requestDigest: String
    do {
      requestDigest = try AIPlayerIPCRequestPolicy.canonicalDigest(for: request)
    } catch {
      return Self.failureResponse(requestID: requestID, message: error.localizedDescription)
    }
    guard let handler else {
      return Self.failureResponse(requestID: requestID, message: "播放器服务尚未就绪。")
    }

    if AIPlayerIPCRequestPolicy.isMutating(command: command) {
      guard let requestID else {
        return Self.failureResponse(
          requestID: nil,
          message: "会改变播放器或文件状态的命令必须提供 request_id。")
      }
      guard let durableLedger else {
        return Self.failureResponse(requestID: requestID, message: "播放器命令幂等账本不可用。")
      }
      do {
        switch try durableLedger.begin(
          requestID: requestID,
          requestDigest: requestDigest,
          command: command)
        {
        case .replay(let response):
          return response
        case .reject(let message):
          return Self.failureResponse(requestID: requestID, message: message)
        case .execute:
          break
        }
      } catch {
        return Self.failureResponse(requestID: requestID, message: error.localizedDescription)
      }

      let result = handler(request)
      do {
        try durableLedger.complete(
          requestID: requestID,
          requestDigest: requestDigest,
          response: result)
        return result
      } catch {
        return Self.failureResponse(
          requestID: requestID,
          message: "命令可能已经执行，但最终结果未能持久化；请保留此 request_id，切勿换号重试。")
      }
    }

    if let requestID, let cached = responseCache[requestID] {
      guard cached.requestDigest == requestDigest else {
        return Self.failureResponse(
          requestID: requestID,
          message: "request_id 已绑定另一份命令内容；本次请求已拒绝。")
      }
      return cached.response
    }
    let result = handler(request)
    if let requestID, AIPlayerIPCRequestPolicy.shouldCache(response: result) {
      responseCache[requestID] = CachedResponse(
        requestDigest: requestDigest,
        response: result)
      responseOrder.append(requestID)
      if responseOrder.count > AIPlayerIPCRequestPolicy.maximumCachedResponses {
        responseCache.removeValue(forKey: responseOrder.removeFirst())
      }
    }
    return result
  }

  static func failureResponse(requestID: String?, message: String) -> [String: Any] {
    [
      "ok": false,
      "protocol": 1,
      "request_id": requestID ?? NSNull(),
      "error": message,
      "state": [
        "playback": "unknown",
        "path": NSNull(),
        "position_seconds": 0,
        "duration_seconds": 0,
      ],
    ]
  }
}
