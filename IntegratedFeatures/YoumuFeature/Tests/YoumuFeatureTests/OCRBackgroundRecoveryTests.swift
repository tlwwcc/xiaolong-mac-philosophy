import AppKit
import Testing
@testable import YoumuFeature

@Suite(.serialized)
final class OCRBackgroundRecoveryTests {
    private enum FixtureError: Error { case recognitionFailed }

    @MainActor
    @Test
    func testUncertainPlaceholdersAndFailedRenderingKeepSourcePixels() throws {
        for text in ["Welcome ｛namej", "fO｝ messages", "Hello {name", "value }"] {
            #expect(OCRService.hasUncertainLiteral(text))
        }
        for text in ["Welcome {name}, {0} messages", "{{nested}}", "66% normal", "Press Caps + ↑"] {
            #expect(!OCRService.hasUncertainLiteral(text))
        }
        let original = try makeImage()
        let blocks = [OCRTextBlock(text: "bad OCR", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), confidence: 0.4)]
        let untouched = try #require(TranslatedImageRenderer.render(original: original, blocks: [], translations: [:]))
        let failed = try #require(TranslatedImageRenderer.render(original: original, blocks: blocks,
            translations: [0: "unreliable rewritten content"], failedIndices: [0]))
        #expect(pixelData(failed) == pixelData(untouched))
    }

    @Test
    func testWrappedProseJoinsWithoutMergingMenusColumnsOrCompletedSentences() {
        func block(_ text: String, _ x: CGFloat, _ y: CGFloat, _ height: CGFloat = 0.02) -> OCRTextBlock {
            .init(text: text, boundingBox: CGRect(x: x, y: y, width: 0.8, height: height), confidence: 1)
        }
        let line = "The fee is twelve dollars per hour, excluding optional food"
        let first = block(line, 0.05, 0.8)
        let last = block("and drinks.", 0.05, 0.77)
        let merged = OCRService.translationBlocks([first, last])
        #expect(merged.count == 1)
        #expect(merged.first?.text == line + " and drinks.")
        #expect(merged.first?.boundingBox == first.boundingBox.union(last.boundingBox))
        for pair in [
            [block("Save", 0.05, 0.8), block("Save As", 0.05, 0.77)],
            [first, block("Other column", 0.55, 0.77)],
            [block(line + ".", 0.05, 0.8), last],
            [first, block("Different heading", 0.05, 0.75, 0.04)],
            [first, block("Large paragraph gap", 0.05, 0.6)]
        ] { #expect(OCRService.translationBlocks(pair).count == 2) }
    }

    @MainActor
    @Test
    func testWarmupCoalescesAndCancelledWaitDoesNotStartRecognition() async throws {
        let entered = TestSignal(description: "preparation started")
        let release = DispatchSemaphore(value: 0)
        let counter = Counter()
        let service = OCRService { _, _ in
            if counter.increment() == 1 {
                entered.fulfill()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            return []
        }
        defer { release.signal() }
        service.prewarm()
        service.prewarm()
        await awaitTestSignals(of: [entered], timeout: 1)
        let image = try makeImage()
        let request = Task { try await service.recognizeText(from: image) }
        await Task.yield()
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled wait must not start OCR")
        } catch { #expect(error is CancellationError) }
        #expect(counter.count == 1)
        release.signal()
        _ = try await service.recognizeText(from: image)
        #expect(counter.count == 2)
        service.prewarm()
        _ = try await service.recognizeText(from: image)
        #expect(counter.count == 3)
    }

    @MainActor
    @Test
    func testWarmupFailureDoesNotDisableRealRecognition() async throws {
        let counter = Counter()
        let service = OCRService { _, _ in
            if counter.increment() == 1 { throw FixtureError.recognitionFailed }
            return [OCRTextBlock(text: "ready", boundingBox: .zero, confidence: 1)]
        }
        service.prewarm()
        let result = try await service.recognizeText(from: makeImage())
        #expect(result.map(\.text) == ["ready"])
        #expect(counter.count == 2)
    }

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
    @Test
    func testBlockedOCRLeavesMainActorAvailableAndCancellationReleasesCaller() async throws {
        let entered = TestSignal(description: "native recognition entered")
        let nativeReturned = TestSignal(description: "late native recognition returned")
        let cancelHookEntered = TestSignal(description: "native cancel hook entered")
        let cancelHookReturned = TestSignal(description: "native cancel hook returned")
        let cancelled = TestSignal(description: "caller cancelled before native work returns")
        let mainActorAvailable = TestSignal(description: "main actor handles another action")
        let releaseNative = DispatchSemaphore(value: 0)
        let releaseCancelHook = DispatchSemaphore(value: 0)
        let invocations = Counter()
        let image = try makeImage()
        let service = OCRService { _, cancellation in
            #expect(!(Thread.isMainThread), Comment(rawValue: "Vision must never run on the UI thread"))
            let invocation = invocations.increment()
            if invocation == 1 {
                cancellation.setHandler {
                    cancelHookEntered.fulfill()
                    #expect((releaseCancelHook.wait(timeout: .now() + 5)) == (.success))
                    cancelHookReturned.fulfill()
                }
                entered.fulfill()
                #expect((releaseNative.wait(timeout: .now() + 5)) == (.success))
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
        await awaitTestSignals(of: [entered], timeout: 1)
        Task { @MainActor in mainActorAvailable.fulfill() }
        await awaitTestSignals(of: [mainActorAvailable], timeout: 1)
        first.cancel()
        let cancellationObserver = Task {
            do {
                _ = try await first.value
                Issue.record(Comment(rawValue: "A cancelled owner must never receive a late OCR result"))
            } catch {
                #expect(error is CancellationError)
            }
            cancelled.fulfill()
        }
        // Both the recognition and its native cancel hook are deliberately still blocked.
        await awaitTestSignals(of: [cancelled, cancelHookEntered], timeout: 1)

        let second = try await service.recognizeText(from: image)
        #expect((second.map(\.text)) == (["replacement"]))
        #expect((invocations.count) == (2))
        releaseNative.signal()
        releaseCancelHook.signal()
        await awaitTestSignals(of: [nativeReturned, cancelHookReturned], timeout: 1)
        await cancellationObserver.value
        // Cancellation was already delivered. The late success must be discarded safely,
        // rather than double-resuming the old continuation or affecting the replacement.
        let third = try await service.recognizeText(from: image)
        #expect((third.map(\.text)) == (["replacement"]))
    }

    @MainActor
    @Test
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
            Issue.record(Comment(rawValue: "Pre-cancelled OCR should fail immediately"))
        } catch {
            #expect(error is CancellationError)
        }
        #expect((invocations.count) == (0))
    }

    @MainActor
    @Test
    func testNativeRecognitionErrorIsPreserved() async throws {
        let service = OCRService { _, _ in throw FixtureError.recognitionFailed }
        do {
            _ = try await service.recognizeText(from: makeImage())
            Issue.record(Comment(rawValue: "Native errors must reach the caller"))
        } catch FixtureError.recognitionFailed {
            // Expected: the worker must not turn a real failure into an empty success.
        }
    }

    @MainActor
    @Test
    func testBackgroundRenderingMatchesSynchronousPixelsAndRestoresGraphicsContext() async throws {
        let original = try makeImage()
        let blocks = [OCRTextBlock(text: "Save document",
                                  boundingBox: CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6),
                                  confidence: 1)]
        let translations = [0: "保存文档"]
        let synchronous = try #require(TranslatedImageRenderer.render(
            original: original, blocks: blocks, translations: translations))
        let asynchronousResult = try await TranslatedImageRenderer.renderAsync(
            original: original, blocks: blocks, translations: translations)
        let asynchronous = try #require(asynchronousResult)
        #expect((asynchronous.width) == (original.width))
        #expect((asynchronous.height) == (original.height))
        #expect((pixelData(asynchronous)) == (pixelData(synchronous)))
        #expect((pixelData(asynchronous)) != (pixelData(original)), Comment(rawValue: "Translation must actually be drawn"))

        let restored = try await ImageProcessingWork.run { _ in
            #expect(!(Thread.isMainThread))
            let bitmap = try #require(CGContext(
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
        #expect(restored, Comment(rawValue: "Rendering must restore the worker's own drawing context"))
    }

    @MainActor
    @Test
    func testAlreadyCancelledRenderingDoesNotReturnAnImage() async throws {
        let original = try makeImage()
        let task = Task {
            try await TranslatedImageRenderer.renderAsync(original: original, blocks: [], translations: [:])
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record(Comment(rawValue: "Cancelled rendering must not return a publishable image"))
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 180, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 180, height: 80))
        return try #require(context.makeImage())
    }

    private func pixelData(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
