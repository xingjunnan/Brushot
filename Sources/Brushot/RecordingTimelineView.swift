import AppKit

@MainActor
final class RecordingTimelineView: NSView {
    enum Interaction {
        case none
        case scrub
        case trimStart
        case trimEnd
        case selectRange
    }

    var duration: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimStart: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimEnd: TimeInterval = 0 { didSet { needsDisplay = true } }
    var currentTime: TimeInterval = 0 { didSet { needsDisplay = true } }
    var deletedRanges: [ClosedRange<TimeInterval>] = [] { didSet { needsDisplay = true } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var isInteractionEnabled = true { didSet { window?.invalidateCursorRects(for: self) } }
    var isRangeSelectionEnabled = false {
        didSet {
            if !isRangeSelectionEnabled { pendingSelection = nil }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var pendingSelection: ClosedRange<TimeInterval>?

    var onSeek: ((TimeInterval) -> Void)?
    var onTrimStarted: (() -> Void)?
    var onTrimChanged: ((TimeInterval, TimeInterval, TimeInterval) -> Void)?
    var onTrimEnded: (() -> Void)?
    var onSelectionChanged: ((ClosedRange<TimeInterval>?) -> Void)?
    var onDeletedRangeSelected: ((Int) -> Void)?

    private var interaction = Interaction.none
    private var dragOriginTime: TimeInterval = 0

    override var intrinsicContentSize: NSSize { CGSize(width: NSView.noIntrinsicMetric, height: 76) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = trackRect
        let path = NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        drawThumbnails(in: track, clippedBy: path)
        drawTrimmedAreas(in: track)
        drawDeletedRanges(in: track)
        if let pendingSelection { drawRange(pendingSelection, in: track, color: .systemOrange, alpha: 0.68) }
        drawBorder(in: track)
        drawTrimHandle(at: x(for: trimStart), isStart: true, in: track)
        drawTrimHandle(at: x(for: trimEnd), isStart: false, in: track)
        drawPlayhead(at: x(for: currentTime), in: track)
        drawTimeLabels(track: track)
    }

    override func resetCursorRects() {
        guard isInteractionEnabled else {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        if isRangeSelectionEnabled {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        beginInteraction(atX: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        continueInteraction(atX: point.x)
    }

    override func mouseUp(with event: NSEvent) {
        endInteraction()
    }

    func beginInteraction(atX xPosition: CGFloat) {
        guard isInteractionEnabled, duration > 0 else { return }
        let time = time(at: xPosition)
        dragOriginTime = time
        if isRangeSelectionEnabled {
            interaction = .selectRange
            pendingSelection = time...time
            onSelectionChanged?(pendingSelection)
            return
        }
        let startDistance = abs(xPosition - x(for: trimStart))
        let endDistance = abs(xPosition - x(for: trimEnd))
        if startDistance <= 13, startDistance <= endDistance {
            interaction = .trimStart
            onTrimStarted?()
        } else if endDistance <= 13 {
            interaction = .trimEnd
            onTrimStarted?()
        } else if let index = deletedRanges.firstIndex(where: { $0.contains(time) }) {
            interaction = .none
            onDeletedRangeSelected?(index)
        } else {
            interaction = .scrub
            onSeek?(time)
        }
    }

    func continueInteraction(atX xPosition: CGFloat) {
        guard duration > 0 else { return }
        let time = time(at: xPosition)
        switch interaction {
        case .scrub:
            onSeek?(time)
        case .trimStart:
            trimStart = min(max(0, time), trimEnd - 0.05)
            onTrimChanged?(trimStart, trimEnd, trimStart)
        case .trimEnd:
            trimEnd = max(trimStart + 0.05, min(duration, time))
            onTrimChanged?(trimStart, trimEnd, trimEnd)
        case .selectRange:
            let lower = max(trimStart, min(dragOriginTime, time))
            let upper = min(trimEnd, max(dragOriginTime, time))
            pendingSelection = lower...upper
            onSelectionChanged?(pendingSelection)
        case .none:
            break
        }
    }

    func endInteraction() {
        if interaction == .trimStart || interaction == .trimEnd { onTrimEnded?() }
        interaction = .none
    }

    func clearPendingSelection() {
        pendingSelection = nil
        onSelectionChanged?(nil)
        needsDisplay = true
    }

    private var trackRect: CGRect {
        CGRect(x: 16, y: 18, width: max(1, bounds.width - 32), height: 44)
    }

    private func x(for time: TimeInterval) -> CGFloat {
        trackRect.minX + trackRect.width * CGFloat(min(1, max(0, time / max(0.001, duration))))
    }

    private func time(at x: CGFloat) -> TimeInterval {
        let fraction = min(1, max(0, (x - trackRect.minX) / max(1, trackRect.width)))
        return duration * TimeInterval(fraction)
    }

    private func drawThumbnails(in track: CGRect, clippedBy path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if thumbnails.isEmpty {
            NSColor.black.withAlphaComponent(0.82).setFill()
            track.fill()
            let stripeWidth: CGFloat = 26
            var x = track.minX
            var alternate = false
            while x < track.maxX {
                (alternate ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.08)).setFill()
                CGRect(x: x, y: track.minY, width: stripeWidth, height: track.height).fill()
                alternate.toggle()
                x += stripeWidth
            }
        } else {
            let width = track.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let destination = CGRect(x: track.minX + CGFloat(index) * width, y: track.minY, width: width + 1, height: track.height)
                image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.medium])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTrimmedAreas(in track: CGRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        CGRect(x: track.minX, y: track.minY, width: max(0, x(for: trimStart) - track.minX), height: track.height).fill()
        CGRect(x: x(for: trimEnd), y: track.minY, width: max(0, track.maxX - x(for: trimEnd)), height: track.height).fill()
    }

    private func drawDeletedRanges(in track: CGRect) {
        for range in deletedRanges {
            let rect = drawRange(range, in: track, color: .systemRed, alpha: 0.62)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            NSColor.white.withAlphaComponent(0.45).setStroke()
            let lines = NSBezierPath()
            var x = rect.minX - track.height
            while x < rect.maxX {
                lines.move(to: CGPoint(x: x, y: rect.minY))
                lines.line(to: CGPoint(x: x + track.height, y: rect.maxY))
                x += 9
            }
            lines.lineWidth = 1
            lines.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    @discardableResult
    private func drawRange(_ range: ClosedRange<TimeInterval>, in track: CGRect, color: NSColor, alpha: CGFloat) -> CGRect {
        let rect = CGRect(
            x: x(for: range.lowerBound),
            y: track.minY,
            width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)),
            height: track.height
        )
        color.withAlphaComponent(alpha).setFill()
        rect.fill()
        return rect
    }

    private func drawBorder(in track: CGRect) {
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawTrimHandle(at x: CGFloat, isStart: Bool, in track: CGRect) {
        let width: CGFloat = 10
        let rect = CGRect(x: x - (isStart ? 1 : width - 1), y: track.minY - 3, width: width, height: track.height + 6)
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let grip = NSBezierPath()
        grip.move(to: CGPoint(x: rect.midX, y: rect.midY - 7))
        grip.line(to: CGPoint(x: rect.midX, y: rect.midY + 7))
        grip.lineWidth = 1.5
        grip.stroke()
    }

    private func drawPlayhead(at x: CGFloat, in track: CGRect) {
        NSColor.white.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: x, y: track.minY - 6))
        line.line(to: CGPoint(x: x, y: track.maxY + 6))
        line.lineWidth = 2
        line.stroke()
        NSColor.controlAccentColor.setFill()
        let marker = NSBezierPath()
        marker.move(to: CGPoint(x: x - 5, y: track.maxY + 7))
        marker.line(to: CGPoint(x: x + 5, y: track.maxY + 7))
        marker.line(to: CGPoint(x: x, y: track.maxY + 1))
        marker.close()
        marker.fill()
    }

    private func drawTimeLabels(track: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSString(string: Self.formatTime(trimStart)).draw(at: CGPoint(x: track.minX, y: 2), withAttributes: attributes)
        let end = NSString(string: Self.formatTime(trimEnd))
        let size = end.size(withAttributes: attributes)
        end.draw(at: CGPoint(x: track.maxX - size.width, y: 2), withAttributes: attributes)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
