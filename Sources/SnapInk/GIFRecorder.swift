import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Continuously captures a ScreenCaptureKit stream into a frame buffer for GIF
/// recording. Unlike `StreamScreenshotCapturer` (one frame then stop), this
/// keeps the stream running and throttles samples to the target fps so the
/// caller can stop whenever it likes and collect the whole sequence.
///
/// Reuses a `ScreenRegionCapturer`'s already-prepared filter/config so the
/// recording region, scale, and SnapInk-overlay exclusion match the selection.
final class GIFRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(
        label: "com.snapink.gif-stream",
        qos: .userInitiated
    )
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let stateLock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private var lastFrameAt = Date.distantPast
    private var minimumInterval: TimeInterval = 1.0 / 15
    private var maxWidth: Int = 0
    private var onFrame: ((Int) -> Void)?
    private var onError: ((Error) -> Void)?

    private let framesLock = NSLock()
    private var frames: [CGImage] = []

    /// Number of frames captured so far.
    var frameCount: Int { framesLock.withLock { frames.count } }
    var isRunning: Bool { stateLock.withLock { stream != nil && !stopped } }

    /// Starts the stream. `onFrame` (main queue) reports the updated frame
    /// count; `onError` (main queue) reports stream failures.
    @MainActor
    func start(
        capturer: ScreenRegionCapturer,
        fps: Double = 15,
        maxWidth: Int = 0,
        onFrame: @escaping (Int) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in }
    ) throws {
        stateLock.lock()
        minimumInterval = 1.0 / max(1, fps)
        self.maxWidth = maxWidth
        self.onFrame = onFrame
        self.onError = onError
        stateLock.unlock()

        // Reuse the selection's geometry/scale; bump queue depth for streaming.
        let configuration = capturer.streamConfiguration
        configuration.queueDepth = 3

        let stream = SCStream(
            filter: capturer.captureContentFilter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: outputQueue
        )
        stateLock.lock()
        self.stream = stream
        stateLock.unlock()
        stream.startCapture { [weak self] error in
            if let error {
                self?.deliverError(error)
            }
        }
    }

    /// Stops the stream and returns all captured frames in order.
    func stop() async -> [CGImage] {
        markStopped()
        if let stream = currentStream() {
            try? await stream.stopCapture()
        }
        clearStream()
        return snapshotFrames()
    }

    // Synchronous accessors so NSLock is never touched from an async context.
    nonisolated private func markStopped() {
        stateLock.lock(); stopped = true; stateLock.unlock()
    }
    nonisolated private func currentStream() -> SCStream? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stream
    }
    nonisolated private func clearStream() {
        stateLock.lock(); stream = nil; stateLock.unlock()
    }
    nonisolated private func snapshotFrames() -> [CGImage] {
        framesLock.lock()
        defer { framesLock.unlock() }
        return frames
    }

    // MARK: SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        stateLock.lock()
        if stopped { stateLock.unlock(); return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= minimumInterval else {
            stateLock.unlock()
            return
        }
        lastFrameAt = now
        stateLock.unlock()

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = ciContext.createCGImage(image, from: bounds) else { return }

        // Downscale on capture so the frame buffer stays small in memory
        // regardless of the selection's native pixel size.
        let widthLimit = stateLock.withLock { maxWidth }
        let stored = widthLimit > 0 ? Self.scaleFrame(cgImage, maxWidth: widthLimit) : cgImage

        let count: Int
        framesLock.lock()
        frames.append(stored)
        count = frames.count
        framesLock.unlock()

        let handler = stateLock.withLock { onFrame }
        DispatchQueue.main.async { handler?(count) }
    }

    nonisolated private static func scaleFrame(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: maxWidth,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage() ?? image
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        deliverError(error)
    }

    nonisolated private func deliverError(_ error: any Error) {
        let handler = stateLock.withLock { onError }
        DispatchQueue.main.async { handler?(error) }
    }
}
