import AppKit
import Combine
import Foundation

/// Owns update presentation and the lifetime of asynchronous update callbacks.
/// Sparkle and AppUpdater retain their existing signed-package verification responsibilities.
@MainActor
final class UpdateWorkspace: ObservableObject {
  @Published private(set) var sparkleUpdateReminder = SparkleUpdateReminder()
  @Published var latestUpdate: AppUpdateManifest?
  @Published var updateServerVersionText = "未检查"
  @Published var updateStatusText = "未检查"
  @Published var updateReleaseDetailText = ""
  @Published var updateDownloadProgress: Double?
  @Published var updateFailureMessage: String?
  @Published var isUpdateBusy = false
  @Published var pendingReleaseNote: ReleaseNoteEntry?
  @Published var isReleaseNotePresented = false

  var sparkleCheckForUpdatesHandler: (() -> Void)?
  private let defaults: UserDefaults
  private let allowsOnlineUpdates: Bool
  private let currentBuildNumber: Int
  private let appVersionText: String
  private let onStatus: @MainActor (String) -> Void
  private let openURL: @MainActor (URL) -> Void
  private let terminateAfterInstall: @MainActor () -> Void
  private var stopped = false
  private var operationID: UUID?
  private enum OperationPhase { case checking, downloading, installing, restarting }
  private var operationPhase: OperationPhase?
  private var stagedUpdate: StagedAppUpdate?
  private var lastAutomaticUpdateCheckAt: Date?
  private var needsUpdateAuthorizationRecheck = false
  private let automaticUpdateCheckInterval: TimeInterval = 6 * 60 * 60
  private static let autoUpdateCheckKey = "lastAutomaticUpdateCheckAtV1"
  private static let lastSeenReleaseNotesBuildDefaultsKey = "lastSeenReleaseNotesBuildV1"
  private var lastStatus = ""
  private var statusMessage: String {
    get { lastStatus }
    set { lastStatus = newValue; onStatus(newValue) }
  }

  init(defaults: UserDefaults = .standard, allowsOnlineUpdates: Bool,
       currentBuildNumber: Int, appVersionText: String,
       onStatus: @escaping @MainActor (String) -> Void,
       openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
       terminateAfterInstall: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
    self.defaults = defaults
    self.allowsOnlineUpdates = allowsOnlineUpdates
    self.currentBuildNumber = currentBuildNumber
    self.appVersionText = appVersionText
    self.onStatus = onStatus
    self.openURL = openURL
    self.terminateAfterInstall = terminateAfterInstall
  }

  var usesSparkleUpdater: Bool { currentBuildNumber >= 182 }
  var availableUpdateVersion: String? {
    sparkleUpdateReminder.availableVersion ?? latestUpdate?.displayVersion
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    operationID = nil
    operationPhase = nil
    sparkleCheckForUpdatesHandler = nil
    isUpdateBusy = false
  }

  func runPrimaryUpdateAction() {
    if latestUpdate == nil {
      checkForUpdates()
    } else {
      installLatestUpdate()
    }
  }

  func checkForUpdatesIfNeeded() {
    guard !stopped else { return }
    guard allowsOnlineUpdates else {
      updateServerVersionText = "不可用"
      updateStatusText = "运行身份无效，更新已停用。"
      return
    }
    // Sparkle owns both scheduled discovery and installation from Build 182 onward.
    guard !usesSparkleUpdater else { return }
    guard !isUpdateBusy else { return }
    guard updateFailureMessage == nil else { return }
    let now = Date()
    let savedLastCheckInterval = defaults.double(forKey: Self.autoUpdateCheckKey)
    var savedLastCheck: Date?
    if savedLastCheckInterval > 0 {
      savedLastCheck = Date(timeIntervalSince1970: savedLastCheckInterval)
    }
    let lastCheck = lastAutomaticUpdateCheckAt ?? savedLastCheck
    if let lastCheck, now.timeIntervalSince(lastCheck) < automaticUpdateCheckInterval {
      return
    }
    lastAutomaticUpdateCheckAt = now
    defaults.set(now.timeIntervalSince1970, forKey: Self.autoUpdateCheckKey)
    checkForUpdates(announcesResult: false)
  }

  func showReleaseNoteIfNeeded() {
    guard !stopped else { return }
    guard pendingReleaseNote == nil, !isReleaseNotePresented else { return }
    guard let note = ReleaseNotes.entry(forBuild: currentBuildNumber) else { return }
    let lastSeenBuild = defaults.integer(
      forKey: Self.lastSeenReleaseNotesBuildDefaultsKey)
    guard lastSeenBuild < note.build else { return }
    pendingReleaseNote = note
    isReleaseNotePresented = true
  }

  func markReleaseNoteSeen() {
    guard !stopped else { return }
    if let pendingReleaseNote {
      defaults.set(
        pendingReleaseNote.build,
        forKey: Self.lastSeenReleaseNotesBuildDefaultsKey
      )
    }
    pendingReleaseNote = nil
    isReleaseNotePresented = false
  }

  func openReleaseNotesChangelog() {
    guard !stopped else { return }
    let url = pendingReleaseNote?.changelogURL ?? ReleaseNotes.fallbackChangelogURL
    openURL(url)
  }

  func checkForUpdates() {
    checkForUpdates(announcesResult: true)
  }

  private func checkForUpdates(announcesResult: Bool) {
    guard !stopped else { return }
    guard allowsOnlineUpdates else {
      latestUpdate = nil
      needsUpdateAuthorizationRecheck = false
      updateServerVersionText = "不可用"
      updateStatusText = "运行身份无效，更新已停用。"
      updateReleaseDetailText = ""
      updateDownloadProgress = nil
      if announcesResult { statusMessage = updateStatusText }
      return
    }
    if usesSparkleUpdater {
      guard !isUpdateBusy else { return }
      latestUpdate = nil
      updateFailureMessage = nil
      guard let sparkleCheckForUpdatesHandler else {
        handleSparkleUpdateState(.failed(message: "更新组件尚未就绪，请稍后再试。"))
        return
      }
      sparkleCheckForUpdatesHandler()
      return
    }
    guard !isUpdateBusy else { return }
    if announcesResult {
      updateFailureMessage = nil
    }
    isUpdateBusy = true
    stagedUpdate = nil
    updateServerVersionText = "检查中"
    updateStatusText = "正在检查更新..."
    updateDownloadProgress = nil
    let operation = UUID()
    operationID = operation
    operationPhase = .checking
    AppUpdater.shared.checkForUpdate(bypassingCache: announcesResult) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.stopped, self.operationID == operation,
          self.operationPhase == .checking
        else { return }
        self.operationID = nil
        self.operationPhase = nil
        self.isUpdateBusy = false
        switch result {
        case .success(let manifest):
          self.updateFailureMessage = nil
          self.updateServerVersionText = manifest.displayVersion
          let currentVersion = self.appVersionText
          self.updateReleaseDetailText = self.updateReleaseDetailText(for: manifest)
          if AppUpdater.shared.isNewer(manifest, thanCurrentBuild: self.currentBuildNumber) {
            let authorization = UpdateReleasePolicy.decision(
              publishedAt: manifest.publishedAt)
            if let denial = authorization.denialMessage {
              self.latestUpdate = nil
              self.needsUpdateAuthorizationRecheck = true
              self.updateStatusText =
                "发现新版 \(manifest.displayVersion)，但更新信息尚未通过校验。"
              self.statusMessage = denial
            } else {
              self.latestUpdate = manifest
              self.needsUpdateAuthorizationRecheck = false
              self.updateStatusText = "发现新版：当前 \(currentVersion)，线上 \(manifest.displayVersion)。"
              self.statusMessage = "发现新版 \(manifest.displayVersion)，可下载并校验更新包。"
            }
          } else {
            self.latestUpdate = nil
            self.needsUpdateAuthorizationRecheck = false
            self.updateStatusText = "已是最新版：当前 \(currentVersion)，线上 \(manifest.displayVersion)。"
            if announcesResult {
              self.statusMessage = "当前已是最新版。"
            }
          }
        case .failure(let error):
          AppDiagnostics.log(
            "update_check_failed",
            [
              "source": announcesResult ? "manual" : "automatic",
              "error": error.localizedDescription,
            ])
          if let latestUpdate = self.latestUpdate {
            self.updateServerVersionText = latestUpdate.displayVersion
            self.updateStatusText =
              "暂时无法重新检查，仍保留已发现的 \(latestUpdate.displayVersion)。"
          } else {
            self.updateServerVersionText = announcesResult ? "暂不可用" : "未检查"
            self.updateStatusText = announcesResult ? "暂时无法检查更新。" : "未检查"
            self.updateReleaseDetailText = ""
          }
          self.updateDownloadProgress = nil
          if announcesResult {
            let detail = AppUpdaterError.customerDescription(
              for: error,
              fallback: "暂时无法连接或读取更新信息，请稍后重试。")
            self.statusMessage = "检查更新失败：\(detail)"
          }
        }
      }
    }
  }

  private func updateReleaseDetailText(for manifest: AppUpdateManifest) -> String {
    var lines = ["通道：\(manifest.channel)"]
    if !manifest.publishedAt.isEmpty {
      lines.append("发布时间：\(manifest.publishedAt)")
    }
    if !manifest.notes.isEmpty {
      lines.append("更新说明：\(manifest.notes)")
    }
    return lines.joined(separator: "\n")
  }

  func installLatestUpdate() {
    guard !stopped else { return }
    guard allowsOnlineUpdates else {
      updateStatusText = "运行身份无效，更新与安装已停用。"
      statusMessage = updateStatusText
      return
    }
    if usesSparkleUpdater {
      checkForUpdates()
      return
    }
    guard !isUpdateBusy else { return }
    guard let latestUpdate else {
      checkForUpdates()
      return
    }
    guard reconcileDetectedUpdateAuthorization() else { return }
    beginInstallingUpdate(latestUpdate)
  }

  @discardableResult
  private func reconcileDetectedUpdateAuthorization() -> Bool {
    guard let latestUpdate else { return true }
    let authorization = UpdateReleasePolicy.decision(
      publishedAt: latestUpdate.publishedAt)
    guard let denial = authorization.denialMessage else { return true }
    self.latestUpdate = nil
    needsUpdateAuthorizationRecheck = true
    updateStatusText =
      "发现新版 \(latestUpdate.displayVersion)，但更新信息尚未通过校验。"
    statusMessage = denial
    return false
  }

  private func beginInstallingUpdate(_ latestUpdate: AppUpdateManifest) {
    let operation = UUID()
    operationID = operation
    operationPhase = .downloading
    isUpdateBusy = true
    updateFailureMessage = nil
    updateDownloadProgress = nil
    updateStatusText = "正在下载 \(latestUpdate.displayVersion)..."
    statusMessage = "正在下载更新包..."
    AppUpdater.shared.downloadAndStage(
      manifest: latestUpdate,
      eligibilityCheck: { publishedAt in
        UpdateReleasePolicy.decision(publishedAt: publishedAt).isAllowed
      },
      eventHandler: { [weak self] event in
        DispatchQueue.main.async {
          guard let self, !self.stopped, self.operationID == operation,
            self.operationPhase == .downloading, self.isUpdateBusy
          else { return }
          switch event {
          case .downloading(let progress):
            self.updateDownloadProgress = progress.fractionCompleted
            self.updateStatusText = self.downloadStatusText(
              progress,
              version: latestUpdate.displayVersion)
          case .verifying:
            self.updateDownloadProgress = nil
            self.updateStatusText = "正在校验 \(latestUpdate.displayVersion)..."
            self.statusMessage = "正在核对更新包完整性和 macOS 安全认证。"
          }
        }
      },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          guard let self, !self.stopped, self.operationID == operation,
            self.operationPhase == .downloading
          else { return }
          switch result {
          case .success(let staged):
            self.operationPhase = .installing
            self.stagedUpdate = staged
            self.updateDownloadProgress = nil
            self.updateStatusText = "正在安装 \(staged.manifest.displayVersion)..."
            self.statusMessage = "更新包已验证，正在准备安全替换。"
            AppUpdater.shared.installStagedUpdate(
              staged,
              eligibilityCheck: { verifiedPublishedAt in
                UpdateReleasePolicy.decision(
                  publishedAt: verifiedPublishedAt
                ).isAllowed
              },
              eventHandler: { [weak self] event in
                DispatchQueue.main.async {
                  guard let self, !self.stopped, self.operationID == operation,
                    self.operationPhase == .installing, self.isUpdateBusy
                  else { return }
                  switch event {
                  case .requestingAuthorization:
                    self.updateStatusText = "等待确认替换“应用程序”中的旧版本..."
                    self.statusMessage = "请在 macOS 提示中确认本次软件更新。"
                  case .replacing:
                    self.updateStatusText = "正在安全替换 \(staged.manifest.displayVersion)..."
                    self.statusMessage = "正在替换并复验 App；完成前不会退出当前版本。"
                  }
                }
              },
              completion: { [weak self] installResult in
                DispatchQueue.main.async {
                  guard let self, !self.stopped, self.operationID == operation,
                    self.operationPhase == .installing
                  else { return }
                  switch installResult {
                  case .success(let installed):
                    self.operationPhase = .restarting
                    do {
                      try AppUpdater.shared.launchRelaunchAfterInstall(installed)
                      self.updateStatusText = "更新已安装，即将重启..."
                      self.statusMessage = "新版本已通过安装后校验，即将重启。"
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, !self.stopped, self.operationID == operation,
                          self.operationPhase == .restarting
                        else { return }
                        self.operationID = nil
                        self.operationPhase = nil
                        self.terminateAfterInstall()
                      }
                    } catch {
                      AppDiagnostics.log(
                        "update_relaunch_failed",
                        ["error": error.localizedDescription])
                      self.isUpdateBusy = false
                      self.operationID = nil
                      self.operationPhase = nil
                      self.latestUpdate = nil
                      self.stagedUpdate = nil
                      self.updateFailureMessage =
                        "新版本已安装，但自动重启失败。请退出 App，再从“应用程序”重新打开。"
                      self.updateStatusText = self.updateFailureMessage ?? "新版本已安装。"
                      self.statusMessage = self.updateStatusText
                    }
                  case .failure(let error):
                    self.finishUpdateFailure(error)
                  }
                }
              })
          case .failure(let error):
            self.finishUpdateFailure(error)
          }
        }
      })
  }

  func handleSparkleUpdateState(_ state: SparkleUpdateState) {
    guard !stopped, allowsOnlineUpdates else { return }
    guard usesSparkleUpdater else { return }
    sparkleUpdateReminder.receive(state)
    latestUpdate = nil
    updateDownloadProgress = nil
    isUpdateBusy = false
    switch state {
    case .ready:
      if updateStatusText == "未检查" {
        updateStatusText = "自动检查已开启。"
      }
    case .checking:
      isUpdateBusy = true
      updateFailureMessage = nil
      updateServerVersionText = "检查中"
      updateStatusText = "正在检查更新..."
    case .found(let displayVersion):
      updateFailureMessage = nil
      updateServerVersionText = displayVersion
      updateStatusText = "发现新版 \(displayVersion)，点击“查看并更新”即可继续。"
      statusMessage = "发现新版 \(displayVersion)。"
    case .installing:
      isUpdateBusy = true
      updateFailureMessage = nil
      updateStatusText = "正在更新，请在更新窗口中查看进度。"
    case .sessionFinished:
      if updateFailureMessage == nil, let version = availableUpdateVersion {
        updateStatusText = "新版 \(version) 随时可以继续更新。"
      }
    case .aheadOfRelease(let displayVersion):
      updateFailureMessage = nil
      updateServerVersionText = displayVersion ?? "暂未确认"
      updateStatusText = "当前版本高于已发布版本，无需降级。"
      statusMessage = updateStatusText
    case .current:
      updateFailureMessage = nil
      updateServerVersionText = appVersionText
      updateStatusText = "已是最新版：当前 \(appVersionText)。"
      statusMessage = "当前已是最新版。"
    case .failed(let message):
      updateServerVersionText = availableUpdateVersion ?? "暂不可用"
      updateFailureMessage = message
      updateStatusText = message
      statusMessage = message
    }
  }

  private func finishUpdateFailure(_ error: Error) {
    operationID = nil
    operationPhase = nil
    isUpdateBusy = false
    updateDownloadProgress = nil
    stagedUpdate = nil
    latestUpdate = nil
    needsUpdateAuthorizationRecheck = false
    AppDiagnostics.log(
      "update_install_failed",
      [
        "type": String(reflecting: type(of: error)),
        "error": error.localizedDescription,
      ])
    let detail = AppUpdaterError.customerDescription(
      for: error,
      fallback:
        "更新包处理失败，已停止本次更新。当前版本保持不变；如仍失败，请从官网下载正式版覆盖一次。")
    let suffix = detail.contains("当前版本") ? "" : " 当前版本未被替换。"
    let message = "更新失败：\(detail)\(suffix) 请确认后手动重试。"
    updateFailureMessage = message
    updateStatusText = message
    statusMessage = message
  }

  private func downloadStatusText(
    _ progress: AppUpdateDownloadProgress,
    version: String
  ) -> String {
    let written = ByteCountFormatter.string(
      fromByteCount: progress.bytesWritten,
      countStyle: .file)
    guard let expectedBytes = progress.expectedBytes,
      let fraction = progress.fractionCompleted
    else {
      return "正在下载 \(version)：\(written)"
    }
    let expected = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    let percent = Int((fraction * 100).rounded(.down))
    return "正在下载 \(version)：\(percent)%（\(written) / \(expected)）"
  }

}
