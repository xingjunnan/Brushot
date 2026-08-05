import AppKit
import Foundation

private final class GIFOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Red recording border, drawn one point outside the capture area so it never
/// becomes part of the recorded pixels.
private final class GIFBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}

/// Owns the GIF recording phase after the capture rectangle has been chosen.
/// A red border marks the region while a small HUD panel shows elapsed time /
/// frame count and offers Finish and Cancel. Recording runs until the user
/// finishes, cancels, or the max duration is reached; on finish the buffered
/// frames are encoded to a GIF via `GIFEncoder`.
@MainActor
final class GIFSessionController: NSObject {
    private let selectionRect: CGRect
    private let capturer: ScreenRegionCapturer
    private let recorder = GIFRecorder()
    private let fps: Double
    private let maxDuration: TimeInterval
    private let maxWidth: Int
    private let onFinish: (Data) -> Void
    private let onCancel: () -> Void
    private let onError: (Error) -> Void

    private let borderWindow: NSWindow
    private let controlWindow: GIFOverlayPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private var startedAt = Date()
    private var timer: Timer?
    private var isFinished = false
    private var isEncoding = false

    nonisolated static let borderExpansion: CGFloat = 3

    init(
        selectionRect: CGRect,
        capturer: ScreenRegionCapturer,
        fps: Double = 15,
        maxDuration: TimeInterval = 30,
        maxWidth: Int = 720,
        onFinish: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.selectionRect = selectionRect
        self.capturer = capturer
        self.fps = fps
        self.maxDuration = maxDuration
        self.maxWidth = maxWidth
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onError = onError

        let borderFrame = selectionRect.insetBy(dx: -Self.borderExpansion, dy: -Self.borderExpansion)
        borderWindow = NSWindow(
            contentRect: borderFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        borderWindow.contentView = GIFBorderView(frame: CGRect(origin: .zero, size: borderFrame.size))
        borderWindow.backgroundColor = .clear
        borderWindow.isOpaque = false
        borderWindow.hasShadow = false
        borderWindow.ignoresMouseEvents = true
        borderWindow.level = .screenSaver
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderWindow.isReleasedWhenClosed = false

        controlWindow = GIFOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureControlPanel()
    }

    func start() {
        guard !isFinished else { return }
        positionControlPanel()
        borderWindow.orderFrontRegardless()
        controlWindow.orderFrontRegardless()
        startedAt = Date()
        updateStatus(frameCount: 0, elapsed: 0)

        Task { [weak self] in
            guard let self else { return }
            // Rebuild the filter now that SnapInk's border/control windows
            // are on screen, so they are excluded from every recorded frame.
            await self.capturer.prepareForOverlayExclusion()
            do {
                try self.recorder.start(
                    capturer: self.capturer,
                    fps: self.fps,
                    maxWidth: self.maxWidth,
                    onFrame: { [weak self] count in
                        self?.updateStatus(frameCount: count)
                    },
                    onError: { [weak self] error in
                        self?.handleRecorderError(error)
                    }
                )
            } catch {
                self.cleanup()
                self.onError(error)
                return
            }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    // MARK: - Actions

    @objc private func finishAction() {
        finish()
    }

    @objc private func cancelAction() {
        cancel()
    }

    func finish() {
        guard !isFinished, !isEncoding else { return }
        isEncoding = true
        finishButton.isEnabled = false
        cancelButton.isEnabled = false
        timer?.invalidate()
        timer = nil

        let fps = self.fps
        let maxWidth = self.maxWidth
        Task { [weak self] in
            guard let self else { return }
            let frames = await self.recorder.stop()
            do {
                let data = try GIFEncoder.encode(
                    frames: frames,
                    options: GIFEncodingOptions(fps: fps, maxWidth: maxWidth, loopCount: 0)
                )
                self.cleanup()
                self.onFinish(data)
            } catch {
                self.cleanup()
                self.onError(error)
            }
        }
    }

    func cancel() {
        guard !isFinished, !isEncoding else { return }
        isFinished = true
        timer?.invalidate()
        timer = nil
        Task { [weak self] in
            _ = await self?.recorder.stop()
        }
        cleanup()
        onCancel()
    }

    // MARK: - Private

    private func tick() {
        guard !isFinished, !isEncoding else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        updateStatus(frameCount: recorder.frameCount, elapsed: elapsed)
        if elapsed >= maxDuration {
            finish()
        }
    }

    private func updateStatus(frameCount: Int, elapsed: TimeInterval? = nil) {
        let e = elapsed ?? Date().timeIntervalSince(startedAt)
        let total = Int(max(0, e))
        statusLabel.stringValue = String(format: "%02d:%02d · %d 帧", total / 60, total % 60, frameCount)
    }

    private func handleRecorderError(_ error: Error) {
        guard !isFinished else { return }
        timer?.invalidate()
        timer = nil
        cleanup()
        onError(error)
    }

    private func cleanup() {
        isFinished = true
        timer?.invalidate()
        timer = nil
        borderWindow.orderOut(nil)
        controlWindow.orderOut(nil)
        borderWindow.close()
        controlWindow.close()
    }

    private func configureControlPanel() {
        controlWindow.isOpaque = false
        controlWindow.backgroundColor = .clear
        controlWindow.hasShadow = true
        controlWindow.hidesOnDeactivate = false
        controlWindow.isReleasedWhenClosed = false
        controlWindow.level = .screenSaver
        controlWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: controlWindow.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        controlWindow.contentView = background

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Red recording dot next to the timer.
        let dot = NSView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        let dotContainer = NSView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dotContainer.addSubview(dot)
        dotContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: dotContainer.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: dotContainer.centerYAnchor)
        ])

        finishButton.target = self
        finishButton.action = #selector(finishAction)
        finishButton.keyEquivalent = "\r"
        finishButton.bezelColor = NSColor.systemRed
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [dotContainer, statusLabel, cancelButton, finishButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }

    private func positionControlPanel() {
        let size = controlWindow.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect
        let gap: CGFloat = 8
        var origin = CGPoint(
            x: min(selectionRect.maxX - size.width, visible.maxX - size.width - 8),
            y: selectionRect.minY - size.height - gap
        )
        if origin.y < visible.minY {
            origin.y = min(selectionRect.maxY + gap, visible.maxY - size.height)
        }
        if origin.x < visible.minX {
            origin.x = visible.minX
        }
        controlWindow.setFrameOrigin(origin)
    }
}
