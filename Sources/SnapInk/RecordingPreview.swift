import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class RecordingExportProgressWindowController: NSWindowController {
    private let label = NSTextField(labelWithString: "正在准备录制文件…")
    private let indicator = NSProgressIndicator()

    init(format: RecordingFormat) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "正在生成\(format.displayName)"
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
        case .preparing: "正在准备…"
        case .encoding: "正在编码…"
        case .finalizing: "正在完成…"
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
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "录制完成"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent(duration: duration, pixelSize: pixelSize)
        loadThumbnail()
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
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true

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

        let discard = NSButton(title: "丢弃", target: self, action: #selector(discardAction))
        discard.identifier = NSUserInterfaceItemIdentifier("discardRecordingAction")
        let copy = NSButton(title: "复制", target: self, action: #selector(copyAction))
        copy.identifier = NSUserInterfaceItemIdentifier("copyRecordingAction")
        let save = NSButton(title: "保存", target: self, action: #selector(saveAction))
        save.identifier = NSUserInterfaceItemIdentifier("saveRecordingAction")
        save.keyEquivalent = "\r"
        save.contentTintColor = .controlAccentColor
        let buttons = NSStackView(views: [discard, copy, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [imageView, metadata, buttons])
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
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 310),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private func loadThumbnail() {
        if format == .gif {
            imageView.image = NSImage(contentsOf: fileURL)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1000, height: 620)
            if let image = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                self.imageView.image = NSImage(
                    cgImage: image,
                    size: CGSize(width: image.width, height: image.height)
                )
            }
        }
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
                    throw RecordingExportError.exportFailed("无法写入剪贴板。")
                }
            } else {
                let directory = Self.clipboardDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let cached = directory.appendingPathComponent(Self.outputFileName(format: .video))
                try FileManager.default.copyItem(at: fileURL, to: cached)
                guard pasteboard.writeObjects([cached as NSURL]) else {
                    try? FileManager.default.removeItem(at: cached)
                    throw RecordingExportError.exportFailed("无法写入剪贴板。")
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
        if ownsFile { try? FileManager.default.removeItem(at: fileURL) }
        onClose()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "录制文件操作失败"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }

    private static var clipboardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapInk", isDirectory: true)
            .appendingPathComponent("RecordingClipboard", isDirectory: true)
    }

    private static func cleanupAbandonedTemporaryFiles() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where
            file.lastPathComponent.hasPrefix("SnapInk-Recording-")
                || file.lastPathComponent.hasPrefix("SnapInk-Export-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func outputFileName(format: RecordingFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "SnapInk-\(formatter.string(from: Date())).\(format.fileExtension)"
    }
}
