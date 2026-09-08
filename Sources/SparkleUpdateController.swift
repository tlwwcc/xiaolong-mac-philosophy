import Foundation
import Sparkle

enum SparkleUpdateState: Equatable {
  case ready
  case checking
  case found(displayVersion: String)
  case current
  case failed(message: String)
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
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
  private let stateHandler: (SparkleUpdateState) -> Void
  private let customerVersionDisplay = CustomerSparkleVersionDisplay()
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: self,
    userDriverDelegate: nil)
  private var started = false

  init(stateHandler: @escaping (SparkleUpdateState) -> Void) {
    self.stateHandler = stateHandler
    super.init()
  }

  func start() {
    startIfNeeded()
  }

  private func startIfNeeded() {
    guard !started else { return }
    started = true
    controller.startUpdater()
    stateHandler(.ready)
  }

  func checkForUpdates() {
    // Free base updates remain available while account recovery is unavailable. Release metadata
    // and the signed update are still checked immediately before installation.
    startIfNeeded()
    stateHandler(.checking)
    controller.checkForUpdates(nil)
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

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    stateHandler(.current)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    let nsError = error as NSError
    if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {
      stateHandler(.current)
      return
    }
    stateHandler(.failed(message: "暂时无法完成更新检查，请稍后重试。"))
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
