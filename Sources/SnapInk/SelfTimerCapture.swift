import AppKit
import Carbon

enum SelfTimerPreferences {
    static let durationRange = 1...60
    private static let durationKey = "selfTimer.durationSeconds"
    private static let tickSoundKey = "selfTimer.playsTickSound"

    static func durationSeconds(defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.object(forKey: durationKey) as? Int ?? 5
        return min(max(raw, durationRange.lowerBound), durationRange.upperBound)
    }

    static func setDurationSeconds(_ seconds: Int, defaults: UserDefaults = .standard) {
        defaults.set(min(max(seconds, durationRange.lowerBound), durationRange.upperBound), forKey: durationKey)
    }

    static func playsTickSound(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tickSoundKey) as? Bool ?? true
    }

    static func setPlaysTickSound(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: tickSoundKey)
    }
}

struct SelfTimerCountdownState: Equatable {
    enum Event: Equatable {
        case updated(Int)
        case completed
        case ignored
    }

    let duration: Int
    private(set) var remaining: Int
    private(set) var isTerminal = false

    init(duration: Int) {
        let clamped = min(max(duration, SelfTimerPreferences.durationRange.lowerBound), SelfTimerPreferences.durationRange.upperBound)
        self.duration = clamped
        remaining = clamped
    }

    mutating func advance() -> Event {
        guard !isTerminal else { return .ignored }
        remaining -= 1
        if remaining <= 0 {
            remaining = 0
            isTerminal = true
            return .completed
        }
        return .updated(remaining)
    }

    mutating func cancel() -> Bool {
        guard !isTerminal else { return false }
        isTerminal = true
        return true
    }
}

@MainActor
final class DelayedCaptureStartBar: NSVisualEffectView {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    private let hint = NSTextField(labelWithString: "")

    init(frame: NSRect, duration: Int) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        setDuration(duration)
        let cancel = NSButton(title: L.text("取消"), target: self, action: #selector(cancelAction))
        let start = NSButton(title: L.text("开始倒计时"), target: self, action: #selector(startAction))
        start.keyEquivalent = "\r"
        start.contentTintColor = .controlAccentColor
        start.identifier = NSUserInterfaceItemIdentifier("startDelayedCaptureAction")
        let stack = NSStackView(views: [hint, cancel, start])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDuration(_ seconds: Int) { hint.stringValue = L.format("%d 秒后截图", seconds) }

    @objc private func startAction() { onStart?() }
    @objc private func cancelAction() { onCancel?() }
}

private final class SelfTimerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SelfTimerBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.stroke()
    }
}

private final class SelfTimerHUDView: NSVisualEffectView {
    var onCancel: (() -> Void)?
    private let numberLabel = NSTextField(labelWithString: "")
    private var remaining = 1
    private var duration = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        numberLabel.alignment = .center
        numberLabel.textColor = .labelColor
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(remaining: Int, duration: Int) {
        self.remaining = remaining
        self.duration = max(1, duration)
        numberLabel.stringValue = "\(remaining)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 9, dy: 9)
        let background = NSBezierPath(ovalIn: rect)
        background.lineWidth = 4
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        background.stroke()

        let fraction = CGFloat(remaining) / CGFloat(duration)
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: rect.width / 2,
            startAngle: 90,
            endAngle: 90 - 360 * fraction,
            clockwise: true
        )
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onCancel?() }
}

@MainActor
final class SelfTimerCountdownController {
    private var state: SelfTimerCountdownState
    private let playsTickSound: Bool
    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private var timer: Timer?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var hudPanel: SelfTimerPanel?
    private var borderPanel: NSPanel?
    private weak var hudView: SelfTimerHUDView?

    init(
        selectionRect: CGRect,
        screen: NSScreen,
        duration: Int,
        playsTickSound: Bool,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        state = SelfTimerCountdownState(duration: duration)
        self.playsTickSound = playsTickSound
        self.onComplete = onComplete
        self.onCancel = onCancel
        show(selectionRect: selectionRect, screen: screen)
    }

    func cancel() {
        guard state.cancel() else { return }
        dismissImmediate()
        onCancel()
    }

    func dismiss() {
        _ = state.cancel()
        dismissImmediate()
    }

    private func show(selectionRect: CGRect, screen: NSScreen) {
        let borderFrame = selectionRect.insetBy(dx: -4, dy: -4)
        let border = NSPanel(
            contentRect: borderFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        border.level = .screenSaver
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = SelfTimerBorderView(frame: CGRect(origin: .zero, size: borderFrame.size))
        borderPanel = border

        let size = CGSize(width: 96, height: 96)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: selectionRect.midX - size.width / 2, y: selectionRect.maxY + 16)
        if origin.y + size.height > visible.maxY { origin.y = selectionRect.minY - size.height - 16 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let panel = SelfTimerPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = SelfTimerHUDView(frame: CGRect(origin: .zero, size: size))
        view.update(remaining: state.remaining, duration: state.duration)
        view.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = view
        hudView = view
        hudPanel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.cancel()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor in self?.cancel() }
        }
        border.orderFrontRegardless()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        switch state.advance() {
        case .updated(let remaining):
            hudView?.update(remaining: remaining, duration: state.duration)
            if playsTickSound { NSSound(named: "Tink")?.play() }
        case .completed:
            dismissImmediate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [onComplete] in onComplete() }
        case .ignored:
            break
        }
    }

    private func dismissImmediate() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        globalKeyMonitor = nil
        hudPanel?.orderOut(nil)
        borderPanel?.orderOut(nil)
        hudPanel?.close()
        borderPanel?.close()
        hudPanel = nil
        borderPanel = nil
    }
}
