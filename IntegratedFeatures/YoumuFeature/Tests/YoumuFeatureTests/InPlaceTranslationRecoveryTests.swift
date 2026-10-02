import AppKit
import XCTest
@testable import YoumuFeature

@MainActor
final class InPlaceTranslationRecoveryTests: XCTestCase {
    private func image() -> CGImage {
        CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func isolatedSettings() -> () -> Void {
        let old = YoumuFeatureEnvironmentStore.shared.environment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        YoumuFeatureEnvironmentStore.shared.configure(YoumuFeatureEnvironment(
            hostBundleIdentifier: YoumuFeatureEnvironment.stableHostBundleIdentifier,
            channelRoot: "translation-recovery-fixture", applicationSupportRoot: root, temporaryRoot: root))
        return {
            YoumuFeatureEnvironmentStore.shared.configure(old)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCancelBarRemainsVisibleAtEveryScreenEdgeIncludingNegativeCoordinates() {
        for visible in [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        CGRect(x: -1440, y: -900, width: 1440, height: 900)] {
            for point in [CGPoint(x: visible.minX, y: visible.minY),
                          CGPoint(x: visible.maxX, y: visible.maxY)] {
                let region = CGRect(x: point.x, y: 1080 - point.y, width: 1, height: 1)
                let frame = InPlaceTranslationController.hintFrame(for: region, visibleFrame: visible, primaryHeight: 1080)
                XCTAssertTrue(visible.contains(frame))
            }
        }
    }

    func testResponderEscapeStillCancelsAfterSelectionHasBeenSubmitted() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var obsoleteCalls = 0
        var cancelled = 0
        view.onEscape = { obsoleteCalls += 1 }
        view.freezeSelection()
        view.enterReviewMode { cancelled += 1 }
        view.handleKeyDown(keyCode: 53, modifiers: [])
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(obsoleteCalls, 0)
    }

    func testCancelImmediatelyHidesProgressAndLateOCRCannotPresent() async throws {
        let restore = isolatedSettings(); defer { restore() }
        var continuation: CheckedContinuation<[OCRTextBlock], Error>?
        var presentationCount = 0
        var translationCount = 0
        let overlay = RegionSelectionController(onSelection: { _ in }, onCancel: {})
        let controller = InPlaceTranslationController(
            region: CGRect(x: 120, y: 120, width: 320, height: 80), prefetchedImage: image(),
            overlayController: overlay, onPresentationReady: { presentationCount += 1; return true },
            onTeardownComplete: {}, recognizeText: { _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }, translateBlocks: { _, _, _ in translationCount += 1; return [] })
        controller.start()
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        let progress = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "youmu-translation-progress" && $0.isVisible
        })
        let cancel = try XCTUnwrap(progress.contentView?.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(cancel.isEnabled)
        cancel.performClick(nil)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(progress.isVisible)
        pending.resume(returning: [OCRTextBlock(text: "Save", boundingBox: .zero, confidence: 1)])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(translationCount, 0)
    }

    func testHungOCRDeadlineReleasesUIWithoutWaitingForWorker() async throws {
        let restore = isolatedSettings(); defer { restore() }
        var continuation: CheckedContinuation<[OCRTextBlock], Error>?
        let controller = InPlaceTranslationController(
            region: CGRect(x: 120, y: 120, width: 320, height: 80), prefetchedImage: image(),
            overlayController: RegionSelectionController(onSelection: { _ in }, onCancel: {}),
            onPresentationReady: { XCTFail("Timed out request must not present"); return false },
            onTeardownComplete: {}, processingTimeout: 0.04,
            recognizeText: { _ in try await withCheckedThrowingContinuation { continuation = $0 } })
        controller.start()
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "youmu-translation-progress" && $0.isVisible })
        try XCTUnwrap(continuation).resume(returning: [])
    }

    func testSystemConfirmationSuspendsDeadlineAndCancellationRejectsLateTranslation() async throws {
        let restore = isolatedSettings(); defer { restore() }
        var continuation: CheckedContinuation<[NumberedBlockTranslation.BlockTranslation], Error>?
        var presentationCount = 0
        let controller = InPlaceTranslationController(
            region: CGRect(x: 120, y: 120, width: 320, height: 80), prefetchedImage: image(),
            overlayController: RegionSelectionController(onSelection: { _ in }, onCancel: {}),
            onPresentationReady: { presentationCount += 1; return true },
            onTeardownComplete: {}, processingTimeout: 0.04,
            recognizeText: { _ in [OCRTextBlock(text: "Save", boundingBox: .zero, confidence: 1)] },
            translateBlocks: { _, _, visibility in
                visibility?(true)
                defer { visibility?(false) }
                return try await withCheckedThrowingContinuation { continuation = $0 }
            })
        controller.start()
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(controller.isActive, "User confirmation must not time out under the overlay deadline")
        controller.cancelActiveSession()
        XCTAssertFalse(controller.isActive)
        try XCTUnwrap(continuation).resume(returning: [.init(index: 0, text: "保存", failed: false)])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentationCount, 0)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "youmu-translation-progress" && $0.isVisible })
    }
}
