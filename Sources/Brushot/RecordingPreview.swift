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
    private var pendingDeleteSelection: ClosedRange<TimeInterval>?
    private var selectedDeletedRangeIndex: Int?
    private var trimDragInitialPlan: RecordingEditPlan?
    private var undoPlans: [RecordingEditPlan] = []
    private var redoPlans: [RecordingEditPlan] = []
    private var previewSelectionEnd: TimeInterval?
    private var isBusy = false
    private let editStatusLabel = NSTextField(labelWithString: "")
    private lazy var deleteRangeButton: NSButton = {
        makeEditButton(L.text("删除片段"), id: "recordingDeleteRange", action: #selector(beginDeleteRange))
    }()
    private lazy var confirmDeleteButton: NSButton = {
        let button = makeEditButton(L.text("确认删除"), id: "recordingDeleteConfirm", action: #selector(confirmDeleteRange))
        button.contentTintColor = .systemRed
        button.isHidden = true
        return button
    }()
    private lazy var previewDeleteButton: NSButton = {
        let button = makeEditButton(L.text("预览选区"), id: "recordingDeletePreview", action: #selector(previewDeleteRange))
        button.isHidden = true
        return button
    }()
    private lazy var cancelDeleteButton: NSButton = {
        let button = makeEditButton(L.text("取消选择"), id: "recordingDeleteCancel", action: #selector(cancelDeleteRange))
        button.isHidden = true
        return button
    }()
    private lazy var restoreDeleteButton: NSButton = {
        let button = makeEditButton(L.text("恢复此片段"), id: "recordingDeleteRestore", action: #selector(restoreDeletedRange))
        button.isHidden = true
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
            ? [preview, makePlaybackControls(), makeEditingControls(), metadata, buttons]
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
        timelineView.deletedRanges = editPlan.deletedRanges
        timelineView.onSeek = { [weak self] time in self?.seek(to: time) }
        timelineView.onTrimStarted = { [weak self] in
            guard let self else { return }
            self.trimDragInitialPlan = self.editPlan
            self.cancelDeleteRange()
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
        timelineView.onSelectionChanged = { [weak self] range in
            self?.pendingDeleteSelection = range
            self?.updateDeleteSelectionControls()
        }
        timelineView.onDeletedRangeSelected = { [weak self] index in
            guard let self else { return }
            self.cancelDeleteRange()
            self.selectedDeletedRangeIndex = index
            self.restoreDeleteButton.isHidden = false
            self.updateEditStatus()
        }
        timelineView.heightAnchor.constraint(equalToConstant: 76).isActive = true
        timelineView.widthAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true

        let frame = makeEditButton(L.text("提取当前帧"), id: "recordingExtractFrame", action: #selector(extractCurrentFrame))
        let gif = makeEditButton(L.text("转为 GIF…"), id: "recordingConvertGIF", action: #selector(convertToGIF))
        let actionRow = NSStackView(views: [
            undoEditButton,
            redoEditButton,
            deleteRangeButton,
            confirmDeleteButton,
            previewDeleteButton,
            cancelDeleteButton,
            restoreDeleteButton,
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
            self.timelineView.thumbnails = images.map { NSImage(cgImage: $0, size: .zero) }
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
        if !isSeeking {
            progressSlider.doubleValue = min(progressSlider.maxValue, current)
        }
        if let previewSelectionEnd, current >= previewSelectionEnd - 0.015 {
            player?.pause()
            self.previewSelectionEnd = nil
            seek(to: previewSelectionEnd)
        } else if player?.timeControlStatus == .playing {
            if current < editPlan.trimStart - 0.015 {
                seek(to: editPlan.trimStart)
            } else if current >= editPlan.trimEnd - 0.015 {
                player?.pause()
                seek(to: editPlan.trimEnd)
            } else if let deleted = editPlan.deletedRanges.first(where: {
                current >= $0.lowerBound - 0.015 && current < $0.upperBound - 0.015
            }) {
                seek(to: min(editPlan.trimEnd, deleted.upperBound))
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
        } else {
            var start = currentPlaybackTime
            if start < editPlan.trimStart || start >= editPlan.trimEnd - 0.05 {
                start = editPlan.trimStart
            }
            if let deleted = editPlan.deletedRanges.first(where: { $0.contains(start) }) {
                start = deleted.upperBound
            }
            seek(to: min(start, editPlan.trimEnd))
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
                self.updateTimeLabel(current: self.progressSlider.doubleValue)
            }
        }
    }

    @objc private func beginDeleteRange() {
        guard !isBusy else { return }
        selectedDeletedRangeIndex = nil
        restoreDeleteButton.isHidden = true
        pendingDeleteSelection = nil
        timelineView.clearPendingSelection()
        timelineView.isRangeSelectionEnabled = true
        deleteRangeButton.isHidden = true
        cancelDeleteButton.isHidden = false
        confirmDeleteButton.isHidden = true
        previewDeleteButton.isHidden = true
        updateEditStatus()
    }

    @objc private func confirmDeleteRange() {
        guard let range = pendingDeleteSelection, range.upperBound - range.lowerBound >= 0.05 else { return }
        let initial = editPlan
        editPlan.addDeletedRange(from: range.lowerBound, to: range.upperBound)
        pushUndoPlan(initial)
        cancelDeleteRange()
        applyEditPlanToTimeline()
        seek(to: min(editPlan.trimEnd, range.lowerBound))
    }

    @objc private func previewDeleteRange() {
        guard let range = pendingDeleteSelection, range.upperBound - range.lowerBound >= 0.05 else { return }
        previewSelectionEnd = range.upperBound
        seek(to: range.lowerBound)
        player?.play()
        updatePlaybackButton()
    }

    @objc private func cancelDeleteRange() {
        previewSelectionEnd = nil
        pendingDeleteSelection = nil
        selectedDeletedRangeIndex = nil
        timelineView.isRangeSelectionEnabled = false
        timelineView.clearPendingSelection()
        deleteRangeButton.isHidden = false
        confirmDeleteButton.isHidden = true
        previewDeleteButton.isHidden = true
        cancelDeleteButton.isHidden = true
        restoreDeleteButton.isHidden = true
        updateEditStatus()
    }

    @objc private func restoreDeletedRange() {
        guard let index = selectedDeletedRangeIndex, editPlan.deletedRanges.indices.contains(index) else { return }
        let initial = editPlan
        editPlan.deletedRanges.remove(at: index)
        editPlan.normalize()
        selectedDeletedRangeIndex = nil
        restoreDeleteButton.isHidden = true
        pushUndoPlan(initial)
        applyEditPlanToTimeline()
    }

    @objc private func undoEdit() {
        guard let previous = undoPlans.popLast() else { return }
        redoPlans.append(editPlan)
        editPlan = previous
        cancelDeleteRange()
        applyEditPlanToTimeline()
        updateUndoButtons()
    }

    @objc private func redoEdit() {
        guard let next = redoPlans.popLast() else { return }
        undoPlans.append(editPlan)
        editPlan = next
        cancelDeleteRange()
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

    private func updateDeleteSelectionControls() {
        let hasSelection = pendingDeleteSelection.map { $0.upperBound - $0.lowerBound >= 0.05 } ?? false
        confirmDeleteButton.isHidden = !hasSelection
        previewDeleteButton.isHidden = !hasSelection
        cancelDeleteButton.isHidden = !timelineView.isRangeSelectionEnabled
        updateEditStatus()
    }

    private func applyEditPlanToTimeline() {
        timelineView.trimStart = editPlan.trimStart
        timelineView.trimEnd = editPlan.trimEnd
        timelineView.deletedRanges = editPlan.deletedRanges
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
        guard !isBusy, let window else { return }
        let startField = NSTextField(string: String(format: "%.2f", editPlan.trimStart))
        let endField = NSTextField(string: String(format: "%.2f", editPlan.trimEnd))
        let widthPopup = NSPopUpButton()
        widthPopup.addItems(withTitles: ["480", "720", "1080", "1440"])
        widthPopup.selectItem(withTitle: "720")
        let fpsPopup = NSPopUpButton()
        fpsPopup.addItems(withTitles: ["8", "10", "15", "20", "30"])
        fpsPopup.selectItem(withTitle: "15")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L.text("开始时间（秒）")), startField],
            [NSTextField(labelWithString: L.text("结束时间（秒）")), endField],
            [NSTextField(labelWithString: L.text("最大宽度（像素）")), widthPopup],
            [NSTextField(labelWithString: L.text("帧率（FPS）")), fpsPopup]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.frame.size = CGSize(width: 300, height: 120)
        let alert = NSAlert()
        alert.messageText = L.text("MP4 转 GIF")
        alert.informativeText = L.text("选择要导出的片段、尺寸和帧率。GIF 最多 600 帧。")
        alert.accessoryView = grid
        alert.addButton(withTitle: L.text("导出 GIF"))
        alert.addButton(withTitle: L.text("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let start = startField.doubleValue
            let end = endField.doubleValue
            guard start >= 0, end > start, end <= self.duration + 0.01 else {
                self.showError(L.text("GIF 时间范围无效。"))
                return
            }
            let options = RecordingGIFOptions(
                startTime: start,
                endTime: end,
                maxWidth: Int(widthPopup.titleOfSelectedItem ?? "720") ?? 720,
                framesPerSecond: Double(fpsPopup.titleOfSelectedItem ?? "15") ?? 15
            )
            self.exportGIF(options: options)
        }
    }

    private func exportGIF(options: RecordingGIFOptions) {
        let source = fileURL
        let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(extension: "gif"))
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await RecordingExporter.exportGIFSegment(source: source, destination: destination, options: options)
                FeedbackSound.playSaveCompleted()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
        }
    }

    private var currentPlaybackTime: TimeInterval {
        let current = player.map { CMTimeGetSeconds($0.currentTime()) } ?? progressSlider.doubleValue
        return current.isFinite ? min(duration, max(0, current)) : 0
    }

    private func seek(to seconds: TimeInterval) {
        progressSlider.doubleValue = seconds
        timelineView.currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateTimeLabel(current: seconds)
    }

    private func updateEditStatus() {
        let trim = "\(Self.formatTime(editPlan.trimStart))–\(Self.formatTime(editPlan.trimEnd))"
        if timelineView.isRangeSelectionEnabled {
            if let range = pendingDeleteSelection, range.upperBound - range.lowerBound >= 0.05 {
                editStatusLabel.stringValue = L.format(
                    "将删除 %@–%@（%@）",
                    Self.formatTime(range.lowerBound),
                    Self.formatTime(range.upperBound),
                    Self.formatTime(range.upperBound - range.lowerBound)
                )
            } else {
                editStatusLabel.stringValue = L.text("在时间线上拖动，选择要删除的内容")
            }
        } else if let index = selectedDeletedRangeIndex, editPlan.deletedRanges.indices.contains(index) {
            let range = editPlan.deletedRanges[index]
            editStatusLabel.stringValue = L.format(
                "已选择删除片段 %@–%@，可恢复此片段",
                Self.formatTime(range.lowerBound),
                Self.formatTime(range.upperBound)
            )
        } else {
            editStatusLabel.stringValue = L.format(
                "选中 %@；已删除 %d 段；导出时长 %@",
                trim,
                editPlan.deletedRanges.count,
                Self.formatTime(editPlan.outputDuration)
            )
        }
    }

    @objc private func changeVolume() {
        player?.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func playbackDidFinish() {
        player?.pause()
        progressSlider.doubleValue = editPlan.trimEnd
        timelineView.currentTime = editPlan.trimEnd
        updatePlaybackButton()
    }

    @objc private func saveAction() {
        guard !isBusy else { return }
        let destination = AppPreferences.saveLocation.appendingPathComponent(Self.outputFileName(format: format))
        if format == .video, editPlan.hasEdits {
            exportEditedVideo(to: destination, forCopy: false)
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
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            close()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func copyAction() {
        guard !isBusy else { return }
        if format == .video, editPlan.hasEdits {
            let directory = Self.clipboardDirectory
            let cached = directory.appendingPathComponent(Self.outputFileName(format: .video))
            exportEditedVideo(to: cached, forCopy: true)
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

    private func exportEditedVideo(to destination: URL, forCopy: Bool) {
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
                } else {
                    self.ownsFile = false
                    try? FileManager.default.removeItem(at: source)
                    FeedbackSound.playSaveCompleted()
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    self.close()
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.setBusy(false)
                self.showError(error.localizedDescription)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        player?.pause()
        timelineView.isInteractionEnabled = !busy
        window?.title = busy ? L.text("正在导出…") : L.text("录制完成")
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
