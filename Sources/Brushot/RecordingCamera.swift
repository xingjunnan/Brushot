import AppKit
@preconcurrency import AVFoundation

enum RecordingCameraShape: String, CaseIterable, Sendable {
    case roundedRectangle
    case circle

    var displayName: String {
        switch self {
        case .roundedRectangle: L.text("圆角矩形")
        case .circle: L.text("圆形画中画")
        }
    }

    var aspectRatio: CGFloat {
        self == .circle ? 1 : 16 / 9
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
        isMirrored: true,
        normalizedCenterX: 0.85,
        normalizedCenterY: 0.18,
        relativeWidth: 0.22
    )
}

enum RecordingCameraPreferences {
    private static let enabledKey = "recording.cameraEnabled"
    private static let deviceKey = "recording.cameraDeviceID"
    private static let shapeKey = "recording.cameraShape"
    private static let mirroredKey = "recording.cameraMirrored"
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
        let mirrored = defaults.object(forKey: mirroredKey) == nil
            ? fallback.isMirrored
            : defaults.bool(forKey: mirroredKey)
        return RecordingCameraOptions(
            isEnabled: defaults.bool(forKey: enabledKey),
            deviceID: defaults.string(forKey: deviceKey),
            shape: shape,
            isMirrored: mirrored,
            normalizedCenterX: min(max(centerX, 0), 1),
            normalizedCenterY: min(max(centerY, 0), 1),
            relativeWidth: min(max(relativeWidth, 0.08), 0.8)
        )
    }

    static func save(_ options: RecordingCameraOptions, defaults: UserDefaults = .standard) {
        defaults.set(options.isEnabled, forKey: enabledKey)
        if let deviceID = options.deviceID { defaults.set(deviceID, forKey: deviceKey) }
        else { defaults.removeObject(forKey: deviceKey) }
        defaults.set(options.shape.rawValue, forKey: shapeKey)
        defaults.set(options.isMirrored, forKey: mirroredKey)
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
        previewLayer.videoGravity = .resizeAspectFill
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        applyAppearance()
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
            CGRect(x: max(0, bounds.maxX - 22), y: 0, width: 22, height: 22),
            cursor: AnnotationCursorFactory.cursor(for: .resizeDiagonalDown)
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = movesWindow ? (window?.frame ?? frame) : frame
        let point = convert(event.locationInWindow, from: nil)
        isResizing = point.x >= bounds.maxX - 22 && point.y <= 22
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
    var isVisible: Bool { window.isVisible }

    func show() throws {
        options.isEnabled = true
        previewView.isHidden = false
        previewView.update(options: options, allowedFrame: selectionRect)
        try previewView.startPreview()
        window.orderFrontRegardless()
    }

    func hide() {
        options.isEnabled = false
        previewView.stopPreview()
        window.orderOut(nil)
    }

    func toggle() throws {
        if window.isVisible { hide() }
        else { try show() }
    }

    func close() {
        previewView.stopPreview()
        window.orderOut(nil)
        window.close()
    }
}
