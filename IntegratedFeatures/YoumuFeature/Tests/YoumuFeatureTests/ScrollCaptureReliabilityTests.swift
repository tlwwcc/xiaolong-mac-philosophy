import AppKit
import XCTest

@testable import YoumuFeature

@MainActor
final class ScrollCaptureReliabilityTests: XCTestCase {
  func testCaptureGateRejectsSecondLongScreenshotSession() {
    XCTAssertTrue(
      CaptureSessionGate.canStart(
        hasSelection: false,
        hasInPlaceSession: false,
        hasLongScreenshotSession: false))
    XCTAssertFalse(
      CaptureSessionGate.canStart(
        hasSelection: false,
        hasInPlaceSession: false,
        hasLongScreenshotSession: true))
  }

  func testSelectionResolvesTheExactWindowBelowTheRegion() throws {
    let hostPID: pid_t = 100
    let browserPID: pid_t = 200
    let candidates = [
      RegionSelectionWindowCandidate(
        ownerProcessIdentifier: browserPID,
        windowID: 42,
        bounds: CGRect(x: 0, y: 0, width: 1_200, height: 900)),
      RegionSelectionWindowCandidate(
        ownerProcessIdentifier: 300,
        windowID: 73,
        bounds: CGRect(x: 1_300, y: 0, width: 900, height: 900)),
    ]

    let selected = try XCTUnwrap(
      RegionSelectionSourceResolver.preferredCandidate(
        for: CGRect(x: 120, y: 140, width: 800, height: 600),
        candidates: candidates,
        hostProcessIdentifier: hostPID))

    XCTAssertEqual(selected.ownerProcessIdentifier, browserPID)
    XCTAssertEqual(selected.windowID, 42)
  }

  func testSelectedWindowGateRejectsAnotherFrontWindowFromTheSameBrowserProcess() {
    let region = CGRect(x: 100, y: 100, width: 500, height: 400)
    let selected = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 200,
      windowID: 42,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
    let otherFrontWindow = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 200,
      windowID: 99,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))

    XCTAssertFalse(
      ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [otherFrontWindow, selected],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
    XCTAssertTrue(
      ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [selected, otherFrontWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
  }

  func testSelectedWindowGateRejectsAHostWindowCoveringTheSelection() {
    let region = CGRect(x: 100, y: 100, width: 500, height: 400)
    let hostWindow = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 100,
      windowID: 7,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
    let selectedSourceWindow = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 200,
      windowID: 42,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))

    XCTAssertFalse(
      ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [hostWindow, selectedSourceWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
  }

  func testExactSelectedWindowGateDoesNotDependOnTheFrontmostApplication() {
    let selectedSourceWindow = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 200,
      windowID: 42,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))

    XCTAssertTrue(
      ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: CGRect(x: 100, y: 100, width: 500, height: 400),
        candidates: [selectedSourceWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
  }

  func testPlainSpaceKeyDownFinishesAndIsConsumed() {
    XCTAssertEqual(
      ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false),
      .consumeAndDispatch(.finish))
  }

  func testPlainSpaceKeyUpIsConsumedWithoutDispatchingAgain() {
    XCTAssertEqual(
      ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyUp,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false),
      .consume)
  }

  func testRepeatedPlainSpaceKeyDownIsConsumedWithoutDispatchingAgain() {
    XCTAssertEqual(
      ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: true),
      .consume)
  }

  func testModifiedSpacePassesThroughToTheSourceApplication() {
    for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
      XCTAssertEqual(
        ScrollCaptureCommandPolicy.disposition(
          keyCode: 49,
          flags: flags,
          eventType: .keyDown,
          isCapturing: true,
          isFinishing: false,
          isRepeat: false),
        .passThrough,
        "flags=\(flags.rawValue)")
    }
  }

  func testPlainSpaceRemainsConsumedWhileFinishing() {
    for eventType: CGEventType in [.keyDown, .keyUp] {
      XCTAssertEqual(
        ScrollCaptureCommandPolicy.disposition(
          keyCode: 49,
          flags: [],
          eventType: eventType,
          isCapturing: false,
          isFinishing: true,
          isRepeat: false),
        .consume,
        "eventType=\(eventType.rawValue)")
    }
  }

  func testConsumedSpaceKeyUpStaysConsumedWhenModifierAppearsMidPress() {
    var router = ScrollCaptureCommandRouter()
    XCTAssertEqual(
      router.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false),
      .consumeAndDispatch(.finish))
    XCTAssertEqual(
      router.disposition(
        keyCode: 49,
        flags: .maskCommand,
        eventType: .keyUp,
        isCapturing: false,
        isFinishing: true,
        isRepeat: false),
      .consume)
  }

  func testPassedModifiedSpaceKeyUpStaysPassedWhenModifierLeavesMidPress() {
    var router = ScrollCaptureCommandRouter()
    XCTAssertEqual(
      router.disposition(
        keyCode: 49,
        flags: .maskCommand,
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false),
      .passThrough)
    XCTAssertEqual(
      router.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyUp,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false),
      .passThrough)
  }

  func testThirtyCompleteFramesCanClaimTheFirstBaselineOnlyOnce() {
    var gate = ScrollCaptureFirstCompleteFrameGate()
    var claims = 0
    for _ in 0..<30 where gate.claim() { claims += 1 }
    XCTAssertEqual(claims, 1)
    XCTAssertTrue(gate.hasClaimedFrame)
    gate.reset()
    XCTAssertTrue(gate.claim())
  }

  func testStreamSourceRectUsesQuartzTopLeftCoordinatesWithoutASecondYFlip() throws {
    XCTAssertEqual(
      try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: 120, y: 180, width: 800, height: 600),
        displayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)),
      CGRect(x: 120, y: 180, width: 800, height: 600))

    XCTAssertEqual(
      try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: -1_800, y: 260, width: 500, height: 400),
        displayBounds: CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080)),
      CGRect(x: 120, y: 160, width: 500, height: 400))
  }

  func testStreamSourceRectRejectsASelectionThatCrossesDisplays() {
    XCTAssertThrowsError(
      try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: 1_300, y: 100, width: 300, height: 400),
        displayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900))) { error in
          guard case ScrollCaptureStreamError.regionCrossesDisplays = error else {
            return XCTFail("unexpected error: \(error)")
          }
        }
  }

  func testRetinaStreamOutputKeepsNativePixelDensity() {
    XCTAssertEqual(
      ScrollCaptureStreamGeometry.fallbackPointPixelScale(
        pixelWidth: 3_840,
        pixelHeight: 2_160,
        displayBounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
      2)
    XCTAssertEqual(
      ScrollCaptureStreamGeometry.outputPixelSize(
        sourceRect: CGRect(x: 0, y: 0, width: 232, height: 519),
        pointPixelScale: 2),
      CGSize(width: 464, height: 1_038))
    XCTAssertEqual(ScrollCapturePolicy.firstCompleteFrameTimeout, 4)
  }

  func testFrameRingKeepsOnlyEightNewestCompleteFrames() throws {
    let image = try XCTUnwrap(makeSolidImage(width: 12, height: 12, gray: 80))
    var ring = ScrollCaptureFrameRing(capacity: 8)

    for sequence in 1...12 {
      ring.append(
        ScrollCaptureStreamFrame(
          sequenceNumber: sequence,
          image: image,
          capturedAt: Double(sequence),
          displayTime: UInt64(sequence),
          containsVisualChange: true))
    }

    XCTAssertEqual(ring.frames.map(\.sequenceNumber), Array(5...12))
    XCTAssertEqual(ring.latest(after: 10)?.sequenceNumber, 12)
    XCTAssertEqual(ring.latest(after: 6, through: 9)?.sequenceNumber, 9)
    XCTAssertNil(ring.latest(after: 9, through: 9))
    XCTAssertNil(ring.latest(after: 12))
  }

  func testFrameRingOrdersOutOfOrderDeliveriesBySequence() throws {
    let image = try XCTUnwrap(makeSolidImage(width: 12, height: 12, gray: 80))
    var ring = ScrollCaptureFrameRing(capacity: 8)
    for sequence in [3, 1, 2] {
      ring.append(
        ScrollCaptureStreamFrame(
          sequenceNumber: sequence,
          image: image,
          capturedAt: Double(sequence),
          displayTime: UInt64(sequence),
          containsVisualChange: true))
    }
    XCTAssertEqual(ring.frames.map(\.sequenceNumber), [1, 2, 3])
    XCTAssertEqual(ring.latest(after: 0)?.sequenceNumber, 3)
    XCTAssertEqual(ring.oldest(after: 0)?.sequenceNumber, 1)
    XCTAssertEqual(ring.earliest(after: 1)?.sequenceNumber, 2)
    XCTAssertEqual(ring.ordered(after: 0).map(\.sequenceNumber), [1, 2, 3])
  }

  func testFrameRingRejectsPreEventDisplayTimesAndKeepsFIFOOrder() throws {
    let image = try XCTUnwrap(makeSolidImage(width: 12, height: 12, gray: 80))
    var ring = ScrollCaptureFrameRing(capacity: 8)
    for (sequence, displayTime) in [(1, 90), (2, 100), (3, 101), (4, 104)] {
      ring.append(
        ScrollCaptureStreamFrame(
          sequenceNumber: sequence,
          image: image,
          capturedAt: Double(sequence),
          displayTime: UInt64(displayTime),
          containsVisualChange: true))
    }

    XCTAssertEqual(
      ring.ordered(after: 0, displayedAfter: 100).map(\.sequenceNumber),
      [3, 4])
    XCTAssertEqual(ring.oldest(after: 0, displayedAfter: 100)?.sequenceNumber, 3)
    XCTAssertNil(ring.oldest(after: 0, through: 2, displayedAfter: 100))
  }

  func testFirstLiveFrameIsTheOnlyBaselineAndDuplicateDoesNotPoisonIt() throws {
    let firstLiveFrame = try XCTUnwrap(
      makeScrollingViewport(width: 232, height: 519, logicalYOffset: 0))
    let stitcher = ScrollingCaptureStitcher()

    let initial = try XCTUnwrap(stitcher.start(with: firstLiveFrame))
    XCTAssertEqual(initial.acceptedFrameCount, 1)
    XCTAssertEqual(initial.outputHeight, 519)
    XCTAssertEqual(initial.alignmentDebug?.path, .initialFrame)

    let duplicate = try XCTUnwrap(
      stitcher.append(
        firstLiveFrame,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(
          pixelWidth: firstLiveFrame.width),
        expectedSignedDeltaPixels: nil))
    assertNoMovement(duplicate.outcome)
    XCTAssertTrue(duplicate.likelyReachedBoundary)
    XCTAssertEqual(duplicate.acceptedFrameCount, 1)
    XCTAssertEqual(duplicate.outputHeight, 519)
  }

  func testMismatchedLiveFrameIsRejectedInsteadOfChangingTheBaseline() throws {
    let first = try XCTUnwrap(
      makeScrollingViewport(width: 232, height: 519, logicalYOffset: 0))
    let wrongSize = try XCTUnwrap(
      makeScrollingViewport(width: 231, height: 519, logicalYOffset: 80))
    let validNext = try XCTUnwrap(
      makeScrollingViewport(width: 232, height: 519, logicalYOffset: 80))
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: first)

    let rejected = try XCTUnwrap(
      stitcher.append(
        wrongSize,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: wrongSize.width)))
    assertAlignmentFailed(rejected.outcome)
    XCTAssertEqual(rejected.safety, .unsafe(reason: "alignment-failed"))
    XCTAssertEqual(rejected.acceptedFrameCount, 1)

    let recovered = try XCTUnwrap(
      stitcher.append(
        validNext,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: validNext.width),
        expectedSignedDeltaPixels: 80))
    assertAppended(recovered.outcome, expectedDelta: 80)
    XCTAssertEqual(recovered.acceptedFrameCount, 2)
  }

  func testNarrowInternalScrollPanelBuildsAContinuousLongImage() throws {
    let width = 232
    let height = 519
    let offsets = [0, 68, 136, 204, 272, 340]
    let stitcher = ScrollingCaptureStitcher()

    let first = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedHeaderHeight: 32,
        fixedFooterHeight: 24))
    _ = stitcher.start(with: first)

    for offset in offsets.dropFirst() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedHeaderHeight: 32,
          fixedFooterHeight: 24))
      let update = try XCTUnwrap(
        stitcher.append(
          frame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    XCTAssertEqual(stitcher.acceptedFrameCount, offsets.count)
    XCTAssertGreaterThan(stitcher.outputHeight, height)
    let output = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertEqual(output.width, width)
    XCTAssertEqual(output.height, stitcher.outputHeight)
  }

  func testAcceptedTimelineRetainsOnlyCompactOutputRows() throws {
    let width = 232
    let height = 519
    let offsets = [0, 40, 80, 120, 160, 200]
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(
      makeScrollingViewport(width: width, height: height, logicalYOffset: offsets[0])))

    for offset in offsets.dropFirst() {
      let update = try XCTUnwrap(
        stitcher.append(
          try XCTUnwrap(
            makeScrollingViewport(width: width, height: height, logicalYOffset: offset)),
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 40,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 40)
    }

    XCTAssertEqual(stitcher.retainedPixelBytes, stitcher.outputHeight * width * 4)
    let oldWholeFrameRetention = offsets.count * width * height * 4
    XCTAssertLessThan(stitcher.retainedPixelBytes, oldWholeFrameRetention / 2)
  }

  func testReverseMovementDoesNotPoisonTheAcceptedForwardTimeline() throws {
    let width = 232
    let height = 519
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(
      makeScrollingViewport(width: width, height: height, logicalYOffset: 0)))

    let firstForward = try XCTUnwrap(
      stitcher.append(
        try XCTUnwrap(
          makeScrollingViewport(width: width, height: height, logicalYOffset: 80)),
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: 80,
        renderMergedImage: false))
    assertAppended(firstForward.outcome, expectedDelta: 80)

    let reversed = try XCTUnwrap(
      stitcher.append(
        try XCTUnwrap(
          makeScrollingViewport(width: width, height: height, logicalYOffset: 20)),
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: -60,
        renderMergedImage: false))
    assertNoMovement(reversed.outcome)
    XCTAssertFalse(reversed.likelyReachedBoundary)
    XCTAssertEqual(stitcher.acceptedFrameCount, 2)
    XCTAssertEqual(stitcher.outputHeight, height + 80)

    let resumedForward = try XCTUnwrap(
      stitcher.append(
        try XCTUnwrap(
          makeScrollingViewport(width: width, height: height, logicalYOffset: 160)),
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: 80,
        renderMergedImage: false))
    assertAppended(resumedForward.outcome, expectedDelta: 80)
    XCTAssertEqual(stitcher.outputHeight, height + 160)
  }

  func testFixedHeaderAndLatestFooterArePreservedExactlyOnce() throws {
    let width = 232
    let height = 519
    let headerHeight = 32
    let footerHeight = 24
    let first = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: 0,
        fixedHeaderHeight: headerHeight,
        fixedFooterHeight: footerHeight))
    let last = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: 136,
        fixedHeaderHeight: headerHeight,
        fixedFooterHeight: footerHeight))
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: first)
    for offset in [68, 136] {
      let update = try XCTUnwrap(
        stitcher.append(
          try XCTUnwrap(
            makeScrollingViewport(
              width: width,
              height: height,
              logicalYOffset: offset,
              fixedHeaderHeight: headerHeight,
              fixedFooterHeight: footerHeight)),
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertEqual(merged.height, height + 136)
    let rowBytes = width * 4
    let firstBytes = try rgbaBytes(first)
    let lastBytes = try rgbaBytes(last)
    let mergedBytes = try rgbaBytes(merged)
    XCTAssertEqual(
      Array(mergedBytes.prefix(headerHeight * rowBytes)),
      Array(firstBytes.prefix(headerHeight * rowBytes)))
    XCTAssertEqual(
      Array(mergedBytes.suffix(footerHeight * rowBytes)),
      Array(lastBytes.suffix(footerHeight * rowBytes)))
  }

  func testViewportFixedControlIsNotRepeatedAcrossAcceptedSlices() throws {
    let width = 232
    let height = 519
    let offsets = [0, 120, 240, 360]
    let fixedControl = CGRect(x: 92, y: 422, width: 48, height: 48)
    let stitcher = ScrollingCaptureStitcher()

    _ = stitcher.start(with: try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedOverlayRect: fixedControl)))
    for offset in offsets.dropFirst() {
      let update = try XCTUnwrap(
        stitcher.append(
          try XCTUnwrap(
            makeScrollingViewport(
              width: width,
              height: height,
              logicalYOffset: offset,
              fixedOverlayRect: fixedControl)),
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 120,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 120)
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let expectedTailControl = fixedControl.offsetBy(dx: 0, dy: CGFloat(offsets.last!))
    let expected = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentOverlayRects: [expectedTailControl]))
    try assertImagesPixelEqual(
      merged,
      expected,
      message: "the only unresolved copy must remain at the real tail document coordinate")
    let overlayPixelCount = try countFixedOverlayPixels(in: merged)
    XCTAssertLessThanOrEqual(
      overlayPixelCount,
      Int(fixedControl.width * fixedControl.height),
      "a viewport-fixed control may remain only at the unresolved tail, never once per slice")
  }

  func testFixedControlThatDisappearsIsRepairedFromCleanDocumentPixels() throws {
    let width = 232
    let height = 519
    let offsets = [0, 120, 240, 360]
    let fixedControl = CGRect(x: 92, y: 422, width: 48, height: 48)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedOverlayRect: index == offsets.indices.last ? nil : fixedControl))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try XCTUnwrap(
          stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: 120,
            renderMergedImage: false))
        assertAppended(update.outcome, expectedDelta: 120)
      }
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let cleanReference = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0))
    try assertImagesPixelEqual(merged, cleanReference)
    XCTAssertEqual(try countFixedOverlayPixels(in: merged), 0)
  }

  func testSmallVariableScrollRepairsAControlCrossingEveryAppendBoundary() throws {
    let width = 232
    let height = 519
    let offsets = [0, 12, 30, 55, 87, 126]
    let fixedControl = CGRect(x: 92, y: 487, width: 48, height: 24)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedOverlayRect: index == offsets.indices.last ? nil : fixedControl))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try XCTUnwrap(
          stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: offsets[index] - offsets[index - 1],
            renderMergedImage: false))
        guard case .appended(let deltaY) = update.outcome else {
          XCTFail("frame \(index) at offset \(offset) did not append: \(update.outcome)")
          continue
        }
        XCTAssertEqual(deltaY, offsets[index] - offsets[index - 1])
      }
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let cleanReference = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0))
    XCTAssertEqual(merged.height, height + offsets.last!)
    try assertImagesPixelEqual(merged, cleanReference)
  }

  func testRoundedFixedControlAndTranslucentShadowAreFullyRepaired() throws {
    let width = 232
    let height = 519
    let offsets = [0, 72, 144, 216, 288]
    let fixedControl = CGRect(x: 87, y: 451, width: 58, height: 58)
    let inlineControl = CGRect(x: 87, y: 180, width: 58, height: 58)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedRoundedOverlayRect: index == offsets.indices.last ? nil : fixedControl,
          documentRoundedOverlayRects: [inlineControl]))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try XCTUnwrap(
          stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: offsets[index] - offsets[index - 1],
            renderMergedImage: false))
        guard case .appended(let deltaY) = update.outcome else {
          XCTFail("frame \(index) at offset \(offset) did not append: \(update.outcome)")
          continue
        }
        XCTAssertEqual(deltaY, offsets[index] - offsets[index - 1])
      }
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let cleanReference = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentRoundedOverlayRects: [inlineControl]))
    try assertImagesPixelEqual(
      merged,
      cleanReference,
      message: "the viewport control, antialiased edge, and translucent shadow must disappear without changing the inline control")
  }

  func testInlineLookalikeControlsMoveWithTheDocumentAndRemainUntouched() throws {
    let width = 232
    let height = 519
    let offsets = [0, 120, 240, 360]
    let documentControls = [
      CGRect(x: 92, y: 180, width: 48, height: 48),
      CGRect(x: 92, y: 430, width: 48, height: 48),
      CGRect(x: 92, y: 690, width: 48, height: 48),
    ]
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          documentOverlayRects: documentControls))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try XCTUnwrap(
          stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: 120,
            renderMergedImage: false))
        assertAppended(update.outcome, expectedDelta: 120)
      }
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let cleanReference = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentOverlayRects: documentControls))
    XCTAssertEqual(try rgbaBytes(merged), try rgbaBytes(cleanReference))
    XCTAssertEqual(
      try countFixedOverlayPixels(in: merged),
      documentControls.reduce(0) { $0 + Int($1.width * $1.height) })
  }

  func testSparseRepeatingSidebarAlignsWithoutWheelHint() throws {
    let offsets = [0, 64, 128, 192]
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(
      makeSparseUIViewport(width: 232, height: 519, logicalYOffset: offsets[0])))

    for offset in offsets.dropFirst() {
      let update = try XCTUnwrap(
        stitcher.append(
          try XCTUnwrap(
            makeSparseUIViewport(width: 232, height: 519, logicalYOffset: offset)),
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 232),
          expectedSignedDeltaPixels: nil,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 64)
    }
    XCTAssertEqual(stitcher.acceptedFrameCount, offsets.count)
  }

  func testMergedImageHasPixelExactSeamsAcrossMultipleFrames() throws {
    let width = 232
    let height = 519
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(
      makeScrollingViewport(width: width, height: height, logicalYOffset: 0)))
    for offset in [68, 136] {
      let update = try XCTUnwrap(
        stitcher.append(
          try XCTUnwrap(
            makeScrollingViewport(width: width, height: height, logicalYOffset: offset)),
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let expected = try XCTUnwrap(
      makeScrollingViewport(width: width, height: height + 136, logicalYOffset: 0))
    XCTAssertEqual(try rgbaBytes(merged), try rgbaBytes(expected))
  }

  func testAnimatedPatchInsideNarrowPanelDoesNotStopTheScrollTimeline() throws {
    let width = 260
    let height = 520
    let offsets = [0, 72, 144, 216]
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(
      makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedHeaderHeight: 28,
        animatedPatchSeed: 1))
    _ = stitcher.start(with: first)

    for (index, offset) in offsets.dropFirst().enumerated() {
      let frame = try XCTUnwrap(
        makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedHeaderHeight: 28,
          animatedPatchSeed: index + 2))
      let update = try XCTUnwrap(
        stitcher.append(
          frame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
          expectedSignedDeltaPixels: 72,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 72)
    }

    XCTAssertEqual(stitcher.acceptedFrameCount, offsets.count)
  }

  func testPreviewUsesTheSameAcceptedTimelineAndStaysWithinBounds() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(
      makeScrollingViewport(width: 320, height: 600, logicalYOffset: 0))
    let second = try XCTUnwrap(
      makeScrollingViewport(width: 320, height: 600, logicalYOffset: 110))
    _ = stitcher.start(with: first)
    let update = try XCTUnwrap(
      stitcher.append(
        second,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: second.width),
        expectedSignedDeltaPixels: 110))
    assertAppended(update.outcome, expectedDelta: 110)

    let preview = try XCTUnwrap(
      stitcher.previewImage(maxPixelWidth: 180, maxPixelHeight: 420))
    XCTAssertLessThanOrEqual(preview.width, 180)
    XCTAssertLessThanOrEqual(preview.height, 420)
    XCTAssertEqual(stitcher.mergedImage()?.height, stitcher.outputHeight)
  }

  func testFinishDrainKeepsTheEntireFrozenPendingAndRingUnion() {
    XCTAssertEqual(
      ScrollCaptureFinishDrainPolicy.snapshotSequences(
        pendingSequences: Array(1...8),
        ringSequences: Array(9...17),
        activeSequence: nil,
        lastAcceptedSequence: 0,
        cutoffSequence: 16,
        failedSequences: []),
      Array(1...16))
    XCTAssertEqual(
      ScrollCaptureFinishDrainPolicy.snapshotSequences(
        pendingSequences: Array(1...8),
        ringSequences: Array(8...17),
        activeSequence: 8,
        lastAcceptedSequence: 0,
        cutoffSequence: 16,
        failedSequences: [9]),
      Array(1...7) + Array(10...16))
    XCTAssertFalse(
      ScrollCaptureFinishDrainPolicy.isComplete(
        lastAcceptedSequence: 15,
        cutoffSequence: 16))
    XCTAssertTrue(
      ScrollCaptureFinishDrainPolicy.isComplete(
        lastAcceptedSequence: 16,
        cutoffSequence: 16))
  }

  func testMaximumOutputHeightScalesWithPixelWidthAndFailsClosed() {
    XCTAssertEqual(
      ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 1),
      ScrollCapturePolicy.absoluteMaximumOutputHeight)
    XCTAssertEqual(ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 2_048), 16_384)
    XCTAssertEqual(ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 4_096), 8_192)
    XCTAssertEqual(ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 0), 0)
    XCTAssertEqual(ScrollCapturePolicy.maximumOutputHeight(pixelWidth: Int.max), 0)
  }

  func testHeightLimitDuringFinishRemainsExplicitlyPartialEvenAtCutoff() {
    XCTAssertEqual(
      ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: ScrollCaptureFinishDrainPolicy.heightLimitPartialReason,
        lastAcceptedSequence: 16,
        cutoffSequence: 16),
      ScrollCaptureFinishDrainPolicy.heightLimitPartialReason)
    XCTAssertNil(
      ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: nil,
        lastAcceptedSequence: 16,
        cutoffSequence: 16))
    XCTAssertEqual(
      ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: nil,
        lastAcceptedSequence: 15,
        cutoffSequence: 16),
      ScrollCaptureFinishDrainPolicy.incompleteTailPartialReason)
  }

  func testHeightLimitAppendsTheFirstUnseenRowsWithoutSkippingDocumentContent() throws {
    let viewportWidth = 232
    let viewportHeight = 519
    let scrollDelta = 120
    let remainingHeight = 50
    let stitcher = ScrollingCaptureStitcher()
    let first = try XCTUnwrap(
      makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight,
        logicalYOffset: 0))
    let second = try XCTUnwrap(
      makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight,
        logicalYOffset: scrollDelta))

    _ = stitcher.start(with: first)
    let update = try XCTUnwrap(
      stitcher.append(
        second,
        maxOutputHeight: viewportHeight + remainingHeight,
        expectedSignedDeltaPixels: scrollDelta))

    guard case .reachedHeightLimit = update.outcome else {
      return XCTFail("expected height limit, got \(update.outcome)")
    }
    let merged = try XCTUnwrap(stitcher.mergedImage())
    let cleanReference = try XCTUnwrap(
      makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight + remainingHeight,
        logicalYOffset: 0))
    try assertImagesPixelEqual(
      merged,
      cleanReference,
      message: "height-limited tail must remain document-contiguous")
  }

  func testRecoveryPolicyWalksIntermediateRingFramesInsteadOfRetryingTheFailedTail() {
    XCTAssertEqual(
      ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 1,
        recoveryCeilingSequence: 9,
        failedSequences: [9],
        availableSequences: Array(2...9)),
      2)
    XCTAssertEqual(
      ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 1,
        recoveryCeilingSequence: 9,
        failedSequences: [2, 9],
        availableSequences: Array(2...9)),
      3)
    XCTAssertNil(
      ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 8,
        recoveryCeilingSequence: 9,
        failedSequences: [9],
      availableSequences: Array(2...9)))
  }

  func testBoundedRingRecoveryBridgesAFastBurstWhoseLatestFrameCannotAlign() throws {
    let offsets = Array(stride(from: 0, through: 640, by: 80))
    let images = try offsets.map {
      try XCTUnwrap(
        makeScrollingViewport(width: 232, height: 519, logicalYOffset: $0))
    }
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: images[0])

    let targetSequence = offsets.count
    var lastAcceptedSequence = 1
    var failedSequences: Set<Int> = []
    var recoveryCount = 0
    var targetAppended = false

    for _ in 0..<8 {
      let targetUpdate = try XCTUnwrap(
        stitcher.append(
          images[targetSequence - 1],
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(
            pixelWidth: images[targetSequence - 1].width),
          expectedSignedDeltaPixels: nil,
          renderMergedImage: false))
      if case .appended = targetUpdate.outcome {
        targetAppended = true
        break
      }
      assertAlignmentFailed(targetUpdate.outcome)
      failedSequences.insert(targetSequence)

      let recoverySequence = try XCTUnwrap(
        ScrollCaptureRecoveryPolicy.nextSequence(
          lastAcceptedSequence: lastAcceptedSequence,
          recoveryCeilingSequence: targetSequence,
          failedSequences: failedSequences,
          availableSequences: Array(2...targetSequence)))
      let recoveryUpdate = try XCTUnwrap(
        stitcher.append(
          images[recoverySequence - 1],
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(
            pixelWidth: images[recoverySequence - 1].width),
          expectedSignedDeltaPixels: 80,
          renderMergedImage: false))
      assertAppended(recoveryUpdate.outcome, expectedDelta: 80)
      lastAcceptedSequence = recoverySequence
      failedSequences.removeAll()
      recoveryCount += 1
    }

    XCTAssertTrue(targetAppended)
    XCTAssertGreaterThan(recoveryCount, 0)
    XCTAssertEqual(stitcher.outputHeight, 519 + 640)
  }

  func testRealBrowserFixtureFramesWhenProvided() throws {
    guard let framesPath = ProcessInfo.processInfo.environment["YOUMU_REAL_FIXTURE_DIR"],
          !framesPath.isEmpty else {
      throw XCTSkip("set YOUMU_REAL_FIXTURE_DIR to run the real Chrome-frame gate")
    }
    let directoryURL = URL(fileURLWithPath: framesPath, isDirectory: true)
    let frameURLs = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertGreaterThan(frameURLs.count, 2)

    let frames: [(offset: Int, image: CGImage)] = try frameURLs.map { url in
      let stem = url.deletingPathExtension().lastPathComponent
      let offsetText = stem.split(separator: "-").last.map(String.init) ?? ""
      let offset = try XCTUnwrap(Int(offsetText), "bad fixture frame name: \(stem)")
      let image = try XCTUnwrap(
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        "cannot decode fixture frame: \(url.lastPathComponent)"
      )
      return (offset, image)
    }

    let stitcher = ScrollingCaptureStitcher()
    _ = try XCTUnwrap(stitcher.start(with: frames[0].image))
    var priorOffset = frames[0].offset
    for frame in frames.dropFirst() {
      let expectedDelta = frame.offset - priorOffset
      XCTAssertGreaterThan(expectedDelta, 0)
      let update = try XCTUnwrap(
        stitcher.append(
          frame.image,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.image.width),
          expectedSignedDeltaPixels: expectedDelta,
          renderMergedImage: false
        )
      )
      assertAppended(update.outcome, expectedDelta: expectedDelta)
      priorOffset = frame.offset
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertEqual(merged.width, frames[0].image.width)
    XCTAssertEqual(merged.height, frames.last!.offset + frames.last!.image.height)
    XCTAssertEqual(stitcher.outputHeight, merged.height)

    if let outputPath = ProcessInfo.processInfo.environment["YOUMU_REAL_FIXTURE_OUTPUT"],
       !outputPath.isEmpty {
      let representation = NSBitmapImageRep(cgImage: merged)
      let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
  }

  func testRealBrowserFixedOverlayIsRemovedWhenProvided() throws {
    guard
      let framesPath = ProcessInfo.processInfo.environment[
        "YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR"
      ],
      !framesPath.isEmpty
    else {
      throw XCTSkip(
        "set YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR to run the fixed-overlay Chrome gate")
    }
    let directoryURL = URL(fileURLWithPath: framesPath, isDirectory: true)
    let frameURLs = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let frames: [(offset: Int, image: CGImage)] = try frameURLs.map { url in
      let stem = url.deletingPathExtension().lastPathComponent
      let offsetText = stem.split(separator: "-").last.map(String.init) ?? ""
      let offset = try XCTUnwrap(Int(offsetText), "bad fixture frame name: \(stem)")
      let image = try XCTUnwrap(
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        "cannot decode fixture frame: \(url.lastPathComponent)")
      return (offset, image)
    }

    XCTAssertEqual(frames.count, 42)
    XCTAssertEqual(frames.first?.offset, 0)
    XCTAssertEqual(frames.last?.offset, 12_120)
    for (index, frame) in frames.dropLast().enumerated() {
      XCTAssertGreaterThan(
        try countPixels(
          in: frame.image,
          red: 245,
          green: 32,
          blue: 198,
          tolerance: 2),
        24,
        "fixture frame \(index) no longer contains the fixed-arrow sentinel")
    }
    XCTAssertEqual(
      try countPixels(
        in: try XCTUnwrap(frames.last?.image),
        red: 245,
        green: 32,
        blue: 198,
        tolerance: 2),
      0,
      "the fixture must hide the arrow only on its clean final frame")

    let stitcher = ScrollingCaptureStitcher()
    _ = try XCTUnwrap(stitcher.start(with: frames[0].image))
    var priorOffset = frames[0].offset
    for frame in frames.dropFirst() {
      let expectedDelta = frame.offset - priorOffset
      let update = try XCTUnwrap(
        stitcher.append(
          frame.image,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.image.width),
          expectedSignedDeltaPixels: expectedDelta,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: expectedDelta)
      priorOffset = frame.offset
    }

    let merged = try XCTUnwrap(stitcher.mergedImage())
    let fixedOverlayPixels = try countPixels(
      in: merged,
      red: 245,
      green: 32,
      blue: 198,
      tolerance: 2)
    XCTAssertEqual(merged.width, 1_000)
    XCTAssertEqual(merged.height, 12_920)
    XCTAssertEqual(fixedOverlayPixels, 0)
    print("fixedOverlayPixels=\(fixedOverlayPixels) stitched=\(merged.width)x\(merged.height)")
  }

  private func assertAppended(
    _ outcome: ScrollingCaptureStitchOutcome,
    expectedDelta: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .appended(let deltaY) = outcome else {
      return XCTFail("expected appended, got \(outcome)", file: file, line: line)
    }
    XCTAssertEqual(deltaY, expectedDelta, file: file, line: line)
  }

  private func assertNoMovement(
    _ outcome: ScrollingCaptureStitchOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .ignoredNoMovement = outcome else {
      return XCTFail("expected ignoredNoMovement, got \(outcome)", file: file, line: line)
    }
  }

  private func assertAlignmentFailed(
    _ outcome: ScrollingCaptureStitchOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .ignoredAlignmentFailed = outcome else {
      return XCTFail("expected ignoredAlignmentFailed, got \(outcome)", file: file, line: line)
    }
  }

  private func makeSolidImage(width: Int, height: Int, gray: UInt8) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      pixels[offset] = gray
      pixels[offset + 1] = gray
      pixels[offset + 2] = gray
      pixels[offset + 3] = 255
    }
    return makeImage(width: width, height: height, pixels: pixels)
  }

  private func makeSparseUIViewport(
    width: Int,
    height: Int,
    logicalYOffset: Int
  ) -> CGImage? {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      let logicalY = logicalYOffset + y
      let rowInCard = logicalY % 80
      let card = logicalY / 80
      for x in 0..<width {
        var gray: UInt8 = 248
        if rowInCard <= 1 {
          gray = 190
        } else if rowInCard >= 15, rowInCard <= 18,
                  x >= 18, x < 92 + (card * 17) % 96 {
          gray = 45
        } else if rowInCard >= 29, rowInCard <= 31,
                  x >= 18, x < 74 + (card * 29) % 118 {
          gray = 112
        } else if rowInCard >= 47, rowInCard <= 58,
                  x >= width - 44, x < width - 24 {
          gray = UInt8(70 + (card * 31) % 120)
        }
        let offset = (y * width + x) * 4
        pixels[offset] = gray
        pixels[offset + 1] = gray
        pixels[offset + 2] = gray
        pixels[offset + 3] = 255
      }
    }
    return makeImage(width: width, height: height, pixels: pixels)
  }

  private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let bytesPerRow = image.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    let drew = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress,
            let context = CGContext(
              data: baseAddress,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard drew else { throw NSError(domain: "ScrollCaptureTests", code: 1) }
    return pixels
  }

  private func countFixedOverlayPixels(in image: CGImage) throws -> Int {
    let pixels = try rgbaBytes(image)
    return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
      if pixels[offset] == 245,
         pixels[offset + 1] == 32,
         pixels[offset + 2] == 198,
         pixels[offset + 3] == 255 {
        count += 1
      }
    }
  }

  private func countPixels(
    in image: CGImage,
    red: Int,
    green: Int,
    blue: Int,
    tolerance: Int
  ) throws -> Int {
    let pixels = try rgbaBytes(image)
    return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
      if abs(Int(pixels[offset]) - red) <= tolerance,
         abs(Int(pixels[offset + 1]) - green) <= tolerance,
         abs(Int(pixels[offset + 2]) - blue) <= tolerance,
         pixels[offset + 3] >= 250 {
        count += 1
      }
    }
  }

  private func assertImagesPixelEqual(
    _ actual: CGImage,
    _ expected: CGImage,
    message: String = "images differ",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertEqual(actual.width, expected.width, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, file: file, line: line)
    guard actual.width == expected.width, actual.height == expected.height else { return }
    let actualBytes = try rgbaBytes(actual)
    let expectedBytes = try rgbaBytes(expected)
    var differentPixels = 0
    var minX = actual.width
    var minY = actual.height
    var maxX = -1
    var maxY = -1
    for byteOffset in stride(from: 0, to: actualBytes.count, by: 4) {
      guard actualBytes[byteOffset..<(byteOffset + 4)]
        != expectedBytes[byteOffset..<(byteOffset + 4)] else { continue }
      let pixel = byteOffset / 4
      let x = pixel % actual.width
      let y = pixel / actual.width
      differentPixels += 1
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
    }
    XCTAssertEqual(
      differentPixels,
      0,
      "\(message); differentPixels=\(differentPixels) bounds=(\(minX),\(minY))...(\(maxX),\(maxY))",
      file: file,
      line: line)
  }

  /// Synthetic viewport with pixel-perfect overlapping document rows, fixed chrome and a
  /// deliberately changing local patch. It models the narrow internal sidebar that failed in 157.
  private func makeScrollingViewport(
    width: Int,
    height: Int,
    logicalYOffset: Int,
    fixedHeaderHeight: Int = 0,
    fixedFooterHeight: Int = 0,
    animatedPatchSeed: Int? = nil,
    fixedOverlayRect: CGRect? = nil,
    documentOverlayRects: [CGRect] = [],
    fixedRoundedOverlayRect: CGRect? = nil,
    documentRoundedOverlayRects: [CGRect] = []
  ) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let logicalY = logicalYOffset + y - fixedHeaderHeight
        var signature = UInt32(truncatingIfNeeded: logicalY)
        signature = signature &* 2_654_435_761
          &+ UInt32(truncatingIfNeeded: x) &* 2_246_822_519
        signature ^= signature >> 16
        signature = signature &* 3_266_489_917
        signature ^= signature >> 13
        var red = UInt8(truncatingIfNeeded: signature)
        var green = UInt8(truncatingIfNeeded: signature >> 8)
        var blue = UInt8(truncatingIfNeeded: signature >> 16)

        if y < fixedHeaderHeight {
          red = UInt8((40 + y * 2 + x) & 255)
          green = UInt8((70 + y + x * 2) & 255)
          blue = 130
        } else if y >= height - fixedFooterHeight {
          red = 24
          green = UInt8((80 + x * 2 + y) & 255)
          blue = UInt8((120 + x) & 255)
        }

        if let animatedPatchSeed,
           x >= width / 3, x < width / 3 + 24,
           y >= height / 3, y < height / 3 + 18 {
          red = UInt8((animatedPatchSeed * 61 + x) & 255)
          green = UInt8((animatedPatchSeed * 97 + y) & 255)
          blue = UInt8((animatedPatchSeed * 149 + x + y) & 255)
        }

        let viewportPoint = CGPoint(x: x, y: y)
        let documentPoint = CGPoint(x: x, y: logicalYOffset + y)
        if fixedOverlayRect?.contains(viewportPoint) == true
            || documentOverlayRects.contains(where: { $0.contains(documentPoint) }) {
          red = 245
          green = 32
          blue = 198
        }

        if let rect = documentRoundedOverlayRects.first(where: { $0.contains(documentPoint) }),
           let color = roundedControlColor(
             point: documentPoint,
             rect: rect,
             background: (red, green, blue)) {
          (red, green, blue) = color
        }
        if let fixedRoundedOverlayRect,
           let color = roundedControlColor(
             point: viewportPoint,
             rect: fixedRoundedOverlayRect,
             background: (red, green, blue)) {
          (red, green, blue) = color
        }

        let offset = (y * width + x) * 4
        pixels[offset] = red
        pixels[offset + 1] = green
        pixels[offset + 2] = blue
        pixels[offset + 3] = 255
      }
    }

    return makeImage(width: width, height: height, pixels: pixels)
  }

  private func roundedControlColor(
    point: CGPoint,
    rect: CGRect,
    background: (UInt8, UInt8, UInt8)
  ) -> (UInt8, UInt8, UInt8)? {
    guard rect.contains(point) else { return nil }
    let dx = point.x + 0.5 - rect.midX
    let dy = point.y + 0.5 - rect.midY
    let distance = hypot(dx, dy)
    let outerRadius = min(rect.width, rect.height) / 2
    let coreRadius = outerRadius * 0.68
    guard distance <= outerRadius else { return nil }

    func blend(
      _ foreground: (Double, Double, Double),
      over background: (UInt8, UInt8, UInt8),
      alpha: Double
    ) -> (UInt8, UInt8, UInt8) {
      let clampedAlpha = min(1, max(0, alpha))
      return (
        UInt8((foreground.0 * clampedAlpha + Double(background.0) * (1 - clampedAlpha)).rounded()),
        UInt8((foreground.1 * clampedAlpha + Double(background.1) * (1 - clampedAlpha)).rounded()),
        UInt8((foreground.2 * clampedAlpha + Double(background.2) * (1 - clampedAlpha)).rounded())
      )
    }

    let shadowProgress = max(0, 1 - (distance - coreRadius) / max(1, outerRadius - coreRadius))
    var color = blend((20, 24, 22), over: background, alpha: shadowProgress * 0.24)
    if distance <= coreRadius + 0.8 {
      let coverage = min(1, max(0, coreRadius + 0.8 - distance))
      color = blend((242, 242, 242), over: color, alpha: coverage)
    }

    let isArrowStem = abs(dx) <= 1.5 && dy >= -8 && dy <= 7
    let isArrowHead = dy >= 2 && dy <= 8 && abs(abs(dx) - (dy - 1)) <= 1.8
    if isArrowStem || isArrowHead {
      color = (24, 24, 24)
    }
    return color
  }

  private func makeImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
    let bytesPerRow = width * 4
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue)
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent)
  }
}
