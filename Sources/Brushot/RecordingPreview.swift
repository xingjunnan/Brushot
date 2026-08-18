import AppKit
import AVFoundation
import ImageIO
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
    private var editPlan: RecordingEditPlan
    private let timelineView = RecordingTimelineView()
    private let gifOverviewTimeline = RecordingTimelineView()
    private let gifDetailTimeline = RecordingTimelineView()
    private let gifWidthPopup = NSPopUpButton()
    private let gifFPSPopup = NSPopUpButton()
    private let gifStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var standardEditingControlsView: NSView?
    private var standardActionButtonsView: NSView?
    private var gifSelectionControlsView: NSView?
    private var gifSelectionRange: ClosedRange<TimeInterval>?
    private var isGIFSelectionMode = false
    private var isPreviewingGIFSelection = false
    private var didExpandForGIFSelection = false
    private var frameBeforeGIFSelection: NSRect?
    private var trimDragInitialPlan: RecordingEditPlan?
    private var undoPlans: [RecordingEditPlan] = []
    private var redoPlans: [RecordingEditPlan] = []
    private var isBusy = false
    private let editStatusLabel = NSTextField(labelWithString: "")
    private lazy var gifPreviewButton: NSButton = {
        makeEditButton(L.text("播放选区"), id: "recordingGIFPreviewSelection", action: #selector(previewGIFSelection))
    }()
    private lazy var gifCancelButton: NSButton = {
        makeEditButton(L.text("取消"), id: "recordingGIFCancelSelection", action: #selector(cancelGIFSelection))
    }()
    private lazy var gifExportButton: NSButton = {
        let button = NSButton(title: L.text("导出 GIF"), target: self, action: #selector(exportSelectedGIF))
        button.identifier = NSUserInterfaceItemIdentifier("recordingGIFExportSelection")
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.contentTintColor = .controlAccentColor
        return button
    }()
    private lazy var undoEditButton: NSButton = {
        let button = makeEditButton(L.text("撤销"), id: "recordingEditUndo", action: #selector(undoEdit))
        button.keyEquivalent = "z"
        button.keyEquivalentModifierMask = .command
        button.isEnabled = false
        return button
    }()
    private lazy var redoEditButton: NSButton = {
        let button = makeEditButton(L.text("重做"), id: "recordingEditRedo", action: #selector(redoEdit))
        button.keyEquivalent = "z"
        button.keyEquivalentModifierMask = [.command, .shift]
        button.isEnabled = false
        return button
    }()
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
        self.editPlan = RecordingEditPlan(duration: duration)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: format == .video ? 760 : 560, height: format == .video ? 650 : 420),
            styleMask: format == .video
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.text("录制完成")
        if format == .video {
            window.minSize = CGSize(width: 680, height: 570)
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

    var isPerformingFileOperation: Bool { isBusy }

    func pauseForPendingRecording() {
        player?.pause()
        player?.isMuted = false
        updatePlaybackButton()
    }

    func saveAndCloseForNewRecording(completion: @escaping (Bool) -> Void) {
        if isGIFSelectionMode { cancelGIFSelection() }
        saveRecording(revealInFinder: false, completion: completion)
    }

    func discardAndCloseForNewRecording(completion: @escaping () -> Void) {
        pauseForPendingRecording()
        close()
        completion()
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
        standardActionButtonsView = buttons

        let preview = format == .video ? playerView : imageView
        let stackViews: [NSView]
        if format == .video {
            let editingControls = makeEditingControls()
            let gifControls = makeGIFSelectionControls()
            editingControls.isHidden = false
            gifControls.isHidden = true
            standardEditingControlsView = editingControls
            gifSelectionControlsView = gifControls
            stackViews = [preview, makePlaybackControls(), editingControls, gifControls, metadata, buttons]
        } else {
            stackViews = [preview, metadata, buttons]
        }
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
            if pixelSize.width > 0, pixelSize.height > 0 {
                let aspect = preview.widthAnchor.constraint(
                    equalTo: preview.heightAnchor,
                    multiplier: pixelSize.width / pixelSize.height
                )
                aspect.priority = .defaultHigh
                aspect.isActive = true
            }
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

    private func makeEditingControls() -> NSView {
        timelineView.identifier = NSUserInterfaceItemIdentifier("recordingTimeline")
        timelineView.duration = duration
        timelineView.trimStart = editPlan.trimStart
        timelineView.trimEnd = editPlan.trimEnd
        timelineView.currentTime = 0
        timelineView.onSeek = { [weak self] time in self?.seek(to: time) }
        timelineView.onTrimStarted = { [weak self] in
            guard let self else { return }
            self.trimDragInitialPlan = self.editPlan
        }
        timelineView.onTrimChanged = { [weak self] start, end, changedTime in
            guard let self else { return }
            self.editPlan.setTrimStart(start)
            self.editPlan.setTrimEnd(end)
            self.applyEditPlanToTimeline()
            self.seek(to: changedTime)
        }
        timelineView.onTrimEnded = { [weak self] in
            guard let self, let initial = self.trimDragInitialPlan else { return }
            self.trimDragInitialPlan = nil
            if initial != self.editPlan { self.pushUndoPlan(initial) }
        }
        timelineView.heightAnchor.constraint(equalToConstant: 76).isActive = true
        timelineView.widthAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true

        let frame = makeEditButton(L.text("提取当前帧"), id: "recordingExtractFrame", action: #selector(extractCurrentFrame))
        let gif = makeEditButton(L.text("转为 GIF…"), id: "recordingConvertGIF", action: #selector(convertToGIF))
        let actionRow = NSStackView(views: [
            undoEditButton,
            redoEditButton,
            frame,
            gif
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        editStatusLabel.identifier = NSUserInterfaceItemIdentifier("recordingEditStatus")
        editStatusLabel.textColor = .secondaryLabelColor
        editStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editStatusLabel.alignment = .center
        updateEditStatus()

        let stack = NSStackView(views: [timelineView, actionRow, editStatusLabel])
        stack.identifier = NSUserInterfaceItemIdentifier("recordingEditingControls")
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        actionRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        actionRow.alignment = .centerY
        return stack
    }

    private func makeGIFSelectionControls() -> NSView {
        gifOverviewTimeline.identifier = NSUserInterfaceItemIdentifier("recordingGIFOverviewTimeline")
        gifOverviewTimeline.duration = duration
        gifOverviewTimeline.allowsTrimInteraction = false
        gifOverviewTimeline.showsVisibleRangeLabels = true
        gifOverviewTimeline.onSeek = { [weak self] time in
            self?.moveGIFSelection(to: time)
        }
        gifOverviewTimeline.heightAnchor.constraint(equalToConstant: 64).isActive = true

        gifDetailTimeline.identifier = NSUserInterfaceItemIdentifier("recordingGIFDetailTimeline")
        gifDetailTimeline.duration = duration
        gifDetailTimeline.movesNearestHandleOnTrackClick = true
        gifDetailTimeline.onTrimStarted = { [weak self] in
            self?.stopGIFSelectionPreview()
        }
        gifDetailTimeline.onTrimChanged = { [weak self] start, end, changedTime in
            guard let self else { return }
            self.gifSelectionRange = start...end
            self.syncGIFSelectionTimelines(updateDetailViewport: false)
            self.seek(to: changedTime)
        }
        gifDetailTimeline.onTrimEnded = { [weak self] in
            self?.syncGIFSelectionTimelines(updateDetailViewport: true)
        }
        gifDetailTimeline.heightAnchor.constraint(equalToConstant: 76).isActive = true

        gifWidthPopup.addItems(withTitles: ["480", "720", "1080", "1440"])
        gifWidthPopup.selectItem(withTitle: "720")
        gifWidthPopup.identifier = NSUserInterfaceItemIdentifier("recordingGIFWidth")
        gifWidthPopup.target = self
        gifWidthPopup.action = #selector(gifSettingsChanged)
        gifFPSPopup.addItems(withTitles: RecordingGIFLimits.supportedFrameRates.map { String(format: "%.0f", $0) })
        gifFPSPopup.selectItem(withTitle: "15")
        gifFPSPopup.identifier = NSUserInterfaceItemIdentifier("recordingGIFFPS")
        gifFPSPopup.target = self
        gifFPSPopup.action = #selector(gifSettingsChanged)

        let overviewTitle = NSTextField(labelWithString: L.text("完整视频：点击或拖动以移动 GIF 选区"))
        overviewTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let detailTitle = NSTextField(labelWithString: L.text("精确选段：拖动黄色手柄，画面会同步预览"))
        detailTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        let settings = NSStackView(views: [
            NSTextField(labelWithString: L.text("最大宽度（像素）")),
            gifWidthPopup,
            NSTextField(labelWithString: L.text("帧率（FPS）")),
            gifFPSPopup,
            NSTextField(labelWithString: L.text("GIF 不包含声音"))
        ])
        settings.orientation = .horizontal
        settings.alignment = .centerY
        settings.spacing = 8
        (settings.arrangedSubviews.last as? NSTextField)?.textColor = .secondaryLabelColor

        let actions = NSStackView(views: [gifPreviewButton, gifCancelButton, gifExportButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        gifStatusLabel.identifier = NSUserInterfaceItemIdentifier("recordingGIFSelectionStatus")
        gifStatusLabel.maximumNumberOfLines = 2
        gifStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gifStatusLabel.alignment = .center

        let footer = NSStackView(views: [settings, NSView(), actions])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let callout = makeGIFSelectionCallout()
        let stack = NSStackView(views: [
            callout,
            overviewTitle,
            gifOverviewTimeline,
            detailTitle,
            gifDetailTimeline,
            footer,
            gifStatusLabel
        ])
        stack.identifier = NSUserInterfaceItemIdentifier("recordingGIFSelectionControls")
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 5
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true
        callout.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return stack
    }

    private func makeGIFSelectionCallout() -> NSView {
        let callout = NSView()
        callout.wantsLayer = true
        callout.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        callout.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        callout.layer?.borderWidth = 1
        callout.layer?.cornerRadius = 8
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "film.stack",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: L.text("先在完整视频中定位，再精确调整；GIF 最长 60 秒"))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        callout.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: callout.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: callout.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: callout.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        return callout
    }

    private func makeEditButton(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
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
        loadTimelineThumbnails()
    }

    private func loadTimelineThumbnails() {
        let source = fileURL
        let duration = self.duration
        guard duration > 0 else { return }
        Task { [weak self] in
            let images = await Task.detached(priority: .utility) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 180, height: 90)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
                return (0..<12).compactMap { index -> CGImage? in
                    let seconds = duration * (Double(index) + 0.5) / 12
                    return try? generator.copyCGImage(
                        at: CMTime(seconds: seconds, preferredTimescale: 600),
                        actualTime: nil
                    )
                }
            }.value
            guard let self else { return }
            let thumbnails = images.map { NSImage(cgImage: $0, size: .zero) }
            self.timelineView.thumbnails = thumbnails
            self.gifOverviewTimeline.thumbnails = thumbnails
        }
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
        timelineView.currentTime = current
        gifOverviewTimeline.currentTime = current
        gifDetailTimeline.currentTime = current
        if !isSeeking {
            progressSlider.doubleValue = min(progressSlider.maxValue, current)
        }
        if player?.timeControlStatus == .playing {
            let range = activePlaybackRange
            if current < range.lowerBound - 0.015 {
                seek(to: range.lowerBound)
            } else if current >= range.upperBound - 0.015 {
                player?.pause()
                if isGIFSelectionMode {
                    seek(to: range.lowerBound)
                    player?.isMuted = false
                    isPreviewingGIFSelection = false
                    gifPreviewButton.title = L.text("播放选区")
                } else {
                    seek(to: range.upperBound)
                }
            }
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
            if isGIFSelectionMode {
                player.isMuted = false
                isPreviewingGIFSelection = false
                gifPreviewButton.title = L.text("播放选区")
            }
        } else {
            let range = activePlaybackRange
            var start = currentPlaybackTime
            if start < range.lowerBound || start >= range.upperBound - 0.05 {
                start = range.lowerBound
            }
            if isGIFSelectionMode {
                player.isMuted = true
                isPreviewingGIFSelection = true
                gifPreviewButton.title = L.text("暂停预览")
            }
            seek(to: min(start, range.upperBound))
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
                self.timelineView.currentTime = self.progressSlider.doubleValue
                self.gifOverviewTimeline.currentTime = self.progressSlider.doubleValue
                self.gifDetailTimeline.currentTime = self.progressSlider.doubleValue
                self.updateTimeLabel(current: self.progressSlider.doubleValue)
            }
        }
    }

    @objc private func undoEdit() {
        guard let previous = undoPlans.popLast() else { return }
        redoPlans.append(editPlan)
        editPlan = previous
        applyEditPlanToTimeline()
        updateUndoButtons()
    }

    @objc private func redoEdit() {
        guard let next = redoPlans.popLast() else { return }
        undoPlans.append(editPlan)
        editPlan = next
        applyEditPlanToTimeline()
        updateUndoButtons()
    }

    private func pushUndoPlan(_ plan: RecordingEditPlan) {
        guard plan != editPlan else { return }
        undoPlans.append(plan)
        redoPlans.removeAll()
        updateUndoButtons()
    }

    private func updateUndoButtons() {
        undoEditButton.isEnabled = !undoPlans.isEmpty && !isBusy
        redoEditButton.isEnabled = !redoPlans.isEmpty && !isBusy
    }

    private func applyEditPlanToTimeline() {
        timelineView.trimStart = editPlan.trimStart
        timelineView.trimEnd = editPlan.trimEnd
        updateEditStatus()
    }

    @objc private func extractCurrentFrame() {
        guard !isBusy else { return }
        let time = currentPlaybackTime
        let source = fileURL
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await RecordingExporter.extractFrame(source: source, at: time)
                let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(extension: "png"))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let destinationRef = CGImageDestinationCreateWithURL(
                    destination as CFURL,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else { throw RecordingExportError.exportFailed(L.text("无法创建 PNG 文件。")) }
                CGImageDestinationAddImage(destinationRef, image, nil)
                guard CGImageDestinationFinalize(destinationRef) else {
                    throw RecordingExportError.exportFailed(L.text("无法写入 PNG 文件。"))
                }
                FeedbackSound.playSaveCompleted()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
        }
    }

    @objc private func convertToGIF() {
        guard !isBusy, !isGIFSelectionMode, let window else { return }
        player?.pause()
        let range = RecordingGIFLimits.defaultRange(
            playhead: currentPlaybackTime,
            trimStart: editPlan.trimStart,
            trimEnd: editPlan.trimEnd
        )
        gifSelectionRange = range
        isGIFSelectionMode = true
        isPreviewingGIFSelection = false
        standardEditingControlsView?.isHidden = true
        standardActionButtonsView?.isHidden = true
        gifSelectionControlsView?.isHidden = false
        window.title = L.text("MP4 转 GIF")
        frameBeforeGIFSelection = window.frame
        if let screen = window.screen {
            let desiredHeight = min(window.frame.height + 150, screen.visibleFrame.height - 30)
            if desiredHeight > window.frame.height {
                var expanded = window.frame
                expanded.origin.y = max(screen.visibleFrame.minY, expanded.maxY - desiredHeight)
                expanded.size.height = desiredHeight
                window.setFrame(expanded, display: true, animate: true)
                didExpandForGIFSelection = true
            }
        }
        syncGIFSelectionTimelines(updateDetailViewport: true)
        seek(to: range.lowerBound)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func cancelGIFSelection() {
        guard isGIFSelectionMode else { return }
        player?.pause()
        player?.isMuted = false
        isPreviewingGIFSelection = false
        isGIFSelectionMode = false
        gifSelectionRange = nil
        gifSelectionControlsView?.isHidden = true
        standardEditingControlsView?.isHidden = false
        standardActionButtonsView?.isHidden = false
        window?.title = L.text("录制完成")
        gifPreviewButton.title = L.text("播放选区")
        if didExpandForGIFSelection, let original = frameBeforeGIFSelection {
            window?.setFrame(original, display: true, animate: true)
        }
        didExpandForGIFSelection = false
        frameBeforeGIFSelection = nil
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func previewGIFSelection() {
        guard isGIFSelectionMode, let range = gifSelectionRange, let player else { return }
        if isPreviewingGIFSelection, player.timeControlStatus == .playing {
            player.pause()
            player.isMuted = false
            isPreviewingGIFSelection = false
            gifPreviewButton.title = L.text("播放选区")
            updatePlaybackButton()
            return
        }
        isPreviewingGIFSelection = true
        gifPreviewButton.title = L.text("暂停预览")
        player.isMuted = true
        seek(to: range.lowerBound)
        player.play()
        updatePlaybackButton()
    }

    @objc private func exportSelectedGIF() {
        guard isGIFSelectionMode, let range = gifSelectionRange else { return }
        let options = RecordingGIFOptions(
            startTime: range.lowerBound,
            endTime: range.upperBound,
            maxWidth: Int(gifWidthPopup.titleOfSelectedItem ?? "720") ?? 720,
            framesPerSecond: selectedGIFFPS
        )
        exportGIF(options: options)
    }

    @objc private func gifSettingsChanged() {
        updateGIFSelectionStatus()
    }

    private var selectedGIFFPS: Double {
        Double(gifFPSPopup.titleOfSelectedItem ?? "15") ?? 15
    }

    private var gifSelectableBounds: ClosedRange<TimeInterval> {
        editPlan.trimStart...editPlan.trimEnd
    }

    private func moveGIFSelection(to startTime: TimeInterval) {
        guard let current = gifSelectionRange else { return }
        stopGIFSelectionPreview()
        let bounds = gifSelectableBounds
        let length = min(current.upperBound - current.lowerBound, bounds.upperBound - bounds.lowerBound)
        let start = min(max(bounds.lowerBound, startTime), max(bounds.lowerBound, bounds.upperBound - length))
        gifSelectionRange = start...(start + length)
        syncGIFSelectionTimelines(updateDetailViewport: true)
        seek(to: start)
    }

    private func stopGIFSelectionPreview() {
        player?.pause()
        player?.isMuted = false
        isPreviewingGIFSelection = false
        gifPreviewButton.title = L.text("播放选区")
        updatePlaybackButton()
    }

    private func syncGIFSelectionTimelines(updateDetailViewport: Bool) {
        guard let range = gifSelectionRange else { return }
        gifOverviewTimeline.trimStart = range.lowerBound
        gifOverviewTimeline.trimEnd = range.upperBound
        gifOverviewTimeline.currentTime = currentPlaybackTime
        gifDetailTimeline.trimStart = range.lowerBound
        gifDetailTimeline.trimEnd = range.upperBound
        gifDetailTimeline.currentTime = currentPlaybackTime
        if updateDetailViewport {
            gifDetailTimeline.visibleRange = gifDetailViewport(around: range)
        }
        updateGIFSelectionStatus()
    }

    private func gifDetailViewport(around range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        let bounds = gifSelectableBounds
        let available = max(0, bounds.upperBound - bounds.lowerBound)
        let span = min(RecordingGIFLimits.maximumDuration, available)
        guard span > 0 else { return bounds.lowerBound...bounds.lowerBound }
        let center = (range.lowerBound + range.upperBound) / 2
        let maximumStart = bounds.upperBound - span
        let start = min(max(bounds.lowerBound, center - span / 2), maximumStart)
        return start...(start + span)
    }

    private func updateGIFSelectionStatus() {
        guard let range = gifSelectionRange else { return }
        let selectionDuration = range.upperBound - range.lowerBound
        let maximumFPS = RecordingGIFLimits.maximumFrameRate(for: selectionDuration)
        gifFPSPopup.itemArray.forEach { item in
            item.isEnabled = (Double(item.title) ?? 0) <= maximumFPS
        }
        if selectedGIFFPS > maximumFPS {
            gifFPSPopup.selectItem(withTitle: String(format: "%.0f", maximumFPS))
        }
        let frames = RecordingGIFLimits.estimatedFrameCount(
            duration: selectionDuration,
            framesPerSecond: selectedGIFFPS
        )
        let selection = "\(Self.formatPreciseTime(range.lowerBound))–\(Self.formatPreciseTime(range.upperBound))"
        gifStatusLabel.stringValue = L.format(
            "选区 %@ · %.1f 秒 · 预计 %d 帧 · %.0f FPS",
            selection,
            selectionDuration,
            frames,
            selectedGIFFPS
        )
        gifStatusLabel.textColor = selectionDuration > RecordingGIFLimits.recommendedDuration
            ? .systemOrange
            : .secondaryLabelColor
    }

    private func exportGIF(options: RecordingGIFOptions) {
        let source = fileURL
        let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(extension: "gif"))
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            var exported = false
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await RecordingExporter.exportGIFSegment(source: source, destination: destination, options: options)
                FeedbackSound.playSaveCompleted()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                exported = true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
            if exported { self.cancelGIFSelection() }
        }
    }

    private var activePlaybackRange: ClosedRange<TimeInterval> {
        if isGIFSelectionMode, let gifSelectionRange { return gifSelectionRange }
        return editPlan.trimStart...editPlan.trimEnd
    }

    private var currentPlaybackTime: TimeInterval {
        let current = player.map { CMTimeGetSeconds($0.currentTime()) } ?? progressSlider.doubleValue
        return current.isFinite ? min(duration, max(0, current)) : 0
    }

    private func seek(to seconds: TimeInterval) {
        progressSlider.doubleValue = seconds
        timelineView.currentTime = seconds
        gifOverviewTimeline.currentTime = seconds
        gifDetailTimeline.currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateTimeLabel(current: seconds)
    }

    private func updateEditStatus() {
        let trim = "\(Self.formatTime(editPlan.trimStart))–\(Self.formatTime(editPlan.trimEnd))"
        editStatusLabel.stringValue = L.format(
            "裁剪范围 %@；导出时长 %@",
            trim,
            Self.formatTime(editPlan.outputDuration)
        )
    }

    @objc private func changeVolume() {
        player?.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func playbackDidFinish() {
        player?.pause()
        let destination = isGIFSelectionMode ? activePlaybackRange.lowerBound : activePlaybackRange.upperBound
        player?.isMuted = false
        isPreviewingGIFSelection = false
        gifPreviewButton.title = L.text("播放选区")
        progressSlider.doubleValue = destination
        timelineView.currentTime = destination
        gifOverviewTimeline.currentTime = destination
        gifDetailTimeline.currentTime = destination
        updatePlaybackButton()
    }

    @objc private func saveAction() {
        saveRecording(revealInFinder: true, completion: nil)
    }

    private func saveRecording(revealInFinder: Bool, completion: ((Bool) -> Void)?) {
        guard !isBusy else {
            completion?(false)
            return
        }
        let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(format: format))
        if format == .video, editPlan.hasEdits {
            exportEditedVideo(
                to: destination,
                forCopy: false,
                revealInFinder: revealInFinder,
                completion: completion
            )
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: fileURL, to: destination)
            ownsFile = false
            FeedbackSound.playSaveCompleted()
            if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            close()
            completion?(true)
        } catch {
            showError(error.localizedDescription)
            completion?(false)
        }
    }

    @objc private func copyAction() {
        guard !isBusy else { return }
        if format == .video, editPlan.hasEdits {
            let directory = Self.clipboardDirectory
            let cached = directory.appendingPathComponent(Self.outputFileName(format: .video))
            exportEditedVideo(
                to: cached,
                forCopy: true,
                revealInFinder: false,
                completion: nil
            )
            return
        }
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

    private func exportEditedVideo(
        to destination: URL,
        forCopy: Bool,
        revealInFinder: Bool,
        completion: ((Bool) -> Void)?
    ) {
        let source = fileURL
        let plan = editPlan
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await RecordingExporter.exportEditedMP4(source: source, destination: destination, plan: plan)
                if forCopy {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects([destination as NSURL]) else {
                        try? FileManager.default.removeItem(at: destination)
                        throw RecordingExportError.exportFailed(L.text("无法写入剪贴板。"))
                    }
                    FeedbackSound.playCopyCompleted()
                    self.setBusy(false)
                    completion?(true)
                } else {
                    self.ownsFile = false
                    try? FileManager.default.removeItem(at: source)
                    FeedbackSound.playSaveCompleted()
                    if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    self.close()
                    completion?(true)
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.setBusy(false)
                self.showError(error.localizedDescription)
                completion?(false)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        player?.pause()
        timelineView.isInteractionEnabled = !busy
        gifOverviewTimeline.isInteractionEnabled = !busy
        gifDetailTimeline.isInteractionEnabled = !busy
        window?.title = if busy {
            L.text("正在导出…")
        } else if isGIFSelectionMode {
            L.text("MP4 转 GIF")
        } else {
            L.text("录制完成")
        }
        if let content = window?.contentView {
            setControlsEnabled(!busy, in: content)
        }
        updateUndoButtons()
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        if let control = view as? NSControl { control.isEnabled = enabled }
        view.subviews.forEach { setControlsEnabled(enabled, in: $0) }
    }

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
        RecordingRecoveryStore.migrateLegacyTemporaryFiles()
        _ = RecordingRecoveryStore.recoverableFiles()
    }

    private static func outputFileName(format: RecordingFormat) -> String {
        outputFileName(extension: format.fileExtension)
    }

    private static func outputFileName(extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Brushot-\(formatter.string(from: Date())).\(pathExtension)"
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let rounded = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", rounded / 60, rounded % 60)
    }

    private static func formatPreciseTime(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
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
