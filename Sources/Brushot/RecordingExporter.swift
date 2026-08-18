import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

enum RecordingExportStage: Sendable {
    case preparing
    case encoding
    case finalizing
}

enum RecordingExportError: LocalizedError {
    case missingSource
    case missingVideoTrack
    case exportFailed(String)
    case gifCreationFailed
    case gifDurationTooLong

    var errorDescription: String? {
        switch self {
        case .missingSource: L.text("录制临时文件已经丢失。")
        case .missingVideoTrack: L.text("录制文件中没有有效视频轨道。")
        case .exportFailed(let reason): L.format("导出失败：%@", reason)
        case .gifCreationFailed: L.text("GIF 编码失败。")
        case .gifDurationTooLong: L.text("GIF 片段最长为 60 秒，请缩短选区。")
        }
    }
}

enum RecordingExporter {
    typealias Progress = @Sendable (RecordingExportStage, Double) -> Void

    static func export(
        source: URL,
        format: RecordingFormat,
        destination: URL,
        watermarkConfiguration: WatermarkConfiguration? = nil,
        watermarkContext: WatermarkContext = WatermarkContext(capturedAt: Date()),
        progress: Progress? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.missingSource
        }
        try? FileManager.default.removeItem(at: destination)
        switch format {
        case .video:
            return try await exportMP4(
                source: source,
                destination: destination,
                watermarkConfiguration: watermarkConfiguration,
                watermarkContext: watermarkContext,
                progress: progress
            )
        case .gif:
            return try await exportGIF(
                source: source,
                destination: destination,
                watermarkConfiguration: watermarkConfiguration,
                watermarkContext: watermarkContext,
                progress: progress
            )
        }
    }

    static func gifTargetFPS(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 15 }
        return min(15, 600 / duration)
    }

    static func needsAudioMix(trackCount: Int) -> Bool { trackCount > 1 }

    static func exportEditedMP4(
        source: URL,
        destination: URL,
        plan: RecordingEditPlan,
        progress: Progress? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.missingSource
        }
        let ranges = plan.retainedRanges
        guard !ranges.isEmpty else {
            throw RecordingExportError.exportFailed(L.text("剪辑后没有可导出的内容。"))
        }
        progress?(.preparing, 0)
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let sourceVideos = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceVideos.first else { throw RecordingExportError.missingVideoTrack }
        var insertionTime = CMTime.zero
        for range in ranges {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
            try await composition.insertTimeRange(timeRange, of: asset, at: insertionTime)
            insertionTime = CMTimeAdd(insertionTime, timeRange.duration)
        }
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        composition.tracks(withMediaType: .video).forEach { $0.preferredTransform = preferredTransform }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingExportError.exportFailed(L.text("无法创建 MP4 导出器。"))
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        progress?(.encoding, 0.1)
        try await runExportSession(session)
        progress?(.finalizing, 1)
        return destination
    }

    static func extractFrame(source: URL, at seconds: TimeInterval) async throws -> CGImage {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.missingSource
        }
        return try await Task.detached(priority: .userInitiated) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try generator.copyCGImage(
                at: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                actualTime: nil
            )
        }.value
    }

    static func exportGIFSegment(
        source: URL,
        destination: URL,
        options: RecordingGIFOptions,
        progress: Progress? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.missingSource
        }
        guard options.endTime - options.startTime <= RecordingGIFLimits.maximumDuration + 0.001 else {
            throw RecordingExportError.gifDurationTooLong
        }
        try? FileManager.default.removeItem(at: destination)
        return try await exportGIF(
            source: source,
            destination: destination,
            watermarkConfiguration: nil,
            watermarkContext: WatermarkContext(capturedAt: Date()),
            requestedRange: options.startTime...options.endTime,
            maxWidth: options.maxWidth,
            requestedFPS: options.framesPerSecond,
            progress: progress
        )
    }

    private static func exportMP4(
        source: URL,
        destination: URL,
        watermarkConfiguration: WatermarkConfiguration?,
        watermarkContext: WatermarkContext,
        progress: Progress?
    ) async throws -> URL {
        progress?(.preparing, 0)
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw RecordingExportError.missingVideoTrack }
        let exportAsset: AVAsset
        let preset: String
        var audioMix: AVAudioMix?
        var videoComposition: AVVideoComposition?
        if watermarkConfiguration != nil || needsAudioMix(trackCount: audioTracks.count) {
            let mixed = try await makeMixedComposition(asset: asset, audioTracks: audioTracks)
            exportAsset = mixed.composition
            audioMix = mixed.audioMix
            preset = AVAssetExportPresetHighestQuality
            if let watermarkConfiguration {
                videoComposition = try await makeWatermarkVideoComposition(
                    videoTrack: mixed.videoTrack,
                    duration: try await asset.load(.duration),
                    configuration: watermarkConfiguration,
                    context: watermarkContext
                )
            }
        } else {
            exportAsset = asset
            preset = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else {
            throw RecordingExportError.exportFailed(L.text("无法创建 MP4 导出器。"))
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = audioMix
        session.videoComposition = videoComposition
        progress?(.encoding, 0.1)
        try await runExportSession(session)
        progress?(.finalizing, 1)
        return destination
    }

    private static func makeMixedComposition(
        asset: AVAsset,
        audioTracks: [AVAssetTrack]
    ) async throws -> (
        composition: AVMutableComposition,
        videoTrack: AVCompositionTrack,
        audioMix: AVAudioMix
    ) {
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let video = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { throw RecordingExportError.missingVideoTrack }
        try video.insertTimeRange(timeRange, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var parameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudio in audioTracks {
            guard let target = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let sourceRange = try await sourceAudio.load(.timeRange)
            try target.insertTimeRange(sourceRange, of: sourceAudio, at: sourceRange.start)
            let input = AVMutableAudioMixInputParameters(track: target)
            input.setVolume(0.75, at: .zero)
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (composition, video, mix)
    }

    private static func makeWatermarkVideoComposition(
        videoTrack: AVAssetTrack,
        duration: CMTime,
        configuration: WatermarkConfiguration,
        context: WatermarkContext
    ) async throws -> AVMutableVideoComposition {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformed.width),
            height: abs(transformed.height)
        )
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))
        guard let watermarkImage = makeTransparentWatermarkImage(
            width: width,
            height: height,
            configuration: configuration,
            context: context
        ) else {
            throw RecordingExportError.exportFailed(L.text("无法生成录制水印。"))
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let watermarkLayer = CALayer()
        watermarkLayer.frame = videoLayer.frame
        watermarkLayer.contents = watermarkImage
        watermarkLayer.contentsGravity = .resize
        watermarkLayer.isGeometryFlipped = true
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(watermarkLayer)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        return composition
    }

    private static func exportGIF(
        source: URL,
        destination: URL,
        watermarkConfiguration: WatermarkConfiguration?,
        watermarkContext: WatermarkContext,
        requestedRange: ClosedRange<TimeInterval>? = nil,
        maxWidth: Int = 720,
        requestedFPS: Double? = nil,
        progress: Progress?
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            progress?(.preparing, 0)
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration)
            let assetSeconds = CMTimeGetSeconds(duration)
            guard assetSeconds.isFinite, assetSeconds > 0 else { throw RecordingExportError.missingVideoTrack }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw RecordingExportError.missingVideoTrack }

            let start = max(0, min(assetSeconds, requestedRange?.lowerBound ?? 0))
            let end = max(start, min(assetSeconds, requestedRange?.upperBound ?? assetSeconds))
            let seconds = end - start
            guard seconds > 0.001 else { throw RecordingExportError.gifCreationFailed }
            if requestedRange != nil, seconds > RecordingGIFLimits.maximumDuration + 0.001 {
                throw RecordingExportError.gifDurationTooLong
            }
            let targetFPS = min(requestedFPS ?? gifTargetFPS(duration: seconds), 600 / seconds)
            let targetInterval = 1.0 / max(0.1, targetFPS)
            let estimatedFrames = max(1, min(600, Int(ceil(seconds * targetFPS))))
            guard let destinationRef = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.gif.identifier as CFString,
                estimatedFrames,
                nil
            ) else { throw RecordingExportError.gifCreationFailed }
            CGImageDestinationSetProperties(destinationRef, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { throw RecordingExportError.missingVideoTrack }
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: seconds, preferredTimescale: 600)
            )
            guard reader.startReading() else {
                throw RecordingExportError.exportFailed(reader.error?.localizedDescription ?? L.text("无法读取视频。"))
            }

            var nextTime = start
            var pending: (image: CGImage, time: Double)?
            var emitted = 0
            while reader.status == .reading, emitted < 600 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard pts.isFinite, pts + 0.0001 >= nextTime,
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                      let image = makeGIFImage(
                        from: pixelBuffer,
                        maxWidth: maxWidth,
                        watermarkConfiguration: watermarkConfiguration,
                        watermarkContext: watermarkContext
                      ) else { continue }
                if let previous = pending {
                    addGIFFrame(previous.image, to: destinationRef, delay: max(0.02, pts - previous.time))
                    emitted += 1
                    progress?(.encoding, min(0.98, (pts - start) / seconds))
                }
                pending = (image, pts)
                nextTime = pts + targetInterval
            }
            if reader.status == .failed {
                throw RecordingExportError.exportFailed(reader.error?.localizedDescription ?? L.text("GIF 读取失败。"))
            }
            if let pending, emitted < 600 {
                let finalDelay = max(0.02, max(end - pending.time, targetInterval))
                addGIFFrame(
                    pending.image,
                    to: destinationRef,
                    delay: finalDelay
                )
                emitted += 1
            }
            guard emitted > 0, CGImageDestinationFinalize(destinationRef) else {
                throw RecordingExportError.gifCreationFailed
            }
            progress?(.finalizing, 1)
            return destination
        }.value
    }

    private static func runExportSession(_ session: AVAssetExportSession) async throws {
        let sessionBox = SendableExportSession(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch sessionBox.value.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: RecordingExportError.exportFailed(
                        sessionBox.value.error?.localizedDescription ?? L.text("未知错误。")
                    ))
                }
            }
        }
    }

    private static func addGIFFrame(_ image: CGImage, to destination: CGImageDestination, delay: Double) {
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
        ] as CFDictionary)
    }

    private static func makeGIFImage(
        from pixelBuffer: CVPixelBuffer,
        maxWidth: Int,
        watermarkConfiguration: WatermarkConfiguration? = nil,
        watermarkContext: WatermarkContext = WatermarkContext(capturedAt: Date())
    ) -> CGImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = sourceWidth > maxWidth ? CGFloat(maxWidth) / CGFloat(sourceWidth) : 1
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        guard let source = ciContext.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        guard let watermarkConfiguration else { return image }
        return try? WatermarkRenderer.render(
            image: image,
            configuration: watermarkConfiguration,
            context: watermarkContext
        )
    }

    private static func makeTransparentWatermarkImage(
        width: Int,
        height: Int,
        configuration: WatermarkConfiguration,
        context watermarkContext: WatermarkContext
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.makeImage() else { return nil }
        return try? WatermarkRenderer.render(
            image: base,
            configuration: configuration,
            context: watermarkContext
        )
    }
}

private final class SendableExportSession: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
