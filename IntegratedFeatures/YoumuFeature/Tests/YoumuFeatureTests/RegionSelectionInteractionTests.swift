import AppKit
import XCTest

@testable import YoumuFeature

@MainActor
final class RegionSelectionInteractionTests: XCTestCase {
  func testLongCaptureDiagnosticsPersistAndRotateInDedicatedJSONL() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("youmu-long-capture-log-\(UUID().uuidString)")
    let logURL = root.appendingPathComponent("long-capture.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }

    PrivacySafeLog.appendLongCaptureEvent(
      name: "long_capture_test_first",
      metadata: ["segments": 2],
      logURL: logURL,
      maximumBytes: 1
    )
    PrivacySafeLog.appendLongCaptureEvent(
      name: "long_capture_test_second",
      metadata: ["segments": 3],
      logURL: logURL,
      maximumBytes: 1
    )

    let current = try String(contentsOf: logURL, encoding: .utf8)
    let backup = try String(
      contentsOf: logURL.appendingPathExtension("1"),
      encoding: .utf8
    )
    XCTAssertTrue(current.contains("long_capture_test_second"))
    XCTAssertTrue(current.contains("\"segments\":3"))
    XCTAssertTrue(backup.contains("long_capture_test_first"))
    XCTAssertFalse(current.contains("http"))
  }

  func testLongScreenshotExposesStartActionAndBlocksPreflightScroll() {
    let policy = CaptureConfirmationPolicy.resolve(
      mode: .longScreenshot,
      settings: AppSettings()
    )

    XCTAssertTrue(policy.spaceConfirmsSelection)
    XCTAssertFalse(policy.confirmOnMouseUp)
    XCTAssertTrue(policy.showsExplicitStartAction)
    XCTAssertTrue(policy.blocksScrollBeforeConfirmation)
  }

  func testOrdinaryCaptureModesDoNotInheritLongScreenshotPreflightBehavior() {
    for mode in TranslateMode.allCases where mode != .longScreenshot {
      let policy = CaptureConfirmationPolicy.resolve(mode: mode, settings: AppSettings())
      XCTAssertFalse(policy.showsExplicitStartAction, mode.rawValue)
      XCTAssertFalse(policy.blocksScrollBeforeConfirmation, mode.rawValue)
    }
  }

  func testQuickSnapshotDefaultsToSubmitOnMouseUpWithoutConfirmation() {
    let policy = CaptureConfirmationPolicy.resolve(
      mode: .quickSnapshot,
      settings: AppSettings()
    )

    XCTAssertFalse(policy.spaceConfirmsSelection)
    XCTAssertTrue(policy.confirmOnMouseUp)
  }

  func testQuickSnapshotCanStillOptIntoSpaceConfirmation() {
    var settings = AppSettings()
    settings.quickSnapshotRequiresConfirmation = true
    let policy = CaptureConfirmationPolicy.resolve(mode: .quickSnapshot, settings: settings)

    XCTAssertTrue(policy.spaceConfirmsSelection)
    XCTAssertFalse(policy.confirmOnMouseUp)
  }

  func testConfirmationActionStaysOnScreenForEdgeToEdgeSelection() {
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let action = SelectionConfirmationLayout.actionRect(for: bounds, within: bounds)

    XCTAssertTrue(bounds.contains(action))
    XCTAssertEqual(action.size, SelectionConfirmationLayout.actionSize)
    XCTAssertTrue(action.intersects(bounds))
  }

  func testConfirmationActionPrefersOutsideSelectionWhenSpaceExists() {
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let selection = CGRect(x: 220, y: 180, width: 900, height: 600)
    let action = SelectionConfirmationLayout.actionRect(for: selection, within: bounds)

    XCTAssertFalse(action.intersects(selection))
    XCTAssertTrue(bounds.contains(action))
  }

  func testStartButtonSubmitsLockedSelection() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let view = SelectionView(frame: bounds)
    view.confirmationActionTitle = "开始长截图"
    let panel = NSPanel(
      contentRect: bounds,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = view
    var submittedRegions: [CGRect] = []
    view.onDragComplete = { submittedRegions.append($0) }

    view.handleMouseDown(at: CGPoint(x: 120, y: 120), clickCount: 1)
    view.handleMouseDragged(to: CGPoint(x: 620, y: 480))
    view.handleMouseUp(at: CGPoint(x: 620, y: 480))
    XCTAssertTrue(view.isSelectionLocked)
    XCTAssertTrue(submittedRegions.isEmpty)

    let buttonCenter = CGPoint(
      x: view.confirmationActionRect.midX,
      y: view.confirmationActionRect.midY
    )
    view.handleMouseDown(at: buttonCenter, clickCount: 1)
    view.handleMouseUp(at: buttonCenter)

    XCTAssertEqual(submittedRegions.count, 1)
    XCTAssertEqual(submittedRegions[0].size, CGSize(width: 500, height: 360))
  }

  func testSelectionAcceptsPlainSpaceReturnAndKeypadEnterExactlyOnce() {
    for keyCode: UInt16 in [49, 36, 76] {
      let (view, panel) = makeLockedSelectionView()
      _ = panel
      var submittedRegions: [CGRect] = []
      view.onDragComplete = { submittedRegions.append($0) }

      for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function] {
        view.handleKeyDown(keyCode: keyCode, modifiers: modifiers)
      }
      XCTAssertTrue(submittedRegions.isEmpty, "keyCode=\(keyCode)")

      // 按住产生的重复 keyDown 与随后另一确认键，都不能二次提交。
      view.handleKeyDown(keyCode: keyCode, modifiers: [])
      view.handleKeyDown(keyCode: keyCode, modifiers: [])
      view.handleKeyDown(keyCode: 49, modifiers: [])
      XCTAssertEqual(submittedRegions.count, 1, "keyCode=\(keyCode)")
      XCTAssertTrue(view.hasSubmittedSelection)
      XCTAssertEqual(submittedRegions[0].size, CGSize(width: 500, height: 360))
    }
  }

  func testDoubleClickInsideSelectionConfirmsOnceWithoutTailMouseUpReplay() {
    let (view, panel) = makeLockedSelectionView()
    _ = panel
    var submittedRegions: [CGRect] = []
    view.onDragComplete = { submittedRegions.append($0) }
    let inside = CGPoint(x: 300, y: 260)

    // 真实双击的第一击仍是普通 clickCount=1，第二击才提交。
    view.handleMouseDown(at: inside, clickCount: 1)
    view.handleMouseUp(at: inside)
    XCTAssertTrue(submittedRegions.isEmpty)
    view.handleMouseDown(at: inside, clickCount: 2)
    view.handleMouseUp(at: inside)
    view.handleMouseDown(at: inside, clickCount: 2)

    XCTAssertEqual(submittedRegions.count, 1)
    XCTAssertTrue(view.hasSubmittedSelection)
  }

  func testDoubleClickOutsideSelectionStartsReplacementInsteadOfConfirming() {
    let (view, panel) = makeLockedSelectionView()
    _ = panel
    var submittedRegions: [CGRect] = []
    view.onDragComplete = { submittedRegions.append($0) }

    view.handleMouseDown(at: CGPoint(x: 40, y: 40), clickCount: 2)
    view.handleMouseUp(at: CGPoint(x: 70, y: 70))

    XCTAssertTrue(submittedRegions.isEmpty)
    XCTAssertFalse(view.hasSubmittedSelection)
  }

  func testSingleCompletionButtonAcceptsTheFirstMouseAndUsesExplicitContrast() {
    let finish = ScrollCaptureActionButton(title: "完成", emphasis: .secondary)

    XCTAssertTrue(finish.acceptsFirstMouse(for: nil))
    XCTAssertFalse(finish.isBordered)
    XCTAssertNotNil(finish.layer?.backgroundColor)
    XCTAssertEqual(
      finish.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        as? NSColor,
      NSColor.black)
    XCTAssertGreaterThanOrEqual(
      contrastRatio(
        ScrollCaptureActionButton.secondaryForegroundColor,
        ScrollCaptureActionButton.secondaryBackgroundColor),
      4.5)
  }

  func testBoundaryStatusAndPreviewPanelFactoryNeverInterceptsTheMouse() {
    let panel = ScrollCaptureController.makePassivePanel(
      frame: CGRect(x: 100, y: 100, width: 300, height: 200),
      cornerRadius: 8)
    defer { panel.close() }

    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertEqual(panel.sharingType, .none)
  }

  func testCaptureControlsStayOutsideTheBlueRegionWhenScreenSpaceExists() {
    let quartzRegion = CGRect(x: 280, y: 220, width: 720, height: 480)
    let appKitRegion = ScrollCapturePanelLayout.appKitFrame(for: quartzRegion)
    let controls = ScrollCapturePanelLayout.outsideFrame(
      for: quartzRegion,
      size: NSSize(width: 88, height: 32),
      role: .controls)
    XCTAssertFalse(controls.intersects(appKitRegion))
  }

  func testPreflightScrollIsConsumedOnlyForLiveExplicitConfirmation() {
    XCTAssertTrue(SelectionPreflightInputPolicy.consumesScroll(
      blocksScrollBeforeConfirmation: true,
      isFrozen: false
    ))
    XCTAssertFalse(SelectionPreflightInputPolicy.consumesScroll(
      blocksScrollBeforeConfirmation: false,
      isFrozen: false
    ))
    XCTAssertFalse(SelectionPreflightInputPolicy.consumesScroll(
      blocksScrollBeforeConfirmation: true,
      isFrozen: true
    ))
  }

  private func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func makeLockedSelectionView() -> (SelectionView, NSPanel) {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let view = SelectionView(frame: bounds)
    view.spaceConfirmsSelection = true
    let panel = NSPanel(
      contentRect: bounds,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = view
    view.handleMouseDown(at: CGPoint(x: 120, y: 120), clickCount: 1)
    view.handleMouseDragged(to: CGPoint(x: 620, y: 480))
    view.handleMouseUp(at: CGPoint(x: 620, y: 480))
    XCTAssertTrue(view.isSelectionLocked)
    return (view, panel)
  }

  private func relativeLuminance(_ color: NSColor) -> CGFloat {
    let converted = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func linear(_ component: CGFloat) -> CGFloat {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }
}
