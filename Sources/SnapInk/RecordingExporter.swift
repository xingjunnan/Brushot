import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
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

    var errorDescription: String? {
        switch self {
        case .missingSource: "录制临时文件已经丢失。"
        case .missingVideoTrack: "录制文件中没有有效视频轨道。"
        case .exportFailed(let reason): "导出失败：\(reason)"
        case .gifCreationFailed: "GIF 编码失败。"
        }
    }
}

enum RecordingExporter {
    typealias Progress = @Sendable (RecordingExportStage, Double) -> Void

    static func export(
        source: URL,
        format: RecordingFormat,
        destination: URL,
        progress: Progress? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.missingSource
        }
        try? FileManager.default.removeItem(at: destination)
        switch format {
        case .video:
            return try await exportMP4(source: source, destination: destination, progress: progress)
        case .gif:
            return try await exportGIF(source: source, destination: destination, progress: progress)
        }
    }

    static func gifTargetFPS(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 15 }
        return min(15, 600 / duration)
    }

    static func needsAudioMix(trackCount: Int) -> Bool { trackCount > 1 }

    private static func exportMP4(
        source: URL,
        destination: URL,
        progress: Progress?
    ) async throws -> URL {
        progress?(.preparing, 0)
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let exportAsset: AVAsset
        let preset: String
        var audioMix: AVAudioMix?
        if needsAudioMix(trackCount: audioTracks.count) {
            let mixed = try await makeMixedComposition(asset: asset, audioTracks: audioTracks)
            exportAsset = mixed.composition
            audioMix = mixed.audioMix
            preset = AVAssetExportPresetHighestQuality
        } else {
            exportAsset = asset
            preset = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else {
            throw RecordingExportError.exportFailed("无法创建 MP4 导出器。")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = audioMix
        progress?(.encoding, 0.1)
        let sessionBox = SendableExportSession(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch sessionBox.value.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: RecordingExportError.exportFailed(
                        sessionBox.value.error?.localizedDescription ?? "未知错误"
                    ))
                }
            }
        }
        progress?(.finalizing, 1)
        return destination
    }

    private static func makeMixedComposition(
        asset: AVAsset,
        audioTracks: [AVAssetTrack]
    ) async throws -> (composition: AVMutableComposition, audioMix: AVAudioMix) {
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
        return (composition, mix)
    }

    private static func exportGIF(
        source: URL,
        destination: URL,
        progress: Progress?
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            progress?(.preparing, 0)
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { throw RecordingExportError.missingVideoTrack }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw RecordingExportError.missingVideoTrack }

            let targetFPS = gifTargetFPS(duration: seconds)
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
            guard reader.startReading() else {
                throw RecordingExportError.exportFailed(reader.error?.localizedDescription ?? "无法读取视频。")
            }

            var nextTime = 0.0
            var pending: (image: CGImage, time: Double)?
            var emitted = 0
            while reader.status == .reading, emitted < 600 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard pts.isFinite, pts + 0.0001 >= nextTime,
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                      let image = makeGIFImage(from: pixelBuffer, maxWidth: 720) else { continue }
                if let previous = pending {
                    addGIFFrame(previous.image, to: destinationRef, delay: max(0.02, pts - previous.time))
                    emitted += 1
                    progress?(.encoding, min(0.98, pts / seconds))
                }
                pending = (image, pts)
                nextTime = pts + targetInterval
            }
            if reader.status == .failed {
                throw RecordingExportError.exportFailed(reader.error?.localizedDescription ?? "GIF 读取失败。")
            }
            if let pending, emitted < 600 {
                let finalDelay = max(0.02, max(seconds - pending.time, targetInterval))
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

    private static func addGIFFrame(_ image: CGImage, to destination: CGImageDestination, delay: Double) {
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
        ] as CFDictionary)
    }

    private static func makeGIFImage(from pixelBuffer: CVPixelBuffer, maxWidth: Int) -> CGImage? {
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
        return context.makeImage()
    }
}

private final class SendableExportSession: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
