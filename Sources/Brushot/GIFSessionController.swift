import AppKit
@preconcurrency import AVFoundation
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
    var onPreferredSizeChanged: ((CGSize) -> Void)?

    static let selectionPreferredSize = CGSize(width: 210, height: 40)
    static let drawingPreferredSize = CGSize(width: 280, height: 72)
    private(set) var currentPreferredSize = selectionPreferredSize

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
        RGBAColor(red: 0, green: 0.478, blue: 1)
    ]
    private var toolButtons: [AnnotationTool: AnnotationHoverButton] = [:]
    private var colorButtons: [NSButton] = []
    private let customColorButton = AnnotationColorPickerButton(
        frame: CGRect(x: 0, y: 0, width: 19, height: 19)
    )
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
        title: L.text("撤销"),
        action: #selector(undoAction)
    )
    private lazy var redoButton = makeToolButton(
        symbol: "arrow.uturn.forward",
        title: L.text("重做"),
        action: #selector(redoAction)
    )
    private var selectedColor = RGBAColor.annotationRed
    private var selectedTool: AnnotationTool = .select

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tooltipPresenter.detach()
            detachColorPanel()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    func deactivateTool() {
        updateToolSelection(.select)
        onToolSelected?(.select)
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
            button.toolTip = L.text("选择标注颜色")
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
        customColorButton.identifier = NSUserInterfaceItemIdentifier("recordingAnnotation.color.6")
        customColorButton.toolTip = L.text("选择标注颜色")
        customColorButton.target = self
        customColorButton.action = #selector(customColorAction)
        customColorButton.translatesAutoresizingMaskIntoConstraints = false
        customColorButton.widthAnchor.constraint(equalToConstant: 19).isActive = true
        customColorButton.heightAnchor.constraint(equalToConstant: 19).isActive = true
        styleRow.addArrangedSubview(customColorButton)
        let widthLabel = NSTextField(labelWithString: L.text("粗细"))
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
        selectedColor = palette[sender.tag]
        refreshColorSelection()
        notifyStyleChanged()
    }

    @objc private func customColorAction() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = selectedColor.nsColor.withAlphaComponent(1)
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        AnnotationColorPanelCoordinator.owner = self
        panel.level = NSWindow.Level(
            rawValue: max(NSWindow.Level.floating.rawValue, (window?.level.rawValue ?? 0) + 1)
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        selectedColor = RGBAColor(sender.color)
        selectedColor.alpha = 1
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
        let preferredSize = tool == .select ? Self.selectionPreferredSize : Self.drawingPreferredSize
        if currentPreferredSize != preferredSize {
            currentPreferredSize = preferredSize
            onPreferredSizeChanged?(preferredSize)
        }
    }

    private func notifyStyleChanged() {
        onStyleChanged?(selectedColor.nsColor, CGFloat(widthSlider.doubleValue))
    }

    private func refreshColorSelection() {
        var matchesPreset = false
        for (index, button) in colorButtons.enumerated() {
            let candidate = palette[index]
            let selected = abs(candidate.red - selectedColor.red) < 0.01
                && abs(candidate.green - selectedColor.green) < 0.01
                && abs(candidate.blue - selectedColor.blue) < 0.01
            matchesPreset = matchesPreset || selected
            button.layer?.borderWidth = selected ? 2.5 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.55).cgColor
        }
        customColorButton.setSelected(!matchesPreset)
    }

    private func detachColorPanel() {
        let panel = NSColorPanel.shared
        guard AnnotationColorPanelCoordinator.owner === self else { return }
        AnnotationColorPanelCoordinator.owner = nil
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
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
enum RecordingCountdown {
    static let seconds = [3, 2, 1]
}

@MainActor
final class RecordingSessionController: NSObject {
    private let selectionRect: CGRect
    private let capturer: ScreenRegionCapturer
    private let engine = RecordingEngine()
    private let configuration: RecordingConfiguration
    private let onFinish: (RecordingResult) -> Void
    private let onInterrupted: (RecordingResult, Error) -> Void
    private let onCancel: () -> Void
    private let onError: (Error) -> Void
    private let onCameraPermissionDenied: () -> Void

    private let borderWindow: NSWindow
    private let controlWindow: GIFOverlayPanel
    private let annotationWindow: GIFAnnotationPanel
    private let annotationView: GIFAnnotationView
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: L.text("暂停"), target: nil, action: nil)
    private let finishButton = NSButton(title: L.text("停止"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L.text("取消"), target: nil, action: nil)
    private let collapseButton = NSButton()
    private let cameraButton = NSButton()
    private let cameraSettingsButton = NSButton()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let annotationToolbar = RecordingAnnotationToolbarView(
        frame: CGRect(origin: .zero, size: RecordingAnnotationToolbarView.selectionPreferredSize)
    )

    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private weak var annotationSeparator: NSView?
    private var annotationSeparatorHeightConstraint: NSLayoutConstraint?
    private var annotationToolbarWidthConstraint: NSLayoutConstraint?
    private var annotationToolbarHeightConstraint: NSLayoutConstraint?
    private var collapseButtonWidthConstraint: NSLayoutConstraint?
    private var isControlPanelCollapsed = false
    private var isFinished = false
    private var lastDiskCheckAt = Date.distantPast
    private var cameraOverlay: RecordingCameraOverlayController?
    private var cameraOptions: RecordingCameraOptions?
    private lazy var cameraSettingsView: RecordingCameraSettingsView = {
        let view = RecordingCameraSettingsView(
            frame: CGRect(x: 0, y: 0, width: 330, height: 252),
            options: cameraOptions ?? .defaults,
            showsDevice: true
        )
        view.onOptionsChanged = { [weak self] options in self?.applyCameraOptions(options) }
        return view
    }()
    private lazy var cameraSettingsPopover: NSPopover = {
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = cameraSettingsView
        popover.contentViewController = controller
        popover.contentSize = cameraSettingsView.frame.size
        popover.behavior = .transient
        return popover
    }()
    private var cameraStatusMessage: String?
    private var cameraStatusExpiresAt = Date.distantPast

    nonisolated static let borderExpansion: CGFloat = 3
    nonisolated static let expandedControlSize = CGSize(width: 616, height: 48)
    nonisolated static let drawingControlSize = CGSize(width: 650, height: 84)
    nonisolated static let collapsedControlSize = CGSize(width: 426, height: 48)
    static let annotationWindowLevel = NSWindow.Level.screenSaver
    static let controlWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    init(
        selectionRect: CGRect,
        capturer: ScreenRegionCapturer,
        configuration: RecordingConfiguration,
        onFinish: @escaping (RecordingResult) -> Void,
        onInterrupted: @escaping (RecordingResult, Error) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onCameraPermissionDenied: @escaping () -> Void
    ) {
        self.selectionRect = selectionRect
        self.capturer = capturer
        self.configuration = configuration
        self.onFinish = onFinish
        self.onInterrupted = onInterrupted
        self.onCancel = onCancel
        self.onError = onError
        self.onCameraPermissionDenied = onCameraPermissionDenied
        cameraOptions = configuration.cameraOptions

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
        borderWindow.level = Self.annotationWindowLevel
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderWindow.isReleasedWhenClosed = false

        controlWindow = GIFOverlayPanel(
            contentRect: CGRect(origin: .zero, size: Self.expandedControlSize),
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
        annotationWindow.level = Self.annotationWindowLevel
        annotationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        annotationWindow.ignoresMouseEvents = true
        annotationWindow.contentView = annotationView

        super.init()
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center
        countdownLabel.wantsLayer = true
        countdownLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        countdownLabel.layer?.cornerRadius = 18
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.isHidden = true
        annotationView.addSubview(countdownLabel)
        NSLayoutConstraint.activate([
            countdownLabel.widthAnchor.constraint(equalToConstant: 72),
            countdownLabel.heightAnchor.constraint(equalToConstant: 72),
            countdownLabel.centerXAnchor.constraint(equalTo: annotationView.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: annotationView.centerYAnchor)
        ])
        engine.onUnexpectedStop = { [weak self] error, recoveredResult in
            guard let self, !self.isFinished else { return }
            self.cleanup()
            if let recoveredResult {
                self.onInterrupted(recoveredResult, error)
            } else {
                self.onError(error)
            }
        }
        configureControlPanel()
    }

    func start() {
        guard !isFinished else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        setControlPanelCollapsed(
            Self.shouldStartWithCollapsedControls(
                selectionRect: selectionRect,
                screenFrame: screen?.frame ?? selectionRect
            ),
            reposition: false
        )
        positionControlPanel()
        annotationWindow.orderFrontRegardless()
        borderWindow.orderFrontRegardless()
        controlWindow.orderFrontRegardless()
        capturer.exceptedWindowIDs.insert(CGWindowID(annotationWindow.windowNumber))
        prepareCameraOverlayIfNeeded()
        updateStatus(elapsed: 0)
        pauseButton.isEnabled = false
        finishButton.isEnabled = false
        cameraButton.isEnabled = false

        startTask = Task { [weak self] in
            guard let self else { return }
            // Rebuild the filter now that Brushot's border/control windows
            // are on screen, so they are excluded from every recorded frame.
            do {
                try await self.capturer.prepareForRecordingOverlay()
                for second in RecordingCountdown.seconds {
                    try Task.checkCancellation()
                    guard !self.isFinished else { return }
                    self.countdownLabel.stringValue = "\(second)"
                    self.countdownLabel.isHidden = false
                    self.statusLabel.stringValue = L.format("录制将在 %d 秒后开始", second)
                    try await Task.sleep(for: .seconds(1))
                }
                guard !self.isFinished else { return }
                self.countdownLabel.isHidden = true
                try await self.engine.start(
                    capturer: self.capturer,
                    configuration: self.configuration
                )
                self.pauseButton.isEnabled = true
                self.finishButton.isEnabled = true
                self.cameraButton.isEnabled = true
            } catch {
                if error is CancellationError { return }
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
            updatePauseButton(paused: true)
            updateStatus(elapsed: engine.elapsedTime)
        } else if engine.state == .paused {
            engine.resume()
            updatePauseButton(paused: false)
        }
    }

    @objc private func cancelAction() {
        cancel()
    }

    @objc private func toggleControlPanel() {
        setControlPanelCollapsed(!isControlPanelCollapsed, reposition: true)
    }

    @objc private func toggleCamera() {
        guard let cameraOverlay else { return }
        if cameraOverlay.isVisible {
            cameraOverlay.hide()
            cameraOptions?.isEnabled = false
            updateCameraButton(isVisible: false)
            return
        }
        cameraButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let status = await RecordingCameras.requestPermissionIfNeeded()
            guard status == .authorized else {
                self.cameraButton.isEnabled = true
                self.onCameraPermissionDenied()
                return
            }
            do {
                try cameraOverlay.show()
                self.capturer.exceptedWindowIDs.insert(cameraOverlay.windowID)
                try await self.capturer.refreshRecordingOverlayExclusion()
                try await self.engine.updateContentFilter(self.capturer.captureContentFilter)
                self.cameraOptions?.isEnabled = true
                self.updateCameraButton(isVisible: true)
            } catch {
                cameraOverlay.hide()
                self.capturer.exceptedWindowIDs.remove(cameraOverlay.windowID)
                self.cameraOptions?.isEnabled = false
                self.updateCameraButton(isVisible: false)
                self.showCameraStatus(L.text("摄像头不可用，录屏继续"))
            }
        }
    }

    @objc private func showCameraSettings() {
        guard let cameraOptions, !cameraSettingsButton.isHidden else { return }
        cameraSettingsView.update(options: cameraOptions)
        if cameraSettingsPopover.isShown { cameraSettingsPopover.performClose(nil) }
        else {
            cameraSettingsPopover.show(
                relativeTo: cameraSettingsButton.bounds,
                of: cameraSettingsButton,
                preferredEdge: .maxY
            )
        }
    }

    private func applyCameraOptions(_ options: RecordingCameraOptions) {
        var updated = options
        updated.isEnabled = cameraOverlay?.isVisible == true
        cameraOptions = updated
        cameraOverlay?.update(options: updated)
        RecordingCameraPreferences.save(updated)
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
            if !RecordingDiskSpace.hasEnoughSpaceToContinue() {
                statusLabel.stringValue = L.text("磁盘可用空间低于 12 GB，正在安全停止…")
                finish()
            }
        }
    }

    private func updateStatus(elapsed: TimeInterval) {
        if let cameraStatusMessage, Date() < cameraStatusExpiresAt {
            statusLabel.stringValue = cameraStatusMessage
            return
        }
        cameraStatusMessage = nil
        let e = elapsed
        let paused = engine.state == .paused ? L.text(" · 已暂停") : ""
        let microphone = configuration.capturesMicrophone ? L.text(" · 麦克风") : ""
        var timeText = Self.clockText(e)
        if let remaining = RecordingLimits.remainingTime(for: configuration.format, elapsed: e) {
            timeText += L.format(" · 剩余 %@", Self.clockText(remaining))
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
        startTask?.cancel()
        startTask = nil
        timer?.invalidate()
        timer = nil
        annotationWindow.orderOut(nil)
        borderWindow.orderOut(nil)
        controlWindow.orderOut(nil)
        if cameraSettingsPopover.isShown { cameraSettingsPopover.performClose(nil) }
        cameraOverlay?.close()
        cameraOverlay = nil
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
        controlWindow.level = Self.controlWindowLevel
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
            dotContainer.widthAnchor.constraint(equalToConstant: 8),
            dotContainer.heightAnchor.constraint(equalToConstant: 8),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: dotContainer.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: dotContainer.centerYAnchor)
        ])

        configureControlButton(finishButton, symbol: "stop.fill", title: L.text("停止"), tint: .systemRed)
        finishButton.target = self
        finishButton.action = #selector(finishAction)
        finishButton.keyEquivalent = "\r"
        configureControlButton(pauseButton, symbol: "pause.fill", title: L.text("暂停"))
        pauseButton.target = self
        pauseButton.action = #selector(pauseAction)
        configureControlButton(cancelButton, symbol: "xmark", title: L.text("取消"))
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"
        configureControlButton(collapseButton, symbol: "chevron.left", title: L.text("收起录制工具栏"))
        collapseButton.target = self
        collapseButton.action = #selector(toggleControlPanel)
        collapseButton.identifier = NSUserInterfaceItemIdentifier("recordingControlsCollapse")
        configureControlButton(cameraButton, symbol: "video.fill", title: L.text("关闭摄像头"))
        cameraButton.target = self
        cameraButton.action = #selector(toggleCamera)
        cameraButton.identifier = NSUserInterfaceItemIdentifier("recordingCameraToggle")
        cameraButton.isHidden = configuration.cameraOptions == nil
        configureControlButton(
            cameraSettingsButton,
            symbol: "slider.horizontal.3",
            title: L.text("画中画设置…")
        )
        cameraSettingsButton.target = self
        cameraSettingsButton.action = #selector(showCameraSettings)
        cameraSettingsButton.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsDuringRecording")
        cameraSettingsButton.isHidden = configuration.cameraOptions == nil

        annotationToolbar.onToolSelected = { [weak self] tool in
            self?.selectRecordingAnnotationTool(tool)
        }
        annotationToolbar.onStyleChanged = { [weak self] color, lineWidth in
            self?.annotationView.setStyle(color: color, lineWidth: lineWidth)
        }
        annotationToolbar.onUndo = { [weak self] in self?.annotationView.undoLast() }
        annotationToolbar.onRedo = { [weak self] in self?.annotationView.redoLast() }
        annotationToolbar.onPreferredSizeChanged = { [weak self] size in
            self?.updateAnnotationToolbarSize(size)
        }
        annotationView.onHistoryChanged = { [weak self] canUndo, canRedo in
            self?.annotationToolbar.setHistory(canUndo: canUndo, canRedo: canRedo)
        }
        annotationView.setStyle(color: .systemRed, lineWidth: 3)

        let statusRow = NSStackView(views: [dotContainer, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7
        let recordingControls = NSStackView(views: [
            statusRow,
            cameraButton,
            cameraSettingsButton,
            pauseButton,
            cancelButton,
            finishButton,
            collapseButton
        ])
        recordingControls.orientation = .horizontal
        recordingControls.alignment = .centerY
        recordingControls.spacing = 6

        annotationToolbar.translatesAutoresizingMaskIntoConstraints = false
        let separator = makeSeparator(height: 28)
        annotationSeparator = separator
        annotationSeparatorHeightConstraint = separator.constraints.first {
            $0.firstAttribute == .height
        }
        let stack = NSStackView(views: [annotationToolbar, separator, recordingControls])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        let toolbarWidth = annotationToolbar.widthAnchor.constraint(
            equalToConstant: RecordingAnnotationToolbarView.selectionPreferredSize.width
        )
        let toolbarHeight = annotationToolbar.heightAnchor.constraint(
            equalToConstant: RecordingAnnotationToolbarView.selectionPreferredSize.height
        )
        annotationToolbarWidthConstraint = toolbarWidth
        annotationToolbarHeightConstraint = toolbarHeight
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            toolbarWidth,
            toolbarHeight,
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
    }

    nonisolated static func shouldStartWithCollapsedControls(
        selectionRect: CGRect,
        screenFrame: CGRect
    ) -> Bool {
        abs(selectionRect.minX - screenFrame.minX) <= 2
            && abs(selectionRect.minY - screenFrame.minY) <= 2
            && abs(selectionRect.width - screenFrame.width) <= 2
            && abs(selectionRect.height - screenFrame.height) <= 2
    }

    private func setControlPanelCollapsed(_ collapsed: Bool, reposition: Bool) {
        isControlPanelCollapsed = collapsed
        annotationToolbar.isHidden = collapsed
        annotationSeparator?.isHidden = collapsed
        if collapsed { annotationToolbar.deactivateTool() }
        let title = collapsed ? L.text("展开录制工具栏") : L.text("收起录制工具栏")
        collapseButtonWidthConstraint?.constant = collapsed ? 72 : 30
        collapseButton.title = collapsed ? L.text("标注") : ""
        collapseButton.image = NSImage(
            systemSymbolName: collapsed ? "pencil.tip" : "chevron.left",
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        collapseButton.imagePosition = collapsed ? .imageLeading : .imageOnly
        collapseButton.isBordered = collapsed
        collapseButton.bezelStyle = .rounded
        collapseButton.toolTip = title
        collapseButton.setAccessibilityLabel(title)
        let size = collapsed
            ? Self.collapsedControlSize
            : expandedControlSize(for: annotationToolbar.currentPreferredSize)
        controlWindow.setContentSize(size)
        if reposition { positionControlPanel() }
    }

    private func updateAnnotationToolbarSize(_ size: CGSize) {
        annotationToolbarWidthConstraint?.constant = size.width
        annotationToolbarHeightConstraint?.constant = size.height
        annotationSeparatorHeightConstraint?.constant = size.height
            > RecordingAnnotationToolbarView.selectionPreferredSize.height ? 56 : 28
        guard !isControlPanelCollapsed else { return }
        controlWindow.setContentSize(expandedControlSize(for: size))
        positionControlPanel()
    }

    private func expandedControlSize(for toolbarSize: CGSize) -> CGSize {
        toolbarSize.height > RecordingAnnotationToolbarView.selectionPreferredSize.height
            ? Self.drawingControlSize
            : Self.expandedControlSize
    }

    private func configureControlButton(
        _ button: NSButton,
        symbol: String,
        title: String,
        tint: NSColor = .labelColor
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = tint
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: 30)
        widthConstraint.isActive = true
        if button === collapseButton { collapseButtonWidthConstraint = widthConstraint }
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func updatePauseButton(paused: Bool) {
        let symbol = paused ? "play.fill" : "pause.fill"
        let title = L.text(paused ? "继续" : "暂停")
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        pauseButton.toolTip = title
        pauseButton.setAccessibilityLabel(title)
    }

    private func prepareCameraOverlayIfNeeded() {
        guard var options = cameraOptions else { return }
        let overlay = RecordingCameraOverlayController(
            selectionRect: selectionRect,
            options: options,
            level: NSWindow.Level(rawValue: Self.annotationWindowLevel.rawValue + 1)
        )
        overlay.onUnavailable = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            overlay.hide()
            self.updateCameraButton(isVisible: false)
            self.showCameraStatus(L.text("摄像头已断开，录屏继续"))
        }
        overlay.onOptionsChanged = { [weak self] updated in
            guard let self else { return }
            self.cameraOptions = updated
            self.cameraSettingsView.update(options: updated)
        }
        cameraOverlay = overlay
        guard options.isEnabled else {
            updateCameraButton(isVisible: false)
            return
        }
        options.isEnabled = true
        do {
            overlay.update(options: options)
            try overlay.show()
            capturer.exceptedWindowIDs.insert(overlay.windowID)
            updateCameraButton(isVisible: true)
        } catch {
            overlay.hide()
            cameraOptions?.isEnabled = false
            updateCameraButton(isVisible: false)
            showCameraStatus(L.text("摄像头启动失败，录屏继续"), duration: 8)
        }
    }

    private func updateCameraButton(isVisible: Bool, isAvailable: Bool = true) {
        let title = isAvailable
            ? L.text(isVisible ? "关闭摄像头" : "打开摄像头")
            : L.text("摄像头不可用")
        cameraButton.image = NSImage(
            systemSymbolName: isAvailable && isVisible ? "video.fill" : "video.slash.fill",
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        cameraButton.contentTintColor = !isAvailable
            ? .systemOrange
            : (isVisible ? .systemGreen : .secondaryLabelColor)
        cameraButton.isEnabled = isAvailable
        cameraButton.toolTip = title
        cameraButton.setAccessibilityLabel(title)
    }

    private func showCameraStatus(_ message: String, duration: TimeInterval = 6) {
        cameraStatusMessage = message
        cameraStatusExpiresAt = Date().addingTimeInterval(duration)
        statusLabel.stringValue = message
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
    var onStart: ((RecordingFormat, RecordingVideoResolution, Int, Bool, Bool, String?, RecordingCameraOptions?, WatermarkConfiguration?) -> Void)?
    var onCancel: (() -> Void)?
    var onCameraOptionsChanged: ((RecordingCameraOptions?) -> Void)?
    var onCameraPermissionDenied: (() -> Void)?
    var onRegionPixelSizeChanged: ((CGSize) -> Void)?
    var onRegionAspectRatioChanged: ((CGFloat?) -> Void)?
    var onRestoreLastRegion: (() -> Void)?
    var cameraPermissionRequester: () async -> AVAuthorizationStatus = {
        await RecordingCameras.requestPermissionIfNeeded()
    }
    var availableDiskBytesProvider: () -> Int64? = {
        RecordingDiskSpace.availableBytes()
    }
    private let audioCheckbox = NSButton(
        checkboxWithTitle: L.text("系统音频"),
        target: nil,
        action: nil
    )
    private let microphoneCheckbox = NSButton(
        checkboxWithTitle: L.text("麦克风"),
        target: nil,
        action: nil
    )
    private let microphonePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let cameraCheckbox = NSButton(checkboxWithTitle: L.text("摄像头"), target: nil, action: nil)
    private let cameraPopup = NSPopUpButton()
    private lazy var cameraSettingsButton = NSButton(
        title: L.text("画中画设置…"),
        target: self,
        action: #selector(showCameraSettingsPopover)
    )
    private lazy var cameraSettingsView: RecordingCameraSettingsView = {
        let view = RecordingCameraSettingsView(
            frame: CGRect(x: 0, y: 0, width: 330, height: 212),
            options: cameraOptions,
            showsDevice: false
        )
        view.onOptionsChanged = { [weak self] options in
            guard let self else { return }
            self.cameraOptions = options
            self.saveAndPublishCameraOptions()
        }
        return view
    }()
    private lazy var cameraSettingsPopover: NSPopover = {
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = cameraSettingsView
        popover.contentViewController = controller
        popover.contentSize = cameraSettingsView.frame.size
        popover.behavior = .transient
        return popover
    }()
    private lazy var regionSizeButton = NSButton(
        title: L.text("选区尺寸"),
        target: self,
        action: #selector(showRegionSizePopover)
    )
    private lazy var regionSizeView: RecordingRegionSizeBar = {
        let view = RecordingRegionSizeBar(frame: CGRect(x: 0, y: 0, width: 410, height: 104))
        view.onPixelSizeChanged = { [weak self] size in self?.onRegionPixelSizeChanged?(size) }
        view.onAspectRatioChanged = { [weak self] ratio in self?.onRegionAspectRatioChanged?(ratio) }
        view.onRestoreLast = { [weak self] in self?.onRestoreLastRegion?() }
        return view
    }()
    private lazy var regionSizePopover: NSPopover = {
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = regionSizeView
        popover.contentViewController = controller
        popover.contentSize = regionSizeView.frame.size
        popover.behavior = .transient
        return popover
    }()
    private let performanceHint = NSTextField(labelWithString: L.text("高负载"))
    private lazy var formatControl = NSSegmentedControl(
        labels: [L.text("视频"), "GIF"],
        trackingMode: .selectOne,
        target: self,
        action: #selector(formatChanged)
    )
    private lazy var startButton = NSButton(
        title: L.text("开始录制视频"),
        target: self,
        action: #selector(startAction)
    )
    private lazy var audioLabel = makeSectionLabel(L.text("视频音频"))
    private lazy var qualityLabel = makeSectionLabel(L.text("视频质量"))
    private lazy var cameraLabel = makeSectionLabel(L.text("画中画"))
    private let silentHint = NSTextField(labelWithString: L.text("GIF 最长 60 秒，建议 30 秒内 · 无声音"))
    private var hasMicrophones = false
    private var canUseMicrophonePermission = true
    private var sourcePixelSize = CGSize.zero
    private var isRegionSizingAvailable = false
    private var cameraOptions = RecordingCameraPreferences.load()
    private var hasCameras = false
    private var isRequestingCameraPermission = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        let formatLabel = makeSectionLabel(L.text("录制格式"))
        formatControl.selectedSegment = 0
        formatControl.identifier = NSUserInterfaceItemIdentifier("recordingFormatControl")
        regionSizeButton.identifier = NSUserInterfaceItemIdentifier("recordingRegionSize")
        configureVideoQualityControls()
        audioCheckbox.state = RecordingPreferences.systemAudioEnabled() ? .on : .off
        audioCheckbox.target = self
        audioCheckbox.action = #selector(audioChanged)
        audioCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingSystemAudio")
        let devices = RecordingMicrophones.availableDevices()
        hasMicrophones = !devices.isEmpty
        canUseMicrophonePermission = RecordingMicrophones.canRequestOrUsePermission()
        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if hasMicrophones {
            if let saved = RecordingPreferences.microphoneDeviceID(),
               let index = microphonePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == saved }) {
                microphonePopup.selectItem(at: index)
            } else if let selected = microphonePopup.selectedItem?.representedObject as? String {
                RecordingPreferences.setMicrophoneDeviceID(selected)
            } else {
                RecordingPreferences.setMicrophoneDeviceID(nil)
            }
        } else {
            microphonePopup.addItem(withTitle: L.text("未检测到麦克风"))
            microphonePopup.lastItem?.representedObject = nil
            RecordingPreferences.setMicrophoneDeviceID(nil)
        }
        microphoneCheckbox.state = RecordingPreferences.microphoneEnabled() ? .on : .off
        microphoneCheckbox.isEnabled = canUseMicrophonePermission
        microphoneCheckbox.target = self
        microphoneCheckbox.action = #selector(microphoneChanged)
        microphoneCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingMicrophone")
        microphonePopup.isEnabled = microphoneCheckbox.state == .on && hasMicrophones
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneDeviceChanged)
        microphonePopup.identifier = NSUserInterfaceItemIdentifier("recordingMicrophoneDevice")
        microphonePopup.toolTip = devices.isEmpty ? L.text("未检测到麦克风") : L.text("选择内置或外置麦克风")
        microphonePopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        microphonePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        microphonePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        configureCameraControls()

        let cancel = NSButton(title: L.text("取消"), target: self, action: #selector(cancelAction))
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
        let audioRow = NSStackView(views: [
            audioLabel,
            audioCheckbox,
            microphoneCheckbox,
            microphonePopup,
            silentHint
        ])
        audioRow.orientation = .horizontal
        audioRow.alignment = .centerY
        audioRow.spacing = 10

        let qualityRow = NSStackView(views: [
            qualityLabel,
            resolutionPopup,
            fpsPopup,
            regionSizeButton,
            performanceHint
        ])
        qualityRow.orientation = .horizontal
        qualityRow.alignment = .centerY
        qualityRow.spacing = 10

        let cameraRow = NSStackView(views: [
            cameraLabel,
            cameraCheckbox,
            cameraPopup,
            cameraSettingsButton
        ])
        cameraRow.orientation = .horizontal
        cameraRow.alignment = .centerY
        cameraRow.spacing = 10

        let stack = NSStackView(views: [formatRow, qualityRow, audioRow, cameraRow])
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
            qualityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cameraRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formatLabel.widthAnchor.constraint(equalToConstant: 58),
            qualityLabel.widthAnchor.constraint(equalToConstant: 58),
            audioLabel.widthAnchor.constraint(equalToConstant: 58),
            cameraLabel.widthAnchor.constraint(equalToConstant: 58)
        ])
        updateFormatState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func audioChanged() {
        RecordingPreferences.setSystemAudioEnabled(audioCheckbox.state == .on)
        updateVideoQualitySummary()
    }

    @objc private func microphoneChanged() {
        let enabled = microphoneCheckbox.state == .on
        RecordingPreferences.setMicrophoneEnabled(enabled)
        microphonePopup.isEnabled = formatControl.selectedSegment == 0 && enabled && hasMicrophones
        updateVideoQualitySummary()
    }

    @objc private func microphoneDeviceChanged() {
        RecordingPreferences.setMicrophoneDeviceID(selectedMicrophoneID)
    }

    @objc private func videoQualityChanged() {
        RecordingPreferences.setVideoResolution(selectedVideoResolution)
        RecordingPreferences.setVideoFPS(selectedVideoFPS)
        updateVideoQualitySummary()
    }

    @objc private func cameraChanged() {
        let requested = cameraCheckbox.state == .on
        guard requested else {
            cameraOptions.isEnabled = false
            saveAndPublishCameraOptions()
            updateCameraControlState()
            return
        }
        cameraCheckbox.isEnabled = false
        isRequestingCameraPermission = true
        updateCameraControlState()
        updateStartButtonState()
        Task { [weak self] in
            guard let self else { return }
            let status = await cameraPermissionRequester()
            isRequestingCameraPermission = false
            guard status == .authorized else {
                cameraCheckbox.state = .off
                cameraOptions.isEnabled = false
                saveAndPublishCameraOptions()
                updateCameraControlState()
                updateStartButtonState()
                onCameraPermissionDenied?()
                return
            }
            cameraOptions.isEnabled = true
            saveAndPublishCameraOptions()
            updateCameraControlState()
            updateStartButtonState()
        }
    }

    @objc private func cameraDeviceChanged() {
        cameraOptions.deviceID = cameraPopup.selectedItem?.representedObject as? String
        saveAndPublishCameraOptions()
    }

    private var selectedMicrophoneID: String? {
        microphonePopup.selectedItem?.representedObject as? String
    }

    private var selectedVideoResolution: RecordingVideoResolution {
        guard let rawValue = resolutionPopup.selectedItem?.representedObject as? String,
              let resolution = RecordingVideoResolution(rawValue: rawValue) else {
            return .p1080
        }
        return resolution
    }

    private var selectedVideoFPS: Int {
        (fpsPopup.selectedItem?.representedObject as? Int) ?? 30
    }

    func updateSourcePixelSize(_ size: CGSize) {
        sourcePixelSize = size
        updateVideoQualitySummary()
    }

    @objc private func formatChanged() { updateFormatState() }

    @objc private func showRegionSizePopover() {
        guard !regionSizeButton.isHidden else { return }
        if regionSizePopover.isShown { regionSizePopover.performClose(nil) }
        else {
            regionSizePopover.show(
                relativeTo: regionSizeButton.bounds,
                of: regionSizeButton,
                preferredEdge: .maxY
            )
        }
    }

    @objc private func showCameraSettingsPopover() {
        guard !cameraSettingsButton.isHidden, cameraSettingsButton.isEnabled else { return }
        cameraSettingsView.update(options: cameraOptions)
        if cameraSettingsPopover.isShown { cameraSettingsPopover.performClose(nil) }
        else {
            cameraSettingsPopover.show(
                relativeTo: cameraSettingsButton.bounds,
                of: cameraSettingsButton,
                preferredEdge: .maxY
            )
        }
    }

    @objc private func startAction() {
        guard !isRequestingCameraPermission else { return }
        guard confirmDiskSpaceBeforeStarting() else { return }
        if formatControl.selectedSegment == 1 {
            onStart?(.gif, selectedVideoResolution, selectedVideoFPS, false, false, nil, nil, nil)
        } else {
            onStart?(
                .video,
                selectedVideoResolution,
                selectedVideoFPS,
                audioCheckbox.state == .on,
                microphoneCheckbox.state == .on && microphoneCheckbox.isEnabled,
                selectedMicrophoneID,
                cameraOptions,
                nil
            )
        }
    }

    private func updateFormatState() {
        let isVideo = formatControl.selectedSegment == 0
        audioLabel.isHidden = !isVideo
        audioCheckbox.isHidden = !isVideo
        microphoneCheckbox.isHidden = !isVideo
        microphonePopup.isHidden = !isVideo
        qualityLabel.isHidden = !isVideo
        resolutionPopup.isHidden = !isVideo
        fpsPopup.isHidden = !isVideo
        regionSizeButton.isHidden = !isVideo || !isRegionSizingAvailable
        performanceHint.isHidden = !isVideo || !isHighLoadSelection
        cameraLabel.isHidden = !isVideo
        cameraCheckbox.isHidden = !isVideo
        cameraPopup.isHidden = !isVideo
        cameraSettingsButton.isHidden = !isVideo
        audioCheckbox.isEnabled = isVideo
        microphoneCheckbox.isEnabled = isVideo && canUseMicrophonePermission
        microphonePopup.isEnabled = isVideo && hasMicrophones && microphoneCheckbox.state == .on
        silentHint.isHidden = isVideo
        if !isVideo { onCameraOptionsChanged?(nil) }
        else if cameraOptions.isEnabled { onCameraOptionsChanged?(cameraOptions) }
        updateCameraControlState()
        updateStartButtonState()
    }

    private var isHighLoadSelection: Bool {
        selectedVideoFPS == 60 && (selectedVideoResolution == .native || selectedVideoResolution == .p4K)
    }

    private func configureVideoQualityControls() {
        let savedResolution = RecordingPreferences.videoResolution()
        for resolution in RecordingVideoResolution.allCases {
            let title = resolution == .p1080 ? L.text("1080p（推荐）") : resolution.displayName
            resolutionPopup.addItem(withTitle: title)
            resolutionPopup.lastItem?.representedObject = resolution.rawValue
        }
        if let index = resolutionPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == savedResolution.rawValue
        }) {
            resolutionPopup.selectItem(at: index)
        }
        resolutionPopup.identifier = NSUserInterfaceItemIdentifier("recordingVideoResolution")
        resolutionPopup.target = self
        resolutionPopup.action = #selector(videoQualityChanged)
        resolutionPopup.toolTip = L.text("保持比例，不裁剪、不放大较小画面")
        resolutionPopup.widthAnchor.constraint(equalToConstant: 122).isActive = true

        let savedFPS = RecordingPreferences.videoFPS()
        for fps in [15, 30, 60] {
            let title = fps == 30 ? L.text("30 FPS（推荐）") : "\(fps) FPS"
            fpsPopup.addItem(withTitle: title)
            fpsPopup.lastItem?.representedObject = fps
        }
        if let index = fpsPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == savedFPS
        }) {
            fpsPopup.selectItem(at: index)
        }
        fpsPopup.identifier = NSUserInterfaceItemIdentifier("recordingVideoFPS")
        fpsPopup.target = self
        fpsPopup.action = #selector(videoQualityChanged)
        fpsPopup.widthAnchor.constraint(equalToConstant: 118).isActive = true

        performanceHint.font = .systemFont(ofSize: 11, weight: .medium)
        performanceHint.textColor = .systemOrange
        performanceHint.toolTip = L.text("高负载模式，长时间录制建议使用 1080p · 30 FPS")
        performanceHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateVideoQualitySummary()
    }

    private func configureCameraControls() {
        let devices = RecordingCameras.availableDevices()
        hasCameras = !devices.isEmpty
        for device in devices {
            cameraPopup.addItem(withTitle: device.name)
            cameraPopup.lastItem?.representedObject = device.id
        }
        if devices.isEmpty {
            cameraPopup.addItem(withTitle: L.text("未检测到摄像头"))
            cameraOptions.isEnabled = false
            cameraOptions.deviceID = nil
        } else if let saved = cameraOptions.deviceID,
                  let index = cameraPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == saved }) {
            cameraPopup.selectItem(at: index)
        } else {
            cameraOptions.deviceID = cameraPopup.selectedItem?.representedObject as? String
        }
        cameraCheckbox.state = cameraOptions.isEnabled ? .on : .off
        cameraCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingCamera")
        cameraCheckbox.target = self
        cameraCheckbox.action = #selector(cameraChanged)
        cameraPopup.identifier = NSUserInterfaceItemIdentifier("recordingCameraDevice")
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraDeviceChanged)
        cameraPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        cameraSettingsButton.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettings")
        RecordingCameraPreferences.save(cameraOptions)
        updateCameraControlState()
    }

    private func updateCameraControlState() {
        let active = formatControl.selectedSegment == 0
            && hasCameras
            && cameraCheckbox.state == .on
            && !isRequestingCameraPermission
        cameraCheckbox.isEnabled = formatControl.selectedSegment == 0 && hasCameras && !isRequestingCameraPermission
        cameraPopup.isEnabled = active
        cameraPopup.isHidden = !active
        cameraSettingsButton.isEnabled = active
        cameraSettingsButton.isHidden = !active
        if !active, cameraSettingsPopover.isShown { cameraSettingsPopover.performClose(nil) }
        startButton.isEnabled = !isRequestingCameraPermission
    }

    private func saveAndPublishCameraOptions() {
        RecordingCameraPreferences.save(cameraOptions)
        let active = formatControl.selectedSegment == 0 && cameraOptions.isEnabled
        onCameraOptionsChanged?(active ? cameraOptions : nil)
    }

    func updateCameraPlacement(_ updated: RecordingCameraOptions) {
        cameraOptions.normalizedCenterX = updated.normalizedCenterX
        cameraOptions.normalizedCenterY = updated.normalizedCenterY
        cameraOptions.relativeWidth = updated.relativeWidth
        cameraSettingsView.update(options: cameraOptions)
        RecordingCameraPreferences.save(cameraOptions)
    }

    private func updateStartButtonState() {
        if isRequestingCameraPermission {
            startButton.title = L.text("正在请求摄像头权限…")
            startButton.isEnabled = false
        } else {
            startButton.title = formatControl.selectedSegment == 0
                ? L.text("开始录制视频")
                : L.text("开始录制 GIF")
            startButton.isEnabled = true
        }
    }

    private func updateVideoQualitySummary() {
        performanceHint.isHidden = formatControl.selectedSegment != 0 || !isHighLoadSelection
    }

    func updateRegionSelection(pixelSize: CGSize, hasLast: Bool, isAvailable: Bool) {
        isRegionSizingAvailable = isAvailable
        regionSizeButton.isHidden = formatControl.selectedSegment != 0 || !isAvailable
        guard isAvailable else {
            if regionSizePopover.isShown { regionSizePopover.performClose(nil) }
            return
        }
        regionSizeButton.title = L.format(
            "选区 %d × %d",
            Int(pixelSize.width.rounded()),
            Int(pixelSize.height.rounded())
        )
        regionSizeView.update(pixelSize: pixelSize, hasLast: hasLast)
    }

    private func confirmDiskSpaceBeforeStarting() -> Bool {
        guard let availableBytes = availableDiskBytesProvider() else { return true }
        let availableGB = String(format: "%.1f", Double(availableBytes) / 1_000_000_000)
        switch RecordingDiskSpace.startDecision(availableBytes: availableBytes) {
        case .blocked:
            let alert = NSAlert()
            alert.messageText = L.text("磁盘空间不足")
            alert.informativeText = L.format(
                "当前可用空间约 %@ GB。录屏至少需要保留 12 GB，请清理空间后重试。",
                availableGB
            )
            alert.addButton(withTitle: L.text("好"))
            alert.runModal()
            return false
        case .warning:
            let alert = NSAlert()
            alert.messageText = L.text("磁盘空间较低")
            alert.informativeText = L.format(
                "当前可用空间约 %@ GB。录制中低于 12 GB 时将自动安全停止，建议先清理空间。",
                availableGB
            )
            alert.addButton(withTitle: L.text("仍要录制"))
            alert.addButton(withTitle: L.text("取消"))
            return alert.runModal() == .alertFirstButtonReturn
        case .allowed:
            return true
        }
    }

    @objc private func cancelAction() { onCancel?() }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

}

@MainActor
final class WatermarkInfoViewController: NSViewController {
    enum Scope {
        case screenshot
        case recording
        case combined
    }

    private let scope: Scope
    private let hasWatermarkContent: Bool

    static func preferredSize(scope: Scope, hasWatermarkContent: Bool) -> CGSize {
        let height: CGFloat
        if !hasWatermarkContent {
            height = 88
        } else {
            height = switch scope {
            case .screenshot: 88
            case .recording: 102
            case .combined: 96
            }
        }
        return CGSize(width: 280, height: height)
    }

    init(scope: Scope, hasWatermarkContent: Bool) {
        self.scope = scope
        self.hasWatermarkContent = hasWatermarkContent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let size = Self.preferredSize(scope: scope, hasWatermarkContent: hasWatermarkContent)
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: infoText)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)
        ])
        self.view = view
    }

    private var infoText: String {
        if !hasWatermarkContent {
            return L.text("请先在水印设置中填写文字或选择 Logo。\n\n没有可渲染的内容时，截图水印和录制水印都无法启用。")
        }
        switch scope {
        case .screenshot:
            return L.text("截图水印会应用到截图、复制、保存、贴图等图片输出。\n\nOCR 仍读取原始图片，不受水印影响。")
        case .recording:
            return L.text("水印在录制结束导出时添加，不会出现在录制过程中。\n\n开启后 MP4 需要重新编码，导出更久且画质可能轻微变化。")
        case .combined:
            return L.text("截图水印和录制水印共享同一套文字、Logo、位置和样式。\n\n录制水印在导出时添加，MP4 可能需要更久导出。")
        }
    }
}
