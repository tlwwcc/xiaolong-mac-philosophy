import Foundation

/// 与 aixlg.com/c 共用的纯值统计规则。
///
/// 网络吞吐使用线性插值 P90，延迟使用 P50；Codex 的偶数中位数再四舍五入为整数毫秒。
enum NetworkProbeStatistics {
  static func percentile(_ values: [Double], probability: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let boundedProbability = min(1, max(0, probability))
    let position = Double(sorted.count - 1) * boundedProbability
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = Int(position.rounded(.up))
    guard lowerIndex != upperIndex else { return sorted[lowerIndex] }

    let fraction = position - Double(lowerIndex)
    return sorted[lowerIndex] + ((sorted[upperIndex] - sorted[lowerIndex]) * fraction)
  }

  static func median(_ values: [Double]) -> Double? {
    percentile(values, probability: 0.5)
  }

  /// 网页中的 jitter：按采样顺序计算相邻延迟差的绝对值，再取算术平均。
  static func meanAdjacentDifference(_ values: [Double]) -> Double? {
    guard values.count >= 2 else { return nil }
    let differences = zip(values, values.dropFirst()).map { abs($1 - $0) }
    return differences.reduce(0, +) / Double(differences.count)
  }
}

enum CodexConnectivityOutcome: String, Equatable, Sendable {
  case reachable
  case blocked
  case rateLimited
  case serviceFailure
  case unexpectedResponse
  case timeout
  case networkFailure

  var isHTTPResponse: Bool {
    switch self {
    case .reachable, .blocked, .rateLimited, .serviceFailure, .unexpectedResponse:
      return true
    case .timeout, .networkFailure:
      return false
    }
  }
}

struct CodexConnectivitySample: Equatable, Sendable {
  let round: Int
  let outcome: CodexConnectivityOutcome
  let latencyMilliseconds: Int?
  let statusCode: Int?

  static func classifyHTTPStatus(_ statusCode: Int) -> CodexConnectivityOutcome {
    switch statusCode {
    case 200...399, 401:
      // 此探针不携带用户凭据；401 代表请求已抵达 Codex API，是预期响应。
      return .reachable
    case 403:
      return .blocked
    case 429:
      return .rateLimited
    case 500...599:
      return .serviceFailure
    default:
      return .unexpectedResponse
    }
  }

  static func http(round: Int, statusCode: Int, latencyMilliseconds: Int) -> Self {
    CodexConnectivitySample(
      round: round,
      outcome: classifyHTTPStatus(statusCode),
      latencyMilliseconds: max(0, latencyMilliseconds),
      statusCode: statusCode)
  }

  static func timeout(round: Int) -> Self {
    CodexConnectivitySample(
      round: round,
      outcome: .timeout,
      latencyMilliseconds: nil,
      statusCode: nil)
  }

  static func networkFailure(round: Int) -> Self {
    CodexConnectivitySample(
      round: round,
      outcome: .networkFailure,
      latencyMilliseconds: nil,
      statusCode: nil)
  }
}

enum CodexConnectivityState: String, Equatable, Sendable {
  case green
  case yellow
  case red
}

struct CodexConnectivitySummary: Equatable, Sendable {
  static let requiredRounds = 4
  static let stableMedianLimitMilliseconds = 1_200
  static let stableSpreadLimitMilliseconds = 700

  let samples: [CodexConnectivitySample]
  let reachableCount: Int
  let medianMilliseconds: Int?
  let spreadMilliseconds: Int
  let successRate: Int
  let latestFailure: CodexConnectivitySample?
  let state: CodexConnectivityState

  var completedRounds: Int { samples.count }

  var title: String {
    switch state {
    case .green:
      return "连接稳定"
    case .yellow:
      return "连接波动"
    case .red where latestFailure?.outcome == .blocked:
      return "连接受阻"
    case .red:
      return "连接失败"
    }
  }

  var metricText: String {
    if let medianMilliseconds {
      return "\(successRate)% 可达 · \(medianMilliseconds) ms"
    }
    return "\(successRate)% 可达"
  }

  var latestFailureText: String {
    guard let latestFailure else { return "无失败记录" }
    switch latestFailure.outcome {
    case .reachable:
      return "无失败记录"
    case .blocked:
      return "403 · 连接被阻止"
    case .rateLimited:
      return "429 · 服务请求过于频繁"
    case .serviceFailure:
      return "\(latestFailure.statusCode ?? 500) · 服务暂时不可用"
    case .unexpectedResponse:
      return "\(latestFailure.statusCode ?? 0) · 收到意外响应"
    case .timeout:
      return "检测超时"
    case .networkFailure:
      return "网络连接失败"
    }
  }

  static func make(samples allSamples: [CodexConnectivitySample]) -> Self {
    let samples = Array(allSamples.prefix(requiredRounds))
    let reachableSamples = samples.filter { $0.outcome == .reachable }
    let httpResponseSamples = samples.filter { $0.outcome.isHTTPResponse }
    let reachableLatencies = reachableSamples.compactMap(\.latencyMilliseconds)
    let medianMilliseconds = NetworkProbeStatistics.median(
      reachableLatencies.map(Double.init)
    ).map { Int($0.rounded()) }
    let spreadMilliseconds: Int
    if let minimum = reachableLatencies.min(), let maximum = reachableLatencies.max() {
      spreadMilliseconds = maximum - minimum
    } else {
      spreadMilliseconds = 0
    }
    let successRate =
      samples.isEmpty
      ? 0
      : Int((Double(reachableSamples.count) / Double(samples.count) * 100).rounded())
    let latestFailure = samples.reversed().first { $0.outcome != .reachable }
    let timeoutCount = samples.count { $0.outcome == .timeout }
    let networkFailureCount = samples.count { $0.outcome == .networkFailure }
    let hasBlockedRequest = samples.contains { $0.outcome == .blocked }
    let allRateLimited = !samples.isEmpty && samples.allSatisfy { $0.outcome == .rateLimited }

    let state: CodexConnectivityState
    if hasBlockedRequest
      || (timeoutCount + networkFailureCount) >= 2
      || (samples.count == requiredRounds && httpResponseSamples.isEmpty)
      || (samples.count == requiredRounds && reachableSamples.isEmpty && !allRateLimited)
    {
      state = .red
    } else if samples.count == requiredRounds,
      reachableSamples.count == requiredRounds,
      let medianMilliseconds,
      medianMilliseconds <= stableMedianLimitMilliseconds,
      spreadMilliseconds <= stableSpreadLimitMilliseconds
    {
      state = .green
    } else {
      state = .yellow
    }

    return CodexConnectivitySummary(
      samples: samples,
      reachableCount: reachableSamples.count,
      medianMilliseconds: medianMilliseconds,
      spreadMilliseconds: spreadMilliseconds,
      successRate: successRate,
      latestFailure: latestFailure,
      state: state)
  }
}
