import AppKit

@MainActor
final class RecordingTimelineView: NSView {
    enum Interaction {
        case none
        case scrub
        case trimStart
        case trimEnd
    }

    var duration: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimStart: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimEnd: TimeInterval = 0 { didSet { needsDisplay = true } }
    var currentTime: TimeInterval = 0 { didSet { needsDisplay = true } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var isInteractionEnabled = true { didSet { window?.invalidateCursorRects(for: self) } }
    var visibleRange: ClosedRange<TimeInterval>? { didSet { needsDisplay = true } }
    var movesNearestHandleOnTrackClick = false
    var allowsTrimInteraction = true
    var showsVisibleRangeLabels = false

    var onSeek: ((TimeInterval) -> Void)?
    var onTrimStarted: (() -> Void)?
    var onTrimChanged: ((TimeInterval, TimeInterval, TimeInterval) -> Void)?
    var onTrimEnded: (() -> Void)?

    private var interaction = Interaction.none

    override var intrinsicContentSize: NSSize { CGSize(width: NSView.noIntrinsicMetric, height: 76) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = trackRect
        let path = NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        drawThumbnails(in: track, clippedBy: path)
        drawTrimmedAreas(in: track)
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
        addCursorRect(bounds, cursor: .pointingHand)
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
        if !allowsTrimInteraction {
            interaction = .scrub
            onSeek?(time)
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
        } else if movesNearestHandleOnTrackClick {
            interaction = abs(time - trimStart) <= abs(time - trimEnd) ? .trimStart : .trimEnd
            onTrimStarted?()
            updateActiveHandle(to: time)
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
            updateActiveHandle(to: time)
        case .trimEnd:
            updateActiveHandle(to: time)
        case .none:
            break
        }
    }

    func endInteraction() {
        if interaction == .trimStart || interaction == .trimEnd { onTrimEnded?() }
        interaction = .none
    }

    private var trackRect: CGRect {
        CGRect(x: 16, y: 18, width: max(1, bounds.width - 32), height: 44)
    }

    private func x(for time: TimeInterval) -> CGFloat {
        let span = max(0.001, visibleEnd - visibleStart)
        let fraction = (time - visibleStart) / span
        return trackRect.minX + trackRect.width * CGFloat(min(1, max(0, fraction)))
    }

    private func time(at x: CGFloat) -> TimeInterval {
        let fraction = min(1, max(0, (x - trackRect.minX) / max(1, trackRect.width)))
        return visibleStart + (visibleEnd - visibleStart) * TimeInterval(fraction)
    }

    private var visibleStart: TimeInterval {
        min(duration, max(0, visibleRange?.lowerBound ?? 0))
    }

    private var visibleEnd: TimeInterval {
        max(visibleStart, min(duration, visibleRange?.upperBound ?? duration))
    }

    private func updateActiveHandle(to time: TimeInterval) {
        switch interaction {
        case .trimStart:
            trimStart = min(max(0, time), trimEnd - 0.05)
            onTrimChanged?(trimStart, trimEnd, trimStart)
        case .trimEnd:
            trimEnd = max(trimStart + 0.05, min(duration, time))
            onTrimChanged?(trimStart, trimEnd, trimEnd)
        case .none, .scrub:
            break
        }
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
        let leftTime = showsVisibleRangeLabels ? visibleStart : trimStart
        let rightTime = showsVisibleRangeLabels ? visibleEnd : trimEnd
        NSString(string: Self.formatTime(leftTime)).draw(at: CGPoint(x: track.minX, y: 2), withAttributes: attributes)
        let end = NSString(string: Self.formatTime(rightTime))
        let size = end.size(withAttributes: attributes)
        end.draw(at: CGPoint(x: track.maxX - size.width, y: 2), withAttributes: attributes)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
