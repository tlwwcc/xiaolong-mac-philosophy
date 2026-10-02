import AppKit
import XCTest
@testable import YoumuFeature

final class OCRBackgroundRecoveryTests: XCTestCase {
    private enum FixtureError: Error { case recognitionFailed }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    func testBlockedOCRLeavesMainActorAvailableAndCancellationReleasesCaller() async throws {
        let entered = expectation(description: "native recognition entered")
        let nativeReturned = expectation(description: "late native recognition returned")
        let cancelHookEntered = expectation(description: "native cancel hook entered")
        let cancelHookReturned = expectation(description: "native cancel hook returned")
        let cancelled = expectation(description: "caller cancelled before native work returns")
        let mainActorAvailable = expectation(description: "main actor handles another action")
        let releaseNative = DispatchSemaphore(value: 0)
        let releaseCancelHook = DispatchSemaphore(value: 0)
        let invocations = Counter()
        let image = try makeImage()
        let service = OCRService { _, cancellation in
            XCTAssertFalse(Thread.isMainThread, "Vision must never run on the UI thread")
            let invocation = invocations.increment()
            if invocation == 1 {
                cancellation.setHandler {
                    cancelHookEntered.fulfill()
                    XCTAssertEqual(releaseCancelHook.wait(timeout: .now() + 5), .success)
                    cancelHookReturned.fulfill()
                }
                entered.fulfill()
                XCTAssertEqual(releaseNative.wait(timeout: .now() + 5), .success)
                nativeReturned.fulfill()
            }
            return [OCRTextBlock(text: invocation == 1 ? "late old result" : "replacement",
                                 boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)]
        }
        defer {
            releaseNative.signal()
            releaseCancelHook.signal()
        }

        let first = Task { try await service.recognizeText(from: image) }
        await fulfillment(of: [entered], timeout: 1)
        Task { @MainActor in mainActorAvailable.fulfill() }
        await fulfillment(of: [mainActorAvailable], timeout: 1)
        first.cancel()
        let cancellationObserver = Task {
            do {
                _ = try await first.value
                XCTFail("A cancelled owner must never receive a late OCR result")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            cancelled.fulfill()
        }
        // Both the recognition and its native cancel hook are deliberately still blocked.
        await fulfillment(of: [cancelled, cancelHookEntered], timeout: 1)

        let second = try await service.recognizeText(from: image)
        XCTAssertEqual(second.map(\.text), ["replacement"])
        XCTAssertEqual(invocations.count, 2)
        releaseNative.signal()
        releaseCancelHook.signal()
        await fulfillment(of: [nativeReturned, cancelHookReturned], timeout: 1)
        await cancellationObserver.value
        // Cancellation was already delivered. The late success must be discarded safely,
        // rather than double-resuming the old continuation or affecting the replacement.
        let third = try await service.recognizeText(from: image)
        XCTAssertEqual(third.map(\.text), ["replacement"])
    }

    @MainActor
    func testAlreadyCancelledTaskNeverStartsNativeOCR() async throws {
        let invocations = Counter()
        let service = OCRService { _, _ in
            _ = invocations.increment()
            return []
        }
        let image = try makeImage()
        // This child cannot enter recognizeText until the MainActor yields below.
        let task = Task { try await service.recognizeText(from: image) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Pre-cancelled OCR should fail immediately")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(invocations.count, 0)
    }

    @MainActor
    func testNativeRecognitionErrorIsPreserved() async throws {
        let service = OCRService { _, _ in throw FixtureError.recognitionFailed }
        do {
            _ = try await service.recognizeText(from: makeImage())
            XCTFail("Native errors must reach the caller")
        } catch FixtureError.recognitionFailed {
            // Expected: the worker must not turn a real failure into an empty success.
        }
    }

    @MainActor
    func testBackgroundRenderingMatchesSynchronousPixelsAndRestoresGraphicsContext() async throws {
        let original = try makeImage()
        let blocks = [OCRTextBlock(text: "Save document",
                                  boundingBox: CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6),
                                  confidence: 1)]
        let translations = [0: "保存文档"]
        let synchronous = try XCTUnwrap(TranslatedImageRenderer.render(
            original: original, blocks: blocks, translations: translations))
        let asynchronousResult = try await TranslatedImageRenderer.renderAsync(
            original: original, blocks: blocks, translations: translations)
        let asynchronous = try XCTUnwrap(asynchronousResult)
        XCTAssertEqual(asynchronous.width, original.width)
        XCTAssertEqual(asynchronous.height, original.height)
        XCTAssertEqual(pixelData(asynchronous), pixelData(synchronous))
        XCTAssertNotEqual(pixelData(asynchronous), pixelData(original), "Translation must actually be drawn")

        let restored = try await ImageProcessingWork.run { _ in
            XCTAssertFalse(Thread.isMainThread)
            let bitmap = try XCTUnwrap(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let previous = NSGraphicsContext(cgContext: bitmap, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = previous
            defer { NSGraphicsContext.restoreGraphicsState() }
            _ = TranslatedImageRenderer.render(original: original, blocks: blocks, translations: translations)
            return NSGraphicsContext.current === previous
        }
        XCTAssertTrue(restored, "Rendering must restore the worker's own drawing context")
    }

    @MainActor
    func testAlreadyCancelledRenderingDoesNotReturnAnImage() async throws {
        let original = try makeImage()
        let task = Task {
            try await TranslatedImageRenderer.renderAsync(original: original, blocks: [], translations: [:])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled rendering must not return a publishable image")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 180, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 180, height: 80))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixelData(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
