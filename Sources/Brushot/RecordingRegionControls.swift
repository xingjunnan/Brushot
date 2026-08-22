import AppKit
import Foundation

enum RecordingRegionAspectRatio: String, CaseIterable {
    case free
    case landscape16x9
    case landscape4x3
    case square
    case portrait9x16

    var value: CGFloat? {
        switch self {
        case .free: nil
        case .landscape16x9: 16 / 9
        case .landscape4x3: 4 / 3
        case .square: 1
        case .portrait9x16: 9 / 16
        }
    }

    var displayName: String {
        switch self {
        case .free: L.text("自由")
        case .landscape16x9: "16:9"
        case .landscape4x3: "4:3"
        case .square: "1:1"
        case .portrait9x16: "9:16"
        }
    }
}

struct RecordingRegionSnapshot: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum RecordingRegionPreferences {
    private static let lastKey = "recordingRegion.last"

    static func snapshot(for rect: CGRect, in bounds: CGRect) -> RecordingRegionSnapshot? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return RecordingRegionSnapshot(
            x: clipped.minX / bounds.width,
            y: clipped.minY / bounds.height,
            width: clipped.width / bounds.width,
            height: clipped.height / bounds.height
        )
    }

    static func rect(for snapshot: RecordingRegionSnapshot, in bounds: CGRect) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = CGRect(
            x: bounds.minX + CGFloat(snapshot.x) * bounds.width,
            y: bounds.minY + CGFloat(snapshot.y) * bounds.height,
            width: CGFloat(snapshot.width) * bounds.width,
            height: CGFloat(snapshot.height) * bounds.height
        ).integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 24, rect.height >= 24 else { return nil }
        return rect
    }

    static func last(defaults: UserDefaults = .standard) -> RecordingRegionSnapshot? {
        load(key: lastKey, defaults: defaults)
    }

    static func setLast(_ snapshot: RecordingRegionSnapshot, defaults: UserDefaults = .standard) {
        save(snapshot, key: lastKey, defaults: defaults)
    }

    private static func load(key: String, defaults: UserDefaults) -> RecordingRegionSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecordingRegionSnapshot.self, from: data)
    }

    private static func save(
        _ snapshot: RecordingRegionSnapshot,
        key: String,
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

enum RecordingRegionGeometry {
    static func centeredRect(
        pixelSize: CGSize,
        scale: CGFloat,
        around center: CGPoint,
        in bounds: CGRect,
        minimumLogicalSize: CGFloat = 24
    ) -> CGRect {
        let safeScale = max(1, scale)
        var width = max(minimumLogicalSize, pixelSize.width / safeScale)
        var height = max(minimumLogicalSize, pixelSize.height / safeScale)
        width = min(width, bounds.width)
        height = min(height, bounds.height)
        let origin = CGPoint(
            x: min(max(center.x - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max(center.y - height / 2, bounds.minY), bounds.maxY - height)
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    static func fittedRect(
        aspectRatio: CGFloat,
        around center: CGPoint,
        preferredWidth: CGFloat,
        in bounds: CGRect,
        minimumLogicalSize: CGFloat = 24
    ) -> CGRect {
        let ratio = max(0.01, aspectRatio)
        var width = min(max(minimumLogicalSize, preferredWidth), bounds.width)
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        if width < minimumLogicalSize {
            width = min(bounds.width, minimumLogicalSize)
            height = min(bounds.height, width / ratio)
        }
        return centeredRect(
            pixelSize: CGSize(width: width, height: height),
            scale: 1,
            around: center,
            in: bounds,
            minimumLogicalSize: minimumLogicalSize
        )
    }
}

@MainActor
final class RecordingRegionSizeBar: NSVisualEffectView, NSTextFieldDelegate {
    var onPixelSizeChanged: ((CGSize) -> Void)?
    var onAspectRatioChanged: ((CGFloat?) -> Void)?
    var onRestoreLast: (() -> Void)?

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let ratioPopup = NSPopUpButton()
    private lazy var lockButton = NSButton(
        image: NSImage(systemSymbolName: "lock.open", accessibilityDescription: L.text("锁定比例")) ?? NSImage(),
        target: self,
        action: #selector(lockChanged)
    )
    private lazy var lastButton = NSButton(
        title: L.text("上次区域"),
        target: self,
        action: #selector(restoreLast)
    )
    private var lockedAspectRatio: CGFloat?
    private var isUpdating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        configureField(widthField, identifier: "recordingRegionWidth")
        configureField(heightField, identifier: "recordingRegionHeight")
        widthField.target = self
        widthField.action = #selector(widthChanged)
        heightField.target = self
        heightField.action = #selector(heightChanged)

        for ratio in RecordingRegionAspectRatio.allCases {
            ratioPopup.addItem(withTitle: ratio.displayName)
            ratioPopup.lastItem?.representedObject = ratio.rawValue
        }
        ratioPopup.selectItem(at: 0)
        ratioPopup.identifier = NSUserInterfaceItemIdentifier("recordingRegionRatio")
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged)
        ratioPopup.widthAnchor.constraint(equalToConstant: 78).isActive = true

        lockButton.bezelStyle = .texturedRounded
        lockButton.isBordered = false
        lockButton.identifier = NSUserInterfaceItemIdentifier("recordingRegionRatioLock")
        lockButton.toolTip = L.text("锁定比例")
        lockButton.setAccessibilityLabel(L.text("锁定比例"))
        lockButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        lastButton.identifier = NSUserInterfaceItemIdentifier("recordingRegionLast")

        let sizeLabel = label(L.text("区域大小"))
        let times = label("×")
        let pixels = label("px")
        let sizeRow = NSStackView(views: [
            sizeLabel,
            widthField,
            times,
            heightField,
            pixels
        ])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .centerY
        sizeRow.spacing = 7

        let ratioLabel = label(L.text("比例"))
        let ratioRow = NSStackView(views: [
            ratioLabel,
            ratioPopup,
            lockButton,
            lastButton
        ])
        ratioRow.orientation = .horizontal
        ratioRow.alignment = .centerY
        ratioRow.spacing = 7
        let stack = NSStackView(views: [sizeRow, ratioRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            sizeLabel.widthAnchor.constraint(equalToConstant: 58),
            ratioLabel.widthAnchor.constraint(equalToConstant: 58)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(pixelSize: CGSize, hasLast: Bool) {
        isUpdating = true
        widthField.stringValue = String(Int(pixelSize.width.rounded()))
        heightField.stringValue = String(Int(pixelSize.height.rounded()))
        lastButton.isEnabled = hasLast
        isUpdating = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === widthField { commitWidth() }
        if field === heightField { commitHeight() }
    }

    private func configureField(_ field: NSTextField, identifier: String) {
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 32_768
        formatter.allowsFloats = false
        field.formatter = formatter
    }

    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12, weight: .medium)
        return field
    }

    @objc private func widthChanged() { commitWidth() }
    @objc private func heightChanged() { commitHeight() }

    private func commitWidth() {
        guard !isUpdating, let width = positiveValue(widthField) else { return }
        var height = positiveValue(heightField) ?? 1
        if let ratio = lockedAspectRatio { height = max(1, Int((CGFloat(width) / ratio).rounded())) }
        onPixelSizeChanged?(CGSize(width: width, height: height))
    }

    private func commitHeight() {
        guard !isUpdating, let height = positiveValue(heightField) else { return }
        var width = positiveValue(widthField) ?? 1
        if let ratio = lockedAspectRatio { width = max(1, Int((CGFloat(height) * ratio).rounded())) }
        onPixelSizeChanged?(CGSize(width: width, height: height))
    }

    private func positiveValue(_ field: NSTextField) -> Int? {
        let value = field.integerValue
        return value > 0 ? value : nil
    }

    @objc private func ratioChanged() {
        guard let raw = ratioPopup.selectedItem?.representedObject as? String,
              let ratio = RecordingRegionAspectRatio(rawValue: raw) else { return }
        lockedAspectRatio = ratio.value
        updateLockAppearance()
        onAspectRatioChanged?(lockedAspectRatio)
    }

    @objc private func lockChanged() {
        if lockedAspectRatio == nil {
            guard let width = positiveValue(widthField),
                  let height = positiveValue(heightField) else { return }
            lockedAspectRatio = CGFloat(width) / CGFloat(height)
        } else {
            lockedAspectRatio = nil
            ratioPopup.selectItem(at: 0)
        }
        updateLockAppearance()
        onAspectRatioChanged?(lockedAspectRatio)
    }

    private func updateLockAppearance() {
        let locked = lockedAspectRatio != nil
        let title = L.text(locked ? "解锁比例" : "锁定比例")
        lockButton.image = NSImage(
            systemSymbolName: locked ? "lock.fill" : "lock.open",
            accessibilityDescription: title
        )
        lockButton.toolTip = title
        lockButton.setAccessibilityLabel(title)
        lockButton.contentTintColor = locked ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func restoreLast() { onRestoreLast?() }
}
