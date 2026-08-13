import AppKit
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import XCTest
@testable import SnapInk

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
        let suite = "SnapInk.RecordingPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RecordingPreferences.systemAudioEnabled(defaults: defaults))
        RecordingPreferences.setSystemAudioEnabled(true, defaults: defaults)
        XCTAssertTrue(RecordingPreferences.systemAudioEnabled(defaults: defaults))
    }

    func testMicrophonePreferenceAndDeviceSelectionPersist() throws {
        let suite = "SnapInk.MicrophonePreferences.\(UUID().uuidString)"
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
    func testRecordingWriterAcceptsScreenCaptureStylePixelBuffers() async throws {
        let output = temporaryURL(extension: "mov")
        let mixedOutput = temporaryURL(extension: "mp4")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: mixedOutput)
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
        watermark.text = "SnapInk"
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
            .appendingPathComponent("SnapInk-RecordingTests-\(UUID().uuidString)")
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
        watermark.text = "SnapInk"
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
        let silentHint = try XCTUnwrap(labels.first { $0.stringValue == "GIF 录制为静音" })
        var received: [(RecordingFormat, Bool, Bool)] = []
        bar.onStart = { (format: RecordingFormat, systemAudio: Bool, microphone: Bool, _: String?) in
            received.append((format, systemAudio, microphone))
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
        XCTAssertEqual(start.title, "开始录制 GIF")
        start.performClick(nil)

        XCTAssertEqual(received.map(\.0), [.video, .gif])
        XCTAssertEqual(received.map(\.1), [true, false])
        XCTAssertEqual(received.map(\.2), [false, false])
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

        XCTAssertFalse(watermarkButton.isEnabled)
        XCTAssertEqual(watermarkButton.state, .off)
        XCTAssertEqual(watermarkButton.toolTip, "请先在水印设置中填写文字或选择 Logo")
        XCTAssertEqual(watermarkInfo.toolTip, "请先在水印设置中填写文字或选择 Logo")
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
            .appendingPathComponent("SnapInk-PreviewTests-\(UUID().uuidString).gif")
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
