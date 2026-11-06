import AppKit
import Testing

@testable import YoumuFeature

struct OCRNativeCopyTests {
  @Test
  func retriesOnlyTheReportedImageReaderFailureOnce() throws {
    var attempts: [Bool] = []
    let cancellation = ImageProcessingCancellation()
    let result = try OCRRecognitionRecovery.run(cancellation: cancellation) { cpu in
      attempts.append(cpu)
      if !cpu { throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1) }
      return [OCRTextBlock(text: "recovered", boundingBox: .zero, confidence: 1)]
    }
    #expect(attempts == [false, true])
    #expect(result.first?.text == "recovered")
  }

  @Test
  func unrelatedErrorsAndCancellationDoNotRetry() throws {
    for error in [
      NSError(domain: "TextRecognition.CRImageReaderError", code: 2),
      NSError(domain: "OtherError", code: 1),
    ] {
      var attempts = 0
      do {
        _ = try OCRRecognitionRecovery.run(cancellation: ImageProcessingCancellation()) { _ in
          attempts += 1
          throw error
        }
        Issue.record("Expected original failure")
      } catch let received as NSError {
        #expect(received.domain == error.domain && received.code == error.code)
      }
      #expect(attempts == 1)
    }
    let cancellation = ImageProcessingCancellation()
    var attempts = 0
    do {
      _ = try OCRRecognitionRecovery.run(cancellation: cancellation) { _ in
        attempts += 1
        cancellation.cancel()
        throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
      }
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(attempts == 1)
  }

  @Test
  func wrappedFailureRetriesButCPUFailureIsTerminal() {
    var attempts: [Bool] = []
    let failure = NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
    do {
      _ = try OCRRecognitionRecovery.run(cancellation: ImageProcessingCancellation()) { cpu in
        attempts.append(cpu)
        if cpu { throw NSError(domain: "CPUFailure", code: 7) }
        throw NSError(domain: "Vision", code: 9, userInfo: [NSUnderlyingErrorKey: failure])
      }
      Issue.record("Expected CPU failure")
    } catch let error as NSError {
      #expect(error.domain == "CPUFailure" && error.code == 7)
    }
    #expect(attempts == [false, true])
  }

  @MainActor
  @Test
  func recognizesCopyTextWithProductionVisionRequest() async throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 240,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 240).fill()
    ("Mac copy 2026" as NSString).draw(
      at: NSPoint(x: 40, y: 130),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black,
      ])
    ("屏幕文字复制" as NSString).draw(
      at: NSPoint(x: 40, y: 40),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black,
      ])
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(bitmap.cgImage)
    let blocks = try await OCRService.shared.recognizeText(from: image)
    let text = OCRService.shared.assembleText(from: blocks)
    #expect(text.contains("Mac copy 2026"))
    #expect(text.contains("屏幕文字复制"))

    let prepared = try OCRService.normalizedImage(image)
    #expect(prepared.width == image.width && prepared.height == image.height)
    #expect(prepared.bitsPerComponent == 8 && prepared.bitsPerPixel == 32)
    #expect(prepared.colorSpace?.name == CGColorSpace.sRGB)
    let cpu = OCRService { image, cancellation in
      try OCRService.performRecognition(
        image: OCRService.normalizedImage(image), cancellation: cancellation, useCPU: true)
    }
    let cpuBlocks = try await cpu.recognizeText(from: image)
    let cpuText = cpu.assembleText(from: cpuBlocks)
    #expect(cpuText.contains("Mac copy 2026") && cpuText.contains("屏幕文字复制"))
  }
}
