import BuiltinFeatureCatalog
import Foundation
import PlatformContracts
import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class YoumuFeatureRuntimeTests {
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

  @Test
  func testEightStableCommandIDsMapToEightCaptureModes() {
    #expect((expectedMappings.count) == (8))
    #expect((Set(expectedMappings.map(\.0)).count) == (8))
    #expect((Set(expectedMappings.map(\.1)).count) == (8))

    for (commandID, featureMode, _) in expectedMappings {
      #expect((YoumuFeatureRuntime.captureMode(for: commandID.rawValue)) == (featureMode), Comment(rawValue: commandID.rawValue))
    }
  }

  @Test
  func testExecuteDispatchesEveryCommandToRealModeBoundary() throws {
    let environment = testEnvironment(channelRoot: "aixlg-hotkeys-dev")
    var received: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(environment: environment) { mode in
      received.append(mode)
    }

    for (commandID, _, expectedMode) in expectedMappings {
      try runtime.execute(commandID: commandID)
      #expect((received.last) == (expectedMode), Comment(rawValue: commandID.rawValue))
    }
    #expect((received.count) == (8))
  }

  @Test
  func testUnknownCommandFailsClosedWithoutStartingCapture() {
    var received: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(environment: testEnvironment()) { mode in
      received.append(mode)
    }

    expectThrowsError(try runtime.execute(commandID: "unknown.command")) { error in
      #expect((error as? YoumuFeatureRuntimeError) == (.unsupportedCommandID("unknown.command")))
    }
    #expect(received.isEmpty)
  }

  @Test
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

    #expect((stable.settingsURL.path) == ("/tmp/youmu-feature-tests/aixlg-hotkeys/Features/Youmu/settings.json"))
    #expect((development.settingsURL.path) == ("/tmp/youmu-feature-tests/aixlg-hotkeys-dev/Features/Youmu/settings.json"))
    #expect((stable.settingsURL) != (development.settingsURL))
    #expect((stable.translationKeychainService) != (development.translationKeychainService))
    #expect((stable.translationKeychainService) == ("cn.tlww.aixlg.hotkeys.feature.youmu.translation-credentials"))
    #expect((development.translationKeychainService) == ("cn.tlww.aixlg.hotkeys.dev.feature.youmu.translation-credentials"))
  }

  @Test
  func testChannelInferenceSeparatesDevelopmentAutomatically() {
    #expect((YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
        buildChannel: "stable"
      )) == ("aixlg-hotkeys"))
    #expect((YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.developmentHostBundleIdentifier,
        buildChannel: nil
      )) == ("aixlg-hotkeys-dev"))
    #expect((YoumuFeatureEnvironment.inferredChannelRoot(
        hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
        buildChannel: "development"
      )) == ("aixlg-hotkeys-dev"))
  }

  @Test
  func testDefaultsNotificationsPasteboardAndTemporaryFilesAreNamespaced() {
    let environment = testEnvironment()
    #expect(environment.userDefaultsKey("consent").contains(".feature.youmu."))
    #expect(environment.notificationName("speech").rawValue.contains(".feature.youmu."))
    #expect(environment.pasteboardPixelScaleType.contains(".feature.youmu."))
    #expect(environment.temporaryDirectory.lastPathComponent.contains(".feature.youmu."))
  }

  @Test
  func testMainInterfaceIsHostInjected() throws {
    var didOpen = false
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      openMainInterface: { didOpen = true },
      captureHandler: { _ in }
    )
    try runtime.openMainInterface()
    #expect(didOpen)

    let missingRoute = YoumuFeatureRuntime(
      environment: testEnvironment(),
      captureHandler: { _ in }
    )
    expectThrowsError(try missingRoute.openMainInterface()) { error in
      #expect((error as? YoumuFeatureRuntimeError) == (.hostManagedInterfaceUnavailable))
    }
  }

  @Test
  func testHostCanCancelActiveGlobalInputSessionsBeforeYieldingLease() {
    var invalidations: [YoumuCommandSessionInvalidationReason] = []
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      invalidationHandler: { invalidations.append($0) },
      captureHandler: { _ in }
    )

    runtime.cancelActiveGlobalInputSessions()

    #expect((invalidations) == ([.globalInputOwnershipYielded]))
  }

  @Test
  func testHostCanPreflightExactModeCancellationBeforeAccessGates() {
    var checked: [TranslateMode] = []
    let runtime = YoumuFeatureRuntime(
      environment: testEnvironment(),
      cancelIfActiveHandler: { mode in
        checked.append(mode)
        return mode == .screenshotTranslate
      },
      captureHandler: { _ in Issue.record(Comment(rawValue: "preflight must not start a new capture")) }
    )

    #expect(runtime.cancelIfActive(commandID: YoumuFeatureIDs.ocrTranslate))
    #expect(!(runtime.cancelIfActive(commandID: "unknown.command")))
    #expect((checked) == ([.screenshotTranslate]))
  }

  @Test
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

    #expect((invalidations) == ([
        .proEntitlementLost,
        .screenRecordingPermissionLost,
        .inputMonitoringPermissionLost,
        .globalInputOwnershipYielded,
      ]))
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
