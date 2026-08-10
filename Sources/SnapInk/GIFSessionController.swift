import AppKit
import Foundation

private final class GIFOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Transparent panel that sits on top of the recording area and captures
/// annotation drawings.  When `ignoresMouseEvents == true` (no tool active)
/// mouse events pass straight through to the app being recorded.
private final class GIFAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum GIFAnnotationShape {
    case pen(points: [CGPoint])
    case rectangle(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
}

@MainActor
private final class GIFAnnotationView: NSView {
    enum Tool { case none, pen, rectangle, arrow }

    private var shapes: [GIFAnnotationShape] = []
    private var currentTool: Tool = .none
    private var drawingShape: GIFAnnotationShape?
    private var drawStartPoint: CGPoint?

    private let annotationColor = NSColor.systemRed
    private let lineWidth: CGFloat = 3

    func setTool(_ tool: Tool) {
        if let shape = drawingShape { shapes.append(shape) }
        drawingShape = nil
        drawStartPoint = nil
        currentTool = tool
        window?.ignoresMouseEvents = (tool == .none)
        needsDisplay = true
    }

    func undoLast() {
        guard !shapes.isEmpty else { return }
        shapes.removeLast()
        needsDisplay = true
    }

    func clearAll() {
        shapes.removeAll()
        drawingShape = nil
        drawStartPoint = nil
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let all = drawingShape.map { shapes + [$0] } ?? shapes
        for shape in all {
            switch shape {
            case .pen(let pts):
                guard pts.count >= 2 else { continue }
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.line(to: p) }
                annotationColor.setStroke()
                path.stroke()
            case .rectangle(let rect):
                let path = NSBezierPath(rect: rect)
                path.lineWidth = lineWidth
                annotationColor.setStroke()
                path.stroke()
            case .arrow(let s, let e):
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.move(to: s)
                path.line(to: e)
                annotationColor.setStroke()
                path.stroke()
                let angle = atan2(e.y - s.y, e.x - s.x)
                let hl: CGFloat = 14
                let p1 = CGPoint(x: e.x - hl * cos(angle - 0.4), y: e.y - hl * sin(angle - 0.4))
                let p2 = CGPoint(x: e.x - hl * cos(angle + 0.4), y: e.y - hl * sin(angle + 0.4))
                let head = NSBezierPath()
                head.lineWidth = lineWidth
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.move(to: p1)
                head.line(to: e)
                head.line(to: p2)
                annotationColor.setStroke()
                head.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard currentTool != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        drawStartPoint = p
        if currentTool == .pen { drawingShape = .pen(points: [p]) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = drawStartPoint, currentTool != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch currentTool {
        case .pen:
            if case .pen(var pts) = drawingShape {
                pts.append(p)
                drawingShape = .pen(points: pts)
            }
        case .rectangle:
            drawingShape = .rectangle(CGRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width: abs(p.x - start.x), height: abs(p.y - start.y)
            ))
        case .arrow:
            drawingShape = .arrow(start: start, end: p)
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let shape = drawingShape {
            let valid: Bool
            switch shape {
            case .pen(let pts): valid = pts.count >= 2
            case .rectangle(let r): valid = r.width >= 2 && r.height >= 2
            case .arrow(let s, let e): valid = sqrt(pow(e.x - s.x, 2) + pow(e.y - s.y, 2)) >= 2
            }
            if valid { shapes.append(shape) }
        }
        drawingShape = nil
        drawStartPoint = nil
        needsDisplay = true
    }
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

/// Owns the video/GIF recording phase after the capture rectangle has been
/// chosen. Both formats share the same streaming recorder and live annotation
/// overlay; format-specific export happens after the recording stops.
@MainActor
final class RecordingSessionController: NSObject {
    private let selectionRect: CGRect
    private let capturer: ScreenRegionCapturer
    private let engine = RecordingEngine()
    private let configuration: RecordingConfiguration
    private let onFinish: (RecordingResult) -> Void
    private let onCancel: () -> Void
    private let onError: (Error) -> Void

    private let borderWindow: NSWindow
    private let controlWindow: GIFOverlayPanel
    private let annotationWindow: GIFAnnotationPanel
    private let annotationView: GIFAnnotationView
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let finishButton = NSButton(title: "停止", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var selectToolButton: NSButton!
    private var penToolButton: NSButton!
    private var rectToolButton: NSButton!
    private var arrowToolButton: NSButton!

    private var timer: Timer?
    private var isFinished = false
    private var lastDiskCheckAt = Date.distantPast

    nonisolated static let borderExpansion: CGFloat = 3

    init(
        selectionRect: CGRect,
        capturer: ScreenRegionCapturer,
        configuration: RecordingConfiguration,
        onFinish: @escaping (RecordingResult) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.selectionRect = selectionRect
        self.capturer = capturer
        self.configuration = configuration
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
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        annotationView = GIFAnnotationView(frame: CGRect(origin: .zero, size: selectionRect.size))
        annotationWindow = GIFAnnotationPanel(
            contentRect: selectionRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        annotationWindow.isOpaque = false
        annotationWindow.backgroundColor = .clear
        annotationWindow.hasShadow = false
        annotationWindow.hidesOnDeactivate = false
        annotationWindow.isReleasedWhenClosed = false
        annotationWindow.level = .screenSaver
        annotationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        annotationWindow.ignoresMouseEvents = true
        annotationWindow.contentView = annotationView

        super.init()
        engine.onUnexpectedStop = { [weak self] error in
            guard let self, !self.isFinished else { return }
            self.cleanup()
            self.onError(error)
        }
        configureControlPanel()
    }

    func start() {
        guard !isFinished else { return }
        positionControlPanel()
        annotationWindow.orderFrontRegardless()
        borderWindow.orderFrontRegardless()
        controlWindow.orderFrontRegardless()
        capturer.exceptedWindowIDs.insert(CGWindowID(annotationWindow.windowNumber))
        updateStatus(elapsed: 0)

        Task { [weak self] in
            guard let self else { return }
            // Rebuild the filter now that SnapInk's border/control windows
            // are on screen, so they are excluded from every recorded frame.
            await self.capturer.prepareForOverlayExclusion()
            do {
                try await self.engine.start(
                    capturer: self.capturer,
                    configuration: self.configuration
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

    @objc private func pauseAction() {
        if engine.state == .recording {
            engine.pause()
            pauseButton.title = "继续"
            updateStatus(elapsed: engine.elapsedTime)
        } else if engine.state == .paused {
            engine.resume()
            pauseButton.title = "暂停"
        }
    }

    @objc private func cancelAction() {
        cancel()
    }

    func finish() {
        guard !isFinished,
              engine.state == .recording || engine.state == .paused else { return }
        finishButton.isEnabled = false
        pauseButton.isEnabled = false
        cancelButton.isEnabled = false
        timer?.invalidate()
        timer = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.stop()
                self.cleanup()
                self.onFinish(result)
            } catch {
                self.cleanup()
                self.onError(error)
            }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        timer?.invalidate()
        timer = nil
        Task { [weak self] in
            guard let self else { return }
            await self.engine.cancel()
            self.cleanup()
            self.onCancel()
        }
    }

    // MARK: - Private

    private func tick() {
        guard !isFinished else { return }
        let elapsed = engine.elapsedTime
        updateStatus(elapsed: elapsed)
        if elapsed >= RecordingLimits.maximumDuration(for: configuration.format) {
            finish()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastDiskCheckAt) >= 5 {
            lastDiskCheckAt = now
            if !RecordingDiskSpace.hasEnoughSpace() {
                statusLabel.stringValue = "磁盘空间不足，正在安全停止…"
                finish()
            }
        }
    }

    private func updateStatus(elapsed: TimeInterval) {
        let e = elapsed
        let paused = engine.state == .paused ? " · 已暂停" : ""
        let microphone = configuration.capturesMicrophone ? " · 麦克风" : ""
        var timeText = Self.clockText(e)
        if let remaining = RecordingLimits.remainingTime(for: configuration.format, elapsed: e) {
            timeText += " · 剩余 \(Self.clockText(remaining))"
        }
        statusLabel.stringValue = "\(configuration.format.displayName)\(microphone) · \(timeText)\(paused)"
    }

    private static func clockText(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded(.down)))
        if total >= 3_600 {
            return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func cleanup() {
        isFinished = true
        timer?.invalidate()
        timer = nil
        annotationWindow.orderOut(nil)
        borderWindow.orderOut(nil)
        controlWindow.orderOut(nil)
        annotationWindow.close()
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
        pauseButton.target = self
        pauseButton.action = #selector(pauseAction)
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"

        // Annotation tool buttons
        selectToolButton = makeToolButton(symbol: "cursorarrow", action: #selector(selectToolAction), tooltip: "选择", toggle: true)
        penToolButton = makeToolButton(symbol: "scribble", action: #selector(penToolAction), tooltip: "画笔", toggle: true)
        rectToolButton = makeToolButton(symbol: "rectangle", action: #selector(rectToolAction), tooltip: "矩形", toggle: true)
        arrowToolButton = makeToolButton(symbol: "arrow.up.right", action: #selector(arrowToolAction), tooltip: "箭头", toggle: true)
        let undoButton = makeToolButton(symbol: "arrow.uturn.backward", action: #selector(undoAnnotationAction), tooltip: "撤销标注", toggle: false)
        let clearButton = makeToolButton(symbol: "xmark.circle", action: #selector(clearAnnotationAction), tooltip: "清除标注", toggle: false)
        selectToolButton.state = .on

        let stack = NSStackView(views: [
            selectToolButton, penToolButton, rectToolButton, arrowToolButton,
            makeSeparator(),
            undoButton, clearButton,
            makeSeparator(),
            dotContainer, statusLabel, pauseButton, cancelButton, finishButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
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

    // MARK: - Annotation actions

    @objc private func selectToolAction() {
        annotationView.setTool(.none)
        updateToolButtonStates(active: nil)
    }

    @objc private func penToolAction(_ sender: NSButton) {
        if sender.state == .on {
            annotationView.setTool(.pen)
            updateToolButtonStates(active: .pen)
        } else {
            annotationView.setTool(.none)
            updateToolButtonStates(active: nil)
        }
    }

    @objc private func rectToolAction(_ sender: NSButton) {
        if sender.state == .on {
            annotationView.setTool(.rectangle)
            updateToolButtonStates(active: .rectangle)
        } else {
            annotationView.setTool(.none)
            updateToolButtonStates(active: nil)
        }
    }

    @objc private func arrowToolAction(_ sender: NSButton) {
        if sender.state == .on {
            annotationView.setTool(.arrow)
            updateToolButtonStates(active: .arrow)
        } else {
            annotationView.setTool(.none)
            updateToolButtonStates(active: nil)
        }
    }

    @objc private func undoAnnotationAction() {
        annotationView.undoLast()
    }

    @objc private func clearAnnotationAction() {
        annotationView.clearAll()
    }

    private func updateToolButtonStates(active: GIFAnnotationView.Tool?) {
        selectToolButton.state = active == nil ? .on : .off
        penToolButton.state = active == .pen ? .on : .off
        rectToolButton.state = active == .rectangle ? .on : .off
        arrowToolButton.state = active == .arrow ? .on : .off
    }

    private func makeToolButton(symbol: String, action: Selector, tooltip: String, toggle: Bool) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.setButtonType(toggle ? .toggle : .momentaryChange)
        button.target = self
        button.action = action
        button.state = .off
        button.toolTip = tooltip
        return button
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 1),
            sep.heightAnchor.constraint(equalToConstant: 20)
        ])
        return sep
    }
}

@MainActor
final class RecordingStartBar: NSVisualEffectView {
    var onStart: ((RecordingFormat, Bool, Bool, String?) -> Void)?
    var onCancel: (() -> Void)?
    private let audioCheckbox = NSButton(
        checkboxWithTitle: "系统音频（仅视频）",
        target: nil,
        action: nil
    )
    private let microphoneCheckbox = NSButton(
        checkboxWithTitle: "麦克风（仅视频）",
        target: nil,
        action: nil
    )
    private let microphonePopup = NSPopUpButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "选择输出格式")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        audioCheckbox.state = RecordingPreferences.systemAudioEnabled() ? .on : .off
        audioCheckbox.target = self
        audioCheckbox.action = #selector(audioChanged)
        audioCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingSystemAudio")

        let devices = RecordingMicrophones.availableDevices()
        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if let saved = RecordingPreferences.microphoneDeviceID(),
           let index = microphonePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == saved }) {
            microphonePopup.selectItem(at: index)
        } else if let selected = microphonePopup.selectedItem?.representedObject as? String {
            RecordingPreferences.setMicrophoneDeviceID(selected)
        }
        microphoneCheckbox.state = RecordingPreferences.microphoneEnabled() ? .on : .off
        microphoneCheckbox.isEnabled = !devices.isEmpty
        microphoneCheckbox.target = self
        microphoneCheckbox.action = #selector(microphoneChanged)
        microphoneCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingMicrophone")
        microphonePopup.isEnabled = microphoneCheckbox.state == .on && !devices.isEmpty
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneDeviceChanged)
        microphonePopup.identifier = NSUserInterfaceItemIdentifier("recordingMicrophoneDevice")
        microphonePopup.toolTip = devices.isEmpty ? "未检测到麦克风" : "选择内置或外置麦克风"
        microphonePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        let gif = NSButton(title: "录制 GIF", target: self, action: #selector(gifAction))
        gif.identifier = NSUserInterfaceItemIdentifier("recordGIFAction")
        let video = NSButton(title: "录制视频", target: self, action: #selector(videoAction))
        video.identifier = NSUserInterfaceItemIdentifier("recordVideoAction")
        video.keyEquivalent = "\r"
        video.contentTintColor = .controlAccentColor
        let options = NSStackView(views: [audioCheckbox, microphoneCheckbox, microphonePopup])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 10
        let actions = NSStackView(views: [hint, cancel, gif, video])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        let stack = NSStackView(views: [options, actions])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func audioChanged() {
        RecordingPreferences.setSystemAudioEnabled(audioCheckbox.state == .on)
    }

    @objc private func microphoneChanged() {
        let enabled = microphoneCheckbox.state == .on
        RecordingPreferences.setMicrophoneEnabled(enabled)
        microphonePopup.isEnabled = enabled && microphonePopup.numberOfItems > 0
    }

    @objc private func microphoneDeviceChanged() {
        RecordingPreferences.setMicrophoneDeviceID(selectedMicrophoneID)
    }

    private var selectedMicrophoneID: String? {
        microphonePopup.selectedItem?.representedObject as? String
    }

    @objc private func videoAction() {
        onStart?(
            .video,
            audioCheckbox.state == .on,
            microphoneCheckbox.state == .on && microphoneCheckbox.isEnabled,
            selectedMicrophoneID
        )
    }

    @objc private func gifAction() {
        onStart?(.gif, false, false, nil)
    }

    @objc private func cancelAction() { onCancel?() }
}
