import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class RecordingExportProgressWindowController: NSWindowController {
    private let label = NSTextField(labelWithString: L.text("正在准备录制文件…"))
    private let indicator = NSProgressIndicator()

    init(format: RecordingFormat) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L.format("正在生成%@", format.displayName)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView else { return }
        label.alignment = .center
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.style = .bar
        let stack = NSStackView(views: [label, indicator])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(stage: RecordingExportStage, fraction: Double) {
        label.stringValue = switch stage {
        case .preparing: L.text("正在准备…")
        case .encoding: L.text("正在编码…")
        case .finalizing: L.text("正在完成…")
        }
        indicator.doubleValue = min(1, max(0, fraction))
    }
}

@MainActor
final class RecordingPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let fileURL: URL
    private let format: RecordingFormat
    private let onClose: () -> Void
    private let imageView = NSImageView()
    private let playerView = RecordingPlayerView()
    private var previewHeightConstraint: NSLayoutConstraint?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var duration: TimeInterval = 0
    private var isSeeking = false
    private lazy var playPauseButton: NSButton = {
        let button = NSButton(title: L.text("播放"), target: self, action: #selector(togglePlayback))
        button.identifier = NSUserInterfaceItemIdentifier("recordingPreviewPlayPause")
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L.text("播放"))
        button.imagePosition = .imageOnly
        button.toolTip = L.text("播放")
        return button
    }()
    private lazy var progressSlider: NSSlider = {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekPlayback))
        slider.identifier = NSUserInterfaceItemIdentifier("recordingPreviewProgress")
        slider.isContinuous = true
        return slider
    }()
    private lazy var timeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "00:00 / 00:00")
        label.identifier = NSUserInterfaceItemIdentifier("recordingPreviewTime")
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        return label
    }()
    private lazy var volumeSlider: NSSlider = {
        let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(changeVolume))
        slider.identifier = NSUserInterfaceItemIdentifier("recordingPreviewVolume")
        slider.isContinuous = true
        slider.toolTip = L.text("音量")
        return slider
    }()
    private var ownsFile = true
    private var didClose = false

    init(
        fileURL: URL,
        format: RecordingFormat,
        duration: TimeInterval,
        pixelSize: CGSize,
        onClose: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.format = format
        self.onClose = onClose
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: format == .video
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.text("录制完成")
        if format == .video {
            window.minSize = CGSize(width: 560, height: 420)
            window.contentAspectRatio = Self.windowAspectRatio(for: pixelSize)
        }
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent(duration: duration, pixelSize: pixelSize)
        configurePreview()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        finishClosing()
    }

    static func cleanupExpiredClipboardFiles(now: Date = Date()) {
        cleanupAbandonedTemporaryFiles()
        let directory = clipboardDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if date == nil || date! < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func configureContent(duration: TimeInterval, pixelSize: CGSize) {
        guard let content = window?.contentView else { return }
        self.duration = max(0, duration)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        playerView.identifier = NSUserInterfaceItemIdentifier("recordingPreviewPlayer")

        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let metadata = NSTextField(labelWithString: String(
            format: "%@ · %.0f × %.0f · %02d:%02d · %@",
            format.displayName,
            pixelSize.width,
            pixelSize.height,
            Int(duration) / 60,
            Int(duration) % 60,
            ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        ))
        metadata.alignment = .center
        metadata.textColor = .secondaryLabelColor

        let discard = NSButton(title: L.text("丢弃"), target: self, action: #selector(discardAction))
        discard.identifier = NSUserInterfaceItemIdentifier("discardRecordingAction")
        let copy = NSButton(title: L.text("复制"), target: self, action: #selector(copyAction))
        copy.identifier = NSUserInterfaceItemIdentifier("copyRecordingAction")
        let save = NSButton(title: L.text("保存"), target: self, action: #selector(saveAction))
        save.identifier = NSUserInterfaceItemIdentifier("saveRecordingAction")
        save.keyEquivalent = "\r"
        save.contentTintColor = .controlAccentColor
        let buttons = NSStackView(views: [discard, copy, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let preview = format == .video ? playerView : imageView
        let stackViews = format == .video
            ? [preview, makePlaybackControls(), metadata, buttons]
            : [preview, metadata, buttons]
        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        let previewHeight = format == .video
            ? preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 310)
            : preview.heightAnchor.constraint(equalToConstant: 310)
        previewHeight.priority = .defaultHigh
        previewHeight.isActive = true
        previewHeightConstraint = previewHeight
        if format == .video {
            preview.setContentHuggingPriority(.defaultLow, for: .vertical)
            preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
    }

    private func makePlaybackControls() -> NSView {
        let volumeIcon = NSImageView(image: NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: L.text("音量")
        ) ?? NSImage())
        volumeIcon.contentTintColor = .secondaryLabelColor
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            volumeIcon.widthAnchor.constraint(equalToConstant: 18),
            volumeIcon.heightAnchor.constraint(equalToConstant: 18),
            volumeSlider.widthAnchor.constraint(equalToConstant: 90),
            timeLabel.widthAnchor.constraint(equalToConstant: 92)
        ])

        progressSlider.maxValue = max(1, duration)
        updateTimeLabel(current: 0)

        let controls = NSStackView(views: [
            playPauseButton,
            progressSlider,
            timeLabel,
            volumeIcon,
            volumeSlider
        ])
        controls.identifier = NSUserInterfaceItemIdentifier("recordingPreviewControls")
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            progressSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])
        return controls
    }

    private func configurePreview() {
        if format == .gif {
            imageView.image = NSImage(contentsOf: fileURL)
            return
        }
        let player = AVPlayer(url: fileURL)
        player.volume = Float(volumeSlider.doubleValue)
        self.player = player
        playerView.player = player
        addPlaybackObservers(to: player)
    }

    private func addPlaybackObservers(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updatePlaybackProgress(time: time)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
    }

    private func updatePlaybackProgress(time: CMTime) {
        let current = max(0, CMTimeGetSeconds(time))
        guard current.isFinite else { return }
        if !isSeeking {
            progressSlider.doubleValue = min(progressSlider.maxValue, current)
        }
        updateTimeLabel(current: current)
        updatePlaybackButton()
    }

    private func updatePlaybackButton() {
        let isPlaying = player?.timeControlStatus == .playing
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: L.text(isPlaying ? "暂停" : "播放")
        )
        playPauseButton.toolTip = L.text(isPlaying ? "暂停" : "播放")
    }

    private func updateTimeLabel(current: TimeInterval) {
        timeLabel.stringValue = "\(Self.formatTime(current)) / \(Self.formatTime(duration))"
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if progressSlider.doubleValue >= progressSlider.maxValue - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        updatePlaybackButton()
    }

    @objc private func seekPlayback() {
        guard let player else { return }
        isSeeking = true
        let target = CMTime(seconds: progressSlider.doubleValue, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.updateTimeLabel(current: self.progressSlider.doubleValue)
            }
        }
    }

    @objc private func changeVolume() {
        player?.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func playbackDidFinish() {
        player?.pause()
        progressSlider.doubleValue = progressSlider.maxValue
        updatePlaybackButton()
    }

    @objc private func saveAction() {
        let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(format: format))
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: fileURL, to: destination)
            ownsFile = false
            FeedbackSound.playSaveCompleted()
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            close()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func copyAction() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        do {
            if format == .gif {
                let data = try Data(contentsOf: fileURL)
                guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif")) else {
                    throw RecordingExportError.exportFailed(L.text("无法写入剪贴板。"))
                }
            } else {
                let directory = Self.clipboardDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let cached = directory.appendingPathComponent(Self.outputFileName(format: .video))
                try FileManager.default.copyItem(at: fileURL, to: cached)
                guard pasteboard.writeObjects([cached as NSURL]) else {
                    try? FileManager.default.removeItem(at: cached)
                    throw RecordingExportError.exportFailed(L.text("无法写入剪贴板。"))
                }
            }
            FeedbackSound.playCopyCompleted()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func discardAction() { close() }

    private func finishClosing() {
        guard !didClose else { return }
        didClose = true
        teardownPlayer()
        if ownsFile { try? FileManager.default.removeItem(at: fileURL) }
        onClose()
    }

    private func teardownPlayer() {
        guard let player else { return }
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        playerView.player = nil
        self.player = nil
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.text("录制文件操作失败")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }

    private static var clipboardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brushot", isDirectory: true)
            .appendingPathComponent("RecordingClipboard", isDirectory: true)
    }

    private static func cleanupAbandonedTemporaryFiles() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where
            file.lastPathComponent.hasPrefix("Brushot-Recording-")
                || file.lastPathComponent.hasPrefix("Brushot-Export-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func outputFileName(format: RecordingFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Brushot-\(formatter.string(from: Date())).\(format.fileExtension)"
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let rounded = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", rounded / 60, rounded % 60)
    }

    private static func windowAspectRatio(for pixelSize: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 16, height: 9)
        }
        return pixelSize
    }
}

private final class RecordingPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 8
        playerLayer.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
