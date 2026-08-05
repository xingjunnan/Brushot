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
    private let annotationWindow: GIFAnnotationPanel
    private let annotationView: GIFAnnotationView
    private let statusLabel = NSTextField(labelWithString: "")
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var selectToolButton: NSButton!
    private var penToolButton: NSButton!
    private var rectToolButton: NSButton!
    private var arrowToolButton: NSButton!

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
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 52),
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
        configureControlPanel()
    }

    func start() {
        guard !isFinished else { return }
        positionControlPanel()
        annotationWindow.orderFrontRegardless()
        borderWindow.orderFrontRegardless()
        controlWindow.orderFrontRegardless()
        capturer.exceptedWindowIDs.insert(CGWindowID(annotationWindow.windowNumber))
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
            dotContainer, statusLabel, cancelButton, finishButton
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
