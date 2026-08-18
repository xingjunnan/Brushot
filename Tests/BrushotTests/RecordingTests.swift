import AppKit
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import XCTest
@testable import Brushot

final class RecordingCoreTests: XCTestCase {
    func testEvenVideoDimensionsNeverGrowPastSelection() {
        XCTAssertEqual(RecordingEngine.evenDimension(1), 2)
        XCTAssertEqual(RecordingEngine.evenDimension(200), 200)
        XCTAssertEqual(RecordingEngine.evenDimension(201), 200)
    }

    func testPausedDurationIsRemovedFromOutputTimeline() {
        let adjusted = RecordingTimeline.adjustedTime(
            source: CMTime(seconds: 12, preferredTimescale: 600),
            firstSource: CMTime(seconds: 5, preferredTimescale: 600),
            paused: CMTime(seconds: 2, preferredTimescale: 600)
        )
        XCTAssertEqual(CMTimeGetSeconds(adjusted), 5, accuracy: 0.001)
    }

    func testSystemAudioPreferenceDefaultsOffAndPersists() throws {
        let suite = "Brushot.RecordingPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RecordingPreferences.systemAudioEnabled(defaults: defaults))
        RecordingPreferences.setSystemAudioEnabled(true, defaults: defaults)
        XCTAssertTrue(RecordingPreferences.systemAudioEnabled(defaults: defaults))
    }

    func testMicrophonePreferenceAndDeviceSelectionPersist() throws {
        let suite = "Brushot.MicrophonePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RecordingPreferences.microphoneEnabled(defaults: defaults))
        XCTAssertNil(RecordingPreferences.microphoneDeviceID(defaults: defaults))
        RecordingPreferences.setMicrophoneEnabled(true, defaults: defaults)
        RecordingPreferences.setMicrophoneDeviceID("external-mic", defaults: defaults)
        XCTAssertTrue(RecordingPreferences.microphoneEnabled(defaults: defaults))
        XCTAssertEqual(RecordingPreferences.microphoneDeviceID(defaults: defaults), "external-mic")
    }

    func testLongGIFRecordingReducesFrameRateToSixHundredFrames() {
        XCTAssertEqual(RecordingExporter.gifTargetFPS(duration: 20), 15, accuracy: 0.001)
        XCTAssertEqual(RecordingExporter.gifTargetFPS(duration: 120), 5, accuracy: 0.001)
    }

    func testMultipleAudioTracksRequireMixing() {
        XCTAssertFalse(RecordingExporter.needsAudioMix(trackCount: 0))
        XCTAssertFalse(RecordingExporter.needsAudioMix(trackCount: 1))
        XCTAssertTrue(RecordingExporter.needsAudioMix(trackCount: 2))
    }

    func testRecordingEditPlanTrimsMergesDeletionsAndBuildsRetainedRanges() {
        var plan = RecordingEditPlan(duration: 20, trimStart: 2, trimEnd: 18)
        plan.addDeletedRange(from: 5, to: 8)
        plan.addDeletedRange(from: 7, to: 10)

        XCTAssertEqual(plan.deletedRanges, [5...10])
        XCTAssertEqual(plan.retainedRanges, [2...5, 10...18])
        XCTAssertEqual(plan.outputDuration, 11, accuracy: 0.001)
        XCTAssertTrue(plan.hasEdits)

        plan.removeLastDeletedRange()
        XCTAssertEqual(plan.retainedRanges, [2...18])
    }

    func testGIFOptionsClampUnsafeValues() {
        let options = RecordingGIFOptions(startTime: -2, endTime: 4, maxWidth: 20, framesPerSecond: 120)
        XCTAssertEqual(options.startTime, 0)
        XCTAssertEqual(options.endTime, 4)
        XCTAssertEqual(options.maxWidth, 160)
        XCTAssertEqual(options.framesPerSecond, 30)
    }

    func testGIFConversionLimitsDurationFramesAndDefaultSelection() {
        XCTAssertEqual(RecordingGIFLimits.maximumDuration, 60)
        XCTAssertEqual(RecordingGIFLimits.maximumFrameRate(for: 20), 30)
        XCTAssertEqual(RecordingGIFLimits.maximumFrameRate(for: 40), 15)
        XCTAssertEqual(RecordingGIFLimits.maximumFrameRate(for: 60), 10)
        XCTAssertEqual(RecordingGIFLimits.estimatedFrameCount(duration: 60, framesPerSecond: 10), 600)
        XCTAssertEqual(
            RecordingGIFLimits.defaultRange(playhead: 3, trimStart: 2, trimEnd: 100),
            3...18
        )
        XCTAssertEqual(
            RecordingGIFLimits.defaultRange(playhead: 99.99, trimStart: 2, trimEnd: 100),
            2...17
        )
    }

    func testRecoveryStoreKeepsRecentRecordingsAndExpiresOldFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recent = directory.appendingPathComponent("recent.mp4")
        let expired = directory.appendingPathComponent("expired.mov")
        let empty = directory.appendingPathComponent("empty.gif")
        try Data([1, 2, 3]).write(to: recent)
        try Data([4]).write(to: expired)
        try Data().write(to: empty)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: expired.path
        )

        let recovered = RecordingRecoveryStore.recoverableFiles(in: directory, now: now)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.resolvingSymlinksInPath(), recent.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testKnownVirtualMicrophonesAreHidden() {
        XCTAssertFalse(RecordingMicrophones.shouldShowDevice(named: "iFlyrecAudioDevice"))
        XCTAssertFalse(RecordingMicrophones.shouldShowDevice(named: "IdeaShare 2ch"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "MacBook Pro 麦克风"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "MacBook Pro Microphone"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "外置麦克风"))
    }

    func testRecordingDurationLimitsAndVideoCountdown() {
        XCTAssertEqual(RecordingLimits.maximumDuration(for: .gif), 180)
        XCTAssertEqual(RecordingLimits.maximumDuration(for: .video), 7_200)
        XCTAssertNil(RecordingLimits.remainingTime(for: .gif, elapsed: 120))
        XCTAssertNil(RecordingLimits.remainingTime(for: .video, elapsed: 3_599))
        XCTAssertEqual(RecordingLimits.remainingTime(for: .video, elapsed: 3_600), 3_600)
        XCTAssertEqual(RecordingLimits.remainingTime(for: .video, elapsed: 7_200), 0)
        XCTAssertEqual(RecordingDiskSpace.minimumFreeBytes, 1_000_000_000)
    }
}

final class RecordingExporterTests: XCTestCase {
    func testGIFSegmentLongerThanSixtySecondsFailsBeforeDecoding() async throws {
        let source = temporaryURL(extension: "mp4")
        let destination = temporaryURL(extension: "gif")
        try Data().write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            _ = try await RecordingExporter.exportGIFSegment(
                source: source,
                destination: destination,
                options: RecordingGIFOptions(startTime: 0, endTime: 60.01)
            )
            XCTFail("Expected a duration limit error")
        } catch let error as RecordingExportError {
            guard case .gifDurationTooLong = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRecordingWriterAcceptsScreenCaptureStylePixelBuffers() async throws {
        let output = temporaryURL(extension: "mov")
        let mixedOutput = temporaryURL(extension: "mp4")
        let editedOutput = temporaryURL(extension: "mp4")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: mixedOutput)
            try? FileManager.default.removeItem(at: editedOutput)
        }
        let writer = try RecordingWriter(
            outputURL: output,
            width: 320,
            height: 180,
            fps: 30,
            includesSystemAudio: true,
            includesMicrophone: true
        )

        for index in 0..<20 {
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: 30)
            writer.appendVideo(try makeVideoSampleBuffer(
                width: 320,
                height: 180,
                presentationTime: presentationTime
            ))
            writer.appendAudio(try makeAudioSampleBuffer(presentationTime: presentationTime))
            writer.appendMicrophone(try makeAudioSampleBuffer(presentationTime: presentationTime))
        }
        let duration = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<TimeInterval, Error>) in
            writer.finish { continuation.resume(with: $0) }
        }

        XCTAssertGreaterThan(duration, 0.2)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let sourceAudioTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceAudioTracks.count, 2)

        _ = try await RecordingExporter.exportEditedMP4(
            source: output,
            destination: editedOutput,
            plan: RecordingEditPlan(duration: duration, trimStart: 0.1, trimEnd: duration)
        )
        let editedAudioTracks = try await AVURLAsset(url: editedOutput).loadTracks(withMediaType: .audio)
        XCTAssertEqual(editedAudioTracks.count, 2)

        _ = try await RecordingExporter.export(source: output, format: .video, destination: mixedOutput)
        let mixedAudioTracks = try await AVURLAsset(url: mixedOutput).loadTracks(withMediaType: .audio)
        XCTAssertEqual(mixedAudioTracks.count, 1)
    }

    func testSyntheticMOVExportsToMP4AndGIF() async throws {
        let source = try await makeSyntheticMOV(width: 320, height: 180, frameCount: 12, fps: 6)
        let mp4 = temporaryURL(extension: "mp4")
        let gif = temporaryURL(extension: "gif")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: mp4)
            try? FileManager.default.removeItem(at: gif)
        }

        _ = try await RecordingExporter.export(source: source, format: .video, destination: mp4)
        let videoTracks = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)

        _ = try await RecordingExporter.export(source: source, format: .gif, destination: gif)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(imageSource), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 320)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 180)
    }

    func testGIFExportCanApplyWatermark() async throws {
        let source = try await makeSyntheticMOV(width: 320, height: 180, frameCount: 12, fps: 6)
        let plain = temporaryURL(extension: "gif")
        let watermarked = temporaryURL(extension: "gif")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: watermarked)
        }
        var watermark = WatermarkConfiguration.default
        watermark.isEnabled = true
        watermark.text = "Brushot"
        watermark.opacity = 1
        watermark.textColor = .white

        _ = try await RecordingExporter.export(source: source, format: .gif, destination: plain)
        _ = try await RecordingExporter.export(
            source: source,
            format: .gif,
            destination: watermarked,
            watermarkConfiguration: watermark,
            watermarkContext: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )

        let plainFrame = try firstGIFFrame(from: plain)
        let watermarkedFrame = try firstGIFFrame(from: watermarked)
        XCTAssertGreaterThan(try changedPixelCount(between: plainFrame, and: watermarkedFrame), 0)
    }

    func testEditedMP4FrameExtractionAndConfiguredGIFExport() async throws {
        let source = try await makeSyntheticMOV(width: 320, height: 180, frameCount: 30, fps: 10)
        let edited = temporaryURL(extension: "mp4")
        let gif = temporaryURL(extension: "gif")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: edited)
            try? FileManager.default.removeItem(at: gif)
        }

        var plan = RecordingEditPlan(duration: 3, trimStart: 0.5, trimEnd: 2.5)
        plan.addDeletedRange(from: 1, to: 1.5)
        _ = try await RecordingExporter.exportEditedMP4(source: source, destination: edited, plan: plan)
        let editedDuration = CMTimeGetSeconds(try await AVURLAsset(url: edited).load(.duration))
        XCTAssertEqual(editedDuration, 1.5, accuracy: 0.15)

        let frame = try await RecordingExporter.extractFrame(source: edited, at: 0.2)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 180)

        _ = try await RecordingExporter.exportGIFSegment(
            source: source,
            destination: gif,
            options: RecordingGIFOptions(startTime: 1, endTime: 2, maxWidth: 160, framesPerSecond: 8)
        )
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertLessThanOrEqual(CGImageSourceGetCount(imageSource), 8)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 160)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 90)
    }

    private func makeSyntheticMOV(
        width: Int,
        height: Int,
        frameCount: Int,
        fps: Int
    ) async throws -> URL {
        let url = temporaryURL(extension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw XCTSkip("当前测试环境没有可用的视频编码器")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw XCTSkip(writer.error?.localizedDescription ?? "当前测试环境无法启动视频编码器")
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            ), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32((index * 17) % 255), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            ) else {
                throw writer.error ?? RecordingExportError.exportFailed("测试帧写入失败")
            }
        }
        input.markAsFinished()
        let writerBox = TestAssetWriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writerBox.value.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writerBox.value.error ?? RecordingExportError.exportFailed("测试视频写入失败"))
                }
            }
        }
        return url
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-RecordingTests-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func firstGIFFrame(from url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func changedPixelCount(between first: CGImage, and second: CGImage) throws -> Int {
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        let firstData = try rgbaData(from: first)
        let secondData = try rgbaData(from: second)
        return stride(from: 0, to: firstData.count, by: 4).reduce(0) { count, offset in
            firstData[offset..<(offset + 4)].elementsEqual(secondData[offset..<(offset + 4)])
                ? count
                : count + 1
        }
    }

    private func rgbaData(from image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RecordingExportError.exportFailed("无法读取测试图片像素。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func makeVideoSampleBuffer(
        width: Int,
        height: Int,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, plane == 0 ? 32 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeAudioSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
        let sampleCount = 1_600
        let bytesPerFrame = 4
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ), noErr)
        var block: CMBlockBuffer?
        let dataLength = sampleCount * bytesPerFrame
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &block
        ), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: dataLength), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: data,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try XCTUnwrap(format),
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }
}

private final class TestAssetWriterBox: @unchecked Sendable {
    let value: AVAssetWriter
    init(_ value: AVAssetWriter) { self.value = value }
}

@MainActor
final class RecordingInteractionTests: XCTestCase {
    func testUnresolvedPreviewPromptOffersSaveDiscardAndCancel() {
        let alert = RecordingPreviewResolutionPrompt.makeAlert()

        XCTAssertEqual(alert.messageText, L.text("还有一段未保存的录制"))
        XCTAssertEqual(
            alert.buttons.map(\.title),
            [L.text("保存并继续录制"), L.text("丢弃并继续录制"), L.text("取消")]
        )
        XCTAssertEqual(
            RecordingPreviewResolutionPrompt.decision(for: .alertFirstButtonReturn),
            .saveAndContinue
        )
        XCTAssertEqual(
            RecordingPreviewResolutionPrompt.decision(for: .alertSecondButtonReturn),
            .discardAndContinue
        )
        XCTAssertEqual(
            RecordingPreviewResolutionPrompt.decision(for: .alertThirdButtonReturn),
            .cancel
        )
    }

    func testTimelineDirectlyTrimsAndSeeks() {
        let timeline = RecordingTimelineView(frame: CGRect(x: 0, y: 0, width: 640, height: 76))
        timeline.duration = 10
        timeline.trimStart = 0
        timeline.trimEnd = 10
        var changedTrim: (TimeInterval, TimeInterval)?
        var trimEnded = false
        timeline.onTrimChanged = { changedTrim = ($0, $1); _ = $2 }
        timeline.onTrimEnded = { trimEnded = true }
        let x: (TimeInterval) -> CGFloat = { 16 + 608 * CGFloat($0 / 10) }

        timeline.beginInteraction(atX: x(0))
        timeline.continueInteraction(atX: x(2))
        timeline.endInteraction()

        XCTAssertEqual(changedTrim?.0 ?? -1, 2, accuracy: 0.02)
        XCTAssertEqual(changedTrim?.1 ?? -1, 10, accuracy: 0.02)
        XCTAssertTrue(trimEnded)

        var seekTime: TimeInterval?
        timeline.onSeek = { seekTime = $0 }
        timeline.beginInteraction(atX: x(6.5))
        XCTAssertEqual(seekTime ?? -1, 6.5, accuracy: 0.02)
    }

    func testTimelineCanSelectWithinZoomedVisibleRange() {
        let timeline = RecordingTimelineView(frame: CGRect(x: 0, y: 0, width: 640, height: 76))
        timeline.duration = 7_200
        timeline.visibleRange = 1_200...1_260
        timeline.trimStart = 1_200
        timeline.trimEnd = 1_215
        timeline.movesNearestHandleOnTrackClick = true
        var changedTrim: (TimeInterval, TimeInterval)?
        timeline.onTrimChanged = { changedTrim = ($0, $1); _ = $2 }

        timeline.beginInteraction(atX: 16 + 608 * 0.5)
        timeline.endInteraction()

        XCTAssertEqual(changedTrim?.0 ?? -1, 1_200, accuracy: 0.02)
        XCTAssertEqual(changedTrim?.1 ?? -1, 1_230, accuracy: 0.02)
    }

    func testRecordingControlsStayAboveLiveAnnotationOverlay() {
        XCTAssertGreaterThan(
            RecordingSessionController.controlWindowLevel.rawValue,
            RecordingSessionController.annotationWindowLevel.rawValue
        )
    }

    func testFormatChooserOffersVideoGIFAndPersistedAudioToggle() throws {
        let originalAudioPreference = RecordingPreferences.systemAudioEnabled()
        let originalMicrophonePreference = RecordingPreferences.microphoneEnabled()
        let originalWatermarkPreference = WatermarkPreferences.recordingEnabled()
        let originalWatermark = WatermarkPreferences.load()
        defer {
            RecordingPreferences.setSystemAudioEnabled(originalAudioPreference)
            RecordingPreferences.setMicrophoneEnabled(originalMicrophonePreference)
            WatermarkPreferences.setRecordingEnabled(originalWatermarkPreference)
            WatermarkPreferences.save(originalWatermark)
        }
        RecordingPreferences.setSystemAudioEnabled(false)
        RecordingPreferences.setMicrophoneEnabled(false)
        var watermark = WatermarkConfiguration.default
        watermark.text = "Brushot"
        WatermarkPreferences.save(watermark)
        WatermarkPreferences.setRecordingEnabled(false)
        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 104))
        let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
        let start = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "startRecordingAction" })
        let format = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSSegmentedControl }.first {
            $0.identifier?.rawValue == "recordingFormatControl"
        })
        let audio = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingSystemAudio" })
        let microphone = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingMicrophone" })
        let microphonePopup = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "recordingMicrophoneDevice"
        })
        let watermarkButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingWatermark" })
        let watermarkInfo = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingWatermarkInfo" })
        XCTAssertTrue(watermarkButton.isEnabled)
        XCTAssertEqual(watermarkInfo.toolTip, "导出时添加水印，不会出现在录制过程中")
        XCTAssertFalse(microphonePopup.isHidden)
        XCTAssertNotNil(microphonePopup.constraints.first {
            $0.firstAttribute == .width && $0.constant >= 170
        })
        let labels = descendants(of: bar).compactMap { $0 as? NSTextField }
        let audioLabel = try XCTUnwrap(labels.first { $0.stringValue == "视频音频" })
        let silentHint = try XCTUnwrap(labels.first { $0.stringValue == "录制 GIF 时静音" })
        var received: [(RecordingFormat, Bool, Bool)] = []
        var receivedWatermarks: [WatermarkConfiguration?] = []
        bar.onStart = { format, systemAudio, microphone, _, watermark in
            received.append((format, systemAudio, microphone))
            receivedWatermarks.append(watermark)
        }

        audio.performClick(nil)
        watermarkButton.performClick(nil)
        start.performClick(nil)
        format.selectedSegment = 1
        format.performClick(nil)
        XCTAssertTrue(audioLabel.isHidden)
        XCTAssertTrue(audio.isHidden)
        XCTAssertTrue(microphone.isHidden)
        XCTAssertTrue(microphonePopup.isHidden)
        XCTAssertFalse(silentHint.isHidden)
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(watermarkButton.frame.minX - silentHint.frame.maxX, 24)
        XCTAssertEqual(start.title, "开始录制 GIF")
        start.performClick(nil)

        XCTAssertEqual(received.map(\.0), [.video, .gif])
        XCTAssertEqual(received.map(\.1), [true, false])
        XCTAssertEqual(received.map(\.2), [false, false])
        XCTAssertEqual(receivedWatermarks.compactMap { $0?.text }, ["Brushot", "Brushot"])
        XCTAssertTrue(RecordingPreferences.systemAudioEnabled())
        XCTAssertTrue(WatermarkPreferences.recordingEnabled())
    }

    func testRecordingWatermarkCheckboxExplainsMissingContent() throws {
        let originalWatermarkPreference = WatermarkPreferences.recordingEnabled()
        let originalWatermark = WatermarkPreferences.load()
        defer {
            WatermarkPreferences.setRecordingEnabled(originalWatermarkPreference)
            WatermarkPreferences.save(originalWatermark)
        }
        WatermarkPreferences.save(.default)
        WatermarkPreferences.setRecordingEnabled(true)

        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 104))
        let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
        let watermarkButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingWatermark" })
        let watermarkInfo = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "recordingWatermarkInfo" })
        let labels = descendants(of: bar).compactMap { $0 as? NSTextField }

        XCTAssertTrue(watermarkButton.isEnabled)
        XCTAssertEqual(watermarkButton.state, .off)
        XCTAssertEqual(watermarkButton.toolTip, "设置水印")
        XCTAssertEqual(watermarkInfo.toolTip, "导出时添加水印，不会出现在录制过程中")
        XCTAssertFalse(WatermarkPreferences.recordingEnabled())
        XCTAssertFalse(labels.contains { $0.stringValue.contains("录制水印会增加导出时间") })
    }

    func testRecordingAnnotationToolbarMatchesScreenshotToolbarStyle() throws {
        let toolbar = RecordingAnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 340, height: 72))
        let buttons = descendants(of: toolbar).compactMap { $0 as? NSButton }
        let rectangle = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.rectangle"
        })
        XCTAssertFalse(rectangle.isBordered)
        XCTAssertEqual((rectangle as? AnnotationHoverButton)?.hoverTitle, "矩形")

        var selectedTool: AnnotationTool?
        toolbar.onToolSelected = { selectedTool = $0 }
        rectangle.performClick(nil)
        XCTAssertEqual(selectedTool, .rectangle)
        XCTAssertEqual(rectangle.state, .on)

        var selectedColor: NSColor?
        toolbar.onStyleChanged = { color, _ in selectedColor = color }
        let blue = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.color.5"
        })
        blue.performClick(nil)
        XCTAssertEqual(selectedColor?.blueComponent ?? 0, 1, accuracy: 0.001)
        let customColor = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.color.6"
        })
        XCTAssertTrue(customColor is AnnotationColorPickerButton)

        let undo = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.undo"
        })
        let redo = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.redo"
        })
        toolbar.setHistory(canUndo: true, canRedo: false)
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)
    }

    func testRecordingPreviewOffersSaveCopyDiscardAndDiscardDeletesTempFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).gif")
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
        try gif.write(to: file)
        var closed = false
        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .gif,
            duration: 1,
            pixelSize: CGSize(width: 1, height: 1),
            onClose: { closed = true }
        )
        let buttons = descendants(of: try XCTUnwrap(controller.window?.contentView))
            .compactMap { $0 as? NSButton }
        XCTAssertNotNil(buttons.first { $0.identifier?.rawValue == "saveRecordingAction" })
        XCTAssertNotNil(buttons.first { $0.identifier?.rawValue == "copyRecordingAction" })
        let discard = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "discardRecordingAction" })

        discard.performClick(nil)

        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecordingPreviewCanSaveSilentlyBeforeStartingAnotherRecording() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).gif")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewSaveTests-\(UUID().uuidString)", isDirectory: true)
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
        try gif.write(to: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalSaveLocation = AppPreferences.saveLocation
        AppPreferences.saveLocation = directory
        defer {
            AppPreferences.saveLocation = originalSaveLocation
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        var closed = false
        var saved: Bool?
        let controller = RecordingPreviewWindowController(
            fileURL: source,
            format: .gif,
            duration: 1,
            pixelSize: CGSize(width: 1, height: 1),
            onClose: { closed = true }
        )

        controller.saveAndCloseForNewRecording { saved = $0 }

        XCTAssertEqual(saved, true)
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let savedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(savedFiles.filter { $0.pathExtension == "gif" }.count, 1)
    }

    func testVideoRecordingPreviewShowsPlaybackControls() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .video,
            duration: 12,
            pixelSize: CGSize(width: 320, height: 180),
            onClose: {}
        )
        let views = descendants(of: try XCTUnwrap(controller.window?.contentView))

        XCTAssertTrue(try XCTUnwrap(controller.window).styleMask.contains(.resizable))
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingPreviewPlayer" })
        XCTAssertNotNil(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingPreviewPlayPause"
        })
        XCTAssertNotNil(views.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "recordingPreviewProgress"
        })
        XCTAssertNotNil(views.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "recordingPreviewVolume"
        })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingEditingControls" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingTimeline" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteRange" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteConfirm" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeletePreview" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteCancel" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteRestore" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingEditUndo" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingEditRedo" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingTrimStart" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteStart" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingExtractFrame" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingConvertGIF" })

        controller.close()
    }

    func testGIFConversionUsesInlineFullVideoAndDetailSelection() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .video,
            duration: 7_200,
            pixelSize: CGSize(width: 320, height: 180),
            onClose: {}
        )
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(of: content)
        let convert = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingConvertGIF"
        })
        let standardEditing = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingEditingControls"
        })
        let gifControls = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingGIFSelectionControls"
        })
        let overview = try XCTUnwrap(views.compactMap { $0 as? RecordingTimelineView }.first {
            $0.identifier?.rawValue == "recordingGIFOverviewTimeline"
        })
        let detail = try XCTUnwrap(views.compactMap { $0 as? RecordingTimelineView }.first {
            $0.identifier?.rawValue == "recordingGIFDetailTimeline"
        })
        let status = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "recordingGIFSelectionStatus"
        })

        XCTAssertTrue(gifControls.isHidden)
        convert.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertTrue(standardEditing.isHidden)
        XCTAssertFalse(gifControls.isHidden)
        XCTAssertEqual(controller.window?.title, "MP4 转 GIF")
        XCTAssertGreaterThan(overview.bounds.width, 0)
        XCTAssertGreaterThan(detail.bounds.width, 0)
        XCTAssertTrue(status.stringValue.contains("00:15.0"))

        overview.beginInteraction(atX: overview.bounds.maxX - 16)
        overview.endInteraction()
        XCTAssertTrue(status.stringValue.contains("120:00.0"))

        detail.beginInteraction(atX: 16)
        detail.endInteraction()
        XCTAssertTrue(status.stringValue.contains("60.0 秒"))
        let fps = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "recordingGIFFPS"
        })
        XCTAssertEqual(fps.titleOfSelectedItem, "10")
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingGIFPreviewSelection" })

        let cancel = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingGIFCancelSelection"
        })
        cancel.performClick(nil)
        XCTAssertFalse(standardEditing.isHidden)
        XCTAssertTrue(gifControls.isHidden)
        XCTAssertEqual(controller.window?.title, "录制完成")

        controller.close()
    }

    func testGIFRecordingPreviewDoesNotShowPlaybackControls() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).gif")
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
        try gif.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .gif,
            duration: 1,
            pixelSize: CGSize(width: 1, height: 1),
            onClose: {}
        )
        let views = descendants(of: try XCTUnwrap(controller.window?.contentView))

        XCTAssertFalse(try XCTUnwrap(controller.window).styleMask.contains(.resizable))
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingPreviewPlayer" })
        XCTAssertNil(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingPreviewPlayPause"
        })
        XCTAssertNil(views.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "recordingPreviewProgress"
        })
        XCTAssertNil(views.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "recordingPreviewVolume"
        })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingEditingControls" })
        controller.close()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
