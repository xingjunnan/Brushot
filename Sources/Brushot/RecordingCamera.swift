import AppKit
@preconcurrency import AVFoundation

enum RecordingCameraShape: String, CaseIterable, Sendable {
    case roundedRectangle
    case circle

    var displayName: String {
        switch self {
        case .roundedRectangle: L.text("圆角矩形")
        case .circle: L.text("圆形")
        }
    }

    var aspectRatio: CGFloat {
        self == .circle ? 1 : 16 / 9
    }
}

enum RecordingCameraSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var relativeWidth: Double {
        switch self {
        case .small: 0.16
        case .medium: 0.22
        case .large: 0.30
        }
    }

    var displayName: String {
        switch self {
        case .small: L.text("小")
        case .medium: L.text("中")
        case .large: L.text("大")
        }
    }

    static func nearest(to relativeWidth: Double) -> RecordingCameraSize? {
        let result = allCases.min { abs($0.relativeWidth - relativeWidth) < abs($1.relativeWidth - relativeWidth) }
        guard let result, abs(result.relativeWidth - relativeWidth) < 0.025 else { return nil }
        return result
    }
}

enum RecordingCameraPosition: String, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft: L.text("左上角")
        case .topRight: L.text("右上角")
        case .bottomLeft: L.text("左下角")
        case .bottomRight: L.text("右下角")
        }
    }

    var normalizedCenter: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0.15, y: 0.82)
        case .topRight: CGPoint(x: 0.85, y: 0.82)
        case .bottomLeft: CGPoint(x: 0.15, y: 0.18)
        case .bottomRight: CGPoint(x: 0.85, y: 0.18)
        }
    }
}

struct RecordingCameraOptions: Equatable, Sendable {
    var isEnabled: Bool
    var deviceID: String?
    var shape: RecordingCameraShape
    var isMirrored: Bool
    var normalizedCenterX: Double
    var normalizedCenterY: Double
    var relativeWidth: Double

    static let defaults = RecordingCameraOptions(
        isEnabled: false,
        deviceID: nil,
        shape: .roundedRectangle,
        isMirrored: false,
        normalizedCenterX: 0.85,
        normalizedCenterY: 0.18,
        relativeWidth: 0.22
    )
}

enum RecordingCameraPreferences {
    private static let deviceKey = "recording.cameraDeviceID"
    private static let shapeKey = "recording.cameraShape"
    private static let centerXKey = "recording.cameraCenterX"
    private static let centerYKey = "recording.cameraCenterY"
    private static let relativeWidthKey = "recording.cameraRelativeWidth"

    static func load(defaults: UserDefaults = .standard) -> RecordingCameraOptions {
        let fallback = RecordingCameraOptions.defaults
        let shape = defaults.string(forKey: shapeKey).flatMap(RecordingCameraShape.init(rawValue:))
            ?? fallback.shape
        let centerX = defaults.object(forKey: centerXKey) == nil
            ? fallback.normalizedCenterX
            : defaults.double(forKey: centerXKey)
        let centerY = defaults.object(forKey: centerYKey) == nil
            ? fallback.normalizedCenterY
            : defaults.double(forKey: centerYKey)
        let relativeWidth = defaults.object(forKey: relativeWidthKey) == nil
            ? fallback.relativeWidth
            : defaults.double(forKey: relativeWidthKey)
        return RecordingCameraOptions(
            isEnabled: false,
            deviceID: defaults.string(forKey: deviceKey),
            shape: shape,
            isMirrored: false,
            normalizedCenterX: min(max(centerX, 0), 1),
            normalizedCenterY: min(max(centerY, 0), 1),
            relativeWidth: min(max(relativeWidth, 0.08), 0.8)
        )
    }

    static func save(_ options: RecordingCameraOptions, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "recording.cameraEnabled")
        if let deviceID = options.deviceID { defaults.set(deviceID, forKey: deviceKey) }
        else { defaults.removeObject(forKey: deviceKey) }
        defaults.set(options.shape.rawValue, forKey: shapeKey)
        defaults.removeObject(forKey: "recording.cameraMirrored")
        defaults.set(options.normalizedCenterX, forKey: centerXKey)
        defaults.set(options.normalizedCenterY, forKey: centerYKey)
        defaults.set(options.relativeWidth, forKey: relativeWidthKey)
    }
}

struct RecordingCameraDevice: Equatable, Sendable {
    let id: String
    let name: String
}

enum RecordingCameras {
    static func captureDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func availableDevices() -> [RecordingCameraDevice] {
        captureDevices().map { RecordingCameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestPermissionIfNeeded() async -> AVAuthorizationStatus {
        let status = authorizationStatus()
        guard status == .notDetermined else { return status }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : authorizationStatus()
    }
}

@MainActor
final class RecordingCameraSettingsView: NSView {
    var onOptionsChanged: ((RecordingCameraOptions) -> Void)?

    private var options: RecordingCameraOptions
    private let showsDevice: Bool
    private let devicePopup = NSPopUpButton()
    private lazy var shapeControl = NSSegmentedControl(
        labels: RecordingCameraShape.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: self,
        action: #selector(shapeChanged)
    )
    private lazy var sizeControl = NSSegmentedControl(
        labels: RecordingCameraSize.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: self,
        action: #selector(sizeChanged)
    )
    private lazy var positionControl = NSSegmentedControl(
        labels: ["↖", "↗", "↙", "↘"],
        trackingMode: .selectOne,
        target: self,
        action: #selector(positionChanged)
    )
    private lazy var flipCheckbox = NSButton(
        checkboxWithTitle: L.text("左右翻转"),
        target: self,
        action: #selector(flipChanged)
    )

    init(frame: CGRect, options: RecordingCameraOptions, showsDevice: Bool) {
        self.options = options
        self.showsDevice = showsDevice
        super.init(frame: frame)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        if showsDevice {
            let devices = RecordingCameras.availableDevices()
            for device in devices {
                devicePopup.addItem(withTitle: device.name)
                devicePopup.lastItem?.representedObject = device.id
            }
            if devices.isEmpty {
                devicePopup.addItem(withTitle: L.text("未检测到摄像头"))
                devicePopup.isEnabled = false
            }
            devicePopup.target = self
            devicePopup.action = #selector(deviceChanged)
            devicePopup.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsDevice")
            devicePopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
            rows.addArrangedSubview(makeRow(label: L.text("摄像头"), control: devicePopup))
        }

        shapeControl.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsShape")
        sizeControl.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsSize")
        positionControl.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsPosition")
        flipCheckbox.identifier = NSUserInterfaceItemIdentifier("recordingCameraSettingsFlip")
        shapeControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        sizeControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        positionControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        rows.addArrangedSubview(makeRow(label: L.text("形状"), control: shapeControl))
        rows.addArrangedSubview(makeRow(label: L.text("大小"), control: sizeControl))
        rows.addArrangedSubview(makeRow(label: L.text("位置"), control: positionControl))

        let bottom = NSStackView(views: [makeLabel(""), flipCheckbox])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        rows.addArrangedSubview(bottom)

        let hint = NSTextField(labelWithString: L.text("可直接拖动画中画调整位置"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let hintRow = NSStackView(views: [makeLabel(""), hint])
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 8
        rows.addArrangedSubview(hintRow)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14)
        ])
        update(options: options)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(options: RecordingCameraOptions) {
        self.options = options
        if showsDevice,
           let index = devicePopup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == options.deviceID
           }) {
            devicePopup.selectItem(at: index)
        }
        shapeControl.selectedSegment = RecordingCameraShape.allCases.firstIndex(of: options.shape) ?? 0
        sizeControl.selectedSegment = RecordingCameraSize.nearest(to: options.relativeWidth)
            .flatMap { RecordingCameraSize.allCases.firstIndex(of: $0) } ?? -1
        positionControl.selectedSegment = nearestPositionIndex(options: options)
        flipCheckbox.state = options.isMirrored ? .on : .off
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let row = NSStackView(views: [makeLabel(label), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return label
    }

    private func publish() { onOptionsChanged?(options) }

    @objc private func deviceChanged() {
        options.deviceID = devicePopup.selectedItem?.representedObject as? String
        publish()
    }

    @objc private func shapeChanged() {
        guard RecordingCameraShape.allCases.indices.contains(shapeControl.selectedSegment) else { return }
        options.shape = RecordingCameraShape.allCases[shapeControl.selectedSegment]
        publish()
    }

    @objc private func sizeChanged() {
        guard RecordingCameraSize.allCases.indices.contains(sizeControl.selectedSegment) else { return }
        options.relativeWidth = RecordingCameraSize.allCases[sizeControl.selectedSegment].relativeWidth
        publish()
    }

    @objc private func positionChanged() {
        guard RecordingCameraPosition.allCases.indices.contains(positionControl.selectedSegment) else { return }
        let position = RecordingCameraPosition.allCases[positionControl.selectedSegment]
        options.normalizedCenterX = Double(position.normalizedCenter.x)
        options.normalizedCenterY = Double(position.normalizedCenter.y)
        publish()
    }

    @objc private func flipChanged() {
        options.isMirrored = flipCheckbox.state == .on
        publish()
    }

    private func nearestPositionIndex(options: RecordingCameraOptions) -> Int {
        let point = CGPoint(x: options.normalizedCenterX, y: options.normalizedCenterY)
        let distances = RecordingCameraPosition.allCases.map { position in
            hypot(point.x - position.normalizedCenter.x, point.y - position.normalizedCenter.y)
        }
        guard let minimum = distances.min(), minimum < 0.08 else { return -1 }
        return distances.firstIndex(of: minimum) ?? -1
    }
}

enum RecordingCameraGeometry {
    static let margin: CGFloat = 12

    static func frame(in selection: CGRect, options: RecordingCameraOptions) -> CGRect {
        guard selection.width > 0, selection.height > 0 else { return .zero }
        let maximumWidth = max(40, selection.width - margin * 2)
        let minimumWidth = min(140, maximumWidth)
        var width = min(max(selection.width * options.relativeWidth, minimumWidth), min(360, maximumWidth))
        var height = width / options.shape.aspectRatio
        let maximumHeight = max(40, selection.height - margin * 2)
        if height > maximumHeight {
            height = maximumHeight
            width = height * options.shape.aspectRatio
        }
        let center = CGPoint(
            x: selection.minX + selection.width * options.normalizedCenterX,
            y: selection.minY + selection.height * options.normalizedCenterY
        )
        return clamp(
            CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
            to: selection
        )
    }

    static func options(
        byUpdating options: RecordingCameraOptions,
        frame: CGRect,
        in selection: CGRect
    ) -> RecordingCameraOptions {
        guard selection.width > 0, selection.height > 0 else { return options }
        let clamped = clamp(frame, to: selection)
        var updated = options
        updated.normalizedCenterX = min(max((clamped.midX - selection.minX) / selection.width, 0), 1)
        updated.normalizedCenterY = min(max((clamped.midY - selection.minY) / selection.height, 0), 1)
        updated.relativeWidth = min(max(clamped.width / selection.width, 0.08), 0.8)
        return updated
    }

    static func resizedFrame(
        from original: CGRect,
        widthDelta: CGFloat,
        shape: RecordingCameraShape,
        in selection: CGRect
    ) -> CGRect {
        let maximumWidth = max(40, selection.width - margin * 2)
        let minimumWidth = min(100, maximumWidth)
        var width = min(max(original.width + widthDelta, minimumWidth), min(480, maximumWidth))
        var height = width / shape.aspectRatio
        let maximumHeight = max(40, selection.height - margin * 2)
        if height > maximumHeight {
            height = maximumHeight
            width = height * shape.aspectRatio
        }
        let proposed = CGRect(
            x: original.minX,
            y: original.maxY - height,
            width: width,
            height: height
        )
        return clamp(proposed, to: selection)
    }

    static func clamp(_ frame: CGRect, to selection: CGRect) -> CGRect {
        var result = frame
        let minX = selection.minX + margin
        let minY = selection.minY + margin
        let maxX = selection.maxX - margin - result.width
        let maxY = selection.maxY - margin - result.height
        result.origin.x = min(max(result.origin.x, minX), max(minX, maxX))
        result.origin.y = min(max(result.origin.y, minY), max(minY, maxY))
        return result.integral
    }

    static func snappedFrame(
        _ frame: CGRect,
        to selection: CGRect,
        threshold: CGFloat = 24
    ) -> CGRect {
        var result = clamp(frame, to: selection)
        let left = selection.minX + margin
        let right = selection.maxX - margin - result.width
        let bottom = selection.minY + margin
        let top = selection.maxY - margin - result.height
        if abs(result.minX - left) <= threshold { result.origin.x = left }
        else if abs(result.minX - right) <= threshold { result.origin.x = right }
        if abs(result.minY - bottom) <= threshold { result.origin.y = bottom }
        else if abs(result.minY - top) <= threshold { result.origin.y = top }
        return result.integral
    }
}

private final class RecordingCameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    let device: AVCaptureDevice
    var onDisconnected: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.brushot.recording.camera", qos: .userInitiated)
    private var disconnectObserver: NSObjectProtocol?

    init(deviceID: String?) throws {
        let devices = RecordingCameras.captureDevices()
        guard let device = deviceID.flatMap({ id in devices.first { $0.uniqueID == id } })
            ?? AVCaptureDevice.default(for: .video)
            ?? devices.first else {
            throw NSError(
                domain: "Brushot.Camera",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.text("未检测到摄像头")]
            )
        }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: .main
        ) { [weak self] _ in
            self?.onDisconnected?()
        }
    }

    func start() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }
}

@MainActor
final class RecordingCameraPreviewView: NSView {
    var onOptionsChanged: ((RecordingCameraOptions) -> Void)?
    var onUnavailable: (() -> Void)?

    private(set) var options: RecordingCameraOptions
    private var allowedFrame: CGRect
    private let movesWindow: Bool
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let resizeHandleBackgroundLayer = CAShapeLayer()
    private let resizeHandleLayer = CAShapeLayer()
    private var capture: RecordingCameraCapture?
    private var dragStartMouse = CGPoint.zero
    private var dragStartFrame = CGRect.zero
    private var isResizing = false

    init(
        frame: CGRect,
        allowedFrame: CGRect,
        options: RecordingCameraOptions,
        movesWindow: Bool
    ) {
        self.allowedFrame = allowedFrame
        self.options = options
        self.movesWindow = movesWindow
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
        if !movesWindow {
            layer?.addSublayer(resizeHandleBackgroundLayer)
            layer?.addSublayer(resizeHandleLayer)
        }
        previewLayer.videoGravity = .resizeAspectFill
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        applyAppearance()
        updateResizeHandle()
    }

    func startPreview() throws {
        stopPreview()
        let capture = try RecordingCameraCapture(deviceID: options.deviceID)
        capture.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in self?.handleUnavailable() }
        }
        self.capture = capture
        previewLayer.session = capture.session
        updateMirroring()
        capture.start()
    }

    func stopPreview() {
        capture?.stop()
        capture = nil
        previewLayer.session = nil
    }

    func update(options: RecordingCameraOptions, allowedFrame: CGRect) {
        let deviceChanged = self.options.deviceID != options.deviceID
        self.options = options
        self.allowedFrame = allowedFrame
        let targetFrame = RecordingCameraGeometry.frame(in: allowedFrame, options: options)
        applyFrame(targetFrame)
        applyAppearance()
        updateMirroring()
        if deviceChanged, options.isEnabled { try? startPreview() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            CGRect(x: max(0, bounds.maxX - 34), y: 0, width: 34, height: 34),
            cursor: AnnotationCursorFactory.cursor(for: .resizeDiagonalDown)
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = movesWindow ? (window?.frame ?? frame) : frame
        let point = convert(event.locationInWindow, from: nil)
        isResizing = point.x >= bounds.maxX - 34 && point.y <= 34
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - dragStartMouse.x, y: mouse.y - dragStartMouse.y)
        let updatedFrame: CGRect
        if isResizing {
            let widthDelta = abs(delta.x) >= abs(delta.y)
                ? delta.x
                : -delta.y * options.shape.aspectRatio
            updatedFrame = RecordingCameraGeometry.resizedFrame(
                from: dragStartFrame,
                widthDelta: widthDelta,
                shape: options.shape,
                in: allowedFrame
            )
        } else {
            updatedFrame = RecordingCameraGeometry.clamp(
                dragStartFrame.offsetBy(dx: delta.x, dy: delta.y),
                to: allowedFrame
            )
        }
        applyFrame(updatedFrame)
        options = RecordingCameraGeometry.options(
            byUpdating: options,
            frame: updatedFrame,
            in: allowedFrame
        )
        onOptionsChanged?(options)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isResizing else { return }
        let currentFrame = movesWindow ? (window?.frame ?? frame) : frame
        let snapped = RecordingCameraGeometry.snappedFrame(currentFrame, to: allowedFrame)
        guard snapped != currentFrame else { return }
        applyFrame(snapped)
        options = RecordingCameraGeometry.options(
            byUpdating: options,
            frame: snapped,
            in: allowedFrame
        )
        onOptionsChanged?(options)
    }

    private func applyFrame(_ newFrame: CGRect) {
        if movesWindow { window?.setFrame(newFrame, display: true) }
        else { frame = newFrame }
    }

    private func applyAppearance() {
        let radius = options.shape == .circle ? bounds.height / 2 : min(18, bounds.height / 5)
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        previewLayer.cornerRadius = radius
        previewLayer.masksToBounds = true
    }

    private func updateMirroring() {
        guard let connection = previewLayer.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = options.isMirrored }
    }

    private func updateResizeHandle() {
        guard !movesWindow else { return }
        let center = CGPoint(x: max(15, bounds.maxX - 19), y: min(bounds.maxY - 15, 19))
        resizeHandleBackgroundLayer.path = CGPath(
            ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24),
            transform: nil
        )
        resizeHandleBackgroundLayer.fillColor = NSColor.black.withAlphaComponent(0.65).cgColor
        let path = CGMutablePath()
        for offset in [CGFloat(-5), 0, 5] {
            path.move(to: CGPoint(x: center.x + offset - 4, y: center.y - 6))
            path.addLine(to: CGPoint(x: center.x + 6, y: center.y + offset + 4))
        }
        resizeHandleLayer.path = path
        resizeHandleLayer.fillColor = nil
        resizeHandleLayer.strokeColor = NSColor.white.cgColor
        resizeHandleLayer.lineWidth = 1.5
        resizeHandleLayer.lineCap = .round
        resizeHandleLayer.lineJoin = .round
    }

    private func handleUnavailable() {
        stopPreview()
        isHidden = true
        onUnavailable?()
    }
}

private final class RecordingCameraPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingCameraOverlayController {
    let window: NSPanel
    private(set) var options: RecordingCameraOptions
    var onOptionsChanged: ((RecordingCameraOptions) -> Void)?
    var onUnavailable: (() -> Void)?

    private let selectionRect: CGRect
    private let previewView: RecordingCameraPreviewView
    private var isActive = false

    init(selectionRect: CGRect, options: RecordingCameraOptions, level: NSWindow.Level) {
        self.selectionRect = selectionRect
        self.options = options
        let frame = RecordingCameraGeometry.frame(in: selectionRect, options: options)
        window = RecordingCameraPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewView = RecordingCameraPreviewView(
            frame: CGRect(origin: .zero, size: frame.size),
            allowedFrame: selectionRect,
            options: options,
            movesWindow: true
        )
        previewView.autoresizingMask = [.width, .height]
        window.contentView = previewView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        previewView.onOptionsChanged = { [weak self] updated in
            guard let self else { return }
            self.options = updated
            RecordingCameraPreferences.save(updated)
            self.onOptionsChanged?(updated)
        }
        previewView.onUnavailable = { [weak self] in self?.onUnavailable?() }
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var isVisible: Bool { isActive }

    func show() throws {
        isActive = true
        options.isEnabled = true
        previewView.isHidden = false
        previewView.update(options: options, allowedFrame: selectionRect)
        try previewView.startPreview()
        window.orderFrontRegardless()
    }

    func hide() {
        isActive = false
        options.isEnabled = false
        previewView.stopPreview()
        previewView.isHidden = true
        window.orderOut(nil)
    }

    func toggle() throws {
        if isActive { hide() }
        else { try show() }
    }

    func update(options: RecordingCameraOptions) {
        var updated = options
        updated.isEnabled = isActive
        self.options = updated
        previewView.update(options: updated, allowedFrame: selectionRect)
    }

    func close() {
        isActive = false
        previewView.stopPreview()
        window.orderOut(nil)
        window.close()
    }
}
