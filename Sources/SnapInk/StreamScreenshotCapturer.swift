import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captures one ScreenCaptureKit frame on macOS 13, where
/// `SCScreenshotManager` is not available yet.
final class StreamScreenshotCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(
        label: "com.snapink.screenshot-stream",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var stream: SCStream?

    @MainActor
    static func capture(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let capturer = StreamScreenshotCapturer()
        return try await capturer.captureFrame(
            contentFilter: contentFilter,
            configuration: configuration
        )
    }

    @MainActor
    private func captureFrame(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let stream = SCStream(
                filter: contentFilter,
                configuration: configuration,
                delegate: self
            )
            lock.withLock {
                self.continuation = continuation
                self.stream = stream
            }

            do {
                try stream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: outputQueue
                )
            } catch {
                complete(with: .failure(error))
                return
            }

            stream.startCapture { [weak self] error in
                if let error {
                    self?.complete(with: .failure(error))
                }
            }

            outputQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.complete(with: .failure(NSError(
                    domain: "SnapInk.ScreenCapture",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: L.text("等待截图画面超时。")]
                )))
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = ciContext.createCGImage(image, from: bounds) else { return }
        complete(with: .success(cgImage))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        complete(with: .failure(error))
    }

    private func complete(with result: Result<CGImage, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<CGImage, any Error>, SCStream?)? in
            guard let continuation else { return nil }
            self.continuation = nil
            let stream = self.stream
            self.stream = nil
            return (continuation, stream)
        }
        guard let (continuation, stream) = state else { return }
        stream?.stopCapture(completionHandler: nil)
        continuation.resume(with: result)
    }
}
