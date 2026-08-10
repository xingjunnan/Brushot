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

private enum GIFAnnotationGeometry {
    case pen(points: [CGPoint])
    case rectangle(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
}

private struct GIFAnnotationShape {
    var geometry: GIFAnnotationGeometry
    let color: NSColor
    let lineWidth: CGFloat
}

@MainActor
private final class GIFAnnotationView: NSView {
    enum Tool { case none, pen, rectangle, arrow }

    var onHistoryChanged: ((Bool, Bool) -> Void)?

    private var shapes: [GIFAnnotationShape] = []
    private var redoShapes: [GIFAnnotationShape] = []
    private var currentTool: Tool = .none
    private var drawingShape: GIFAnnotationShape?
    private var drawStartPoint: CGPoint?

    private var annotationColor = NSColor.systemRed
    private var lineWidth: CGFloat = 3

    func setTool(_ tool: Tool) {
        if let shape = drawingShape { commit(shape) }
        drawingShape = nil
        drawStartPoint = nil
        currentTool = tool
        window?.ignoresMouseEvents = (tool == .none)
        needsDisplay = true
    }

    func undoLast() {
        guard let shape = shapes.popLast() else { return }
        redoShapes.append(shape)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func redoLast() {
        guard let shape = redoShapes.popLast() else { return }
        shapes.append(shape)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func setStyle(color: NSColor, lineWidth: CGFloat) {
        annotationColor = color
        self.lineWidth = min(max(lineWidth, 1), 24)
    }

    func clearAll() {
        shapes.removeAll()
        redoShapes.removeAll()
        drawingShape = nil
        drawStartPoint = nil
        notifyHistoryChanged()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let all = drawingShape.map { shapes + [$0] } ?? shapes
        for shape in all {
            shape.color.setStroke()
            switch shape.geometry {
            case .pen(let pts):
                guard pts.count >= 2 else { continue }
                let path = NSBezierPath()
                path.lineWidth = shape.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.line(to: p) }
                path.stroke()
            case .rectangle(let rect):
                let path = NSBezierPath(rect: rect)
                path.lineWidth = shape.lineWidth
                path.stroke()
            case .arrow(let s, let e):
                let path = NSBezierPath()
                path.lineWidth = shape.lineWidth
                path.lineCapStyle = .round
                path.move(to: s)
                path.line(to: e)
                path.stroke()
                let angle = atan2(e.y - s.y, e.x - s.x)
                let hl: CGFloat = 14
                let p1 = CGPoint(x: e.x - hl * cos(angle - 0.4), y: e.y - hl * sin(angle - 0.4))
                let p2 = CGPoint(x: e.x - hl * cos(angle + 0.4), y: e.y - hl * sin(angle + 0.4))
                let head = NSBezierPath()
                head.lineWidth = shape.lineWidth
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.move(to: p1)
                head.line(to: e)
                head.line(to: p2)
                head.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard currentTool != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        drawStartPoint = p
        if currentTool == .pen { drawingShape = makeShape(.pen(points: [p])) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = drawStartPoint, currentTool != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch currentTool {
        case .pen:
            if case .pen(var pts) = drawingShape?.geometry {
                pts.append(p)
                drawingShape = makeShape(.pen(points: pts))
            }
        case .rectangle:
            drawingShape = makeShape(.rectangle(CGRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width: abs(p.x - start.x), height: abs(p.y - start.y)
            )))
        case .arrow:
            drawingShape = makeShape(.arrow(start: start, end: p))
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let shape = drawingShape {
            let valid: Bool
            switch shape.geometry {
            case .pen(let pts): valid = pts.count >= 2
            case .rectangle(let r): valid = r.width >= 2 && r.height >= 2
            case .arrow(let s, let e): valid = sqrt(pow(e.x - s.x, 2) + pow(e.y - s.y, 2)) >= 2
            }
            if valid { commit(shape) }
        }
        drawingShape = nil
        drawStartPoint = nil
        needsDisplay = true
    }

    private func makeShape(_ geometry: GIFAnnotationGeometry) -> GIFAnnotationShape {
        GIFAnnotationShape(geometry: geometry, color: annotationColor, lineWidth: lineWidth)
    }

    private func commit(_ shape: GIFAnnotationShape) {
        shapes.append(shape)
        redoShapes.removeAll()
        notifyHistoryChanged()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?(!shapes.isEmpty, !redoShapes.isEmpty)
    }
}

/// Compact real-time annotation toolbar using the same icon, selection,
/// palette, and width controls as the screenshot annotation toolbar.
@MainActor
final class RecordingAnnotationToolbarView: NSView {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onStyleChanged: ((NSColor, CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private let supportedTools: [(AnnotationTool, String)] = [
        (.select, "cursorarrow"),
        (.rectangle, "rectangle"),
        (.arrow, "arrow.up.right"),
        (.pen, "pencil.tip")
    ]
    private let palette: [RGBAColor] = [
        .annotationRed,
        RGBAColor(red: 1, green: 0.584, blue: 0),
        RGBAColor(red: 1, green: 0.8, blue: 0),
        RGBAColor(red: 0.204, green: 0.78, blue: 0.349),
        RGBAColor(red: 0.196, green: 0.678, blue: 0.902),
        RGBAColor(red: 0, green: 0.478, blue: 1),
        RGBAColor(red: 0.12, green: 0.12, blue: 0.12)
    ]
    private var toolButtons: [AnnotationTool: AnnotationHoverButton] = [:]
    private var colorButtons: [NSButton] = []
    private let tooltipPresenter = AnnotationHoverTooltipPresenter()
    private let styleRow = NSStackView()
    private lazy var widthSlider = NSSlider(
        value: 3,
        minValue: 1,
        maxValue: 24,
        target: self,
        action: #selector(widthChanged)
    )
    private lazy var undoButton = makeToolButton(
        symbol: "arrow.uturn.backward",
        title: "撤销",
        action: #selector(undoAction)
    )
    private lazy var redoButton = makeToolButton(
        symbol: "arrow.uturn.forward",
        title: "重做",
        action: #selector(redoAction)
    )
    private var selectedColorIndex = 0
    private var selectedTool: AnnotationTool = .select

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { tooltipPresenter.detach() }
        super.viewWillMove(toWindow: newWindow)
    }

    func setHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private func configureLayout() {
        let toolRow = NSStackView()
        toolRow.orientation = .horizontal
        toolRow.alignment = .centerY
        toolRow.spacing = 3
        for (tool, symbol) in supportedTools {
            let button = makeToolButton(
                symbol: symbol,
                title: tool.title,
                action: #selector(toolAction(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier("recordingAnnotation.\(tool.rawValue)")
            button.setButtonType(.toggle)
            toolButtons[tool] = button
            toolRow.addArrangedSubview(button)
        }
        undoButton.identifier = NSUserInterfaceItemIdentifier("recordingAnnotation.undo")
        redoButton.identifier = NSUserInterfaceItemIdentifier("recordingAnnotation.redo")
        toolRow.addArrangedSubview(makeSeparator())
        toolRow.addArrangedSubview(undoButton)
        toolRow.addArrangedSubview(redoButton)

        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 5
        for (index, color) in palette.enumerated() {
            let button = NSButton(frame: CGRect(x: 0, y: 0, width: 19, height: 19))
            button.title = ""
            button.isBordered = false
            button.refusesFirstResponder = true
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("recordingAnnotation.color.\(index)")
            button.toolTip = "选择标注颜色"
            button.target = self
            button.action = #selector(colorAction(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 19).isActive = true
            button.heightAnchor.constraint(equalToConstant: 19).isActive = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 9.5
            button.layer?.backgroundColor = color.nsColor.cgColor
            colorButtons.append(button)
            styleRow.addArrangedSubview(button)
        }
        let widthLabel = NSTextField(labelWithString: "粗细")
        widthLabel.font = .systemFont(ofSize: 11)
        widthLabel.textColor = .secondaryLabelColor
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        styleRow.addArrangedSubview(widthLabel)
        styleRow.addArrangedSubview(widthSlider)

        let root = NSStackView(views: [toolRow, styleRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            root.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setHistory(canUndo: false, canRedo: false)
        updateToolSelection(.select)
        refreshColorSelection()
        notifyStyleChanged()
    }

    @objc private func toolAction(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue.split(separator: ".").last,
              let tool = AnnotationTool(rawValue: String(value)) else { return }
        updateToolSelection(tool)
        onToolSelected?(tool)
    }

    @objc private func colorAction(_ sender: NSButton) {
        guard palette.indices.contains(sender.tag) else { return }
        selectedColorIndex = sender.tag
        refreshColorSelection()
        notifyStyleChanged()
    }

    @objc private func widthChanged() { notifyStyleChanged() }
    @objc private func undoAction() { onUndo?() }
    @objc private func redoAction() { onRedo?() }

    private func updateToolSelection(_ tool: AnnotationTool) {
        selectedTool = tool
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? .systemBlue : .labelColor
        }
        styleRow.isHidden = tool == .select
    }

    private func notifyStyleChanged() {
        onStyleChanged?(palette[selectedColorIndex].nsColor, CGFloat(widthSlider.doubleValue))
    }

    private func refreshColorSelection() {
        for (index, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = index == selectedColorIndex ? 2.5 : 1
            button.layer?.borderColor = index == selectedColorIndex
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.55).cgColor
        }
    }

    private func makeToolButton(symbol: String, title: String, action: Selector) -> AnnotationHoverButton {
        let button = AnnotationHoverButton(frame: CGRect(x: 0, y: 0, width: 30, height: 28))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.hoverTitle = title
        button.onHoverShow = { [weak self] button, title in
            self?.tooltipPresenter.show(title: title, relativeTo: button)
        }
        button.onHoverHide = { [weak self] in self?.tooltipPresenter.hide() }
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return separator
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
    private let annotationToolbar = RecordingAnnotationToolbarView(
        frame: CGRect(x: 0, y: 0, width: 340, height: 72)
    )

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
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 84),
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

        annotationToolbar.onToolSelected = { [weak self] tool in
            self?.selectRecordingAnnotationTool(tool)
        }
        annotationToolbar.onStyleChanged = { [weak self] color, lineWidth in
            self?.annotationView.setStyle(color: color, lineWidth: lineWidth)
        }
        annotationToolbar.onUndo = { [weak self] in self?.annotationView.undoLast() }
        annotationToolbar.onRedo = { [weak self] in self?.annotationView.redoLast() }
        annotationView.onHistoryChanged = { [weak self] canUndo, canRedo in
            self?.annotationToolbar.setHistory(canUndo: canUndo, canRedo: canRedo)
        }
        annotationView.setStyle(color: .systemRed, lineWidth: 3)

        let statusRow = NSStackView(views: [dotContainer, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7
        let actionRow = NSStackView(views: [pauseButton, cancelButton, finishButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        let recordingControls = NSStackView(views: [statusRow, actionRow])
        recordingControls.orientation = .vertical
        recordingControls.alignment = .trailing
        recordingControls.spacing = 8

        annotationToolbar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [annotationToolbar, makeSeparator(height: 56), recordingControls])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            annotationToolbar.widthAnchor.constraint(equalToConstant: 340),
            annotationToolbar.heightAnchor.constraint(equalToConstant: 72),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
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

    private func selectRecordingAnnotationTool(_ tool: AnnotationTool) {
        switch tool {
        case .select: annotationView.setTool(.none)
        case .rectangle: annotationView.setTool(.rectangle)
        case .arrow: annotationView.setTool(.arrow)
        case .pen: annotationView.setTool(.pen)
        default: annotationView.setTool(.none)
        }
    }

    private func makeSeparator(height: CGFloat = 20) -> NSView {
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 1),
            sep.heightAnchor.constraint(equalToConstant: height)
        ])
        return sep
    }
}

@MainActor
final class RecordingStartBar: NSVisualEffectView {
    var onStart: ((RecordingFormat, Bool, Bool, String?) -> Void)?
    var onCancel: (() -> Void)?
    private let audioCheckbox = NSButton(
        checkboxWithTitle: "系统音频",
        target: nil,
        action: nil
    )
    private let microphoneCheckbox = NSButton(
        checkboxWithTitle: "麦克风",
        target: nil,
        action: nil
    )
    private let microphonePopup = NSPopUpButton()
    private lazy var formatControl = NSSegmentedControl(
        labels: ["视频", "GIF"],
        trackingMode: .selectOne,
        target: self,
        action: #selector(formatChanged)
    )
    private lazy var startButton = NSButton(
        title: "开始录制视频",
        target: self,
        action: #selector(startAction)
    )
    private let silentHint = NSTextField(labelWithString: "GIF 将以静音方式录制")
    private var hasMicrophones = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        let formatLabel = makeSectionLabel("录制格式")
        let audioLabel = makeSectionLabel("视频音频")
        formatControl.selectedSegment = 0
        formatControl.identifier = NSUserInterfaceItemIdentifier("recordingFormatControl")
        audioCheckbox.state = RecordingPreferences.systemAudioEnabled() ? .on : .off
        audioCheckbox.target = self
        audioCheckbox.action = #selector(audioChanged)
        audioCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingSystemAudio")

        let devices = RecordingMicrophones.availableDevices()
        hasMicrophones = !devices.isEmpty
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
        microphoneCheckbox.isEnabled = hasMicrophones
        microphoneCheckbox.target = self
        microphoneCheckbox.action = #selector(microphoneChanged)
        microphoneCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingMicrophone")
        microphonePopup.isEnabled = microphoneCheckbox.state == .on && hasMicrophones
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneDeviceChanged)
        microphonePopup.identifier = NSUserInterfaceItemIdentifier("recordingMicrophoneDevice")
        microphonePopup.toolTip = devices.isEmpty ? "未检测到麦克风" : "选择内置或外置麦克风"
        microphonePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        startButton.identifier = NSUserInterfaceItemIdentifier("startRecordingAction")
        startButton.keyEquivalent = "\r"
        startButton.contentTintColor = .controlAccentColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let formatRow = NSStackView(views: [formatLabel, formatControl, spacer, cancel, startButton])
        formatRow.orientation = .horizontal
        formatRow.alignment = .centerY
        formatRow.spacing = 10

        silentHint.font = .systemFont(ofSize: 12)
        silentHint.textColor = .secondaryLabelColor
        let audioRow = NSStackView(views: [audioLabel, audioCheckbox, microphoneCheckbox, microphonePopup, silentHint])
        audioRow.orientation = .horizontal
        audioRow.alignment = .centerY
        audioRow.spacing = 10

        let stack = NSStackView(views: [formatRow, audioRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            formatRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formatLabel.widthAnchor.constraint(equalToConstant: 58),
            audioLabel.widthAnchor.constraint(equalToConstant: 58)
        ])
        updateFormatState()
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
        microphonePopup.isEnabled = formatControl.selectedSegment == 0 && enabled && hasMicrophones
    }

    @objc private func microphoneDeviceChanged() {
        RecordingPreferences.setMicrophoneDeviceID(selectedMicrophoneID)
    }

    private var selectedMicrophoneID: String? {
        microphonePopup.selectedItem?.representedObject as? String
    }

    @objc private func formatChanged() { updateFormatState() }

    @objc private func startAction() {
        if formatControl.selectedSegment == 1 {
            onStart?(.gif, false, false, nil)
        } else {
            onStart?(
                .video,
                audioCheckbox.state == .on,
                microphoneCheckbox.state == .on && microphoneCheckbox.isEnabled,
                selectedMicrophoneID
            )
        }
    }

    private func updateFormatState() {
        let isVideo = formatControl.selectedSegment == 0
        audioCheckbox.isEnabled = isVideo
        microphoneCheckbox.isEnabled = isVideo && hasMicrophones
        microphonePopup.isEnabled = isVideo && hasMicrophones && microphoneCheckbox.state == .on
        silentHint.isHidden = isVideo
        startButton.title = isVideo ? "开始录制视频" : "开始录制 GIF"
    }

    @objc private func cancelAction() { onCancel?() }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
}
