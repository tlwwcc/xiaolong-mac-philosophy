import AppKit
import Combine
import Darwin
import Foundation
import os.log

struct BoundedProcessResult {
  let terminationStatus: Int32?
  let standardOutput: String
  let standardError: String
  let outputWasTruncated: Bool
  let errorWasTruncated: Bool
  let timedOut: Bool
  let cancelled: Bool
  let launchError: String?

  var succeeded: Bool {
    launchError == nil && !timedOut && !cancelled && terminationStatus == 0
  }
}

private final class BoundedProcessOutputBuffer: @unchecked Sendable {
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
    if remaining > 0 {
      data.append(incoming.prefix(remaining))
    }
    if incoming.count > remaining { truncated = true }
    lock.unlock()
  }

  func value() -> (String, Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (String(decoding: data, as: UTF8.self), truncated)
  }
}

private final class BoundedProcessResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedResult: BoundedProcessResult?

  func store(_ result: BoundedProcessResult) {
    lock.lock()
    storedResult = result
    lock.unlock()
  }

  func value() -> BoundedProcessResult? {
    lock.lock()
    defer { lock.unlock() }
    return storedResult
  }
}

private enum BoundedProcessTerminationTarget: Equatable, Sendable {
  case processGroup(pid_t)
  case process(pid_t)

  var signalIdentifier: pid_t {
    switch self {
    case .processGroup(let processGroupID):
      return -processGroupID
    case .process(let processID):
      return processID
    }
  }
}

private enum BoundedProcessOutputStream {
  case standardOutput
  case standardError
}

/// Runs a child process without letting either output pipe fill up. Completion is delivered once,
/// and timeout/cancellation always closes this process's pipe ownership even if a descendant keeps
/// an inherited descriptor open.
final class BoundedProcessExecution: @unchecked Sendable {
  private let process: Process
  private let outputPipe = Pipe()
  private let errorPipe = Pipe()
  private let outputBuffer: BoundedProcessOutputBuffer
  private let errorBuffer: BoundedProcessOutputBuffer
  private let timeout: TimeInterval
  private let completionQueue: DispatchQueue
  private let completion: (BoundedProcessResult) -> Void
  private let stateLock = NSLock()
  private var started = false
  private var finished = false
  private var timedOut = false
  private var cancelled = false
  private var launchError: String?
  private var timeoutWorkItem: DispatchWorkItem?
  private var finishFallbackWorkItem: DispatchWorkItem?
  private var selfRetainer: BoundedProcessExecution?
  private var launchCompleted = false
  private var launchedProcessID: pid_t?
  private var isolatedProcessGroupID: pid_t?
  private var rootProcessTerminated = false
  private var standardOutputReachedEOF = false
  private var standardErrorReachedEOF = false
  private var terminationTarget: BoundedProcessTerminationTarget?
  private var stopRequested = false

  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    timeout: TimeInterval,
    outputByteLimit: Int = 131_072,
    completionQueue: DispatchQueue = .main,
    completion: @escaping (BoundedProcessResult) -> Void
  ) {
    process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    outputBuffer = BoundedProcessOutputBuffer(byteLimit: outputByteLimit)
    errorBuffer = BoundedProcessOutputBuffer(byteLimit: outputByteLimit)
    self.timeout = timeout
    self.completionQueue = completionQueue
    self.completion = completion

    process.standardOutput = outputPipe
    process.standardError = errorPipe
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consumeAvailableData(from: handle, stream: .standardOutput)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consumeAvailableData(from: handle, stream: .standardError)
    }
    process.terminationHandler = { [weak self] terminatedProcess in
      self?.rootProcessDidTerminate(processID: terminatedProcess.processIdentifier)
    }
  }

  @discardableResult
  func start() -> BoundedProcessExecution {
    stateLock.lock()
    guard !started, !finished, !cancelled, !timedOut else {
      stateLock.unlock()
      return self
    }
    started = true
    selfRetainer = self
    stateLock.unlock()
    do {
      try process.run()
      let processID = process.processIdentifier
      let processGroupID = Self.confirmedIsolatedProcessGroupID(for: processID)
      stateLock.lock()
      launchCompleted = true
      if processID > 0 {
        launchedProcessID = processID
      }
      if let processGroupID {
        isolatedProcessGroupID = processGroupID
      }
      let shouldTerminate = stopRequested || rootProcessTerminated
      stateLock.unlock()
      if shouldTerminate {
        beginTerminationSequenceIfNeeded()
        scheduleFinishFallbackIfNeeded()
      }
      scheduleTimeoutIfNeeded()
      finishIfReady()
    } catch {
      stateLock.lock()
      launchCompleted = true
      launchError = error.localizedDescription
      stateLock.unlock()
      finish()
    }
    return self
  }

  private func scheduleTimeoutIfNeeded() {
    guard timeout > 0 else { return }
    let item = DispatchWorkItem { [weak self] in
      self?.stop(timedOut: true, cancelled: false)
    }
    stateLock.lock()
    guard !finished, !rootProcessTerminated, !stopRequested else {
      stateLock.unlock()
      return
    }
    timeoutWorkItem = item
    stateLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: item)
  }

  /// Synchronous bridge for callers that already run on a worker queue. Output is still drained
  /// concurrently, and the extra completion grace prevents an unbounded wait if Process fails to
  /// deliver its termination callback.
  static func runSynchronously(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    timeout: TimeInterval,
    outputByteLimit: Int = 131_072
  ) -> BoundedProcessResult {
    let resultBox = BoundedProcessResultBox()
    let completed = DispatchSemaphore(value: 0)
    let execution = BoundedProcessExecution(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: currentDirectoryURL,
      timeout: timeout,
      outputByteLimit: outputByteLimit,
      completionQueue: .global(qos: .utility)
    ) { result in
      resultBox.store(result)
      completed.signal()
    }.start()

    let completionBudget = max(0.05, timeout) + 1.5
    if completed.wait(timeout: .now() + completionBudget) != .success {
      execution.cancel()
      _ = completed.wait(timeout: .now() + 1.5)
    }
    if let result = resultBox.value() { return result }
    return BoundedProcessResult(
      terminationStatus: nil,
      standardOutput: "",
      standardError: "",
      outputWasTruncated: false,
      errorWasTruncated: false,
      timedOut: true,
      cancelled: true,
      launchError: "Process completion was not delivered within its bounded deadline.")
  }

  func cancel() {
    stop(timedOut: false, cancelled: true)
  }

  private func stop(timedOut: Bool, cancelled: Bool) {
    stateLock.lock()
    guard !finished else {
      stateLock.unlock()
      return
    }
    self.timedOut = self.timedOut || timedOut
    self.cancelled = self.cancelled || cancelled
    stopRequested = true
    stateLock.unlock()

    beginTerminationSequenceIfNeeded()
    scheduleFinishFallbackIfNeeded()
  }

  private func consumeAvailableData(
    from handle: FileHandle,
    stream: BoundedProcessOutputStream
  ) {
    let availableData = handle.availableData
    guard availableData.isEmpty else {
      switch stream {
      case .standardOutput:
        outputBuffer.append(availableData)
      case .standardError:
        errorBuffer.append(availableData)
      }
      return
    }

    handle.readabilityHandler = nil
    stateLock.lock()
    switch stream {
    case .standardOutput:
      standardOutputReachedEOF = true
    case .standardError:
      standardErrorReachedEOF = true
    }
    stateLock.unlock()
    finishIfReady()
  }

  private func rootProcessDidTerminate(processID: pid_t) {
    let processGroupID = Self.confirmedIsolatedProcessGroupID(for: processID)
    stateLock.lock()
    guard !finished else {
      stateLock.unlock()
      return
    }
    launchCompleted = true
    if processID > 0 {
      launchedProcessID = processID
    }
    if isolatedProcessGroupID == nil, let processGroupID {
      isolatedProcessGroupID = processGroupID
    }
    rootProcessTerminated = true
    stateLock.unlock()

    // A shell can exit successfully while a background descendant continues. Contain any
    // surviving member of the exact launch group before reporting the root's result.
    beginTerminationSequenceIfNeeded()
    scheduleFinishFallbackIfNeeded()
    finishIfReady()
  }

  private static func confirmedIsolatedProcessGroupID(for processID: pid_t) -> pid_t? {
    guard processID > 0 else { return nil }
    errno = 0
    let processGroupID = getpgid(processID)
    if processGroupID == processID {
      return processID
    }
    // Process exposes its PID only after run(). If the root exits before getpgid(), ESRCH cannot
    // distinguish "nothing remains" from "its descendants still own the launch group". A signal
    // 0 probe of the negative PID safely confirms that the exact group still exists without
    // delivering a signal. Never infer ownership when a live root reports a different group.
    guard processGroupID == -1, errno == ESRCH else { return nil }
    errno = 0
    let groupProbe = kill(-processID, 0)
    return groupProbe == 0 || errno == EPERM ? processID : nil
  }

  private func beginTerminationSequenceIfNeeded() {
    stateLock.lock()
    guard !finished, terminationTarget == nil, stopRequested || rootProcessTerminated else {
      stateLock.unlock()
      return
    }
    let target: BoundedProcessTerminationTarget?
    if let processGroupID = isolatedProcessGroupID {
      target = .processGroup(processGroupID)
    } else if stopRequested, !rootProcessTerminated, let processID = launchedProcessID {
      target = .process(processID)
    } else {
      target = nil
    }
    guard let target else {
      stateLock.unlock()
      return
    }
    terminationTarget = target
    stateLock.unlock()

    errno = 0
    let termResult = kill(target.signalIdentifier, SIGTERM)
    let targetStillExists = termResult == 0 || errno == EPERM
    guard targetStillExists else { return }

    // SIGKILL escalation deliberately outlives this object: a descendant may close both pipes,
    // allowing result delivery, while continuing to ignore SIGTERM in the isolated group.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
      _ = kill(target.signalIdentifier, SIGKILL)
    }
  }

  private func scheduleFinishFallbackIfNeeded(delay: TimeInterval = 0.75) {
    let item = DispatchWorkItem { [weak self] in
      self?.finishAfterGracePeriod()
    }
    stateLock.lock()
    guard !finished, finishFallbackWorkItem == nil else {
      stateLock.unlock()
      return
    }
    finishFallbackWorkItem = item
    stateLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func finishAfterGracePeriod() {
    stateLock.lock()
    finishFallbackWorkItem = nil
    let launchIsStillInFlight = started && !launchCompleted
    stateLock.unlock()
    if launchIsStillInFlight {
      scheduleFinishFallbackIfNeeded(delay: 0.25)
    } else {
      finish()
    }
  }

  private func finishIfReady() {
    stateLock.lock()
    let ready =
      launchCompleted && rootProcessTerminated && standardOutputReachedEOF
      && standardErrorReachedEOF
    stateLock.unlock()
    if ready { finish() }
  }

  private func finish() {
    stateLock.lock()
    guard !finished else {
      stateLock.unlock()
      return
    }
    finished = true
    timeoutWorkItem?.cancel()
    finishFallbackWorkItem?.cancel()
    let didTimeOut = timedOut
    let wasCancelled = cancelled
    let startError = launchError
    let terminationStatus =
      startError == nil && rootProcessTerminated ? process.terminationStatus : nil
    stateLock.unlock()

    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    try? outputPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForReading.close()
    let (standardOutput, outputWasTruncated) = outputBuffer.value()
    let (standardError, errorWasTruncated) = errorBuffer.value()
    let result = BoundedProcessResult(
      terminationStatus: terminationStatus,
      standardOutput: standardOutput,
      standardError: standardError,
      outputWasTruncated: outputWasTruncated,
      errorWasTruncated: errorWasTruncated,
      timedOut: didTimeOut,
      cancelled: wasCancelled,
      launchError: startError)
    completionQueue.async(execute: DispatchWorkItem { [completion] in completion(result) })
    stateLock.lock()
    selfRetainer = nil
    stateLock.unlock()
  }
}

struct LauncherOpenLearningCoordinator {
  private(set) var generation: UInt64 = 0

  mutating func beginOpen() -> UInt64 {
    generation &+= 1
    return generation
  }

  func shouldRecord(token: UInt64, succeeded: Bool) -> Bool {
    succeeded && token == generation
  }
}

struct WindowScreenGeometry: Equatable {
  let frame: CGRect
  let visibleFrame: CGRect
}

enum AXWindowGeometry {
  static func convertAppKitRectToAX(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX,
      y: primaryTop - rect.maxY,
      width: rect.width,
      height: rect.height)
  }

  static func visibleAXFrame(
    for screen: WindowScreenGeometry,
    primaryTop: CGFloat
  ) -> CGRect {
    convertAppKitRectToAX(screen.visibleFrame, primaryTop: primaryTop)
  }

  static func screenIndex(
    containingAXFrame windowFrame: CGRect,
    screens: [WindowScreenGeometry],
    primaryTop: CGFloat
  ) -> Int? {
    guard !screens.isEmpty else { return nil }
    let converted = screens.map { convertAppKitRectToAX($0.frame, primaryTop: primaryTop) }
    let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    if let exact = converted.firstIndex(where: { $0.contains(center) }) { return exact }

    let areas = converted.map { $0.intersection(windowFrame) }.map {
      $0.isNull ? CGFloat.zero : max(0, $0.width) * max(0, $0.height)
    }
    if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
      return best
    }
    return converted.indices.min {
      squaredDistance(from: center, to: converted[$0])
        < squaredDistance(from: center, to: converted[$1])
    }
  }

  static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
    let width = min(max(1, frame.width), visibleFrame.width)
    let height = min(max(1, frame.height), visibleFrame.height)
    return CGRect(
      x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
      width: width,
      height: height)
  }

  private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let closestX = min(max(point.x, rect.minX), rect.maxX)
    let closestY = min(max(point.y, rect.minY), rect.maxY)
    let dx = point.x - closestX
    let dy = point.y - closestY
    return dx * dx + dy * dy
  }
}

struct LauncherApp: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let path: String
  let normalizedName: String
  let searchTokens: String
  let initials: String
  let useCount: Int
  let lastUsedDate: Date?
  let metadataModifiedAt: TimeInterval?

  init(
    id: String,
    name: String,
    bundleIdentifier: String,
    path: String,
    normalizedName: String,
    searchTokens: String,
    initials: String,
    useCount: Int,
    lastUsedDate: Date?,
    metadataModifiedAt: TimeInterval? = nil
  ) {
    self.id = id
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.path = path
    self.normalizedName = normalizedName
    self.searchTokens = searchTokens
    self.initials = initials
    self.useCount = useCount
    self.lastUsedDate = lastUsedDate
    self.metadataModifiedAt = metadataModifiedAt
  }

  var url: URL {
    URL(fileURLWithPath: path)
  }

  var cacheKey: String {
    let bundleKey = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(bundleKey)|\(url.standardizedFileURL.path.lowercased())"
  }
}

enum LauncherDisplayMode: String, CaseIterable, Identifiable {
  case list
  case icons

  var id: String { rawValue }

  var title: String {
    switch self {
    case .list: return "列表"
    case .icons: return "图标"
    }
  }
}

enum LauncherPerformance {
  struct OpenToken {
    fileprivate let signpostID: OSSignpostID
  }

  struct ScanToken {
    fileprivate let signpostID: OSSignpostID
  }

  private static let log = OSLog(
    subsystem: AppRuntimeIdentity.current.bundleIdentifier,
    category: "LauncherPerformance")

  static func beginOpen(isWarm: Bool, cachedCount: Int) -> OpenToken {
    let signpostID = OSSignpostID(log: log)
    os_signpost(
      .begin,
      log: log,
      name: "Launcher Open",
      signpostID: signpostID,
      "kind=%{public}@ cached=%d",
      isWarm ? "warm" : "cold",
      cachedCount)
    return OpenToken(signpostID: signpostID)
  }

  static func markInteractive(_ token: OpenToken) {
    os_signpost(
      .event,
      log: log,
      name: "Launcher Interactive",
      signpostID: token.signpostID)
  }

  static func endOpen(_ token: OpenToken, resultCount: Int, source: String) {
    os_signpost(
      .end,
      log: log,
      name: "Launcher Open",
      signpostID: token.signpostID,
      "results=%d source=%{public}@",
      resultCount,
      source)
  }

  static func beginScan(cachedCount: Int, forced: Bool) -> ScanToken {
    let signpostID = OSSignpostID(log: log)
    os_signpost(
      .begin,
      log: log,
      name: "Launcher Index Refresh",
      signpostID: signpostID,
      "cached=%d forced=%{public}@",
      cachedCount,
      forced ? "true" : "false")
    return ScanToken(signpostID: signpostID)
  }

  static func endScan(_ token: ScanToken, resultCount: Int) {
    os_signpost(
      .end,
      log: log,
      name: "Launcher Index Refresh",
      signpostID: token.signpostID,
      "results=%d",
      resultCount)
  }

  static func markPresentationChange(kind: String, value: String, resultCount: Int) {
    os_signpost(
      .event,
      log: log,
      name: "Launcher Presentation Change",
      "kind=%{public}@ value=%{public}@ results=%d",
      kind,
      value,
      resultCount)
  }
}

@MainActor
final class LauncherIconCache: ObservableObject {
  static let shared = LauncherIconCache()

  @Published private var icons: [String: NSImage] = [:]
  private var loadingKeys = Set<String>()

  func icon(for app: LauncherApp) -> NSImage? {
    icons[app.cacheKey]
  }

  func load(_ app: LauncherApp) {
    let key = app.cacheKey
    guard icons[key] == nil, loadingKeys.insert(key).inserted else { return }
    let path = app.path
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let image = NSWorkspace.shared.icon(forFile: path)
      DispatchQueue.main.async {
        guard let self else { return }
        self.icons[key] = image
        self.loadingKeys.remove(key)
      }
    }
  }
}

struct LauncherAppIndex: Codable {
  let version: Int
  let generatedAt: Date
  let rootSnapshots: [LauncherRootSnapshot]
  let apps: [LauncherApp]
}

enum LauncherSearchEngine: String, CaseIterable, Identifiable {
  case baidu
  case google
  case bilibili
  case douyinFeatured
  case xiaohongshu
  case zhihu
  case wechat
  case youtube

  var id: String { rawValue }

  var title: String {
    switch self {
    case .baidu: return "百度"
    case .google: return "Google"
    case .bilibili: return "B站"
    case .douyinFeatured: return "抖音精选"
    case .xiaohongshu: return "小红书"
    case .zhihu: return "知乎"
    case .wechat: return "微信搜一搜"
    case .youtube: return "YouTube"
    }
  }

  var systemImage: String {
    switch self {
    case .baidu: return "pawprint.fill"
    case .google: return "g.circle.fill"
    case .bilibili: return "play.tv.fill"
    case .douyinFeatured: return "sparkles.tv.fill"
    case .xiaohongshu: return "book.closed.fill"
    case .zhihu: return "questionmark.bubble.fill"
    case .wechat: return "bubble.left.and.bubble.right.fill"
    case .youtube: return "play.rectangle.fill"
    }
  }

  func searchURL(for value: String) -> URL? {
    switch self {
    case .baidu:
      var components = URLComponents(string: "https://www.baidu.com/s")
      components?.queryItems = [URLQueryItem(name: "wd", value: value)]
      return components?.url
    case .google:
      var components = URLComponents(string: "https://www.google.com/search")
      components?.queryItems = [URLQueryItem(name: "q", value: value)]
      return components?.url
    case .bilibili:
      var components = URLComponents(string: "https://search.bilibili.com/all")
      components?.queryItems = [URLQueryItem(name: "keyword", value: value)]
      return components?.url
    case .douyinFeatured:
      let baseURL = URL(string: "https://www.douyin.com/search")
      return baseURL?.appendingPathComponent(value)
    case .xiaohongshu:
      var components = URLComponents(string: "https://www.xiaohongshu.com/search_result")
      components?.queryItems = [URLQueryItem(name: "keyword", value: value)]
      return components?.url
    case .zhihu:
      var components = URLComponents(string: "https://www.zhihu.com/search")
      components?.queryItems = [
        URLQueryItem(name: "type", value: "content"),
        URLQueryItem(name: "q", value: value),
      ]
      return components?.url
    case .wechat:
      var components = URLComponents(string: "https://weixin.sogou.com/weixin")
      components?.queryItems = [
        URLQueryItem(name: "type", value: "2"),
        URLQueryItem(name: "query", value: value),
      ]
      return components?.url
    case .youtube:
      var components = URLComponents(string: "https://www.youtube.com/results")
      components?.queryItems = [URLQueryItem(name: "search_query", value: value)]
      return components?.url
    }
  }
}

struct LauncherRootSnapshot: Codable, Hashable {
  let path: String
  let modificationTime: TimeInterval
}

struct LauncherUsageRecord: Codable, Equatable, Identifiable {
  let id: String
  var bundleIdentifier: String
  var path: String
  var displayName: String
  var pinyinInitials: String
  var lastOpenedAt: Date
  var openCount: Int
  var lastMatchedQuery: String
}

struct LauncherUsageHistory: Codable, Equatable {
  static let currentVersion = 1
  static let empty = LauncherUsageHistory(version: currentVersion, records: [])

  var version: Int
  var records: [LauncherUsageRecord]

  static func load(from url: URL) -> LauncherUsageHistory {
    guard let data = try? LocalConfigurationFileCodec.readData(from: url),
      let history = try? JSONDecoder().decode(LauncherUsageHistory.self, from: data),
      history.version == currentVersion,
      history.records.count <= LocalConfigurationFileCodec.maximumRecordCount
    else {
      return .empty
    }
    return history
  }

  func save(to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(self)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppDiagnostics.log("launcher_history_save_failed error=\(error.localizedDescription)")
    }
  }

  mutating func recordOpen(app: LauncherApp, query: String, openedAt: Date = Date()) {
    let key = Self.key(for: app)
    let normalizedQuery = AppLauncherScanner.normalize(query)
    if let index = records.firstIndex(where: { $0.id == key }) {
      records[index].bundleIdentifier = app.bundleIdentifier
      records[index].path = app.path
      records[index].displayName = app.name
      records[index].pinyinInitials = app.initials
      records[index].lastOpenedAt = openedAt
      records[index].openCount = min(records[index].openCount + 1, 10_000)
      records[index].lastMatchedQuery = normalizedQuery
    } else {
      records.append(
        LauncherUsageRecord(
          id: key,
          bundleIdentifier: app.bundleIdentifier,
          path: app.path,
          displayName: app.name,
          pinyinInitials: app.initials,
          lastOpenedAt: openedAt,
          openCount: 1,
          lastMatchedQuery: normalizedQuery
        )
      )
    }
  }

  @discardableResult
  mutating func pruneUnavailableApps(_ apps: [LauncherApp]) -> Bool {
    let availableKeys = Set(apps.map(Self.key(for:)))
    let before = records.count
    records.removeAll {
      !availableKeys.contains($0.id) || !FileManager.default.fileExists(atPath: $0.path)
    }
    return records.count != before
  }

  func learningScore(for app: LauncherApp, query: String, now: Date = Date()) -> Int {
    let normalizedQuery = AppLauncherScanner.normalize(query)
    guard !normalizedQuery.isEmpty else { return 0 }
    return learningScore(
      for: app,
      normalizedQuery: normalizedQuery,
      now: now,
      indexedRecords: indexedRecords())
  }

  func indexedRecords() -> [String: LauncherUsageRecord] {
    var result: [String: LauncherUsageRecord] = [:]
    result.reserveCapacity(records.count)
    for record in records {
      result[record.id] = record
    }
    return result
  }

  func learningScore(
    for app: LauncherApp,
    normalizedQuery: String,
    now: Date,
    indexedRecords: [String: LauncherUsageRecord]
  ) -> Int {
    guard let record = indexedRecords[Self.key(for: app)] else { return 0 }

    var score = 0
    let lastQuery = AppLauncherScanner.normalize(record.lastMatchedQuery)
    if !lastQuery.isEmpty {
      if lastQuery == normalizedQuery {
        score += normalizedQuery.count == 1 ? 1_600 : 900
      } else if lastQuery.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(lastQuery) {
        score += normalizedQuery.count == 1 ? 950 : 500
      }
    }
    if record.pinyinInitials.hasPrefix(normalizedQuery) {
      score += normalizedQuery.count == 1 ? 1_200 : 650
    }
    score += min(record.openCount, 12) * 90

    let age = max(0, now.timeIntervalSince(record.lastOpenedAt))
    switch age {
    case 0..<(60 * 60):
      score += 900
    case 0..<(60 * 60 * 24):
      score += 650
    case 0..<(60 * 60 * 24 * 7):
      score += 350
    case 0..<(60 * 60 * 24 * 30):
      score += 140
    default:
      break
    }

    return min(score, normalizedQuery.count == 1 ? 4_800 : 1_800)
  }

  private static func key(for app: LauncherApp) -> String {
    app.bundleIdentifier.isEmpty ? "path:\(app.path)" : "bundle:\(app.bundleIdentifier)"
  }
}

struct LauncherPinnedRecord: Codable, Identifiable, Hashable {
  static let appKind = "app"
  static let builtInKind = "builtIn"
  static let aiPlayerBuiltInID = "builtIn:ai-player"

  let id: String
  let kind: String
  let bundleIdentifier: String
  let path: String
  let displayName: String

  static func app(_ app: LauncherApp) -> LauncherPinnedRecord {
    LauncherPinnedRecord(
      id: stableAppID(for: app),
      kind: appKind,
      bundleIdentifier: app.bundleIdentifier,
      path: app.url.standardizedFileURL.path,
      displayName: app.name
    )
  }

  static var aiPlayer: LauncherPinnedRecord {
    LauncherPinnedRecord(
      id: aiPlayerBuiltInID,
      kind: builtInKind,
      bundleIdentifier: "",
      path: "",
      displayName: "小龙哥 AI 播放器"
    )
  }

  var isAIPlayer: Bool {
    kind == Self.builtInKind && id == Self.aiPlayerBuiltInID
  }

  static func stableAppID(for app: LauncherApp) -> String {
    let bundleIdentifier = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !bundleIdentifier.isEmpty {
      return "app:bundle:\(bundleIdentifier.lowercased())"
    }
    return "app:path:\(app.url.standardizedFileURL.path.lowercased())"
  }
}

struct LauncherPinnedCollection: Codable, Equatable {
  static let currentVersion = 1
  static let maximumItemCount = 8
  static let empty = LauncherPinnedCollection(version: currentVersion, items: [])

  var version: Int
  var items: [LauncherPinnedRecord]

  static func load(from url: URL) -> LauncherPinnedCollection {
    guard let data = try? LocalConfigurationFileCodec.readData(from: url) else { return .empty }
    do {
      let collection = try JSONDecoder().decode(LauncherPinnedCollection.self, from: data)
      guard collection.version == currentVersion else {
        AppDiagnostics.log(
          "launcher_pinned_load_unsupported_version",
          ["version": "\(collection.version)"])
        return .empty
      }
      return LauncherPinnedCollection(
        version: currentVersion,
        items: Array(collection.items.prefix(maximumItemCount))
      )
    } catch {
      AppDiagnostics.log("launcher_pinned_load_failed", ["error": error.localizedDescription])
      return .empty
    }
  }

  func save(to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(self)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppDiagnostics.log("launcher_pinned_save_failed", ["error": error.localizedDescription])
    }
  }

  mutating func insert(_ record: LauncherPinnedRecord) -> LauncherPinnedInsertionResult {
    if items.contains(where: { $0.id == record.id }) {
      return .alreadyPresent
    }
    guard items.count < Self.maximumItemCount else { return .maximumReached }
    items.append(record)
    return .inserted(position: items.count)
  }

  @discardableResult
  mutating func remove(id: String) -> LauncherPinnedRecord? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    return items.remove(at: index)
  }

  mutating func move(id: String, offset: Int) -> Int? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    let destination = index + offset
    guard items.indices.contains(destination) else { return nil }
    items.swapAt(index, destination)
    return destination
  }

  mutating func move(id: String, before targetID: String) -> Int? {
    guard id != targetID, let source = items.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    let record = items.remove(at: source)
    guard let target = items.firstIndex(where: { $0.id == targetID }) else {
      items.insert(record, at: min(source, items.count))
      return nil
    }
    items.insert(record, at: target)
    return target
  }
}

enum LauncherPinnedInsertionResult: Equatable {
  case inserted(position: Int)
  case alreadyPresent
  case maximumReached
}

enum LauncherPinnedResolver {
  static func resolve(
    _ record: LauncherPinnedRecord,
    apps: [LauncherApp]
  ) -> LauncherApp? {
    guard record.kind == LauncherPinnedRecord.appKind else { return nil }
    let bundleIdentifier = record.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !bundleIdentifier.isEmpty,
      let app = apps.first(where: {
        $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
      })
    {
      return app
    }
    let path = URL(fileURLWithPath: record.path).standardizedFileURL.path
    return apps.first(where: { $0.url.standardizedFileURL.path == path })
  }

  static func excludingPinnedApps(
    _ apps: [LauncherApp],
    records: [LauncherPinnedRecord]
  ) -> [LauncherApp] {
    let pinnedIDs = Set(records.map(\.id))
    return apps.filter { !pinnedIDs.contains(LauncherPinnedRecord.stableAppID(for: $0)) }
  }
}

enum LauncherPinnedPresentation {
  static func shouldShowPinnedItems(query: String, itemCount: Int) -> Bool {
    AppLauncherScanner.normalize(query).isEmpty && itemCount > 0
  }

  static func columnCount(for width: CGFloat) -> Int {
    width < 600 ? 4 : 8
  }

  static func searchFieldHeight(for width: CGFloat) -> CGFloat {
    if width < 420 { return 52 }
    if width < 600 { return 56 }
    return 62
  }
}

struct ResolvedLauncherPinnedItem: Identifiable, Hashable {
  let record: LauncherPinnedRecord
  let app: LauncherApp?

  var id: String { record.id }
  var name: String { app?.name ?? record.displayName }
  var isAIPlayer: Bool { record.isAIPlayer }
  var isAvailable: Bool { app != nil || isAIPlayer }
  var kindLabel: String { isAIPlayer ? "内置功能" : "App" }
  var systemImageName: String? { isAIPlayer ? "play.square.stack.fill" : nil }
}

enum LauncherUtilityKind: String {
  case calculator
  case web
}

struct LauncherUtilityItem: Identifiable, Hashable {
  let id: String
  let kind: LauncherUtilityKind
  let title: String
  let subtitle: String
  let actionTitle: String
  let value: String
  let url: URL?
}

enum LauncherCalculator {
  private static let maximumInputByteCount = 512
  private static let maximumTokenCount = 256
  private static let maximumNestingDepth = 32

  static func evaluate(_ query: String) -> LauncherUtilityItem? {
    guard query.utf8.count <= maximumInputByteCount else { return nil }
    let expression = normalizedExpression(query)
    guard expression.utf8.count <= maximumInputByteCount else { return nil }
    guard expression.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
    guard expression.range(of: #"^[0-9+\-*/().% ]+$"#, options: .regularExpression) != nil
    else { return nil }
    var parser = ExpressionParser(
      expression,
      tokenLimit: maximumTokenCount,
      nestingLimit: maximumNestingDepth)
    guard let value = parser.parse(), value.isFinite else { return nil }
    let valueText = format(value)
    return LauncherUtilityItem(
      id: "calculator-\(expression)",
      kind: .calculator,
      title: valueText,
      subtitle: "\(expression) = \(valueText)",
      actionTitle: "Return 复制结果",
      value: valueText,
      url: nil
    )
  }

  private static func normalizedExpression(_ query: String) -> String {
    query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "×", with: "*")
      .replacingOccurrences(of: "÷", with: "/")
      .replacingOccurrences(of: "＋", with: "+")
      .replacingOccurrences(of: "－", with: "-")
      .replacingOccurrences(of: "＊", with: "*")
      .replacingOccurrences(of: "／", with: "/")
      .replacingOccurrences(of: "（", with: "(")
      .replacingOccurrences(of: "）", with: ")")
  }

  private static func format(_ value: Double) -> String {
    if abs(value.rounded() - value) < 0.0000000001 {
      return String(format: "%.0f", value)
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 10
    formatter.minimumFractionDigits = 0
    formatter.usesGroupingSeparator = false
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private struct ExpressionParser {
    private let characters: [Character]
    private let tokenLimit: Int
    private let nestingLimit: Int
    private var index = 0
    private var tokenCount = 0

    init(_ expression: String, tokenLimit: Int, nestingLimit: Int) {
      characters = Array(expression)
      self.tokenLimit = tokenLimit
      self.nestingLimit = nestingLimit
    }

    mutating func parse() -> Double? {
      guard let value = parseExpression(depth: 0) else { return nil }
      skipSpaces()
      return index == characters.count ? value : nil
    }

    private mutating func parseExpression(depth: Int) -> Double? {
      guard var value = parseTerm(depth: depth) else { return nil }
      while true {
        skipSpaces()
        if match("+") {
          guard consumeToken(), let right = parseTerm(depth: depth) else { return nil }
          value += right
        } else if match("-") {
          guard consumeToken(), let right = parseTerm(depth: depth) else { return nil }
          value -= right
        } else {
          return value
        }
      }
    }

    private mutating func parseTerm(depth: Int) -> Double? {
      guard var value = parseFactor(depth: depth) else { return nil }
      while true {
        skipSpaces()
        if match("*") {
          guard consumeToken(), let right = parseFactor(depth: depth) else { return nil }
          value *= right
        } else if match("/") {
          guard consumeToken(), let right = parseFactor(depth: depth),
            abs(right) > Double.ulpOfOne
          else { return nil }
          value /= right
        } else {
          return value
        }
      }
    }

    private mutating func parseFactor(depth: Int) -> Double? {
      guard depth <= nestingLimit else { return nil }
      skipSpaces()
      if match("+") {
        guard consumeToken() else { return nil }
        return parseFactor(depth: depth + 1)
      }
      if match("-") {
        guard consumeToken() else { return nil }
        return parseFactor(depth: depth + 1).map { -$0 }
      }

      let value: Double?
      if match("(") {
        guard consumeToken() else { return nil }
        value = parseExpression(depth: depth + 1)
        skipSpaces()
        guard match(")"), consumeToken() else { return nil }
      } else {
        value = parseNumber()
      }

      guard var result = value else { return nil }
      while true {
        skipSpaces()
        if match("%") {
          guard consumeToken() else { return nil }
          result /= 100
        } else {
          return result
        }
      }
    }

    private mutating func parseNumber() -> Double? {
      skipSpaces()
      let start = index
      var seenDot = false
      while index < characters.count {
        let character = characters[index]
        if character == "." && !seenDot {
          seenDot = true
          index += 1
        } else if character.isNumber {
          index += 1
        } else {
          break
        }
      }
      guard index > start else { return nil }
      guard consumeToken() else { return nil }
      return Double(String(characters[start..<index]))
    }

    private mutating func skipSpaces() {
      while index < characters.count, characters[index].isWhitespace {
        index += 1
      }
    }

    private mutating func match(_ character: Character) -> Bool {
      guard index < characters.count, characters[index] == character else { return false }
      index += 1
      return true
    }

    private mutating func consumeToken() -> Bool {
      tokenCount += 1
      return tokenCount <= tokenLimit
    }
  }
}

enum LauncherWebResolver {
  static func destination(
    for query: String,
    searchEngine: LauncherSearchEngine = .baidu
  ) -> LauncherUtilityItem? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard LauncherCalculator.evaluate(trimmed) == nil else { return nil }

    if let url = directURL(from: trimmed) {
      return LauncherUtilityItem(
        id: "web-\(trimmed)",
        kind: .web,
        title: "打开网址",
        subtitle: url.absoluteString,
        actionTitle: "Return 打开",
        value: trimmed,
        url: url
      )
    }

    guard let url = searchEngine.searchURL(for: trimmed) else { return nil }
    return LauncherUtilityItem(
      id: "web-search-\(trimmed)",
      kind: .web,
      title: "浏览器搜索",
      subtitle: "\(searchEngine.title)：\(trimmed)",
      actionTitle: "Return 搜索",
      value: trimmed,
      url: url
    )
  }

  private static func directURL(from value: String) -> URL? {
    if let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) {
      return url
    }
    let hasSpaces = value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    let looksLikeDomain =
      !hasSpaces && value.contains(".")
      && value.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}.*$"#, options: .regularExpression) != nil
    guard looksLikeDomain else { return nil }
    return URL(string: "https://\(value)")
  }

}

enum AppLauncherScanner {
  private static let indexVersion = 2
  private static let maxIndexAge: TimeInterval = 60 * 60 * 12
  private static let roots = [
    "/Applications",
    "/System/Applications",
    "/System/Applications/Utilities",
    NSString(string: "~/Applications").expandingTildeInPath,
  ]

  static func loadIndex(from url: URL) -> LauncherAppIndex? {
    guard let data = try? LocalConfigurationFileCodec.readData(from: url),
      let index = try? JSONDecoder().decode(LauncherAppIndex.self, from: data),
      index.version == indexVersion,
      index.apps.count <= LocalConfigurationFileCodec.maximumRecordCount,
      index.rootSnapshots.count <= LocalConfigurationFileCodec.maximumCollectionEntries
    else {
      return nil
    }
    return index
  }

  static func saveIndex(_ apps: [LauncherApp], to url: URL) {
    let index = LauncherAppIndex(
      version: indexVersion,
      generatedAt: Date(),
      rootSnapshots: currentRootSnapshots(),
      apps: apps
    )
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(index)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppDiagnostics.log("launcher_index_save_failed error=\(error.localizedDescription)")
    }
  }

  static func cachedApps(from index: LauncherAppIndex) -> [LauncherApp] {
    sortedForLauncher(
      index.apps.filter { FileManager.default.fileExists(atPath: $0.path) })
  }

  static func shouldRefreshIndex(_ index: LauncherAppIndex?) -> Bool {
    guard let index else { return true }
    guard Date().timeIntervalSince(index.generatedAt) < maxIndexAge else { return true }
    return Set(index.rootSnapshots) != Set(currentRootSnapshots())
  }

  static func scan(cachedApps: [LauncherApp] = []) -> [LauncherApp] {
    var seenKeys = Set<String>()
    var apps: [LauncherApp] = []
    let cachedByPath = Dictionary(
      uniqueKeysWithValues: cachedApps.map { ($0.url.standardizedFileURL.path, $0) })

    for root in roots {
      let rootURL = URL(fileURLWithPath: root, isDirectory: true)
      guard FileManager.default.fileExists(atPath: rootURL.path),
        let enumerator = FileManager.default.enumerator(
          at: rootURL,
          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        continue
      }

      for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
        guard !shouldSkip(url) else {
          continue
        }
        let canonicalPath = url.standardizedFileURL.path
        let metadataModifiedAt = appMetadataModifiedAt(url)
        let cachedApp = cachedByPath[canonicalPath]
        let app =
          cachedApp?.metadataModifiedAt == metadataModifiedAt
          ? cachedApp
          : launcherApp(at: url, metadataModifiedAt: metadataModifiedAt)
        guard let app else {
          continue
        }
        let uniqueKey = app.bundleIdentifier.isEmpty ? app.path : "bundle:\(app.bundleIdentifier)"
        guard seenKeys.insert(uniqueKey).inserted else {
          continue
        }
        apps.append(app)
      }
    }

    return sortedForLauncher(apps)
  }

  static func filter(
    _ apps: [LauncherApp],
    query: String,
    history: LauncherUsageHistory? = nil
  ) -> [LauncherApp] {
    let normalizedQuery = normalize(query)
    guard !normalizedQuery.isEmpty else {
      return apps
    }

    let now = Date()
    let indexedHistory = history?.indexedRecords() ?? [:]
    let runningBundleIdentifiers = runningBundleIdentifiers()
    return
      apps
      .enumerated()
      .compactMap {
        offset, app -> (
          app: LauncherApp, rank: Int, finalScore: Int, usageScore: Int, offset: Int
        )? in
        guard let score = score(app, query: normalizedQuery) else { return nil }
        let baseScore = matchBaseScore(rank: score, query: normalizedQuery)
        let learningScore =
          history?
          .learningScore(
            for: app,
            normalizedQuery: normalizedQuery,
            now: now,
            indexedRecords: indexedHistory) ?? 0
        return (
          app,
          score,
          baseScore + learningScore,
          usageScore(app, runningBundleIdentifiers: runningBundleIdentifiers, now: now),
          offset
        )
      }
      .sorted {
        let lhsProtected = isExactProtected(rank: $0.rank)
        let rhsProtected = isExactProtected(rank: $1.rank)
        if lhsProtected != rhsProtected { return lhsProtected }
        if $0.finalScore != $1.finalScore { return $0.finalScore > $1.finalScore }
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        if $0.usageScore != $1.usageScore { return $0.usageScore > $1.usageScore }
        let nameOrder = $0.app.name.localizedCaseInsensitiveCompare($1.app.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return $0.offset < $1.offset
      }
      .map(\.app)
  }

  private static func launcherApp(
    at url: URL,
    metadataModifiedAt: TimeInterval?
  ) -> LauncherApp? {
    let bundle = Bundle(url: url)
    let info = bundle?.infoDictionary ?? [:]
    let displayName =
      localizedName(in: bundle)
      ?? info["CFBundleDisplayName"] as? String
      ?? info["CFBundleName"] as? String
      ?? url.deletingPathExtension().lastPathComponent
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }

    let bundleIdentifier = bundle?.bundleIdentifier ?? ""
    let normalizedName = normalize(name)
    let pinyin = pinyinText(name)
    let initials = initialsText(name)
    let tokens = [
      normalizedName,
      normalize(bundleIdentifier),
      normalize(url.deletingPathExtension().lastPathComponent),
      pinyin,
      initials,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: " ")

    let id = bundleIdentifier.isEmpty ? url.standardizedFileURL.path : bundleIdentifier
    let usage = usageMetadata(for: url)
    return LauncherApp(
      id: id,
      name: name,
      bundleIdentifier: bundleIdentifier,
      path: url.standardizedFileURL.path,
      normalizedName: normalizedName,
      searchTokens: tokens,
      initials: initials,
      useCount: usage.useCount,
      lastUsedDate: usage.lastUsedDate,
      metadataModifiedAt: metadataModifiedAt
    )
  }

  private static func appMetadataModifiedAt(_ url: URL) -> TimeInterval? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
      return nil
    }
    return values.contentModificationDate?.timeIntervalSince1970
  }

  private static func shouldSkip(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return path.contains("/Chrome Apps.localized/") || path.contains("/Chrome Apps/")
  }

  private static func currentRootSnapshots() -> [LauncherRootSnapshot] {
    roots.compactMap { root -> LauncherRootSnapshot? in
      guard
        let values = try? URL(fileURLWithPath: root, isDirectory: true)
          .resourceValues(forKeys: [.contentModificationDateKey]),
        let date = values.contentModificationDate
      else {
        return nil
      }
      return LauncherRootSnapshot(
        path: root, modificationTime: date.timeIntervalSince1970.rounded())
    }
  }

  private static func localizedName(in bundle: Bundle?) -> String? {
    guard let bundle else { return nil }
    if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String {
      return name
    }
    if let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String {
      return name
    }
    return nil
  }

  private static func score(_ app: LauncherApp, query: String) -> Int? {
    let name = app.normalizedName
    let words = normalizedWords(app.name)
    if name == query { return 0 }
    if words.contains(query) { return 1 }
    if name.hasPrefix(query) { return 2 }
    if app.initials == query { return 3 }
    if words.contains(where: { $0.hasPrefix(query) }) { return 4 }
    if app.initials.hasPrefix(query) { return 5 }
    if app.searchTokens.contains(query) { return 6 }
    return nil
  }

  private static func matchBaseScore(rank: Int, query: String) -> Int {
    if query.count == 1 {
      switch rank {
      case 0: return 120_000
      case 1: return 116_000
      case 2: return 76_000
      case 3: return 75_500
      case 4: return 75_000
      case 5: return 74_500
      case 6: return 70_000
      default: return 0
      }
    }
    switch rank {
    case 0: return 120_000
    case 1: return 116_000
    case 2: return 92_000
    case 3: return 88_000
    case 4: return 82_000
    case 5: return 78_000
    case 6: return 68_000
    default: return 0
    }
  }

  private static func isExactProtected(rank: Int) -> Bool {
    rank <= 1
  }

  private static func sortedForLauncher(_ apps: [LauncherApp]) -> [LauncherApp] {
    let now = Date()
    let runningBundleIdentifiers = runningBundleIdentifiers()
    return
      apps
      .enumerated()
      .map {
        (
          app: $0.element,
          usageScore: usageScore(
            $0.element,
            runningBundleIdentifiers: runningBundleIdentifiers,
            now: now),
          offset: $0.offset
        )
      }
      .sorted {
        if $0.usageScore != $1.usageScore { return $0.usageScore > $1.usageScore }
        let nameOrder = $0.app.name.localizedCaseInsensitiveCompare($1.app.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return $0.offset < $1.offset
      }
      .map(\.app)
  }

  private static func runningBundleIdentifiers() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
  }

  private static func usageScore(
    _ app: LauncherApp,
    runningBundleIdentifiers: Set<String>,
    now: Date
  ) -> Int {
    var score = min(app.useCount, 50_000)
    if !app.bundleIdentifier.isEmpty, runningBundleIdentifiers.contains(app.bundleIdentifier) {
      score += 8_000
    }
    if let lastUsedDate = app.lastUsedDate {
      let age = max(0, now.timeIntervalSince(lastUsedDate))
      switch age {
      case 0..<(60 * 60 * 24):
        score += 2_000
      case 0..<(60 * 60 * 24 * 7):
        score += 1_000
      case 0..<(60 * 60 * 24 * 30):
        score += 400
      default:
        break
      }
    }
    if app.path.hasPrefix("/System/") {
      score -= 600
    } else if app.path.hasPrefix("/Applications/") {
      score += 120
    }
    return score
  }

  private static func usageMetadata(for url: URL) -> (useCount: Int, lastUsedDate: Date?) {
    let metadata = NSMetadataItem(url: url)
    let useCount =
      metadata?.value(forAttribute: "kMDItemUseCount") as? Int
      ?? (metadata?.value(forAttribute: "kMDItemUseCount") as? NSNumber)?.intValue
      ?? 0
    let lastUsedDate = metadata?.value(forAttribute: "kMDItemLastUsedDate") as? Date
    return (useCount, lastUsedDate)
  }

  static func normalize(_ value: String) -> String {
    value
      .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func pinyinText(_ value: String) -> String {
    let latin = value.applyingTransform(.mandarinToLatin, reverse: false) ?? value
    return normalize(latin)
  }

  private static func initialsText(_ value: String) -> String {
    let latin = value.applyingTransform(.mandarinToLatin, reverse: false) ?? value
    let folded =
      latin
      .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
      .lowercased()
    let parts = folded.split { !$0.isLetter && !$0.isNumber }
    let wordInitials = parts.compactMap(\.first).map(String.init).joined()
    if !wordInitials.isEmpty {
      return normalize(wordInitials)
    }
    return normalize(value).prefix(1).description
  }

  private static func normalizedWords(_ value: String) -> [String] {
    let folded =
      value
      .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
      .lowercased()
    return
      folded
      .split { !$0.isLetter && !$0.isNumber }
      .map { normalize(String($0)) }
      .filter { !$0.isEmpty }
  }
}
