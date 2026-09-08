import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// One CPU-owned viewport frame. The WindowServer sample buffer never leaves the stream queue.
nonisolated struct ScrollCaptureStreamFrame: @unchecked Sendable {
    let sequenceNumber: Int
    let image: CGImage
    let capturedAt: TimeInterval
    let displayTime: UInt64
    let containsVisualChange: Bool
}

nonisolated enum ScrollCaptureStreamError: LocalizedError {
    case targetDisplayMissing
    case targetWindowMissing
    case regionCrossesDisplays
    case invalidRegion

    var errorDescription: String? {
        switch self {
        case .targetDisplayMissing:
            return "找不到选区所在的显示器"
        case .targetWindowMissing:
            return "目标窗口已经关闭或不可捕获"
        case .regionCrossesDisplays:
            return "长截图选区需要完整位于同一块屏幕"
        case .invalidRegion:
            return "长截图选区尺寸无效"
        }
    }
}

nonisolated enum ScrollCaptureStreamGeometry {
    static func sourceRect(globalRegion: CGRect, displayBounds: CGRect) throws -> CGRect {
        guard globalRegion.width >= 8, globalRegion.height >= 8 else {
            throw ScrollCaptureStreamError.invalidRegion
        }
        let clipped = globalRegion.intersection(displayBounds)
        guard !clipped.isNull,
              clipped.width > 0,
              clipped.height > 0,
              abs(clipped.width - globalRegion.width) < 1,
              abs(clipped.height - globalRegion.height) < 1 else {
            throw ScrollCaptureStreamError.regionCrossesDisplays
        }
        return CGRect(
            x: clipped.minX - displayBounds.minX,
            y: clipped.minY - displayBounds.minY,
            width: clipped.width,
            height: clipped.height
        ).integral
    }

    static func fallbackPointPixelScale(
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        return fallbackPointPixelScale(
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            displayBounds: displayBounds
        )
    }

    static func fallbackPointPixelScale(
        pixelWidth: Int,
        pixelHeight: Int,
        displayBounds: CGRect
    ) -> CGFloat {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return 1 }
        // On macOS 13, CGDisplayPixelsWide/High can report the logical mode dimensions
        // (for example 1920 × 1080) even when WindowServer renders at 3840 × 2160.
        // CGDisplayMode.pixelWidth/pixelHeight expose the real backing raster.
        let scaleX = CGFloat(pixelWidth) / displayBounds.width
        let scaleY = CGFloat(pixelHeight) / displayBounds.height
        let scale = max(scaleX, scaleY)
        guard scale.isFinite else { return 1 }
        return min(max(scale, 1), 4)
    }

    static func outputPixelSize(sourceRect: CGRect, pointPixelScale: CGFloat) -> CGSize {
        let scale = min(max(pointPixelScale.isFinite ? pointPixelScale : 1, 1), 4)
        return CGSize(
            width: max(1, (sourceRect.width * scale).rounded()),
            height: max(1, (sourceRect.height * scale).rounded())
        )
    }
}

/// Region-scoped ScreenCaptureKit stream. It is deliberately independent of wheel events:
/// scrolling only changes pixels; WindowServer is the single frame producer.
nonisolated final class ScrollCaptureFrameSource: NSObject, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(
        label: "cn.tlww.aixlg.youmu.long-capture.stream",
        qos: .userInteractive
    )
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var onFrame: (@MainActor @Sendable (ScrollCaptureStreamFrame) -> Void)?
    private var onFailure: (@MainActor @Sendable (Error) -> Void)?
    private var nextSequenceNumber = 0
    private var lastDisplayTime: UInt64 = 0
    private var isAcceptingFrames = false
    private var streamGeneration: UInt64 = 0

    @MainActor
    func start(
        region: CGRect,
        sourceWindowID: CGWindowID,
        frameHandler: @escaping @MainActor @Sendable (ScrollCaptureStreamFrame) -> Void,
        failureHandler: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        stop()
        guard region.width >= 8, region.height >= 8 else {
            throw ScrollCaptureStreamError.invalidRegion
        }
        let startupGeneration = stateLock.withLock { () -> UInt64 in
            streamGeneration &+= 1
            return streamGeneration
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        guard stateLock.withLock({ streamGeneration == startupGeneration }) else {
            throw CancellationError()
        }
        guard let targetWindow = content.windows.first(where: {
            $0.windowID == sourceWindowID
        }) else {
            throw ScrollCaptureStreamError.targetWindowMissing
        }

        let intersectingDisplays = content.displays.compactMap { display -> (SCDisplay, CGRect)? in
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(display.displayID))
            let intersection = region.intersection(displayBounds)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (display, displayBounds)
        }
        guard let (display, displayBounds) = intersectingDisplays.max(by: {
            $0.1.intersection(region).width * $0.1.intersection(region).height
                < $1.1.intersection(region).width * $1.1.intersection(region).height
        }) else {
            throw ScrollCaptureStreamError.targetDisplayMissing
        }

        // RegionSelectionResult.region and CGDisplayBounds both use global Quartz coordinates
        // with a top-left origin. sourceRect is display-relative; no AppKit Y flip belongs here.
        let sourceRect = try ScrollCaptureStreamGeometry.sourceRect(
            globalRegion: region,
            displayBounds: displayBounds
        )

        let filter = SCContentFilter(display: display, including: [targetWindow])
        let displayID = CGDirectDisplayID(display.displayID)
        let pointPixelScale: CGFloat
        if #available(macOS 14.0, *) {
            pointPixelScale = min(max(CGFloat(filter.pointPixelScale), 1), 4)
        } else {
            pointPixelScale = ScrollCaptureStreamGeometry.fallbackPointPixelScale(
                displayID: displayID,
                displayBounds: displayBounds
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        let outputPixelSize = ScrollCaptureStreamGeometry.outputPixelSize(
            sourceRect: sourceRect,
            pointPixelScale: pointPixelScale
        )
        configuration.width = Int(outputPixelSize.width)
        configuration.height = Int(outputPixelSize.height)
        configuration.destinationRect = CGRect(
            x: 0,
            y: 0,
            width: configuration.width,
            height: configuration.height
        )
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        let admitted = stateLock.withLock { () -> Bool in
            guard streamGeneration == startupGeneration, !Task.isCancelled else { return false }
            self.stream = stream
            self.onFrame = frameHandler
            self.onFailure = failureHandler
            nextSequenceNumber = 0
            lastDisplayTime = 0
            isAcceptingFrames = true
            return true
        }
        guard admitted else {
            try? stream.removeStreamOutput(self, type: .screen)
            throw CancellationError()
        }

        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            guard stateLock.withLock({
                streamGeneration == startupGeneration && self.stream === stream
            }) else {
                try? await stream.stopCapture()
                throw CancellationError()
            }
        } catch {
            stop()
            throw error
        }
    }

    @MainActor
    func stop() {
        let activeStream = stateLock.withLock { () -> SCStream? in
            let activeStream = stream
            stream = nil
            onFrame = nil
            onFailure = nil
            isAcceptingFrames = false
            streamGeneration &+= 1
            return activeStream
        }

        guard let activeStream else { return }
        try? activeStream.removeStreamOutput(self, type: .screen)
        Task { @MainActor in
            try? await activeStream.stopCapture()
        }
    }
}

extension ScrollCaptureFrameSource: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            guard let attachment = (
                CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ) as? [[SCStreamFrameInfo: Any]]
            )?.first,
                  let statusRaw = attachment[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete else { return }

            let displayTime = (attachment[.displayTime] as? NSNumber)?.uint64Value ?? 0
            // ScreenCaptureKit bridges SCStreamFrameInfoDirtyRects as NSArray<NSValue>.
            // A direct `[CGRect]` cast silently fails on real streams, which made every frame
            // look visually stationary even while the selected surface was changing.
            let dirtyRects = (attachment[.dirtyRects] as? [NSValue])?.map(\.rectValue) ?? []
            let imageRect = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: imageRect) else { return }

            let delivery = stateLock.withLock {
                () -> (Int, UInt64, (@MainActor @Sendable (ScrollCaptureStreamFrame) -> Void)?)? in
                guard isAcceptingFrames, self.stream === stream,
                      displayTime == 0 || displayTime > lastDisplayTime else { return nil }
                if displayTime > 0 { lastDisplayTime = displayTime }
                nextSequenceNumber += 1
                return (nextSequenceNumber, streamGeneration, onFrame)
            }
            guard let (sequenceNumber, generation, handler) = delivery else { return }

            let frame = ScrollCaptureStreamFrame(
                sequenceNumber: sequenceNumber,
                image: cgImage,
                capturedAt: ProcessInfo.processInfo.systemUptime,
                displayTime: displayTime,
                containsVisualChange: sequenceNumber == 1 || !dirtyRects.isEmpty
            )
            Task { @MainActor in
                let isCurrent = self.stateLock.withLock {
                    self.isAcceptingFrames && self.streamGeneration == generation
                }
                guard isCurrent else { return }
                handler?(frame)
            }
        }
    }
}

extension ScrollCaptureFrameSource: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let delivery = stateLock.withLock {
            () -> (UInt64, (@MainActor @Sendable (Error) -> Void)?)? in
            guard isAcceptingFrames, self.stream === stream else { return nil }
            return (streamGeneration, onFailure)
        }
        guard let (generation, handler) = delivery else { return }
        Task { @MainActor in
            let isCurrent = self.stateLock.withLock {
                self.isAcceptingFrames && self.streamGeneration == generation
            }
            guard isCurrent else { return }
            handler?(error)
        }
    }
}

/// Shared bounded frame timeline for both preview and stitch commits.
///
/// The controller deliberately asks for the oldest eligible frame. Skipping straight to the
/// newest sample breaks overlap when a fast wheel burst covers more than one viewport. Returned
/// frame values own their CGImage, so a queued request remains valid after this ring evicts it.
nonisolated struct ScrollCaptureFrameRing {
    let capacity: Int
    private(set) var frames: [ScrollCaptureStreamFrame] = []

    init(capacity: Int = 8) {
        self.capacity = max(2, capacity)
    }

    mutating func append(_ frame: ScrollCaptureStreamFrame) {
        guard frames.allSatisfy({ $0.sequenceNumber != frame.sequenceNumber }) else { return }
        frames.append(frame)
        frames.sort { $0.sequenceNumber < $1.sequenceNumber }
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func latest(
        after sequenceNumber: Int,
        through cutoff: Int? = nil,
        excluding excludedSequences: Set<Int> = [],
        displayedAfter displayTimeBarrier: UInt64? = nil
    ) -> ScrollCaptureStreamFrame? {
        frames.last(where: { frame in
            frame.sequenceNumber > sequenceNumber
                && (cutoff.map { frame.sequenceNumber <= $0 } ?? true)
                && !excludedSequences.contains(frame.sequenceNumber)
                && (displayTimeBarrier.map { frame.displayTime > $0 } ?? true)
        })
    }

    func oldest(
        after sequenceNumber: Int,
        through cutoff: Int? = nil,
        excluding excludedSequences: Set<Int> = [],
        displayedAfter displayTimeBarrier: UInt64? = nil
    ) -> ScrollCaptureStreamFrame? {
        frames.first(where: { frame in
            frame.sequenceNumber > sequenceNumber
                && (cutoff.map { frame.sequenceNumber <= $0 } ?? true)
                && !excludedSequences.contains(frame.sequenceNumber)
                && (displayTimeBarrier.map { frame.displayTime > $0 } ?? true)
        })
    }

    func earliest(
        after sequenceNumber: Int,
        through cutoff: Int? = nil,
        excluding excludedSequences: Set<Int> = [],
        displayedAfter displayTimeBarrier: UInt64? = nil
    ) -> ScrollCaptureStreamFrame? {
        oldest(
            after: sequenceNumber,
            through: cutoff,
            excluding: excludedSequences,
            displayedAfter: displayTimeBarrier
        )
    }

    func ordered(
        after sequenceNumber: Int,
        through cutoff: Int? = nil,
        excluding excludedSequences: Set<Int> = [],
        displayedAfter displayTimeBarrier: UInt64? = nil
    ) -> [ScrollCaptureStreamFrame] {
        frames.filter { frame in
            frame.sequenceNumber > sequenceNumber
                && (cutoff.map { frame.sequenceNumber <= $0 } ?? true)
                && !excludedSequences.contains(frame.sequenceNumber)
                && (displayTimeBarrier.map { frame.displayTime > $0 } ?? true)
        }
    }

    func frame(sequenceNumber: Int) -> ScrollCaptureStreamFrame? {
        frames.last(where: { $0.sequenceNumber == sequenceNumber })
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
    }
}
