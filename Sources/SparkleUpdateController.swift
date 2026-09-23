import AppKit
import Sparkle

enum SparkleUpdateState: Equatable {
  case ready
  case checking
  case found(displayVersion: String)
  case current
  case aheadOfRelease(displayVersion: String?)
  case failed(message: String)
}

enum SparkleUpdateResultPolicy {
  static func state(for error: NSError) -> SparkleUpdateState {
    guard error.domain == SUSparkleErrorDomain,
      error.code == SUError.noUpdateError.rawValue
    else {
      return .failed(message: "暂时无法完成更新检查，请重试，或下载完整安装包。")
    }
    guard let rawReason = error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
      let reason = SPUNoUpdateFoundReason(rawValue: rawReason.int32Value)
    else {
      return .failed(message: "暂时无法确认可用版本，请重新检查更新。")
    }
    let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
    switch reason {
    case .onLatestVersion:
      // Sparkle also uses this reason for an empty or inapplicable feed. Only an actual
      // matching item proves that the installed version is the latest published version.
      guard item != nil else {
        return .failed(message: "更新列表暂时没有可用版本，请稍后重新检查。")
      }
      return .current
    case .onNewerThanLatestVersion:
      return .aheadOfRelease(
        displayVersion: item.map {
          CustomerVersionFormatter.updateVersion($0.displayVersionString)
        })
    case .systemIsTooOld:
      return .failed(message: "新版本需要更高版本的 macOS；升级系统后再检查更新。当前版本可继续使用。")
    case .systemIsTooNew:
      return .failed(message: "新版本暂不支持当前 macOS，请保留当前版本并稍后检查更新。")
    case .hardwareDoesNotSupportARM64:
      return .failed(message: "此更新适用于 Apple 芯片，当前 Intel Mac 暂无可用更新。")
    case .unknown:
      return .failed(message: "暂时无法确认可用版本，请重新检查更新。")
    @unknown default:
      return .failed(message: "暂时无法确认可用版本，请重新检查更新。")
    }
  }
}

@MainActor
enum CustomerSparkleNoUpdateAlert {
  static func make(error: NSError, currentVersion: String) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .informational
    let current = CustomerVersionFormatter.updateVersion(currentVersion)
    switch SparkleUpdateResultPolicy.state(for: error) {
    case .current:
      alert.messageText = "当前已是最新版本"
      alert.informativeText = "本机版本 \(current)，与公开版本一致。"
    case .aheadOfRelease(let published):
      alert.messageText = "当前版本比公开版更新"
      if let published {
        alert.informativeText = "本机版本 \(current)，公开版本 \(published)。无需更新，可继续使用。"
      } else {
        alert.informativeText = "本机版本 \(current) 已领先于公开更新，无需更新，可继续使用。"
      }
    case .failed(let message):
      alert.messageText = "暂时没有可用更新"
      alert.informativeText = message
    case .ready, .checking, .found:
      alert.messageText = "暂时无法确认更新结果"
      alert.informativeText = "请稍后重新检查更新。"
    }
    alert.addButton(withTitle: "好")
    return alert
  }
}

@MainActor
final class CustomerSparkleUserDriver: SPUStandardUserDriver {
  override func showUpdateNotFoundWithError(
    _ error: any Error, acknowledgement: @escaping () -> Void
  ) {
    // This public cleanup also closes the standard checking window. The updater will
    // finish its session after acknowledgement; all download/install UI stays standard.
    dismissUpdateInstallation()
    let alert = CustomerSparkleNoUpdateAlert.make(
      error: error as NSError,
      currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "")
    defer { acknowledgement() }
    alert.runModal()
  }
}

final class CustomerSparkleVersionDisplay: NSObject, SUVersionDisplay {
  func formatUpdateVersion(
    fromUpdate update: SUAppcastItem,
    andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
    withBundleVersion bundleVersion: String
  ) -> String {
    let bundleDisplayVersion = inOutBundleDisplayVersion.pointee as String
    inOutBundleDisplayVersion.pointee =
      CustomerVersionFormatter.updateVersion(bundleDisplayVersion) as NSString
    return CustomerVersionFormatter.updateVersion(update.displayVersionString)
  }

  func formatBundleDisplayVersion(
    _ bundleDisplayVersion: String,
    withBundleVersion bundleVersion: String,
    matchingUpdate: SUAppcastItem?
  ) -> String {
    CustomerVersionFormatter.updateVersion(bundleDisplayVersion)
  }
}

@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate,
  @preconcurrency SPUStandardUserDriverDelegate
{
  private let stateHandler: (SparkleUpdateState) -> Void
  private let customerVersionDisplay = CustomerSparkleVersionDisplay()
  private lazy var userDriver = CustomerSparkleUserDriver(hostBundle: .main, delegate: self)
  private lazy var updater = SPUUpdater(
    hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
  private var started = false

  init(stateHandler: @escaping (SparkleUpdateState) -> Void) {
    self.stateHandler = stateHandler
    super.init()
  }

  func start() {
    startIfNeeded()
  }

  @discardableResult
  private func startIfNeeded() -> Bool {
    guard !started else { return true }
    do {
      // Version monitoring is part of the product default. Keep the published default active
      // even when an older install carried an unset or stale Sparkle preference.
      updater.automaticallyChecksForUpdates = true
      try updater.start()
      started = true
      stateHandler(.ready)
      return true
    } catch {
      stateHandler(SparkleUpdateResultPolicy.state(for: error as NSError))
      return false
    }
  }

  func checkForUpdates() {
    // Free base updates remain available while account recovery is unavailable. Release metadata
    // and the signed update are still checked immediately before installation.
    guard startIfNeeded() else { return }
    stateHandler(.checking)
    updater.checkForUpdates()
  }

  func updater(
    _ updater: SPUUpdater,
    shouldProceedWithUpdate updateItem: SUAppcastItem,
    updateCheck: SPUUpdateCheck
  ) throws {
    guard let releaseDate = updateItem.date else {
      throw updateDenial("更新发布时间缺失或无效，已安全停止。")
    }
    let publishedAt = ISO8601DateFormatter().string(from: releaseDate)
    let decision = UpdateReleasePolicy.decision(publishedAt: publishedAt)
    if let denial = decision.denialMessage {
      throw updateDenial(denial)
    }
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    stateHandler(
      .found(
        displayVersion: CustomerVersionFormatter.updateVersion(item.displayVersionString)))
  }

  @objc(versionDisplayerForUpdater:)
  func versionDisplayer(for updater: SPUUpdater) -> (any SUVersionDisplay)? {
    customerVersionDisplay
  }

  func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
    customerVersionDisplay
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    stateHandler(SparkleUpdateResultPolicy.state(for: error as NSError))
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    let nsError = error as NSError
    if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {
      stateHandler(SparkleUpdateResultPolicy.state(for: nsError))
      return
    }
    stateHandler(SparkleUpdateResultPolicy.state(for: nsError))
    AppDiagnostics.log(
      "sparkle_update_aborted",
      ["domain": nsError.domain, "code": "\(nsError.code)"])
  }

  private func updateDenial(_ message: String) -> NSError {
    NSError(
      domain: "cn.tlww.aixlg.hotkeys.sparkle",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
