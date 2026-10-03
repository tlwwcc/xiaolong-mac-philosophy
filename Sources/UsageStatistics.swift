import AppKit
import CryptoKit
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
  static let nicknameKey = "usageStatistics.nickname.v1"
  static let earlyAccessKey = "usageStatistics.earlyAccess.v1"
  static let profileKnownKey = "usageStatistics.profileKnown.v1"
  static let profileSequenceKey = "usageStatistics.profileSequence.v1"
  private let endpoint = URL(string: "https://aixlg.com/api/usage/presence")!
  @Published private(set) var enabled: Bool
  @Published private(set) var deleting = false
  @Published private(set) var deletionMessage: String?
  @Published private(set) var deviceCode: String?
  @Published private(set) var nickname: String
  @Published private(set) var earlyAccess: Bool
  @Published private(set) var invitation: FriendInvitation?
  @Published private(set) var profileBusy = false
  @Published private(set) var profileMessage: String?
  @Published private(set) var profileFailed = false
  @Published private(set) var profileChange = 0
  private var profileTask: Task<Void, Never>?
  private var profileOwner = UUID()
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
    nickname = defaults.string(forKey: Self.nicknameKey) ?? ""
    earlyAccess = defaults.bool(forKey: Self.earlyAccessKey)
    deviceCode = Self.deviceCode(for: defaults.string(forKey: Self.installationKey))
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

  static func deviceCode(for installation: String?) -> String? {
    guard let installation, installation.utf8.count == 64,
      installation.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else { return nil }
    let digest = SHA256.hash(data: Data(installation.utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
  }

  @discardableResult
  func copyDeviceCode(to pasteboard: NSPasteboard = .general) -> Bool {
    guard !deleting, let deviceCode else { return false }
    pasteboard.clearContents()
    return pasteboard.setString(deviceCode, forType: .string)
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
    deviceCode = Self.deviceCode(for: value)
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
    profileOwner = UUID()
    profileTask?.cancel()
    profileBusy = false
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
        [Self.nicknameKey, Self.earlyAccessKey, Self.profileKnownKey, Self.profileSequenceKey]
          .forEach(defaults.removeObject(forKey:))
        nickname = ""
        earlyAccess = false
        invitation = nil
        profileMessage = nil
        profileChange += 1
        deviceCode = nil
        defaults.synchronize()
        deletionMessage = "服务器中的统计、昵称和报名已清除，统计保持关闭。"
      } catch {
        deletionMessage = "统计已关闭；暂未清除服务器记录，请联网后重试。"
      }
    }
  }

  struct FriendInvitation: Decodable {
    let title: String
    let detail: String
    let url: String

    var safeURL: URL? {
      guard let components = URLComponents(string: url),
        components.scheme == "https", components.host == "aixlg.com",
        components.user == nil, components.password == nil, components.port == nil,
        components.query == nil,
        components.percentEncodedPath.range(of: "^/mac/[A-Za-z0-9/_-]*$", options: .regularExpression) != nil
      else { return nil }
      return components.url
    }
  }

  private struct ProfileReceipt: Decodable {
    let ok: Bool
    let profileProtocol: Int
    let profile: Profile
    struct Profile: Decodable {
      let nickname: String
      let earlyAccess: Bool
      let sequence: Int
      let invitation: FriendInvitation?
    }
  }

  static func normalizedNickname(_ input: String) -> String? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    guard value.unicodeScalars.count <= 24, !value.unicodeScalars.contains(where: {
      switch $0.properties.generalCategory {
      case .control, .surrogate, .lineSeparator, .paragraphSeparator: return true
      case .format: return $0.value != 0x200D
      default: return false
      }
    }) else { return nil }
    return value
  }

  func refreshProfile() {
    guard defaults.bool(forKey: Self.profileKnownKey) else { return }
    performProfileSave(nil)
  }

  func saveProfile(nickname input: String, earlyAccess: Bool) {
    guard let name = Self.normalizedNickname(input), !name.isEmpty else {
      profileFailed = true
      profileMessage = "请填 1–24 个字的称呼，不要换行。"
      return
    }
    performProfileSave((name, earlyAccess))
  }

  func removeProfile() { performProfileSave(("", false)) }

  private func performProfileSave(_ value: (String, Bool)?) {
    guard !profileBusy, !deleting, let token = installation(create: value != nil) else { return }
    let owner = UUID()
    profileOwner = owner
    var payload: [String: Any] = ["installation": token, "action": value == nil ? "get" : "save"]
    var sequence = defaults.integer(forKey: Self.profileSequenceKey)
    if let value {
      guard sequence >= 0, sequence < 9_007_199_254_740_991 else { return }
      sequence += 1
      defaults.set(sequence, forKey: Self.profileSequenceKey)
      // A lost save receipt can be recovered by reopening this entry.
      defaults.set(true, forKey: Self.profileKnownKey)
      guard defaults.synchronize() else {
        profileFailed = true
        profileMessage = "本机未能保存登记状态，请稍后重试。"
        return
      }
      payload["sequence"] = sequence
      payload["nickname"] = value.0
      payload["earlyAccess"] = value.1
    }
    var request = URLRequest(url: URL(string: "https://aixlg.com/api/usage/profile")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    profileBusy = true
    profileFailed = false
    profileMessage = value == nil ? "正在同步…" : "正在保存…"
    profileTask = Task { [weak self] in
      guard let self else { return }
      defer { if profileOwner == owner { profileBusy = false } }
      do {
        let (data, response) = try await session.data(for: request)
        guard profileOwner == owner, !Task.isCancelled else { return }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
          let receipt = try? JSONDecoder().decode(ProfileReceipt.self, from: data),
          receipt.ok, receipt.profileProtocol == 1,
          receipt.profile.sequence >= 0, receipt.profile.sequence <= 9_007_199_254_740_991,
          Self.normalizedNickname(receipt.profile.nickname) == receipt.profile.nickname,
          !receipt.profile.earlyAccess || !receipt.profile.nickname.isEmpty
        else { throw URLError(.badServerResponse) }
        let result = receipt.profile
        defaults.set(max(sequence, result.sequence), forKey: Self.profileSequenceKey)
        if let value, (result.sequence != sequence || result.nickname != value.0 || result.earlyAccess != value.1) {
          profileFailed = true
          profileMessage = "登记状态已变化；输入已保留，请再次保存。"
          return
        }
        nickname = result.nickname
        earlyAccess = result.earlyAccess
        invitation = result.earlyAccess ? result.invitation : nil
        defaults.set(nickname, forKey: Self.nicknameKey)
        defaults.set(earlyAccess, forKey: Self.earlyAccessKey)
        defaults.set(!nickname.isEmpty, forKey: Self.profileKnownKey)
        defaults.synchronize()
        profileChange += 1
        profileMessage = nickname.isEmpty ? "昵称和报名已清除。" : value == nil ? "已同步。" : "昵称已保存，小龙哥能在后台看到。"
      } catch {
        guard profileOwner == owner, !Task.isCancelled else { return }
        profileFailed = true
        profileMessage = value == nil ? "暂时无法同步，请联网后重试。" : "未确认保存结果，输入已保留；请重试或重新打开此页同步。"
      }
    }
  }

  @discardableResult
  func copyFeedbackInfo(to pasteboard: NSPasteboard = .general) -> Bool {
    guard !deleting, !profileBusy, let deviceCode else { return false }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let text = "称呼：\(nickname.isEmpty ? "未登记" : nickname)\n设备：\(deviceCode)\nMac 哲学：\(version)\nmacOS：\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n遇到的问题："
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}

@MainActor
struct FriendProfileSettingsView: View {
  @ObservedObject private var statistics: UsageStatistics
  @State private var draft = ""
  @State private var earlyAccess = false
  @State private var confirmsRemoval = false
  @State private var copyMessage: String?

  init(statistics: UsageStatistics? = nil) { self.statistics = statistics ?? .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("用微信群里的称呼，方便小龙哥认出你。")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField("微信群昵称，或小龙哥认识的称呼", text: $draft)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("你的昵称")
        .accessibilityIdentifier("friendProfile.nickname")
        .disabled(statistics.profileBusy || statistics.deleting)
      UsageDeviceCodeView(statistics: statistics)
      Toggle("报名老朋友尝鲜", isOn: $earlyAccess)
        .disabled(statistics.profileBusy || statistics.deleting)
        .accessibilityIdentifier("friendProfile.earlyAccess")
      Text("新功能优先体验；有邀请时，到这里查看。不会自动安装。")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(statistics.profileBusy ? "正在同步…" : "保存昵称") {
          statistics.saveProfile(nickname: draft, earlyAccess: earlyAccess)
        }
        .disabled(statistics.profileBusy || statistics.deleting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("friendProfile.save")
        if !statistics.nickname.isEmpty {
          Button("删除昵称", role: .destructive) { confirmsRemoval = true }
            .disabled(statistics.profileBusy || statistics.deleting)
            .accessibilityIdentifier("friendProfile.remove")
        }
      }
      if let message = statistics.profileMessage {
        Text(message).font(.caption)
          .foregroundStyle(statistics.profileFailed ? AppVisualStyle.danger : AppVisualStyle.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if statistics.profileFailed {
          Button("重新同步") { statistics.refreshProfile() }
            .disabled(statistics.profileBusy || statistics.deleting)
        }
      }
      if statistics.earlyAccess {
        if let invitation = statistics.invitation, let url = invitation.safeURL {
          VStack(alignment: .leading, spacing: 6) {
            Text(invitation.title).font(.headline)
            Text(invitation.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            Link("查看尝鲜邀请", destination: url)
          }
        } else {
          Text(statistics.profileBusy ? "正在查看尝鲜邀请…" : statistics.profileFailed ? "上次已报名；本次未能确认邀请。" : "已报名，目前暂无尝鲜邀请。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      if !statistics.nickname.isEmpty {
        Button("复制反馈信息") {
          copyMessage = statistics.copyFeedbackInfo() ? "已复制昵称、设备编号和版本，可粘贴到交流群并补充问题。" : "未能复制，请稍后重试。"
        }
        .disabled(statistics.profileBusy || statistics.deleting)
        .accessibilityIdentifier("friendProfile.copyFeedback")
        if let copyMessage {
          Text(copyMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text("昵称仅小龙哥可见，可改可删；设备统计可在下方关闭。")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("昵称与隐私") {
        VStack(alignment: .leading, spacing: 12) {
          Text("保存后，昵称与上方本机编号关联，不用再找小龙哥登记。关闭统计也能保存昵称；不会读取微信、通讯录或计算机名。昵称与报名最长保留一年，重新保存续期。删除昵称同时退出尝鲜；不影响其他功能。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Divider()
          UsageStatisticsSettingsView(statistics: statistics)
        }
        .padding(.top, 8)
      }
      .accessibilityIdentifier("friendProfile.privacy")
      .font(.caption)
    }
    .onAppear {
      draft = statistics.nickname
      earlyAccess = statistics.earlyAccess
      statistics.refreshProfile()
    }
    .onReceive(statistics.$profileChange) { _ in
      draft = statistics.nickname
      earlyAccess = statistics.earlyAccess
      copyMessage = nil
    }
    .confirmationDialog("删除昵称并退出老朋友尝鲜？", isPresented: $confirmsRemoval) {
      Button("删除昵称并退出", role: .destructive) { statistics.removeProfile() }
    } message: {
      Text("不影响免费使用，也不改变使用量统计的开关。")
    }
  }
}

@MainActor
private struct UsageDeviceCodeView: View {
  @ObservedObject var statistics: UsageStatistics
  @State private var copiedDeviceCode: String?
  @State private var copyFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Text("本机编号").fixedSize()
          deviceCodeControls
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("本机编号")
          deviceCodeControls
        }
      }
      if statistics.deviceCode == nil {
        Text("保存昵称或开启统计后显示。")
          .fixedSize(horizontal: false, vertical: true)
      }
      if copyFailed {
        Text("未能复制，请选中编号后复制。")
          .foregroundStyle(AppVisualStyle.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .onReceive(statistics.$deviceCode) { _ in
      copiedDeviceCode = nil
      copyFailed = false
    }
  }

  private var deviceCodeControls: some View {
    HStack(spacing: 12) {
      Text(statistics.deviceCode ?? "尚未生成")
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize()
        .accessibilityIdentifier("usageStatistics.deviceCode")
      Spacer(minLength: 0)
      Button {
        if statistics.copyDeviceCode() {
          copiedDeviceCode = statistics.deviceCode
          copyFailed = false
        } else {
          copiedDeviceCode = nil
          copyFailed = true
        }
      } label: {
        Label(copiedDeviceCode != nil && copiedDeviceCode == statistics.deviceCode ? "已复制" : "复制",
          systemImage: copiedDeviceCode != nil && copiedDeviceCode == statistics.deviceCode ? "checkmark" : "square.on.square")
      }
      .fixedSize()
      .disabled(statistics.deviceCode == nil || statistics.deleting)
      .accessibilityIdentifier("usageStatistics.copyDeviceCode")
    }
  }
}

@MainActor
struct UsageStatisticsSettingsView: View {
  @ObservedObject private var statistics: UsageStatistics
  @State private var confirmsDeletion = false

  init(statistics: UsageStatistics? = nil) {
    self.statistics = statistics ?? .shared
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(statistics.nickname.isEmpty ? "参与匿名设备统计" : "参与设备统计（已关联昵称）", isOn: Binding(
        get: { statistics.enabled }, set: { statistics.setEnabled($0) }))
        .font(.body)
        .disabled(statistics.deleting)
        .accessibilityIdentifier("usageStatistics.enabled")
      Text("默认开启，可随时关闭；此前主动关闭的选择会保留。开启后，向小龙哥发送随机安装编号、软件与系统版本和在线状态，用于统计接入与在线设备。不会发送文件、剪贴板、截图或输入内容；关闭不影响任何功能。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("每日记录保留一年；设备信息在一年未报告在线后清理。多台 Mac 分别计数，无需注册账号。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(statistics.deleting ? "正在清除…" : "清除统计与昵称并关闭") { confirmsDeletion = true }
        .disabled(statistics.deleting)
        .confirmationDialog("清除这台 Mac 的服务器统计记录？", isPresented: $confirmsDeletion) {
          Button("清除并关闭", role: .destructive) { statistics.deleteRecords() }
        } message: {
          Text("同时删除本机的服务器统计、昵称、备注与尝鲜报名，不影响本机文件、设置或功能。以后重新开启将作为新的参与设备。")
        }
      if let message = statistics.deletionMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
