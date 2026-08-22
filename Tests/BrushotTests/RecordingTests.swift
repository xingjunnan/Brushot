import AppKit
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import XCTest
@testable import Brushot

final class RecordingCoreTests: XCTestCase {
    func testCameraPreferencesPersistAndClampLayout() throws {
        let suite = "BrushotTests.Camera.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = RecordingCameraOptions.defaults
        options.isEnabled = true
        options.deviceID = "camera-1"
        options.shape = .circle
        options.isMirrored = false
        options.normalizedCenterX = 2
        options.normalizedCenterY = -1
        options.relativeWidth = 2
        RecordingCameraPreferences.save(options, defaults: defaults)

        let loaded = RecordingCameraPreferences.load(defaults: defaults)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.deviceID, "camera-1")
        XCTAssertEqual(loaded.shape, .circle)
        XCTAssertFalse(loaded.isMirrored)
        XCTAssertEqual(loaded.normalizedCenterX, 1)
        XCTAssertEqual(loaded.normalizedCenterY, 0)
        XCTAssertEqual(loaded.relativeWidth, 0.8)
        XCTAssertEqual(RecordingCameraSize.small.relativeWidth, 0.16)
        XCTAssertEqual(RecordingCameraSize.medium.relativeWidth, 0.22)
        XCTAssertEqual(RecordingCameraSize.large.relativeWidth, 0.30)
    }

    func testCameraPreferencesDefaultToMirroredBeforeUserChooses() throws {
        let suite = "BrushotTests.CameraDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(RecordingCameraPreferences.load(defaults: defaults).isMirrored)
    }

    func testCameraGeometryKeepsCircleInsideSelectionAndRoundTripsPosition() {
        let selection = CGRect(x: 100, y: 200, width: 800, height: 500)
        var options = RecordingCameraOptions.defaults
        options.isEnabled = true
        options.shape = .circle
        let frame = RecordingCameraGeometry.frame(in: selection, options: options)
        XCTAssertEqual(frame.width, frame.height)
        XCTAssertTrue(selection.contains(frame))

        let moved = RecordingCameraGeometry.clamp(
            frame.offsetBy(dx: -1_000, dy: 1_000),
            to: selection
        )
        XCTAssertGreaterThanOrEqual(moved.minX, selection.minX + RecordingCameraGeometry.margin)
        XCTAssertLessThanOrEqual(moved.maxY, selection.maxY - RecordingCameraGeometry.margin)
        let updated = RecordingCameraGeometry.options(byUpdating: options, frame: moved, in: selection)
        XCTAssertEqual(RecordingCameraGeometry.frame(in: selection, options: updated), moved)

        let almostBottomRight = CGRect(
            x: selection.maxX - RecordingCameraGeometry.margin - frame.width + 10,
            y: selection.minY + RecordingCameraGeometry.margin + 8,
            width: frame.width,
            height: frame.height
        )
        let snapped = RecordingCameraGeometry.snappedFrame(almostBottomRight, to: selection)
        XCTAssertEqual(snapped.maxX, selection.maxX - RecordingCameraGeometry.margin)
        XCTAssertEqual(snapped.minY, selection.minY + RecordingCameraGeometry.margin)
        for position in RecordingCameraPosition.allCases {
            XCTAssertFalse(position.displayName.isEmpty)
        }
    }

    func testRecordingCaptureTargetsPreserveSourceIdentityAndBounds() {
        let rect = CGRect(x: 20, y: 30, width: 640, height: 360)
        let window = RecordingCaptureTarget.window(id: 42, globalRect: rect, title: "Document")

        XCTAssertEqual(window.globalRect, rect)
        XCTAssertEqual(window.displayName, "Document")
        XCTAssertNotEqual(window, .region(globalRect: rect))
    }

    func testEvenVideoDimensionsNeverGrowPastSelection() {
        XCTAssertEqual(RecordingEngine.evenDimension(1), 2)
        XCTAssertEqual(RecordingEngine.evenDimension(200), 200)
        XCTAssertEqual(RecordingEngine.evenDimension(201), 200)
    }

    func testTerminalScreenCaptureStopErrorsAreRecognized() {
        XCTAssertTrue(RecordingEngine.isTerminalStreamStopError(NSError(
            domain: SCStreamErrorDomain,
            code: -3817
        )))
        XCTAssertTrue(RecordingEngine.isTerminalStreamStopError(NSError(
            domain: SCStreamErrorDomain,
            code: -3821
        )))
        XCTAssertFalse(RecordingEngine.isTerminalStreamStopError(NSError(
            domain: SCStreamErrorDomain,
            code: -3811
        )))
    }

    func testVideoResolutionPreservesAspectRatioWithoutUpscaling() {
        XCTAssertEqual(
            RecordingVideoResolution.p1080.outputSize(for: CGSize(width: 2_560, height: 1_600)),
            CGSize(width: 1_728, height: 1_080)
        )
        XCTAssertEqual(
            RecordingVideoResolution.p1080.outputSize(for: CGSize(width: 1_600, height: 2_560)),
            CGSize(width: 1_080, height: 1_728)
        )
        XCTAssertEqual(
            RecordingVideoResolution.p1080.outputSize(for: CGSize(width: 1_280, height: 800)),
            CGSize(width: 1_280, height: 800)
        )
        XCTAssertEqual(
            RecordingVideoResolution.p4K.outputSize(for: CGSize(width: 3_000, height: 3_000)),
            CGSize(width: 2_160, height: 2_160)
        )
        XCTAssertEqual(
            RecordingVideoResolution.native.outputSize(for: CGSize(width: 2_561, height: 1_601)),
            CGSize(width: 2_560, height: 1_600)
        )
    }

    func testRecordingRegionGeometryUsesPixelsAndPreservesAspectRatio() {
        let bounds = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let exact = RecordingRegionGeometry.centeredRect(
            pixelSize: CGSize(width: 1_920, height: 1_080),
            scale: 2,
            around: CGPoint(x: bounds.midX, y: bounds.midY),
            in: bounds
        )
        XCTAssertEqual(exact.size, CGSize(width: 960, height: 540))
        XCTAssertTrue(bounds.contains(exact))

        let widescreen = RecordingRegionGeometry.fittedRect(
            aspectRatio: 16 / 9,
            around: CGPoint(x: bounds.midX, y: bounds.midY),
            preferredWidth: 960,
            in: bounds
        )
        XCTAssertEqual(widescreen.size, CGSize(width: 960, height: 540))
        XCTAssertTrue(bounds.contains(widescreen))
    }

    func testRecordingRegionSnapshotsScaleAcrossDisplaysAndPersist() throws {
        let suiteName = "BrushotTests.RecordingRegion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceBounds = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let snapshot = try XCTUnwrap(RecordingRegionPreferences.snapshot(
            for: CGRect(x: 100, y: 160, width: 500, height: 400),
            in: sourceBounds
        ))
        RecordingRegionPreferences.setLast(snapshot, defaults: defaults)
        XCTAssertEqual(RecordingRegionPreferences.last(defaults: defaults), snapshot)
        XCTAssertEqual(
            RecordingRegionPreferences.rect(
                for: snapshot,
                in: CGRect(x: 0, y: 0, width: 2_000, height: 1_600)
            ),
            CGRect(x: 200, y: 320, width: 1_000, height: 800)
        )
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

    func testVideoQualityPreferencesDefaultAndPersist() throws {
        let suite = "Brushot.VideoQualityPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecordingPreferences.videoResolution(defaults: defaults), .p1080)
        XCTAssertEqual(RecordingPreferences.videoFPS(defaults: defaults), 30)
        RecordingPreferences.setVideoResolution(.p4K, defaults: defaults)
        RecordingPreferences.setVideoFPS(60, defaults: defaults)
        XCTAssertEqual(RecordingPreferences.videoResolution(defaults: defaults), .p4K)
        XCTAssertEqual(RecordingPreferences.videoFPS(defaults: defaults), 60)
        RecordingPreferences.setVideoFPS(24, defaults: defaults)
        XCTAssertEqual(RecordingPreferences.videoFPS(defaults: defaults), 30)
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

    func testRecordingCountdownUsesThreeTwoOne() {
        XCTAssertEqual(RecordingCountdown.seconds, [3, 2, 1])
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

    func testRecoveryStorePreservesRawGIFRecordingIntent() {
        let gifRecording = URL(fileURLWithPath: "/tmp/Brushot-RecordingGIF-123.mov")
        let videoRecording = URL(fileURLWithPath: "/tmp/Brushot-Recording-123.mov")

        XCTAssertEqual(RecordingRecoveryStore.intendedFormat(for: gifRecording), .gif)
        XCTAssertEqual(RecordingRecoveryStore.intendedFormat(for: videoRecording), .video)
    }

    func testKnownVirtualMicrophonesAreHidden() {
        XCTAssertFalse(RecordingMicrophones.shouldShowDevice(named: "iFlyrecAudioDevice"))
        XCTAssertFalse(RecordingMicrophones.shouldShowDevice(named: "IdeaShare 2ch"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "MacBook Pro 麦克风"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "MacBook Pro Microphone"))
        XCTAssertTrue(RecordingMicrophones.shouldShowDevice(named: "外置麦克风"))
    }

    func testRecordingDurationLimitsAndCountdowns() {
        XCTAssertEqual(RecordingLimits.maximumDuration(for: .gif), 60)
        XCTAssertEqual(RecordingLimits.maximumDuration(for: .video), 7_200)
        XCTAssertEqual(RecordingLimits.remainingTime(for: .gif, elapsed: 0), 60)
        XCTAssertEqual(RecordingLimits.remainingTime(for: .gif, elapsed: 30), 30)
        XCTAssertEqual(RecordingLimits.remainingTime(for: .gif, elapsed: 60), 0)
        XCTAssertNil(RecordingLimits.remainingTime(for: .video, elapsed: 3_599))
        XCTAssertEqual(RecordingLimits.remainingTime(for: .video, elapsed: 3_600), 3_600)
        XCTAssertEqual(RecordingLimits.remainingTime(for: .video, elapsed: 7_200), 0)
        XCTAssertEqual(RecordingDiskSpace.warningFreeBytes, 16_000_000_000)
        XCTAssertEqual(RecordingDiskSpace.minimumFreeBytesToStart, 12_000_000_000)
        XCTAssertEqual(RecordingDiskSpace.minimumFreeBytesToContinue, 12_000_000_000)
        XCTAssertGreaterThan(
            RecordingDiskSpace.warningFreeBytes,
            RecordingDiskSpace.minimumFreeBytesToStart
        )
        XCTAssertEqual(
            RecordingDiskSpace.startDecision(availableBytes: 11_999_999_999),
            .blocked
        )
        XCTAssertEqual(
            RecordingDiskSpace.startDecision(availableBytes: 12_000_000_000),
            .warning
        )
        XCTAssertEqual(
            RecordingDiskSpace.startDecision(availableBytes: 15_999_999_999),
            .warning
        )
        XCTAssertEqual(
            RecordingDiskSpace.startDecision(availableBytes: 16_000_000_000),
            .allowed
        )
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
        var watermark = WatermarkConfiguration.default
        watermark.isEnabled = true
        watermark.text = "Brushot"
        _ = try await RecordingExporter.exportEditedMP4(
            source: source,
            destination: edited,
            plan: plan,
            watermarkConfiguration: watermark,
            watermarkContext: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )
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
    func testRegionRecordingShowsEditablePixelSizeAndFullscreenDoesNot() throws {
        let area = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            purpose: .recording,
            allowsRecordingRegionSizing: true
        )
        area.presetSelection(CGRect(x: 200, y: 180, width: 960, height: 540))
        let areaRecordingBar = try XCTUnwrap(descendants(of: area).first { $0 is RecordingStartBar })
        area.layoutSubtreeIfNeeded()
        let areaSizeButton = try XCTUnwrap(descendants(of: areaRecordingBar).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingRegionSize"
        })
        XCTAssertFalse(areaSizeButton.isHidden)
        XCTAssertEqual(regionDimensions(areaSizeButton.title), [960, 540])

        area.updateRecordingAspectRatio(1)
        let square = regionDimensions(areaSizeButton.title)
        XCTAssertEqual(square[0], square[1])

        area.updateRecordingAspectRatio(16 / 9)
        let widescreen = regionDimensions(areaSizeButton.title)
        XCTAssertEqual(Double(widescreen[0]) / Double(widescreen[1]), 16.0 / 9.0, accuracy: 0.02)
        let rightHandle = CGPoint(
            x: 680 + CGFloat(widescreen[0]) / 2,
            y: 450
        )
        area.mouseDown(with: try recordingMouseEvent(type: .leftMouseDown, at: rightHandle))
        area.mouseDragged(with: try recordingMouseEvent(
            type: .leftMouseDragged,
            at: CGPoint(x: rightHandle.x - 120, y: rightHandle.y)
        ))
        area.mouseUp(with: try recordingMouseEvent(
            type: .leftMouseUp,
            at: CGPoint(x: rightHandle.x - 120, y: rightHandle.y)
        ))
        XCTAssertEqual(
            Double(regionDimensions(areaSizeButton.title)[0]) /
                Double(regionDimensions(areaSizeButton.title)[1]),
            16.0 / 9.0,
            accuracy: 0.02
        )

        let fullscreen = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            purpose: .recording,
            allowsRecordingRegionSizing: false
        )
        fullscreen.presetSelection(fullscreen.bounds)
        let fullscreenRecordingBar = try XCTUnwrap(
            descendants(of: fullscreen).first { $0 is RecordingStartBar }
        )
        let fullscreenSizeButton = try XCTUnwrap(
            descendants(of: fullscreenRecordingBar).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "recordingRegionSize"
            }
        )
        XCTAssertTrue(fullscreenSizeButton.isHidden)
    }

    func testCameraPermissionRequestBlocksStartingUntilItFinishes() async throws {
        let original = RecordingCameraPreferences.load()
        var disabled = original
        disabled.isEnabled = false
        RecordingCameraPreferences.save(disabled)
        defer { RecordingCameraPreferences.save(original) }

        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 176))
        bar.availableDiskBytesProvider = { 20_000_000_000 }
        let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
        let camera = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingCamera"
        })
        let start = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "startRecordingAction"
        })
        try XCTSkipIf(!camera.isEnabled, "This host has no camera to exercise the permission UI.")
        var didStart = false
        bar.onStart = { _, _, _, _, _, _, _, _ in didStart = true }
        bar.cameraPermissionRequester = {
            try? await Task.sleep(for: .milliseconds(120))
            return .authorized
        }

        camera.performClick(nil)
        XCTAssertFalse(start.isEnabled)
        XCTAssertEqual(start.title, "正在请求摄像头权限…")
        start.performClick(nil)
        XCTAssertFalse(didStart)

        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.title, "开始录制视频")
        start.performClick(nil)
        XCTAssertTrue(didStart)
    }

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

    func testFullscreenRecordingStartsWithCompactControls() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertTrue(RecordingSessionController.shouldStartWithCollapsedControls(
            selectionRect: screen,
            screenFrame: screen
        ))
        XCTAssertFalse(RecordingSessionController.shouldStartWithCollapsedControls(
            selectionRect: CGRect(x: 100, y: 100, width: 1_200, height: 700),
            screenFrame: screen
        ))
        XCTAssertLessThan(
            RecordingSessionController.collapsedControlSize.width,
            RecordingSessionController.expandedControlSize.width
        )
        XCTAssertLessThan(
            RecordingSessionController.collapsedControlSize.height,
            RecordingSessionController.drawingControlSize.height
        )
        XCTAssertLessThan(
            RecordingSessionController.expandedControlSize.width,
            RecordingSessionController.drawingControlSize.width
        )
    }

    func testFormatChooserOffersVideoGIFAndPersistedAudioToggle() throws {
        let originalAudioPreference = RecordingPreferences.systemAudioEnabled()
        let originalMicrophonePreference = RecordingPreferences.microphoneEnabled()
        let originalResolution = RecordingPreferences.videoResolution()
        let originalFPS = RecordingPreferences.videoFPS()
        defer {
            RecordingPreferences.setSystemAudioEnabled(originalAudioPreference)
            RecordingPreferences.setMicrophoneEnabled(originalMicrophonePreference)
            RecordingPreferences.setVideoResolution(originalResolution)
            RecordingPreferences.setVideoFPS(originalFPS)
        }
        RecordingPreferences.setSystemAudioEnabled(false)
        RecordingPreferences.setMicrophoneEnabled(false)
        RecordingPreferences.setVideoResolution(.p1080)
        RecordingPreferences.setVideoFPS(30)
        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 176))
        bar.availableDiskBytesProvider = { 20_000_000_000 }
        bar.updateSourcePixelSize(CGSize(width: 2_560, height: 1_600))
        bar.updateRegionSelection(
            pixelSize: CGSize(width: 1_512, height: 982),
            hasLast: false,
            isAvailable: true
        )
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
        let resolutionPopup = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "recordingVideoResolution"
        })
        let fpsPopup = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "recordingVideoFPS"
        })
        let regionSizeButton = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingRegionSize"
        })
        let cameraSettingsButton = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingCameraSettings"
        })
        XCTAssertNil(descendants(of: bar).first {
            $0.identifier?.rawValue == "recordingMicrophoneVolume"
        })
        XCTAssertNil(buttons.first { $0.identifier?.rawValue == "recordingWatermark" })
        XCTAssertNil(buttons.first { $0.identifier?.rawValue == "recordingWatermarkInfo" })
        XCTAssertFalse(microphonePopup.isHidden)
        XCTAssertNotNil(microphonePopup.constraints.first {
            $0.firstAttribute == .width && $0.constant >= 170
        })
        let labels = descendants(of: bar).compactMap { $0 as? NSTextField }
        let audioLabel = try XCTUnwrap(labels.first { $0.stringValue == "视频音频" })
        let qualityLabel = try XCTUnwrap(labels.first { $0.stringValue == "分辨率" })
        let frameRateLabel = try XCTUnwrap(labels.first { $0.stringValue == "帧率" })
        XCTAssertNil(labels.first { $0.stringValue.hasPrefix("输出 ") })
        let silentHint = try XCTUnwrap(labels.first {
            $0.stringValue == "GIF 最长 60 秒，建议 30 秒内 · 无声音"
        })
        let performanceHint = try XCTUnwrap(labels.first {
            $0.stringValue == "高负载"
        })
        XCTAssertTrue(performanceHint.isHidden)
        XCTAssertEqual(fpsPopup.selectedItem?.title, "30 帧/秒（推荐）")
        XCTAssertFalse(regionSizeButton.isHidden)
        XCTAssertTrue(cameraSettingsButton.isHidden)
        XCTAssertEqual(regionDimensions(regionSizeButton.title), [1_512, 982])

        resolutionPopup.selectItem(at: try XCTUnwrap(resolutionPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == RecordingVideoResolution.p4K.rawValue
        }))
        XCTAssertTrue(resolutionPopup.sendAction(resolutionPopup.action, to: resolutionPopup.target))
        fpsPopup.selectItem(at: try XCTUnwrap(fpsPopup.itemArray.firstIndex {
            ($0.representedObject as? Int) == 60
        }))
        XCTAssertTrue(fpsPopup.sendAction(fpsPopup.action, to: fpsPopup.target))
        XCTAssertEqual(RecordingPreferences.videoResolution(), .p4K)
        XCTAssertEqual(RecordingPreferences.videoFPS(), 60)
        XCTAssertFalse(performanceHint.isHidden)

        bar.layoutSubtreeIfNeeded()
        for view in [resolutionPopup, fpsPopup, regionSizeButton, performanceHint] {
            let frame = view.convert(view.bounds, to: bar)
            XCTAssertGreaterThanOrEqual(frame.minX, bar.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, bar.bounds.maxX)
            XCTAssertGreaterThanOrEqual(frame.minY, bar.bounds.minY)
            XCTAssertLessThanOrEqual(frame.maxY, bar.bounds.maxY)
        }
        XCTAssertGreaterThanOrEqual(resolutionPopup.frame.width, resolutionPopup.fittingSize.width)
        XCTAssertGreaterThanOrEqual(fpsPopup.frame.width, fpsPopup.fittingSize.width)
        XCTAssertGreaterThanOrEqual(performanceHint.frame.width, performanceHint.fittingSize.width)
        var received: [(RecordingFormat, RecordingVideoResolution, Int, Bool, Bool)] = []
        var receivedWatermarks: [WatermarkConfiguration?] = []
        bar.onStart = { format, resolution, fps, systemAudio, microphone, _, _, watermark in
            received.append((format, resolution, fps, systemAudio, microphone))
            receivedWatermarks.append(watermark)
        }

        audio.performClick(nil)
        start.performClick(nil)
        format.selectedSegment = 1
        format.performClick(nil)
        XCTAssertTrue(audioLabel.isHidden)
        XCTAssertTrue(qualityLabel.isHidden)
        XCTAssertTrue(frameRateLabel.isHidden)
        XCTAssertTrue(resolutionPopup.isHidden)
        XCTAssertTrue(fpsPopup.isHidden)
        XCTAssertTrue(regionSizeButton.isHidden)
        XCTAssertTrue(audio.isHidden)
        XCTAssertTrue(microphone.isHidden)
        XCTAssertTrue(microphonePopup.isHidden)
        XCTAssertFalse(silentHint.isHidden)
        XCTAssertEqual(start.title, "开始录制 GIF")
        start.performClick(nil)

        XCTAssertEqual(received.map(\.0), [.video, .gif])
        XCTAssertEqual(received.map(\.1), [.p4K, .p4K])
        XCTAssertEqual(received.map(\.2), [60, 60])
        XCTAssertEqual(received.map(\.3), [true, false])
        XCTAssertEqual(received.map(\.4), [false, false])
        XCTAssertTrue(receivedWatermarks.allSatisfy { $0 == nil })
        XCTAssertTrue(RecordingPreferences.systemAudioEnabled())
    }

    func testCameraSettingsOfferShapeSizePositionAndHorizontalFlip() throws {
        let view = RecordingCameraSettingsView(
            frame: CGRect(x: 0, y: 0, width: 330, height: 154),
            options: .defaults,
            showsDevice: false
        )
        view.layoutSubtreeIfNeeded()
        let segments = descendants(of: view).compactMap { $0 as? NSSegmentedControl }
        let shape = try XCTUnwrap(segments.first {
            $0.identifier?.rawValue == "recordingCameraSettingsShape"
        })
        let size = try XCTUnwrap(segments.first {
            $0.identifier?.rawValue == "recordingCameraSettingsSize"
        })
        let position = try XCTUnwrap(segments.first {
            $0.identifier?.rawValue == "recordingCameraSettingsPosition"
        })
        let flip = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingCameraSettingsFlip"
        })

        XCTAssertEqual(shape.segmentCount, RecordingCameraShape.allCases.count)
        XCTAssertEqual(size.segmentCount, RecordingCameraSize.allCases.count)
        XCTAssertEqual(position.segmentCount, RecordingCameraPosition.allCases.count)
        XCTAssertEqual(flip.title, "左右翻转")
        XCTAssertEqual(flip.state, .on)
        XCTAssertNil(descendants(of: view).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "可直接拖动画中画调整位置"
        })
        for control in [shape, size, position] {
            let frame = control.convert(control.bounds, to: view)
            XCTAssertTrue(view.bounds.contains(frame))
        }
        XCTAssertTrue(view.bounds.contains(flip.convert(flip.bounds, to: view)))

        let liveView = RecordingCameraSettingsView(
            frame: CGRect(x: 0, y: 0, width: 330, height: 190),
            options: .defaults,
            showsDevice: true
        )
        liveView.layoutSubtreeIfNeeded()
        for control in descendants(of: liveView).filter({
            $0.identifier?.rawValue.hasPrefix("recordingCameraSettings") == true
        }) {
            XCTAssertTrue(liveView.bounds.contains(control.convert(control.bounds, to: liveView)))
        }

        var received: RecordingCameraOptions?
        view.onOptionsChanged = { received = $0 }
        size.selectedSegment = 2
        XCTAssertTrue(size.sendAction(size.action, to: size.target))
        XCTAssertEqual(received?.relativeWidth, RecordingCameraSize.large.relativeWidth)
        flip.performClick(nil)
        XCTAssertEqual(received?.isMirrored, false)
    }

    func testRecordingFormatChooserDoesNotOfferWatermarkBeforeRecording() {
        let bar = RecordingStartBar(frame: CGRect(x: 0, y: 0, width: 650, height: 176))
        let buttons = descendants(of: bar).compactMap { $0 as? NSButton }
        XCTAssertNil(buttons.first { $0.identifier?.rawValue == "recordingWatermark" })
        XCTAssertNil(buttons.first { $0.identifier?.rawValue == "recordingWatermarkInfo" })
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
        var preferredSize: CGSize?
        toolbar.onToolSelected = { selectedTool = $0 }
        toolbar.onPreferredSizeChanged = { preferredSize = $0 }
        rectangle.performClick(nil)
        XCTAssertEqual(selectedTool, .rectangle)
        XCTAssertEqual(rectangle.state, .on)
        XCTAssertEqual(preferredSize, RecordingAnnotationToolbarView.drawingPreferredSize)

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

        let select = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "recordingAnnotation.select"
        })
        select.performClick(nil)
        XCTAssertEqual(preferredSize, RecordingAnnotationToolbarView.selectionPreferredSize)
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
        let content = try XCTUnwrap(controller.window?.contentView)
        let views = descendants(of: content)

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
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingEditUndo" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingEditRedo" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingTrimStart" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingDeleteStart" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingExtractFrame" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingConvertGIF" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingFileActions" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingMetadata" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingWatermarkControls" })
        let watermarkSettings = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingExportWatermarkSettings"
        })
        XCTAssertEqual(watermarkSettings.title, "编辑水印…")
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingExportProgressControls" })
        let watermark = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingExportWatermark"
        })
        XCTAssertEqual(watermark.state, .off)
        let watermarkStatus = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "recordingExportWatermarkHint"
        })
        XCTAssertTrue(watermarkStatus.isHidden)
        XCTAssertEqual(watermarkStatus.stringValue, "")
        let watermarkControls = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingWatermarkControls"
        })
        let playerView = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingPreviewPlayer"
        })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(watermarkControls.frame.width, playerView.frame.width, accuracy: 1)

        controller.close()
    }

    func testVideoRecordingPreviewKeepsPreRecordingWatermarkAsExportDefault() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).mov")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var configuration = WatermarkConfiguration.default
        configuration.text = "Brushot"

        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .video,
            duration: 12,
            pixelSize: CGSize(width: 320, height: 180),
            watermarkConfiguration: configuration,
            watermarkEnabled: true,
            onClose: {}
        )
        let views = descendants(of: try XCTUnwrap(controller.window?.contentView))
        let watermark = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingExportWatermark"
        })
        let status = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "recordingExportWatermarkHint"
        })

        XCTAssertEqual(watermark.state, .on)
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(status.stringValue, "保存或复制时添加，导出时间可能稍长")
        watermark.performClick(nil)
        XCTAssertEqual(watermark.state, .off)
        XCTAssertTrue(status.isHidden)
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
        let playerView = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingPreviewPlayer"
        })
        let standardFileActions = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingFileActions"
        })
        let gifControls = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingGIFSelectionControls"
        })
        let gifExport = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "recordingGIFExportSelection"
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
        XCTAssertTrue(standardFileActions.isHidden)
        XCTAssertFalse(gifControls.isHidden)
        XCTAssertEqual(controller.window?.title, "MP4 转 GIF")
        XCTAssertGreaterThan(overview.bounds.width, 0)
        XCTAssertGreaterThan(detail.bounds.width, 0)
        XCTAssertTrue(status.stringValue.contains("00:15.0"))
        let gifControlsFrame = gifControls.convert(gifControls.bounds, to: content)
        let exportFrame = gifExport.convert(gifExport.bounds, to: content)
        let playerFrame = playerView.convert(playerView.bounds, to: content)
        XCTAssertGreaterThanOrEqual(gifControlsFrame.minY, content.bounds.minY - 1)
        XCTAssertLessThanOrEqual(gifControlsFrame.maxY, content.bounds.maxY + 1)
        XCTAssertGreaterThanOrEqual(exportFrame.minY, content.bounds.minY - 1)
        XCTAssertLessThanOrEqual(exportFrame.maxY, content.bounds.maxY + 1)
        XCTAssertFalse(playerFrame.intersects(gifControlsFrame))
        XCTAssertEqual(playerFrame.height, 240, accuracy: 1)

        controller.window?.setContentSize(CGSize(width: 1_200, height: 900))
        content.layoutSubtreeIfNeeded()
        let enlargedGIFFrame = gifControls.convert(gifControls.bounds, to: content)
        let enlargedPlayerFrame = playerView.convert(playerView.bounds, to: content)
        let enlargedExportFrame = gifExport.convert(gifExport.bounds, to: content)
        XCTAssertFalse(enlargedPlayerFrame.intersects(enlargedGIFFrame))
        XCTAssertEqual(enlargedPlayerFrame.height, 240, accuracy: 1)
        XCTAssertEqual(enlargedGIFFrame.height, gifControlsFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(enlargedExportFrame.minY, content.bounds.minY - 1)
        XCTAssertLessThanOrEqual(enlargedExportFrame.maxY, content.bounds.maxY + 1)

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
        XCTAssertFalse(standardFileActions.isHidden)
        XCTAssertTrue(gifControls.isHidden)
        XCTAssertEqual(controller.window?.title, "录制完成")

        controller.close()
    }

    func testExistingGIFFilePreviewDoesNotShowPlaybackControls() throws {
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
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(of: content)

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

    func testRawGIFRecordingOpensVideoPreviewWithPostRecordingWatermarkControls() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-PreviewTests-\(UUID().uuidString).mov")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let controller = RecordingPreviewWindowController(
            fileURL: file,
            format: .gif,
            duration: 12,
            pixelSize: CGSize(width: 320, height: 180),
            onClose: {}
        )
        let content = try XCTUnwrap(controller.window?.contentView)
        let views = descendants(of: content)

        XCTAssertTrue(try XCTUnwrap(controller.window).styleMask.contains(.resizable))
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingPreviewPlayer" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingPreviewControls" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingWatermarkControls" })
        XCTAssertNotNil(views.first { $0.identifier?.rawValue == "recordingExportProgressControls" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingEditingControls" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "recordingGIFSelectionControls" })
        let fileActions = try XCTUnwrap(views.first { $0.identifier?.rawValue == "recordingFileActions" })
        let watermarkControls = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "recordingWatermarkControls"
        })
        let playerView = try XCTUnwrap(views.first { $0.identifier?.rawValue == "recordingPreviewPlayer" })
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(fileActions.frame.minY, 16)
        XCTAssertEqual(watermarkControls.frame.width, playerView.frame.width, accuracy: 1)
        XCTAssertLessThanOrEqual(content.frame.height, 450)
        controller.close()
    }

    func testRecordingCopyCacheKeyReusesOnlyMatchingEditsAndWatermark() {
        let plan = RecordingEditPlan(duration: 12)
        var watermark = WatermarkConfiguration.default
        watermark.text = "Brushot"

        let original = RecordingCopyCacheKey.make(
            format: .video,
            editPlan: plan,
            watermarkEnabled: true,
            watermarkConfiguration: watermark
        )
        let same = RecordingCopyCacheKey.make(
            format: .video,
            editPlan: plan,
            watermarkEnabled: true,
            watermarkConfiguration: watermark
        )
        var trimmedPlan = plan
        trimmedPlan.setTrimStart(1)
        let trimmed = RecordingCopyCacheKey.make(
            format: .video,
            editPlan: trimmedPlan,
            watermarkEnabled: true,
            watermarkConfiguration: watermark
        )
        watermark.opacity = 0.4
        let changedWatermark = RecordingCopyCacheKey.make(
            format: .video,
            editPlan: plan,
            watermarkEnabled: true,
            watermarkConfiguration: watermark
        )
        let watermarkDisabled = RecordingCopyCacheKey.make(
            format: .video,
            editPlan: plan,
            watermarkEnabled: false,
            watermarkConfiguration: watermark
        )

        XCTAssertEqual(original, same)
        XCTAssertNotEqual(original, trimmed)
        XCTAssertNotEqual(original, changedWatermark)
        XCTAssertNotEqual(original, watermarkDisabled)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func regionDimensions(_ title: String) -> [Int] {
        title.replacingOccurrences(of: ",", with: "")
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private func recordingMouseEvent(type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
