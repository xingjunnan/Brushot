import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PinHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let contentHash: String
    let fileName: String
    let createdAt: Date
    var lastUsedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
}

@MainActor
final class PinHistoryStore {
    private struct Index: Codable {
        var version = 1
        var entries: [PinHistoryEntry]
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let maxEntries: Int
    private(set) var entries: [PinHistoryEntry] = []

    init(
        directoryURL: URL,
        maxEntries: Int = 100,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.indexURL = directoryURL.appendingPathComponent("index.json")
        self.fileManager = fileManager
        self.maxEntries = max(1, maxEntries)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        loadIndex()
    }

    @discardableResult
    func add(_ image: CGImage, now: Date = Date()) throws -> PinHistoryEntry {
        let pngData = try PinImageCodec.pngData(from: image)
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        if let index = entries.firstIndex(where: { $0.contentHash == hash }) {
            entries[index].lastUsedAt = now
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            try saveIndex()
            return entry
        }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let entry = PinHistoryEntry(
            id: id,
            contentHash: hash,
            fileName: fileName,
            createdAt: now,
            lastUsedAt: now,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
        try pngData.write(to: directoryURL.appendingPathComponent(fileName), options: .atomic)
        entries.insert(entry, at: 0)
        while entries.count > maxEntries {
            let removed = entries.removeLast()
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(removed.fileName))
        }
        try saveIndex()
        return entry
    }

    func image(for entry: PinHistoryEntry) -> CGImage? {
        guard entries.contains(where: { $0.id == entry.id }),
              let data = try? Data(contentsOf: directoryURL.appendingPathComponent(entry.fileName)) else {
            return nil
        }
        return PinImageCodec.cgImage(from: data)
    }

    func touch(_ entry: PinHistoryEntry, now: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].lastUsedAt = now
        let updated = entries.remove(at: index)
        entries.insert(updated, at: 0)
        try saveIndex()
    }

    func delete(_ entry: PinHistoryEntry) throws {
        entries.removeAll { $0.id == entry.id }
        let imageURL = directoryURL.appendingPathComponent(entry.fileName)
        if fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.removeItem(at: imageURL)
        }
        try saveIndex()
    }

    func clear() throws {
        for entry in entries {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(entry.fileName))
        }
        entries.removeAll()
        try saveIndex()
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(Index.self, from: data) else {
            entries = []
            return
        }
        entries = index.entries
            .filter { fileManager.fileExists(atPath: directoryURL.appendingPathComponent($0.fileName).path) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Index(entries: entries))
        try data.write(to: indexURL, options: .atomic)
    }
}

enum PinImageCodec {
    static func pngData(from image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw makeError(L.text("无法编码贴图图片。"))
        }
        return data
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func imageFromPasteboard(_ pasteboard: NSPasteboard = .general) -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = cgImage(from: data) {
                return image
            }
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "SnapInk.PinImage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum PinDesktopBehavior: Int {
    case currentDesktop
    case allDesktops
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PinImageView: NSView {
    var image: CGImage {
        didSet { needsDisplay = true }
    }
    weak var owner: PinWindowController?

    init(frame: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let destination = Self.aspectFitRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
        ) else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(
            cgImage: image,
            size: CGSize(width: image.width, height: image.height)
        ).draw(in: destination)
    }

    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return nil }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // magnify(with:) 等手势事件只派发给 key window 的 first responder。
        // .nonactivatingPanel 失去 key 后点击不会自动恢复 key，必须显式 makeKey
        // （不会激活 App，不会触发激活竞争）。
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            owner?.beginAnnotation()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.makeContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.015 : 0.1
        let factor = 1.0 + delta * sensitivity
        let point = convert(event.locationInWindow, from: nil)
        owner?.zoomBy(factor: factor, centeredAt: point)
    }

    override func magnify(with event: NSEvent) {
        guard abs(event.magnification) > 0.001 else { return }
        let factor = 1.0 + event.magnification
        let point = convert(event.locationInWindow, from: nil)
        owner?.zoomBy(factor: factor, centeredAt: point)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step = modifiers.contains(.shift) ? 10 : 1

        if modifiers.contains(.command) {
            switch event.keyCode {
            case 24: owner?.zoomIn()   // = / +
            case 27: owner?.zoomOut()  // -
            case 29: owner?.resetZoom() // 0
            default: super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 123: owner?.moveByPixels(dx: -step, dy: 0)
        case 124: owner?.moveByPixels(dx: step, dy: 0)
        case 125: owner?.moveByPixels(dx: 0, dy: -step)
        case 126: owner?.moveByPixels(dx: 0, dy: step)
        case 53: owner?.closePin()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    let id = UUID()
    private(set) var image: CGImage
    private weak var manager: PinManager?
    private let imageView: PinImageView
    private(set) var opacity: CGFloat = 1
    private(set) var cornerRadius: CGFloat = 10
    private(set) var desktopBehavior: PinDesktopBehavior = .currentDesktop
    private var annotationEditor: PinAnnotationEditorWindowController?

    init(
        image: CGImage,
        manager: PinManager,
        displaySize: CGSize? = nil,
        origin: CGPoint? = nil
    ) {
        self.image = image
        self.manager = manager
        let size = Self.displaySize(for: image, preferredSize: displaySize)
        let imageSize = CGSize(width: image.width, height: image.height)
        imageView = PinImageView(frame: CGRect(origin: .zero, size: size), image: image)
        let panel = PinPanel(
            contentRect: CGRect(origin: origin ?? .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        imageView.owner = self
        panel.contentView = imageView
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.minSize = Self.minimumSize(for: image)
        panel.aspectRatio = imageSize
        applyCornerRadius()
        setDesktopBehavior(.currentDesktop)
        if origin == nil { centerNearPointer(size: size) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(imageView)
        // magnify 等手势事件只路由到 active app 的 key window。
        // .accessory App 截图后可能失活，贴图虽 makeKey 但 app 非 active，
        // 手势不路由。激活 App 让贴图能接收捏合手势。
        NSApp.activate(ignoringOtherApps: true)
    }

    func setImage(_ image: CGImage) {
        self.image = image
        imageView.image = image
        guard let window else { return }
        let currentArea = max(1, window.frame.width * window.frame.height)
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let width = sqrt(currentArea * ratio)
        let height = width / ratio
        window.minSize = Self.minimumSize(for: image)
        window.aspectRatio = CGSize(width: image.width, height: image.height)
        window.setContentSize(CGSize(width: width, height: height))
    }

    func moveByPixels(dx: Int, dy: Int) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += CGFloat(dx)
        frame.origin.y += CGFloat(dy)
        window.setFrameOrigin(frame.origin)
    }

    // MARK: - Zoom

    func zoomBy(factor: CGFloat, centeredAt point: CGPoint) {
        guard let window else { return }
        let frame = window.frame
        let ratio = frame.height / max(1, frame.width)
        var newWidth = frame.width * factor
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let minWidth: CGFloat = 50
        let maxWidth = max(screen.width, screen.height) * 2
        newWidth = min(max(newWidth, minWidth), maxWidth)
        let newHeight = newWidth * ratio
        guard abs(newWidth - frame.width) > 0.5 else { return }

        let ratioX = point.x / max(1, frame.width)
        let ratioY = point.y / max(1, frame.height)
        let newOriginX = frame.origin.x + ratioX * (frame.width - newWidth)
        let newOriginY = frame.origin.y + ratioY * (frame.height - newHeight)

        window.setFrame(
            CGRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight),
            display: true,
            animate: false
        )
    }

    func zoomIn() {
        guard let window else { return }
        let center = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        zoomBy(factor: 1.25, centeredAt: center)
    }

    func zoomOut() {
        guard let window else { return }
        let center = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        zoomBy(factor: 0.8, centeredAt: center)
    }

    func resetZoom() {
        guard let window else { return }
        let size = Self.initialSize(for: image)
        let frame = window.frame
        let originX = frame.midX - size.width / 2
        let originY = frame.midY - size.height / 2
        window.setFrame(
            CGRect(x: originX, y: originY, width: size.width, height: size.height),
            display: true,
            animate: false
        )
    }

    func setOpacity(_ value: CGFloat) {
        opacity = min(1, max(0.15, value))
        window?.alphaValue = opacity
    }

    func setCornerRadius(_ value: CGFloat) {
        cornerRadius = min(48, max(0, value))
        applyCornerRadius()
    }

    func setDesktopBehavior(_ behavior: PinDesktopBehavior) {
        desktopBehavior = behavior
        switch behavior {
        case .currentDesktop:
            window?.collectionBehavior = [.managed, .fullScreenAuxiliary]
        case .allDesktops:
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L.text("再次标注…"), action: #selector(annotateAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.text("复制图片"), action: #selector(copyAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.text("保存图片…"), action: #selector(saveAction), keyEquivalent: ""))
        menu.addItem(.separator())

        let opacityItem = NSMenuItem(title: L.text("透明度"), action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(opacityAction(_:)), keyEquivalent: "")
            item.tag = value
            item.state = abs(opacity - CGFloat(value) / 100) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let cornerItem = NSMenuItem(title: L.text("圆角"), action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        for value in [0, 8, 16, 24] {
            let item = NSMenuItem(title: value == 0 ? L.text("直角") : "\(value) px", action: #selector(cornerAction(_:)), keyEquivalent: "")
            item.tag = value
            item.state = abs(cornerRadius - CGFloat(value)) < 0.01 ? .on : .off
            cornerMenu.addItem(item)
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)

        let desktopItem = NSMenuItem(title: L.text("桌面行为"), action: nil, keyEquivalent: "")
        let desktopMenu = NSMenu()
        let current = NSMenuItem(title: L.text("固定在当前桌面"), action: #selector(currentDesktopAction), keyEquivalent: "")
        current.state = desktopBehavior == .currentDesktop ? .on : .off
        desktopMenu.addItem(current)
        let all = NSMenuItem(title: L.text("跟随所有桌面"), action: #selector(allDesktopsAction), keyEquivalent: "")
        all.state = desktopBehavior == .allDesktops ? .on : .off
        desktopMenu.addItem(all)
        desktopItem.submenu = desktopMenu
        menu.addItem(desktopItem)

        menu.addItem(.separator())
        let zoomItem = NSMenuItem(title: L.text("缩放"), action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        zoomMenu.addItem(NSMenuItem(title: L.text("放大"), action: #selector(zoomInAction), keyEquivalent: ""))
        zoomMenu.addItem(NSMenuItem(title: L.text("缩小"), action: #selector(zoomOutAction), keyEquivalent: ""))
        zoomMenu.addItem(.separator())
        zoomMenu.addItem(NSMenuItem(title: L.text("重置大小"), action: #selector(resetZoomAction), keyEquivalent: ""))
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L.text("关闭贴图"), action: #selector(closeAction), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        for submenu in menu.items.compactMap(\.submenu) {
            for item in submenu.items { item.target = self }
        }
        return menu
    }

    func beginAnnotation() {
        guard annotationEditor == nil else {
            annotationEditor?.showWindow(nil)
            return
        }
        let editor = PinAnnotationEditorWindowController(image: image) { [weak self] updated in
            guard let self else { return }
            self.manager?.replaceImage(for: self.id, with: updated)
            self.annotationEditor = nil
        } onCancel: { [weak self] in
            self?.annotationEditor = nil
        }
        annotationEditor = editor
        editor.showWindow(nil)
    }

    func closePin() {
        manager?.closePin(id: id)
    }

    func windowWillClose(_ notification: Notification) {
        manager?.pinWindowDidClose(id: id)
    }

    @objc private func annotateAction() { beginAnnotation() }
    @objc private func copyAction() {
        try? ScreenshotWriter.copyToPasteboard(image, appliesScreenshotAppearance: false)
    }
    @objc private func closeAction() { closePin() }
    @objc private func opacityAction(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func cornerAction(_ sender: NSMenuItem) { setCornerRadius(CGFloat(sender.tag)) }
    @objc private func currentDesktopAction() { setDesktopBehavior(.currentDesktop) }
    @objc private func allDesktopsAction() { setDesktopBehavior(.allDesktops) }
    @objc private func zoomInAction() { zoomIn() }
    @objc private func zoomOutAction() { zoomOut() }
    @objc private func resetZoomAction() { resetZoom() }

    @objc private func saveAction() {
        let panel = configuredSavePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PinImageCodec.pngData(from: image).write(to: url, options: .atomic)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func configuredSavePanel(now: Date = Date()) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.defaultSaveFileName(now: now)
        panel.allowedContentTypes = [.png]
        panel.directoryURL = AppPreferences.saveLocation
        return panel
    }

    static func defaultSaveFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "SnapInk-贴图-\(formatter.string(from: now)).png"
    }

    private func applyCornerRadius() {
        imageView.layer?.cornerRadius = cornerRadius
        imageView.layer?.masksToBounds = true
    }

    private func centerNearPointer(size: CGSize) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: min(max(mouse.x - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height)
        )
        window.setFrameOrigin(origin)
    }

    private static func initialSize(for image: CGImage) -> CGSize {
        let pixelSize = CGSize(width: image.width, height: image.height)
        let maxWidth: CGFloat = 640
        let maxHeight: CGFloat = 480
        let downscale = min(1, maxWidth / pixelSize.width, maxHeight / pixelSize.height)
        var size = CGSize(width: pixelSize.width * downscale, height: pixelSize.height * downscale)
        let longestSide = max(size.width, size.height)
        if longestSide < 80 {
            let upscale = 80 / longestSide
            size.width *= upscale
            size.height *= upscale
        }
        return size
    }

    static func displaySize(for image: CGImage, preferredSize: CGSize?) -> CGSize {
        guard let preferredSize,
              preferredSize.width.isFinite,
              preferredSize.height.isFinite,
              preferredSize.width > 0,
              preferredSize.height > 0 else {
            return initialSize(for: image)
        }
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let area = preferredSize.width * preferredSize.height
        let width = sqrt(area * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private static func minimumSize(for image: CGImage) -> CGSize {
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        if ratio >= 1 {
            return CGSize(width: 80, height: 80 / ratio)
        }
        return CGSize(width: 80 * ratio, height: 80)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.text("贴图操作失败")
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class PinManager {
    static let shared = PinManager()

    let historyStore: PinHistoryStore
    private(set) var pinWindows: [UUID: PinWindowController] = [:]
    private var libraryController: PinLibraryWindowController?
    private var arePinsHidden = false
    var onVisibilityChanged: (() -> Void)?

    init(historyStore: PinHistoryStore? = nil) {
        if let historyStore {
            self.historyStore = historyStore
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SnapInk", isDirectory: true)
                .appendingPathComponent("PinLibrary", isDirectory: true)
            self.historyStore = PinHistoryStore(directoryURL: base)
        }
    }

    @discardableResult
    func pin(
        _ image: CGImage,
        displaySize: CGSize? = nil,
        recordHistory: Bool = true
    ) throws -> PinWindowController {
        if recordHistory { _ = try historyStore.add(image) }
        if arePinsHidden {
            arePinsHidden = false
            for existing in pinWindows.values { existing.show() }
        }
        let controller = PinWindowController(image: image, manager: self, displaySize: displaySize)
        pinWindows[controller.id] = controller
        controller.show()
        libraryController?.reload()
        onVisibilityChanged?()
        return controller
    }

    @discardableResult
    func pinClipboard(_ pasteboard: NSPasteboard = .general) throws -> PinWindowController {
        guard let image = PinImageCodec.imageFromPasteboard(pasteboard) else {
            throw NSError(
                domain: "SnapInk.PinClipboard",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.text("剪贴板中没有可贴出的图片。")]
            )
        }
        return try pin(image)
    }

    func pinHistoryEntry(_ entry: PinHistoryEntry) throws {
        guard let image = historyStore.image(for: entry) else {
            throw NSError(domain: "SnapInk.PinHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: L.text("历史图片已经丢失。")])
        }
        try historyStore.touch(entry)
        _ = try pin(image, recordHistory: false)
    }

    func replaceImage(for id: UUID, with image: CGImage) {
        guard let controller = pinWindows[id] else { return }
        controller.setImage(image)
        _ = try? historyStore.add(image)
        libraryController?.reload()
    }

    func closePin(id: UUID) {
        guard let controller = pinWindows.removeValue(forKey: id) else { return }
        controller.window?.delegate = nil
        controller.close()
        onVisibilityChanged?()
    }

    func pinWindowDidClose(id: UUID) {
        pinWindows.removeValue(forKey: id)
        onVisibilityChanged?()
    }

    func toggleAllPins() {
        arePinsHidden.toggle()
        for controller in pinWindows.values {
            if arePinsHidden {
                controller.window?.orderOut(nil)
            } else {
                controller.show()
            }
        }
        onVisibilityChanged?()
    }

    var visibilityMenuTitle: String {
        arePinsHidden ? L.text("显示全部贴图") : L.text("隐藏全部贴图")
    }

    func showLibrary() {
        if libraryController == nil {
            libraryController = PinLibraryWindowController(manager: self)
        }
        libraryController?.reload()
        libraryController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        libraryController?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class PinLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let manager: PinManager
    private let tableView = NSTableView()

    init(manager: PinManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.text("SnapInk 贴图库")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        manager.historyStore.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard manager.historyStore.entries.indices.contains(row) else { return nil }
        let entry = manager.historyStore.entries[row]
        let cell = NSView()
        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        if let image = manager.historyStore.image(for: entry) {
            thumbnail.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        let title = NSTextField(labelWithString: "\(entry.pixelWidth) × \(entry.pixelHeight)")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let date = NSTextField(labelWithString: formatter.string(from: entry.lastUsedAt))
        date.textColor = .secondaryLabelColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        date.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnail)
        cell.addSubview(title)
        cell.addSubview(date)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            thumbnail.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            thumbnail.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
            thumbnail.widthAnchor.constraint(equalToConstant: 112),
            title.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 20),
            date.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            date.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8)
        ])
        return cell
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        let clipboard = NSButton(title: L.text("从剪贴板贴图"), target: self, action: #selector(pinClipboardAction))
        let pin = NSButton(title: L.text("贴出选中项"), target: self, action: #selector(pinSelectedAction))
        let remove = NSButton(title: L.text("删除记录"), target: self, action: #selector(deleteSelectedAction))
        let clear = NSButton(title: L.text("清空历史"), target: self, action: #selector(clearAction))
        toolbar.addArrangedSubview(clipboard)
        toolbar.addArrangedSubview(pin)
        toolbar.addArrangedSubview(remove)
        toolbar.addArrangedSubview(clear)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PinHistory"))
        column.title = L.text("历史贴图")
        column.width = 600
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = 92
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pinSelectedAction)
        tableView.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    @objc private func pinClipboardAction() {
        do { _ = try manager.pinClipboard() } catch { showError(error.localizedDescription) }
    }

    @objc private func pinSelectedAction() {
        let row = tableView.selectedRow
        guard manager.historyStore.entries.indices.contains(row) else { return }
        do { try manager.pinHistoryEntry(manager.historyStore.entries[row]) }
        catch { showError(error.localizedDescription) }
    }

    @objc private func deleteSelectedAction() {
        let row = tableView.selectedRow
        guard manager.historyStore.entries.indices.contains(row) else { return }
        do {
            try manager.historyStore.delete(manager.historyStore.entries[row])
            reload()
        } catch { showError(error.localizedDescription) }
    }

    @objc private func clearAction() {
        let alert = NSAlert()
        alert.messageText = L.text("清空贴图历史？")
        alert.informativeText = L.text("已打开的贴图不会关闭，历史图片将从磁盘删除。")
        alert.addButton(withTitle: L.text("清空"))
        alert.addButton(withTitle: L.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try manager.historyStore.clear(); reload() }
        catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.text("贴图库操作失败")
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class PinAnnotationEditorWindowController: NSWindowController {
    private let canvas: AnnotationCanvasView
    private let toolbar: AnnotationToolbarView
    private let scrollView = NSScrollView()
    private var activeTool: AnnotationTool = .select
    private var styles = Dictionary(uniqueKeysWithValues: AnnotationTool.drawingTools.map {
        ($0, AnnotationStylePreferences.load(for: $0))
    })
    private let onFinish: (CGImage) -> Void
    private let onCancel: () -> Void

    init(
        image: CGImage,
        title: String = L.text("贴图二次标注"),
        onFinish: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let maximumCanvasWidth = min(1000, visible.width - 80)
        let maximumViewportHeight = min(700, visible.height - 150)
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let imageWidth = min(CGFloat(image.width), maximumCanvasWidth)
        let imageSize = CGSize(width: imageWidth, height: imageWidth / ratio)
        let viewportHeight = min(imageSize.height, maximumViewportHeight)
        canvas = AnnotationCanvasView(frame: CGRect(origin: .zero, size: imageSize), baseImage: image)
        toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 72))
        let contentSize = CGSize(
            width: max(imageSize.width + 18, toolbar.frame.width) + 20,
            height: viewportHeight + 92
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureLayout(imageSize: imageSize, viewportHeight: viewportHeight)
        configureActions()
        setTool(.select)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    private func configureLayout(imageSize: CGSize, viewportHeight: CGFloat) {
        guard let content = window?.contentView else { return }
        scrollView.hasVerticalScroller = imageSize.height > viewportHeight + 0.5
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = canvas
        scrollView.frame = CGRect(
            x: 10,
            y: 84,
            width: content.bounds.width - 20,
            height: viewportHeight
        )
        content.addSubview(scrollView)
        content.addSubview(toolbar)
        toolbar.setFrameOrigin(CGPoint(x: (content.bounds.width - toolbar.frame.width) / 2, y: 6))
        toolbar.setPinEditingMode()
        toolbar.setLongCaptureEnabled(false)
        toolbar.setGIFEnabled(false)
        toolbar.onPreferredSizeChanged = { [weak self] in
            guard let self, let content = self.window?.contentView else { return }
            self.toolbar.setFrameOrigin(CGPoint(x: (content.bounds.width - self.toolbar.frame.width) / 2, y: 6))
        }
    }

    private func configureActions() {
        toolbar.onToolSelected = { [weak self] tool in self?.setTool(tool) }
        toolbar.onStyleChanged = { [weak self] style in
            guard let self else { return }
            let target = self.canvas.document.selectedItem?.tool ?? self.activeTool
            guard target != .select else { return }
            self.styles[target] = style
            AnnotationStylePreferences.save(style, for: target)
            self.canvas.applyStyle(style)
        }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        toolbar.onRedo = { [weak self] in self?.canvas.redo() }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        toolbar.onSave = { [weak self] in self?.finish() }
        canvas.onDocumentChanged = { [weak self] in
            guard let self else { return }
            self.toolbar.setUndoEnabled(
                self.canvas.document.undoManager.canUndo,
                redoEnabled: self.canvas.document.undoManager.canRedo
            )
        }
        canvas.onSelectionChanged = { [weak self] item in self?.toolbar.setSelectedItem(item) }
        canvas.onToolShortcut = { [weak self] tool in self?.setTool(tool) }
        canvas.onCancelCapture = { [weak self] in self?.cancel() }
    }

    private func setTool(_ tool: AnnotationTool) {
        activeTool = tool
        let style = styles[tool] ?? .defaultStyle(for: tool)
        toolbar.setTool(tool, style: style)
        canvas.setTool(tool, style: style)
    }

    private func finish() {
        guard let image = try? canvas.renderedImage() else { return }
        onFinish(image)
        close()
    }

    private func cancel() {
        onCancel()
        close()
    }
}
