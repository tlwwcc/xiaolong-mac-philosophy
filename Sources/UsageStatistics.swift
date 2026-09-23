import AppKit
import Foundation
import SwiftUI

private final class UsageNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Enabled by default; an explicit local choice always wins and is never exported.
@MainActor
final class UsageStatistics: ObservableObject {
  static let shared = UsageStatistics()
  static let consentKey = "usageStatistics.consent.v1"
  static let installationKey = "usageStatistics.installation.v1"
  static let sequenceKey = "usageStatistics.sequence.v1"
  private let endpoint = URL(string: "https://aixlg.com/api/usage/presence")!
  @Published private(set) var enabled: Bool
  @Published private(set) var deleting = false
  @Published private(set) var deletionMessage: String?
  private var policy = UsageReportingPolicy()
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var activeTask: Task<Void, Never>?
  private var stoppingTask: URLSessionDataTask?
  private var pauseReasons: Set<String> = []
  private var started = false
  private var runtimeID: UUID?
  private let defaults: UserDefaults
  private let session: URLSession
  var hasReportingResources: Bool { timer != nil || !observers.isEmpty }

  init(defaults: UserDefaults = .standard, session injectedSession: URLSession? = nil) {
    self.defaults = defaults
    enabled = defaults.object(forKey: Self.consentKey) == nil
      ? true : defaults.bool(forKey: Self.consentKey)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    session = injectedSession ?? URLSession(configuration: configuration, delegate: UsageNoRedirectDelegate(), delegateQueue: nil)
  }

  func start() {
    guard !started else { return }
    started = true
    policy.setEnabled(enabled)
    if enabled { startRuntime() }
  }

  private func startRuntime() {
    guard started, enabled, timer == nil else { return }
    let owner = UUID()
    runtimeID = owner
    let center = NSWorkspace.shared.notificationCenter
    for (name, reason, paused) in [
      (NSWorkspace.willSleepNotification, "sleep", true),
      (NSWorkspace.didWakeNotification, "sleep", false),
      (NSWorkspace.sessionDidResignActiveNotification, "session", true),
      (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
      (NSWorkspace.screensDidSleepNotification, "display", true),
      (NSWorkspace.screensDidWakeNotification, "display", false),
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.runtimeID == owner else { return }
          self.pause(reason: reason, value: paused)
        }
      })
    }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.runtimeID == owner else { return }
        self.tick()
      }
    }
    timer?.tolerance = 15
    tick()
  }

  func setEnabled(_ value: Bool) {
    guard !deleting, value != enabled else { return }
    enabled = value
    defaults.set(value, forKey: Self.consentKey)
    policy.setEnabled(value)
    activeTask?.cancel()
    activeTask = nil
    deletionMessage = nil
    if value {
      startRuntime()
    } else {
      stopRuntime()
      sendOfflineIfKnown()
    }
  }

  func stop() {
    guard started else { return }
    started = false
    policy.setEnabled(false)
    stopRuntime()
    if enabled { sendOfflineIfKnown() }
  }

  private func stopRuntime() {
    runtimeID = nil
    timer?.invalidate()
    timer = nil
    activeTask?.cancel()
    activeTask = nil
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers.removeAll()
    pauseReasons.removeAll()
    policy.setSuspended(false)
  }

  private func pause(reason: String, value: Bool) {
    guard started, enabled, timer != nil else { return }
    if value { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
    let wasSuspended = policy.suspended
    policy.setSuspended(!pauseReasons.isEmpty)
    guard wasSuspended != policy.suspended else { return }
    activeTask?.cancel()
    activeTask = nil
    if policy.suspended {
      if enabled { sendOfflineIfKnown() }
    } else {
      tick()
    }
  }

  private func installation(create: Bool) -> String? {
    if let existing = defaults.string(forKey: Self.installationKey),
      existing.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
      return existing
    }
    guard create else { return nil }
    let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    defaults.set(value, forKey: Self.installationKey)
    defaults.removeObject(forKey: Self.sequenceKey)
    return value
  }

  private func request(state: String, token: String) -> URLRequest? {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let previous = defaults.integer(forKey: Self.sequenceKey)
    guard previous >= 0, previous < 9_007_199_254_740_991 else { return nil }
    let sequence = previous + 1
    defaults.set(sequence, forKey: Self.sequenceKey)
    guard defaults.synchronize() else { return nil }
    let payload: [String: Any] = ["installation": token, "sequence": sequence, "state": state, "version": version,
                   "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    return request
  }

  private func tick() {
    guard started, !deleting,
      let generation = policy.begin(now: ProcessInfo.processInfo.systemUptime)
    else { return }
    guard let token = installation(create: true), let request = request(state: "online", token: token) else {
      policy.finish(generation: generation, success: false, now: ProcessInfo.processInfo.systemUptime)
      return
    }
    activeTask = Task { [weak self] in
      guard let self else { return }
      var success = false
      do {
        let (data, response) = try await session.data(for: request)
        success = Self.hasReceipt(data: data, response: response)
      } catch { /* Statistics never interrupt a software feature. */ }
      policy.finish(generation: generation, success: success, now: ProcessInfo.processInfo.systemUptime)
    }
  }

  private static func hasReceipt(data: Data, response: URLResponse) -> Bool {
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return false }
    return receipt["ok"] as? Bool == true && receipt["protocol"] as? Int == 2
  }

  private func sendOfflineIfKnown() {
    guard let token = installation(create: false), let request = request(state: "offline", token: token) else { return }
    stoppingTask?.cancel()
    stoppingTask = session.dataTask(with: request)
    stoppingTask?.resume() // Best effort. The server expires presence after five minutes regardless.
  }

  func deleteRecords() {
    guard !deleting else { return }
    setEnabled(false)
    guard let token = installation(create: false), let request = request(state: "delete", token: token) else {
      deletionMessage = "这台 Mac 尚未生成统计标识。"
      return
    }
    deleting = true
    deletionMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { deleting = false }
      do {
        let (data, response) = try await session.data(for: request)
        guard Self.hasReceipt(data: data, response: response) else { throw URLError(.badServerResponse) }
        defaults.removeObject(forKey: Self.installationKey)
        defaults.removeObject(forKey: Self.sequenceKey)
        defaults.synchronize()
        deletionMessage = "服务器中的统计记录已清除，统计保持关闭。"
      } catch {
        deletionMessage = "统计已关闭；暂未清除服务器记录，请联网后重试。"
      }
    }
  }
}

struct UsageStatisticsSettingsView: View {
  @ObservedObject private var statistics = UsageStatistics.shared
  @State private var confirmsDeletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("参与匿名使用量统计", isOn: Binding(
        get: { statistics.enabled }, set: { statistics.setEnabled($0) }))
        .disabled(statistics.deleting)
        .accessibilityIdentifier("usageStatistics.enabled")
      Text("默认开启，可随时关闭；此前主动关闭的选择会保留。开启后，向小龙哥发送随机安装编号、软件与系统版本和在线状态，用于统计在线设备。不会发送文件、剪贴板、截图或输入内容；关闭不影响任何功能。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("每日记录保留一年；设备信息在一年未报告在线后清理。多台 Mac 分别计数，无需注册账号。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button(statistics.deleting ? "正在清除…" : "清除统计记录并关闭") { confirmsDeletion = true }
        .disabled(statistics.deleting)
        .confirmationDialog("清除这台 Mac 的服务器统计记录？", isPresented: $confirmsDeletion) {
          Button("清除并关闭", role: .destructive) { statistics.deleteRecords() }
        } message: {
          Text("只清除使用量统计，不影响本机文件、设置或功能。以后重新开启将作为新的参与设备。")
        }
      if let message = statistics.deletionMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
