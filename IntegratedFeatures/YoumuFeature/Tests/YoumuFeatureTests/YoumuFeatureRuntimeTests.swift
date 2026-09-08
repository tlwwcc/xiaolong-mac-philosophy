import BuiltinFeatureCatalog
import Foundation
import PlatformContracts
import XCTest

@testable import YoumuFeature

@MainActor
final class YoumuFeatureRuntimeTests: XCTestCase {
  private let expectedMappings: [(CommandID, YoumuCaptureMode, TranslateMode)] = [
    (YoumuFeatureIDs.quickSnapshot, .quickSnapshot, .quickSnapshot),
    (YoumuFeatureIDs.annotatedScreenshot, .annotatedScreenshot, .screenshotEdit),
    (YoumuFeatureIDs.longScreenshot, .longScreenshot, .longScreenshot),
    (YoumuFeatureIDs.pinScreenshot, .pinScreenshot, .pinClipboard),
    (YoumuFeatureIDs.selectionReader, .selectionReader, .selectionReader),
    (YoumuFeatureIDs.imageTranslate, .imageTranslate, .imageTranslate),
    (YoumuFeatureIDs.ocrTranslate, .ocrTranslate, .screenshotTranslate),
    (YoumuFeatureIDs.ocrCopy, .ocrCopy, .silentOCR),
  ]

  func testEightStableCommandIDsMapToEightCaptureModes() {
    XCTAssertEqual(expectedMappings.count, 8)
    XCTAssertEqual(Set(expectedMappings.map(\.0)).count, 8)
    XCTAssertEqual(Set(expectedMappings.map(\.1)).count, 8)

    for (commandID, featureMode, _) in expectedMappings {
      XCTAssertEqual(
        YoumuFeatureRuntime.captureMode(for: commandID.rawValue),
        featureMode,
        commandID.rawValue
      )
    }
  }

  func testExecuteDispatchesEveryCommandToRealModeBoundary() throws {
    let environment = testEnvironment(channelRoot: "aixlg-hotkeys-dev")
    var received: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(environment: environment) { mode in
      received.append(mode)
    }

    for (commandID, _, expectedMode) in expectedMappings {
      try runtime.execute(commandID: commandID)
      XCTAssertEqual(received.last, expectedMode, commandID.rawValue)
    }
    XCTAssertEqual(received.count, 8)
  }

  func testUnknownCommandFailsClosedWithoutStartingCapture() {
    var received: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(environment: testEnvironment()) { mode in
      received.append(mode)
    }

    XCTAssertThrowsError(try runtime.execute(commandID: "unknown.command")) { error in
      XCTAssertEqual(
        error as? YoumuFeatureRuntimeError,
        .unsupportedCommandID("unknown.command")
      )
    }
    XCTAssertTrue(received.isEmpty)
  }

  func testStableAndDevelopmentStorageAndKeychainAreSeparated() {
    let root = URL(fileURLWithPath: "/tmp/youmu-feature-tests", isDirectory: true)
    let stable = YoumuFeatureEnvironment(
      hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
      channelRoot: "aixlg-hotkeys",
      applicationSupportRoot: root,
      temporaryRoot: root
    )
    let development = YoumuFeatureEnvironment(
      hostBundleIdentifier: YoumuFeatureEnvironment.developmentHostBundleIdentifier,
      channelRoot: "aixlg-hotkeys-dev",
      applicationSupportRoot: root,
      temporaryRoot: root
    )

    XCTAssertEqual(
      stable.settingsURL.path,
      "/tmp/youmu-feature-tests/aixlg-hotkeys/Features/Youmu/settings.json"
    )
    XCTAssertEqual(
      development.settingsURL.path,
      "/tmp/youmu-feature-tests/aixlg-hotkeys-dev/Features/Youmu/settings.json"
    )
    XCTAssertNotEqual(stable.settingsURL, development.settingsURL)
    XCTAssertNotEqual(stable.translationKeychainService, development.translationKeychainService)
    XCTAssertEqual(
      stable.translationKeychainService,
      "cn.tlww.aixlg.hotkeys.feature.youmu.translation-credentials"
    )
    XCTAssertEqual(
      development.translationKeychainService,
      "cn.tlww.aixlg.hotkeys.dev.feature.youmu.translation-credentials"
    )
  }

  func testChannelInferenceSeparatesDevelopmentAutomatically() {
    XCTAssertEqual(
      YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
        buildChannel: "stable"
      ),
      "aixlg-hotkeys"
    )
    XCTAssertEqual(
      YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.developmentHostBundleIdentifier,
        buildChannel: nil
      ),
      "aixlg-hotkeys-dev"
    )
    XCTAssertEqual(
      YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
        buildChannel: "development"
      ),
      "aixlg-hotkeys-dev"
    )
  }

  func testDefaultsNotificationsPasteboardAndTemporaryFilesAreNamespaced() {
    let environment = testEnvironment()
    XCTAssertTrue(environment.userDefaultsKey("consent").contains(".feature.youmu."))
    XCTAssertTrue(environment.notificationName("speech").rawValue.contains(".feature.youmu."))
    XCTAssertTrue(environment.pasteboardPixelScaleType.contains(".feature.youmu."))
    XCTAssertTrue(environment.temporaryDirectory.lastPathComponent.contains(".feature.youmu."))
  }

  func testMainInterfaceIsHostInjected() throws {
    var didOpen = false
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      openMainInterface: { didOpen = true },
      captureHandler: { _ in }
    )
    try runtime.openMainInterface()
    XCTAssertTrue(didOpen)

    let missingRoute = YoumuFeatureRuntime(
      environment: testEnvironment(),
      captureHandler: { _ in }
    )
    XCTAssertThrowsError(try missingRoute.openMainInterface()) { error in
      XCTAssertEqual(
        error as? YoumuFeatureRuntimeError,
        .hostManagedInterfaceUnavailable
      )
    }
  }

  func testHostCanCancelActiveGlobalInputSessionsBeforeYieldingLease() {
    var invalidations: [YoumuCommandSessionInvalidationReason] = []
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      invalidationHandler: { invalidations.append($0) },
      captureHandler: { _ in }
    )

    runtime.cancelActiveGlobalInputSessions()

    XCTAssertEqual(invalidations, [.globalInputOwnershipYielded])
  }

  func testHostCanPreflightExactModeCancellationBeforeAccessGates() {
    var checked: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      cancelIfActiveHandler: { mode in
        checked.append(mode)
        return mode == .screenshotTranslate
      },
      captureHandler: { _ in XCTFail("preflight must not start a new capture") }
    )

    XCTAssertTrue(runtime.cancelIfActive(commandID: YoumuFeatureIDs.ocrTranslate))
    XCTAssertFalse(runtime.cancelIfActive(commandID: "unknown.command"))
    XCTAssertEqual(checked, [.screenshotTranslate])
  }

  func testHostForwardsTargetedLifecycleInvalidationReasons() {
    var invalidations: [YoumuCommandSessionInvalidationReason] = []
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      invalidationHandler: { invalidations.append($0) },
      captureHandler: { _ in }
    )

    runtime.invalidateCommandSessions(for: .proEntitlementLost)
    runtime.invalidateCommandSessions(for: .screenRecordingPermissionLost)
    runtime.invalidateCommandSessions(for: .inputMonitoringPermissionLost)
    runtime.cancelAllCommandSessions()

    XCTAssertEqual(
      invalidations,
      [
        .proEntitlementLost,
        .screenRecordingPermissionLost,
        .inputMonitoringPermissionLost,
        .globalInputOwnershipYielded,
      ]
    )
  }

  private func testEnvironment(
    channelRoot: String = "aixlg-hotkeys-dev"
  ) -> YoumuFeatureEnvironment {
    let root = URL(fileURLWithPath: "/tmp/youmu-feature-tests", isDirectory: true)
    return YoumuFeatureEnvironment(
      hostBundleIdentifier: YoumuFeatureEnvironment.developmentHostBundleIdentifier,
      channelRoot: channelRoot,
      applicationSupportRoot: root,
      temporaryRoot: root,
      userDefaultsSuiteName: "cn.tlww.aixlg.hotkeys.dev.feature.youmu.tests"
    )
  }
}
