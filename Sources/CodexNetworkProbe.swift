import AppKit
import Foundation
import SwiftUI

/// 客户界面只保留网页上的两个球。
/// `international` 仅用于读取旧设置，统一迁回网络测速，不再出现在界面中。
enum NetworkProbeDirection: String, CaseIterable, Codable, Identifiable {
  case domestic
  case international
  case codex

  var id: String { rawValue }

  static let customerChoices: [NetworkProbeDirection] = [.domestic, .codex]

  static func customerFacing(_ stored: NetworkProbeDirection?) -> NetworkProbeDirection {
    stored == .codex ? .codex : .domestic
  }

  var title: String {
    switch self {
    case .domestic: return "网络测速"
    case .international: return "网络测速"
    case .codex: return "Codex 连接"
    }
  }

  var fullTitle: String { title }

  var subtitle: String {
    switch self {
    case .domestic, .international: return "下载、上传、延迟、抖动"
    case .codex: return "当前网络 · 4 轮"
    }
  }

  var systemImage: String {
    switch self {
    case .domestic, .international: return "arrow.up.arrow.down"
    case .codex: return "arrow.clockwise"
    }
  }
}

enum WebsiteSpeedStage: String, Equatable, Sendable {
  case latency
  case download
  case upload

  var title: String {
    switch self {
    case .latency: return "正在校准延迟"
    case .download: return "正在测试下载"
    case .upload: return "正在测试上传"
    }
  }
}

struct WebsiteSpeedMeasurementGroup: Equatable, Sendable {
  let stage: WebsiteSpeedStage
  let bytes: Int
  let count: Int
  let bypassFinishThreshold: Bool
}

/// 当前生产版 aixlg.com/c 的 Cloudflare 测量序列。
enum WebsiteSpeedPlan {
  static let bandwidthFinishRequestDuration: TimeInterval = 1.2
  static let bandwidthMinimumRequestDuration: TimeInterval = 0.01
  static let estimatedServerTimeMilliseconds: Double = 10
  static let maximumConsecutiveRetries = 4
  static let requestTimeout: TimeInterval = 15
  static let maximumWallClockDuration: TimeInterval = 75
  static let maximumDownloadBytesIncludingRetries = 80_000_000
  static let maximumUploadBytesIncludingRetries = 48_000_000
  static let loadedLatencyThrottleNanoseconds: UInt64 = 400_000_000

  static let groups: [WebsiteSpeedMeasurementGroup] = [
    WebsiteSpeedMeasurementGroup(
      stage: .latency, bytes: 0, count: 1, bypassFinishThreshold: true),
    WebsiteSpeedMeasurementGroup(
      stage: .latency, bytes: 0, count: 8, bypassFinishThreshold: true),
    WebsiteSpeedMeasurementGroup(
      stage: .download, bytes: 100_000, count: 1, bypassFinishThreshold: true),
    WebsiteSpeedMeasurementGroup(
      stage: .download, bytes: 1_000_000, count: 2, bypassFinishThreshold: false),
    WebsiteSpeedMeasurementGroup(
      stage: .download, bytes: 8_000_000, count: 3, bypassFinishThreshold: false),
    WebsiteSpeedMeasurementGroup(
      stage: .download, bytes: 16_000_000, count: 2, bypassFinishThreshold: false),
    WebsiteSpeedMeasurementGroup(
      stage: .upload, bytes: 500_000, count: 2, bypassFinishThreshold: false),
    WebsiteSpeedMeasurementGroup(
      stage: .upload, bytes: 2_000_000, count: 3, bypassFinishThreshold: false),
    WebsiteSpeedMeasurementGroup(
      stage: .upload, bytes: 8_000_000, count: 3, bypassFinishThreshold: false),
  ]

  static let totalSampleCount = groups.reduce(0) { $0 + $1.count }
  static let maximumPlannedDownloadBytes =
    groups
    .filter { $0.stage == .download }
    .reduce(0) { $0 + ($1.bytes * $1.count) }
  static let maximumPlannedUploadBytes =
    groups
    .filter { $0.stage == .upload }
    .reduce(0) { $0 + ($1.bytes * $1.count) }

  static func endpoint(
    for stage: WebsiteSpeedStage,
    bytes: Int,
    duringLoad: WebsiteSpeedStage? = nil
  ) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "speed.cloudflare.com"
    components.path = stage == .upload ? "/__up" : "/__down"
    components.queryItems = [URLQueryItem(name: "bytes", value: String(bytes))]
    if let duringLoad {
      components.queryItems?.append(
        URLQueryItem(name: "during", value: duringLoad.rawValue))
    }
    return components.url!
  }

  static func uploadBody(bytes: Int) -> Data {
    Data(repeating: 48, count: max(0, bytes))
  }
}

struct WebsiteSpeedTransferBudget: Equatable, Sendable {
  private(set) var remainingDownloadBytes = WebsiteSpeedPlan.maximumDownloadBytesIncludingRetries
  private(set) var remainingUploadBytes = WebsiteSpeedPlan.maximumUploadBytesIncludingRetries

  mutating func reserve(stage: WebsiteSpeedStage, bytes: Int) -> Bool {
    let bytes = max(0, bytes)
    switch stage {
    case .latency:
      return true
    case .download where bytes <= remainingDownloadBytes:
      remainingDownloadBytes -= bytes
      return true
    case .upload where bytes <= remainingUploadBytes:
      remainingUploadBytes -= bytes
      return true
    case .download, .upload:
      return false
    }
  }
}

struct WebsiteSpeedDeadline: Equatable, Sendable {
  let startedAt: TimeInterval
  let maximumDuration: TimeInterval

  func remaining(at now: TimeInterval) -> TimeInterval {
    max(0, maximumDuration - max(0, now - startedAt))
  }

  func requestTimeout(at now: TimeInterval, maximumRequestTimeout: TimeInterval) -> TimeInterval? {
    let remaining = remaining(at: now)
    guard remaining > 0 else { return nil }
    return min(remaining, maximumRequestTimeout)
  }
}

enum WebsiteSpeedHTTPStatus {
  static func failureDescription(_ statusCode: Int) -> String? {
    switch statusCode {
    case 200...299:
      return nil
    case 429:
      return "测速节点请求过于频繁（HTTP 429）"
    case 500...599:
      return "测速节点暂时不可用（HTTP \(statusCode)）"
    case 400...499:
      return "测速请求被拒绝（HTTP \(statusCode)）"
    default:
      return "测速节点返回意外状态（HTTP \(statusCode)）"
    }
  }
}

enum WebsiteSpeedTransportFailure {
  static func description(for error: Error) -> String {
    guard let urlError = error as? URLError else { return error.localizedDescription }
    switch urlError.code {
    case .dataNotAllowed, .internationalRoamingOff:
      return "当前网络被系统标记为受限或昂贵，已停止测速以避免消耗流量"
    case .timedOut:
      return "测速节点响应超时，请检查网络后重试"
    case .notConnectedToInternet:
      return "当前没有可用网络连接"
    default:
      return urlError.localizedDescription
    }
  }
}

enum WebsiteSpeedTiming {
  static func serverDurationMilliseconds(from header: String?) -> Double? {
    guard let header else { return nil }
    let pattern = #"(?:^|;)\s*dur=([0-9.]+)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let fullRange = NSRange(header.startIndex..<header.endIndex, in: header)
    guard let match = expression.firstMatch(in: header, range: fullRange),
      let valueRange = Range(match.range(at: 1), in: header)
    else { return nil }
    return Double(header[valueRange])
  }

  static func pingMilliseconds(
    ttfbMilliseconds: Double,
    serverDurationMilliseconds: Double?
  ) -> Double {
    let measuredServerDuration = serverDurationMilliseconds ?? 0
    let effectiveServerDuration =
      measuredServerDuration > 0
      ? measuredServerDuration
      : WebsiteSpeedPlan.estimatedServerTimeMilliseconds
    return max(
      0.01,
      ttfbMilliseconds - effectiveServerDuration)
  }

  static func downloadDurationSeconds(
    pingMilliseconds: Double,
    payloadDownloadSeconds: TimeInterval
  ) -> TimeInterval {
    // 吞吐只计算响应正文传输窗口；往返延迟已作为独立指标展示。
    _ = pingMilliseconds
    return max(0.000_01, payloadDownloadSeconds)
  }

  static func bitsPerSecond(
    stage: WebsiteSpeedStage,
    requestedBytes: Int,
    transferredBytes: Int64?,
    duration: TimeInterval
  ) -> Double? {
    guard stage != .latency, duration > 0 else { return nil }
    _ = requestedBytes
    guard let transferredBytes, transferredBytes > 0 else { return nil }
    return Double(transferredBytes) * 8 / duration
  }

  static func qualifiesForBandwidth(duration: TimeInterval) -> Bool {
    duration >= WebsiteSpeedPlan.bandwidthMinimumRequestDuration
  }
}

struct WebsiteSpeedProgress: Equatable, Sendable {
  let stage: WebsiteSpeedStage
  let completedSamples: Int
  let totalSamples: Int
  let stageValue: Double?
  let displayPercent: Double

  var fraction: Double {
    min(1, max(0, displayPercent / 100))
  }

  func withDisplayPercent(_ displayPercent: Double) -> WebsiteSpeedProgress {
    WebsiteSpeedProgress(
      stage: stage,
      completedSamples: completedSamples,
      totalSamples: totalSamples,
      stageValue: stageValue,
      displayPercent: displayPercent)
  }

  static func nextDisplayPercent(after current: Double) -> Double {
    min(92, current + (current < 55 ? 2.4 : 0.8))
  }
}

struct WebsiteSpeedRetryPolicy: Equatable, Sendable {
  private(set) var consecutiveFailures = 0

  mutating func registerFailure() -> Bool {
    guard consecutiveFailures < WebsiteSpeedPlan.maximumConsecutiveRetries else {
      return false
    }
    consecutiveFailures += 1
    return true
  }

  mutating func registerSuccess() {
    consecutiveFailures = 0
  }
}

enum WebsiteSpeedRequestDisposition: Equatable, Sendable {
  case accept
  case retry
  case cancel

  static func resolve(
    startedAtPauseEpoch: Int,
    currentPauseEpoch: Int,
    isPaused: Bool,
    isCancelled: Bool
  ) -> Self {
    if isCancelled { return .cancel }
    if isPaused || startedAtPauseEpoch != currentPauseEpoch { return .retry }
    return .accept
  }
}

struct WebsiteSpeedResult: Equatable, Sendable {
  let downloadMbps: Double
  let uploadMbps: Double
  let latencyMilliseconds: Double
  let jitterMilliseconds: Double

  static func make(
    latencyMilliseconds: [Double],
    downloadBitsPerSecond: [Double],
    uploadBitsPerSecond: [Double]
  ) -> WebsiteSpeedResult? {
    let latency =
      NetworkProbeStatistics.percentile(latencyMilliseconds, probability: 0.5) ?? 0
    let download =
      NetworkProbeStatistics.percentile(downloadBitsPerSecond, probability: 0.9) ?? 0
    let upload =
      NetworkProbeStatistics.percentile(uploadBitsPerSecond, probability: 0.9) ?? 0

    return WebsiteSpeedResult(
      downloadMbps: download / 1_000_000,
      uploadMbps: upload / 1_000_000,
      latencyMilliseconds: latency,
      jitterMilliseconds: NetworkProbeStatistics.meanAdjacentDifference(
        latencyMilliseconds) ?? 0)
  }
}

struct WebsiteSpeedSampleLedger: Equatable, Sendable {
  private(set) var latencyMilliseconds: [Double] = []
  private(set) var downloadBitsPerSecond: [Double] = []
  private(set) var uploadBitsPerSecond: [Double] = []

  mutating func begin(_ group: WebsiteSpeedMeasurementGroup) {
    if group.stage == .latency {
      // Cloudflare 的下一组 latency measurement 会覆盖前一组；首组 1 包只预热。
      latencyMilliseconds.removeAll(keepingCapacity: true)
    }
  }

  mutating func record(
    stage: WebsiteSpeedStage,
    bitsPerSecond: Double?,
    latency: Double,
    duration: TimeInterval
  ) {
    switch stage {
    case .latency:
      latencyMilliseconds.append(latency)
    case .download:
      if WebsiteSpeedTiming.qualifiesForBandwidth(duration: duration), let bitsPerSecond {
        downloadBitsPerSecond.append(bitsPerSecond)
      }
    case .upload:
      if WebsiteSpeedTiming.qualifiesForBandwidth(duration: duration), let bitsPerSecond {
        uploadBitsPerSecond.append(bitsPerSecond)
      }
    }
  }

  func value(for stage: WebsiteSpeedStage) -> Double? {
    switch stage {
    case .latency:
      return NetworkProbeStatistics.percentile(latencyMilliseconds, probability: 0.5)
    case .download:
      return NetworkProbeStatistics.percentile(downloadBitsPerSecond, probability: 0.9)
        .map { $0 / 1_000_000 }
    case .upload:
      return NetworkProbeStatistics.percentile(uploadBitsPerSecond, probability: 0.9)
        .map { $0 / 1_000_000 }
    }
  }

  var result: WebsiteSpeedResult? {
    WebsiteSpeedResult.make(
      latencyMilliseconds: latencyMilliseconds,
      downloadBitsPerSecond: downloadBitsPerSecond,
      uploadBitsPerSecond: uploadBitsPerSecond)
  }
}

private enum WebsiteSpeedRequestOutcome {
  case success(bitsPerSecond: Double?, latencyMilliseconds: Double, duration: TimeInterval)
  case failure(String)
  case cancelled
}

private protocol ProbeURLSessionTaskHandler: AnyObject {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64)
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics)
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
}

extension ProbeURLSessionTaskHandler {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {}

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {}
}

/// 一次测速运行共用同一 URLSession，保留网页 global fetch 的连接预热与复用语义。
private final class ProbeURLSessionPool: NSObject, URLSessionDataDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var handlers: [Int: ProbeURLSessionTaskHandler] = [:]
  private var invalidated = false
  private lazy var session = URLSession(
    configuration: configuration,
    delegate: self,
    delegateQueue: nil)

  init(configuration: URLSessionConfiguration) {
    self.configuration = configuration
    super.init()
  }

  func dataTask(
    with request: URLRequest,
    handler: ProbeURLSessionTaskHandler
  ) -> URLSessionDataTask? {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return nil }
    let task = session.dataTask(with: request)
    handlers[task.taskIdentifier] = handler
    return task
  }

  func unregister(taskIdentifier: Int) {
    lock.lock()
    handlers[taskIdentifier] = nil
    lock.unlock()
  }

  func invalidateAndCancel() {
    lock.lock()
    guard !invalidated else {
      lock.unlock()
      return
    }
    invalidated = true
    let session = session
    lock.unlock()
    session.invalidateAndCancel()
  }

  private func handler(for task: URLSessionTask) -> ProbeURLSessionTaskHandler? {
    lock.lock()
    defer { lock.unlock() }
    return handlers[task.taskIdentifier]
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let handler = handler(for: dataTask) else {
      completionHandler(.cancel)
      return
    }
    handler.urlSession(
      session,
      dataTask: dataTask,
      didReceive: response,
      completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    handler(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    handler(for: task)?.urlSession(
      session,
      task: task,
      didSendBodyData: bytesSent,
      totalBytesSent: totalBytesSent,
      totalBytesExpectedToSend: totalBytesExpectedToSend)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    handler(for: task)?.urlSession(session, task: task, didFinishCollecting: metrics)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let handler = handler(for: task)
    handler?.urlSession(session, task: task, didCompleteWithError: error)
    unregister(taskIdentifier: task.taskIdentifier)
  }
}

private final class WebsiteSpeedRequest: ProbeURLSessionTaskHandler, @unchecked Sendable {
  private let sessionPool: ProbeURLSessionPool
  private let stage: WebsiteSpeedStage
  private let expectedBytes: Int
  private let duringLoad: WebsiteSpeedStage?
  private let timeout: TimeInterval
  private let lock = NSLock()
  private var continuation: CheckedContinuation<WebsiteSpeedRequestOutcome, Never>?
  private var task: URLSessionDataTask?
  private var transactionMetrics: URLSessionTaskTransactionMetrics?
  private var response: HTTPURLResponse?
  private var responseStartedAt: TimeInterval?
  private var receivedBodyBytes: Int64 = 0
  private var sentBodyBytes: Int64 = 0
  private var lastBodySendAt: TimeInterval?
  private var startedAt: TimeInterval = 0
  private var finished = false
  private var cancellationRequested = false

  init(
    sessionPool: ProbeURLSessionPool,
    stage: WebsiteSpeedStage,
    bytes: Int,
    duringLoad: WebsiteSpeedStage? = nil,
    timeout: TimeInterval = WebsiteSpeedPlan.requestTimeout
  ) {
    self.sessionPool = sessionPool
    self.stage = stage
    expectedBytes = bytes
    self.duringLoad = duringLoad
    self.timeout = timeout
  }

  func run() async -> WebsiteSpeedRequestOutcome {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        if cancellationRequested {
          lock.unlock()
          continuation.resume(returning: .cancelled)
          return
        }
        self.continuation = continuation
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        var request = URLRequest(
          url: WebsiteSpeedPlan.endpoint(
            for: stage,
            bytes: expectedBytes,
            duringLoad: duringLoad))
        request.httpMethod = stage == .upload ? "POST" : "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if stage == .upload {
          request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
          request.httpBody = WebsiteSpeedPlan.uploadBody(bytes: expectedBytes)
        }

        guard let task = sessionPool.dataTask(with: request, handler: self) else {
          complete(.cancelled)
          return
        }
        lock.lock()
        let shouldStart = !finished && !cancellationRequested
        if shouldStart {
          self.task = task
        }
        lock.unlock()

        guard shouldStart else {
          task.cancel()
          sessionPool.unregister(taskIdentifier: task.taskIdentifier)
          return
        }
        task.resume()
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let task = task
    lock.unlock()
    task?.cancel()
    complete(.cancelled)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    self.response = response as? HTTPURLResponse
    responseStartedAt = ProcessInfo.processInfo.systemUptime
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    receivedBodyBytes += Int64(data.count)
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    lock.lock()
    sentBodyBytes = max(sentBodyBytes, totalBytesSent)
    lastBodySendAt = ProcessInfo.processInfo.systemUptime
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    lock.lock()
    transactionMetrics = metrics.transactionMetrics.last
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    lock.lock()
    let response = response
    let responseStartedAt = responseStartedAt
    let startedAt = startedAt
    let metrics = transactionMetrics
    let receivedBodyBytes = receivedBodyBytes
    let sentBodyBytes = sentBodyBytes
    let lastBodySendAt = lastBodySendAt
    let wasCancelled = cancellationRequested
    lock.unlock()

    if wasCancelled || (error as? URLError)?.code == .cancelled {
      complete(.cancelled)
      return
    }
    if let error {
      complete(.failure(WebsiteSpeedTransportFailure.description(for: error)))
      return
    }
    guard let response else {
      complete(.failure("测速节点没有返回 HTTP 响应"))
      return
    }
    if let failure = WebsiteSpeedHTTPStatus.failureDescription(response.statusCode) {
      complete(.failure(failure))
      return
    }

    let finishedAt = ProcessInfo.processInfo.systemUptime
    let metricStart = metrics?.requestStartDate
    let metricResponseStart = metrics?.responseStartDate
    let ttfbDuration =
      metricStart.flatMap { start in
        metricResponseStart.map { $0.timeIntervalSince(start) }
      } ?? max(0, (responseStartedAt ?? finishedAt) - startedAt)
    let serverDuration = WebsiteSpeedTiming.serverDurationMilliseconds(
      from: response.value(forHTTPHeaderField: "Server-Timing"))
    let latencyMilliseconds = WebsiteSpeedTiming.pingMilliseconds(
      ttfbMilliseconds: max(0, ttfbDuration * 1_000),
      serverDurationMilliseconds: serverDuration)

    switch stage {
    case .latency:
      complete(
        .success(
          bitsPerSecond: nil,
          latencyMilliseconds: latencyMilliseconds,
          duration: max(0.000_01, latencyMilliseconds / 1_000)))
    case .download:
      let metricDuration = metrics?.responseStartDate.flatMap { start in
        metrics?.responseEndDate.map { $0.timeIntervalSince(start) }
      }
      let payloadDuration = max(
        0,
        metricDuration ?? (finishedAt - (responseStartedAt ?? startedAt)))
      let duration = WebsiteSpeedTiming.downloadDurationSeconds(
        pingMilliseconds: latencyMilliseconds,
        payloadDownloadSeconds: payloadDuration)
      let transferredBytes = max(
        receivedBodyBytes,
        metrics?.countOfResponseBodyBytesReceived ?? 0)
      complete(
        .success(
          bitsPerSecond: WebsiteSpeedTiming.bitsPerSecond(
            stage: .download,
            requestedBytes: expectedBytes,
            transferredBytes: transferredBytes,
            duration: duration),
          latencyMilliseconds: latencyMilliseconds,
          duration: duration))
    case .upload:
      let metricDuration = metrics?.requestStartDate.flatMap { start in
        metrics?.requestEndDate.map { $0.timeIntervalSince(start) }
      }
      let measuredBodyDuration = lastBodySendAt.map { max(0, $0 - startedAt) }
      let duration = max(0.000_01, metricDuration ?? measuredBodyDuration ?? ttfbDuration)
      let transferredBytes = max(
        sentBodyBytes,
        metrics?.countOfRequestBodyBytesSent ?? 0)
      complete(
        .success(
          bitsPerSecond: WebsiteSpeedTiming.bitsPerSecond(
            stage: .upload,
            requestedBytes: expectedBytes,
            transferredBytes: transferredBytes,
            duration: duration),
          latencyMilliseconds: latencyMilliseconds,
          duration: duration))
    }
  }

  private func complete(_ outcome: WebsiteSpeedRequestOutcome) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    let taskIdentifier = task?.taskIdentifier
    task = nil
    lock.unlock()

    if let taskIdentifier { sessionPool.unregister(taskIdentifier: taskIdentifier) }
    continuation?.resume(returning: outcome)
  }
}

enum WebsiteSpeedRunOutcome: Equatable, Sendable {
  case success(WebsiteSpeedResult)
  case failure(String)
  case cancelled
}

final class WebsiteSpeedTestRunner: @unchecked Sendable {
  private let sessionPool: ProbeURLSessionPool
  private let now: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var paused = false
  private var cancelled = false
  private var pauseEpoch = 0
  private var currentRequest: WebsiteSpeedRequest?
  private var currentLoadedLatencyRequest: WebsiteSpeedRequest?

  init(
    now: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.now = now
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = WebsiteSpeedPlan.requestTimeout
    configuration.timeoutIntervalForResource = WebsiteSpeedPlan.requestTimeout
    configuration.allowsExpensiveNetworkAccess = false
    configuration.allowsConstrainedNetworkAccess = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    sessionPool = ProbeURLSessionPool(configuration: configuration)
  }

  func pause() {
    lock.lock()
    paused = true
    pauseEpoch &+= 1
    let request = currentRequest
    let loadedLatencyRequest = currentLoadedLatencyRequest
    lock.unlock()
    request?.cancel()
    loadedLatencyRequest?.cancel()
  }

  func resume() {
    lock.lock()
    paused = false
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    paused = false
    let request = currentRequest
    let loadedLatencyRequest = currentLoadedLatencyRequest
    lock.unlock()
    request?.cancel()
    loadedLatencyRequest?.cancel()
  }

  func run(
    progress: @MainActor @escaping @Sendable (WebsiteSpeedProgress) async -> Void
  ) async -> WebsiteSpeedRunOutcome {
    defer { sessionPool.invalidateAndCancel() }
    var ledger = WebsiteSpeedSampleLedger()
    var completedSamples = 0
    var stopDownload = false
    var stopUpload = false
    var retryPolicy = WebsiteSpeedRetryPolicy()
    var transferBudget = WebsiteSpeedTransferBudget()
    let deadline = WebsiteSpeedDeadline(
      startedAt: now(),
      maximumDuration: WebsiteSpeedPlan.maximumWallClockDuration)

    for group in WebsiteSpeedPlan.groups {
      guard deadline.remaining(at: now()) > 0 else {
        return .failure("测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止")
      }
      if (group.stage == .download && stopDownload)
        || (group.stage == .upload && stopUpload)
      {
        continue
      }

      ledger.begin(group)
      let valueAtGroupStart = ledger.value(for: group.stage)
      await progress(
        WebsiteSpeedProgress(
          stage: group.stage,
          completedSamples: completedSamples,
          totalSamples: WebsiteSpeedPlan.totalSampleCount,
          stageValue: valueAtGroupStart,
          displayPercent: 3))

      let loadedLatencyTask = startLoadedLatency(for: group.stage)
      var sampleIndex = 0
      var groupDurations: [TimeInterval] = []
      while sampleIndex < group.count {
        guard await waitUntilRunnable() else {
          await stopLoadedLatency(loadedLatencyTask)
          return .cancelled
        }
        guard
          let requestTimeout = deadline.requestTimeout(
            at: now(),
            maximumRequestTimeout: WebsiteSpeedPlan.requestTimeout)
        else {
          await stopLoadedLatency(loadedLatencyTask)
          return .failure(
            "测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止")
        }
        guard transferBudget.reserve(stage: group.stage, bytes: group.bytes) else {
          await stopLoadedLatency(loadedLatencyTask)
          return .failure("测速已达到本次流量上限，已自动停止")
        }

        let request = WebsiteSpeedRequest(
          sessionPool: sessionPool,
          stage: group.stage,
          bytes: group.bytes,
          timeout: requestTimeout)
        let requestPauseEpoch = setCurrentRequest(request)
        let outcome = await request.run()
        let disposition = finishCurrentRequest(
          request,
          startedAtPauseEpoch: requestPauseEpoch)

        if disposition == .cancel || Task.isCancelled {
          await stopLoadedLatency(loadedLatencyTask)
          return .cancelled
        }
        if disposition == .retry { continue }
        guard deadline.remaining(at: now()) > 0 else {
          await stopLoadedLatency(loadedLatencyTask)
          return .failure(
            "测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止")
        }

        switch outcome {
        case .cancelled:
          // 暂停会取消当前样本；即使用户很快继续，也应重试当前样本而不是结束整轮。
          continue
        case .failure(let message):
          if retryPolicy.registerFailure() {
            continue
          }
          await stopLoadedLatency(loadedLatencyTask)
          return .failure(message)
        case .success(let bitsPerSecond, let latencyMilliseconds, let duration):
          retryPolicy.registerSuccess()
          groupDurations.append(duration)
          ledger.record(
            stage: group.stage,
            bitsPerSecond: bitsPerSecond,
            latency: latencyMilliseconds,
            duration: duration)
          sampleIndex += 1
          completedSamples += 1

          let stageValue = ledger.value(for: group.stage)
          await progress(
            WebsiteSpeedProgress(
              stage: group.stage,
              completedSamples: completedSamples,
              totalSamples: WebsiteSpeedPlan.totalSampleCount,
              stageValue: stageValue,
              displayPercent: 3))
        }
      }
      await stopLoadedLatency(loadedLatencyTask)

      if !group.bypassFinishThreshold,
        let fastestDuration = groupDurations.min(),
        fastestDuration > WebsiteSpeedPlan.bandwidthFinishRequestDuration
      {
        if group.stage == .download { stopDownload = true }
        if group.stage == .upload { stopUpload = true }
      }
    }

    guard let result = ledger.result else {
      return .failure("有效样本不足，请稍后重试")
    }
    return .success(result)
  }

  private var isPaused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return paused
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  private func waitUntilRunnable() async -> Bool {
    while true {
      let (cancelled, paused) = stateSnapshot()
      if cancelled || Task.isCancelled { return false }
      if !paused { return true }
      try? await Task.sleep(nanoseconds: 80_000_000)
    }
  }

  private func stateSnapshot() -> (cancelled: Bool, paused: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (cancelled, paused)
  }

  private func setCurrentRequest(_ request: WebsiteSpeedRequest) -> Int {
    lock.lock()
    currentRequest = request
    let requestPauseEpoch = pauseEpoch
    let shouldCancel = cancelled || paused
    lock.unlock()
    if shouldCancel { request.cancel() }
    return requestPauseEpoch
  }

  private func finishCurrentRequest(
    _ request: WebsiteSpeedRequest,
    startedAtPauseEpoch: Int
  ) -> WebsiteSpeedRequestDisposition {
    lock.lock()
    if currentRequest === request { currentRequest = nil }
    let disposition = WebsiteSpeedRequestDisposition.resolve(
      startedAtPauseEpoch: startedAtPauseEpoch,
      currentPauseEpoch: pauseEpoch,
      isPaused: paused,
      isCancelled: cancelled)
    lock.unlock()
    return disposition
  }

  private func startLoadedLatency(for stage: WebsiteSpeedStage) -> Task<Void, Never>? {
    guard stage == .download || stage == .upload else { return nil }
    return Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000)
      var retryPolicy = WebsiteSpeedRetryPolicy()
      while let self, !Task.isCancelled {
        guard await self.waitUntilRunnable() else { return }
        let request = WebsiteSpeedRequest(
          sessionPool: sessionPool,
          stage: .latency,
          bytes: 0,
          duringLoad: stage)
        self.setCurrentLoadedLatencyRequest(request)
        let outcome = await request.run()
        self.clearCurrentLoadedLatencyRequest(request)
        if self.isCancelled || Task.isCancelled { return }
        if self.isPaused { continue }
        switch outcome {
        case .cancelled:
          continue
        case .failure:
          if retryPolicy.registerFailure() { continue }
          return
        case .success:
          retryPolicy.registerSuccess()
        }
        do {
          try await Task.sleep(
            nanoseconds: WebsiteSpeedPlan.loadedLatencyThrottleNanoseconds)
        } catch {
          return
        }
      }
    }
  }

  private func stopLoadedLatency(_ task: Task<Void, Never>?) async {
    task?.cancel()
    currentLoadedLatencyRequestSnapshot()?.cancel()
    await task?.value
  }

  private func currentLoadedLatencyRequestSnapshot() -> WebsiteSpeedRequest? {
    lock.lock()
    defer { lock.unlock() }
    return currentLoadedLatencyRequest
  }

  private func setCurrentLoadedLatencyRequest(_ request: WebsiteSpeedRequest) {
    lock.lock()
    currentLoadedLatencyRequest = request
    let shouldCancel = cancelled || paused
    lock.unlock()
    if shouldCancel { request.cancel() }
  }

  private func clearCurrentLoadedLatencyRequest(_ request: WebsiteSpeedRequest) {
    lock.lock()
    if currentLoadedLatencyRequest === request { currentLoadedLatencyRequest = nil }
    lock.unlock()
  }
}

enum CodexConnectivityContract {
  static let endpoint = URL(string: "https://api.openai.com/v1/models")!
  static let method = "GET"
  static let rounds = 4
  static let roundTimeout: TimeInterval = 3.5

  static func outcome(forHTTPStatus statusCode: Int) -> CodexConnectivityOutcome {
    CodexConnectivitySample.classifyHTTPStatus(statusCode)
  }
}

private final class CodexConnectivityHeaderRequest: ProbeURLSessionTaskHandler,
  @unchecked Sendable
{
  private let sessionPool: ProbeURLSessionPool
  private let round: Int
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CodexConnectivitySample?, Never>?
  private var task: URLSessionDataTask?
  private var timeoutWorkItem: DispatchWorkItem?
  private var startedAt: TimeInterval = 0
  private var finished = false
  private var cancellationRequested = false

  init(sessionPool: ProbeURLSessionPool, round: Int) {
    self.sessionPool = sessionPool
    self.round = round
  }

  func run() async -> CodexConnectivitySample? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        if cancellationRequested {
          lock.unlock()
          continuation.resume(returning: nil)
          return
        }
        self.continuation = continuation
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        var request = URLRequest(
          url: CodexConnectivityContract.endpoint,
          cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
          timeoutInterval: CodexConnectivityContract.roundTimeout)
        request.httpMethod = CodexConnectivityContract.method
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        guard let task = sessionPool.dataTask(with: request, handler: self) else {
          complete(nil, cancelRequest: false)
          return
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
          self?.complete(.timeout(round: self?.round ?? 0), cancelRequest: true)
        }

        lock.lock()
        let shouldStart = !finished && !cancellationRequested
        if shouldStart {
          self.task = task
          self.timeoutWorkItem = timeoutWorkItem
        }
        lock.unlock()

        guard shouldStart else {
          task.cancel()
          sessionPool.unregister(taskIdentifier: task.taskIdentifier)
          return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
          deadline: .now() + CodexConnectivityContract.roundTimeout,
          execute: timeoutWorkItem)
        task.resume()
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    lock.unlock()
    complete(nil, cancelRequest: true)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      complete(.networkFailure(round: round), cancelRequest: true)
      return
    }
    let latencyMilliseconds = Int(
      (max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
    completionHandler(.cancel)
    complete(
      .http(
        round: round,
        statusCode: response.statusCode,
        latencyMilliseconds: latencyMilliseconds),
      cancelRequest: true)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    lock.lock()
    let wasExternallyCancelled = cancellationRequested
    lock.unlock()
    if wasExternallyCancelled {
      complete(nil, cancelRequest: false)
    } else if (error as? URLError)?.code == .timedOut {
      complete(.timeout(round: round), cancelRequest: false)
    } else if error != nil {
      complete(.networkFailure(round: round), cancelRequest: false)
    }
  }

  private func complete(
    _ sample: CodexConnectivitySample?,
    cancelRequest: Bool
  ) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    let task = task
    self.task = nil
    let taskIdentifier = task?.taskIdentifier
    let timeoutWorkItem = timeoutWorkItem
    self.timeoutWorkItem = nil
    lock.unlock()

    timeoutWorkItem?.cancel()
    if cancelRequest { task?.cancel() }
    if let taskIdentifier { sessionPool.unregister(taskIdentifier: taskIdentifier) }
    continuation?.resume(returning: sample)
  }
}

final class CodexConnectivityProbe: @unchecked Sendable {
  private let sessionPool: ProbeURLSessionPool

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = CodexConnectivityContract.roundTimeout
    configuration.timeoutIntervalForResource = CodexConnectivityContract.roundTimeout
    configuration.allowsExpensiveNetworkAccess = true
    configuration.allowsConstrainedNetworkAccess = true
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    sessionPool = ProbeURLSessionPool(configuration: configuration)
  }

  func measure(round: Int) async -> CodexConnectivitySample? {
    await CodexConnectivityHeaderRequest(sessionPool: sessionPool, round: round).run()
  }

  func invalidate() {
    sessionPool.invalidateAndCancel()
  }
}

struct NetworkProbeFailure: Equatable, Sendable {
  let title: String
  let detail: String
}

enum CodexNetworkProbePhase: Equatable {
  case idle
  case networkRunning(WebsiteSpeedProgress)
  case networkPaused(WebsiteSpeedProgress)
  case networkFinished(WebsiteSpeedResult)
  case codexRunning(completedRounds: Int, samples: [CodexConnectivitySample])
  case codexFinished(CodexConnectivitySummary)
  case failed(NetworkProbeFailure)
}

@MainActor
final class CodexNetworkProbeController: ObservableObject {
  @Published private(set) var phases: [NetworkProbeDirection: CodexNetworkProbePhase] = [
    .domestic: .idle,
    .codex: .idle,
  ]

  private var isEnabled = false
  private var runIDs: [NetworkProbeDirection: Int] = [.domestic: 0, .codex: 0]
  private var runningTasks: [NetworkProbeDirection: Task<Void, Never>] = [:]
  private var websiteRunner: WebsiteSpeedTestRunner?
  private var networkProgressTask: Task<Void, Never>?

  nonisolated init() {}

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    if !enabled { cancelAll() }
  }

  func phase(for requestedDirection: NetworkProbeDirection) -> CodexNetworkProbePhase {
    phases[NetworkProbeDirection.customerFacing(requestedDirection)] ?? .idle
  }

  var isRunning: Bool {
    NetworkProbeDirection.customerChoices.contains { isRunning($0) }
  }

  func isRunning(_ requestedDirection: NetworkProbeDirection) -> Bool {
    switch phase(for: requestedDirection) {
    case .networkRunning, .codexRunning: return true
    default: return false
    }
  }

  func toggle(_ requestedDirection: NetworkProbeDirection) {
    guard isEnabled else { return }
    let direction = NetworkProbeDirection.customerFacing(requestedDirection)
    switch (direction, phase(for: direction)) {
    case (.domestic, .networkRunning(let progress)):
      websiteRunner?.pause()
      networkProgressTask?.cancel()
      networkProgressTask = nil
      phases[.domestic] = .networkPaused(progress)
    case (.domestic, .networkPaused(let progress)):
      websiteRunner?.resume()
      phases[.domestic] = .networkRunning(progress)
      startNetworkProgressAnimation(runID: runIDs[.domestic, default: 0])
    case (.codex, .codexRunning):
      return
    case (.domestic, _):
      startNetworkSpeed()
    case (.codex, _):
      startCodexConnectivity()
    case (.international, _):
      startNetworkSpeed()
    }
  }

  func start(_ requestedDirection: NetworkProbeDirection) {
    let direction = NetworkProbeDirection.customerFacing(requestedDirection)
    if direction == .domestic { startNetworkSpeed() } else { startCodexConnectivity() }
  }

  func cancelAll() {
    websiteRunner?.cancel()
    websiteRunner = nil
    networkProgressTask?.cancel()
    networkProgressTask = nil
    for direction in NetworkProbeDirection.customerChoices {
      runningTasks[direction]?.cancel()
      runningTasks[direction] = nil
      runIDs[direction, default: 0] += 1
      phases[direction] = .idle
    }
  }

  private func startNetworkSpeed() {
    cancel(.domestic)
    let runID = nextRunID(for: .domestic)
    let runner = WebsiteSpeedTestRunner()
    websiteRunner = runner
    phases[.domestic] = .networkRunning(
      WebsiteSpeedProgress(
        stage: .latency,
        completedSamples: 0,
        totalSamples: WebsiteSpeedPlan.totalSampleCount,
        stageValue: nil,
        displayPercent: 3))
    startNetworkProgressAnimation(runID: runID)

    runningTasks[.domestic] = Task { @MainActor [weak self] in
      let outcome = await runner.run { progress in
        guard let self, self.stillActive(.domestic, runID: runID) else { return }
        let displayPercent = self.currentNetworkDisplayPercent
        let displayedProgress = progress.withDisplayPercent(displayPercent)
        if case .networkPaused = self.phases[.domestic] {
          self.phases[.domestic] = .networkPaused(displayedProgress)
        } else {
          self.phases[.domestic] = .networkRunning(displayedProgress)
        }
      }
      guard let self, stillActive(.domestic, runID: runID) else { return }
      websiteRunner = nil
      runningTasks[.domestic] = nil
      networkProgressTask?.cancel()
      networkProgressTask = nil
      switch outcome {
      case .success(let result):
        phases[.domestic] = .networkFinished(result)
      case .failure(let detail):
        phases[.domestic] = .failed(
          NetworkProbeFailure(title: "测速失败", detail: detail))
      case .cancelled:
        break
      }
    }
  }

  private func startCodexConnectivity() {
    cancel(.codex)
    let runID = nextRunID(for: .codex)
    phases[.codex] = .codexRunning(completedRounds: 0, samples: [])

    runningTasks[.codex] = Task { @MainActor [weak self] in
      let probe = CodexConnectivityProbe()
      defer { probe.invalidate() }
      var samples: [CodexConnectivitySample] = []
      for round in 1...CodexConnectivityContract.rounds {
        guard let self, stillActive(.codex, runID: runID), !Task.isCancelled else {
          return
        }
        guard let sample = await probe.measure(round: round) else { return }
        guard stillActive(.codex, runID: runID), !Task.isCancelled else { return }
        samples.append(sample)
        phases[.codex] = .codexRunning(
          completedRounds: samples.count,
          samples: samples)
      }

      guard let self, self.stillActive(.codex, runID: runID), !Task.isCancelled else {
        return
      }
      self.runningTasks[.codex] = nil
      self.phases[.codex] = .codexFinished(
        CodexConnectivitySummary.make(samples: samples))
    }
  }

  private func cancel(_ direction: NetworkProbeDirection) {
    runningTasks[direction]?.cancel()
    runningTasks[direction] = nil
    if direction == .domestic {
      websiteRunner?.cancel()
      websiteRunner = nil
      networkProgressTask?.cancel()
      networkProgressTask = nil
    }
    runIDs[direction, default: 0] += 1
  }

  private func nextRunID(for direction: NetworkProbeDirection) -> Int {
    runIDs[direction, default: 0] += 1
    return runIDs[direction, default: 0]
  }

  private func stillActive(_ direction: NetworkProbeDirection, runID: Int) -> Bool {
    runIDs[direction] == runID
  }

  private var currentNetworkDisplayPercent: Double {
    switch phases[.domestic] {
    case .networkRunning(let progress), .networkPaused(let progress):
      return progress.displayPercent
    default:
      return 3
    }
  }

  private func startNetworkProgressAnimation(runID: Int) {
    networkProgressTask?.cancel()
    networkProgressTask = Task { @MainActor [weak self] in
      while let self, self.stillActive(.domestic, runID: runID) {
        do {
          try await Task.sleep(nanoseconds: 320_000_000)
        } catch {
          return
        }
        guard self.stillActive(.domestic, runID: runID) else { return }
        guard case .networkRunning(let progress) = self.phases[.domestic] else {
          continue
        }
        self.phases[.domestic] = .networkRunning(
          progress.withDisplayPercent(
            WebsiteSpeedProgress.nextDisplayPercent(after: progress.displayPercent)))
      }
    }
  }
}

enum NetworkProbeVisualTone: Equatable {
  case brand
  case latency
  case download
  case upload
  case paused
  case success
  case warning
  case failure

  var color: Color {
    switch self {
    case .brand: return Color(red: 107 / 255, green: 35 / 255, blue: 142 / 255)
    case .latency: return Color(red: 23 / 255, green: 19 / 255, blue: 28 / 255)
    case .download: return Color(red: 23 / 255, green: 105 / 255, blue: 224 / 255)
    case .upload: return Color(red: 216 / 255, green: 86 / 255, blue: 79 / 255)
    case .paused: return Color(red: 95 / 255, green: 88 / 255, blue: 102 / 255)
    case .success: return Color(red: 35 / 255, green: 122 / 255, blue: 75 / 255)
    case .warning: return Color(red: 164 / 255, green: 93 / 255, blue: 10 / 255)
    case .failure: return Color(red: 179 / 255, green: 38 / 255, blue: 30 / 255)
    }
  }
}

struct CodexNetworkProbeWindowRoot: View {
  @ObservedObject var controller: CodexNetworkProbeController

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 16) {
          windowHeader
          HStack(spacing: proxy.size.width < 650 ? 14 : 24) {
            sphere(.domestic)
            sphere(.codex)
          }
          .frame(maxWidth: .infinity)

          if case .networkFinished(let result) = controller.phase(for: .domestic) {
            NetworkSpeedMetricStrip(result: result)
          }

          methodNote
        }
        .padding(.horizontal, proxy.size.width < 650 ? 18 : 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { controller.setEnabled(true) }
    .onDisappear { controller.cancelAll() }
  }

  private var windowHeader: some View {
    VStack(spacing: 5) {
      Text("测试网速")
        .font(.system(size: 28, weight: .bold))
      Text("点击一个球开始测试；网速球测试中再次点击可暂停。")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }

  private func sphere(_ direction: NetworkProbeDirection) -> some View {
    NetworkProbeSphere(
      direction: direction,
      phase: controller.phase(for: direction)
    ) {
      controller.toggle(direction)
    }
  }

  private var methodNote: some View {
    Text("网速测试会按当前线路自适应取样；Codex 只检测 OpenAI 连通与响应，不运行任务。")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct NetworkSpeedMetricStrip: View {
  let result: WebsiteSpeedResult

  var body: some View {
    HStack(spacing: 0) {
      metric("下载", value: wholeNumber(result.downloadMbps), unit: "Mbps")
      divider
      metric("上传", value: wholeNumber(result.uploadMbps), unit: "Mbps")
      divider
      metric("延迟", value: wholeNumber(result.latencyMilliseconds), unit: "ms")
      divider
      metric("抖动", value: decimal(result.jitterMilliseconds), unit: "ms")
    }
    .padding(.vertical, 10)
    .frame(maxWidth: 600)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "下载 \(wholeNumber(result.downloadMbps)) 兆每秒，上传 \(wholeNumber(result.uploadMbps)) 兆每秒，延迟 \(wholeNumber(result.latencyMilliseconds)) 毫秒，抖动 \(decimal(result.jitterMilliseconds)) 毫秒"
    )
  }

  private var divider: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor).opacity(0.55))
      .frame(width: 1, height: 30)
  }

  private func metric(_ title: String, value: String, unit: String) -> some View {
    VStack(spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text(value)
          .font(.system(size: 17, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text(unit)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func wholeNumber(_ value: Double) -> String {
    String(Int(value.rounded()))
  }

  private func decimal(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}

private struct NetworkProbeSphere: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let direction: NetworkProbeDirection
  let phase: CodexNetworkProbePhase
  let action: () -> Void

  private let size: CGFloat = 240

  private var progress: Double {
    switch phase {
    case .networkRunning(let progress), .networkPaused(let progress):
      return progress.fraction
    case .codexRunning(let completedRounds, _):
      return Double(completedRounds) / Double(CodexConnectivityContract.rounds)
    case .networkFinished, .codexFinished:
      return 1
    case .idle, .failed:
      return 0
    }
  }

  private var tone: NetworkProbeVisualTone {
    switch phase {
    case .idle: return .brand
    case .networkRunning(let progress):
      switch progress.stage {
      case .latency: return .latency
      case .download: return .download
      case .upload: return .upload
      }
    case .networkPaused: return .paused
    case .networkFinished: return .brand
    case .codexRunning: return .brand
    case .codexFinished(let summary):
      switch summary.state {
      case .green: return .success
      case .yellow: return .warning
      case .red: return .failure
      }
    case .failed: return .failure
    }
  }

  private var codexIsRunning: Bool {
    direction == .codex
      && {
        if case .codexRunning = phase { return true }
        return false
      }()
  }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(Circle().fill(tone.color.opacity(0.06)))
          .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)

        Circle()
          .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 6)
          .padding(6)

        if progress > 0 {
          Circle()
            .trim(from: 0, to: progress)
            .stroke(tone.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(6)
        } else {
          Circle()
            .stroke(tone.color.opacity(0.38), lineWidth: 2)
            .padding(8)
        }

        content
          .padding(24)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(codexIsRunning)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: tone)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(accessibilityHint)
    .help(accessibilityHint)
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .idle:
      if direction == .codex {
        VStack(spacing: 9) {
          Text("Codex connectivity")
            .font(.caption.weight(.semibold))
          Text("检测连接")
            .font(.system(size: 27, weight: .bold))
            .foregroundStyle(tone.color)
          Text(direction.subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
          actionLabel("点击检测", systemImage: "play.fill")
        }
      } else {
        VStack(spacing: 9) {
          Text("准备就绪")
            .font(.caption.weight(.semibold))
          Text("开始测速")
            .font(.system(size: 27, weight: .bold))
            .foregroundStyle(tone.color)
          Text("约需 15 秒")
            .font(.callout)
            .foregroundStyle(.secondary)
          actionLabel("点击测速", systemImage: "play.fill")
        }
      }
    case .networkRunning(let progress):
      networkProgress(progress, paused: false)
    case .networkPaused(let progress):
      networkProgress(progress, paused: true)
    case .networkFinished(let result):
      VStack(spacing: 7) {
        Text("测速完成")
          .font(.caption.weight(.semibold))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(roundedNumber(result.downloadMbps))
            .font(.system(size: 43, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("Mbps")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tone.color)
        Text("下载")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("上传 \(roundedNumber(result.uploadMbps)) Mbps")
          .font(.caption.weight(.semibold))
        actionLabel("再测一次", systemImage: "arrow.clockwise")
      }
    case .codexRunning(let completedRounds, _):
      VStack(spacing: 9) {
        Text("正在检测第 \(min(4, completedRounds + 1)) 轮")
          .font(.caption.weight(.semibold))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("\(completedRounds)")
            .font(.system(size: 46, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("/ 4")
            .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(tone.color)
        Text("按顺序连接 OpenAI")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    case .codexFinished(let summary):
      VStack(spacing: 8) {
        Text("Codex connectivity")
          .font(.caption.weight(.semibold))
        Text(summary.title)
          .font(.system(size: 25, weight: .bold))
          .foregroundStyle(tone.color)
        Text(summary.metricText)
          .font(.system(.callout, design: .rounded).monospacedDigit())
        Text("最近失败：\(summary.latestFailureText)")
          .font(.caption)
          .foregroundStyle(.secondary)
        actionLabel("再测一次", systemImage: "arrow.clockwise")
      }
    case .failed(let failure):
      if direction == .domestic {
        VStack(spacing: 8) {
          Text("测速未完成")
            .font(.caption.weight(.semibold))
          Text("请重试")
            .font(.system(size: 27, weight: .bold))
            .foregroundStyle(tone.color)
          actionLabel("重新测速", systemImage: "arrow.clockwise")
        }
      } else {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 27))
            .foregroundStyle(tone.color)
          Text(failure.title)
            .font(.system(size: 22, weight: .bold))
          Text(failure.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          actionLabel("重新测试", systemImage: "arrow.clockwise")
        }
      }
    }
  }

  private func networkProgress(_ progress: WebsiteSpeedProgress, paused: Bool) -> some View {
    VStack(spacing: 9) {
      Text(paused ? "已暂停" : progress.stage.title)
        .font(.caption.weight(.semibold))
      if let value = progress.stageValue {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(roundedNumber(value))
            .font(.system(size: 43, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text(progress.stage == .latency ? "ms" : "Mbps")
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tone.color)
      } else {
        Text("校准中")
          .font(.system(size: 43, weight: .bold, design: .rounded))
          .foregroundStyle(tone.color)
      }
      if progress.stageValue == nil {
        Text("保留当前结果")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      actionLabel(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
    }
  }

  private func actionLabel(_ text: String, systemImage: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .font(.system(size: 10, weight: .bold))
      Text(text)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(tone.color)
    .padding(.top, 2)
  }

  private func speed(_ value: Double) -> String {
    value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
  }

  private func roundedNumber(_ value: Double) -> String {
    String(Int(value.rounded()))
  }

  private func milliseconds(_ value: Double) -> String {
    String(Int(value.rounded()))
  }

  private var accessibilityLabel: String {
    switch (direction, phase) {
    case (.codex, .idle), (.codex, .codexFinished), (.codex, .failed):
      return "开始或重新检测 Codex 连接，共 4 轮"
    case (.domestic, .idle), (.domestic, .networkFinished), (.domestic, .failed):
      return "开始或重新测试网络速度"
    default:
      return direction.title
    }
  }

  private var accessibilityValue: String {
    switch phase {
    case .idle:
      return "准备就绪"
    case .networkRunning(let progress):
      return "\(progress.stage.title)，已完成 \(progress.completedSamples) 项"
    case .networkPaused(let progress):
      return "已暂停，当前阶段 \(progress.stage.title)"
    case .networkFinished(let result):
      return "下载 \(speed(result.downloadMbps)) 兆每秒，上传 \(speed(result.uploadMbps)) 兆每秒"
    case .codexRunning(let completedRounds, _):
      return "进行中，已完成 \(completedRounds) / 4 轮"
    case .codexFinished(let summary):
      return "\(summary.title)，\(summary.reachableCount) / 4 轮可达，最近失败：\(summary.latestFailureText)"
    case .failed(let failure):
      if direction == .domestic {
        return "测速未完成，请重试"
      }
      return "\(failure.title)，\(failure.detail)"
    }
  }

  private var accessibilityHint: String {
    switch phase {
    case .networkRunning:
      return "暂停本次网络测速"
    case .networkPaused:
      return "继续本次网络测速"
    case .codexRunning:
      return "Codex 连接检测正在进行"
    default:
      return "点击开始测试"
    }
  }
}
