import AppKit
import Foundation
import SwiftUI

/// 客户界面只保留网页上的两个球。
/// `international` 仅用于读取旧设置，映射为 Codex 连接，不再单列入口。
enum NetworkProbeDirection: String, CaseIterable, Codable, Identifiable {
  case domestic
  case international
  case codex

  var id: String { rawValue }

  static let customerChoices: [NetworkProbeDirection] = [.domestic, .codex]

  static func customerFacing(_ stored: NetworkProbeDirection?) -> NetworkProbeDirection {
    stored == .domestic ? .domestic : .codex
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
    case .domestic, .international: return "Cloudflare · 当前线路"
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
    case .latency: return "正在准备测速"
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

/// 同一测量窗口内并发传输，避免单个请求限制带宽采样。
enum WebsiteSpeedPlan {
  static let concurrentTransfers = 4
  static let bandwidthFinishRequestDuration: TimeInterval = 1.2
  static let bandwidthMinimumRequestDuration: TimeInterval = 0.01
  static let estimatedServerTimeMilliseconds: Double = 10
  static let maximumConsecutiveRetries = 4
  static let requestTimeout: TimeInterval = 15
  static let maximumWallClockDuration: TimeInterval = 75
  static let maximumDownloadBytesIncludingRetries = 320_000_000
  static let maximumUploadBytesIncludingRetries = 192_000_000
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
      stage: .download, bytes: 8_000_000, count: 2, bypassFinishThreshold: false),
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
    .reduce(0) { $0 + ($1.bytes * $1.count * concurrentTransfers) }
  static let maximumPlannedUploadBytes =
    groups
    .filter { $0.stage == .upload }
    .reduce(0) { $0 + ($1.bytes * $1.count * concurrentTransfers) }

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
  let completedDownloadMbps: Double?
  let pauseEpoch: Int
  var displayUnit: String? = nil

  /// Batch resets belong to measurement, not to the visible readout. Never carry
  /// a download value into upload, and never replace an observed zero with a held value.
  func retainingReadout(from previous: WebsiteSpeedProgress?) -> WebsiteSpeedProgress {
    let previous = previous?.stage == stage ? previous : nil
    let validValue = stageValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    let value = validValue ?? previous?.stageValue
    let display = WebsiteSpeedDisplay.rate(value, holdingUnit: previous?.displayUnit)
    return WebsiteSpeedProgress(
      stage: stage, completedSamples: completedSamples, totalSamples: totalSamples,
      stageValue: value, completedDownloadMbps: completedDownloadMbps,
      pauseEpoch: pauseEpoch, displayUnit: display.unit.isEmpty ? nil : display.unit)
  }

  var fraction: Double {
    guard totalSamples > 0 else { return 0 }
    return min(1, max(0, Double(completedSamples) / Double(totalSamples)))
  }
}

/// A batch owns this counter. Delegates only record bytes; a 250 ms task samples
/// the shared monotonic clock, so concurrent request rates are never added.
final class WebsiteSpeedLiveMeter: @unchecked Sendable {
  static let intervalNanoseconds: UInt64 = 250_000_000
  private let lock = NSLock()
  private var bytesByRequest: [Int: Int64] = [:]
  private var observations: [(time: TimeInterval, bytes: Int64)]
  private var closed = false

  init(startedAt: TimeInterval) {
    observations = [(startedAt, 0)]
  }

  func record(totalBytes: Int64, requestID: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, totalBytes >= 0 else { return }
    bytesByRequest[requestID] = max(bytesByRequest[requestID, default: 0], totalBytes)
  }

  func sample(at now: TimeInterval) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, now.isFinite, let last = observations.last, now > last.time else {
      return nil
    }
    let bytes = bytesByRequest.values.reduce(Int64(0), +)
    observations.append((now, bytes))
    // Retain the sample immediately preceding the one-second window boundary.
    while observations.count > 2, observations[1].time <= now - 1 {
      observations.removeFirst()
    }
    guard bytes > 0, let first = observations.first else { return nil }
    return Double(bytes - first.bytes) * 8 / (now - first.time) / 1_000_000
  }

  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }
}

struct WebsiteSpeedDisplay: Equatable {
  let value: String
  let unit: String
  private let spokenUnit: String

  var text: String { unit.isEmpty ? value : "\(value) \(unit)" }
  var accessibilityText: String {
    unit.isEmpty ? "待测" : "\(value == "<1" ? "不足1" : value)\(spokenUnit)每秒"
  }

  /// Match the status bar's decimal byte units; keep one decimal in the larger sphere.
  static func rate(_ mbps: Double?, holdingUnit: String? = nil) -> WebsiteSpeedDisplay {
    guard let mbps, mbps.isFinite, mbps >= 0 else {
      return WebsiteSpeedDisplay(value: "—", unit: "", spokenUnit: "")
    }
    let bytesPerSecond = mbps * 125_000
    guard bytesPerSecond.isFinite else {
      return WebsiteSpeedDisplay(value: "—", unit: "", spokenUnit: "")
    }
    // A narrow dead band keeps live values near a unit boundary from alternating
    // KB/s and MB/s. Final results call this without holdingUnit.
    let units: [(name: String, divisor: Double, spoken: String)] = [
      ("B/s", 1, "字节"), ("KB/s", 1_000, "千字节"),
      ("MB/s", 1_000_000, "兆字节"), ("GB/s", 1_000_000_000, "吉字节"),
    ]
    if let index = units.firstIndex(where: { $0.name == holdingUnit }),
      bytesPerSecond >= (index == 0 ? 0 : units[index].divisor * 0.9),
      index == units.count - 1 || bytesPerSecond < units[index + 1].divisor * 1.1
    {
      let unit = units[index]
      return WebsiteSpeedDisplay(
        value: bytesPerSecond > 0 && bytesPerSecond < 1
          ? "<1"
          : String(format: index < 2 ? "%.0f" : "%.1f", bytesPerSecond / unit.divisor),
        unit: unit.name, spokenUnit: unit.spoken)
    }
    if bytesPerSecond >= 1_000_000_000 {
      return WebsiteSpeedDisplay(
        value: String(format: "%.1f", bytesPerSecond / 1_000_000_000),
        unit: "GB/s", spokenUnit: "吉字节")
    }
    if bytesPerSecond >= 1_000_000 {
      return WebsiteSpeedDisplay(
        value: String(format: "%.1f", bytesPerSecond / 1_000_000),
        unit: "MB/s", spokenUnit: "兆字节")
    }
    if bytesPerSecond >= 1_000 {
      return WebsiteSpeedDisplay(
        value: String(format: "%.0f", min((bytesPerSecond / 1_000).rounded(), 999)),
        unit: "KB/s", spokenUnit: "千字节")
    }
    return WebsiteSpeedDisplay(
      value: bytesPerSecond > 0 && bytesPerSecond < 1
        ? "<1" : String(format: "%.0f", min(bytesPerSecond.rounded(), 999)),
      unit: "B/s", spokenUnit: "字节")
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
    guard !downloadBitsPerSecond.isEmpty, !uploadBitsPerSecond.isEmpty,
      downloadBitsPerSecond.allSatisfy({ $0.isFinite && $0 > 0 }),
      uploadBitsPerSecond.allSatisfy({ $0.isFinite && $0 > 0 })
    else { return nil }
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

  func failure(_ detail: String, during stage: WebsiteSpeedStage) -> WebsiteSpeedRunOutcome {
    .failure(detail, completedDownloadMbps: stage == .upload ? value(for: .download) : nil)
  }

  var result: WebsiteSpeedResult? {
    WebsiteSpeedResult.make(
      latencyMilliseconds: latencyMilliseconds,
      downloadBitsPerSecond: downloadBitsPerSecond,
      uploadBitsPerSecond: uploadBitsPerSecond)
  }
}

enum WebsiteSpeedRequestOutcome: Equatable, Sendable {
  case success(bitsPerSecond: Double?, latencyMilliseconds: Double, duration: TimeInterval)
  case failure(String)
  case httpFailure(Int)
  case cancelled
}

enum WebsiteSpeedBatch {
  static func aggregate(
    _ outcomes: [WebsiteSpeedRequestOutcome],
    stage: WebsiteSpeedStage,
    wallDuration: TimeInterval
  ) -> WebsiteSpeedRequestOutcome {
    guard !outcomes.isEmpty else { return .failure("没有取得测速样本") }
    if outcomes.contains(.cancelled) { return .cancelled }
    var transferredBits = 0.0
    var latencies: [Double] = []
    for outcome in outcomes {
      switch outcome {
      case .failure(let message): return .failure(message)
      case .httpFailure(let status): return .httpFailure(status)
      case .cancelled: return .cancelled
      case .success(let rate, let latency, let duration):
        latencies.append(latency)
        if stage != .latency {
          guard let rate, rate.isFinite, rate > 0, duration.isFinite, duration > 0 else {
            return .failure("有效传输样本不足，请重试")
          }
          transferredBits += rate * duration
        }
      }
    }
    if stage == .latency { return outcomes[0] }
    guard wallDuration.isFinite, wallDuration > 0, transferredBits.isFinite else {
      return .failure("测速计时无效，请重试")
    }
    // 并发请求的速率不能直接相加；字节总量必须除以共同的实际耗时。
    return .success(
      bitsPerSecond: transferredBits / wallDuration,
      latencyMilliseconds: NetworkProbeStatistics.median(latencies) ?? 0,
      duration: wallDuration)
  }
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
  private let byteProgress: (@Sendable (Int64) -> Void)?
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
    timeout: TimeInterval = WebsiteSpeedPlan.requestTimeout,
    byteProgress: (@Sendable (Int64) -> Void)? = nil
  ) {
    self.sessionPool = sessionPool
    self.stage = stage
    expectedBytes = bytes
    self.duringLoad = duringLoad
    self.timeout = timeout
    self.byteProgress = byteProgress
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
    guard !finished, !cancellationRequested else {
      lock.unlock()
      return
    }
    receivedBodyBytes += Int64(data.count)
    let bytes = receivedBodyBytes
    lock.unlock()
    if stage == .download { byteProgress?(bytes) }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    lock.lock()
    guard !finished, !cancellationRequested else {
      lock.unlock()
      return
    }
    sentBodyBytes = max(sentBodyBytes, totalBytesSent)
    lastBodySendAt = ProcessInfo.processInfo.systemUptime
    let bytes = sentBodyBytes
    lock.unlock()
    if stage == .upload { byteProgress?(bytes) }
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
    if WebsiteSpeedHTTPStatus.failureDescription(response.statusCode) != nil {
      complete(.httpFailure(response.statusCode))
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
  case failure(String, completedDownloadMbps: Double? = nil)
  case cancelled
}

final class WebsiteSpeedTestRunner: @unchecked Sendable {
  private let sessionPool: ProbeURLSessionPool
  private let now: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var paused = false
  private var cancelled = false
  private var pauseEpoch = 0
  private var currentRequests: [WebsiteSpeedRequest] = []
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
    configuration.httpMaximumConnectionsPerHost = WebsiteSpeedPlan.concurrentTransfers + 1
    // 带宽测试测本机直连；Codex 连接仍沿用用户的系统代理。
    // 不改系统设置，VPN/透明网关仍由系统路由决定。
    configuration.connectionProxyDictionary = [:]
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
    let requests = currentRequests
    let loadedLatencyRequest = currentLoadedLatencyRequest
    lock.unlock()
    requests.forEach { $0.cancel() }
    loadedLatencyRequest?.cancel()
  }

  /// Checked again on the main actor immediately before publishing a live value.
  /// A callback queued before pause must not become current after resume.
  func acceptsProgress(pauseEpoch expectedEpoch: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !cancelled && !paused && pauseEpoch == expectedEpoch
  }

  private var currentPauseEpoch: Int {
    lock.lock()
    defer { lock.unlock() }
    return pauseEpoch
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
    let requests = currentRequests
    let loadedLatencyRequest = currentLoadedLatencyRequest
    lock.unlock()
    requests.forEach { $0.cancel() }
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
        return ledger.failure(
          "测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止", during: group.stage)
      }
      if (group.stage == .download && stopDownload)
        || (group.stage == .upload && stopUpload)
      {
        continue
      }

      ledger.begin(group)
      let valueAtGroupStart = group.stage == .latency ? ledger.value(for: .latency) : nil
      await progress(
        WebsiteSpeedProgress(
          stage: group.stage,
          completedSamples: completedSamples,
          totalSamples: WebsiteSpeedPlan.totalSampleCount,
          stageValue: valueAtGroupStart,
          completedDownloadMbps: group.stage == .upload ? ledger.value(for: .download) : nil,
          pauseEpoch: currentPauseEpoch))

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
          return ledger.failure(
            "测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止", during: group.stage)
        }
        let transferCount = group.stage == .latency ? 1 : WebsiteSpeedPlan.concurrentTransfers
        guard transferBudget.reserve(stage: group.stage, bytes: group.bytes * transferCount) else {
          await stopLoadedLatency(loadedLatencyTask)
          return ledger.failure("测速已达到本次流量上限，已自动停止", during: group.stage)
        }

        let requestPauseEpoch = currentPauseEpoch
        let liveCompletedSamples = completedSamples
        let completedDownload = group.stage == .upload ? ledger.value(for: .download) : nil
        // Clear the previous batch before starting the next transfer window.
        await progress(
          WebsiteSpeedProgress(
            stage: group.stage,
            completedSamples: completedSamples,
            totalSamples: WebsiteSpeedPlan.totalSampleCount,
            stageValue: nil,
            completedDownloadMbps: completedDownload,
            pauseEpoch: requestPauseEpoch))
        guard acceptsProgress(pauseEpoch: requestPauseEpoch) else { continue }
        let batchStartedAt = now()
        let liveMeter = WebsiteSpeedLiveMeter(startedAt: batchStartedAt)
        let requests = (0..<transferCount).map { requestID in
          WebsiteSpeedRequest(
            sessionPool: sessionPool,
            stage: group.stage,
            bytes: group.bytes,
            timeout: requestTimeout,
            byteProgress: { liveMeter.record(totalBytes: $0, requestID: requestID) })
        }
        setCurrentRequests(requests, expectedPauseEpoch: requestPauseEpoch)
        let liveProgressTask: Task<Void, Never>? =
          group.stage == .latency
          ? nil
          : Task {
            while !Task.isCancelled {
              do {
                try await Task.sleep(nanoseconds: WebsiteSpeedLiveMeter.intervalNanoseconds)
              } catch { return }
              guard !Task.isCancelled, self.acceptsProgress(pauseEpoch: requestPauseEpoch),
                let value = liveMeter.sample(at: self.now())
              else { continue }
              await progress(
                WebsiteSpeedProgress(
                  stage: group.stage,
                  completedSamples: liveCompletedSamples,
                  totalSamples: WebsiteSpeedPlan.totalSampleCount,
                  stageValue: value,
                  completedDownloadMbps: completedDownload,
                  pauseEpoch: requestPauseEpoch))
            }
          }
        let outcomes = await withTaskGroup(of: WebsiteSpeedRequestOutcome.self) { batch in
          for request in requests { batch.addTask { await request.run() } }
          var results: [WebsiteSpeedRequestOutcome] = []
          for await outcome in batch { results.append(outcome) }
          return results
        }
        // Freeze transfer time before draining a potentially queued main-actor update.
        let batchFinishedAt = now()
        let lastLiveValue = liveMeter.sample(at: batchFinishedAt)
        liveMeter.close()
        liveProgressTask?.cancel()
        await liveProgressTask?.value
        let outcome = WebsiteSpeedBatch.aggregate(
          outcomes, stage: group.stage, wallDuration: batchFinishedAt - batchStartedAt)
        let disposition = finishCurrentRequests(startedAtPauseEpoch: requestPauseEpoch)

        if disposition == .cancel || Task.isCancelled {
          await stopLoadedLatency(loadedLatencyTask)
          return .cancelled
        }
        if disposition == .retry { continue }
        guard deadline.remaining(at: now()) > 0 else {
          await stopLoadedLatency(loadedLatencyTask)
          return ledger.failure(
            "测速已超过 \(Int(WebsiteSpeedPlan.maximumWallClockDuration)) 秒，已自动停止", during: group.stage)
        }

        switch outcome {
        case .cancelled:
          // 用户暂停已由 pauseEpoch 接续；其他取消不能无休止消耗流量预算。
          await stopLoadedLatency(loadedLatencyTask)
          return ledger.failure("网络中断了测速，请重试", during: group.stage)
        case .httpFailure(let status):
          if status == 429 || status >= 500, retryPolicy.registerFailure() { continue }
          await stopLoadedLatency(loadedLatencyTask)
          return ledger.failure(
            WebsiteSpeedHTTPStatus.failureDescription(status) ?? "测速节点响应异常", during: group.stage)
        case .failure(let message):
          if retryPolicy.registerFailure() {
            continue
          }
          await stopLoadedLatency(loadedLatencyTask)
          return ledger.failure(message, during: group.stage)
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

          let stageValue = group.stage == .latency ? ledger.value(for: .latency) : lastLiveValue
          await progress(
            WebsiteSpeedProgress(
              stage: group.stage,
              completedSamples: completedSamples,
              totalSamples: WebsiteSpeedPlan.totalSampleCount,
              stageValue: stageValue,
              completedDownloadMbps: completedDownload,
              pauseEpoch: requestPauseEpoch))
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
      return ledger.failure("有效样本不足，请稍后重试", during: .upload)
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

  private func setCurrentRequests(_ requests: [WebsiteSpeedRequest], expectedPauseEpoch: Int) {
    lock.lock()
    currentRequests = requests
    let shouldCancel = cancelled || paused || pauseEpoch != expectedPauseEpoch
    lock.unlock()
    if shouldCancel { requests.forEach { $0.cancel() } }
  }

  private func finishCurrentRequests(startedAtPauseEpoch: Int) -> WebsiteSpeedRequestDisposition {
    lock.lock()
    currentRequests = []
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
        case .httpFailure(let status):
          if status == 429 || status >= 500, retryPolicy.registerFailure() { continue }
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
  var completedDownloadMbps: Double? = nil
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
      phases[.domestic] = .networkPaused(progress)
    case (.domestic, .networkPaused(let progress)):
      websiteRunner?.resume()
      phases[.domestic] = .networkRunning(
        WebsiteSpeedProgress(
          stage: progress.stage, completedSamples: progress.completedSamples,
          totalSamples: progress.totalSamples, stageValue: progress.stageValue,
          completedDownloadMbps: progress.completedDownloadMbps, pauseEpoch: progress.pauseEpoch,
          displayUnit: progress.displayUnit))
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
        completedDownloadMbps: nil,
        pauseEpoch: 0))

    runningTasks[.domestic] = Task { @MainActor [weak self] in
      let outcome = await runner.run { progress in
        guard let self, self.stillActive(.domestic, runID: runID),
          runner.acceptsProgress(pauseEpoch: progress.pauseEpoch),
          case .networkRunning = self.phases[.domestic]
        else { return }
        let previous: WebsiteSpeedProgress?
        if case .networkRunning(let visible) = self.phases[.domestic] {
          previous = visible
        } else {
          previous = nil
        }
        self.phases[.domestic] = .networkRunning(progress.retainingReadout(from: previous))
      }
      guard let self, stillActive(.domestic, runID: runID) else { return }
      websiteRunner = nil
      runningTasks[.domestic] = nil
      switch outcome {
      case .success(let result):
        phases[.domestic] = .networkFinished(result)
      case .failure(let detail, let download):
        phases[.domestic] = .failed(
          NetworkProbeFailure(title: "测速失败", detail: detail, completedDownloadMbps: download))
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

}

enum NetworkProbeVisualTone: Equatable {
  case brand
  case neutral
  case latency
  case download
  case upload
  case paused
  case success
  case warning
  case failure

  var color: Color {
    switch self {
    case .brand: return AppVisualStyle.accent
    case .neutral, .latency: return AppVisualStyle.textSecondary
    // Match the status bar's established transfer colors exactly.
    case .download:
      return Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.62, blue: 1.0, alpha: 0.96))
    case .upload:
      return Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.31, alpha: 0.96))
    case .paused: return AppVisualStyle.textSecondary
    case .success: return AppVisualStyle.success
    case .warning: return AppVisualStyle.warning
    case .failure: return AppVisualStyle.danger
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
    Text("网速测量当前线路到 Cloudflare 的下载与上传，不代表国内宽带，VPN 仍可能影响结果。Codex 只检测 OpenAI 连通与响应，不运行任务，沿用当前线路。")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct NetworkProbeSphere: View {
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
    case .networkPaused(let progress):
      return progress.stage == .upload
        ? .upload : progress.stage == .download ? .download : .neutral
    case .networkFinished: return .neutral
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

        if direction == .domestic {
          Circle()
            .stroke(tone.color.opacity(0.65), lineWidth: 3)
            .padding(8)
        } else if progress > 0 {
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
          Text(direction.subtitle)
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
      VStack(spacing: 18) {
        finishedSpeed("上传", value: result.uploadMbps, tone: .upload, symbol: "arrow.up")
        finishedSpeed("下载", value: result.downloadMbps, tone: .download, symbol: "arrow.down")
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
        if let download = failure.completedDownloadMbps {
          VStack(spacing: 18) {
            HStack {
              Label("上传", systemImage: "arrow.up")
                .font(.system(size: 12, weight: .medium))
              Spacer()
              Text("未测成")
                .font(.system(size: 21, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            finishedSpeed("下载", value: download, tone: .download, symbol: "arrow.down")
          }
        } else {
          VStack(spacing: 8) {
            Text("测速未完成")
              .font(.caption.weight(.semibold))
            Text("请重试")
              .font(.system(size: 27, weight: .bold))
              .foregroundStyle(tone.color)
            actionLabel("重新测速", systemImage: "arrow.clockwise")
          }
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
      if let value = progress.stageValue, progress.stage != .latency {
        let display = WebsiteSpeedDisplay.rate(value, holdingUnit: progress.displayUnit)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(display.value)
            .font(.system(size: 43, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: 124, alignment: .trailing)
          Text(display.unit)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 38, alignment: .leading)
            .foregroundStyle(AppVisualStyle.textSecondary)
        }
        .foregroundStyle(tone.color)
      } else {
        Text(progress.stage == .upload ? "准备上传" : progress.stage == .download ? "准备下载" : "正在准备")
          .font(.system(size: 23, weight: .semibold))
          .foregroundStyle(tone.color)
      }
      if progress.stage == .upload, let download = progress.completedDownloadMbps {
        Text("下载 \(speed(download))")
          .font(.caption.weight(.semibold))
          .foregroundStyle(NetworkProbeVisualTone.download.color)
      }
      actionLabel(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
    }
  }

  private func finishedSpeed(
    _ title: String, value: Double, tone: NetworkProbeVisualTone, symbol: String
  ) -> some View {
    let display = WebsiteSpeedDisplay.rate(value)
    return HStack(alignment: .firstTextBaseline, spacing: 7) {
      HStack(spacing: 3) {
        Image(systemName: symbol)
          .foregroundStyle(tone.color)
        Text(title)
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(AppVisualStyle.textSecondary)
      .frame(width: 43, alignment: .leading)
      Text(display.value)
        .font(.system(size: 27, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(tone.color)
      Text(display.unit)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 33, alignment: .leading)
        .foregroundStyle(AppVisualStyle.textSecondary)
    }
    .frame(maxWidth: .infinity)
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
    WebsiteSpeedDisplay.rate(value).text
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
      if progress.stage == .latency { return progress.stage.title }
      let rate = WebsiteSpeedDisplay.rate(progress.stageValue, holdingUnit: progress.displayUnit)
        .accessibilityText
      return "\(progress.stage.title)，\(rate)"
    case .networkPaused(let progress):
      return "已暂停，当前阶段 \(progress.stage.title)"
    case .networkFinished(let result):
      let download = WebsiteSpeedDisplay.rate(result.downloadMbps).accessibilityText
      let upload = WebsiteSpeedDisplay.rate(result.uploadMbps).accessibilityText
      return "下载 \(download)，上传 \(upload)"
    case .codexRunning(let completedRounds, _):
      return "进行中，已完成 \(completedRounds) / 4 轮"
    case .codexFinished(let summary):
      return "\(summary.title)，\(summary.reachableCount) / 4 轮可达，最近失败：\(summary.latestFailureText)"
    case .failed(let failure):
      if direction == .domestic {
        if let download = failure.completedDownloadMbps {
          return "上传未测成，下载 \(WebsiteSpeedDisplay.rate(download).accessibilityText)，点击重试"
        }
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
    case .networkFinished:
      return "点击圆球重新测速"
    default:
      return "点击开始测试"
    }
  }
}
