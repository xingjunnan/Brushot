import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum RecordingFormat: String, Sendable {
    case video
    case gif

    var displayName: String { self == .video ? L.text("视频") : "GIF" }
    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

enum RecordingPreferences {
    private static let systemAudioKey = "recording.systemAudioEnabled"
    private static let microphoneKey = "recording.microphoneEnabled"
    private static let microphoneDeviceKey = "recording.microphoneDeviceID"

    static func systemAudioEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: systemAudioKey)
    }

    static func setSystemAudioEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: systemAudioKey)
    }

    static func microphoneEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: microphoneKey)
    }

    static func setMicrophoneEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: microphoneKey)
    }

    static func microphoneDeviceID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: microphoneDeviceKey)
    }

    static func setMicrophoneDeviceID(_ identifier: String?, defaults: UserDefaults = .standard) {
        if let identifier { defaults.set(identifier, forKey: microphoneDeviceKey) }
        else { defaults.removeObject(forKey: microphoneDeviceKey) }
    }
}

struct RecordingMicrophoneDevice: Equatable, Sendable {
    let id: String
    let name: String
}

enum RecordingMicrophones {
    private static let hiddenDeviceNames: Set<String> = [
        "iflyrecaudiodevice",
        "ideashare 2ch"
    ]

    static func shouldShowDevice(named name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !hiddenDeviceNames.contains(normalized)
    }

    static func captureDevices() -> [AVCaptureDevice] {
        let devices: [AVCaptureDevice]
        if #available(macOS 14.0, *) {
            devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
        } else {
            devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
        return devices.filter { shouldShowDevice(named: $0.localizedName) }
    }

    static func availableDevices() -> [RecordingMicrophoneDevice] {
        captureDevices().map { RecordingMicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func canRequestOrUsePermission() -> Bool {
        authorizationStatus() != .restricted
    }

    static func requestPermission() async -> Bool {
        switch authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    static func requestPermissionIfNeeded() async -> AVAuthorizationStatus {
        let status = authorizationStatus()
        guard status == .notDetermined else { return status }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        return granted ? .authorized : authorizationStatus()
    }
}

final class MicrophoneCaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "com.brushot.recording.microphone.control")
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(
        deviceID: String?,
        sampleQueue: DispatchQueue,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        self.onSample = onSample
        super.init()
        let devices = RecordingMicrophones.captureDevices()
        let device = deviceID.flatMap { id in devices.first { $0.uniqueID == id } }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecordingError.microphoneUnavailable }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecordingError.microphoneUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func start() async throws {
        await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                self?.session.startRunning()
                continuation.resume()
            }
        }
        guard session.isRunning else { throw RecordingError.microphoneUnavailable }
    }

    func stop() async {
        guard session.isRunning else { return }
        await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                self?.session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample(sampleBuffer)
    }
}

enum RecordingState: String, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case exporting

    var isActive: Bool { self != .idle }
}

enum RecordingLimits {
    static let gifMaximumDuration: TimeInterval = 3 * 60
    static let videoMaximumDuration: TimeInterval = 2 * 60 * 60
    static let videoCountdownStart: TimeInterval = 60 * 60

    static func maximumDuration(for format: RecordingFormat) -> TimeInterval {
        format == .gif ? gifMaximumDuration : videoMaximumDuration
    }

    static func remainingTime(for format: RecordingFormat, elapsed: TimeInterval) -> TimeInterval? {
        guard format == .video, elapsed >= videoCountdownStart else { return nil }
        return max(0, videoMaximumDuration - elapsed)
    }
}

enum RecordingDiskSpace {
    static let minimumFreeBytes: Int64 = 1_000_000_000

    static func availableBytes(at url: URL = FileManager.default.temporaryDirectory) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func hasEnoughSpace(at url: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard let available = availableBytes(at: url) else { return true }
        return available >= minimumFreeBytes
    }
}

struct RecordingConfiguration: Sendable {
    let format: RecordingFormat
    var fps: Int = 30
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var microphoneDeviceID: String?
    var showsCursor = true
    var watermarkConfiguration: WatermarkConfiguration?
    var capturedAt = Date()
}

struct RecordingResult: Sendable {
    let sourceURL: URL
    let duration: TimeInterval
    let format: RecordingFormat
    let pixelSize: CGSize
    let capturedAt: Date
    let watermarkConfiguration: WatermarkConfiguration?
}

enum RecordingTimeline {
    static func adjustedTime(source: CMTime, firstSource: CMTime, paused: CMTime) -> CMTime {
        let adjusted = CMTimeSubtract(CMTimeSubtract(source, firstSource), paused)
        return CMTimeCompare(adjusted, .zero) < 0 ? .zero : adjusted
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case writerSetupFailed(String)
    case writerFailed(String)
    case noFrames
    case microphonePermissionDenied
    case microphoneUnavailable
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: L.text("已有录制正在进行。")
        case .notRecording: L.text("当前没有正在进行的录制。")
        case .writerSetupFailed(let reason): L.format("无法准备录制：%@", reason)
        case .writerFailed(let reason): L.format("录制写入失败：%@", reason)
        case .noFrames: L.text("没有录制到有效画面。")
        case .microphonePermissionDenied: L.text("没有麦克风权限。请在“系统设置 → 隐私与安全性 → 麦克风”中允许 Brushot，然后重试。")
        case .microphoneUnavailable: L.text("所选麦克风不可用，请重新连接设备或选择其他麦克风。")
        case .insufficientDiskSpace: L.text("磁盘剩余空间不足 1 GB，无法安全录制。请清理空间后重试。")
        }
    }
}

enum RecordingDiagnostics {
    static func describe(_ error: Error?) -> String {
        guard let error else { return L.text("未知错误。") }
        var parts: [String] = []
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []
        while let item = current, visited.insert(ObjectIdentifier(item)).inserted {
            let description = item.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = "\(item.domain) \(item.code)"
            if !description.isEmpty, description != "The operation could not be completed" {
                parts.append("\(description)（\(identity)）")
            } else {
                parts.append(identity)
            }
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: L.text("；底层错误："))
    }
}

@MainActor
final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var state: RecordingState = .idle
    private(set) var elapsedTime: TimeInterval = 0
    var onUnexpectedStop: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.brushot.recording.samples", qos: .userInitiated)
    private var stream: SCStream?
    private var microphoneCapture: MicrophoneCaptureSession?
    nonisolated(unsafe) private var writer: RecordingWriter?
    private var configuration: RecordingConfiguration?
    private var sourceURL: URL?
    private var pixelSize: CGSize = .zero
    private var elapsedTimer: Timer?
    private var activeStartedAt: Date?
    private var accumulatedElapsed: TimeInterval = 0

    func start(
        capturer: ScreenRegionCapturer,
        configuration: RecordingConfiguration
    ) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        guard RecordingDiskSpace.hasEnoughSpace() else { throw RecordingError.insufficientDiskSpace }
        state = .preparing
        elapsedTime = 0
        accumulatedElapsed = 0
        self.configuration = configuration

        if configuration.capturesMicrophone && configuration.format == .video {
            guard await RecordingMicrophones.requestPermission() else {
                reset()
                throw RecordingError.microphonePermissionDenied
            }
        }

        let streamConfiguration = capturer.streamConfiguration
        let width = Self.evenDimension(streamConfiguration.width)
        let height = Self.evenDimension(streamConfiguration.height)
        streamConfiguration.width = width
        streamConfiguration.height = height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, configuration.fps)))
        streamConfiguration.queueDepth = 5
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio && configuration.format == .video
        if streamConfiguration.capturesAudio {
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2
            streamConfiguration.excludesCurrentProcessAudio = true
        }
        let capturesMicrophone = configuration.capturesMicrophone && configuration.format == .video
        if #available(macOS 15.0, *), capturesMicrophone {
            streamConfiguration.captureMicrophone = true
            streamConfiguration.microphoneCaptureDeviceID = configuration.microphoneDeviceID
        }

        let url = Self.temporaryURL(extension: "mov")
        let recordingWriter: RecordingWriter
        do {
            recordingWriter = try RecordingWriter(
                outputURL: url,
                width: width,
                height: height,
                fps: configuration.fps,
                includesSystemAudio: streamConfiguration.capturesAudio,
                includesMicrophone: capturesMicrophone
            )
        } catch {
            state = .idle
            throw RecordingError.writerSetupFailed(error.localizedDescription)
        }

        let recordingStream = SCStream(
            filter: capturer.captureContentFilter,
            configuration: streamConfiguration,
            delegate: self
        )
        writer = recordingWriter
        sourceURL = url
        pixelSize = CGSize(width: width, height: height)
        if capturesMicrophone {
            if #available(macOS 15.0, *) {
                microphoneCapture = nil
            } else {
                microphoneCapture = try MicrophoneCaptureSession(
                    deviceID: configuration.microphoneDeviceID,
                    sampleQueue: sampleQueue,
                    onSample: { recordingWriter.appendMicrophone($0) }
                )
            }
        }
        do {
            try recordingStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if streamConfiguration.capturesAudio {
                try recordingStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if #available(macOS 15.0, *), capturesMicrophone {
                try recordingStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await recordingStream.startCapture()
            try await microphoneCapture?.start()
        } catch {
            await microphoneCapture?.stop()
            recordingWriter.cancel()
            try? FileManager.default.removeItem(at: url)
            reset()
            throw error
        }

        stream = recordingStream
        state = .recording
        activeStartedAt = Date()
        startElapsedTimer()
    }

    func pause() {
        guard state == .recording else { return }
        updateElapsed()
        accumulatedElapsed = elapsedTime
        activeStartedAt = nil
        state = .paused
        stopElapsedTimer()
        sampleQueue.async { [writer] in writer?.pause() }
    }

    func resume() {
        guard state == .paused else { return }
        state = .recording
        activeStartedAt = Date()
        sampleQueue.async { [writer] in writer?.resume() }
        startElapsedTimer()
    }

    func stop() async throws -> RecordingResult {
        guard state == .recording || state == .paused,
              let stream,
              let writer,
              let sourceURL,
              let configuration else {
            throw RecordingError.notRecording
        }
        if state == .recording { updateElapsed() }
        state = .stopping
        stopElapsedTimer()
        await microphoneCapture?.stop()
        try await stream.stopCapture()
        let duration: TimeInterval
        do {
            duration = try await withCheckedThrowingContinuation { continuation in
                sampleQueue.async {
                    writer.finish { continuation.resume(with: $0) }
                }
            }
        } catch {
            reset()
            try? FileManager.default.removeItem(at: sourceURL)
            throw error
        }
        guard duration > 0 else {
            reset()
            try? FileManager.default.removeItem(at: sourceURL)
            throw RecordingError.noFrames
        }
        let result = RecordingResult(
            sourceURL: sourceURL,
            duration: duration,
            format: configuration.format,
            pixelSize: pixelSize,
            capturedAt: configuration.capturedAt,
            watermarkConfiguration: configuration.watermarkConfiguration
        )
        reset()
        return result
    }

    func cancel() async {
        guard state.isActive else { return }
        stopElapsedTimer()
        await microphoneCapture?.stop()
        try? await stream?.stopCapture()
        let writer = self.writer
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                writer?.cancel()
                continuation.resume()
            }
        }
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        reset()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        guard let writer else { return }
        switch type {
        case .screen: writer.appendVideo(sampleBuffer)
        case .audio: writer.appendAudio(sampleBuffer)
        case .microphone: writer.appendMicrophone(sampleBuffer)
        @unknown default: break
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self, self.state != .stopping else { return }
            self.stopElapsedTimer()
            let url = self.sourceURL
            let writer = self.writer
            await self.microphoneCapture?.stop()
            self.sampleQueue.async { writer?.cancel() }
            if let url { try? FileManager.default.removeItem(at: url) }
            self.reset()
            self.onUnexpectedStop?(error)
        }
    }

    nonisolated static func evenDimension(_ value: Int) -> Int {
        let positive = max(2, value)
        return positive.isMultiple(of: 2) ? positive : positive - 1
    }

    private static func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Brushot-Recording-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsed() {
        elapsedTime = accumulatedElapsed + (activeStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func reset() {
        stopElapsedTimer()
        stream = nil
        microphoneCapture = nil
        writer = nil
        configuration = nil
        sourceURL = nil
        pixelSize = .zero
        activeStartedAt = nil
        accumulatedElapsed = 0
        state = .idle
    }
}

final class RecordingWriter: @unchecked Sendable {
    private struct AudioTimeline {
        var sourceStart: CMTime?
        var outputStart = CMTime.zero
        var pauseAtStart = CMTime.zero
    }

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let frameDuration: CMTime
    private var firstSourceTime: CMTime?
    private var systemAudioTimeline = AudioTimeline()
    private var microphoneTimeline = AudioTimeline()
    private var pauseStartedAt: CMTime?
    private var accumulatedPause = CMTime.zero
    private var latestOutputTime = CMTime.zero
    private var latestVideoTime = CMTime.zero
    private var wroteVideo = false
    private var isCancelled = false
    private var isPaused = false
    private var terminalError: Error?

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitsPerSecond = min(20_000_000, max(2_000_000, width * height * max(1, fps) / 10))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: max(1, fps),
                AVVideoMaxKeyFrameIntervalKey: max(1, fps * 2)
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard assetWriter.canAdd(videoInput) else {
            throw RecordingError.writerSetupFailed(L.text("视频编码器不可用。"))
        }
        assetWriter.add(videoInput)

        let writer = assetWriter
        func makeAudioInput(name: String) throws -> AVAssetWriterInput {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writerSetupFailed(L.format("%@编码器不可用。", name))
            }
            writer.add(input)
            return input
        }
        systemAudioInput = try includesSystemAudio ? makeAudioInput(name: L.text("系统音频")) : nil
        microphoneInput = try includesMicrophone ? makeAudioInput(name: L.text("麦克风")) : nil
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isCancelled, !isPaused, terminalError == nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSourceTime == nil {
            guard assetWriter.startWriting() else {
                recordFailure(assetWriter.error, fallback: L.text("无法启动视频编码器。"))
                return
            }
            firstSourceTime = sourceTime
            assetWriter.startSession(atSourceTime: .zero)
        }
        guard assetWriter.status == .writing else {
            recordFailure(assetWriter.error, fallback: L.text("视频编码器已停止工作。"))
            return
        }
        guard videoInput.isReadyForMoreMediaData, let firstSourceTime else { return }
        let presentationTime = RecordingTimeline.adjustedTime(
            source: sourceTime,
            firstSource: firstSourceTime,
            paused: accumulatedPause
        )
        if videoAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            wroteVideo = true
            latestVideoTime = CMTimeAdd(presentationTime, frameDuration)
            updateLatestTime(latestVideoTime)
        } else {
            recordFailure(assetWriter.error, fallback: L.text("视频帧写入失败。"))
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        appendAudioTrack(
            sampleBuffer,
            input: systemAudioInput,
            timeline: &systemAudioTimeline,
            name: L.text("系统音频")
        )
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        appendAudioTrack(
            sampleBuffer,
            input: microphoneInput,
            timeline: &microphoneTimeline,
            name: L.text("麦克风")
        )
    }

    func pause() {
        guard pauseStartedAt == nil else { return }
        isPaused = true
        pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
    }

    func resume() {
        guard let pauseStartedAt else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(now, pauseStartedAt))
        self.pauseStartedAt = nil
        isPaused = false
    }

    func finish(completion: @escaping @Sendable (Result<TimeInterval, Error>) -> Void) {
        if let terminalError {
            assetWriter.cancelWriting()
            completion(.failure(terminalError))
            return
        }
        guard wroteVideo else {
            assetWriter.cancelWriting()
            completion(.failure(RecordingError.noFrames))
            return
        }
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        let duration = latestVideoTime
        assetWriter.finishWriting { [self] in
            if self.assetWriter.status == .completed {
                completion(.success(max(0, CMTimeGetSeconds(duration))))
            } else {
                completion(.failure(RecordingError.writerFailed(
                    RecordingDiagnostics.describe(self.assetWriter.error)
                )))
            }
        }
    }

    func cancel() {
        isCancelled = true
        assetWriter.cancelWriting()
    }

    private func appendAudioTrack(
        _ sampleBuffer: CMSampleBuffer,
        input: AVAssetWriterInput?,
        timeline: inout AudioTimeline,
        name: String
    ) {
        guard !isCancelled, !isPaused, firstSourceTime != nil,
              let input, input.isReadyForMoreMediaData else { return }
        if timeline.sourceStart == nil {
            timeline.sourceStart = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            timeline.outputStart = latestVideoTime
            timeline.pauseAtStart = accumulatedPause
        }
        guard let adjusted = adjustedAudioCopy(of: sampleBuffer, timeline: timeline) else { return }
        if input.append(adjusted) {
            updateLatestTime(from: adjusted)
        } else {
            recordFailure(assetWriter.error, fallback: L.format("%@写入失败。", name))
        }
    }

    private func adjustedAudioCopy(
        of sampleBuffer: CMSampleBuffer,
        timeline: AudioTimeline
    ) -> CMSampleBuffer? {
        guard let sourceStart = timeline.sourceStart else { return nil }
        let pausedSinceStart = maxZero(CMTimeSubtract(accumulatedPause, timeline.pauseAtStart))
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        )
        guard count > 0 else { return nil }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        ) == noErr else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = adjustedAudioTime(
                    timings[index].presentationTimeStamp,
                    sourceStart: sourceStart,
                    outputStart: timeline.outputStart,
                    paused: pausedSinceStart
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = adjustedAudioTime(
                    timings[index].decodeTimeStamp,
                    sourceStart: sourceStart,
                    outputStart: timeline.outputStart,
                    paused: pausedSinceStart
                )
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
    }

    private func adjustedAudioTime(
        _ source: CMTime,
        sourceStart: CMTime,
        outputStart: CMTime,
        paused: CMTime
    ) -> CMTime {
        let relative = CMTimeSubtract(CMTimeSubtract(source, sourceStart), paused)
        return CMTimeAdd(outputStart, maxZero(relative))
    }

    private func updateLatestTime(from sampleBuffer: CMSampleBuffer) {
        let end = CMTimeAdd(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            maxZero(CMSampleBufferGetDuration(sampleBuffer))
        )
        updateLatestTime(end)
    }

    private func updateLatestTime(_ time: CMTime) {
        if CMTimeCompare(time, latestOutputTime) > 0 { latestOutputTime = time }
    }

    private func recordFailure(_ error: Error?, fallback: String) {
        guard terminalError == nil else { return }
        let reason = error.map(RecordingDiagnostics.describe) ?? fallback
        terminalError = RecordingError.writerFailed(reason)
        NSLog("Brushot recording writer failed: %@", reason)
    }

    private func maxZero(_ time: CMTime) -> CMTime {
        CMTimeCompare(time, .zero) < 0 ? .zero : time
    }
}
