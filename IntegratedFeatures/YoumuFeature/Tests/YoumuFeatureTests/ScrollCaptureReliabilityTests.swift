import AppKit
import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class ScrollCaptureReliabilityTests {
  @Test
  func testCaptureGateRejectsSecondLongScreenshotSession() {
    #expect(CaptureSessionGate.canStart(
        hasSelection: false,
        hasInPlaceSession: false,
        hasLongScreenshotSession: false))
    #expect(!(CaptureSessionGate.canStart(
        hasSelection: false,
        hasInPlaceSession: false,
        hasLongScreenshotSession: true)))
  }

  @Test
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

    let selected = try #require(RegionSelectionSourceResolver.preferredCandidate(
        for: CGRect(x: 120, y: 140, width: 800, height: 600),
        candidates: candidates,
        hostProcessIdentifier: hostPID))

    #expect((selected.ownerProcessIdentifier) == (browserPID))
    #expect((selected.windowID) == (42))
  }

  @Test
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

    #expect(!(ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [otherFrontWindow, selected],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42)))
    #expect(ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [selected, otherFrontWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
  }

  @Test
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

    #expect(!(ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: region,
        candidates: [hostWindow, selectedSourceWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42)))
  }

  @Test
  func testExactSelectedWindowGateDoesNotDependOnTheFrontmostApplication() {
    let selectedSourceWindow = RegionSelectionWindowCandidate(
      ownerProcessIdentifier: 200,
      windowID: 42,
      bounds: CGRect(x: 0, y: 0, width: 900, height: 700))

    #expect(ScrollCaptureSourceWindowPolicy.matchesSelectedWindow(
        region: CGRect(x: 100, y: 100, width: 500, height: 400),
        candidates: [selectedSourceWindow],
        hostProcessIdentifier: 100,
        sourceProcessIdentifier: 200,
        sourceWindowID: 42))
  }

  @Test
  func testPlainSpaceKeyDownFinishesAndIsConsumed() {
    #expect((ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false)) == (.consumeAndDispatch(.finish)))
  }

  @Test
  func testPlainSpaceKeyUpIsConsumedWithoutDispatchingAgain() {
    #expect((ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyUp,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false)) == (.consume))
  }

  @Test
  func testRepeatedPlainSpaceKeyDownIsConsumedWithoutDispatchingAgain() {
    #expect((ScrollCaptureCommandPolicy.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: true)) == (.consume))
  }

  @Test
  func testModifiedSpacePassesThroughToTheSourceApplication() {
    for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
      #expect((ScrollCaptureCommandPolicy.disposition(
          keyCode: 49,
          flags: flags,
          eventType: .keyDown,
          isCapturing: true,
          isFinishing: false,
          isRepeat: false)) == (.passThrough), Comment(rawValue: "flags=\(flags.rawValue)"))
    }
  }

  @Test
  func testPlainSpaceRemainsConsumedWhileFinishing() {
    for eventType: CGEventType in [.keyDown, .keyUp] {
      #expect((ScrollCaptureCommandPolicy.disposition(
          keyCode: 49,
          flags: [],
          eventType: eventType,
          isCapturing: false,
          isFinishing: true,
          isRepeat: false)) == (.consume), Comment(rawValue: "eventType=\(eventType.rawValue)"))
    }
  }

  @Test
  func testConsumedSpaceKeyUpStaysConsumedWhenModifierAppearsMidPress() {
    var router = ScrollCaptureCommandRouter()
    #expect((router.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false)) == (.consumeAndDispatch(.finish)))
    #expect((router.disposition(
        keyCode: 49,
        flags: .maskCommand,
        eventType: .keyUp,
        isCapturing: false,
        isFinishing: true,
        isRepeat: false)) == (.consume))
  }

  @Test
  func testPassedModifiedSpaceKeyUpStaysPassedWhenModifierLeavesMidPress() {
    var router = ScrollCaptureCommandRouter()
    #expect((router.disposition(
        keyCode: 49,
        flags: .maskCommand,
        eventType: .keyDown,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false)) == (.passThrough))
    #expect((router.disposition(
        keyCode: 49,
        flags: [],
        eventType: .keyUp,
        isCapturing: true,
        isFinishing: false,
        isRepeat: false)) == (.passThrough))
  }

  @Test
  func testThirtyCompleteFramesCanClaimTheFirstBaselineOnlyOnce() {
    var gate = ScrollCaptureFirstCompleteFrameGate()
    var claims = 0
    for _ in 0..<30 where gate.claim() { claims += 1 }
    #expect((claims) == (1))
    #expect(gate.hasClaimedFrame)
    gate.reset()
    let reclaimed = gate.claim()
    #expect(reclaimed)
  }

  @Test
  func testStreamSourceRectUsesQuartzTopLeftCoordinatesWithoutASecondYFlip() throws {
    #expect((try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: 120, y: 180, width: 800, height: 600),
        displayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900))) == (CGRect(x: 120, y: 180, width: 800, height: 600)))

    #expect((try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: -1_800, y: 260, width: 500, height: 400),
        displayBounds: CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080))) == (CGRect(x: 120, y: 160, width: 500, height: 400)))
  }

  @Test
  func testStreamSourceRectRejectsASelectionThatCrossesDisplays() {
    expectThrowsError(
      try ScrollCaptureStreamGeometry.sourceRect(
        globalRegion: CGRect(x: 1_300, y: 100, width: 300, height: 400),
        displayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900))) { error in
          guard case ScrollCaptureStreamError.regionCrossesDisplays = error else {
            Issue.record(Comment(rawValue: "unexpected error: \(error)")); return
          }
        }
  }

  @Test
  func testRetinaStreamOutputKeepsNativePixelDensity() {
    #expect((ScrollCaptureStreamGeometry.fallbackPointPixelScale(
        pixelWidth: 3_840,
        pixelHeight: 2_160,
        displayBounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))) == (2))
    #expect((ScrollCaptureStreamGeometry.outputPixelSize(
        sourceRect: CGRect(x: 0, y: 0, width: 232, height: 519),
        pointPixelScale: 2)) == (CGSize(width: 464, height: 1_038)))
    #expect((ScrollCapturePolicy.firstCompleteFrameTimeout) == (4))
  }

  @Test
  func testFrameRingKeepsOnlyEightNewestCompleteFrames() throws {
    let image = try #require(makeSolidImage(width: 12, height: 12, gray: 80))
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

    #expect((ring.frames.map(\.sequenceNumber)) == (Array(5...12)))
    #expect((ring.latest(after: 10)?.sequenceNumber) == (12))
    #expect((ring.latest(after: 6, through: 9)?.sequenceNumber) == (9))
    #expect((ring.latest(after: 9, through: 9)) == nil)
    #expect((ring.latest(after: 12)) == nil)
  }

  @Test
  func testFrameRingOrdersOutOfOrderDeliveriesBySequence() throws {
    let image = try #require(makeSolidImage(width: 12, height: 12, gray: 80))
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
    #expect((ring.frames.map(\.sequenceNumber)) == ([1, 2, 3]))
    #expect((ring.latest(after: 0)?.sequenceNumber) == (3))
    #expect((ring.oldest(after: 0)?.sequenceNumber) == (1))
    #expect((ring.earliest(after: 1)?.sequenceNumber) == (2))
    #expect((ring.ordered(after: 0).map(\.sequenceNumber)) == ([1, 2, 3]))
  }

  @Test
  func testFrameRingRejectsPreEventDisplayTimesAndKeepsFIFOOrder() throws {
    let image = try #require(makeSolidImage(width: 12, height: 12, gray: 80))
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

    #expect((ring.ordered(after: 0, displayedAfter: 100).map(\.sequenceNumber)) == ([3, 4]))
    #expect((ring.oldest(after: 0, displayedAfter: 100)?.sequenceNumber) == (3))
    #expect((ring.oldest(after: 0, through: 2, displayedAfter: 100)) == nil)
  }

  @Test
  func testFirstLiveFrameIsTheOnlyBaselineAndDuplicateDoesNotPoisonIt() throws {
    let firstLiveFrame = try #require(makeScrollingViewport(width: 232, height: 519, logicalYOffset: 0))
    let stitcher = ScrollingCaptureStitcher()

    let initial = try #require(stitcher.start(with: firstLiveFrame))
    #expect((initial.acceptedFrameCount) == (1))
    #expect((initial.outputHeight) == (519))
    #expect((initial.alignmentDebug?.path) == (.initialFrame))

    let duplicate = try #require(stitcher.append(
        firstLiveFrame,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(
          pixelWidth: firstLiveFrame.width),
        expectedSignedDeltaPixels: nil))
    assertNoMovement(duplicate.outcome)
    #expect(duplicate.likelyReachedBoundary)
    #expect((duplicate.acceptedFrameCount) == (1))
    #expect((duplicate.outputHeight) == (519))
  }

  @Test
  func testMismatchedLiveFrameIsRejectedInsteadOfChangingTheBaseline() throws {
    let first = try #require(makeScrollingViewport(width: 232, height: 519, logicalYOffset: 0))
    let wrongSize = try #require(makeScrollingViewport(width: 231, height: 519, logicalYOffset: 80))
    let validNext = try #require(makeScrollingViewport(width: 232, height: 519, logicalYOffset: 80))
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: first)

    let rejected = try #require(stitcher.append(
        wrongSize,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: wrongSize.width)))
    assertAlignmentFailed(rejected.outcome)
    #expect((rejected.safety) == (.unsafe(reason: "alignment-failed")))
    #expect((rejected.acceptedFrameCount) == (1))

    let recovered = try #require(stitcher.append(
        validNext,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: validNext.width),
        expectedSignedDeltaPixels: 80))
    assertAppended(recovered.outcome, expectedDelta: 80)
    #expect((recovered.acceptedFrameCount) == (2))
  }

  @Test
  func testNarrowInternalScrollPanelBuildsAContinuousLongImage() throws {
    let width = 232
    let height = 519
    let offsets = [0, 68, 136, 204, 272, 340]
    let stitcher = ScrollingCaptureStitcher()

    let first = try #require(makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedHeaderHeight: 32,
        fixedFooterHeight: 24))
    _ = stitcher.start(with: first)

    for offset in offsets.dropFirst() {
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedHeaderHeight: 32,
          fixedFooterHeight: 24))
      let update = try #require(stitcher.append(
          frame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    #expect((stitcher.acceptedFrameCount) == (offsets.count))
    #expect((stitcher.outputHeight) > (height))
    let output = try #require(stitcher.mergedImage())
    #expect((output.width) == (width))
    #expect((output.height) == (stitcher.outputHeight))
  }

  @Test
  func testAcceptedTimelineRetainsOnlyCompactOutputRows() throws {
    let width = 232
    let height = 519
    let offsets = [0, 40, 80, 120, 160, 200]
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: offsets[0])))

    for offset in offsets.dropFirst() {
      let updateFrame = try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: offset))
      let update = try #require(stitcher.append(
          updateFrame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 40,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 40)
    }

    #expect((stitcher.retainedPixelBytes) == (stitcher.outputHeight * width * 4))
    let oldWholeFrameRetention = offsets.count * width * height * 4
    #expect((stitcher.retainedPixelBytes) < (oldWholeFrameRetention / 2))
  }

  @Test
  func testReverseMovementDoesNotPoisonTheAcceptedForwardTimeline() throws {
    let width = 232
    let height = 519
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: 0)))

    let firstForwardFrame = try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: 80))
    let firstForward = try #require(stitcher.append(
        firstForwardFrame,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: 80,
        renderMergedImage: false))
    assertAppended(firstForward.outcome, expectedDelta: 80)

    let reversedFrame = try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: 20))
    let reversed = try #require(stitcher.append(
        reversedFrame,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: -60,
        renderMergedImage: false))
    assertNoMovement(reversed.outcome)
    #expect(!(reversed.likelyReachedBoundary))
    #expect((stitcher.acceptedFrameCount) == (2))
    #expect((stitcher.outputHeight) == (height + 80))

    let resumedForwardFrame = try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: 160))
    let resumedForward = try #require(stitcher.append(
        resumedForwardFrame,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
        expectedSignedDeltaPixels: 80,
        renderMergedImage: false))
    assertAppended(resumedForward.outcome, expectedDelta: 80)
    #expect((stitcher.outputHeight) == (height + 160))
  }

  @Test
  func testFixedHeaderAndLatestFooterArePreservedExactlyOnce() throws {
    let width = 232
    let height = 519
    let headerHeight = 32
    let footerHeight = 24
    let first = try #require(makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: 0,
        fixedHeaderHeight: headerHeight,
        fixedFooterHeight: footerHeight))
    let last = try #require(makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: 136,
        fixedHeaderHeight: headerHeight,
        fixedFooterHeight: footerHeight))
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: first)
    for offset in [68, 136] {
      let updateFrame = try #require(makeScrollingViewport(
              width: width,
              height: height,
              logicalYOffset: offset,
              fixedHeaderHeight: headerHeight,
              fixedFooterHeight: footerHeight))
      let update = try #require(stitcher.append(
          updateFrame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    let merged = try #require(stitcher.mergedImage())
    #expect((merged.height) == (height + 136))
    let rowBytes = width * 4
    let firstBytes = try rgbaBytes(first)
    let lastBytes = try rgbaBytes(last)
    let mergedBytes = try rgbaBytes(merged)
    #expect((Array(mergedBytes.prefix(headerHeight * rowBytes))) == (Array(firstBytes.prefix(headerHeight * rowBytes))))
    #expect((Array(mergedBytes.suffix(footerHeight * rowBytes))) == (Array(lastBytes.suffix(footerHeight * rowBytes))))
  }

  @Test
  func testViewportFixedControlIsNotRepeatedAcrossAcceptedSlices() throws {
    let width = 232
    let height = 519
    let offsets = [0, 120, 240, 360]
    let fixedControl = CGRect(x: 92, y: 422, width: 48, height: 48)
    let stitcher = ScrollingCaptureStitcher()

    _ = stitcher.start(with: try #require(makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedOverlayRect: fixedControl)))
    for offset in offsets.dropFirst() {
      let updateFrame = try #require(makeScrollingViewport(
              width: width,
              height: height,
              logicalYOffset: offset,
              fixedOverlayRect: fixedControl))
      let update = try #require(stitcher.append(
          updateFrame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 120,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 120)
    }

    let merged = try #require(stitcher.mergedImage())
    let expectedTailControl = fixedControl.offsetBy(dx: 0, dy: CGFloat(offsets.last!))
    let expected = try #require(makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentOverlayRects: [expectedTailControl]))
    try assertImagesPixelEqual(
      merged,
      expected,
      message: "the only unresolved copy must remain at the real tail document coordinate")
    let overlayPixelCount = try countFixedOverlayPixels(in: merged)
    #expect((overlayPixelCount) <= (Int(fixedControl.width * fixedControl.height)), Comment(rawValue: "a viewport-fixed control may remain only at the unresolved tail, never once per slice"))
  }

  @Test
  func testFixedControlThatDisappearsIsRepairedFromCleanDocumentPixels() throws {
    let width = 232
    let height = 519
    let offsets = [0, 120, 240, 360]
    let fixedControl = CGRect(x: 92, y: 422, width: 48, height: 48)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedOverlayRect: index == offsets.indices.last ? nil : fixedControl))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try #require(stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: 120,
            renderMergedImage: false))
        assertAppended(update.outcome, expectedDelta: 120)
      }
    }

    let merged = try #require(stitcher.mergedImage())
    let cleanReference = try #require(makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0))
    try assertImagesPixelEqual(merged, cleanReference)
    #expect((try countFixedOverlayPixels(in: merged)) == (0))
  }

  @Test
  func testSmallVariableScrollRepairsAControlCrossingEveryAppendBoundary() throws {
    let width = 232
    let height = 519
    let offsets = [0, 12, 30, 55, 87, 126]
    let fixedControl = CGRect(x: 92, y: 487, width: 48, height: 24)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedOverlayRect: index == offsets.indices.last ? nil : fixedControl))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try #require(stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: offsets[index] - offsets[index - 1],
            renderMergedImage: false))
        guard case .appended(let deltaY) = update.outcome else {
          Issue.record(Comment(rawValue: "frame \(index) at offset \(offset) did not append: \(update.outcome)"))
          continue
        }
        #expect((deltaY) == (offsets[index] - offsets[index - 1]))
      }
    }

    let merged = try #require(stitcher.mergedImage())
    let cleanReference = try #require(makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0))
    #expect((merged.height) == (height + offsets.last!))
    try assertImagesPixelEqual(merged, cleanReference)
  }

  @Test
  func testRoundedFixedControlAndTranslucentShadowAreFullyRepaired() throws {
    let width = 232
    let height = 519
    let offsets = [0, 72, 144, 216, 288]
    let fixedControl = CGRect(x: 87, y: 451, width: 58, height: 58)
    let inlineControl = CGRect(x: 87, y: 180, width: 58, height: 58)
    let stitcher = ScrollingCaptureStitcher()

    for (index, offset) in offsets.enumerated() {
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedRoundedOverlayRect: index == offsets.indices.last ? nil : fixedControl,
          documentRoundedOverlayRects: [inlineControl]))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try #require(stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: offsets[index] - offsets[index - 1],
            renderMergedImage: false))
        guard case .appended(let deltaY) = update.outcome else {
          Issue.record(Comment(rawValue: "frame \(index) at offset \(offset) did not append: \(update.outcome)"))
          continue
        }
        #expect((deltaY) == (offsets[index] - offsets[index - 1]))
      }
    }

    let merged = try #require(stitcher.mergedImage())
    let cleanReference = try #require(makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentRoundedOverlayRects: [inlineControl]))
    try assertImagesPixelEqual(
      merged,
      cleanReference,
      message: "the viewport control, antialiased edge, and translucent shadow must disappear without changing the inline control")
  }

  @Test
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
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          documentOverlayRects: documentControls))
      if index == 0 {
        _ = stitcher.start(with: frame)
      } else {
        let update = try #require(stitcher.append(
            frame,
            maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
            expectedSignedDeltaPixels: 120,
            renderMergedImage: false))
        assertAppended(update.outcome, expectedDelta: 120)
      }
    }

    let merged = try #require(stitcher.mergedImage())
    let cleanReference = try #require(makeScrollingViewport(
        width: width,
        height: height + offsets.last!,
        logicalYOffset: 0,
        documentOverlayRects: documentControls))
    #expect((try rgbaBytes(merged)) == (try rgbaBytes(cleanReference)))
    #expect((try countFixedOverlayPixels(in: merged)) == (documentControls.reduce(0) { $0 + Int($1.width * $1.height) }))
  }

  @Test
  func testSparseRepeatingSidebarAlignsWithoutWheelHint() throws {
    let offsets = [0, 64, 128, 192]
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try #require(makeSparseUIViewport(width: 232, height: 519, logicalYOffset: offsets[0])))

    for offset in offsets.dropFirst() {
      let updateFrame = try #require(makeSparseUIViewport(width: 232, height: 519, logicalYOffset: offset))
      let update = try #require(stitcher.append(
          updateFrame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 232),
          expectedSignedDeltaPixels: nil,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 64)
    }
    #expect((stitcher.acceptedFrameCount) == (offsets.count))
  }

  @Test
  func testMergedImageHasPixelExactSeamsAcrossMultipleFrames() throws {
    let width = 232
    let height = 519
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: 0)))
    for offset in [68, 136] {
      let updateFrame = try #require(makeScrollingViewport(width: width, height: height, logicalYOffset: offset))
      let update = try #require(stitcher.append(
          updateFrame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: width),
          expectedSignedDeltaPixels: 68,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 68)
    }

    let merged = try #require(stitcher.mergedImage())
    let expected = try #require(makeScrollingViewport(width: width, height: height + 136, logicalYOffset: 0))
    #expect((try rgbaBytes(merged)) == (try rgbaBytes(expected)))
  }

  @Test
  func testAnimatedPatchInsideNarrowPanelDoesNotStopTheScrollTimeline() throws {
    let width = 260
    let height = 520
    let offsets = [0, 72, 144, 216]
    let stitcher = ScrollingCaptureStitcher()
    let first = try #require(makeScrollingViewport(
        width: width,
        height: height,
        logicalYOffset: offsets[0],
        fixedHeaderHeight: 28,
        animatedPatchSeed: 1))
    _ = stitcher.start(with: first)

    for (index, offset) in offsets.dropFirst().enumerated() {
      let frame = try #require(makeScrollingViewport(
          width: width,
          height: height,
          logicalYOffset: offset,
          fixedHeaderHeight: 28,
          animatedPatchSeed: index + 2))
      let update = try #require(stitcher.append(
          frame,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.width),
          expectedSignedDeltaPixels: 72,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: 72)
    }

    #expect((stitcher.acceptedFrameCount) == (offsets.count))
  }

  @Test
  func testPreviewUsesTheSameAcceptedTimelineAndStaysWithinBounds() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try #require(makeScrollingViewport(width: 320, height: 600, logicalYOffset: 0))
    let second = try #require(makeScrollingViewport(width: 320, height: 600, logicalYOffset: 110))
    _ = stitcher.start(with: first)
    let update = try #require(stitcher.append(
        second,
        maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: second.width),
        expectedSignedDeltaPixels: 110))
    assertAppended(update.outcome, expectedDelta: 110)

    let preview = try #require(stitcher.previewImage(maxPixelWidth: 180, maxPixelHeight: 420))
    #expect((preview.width) <= (180))
    #expect((preview.height) <= (420))
    #expect((stitcher.mergedImage()?.height) == (stitcher.outputHeight))
  }

  @Test
  func testFinishDrainKeepsTheEntireFrozenPendingAndRingUnion() {
    #expect((ScrollCaptureFinishDrainPolicy.snapshotSequences(
        pendingSequences: Array(1...8),
        ringSequences: Array(9...17),
        activeSequence: nil,
        lastAcceptedSequence: 0,
        cutoffSequence: 16,
        failedSequences: [])) == (Array(1...16)))
    #expect((ScrollCaptureFinishDrainPolicy.snapshotSequences(
        pendingSequences: Array(1...8),
        ringSequences: Array(8...17),
        activeSequence: 8,
        lastAcceptedSequence: 0,
        cutoffSequence: 16,
        failedSequences: [9])) == (Array(1...7) + Array(10...16)))
    #expect(!(ScrollCaptureFinishDrainPolicy.isComplete(
        lastAcceptedSequence: 15,
        cutoffSequence: 16)))
    #expect(ScrollCaptureFinishDrainPolicy.isComplete(
        lastAcceptedSequence: 16,
        cutoffSequence: 16))
  }

  @Test
  func testMaximumOutputHeightScalesWithPixelWidthAndFailsClosed() {
    #expect((ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 1)) == (ScrollCapturePolicy.absoluteMaximumOutputHeight))
    #expect((ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 2_048)) == (16_384))
    #expect((ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 4_096)) == (8_192))
    #expect((ScrollCapturePolicy.maximumOutputHeight(pixelWidth: 0)) == (0))
    #expect((ScrollCapturePolicy.maximumOutputHeight(pixelWidth: Int.max)) == (0))
  }

  @Test
  func testHeightLimitDuringFinishRemainsExplicitlyPartialEvenAtCutoff() {
    #expect((ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: ScrollCaptureFinishDrainPolicy.heightLimitPartialReason,
        lastAcceptedSequence: 16,
        cutoffSequence: 16)) == (ScrollCaptureFinishDrainPolicy.heightLimitPartialReason))
    #expect((ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: nil,
        lastAcceptedSequence: 16,
        cutoffSequence: 16)) == nil)
    #expect((ScrollCaptureFinishDrainPolicy.resolvedPartialReason(
        explicitReason: nil,
        lastAcceptedSequence: 15,
        cutoffSequence: 16)) == (ScrollCaptureFinishDrainPolicy.incompleteTailPartialReason))
  }

  @Test
  func testHeightLimitAppendsTheFirstUnseenRowsWithoutSkippingDocumentContent() throws {
    let viewportWidth = 232
    let viewportHeight = 519
    let scrollDelta = 120
    let remainingHeight = 50
    let stitcher = ScrollingCaptureStitcher()
    let first = try #require(makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight,
        logicalYOffset: 0))
    let second = try #require(makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight,
        logicalYOffset: scrollDelta))

    _ = stitcher.start(with: first)
    let update = try #require(stitcher.append(
        second,
        maxOutputHeight: viewportHeight + remainingHeight,
        expectedSignedDeltaPixels: scrollDelta))

    guard case .reachedHeightLimit = update.outcome else {
      Issue.record(Comment(rawValue: "expected height limit, got \(update.outcome)")); return
    }
    let merged = try #require(stitcher.mergedImage())
    let cleanReference = try #require(makeScrollingViewport(
        width: viewportWidth,
        height: viewportHeight + remainingHeight,
        logicalYOffset: 0))
    try assertImagesPixelEqual(
      merged,
      cleanReference,
      message: "height-limited tail must remain document-contiguous")
  }

  @Test
  func testRecoveryPolicyWalksIntermediateRingFramesInsteadOfRetryingTheFailedTail() {
    #expect((ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 1,
        recoveryCeilingSequence: 9,
        failedSequences: [9],
        availableSequences: Array(2...9))) == (2))
    #expect((ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 1,
        recoveryCeilingSequence: 9,
        failedSequences: [2, 9],
        availableSequences: Array(2...9))) == (3))
    #expect((ScrollCaptureRecoveryPolicy.nextSequence(
        lastAcceptedSequence: 8,
        recoveryCeilingSequence: 9,
        failedSequences: [9],
      availableSequences: Array(2...9))) == nil)
  }

  @Test
  func testBoundedRingRecoveryBridgesAFastBurstWhoseLatestFrameCannotAlign() throws {
    let offsets = Array(stride(from: 0, through: 640, by: 80))
    let images = try offsets.map {
      try #require(makeScrollingViewport(width: 232, height: 519, logicalYOffset: $0))
    }
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: images[0])

    let targetSequence = offsets.count
    var lastAcceptedSequence = 1
    var failedSequences: Set<Int> = []
    var recoveryCount = 0
    var targetAppended = false

    for _ in 0..<8 {
      let targetUpdate = try #require(stitcher.append(
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

      let recoverySequence = try #require(ScrollCaptureRecoveryPolicy.nextSequence(
          lastAcceptedSequence: lastAcceptedSequence,
          recoveryCeilingSequence: targetSequence,
          failedSequences: failedSequences,
          availableSequences: Array(2...targetSequence)))
      let recoveryUpdate = try #require(stitcher.append(
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

    #expect(targetAppended)
    #expect((recoveryCount) > (0))
    #expect((stitcher.outputHeight) == (519 + 640))
  }

  @Test(.enabled(if: !(ProcessInfo.processInfo.environment["YOUMU_REAL_FIXTURE_DIR"] ?? "").isEmpty,
                 "set YOUMU_REAL_FIXTURE_DIR to run the real Chrome-frame gate"))
  func testRealBrowserFixtureFramesWhenProvided() throws {
    let framesPath = try #require(ProcessInfo.processInfo.environment["YOUMU_REAL_FIXTURE_DIR"])
    let directoryURL = URL(fileURLWithPath: framesPath, isDirectory: true)
    let frameURLs = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect((frameURLs.count) > (2))

    let frames: [(offset: Int, image: CGImage)] = try frameURLs.map { url in
      let stem = url.deletingPathExtension().lastPathComponent
      let offsetText = stem.split(separator: "-").last.map(String.init) ?? ""
      let offset = try #require(Int(offsetText), Comment(rawValue: "bad fixture frame name: \(stem)"))
      let image = try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil), Comment(rawValue: "cannot decode fixture frame: \(url.lastPathComponent)"))
      return (offset, image)
    }

    let stitcher = ScrollingCaptureStitcher()
    _ = try #require(stitcher.start(with: frames[0].image))
    var priorOffset = frames[0].offset
    for frame in frames.dropFirst() {
      let expectedDelta = frame.offset - priorOffset
      #expect((expectedDelta) > (0))
      let update = try #require(stitcher.append(
          frame.image,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.image.width),
          expectedSignedDeltaPixels: expectedDelta,
          renderMergedImage: false
        ))
      assertAppended(update.outcome, expectedDelta: expectedDelta)
      priorOffset = frame.offset
    }

    let merged = try #require(stitcher.mergedImage())
    #expect((merged.width) == (frames[0].image.width))
    #expect((merged.height) == (frames.last!.offset + frames.last!.image.height))
    #expect((stitcher.outputHeight) == (merged.height))

    if let outputPath = ProcessInfo.processInfo.environment["YOUMU_REAL_FIXTURE_OUTPUT"],
       !outputPath.isEmpty {
      let representation = NSBitmapImageRep(cgImage: merged)
      let png = try #require(representation.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
  }

  @Test(.enabled(if: !(ProcessInfo.processInfo.environment["YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR"] ?? "").isEmpty,
                 "set YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR to run the fixed-overlay Chrome gate"))
  func testRealBrowserFixedOverlayIsRemovedWhenProvided() throws {
    let framesPath = try #require(ProcessInfo.processInfo.environment["YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR"])
    let directoryURL = URL(fileURLWithPath: framesPath, isDirectory: true)
    let frameURLs = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let frames: [(offset: Int, image: CGImage)] = try frameURLs.map { url in
      let stem = url.deletingPathExtension().lastPathComponent
      let offsetText = stem.split(separator: "-").last.map(String.init) ?? ""
      let offset = try #require(Int(offsetText), Comment(rawValue: "bad fixture frame name: \(stem)"))
      let image = try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil), Comment(rawValue: "cannot decode fixture frame: \(url.lastPathComponent)"))
      return (offset, image)
    }

    #expect((frames.count) == (42))
    #expect((frames.first?.offset) == (0))
    #expect((frames.last?.offset) == (12_120))
    for (index, frame) in frames.dropLast().enumerated() {
      #expect((try countPixels(
          in: frame.image,
          red: 245,
          green: 32,
          blue: 198,
          tolerance: 2)) > (24), Comment(rawValue: "fixture frame \(index) no longer contains the fixed-arrow sentinel"))
    }
    #expect((try countPixels(
        in: try #require(frames.last?.image),
        red: 245,
        green: 32,
        blue: 198,
        tolerance: 2)) == (0), Comment(rawValue: "the fixture must hide the arrow only on its clean final frame"))

    let stitcher = ScrollingCaptureStitcher()
    _ = try #require(stitcher.start(with: frames[0].image))
    var priorOffset = frames[0].offset
    for frame in frames.dropFirst() {
      let expectedDelta = frame.offset - priorOffset
      let update = try #require(stitcher.append(
          frame.image,
          maxOutputHeight: ScrollCapturePolicy.maximumOutputHeight(pixelWidth: frame.image.width),
          expectedSignedDeltaPixels: expectedDelta,
          renderMergedImage: false))
      assertAppended(update.outcome, expectedDelta: expectedDelta)
      priorOffset = frame.offset
    }

    let merged = try #require(stitcher.mergedImage())
    let fixedOverlayPixels = try countPixels(
      in: merged,
      red: 245,
      green: 32,
      blue: 198,
      tolerance: 2)
    #expect((merged.width) == (1_000))
    #expect((merged.height) == (12_920))
    #expect((fixedOverlayPixels) == (0))
    print("fixedOverlayPixels=\(fixedOverlayPixels) stitched=\(merged.width)x\(merged.height)")
  }

  private func assertAppended(
    _ outcome: ScrollingCaptureStitchOutcome,
    expectedDelta: Int,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .appended(let deltaY) = outcome else {
      Issue.record(Comment(rawValue: "expected appended, got \(outcome)"), sourceLocation: sourceLocation)
      return
    }
    #expect((deltaY) == (expectedDelta), sourceLocation: sourceLocation)
  }

  private func assertNoMovement(
    _ outcome: ScrollingCaptureStitchOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .ignoredNoMovement = outcome else {
      Issue.record(Comment(rawValue: "expected ignoredNoMovement, got \(outcome)"), sourceLocation: sourceLocation)
      return
    }
  }

  private func assertAlignmentFailed(
    _ outcome: ScrollingCaptureStitchOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .ignoredAlignmentFailed = outcome else {
      Issue.record(Comment(rawValue: "expected ignoredAlignmentFailed, got \(outcome)"), sourceLocation: sourceLocation)
      return
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
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect((actual.width) == (expected.width), sourceLocation: sourceLocation)
    #expect((actual.height) == (expected.height), sourceLocation: sourceLocation)
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
    #expect((differentPixels) == (0), Comment(rawValue: "\(message); differentPixels=\(differentPixels) bounds=(\(minX),\(minY))...(\(maxX),\(maxY))"), sourceLocation: sourceLocation)
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
